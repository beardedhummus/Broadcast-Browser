import BBBridge
import CoreVideo
import Foundation

enum NDIRuntime {
    private static let fourCCUYVY: UInt32 = 0x5956_5955 // 'UYVY'
    private static let fourCCBGRA: UInt32 = 0x4152_4742 // 'BGRA'

    static func fourCC(alpha: Bool) -> UInt32 { alpha ? fourCCBGRA : fourCCUYVY }

    /// Loads the NDI runtime, using the path from Preferences when set.
    static func ensureLoaded(customPath: String) throws {
        if BBNDIIsLoaded() { return }
        var errorBuffer = [CChar](repeating: 0, count: 512)
        let ok = customPath.withCString { path in
            BBNDILoad(customPath.isEmpty ? nil : path, &errorBuffer, Int32(errorBuffer.count))
        }
        if !ok {
            throw OutputStartError(String(cString: errorBuffer))
        }
    }

    static var isLoaded: Bool { BBNDIIsLoaded() }

    static var libraryPath: String? {
        BBNDILibraryPath().map { String(cString: $0) }
    }

    static var version: String? {
        BBNDIVersionString().map { String(cString: $0) }
    }

    /// Lists NDI sources currently visible on the network.
    static func findSources(waitMs: UInt32 = 2500) -> [String] {
        var buffer = [CChar](repeating: 0, count: 16_384)
        let count = BBNDIFindSources(&buffer, Int32(buffer.count), waitMs)
        guard count > 0 else { return [] }
        return String(cString: buffer).split(separator: "\n").map(String.init)
    }
}

/// NDI® sender. Frames are paced by our own clock and sent asynchronously
/// (UYVY 4:2:2, or BGRA when the alpha channel is enabled).
final class NDIOutput: OutputRuntime, @unchecked Sendable {
    private var sender: UnsafeMutableRawPointer?
    private var converter: PixelConverter?
    private var clock: OutputClock?
    private var inFlight: CVPixelBuffer?
    private var audioTap: OutputAudioTap?
    private var planar: [Float] = []
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "bb.ndi.poll", qos: .utility)
    var ndiLibraryPath = ""

    override func start() throws {
        setStatus(.starting)
        try NDIRuntime.ensureLoaded(customPath: ndiLibraryPath)
        let name = config.name.isEmpty ? "Broadcast Browser" : config.name
        guard let sender = BBNDISenderCreate(name, config.ndiGroups, false) else {
            throw OutputStartError("Could not create the NDI sender \"\(name)\".")
        }
        self.sender = sender
        let format = config.ndiAlpha ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_422YpCbCr8
        guard let converter = PixelConverter(width: config.width, height: config.height, pixelFormat: format, scaling: config.scaling, crop: config.cropRect) else {
            BBNDISenderDestroy(sender)
            self.sender = nil
            throw OutputStartError("Could not create the NDI frame converter.")
        }
        self.converter = converter
        stats.update { $0.detail = "NDI source: \(name)" }

        if config.audioEnabled {
            audioTap = OutputAudioTap(rate: config.frameRate)
        }
        let clock = OutputClock(frameRate: config.frameRate, name: "ndi",
                                tick: { [weak self] index in self?.sendFrame(index: index) },
                                onDrop: { [weak self] count in self?.stats.recordDropped(count) })
        self.clock = clock
        clock.start()
        startPolling()
        setStatus(.live)
    }

    private func sendFrame(index: Int64) {
        sendVideo()
        if let audioTap, let sender { sendAudio(audioTap, sender: sender, index: index) }
    }

    /// NDI wants planar float audio; the tap provides interleaved stereo.
    private func sendAudio(_ tap: OutputAudioTap, sender: UnsafeMutableRawPointer, index: Int64) {
        let (_, interleaved) = tap.samples(forFrame: index)
        let frames = interleaved.count / 2
        guard frames > 0 else { return }
        if planar.count < frames * 2 { planar = [Float](repeating: 0, count: frames * 2) }
        for i in 0..<frames {
            planar[i] = interleaved[i * 2]
            planar[frames + i] = interleaved[i * 2 + 1]
        }
        planar.withUnsafeBufferPointer { pointer in
            BBNDISenderSendAudio(sender, Int32(AudioHub.sampleRate), 2, Int32(frames), pointer.baseAddress!, Int32(frames * 4))
        }
    }

    private func sendVideo() {
        guard let sender, let converter, let frame = converter.frame(from: source) else { return }
        let buffer = frame.buffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            return
        }
        BBNDISenderSendVideo(sender,
                             Int32(converter.width),
                             Int32(converter.height),
                             NDIRuntime.fourCC(alpha: config.ndiAlpha),
                             config.frameRate.numerator,
                             config.frameRate.denominator,
                             base,
                             Int32(CVPixelBufferGetBytesPerRow(buffer)),
                             true)
        // The previous async frame is released by NDI once the new one is queued.
        if let previous = inFlight {
            CVPixelBufferUnlockBaseAddress(previous, .readOnly)
        }
        inFlight = buffer
        stats.recordFrame(sourceCounter: frame.counter)
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, let sender = self.sender else { return }
            let connections = BBNDISenderConnectionCount(sender, 0)
            var program = false
            var preview = false
            BBNDISenderGetTally(sender, &program, &preview)
            self.stats.update {
                $0.connections = Int(connections)
                $0.tallyProgram = program
                $0.tallyPreview = preview
            }
        }
        timer.resume()
        pollTimer = timer
    }

    override func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        pollQueue.sync {}
        clock?.stop()
        clock = nil
        if let sender {
            BBNDISenderFlushAsync(sender)
            if let previous = inFlight {
                CVPixelBufferUnlockBaseAddress(previous, .readOnly)
                inFlight = nil
            }
            BBNDISenderDestroy(sender)
        }
        sender = nil
        converter = nil
        audioTap = nil
        setStatus(.idle)
    }
}
