import AppKit
import BBBridge
import Combine

/// Discovers output hardware / runtimes.
@MainActor
final class DeviceDiscovery: ObservableObject {
    @Published private(set) var deckLinkDevices: [DeckLinkDeviceInfo] = []
    @Published private(set) var deckLinkMessage: String?
    @Published private(set) var screens: [ScreenInfo] = []
    @Published private(set) var ndiMessage = "Not loaded yet"
    @Published private(set) var syphonMessage = "Not loaded yet"

    struct ScreenInfo: Identifiable, Hashable {
        let id: UInt32
        let name: String
        let pixelSize: PixelSize
        let isMain: Bool
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScreens() }
        }
    }

    func refreshAll(preferences: AppPreferences) {
        refreshScreens()
        refreshDeckLink()
        refreshNDI(preferences: preferences)
        refreshSyphon(preferences: preferences)
    }

    func refreshScreens() {
        screens = NSScreen.screens.map { screen in
            ScreenInfo(id: screen.displayID,
                       name: screen.localizedName,
                       pixelSize: PixelSize(Int(screen.frame.width * screen.backingScaleFactor), Int(screen.frame.height * screen.backingScaleFactor)),
                       isMain: screen == NSScreen.screens.first)
        }
    }

    func refreshDeckLink() {
        let result = DeckLinkRuntime.devices()
        deckLinkDevices = result.devices
        if !DeckLinkRuntime.isCompiledIn {
            let driver = DeckLinkRuntime.driverVersion.map { " Desktop Video \($0) is installed." } ?? ""
            deckLinkMessage = "DeckLink support is not compiled in. Add the Desktop Video SDK and rebuild.\(driver)"
        } else if let error = result.error {
            deckLinkMessage = error
        } else if result.devices.isEmpty {
            deckLinkMessage = "No DeckLink / UltraStudio devices found."
        } else {
            deckLinkMessage = nil
        }
    }

    func refreshNDI(preferences: AppPreferences) {
        do {
            try NDIRuntime.ensureLoaded(customPath: preferences.ndiLibraryPath)
            ndiMessage = "NDI \(NDIRuntime.version ?? "") — \(NDIRuntime.libraryPath ?? "")"
        } catch {
            ndiMessage = error.localizedDescription
        }
    }

    func refreshSyphon(preferences: AppPreferences) {
        do {
            try SyphonRuntime.ensureLoaded(customPath: preferences.syphonFrameworkPath)
            syphonMessage = "Syphon loaded — \(SyphonRuntime.loadedPath ?? "")"
        } catch {
            syphonMessage = error.localizedDescription
        }
    }
}

/// Shared app state: preferences, bookmarks, recent sessions, monitor and the open session.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var preferences: AppPreferences {
        didSet {
            guard preferences != oldValue else { return }
            savePreferences()
            if preferences.captureEngine != oldValue.captureEngine {
                session?.tabs.forEach { $0.restartCapture() }
            }
            if preferences.muteTabsNotLive != oldValue.muteTabsNotLive {
                session?.tabs.forEach { $0.applyMute() }
            }
            applyAudioPreferences()
            OSCController.shared.apply()
        }
    }

    func applyAudioPreferences() {
        AudioHub.shared.delayMs = preferences.audioDelayMs
        AudioHub.shared.source = preferences.audioSource
    }
    @Published var session: SessionController?
    @Published var screenCaptureGranted = ScreenCapturePermission.isGranted

    let bookmarks = BookmarkStore()
    let recents = RecentSessionsStore()
    let monitor = SystemMonitor()
    let devices = DeviceDiscovery()

    private var askedForScreenCapture = false

    private init() {
        preferences = (try? JSONFile.load(AppPreferences.self, from: AppPaths.preferencesURL)) ?? AppPreferences()
        monitor.webProcessIDs = { [weak self] in
            guard let tabs = self?.session?.tabs else { return [] }
            var pids = tabs.map(\.webProcessIdentifier)
            if let gpu = tabs.first?.gpuProcessIdentifier { pids.append(gpu) }
            return pids
        }
    }

    func savePreferences() {
        guard !SelfTest.isEnabled else { return }
        try? JSONFile.save(preferences, to: AppPaths.preferencesURL)
    }

    /// Returns true when ScreenCaptureKit can be used. Asks once per launch.
    func ensureScreenCapturePermission() -> Bool {
        if ScreenCapturePermission.isGranted {
            screenCaptureGranted = true
            return true
        }
        if !askedForScreenCapture {
            askedForScreenCapture = true
            screenCaptureGranted = ScreenCapturePermission.request()
            if !screenCaptureGranted {
                DispatchQueue.main.async { AppModel.showScreenCaptureHelp() }
            }
        }
        return screenCaptureGranted
    }

    static func showScreenCaptureHelp() {
        let alert = NSAlert()
        alert.messageText = "Allow Screen Recording for full-quality capture"
        alert.informativeText = """
        Broadcast Browser captures each tab's canvas with ScreenCaptureKit (GPU, up to 60 fps). macOS requires the Screen & System Audio Recording permission for that — only the app's own canvas windows are captured.

        Until it's granted, outputs use WebKit snapshots (about 25–30 fps). After allowing it in System Settings, quit and reopen Broadcast Browser.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Continue with Snapshots")
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenCapturePermission.openSystemSettings()
        }
    }
}
