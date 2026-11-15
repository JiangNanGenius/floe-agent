import Foundation

public enum MQTTCodec {
    public static func remainingLength(_ bytes: Data) throws -> (value: Int, bytes: Int)? {
        var result = 0, multiplier = 1
        for (i, b) in bytes.prefix(4).enumerated() {
            result += Int(b & 127) * multiplier
            if b & 128 == 0 { if i > 0 && b == 0 { throw ToolboxError.invalid("Non-canonical MQTT length") }; return (result, i+1) }
            multiplier *= 128
        }
        if bytes.count >= 4 { throw ToolboxError.invalid("MQTT length overflow") }; return nil
    }
    public static func decode(_ data: Data, version5: Bool = false) throws -> ProtocolReport {
        guard let first = data.first, let length = try remainingLength(data.dropFirst()) else { throw ToolboxError.truncated("MQTT header") }
        guard data.count == 1 + length.bytes + length.value else { throw ToolboxError.invalid("MQTT packet length") }
        let kind = first >> 4, flags = first & 15
        guard (1...15).contains(kind) else { throw ToolboxError.invalid("MQTT packet kind") }
        let requiredFlags: UInt8 = [6, 8, 10].contains(kind) ? 2 : 0
        guard kind == 3 || flags == requiredFlags else { throw ToolboxError.invalid("MQTT fixed flags") }
        var r = ByteReader(data.dropFirst(1 + length.bytes))
        var fields = ["type": String(kind), "remainingLength": String(length.value)]
        let names = ["", "CONNECT", "CONNACK", "PUBLISH", "PUBACK", "PUBREC", "PUBREL", "PUBCOMP", "SUBSCRIBE", "SUBACK", "UNSUBSCRIBE", "UNSUBACK", "PINGREQ", "PINGRESP", "DISCONNECT", "AUTH"]
        if kind == 1 { fields["sensitivePayload"] = "omitted" }
        if kind == 3 {
            let qos = (flags >> 1) & 3; guard qos != 3 else { throw ToolboxError.invalid("MQTT QoS") }
            let topicLength = Int(try r.u16()); let topicBytes = try r.take(topicLength)
            guard let topic = String(bytes: topicBytes, encoding: .utf8), !topic.isEmpty, !topic.contains("\0"), !topic.contains("#"), !topic.contains("+") else { throw ToolboxError.invalid("MQTT topic") }
            fields["topic"] = topic; fields["qos"] = String(qos); fields["retain"] = String(flags & 1 == 1)
            if qos > 0 { let id = try r.u16(); guard id > 0 else { throw ToolboxError.invalid("MQTT packet ID") }; fields["packetID"] = String(id) }
            if version5 {
                let rest = Data(r.bytes.dropFirst(r.offset))
                guard let props = try remainingLength(rest) else { throw ToolboxError.truncated("MQTT properties") }
                _ = try r.take(props.bytes + props.value)
            }
            let payload = Data(try r.take(r.remaining)); fields["payloadHex"] = payload.hex
            if let text = String(data: payload, encoding: .utf8) { fields["payloadText"] = text }
        }
        if [12, 13].contains(kind), length.value != 0 { throw ToolboxError.invalid("MQTT ping length") }
        if !version5, kind == 15 { throw ToolboxError.invalid("AUTH requires MQTT 5") }
        return ProtocolReport(name: version5 ? "MQTT 5" : "MQTT 3.1.1", summary: names[Int(kind)], fields: fields)
    }
}

/// Reassembles ordered application stream chunks; IP packet reordering is not implied.
public struct SerialStreamFramer: Sendable {
    public enum Format: Sendable { case modbusTCP, mqtt }
    public let maximumFrameBytes: Int
    private var buffer = Data()
    public init(maximumFrameBytes: Int = 256 * 1024) { self.maximumFrameBytes = max(8, min(maximumFrameBytes, 1024 * 1024)) }
    public mutating func append(_ chunk: Data, format: Format) throws -> [Data] {
        guard chunk.count <= maximumFrameBytes, buffer.count + chunk.count <= maximumFrameBytes else { throw ToolboxError.limit("stream buffer") }
        let old = buffer; buffer.append(chunk)
        do {
            var frames: [Data] = []
            while !buffer.isEmpty {
                let total: Int
                switch format {
                case .modbusTCP:
                    guard buffer.count >= 6 else { return frames }
                    let bytes = Array(buffer.prefix(6)); let length = Int(bytes[4]) << 8 | Int(bytes[5])
                    guard bytes[2] == 0, bytes[3] == 0, (2...254).contains(length) else { throw ToolboxError.invalid("MBAP stream header") }
                    total = length + 6
                case .mqtt:
                    guard buffer.count >= 2, let length = try MQTTCodec.remainingLength(buffer.dropFirst()) else { return frames }
                    total = 1 + length.bytes + length.value
                }
                guard total <= maximumFrameBytes else { throw ToolboxError.limit("stream frame") }
                guard buffer.count >= total else { return frames }
                frames.append(Data(buffer.prefix(total))); buffer = Data(buffer.dropFirst(total))
            }
            return frames
        } catch { buffer = old; throw error }
    }
    public var pendingBytes: Int { buffer.count }
    public mutating func reset() { buffer.removeAll(keepingCapacity: false) }
}

extension Data {
    public var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
    public init(hex: String) throws {
        let compact = hex.filter { !$0.isWhitespace }
        guard compact.count.isMultiple(of: 2), compact.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw ToolboxError.invalid("HEX bytes") }
        var bytes: [UInt8] = []; var cursor = compact.startIndex
        while cursor < compact.endIndex { let end = compact.index(cursor, offsetBy: 2); guard let byte = UInt8(compact[cursor..<end], radix: 16) else { throw ToolboxError.invalid("HEX bytes") }; bytes.append(byte); cursor = end }
        self.init(bytes)
    }
}
