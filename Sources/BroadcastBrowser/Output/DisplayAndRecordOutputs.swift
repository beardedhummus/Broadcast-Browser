import AppKit
import AVFoundation
import CoreVideo
import QuartzCore

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// CADisplayLink retains its target; this proxy avoids a retain cycle.
final class DisplayLinkProxy: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire(_ link: CADisplayLink) { handler() }
}

/// Fullscreen output on a connected display / projector / HDMI port. Updates
/// are synced to that display's refresh via its display link.
final class DisplayOutput: OutputRuntime, @unchecked Sendable {
    private var window: NSWindow?
    private var layer: CALayer?
    private var converter: PixelConverter?
    private var displayLink: CADisplayLink?
    private var displayed: CVPixelBuffer?
    private var lastCounter: UInt64?

    override var requiredCaptureFPS: Double { 60 }

    override func start() throws {
        try MainActor.assumeIsolated {
            setStatus(.starting)
            guard let screen = NSScreen.screens.first(where: { $0.displayID == config.displayID }) else {
                throw OutputStartError("Display \"\(config.displayName)\" is not connected.")
            }
            let scale = screen.backingScaleFactor
            let pixelWidth = Int(screen.frame.width * scale)
            let pixelHeight = Int(screen.frame.height * scale)
            guard let converter = PixelConverter(width: pixelWidth, height: pixelHeight,
                                                 pixelFormat: kCVPixelFormatType_32BGRA, scaling: config.scaling, crop: config.cropRect) else {
                throw OutputStartError("Could not create the display converter.")
            }
            self.converter = converter

            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isReleasedWhenClosed = false
            window.backgroundColor = .black
            window.hasShadow = false
            window.canHide = false
            window.isExcludedFromWindowsMenu = true
            window.animationBehavior = .none
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            let layer = CALayer()
            layer.frame = view.bounds
            layer.contentsGravity = .resize
            layer.backgroundColor = NSColor.black.cgColor
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            view.layer?.addSublayer(layer)
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            self.window = window
            self.layer = layer

            let proxy = DisplayLinkProxy { [weak self] in self?.refresh() }
            let link = screen.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.fire(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
            stats.update { $0.detail = "\(config.displayName) · \(pixelWidth)×\(pixelHeight)" }
            setStatus(.live)
        }
    }

    private func refresh() {
        guard let converter, let layer, let frame = converter.frame(from: source) else { return }
        if let counter = frame.counter, counter == lastCounter {
            stats.recordFrame(sourceCounter: counter)
            return
        }
        lastCounter = frame.counter
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = CVPixelBufferGetIOSurface(frame.buffer)?.takeUnretainedValue()
        CATransaction.commit()
        displayed = frame.buffer
        stats.recordFrame(sourceCounter: frame.counter)
    }

    override func stop() {
        MainActor.assumeIsolated {
            displayLink?.invalidate()
            displayLink = nil
            window?.orderOut(nil)
            window?.close()
            window = nil
            layer = nil
            displayed = nil
            converter = nil
            setStatus(.idle)
        }
    }
}

/// Records the tab to a movie file (H.264/HEVC with a bitrate, or ProRes).
final class RecordOutput: OutputRuntime, @unchecked Sendable {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMAudioFormatDescription?
    private var audioTap: OutputAudioTap?
    private var converter: PixelConverter?
    private var clock: OutputClock?
    private let lock = NSLock()
    var tabName = "Tab"
    private(set) var fileURL: URL?

    override func start() throws {
        setStatus(.starting)
        let folderPath = config.recordFolder.isEmpty ? AppPaths.defaultRecordingsDirectory.path : config.recordFolder
        let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safeName = "\(tabName) - \(config.name)"
            .components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        let url = folder.appendingPathComponent("\(safeName) \(formatter.string(from: Date())).\(config.codec.fileExtension)")
        fileURL = url

        let fileType: AVFileType = config.codec.usesBitrate ? .mp4 : .mov
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        var settings: [String: Any] = [
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let pixelFormat: OSType
        switch config.codec {
        case .h264, .hevc:
            settings[AVVideoCodecKey] = config.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: Int(config.bitrateMbps * 1_000_000),
                AVVideoExpectedSourceFrameRateKey: config.frameRate.fps,
                AVVideoMaxKeyFrameIntervalKey: max(1, Int((config.frameRate.fps * config.keyframeIntervalSeconds).rounded())),
                AVVideoAllowFrameReorderingKey: false,
            ]
            if config.codec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            settings[AVVideoCompressionPropertiesKey] = compression
            pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .proRes422:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
            pixelFormat = kCVPixelFormatType_422YpCbCr8
        case .proRes422HQ:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422HQ
            pixelFormat = kCVPixelFormatType_422YpCbCr8
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw OutputStartError("The recorder rejected these video settings.") }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)

        // Audio: AAC in .mp4, 24-bit PCM alongside ProRes in .mov.
        var newAudioInput: AVAssetWriterInput?
        if config.audioEnabled {
            let audioSettings: [String: Any]
            if config.codec.usesBitrate {
                audioSettings = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: AudioHub.sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: max(64, config.audioBitrateKbps) * 1000,
                ]
            } else {
                audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: AudioHub.sampleRate,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 24,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
            }
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                newAudioInput = audio
                var asbd = AudioStreamBasicDescription(
                    mSampleRate: Float64(AudioHub.sampleRate), mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                    mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                    mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
                var format: CMAudioFormatDescription?
                CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                               magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                               formatDescriptionOut: &format)
                audioFormat = format
                audioTap = OutputAudioTap(rate: config.frameRate)
            }
        }

        guard writer.startWriting() else {
            throw OutputStartError(writer.error?.localizedDescription ?? "Could not start recording.")
        }
        writer.startSession(atSourceTime: .zero)
        guard let converter = PixelConverter(width: config.width, height: config.height, pixelFormat: pixelFormat, scaling: config.scaling, crop: config.cropRect) else {
            writer.cancelWriting()
            throw OutputStartError("Could not create the recording converter.")
        }
        lock.sync {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.audioInput = newAudioInput
            self.converter = converter
        }
        stats.update { $0.detail = url.lastPathComponent }

        let clock = OutputClock(frameRate: config.frameRate, name: "record",
                                tick: { [weak self] index in self?.append(index: index) },
                                onDrop: { [weak self] count in self?.stats.recordDropped(count) })
        self.clock = clock
        clock.start()
        setStatus(.live)
    }

    private func append(index: Int64) {
        let (input, adaptor, converter) = lock.sync { (self.input, self.adaptor, self.converter) }
        guard let input, let adaptor, let converter, let frame = converter.frame(from: source) else { return }
        guard input.isReadyForMoreMediaData else {
            stats.recordDropped()
            return
        }
        let time = CMTime(value: CMTimeValue(index) * CMTimeValue(config.frameRate.denominator),
                          timescale: config.frameRate.numerator)
        if adaptor.append(frame.buffer, withPresentationTime: time) {
            stats.recordFrame(sourceCounter: frame.counter)
        } else {
            stats.recordDropped()
        }
        appendAudio(index: index)
    }

    private func appendAudio(index: Int64) {
        let audioInput = lock.sync { self.audioInput }
        guard let audioInput, let audioTap, let audioFormat else { return }
        let (start, samples) = audioTap.samples(forFrame: index)
        let frames = samples.count / 2
        guard frames > 0, audioInput.isReadyForMoreMediaData else { return }
        let byteCount = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        samples.withUnsafeBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: frames,
            presentationTimeStamp: CMTime(value: start, timescale: CMTimeScale(AudioHub.sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
        if let sampleBuffer { audioInput.append(sampleBuffer) }
    }

    override func stop() {
        clock?.stop()
        clock = nil
        let (writer, input, audioInput) = lock.sync { () -> (AVAssetWriter?, AVAssetWriterInput?, AVAssetWriterInput?) in
            let result = (self.writer, self.input, self.audioInput)
            self.writer = nil
            self.input = nil
            self.audioInput = nil
            self.adaptor = nil
            self.converter = nil
            return result
        }
        audioTap = nil
        if let writer, writer.status == .writing {
            input?.markAsFinished()
            audioInput?.markAsFinished()
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            _ = done.wait(timeout: .now() + 5)
        }
        setStatus(.idle)
    }
}
