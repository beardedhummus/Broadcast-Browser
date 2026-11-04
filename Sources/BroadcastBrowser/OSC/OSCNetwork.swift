import Darwin
import Foundation

enum UDPPort {
    /// True when nothing on this Mac is bound to the UDP port.
    static func isAvailable(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

/// Receives OSC packets on a UDP port (IPv4, all interfaces).
final class OSCUDPReceiver: @unchecked Sendable {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "bb.osc.receive", qos: .userInitiated)
    private(set) var port: Int = 0
    /// Called on a background queue with the decoded messages and the sender.
    var onPacket: (([OSCMessage], String, UInt16) -> Void)?

    enum ReceiverError: LocalizedError {
        case socket(String)
        case portInUse(Int)
        var errorDescription: String? {
            switch self {
            case .socket(let message): return message
            case .portInUse(let port): return "UDP port \(port) is already in use by another application."
            }
        }
    }

    func start(port: Int) throws {
        stop()
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ReceiverError.socket("Could not create a UDP socket (\(String(cString: strerror(errno)))).") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            let code = errno
            close(fd)
            if code == EADDRINUSE { throw ReceiverError.portInUse(port) }
            throw ReceiverError.socket("Could not listen on UDP \(port): \(String(cString: strerror(code))).")
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        self.fd = fd
        self.port = port
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        fd = -1
        port = 0
    }

    var isRunning: Bool { source != nil }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength)
                }
            }
            if count <= 0 { break }
            var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &hostBuffer, socklen_t(INET_ADDRSTRLEN))
            let host = String(cString: hostBuffer)
            let port = UInt16(bigEndian: from.sin_port)
            let messages = OSCCodec.decode(Data(buffer[0..<count]))
            if !messages.isEmpty { onPacket?(messages, host, port) }
        }
    }
}

/// Sends OSC packets over UDP.
final class OSCUDPSender: @unchecked Sendable {
    private let fd: Int32
    private let queue = DispatchQueue(label: "bb.osc.send", qos: .utility)
    private var resolved: [String: in_addr] = [:]
    private let lock = NSLock()

    init() {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close(fd)
    }

    private func resolve(_ host: String) -> in_addr? {
        if let cached = lock.sync({ resolved[host] }) { return cached }
        var address = in_addr()
        let name = host == "localhost" ? "127.0.0.1" : host
        if inet_pton(AF_INET, name, &address) == 1 {
            lock.sync { resolved[host] = address }
            return address
        }
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        guard let sockaddrPointer = info.pointee.ai_addr else { return nil }
        let found = sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        lock.sync { resolved[host] = found }
        return found
    }

    func clearCache() {
        lock.sync { resolved.removeAll() }
    }

    /// Sends each packet to host:port. Returns immediately.
    func send(_ packets: [Data], host: String, port: Int) {
        guard fd >= 0, (1...65535).contains(port) else { return }
        queue.async { [self] in
            guard let address = resolve(host) else { return }
            var destination = sockaddr_in()
            destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            destination.sin_family = sa_family_t(AF_INET)
            destination.sin_port = in_port_t(UInt16(port)).bigEndian
            destination.sin_addr = address
            for packet in packets {
                packet.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &destination) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            _ = sendto(fd, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }
}
