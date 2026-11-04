import CoreGraphics
import Foundation

enum OutputKind: String, Codable, CaseIterable, Identifiable {
    case ndi, syphon, decklink, display, record

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ndi: return "NDI®"
        case .syphon: return "Syphon"
        case .decklink: return "DeckLink (SDI/HDMI)"
        case .display: return "Display (Fullscreen)"
        case .record: return "Record to File"
        }
    }

    var shortLabel: String {
        switch self {
        case .ndi: return "NDI"
        case .syphon: return "Syphon"
        case .decklink: return "DeckLink"
        case .display: return "Display"
        case .record: return "Record"
        }
    }

    var symbol: String {
        switch self {
        case .ndi: return "network"
        case .syphon: return "square.stack.3d.forward.dottedline"
        case .decklink: return "cable.connector"
        case .display: return "display"
        case .record: return "record.circle"
        }
    }

    var isIP: Bool { self == .ndi || self == .syphon }
}

enum RecordCodec: String, Codable, CaseIterable, Identifiable {
    case h264, hevc, proRes422, proRes422HQ

    var id: String { rawValue }

    var label: String {
        switch self {
        case .h264: return "H.264 (.mp4)"
        case .hevc: return "HEVC / H.265 (.mp4)"
        case .proRes422: return "Apple ProRes 422 (.mov)"
        case .proRes422HQ: return "Apple ProRes 422 HQ (.mov)"
        }
    }

    var usesBitrate: Bool { self == .h264 || self == .hevc }
    var fileExtension: String { usesBitrate ? "mp4" : "mov" }
}

/// Configuration of a single video output attached to a tab. Saved in sessions.
struct OutputConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: OutputKind
    var name: String
    /// Start this output when the tab goes live.
    var autoStart = true
    var width = 1920
    var height = 1080
    var frameRate: FrameRate = .fps59_94
    var interlaced = false
    var scaling: ScalingMode = .fit

    // NDI
    var ndiGroups = ""
    var ndiAlpha = false

    // Syphon
    var syphonFlipped = false

    // DeckLink
    var deckLinkPersistentID: Int64 = 0
    var deckLinkDeviceName = ""
    var deckLinkModeName = ""

    // Display
    var displayID: UInt32 = 0
    var displayName = ""

    // Record
    var codec: RecordCodec = .h264
    var bitrateMbps: Double = 16
    var keyframeIntervalSeconds: Double = 2
    var recordFolder = ""

    // Crop (canvas pixels, top-left origin). Applied before scaling.
    var cropEnabled = false
    var cropX = 0
    var cropY = 0
    var cropWidth = 1920
    var cropHeight = 1080

    // Audio (NDI, DeckLink, Record)
    var audioEnabled = false
    var audioBitrateKbps = 192

    var cropRect: CGRect? {
        guard cropEnabled, cropWidth >= 16, cropHeight >= 16 else { return nil }
        return CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)
    }

    var supportsAudio: Bool { kind == .ndi || kind == .decklink || kind == .record }

    var size: PixelSize {
        get { PixelSize(width, height) }
        set {
            width = newValue.width
            height = newValue.height
        }
    }

    var formatSummary: String {
        switch kind {
        case .display:
            return displayName.isEmpty ? "No display selected" : displayName
        default:
            return formatLabel(size: size, rate: frameRate, interlaced: interlaced)
        }
    }

    /// Uncompressed payload bandwidth before NDI compression (for reference).
    var rawBandwidthMbps: Double {
        let bytesPerPixel = (kind == .ndi && ndiAlpha) ? 4.0 : 2.0
        return Double(width * height) * bytesPerPixel * frameRate.fps * 8 / 1_000_000
    }

    /// Rough NDI (SpeedHQ) network bandwidth estimate.
    var estimatedNDIMbps: Double {
        // NewTek's published figures: ~125 Mbps for 1080p59.94, scale by pixel rate.
        let pixelRate = Double(width * height) * frameRate.fps
        let base = 125.0 * pixelRate / (1920.0 * 1080.0 * 59.94)
        return ndiAlpha ? base * 1.5 : base
    }

    init(kind: OutputKind, name: String) {
        self.kind = kind
        self.name = name
    }

    static func makeDefault(kind: OutputKind, tabName: String, preferences: AppPreferences) -> OutputConfig {
        var config = OutputConfig(kind: kind, name: tabName)
        config.size = preferences.defaultCanvas
        config.frameRate = preferences.defaultFrameRate
        config.scaling = preferences.defaultScaling
        switch kind {
        case .ndi:
            config.ndiGroups = preferences.ndiDefaultGroups
        case .record:
            config.recordFolder = preferences.recordingsFolder
            config.codec = preferences.defaultRecordCodec
            config.bitrateMbps = preferences.defaultRecordBitrateMbps
        case .decklink:
            config.name = "DeckLink"
        case .display:
            config.name = "Display"
        case .syphon:
            break
        }
        return config
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, autoStart, width, height, frameRate, interlaced, scaling
        case ndiGroups, ndiAlpha, syphonFlipped
        case deckLinkPersistentID, deckLinkDeviceName, deckLinkModeName
        case displayID, displayName
        case codec, bitrateMbps, keyframeIntervalSeconds, recordFolder
        case cropEnabled, cropX, cropY, cropWidth, cropHeight
        case audioEnabled, audioBitrateKbps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        kind = try c.decode(OutputKind.self, forKey: .kind)
        name = c.value(.name, default: kind.shortLabel)
        autoStart = c.value(.autoStart, default: true)
        width = c.value(.width, default: 1920)
        height = c.value(.height, default: 1080)
        frameRate = c.value(.frameRate, default: .fps59_94)
        interlaced = c.value(.interlaced, default: false)
        scaling = c.value(.scaling, default: .fit)
        ndiGroups = c.value(.ndiGroups, default: "")
        ndiAlpha = c.value(.ndiAlpha, default: false)
        syphonFlipped = c.value(.syphonFlipped, default: false)
        deckLinkPersistentID = c.value(.deckLinkPersistentID, default: 0)
        deckLinkDeviceName = c.value(.deckLinkDeviceName, default: "")
        deckLinkModeName = c.value(.deckLinkModeName, default: "")
        displayID = c.value(.displayID, default: 0)
        displayName = c.value(.displayName, default: "")
        codec = c.value(.codec, default: .h264)
        bitrateMbps = c.value(.bitrateMbps, default: 16)
        keyframeIntervalSeconds = c.value(.keyframeIntervalSeconds, default: 2)
        recordFolder = c.value(.recordFolder, default: "")
        cropEnabled = c.value(.cropEnabled, default: false)
        cropX = c.value(.cropX, default: 0)
        cropY = c.value(.cropY, default: 0)
        cropWidth = c.value(.cropWidth, default: width)
        cropHeight = c.value(.cropHeight, default: height)
        audioEnabled = c.value(.audioEnabled, default: false)
        audioBitrateKbps = c.value(.audioBitrateKbps, default: 192)
    }
}
