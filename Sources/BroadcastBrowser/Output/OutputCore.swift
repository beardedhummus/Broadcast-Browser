import CoreImage
import CoreVideo
import Foundation
import VideoToolbox

enum OutputStatus: Equatable {
    case idle
    case starting
    case live
    case error(String)

    var isActive: Bool {
        switch self {
        case .starting, .live: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Off"
        case .starting: return "Starting"
        case .live: return "Live"
        case .error: return "Error"
        }
    }

    var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }
}

struct OutputStatsSnapshot {
    var status: OutputStatus = .idle
    var startedAt: Date?
    var framesSent: UInt64 = 0
    var framesDropped: UInt64 = 0
    var framesLate: UInt64 = 0
    var uniqueSourceFrames: UInt64 = 0
    var measuredFPS: Double = 0
    var connections: Int = -1
    var tallyProgram = false
    var tallyPreview = false
    var bufferedFrames: Int = -1
    var detail = ""

    var uptime: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }
}

/// Thread-safe statistics written by output threads and read by the UI.
final class OutputStats: @unchecked Sendable {
    private let lock = NSLock()
    private var state = OutputStatsSnapshot()
    private var windowStart: CFAbsoluteTime = 0
    private var windowCount = 0
    private var lastSourceCounter: UInt64 = .max

    func snapshot() -> OutputStatsSnapshot { lock.sync { state } }

    func update(_ body: (inout OutputStatsSnapshot) -> Void) {
        lock.sync { body(&state) }
    }

    func recordFrame(sourceCounter: UInt64?) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.sync {
            state.framesSent &+= 1
            if let sourceCounter, sourceCounter != lastSourceCounter {
                state.uniqueSourceFrames &+= 1
                lastSourceCounter = sourceCounter
            }
            if windowStart == 0 { windowStart = now }
            windowCount += 1
            let elapsed = now - windowStart
            if elapsed >= 1 {
                state.measuredFPS = Double(windowCount) / elapsed
                windowStart = now
                windowCount = 0
            }
        }
    }

    func recordDropped(_ count: UInt64 = 1) {
        lock.sync { state.framesDropped &+= count }
    }
}

/// Base class of every running output.
class OutputRuntime {
    let config: OutputConfig
    let source: FrameSource
    let stats = OutputStats()
    /// Called on the main thread whenever the status changes.
    var onStatusChange: ((OutputStatus) -> Void)?

    init(config: OutputConfig, source: FrameSource) {
        self.config = config
        self.source = source
    }

    var status: OutputStatus { stats.snapshot().status }

    /// Capture rate this output needs from its tab.
    var requiredCaptureFPS: Double { config.frameRate.fps }

    func start() throws {}
    func stop() {}

    func setStatus(_ status: OutputStatus) {
        stats.update { state in
            state.status = status
            switch status {
            case .live where state.startedAt == nil:
                state.startedAt = Date()
            case .idle, .error:
                state.startedAt = nil
            default:
                break
            }
        }
        let callback = onStatusChange
        DispatchQueue.main.async { callback?(status) }
    }
}

/// Drift-free frame clock on a dedicated high-priority thread.
final class OutputClock: @unchecked Sendable {
    private let periodSeconds: Double
    private let name: String
    private let tick: (Int64) -> Void
    private let onDrop: (UInt64) -> Void
    private let lock = NSLock()
    private var running = false
    private var finished = DispatchSemaphore(value: 0)
    private var thread: Thread?

    init(frameRate: FrameRate, name: String, tick: @escaping (Int64) -> Void, onDrop: @escaping (UInt64) -> Void) {
        self.periodSeconds = Double(frameRate.denominator) / Double(frameRate.numerator)
        self.name = name
        self.tick = tick
        self.onDrop = onDrop
    }

    private var isRunning: Bool { lock.sync { running } }

    func start() {
        lock.sync { running = true }
        finished = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in self.run() }
        thread.name = "bb.clock.\(name)"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    /// Stops the clock and waits (briefly) for the in-flight tick to finish.
    func stop() {
        let wasRunning = lock.sync { () -> Bool in
            let was = running
            running = false
            return was
        }
        if wasRunning {
            _ = finished.wait(timeout: .now() + 1.0)
        }
        thread = nil
    }

    private func run() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let periodTicks = periodSeconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer)
        let start = mach_absolute_time()
        var index: Int64 = 0
        while isRunning {
            autoreleasepool { tick(index) }
            index += 1
            var target = start + UInt64(Double(index) * periodTicks)
            let now = mach_absolute_time()
            if now > target + UInt64(periodTicks) {
                // More than a frame behind: skip ahead instead of bursting.
                let behind = Int64(Double(now - target) / periodTicks)
                if behind > 0 {
                    onDrop(UInt64(behind))
                    index += behind
                    target = start + UInt64(Double(index) * periodTicks)
                }
            }
            if target > mach_absolute_time() {
                mach_wait_until(target)
            }
        }
        finished.signal()
    }
}

/// Scales / converts captured frames into an output's size and pixel format
/// using VideoToolbox (hardware accelerated on Apple silicon).
final class PixelConverter {
    let width: Int
    let height: Int
    let pixelFormat: OSType
    /// Source region in canvas pixels (top-left origin), or nil for the whole frame.
    let crop: CGRect?
    let scaling: ScalingMode
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var cropPool: CVPixelBufferPool?
    private var cachedBlack: CVPixelBuffer?
    private lazy var ciContext: CIContext = {
        let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]
        if let device = SharedMetal.device { return CIContext(mtlDevice: device, options: options) }
        return CIContext(options: options)
    }()

    var isYUV: Bool {
        pixelFormat == kCVPixelFormatType_422YpCbCr8 || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    init?(width: Int, height: Int, pixelFormat: OSType, scaling: ScalingMode, crop: CGRect? = nil) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.crop = crop
        self.scaling = scaling

        var newSession: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &newSession) == noErr,
              let newSession else { return nil }
        session = newSession

        let scalingMode: CFString
        switch scaling {
        case .fit: scalingMode = kVTScalingMode_Letterbox
        case .fill: scalingMode = kVTScalingMode_Trim
        case .stretch: scalingMode = kVTScalingMode_Normal
        }
        VTSessionSetProperty(newSession, key: kVTPixelTransferPropertyKey_ScalingMode, value: scalingMode)
        VTSessionSetProperty(newSession, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
        if isYUV {
            let matrix = height > 576 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
            VTSessionSetProperty(newSession, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: matrix)
        }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                                attributes as CFDictionary, &newPool)
        guard let newPool else { return nil }
        pool = newPool

        if crop != nil {
            // Cropping renders through Core Image into BGRA first.
            let bgraAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var intermediate: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                                    bgraAttributes as CFDictionary, &intermediate)
            cropPool = intermediate
        }
    }

    deinit {
        if let session { VTPixelTransferSessionInvalidate(session) }
    }

    private func makeBuffer() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        if let buffer { tagColor(buffer) }
        return buffer
    }

    private func tagColor(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        if isYUV {
            let matrix = height > 576 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        }
    }

    /// Crops `source` to `crop`, fits it into the output size, and returns BGRA.
    private func cropped(_ source: CVPixelBuffer, crop: CGRect) -> CVPixelBuffer? {
        let target: CVPixelBuffer?
        if pixelFormat == kCVPixelFormatType_32BGRA {
            target = makeBuffer()
        } else {
            guard let cropPool else { return nil }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, cropPool, &buffer)
            target = buffer
        }
        guard let target else { return nil }
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(source))
        var image = CIImage(cvPixelBuffer: source)
        // Core Image uses a bottom-left origin.
        let region = CGRect(x: crop.minX, y: sourceHeight - crop.maxY, width: crop.width, height: crop.height)
            .intersection(image.extent)
        guard region.width >= 1, region.height >= 1 else { return nil }
        image = image.cropped(to: region).transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
        let outWidth = CGFloat(width)
        let outHeight = CGFloat(height)
        let scaleX = outWidth / region.width
        let scaleY = outHeight / region.height
        let transform: CGAffineTransform
        switch scaling {
        case .stretch:
            transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        case .fit, .fill:
            let scale = scaling == .fit ? min(scaleX, scaleY) : max(scaleX, scaleY)
            let dx = (outWidth - region.width * scale) / 2
            let dy = (outHeight - region.height * scale) / 2
            transform = CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: dx, y: dy))
        }
        let destination = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: pixelFormat == kCVPixelFormatType_32BGRA ? 0 : 1))
            .cropped(to: destination)
        let composed = image.transformed(by: transform).cropped(to: destination).composited(over: background)
        ciContext.render(composed, to: target)
        return target
    }

    /// Converts `source`. BGRA sources that already match are passed through untouched.
    func convert(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        if let crop {
            guard let croppedBuffer = cropped(source, crop: crop) else { return nil }
            if pixelFormat == kCVPixelFormatType_32BGRA { return croppedBuffer }
            guard let session, let destination = makeBuffer() else { return nil }
            return VTPixelTransferSessionTransferImage(session, from: croppedBuffer, to: destination) == noErr ? destination : nil
        }
        if pixelFormat == kCVPixelFormatType_32BGRA,
           CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
           CVPixelBufferGetWidth(source) == width,
           CVPixelBufferGetHeight(source) == height {
            return source
        }
        guard let session, let destination = makeBuffer() else { return nil }
        let status = VTPixelTransferSessionTransferImage(session, from: source, to: destination)
        return status == noErr ? destination : nil
    }

    /// A black (transparent for BGRA) frame used before the first capture arrives.
    var blackFrame: CVPixelBuffer? {
        if let cachedBlack { return cachedBlack }
        guard let buffer = makeBuffer() else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if pixelFormat == kCVPixelFormatType_422YpCbCr8, let base = CVPixelBufferGetBaseAddress(buffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<height {
                let line = base.advanced(by: row * rowBytes).assumingMemoryBound(to: UInt32.self)
                // Cb=128 Y=16 Cr=128 Y=16, little-endian
                for x in 0..<(width / 2) { line[x] = 0x1080_1080 }
            }
        } else if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                memset(luma, 16, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0))
            }
            if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
                memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
            }
        } else if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        cachedBlack = buffer
        return buffer
    }

    /// Latest source frame converted, or black when nothing has been captured yet.
    func frame(from source: FrameSource) -> (buffer: CVPixelBuffer, counter: UInt64?)? {
        if let latest = source.latest(), let converted = convert(latest.buffer) {
            return (converted, latest.counter)
        }
        if let black = blackFrame { return (black, nil) }
        return nil
    }
}

enum OutputFactory {
    static func make(config: OutputConfig, source: FrameSource) -> OutputRuntime {
        switch config.kind {
        case .ndi: return NDIOutput(config: config, source: source)
        case .syphon: return SyphonOutput(config: config, source: source)
        case .decklink: return DeckLinkOutputRuntime(config: config, source: source)
        case .display: return DisplayOutput(config: config, source: source)
        case .record: return RecordOutput(config: config, source: source)
        }
    }
}

struct OutputStartError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
