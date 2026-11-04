import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import WebKit

enum CaptureError: LocalizedError {
    case windowNotFound
    case permissionDenied
    case noFrames

    var errorDescription: String? {
        switch self {
        case .windowNotFound: return "The tab's canvas window could not be found for capture."
        case .permissionDenied: return "Screen Recording permission has not been granted."
        case .noFrames: return "ScreenCaptureKit delivered no picture for the canvas window."
        }
    }
}

/// Captures a tab's canvas into its FrameSource.
@MainActor
protocol FrameCapturer: AnyObject {
    var engineName: String { get }
    func start(completion: @escaping (Error?) -> Void)
    func stop()
    func update(fps: Double, size: PixelSize, transparent: Bool)
}

enum ScreenCapturePermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time. Returns the current state.
    @discardableResult
    static func request() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// GPU capture of the tab's dedicated canvas window via ScreenCaptureKit.
/// Only that window is captured, so overlays (element picker highlights,
/// safe-area guides) and other windows never reach the outputs.
@MainActor
final class SCKCapturer: NSObject, FrameCapturer, SCStreamOutput, SCStreamDelegate {
    let engineName = "ScreenCaptureKit"
    private let windowID: CGWindowID
    private let source: FrameSource
    private var stream: SCStream?
    private var fps: Double
    private var size: PixelSize
    private var transparent: Bool
    private let queue = DispatchQueue(label: "bb.capture.sck", qos: .userInteractive)
    private let frameCounter = FrameCounter()
    var onStop: ((Error) -> Void)?

    /// Counts complete frames delivered by ScreenCaptureKit (watchdog).
    final class FrameCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.sync { count += 1 } }
        var value: Int { lock.sync { count } }
    }

    init(windowID: CGWindowID, source: FrameSource, fps: Double, size: PixelSize, transparent: Bool) {
        self.windowID = windowID
        self.source = source
        self.fps = fps
        self.size = size
        self.transparent = transparent
    }

    func start(completion: @escaping (Error?) -> Void) {
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw CaptureError.windowNotFound
                }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let stream = SCStream(filter: filter, configuration: makeConfiguration(), delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                self.stream = stream
                completion(nil)
                // Watchdog: if no picture arrives, report it so the tab can fall back.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.stream === stream && self.frameCounter.value == 0 {
                    self.stop()
                    self.onStop?(CaptureError.noFrames)
                }
            } catch {
                completion(error)
            }
        }
    }

    private func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        let rate = Int32(max(1, min(120, fps.rounded(.up))))
        config.minimumFrameInterval = CMTime(value: 1, timescale: rate)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = false
        config.queueDepth = 6
        config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        // The canvas window sits almost entirely off screen: capture all of it.
        config.ignoreGlobalClipSingleWindow = true
        if #available(macOS 14.2, *) { config.includeChildWindows = false }
        config.shouldBeOpaque = !transparent
        return config
    }

    func update(fps: Double, size: PixelSize, transparent: Bool) {
        guard fps != self.fps || size != self.size || transparent != self.transparent else { return }
        self.fps = fps
        self.size = size
        self.transparent = transparent
        stream?.updateConfiguration(makeConfiguration()) { error in
            if let error { NSLog("[BroadcastBrowser] SCK update failed: \(error.localizedDescription)") }
        }
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        stream?.stopCapture { _ in }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        frameCounter.increment()
        source.push(pixelBuffer)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.stream = nil
            self.onStop?(error)
        }
    }
}

/// Fallback capture using WKWebView snapshots. Needs no permission but is
/// CPU-bound and typically tops out around 25–30 fps at 1080p.
@MainActor
final class SnapshotCapturer: FrameCapturer {
    let engineName = "WebKit Snapshot"
    private weak var webView: WKWebView?
    private let source: FrameSource
    private var fps: Double
    private var size: PixelSize
    private var transparent: Bool
    private var timer: Timer?
    private var inFlight = false
    private var pool: CVPixelBufferPool?

    init(webView: WKWebView, source: FrameSource, fps: Double, size: PixelSize, transparent: Bool) {
        self.webView = webView
        self.source = source
        self.fps = fps
        self.size = size
        self.transparent = transparent
    }

    func start(completion: @escaping (Error?) -> Void) {
        rebuildPool()
        scheduleTimer()
        completion(nil)
    }

    func update(fps: Double, size: PixelSize, transparent: Bool) {
        let sizeChanged = size != self.size
        self.fps = fps
        self.size = size
        self.transparent = transparent
        if sizeChanged { rebuildPool() }
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = 1.0 / max(1, min(60, fps))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func rebuildPool() {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                                attributes as CFDictionary, &newPool)
        pool = newPool
    }

    private func tick() {
        guard !inFlight, let webView else { return }
        inFlight = true
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self else { return }
            self.inFlight = false
            guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            if let buffer = self.makeBuffer(from: cgImage) {
                self.source.push(buffer)
            }
        }
    }

    private func makeBuffer(from image: CGImage) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base,
                                      width: size.width,
                                      height: size.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        if transparent {
            context.clear(rect)
        } else {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(rect)
        }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        return buffer
    }
}
