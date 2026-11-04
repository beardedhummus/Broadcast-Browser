import AppKit
import CoreVideo
import QuartzCore
import SwiftUI

extension Color {
    static let bbLive = Color(red: 0.92, green: 0.16, blue: 0.20)
    static let bbChrome = Color(nsColor: NSColor(calibratedWhite: 0.105, alpha: 1))
    static let bbPanel = Color(nsColor: NSColor(calibratedWhite: 0.145, alpha: 1))
    static let bbCard = Color(nsColor: NSColor(calibratedWhite: 0.185, alpha: 1))
    static let bbStage = Color(nsColor: NSColor(calibratedWhite: 0.06, alpha: 1))
}

/// Red "ON AIR" pill with a running timer.
struct LiveBadge: View {
    let since: Date?
    var compact = false

    var body: some View {
        if let since {
            TimelineView(.periodic(from: since, by: 1)) { context in
                HStack(spacing: 5) {
                    Circle().fill(Color.white).frame(width: 6, height: 6)
                    if compact {
                        Text("LIVE").font(.system(size: 9, weight: .heavy))
                    } else {
                        Text("ON AIR").font(.system(size: 10, weight: .heavy))
                        Text(formatDuration(context.date.timeIntervalSince(since)))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 5 : 8)
                .padding(.vertical, compact ? 2 : 3)
                .background(Capsule().fill(Color.bbLive))
            }
        }
    }
}

struct StatusDot: View {
    let status: OutputStatus

    var color: Color {
        switch status {
        case .idle: return Color(nsColor: .tertiaryLabelColor)
        case .starting: return .yellow
        case .live: return .bbLive
        case .error: return .orange
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 0.5))
            .help(status.errorMessage ?? status.label)
    }
}

/// A titled group in the sidebar.
struct PanelSection<Content: View, Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer()
                accessory()
            }
            content()
        }
    }
}

extension PanelSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// Label + control row sized for the 340 pt sidebar.
struct FieldRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 92
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CardBackground: ViewModifier {
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.bbCard))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(highlighted ? Color.bbLive.opacity(0.85) : Color.white.opacity(0.06), lineWidth: highlighted ? 1.5 : 1))
    }
}

extension View {
    func card(highlighted: Bool = false) -> some View { modifier(CardBackground(highlighted: highlighted)) }
}

/// Integer text field with clamping.
struct IntField: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 16...8192
    var width: CGFloat = 60
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: width)
            .font(.system(size: 11).monospacedDigit())
            .onAppear { text = String(value) }
            .onChange(of: value) { _, newValue in text = String(newValue) }
            .onSubmit(commit)
    }

    private func commit() {
        if let number = Int(text.filter(\.isNumber)) {
            value = min(range.upperBound, max(range.lowerBound, number))
        }
        text = String(value)
    }
}

// MARK: - Live preview of a tab's captured frames

final class PreviewLayerView: NSView {
    private let contentLayer = CALayer()
    private var link: CADisplayLink?
    private var lastCounter: UInt64 = .max
    private var current: CVPixelBuffer?
    var source: FrameSource? {
        didSet { lastCounter = .max }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        contentLayer.contentsGravity = .resizeAspect
        contentLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(contentLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let proxy = DisplayLinkProxy { [weak self] in self?.refresh() }
        let link = displayLink(target: proxy, selector: #selector(DisplayLinkProxy.fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func refresh() {
        guard let latest = source?.latest(), latest.counter != lastCounter else { return }
        lastCounter = latest.counter
        current = latest.buffer
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.contents = CVPixelBufferGetIOSurface(latest.buffer)?.takeUnretainedValue()
        CATransaction.commit()
    }

    func stop() {
        link?.invalidate()
        link = nil
        current = nil
    }
}

/// Shows what a tab is sending (requests capture while visible).
struct LivePreview: NSViewRepresentable {
    @ObservedObject var tab: BrowserTab

    final class Coordinator {
        weak var tab: BrowserTab?
        var token: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView(frame: .zero)
        attach(view, context: context)
        return view
    }

    func updateNSView(_ view: PreviewLayerView, context: Context) {
        if context.coordinator.tab !== tab {
            if let token = context.coordinator.token { context.coordinator.tab?.removePreviewClient(token) }
            attach(view, context: context)
        }
    }

    private func attach(_ view: PreviewLayerView, context: Context) {
        context.coordinator.tab = tab
        view.source = tab.frameSource
        context.coordinator.token = tab.addPreviewClient(fps: 30)
    }

    static func dismantleNSView(_ view: PreviewLayerView, coordinator: Coordinator) {
        view.stop()
        if let token = coordinator.token { coordinator.tab?.removePreviewClient(token) }
        coordinator.tab = nil
    }
}

/// Favicon or a globe placeholder.
struct FaviconView: View {
    @ObservedObject var tab: BrowserTab
    var size: CGFloat = 14

    var body: some View {
        Group {
            if tab.isLoading && tab.progress < 1 {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            } else if let image = tab.favicon {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}
