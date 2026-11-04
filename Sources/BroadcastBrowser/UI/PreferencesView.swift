import AppKit
import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        TabView {
            GeneralPreferences()
                .tabItem { Label("General", systemImage: "gearshape") }
            VideoPreferences()
                .tabItem { Label("Video", systemImage: "film") }
            OutputPreferences(devices: app.devices)
                .tabItem { Label("Outputs", systemImage: "dot.radiowaves.left.and.right") }
            AudioPreferences()
                .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
            OSCPreferences(osc: OSCController.shared)
                .tabItem { Label("OSC", systemImage: "slider.horizontal.below.square.filled.and.square") }
            CapturePreferences()
                .tabItem { Label("Capture", systemImage: "camera.metering.matrix") }
        }
        .padding(16)
        .frame(width: 720, height: 600)
        .preferredColorScheme(.dark)
    }
}

struct GeneralPreferences: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
            Section("Browsing") {
                TextField("Home page", text: $app.preferences.homePage)
                Picker("Search engine", selection: $app.preferences.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show bookmarks bar", isOn: $app.preferences.showBookmarksBar)
            }
            Section("Sessions") {
                Picker("When the app opens", selection: $app.preferences.launchBehavior) {
                    ForEach(LaunchBehavior.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Keep a recovery autosave of unsaved sessions", isOn: $app.preferences.autosaveRecovery)
                Toggle("Confirm before closing a live tab or session", isOn: $app.preferences.confirmCloseWhileLive)
                LabeledContent("Sessions folder") {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppPaths.defaultSessionsDirectory) }
                }
                LabeledContent("Preferences file") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.preferencesURL]) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct VideoPreferences: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Enable PAL formats (25 / 50 fps, 576i/p)", isOn: $app.preferences.enablePALFormats)
            } header: {
                Text("Standards")
            } footer: {
                Text("NTSC-family rates (23.98, 24, 29.97, 30, 59.94, 60) are always available. Enabling PAL adds 25 and 50 fps and PAL SD.")
            }
            Section("Defaults for new tabs and outputs") {
                Picker("Canvas resolution", selection: $app.preferences.defaultCanvas) {
                    ForEach(ResolutionPreset.choices(includePAL: app.preferences.enablePALFormats)) { preset in
                        Text(preset.menuLabel).tag(preset.size)
                    }
                    if !ResolutionPreset.all.contains(where: { $0.size == app.preferences.defaultCanvas }) {
                        Text("Custom \(app.preferences.defaultCanvas.label)").tag(app.preferences.defaultCanvas)
                    }
                }
                Picker("Frame rate", selection: $app.preferences.defaultFrameRate) {
                    ForEach(FrameRate.choices(includePAL: app.preferences.enablePALFormats, including: app.preferences.defaultFrameRate)) { rate in
                        Text("\(rate.label) fps").tag(rate)
                    }
                }
                Picker("Scaling", selection: $app.preferences.defaultScaling) {
                    ForEach(ScalingMode.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Hide page scrollbars", isOn: $app.preferences.hideScrollbarsByDefault)
            }
        }
        .formStyle(.grouped)
    }
}

struct OutputPreferences: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var devices: DeviceDiscovery
    @State private var ndiSources: [String]?
    @State private var searching = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(devices.ndiMessage)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                HStack {
                    TextField("Runtime library (auto-detect)", text: $app.preferences.ndiLibraryPath)
                    Button("Choose…") {
                        if let path = choose(file: true) { app.preferences.ndiLibraryPath = path }
                    }
                }
                TextField("Default groups", text: $app.preferences.ndiDefaultGroups, prompt: Text("Public"))
                HStack {
                    Button(searching ? "Searching…" : "Find NDI Sources on Network") { findSources() }
                        .disabled(searching)
                    if let ndiSources {
                        Text(ndiSources.isEmpty ? "None found" : "\(ndiSources.count) found")
                            .foregroundStyle(.secondary)
                    }
                }
                if let ndiSources, !ndiSources.isEmpty {
                    Text(ndiSources.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("NDI®")
            } footer: {
                Text("Uses the NDI runtime from NDI Tools / the NDI SDK. Standard NDI sets its own bitrate (SpeedHQ); bandwidth is shown per output. NDI® is a registered trademark of Vizrt NDI AB.")
            }

            Section {
                LabeledContent("Status") {
                    Text(devices.syphonMessage)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.trailing)
                }
                HStack {
                    TextField("Syphon.framework (auto-detect)", text: $app.preferences.syphonFrameworkPath)
                    Button("Choose…") {
                        if let path = choose(file: false) { app.preferences.syphonFrameworkPath = path }
                    }
                }
            } header: {
                Text("Syphon")
            }

            Section {
                LabeledContent("Status") {
                    Text(devices.deckLinkMessage ?? "\(devices.deckLinkDevices.count) device(s)")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.trailing)
                }
                if let version = DeckLinkRuntime.driverVersion {
                    LabeledContent("Desktop Video", value: version)
                }
                ForEach(devices.deckLinkDevices) { device in
                    LabeledContent(device.name) {
                        Text("\(device.model) · \(device.modes.count) modes\(device.supportsPlayback ? "" : " · no playback")")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Rescan Devices") { devices.refreshDeckLink() }
            } header: {
                Text("Blackmagic DeckLink / UltraStudio")
            }

            Section("Recording") {
                HStack {
                    TextField("Folder", text: $app.preferences.recordingsFolder)
                    Button("Choose…") {
                        if let path = chooseFolder() { app.preferences.recordingsFolder = path }
                    }
                }
                Picker("Default codec", selection: $app.preferences.defaultRecordCodec) {
                    ForEach(RecordCodec.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Default bitrate") {
                    HStack {
                        Slider(value: $app.preferences.defaultRecordBitrateMbps, in: 2...100, step: 1)
                        Text("\(Int(app.preferences.defaultRecordBitrateMbps)) Mbps").monospacedDigit().frame(width: 70)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: app.preferences.ndiLibraryPath) { _, _ in devices.refreshNDI(preferences: app.preferences) }
        .onChange(of: app.preferences.syphonFrameworkPath) { _, _ in devices.refreshSyphon(preferences: app.preferences) }
    }

    private func findSources() {
        searching = true
        devices.refreshNDI(preferences: app.preferences)
        DispatchQueue.global(qos: .userInitiated).async {
            let found = NDIRuntime.isLoaded ? NDIRuntime.findSources(waitMs: 3000) : []
            DispatchQueue.main.async {
                ndiSources = found
                searching = false
            }
        }
    }

    private func choose(file: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = !file
        panel.treatsFilePackagesAsDirectories = file
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

struct CapturePreferences: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Capture engine", selection: $app.preferences.captureEngine) {
                    ForEach(CaptureEngine.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Screen Recording") {
                    HStack {
                        Text(app.screenCaptureGranted ? "Allowed" : "Not allowed")
                            .foregroundStyle(app.screenCaptureGranted ? Color.green : Color.orange)
                        Button("Open System Settings") { ScreenCapturePermission.openSystemSettings() }
                    }
                }
            } header: {
                Text("Capture")
            } footer: {
                Text("ScreenCaptureKit captures only Broadcast Browser's own canvas windows, on the GPU, at up to 60 fps. It needs the Screen & System Audio Recording permission (relaunch after granting).")
            }
            Section {
                Picker("Editing a live tab", selection: $app.preferences.liveEditBehavior) {
                    ForEach(LiveEditBehavior.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Edit Mode")
            } footer: {
                Text("Edit Mode turns on the element picker, style editing and the Web Inspector. Going live always leaves Edit Mode first, so inspector highlights never reach air.")
            }
            Section {
                Toggle("Prevent sleep and App Nap while live", isOn: $app.preferences.preventSleepWhileLive)
            } header: {
                Text("Background rendering")
            } footer: {
                Text("Every tab renders in its own hidden canvas window, so it stays on air while you work in another tab. The canvas you see in the browser window is the captured picture — exactly what the outputs receive.")
            }
            Section {
                Button("Reset All Preferences…") {
                    let alert = NSAlert()
                    alert.messageText = "Reset all preferences to their defaults?"
                    alert.addButton(withTitle: "Reset")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn { app.preferences = AppPreferences() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { app.screenCaptureGranted = ScreenCapturePermission.isGranted }
    }
}

struct AudioPreferences: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var monitor = AppModel.shared.monitor

    var body: some View {
        let status = AudioHub.shared.status()
        Form {
            Section {
                Picker("Source", selection: $app.preferences.audioSource) {
                    ForEach(AudioSource.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Status") {
                    Text(status.consumers == 0 ? "Idle — no output has audio enabled" : status.text)
                        .font(.system(size: 11))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Level") {
                    AudioMeter(left: status.peakLdB, right: status.peakRdB)
                        .frame(width: 220)
                }
            } header: {
                Text("Audio")
            } footer: {
                Text("Audio is off for every output until you enable it on that output (NDI, DeckLink and Record). macOS plays all tabs through one WebKit audio engine, so outputs carry the mix of every unmuted tab — mute tabs you don't want on air. Website audio uses the Screen & System Audio Recording permission.")
            }
            Section {
                Toggle("Mute tabs that aren't live", isOn: $app.preferences.muteTabsNotLive)
                LabeledContent("Audio delay") {
                    HStack {
                        Slider(value: Binding(get: { Double(app.preferences.audioDelayMs) },
                                              set: { app.preferences.audioDelayMs = Int($0) }), in: 0...500, step: 10)
                        Text("\(app.preferences.audioDelayMs) ms").monospacedDigit().frame(width: 60)
                    }
                }
            } header: {
                Text("Mix & sync")
            } footer: {
                Text("Format: 48 kHz stereo. NDI sends 32-bit float, DeckLink embeds 2 channels of 24-bit audio in 32-bit words, recordings use AAC (MP4) or 24-bit PCM (MOV). Increase the delay if audio arrives before the picture; it applies to outputs started afterwards.")
            }
        }
        .formStyle(.grouped)
    }
}

struct AudioMeter: View {
    let left: Double
    let right: Double

    var body: some View {
        VStack(spacing: 3) {
            bar(left, label: "L")
            bar(right, label: "R")
        }
    }

    private func bar(_ db: Double, label: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 8)
            GeometryReader { proxy in
                let fraction = max(0, min(1, (db + 60) / 60))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(db > -6 ? ChartPalette.critical : (db > -18 ? ChartPalette.warning : ChartPalette.good))
                        .frame(width: max(2, proxy.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text(db <= -89 ? "−∞" : String(format: "%.0f", db))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 26, alignment: .trailing)
        }
    }
}

struct OSCPreferences: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var osc: OSCController
    @State private var portDraft = ""
    @State private var portMessage = ""
    @State private var portOK = true

    var body: some View {
        Form {
            Section {
                Toggle("Receive OSC commands", isOn: $app.preferences.oscEnabled)
                LabeledContent("Input port (UDP)") {
                    HStack {
                        TextField("", text: $portDraft)
                            .frame(width: 70)
                            .onSubmit(applyPort)
                        Button("Check & Apply", action: applyPort)
                    }
                }
                if !portMessage.isEmpty {
                    Label(portMessage, systemImage: portOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(portOK ? Color.green : Color.red)
                        .font(.system(size: 11))
                }
                LabeledContent("Status") {
                    Text(osc.status)
                        .font(.system(size: 11))
                        .foregroundStyle(osc.statusIsError ? Color.red : Color.secondary)
                        .multilineTextAlignment(.trailing)
                }
                TextField("Accept from (IP addresses, empty = anyone)", text: $app.preferences.oscAllowedSenders)
                Toggle("Allow /js and /css commands (runs code in your pages)", isOn: $app.preferences.oscAllowScripting)
            } header: {
                Text("Input")
            } footer: {
                Text("Default port 9300. The port is checked before it's used; pick another if another app owns it. OSC has no authentication — use the allow-list on shared networks.")
            }

            Section {
                Toggle("Send status feedback", isOn: $app.preferences.oscFeedbackEnabled)
                TextField("Destination host", text: $app.preferences.oscFeedbackHost)
                LabeledContent("Destination port (UDP)") {
                    IntField(value: $app.preferences.oscFeedbackPort, range: 1...65535, width: 70)
                }
                Picker("Interval", selection: $app.preferences.oscFeedbackIntervalMs) {
                    Text("4× per second").tag(250)
                    Text("2× per second").tag(500)
                    Text("Every second").tag(1000)
                    Text("Every 2 seconds").tag(2000)
                    Text("Every 5 seconds").tag(5000)
                }
                Picker("True/false values", selection: $app.preferences.oscBooleanStyle) {
                    ForEach(OSCBooleanStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Pack messages into OSC bundles", isOn: $app.preferences.oscUseBundles)
                if app.preferences.oscFeedbackPort == app.preferences.oscInputPort
                    && ["127.0.0.1", "localhost"].contains(app.preferences.oscFeedbackHost) {
                    Label("Feedback is pointed at this app's own input port.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 11))
                }
                HStack {
                    Button("Send Test Message") { osc.sendTestMessage() }
                    Button("Send Full Status Now") { osc.sendFeedback() }
                }
            } header: {
                Text("Feedback output")
            } footer: {
                Text("Default 127.0.0.1:9301. Receivers can also register themselves with /bb/feedback/subscribe. State changes (a tab going live or stopping, output errors) are sent immediately as events.")
            }

            Section("Activity") {
                LabeledContent("Messages received", value: "\(osc.messagesReceived)")
                LabeledContent("Messages sent", value: "\(osc.messagesSent)")
                if osc.messagesRejected > 0 {
                    LabeledContent("Rejected (not on allow-list)", value: "\(osc.messagesRejected)")
                }
                if !osc.subscribers.isEmpty {
                    LabeledContent("Subscribers", value: osc.subscribers.map(\.id).joined(separator: ", "))
                }
                LabeledContent("Last command") {
                    Text(osc.lastCommand.isEmpty ? "—" : osc.lastCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Button("Open OSC Reference") { OSCReference.open() }
            }
        }
        .formStyle(.grouped)
        .onAppear { portDraft = String(app.preferences.oscInputPort) }
    }

    private func applyPort() {
        guard let port = Int(portDraft.trimmingCharacters(in: .whitespaces)) else {
            portOK = false
            portMessage = "Enter a number between 1024 and 65535."
            return
        }
        switch osc.check(port: port) {
        case .invalid:
            portOK = false
            portMessage = "Use a port between 1024 and 65535."
        case .inUse:
            portOK = false
            portMessage = "UDP \(port) is already in use by another application. Choose a different port."
        case .inUseByThisApp:
            portOK = true
            portMessage = "Already listening on UDP \(port)."
        case .available:
            portOK = true
            portMessage = "UDP \(port) is free — now listening on it."
            app.preferences.oscInputPort = port
        }
    }
}

/// Opens the bundled OSC reference (docs/OSC.md rendered to HTML at build time).
enum OSCReference {
    @MainActor static func open() {
        if let url = Bundle.main.url(forResource: "OSC", withExtension: "html") {
            NSWorkspace.shared.open(url)
        } else {
            let alert = NSAlert()
            alert.messageText = "OSC reference not bundled"
            alert.informativeText = "This build has no OSC.html. See docs/OSC.md in the project folder."
            alert.runModal()
        }
    }
}
