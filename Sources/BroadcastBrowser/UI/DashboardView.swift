import Charts
import SwiftUI

/// Chart colors: reference categorical slots 1–2 (dark steps), validated
/// against the dark card surface with the data-viz palette checker.
enum ChartPalette {
    static let series1 = Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xE5 / 255) // blue
    static let series2 = Color(red: 0xD9 / 255, green: 0x59 / 255, blue: 0x26 / 255) // orange
    static let good = Color(red: 0x0C / 255, green: 0xA3 / 255, blue: 0x0C / 255)
    static let warning = Color(red: 0xFA / 255, green: 0xB2 / 255, blue: 0x19 / 255)
    static let serious = Color(red: 0xEC / 255, green: 0x83 / 255, blue: 0x5A / 255)
    static let critical = Color(red: 0xD0 / 255, green: 0x3B / 255, blue: 0x3B / 255)
    static let grid = Color.white.opacity(0.07)
}

struct DashboardView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        DashboardContent(monitor: app.monitor, session: app.session)
            .preferredColorScheme(.dark)
    }
}

struct DashboardContent: View {
    @ObservedObject var monitor: SystemMonitor
    let session: SessionController?
    @State private var showAllPreviews = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let session {
                    SessionHeader(session: session)
                } else {
                    Text("No session open").font(.system(size: 20, weight: .semibold))
                }
                kpiRow
                charts
                if let session {
                    multiview(session)
                    OutputsTable(session: session, tick: monitor.tick)
                }
            }
            .padding(20)
        }
        .background(Color.bbChrome)
    }

    // MARK: KPI tiles

    private var kpiRow: some View {
        let sample = monitor.latest
        let cores = Double(max(1, monitor.coreCount))
        let appCPU = (sample?.appCPU ?? 0) + (sample?.webCPU ?? 0)
        let memoryMB = (sample?.appMemoryMB ?? 0) + (sample?.webMemoryMB ?? 0)
        let usedGB = Double(monitor.systemMemoryUsed) / 1_073_741_824
        let totalGB = Double(monitor.systemMemoryTotal) / 1_073_741_824
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            StatTile(title: "Broadcast Browser CPU",
                     value: String(format: "%.0f%%", appCPU),
                     detail: String(format: "%.1f%% of this Mac · app + WebKit", appCPU / cores))
            StatTile(title: "System CPU",
                     value: String(format: "%.0f%%", sample?.systemCPU ?? 0),
                     detail: "\(monitor.coreCount) cores")
            StatTile(title: "GPU",
                     value: sample.map { String(format: "%.0f%%", $0.gpu) } ?? "—",
                     detail: "Device utilization")
            StatTile(title: "Memory (app + WebKit)",
                     value: memoryMB >= 1024 ? String(format: "%.2f GB", memoryMB / 1024) : String(format: "%.0f MB", memoryMB),
                     detail: String(format: "App %.0f MB · Web %.0f MB", sample?.appMemoryMB ?? 0, sample?.webMemoryMB ?? 0))
            MeterTile(title: "System memory",
                      value: String(format: "%.1f / %.0f GB", usedGB, totalGB),
                      fraction: totalGB > 0 ? usedGB / totalGB : 0)
            StatTile(title: "Network out",
                     value: String(format: "%.1f Mbps", sample?.networkOutMbps ?? 0),
                     detail: String(format: "In %.1f Mbps", sample?.networkInMbps ?? 0))
            ThermalTile(state: monitor.thermalState)
            AudioTile(tick: monitor.tick)
            OSCTile(osc: OSCController.shared)
        }
    }

    // MARK: Charts

    private var charts: some View {
        let cores = Double(max(1, monitor.coreCount))
        let history = monitor.history
        let cpuPoints = history.flatMap { sample in
            [ChartPoint(time: sample.time, value: (sample.appCPU + sample.webCPU) / cores, series: "Broadcast Browser"),
             ChartPoint(time: sample.time, value: sample.systemCPU, series: "Whole Mac")]
        }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            HoverLineChart(title: "CPU — % of this Mac",
                           series: [("Broadcast Browser", ChartPalette.series1), ("Whole Mac", ChartPalette.series2)],
                           points: cpuPoints, yMax: 100, format: { String(format: "%.1f%%", $0) })
            HoverLineChart(title: "GPU utilization",
                           series: [("GPU", ChartPalette.series1)],
                           points: history.map { ChartPoint(time: $0.time, value: $0.gpu, series: "GPU") },
                           yMax: 100, format: { String(format: "%.0f%%", $0) })
            HoverLineChart(title: "Memory — app + WebKit (MB)",
                           series: [("Memory", ChartPalette.series1)],
                           points: history.map { ChartPoint(time: $0.time, value: $0.appMemoryMB + $0.webMemoryMB, series: "Memory") },
                           yMax: nil, format: { String(format: "%.0f MB", $0) })
            HoverLineChart(title: "Network out (Mbps) — NDI traffic",
                           series: [("Network out", ChartPalette.series1)],
                           points: history.map { ChartPoint(time: $0.time, value: $0.networkOutMbps, series: "Network out") },
                           yMax: nil, format: { String(format: "%.1f Mbps", $0) })
        }
    }

    // MARK: Multiview

    @ViewBuilder
    private func multiview(_ session: SessionController) -> some View {
        let tabs = showAllPreviews ? session.tabs : session.tabs.filter { $0.isLive }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Multiview").font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("Show tabs that are not live", isOn: $showAllPreviews)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .help("Previewing a tab that is not live starts capturing it, which uses some CPU/GPU.")
            }
            if tabs.isEmpty {
                Text("No live tabs. Go live from a tab's Outputs panel (⌘↩) or Broadcast › Go Live — All Tabs.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .card()
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(tabs) { tab in
                        MultiviewTile(tab: tab, tick: monitor.tick)
                    }
                }
            }
        }
    }
}

struct ChartPoint: Identifiable {
    let time: Date
    let value: Double
    let series: String
    var id: String { "\(series)-\(time.timeIntervalSinceReferenceDate)" }
}

// MARK: - Header

struct SessionHeader: View {
    @ObservedObject var session: SessionController

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name).font(.system(size: 20, weight: .semibold))
                Text("\(session.tabs.count) tab\(session.tabs.count == 1 ? "" : "s") · \(session.liveOutputCount) output\(session.liveOutputCount == 1 ? "" : "s") live · opened \(session.openedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.liveSince == nil ? "OFF AIR" : "ON AIR")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(session.liveSince == nil ? Color.secondary : Color.bbLive)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(session.liveSince.map { formatDuration(context.date.timeIntervalSince($0)) } ?? "--:--:--")
                        .font(.system(size: 48, weight: .semibold).monospacedDigit())
                        .foregroundStyle(session.liveSince == nil ? Color.secondary : Color.primary)
                }
            }
            VStack(spacing: 6) {
                Button {
                    session.goLiveAll()
                } label: {
                    Label("Go Live — All", systemImage: "dot.radiowaves.left.and.right")
                        .frame(width: 130)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.bbLive)
                Button {
                    session.stopAll()
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                        .frame(width: 130)
                }
                .controlSize(.large)
                .disabled(session.liveSince == nil)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.bbCard))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(session.liveSince == nil ? Color.white.opacity(0.06) : Color.bbLive.opacity(0.8), lineWidth: 1.5))
    }
}

// MARK: - Tiles

struct StatTile: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 22, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .card()
    }
}

struct MeterTile: View {
    let title: String
    let value: String
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(ChartPalette.series1.opacity(0.22))
                    Capsule().fill(ChartPalette.series1)
                        .frame(width: max(4, proxy.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 6)
            .help(String(format: "%.0f%% used", fraction * 100))
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .card()
    }
}

struct AudioTile: View {
    let tick: Int

    var body: some View {
        let status = AudioHub.shared.status()
        VStack(alignment: .leading, spacing: 6) {
            Text("Audio").font(.system(size: 11)).foregroundStyle(.secondary)
            if status.consumers == 0 {
                Text("Off").font(.system(size: 18, weight: .semibold))
                Text("No output has audio enabled").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            } else {
                AudioMeter(left: status.peakLdB, right: status.peakRdB)
                Text("\(status.source == .testTone ? "Test tone" : "Website audio") → \(status.consumers) output\(status.consumers == 1 ? "" : "s")")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .card()
    }
}

struct OSCTile: View {
    @ObservedObject var osc: OSCController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OSC").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: osc.listeningPort != nil ? "checkmark.circle.fill" : (osc.statusIsError ? "exclamationmark.triangle.fill" : "minus.circle"))
                    .foregroundStyle(osc.listeningPort != nil ? ChartPalette.good : (osc.statusIsError ? ChartPalette.warning : Color.secondary))
                Text(osc.listeningPort.map { "UDP \($0)" } ?? "Off")
            }
            .font(.system(size: 18, weight: .semibold))
            Text("\(osc.messagesReceived) in · \(osc.messagesSent) out")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .card()
        .help(osc.status)
    }
}

struct ThermalTile: View {
    let state: ProcessInfo.ThermalState

    private var style: (Color, String) {
        switch state {
        case .nominal: return (ChartPalette.good, "checkmark.circle.fill")
        case .fair: return (ChartPalette.warning, "exclamationmark.triangle.fill")
        case .serious: return (ChartPalette.serious, "exclamationmark.triangle.fill")
        case .critical: return (ChartPalette.critical, "xmark.octagon.fill")
        @unknown default: return (Color.secondary, "questionmark.circle")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Thermal state").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: style.1).foregroundStyle(style.0)
                Text(state.label)
            }
            .font(.system(size: 20, weight: .semibold))
            Text(state == .nominal ? "No throttling" : "macOS may throttle performance")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .card()
    }
}

// MARK: - Line chart with hover readout

struct HoverLineChart: View {
    let title: String
    let series: [(name: String, color: Color)]
    let points: [ChartPoint]
    let yMax: Double?
    let format: (Double) -> String
    @State private var hoverTime: Date?
    @State private var hoverX: CGFloat = 0

    private var upperBound: Double {
        if let yMax { return yMax }
        let peak = points.map(\.value).max() ?? 0
        return max(1, peak * 1.2)
    }

    private func values(at time: Date) -> [(String, Double)] {
        series.compactMap { entry in
            let candidates = points.filter { $0.series == entry.name }
            guard let nearest = candidates.min(by: { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }) else { return nil }
            return (entry.name, nearest.value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if series.count > 1 {
                    ForEach(series, id: \.name) { entry in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1).fill(entry.color).frame(width: 10, height: 2)
                            Text(entry.name).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        }
                    }
                } else if let last = points.last {
                    Text(format(last.value)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            chart
                .frame(height: 140)
        }
        .card()
    }

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                LineMark(x: .value("Time", point.time),
                         y: .value("Value", point.value),
                         series: .value("Series", point.series))
                    .foregroundStyle(by: .value("Series", point.series))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if series.count > 1 {
                ForEach(series, id: \.name) { entry in
                    if let last = points.last(where: { $0.series == entry.name }) {
                        PointMark(x: .value("Time", last.time), y: .value("Value", last.value))
                            .foregroundStyle(entry.color)
                            .symbolSize(30)
                            .annotation(position: .topLeading, spacing: 2) {
                                Text(entry.name).font(.system(size: 9.5)).foregroundStyle(.secondary)
                            }
                    }
                }
            }
            if let hoverTime {
                RuleMark(x: .value("Time", hoverTime))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                ForEach(series, id: \.name) { entry in
                    if let nearest = points.filter({ $0.series == entry.name })
                        .min(by: { abs($0.time.timeIntervalSince(hoverTime)) < abs($1.time.timeIntervalSince(hoverTime)) }) {
                        PointMark(x: .value("Time", nearest.time), y: .value("Value", nearest.value))
                            .foregroundStyle(entry.color)
                            .symbolSize(64)
                    }
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
        .chartLegend(.hidden)
        .chartYScale(domain: 0...upperBound)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(ChartPalette.grid)
                AxisValueLabel(format: .dateTime.hour().minute().second())
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(ChartPalette.grid)
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotAnchor = proxy.plotFrame else { return }
                            let plot = geometry[plotAnchor]
                            let x = location.x - plot.minX
                            guard x >= 0, x <= plot.width else {
                                hoverTime = nil
                                return
                            }
                            hoverTime = proxy.value(atX: x, as: Date.self)
                            hoverX = location.x
                        case .ended:
                            hoverTime = nil
                        }
                    }
                if let hoverTime {
                    tooltip(for: hoverTime)
                        .position(x: min(max(hoverX, 80), geometry.size.width - 80), y: 22)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func tooltip(for time: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(time.formatted(date: .omitted, time: .standard))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
            ForEach(values(at: time), id: \.0) { entry in
                HStack(spacing: 5) {
                    Circle()
                        .fill(series.first { $0.name == entry.0 }?.color ?? .white)
                        .frame(width: 6, height: 6)
                    Text(entry.0).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Text(format(entry.1)).font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
            }
        }
        .padding(7)
        .frame(width: 150)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.12)))
    }
}

// MARK: - Multiview tile

struct MultiviewTile: View {
    @ObservedObject var tab: BrowserTab
    let tick: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LivePreview(tab: tab)
                .aspectRatio(CGFloat(tab.canvasSize.aspect), contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(tab.isLive ? Color.bbLive : Color.white.opacity(0.1), lineWidth: tab.isLive ? 2 : 1))
            HStack(spacing: 6) {
                Text(tab.displayName).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Spacer()
                if tab.isLive { LiveBadge(since: tab.liveSince) }
            }
            Text("\(tab.canvasSize.label) · \(Int(tab.captureFPS.rounded())) fps captured")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .card(highlighted: tab.isLive)
    }
}

// MARK: - Outputs table

struct OutputsTable: View {
    @ObservedObject var session: SessionController
    let tick: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tabs & outputs").font(.system(size: 14, weight: .semibold))
            VStack(alignment: .leading, spacing: 14) {
                ForEach(session.tabs) { tab in
                    TabOutputsBlock(tab: tab, tick: tick)
                }
            }
            .card()
        }
    }
}

struct TabOutputsBlock: View {
    @ObservedObject var tab: BrowserTab
    let tick: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FaviconView(tab: tab)
                Text(tab.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(tab.urlString).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let since = tab.liveSince {
                    LiveBadge(since: since)
                } else {
                    Text("Off air").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            if tab.outputs.isEmpty {
                Text("No outputs").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 22)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["", "Output", "Format", "Uptime", "FPS", "Frames", "Dropped / late", "Receivers", "Detail"], id: \.self) { header in
                            Text(header).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        }
                    }
                    Divider().gridCellColumns(9)
                    ForEach(tab.outputs) { config in
                        let stats = tab.runtime(for: config.id)?.stats.snapshot() ?? OutputStatsSnapshot()
                        GridRow {
                            StatusDot(status: stats.status)
                            Label(config.name.isEmpty ? config.kind.shortLabel : config.name, systemImage: config.kind.symbol)
                                .lineLimit(1)
                            Text(config.formatSummary)
                            Text(stats.status == .live ? formatDuration(stats.uptime) : stats.status.label)
                            Text(stats.status == .live ? String(format: "%.2f", stats.measuredFPS) : "—")
                            Text(stats.status == .live ? "\(stats.framesSent)" : "—")
                            Text(stats.status == .live ? "\(stats.framesDropped) / \(stats.framesLate)" : "—")
                                .foregroundStyle(stats.framesDropped + stats.framesLate > 0 ? Color.orange : Color.primary)
                            receivers(config: config, stats: stats)
                            Text(stats.status.errorMessage ?? stats.detail)
                                .foregroundStyle(stats.status.errorMessage == nil ? Color.secondary : Color.orange)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 11).monospacedDigit())
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    @ViewBuilder
    private func receivers(config: OutputConfig, stats: OutputStatsSnapshot) -> some View {
        switch config.kind {
        case .ndi where stats.status == .live:
            HStack(spacing: 4) {
                Text(stats.connections >= 0 ? "\(stats.connections)" : "—")
                if stats.tallyProgram {
                    Text("PGM").font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.bbLive)
                } else if stats.tallyPreview {
                    Text("PVW").font(.system(size: 9, weight: .heavy)).foregroundStyle(ChartPalette.good)
                }
            }
        case .syphon where stats.status == .live:
            Text(stats.connections > 0 ? "Yes" : "None")
        case .decklink where stats.status == .live:
            Text(stats.bufferedFrames >= 0 ? "buf \(stats.bufferedFrames)" : "—")
        default:
            Text("—")
        }
    }
}
