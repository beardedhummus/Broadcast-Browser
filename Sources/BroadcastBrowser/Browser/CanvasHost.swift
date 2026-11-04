import AppKit
import WebKit

/// Borderless window that holds one tab's web view at exactly the canvas
/// resolution. It is captured on its own (nothing is ever attached to it), and
/// it lives almost entirely off screen: only its corner point overlaps the top-left
/// corner of the main display, under the menu bar. That keeps macOS treating it
/// as "on a display" (so WebKit keeps animating at the display's refresh rate)
/// while nothing of it is ever visible to the user.
final class RenderWindow: NSWindow {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hasShadow = false
        canHide = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        colorSpace = .sRGB
        backgroundColor = .black
        acceptsMouseMovedEvents = true
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    // Key so typing reaches the page; never main, so the browser window keeps looking active.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Draws the element picker highlights, crop guides, safe areas and the Edit
/// Mode frame on top of the canvas image in the main window. It lives in the
/// browser window, never in the captured canvas window, so none of it can
/// reach an output.
final class OverlayView: NSView {
    /// Where the canvas image is drawn, in this view's (flipped) coordinates.
    var contentRect: CGRect = .zero { didSet { needsDisplay = true } }
    /// Canvas size in pixels.
    var canvasPixelSize = CGSize(width: 1920, height: 1080) { didSet { needsDisplay = true } }
    /// Page zoom (canvas pixels per CSS pixel).
    var zoom: CGFloat = 1 { didSet { needsDisplay = true } }
    var isLive = false { didSet { needsDisplay = true } }

    /// Rects are in CSS pixels (viewport coordinates).
    var hoverRect: CGRect? { didSet { needsDisplay = true } }
    var hoverLabel: String? { didSet { needsDisplay = true } }
    var selectionRect: CGRect? { didSet { needsDisplay = true } }
    var matchRects: [CGRect] = [] { didSet { needsDisplay = true } }
    var showSafeAreas = false { didSet { needsDisplay = true } }
    /// Output crop regions in canvas pixels with their output names.
    var cropGuides: [(CGRect, String)] = [] { didSet { needsDisplay = true } }
    /// Shown as an orange frame + label while the tab is in Edit Mode.
    var editBanner: String? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// View points per canvas pixel.
    private var scale: CGFloat {
        canvasPixelSize.width > 0 ? contentRect.width / canvasPixelSize.width : 0
    }

    private func fromCanvas(_ rect: CGRect) -> CGRect {
        CGRect(x: contentRect.minX + rect.minX * scale, y: contentRect.minY + rect.minY * scale,
               width: rect.width * scale, height: rect.height * scale)
    }

    private func fromCSS(_ rect: CGRect) -> CGRect {
        fromCanvas(CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard contentRect.width > 1 else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: contentRect).addClip()

        if showSafeAreas {
            drawSafeArea(inset: 0.035, color: NSColor.systemYellow.withAlphaComponent(0.7), label: "Action safe 93%")
            drawSafeArea(inset: 0.05, color: NSColor.systemTeal.withAlphaComponent(0.8), label: "Title safe 90%")
            let center = NSBezierPath()
            center.move(to: NSPoint(x: contentRect.midX - 12, y: contentRect.midY))
            center.line(to: NSPoint(x: contentRect.midX + 12, y: contentRect.midY))
            center.move(to: NSPoint(x: contentRect.midX, y: contentRect.midY - 12))
            center.line(to: NSPoint(x: contentRect.midX, y: contentRect.midY + 12))
            NSColor.white.withAlphaComponent(0.6).setStroke()
            center.lineWidth = 1
            center.stroke()
        }

        for (rect, name) in cropGuides {
            let r = fromCanvas(rect)
            let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1.5
            path.setLineDash([8, 4], count: 2, phase: 0)
            NSColor.systemPink.setStroke()
            path.stroke()
            drawTag("Crop: \(name)", at: NSPoint(x: r.minX + 2, y: r.minY + 2), color: .systemPink)
        }

        for rect in matchRects {
            let path = NSBezierPath(rect: fromCSS(rect).insetBy(dx: -1, dy: -1))
            path.lineWidth = 1
            path.setLineDash([3, 2], count: 2, phase: 0)
            NSColor.systemOrange.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }

        if let selection = selectionRect {
            let r = fromCSS(selection)
            NSColor.systemOrange.withAlphaComponent(0.12).setFill()
            r.fill()
            let path = NSBezierPath(rect: r.insetBy(dx: -1, dy: -1))
            path.lineWidth = 2
            NSColor.systemOrange.setStroke()
            path.stroke()
        }

        if let hover = hoverRect {
            let r = fromCSS(hover)
            NSColor.systemBlue.withAlphaComponent(0.18).setFill()
            r.fill()
            let path = NSBezierPath(rect: r)
            path.lineWidth = 1.5
            NSColor.systemBlue.setStroke()
            path.stroke()
            if let label = hoverLabel {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
                let text = NSAttributedString(string: label, attributes: attributes)
                let size = text.size()
                var origin = NSPoint(x: r.minX, y: r.minY - size.height - 6)
                if origin.y < contentRect.minY + 2 { origin.y = r.maxY + 4 }
                origin.x = min(max(contentRect.minX + 2, origin.x), contentRect.maxX - size.width - 10)
                let background = NSRect(x: origin.x, y: origin.y, width: size.width + 8, height: size.height + 4)
                NSColor.systemBlue.setFill()
                NSBezierPath(roundedRect: background, xRadius: 3, yRadius: 3).fill()
                text.draw(at: NSPoint(x: origin.x + 4, y: origin.y + 2))
            }
        }

        NSGraphicsContext.current?.restoreGraphicsState()

        // Frame around the canvas: orange in Edit Mode, red when live.
        if let banner = editBanner {
            let frame = NSBezierPath(rect: contentRect.insetBy(dx: -1.5, dy: -1.5))
            frame.lineWidth = 3
            NSColor.systemOrange.setStroke()
            frame.stroke()
            drawTag(banner, at: NSPoint(x: contentRect.minX + 8, y: contentRect.minY + 8), color: .systemOrange)
        } else {
            let frame = NSBezierPath(rect: contentRect.insetBy(dx: -1, dy: -1))
            frame.lineWidth = isLive ? 2 : 1
            (isLive ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.12)).setStroke()
            frame.stroke()
        }
    }

    private func drawTag(_ text: String, at origin: NSPoint, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let background = NSRect(x: origin.x, y: origin.y, width: size.width + 10, height: size.height + 4)
        color.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: background, xRadius: 3, yRadius: 3).fill()
        string.draw(at: NSPoint(x: origin.x + 5, y: origin.y + 2))
    }

    private func drawSafeArea(inset: CGFloat, color: NSColor, label: String) {
        let rect = contentRect.insetBy(dx: contentRect.width * inset, dy: contentRect.height * inset)
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        path.setLineDash([6, 4], count: 2, phase: 0)
        color.setStroke()
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: color,
        ]
        NSAttributedString(string: label, attributes: attributes).draw(at: NSPoint(x: rect.minX + 4, y: rect.minY + 3))
    }
}

/// Owns a tab's render window: geometry, zoom, transparency and placement.
@MainActor
final class CanvasHost: NSObject {
    let window: RenderWindow
    let overlayView = OverlayView()
    private let webView: WKWebView

    var canvasSize: PixelSize {
        didSet { if canvasSize != oldValue { applyGeometry() } }
    }
    var zoom: Double {
        didSet { if zoom != oldValue { applyZoom() } }
    }
    var transparent: Bool {
        didSet { if transparent != oldValue { applyTransparency() } }
    }
    /// Called after the canvas size in points changes.
    var onGeometryChange: (() -> Void)?

    var backingScale: CGFloat { max(1, window.backingScaleFactor) }

    /// Canvas size in points for a given backing scale (1 canvas px = 1 device px).
    func pointSize(scale: CGFloat) -> NSSize {
        NSSize(width: CGFloat(canvasSize.width) / scale, height: CGFloat(canvasSize.height) / scale)
    }

    var pointSize: NSSize { pointSize(scale: backingScale) }

    /// Points per CSS pixel. pageZoom = zoom / backingScale keeps the CSS
    /// viewport at exactly canvasSize / zoom.
    var cssToPoints: CGFloat { CGFloat(zoom) / backingScale }

    init(webView: WKWebView, canvas: PixelSize, zoom: Double, transparent: Bool) {
        self.webView = webView
        self.canvasSize = canvas
        self.zoom = zoom
        self.transparent = transparent
        let screenScale = NSScreen.screens.first?.backingScaleFactor ?? 2
        window = RenderWindow(size: NSSize(width: CGFloat(canvas.width) / screenScale, height: CGFloat(canvas.height) / screenScale))
        super.init()

        let container = NSView(frame: NSRect(origin: .zero, size: window.frame.size))
        container.wantsLayer = true
        container.autoresizesSubviews = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        window.contentView = container

        NotificationCenter.default.addObserver(self, selector: #selector(backingChanged(_:)),
                                               name: NSWindow.didChangeBackingPropertiesNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        applyTransparency()
        applyGeometry()
        window.orderBack(nil)
    }

    @objc private func backingChanged(_ note: Notification) {
        applyGeometry()
    }

    @objc private func screensChanged(_ note: Notification) {
        place()
    }

    func applyGeometry() {
        window.setContentSize(pointSize)
        overlayView.canvasPixelSize = CGSize(width: canvasSize.width, height: canvasSize.height)
        place()
        applyZoom()
        onGeometryChange?()
    }

    func applyZoom() {
        webView.pageZoom = CGFloat(zoom) / backingScale
        overlayView.zoom = CGFloat(zoom)
    }

    func applyTransparency() {
        window.isOpaque = !transparent
        window.backgroundColor = transparent ? .clear : .black
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            webView.setValue(!transparent, forKey: "drawsBackground")
        }
        webView.underPageBackgroundColor = transparent ? .clear : .black
    }

    /// Off screen, except one point hidden under the menu bar at the main
    /// display's top-left corner.
    func place() {
        guard let screen = NSScreen.screens.first else { return }
        let size = window.frame.size
        let origin = NSPoint(x: screen.frame.minX - size.width + 1, y: screen.frame.maxY - 1)
        if window.frame.origin != origin {
            window.setFrameOrigin(origin)
        }
        if !window.isVisible {
            window.orderBack(nil)
        }
    }

    /// Converts a canvas-pixel point (top-left origin) into window coordinates.
    func windowPoint(forCanvas point: CGPoint) -> NSPoint {
        let bounds = window.contentView?.bounds ?? NSRect(origin: .zero, size: pointSize)
        let scale = 1 / backingScale
        return NSPoint(x: point.x * scale, y: bounds.height - point.y * scale)
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        window.orderOut(nil)
        window.close()
    }
}
