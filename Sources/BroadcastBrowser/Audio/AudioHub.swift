import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Interleaved stereo Float32 FIFO between the audio source and one output.
final class AudioRingBuffer: @unchecked Sendable {
    static let channels = 2
    private let lock = NSLock()
    private var storage: [Float]
    private let capacity: Int
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private(set) var underruns: UInt64 = 0
    private(set) var overruns: UInt64 = 0

    init(capacityFrames: Int) {
        capacity = max(1024, capacityFrames)
        storage = [Float](repeating: 0, count: capacity * Self.channels)
    }

    var bufferedFrames: Int { lock.sync { count } }

    func write(_ samples: UnsafePointer<Float>, frames: Int) {
        lock.sync {
            for i in 0..<frames {
                if count == capacity {
                    readIndex = (readIndex + 1) % capacity
                    count -= 1
                    overruns &+= 1
                }
                let w = writeIndex * 2
                storage[w] = samples[i * 2]
                storage[w + 1] = samples[i * 2 + 1]
                writeIndex = (writeIndex + 1) % capacity
                count += 1
            }
        }
    }

    func writeSilence(frames: Int) {
        let zeros = [Float](repeating: 0, count: frames * 2)
        zeros.withUnsafeBufferPointer { write($0.baseAddress!, frames: frames) }
    }

    /// Reads exactly `frames` stereo frames, padding with silence on underrun.
    /// If more than `maxLatencyFrames` are queued the oldest audio is dropped,
    /// so clock drift between the audio source and the output never builds up.
    func read(into out: UnsafeMutablePointer<Float>, frames: Int, maxLatencyFrames: Int) {
        lock.sync {
            if count > maxLatencyFrames + frames {
                let drop = count - maxLatencyFrames
                readIndex = (readIndex + drop) % capacity
                count -= drop
                overruns &+= 1
            }
            let available = min(frames, count)
            for i in 0..<available {
                let r = readIndex * 2
                out[i * 2] = storage[r]
                out[i * 2 + 1] = storage[r + 1]
                readIndex = (readIndex + 1) % capacity
            }
            count -= available
            if available < frames {
                underruns &+= 1
                for i in available..<frames {
                    out[i * 2] = 0
                    out[i * 2 + 1] = 0
                }
            }
        }
    }
}

/// Number of audio samples belonging to video frame `index` (exact cadence,
/// e.g. 1601/1602 samples per frame at 29.97 fps).
func audioSamples(forFrame index: Int64, rate: FrameRate, sampleRate: Int = 48000) -> (start: Int64, count: Int) {
    let numerator = Int64(sampleRate) * Int64(rate.denominator)
    let start = index * numerator / Int64(rate.numerator)
    let end = (index + 1) * numerator / Int64(rate.numerator)
    return (start, Int(end - start))
}

/// Captures website audio (the app's audio mix via ScreenCaptureKit) or
/// generates a line-up tone, and feeds every output that has audio enabled.
final class AudioHub: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {
    static let shared = AudioHub()
    static let sampleRate = 48000

    private let lock = NSLock()
    private var consumers: [ObjectIdentifier: AudioRingBuffer] = [:]
    private var stream: SCStream?
    private var toneThread: Thread?
    private var toneRunning = false
    private var running = false
    private var activeSource: AudioSource = .website
    private var statusText = "Off"
    private var peakL: Float = 0
    private var peakR: Float = 0
    private var lastMeterTime = CFAbsoluteTimeGetCurrent()
    private var receivedFrames: UInt64 = 0
    private let captureQueue = DispatchQueue(label: "bb.audio.capture", qos: .userInteractive)

    /// Extra delay added to every consumer (lip-sync trim).
    var delayMs = 0
    var source: AudioSource = .website {
        didSet {
            guard source != oldValue else { return }
            DispatchQueue.main.async { self.restart() }
        }
    }

    // MARK: Consumers

    func register() -> AudioRingBuffer {
        let ring = AudioRingBuffer(capacityFrames: Self.sampleRate * 2)
        let delayFrames = max(0, delayMs) * Self.sampleRate / 1000
        if delayFrames > 0 { ring.writeSilence(frames: delayFrames) }
        lock.sync { consumers[ObjectIdentifier(ring)] = ring }
        DispatchQueue.main.async { self.startIfNeeded() }
        return ring
    }

    func unregister(_ ring: AudioRingBuffer) {
        let empty = lock.sync { () -> Bool in
            consumers[ObjectIdentifier(ring)] = nil
            return consumers.isEmpty
        }
        if empty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.stopIfUnused() }
        }
    }

    var consumerCount: Int { lock.sync { consumers.count } }

    /// Latency limit used by outputs when reading (delay + ~120 ms of slack).
    var maxLatencyFrames: Int { (max(0, delayMs) + 120) * Self.sampleRate / 1000 }

    // MARK: Status / meters

    struct Status {
        var running: Bool
        var source: AudioSource
        var text: String
        var peakLdB: Double
        var peakRdB: Double
        var consumers: Int
    }

    func status() -> Status {
        lock.sync {
            decayMeters()
            return Status(running: running, source: activeSource, text: statusText,
                          peakLdB: Self.decibels(peakL), peakRdB: Self.decibels(peakR), consumers: consumers.count)
        }
    }

    private static func decibels(_ value: Float) -> Double {
        value <= 0.000_031_6 ? -90 : Double(20 * log10(value))
    }

    /// Peak meters fall at 20 dB/s. Call with the lock held.
    private func decayMeters() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = Float(now - lastMeterTime)
        lastMeterTime = now
        let factor = powf(10, -20 * elapsed / 20)
        peakL *= factor
        peakR *= factor
    }

    private func deliver(_ interleaved: UnsafePointer<Float>, frames: Int) {
        var chunkL: Float = 0
        var chunkR: Float = 0
        for i in 0..<frames {
            chunkL = max(chunkL, abs(interleaved[i * 2]))
            chunkR = max(chunkR, abs(interleaved[i * 2 + 1]))
        }
        let targets = lock.sync { () -> [AudioRingBuffer] in
            decayMeters()
            peakL = max(peakL, chunkL)
            peakR = max(peakR, chunkR)
            receivedFrames &+= UInt64(frames)
            return Array(consumers.values)
        }
        for ring in targets { ring.write(interleaved, frames: frames) }
    }

    private func setStatus(_ text: String, running: Bool) {
        lock.sync {
            statusText = text
            self.running = running
        }
    }

    // MARK: Lifecycle (main thread)

    private func startIfNeeded() {
        guard consumerCount > 0, !lock.sync({ running }) else { return }
        start()
    }

    private func stopIfUnused() {
        guard consumerCount == 0 else { return }
        stop()
    }

    private func restart() {
        let wasRunning = lock.sync { running }
        stop()
        if wasRunning || consumerCount > 0 { start() }
    }

    private func start() {
        activeSource = source
        switch source {
        case .testTone:
            startTone()
        case .website:
            startWebsiteCapture()
        }
    }

    private func stop() {
        toneRunning = false
        toneThread = nil
        if let stream {
            stream.stopCapture { _ in }
            self.stream = nil
        }
        setStatus("Off", running: false)
    }

    // MARK: Test tone

    private func startTone() {
        toneRunning = true
        setStatus("Test tone 1 kHz, −20 dBFS", running: true)
        let thread = Thread { [weak self] in self?.runTone() }
        thread.name = "bb.audio.tone"
        thread.qualityOfService = .userInteractive
        toneThread = thread
        thread.start()
    }

    private func runTone() {
        let chunk = 480 // 10 ms
        var phase = 0.0
        let step = 2 * Double.pi * 1000 / Double(Self.sampleRate)
        var buffer = [Float](repeating: 0, count: chunk * 2)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticksPerChunk = 0.010 * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)
        let start = mach_absolute_time()
        var index: UInt64 = 0
        while toneRunning {
            for i in 0..<chunk {
                let sample = Float(0.1 * sin(phase)) // 0.1 peak = −20 dBFS (AES17)
                buffer[i * 2] = sample
                buffer[i * 2 + 1] = sample
                phase += step
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            }
            buffer.withUnsafeBufferPointer { deliver($0.baseAddress!, frames: chunk) }
            index += 1
            mach_wait_until(start + UInt64(Double(index) * ticksPerChunk))
        }
    }

    // MARK: Website audio (ScreenCaptureKit app audio)

    private func startWebsiteCapture() {
        guard ScreenCapturePermission.isGranted else {
            setStatus("Website audio needs the Screen & System Audio Recording permission — sending silence.", running: true)
            return
        }
        setStatus("Starting website audio…", running: true)
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let app = content.applications.first(where: { $0.processID == getpid() }),
                      let display = content.displays.first else {
                    self.setStatus("Could not find Broadcast Browser for audio capture — sending silence.", running: true)
                    return
                }
                let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.sampleRate = Self.sampleRate
                config.channelCount = 2
                config.excludesCurrentProcessAudio = false
                config.width = 16
                config.height = 16
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.queueDepth = 3
                config.showsCursor = false
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.captureQueue)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.captureQueue)
                try await stream.startCapture()
                self.stream = stream
                self.setStatus("Website audio (48 kHz stereo)", running: true)
            } catch {
                self.setStatus("Website audio failed: \(error.localizedDescription) — sending silence.", running: true)
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return }
        let asbd = asbdPointer.pointee
        guard asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }

        let bufferList = AudioBufferList.allocate(maximumBuffers: 8)
        defer { free(bufferList.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 8),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return }

        var interleaved = [Float](repeating: 0, count: frames * 2)
        let channels = Int(asbd.mChannelsPerFrame)
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        if nonInterleaved {
            guard let left = bufferList[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let right = (bufferList.count > 1 ? bufferList[1].mData?.assumingMemoryBound(to: Float.self) : nil) ?? left
            for i in 0..<frames {
                interleaved[i * 2] = left[i]
                interleaved[i * 2 + 1] = right[i]
            }
        } else {
            guard let data = bufferList[0].mData?.assumingMemoryBound(to: Float.self), channels > 0 else { return }
            for i in 0..<frames {
                interleaved[i * 2] = data[i * channels]
                interleaved[i * 2 + 1] = data[i * channels + (channels > 1 ? 1 : 0)]
            }
        }
        interleaved.withUnsafeBufferPointer { deliver($0.baseAddress!, frames: frames) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        setStatus("Website audio stopped: \(error.localizedDescription)", running: true)
    }
}

/// Reads audio for one output in step with its video frames.
final class OutputAudioTap: @unchecked Sendable {
    private let ring: AudioRingBuffer
    private let rate: FrameRate
    private var scratch: [Float] = []

    init(rate: FrameRate) {
        self.rate = rate
        ring = AudioHub.shared.register()
    }

    deinit {
        AudioHub.shared.unregister(ring)
    }

    /// Interleaved stereo samples for video frame `index`.
    func samples(forFrame index: Int64) -> (start: Int64, data: [Float]) {
        let (start, count) = audioSamples(forFrame: index, rate: rate)
        return (start, read(frames: count))
    }

    func read(frames: Int) -> [Float] {
        if scratch.count < frames * 2 { scratch = [Float](repeating: 0, count: frames * 2) }
        scratch.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, frames: frames, maxLatencyFrames: AudioHub.shared.maxLatencyFrames)
        }
        return Array(scratch.prefix(frames * 2))
    }
}
