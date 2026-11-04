import AppKit
import Foundation

/// OSC remote control (input) and status feedback (output).
/// The full address reference lives in docs/OSC.md.
@MainActor
final class OSCController: ObservableObject {
    static let shared = OSCController()

    struct Endpoint: Hashable, Identifiable {
        let host: String
        let port: Int
        var id: String { "\(host):\(port)" }
    }

    enum PortCheck {
        case available, inUseByThisApp, inUse, invalid
    }

    @Published private(set) var listeningPort: Int?
    @Published private(set) var status = "Off"
    @Published private(set) var statusIsError = false
    @Published private(set) var messagesReceived = 0
    @Published private(set) var messagesSent = 0
    @Published private(set) var messagesRejected = 0
    @Published private(set) var lastCommand = ""
    @Published private(set) var subscribers: [Endpoint] = []

    private let receiver = OSCUDPReceiver()
    private let sender = OSCUDPSender()
    private var feedbackTimer: Timer?
    private var heartbeat: Int32 = 0
    private var applied: AppPreferences?
    private var lastTabLive: [UUID: Bool] = [:]
    private var lastTabEditing: [UUID: Bool] = [:]
    private var reportedErrors: Set<UUID> = []
    private var lastSessionLive = false

    private var preferences: AppPreferences { AppModel.shared.preferences }
    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    // MARK: Configuration

    /// Applies OSC preferences (call at launch and whenever they change).
    func apply() {
        let prefs = preferences
        let previous = applied
        applied = prefs
        if previous == nil || previous?.oscEnabled != prefs.oscEnabled || previous?.oscInputPort != prefs.oscInputPort {
            restartReceiver()
        }
        if previous?.oscFeedbackHost != prefs.oscFeedbackHost { sender.clearCache() }
        if previous == nil || previous?.oscFeedbackIntervalMs != prefs.oscFeedbackIntervalMs
            || previous?.oscFeedbackEnabled != prefs.oscFeedbackEnabled {
            restartFeedbackTimer()
        }
    }

    func restartReceiver() {
        receiver.stop()
        listeningPort = nil
        let prefs = preferences
        guard prefs.oscEnabled else {
            status = "OSC input is off"
            statusIsError = false
            return
        }
        receiver.onPacket = { [weak self] messages, host, port in
            DispatchQueue.main.async { self?.handlePacket(messages, host: host, port: port) }
        }
        do {
            try receiver.start(port: prefs.oscInputPort)
            listeningPort = prefs.oscInputPort
            status = "Listening on UDP \(prefs.oscInputPort)"
            statusIsError = false
        } catch {
            status = "\(error.localizedDescription) Choose another port in Preferences › OSC."
            statusIsError = true
        }
    }

    /// Checks a port before the user switches to it.
    func check(port: Int) -> PortCheck {
        guard (1024...65535).contains(port) else { return .invalid }
        if port == listeningPort { return .inUseByThisApp }
        return UDPPort.isAvailable(port) ? .available : .inUse
    }

    private func restartFeedbackTimer() {
        feedbackTimer?.invalidate()
        feedbackTimer = nil
        let interval = Double(max(100, preferences.oscFeedbackIntervalMs)) / 1000
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendFeedback() }
        }
        timer.tolerance = interval * 0.05
        RunLoop.main.add(timer, forMode: .common)
        feedbackTimer = timer
    }

    // MARK: Sending

    private var targets: [Endpoint] {
        var list: [Endpoint] = []
        let prefs = preferences
        if prefs.oscFeedbackEnabled, !prefs.oscFeedbackHost.isEmpty, (1...65535).contains(prefs.oscFeedbackPort) {
            list.append(Endpoint(host: prefs.oscFeedbackHost, port: prefs.oscFeedbackPort))
        }
        for subscriber in subscribers where !list.contains(subscriber) { list.append(subscriber) }
        return list
    }

    private func send(_ messages: [OSCMessage], to endpoints: [Endpoint]? = nil) {
        let destinations = endpoints ?? targets
        guard !messages.isEmpty, !destinations.isEmpty else { return }
        let style = preferences.oscBooleanStyle
        let packets = preferences.oscUseBundles
            ? OSCCodec.encodeBundles(messages, booleans: style)
            : messages.map { OSCCodec.encode($0, booleans: style) }
        for endpoint in destinations {
            sender.send(packets, host: endpoint.host, port: endpoint.port)
        }
        messagesSent += messages.count * destinations.count
    }

    /// Sends the complete status snapshot now.
    func sendFeedback() {
        guard !targets.isEmpty else { return }
        send(buildFeedback())
    }

    func sendTestMessage() {
        send([OSCMessage("/bb/test", [.string("Broadcast Browser \(appVersion)"), .bool(true), .int(1), .float(1.5)])])
    }

    // MARK: Events

    /// Called whenever a tab's live / edit / output state changes.
    func tabStateChanged(_ tab: BrowserTab) {
        guard let session = tab.session, let index = session.tabs.firstIndex(where: { $0 === tab }) else { return }
        let n = index + 1
        var messages: [OSCMessage] = []
        let live = tab.isLive
        if lastTabLive[tab.id] != live {
            lastTabLive[tab.id] = live
            messages.append(OSCMessage("/bb/tab/\(n)/isLive", [.bool(live)]))
            messages.append(OSCMessage("/bb/event/tabLive", [.int(Int32(n)), .string(tab.displayName), .bool(live)]))
        }
        if lastTabEditing[tab.id] != tab.isEditing {
            lastTabEditing[tab.id] = tab.isEditing
            messages.append(OSCMessage("/bb/tab/\(n)/isEditing", [.bool(tab.isEditing)]))
            messages.append(OSCMessage("/bb/tab/\(n)/isHolding", [.bool(tab.isHoldingOutput)]))
        }
        for (m, config) in tab.outputs.enumerated() {
            let status = tab.runtime(for: config.id)?.status ?? .idle
            if let message = status.errorMessage {
                if !reportedErrors.contains(config.id) {
                    reportedErrors.insert(config.id)
                    messages.append(OSCMessage("/bb/event/outputError", [.int(Int32(n)), .int(Int32(m + 1)), .string(config.name), .string(message)]))
                }
            } else {
                reportedErrors.remove(config.id)
            }
        }
        let sessionLive = session.tabs.contains { $0.isLive }
        if sessionLive != lastSessionLive {
            lastSessionLive = sessionLive
            messages.append(OSCMessage("/bb/session/isLive", [.bool(sessionLive)]))
            messages.append(OSCMessage("/bb/event/sessionLive", [.bool(sessionLive)]))
        }
        send(messages)
    }

    func tabsChanged(count: Int) {
        send([OSCMessage("/bb/event/tabsChanged", [.int(Int32(count))])])
    }

    // MARK: Receiving

    private func isAllowed(_ host: String) -> Bool {
        let list = preferences.oscAllowedSenders
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if list.isEmpty { return true }
        return list.contains { allowed in
            allowed == host || (allowed == "localhost" && host == "127.0.0.1")
        }
    }

    private func handlePacket(_ messages: [OSCMessage], host: String, port: UInt16) {
        guard isAllowed(host) else {
            messagesRejected += messages.count
            return
        }
        messagesReceived += messages.count
        for message in messages {
            lastCommand = "\(message.debugText)  ← \(host)"
            handle(message, reply: Endpoint(host: host, port: Int(port)))
        }
    }

    private func replyError(_ text: String, to endpoint: Endpoint) {
        send([OSCMessage("/bb/error", [.string(text)])], to: [endpoint] + targets.filter { $0 != endpoint })
    }

    func handle(_ message: OSCMessage, reply: Endpoint) {
        let parts = message.address.split(separator: "/").map(String.init)
        guard parts.count >= 2, parts[0].lowercased() == "bb" else {
            replyError("Unknown address \(message.address) (addresses start with /bb/)", to: reply)
            return
        }
        let args = message.arguments
        switch parts[1].lowercased() {
        case "ping":
            send([OSCMessage("/bb/pong", [.string(appVersion)])], to: [reply] + targets.filter { $0 != reply })
        case "feedback":
            handleFeedbackCommand(parts.count > 2 ? parts[2].lowercased() : "", args: args, reply: reply)
        case "session":
            handleSessionCommand(parts.count > 2 ? parts[2].lowercased() : "", args: args, reply: reply)
        case "tab":
            handleTabCommand(Array(parts.dropFirst(2)), args: args, reply: reply)
        default:
            replyError("Unknown address \(message.address)", to: reply)
        }
    }

    private func handleFeedbackCommand(_ command: String, args: [OSCValue], reply: Endpoint) {
        switch command {
        case "refresh":
            sendFeedback()
            if !targets.contains(reply) { send(buildFeedback(), to: [reply]) }
        case "subscribe":
            let port = args.first?.doubleValue.map { Int($0) } ?? reply.port
            let endpoint = Endpoint(host: reply.host, port: port)
            if !subscribers.contains(endpoint) { subscribers.append(endpoint) }
            if subscribers.count > 16 { subscribers.removeFirst() }
            send(buildFeedback(), to: [endpoint])
        case "unsubscribe":
            let port = args.first?.doubleValue.map { Int($0) } ?? reply.port
            subscribers.removeAll { $0.host == reply.host && $0.port == port }
        default:
            replyError("Unknown feedback command \(command)", to: reply)
        }
    }

    private func handleSessionCommand(_ command: String, args: [OSCValue], reply: Endpoint) {
        guard let session = AppModel.shared.session else {
            replyError("No session is open", to: reply)
            return
        }
        switch command {
        case "golive", "start":
            session.goLiveAll()
        case "stop":
            session.stopAll()
        case "live":
            guard let flag = args.first?.boolValue else { return replyError("/bb/session/live needs 1/0 or true/false", to: reply) }
            flag ? session.goLiveAll() : session.stopAll()
        case "toggle":
            session.liveSince == nil ? session.goLiveAll() : session.stopAll()
        case "save":
            if session.fileURL == nil {
                replyError("The session has not been saved yet — save it once in the app first", to: reply)
            } else {
                session.save()
            }
        default:
            replyError("Unknown session command \(command)", to: reply)
        }
    }

    /// Finds a tab by 1-based index, "selected", tab id, or name (underscores = spaces).
    func resolveTab(_ token: String, in session: SessionController) -> BrowserTab? {
        let lower = token.lowercased()
        if lower == "selected" || lower == "current" { return session.selectedTab }
        if let index = Int(token) {
            return (1...session.tabs.count).contains(index) ? session.tabs[index - 1] : nil
        }
        if let uuid = UUID(uuidString: token) { return session.tabs.first { $0.id == uuid } }
        let name = token.replacingOccurrences(of: "_", with: " ").lowercased()
        return session.tabs.first { $0.displayName.lowercased() == name || $0.label.lowercased() == name }
    }

    private func resolveOutput(_ token: String, in tab: BrowserTab) -> OutputConfig? {
        if let index = Int(token) {
            return (1...max(1, tab.outputs.count)).contains(index) && index <= tab.outputs.count ? tab.outputs[index - 1] : nil
        }
        if let uuid = UUID(uuidString: token) { return tab.outputs.first { $0.id == uuid } }
        let name = token.replacingOccurrences(of: "_", with: " ").lowercased()
        return tab.outputs.first { $0.name.lowercased() == name }
    }

    private func handleTabCommand(_ parts: [String], args: [OSCValue], reply: Endpoint) {
        guard let session = AppModel.shared.session else { return replyError("No session is open", to: reply) }
        guard let token = parts.first else { return replyError("Missing tab number", to: reply) }
        if token.lowercased() == "new" {
            let tab = session.newTab(url: args.first?.stringValue, select: false)
            send([OSCMessage("/bb/event/tabCreated", [.int(Int32(session.tabs.firstIndex { $0 === tab }.map { $0 + 1 } ?? 0)), .string(tab.id.uuidString)])],
                 to: [reply] + targets.filter { $0 != reply })
            return
        }
        guard let tab = resolveTab(token, in: session) else { return replyError("No tab \(token)", to: reply) }
        guard parts.count >= 2 else { return replyError("Missing command for tab \(token)", to: reply) }
        let command = parts[1].lowercased()
        let prefs = preferences
        switch command {
        case "golive", "start": tab.goLive()
        case "stop": tab.stopAllOutputs()
        case "live":
            guard let flag = args.first?.boolValue else { return replyError("live needs 1/0 or true/false", to: reply) }
            flag ? tab.goLive() : tab.stopAllOutputs()
        case "toggle": tab.isLive ? tab.stopAllOutputs() : tab.goLive()
        case "reload": tab.reload()
        case "url":
            guard let url = args.first?.stringValue, !url.isEmpty else { return replyError("url needs a string", to: reply) }
            tab.load(input: url)
        case "zoom":
            guard let value = args.first?.doubleValue else { return replyError("zoom needs a number (1.0 = 100%)", to: reply) }
            tab.zoom = min(5, max(0.25, value > 10 ? value / 100 : value))
        case "zoomin": tab.zoomIn()
        case "zoomout": tab.zoomOut()
        case "zoomreset": tab.resetZoom()
        case "select": session.select(tab)
        case "mute":
            guard let flag = args.first?.boolValue else { return replyError("mute needs 1/0", to: reply) }
            tab.muted = flag
        case "edit":
            guard let flag = args.first?.boolValue else { return replyError("edit needs 1/0", to: reply) }
            flag ? tab.enterEditMode() : tab.exitEditMode()
        case "isolate":
            tab.customization.isolateSelector = args.first?.stringValue ?? ""
        case "scroll", "scrollby":
            let x = args.count > 0 ? (args[0].doubleValue ?? 0) : 0
            let y = args.count > 1 ? (args[1].doubleValue ?? 0) : 0
            let function = command == "scroll" ? "scrollTo" : "scrollBy"
            tab.webView.evaluateJavaScript("window.\(function)(\(x), \(y))", completionHandler: nil)
        case "rule":
            guard parts.count >= 4, let index = Int(parts[2]), (1...tab.customization.rules.count).contains(index),
                  parts[3].lowercased() == "enabled", let flag = args.first?.boolValue else {
                return replyError("Use /bb/tab/<tab>/rule/<n>/enabled <1|0>", to: reply)
            }
            tab.customization.rules[index - 1].enabled = flag
        case "js", "css":
            guard prefs.oscAllowScripting else {
                return replyError("Scripting over OSC is off (Preferences › OSC › Allow /js and /css)", to: reply)
            }
            let code = args.first?.stringValue ?? ""
            if command == "js" {
                tab.webView.evaluateJavaScript(code) { [weak self] result, error in
                    let text = error?.localizedDescription ?? (result.map { "\($0)" } ?? "")
                    self?.send([OSCMessage("/bb/tab/\(token)/jsResult", [.string(String(text.prefix(1000)))])], to: [reply])
                }
            } else {
                tab.customization.customCSS = code
            }
        case "close":
            session.closeTab(tab, force: true)
        case "output":
            guard parts.count >= 4 else { return replyError("Use /bb/tab/<tab>/output/<n>/start|stop|live|toggle", to: reply) }
            guard let config = resolveOutput(parts[2], in: tab) else { return replyError("No output \(parts[2]) on tab \(token)", to: reply) }
            let isActive = tab.runtime(for: config.id)?.status.isActive == true
            switch parts[3].lowercased() {
            case "start": tab.startOutput(config.id)
            case "stop": tab.stopOutput(config.id)
            case "toggle": tab.toggleOutput(config.id)
            case "live":
                guard let flag = args.first?.boolValue else { return replyError("live needs 1/0", to: reply) }
                if flag && !isActive { tab.startOutput(config.id) }
                if !flag && isActive { tab.stopOutput(config.id) }
            default:
                replyError("Unknown output command \(parts[3])", to: reply)
            }
        default:
            replyError("Unknown tab command \(command)", to: reply)
        }
    }

    // MARK: Feedback snapshot

    func buildFeedback() -> [OSCMessage] {
        var out: [OSCMessage] = []
        func add(_ address: String, _ values: OSCValue...) { out.append(OSCMessage(address, values)) }
        heartbeat &+= 1
        add("/bb/heartbeat", .int(heartbeat))
        add("/bb/app/version", .string(appVersion))

        let monitor = AppModel.shared.monitor
        let cores = Double(max(1, monitor.coreCount))
        if let sample = monitor.latest {
            let appCPU = sample.appCPU + sample.webCPU
            add("/bb/stats/cpuApp", .float(Float(appCPU)))
            add("/bb/stats/cpuAppOfMac", .float(Float(appCPU / cores)))
            add("/bb/stats/cpuSystem", .float(Float(sample.systemCPU)))
            add("/bb/stats/gpu", .float(Float(sample.gpu)))
            add("/bb/stats/memoryAppMB", .float(Float(sample.appMemoryMB + sample.webMemoryMB)))
            add("/bb/stats/networkOutMbps", .float(Float(sample.networkOutMbps)))
            add("/bb/stats/networkInMbps", .float(Float(sample.networkInMbps)))
        }
        add("/bb/stats/memorySystemUsedGB", .float(Float(Double(monitor.systemMemoryUsed) / 1_073_741_824)))
        add("/bb/stats/memorySystemTotalGB", .float(Float(Double(monitor.systemMemoryTotal) / 1_073_741_824)))
        add("/bb/stats/thermal", .string(monitor.thermalState.label.lowercased()))
        add("/bb/stats/thermalLevel", .int(Int32(monitor.thermalState.rawValue)))

        let audio = AudioHub.shared.status()
        add("/bb/audio/active", .bool(audio.running))
        add("/bb/audio/source", .string(audio.source.rawValue))
        add("/bb/audio/peakL", .float(Float(audio.peakLdB)))
        add("/bb/audio/peakR", .float(Float(audio.peakRdB)))

        guard let session = AppModel.shared.session else {
            add("/bb/session/open", .bool(false))
            return out
        }
        let tabs = session.tabs
        let allOutputs = tabs.flatMap { tab in tab.outputs.map { (tab, $0) } }
        let liveOutputs = allOutputs.filter { $0.0.runtime(for: $0.1.id)?.status.isActive == true }.count
        let errorOutputs = allOutputs.filter { $0.0.runtime(for: $0.1.id)?.status.errorMessage != nil }.count
        let uptime = session.liveSince.map { Date().timeIntervalSince($0) } ?? 0
        add("/bb/session/open", .bool(true))
        add("/bb/session/name", .string(session.name))
        add("/bb/session/isLive", .bool(session.liveSince != nil))
        add("/bb/session/uptime", .float(Float(uptime)))
        add("/bb/session/uptimeText", .string(formatDuration(uptime)))
        add("/bb/session/tabCount", .int(Int32(tabs.count)))
        add("/bb/session/outputsLive", .int(Int32(liveOutputs)))
        add("/bb/session/outputsTotal", .int(Int32(allOutputs.count)))
        add("/bb/session/outputsError", .int(Int32(errorOutputs)))
        out.append(OSCMessage("/bb/session/tabNames", tabs.map { .string($0.displayName) }))
        out.append(OSCMessage("/bb/session/tabsLive", tabs.map { .bool($0.isLive) }))

        for (index, tab) in tabs.enumerated() {
            let base = "/bb/tab/\(index + 1)"
            let tabUptime = tab.liveSince.map { Date().timeIntervalSince($0) } ?? 0
            let liveCount = tab.outputs.filter { tab.runtime(for: $0.id)?.status.isActive == true }.count
            add("\(base)/id", .string(tab.id.uuidString))
            add("\(base)/name", .string(tab.displayName))
            add("\(base)/url", .string(tab.urlString))
            add("\(base)/isLive", .bool(tab.isLive))
            add("\(base)/uptime", .float(Float(tabUptime)))
            add("\(base)/uptimeText", .string(formatDuration(tabUptime)))
            add("\(base)/isSelected", .bool(session.selectedTab === tab))
            add("\(base)/isEditing", .bool(tab.isEditing))
            add("\(base)/isHolding", .bool(tab.isHoldingOutput))
            add("\(base)/isLoading", .bool(tab.isLoading))
            add("\(base)/muted", .bool(tab.muted))
            add("\(base)/zoom", .float(Float(tab.zoom)))
            add("\(base)/canvas", .string("\(tab.canvasSize.width)x\(tab.canvasSize.height)"))
            add("\(base)/captureFps", .float(Float(tab.captureFPS)))
            add("\(base)/outputCount", .int(Int32(tab.outputs.count)))
            add("\(base)/outputsLive", .int(Int32(liveCount)))
            add("\(base)/error", .string(tab.captureProblem ?? tab.lastError ?? ""))
            for (m, config) in tab.outputs.enumerated() {
                let o = "\(base)/output/\(m + 1)"
                let stats = tab.runtime(for: config.id)?.stats.snapshot() ?? OutputStatsSnapshot()
                let tally = stats.tallyProgram ? "program" : (stats.tallyPreview ? "preview" : "none")
                add("\(o)/name", .string(config.name))
                add("\(o)/kind", .string(config.kind.rawValue))
                add("\(o)/isLive", .bool(stats.status == .live))
                add("\(o)/status", .string(statusName(stats.status)))
                add("\(o)/error", .string(stats.status.errorMessage ?? ""))
                add("\(o)/format", .string(config.formatSummary))
                add("\(o)/fps", .float(Float(stats.measuredFPS)))
                add("\(o)/framesSent", .int(Int32(truncatingIfNeeded: stats.framesSent)))
                add("\(o)/dropped", .int(Int32(truncatingIfNeeded: stats.framesDropped)))
                add("\(o)/late", .int(Int32(truncatingIfNeeded: stats.framesLate)))
                add("\(o)/uptime", .float(Float(stats.uptime)))
                add("\(o)/receivers", .int(Int32(stats.connections)))
                add("\(o)/tally", .string(tally))
                add("\(o)/audio", .bool(config.audioEnabled))
                add("\(o)/crop", .bool(config.cropEnabled))
            }
        }
        return out
    }

    private func statusName(_ status: OutputStatus) -> String {
        switch status {
        case .idle: return "idle"
        case .starting: return "starting"
        case .live: return "live"
        case .error: return "error"
        }
    }
}
