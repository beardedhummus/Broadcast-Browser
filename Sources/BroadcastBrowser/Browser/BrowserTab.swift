import AppKit
import Combine
import WebKit

/// One entry of a page's <select> list, shown as a native menu.
struct SelectOption {
    let index: Int
    let label: String
    let disabled: Bool
    let group: String

    init(json: [String: Any]) {
        index = (json["i"] as? NSNumber)?.intValue ?? 0
        label = json["label"] as? String ?? ""
        disabled = (json["disabled"] as? NSNumber)?.boolValue ?? false
        group = json["group"] as? String ?? ""
    }
}

/// Element chosen with the picker, with its current computed styles.
struct PickedElement: Equatable {
    var selector: String
    var classSelector: String
    var matchCount: Int
    var tag: String
    var elementID: String
    var classes: [String]
    var text: String
    var label: String
    var rect: CGRect
    var computed: [String: String]

    init?(json: Any?) {
        guard let dict = json as? [String: Any], let selector = dict["selector"] as? String else { return nil }
        self.selector = selector
        classSelector = dict["classSelector"] as? String ?? selector
        matchCount = (dict["matchCount"] as? NSNumber)?.intValue ?? 1
        tag = dict["tag"] as? String ?? ""
        elementID = dict["id"] as? String ?? ""
        classes = dict["classes"] as? [String] ?? []
        text = dict["text"] as? String ?? ""
        label = dict["label"] as? String ?? tag
        rect = PickedElement.rect(dict["rect"]) ?? .zero
        computed = dict["style"] as? [String: String] ?? [:]
    }

    static func rect(_ value: Any?) -> CGRect? {
        guard let r = value as? [String: Any] else { return nil }
        func n(_ key: String) -> CGFloat { CGFloat((r[key] as? NSNumber)?.doubleValue ?? 0) }
        return CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h"))
    }
}

/// WKWebView with an extra "Customize This Element" context-menu item.
final class BBWebView: WKWebView {
    var onCustomizeElement: ((CGPoint) -> Void)?
    /// Outside Edit Mode the Web Inspector is not offered at all.
    var editingEnabled = false
    private var lastMenuPoint: CGPoint = .zero

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let point = convert(event.locationInWindow, from: nil)
        lastMenuPoint = CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
        if !editingEnabled {
            for item in menu.items where item.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" || item.title == "Inspect Element" {
                menu.removeItem(item)
            }
        }
        menu.addItem(.separator())
        let item = NSMenuItem(title: editingEnabled ? "Customize This Element…" : "Edit This Element…",
                              action: #selector(customizeElement(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func customizeElement(_ sender: Any?) {
        onCustomizeElement?(lastMenuPoint)
    }

    /// The canvas must always fill its window. If the Web Inspector gets docked
    /// inside it (which would shrink the broadcast), detach it instead.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let superview else { return }
        if abs(newSize.width - superview.bounds.width) > 0.5 || abs(newSize.height - superview.bounds.height) > 0.5 {
            DispatchQueue.main.async { [weak self] in self?.restoreCanvasFrame() }
        }
    }

    private func restoreCanvasFrame() {
        guard let superview, frame.size != superview.bounds.size else { return }
        detachInspector()
        frame = superview.bounds
    }

    func showInspector() -> Bool {
        guard let inspector = inspectorObject else { return false }
        if inspector.responds(to: NSSelectorFromString("show")) {
            inspector.perform(NSSelectorFromString("show"))
        }
        detachInspector()
        return true
    }

    func closeInspector() {
        guard let inspector = inspectorObject, inspector.responds(to: NSSelectorFromString("close")) else { return }
        inspector.perform(NSSelectorFromString("close"))
    }

    func detachInspector() {
        guard let inspector = inspectorObject, inspector.responds(to: NSSelectorFromString("detach")) else { return }
        inspector.perform(NSSelectorFromString("detach"))
    }

    private var inspectorObject: NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard responds(to: selector) else { return nil }
        return perform(selector)?.takeUnretainedValue() as? NSObject
    }
}

/// Receives script messages without retaining the tab.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var tab: BrowserTab?

    init(_ tab: BrowserTab) {
        self.tab = tab
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { tab?.handleScriptMessage(body) }
    }
}

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id: UUID
    weak var session: SessionController?

    // MARK: Saved state

    @Published var label: String { didSet { markDirty() } }
    @Published var title: String
    @Published var urlString: String
    @Published var canvasSize: PixelSize {
        didSet {
            guard canvasSize != oldValue else { return }
            host.canvasSize = canvasSize
            updateCapture()
            markDirty()
        }
    }
    @Published var zoom: Double {
        didSet {
            guard zoom != oldValue else { return }
            host.zoom = zoom
            markDirty()
        }
    }
    @Published var transparentBackground: Bool {
        didSet {
            guard transparentBackground != oldValue else { return }
            host.transparent = transparentBackground
            applyCustomization(immediately: true)
            capturer?.update(fps: currentCaptureFPS, size: canvasSize, transparent: transparentBackground)
            markDirty()
        }
    }
    @Published var customization: TabCustomization {
        didSet {
            guard customization != oldValue else { return }
            applyCustomization(immediately: false)
            markDirty()
        }
    }
    @Published var outputs: [OutputConfig] {
        didSet {
            markDirty()
            refreshOverlayGuides()
        }
    }
    @Published var autoReloadMinutes: Int {
        didSet {
            configureAutoReload()
            markDirty()
        }
    }
    @Published var userAgent: String {
        didSet {
            webView.customUserAgent = userAgent.isEmpty ? nil : userAgent
            markDirty()
        }
    }
    @Published var muted: Bool {
        didSet {
            applyMute()
            markDirty()
        }
    }

    // MARK: Runtime state

    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var favicon: NSImage?
    @Published var isPicking = false
    @Published var picked: PickedElement?
    /// Edit Mode enables the element picker, Web Inspector and style editing.
    @Published private(set) var isEditing = false
    /// True while outputs repeat the last clean frame because a live tab is being edited.
    @Published private(set) var isHoldingOutput = false
    @Published var lastError: String?
    @Published private(set) var liveSince: Date?
    @Published private(set) var runtimeRevision = 0
    @Published private(set) var captureEngineName: String?
    @Published private(set) var captureProblem: String?

    let webView: BBWebView
    let host: CanvasHost
    let frameSource = FrameSource()
    private(set) var runtimes: [UUID: OutputRuntime] = [:]
    private var capturer: FrameCapturer?
    private var captureStarting = false
    private var currentCaptureFPS: Double = 0
    private var previewRequests: [UUID: Double] = [:]

    // Hooks for the interactive canvas view in the main window.
    var onCanvasGeometryChange: (() -> Void)?
    var onCursorChange: ((String) -> Void)?
    var onSelectMenu: ((_ id: String, _ options: [SelectOption], _ selected: Int, _ rect: CGRect) -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private var reloadTimer: Timer?
    private var applyWork: DispatchWorkItem?
    private var autoStartPending = false
    private var didFinishFirstLoad = false
    private var forceSnapshot = false

    var displayName: String {
        if !label.isEmpty { return label }
        if !title.isEmpty { return title }
        return urlString.isEmpty ? "New Tab" : urlString
    }

    var isLive: Bool { runtimes.values.contains { $0.status.isActive } }

    init(state: TabState, session: SessionController?, configuration: WKWebViewConfiguration? = nil) {
        let initialCanvas = state.canvas.isValid ? state.canvas : PixelSize(1920, 1080)
        let initialZoom = min(5, max(0.25, state.zoom))
        id = state.id
        self.session = session
        label = state.label
        title = state.title
        urlString = state.url
        canvasSize = initialCanvas
        zoom = initialZoom
        transparentBackground = state.transparentBackground
        customization = state.customization
        outputs = state.outputs
        autoReloadMinutes = state.autoReloadMinutes
        userAgent = state.userAgent
        muted = state.muted

        let config = configuration ?? WKWebViewConfiguration()
        if configuration == nil {
            config.websiteDataStore = .default()
        }
        config.userContentController = WKUserContentController()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.preferences.isElementFullscreenEnabled = false
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = false
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"

        webView = BBWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 540), configuration: config)
        host = CanvasHost(webView: webView, canvas: initialCanvas, zoom: initialZoom, transparent: state.transparentBackground)
        super.init()

        config.userContentController.add(WeakScriptHandler(self), name: "bb")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = false
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = true
        if !state.userAgent.isEmpty { webView.customUserAgent = state.userAgent }
        // Keep rendering even when the canvas window is covered or parked.
        if webView.responds(to: NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")) {
            webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
        webView.onCustomizeElement = { [weak self] point in
            self?.customizeElement(atViewPoint: point)
        }
        host.onGeometryChange = { [weak self] in
            self?.onCanvasGeometryChange?()
        }

        installUserScripts()
        observeWebView()
        applyMute()
        configureAutoReload()

        if configuration == nil, let url = URLInput.url(from: state.url, search: AppModel.shared.preferences.searchEngine) {
            webView.load(URLRequest(url: url))
        }
    }

    func makeState() -> TabState {
        var state = TabState(url: webView.url?.absoluteString ?? urlString, canvas: canvasSize, hideScrollbars: customization.hideScrollbars)
        state.id = id
        state.label = label
        state.title = title
        state.zoom = zoom
        state.transparentBackground = transparentBackground
        state.customization = customization
        state.outputs = outputs
        state.autoReloadMinutes = autoReloadMinutes
        state.userAgent = userAgent
        state.muted = muted
        return state
    }

    private func markDirty() {
        session?.markDirty()
    }

    private func observeWebView() {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let newTitle = webView.title ?? ""
                    if !newTitle.isEmpty { self.title = newTitle }
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = webView.url else { return }
                    self.urlString = url.absoluteString
                    self.markDirty()
                }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.isLoading = webView.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.progress = webView.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated { self?.canGoForward = webView.canGoForward }
            },
        ]
    }

    // MARK: Navigation

    func load(input: String) {
        guard let url = URLInput.url(from: input, search: AppModel.shared.preferences.searchEngine) else { return }
        lastError = nil
        webView.load(URLRequest(url: url))
    }

    func goHome() {
        load(input: AppModel.shared.preferences.homePage)
    }

    func reload() {
        if webView.url == nil {
            load(input: urlString)
        } else {
            webView.reload()
        }
    }

    static let zoomSteps: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0]

    func zoomIn() {
        zoom = BrowserTab.zoomSteps.first { $0 > zoom + 0.001 } ?? zoom
    }

    func zoomOut() {
        zoom = BrowserTab.zoomSteps.last { $0 < zoom - 0.001 } ?? zoom
    }

    func resetZoom() {
        zoom = 1.0
    }

    private func configureAutoReload() {
        reloadTimer?.invalidate()
        reloadTimer = nil
        guard autoReloadMinutes > 0 else { return }
        let timer = Timer(timeInterval: TimeInterval(autoReloadMinutes * 60), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.webView.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        reloadTimer = timer
    }

    /// Mutes the page when the tab is muted, or when "mute tabs that aren't
    /// live" is on and this tab has no live outputs.
    func applyMute() {
        let shouldMute = muted || (AppModel.shared.preferences.muteTabsNotLive && !isLive)
        if webView.responds(to: NSSelectorFromString("_setPageMuted:")) {
            webView.setValue(shouldMute ? 1 : 0, forKey: "pageMuted")
        }
    }

    // MARK: Customization

    private func installUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        let css = StyleCompiler.css(for: customization, transparent: transparentBackground)
        controller.addUserScript(WKUserScript(source: PageScripts.core(css: css), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let js = customization.customJS.trimmingCharacters(in: .whitespacesAndNewlines)
        if !js.isEmpty {
            controller.addUserScript(WKUserScript(source: PageScripts.customJS(js), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
    }

    /// Pushes the current CSS into the live page and updates the scripts used on reload.
    func applyCustomization(immediately: Bool) {
        applyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let css = StyleCompiler.css(for: self.customization, transparent: self.transparentBackground)
            self.webView.evaluateJavaScript("window.__bb && window.__bb.setCSS(\(PageScripts.literal(css)))", completionHandler: nil)
            self.installUserScripts()
            if self.picked != nil {
                self.webView.evaluateJavaScript("window.__bb && window.__bb.refreshSelection()", completionHandler: nil)
            }
        }
        applyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0 : 0.08), execute: work)
    }

    func runCustomJSNow() {
        let js = customization.customJS.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !js.isEmpty else { return }
        webView.evaluateJavaScript(PageScripts.customJS(js)) { [weak self] _, error in
            if let error { self?.lastError = "Custom script: \(error.localizedDescription)" }
        }
    }

    func ruleIndex(for selector: String) -> Int? {
        customization.rules.firstIndex { $0.selector == selector }
    }

    func styleValue(selector: String, property: String) -> String? {
        guard let index = ruleIndex(for: selector) else { return nil }
        return customization.rules[index].properties[property]
    }

    /// Sets (or clears, when value is nil/empty) one CSS property for a selector.
    func setStyle(selector: String, property: String, value: String?) {
        let trimmedSelector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelector.isEmpty else { return }
        let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var updated = customization
        if let index = updated.rules.firstIndex(where: { $0.selector == trimmedSelector }) {
            if cleaned.isEmpty {
                updated.rules[index].properties[property] = nil
            } else {
                updated.rules[index].properties[property] = cleaned
            }
        } else if !cleaned.isEmpty {
            var rule = StyleRule(selector: trimmedSelector, label: picked?.label ?? "")
            rule.properties[property] = cleaned
            updated.rules.append(rule)
        }
        customization = updated
    }

    func clearStyles(selector: String) {
        customization.rules.removeAll { $0.selector == selector }
    }

    // MARK: Element picker

    func togglePicking() {
        isPicking ? stopPicking() : startPicking()
    }

    func startPicking() {
        if !isEditing { enterEditMode() }
        isPicking = true
        session?.sidebarPanel = .customize
        session?.sidebarVisible = true
        webView.evaluateJavaScript("window.__bb && window.__bb.startPicking()", completionHandler: nil)
        host.window.makeKey()
    }

    func stopPicking() {
        isPicking = false
        host.overlayView.hoverRect = nil
        host.overlayView.hoverLabel = nil
        webView.evaluateJavaScript("window.__bb && window.__bb.stopPicking()", completionHandler: nil)
    }

    func selectElement(selector: String) {
        webView.evaluateJavaScript("window.__bb && window.__bb.select(\(PageScripts.literal(selector)))", completionHandler: nil)
    }

    func selectParentElement() {
        webView.evaluateJavaScript("window.__bb && window.__bb.selectParent()", completionHandler: nil)
    }

    func clearSelection() {
        picked = nil
        host.overlayView.selectionRect = nil
        host.overlayView.matchRects = []
        webView.evaluateJavaScript("window.__bb && window.__bb.clearSelection()", completionHandler: nil)
    }

    /// Outlines every element matching `selector` (used for class-wide edits).
    func highlightMatches(_ selector: String?) {
        guard let selector, !selector.isEmpty else {
            host.overlayView.matchRects = []
            return
        }
        webView.evaluateJavaScript("window.__bb ? window.__bb.matchRects(\(PageScripts.literal(selector))) : []") { [weak self] result, _ in
            let rects = (result as? [Any])?.compactMap { PickedElement.rect($0) } ?? []
            self?.host.overlayView.matchRects = rects
        }
    }

    private func customizeElement(atViewPoint point: CGPoint) {
        if !isEditing { enterEditMode() }
        let scale = max(0.01, host.cssToPoints)
        let x = point.x / scale
        let y = point.y / scale
        session?.sidebarPanel = .customize
        session?.sidebarVisible = true
        webView.evaluateJavaScript("window.__bb && window.__bb.selectAtPoint(\(x), \(y))", completionHandler: nil)
    }

    func handleScriptMessage(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        let overlay = host.overlayView
        switch type {
        case "hover":
            overlay.hoverRect = PickedElement.rect(message["rect"])
            overlay.hoverLabel = message["label"] as? String
        case "select":
            if let element = PickedElement(json: message["info"]) {
                picked = element
                overlay.selectionRect = element.rect
                overlay.matchRects = []
            }
        case "selRect":
            overlay.selectionRect = PickedElement.rect(message["rect"])
        case "pickEnd":
            isPicking = false
            overlay.hoverRect = nil
            overlay.hoverLabel = nil
        case "clear":
            overlay.selectionRect = nil
        case "cursor":
            if let value = message["value"] as? String { onCursorChange?(value) }
        case "selectMenu":
            guard let id = message["id"] as? String, let rect = PickedElement.rect(message["rect"]) else { return }
            let options = (message["options"] as? [[String: Any]] ?? []).map { SelectOption(json: $0) }
            let selected = (message["selected"] as? NSNumber)?.intValue ?? -1
            onSelectMenu?(id, options, selected, rect)
        default:
            break
        }
    }

    // MARK: Input from the main window's canvas view

    /// Sends a mouse event to the page. `canvasPoint` is in canvas pixels
    /// (top-left origin). Mouse moves become in-page hover events.
    func forwardMouse(_ type: NSEvent.EventType, canvasPoint: CGPoint, modifierFlags: NSEvent.ModifierFlags = [],
                      clickCount: Int = 1, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime, pressure: Float = 1) {
        if type == .mouseMoved {
            // WebKit ignores synthetic mouse-move events, so hover is driven
            // from inside the page (mouseover/enter/leave/move at the point).
            let x = Double(canvasPoint.x) / zoom
            let y = Double(canvasPoint.y) / zoom
            webView.evaluateJavaScript("window.__bb && window.__bb.hover(\(x), \(y))", completionHandler: nil)
            return
        }
        let window = host.window
        let location = host.windowPoint(forCanvas: canvasPoint)
        let isDown = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        if isDown {
            // Key window = keyboard input goes to the page.
            if !window.isKeyWindow { window.makeKey() }
            if window.firstResponder !== webView { window.makeFirstResponder(webView) }
        }
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifierFlags,
                                             timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: clickCount, pressure: pressure) else { return }
        // Call the web view directly: going through NSWindow.sendEvent lets
        // AppKit swallow the click as a "first click" when the window isn't key yet.
        switch type {
        case .leftMouseDown: webView.mouseDown(with: event)
        case .leftMouseUp: webView.mouseUp(with: event)
        case .leftMouseDragged: webView.mouseDragged(with: event)
        case .otherMouseDown: webView.otherMouseDown(with: event)
        case .otherMouseUp: webView.otherMouseUp(with: event)
        default: window.sendEvent(event)
        }
    }

    /// Tells the page the pointer left the canvas (ends hover effects).
    func forwardMouseExit() {
        webView.evaluateJavaScript("window.__bb && window.__bb.hover(-1, -1)", completionHandler: nil)
    }

    /// Scrolls whatever is under `canvasPoint` (deltas in CSS pixels, positive = down/right).
    func forwardScroll(canvasPoint: CGPoint, deltaX: Double, deltaY: Double) {
        let x = Double(canvasPoint.x) / zoom
        let y = Double(canvasPoint.y) / zoom
        webView.evaluateJavaScript("window.__bb && window.__bb.wheel(\(x), \(y), \(deltaX), \(deltaY))", completionHandler: nil)
    }

    struct ContextInfo {
        var link = ""
        var image = ""
        var selection = ""
        var editable = false
    }

    /// What is under a canvas point (for the right-click menu).
    func contextInfo(atCanvas point: CGPoint, completion: @escaping (ContextInfo) -> Void) {
        let x = Double(point.x) / zoom
        let y = Double(point.y) / zoom
        webView.evaluateJavaScript("window.__bb ? window.__bb.contextInfo(\(x), \(y)) : null") { result, _ in
            var info = ContextInfo()
            if let dict = result as? [String: Any] {
                info.link = dict["link"] as? String ?? ""
                info.image = dict["image"] as? String ?? ""
                info.selection = dict["selection"] as? String ?? ""
                info.editable = (dict["editable"] as? NSNumber)?.boolValue ?? false
            }
            completion(info)
        }
    }

    func chooseSelectOption(id: String, index: Int) {
        webView.evaluateJavaScript("window.__bb && window.__bb.chooseOption(\(PageScripts.literal(id)), \(index))", completionHandler: nil)
    }

    /// Selects the element under a canvas point (right-click › Customize).
    func customizeElement(atCanvas point: CGPoint) {
        if !isEditing { enterEditMode() }
        session?.sidebarPanel = .customize
        session?.sidebarVisible = true
        webView.evaluateJavaScript("window.__bb && window.__bb.selectAtPoint(\(Double(point.x) / zoom), \(Double(point.y) / zoom))", completionHandler: nil)
    }

    // MARK: Web Inspector

    /// Opens WebKit's Web Inspector in its own window (never attached, so the
    /// canvas size — and the broadcast — is not affected).
    func openWebInspector() {
        if !isEditing { enterEditMode() }
        if isLive && !isHoldingOutput {
            lastError = "Web Inspector is unavailable while this tab is on air — its highlights would be broadcast. Stop the tab, or set Preferences › Capture › Editing a live tab to “Hold outputs”."
            return
        }
        let existing = Set(NSApp.windows.map(ObjectIdentifier.init))
        if !webView.showInspector() {
            lastError = "Web Inspector is not available here. You can also use Safari › Develop › \(Host.current().localizedName ?? "this Mac")."
            return
        }
        // The inspector opens next to the (off-screen) canvas window; bring it on screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard let screen = NSApp.mainWindow?.screen ?? NSScreen.main else { return }
            for window in NSApp.windows where !existing.contains(ObjectIdentifier(window)) && window.isVisible && !(window is RenderWindow) {
                let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame.insetBy(dx: 40, dy: 40)) }
                if !onScreen {
                    let size = NSSize(width: min(window.frame.width, screen.visibleFrame.width * 0.8),
                                      height: min(window.frame.height, screen.visibleFrame.height * 0.8))
                    window.setFrame(NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2,
                                           width: size.width, height: size.height), display: true)
                }
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    // MARK: Edit Mode

    func toggleEditMode() {
        isEditing ? exitEditMode() : enterEditMode()
    }

    /// Turns on the picker / inspector tools. If the tab is live and the
    /// preference says so, outputs hold the last clean frame until you finish.
    func enterEditMode() {
        guard !isEditing else { return }
        if isLive && AppModel.shared.preferences.liveEditBehavior == .holdOutputs {
            frameSource.isHeld = true
            isHoldingOutput = true
        }
        isEditing = true
        webView.isInspectable = true
        webView.editingEnabled = true
        session?.sidebarVisible = true
        session?.sidebarPanel = .customize
        refreshOverlayGuides()
        OSCController.shared.tabStateChanged(self)
    }

    /// Leaves Edit Mode: closes the Web Inspector, clears highlights and
    /// releases any held outputs so the edited page goes to air.
    func exitEditMode() {
        guard isEditing else { return }
        if isPicking { stopPicking() }
        clearSelection()
        highlightMatches(nil)
        webView.closeInspector()
        webView.isInspectable = false
        webView.editingEnabled = false
        isEditing = false
        frameSource.isHeld = false
        isHoldingOutput = false
        refreshOverlayGuides()
        OSCController.shared.tabStateChanged(self)
    }

    /// Updates the overlay's edit banner and crop guides (never on air).
    func refreshOverlayGuides() {
        let overlay = host.overlayView
        overlay.editBanner = isEditing ? (isHoldingOutput ? "EDIT MODE — outputs holding last frame" : (isLive ? "EDIT MODE — on air" : "EDIT MODE")) : nil
        let showCrops = isEditing || (session?.sidebarPanel == .outputs && session?.sidebarVisible == true)
        overlay.isLive = isLive
        overlay.cropGuides = showCrops ? outputs.compactMap { config in
            config.cropRect.map { ($0, config.name.isEmpty ? config.kind.shortLabel : config.name) }
        } : []
    }

    /// Selected element's bounds in canvas pixels (for cropping an output to it).
    var pickedCanvasRect: CGRect? {
        guard let rect = picked?.rect, rect.width > 0, rect.height > 0 else { return nil }
        let scaled = CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
        return scaled.intersection(CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)).integral
    }

    func cropOutput(_ id: UUID, to rect: CGRect) {
        guard let index = outputs.firstIndex(where: { $0.id == id }) else { return }
        outputs[index].cropEnabled = true
        outputs[index].cropX = Int(rect.minX)
        outputs[index].cropY = Int(rect.minY)
        outputs[index].cropWidth = max(16, Int(rect.width))
        outputs[index].cropHeight = max(16, Int(rect.height))
    }

    // MARK: Outputs

    func addOutput(kind: OutputKind) -> OutputConfig {
        let prefs = AppModel.shared.preferences
        var config = OutputConfig.makeDefault(kind: kind, tabName: displayName, preferences: prefs)
        config.size = kind == .display ? canvasSize : (canvasSize.isValid ? canvasSize : prefs.defaultCanvas)
        let devices = AppModel.shared.devices
        switch kind {
        case .ndi, .syphon:
            config.name = uniqueOutputName(base: displayName, kind: kind)
        case .decklink:
            if let device = devices.deckLinkDevices.first(where: { $0.supportsPlayback }) {
                config.deckLinkPersistentID = device.persistentID
                config.deckLinkDeviceName = device.name
                if let mode = device.modes.first(where: { $0.size == config.size && $0.frameRate == config.frameRate && !$0.interlaced }) {
                    config.deckLinkModeName = mode.name
                }
            }
        case .display:
            let mainScreen = session?.windowController?.window?.screen
            if let screen = NSScreen.screens.first(where: { $0 != mainScreen }) ?? NSScreen.screens.first {
                config.displayID = screen.displayID
                config.displayName = screen.localizedName
            }
        case .record:
            break
        }
        outputs.append(config)
        return config
    }

    private func uniqueOutputName(base: String, kind: OutputKind) -> String {
        let trimmed = String(base.prefix(40))
        let existing = Set((session?.tabs ?? [self]).flatMap { $0.outputs.filter { $0.kind == kind }.map(\.name) })
        if !existing.contains(trimmed) { return trimmed }
        var n = 2
        while existing.contains("\(trimmed) \(n)") { n += 1 }
        return "\(trimmed) \(n)"
    }

    func removeOutput(_ id: UUID) {
        stopOutput(id)
        runtimes[id] = nil
        outputs.removeAll { $0.id == id }
        runtimeRevision += 1
    }

    func runtime(for id: UUID) -> OutputRuntime? {
        runtimes[id]
    }

    /// True when the output is running with a configuration that differs from the saved one.
    func needsRestart(_ config: OutputConfig) -> Bool {
        guard let runtime = runtimes[config.id], runtime.status.isActive else { return false }
        return runtime.config != config
    }

    func startOutput(_ id: UUID) {
        guard let config = outputs.first(where: { $0.id == id }) else { return }
        if let existing = runtimes[id], existing.status.isActive { return }
        // Nothing from editing (inspector highlights, half-typed values) may reach air.
        if isEditing { exitEditMode() }
        let prefs = AppModel.shared.preferences
        let runtime = OutputFactory.make(config: config, source: frameSource)
        if let ndi = runtime as? NDIOutput { ndi.ndiLibraryPath = prefs.ndiLibraryPath }
        if let syphon = runtime as? SyphonOutput { syphon.frameworkPath = prefs.syphonFrameworkPath }
        if let record = runtime as? RecordOutput { record.tabName = displayName }
        runtime.onStatusChange = { [weak self] _ in
            MainActor.assumeIsolated { self?.runtimesChanged() }
        }
        runtimes[id] = runtime
        do {
            try runtime.start()
        } catch {
            runtime.stop()
            runtime.setStatus(.error(error.localizedDescription))
        }
        runtimesChanged()
    }

    func stopOutput(_ id: UUID) {
        guard let runtime = runtimes[id] else { return }
        if runtime.status.isActive { runtime.stop() }
        runtimes[id] = nil
        runtimesChanged()
    }

    func restartOutput(_ id: UUID) {
        stopOutput(id)
        startOutput(id)
    }

    func toggleOutput(_ id: UUID) {
        if runtimes[id]?.status.isActive == true {
            stopOutput(id)
        } else {
            startOutput(id)
        }
    }

    /// Starts every output marked "start with Go Live".
    func goLive() {
        let toStart = outputs.filter(\.autoStart)
        if toStart.isEmpty {
            lastError = "Add an output (NDI, Syphon, DeckLink…) in the Outputs panel before going live."
            session?.sidebarPanel = .outputs
            session?.sidebarVisible = true
            return
        }
        for config in toStart { startOutput(config.id) }
    }

    func stopAllOutputs() {
        for id in Array(runtimes.keys) { stopOutput(id) }
    }

    func goLiveWhenLoaded() {
        if didFinishFirstLoad {
            goLive()
        } else {
            autoStartPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.autoStartPending else { return }
                self.autoStartPending = false
                self.goLive()
            }
        }
    }

    private func runtimesChanged() {
        let live = isLive
        if live && liveSince == nil { liveSince = Date() }
        if !live { liveSince = nil }
        if !live && isHoldingOutput {
            frameSource.isHeld = false
            isHoldingOutput = false
        }
        runtimeRevision += 1
        updateCapture()
        applyMute()
        refreshOverlayGuides()
        session?.liveStateChanged()
        OSCController.shared.tabStateChanged(self)
    }

    // MARK: Capture

    /// Keeps the tab captured while something shows it (the canvas view at
    /// 60 fps, dashboard thumbnails at 30). Returns a token for removal.
    @discardableResult
    func addPreviewClient(fps: Double = 30) -> UUID {
        let token = UUID()
        previewRequests[token] = fps
        updateCapture()
        return token
    }

    func removePreviewClient(_ token: UUID) {
        previewRequests[token] = nil
        updateCapture()
    }

    private var desiredCaptureFPS: Double? {
        let outputFPS = runtimes.values.filter { $0.status.isActive }.map(\.requiredCaptureFPS).max()
        let previewFPS = previewRequests.values.max()
        guard let fps = [outputFPS, previewFPS].compactMap({ $0 }).max() else { return nil }
        return min(60, fps)
    }

    func updateCapture() {
        guard let fps = desiredCaptureFPS else {
            stopCapture()
            return
        }
        let captureFPS = fps.rounded(.up)
        if let capturer {
            currentCaptureFPS = captureFPS
            capturer.update(fps: captureFPS, size: canvasSize, transparent: transparentBackground)
            return
        }
        guard !captureStarting else { return }
        startCapture(fps: captureFPS)
    }

    private func startCapture(fps: Double) {
        currentCaptureFPS = fps
        let engine = AppModel.shared.preferences.captureEngine
        if engine == .screenCaptureKit && !forceSnapshot && AppModel.shared.ensureScreenCapturePermission() {
            let sck = SCKCapturer(windowID: CGWindowID(host.window.windowNumber), source: frameSource,
                                  fps: fps, size: canvasSize, transparent: transparentBackground)
            sck.onStop = { [weak self] error in
                guard let self else { return }
                self.captureProblem = "Capture stopped: \(error.localizedDescription). Switched to snapshot capture."
                self.capturer = nil
                self.forceSnapshot = true
                self.updateCapture()
            }
            capturer = sck
            captureStarting = true
            sck.start { [weak self] error in
                guard let self else { return }
                self.captureStarting = false
                if let error {
                    self.captureProblem = "ScreenCaptureKit failed (\(error.localizedDescription)). Using snapshot capture."
                    self.capturer = nil
                    self.forceSnapshot = true
                    self.updateCapture()
                } else {
                    self.captureEngineName = sck.engineName
                    self.captureProblem = nil
                }
            }
        } else {
            let snapshot = SnapshotCapturer(webView: webView, source: frameSource, fps: fps, size: canvasSize, transparent: transparentBackground)
            capturer = snapshot
            snapshot.start { _ in }
            captureEngineName = snapshot.engineName
            if engine == .screenCaptureKit && !forceSnapshot {
                captureProblem = "Screen Recording permission is off — using snapshot capture (lower frame rate)."
            }
        }
    }

    private func stopCapture() {
        capturer?.stop()
        capturer = nil
        captureEngineName = nil
        captureStarting = false
        frameSource.reset()
    }

    /// Re-creates the capturer (after a preference change or permission grant).
    func restartCapture() {
        forceSnapshot = false
        captureProblem = nil
        stopCapture()
        updateCapture()
    }

    var captureFPS: Double { capturer == nil ? 0 : frameSource.measuredFPS }

    // MARK: Teardown

    func teardown() {
        stopAllOutputs()
        stopCapture()
        reloadTimer?.invalidate()
        applyWork?.cancel()
        observations.removeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "bb")
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        host.close()
    }

    var webProcessIdentifier: pid_t {
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")) else { return 0 }
        return (webView.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    }

    var gpuProcessIdentifier: pid_t {
        guard webView.responds(to: NSSelectorFromString("_gpuProcessIdentifier")) else { return 0 }
        return (webView.value(forKey: "_gpuProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    }

    // MARK: Favicon

    private func fetchFavicon() {
        webView.evaluateJavaScript("window.__bb ? window.__bb.favicon() : ''") { [weak self] result, _ in
            guard let string = result as? String, let url = URL(string: string), !string.isEmpty else { return }
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
                await MainActor.run { self?.favicon = image }
            }
        }
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate

extension BrowserTab: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        lastError = nil
        favicon = nil
        if picked != nil { clearSelection() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !didFinishFirstLoad {
            didFinishFirstLoad = true
            if autoStartPending {
                autoStartPending = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.goLive() }
            }
        }
        fetchFavicon()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return } // frame load interrupted (downloads)
        lastError = error.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        lastError = "The page crashed and was reloaded."
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme) {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var destination = downloads.appendingPathComponent(suggestedFilename)
        var n = 1
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = downloads.appendingPathComponent("\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            n += 1
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        lastError = "Download finished (saved to Downloads)."
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        lastError = "Download failed: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let session else { return nil }
        let tab = session.openTab(configuration: configuration, url: navigationAction.request.url?.absoluteString ?? "")
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        session?.closeTab(self, force: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "This page says"
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }
}

/// Converts what the user typed in the address bar into a URL.
enum URLInput {
    static func url(from input: String, search: SearchEngine) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("about:") || lower.hasPrefix("data:") || lower.hasPrefix("file:") {
            return URL(string: text)
        }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil {
            return url
        }
        if text.hasPrefix("/") || text.hasPrefix("~") {
            return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }
        let looksLikeHost = !text.contains(" ") && (text.contains(".") || lower.hasPrefix("localhost") || text.contains(":"))
        if looksLikeHost {
            let scheme = lower.hasPrefix("localhost") || lower.range(of: #"^\d+\.\d+\.\d+\.\d+"#, options: .regularExpression) != nil ? "http" : "https"
            return URL(string: "\(scheme)://\(text)")
        }
        return search.url(for: text)
    }
}
