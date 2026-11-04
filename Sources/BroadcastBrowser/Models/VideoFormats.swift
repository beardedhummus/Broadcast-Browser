import Foundation

/// Output frame rates. NTSC-family rates are always available; 25/50 (PAL)
/// appear when PAL formats are enabled in Preferences.
enum FrameRate: String, Codable, CaseIterable, Identifiable, Hashable {
    case fps23_976 = "23.976"
    case fps24 = "24"
    case fps25 = "25"
    case fps29_97 = "29.97"
    case fps30 = "30"
    case fps50 = "50"
    case fps59_94 = "59.94"
    case fps60 = "60"

    var id: String { rawValue }

    var numerator: Int32 {
        switch self {
        case .fps23_976: return 24000
        case .fps24: return 24
        case .fps25: return 25
        case .fps29_97: return 30000
        case .fps30: return 30
        case .fps50: return 50
        case .fps59_94: return 60000
        case .fps60: return 60
        }
    }

    var denominator: Int32 {
        switch self {
        case .fps23_976, .fps29_97, .fps59_94: return 1001
        default: return 1
        }
    }

    var fps: Double { Double(numerator) / Double(denominator) }

    /// Industry label (23.98, 29.97, 59.94 ...).
    var label: String {
        switch self {
        case .fps23_976: return "23.98"
        case .fps24: return "24"
        case .fps25: return "25"
        case .fps29_97: return "29.97"
        case .fps30: return "30"
        case .fps50: return "50"
        case .fps59_94: return "59.94"
        case .fps60: return "60"
        }
    }

    var isPAL: Bool { self == .fps25 || self == .fps50 }

    static func choices(includePAL: Bool, including current: FrameRate? = nil) -> [FrameRate] {
        allCases.filter { includePAL || !$0.isPAL || $0 == current }
    }

    /// Closest rate for a DeckLink timing pair.
    static func matching(frameDuration: Int64, timeScale: Int64) -> FrameRate? {
        guard frameDuration > 0 else { return nil }
        let value = Double(timeScale) / Double(frameDuration)
        return allCases.min { abs($0.fps - value) < abs($1.fps - value) }
            .flatMap { abs($0.fps - value) < 0.01 ? $0 : nil }
    }
}

struct PixelSize: Codable, Hashable {
    var width: Int
    var height: Int

    init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    var label: String { "\(width)×\(height)" }
    var aspect: Double { height == 0 ? 16.0 / 9.0 : Double(width) / Double(height) }
    var isValid: Bool { width >= 16 && height >= 16 && width <= 8192 && height <= 8192 }
}

struct ResolutionPreset: Identifiable, Hashable {
    let name: String
    let size: PixelSize
    let isPAL: Bool

    var id: String { "\(name)-\(size.label)" }
    var menuLabel: String { "\(name) — \(size.label)" }

    static let all: [ResolutionPreset] = [
        ResolutionPreset(name: "HD 1080", size: PixelSize(1920, 1080), isPAL: false),
        ResolutionPreset(name: "HD 720", size: PixelSize(1280, 720), isPAL: false),
        ResolutionPreset(name: "UHD 4K", size: PixelSize(3840, 2160), isPAL: false),
        ResolutionPreset(name: "QHD 1440", size: PixelSize(2560, 1440), isPAL: false),
        ResolutionPreset(name: "NTSC SD", size: PixelSize(720, 486), isPAL: false),
        ResolutionPreset(name: "PAL SD", size: PixelSize(720, 576), isPAL: true),
        ResolutionPreset(name: "Vertical 1080", size: PixelSize(1080, 1920), isPAL: false),
        ResolutionPreset(name: "Square", size: PixelSize(1080, 1080), isPAL: false),
    ]

    static func choices(includePAL: Bool) -> [ResolutionPreset] {
        all.filter { includePAL || !$0.isPAL }
    }
}

/// How a source frame is fitted into an output that has a different size.
enum ScalingMode: String, Codable, CaseIterable, Identifiable {
    case fit, fill, stretch
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: return "Fit (letterbox)"
        case .fill: return "Fill (crop)"
        case .stretch: return "Stretch"
        }
    }
}

func formatLabel(size: PixelSize, rate: FrameRate, interlaced: Bool) -> String {
    let lines: String
    switch (size.width, size.height) {
    case (1920, 1080): lines = "1080"
    case (1280, 720): lines = "720"
    case (3840, 2160): lines = "2160"
    case (720, 486): lines = "486"
    case (720, 576): lines = "576"
    default: return "\(size.label) · \(rate.label) fps"
    }
    if interlaced {
        // Interlaced formats are named by field rate (1080i59.94).
        let fieldRate: String
        switch rate {
        case .fps29_97: fieldRate = "59.94"
        case .fps25: fieldRate = "50"
        case .fps30: fieldRate = "60"
        default: fieldRate = rate.label
        }
        return "\(lines)i\(fieldRate)"
    }
    return "\(lines)p\(rate.label)"
}

func formatDuration(_ interval: TimeInterval) -> String {
    let total = max(0, Int(interval))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60
    if hours >= 24 {
        return String(format: "%dd %02d:%02d:%02d", hours / 24, hours % 24, minutes, seconds)
    }
    return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
}
