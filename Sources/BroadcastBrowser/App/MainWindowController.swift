import AppKit
import Combine
import SwiftUI

/// The browser window. Tabs render in their own hidden canvas windows; this
/// window shows the selected tab's captured picture and forwards input to it
/// (see CanvasInteractionView), so nothing in this window can reach an output.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let session: SessionController
    private var cancellables = Set<AnyCancellable>()
    var onClose: (() -> Void)?

    init(session: SessionController) {
        self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = session.name
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)
        window.delegate = self
        session.windowController = self

        let root = BrowserRootView()
            .environmentObject(session)
            .environmentObject(AppModel.shared)
        window.contentView = NSHostingView(rootView: root)

        if let saved = session.savedWindowFrame {
            window.setFrame(NSRectFromString(saved), display: false)
        } else {
            sizeToFit()
            window.center()
        }

        session.$name
            .sink { [weak window] name in window?.title = name }
            .store(in: &cancellables)
        session.$isDirty
            .sink { [weak window] dirty in window?.isDocumentEdited = dirty }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Picks a window size that shows a 1080p canvas comfortably plus the sidebar.
    private func sizeToFit() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        let canvas = session.selectedTab?.canvasSize ?? AppModel.shared.preferences.defaultCanvas
        let canvasPoints = NSSize(width: CGFloat(canvas.width) / scale, height: CGFloat(canvas.height) / scale)
        let chromeHeight: CGFloat = 34 + 44 + 30 + 26 + 24
        let desired = NSSize(width: canvasPoints.width + 340 + 32, height: canvasPoints.height + chromeHeight + 32)
        let visible = screen.visibleFrame.size
        let size = NSSize(width: min(max(desired.width, 1100), visible.width * 0.96),
                          height: min(max(desired.height, 700), visible.height * 0.96))
        window.setContentSize(size)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        session.confirmClose()
    }

    func windowWillClose(_ notification: Notification) {
        cancellables.removeAll()
        session.close()
        onClose?()
    }
}
