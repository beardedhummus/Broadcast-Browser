import BBBridge
import Foundation

struct MonitorSample: Identifiable {
    let id = UUID()
    let time: Date
    /// Percent of one core (100 = one full core), like Activity Monitor.
    let appCPU: Double
    let webCPU: Double
    /// Percent of the whole machine.
    let systemCPU: Double
    let gpu: Double
    let appMemoryMB: Double
    let webMemoryMB: Double
    let networkOutMbps: Double
    let networkInMbps: Double
}

/// Samples CPU / memory / GPU / network once per second for the dashboard.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var latest: MonitorSample?
    @Published private(set) var history: [MonitorSample] = []
    @Published private(set) var systemMemoryUsed: UInt64 = 0
    @Published private(set) var systemMemoryTotal: UInt64 = 0
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published private(set) var tick = 0

    let coreCount = ProcessInfo.processInfo.activeProcessorCount
    let historyLength = 300

    /// Supplies the WebKit helper process IDs of the open tabs.
    var webProcessIDs: () -> [pid_t] = { [] }

    private var timer: Timer?
    private var previousProcessCPU: [pid_t: UInt64] = [:]
    private var previousTime = CFAbsoluteTimeGetCurrent()
    private var previousHostBusy: UInt64 = 0
    private var previousHostTotal: UInt64 = 0
    private var previousNetIn: UInt64 = 0
    private var previousNetOut: UInt64 = 0

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func cpuPercent(pid: pid_t, elapsed: Double) -> (cpu: Double, memory: UInt64)? {
        var cpuNanos: UInt64 = 0
        var footprint: UInt64 = 0
        guard BBProcessStats(pid, &cpuNanos, &footprint) else { return nil }
        defer { previousProcessCPU[pid] = cpuNanos }
        guard let previous = previousProcessCPU[pid], cpuNanos >= previous, elapsed > 0 else {
            return (0, footprint)
        }
        let percent = Double(cpuNanos - previous) / (elapsed * 1_000_000_000) * 100
        return (percent, footprint)
    }

    private func sample() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - previousTime
        previousTime = now

        let app = cpuPercent(pid: getpid(), elapsed: elapsed) ?? (0, 0)
        var webCPU = 0.0
        var webMemory: UInt64 = 0
        let pids = Set(webProcessIDs()).filter { $0 > 0 && $0 != getpid() }
        for pid in pids {
            if let stats = cpuPercent(pid: pid, elapsed: elapsed) {
                webCPU += stats.cpu
                webMemory += stats.memory
            }
        }
        previousProcessCPU = previousProcessCPU.filter { $0.key == getpid() || pids.contains($0.key) }

        var busy: UInt64 = 0
        var total: UInt64 = 0
        var systemCPU = 0.0
        if BBHostCPUTicks(&busy, &total) {
            if previousHostTotal > 0, total > previousHostTotal {
                systemCPU = Double(busy - previousHostBusy) / Double(total - previousHostTotal) * 100
            }
            previousHostBusy = busy
            previousHostTotal = total
        }

        var used: UInt64 = 0
        var memTotal: UInt64 = 0
        if BBHostMemory(&used, &memTotal) {
            systemMemoryUsed = used
            systemMemoryTotal = memTotal
        }

        var netIn: UInt64 = 0
        var netOut: UInt64 = 0
        var outMbps = 0.0
        var inMbps = 0.0
        if BBNetworkBytes(&netIn, &netOut) {
            if previousNetOut > 0, netOut >= previousNetOut, elapsed > 0 {
                outMbps = Double(netOut - previousNetOut) * 8 / elapsed / 1_000_000
                inMbps = Double(netIn &- previousNetIn) * 8 / elapsed / 1_000_000
            }
            previousNetIn = netIn
            previousNetOut = netOut
        }

        let gpu = Double(max(0, BBGPUUtilization()))
        let sample = MonitorSample(time: Date(),
                                   appCPU: app.cpu,
                                   webCPU: webCPU,
                                   systemCPU: systemCPU,
                                   gpu: gpu,
                                   appMemoryMB: Double(app.memory) / 1_048_576,
                                   webMemoryMB: Double(webMemory) / 1_048_576,
                                   networkOutMbps: outMbps,
                                   networkInMbps: max(0, inMbps))
        latest = sample
        history.append(sample)
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
        thermalState = ProcessInfo.processInfo.thermalState
        tick &+= 1
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}
