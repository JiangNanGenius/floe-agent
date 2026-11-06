import Foundation

public enum ModbusCodec {
    public static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xa001 : crc >> 1 }
        }
        return crc
    }
    public static func readRequest(unit: UInt8, function: UInt8 = 3, address: UInt16, count: UInt16,
                                   transactionID: UInt16 = 1, rtu: Bool = false) throws -> Data {
        guard [1, 2, 3, 4].contains(function), count > 0,
              count <= (function <= 2 ? 2000 : 125), Int(address) + Int(count) <= 65536 else { throw ToolboxError.invalid("Modbus read range") }
        let body = Data([unit, function, UInt8(address >> 8), UInt8(address & 255), UInt8(count >> 8), UInt8(count & 255)])
        if rtu { let crc = crc16(body); return body + Data([UInt8(crc & 255), UInt8(crc >> 8)]) }
        return Data([UInt8(transactionID >> 8), UInt8(transactionID & 255), 0, 0, 0, UInt8(body.count)]) + body
    }
    public static func decode(_ data: Data, rtu: Bool = false, response: Bool) throws -> ProtocolReport {
        guard data.count <= (rtu ? 256 : 260) else { throw ToolboxError.limit("Modbus frame") }
        var r = ByteReader(data); var fields: [String: String] = [:]; let body: Data
        if rtu {
            guard data.count >= 5 else { throw ToolboxError.truncated("RTU frame") }
            body = data.dropLast(2)
            let tail = Array(data.suffix(2))
            let expected = UInt16(tail[0]) | UInt16(tail[1]) << 8
            guard crc16(body) == expected else { throw ToolboxError.invalid("RTU CRC") }
            fields["crc"] = "valid"
        } else {
            let tid = try r.u16(), pid = try r.u16(), length = try r.u16()
            guard pid == 0, length >= 2, Int(length) + 6 == data.count else { throw ToolboxError.invalid("MBAP length or protocol") }
            fields["transactionID"] = String(tid); body = Data(try r.take(Int(length)))
        }
        var p = ByteReader(body); let unit = try p.u8(), function = try p.u8()
        fields["unitID"] = String(unit); fields["function"] = String(function)
        if function & 0x80 != 0 {
            guard response, p.remaining == 1 else { throw ToolboxError.invalid("Modbus exception") }
            fields["exceptionCode"] = String(try p.u8())
            return ProtocolReport(name: rtu ? "Modbus RTU" : "Modbus TCP", summary: "Exception response", fields: fields)
        }
        if [1, 2, 3, 4].contains(function) {
            if response {
                let byteCount = Int(try p.u8())
                guard byteCount == p.remaining, byteCount > 0, byteCount <= 250,
                      function < 3 || byteCount % 2 == 0 else { throw ToolboxError.invalid("Modbus byte count") }
                fields["byteCount"] = String(byteCount)
                if function >= 3 {
                    var values: [String] = []
                    while p.remaining > 0 { values.append(String(try p.u16())) }
                    fields["registerValues"] = values.joined(separator: ",")
                } else { fields["packedCoilsHex"] = Data(try p.take(byteCount)).hex }
            } else {
                guard p.remaining == 4 else { throw ToolboxError.invalid("Modbus read request length") }
                let address = try p.u16(), quantity = try p.u16()
                guard quantity > 0, quantity <= (function < 3 ? 2000 : 125), Int(address) + Int(quantity) <= 65536 else { throw ToolboxError.invalid("Modbus read range") }
                fields["zeroBasedAddress"] = String(address); fields["quantity"] = String(quantity)
            }
        } else if [5, 6, 15, 16].contains(function) {
            guard p.remaining >= 4 else { throw ToolboxError.truncated("Modbus write") }
            let address = try p.u16(), value = try p.u16()
            fields["zeroBasedAddress"] = String(address); fields["valueOrQuantity"] = String(value)
            if function == 5, ![0, 0xff00].contains(value) { throw ToolboxError.invalid("Modbus coil value") }
            if function >= 15 {
                guard value > 0, value <= (function == 15 ? 1968 : 123), Int(address)+Int(value) <= 65536 else { throw ToolboxError.invalid("Modbus write range") }
            }
            if function <= 6 || response { guard p.remaining == 0 else { throw ToolboxError.invalid("Modbus write length") } }
            else { let size = Int(try p.u8()); let expected = function == 15 ? (Int(value)+7)/8 : Int(value)*2; guard size == p.remaining, size == expected else { throw ToolboxError.invalid("Modbus write byte count") }; fields["payloadHex"] = Data(try p.take(size)).hex }
        } else {
            return ProtocolReport(name: "Modbus", summary: "Unrecognized function", fields: fields, warnings: ["Payload preserved; unsupported function is not inferred."])
        }
        return ProtocolReport(name: rtu ? "Modbus RTU" : "Modbus TCP", summary: response ? "Response" : "Request", fields: fields)
    }
}

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
