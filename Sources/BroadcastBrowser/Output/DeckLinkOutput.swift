import BBBridge
import CoreVideo
import Foundation

struct DeckLinkModeInfo: Identifiable, Hashable {
    let modeID: UInt32
    let name: String
    let size: PixelSize
    let frameRate: FrameRate?
    let interlaced: Bool

    var id: UInt32 { modeID }
    var label: String {
        guard let frameRate else { return name }
        return formatLabel(size: size, rate: frameRate, interlaced: interlaced)
    }
}

struct DeckLinkDeviceInfo: Identifiable, Hashable {
    let index: Int
    let name: String
    let model: String
    let persistentID: Int64
    let supportsPlayback: Bool
    let modes: [DeckLinkModeInfo]

    var id: String { persistentID != 0 ? String(persistentID) : "\(index)-\(name)" }

    func matches(_ config: OutputConfig) -> Bool {
        if config.deckLinkPersistentID != 0 { return persistentID == config.deckLinkPersistentID }
        return name == config.deckLinkDeviceName
    }

    func mode(for config: OutputConfig) -> DeckLinkModeInfo? {
        modes.first {
            $0.size == config.size && $0.frameRate == config.frameRate && $0.interlaced == config.interlaced
        }
    }
}

enum DeckLinkRuntime {
    static var isCompiledIn: Bool { BBDeckLinkOutput.isSDKCompiledIn() }
    static var driverVersion: String? { BBDeckLinkOutput.driverVersion() }

    static func devices() -> (devices: [DeckLinkDeviceInfo], error: String?) {
        do {
            let list = try BBDeckLinkOutput.devices()
            let devices = list.map { device in
                DeckLinkDeviceInfo(
                    index: device.index,
                    name: device.displayName,
                    model: device.modelName,
                    persistentID: device.persistentID,
                    supportsPlayback: device.supportsPlayback,
                    modes: device.displayModes.map { mode in
                        DeckLinkModeInfo(modeID: mode.modeID,
                                         name: mode.name,
                                         size: PixelSize(Int(mode.width), Int(mode.height)),
                                         frameRate: FrameRate.matching(frameDuration: mode.frameDuration, timeScale: mode.timeScale),
                                         interlaced: mode.interlaced)
                    }
                )
            }
            return (devices, nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }
}

/// Keeps one output per DeckLink (sub)device across all tabs.
final class DeckLinkRegistry: @unchecked Sendable {
    static let shared = DeckLinkRegistry()
    private let lock = NSLock()
    private var claimed: [String: UUID] = [:]

    func claim(_ deviceKey: String, by output: UUID) -> Bool {
        lock.sync {
            if let owner = claimed[deviceKey], owner != output { return false }
            claimed[deviceKey] = output
            return true
        }
    }

    func release(_ deviceKey: String, by output: UUID) {
        lock.sync {
            if claimed[deviceKey] == output { claimed[deviceKey] = nil }
        }
    }
}

/// Hardware-clocked SDI/HDMI playback through a Blackmagic DeckLink or
/// UltraStudio device (8-bit 4:2:2 YUV).
final class DeckLinkOutputRuntime: OutputRuntime, @unchecked Sendable {
    private var device: BBDeckLinkOutput?
    private var converter: PixelConverter?
    private var deviceKey = ""
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "bb.decklink.poll", qos: .utility)
    private let lock = NSLock()
    private var audioTap: OutputAudioTap?

    override func start() throws {
        setStatus(.starting)
        guard DeckLinkRuntime.isCompiledIn else {
            throw OutputStartError("This build does not include DeckLink support. Add the Blackmagic Desktop Video SDK to ThirdParty/DeckLinkSDK and rebuild.")
        }
        let (devices, error) = DeckLinkRuntime.devices()
        if let error, devices.isEmpty { throw OutputStartError(error) }
        guard let info = devices.first(where: { $0.matches(config) }) else {
            throw OutputStartError("DeckLink device \"\(config.deckLinkDeviceName)\" is not connected.")
        }
        guard let mode = info.mode(for: config) else {
            throw OutputStartError("\(info.name) does not support \(config.formatSummary).")
        }
        deviceKey = info.id
        guard DeckLinkRegistry.shared.claim(deviceKey, by: config.id) else {
            throw OutputStartError("\(info.name) is already used by another output.")
        }

        do {
            let output = try BBDeckLinkOutput(deviceIndex: info.index)
            guard let converter = PixelConverter(width: mode.size.width, height: mode.size.height,
                                                 pixelFormat: kCVPixelFormatType_422YpCbCr8, scaling: config.scaling, crop: config.cropRect) else {
                throw OutputStartError("Could not create the DeckLink frame converter.")
            }
            self.converter = converter
            self.device = output
            let audioChannels: UInt32 = config.audioEnabled ? 2 : 0
            if config.audioEnabled { audioTap = OutputAudioTap(rate: config.frameRate) }
            try output.start(withModeID: mode.modeID, yuv: true, audioChannels: audioChannels, filler: { [weak self] bytes, rowBytes, width, height in
                self?.fill(bytes: bytes, rowBytes: rowBytes, width: Int(width), height: Int(height)) ?? false
            }, audioFiller: { [weak self] samples, frames, channels in
                self?.fillAudio(samples, frames: Int(frames), channels: Int(channels))
            })
        } catch {
            DeckLinkRegistry.shared.release(deviceKey, by: config.id)
            device = nil
            converter = nil
            throw error
        }

        stats.update { $0.detail = "\(info.name) · \(mode.label)" }
        startPolling()
        setStatus(.live)
    }

    /// Called on the DeckLink thread for every frame the hardware needs.
    private func fill(bytes: UnsafeMutableRawPointer, rowBytes: Int, width: Int, height: Int) -> Bool {
        guard let converter = lock.sync({ self.converter }),
              let frame = converter.frame(from: source) else { return false }
        let buffer = frame.buffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let copyBytes = min(rowBytes, sourceRowBytes)
        let rows = min(height, CVPixelBufferGetHeight(buffer))
        if sourceRowBytes == rowBytes {
            memcpy(bytes, base, rowBytes * rows)
        } else {
            for row in 0..<rows {
                memcpy(bytes.advanced(by: row * rowBytes), base.advanced(by: row * sourceRowBytes), copyBytes)
            }
        }
        stats.recordFrame(sourceCounter: frame.counter)
        return true
    }

    /// Converts float stereo into the card's 32-bit integer PCM.
    private func fillAudio(_ samples: UnsafeMutablePointer<Int32>, frames: Int, channels: Int) {
        guard let audioTap else {
            samples.initialize(repeating: 0, count: frames * channels)
            return
        }
        let stereo = audioTap.read(frames: frames)
        for i in 0..<frames {
            for c in 0..<channels {
                let value = c < 2 ? stereo[i * 2 + c] : 0
                let clamped = max(-1, min(1, value))
                samples[i * channels + c] = Int32(clamped * 2_147_483_647)
            }
        }
    }

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now() + 0.5, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, let device = self.lock.sync({ self.device }) else { return }
            let late = device.framesLate
            let dropped = device.framesDropped
            let buffered = device.bufferedFrames
            self.stats.update {
                $0.framesLate = late
                $0.framesDropped = dropped
                $0.bufferedFrames = Int(buffered)
            }
        }
        timer.resume()
        pollTimer = timer
    }

    override func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        pollQueue.sync {}
        let device = lock.sync { () -> BBDeckLinkOutput? in
            let d = self.device
            self.device = nil
            return d
        }
        device?.stop()
        lock.sync { converter = nil }
        audioTap = nil
        if !deviceKey.isEmpty {
            DeckLinkRegistry.shared.release(deviceKey, by: config.id)
        }
        setStatus(.idle)
    }
}
