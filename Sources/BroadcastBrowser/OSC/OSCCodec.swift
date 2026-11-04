import Foundation

/// One OSC argument.
enum OSCValue: Equatable {
    case int(Int32)
    case float(Float)
    case string(String)
    case bool(Bool)
    case double(Double)
    case int64(Int64)
    case blob(Data)
    case null
    case impulse

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value != 0
        case .int64(let value): return value != 0
        case .float(let value): return value != 0
        case .double(let value): return value != 0
        case .string(let value):
            switch value.lowercased() {
            case "1", "true", "on", "yes": return true
            case "0", "false", "off", "no": return false
            default: return nil
            }
        case .impulse: return true
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .int64(let value): return Double(value)
        case .float(let value): return Double(value)
        case .double(let value): return value
        case .bool(let value): return value ? 1 : 0
        case .string(let value): return Double(value)
        default: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        case .int64(let value): return String(value)
        case .float(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var debugText: String {
        switch self {
        case .int(let value): return "\(value)"
        case .float(let value): return String(format: "%g", value)
        case .string(let value): return "\"\(value)\""
        case .bool(let value): return value ? "true" : "false"
        case .double(let value): return "\(value)"
        case .int64(let value): return "\(value)"
        case .blob(let data): return "<blob \(data.count) bytes>"
        case .null: return "nil"
        case .impulse: return "impulse"
        }
    }
}

struct OSCMessage {
    var address: String
    var arguments: [OSCValue]

    init(_ address: String, _ arguments: [OSCValue] = []) {
        self.address = address
        self.arguments = arguments
    }

    var debugText: String {
        ([address] + arguments.map(\.debugText)).joined(separator: " ")
    }
}

/// OSC 1.0 encoder/decoder (with the common 1.1 types T, F, N, I, h, d).
enum OSCCodec {
    // MARK: Encoding

    private static func pad(_ data: inout Data) {
        while data.count % 4 != 0 { data.append(0) }
    }

    private static func appendString(_ string: String, to data: inout Data) {
        data.append(contentsOf: Array(string.utf8))
        data.append(0)
        pad(&data)
    }

    private static func appendInt32(_ value: Int32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendInt64(_ value: Int64, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    static func encode(_ message: OSCMessage, booleans: OSCBooleanStyle = .oscBool) -> Data {
        var data = Data()
        appendString(message.address, to: &data)
        var tags = ","
        var payload = Data()
        for argument in message.arguments {
            switch argument {
            case .int(let value):
                tags += "i"
                appendInt32(value, to: &payload)
            case .float(let value):
                tags += "f"
                appendInt32(Int32(bitPattern: value.bitPattern), to: &payload)
            case .string(let value):
                tags += "s"
                appendString(value, to: &payload)
            case .bool(let value):
                switch booleans {
                case .oscBool:
                    tags += value ? "T" : "F"
                case .integer:
                    tags += "i"
                    appendInt32(value ? 1 : 0, to: &payload)
                case .string:
                    tags += "s"
                    appendString(value ? "true" : "false", to: &payload)
                }
            case .double(let value):
                tags += "d"
                appendInt64(Int64(bitPattern: value.bitPattern), to: &payload)
            case .int64(let value):
                tags += "h"
                appendInt64(value, to: &payload)
            case .blob(let blob):
                tags += "b"
                appendInt32(Int32(blob.count), to: &payload)
                payload.append(blob)
                pad(&payload)
            case .null:
                tags += "N"
            case .impulse:
                tags += "I"
            }
        }
        appendString(tags, to: &data)
        data.append(payload)
        return data
    }

    /// Packs messages into "#bundle" packets no larger than `maxPacket` bytes.
    static func encodeBundles(_ messages: [OSCMessage], booleans: OSCBooleanStyle, maxPacket: Int = 1400) -> [Data] {
        var packets: [Data] = []
        var current = Data()
        func startBundle() -> Data {
            var bundle = Data()
            appendString("#bundle", to: &bundle)
            appendInt64(1, to: &bundle) // time tag 1 = "immediately"
            return bundle
        }
        current = startBundle()
        let headerSize = current.count
        for message in messages {
            let element = encode(message, booleans: booleans)
            if current.count + 4 + element.count > maxPacket && current.count > headerSize {
                packets.append(current)
                current = startBundle()
            }
            appendInt32(Int32(element.count), to: &current)
            current.append(element)
        }
        if current.count > headerSize { packets.append(current) }
        return packets
    }

    // MARK: Decoding

    /// Decodes a packet into messages (bundles are flattened, time tags ignored).
    static func decode(_ data: Data) -> [OSCMessage] {
        let bytes = [UInt8](data)
        var messages: [OSCMessage] = []
        decodePacket(bytes[...], into: &messages, depth: 0)
        return messages
    }

    private static func decodePacket(_ bytes: ArraySlice<UInt8>, into messages: inout [OSCMessage], depth: Int) {
        guard depth < 8, !bytes.isEmpty else { return }
        if bytes.first == UInt8(ascii: "#") {
            var cursor = bytes.startIndex
            guard let tag = readString(bytes, &cursor), tag == "#bundle", cursor + 8 <= bytes.endIndex else { return }
            cursor += 8 // time tag
            while cursor + 4 <= bytes.endIndex {
                guard let size = readInt32(bytes, &cursor), size > 0, cursor + Int(size) <= bytes.endIndex else { return }
                decodePacket(bytes[cursor..<(cursor + Int(size))], into: &messages, depth: depth + 1)
                cursor += Int(size)
            }
        } else if let message = decodeMessage(bytes) {
            messages.append(message)
        }
    }

    private static func decodeMessage(_ bytes: ArraySlice<UInt8>) -> OSCMessage? {
        var cursor = bytes.startIndex
        guard let address = readString(bytes, &cursor), address.hasPrefix("/") else { return nil }
        guard cursor < bytes.endIndex, let tags = readString(bytes, &cursor), tags.hasPrefix(",") else {
            return OSCMessage(address) // tolerate missing type tags
        }
        var arguments: [OSCValue] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i":
                guard let value = readInt32(bytes, &cursor) else { return OSCMessage(address, arguments) }
                arguments.append(.int(value))
            case "f":
                guard let value = readInt32(bytes, &cursor) else { return OSCMessage(address, arguments) }
                arguments.append(.float(Float(bitPattern: UInt32(bitPattern: value))))
            case "s", "S":
                guard let value = readString(bytes, &cursor) else { return OSCMessage(address, arguments) }
                arguments.append(.string(value))
            case "b":
                guard let size = readInt32(bytes, &cursor), size >= 0, cursor + Int(size) <= bytes.endIndex else {
                    return OSCMessage(address, arguments)
                }
                arguments.append(.blob(Data(bytes[cursor..<(cursor + Int(size))])))
                cursor += (Int(size) + 3) & ~3
            case "h", "t":
                guard let value = readInt64(bytes, &cursor) else { return OSCMessage(address, arguments) }
                arguments.append(.int64(value))
            case "d":
                guard let value = readInt64(bytes, &cursor) else { return OSCMessage(address, arguments) }
                arguments.append(.double(Double(bitPattern: UInt64(bitPattern: value))))
            case "T": arguments.append(.bool(true))
            case "F": arguments.append(.bool(false))
            case "N": arguments.append(.null)
            case "I": arguments.append(.impulse)
            case "c", "r", "m":
                guard let value = readInt32(bytes, &cursor) else { return OSCMessage(address, arguments) }
                arguments.append(.int(value))
            default:
                return OSCMessage(address, arguments) // unknown tag: stop parsing safely
            }
        }
        return OSCMessage(address, arguments)
    }

    private static func readString(_ bytes: ArraySlice<UInt8>, _ cursor: inout Int) -> String? {
        guard let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
        let string = String(decoding: bytes[cursor..<end], as: UTF8.self)
        cursor = end + 1
        while (cursor - bytes.startIndex) % 4 != 0 { cursor += 1 }
        return string
    }

    private static func readInt32(_ bytes: ArraySlice<UInt8>, _ cursor: inout Int) -> Int32? {
        guard cursor + 4 <= bytes.endIndex else { return nil }
        var value: UInt32 = 0
        for i in 0..<4 { value = (value << 8) | UInt32(bytes[cursor + i]) }
        cursor += 4
        return Int32(bitPattern: value)
    }

    private static func readInt64(_ bytes: ArraySlice<UInt8>, _ cursor: inout Int) -> Int64? {
        guard cursor + 8 <= bytes.endIndex else { return nil }
        var value: UInt64 = 0
        for i in 0..<8 { value = (value << 8) | UInt64(bytes[cursor + i]) }
        cursor += 8
        return Int64(bitPattern: value)
    }
}
