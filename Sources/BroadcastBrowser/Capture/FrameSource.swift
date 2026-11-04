import CoreVideo
import Foundation

/// Holds the most recent captured frame of a tab. Capturers push frames in;
/// every output pulls the latest frame on its own clock, so outputs with
/// different frame rates never block each other or the capture.
final class FrameSource: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var counter: UInt64 = 0
    private var stamps: [CFAbsoluteTime] = []
    private var held = false

    /// While held (editing a live tab), new captures are ignored and outputs
    /// keep repeating the last clean frame.
    var isHeld: Bool {
        get { lock.sync { held } }
        set { lock.sync { held = newValue } }
    }

    func push(_ pixelBuffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.sync {
            if held { return }
            buffer = pixelBuffer
            counter &+= 1
            stamps.append(now)
            if stamps.count > 180 { stamps.removeFirst(stamps.count - 180) }
        }
    }

    func latest() -> (buffer: CVPixelBuffer, counter: UInt64)? {
        lock.sync {
            guard let buffer else { return nil }
            return (buffer, counter)
        }
    }

    var frameCount: UInt64 { lock.sync { counter } }

    /// New frames delivered during the last second.
    var measuredFPS: Double {
        let now = CFAbsoluteTimeGetCurrent()
        return lock.sync { Double(stamps.reduce(0) { now - $1 <= 1.0 ? $0 + 1 : $0 }) }
    }

    func reset() {
        lock.sync {
            buffer = nil
            stamps.removeAll()
        }
    }
}
