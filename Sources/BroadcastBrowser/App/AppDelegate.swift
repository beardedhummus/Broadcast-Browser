import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private(set) var startWindow: NSWindow?
    private(set) var mainController: MainWindowController?
    private(set) var dashboardWindow: NSWindow?
    private(set) var preferencesWindow: NSWindow?
    private var bookmarksWindow: NSWindow?
    private let bookmarksMenu = NSMenu(title: "Bookmarks")
    private let recentMenu = NSMenu(title: "Open Recent")
    private var showStartAfterClose = true

    var app: AppModel { AppModel.shared }
    var session: SessionController? { mainController?.session }
    var tab: BrowserTab? { session?.selectedTab }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        buildMenus()
        app.monitor.start()
        app.applyAudioPreferences()
        if !SelfTest.isEnabled { OSCController.shared.apply() }
        app.devices.refreshScreens()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.app.devices.refreshAll(preferences: self.app.preferences)
        }

        if SelfTest.isEnabled {
            SelfTest.run(delegate: self)
            return
        }

        let prefs = app.preferences
        if prefs.launchBehavior == .lastSession, !prefs.lastSessionPath.isEmpty,
           FileManager.default.fileExists(atPath: prefs.lastSessionPath) {
            openSession(at: URL(fileURLWithPath: prefs.lastSessionPath))
        } else {
            showStartWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let mainController {
                mainController.showWindow(nil)
            } else {
                showStartWindow()
            }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        guard session.confirmClose() else { return .terminateCancel }
        session.close()
        return .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first(where: { $0.pathExtension.lowercased() == "json" }) {
            openSession(at: url)
        }
    }

    // MARK: Windows

    func showStartWindow() {
        if startWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 540),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.title = "Welcome to Broadcast Browser"
            let view = StartView(
                onNewSession: { [weak self] in self?.newSession() },
                onOpenSession: { [weak self] in self?.openSessionPanel() },
                onOpenRecent: { [weak self] url in self?.openSession(at: url) },
                onRecover: { [weak self] in self?.recoverAutosave() },
                onPreferences: { [weak self] in self?.showPreferences() }
            )
            .environmentObject(app)
            window.contentView = NSHostingView(rootView: view)
            window.center()
            startWindow = window
        }
        app.recents.prune()
        startWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showDashboard() {
        if dashboardWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Dashboard"
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 760, height: 520)
            window.contentView = NSHostingView(rootView: DashboardView().environmentObject(app))
            window.center()
            window.setFrameAutosaveName("BBDashboard")
            dashboardWindow = window
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showPreferences() {
        if preferencesWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "Preferences"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = NSHostingView(rootView: PreferencesView().environmentObject(app))
            window.center()
            preferencesWindow = window
        }
        app.devices.refreshAll(preferences: app.preferences)
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showBookmarksManager() {
        if bookmarksWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                                  styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "Bookmarks"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BookmarksManagerView(store: app.bookmarks, onOpen: { [weak self] url in
                self?.open(bookmarkURL: url, newTab: true)
            }))
            window.center()
            bookmarksWindow = window
        }
        bookmarksWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Sessions

    @objc func newSession() {
        guard closeCurrentSession(showStart: false) else { return }
        let session = SessionController(name: "Untitled Session")
        session.newTab()
        present(session)
    }

    @objc func openSessionPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open Session"
        panel.allowedContentTypes = [.json]
        panel.directoryURL = AppPaths.defaultSessionsDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openSession(at: url)
    }

    func openSession(at url: URL) {
        do {
            let file = try JSONFile.load(SessionFile.self, from: url)
            guard closeCurrentSession(showStart: false) else { return }
            let session = SessionController(file: file, url: url)
            app.recents.note(url: url, file: file)
            app.preferences.lastSessionPath = url.path
            present(session)
            if file.autoStartOutputs {
                session.tabs.forEach { $0.goLiveWhenLoaded() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not open \(url.lastPathComponent)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func recoverAutosave() {
        guard let file = try? JSONFile.load(SessionFile.self, from: AppPaths.autosaveURL) else { return }
        guard closeCurrentSession(showStart: false) else { return }
        let session = SessionController(file: file, url: nil)
        session.markDirty()
        present(session)
    }

    func present(_ session: SessionController) {
        app.session = session
        let controller = MainWindowController(session: session)
        controller.onClose = { [weak self] in self?.sessionDidClose() }
        mainController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        startWindow?.orderOut(nil)
        session.startAutosave()
    }

    /// Closes the open session after confirming. Returns false if cancelled.
    @discardableResult
    func closeCurrentSession(showStart: Bool) -> Bool {
        guard let controller = mainController else { return true }
        guard controller.session.confirmClose() else { return false }
        showStartAfterClose = showStart
        controller.window?.close()
        showStartAfterClose = true
        return true
    }

    private func sessionDidClose() {
        app.session = nil
        mainController = nil
        if showStartAfterClose { showStartWindow() }
    }

    @objc func closeSession() {
        closeCurrentSession(showStart: true)
    }

    @objc func saveSession() { session?.save() }
    @objc func saveSessionAs() { session?.saveAs() }

    @objc func toggleAutoStart() {
        session?.autoStartOutputs.toggle()
    }

    // MARK: Tabs & navigation

    @objc func newTab() {
        guard let session else {
            newSession()
            return
        }
        session.newTab()
        focusAddressBar()
    }

    /// ⌘W closes the frontmost utility window (Preferences, Dashboard…) if one
    /// is key; otherwise it closes the selected browser tab.
    @objc func closeTab() {
        if let key = NSApp.keyWindow, key !== mainController?.window, !(key is RenderWindow) {
            key.performClose(nil)
            return
        }
        guard let session, let tab else { return }
        session.closeTab(tab)
    }

    @objc func duplicateTab() {
        guard let session, let tab else { return }
        session.duplicate(tab)
    }

    @objc func focusAddressBar() {
        guard let session else { return }
        mainController?.window?.makeKey()
        session.focusAddressBarToken += 1
    }

    @objc func nextTab() { session?.selectTab(offset: 1) }
    @objc func previousTab() { session?.selectTab(offset: -1) }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        guard let session, !session.tabs.isEmpty else { return }
        let index = sender.tag == 9 ? session.tabs.count - 1 : min(sender.tag - 1, session.tabs.count - 1)
        session.select(session.tabs[index])
    }

    @objc func reload() { tab?.reload() }
    @objc func goBack() { tab?.webView.goBack() }
    @objc func goForward() { tab?.webView.goForward() }
    @objc func goHome() { tab?.goHome() }
    @objc func zoomIn() { tab?.zoomIn() }
    @objc func zoomOut() { tab?.zoomOut() }
    @objc func actualSize() { tab?.resetZoom() }

    @objc func toggleInputLock() { session?.canvasInputLocked.toggle() }
    @objc func toggleSafeAreas() { session?.showSafeAreas.toggle() }
    @objc func toggleSidebar() { session?.sidebarVisible.toggle() }
    @objc func toggleBookmarksBar() { app.preferences.showBookmarksBar.toggle() }

    @objc func pickElement() { tab?.togglePicking() }
    @objc func toggleEditMode() { tab?.toggleEditMode() }
    @objc func openOSCReference() { OSCReference.open() }
    @objc func openWebInspector() { tab?.openWebInspector() }

    @objc func showCustomize() {
        session?.sidebarVisible = true
        session?.sidebarPanel = .customize
    }

    @objc func showOutputs() {
        session?.sidebarVisible = true
        session?.sidebarPanel = .outputs
    }

    // MARK: Broadcast

    @objc func goLiveSelected() { tab?.goLive() }
    @objc func stopSelected() { tab?.stopAllOutputs() }
    @objc func goLiveAll() { session?.goLiveAll() }
    @objc func stopAll() { session?.stopAll() }
    @objc func refreshDevices() { app.devices.refreshAll(preferences: app.preferences) }

    // MARK: Bookmarks

    @objc func bookmarkPage() {
        guard let tab else { return }
        app.bookmarks.toggle(title: tab.title, url: tab.urlString)
    }

    @objc private func openBookmark(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        open(bookmarkURL: url, newTab: NSEvent.modifierFlags.contains(.command))
    }

    func open(bookmarkURL: String, newTab: Bool) {
        guard let session else {
            newSession()
            self.session?.selectedTab?.load(input: bookmarkURL)
            return
        }
        if newTab || session.selectedTab == nil {
            session.newTab(url: bookmarkURL)
        } else {
            session.selectedTab?.load(input: bookmarkURL)
        }
    }

    @objc private func openRecentSession(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openSession(at: URL(fileURLWithPath: path))
    }

    @objc private func clearRecents() {
        for item in app.recents.items { app.recents.remove(item) }
    }

    // MARK: Help

    @objc func openSessionsFolder() { NSWorkspace.shared.open(AppPaths.defaultSessionsDirectory) }

    @objc func openRecordingsFolder() {
        let url = URL(fileURLWithPath: app.preferences.recordingsFolder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc func screenRecordingHelp() { AppModel.showScreenCaptureHelp() }

    @objc func showAbout() {
        let credits = NSAttributedString(
            string: """
            A web browser for broadcast: send tabs to DeckLink SDI/HDMI, NDI®, Syphon, displays and recordings.

            NDI® is a registered trademark of Vizrt NDI AB. Blackmagic Design, DeckLink and UltraStudio are trademarks of Blackmagic Design Pty. Ltd. Syphon is open source (BSD).
            """,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .applicationName: "Broadcast Browser"])
    }

    // MARK: Menus

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        if let action, responds(to: action) { item.target = self }
        return item
    }

    private func buildMenus() {
        let main = NSMenu()

        // App
        let appMenu = NSMenu()
        appMenu.addItem(item("About Broadcast Browser", #selector(showAbout)))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Preferences…", #selector(showPreferences), ","))
        appMenu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(services)
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide Broadcast Browser", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit Broadcast Browser", #selector(NSApplication.terminate(_:)), "q"))
        addSubmenu(appMenu, title: "Broadcast Browser", to: main)

        // File
        let file = NSMenu(title: "File")
        file.addItem(item("New Session", #selector(newSession), "n", [.command, .shift]))
        file.addItem(item("Open Session…", #selector(openSessionPanel), "o"))
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(.separator())
        file.addItem(item("New Tab", #selector(newTab), "t"))
        file.addItem(item("Duplicate Tab", #selector(duplicateTab)))
        file.addItem(item("Open Location…", #selector(focusAddressBar), "l"))
        file.addItem(.separator())
        file.addItem(item("Close Tab", #selector(closeTab), "w"))
        file.addItem(item("Close Session", #selector(closeSession), "w", [.command, .shift]))
        file.addItem(item("Save Session", #selector(saveSession), "s"))
        file.addItem(item("Save Session As…", #selector(saveSessionAs), "s", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Go Live When Session Opens", #selector(toggleAutoStart)))
        addSubmenu(file, title: "File", to: main)

        // Edit
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        edit.addItem(item("Delete", #selector(NSText.delete(_:))))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        addSubmenu(edit, title: "Edit", to: main)

        // View
        let view = NSMenu(title: "View")
        view.addItem(item("Reload Page", #selector(reload), "r"))
        view.addItem(.separator())
        view.addItem(item("Zoom In", #selector(zoomIn), "="))
        let zoomInAlternate = item("Zoom In", #selector(zoomIn), "+")
        zoomInAlternate.isHidden = true
        zoomInAlternate.allowsKeyEquivalentWhenHidden = true
        view.addItem(zoomInAlternate)
        view.addItem(item("Zoom Out", #selector(zoomOut), "-"))
        view.addItem(item("Actual Size", #selector(actualSize), "0"))
        view.addItem(.separator())
        view.addItem(item("Lock Canvas Input", #selector(toggleInputLock), "l", [.command, .option]))
        view.addItem(item("Safe Area Guides", #selector(toggleSafeAreas), "g", [.command, .option]))
        view.addItem(.separator())
        view.addItem(item("Show Sidebar", #selector(toggleSidebar), "s", [.command, .control]))
        view.addItem(item("Show Bookmarks Bar", #selector(toggleBookmarksBar), "b", [.command, .shift]))
        view.addItem(.separator())
        view.addItem(item("Edit Mode", #selector(toggleEditMode), "e"))
        view.addItem(item("Pick Element to Customize", #selector(pickElement), "c", [.command, .shift]))
        view.addItem(item("Customize Inspector", #selector(showCustomize), "i", [.command, .shift]))
        view.addItem(item("Web Inspector", #selector(openWebInspector), "i", [.command, .option]))
        addSubmenu(view, title: "View", to: main)

        // History
        let history = NSMenu(title: "History")
        history.addItem(item("Back", #selector(goBack), "["))
        history.addItem(item("Forward", #selector(goForward), "]"))
        history.addItem(item("Home", #selector(goHome), "h", [.command, .shift]))
        addSubmenu(history, title: "History", to: main)

        // Bookmarks
        bookmarksMenu.delegate = self
        addSubmenu(bookmarksMenu, title: "Bookmarks", to: main)

        // Broadcast
        let broadcast = NSMenu(title: "Broadcast")
        broadcast.addItem(item("Go Live — Selected Tab", #selector(goLiveSelected), "\r"))
        broadcast.addItem(item("Stop — Selected Tab", #selector(stopSelected), "\r", [.command, .shift]))
        broadcast.addItem(.separator())
        broadcast.addItem(item("Go Live — All Tabs", #selector(goLiveAll), "\r", [.command, .option]))
        broadcast.addItem(item("Stop All Outputs", #selector(stopAll), "\r", [.command, .option, .shift]))
        broadcast.addItem(.separator())
        broadcast.addItem(item("Outputs Panel", #selector(showOutputs), "o", [.command, .shift]))
        broadcast.addItem(item("Dashboard", #selector(showDashboard), "d", [.command, .option]))
        broadcast.addItem(item("Refresh Devices", #selector(refreshDevices)))
        addSubmenu(broadcast, title: "Broadcast", to: main)

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Show Next Tab", #selector(nextTab), "]", [.command, .shift]))
        window.addItem(item("Show Previous Tab", #selector(previousTab), "[", [.command, .shift]))
        for number in 1...9 {
            let selectItem = item(number == 9 ? "Select Last Tab" : "Select Tab \(number)", #selector(selectTabByNumber(_:)), "\(number)")
            selectItem.tag = number
            window.addItem(selectItem)
        }
        window.addItem(.separator())
        window.addItem(item("Dashboard", #selector(showDashboard)))
        window.addItem(item("Bookmarks", #selector(showBookmarksManager), "b", [.command, .option]))
        window.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        addSubmenu(window, title: "Window", to: main)
        NSApp.windowsMenu = window

        // Help
        let help = NSMenu(title: "Help")
        help.addItem(item("OSC Reference", #selector(openOSCReference)))
        help.addItem(item("Screen Recording Permission…", #selector(screenRecordingHelp)))
        help.addItem(item("Open Sessions Folder", #selector(openSessionsFolder)))
        help.addItem(item("Open Recordings Folder", #selector(openRecordingsFolder)))
        addSubmenu(help, title: "Help", to: main)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    private func addSubmenu(_ menu: NSMenu, title: String, to main: NSMenu) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        holder.submenu = menu
        main.addItem(holder)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === bookmarksMenu {
            menu.removeAllItems()
            let isBookmarked = tab.map { app.bookmarks.contains(url: $0.urlString) } ?? false
            menu.addItem(item(isBookmarked ? "Remove Bookmark" : "Bookmark This Page", #selector(bookmarkPage), "d"))
            menu.addItem(item("Manage Bookmarks…", #selector(showBookmarksManager)))
            menu.addItem(.separator())
            for bookmark in app.bookmarks.bookmarks {
                let entry = NSMenuItem(title: bookmark.title, action: #selector(openBookmark(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = bookmark.url
                entry.toolTip = bookmark.url
                menu.addItem(entry)
            }
        } else if menu === recentMenu {
            menu.removeAllItems()
            for recent in app.recents.items {
                let entry = NSMenuItem(title: recent.name, action: #selector(openRecentSession(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = recent.path
                entry.toolTip = recent.path
                menu.addItem(entry)
            }
            if !app.recents.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(item("Clear Menu", #selector(clearRecents)))
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let needsSession: Set<Selector> = [
            #selector(duplicateTab), #selector(focusAddressBar), #selector(reload),
            #selector(goBack), #selector(goForward), #selector(goHome), #selector(zoomIn), #selector(zoomOut),
            #selector(actualSize), #selector(toggleInputLock), #selector(toggleSafeAreas),
            #selector(toggleSidebar), #selector(pickElement), #selector(openWebInspector), #selector(showCustomize),
            #selector(showOutputs), #selector(goLiveSelected), #selector(stopSelected), #selector(goLiveAll), #selector(stopAll),
            #selector(closeSession), #selector(saveSession), #selector(saveSessionAs), #selector(toggleAutoStart),
            #selector(nextTab), #selector(previousTab), #selector(selectTabByNumber(_:)), #selector(bookmarkPage),
            #selector(toggleEditMode),
        ]
        if let action = menuItem.action, needsSession.contains(action), session == nil { return false }
        switch menuItem.action {
        case #selector(closeTab):
            if let key = NSApp.keyWindow, key !== mainController?.window, !(key is RenderWindow) {
                menuItem.title = "Close Window"
                return true
            }
            menuItem.title = "Close Tab"
            return session != nil
        case #selector(goBack): return tab?.canGoBack ?? false
        case #selector(goForward): return tab?.canGoForward ?? false
        case #selector(toggleInputLock): menuItem.state = session?.canvasInputLocked == true ? .on : .off
        case #selector(toggleSafeAreas): menuItem.state = session?.showSafeAreas == true ? .on : .off
        case #selector(toggleSidebar): menuItem.state = session?.sidebarVisible == true ? .on : .off
        case #selector(toggleBookmarksBar): menuItem.state = app.preferences.showBookmarksBar ? .on : .off
        case #selector(pickElement): menuItem.state = tab?.isPicking == true ? .on : .off
        case #selector(toggleEditMode): menuItem.state = tab?.isEditing == true ? .on : .off
        case #selector(toggleAutoStart): menuItem.state = session?.autoStartOutputs == true ? .on : .off
        case #selector(stopSelected): return tab?.isLive ?? false
        default: break
        }
        return true
    }
}
