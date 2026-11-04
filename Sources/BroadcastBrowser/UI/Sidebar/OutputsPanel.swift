import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var session: SessionController

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $session.sidebarPanel) {
                ForEach(SidebarPanel.allCases) { panel in
                    Text(panel.label).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            if let tab = session.selectedTab {
                switch session.sidebarPanel {
                case .outputs: OutputsPanel(tab: tab)
                case .customize: CustomizePanel(tab: tab)
                case .page: PagePanel(tab: tab)
                }
            } else {
                Spacer()
            }
        }
        .background(Color.bbPanel)
    }
}

// MARK: - Outputs panel

struct OutputsPanel: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var app: AppModel
    @State private var expanded: Set<UUID> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                liveCard
                CanvasSettings(tab: tab)
                PanelSection("Outputs", accessory: { addMenu }) {
                    if tab.outputs.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No outputs yet.")
                                .font(.system(size: 12, weight: .medium))
                            Text("Add NDI or Syphon for IP video, DeckLink for SDI/HDMI hardware, a Display for a projector or HDMI port, or Record to File. A tab can feed several outputs at once.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .card()
                    }
                    ForEach($tab.outputs) { $config in
                        OutputCard(tab: tab, config: $config, expanded: Binding(
                            get: { expanded.contains(config.id) },
                            set: { isOpen in
                                if isOpen { expanded.insert(config.id) } else { expanded.remove(config.id) }
                            }))
                    }
                }
            }
            .padding(12)
        }
    }

    private var liveCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                let active = tab.runtimes.values.filter { $0.status.isActive }.count
                Text(tab.isLive ? "\(active) of \(tab.outputs.count) outputs live" : "\(tab.outputs.count) output\(tab.outputs.count == 1 ? "" : "s") configured")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            GoLiveButton(tab: tab)
        }
        .card(highlighted: tab.isLive)
    }

    private var addMenu: some View {
        Menu {
            ForEach(OutputKind.allCases) { kind in
                Button {
                    let config = tab.addOutput(kind: kind)
                    expanded.insert(config.id)
                } label: {
                    Label(kind.label, systemImage: kind.symbol)
                }
            }
        } label: {
            Label("Add", systemImage: "plus")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

struct CanvasSettings: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var app: AppModel

    var body: some View {
        PanelSection("Canvas") {
            VStack(alignment: .leading, spacing: 8) {
                FieldRow(label: "Resolution") {
                    ResolutionPicker(size: $tab.canvasSize, includePAL: app.preferences.enablePALFormats)
                }
                FieldRow(label: "Background") {
                    Toggle("Transparent (alpha)", isOn: $tab.transparentBackground)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .help("Removes the page background so NDI (with alpha) and Syphon carry transparency for keying.")
                }
                Text("The page is laid out at exactly \(tab.canvasSize.label) CSS pixels (at 100% zoom) and rendered 1:1 — what you see in the canvas is what goes to air.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .card()
        }
    }
}

struct ResolutionPicker: View {
    @Binding var size: PixelSize
    let includePAL: Bool

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(ResolutionPreset.choices(includePAL: includePAL)) { preset in
                    Button(preset.menuLabel) { size = preset.size }
                }
            } label: {
                Text(presetName)
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 4)
            IntField(value: $size.width, width: 52)
            Text("×").font(.system(size: 11)).foregroundStyle(.secondary)
            IntField(value: $size.height, width: 52)
        }
    }

    private var presetName: String {
        ResolutionPreset.all.first { $0.size == size }?.name ?? "Custom"
    }
}

// MARK: - Output card

struct OutputCard: View {
    @ObservedObject var tab: BrowserTab
    @Binding var config: OutputConfig
    @Binding var expanded: Bool
    @EnvironmentObject var app: AppModel
    /// Re-renders once per second so live stats stay current.
    @ObservedObject private var monitor = AppModel.shared.monitor

    var body: some View {
        let runtime = tab.runtime(for: config.id)
        let snapshot = runtime?.stats.snapshot()
        let status = snapshot?.status ?? .idle
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: config.kind.symbol)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(status == .live ? Color.bbLive : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(config.name.isEmpty ? config.kind.shortLabel : config.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text("\(config.kind.shortLabel) · \(config.formatSummary)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                StatusDot(status: status)
                Button {
                    tab.toggleOutput(config.id)
                } label: {
                    Image(systemName: status.isActive ? "stop.fill" : "play.fill")
                        .font(.system(size: 10))
                        .frame(width: 24, height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(status.isActive ? Color.bbLive : Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help(status.isActive ? "Stop this output" : "Start this output")
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 22)
                }
                .buttonStyle(.plain)
            }

            if let message = status.errorMessage {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let snapshot, snapshot.status == .live {
                OutputStatsLine(config: config, stats: snapshot)
            }

            if tab.needsRestart(config) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Settings changed while live.")
                    Spacer()
                    Button("Restart Output") { tab.restartOutput(config.id) }
                        .controlSize(.small)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.yellow)
            }

            if expanded {
                Divider()
                OutputEditor(tab: tab, config: $config)
                HStack {
                    Toggle("Start with Go Live", isOn: $config.autoStart)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                    Spacer()
                    Button(role: .destructive) {
                        tab.removeOutput(config.id)
                    } label: {
                        Label("Remove", systemImage: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .card(highlighted: status == .live)
    }
}

struct OutputStatsLine: View {
    let config: OutputConfig
    let stats: OutputStatsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(formatDuration(stats.uptime))
                Text(String(format: "%.2f fps", stats.measuredFPS))
                Text("\(stats.framesSent) frames")
                if stats.framesDropped > 0 || stats.framesLate > 0 {
                    Text("\(stats.framesDropped + stats.framesLate) dropped/late")
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 10) {
                switch config.kind {
                case .ndi:
                    Text(stats.connections < 0 ? "Receivers —" : "\(stats.connections) receiver\(stats.connections == 1 ? "" : "s")")
                    if stats.tallyProgram {
                        Text("PROGRAM").foregroundStyle(Color.bbLive).fontWeight(.bold)
                    } else if stats.tallyPreview {
                        Text("PREVIEW").foregroundStyle(.green).fontWeight(.bold)
                    }
                    Text(String(format: "≈%.0f Mbps", config.estimatedNDIMbps))
                case .syphon:
                    Text(stats.connections > 0 ? "Client connected" : "No clients")
                case .decklink:
                    if stats.bufferedFrames >= 0 { Text("Buffered \(stats.bufferedFrames)") }
                case .record:
                    Text(stats.detail).lineLimit(1).truncationMode(.middle)
                case .display:
                    Text(stats.detail).lineLimit(1)
                }
            }
        }
        .font(.system(size: 10.5).monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

// MARK: - Output editor

struct OutputEditor: View {
    @ObservedObject var tab: BrowserTab
    @Binding var config: OutputConfig
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if config.kind != .display && config.kind != .decklink {
                FieldRow(label: config.kind == .ndi ? "NDI name" : (config.kind == .syphon ? "Server name" : "Name")) {
                    TextField("Name", text: $config.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
            }

            switch config.kind {
            case .decklink:
                DeckLinkEditor(config: $config, devices: app.devices)
            case .display:
                DisplayEditor(config: $config, devices: app.devices)
            default:
                FieldRow(label: "Resolution") {
                    ResolutionPicker(size: $config.size, includePAL: app.preferences.enablePALFormats)
                }
                FieldRow(label: "Frame rate") {
                    FrameRatePicker(rate: $config.frameRate, includePAL: app.preferences.enablePALFormats)
                }
            }

            if config.kind != .display {
                FieldRow(label: "Scaling") {
                    Picker("", selection: $config.scaling) {
                        ForEach(ScalingMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }

            CropEditor(tab: tab, config: $config)

            if config.supportsAudio {
                FieldRow(label: "Audio") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(audioLabel, isOn: $config.audioEnabled)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11))
                        if config.audioEnabled {
                            Text("Source: \(app.preferences.audioSource.label). Change it in Preferences › Audio.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            switch config.kind {
            case .ndi:
                FieldRow(label: "Groups") {
                    TextField("Public (default)", text: $config.ndiGroups)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
                FieldRow(label: "Alpha") {
                    Toggle("Send alpha channel (BGRA)", isOn: $config.ndiAlpha)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }
                FieldRow(label: "Bandwidth") {
                    Text(String(format: "≈ %.0f Mbps (NDI High Bandwidth, set by the NDI codec)", config.estimatedNDIMbps))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .syphon:
                FieldRow(label: "Orientation") {
                    Toggle("Flip vertically", isOn: $config.syphonFlipped)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }
                Text("Syphon shares GPU textures with apps on this Mac (no compression, so no bitrate).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .record:
                RecordEditor(config: $config)
            case .decklink, .display:
                EmptyView()
            }
        }
    }
}

extension OutputEditor {
    var audioLabel: String {
        switch config.kind {
        case .ndi: return "Send audio (48 kHz stereo)"
        case .decklink: return "Embed audio (48 kHz, 2 ch, 24-bit in 32)"
        case .record: return config.codec.usesBitrate ? "Record audio (AAC)" : "Record audio (24-bit PCM)"
        default: return "Audio"
        }
    }
}

/// Crops a region of the canvas for one output (shown as a pink guide on the canvas, never on air).
struct CropEditor: View {
    @ObservedObject var tab: BrowserTab
    @Binding var config: OutputConfig

    var body: some View {
        FieldRow(label: "Crop") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Crop the canvas", isOn: Binding(
                    get: { config.cropEnabled },
                    set: { enabled in
                        if enabled && !config.cropEnabled && (config.cropWidth < 16 || config.cropHeight < 16) {
                            config.cropX = 0
                            config.cropY = 0
                            config.cropWidth = tab.canvasSize.width
                            config.cropHeight = tab.canvasSize.height
                        }
                        config.cropEnabled = enabled
                    }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                if config.cropEnabled {
                    HStack(spacing: 4) {
                        Text("X").font(.system(size: 10)).foregroundStyle(.secondary)
                        IntField(value: $config.cropX, range: 0...8192, width: 48)
                        Text("Y").font(.system(size: 10)).foregroundStyle(.secondary)
                        IntField(value: $config.cropY, range: 0...8192, width: 48)
                    }
                    HStack(spacing: 4) {
                        Text("W").font(.system(size: 10)).foregroundStyle(.secondary)
                        IntField(value: $config.cropWidth, range: 16...8192, width: 48)
                        Text("H").font(.system(size: 10)).foregroundStyle(.secondary)
                        IntField(value: $config.cropHeight, range: 16...8192, width: 48)
                    }
                    HStack(spacing: 6) {
                        Button("Selected Element") {
                            if let rect = tab.pickedCanvasRect { tab.cropOutput(config.id, to: rect) }
                        }
                        .disabled(tab.pickedCanvasRect == nil)
                        .help("Pick an element in Edit Mode first")
                        Button("Match Output Shape") { matchAspect() }
                            .help("Adjust the crop height so it has the same shape as the output — no letterboxing")
                        Button("Full") {
                            config.cropX = 0
                            config.cropY = 0
                            config.cropWidth = tab.canvasSize.width
                            config.cropHeight = tab.canvasSize.height
                        }
                    }
                    .controlSize(.mini)
                    Text("Canvas pixels. The region is scaled to \(config.width)×\(config.height) using “\(config.scaling.label)”. A pink guide marks it on the canvas (never on air).")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func matchAspect() {
        guard config.height > 0, config.cropWidth > 0 else { return }
        let target = Double(config.width) / Double(config.height)
        let centerY = Double(config.cropY) + Double(config.cropHeight) / 2
        var height = Double(config.cropWidth) / target
        var width = Double(config.cropWidth)
        if height > Double(tab.canvasSize.height) {
            height = Double(tab.canvasSize.height)
            width = height * target
        }
        config.cropHeight = Int(height.rounded())
        config.cropWidth = Int(width.rounded())
        config.cropY = max(0, min(tab.canvasSize.height - config.cropHeight, Int((centerY - height / 2).rounded())))
    }
}

struct FrameRatePicker: View {
    @Binding var rate: FrameRate
    let includePAL: Bool

    var body: some View {
        Picker("", selection: $rate) {
            ForEach(FrameRate.choices(includePAL: includePAL, including: rate)) { rate in
                Text("\(rate.label) fps").tag(rate)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .frame(maxWidth: 140)
    }
}

struct DeckLinkEditor: View {
    @Binding var config: OutputConfig
    @ObservedObject var devices: DeviceDiscovery
    @EnvironmentObject var app: AppModel

    private var device: DeckLinkDeviceInfo? {
        devices.deckLinkDevices.first { $0.matches(config) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = devices.deckLinkMessage {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FieldRow(label: "Device") {
                HStack {
                    Picker("", selection: Binding(
                        get: { device?.id ?? "" },
                        set: { id in
                            if let chosen = devices.deckLinkDevices.first(where: { $0.id == id }) {
                                config.deckLinkPersistentID = chosen.persistentID
                                config.deckLinkDeviceName = chosen.name
                                config.name = chosen.name
                            }
                        })) {
                        if device == nil {
                            Text(config.deckLinkDeviceName.isEmpty ? "Choose…" : "\(config.deckLinkDeviceName) (offline)").tag("")
                        }
                        ForEach(devices.deckLinkDevices.filter(\.supportsPlayback)) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    Button {
                        devices.refreshDeckLink()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Rescan DeckLink devices")
                }
            }
            FieldRow(label: "Video mode") {
                if let device {
                    let modes = device.modes.filter { mode in
                        guard let rate = mode.frameRate else { return false }
                        return app.preferences.enablePALFormats || !rate.isPAL || (mode.size == config.size && rate == config.frameRate)
                    }
                    Picker("", selection: Binding(
                        get: { device.mode(for: config)?.modeID ?? 0 },
                        set: { id in
                            if let mode = device.modes.first(where: { $0.modeID == id }), let rate = mode.frameRate {
                                config.size = mode.size
                                config.frameRate = rate
                                config.interlaced = mode.interlaced
                                config.deckLinkModeName = mode.name
                            }
                        })) {
                        if device.mode(for: config) == nil { Text("Choose…").tag(UInt32(0)) }
                        ForEach(modes) { mode in
                            Text(mode.label).tag(mode.modeID)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                } else {
                    Text(config.formatSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct DisplayEditor: View {
    @Binding var config: OutputConfig
    @ObservedObject var devices: DeviceDiscovery

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldRow(label: "Display") {
                Picker("", selection: Binding(
                    get: { config.displayID },
                    set: { id in
                        config.displayID = id
                        if let screen = devices.screens.first(where: { $0.id == id }) {
                            config.displayName = screen.name
                            config.size = screen.pixelSize
                            config.name = screen.name
                        }
                    })) {
                    if !devices.screens.contains(where: { $0.id == config.displayID }) {
                        Text(config.displayName.isEmpty ? "Choose…" : "\(config.displayName) (disconnected)").tag(config.displayID)
                    }
                    ForEach(devices.screens) { screen in
                        Text("\(screen.name) — \(screen.pixelSize.label)\(screen.isMain ? " (main)" : "")").tag(screen.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            FieldRow(label: "Scaling") {
                Picker("", selection: $config.scaling) {
                    ForEach(ScalingMode.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            Text("Fills the chosen screen (projector, TV, HDMI/USB-C port) and refreshes in sync with it. Choosing the screen this window is on will cover it — press the output's stop button or ⌥⇧⌘↩ to stop.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct RecordEditor: View {
    @Binding var config: OutputConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldRow(label: "Codec") {
                Picker("", selection: $config.codec) {
                    ForEach(RecordCodec.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
            }
            if config.codec.usesBitrate && config.audioEnabled {
                FieldRow(label: "Audio bitrate") {
                    Picker("", selection: $config.audioBitrateKbps) {
                        Text("128 kbps").tag(128)
                        Text("192 kbps").tag(192)
                        Text("256 kbps").tag(256)
                        Text("320 kbps").tag(320)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
            if config.codec.usesBitrate {
                FieldRow(label: "Bitrate") {
                    HStack(spacing: 6) {
                        Slider(value: $config.bitrateMbps, in: 2...100, step: 1)
                            .controlSize(.small)
                        Text("\(Int(config.bitrateMbps)) Mbps")
                            .font(.system(size: 11).monospacedDigit())
                            .frame(width: 62, alignment: .trailing)
                    }
                }
                FieldRow(label: "Keyframes") {
                    Picker("", selection: $config.keyframeIntervalSeconds) {
                        Text("Every 1 s").tag(1.0)
                        Text("Every 2 s").tag(2.0)
                        Text("Every 4 s").tag(4.0)
                        Text("Every 10 s").tag(10.0)
                    }
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
            FieldRow(label: "Folder") {
                HStack {
                    Text(config.recordFolder.isEmpty ? "Default" : (config.recordFolder as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { config.recordFolder = url.path }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
