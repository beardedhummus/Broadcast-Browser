import AppKit
import SwiftUI

struct BrowserRootView: View {
    @EnvironmentObject var session: SessionController
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TabStripView()
            if let tab = session.selectedTab {
                BrowserToolbar(tab: tab)
            }
            if app.preferences.showBookmarksBar {
                BookmarksBar(store: app.bookmarks)
            }
            Divider()
            HStack(spacing: 0) {
                CanvasViewport()
                if session.sidebarVisible {
                    Divider()
                    SidebarView()
                        .frame(width: 340)
                }
            }
            Divider()
            StatusBarView(monitor: app.monitor)
        }
        .background(Color.bbChrome)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Tab strip

struct TabStripView: View {
    @EnvironmentObject var session: SessionController

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(session.tabs) { tab in
                        TabChip(tab: tab, selected: tab.id == session.selectedTab?.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            Button {
                session.newTab()
                session.focusAddressBarToken += 1
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 26)
            }
            .buttonStyle(.borderless)
            .help("New Tab (⌘T)")
            .padding(.trailing, 6)
        }
        .frame(height: 36)
        .background(Color.bbStage.opacity(0.7))
    }
}

struct TabChip: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    @EnvironmentObject var session: SessionController
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            FaviconView(tab: tab)
            Text(tab.displayName)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Spacer(minLength: 2)
            if tab.isEditing {
                Text(tab.isHoldingOutput ? "HOLD" : "EDIT")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange))
                    .fixedSize()
                    .help(tab.isHoldingOutput ? "Editing — outputs are holding the last frame" : "Edit Mode")
            }
            if tab.liveSince != nil {
                LiveBadge(since: tab.liveSince, compact: true)
                    .fixedSize()
            }
            Button {
                session.closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
            }
            .buttonStyle(.plain)
            .opacity(hovering || selected ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minWidth: 150, idealWidth: 210, maxWidth: 250, minHeight: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.bbCard : (hovering ? Color.white.opacity(0.05) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(tab.liveSince != nil ? Color.bbLive.opacity(0.9) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { session.select(tab) }
        .onHover { hovering = $0 }
        .help(tab.urlString)
        .contextMenu {
            Button("Reload") { tab.reload() }
            Button("Duplicate Tab") { session.duplicate(tab) }
            Divider()
            if tab.isLive {
                Button("Stop Outputs") { tab.stopAllOutputs() }
            } else {
                Button("Go Live") { tab.goLive() }
            }
            Divider()
            Button("Move Left") { session.moveTab(tab, by: -1) }
            Button("Move Right") { session.moveTab(tab, by: 1) }
            Divider()
            Button("Close Tab") { session.closeTab(tab) }
        }
    }
}

// MARK: - Toolbar

struct BrowserToolbar: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var session: SessionController
    @EnvironmentObject var app: AppModel
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                toolbarButton("chevron.left", help: "Back (⌘[)", enabled: tab.canGoBack) { tab.webView.goBack() }
                toolbarButton("chevron.right", help: "Forward (⌘])", enabled: tab.canGoForward) { tab.webView.goForward() }
                toolbarButton(tab.isLoading ? "xmark" : "arrow.clockwise", help: tab.isLoading ? "Stop" : "Reload (⌘R)") {
                    tab.isLoading ? tab.webView.stopLoading() : tab.reload()
                }
                toolbarButton("house", help: "Home (⇧⌘H)") { tab.goHome() }
            }

            addressField

            ZoomControl(tab: tab)

            Divider().frame(height: 20)

            EditModeButton(tab: tab)

            HStack(spacing: 2) {
                toolbarToggle("scope", help: "Pick an element to customize (⇧⌘C) — turns on Edit Mode", on: tab.isPicking) { tab.togglePicking() }
                toolbarToggle("rectangle.dashed", help: "Safe area guides (⌥⌘G) — never sent to outputs", on: session.showSafeAreas) {
                    session.showSafeAreas.toggle()
                }
                toolbarToggle(session.canvasInputLocked ? "lock.fill" : "lock.open",
                              help: session.canvasInputLocked
                                ? "Canvas input is locked — clicks and typing don't reach the page (⌥⌘L)"
                                : "Lock canvas input so stray clicks can't change a live page (⌥⌘L)",
                              on: session.canvasInputLocked) {
                    session.canvasInputLocked.toggle()
                }
                toolbarButton("hammer", help: "Web Inspector (⌥⌘I) — Edit Mode only") { tab.openWebInspector() }
            }

            Divider().frame(height: 20)

            GoLiveButton(tab: tab)

            toolbarToggle("sidebar.right", help: "Show sidebar (⌃⌘S)", on: session.sidebarVisible) {
                session.sidebarVisible.toggle()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .onAppear { address = tab.urlString }
        .onChange(of: tab.urlString) { _, newValue in
            if !addressFocused { address = newValue }
        }
        .onChange(of: tab.id) { _, _ in address = tab.urlString }
        .onChange(of: session.focusAddressBarToken) { _, _ in
            addressFocused = true
        }
    }

    private var addressField: some View {
        let isSecure = tab.urlString.hasPrefix("https://")
        let bookmarked = app.bookmarks.contains(url: tab.urlString)
        return HStack(spacing: 6) {
            Image(systemName: isSecure ? "lock.fill" : "globe")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField("Search or enter website address", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($addressFocused)
                .onSubmit {
                    tab.load(input: address)
                    addressFocused = false
                }
                .onExitCommand {
                    address = tab.urlString
                    addressFocused = false
                }
            Button {
                app.bookmarks.toggle(title: tab.title, url: tab.urlString)
            } label: {
                Image(systemName: bookmarked ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(bookmarked ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(bookmarked ? "Remove bookmark" : "Bookmark this page (⌘D)")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.black.opacity(0.35))
        )
        .overlay(alignment: .bottom) {
            if tab.isLoading && tab.progress < 1 {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * tab.progress, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, 4)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(addressFocused ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func toolbarButton(_ symbol: String, help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }

    private func toolbarToggle(_ symbol: String, help: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.18) : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Toggles Edit Mode (picker, Web Inspector, style editing).
struct EditModeButton: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        Button {
            tab.toggleEditMode()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.isEditing ? "checkmark" : "pencil")
                    .font(.system(size: 10, weight: .bold))
                Text(tab.isEditing ? "Done" : "Edit")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(tab.isEditing ? Color.black : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(tab.isEditing ? Color.orange : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(tab.isEditing
              ? "Leave Edit Mode (⌘E): closes the Web Inspector and returns held outputs to the live page"
              : "Edit Mode (⌘E): pick elements, change styles and use the Web Inspector. Live outputs hold their last frame while you edit.")
    }
}

struct ZoomControl: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        HStack(spacing: 0) {
            Button { tab.zoomOut() } label: {
                Image(systemName: "minus").frame(width: 22, height: 24)
            }
            .help("Zoom out (⌘-)")
            Button { tab.resetZoom() } label: {
                Text("\(Int((tab.zoom * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .frame(width: 42, height: 24)
            }
            .help("Actual size (⌘0)")
            Button { tab.zoomIn() } label: {
                Image(systemName: "plus").frame(width: 22, height: 24)
            }
            .help("Zoom in (⌘=)")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11, weight: .medium))
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.25)))
    }
}

struct GoLiveButton: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        if let since = tab.liveSince {
            Button {
                tab.stopAllOutputs()
            } label: {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill").font(.system(size: 9))
                        Text(formatDuration(context.date.timeIntervalSince(since)))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.bbLive))
                }
            }
            .buttonStyle(.plain)
            .help("Stop this tab's outputs (⇧⌘↩)")
        } else {
            Button {
                tab.goLive()
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(Color.bbLive).frame(width: 8, height: 8)
                    Text("Go Live").font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.bbLive.opacity(0.7), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Start this tab's outputs (⌘↩)")
        }
    }
}

// MARK: - Bookmarks bar

struct BookmarksBar: View {
    @ObservedObject var store: BookmarkStore
    @EnvironmentObject var session: SessionController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if store.bookmarks.isEmpty {
                    Text("Bookmarks appear here — press ⌘D or click the star.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                }
                ForEach(store.bookmarks) { bookmark in
                    Button {
                        open(bookmark, newTab: NSEvent.modifierFlags.contains(.command))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow.opacity(0.8))
                            Text(bookmark.title).lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .frame(maxWidth: 180)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(bookmark.url)
                    .contextMenu {
                        Button("Open") { open(bookmark, newTab: false) }
                        Button("Open in New Tab") { open(bookmark, newTab: true) }
                        Divider()
                        Button("Delete") { store.remove(bookmark) }
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 26)
    }

    private func open(_ bookmark: Bookmark, newTab: Bool) {
        if newTab || session.selectedTab == nil {
            session.newTab(url: bookmark.url)
        } else {
            session.selectedTab?.load(input: bookmark.url)
        }
    }
}

// MARK: - Canvas viewport

struct CanvasViewport: View {
    @EnvironmentObject var session: SessionController

    var body: some View {
        ZStack {
            Color.bbStage
            if let tab = session.selectedTab {
                InteractiveCanvas(tab: tab, inputLocked: session.canvasInputLocked)
            } else {
                Text("No tab").foregroundStyle(.secondary)
            }
        }
        .clipped()
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    @ObservedObject var monitor: SystemMonitor
    @EnvironmentObject var session: SessionController
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 14) {
            if let tab = session.selectedTab {
                TabStatusItems(tab: tab, tick: monitor.tick)
            }
            Spacer()
            if let sample = monitor.latest {
                Label(String(format: "CPU %.0f%%", sample.appCPU + sample.webCPU), systemImage: "cpu")
                    .help("Broadcast Browser + WebKit processes (100% = one core). System: \(Int(sample.systemCPU))%")
                Label(String(format: "%.0f MB", sample.appMemoryMB + sample.webMemoryMB), systemImage: "memorychip")
                if sample.gpu > 0 {
                    Label(String(format: "GPU %.0f%%", sample.gpu), systemImage: "square.3.layers.3d")
                }
            }
            OSCStatusItem(osc: OSCController.shared)
            Text("\(session.liveOutputCount) output\(session.liveOutputCount == 1 ? "" : "s") live")
                .foregroundStyle(session.liveOutputCount > 0 ? Color.primary : Color.secondary)
            if session.liveSince != nil {
                LiveBadge(since: session.liveSince)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color.bbStage.opacity(0.7))
    }
}

struct OSCStatusItem: View {
    @ObservedObject var osc: OSCController

    var body: some View {
        if let port = osc.listeningPort {
            Label { Text(verbatim: "OSC \(port)") } icon: { Image(systemName: "dot.radiowaves.forward") }
                .help("Receiving OSC on UDP \(port) · \(osc.messagesReceived) received · \(osc.messagesSent) sent\nLast: \(osc.lastCommand)")
        } else if osc.statusIsError {
            Label("OSC off", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .help(osc.status)
        }
    }
}

struct TabStatusItems: View {
    @ObservedObject var tab: BrowserTab
    /// Changes every second so the capture rate stays current.
    let tick: Int

    var body: some View {
        HStack(spacing: 14) {
            Text("Canvas \(tab.canvasSize.label)")
            if tab.zoom != 1 {
                Text("Zoom \(Int((tab.zoom * 100).rounded()))%")
            }
            if let engine = tab.captureEngineName {
                Text("\(engine) \(Int(tab.captureFPS.rounded())) fps")
            }
            if let problem = tab.captureProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .lineLimit(1)
            } else if let error = tab.lastError {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
    }
}
