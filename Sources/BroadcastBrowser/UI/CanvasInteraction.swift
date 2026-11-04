import AppKit
import CoreVideo
import QuartzCore
import SwiftUI

/// Shows the selected tab's captured canvas (exactly what the outputs get)
/// and passes mouse, scroll and keyboard input through to the real page,
/// which lives in its own off-screen window. Picker highlights and guides are
/// drawn here by the tab's OverlayView, so they can never reach an output.
final class CanvasInteractionView: NSView {
    private let frameLayer = CALayer()
    private(set) weak var tab: BrowserTab?
    private var previewToken: UUID?
    private var link: CADisplayLink?
    private var lastCounter: UInt64 = .max
    private var current: CVPixelBuffer?
    private var trackingArea: NSTrackingArea?
    private var cursorName = "default"
    private var mouseInside = false
    var inputLocked = false {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        frameLayer.contentsGravity = .resize
        frameLayer.backgroundColor = NSColor.black.cgColor
        frameLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer?.addSublayer(frameLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        link?.invalidate()
    }

    // MARK: Tab attachment

    func attach(_ newTab: BrowserTab?) {
        guard newTab !== tab else { return }
        if let old = tab {
            if let previewToken { old.removePreviewClient(previewToken) }
            old.onCursorChange = nil
            old.onSelectMenu = nil
            old.onCanvasGeometryChange = nil
            old.host.overlayView.removeFromSuperview()
        }
        previewToken = nil
        tab = newTab
        current = nil
        lastCounter = .max
        frameLayer.contents = nil
        guard let newTab else { return }
        previewToken = newTab.addPreviewClient(fps: 60)
        let overlay = newTab.host.overlayView
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        newTab.onCursorChange = { [weak self] name in self?.setPageCursor(name) }
        newTab.onSelectMenu = { [weak self] id, options, selected, rect in
            self?.showSelectMenu(id: id, options: options, selected: selected, cssRect: rect)
        }
        newTab.onCanvasGeometryChange = { [weak self] in self?.needsLayout = true }
        needsLayout = true
    }

    func detach() {
        attach(nil)
    }

    // MARK: Layout & frames

    /// Canvas image rect (aspect fit, non-flipped view coordinates).
    var contentRect: CGRect {
        guard let tab else { return .zero }
        let canvas = tab.canvasSize
        let available = bounds.insetBy(dx: 14, dy: 14)
        guard canvas.width > 0, canvas.height > 0, available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / CGFloat(canvas.width), available.height / CGFloat(canvas.height))
        let size = CGSize(width: (CGFloat(canvas.width) * scale).rounded(), height: (CGFloat(canvas.height) * scale).rounded())
        return CGRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        let rect = contentRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = rect
        CATransaction.commit()
        if let overlay = tab?.host.overlayView {
            overlay.frame = bounds
            overlay.contentRect = CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let proxy = DisplayLinkProxy { [weak self] in self?.refresh() }
        let link = displayLink(target: proxy, selector: #selector(DisplayLinkProxy.fire(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func refresh() {
        let source = tab?.frameSource
        guard let latest = source?.latest(), latest.counter != lastCounter else { return }
        lastCounter = latest.counter
        current = latest.buffer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = CVPixelBufferGetIOSurface(latest.buffer)?.takeUnretainedValue()
        CATransaction.commit()
    }

    // MARK: Coordinates

    /// Converts a mouse location into canvas pixels (top-left origin).
    private func canvasPoint(for event: NSEvent, clamp: Bool) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil)
        let rect = contentRect
        guard rect.width > 0, let tab else { return nil }
        if !clamp && !rect.contains(point) { return nil }
        let canvas = tab.canvasSize
        let u = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let v = min(max((rect.maxY - point.y) / rect.height, 0), 1)
        return CGPoint(x: u * CGFloat(canvas.width), y: v * CGFloat(canvas.height))
    }

    /// View points per canvas pixel.
    private var displayScale: CGFloat {
        guard let tab else { return 1 }
        let width = tab.canvasSize.width
        return width > 0 ? contentRect.width / CGFloat(width) : 1
    }

    // MARK: Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func forward(_ event: NSEvent, as type: NSEvent.EventType, clamp: Bool) {
        guard !inputLocked, let point = canvasPoint(for: event, clamp: clamp) else { return }
        tab?.forwardMouse(type, canvasPoint: point, modifierFlags: event.modifierFlags,
                          clickCount: event.clickCount, timestamp: event.timestamp, pressure: event.pressure)
    }

    override func mouseDown(with event: NSEvent) { forward(event, as: .leftMouseDown, clamp: false) }
    override func mouseDragged(with event: NSEvent) { forward(event, as: .leftMouseDragged, clamp: true) }
    override func mouseUp(with event: NSEvent) { forward(event, as: .leftMouseUp, clamp: true) }
    override func otherMouseDown(with event: NSEvent) { forward(event, as: .otherMouseDown, clamp: false) }
    override func otherMouseUp(with event: NSEvent) { forward(event, as: .otherMouseUp, clamp: true) }

    override func mouseMoved(with event: NSEvent) {
        guard !inputLocked, canvasPoint(for: event, clamp: false) != nil else { return }
        forward(event, as: .mouseMoved, clamp: false)
    }

    override func mouseEntered(with event: NSEvent) {
        mouseInside = true
        applyCursor()
    }

    override func mouseExited(with event: NSEvent) {
        mouseInside = false
        NSCursor.arrow.set()
        if !inputLocked { tab?.forwardMouseExit() }
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor()
    }

    override func scrollWheel(with event: NSEvent) {
        guard !inputLocked, let point = canvasPoint(for: event, clamp: false), let tab else { return }
        // Precise (trackpad) deltas are in points on screen: convert them so the
        // page moves with your fingers. Mouse wheels report lines.
        let zoom = tab.zoom
        let perCSSPixel = max(0.01, displayScale * CGFloat(zoom))
        let dx: CGFloat
        let dy: CGFloat
        if event.hasPreciseScrollingDeltas {
            dx = -event.scrollingDeltaX / perCSSPixel
            dy = -event.scrollingDeltaY / perCSSPixel
        } else {
            dx = -event.scrollingDeltaX * 40
            dy = -event.scrollingDeltaY * 40
        }
        guard dx != 0 || dy != 0 else { return }
        tab.forwardScroll(canvasPoint: point, deltaX: Double(dx), deltaY: Double(dy))
    }

    // MARK: Cursor

    private func setPageCursor(_ name: String) {
        cursorName = name
        if mouseInside { applyCursor() }
    }

    private func applyCursor() {
        guard !inputLocked else {
            NSCursor.arrow.set()
            return
        }
        let cursor: NSCursor
        switch cursorName {
        case "pointer": cursor = .pointingHand
        case "text", "vertical-text": cursor = .iBeam
        case "crosshair": cursor = .crosshair
        case "grab", "move", "all-scroll": cursor = .openHand
        case "grabbing": cursor = .closedHand
        case "not-allowed", "no-drop": cursor = .operationNotAllowed
        case "ew-resize", "col-resize", "e-resize", "w-resize": cursor = .resizeLeftRight
        case "ns-resize", "row-resize", "n-resize", "s-resize": cursor = .resizeUpDown
        case "copy": cursor = .dragCopy
        default: cursor = .arrow
        }
        cursor.set()
    }

    // MARK: Menus

    override func rightMouseDown(with event: NSEvent) {
        guard let point = canvasPoint(for: event, clamp: false), let tab else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        tab.contextInfo(atCanvas: point) { [weak self] info in
            self?.showContextMenu(info: info, canvasPoint: point, at: viewPoint)
        }
    }

    private func showContextMenu(info: BrowserTab.ContextInfo, canvasPoint: CGPoint, at viewPoint: NSPoint) {
        guard let tab else { return }
        let menu = NSMenu()
        func add(_ title: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, action: action)
            item.isEnabled = enabled
            menu.addItem(item)
        }
        if !info.link.isEmpty {
            add("Open Link") { tab.load(input: info.link) }
            add("Open Link in New Tab") { tab.session?.newTab(url: info.link) }
            add("Copy Link") { Self.copy(info.link) }
            menu.addItem(.separator())
        }
        if !info.image.isEmpty {
            add("Open Image in New Tab") { tab.session?.newTab(url: info.image) }
            add("Copy Image Address") { Self.copy(info.image) }
            menu.addItem(.separator())
        }
        if !info.selection.isEmpty {
            add("Copy") { Self.copy(info.selection) }
        }
        if info.editable {
            add("Paste") {
                tab.host.window.makeKey()
                NSApp.sendAction(#selector(NSText.paste(_:)), to: tab.webView, from: nil)
            }
        }
        if !info.selection.isEmpty || info.editable { menu.addItem(.separator()) }
        add("Back", enabled: tab.canGoBack) { tab.webView.goBack() }
        add("Forward", enabled: tab.canGoForward) { tab.webView.goForward() }
        add("Reload") { tab.reload() }
        menu.addItem(.separator())
        add(tab.isEditing ? "Customize This Element" : "Edit This Element…") { tab.customizeElement(atCanvas: canvasPoint) }
        add("Inspect Element") {
            tab.customizeElement(atCanvas: canvasPoint)
            tab.openWebInspector()
        }
        menu.popUp(positioning: nil, at: viewPoint, in: self)
    }

    private func showSelectMenu(id: String, options: [SelectOption], selected: Int, cssRect: CGRect) {
        guard let tab, !options.isEmpty else { return }
        let menu = NSMenu()
        var lastGroup = ""
        for option in options {
            if option.group != lastGroup {
                if !option.group.isEmpty {
                    if menu.numberOfItems > 0 { menu.addItem(.separator()) }
                    let header = NSMenuItem(title: option.group, action: nil, keyEquivalent: "")
                    header.isEnabled = false
                    menu.addItem(header)
                }
                lastGroup = option.group
            }
            let item = ClosureMenuItem(title: option.label.isEmpty ? " " : option.label) {
                tab.chooseSelectOption(id: id, index: option.index)
            }
            item.isEnabled = !option.disabled
            item.state = option.index == selected ? .on : .off
            if !option.group.isEmpty { item.indentationLevel = 1 }
            menu.addItem(item)
        }
        // Place the menu under the <select> element as drawn in this view.
        let scale = displayScale * CGFloat(tab.zoom)
        let rect = contentRect
        let x = rect.minX + cssRect.minX * scale
        let bottom = rect.maxY - cssRect.maxY * scale
        menu.minimumWidth = max(120, cssRect.width * scale)
        let selectedItem = menu.items.first { $0.state == .on }
        menu.popUp(positioning: selectedItem, at: NSPoint(x: x, y: selectedItem == nil ? bottom : rect.maxY - cssRect.minY * scale - cssRect.height * scale / 2), in: self)
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// SwiftUI wrapper for the selected tab's interactive canvas.
struct InteractiveCanvas: NSViewRepresentable {
    @ObservedObject var tab: BrowserTab
    let inputLocked: Bool

    func makeNSView(context: Context) -> CanvasInteractionView {
        let view = CanvasInteractionView(frame: .zero)
        view.attach(tab)
        view.inputLocked = inputLocked
        return view
    }

    func updateNSView(_ view: CanvasInteractionView, context: Context) {
        view.attach(tab)
        view.inputLocked = inputLocked
        view.needsLayout = true
    }

    static func dismantleNSView(_ view: CanvasInteractionView, coordinator: ()) {
        view.detach()
    }
}
