import Foundation

enum CaptureEngine: String, Codable, CaseIterable, Identifiable {
    case screenCaptureKit, snapshot
    var id: String { rawValue }
    var label: String {
        switch self {
        case .screenCaptureKit: return "ScreenCaptureKit (GPU, up to 60 fps)"
        case .snapshot: return "WebKit Snapshot (no permission, ~30 fps)"
        }
    }
}

/// What happens to a tab's outputs when you enter Edit Mode while it is live.
enum LiveEditBehavior: String, Codable, CaseIterable, Identifiable {
    case holdOutputs, editOnAir
    var id: String { rawValue }
    var label: String {
        switch self {
        case .holdOutputs: return "Hold outputs on the last frame until editing ends (safest)"
        case .editOnAir: return "Keep outputs live; Web Inspector disabled while on air"
        }
    }
}

enum AudioSource: String, Codable, CaseIterable, Identifiable {
    case website, testTone
    var id: String { rawValue }
    var label: String {
        switch self {
        case .website: return "Website audio (all unmuted tabs)"
        case .testTone: return "Test tone (1 kHz, −20 dBFS)"
        }
    }
}

/// How OSC feedback encodes true/false values.
enum OSCBooleanStyle: String, Codable, CaseIterable, Identifiable {
    case oscBool, integer, string
    var id: String { rawValue }
    var label: String {
        switch self {
        case .oscBool: return "OSC true/false (type tags T/F)"
        case .integer: return "Integer 1/0"
        case .string: return "String \"true\"/\"false\""
        }
    }
}

enum LaunchBehavior: String, Codable, CaseIterable, Identifiable {
    case startPage, lastSession
    var id: String { rawValue }
    var label: String {
        switch self {
        case .startPage: return "Show the start page"
        case .lastSession: return "Reopen the last session"
        }
    }
}

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case google, duckDuckGo, bing
    var id: String { rawValue }
    var label: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        }
    }
    func url(for query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .google: return URL(string: "https://www.google.com/search?q=\(q)")
        case .duckDuckGo: return URL(string: "https://duckduckgo.com/?q=\(q)")
        case .bing: return URL(string: "https://www.bing.com/search?q=\(q)")
        }
    }
}

/// App-wide preferences, saved to ~/Library/Application Support/Broadcast Browser/preferences.json.
struct AppPreferences: Codable, Equatable {
    // General
    var homePage = "https://www.google.com"
    var searchEngine: SearchEngine = .google
    var launchBehavior: LaunchBehavior = .startPage
    var showBookmarksBar = true
    var confirmCloseWhileLive = true
    var autosaveRecovery = true

    // Video
    var enablePALFormats = false
    var defaultCanvasWidth = 1920
    var defaultCanvasHeight = 1080
    var defaultFrameRate: FrameRate = .fps59_94
    var defaultScaling: ScalingMode = .fit
    var hideScrollbarsByDefault = true

    // Outputs
    var ndiLibraryPath = ""
    var ndiDefaultGroups = ""
    var syphonFrameworkPath = ""
    var recordingsFolder = AppPaths.defaultRecordingsDirectory.path
    var defaultRecordCodec: RecordCodec = .h264
    var defaultRecordBitrateMbps: Double = 16

    // Capture / advanced
    var captureEngine: CaptureEngine = .screenCaptureKit
    var preventSleepWhileLive = true
    var lastSessionPath = ""
    var liveEditBehavior: LiveEditBehavior = .holdOutputs

    // Audio
    var audioSource: AudioSource = .website
    var audioDelayMs = 0
    var muteTabsNotLive = false

    // OSC
    var oscEnabled = true
    var oscInputPort = 9300
    var oscAllowedSenders = ""
    var oscAllowScripting = false
    var oscFeedbackEnabled = true
    var oscFeedbackHost = "127.0.0.1"
    var oscFeedbackPort = 9301
    var oscFeedbackIntervalMs = 1000
    var oscBooleanStyle: OSCBooleanStyle = .oscBool
    var oscUseBundles = false

    var defaultCanvas: PixelSize {
        get { PixelSize(defaultCanvasWidth, defaultCanvasHeight) }
        set {
            defaultCanvasWidth = newValue.width
            defaultCanvasHeight = newValue.height
        }
    }

    init() {}

    enum CodingKeys: String, CodingKey {
        case homePage, searchEngine, launchBehavior, showBookmarksBar, confirmCloseWhileLive, autosaveRecovery
        case enablePALFormats, defaultCanvasWidth, defaultCanvasHeight, defaultFrameRate, defaultScaling, hideScrollbarsByDefault
        case ndiLibraryPath, ndiDefaultGroups, syphonFrameworkPath, recordingsFolder, defaultRecordCodec, defaultRecordBitrateMbps
        case captureEngine, preventSleepWhileLive, lastSessionPath, liveEditBehavior
        case audioSource, audioDelayMs, muteTabsNotLive
        case oscEnabled, oscInputPort, oscAllowedSenders, oscAllowScripting, oscFeedbackEnabled
        case oscFeedbackHost, oscFeedbackPort, oscFeedbackIntervalMs, oscBooleanStyle, oscUseBundles
    }

    init(from decoder: Decoder) throws {
        let d = AppPreferences()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        homePage = c.value(.homePage, default: d.homePage)
        searchEngine = c.value(.searchEngine, default: d.searchEngine)
        launchBehavior = c.value(.launchBehavior, default: d.launchBehavior)
        showBookmarksBar = c.value(.showBookmarksBar, default: d.showBookmarksBar)
        confirmCloseWhileLive = c.value(.confirmCloseWhileLive, default: d.confirmCloseWhileLive)
        autosaveRecovery = c.value(.autosaveRecovery, default: d.autosaveRecovery)
        enablePALFormats = c.value(.enablePALFormats, default: d.enablePALFormats)
        defaultCanvasWidth = c.value(.defaultCanvasWidth, default: d.defaultCanvasWidth)
        defaultCanvasHeight = c.value(.defaultCanvasHeight, default: d.defaultCanvasHeight)
        defaultFrameRate = c.value(.defaultFrameRate, default: d.defaultFrameRate)
        defaultScaling = c.value(.defaultScaling, default: d.defaultScaling)
        hideScrollbarsByDefault = c.value(.hideScrollbarsByDefault, default: d.hideScrollbarsByDefault)
        ndiLibraryPath = c.value(.ndiLibraryPath, default: d.ndiLibraryPath)
        ndiDefaultGroups = c.value(.ndiDefaultGroups, default: d.ndiDefaultGroups)
        syphonFrameworkPath = c.value(.syphonFrameworkPath, default: d.syphonFrameworkPath)
        recordingsFolder = c.value(.recordingsFolder, default: d.recordingsFolder)
        defaultRecordCodec = c.value(.defaultRecordCodec, default: d.defaultRecordCodec)
        defaultRecordBitrateMbps = c.value(.defaultRecordBitrateMbps, default: d.defaultRecordBitrateMbps)
        captureEngine = c.value(.captureEngine, default: d.captureEngine)
        preventSleepWhileLive = c.value(.preventSleepWhileLive, default: d.preventSleepWhileLive)
        lastSessionPath = c.value(.lastSessionPath, default: d.lastSessionPath)
        liveEditBehavior = c.value(.liveEditBehavior, default: d.liveEditBehavior)
        audioSource = c.value(.audioSource, default: d.audioSource)
        audioDelayMs = c.value(.audioDelayMs, default: d.audioDelayMs)
        muteTabsNotLive = c.value(.muteTabsNotLive, default: d.muteTabsNotLive)
        oscEnabled = c.value(.oscEnabled, default: d.oscEnabled)
        oscInputPort = c.value(.oscInputPort, default: d.oscInputPort)
        oscAllowedSenders = c.value(.oscAllowedSenders, default: d.oscAllowedSenders)
        oscAllowScripting = c.value(.oscAllowScripting, default: d.oscAllowScripting)
        oscFeedbackEnabled = c.value(.oscFeedbackEnabled, default: d.oscFeedbackEnabled)
        oscFeedbackHost = c.value(.oscFeedbackHost, default: d.oscFeedbackHost)
        oscFeedbackPort = c.value(.oscFeedbackPort, default: d.oscFeedbackPort)
        oscFeedbackIntervalMs = c.value(.oscFeedbackIntervalMs, default: d.oscFeedbackIntervalMs)
        oscBooleanStyle = c.value(.oscBooleanStyle, default: d.oscBooleanStyle)
        oscUseBundles = c.value(.oscUseBundles, default: d.oscUseBundles)
    }
}

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var url: String
    var addedAt = Date()

    init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

@MainActor
final class BookmarkStore: ObservableObject {
    @Published var bookmarks: [Bookmark] = [] {
        didSet { save() }
    }

    private var loading = false

    init() {
        loading = true
        bookmarks = (try? JSONFile.load([Bookmark].self, from: AppPaths.bookmarksURL)) ?? BookmarkStore.defaults
        loading = false
    }

    static let defaults: [Bookmark] = [
        Bookmark(title: "Google", url: "https://www.google.com"),
        Bookmark(title: "YouTube", url: "https://www.youtube.com"),
        Bookmark(title: "Weather", url: "https://weather.com"),
        Bookmark(title: "Time.is", url: "https://time.is"),
    ]

    func contains(url: String) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    func toggle(title: String, url: String) {
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.append(Bookmark(title: title.isEmpty ? url : title, url: url))
        }
    }

    func add(title: String, url: String) {
        bookmarks.append(Bookmark(title: title.isEmpty ? url : title, url: url))
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
    }

    func importFile(_ url: URL) throws {
        let imported = try JSONFile.load([Bookmark].self, from: url)
        let existing = Set(bookmarks.map(\.url))
        bookmarks.append(contentsOf: imported.filter { !existing.contains($0.url) })
    }

    func exportFile(_ url: URL) throws {
        try JSONFile.save(bookmarks, to: url)
    }

    private func save() {
        guard !loading else { return }
        try? JSONFile.save(bookmarks, to: AppPaths.bookmarksURL)
    }
}

struct RecentSession: Codable, Identifiable, Hashable {
    var path: String
    var name: String
    var lastOpened: Date
    var tabCount: Int
    var outputCount: Int
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

@MainActor
final class RecentSessionsStore: ObservableObject {
    @Published private(set) var items: [RecentSession] = []

    init() {
        items = (try? JSONFile.load([RecentSession].self, from: AppPaths.recentsURL)) ?? []
        prune()
    }

    func note(url: URL, file: SessionFile) {
        items.removeAll { $0.path == url.path }
        items.insert(RecentSession(path: url.path,
                                   name: file.name,
                                   lastOpened: Date(),
                                   tabCount: file.tabs.count,
                                   outputCount: file.tabs.reduce(0) { $0 + $1.outputs.count }),
                     at: 0)
        if items.count > 20 { items = Array(items.prefix(20)) }
        save()
    }

    func remove(_ item: RecentSession) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func prune() {
        let before = items.count
        items.removeAll { !FileManager.default.fileExists(atPath: $0.path) }
        if items.count != before { save() }
    }

    private func save() {
        try? JSONFile.save(items, to: AppPaths.recentsURL)
    }
}
