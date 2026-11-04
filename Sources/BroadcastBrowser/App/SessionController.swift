import AppKit
import Combine
import WebKit

enum SidebarPanel: String, CaseIterable, Identifiable {
    case outputs, customize, page
    var id: String { rawValue }
    var label: String {
        switch self {
        case .outputs: return "Outputs"
        case .customize: return "Customize"
        case .page: return "Page"
        }
    }
}


/// One open session: its tabs, outputs and file.
@MainActor
final class SessionController: ObservableObject {
    @Published var name: String { didSet { markDirty() } }
    @Published var fileURL: URL?
    @Published private(set) var tabs: [BrowserTab] = [] {
        didSet {
            if tabs.map(\.id) != oldValue.map(\.id) { OSCController.shared.tabsChanged(count: tabs.count) }
        }
    }
    @Published var selectedTabID: UUID?
    @Published private(set) var isDirty = false
    @Published var sidebarVisible = true {
        didSet { tabs.forEach { $0.refreshOverlayGuides() } }
    }
    @Published var sidebarPanel: SidebarPanel = .outputs {
        didSet { tabs.forEach { $0.refreshOverlayGuides() } }
    }
    /// When on, clicks and typing in the canvas view are ignored (safety while live).
    @Published var canvasInputLocked = false
    @Published var showSafeAreas = false {
        didSet { tabs.forEach { $0.host.overlayView.showSafeAreas = showSafeAreas } }
    }
    @Published private(set) var liveSince: Date?
    @Published var focusAddressBarToken = 0
    @Published var autoStartOutputs = false { didSet { markDirty() } }

    let openedAt = Date()
    weak var windowController: MainWindowController?
    var savedWindowFrame: String?
    private var activity: NSObjectProtocol?
    private var loading = false
    private var autosaveTimer: Timer?

    var selectedTab: BrowserTab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }

    var liveOutputCount: Int {
        tabs.reduce(0) { $0 + $1.runtimes.values.filter { $0.status.isActive }.count }
    }

    init(name: String) {
        self.name = name
    }

    /// Builds a session from a file. Tabs are created immediately.
    convenience init(file: SessionFile, url: URL?) {
        self.init(name: file.name)
        loading = true
        fileURL = url
        autoStartOutputs = file.autoStartOutputs
        sidebarVisible = file.sidebarVisible
        savedWindowFrame = file.windowFrame
        for state in file.tabs {
            let tab = BrowserTab(state: state, session: self)
            tabs.append(tab)
        }
        selectedTabID = file.selectedTabID.flatMap { id in tabs.contains { $0.id == id } ? id : nil } ?? tabs.first?.id
        loading = false
        isDirty = false
    }

    func startAutosave() {
        autosaveTimer?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.writeRecoveryAutosave() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autosaveTimer = timer
    }

    func markDirty() {
        guard !loading else { return }
        if !isDirty { isDirty = true }
    }

    // MARK: Tabs

    @discardableResult
    func newTab(url: String? = nil, select: Bool = true) -> BrowserTab {
        let prefs = AppModel.shared.preferences
        let defaultURL = url ?? prefs.homePage
        let state = TabState(url: defaultURL, canvas: selectedTab?.canvasSize ?? prefs.defaultCanvas,
                             hideScrollbars: prefs.hideScrollbarsByDefault)
        let tab = BrowserTab(state: state, session: self)
        tab.host.overlayView.showSafeAreas = showSafeAreas
        insert(tab, select: select)
        return tab
    }

    /// Used for target=_blank links and window.open: the new tab uses WebKit's configuration.
    func openTab(configuration: WKWebViewConfiguration, url: String) -> BrowserTab {
        let prefs = AppModel.shared.preferences
        let state = TabState(url: url, canvas: selectedTab?.canvasSize ?? prefs.defaultCanvas,
                             hideScrollbars: prefs.hideScrollbarsByDefault)
        let tab = BrowserTab(state: state, session: self, configuration: configuration)
        insert(tab, select: true)
        return tab
    }

    func duplicate(_ tab: BrowserTab) {
        var state = tab.makeState()
        state.id = UUID()
        state.outputs = state.outputs.map { config in
            var copy = config
            copy.id = UUID()
            copy.autoStart = false
            copy.name = config.name + " copy"
            return copy
        }
        let newTab = BrowserTab(state: state, session: self)
        insert(newTab, select: true, after: tab)
    }

    private func insert(_ tab: BrowserTab, select: Bool, after: BrowserTab? = nil) {
        if let after, let index = tabs.firstIndex(where: { $0 === after }) {
            tabs.insert(tab, at: index + 1)
        } else if let current = selectedTab, let index = tabs.firstIndex(where: { $0 === current }) {
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        if select { selectedTabID = tab.id }
        markDirty()
    }

    func select(_ tab: BrowserTab) {
        selectedTabID = tab.id
    }

    func selectTab(offset: Int) {
        guard let current = selectedTab, let index = tabs.firstIndex(where: { $0 === current }), !tabs.isEmpty else { return }
        let next = (index + offset + tabs.count) % tabs.count
        selectedTabID = tabs[next].id
    }

    func moveTab(_ tab: BrowserTab, by offset: Int) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let target = max(0, min(tabs.count - 1, index + offset))
        guard target != index else { return }
        tabs.remove(at: index)
        tabs.insert(tab, at: target)
        markDirty()
    }

    func closeTab(_ tab: BrowserTab, force: Bool = false) {
        if !force, tab.isLive, AppModel.shared.preferences.confirmCloseWhileLive {
            let alert = NSAlert()
            alert.messageText = "\"\(tab.displayName)\" is live"
            alert.informativeText = "Closing the tab stops its outputs."
            alert.addButton(withTitle: "Stop & Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        let wasSelected = selectedTab === tab
        tab.teardown()
        tabs.remove(at: index)
        if wasSelected {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        if tabs.isEmpty { newTab() }
        markDirty()
        liveStateChanged()
    }

    // MARK: Broadcast

    func goLiveAll() {
        for tab in tabs { tab.goLive() }
    }

    func stopAll() {
        for tab in tabs { tab.stopAllOutputs() }
    }

    func liveStateChanged() {
        let anyLive = tabs.contains { $0.isLive }
        if anyLive && liveSince == nil {
            liveSince = Date()
        } else if !anyLive {
            liveSince = nil
        }
        if anyLive && activity == nil && AppModel.shared.preferences.preventSleepWhileLive {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled, .latencyCritical],
                reason: "Broadcasting browser tabs")
        } else if !anyLive, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        objectWillChange.send()
    }

    // MARK: Saving

    func makeFile() -> SessionFile {
        var file = SessionFile(name: name, tabs: tabs.map { $0.makeState() })
        file.selectedTabID = selectedTab?.id
        file.autoStartOutputs = autoStartOutputs
        file.sidebarVisible = sidebarVisible
        if let frame = windowController?.window?.frame {
            file.windowFrame = NSStringFromRect(frame)
        }
        return file
    }

    @discardableResult
    func save() -> Bool {
        guard let fileURL else { return saveAs() }
        return write(to: fileURL)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.title = "Save Session"
        panel.allowedContentTypes = [.json]
        panel.directoryURL = fileURL?.deletingLastPathComponent() ?? AppPaths.defaultSessionsDirectory
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? name) + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        if name == "Untitled Session" {
            loading = true
            name = url.deletingPathExtension().lastPathComponent
            loading = false
        }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        let file = makeFile()
        do {
            try JSONFile.save(file, to: url)
            fileURL = url
            isDirty = false
            AppModel.shared.recents.note(url: url, file: file)
            AppModel.shared.preferences.lastSessionPath = url.path
            try? FileManager.default.removeItem(at: AppPaths.autosaveURL)
            return true
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not save the session"
            alert.runModal()
            return false
        }
    }

    func writeRecoveryAutosave() {
        guard isDirty, AppModel.shared.preferences.autosaveRecovery else { return }
        try? JSONFile.save(makeFile(), to: AppPaths.autosaveURL)
    }

    /// Asks to save unsaved changes / stop live outputs. Returns false to cancel.
    func confirmClose() -> Bool {
        if tabs.contains(where: { $0.isLive }) && AppModel.shared.preferences.confirmCloseWhileLive {
            let alert = NSAlert()
            alert.messageText = "This session is on air"
            alert.informativeText = "Closing the session stops all outputs."
            alert.addButton(withTitle: "Stop & Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        if isDirty {
            let alert = NSAlert()
            alert.messageText = "Save changes to \"\(name)\"?"
            alert.informativeText = "Your tabs, outputs and site customizations will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Don't Save")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return save()
            case .alertSecondButtonReturn:
                return true
            default:
                return false
            }
        }
        return true
    }

    func close() {
        autosaveTimer?.invalidate()
        autosaveTimer = nil
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        liveSince = nil
        try? FileManager.default.removeItem(at: AppPaths.autosaveURL)
    }
}
