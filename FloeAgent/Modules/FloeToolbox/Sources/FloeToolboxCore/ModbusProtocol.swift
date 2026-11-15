import Foundation

/// The four Modbus data tables. A PDU address is always zero-based; the
/// five/six-digit references are documentation conventions, not wire values.
public enum ModbusTable: String, Codable, Sendable, CaseIterable {
    case coil, discreteInput, inputRegister, holdingRegister
    public var isBit: Bool { self == .coil || self == .discreteInput }
    public var isReadOnly: Bool { self == .discreteInput || self == .inputRegister }
    public var readFunction: UInt8 {
        switch self { case .coil: 1; case .discreteInput: 2; case .inputRegister: 4; case .holdingRegister: 3 }
    }
    public var writeFunction: UInt8? {
        switch self { case .coil: 5; case .holdingRegister: 6; case .discreteInput, .inputRegister: nil }
    }
    /// Five-digit reference base used by device manuals.
    public var referenceBase: Int {
        switch self { case .coil: 1; case .discreteInput: 10001; case .inputRegister: 30001; case .holdingRegister: 40001 }
    }
    /// Six-digit extended reference base for addresses above 9998.
    public var extendedReferenceBase: Int {
        switch self { case .coil: 1; case .discreteInput: 100001; case .inputRegister: 300001; case .holdingRegister: 400001 }
    }
}

/// One of the eight public operations requested by the serial assistant.
public enum ModbusOperationKind: UInt8, CaseIterable, Sendable, Identifiable {
    case readCoils = 1
    case readDiscreteInputs = 2
    case readHoldingRegisters = 3
    case readInputRegisters = 4
    case writeSingleCoil = 5
    case writeSingleRegister = 6
    case writeMultipleCoils = 15
    case writeMultipleRegisters = 16
    public var id: UInt8 { rawValue }
    public var table: ModbusTable {
        switch self {
        case .readCoils, .writeSingleCoil, .writeMultipleCoils: .coil
        case .readDiscreteInputs: .discreteInput
        case .readHoldingRegisters, .writeSingleRegister, .writeMultipleRegisters: .holdingRegister
        case .readInputRegisters: .inputRegister
        }
    }
    public var isWrite: Bool {
        switch self { case .writeSingleCoil, .writeSingleRegister, .writeMultipleCoils, .writeMultipleRegisters: true; default: false }
    }
    public var maximumQuantity: Int {
        switch self {
        case .readCoils, .readDiscreteInputs: 2000
        case .readHoldingRegisters, .readInputRegisters: 125
        case .writeSingleCoil, .writeSingleRegister: 1
        case .writeMultipleCoils: 1968
        case .writeMultipleRegisters: 123
        }
    }
    /// The read that verifies a write, using the same zero-based address.
    public var readBackFunction: UInt8? {
        switch self {
        case .writeSingleCoil, .writeMultipleCoils: 1
        case .writeSingleRegister, .writeMultipleRegisters: 3
        default: nil
        }
    }
}

public struct ModbusDataAddress: Equatable, Sendable {
    public let zeroBased: UInt16
    /// Inferred from a five/six-digit reference; nil when the input was a
    /// plain zero-based value.
    public let table: ModbusTable?
    public init(zeroBased: UInt16, table: ModbusTable? = nil) {
        self.zeroBased = zeroBased; self.table = table
    }
}

public enum ModbusAddressText {
    /// Accepts a plain zero-based decimal/hex value or the conventional
    /// 0xxxx/1xxxx/3xxxx/4xxxx (and six-digit extended) reference.
    /// A value outside a valid reference range falls back to a plain address.
    public static func parse(_ text: String, expected: ModbusTable? = nil) throws -> ModbusDataAddress {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 16 else { throw ToolboxError.invalid("Modbus address") }
        if trimmed.lowercased().hasPrefix("0x") {
            let digits = trimmed.dropFirst(2)
            guard !digits.isEmpty, digits.utf8.allSatisfy({ hexNibble($0) != nil }), let value = UInt16(digits, radix: 16) else {
                throw ToolboxError.invalid("Modbus hex address")
            }
            return ModbusDataAddress(zeroBased: value, table: expected)
        }
        guard trimmed.utf8.allSatisfy({ (48...57).contains($0) }), let numeric = Int(trimmed) else {
            throw ToolboxError.invalid("Modbus address")
        }
        if trimmed.count == 5, let first = trimmed.first, let table = referenceTable(first) {
            let base = table.referenceBase
            if numeric >= base, numeric < base + 10_000 {
                if let expected, expected != table { throw ToolboxError.invalid("reference table does not match the function") }
                return ModbusDataAddress(zeroBased: UInt16(numeric - base), table: table)
            }
        }
        if trimmed.count == 6, let first = trimmed.first, let table = referenceTable(first) {
            let base = table.extendedReferenceBase
            if numeric >= base, numeric <= base + 65_535 {
                if let expected, expected != table { throw ToolboxError.invalid("reference table does not match the function") }
                return ModbusDataAddress(zeroBased: UInt16(numeric - base), table: table)
            }
        }
        guard let value = UInt16(trimmed) else { throw ToolboxError.invalid("Modbus address") }
        return ModbusDataAddress(zeroBased: value, table: expected)
    }

    /// Display the conventional reference alongside the actual PDU address.
    public static func reference(table: ModbusTable, zeroBased: UInt16) -> String {
        let value = Int(zeroBased)
        if value <= 9_998 {
            return String(format: "%05d", table.referenceBase + value)
        }
        return String(format: "%06d", table.extendedReferenceBase + value)
    }

    private static func referenceTable(_ first: Character) -> ModbusTable? {
        switch first { case "0": .coil; case "1": .discreteInput; case "3": .inputRegister; case "4": .holdingRegister; default: nil }
    }
    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}

/// A framing-independent envelope decoded from one wire frame.
public struct ModbusDecodedFrame: Equatable, Sendable {
    public let framing: ModbusFraming
    public let unit: UInt8
    public let pdu: Data
    public let transactionID: UInt16?
    public let bytes: Data
    public var function: UInt8 { pdu.first ?? 0 }
    public init(framing: ModbusFraming, unit: UInt8, pdu: Data, transactionID: UInt16?, bytes: Data) {
        self.framing = framing; self.unit = unit; self.pdu = pdu; self.transactionID = transactionID; self.bytes = bytes
    }
}

public enum ModbusCodec {
    public static func crc16(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0xffff
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xa001 : crc >> 1 }
        }
        return crc
    }
    /// Longitudinal redundancy check used by ASCII framing.
    public static func lrc(_ data: Data) -> UInt8 {
        var sum: UInt8 = 0
        for byte in data { sum &+= byte }
        return (0 &- sum)
    }

    // MARK: Envelope

    public static func encode(unit: UInt8, pdu: Data, framing: ModbusFraming, transactionID: UInt16 = 0) throws -> Data {
        guard !pdu.isEmpty, pdu.count <= 253, pdu.first != 0 else { throw ToolboxError.invalid("Modbus PDU") }
        switch framing {
        case .mbap:
            let length = pdu.count + 1
            guard length <= 254 else { throw ToolboxError.limit("Modbus MBAP frame") }
            return Data([UInt8(transactionID >> 8), UInt8(transactionID & 255), 0, 0,
                         UInt8(length >> 8), UInt8(length & 255), unit]) + pdu
        case .rtu:
            let body = Data([unit]) + pdu
            let crc = crc16(body)
            return body + Data([UInt8(crc & 255), UInt8(crc >> 8)])
        case .ascii:
            let body = Data([unit]) + pdu + Data([lrc(Data([unit]) + pdu)])
            let text = ":" + body.map { String(format: "%02X", $0) }.joined() + "\r\n"
            guard text.utf8.count <= 513 else { throw ToolboxError.limit("Modbus ASCII frame") }
            return Data(text.utf8)
        }
    }

    public static func decodeFrame(_ data: Data, framing: ModbusFraming) throws -> ModbusDecodedFrame {
        switch framing {
        case .mbap:
            guard data.count >= 8, data.count <= 260 else { throw ToolboxError.invalid("Modbus MBAP length") }
            let bytes = Array(data)
            let transaction = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            let protocolID = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
            let length = Int(bytes[4]) << 8 | Int(bytes[5])
            guard protocolID == 0, (2...254).contains(length), length + 6 == data.count else {
                throw ToolboxError.invalid("Modbus MBAP header")
            }
            let unit = bytes[6]
            let pdu = Data(bytes[7..<(6 + length)])
            guard !pdu.isEmpty else { throw ToolboxError.truncated("Modbus PDU") }
            return ModbusDecodedFrame(framing: .mbap, unit: unit, pdu: pdu, transactionID: transaction, bytes: data)
        case .rtu:
            guard data.count >= 5, data.count <= 256 else { throw ToolboxError.invalid("Modbus RTU length") }
            let body = Data(data.dropLast(2))
            let tail = Array(data.suffix(2))
            let expected = UInt16(tail[0]) | UInt16(tail[1]) << 8
            guard crc16(body) == expected else { throw ToolboxError.invalid("Modbus RTU CRC") }
            guard let unit = body.first, body.count >= 2 else { throw ToolboxError.truncated("Modbus RTU frame") }
            return ModbusDecodedFrame(framing: .rtu, unit: unit, pdu: Data(body.dropFirst()), transactionID: nil, bytes: data)
        case .ascii:
            guard data.count >= 11, data.count <= 513, data.first == 0x3a,
                  data.suffix(2) == Data([0x0d, 0x0a]) else { throw ToolboxError.invalid("Modbus ASCII frame") }
            let hex = data.dropFirst().dropLast(2)
            guard hex.count.isMultiple(of: 2), !hex.isEmpty,
                  hex.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw ToolboxError.invalid("Modbus ASCII hex")
            }
            var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
            var index = hex.startIndex
            while index < hex.endIndex {
                let end = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(String(decoding: hex[index..<end], as: UTF8.self), radix: 16) else {
                    throw ToolboxError.invalid("Modbus ASCII hex")
                }
                bytes.append(byte); index = end
            }
            guard bytes.count >= 3, bytes.count <= 255 else { throw ToolboxError.invalid("Modbus ASCII length") }
            let payload = Data(bytes.dropLast()), check = bytes.last ?? 0
            guard lrc(payload) == check else { throw ToolboxError.invalid("Modbus ASCII LRC") }
            let unit = bytes[0], pdu = Data(bytes[1..<(bytes.count - 1)])
            guard !pdu.isEmpty else { throw ToolboxError.truncated("Modbus PDU") }
            return ModbusDecodedFrame(framing: .ascii, unit: unit, pdu: pdu, transactionID: nil, bytes: data)
        }
    }

    public static func convert(_ data: Data, from: ModbusFraming, to: ModbusFraming, transactionID: UInt16? = nil) throws -> Data {
        let frame = try decodeFrame(data, framing: from)
        let write = ModbusOperationKind(rawValue: frame.function)?.isWrite == true &&
            (try? decodeBody(unit: frame.unit, pdu: frame.pdu, framing: from, response: false)) != nil
        try validate(unit: frame.unit, framing: from, write: write)
        try validate(unit: frame.unit, framing: to, write: write)
        return try encode(unit: frame.unit, pdu: frame.pdu, framing: to, transactionID: transactionID ?? frame.transactionID ?? 0)
    }

    // MARK: PDU

    public static func decode(_ data: Data, framing: ModbusFraming, response: Bool) throws -> ProtocolReport {
        let frame = try decodeFrame(data, framing: framing)
        return try decodeBody(unit: frame.unit, pdu: frame.pdu, framing: framing, response: response)
    }
    /// Compatibility overload kept for callers built before ASCII framing.
    public static func decode(_ data: Data, rtu: Bool = false, response: Bool) throws -> ProtocolReport {
        try decode(data, framing: rtu ? .rtu : .mbap, response: response)
    }
    public static func decodeAuto(_ data: Data, framing: ModbusFraming) throws -> ProtocolReport {
        let frame = try decodeFrame(data, framing: framing)
        if let request = try? decodeBody(unit: frame.unit, pdu: frame.pdu, framing: framing, response: false) {
            if [1, 2].contains(frame.function),
               (try? decodeBody(unit: frame.unit, pdu: frame.pdu, framing: framing, response: true)) != nil {
                return ProtocolReport(name: request.name, summary: "Request or response",
                    fields: ["unitID": String(frame.unit), "function": String(frame.function), "direction": "requestOrResponse"])
            }
            return request
        }
        return try decodeBody(unit: frame.unit, pdu: frame.pdu, framing: framing, response: true)
    }

    /// True only for a frame that cannot also represent a valid request.
    public static func isResponse(_ frame: ModbusDecodedFrame) -> Bool {
        (try? decodeAuto(frame.bytes, framing: frame.framing))?.fields["direction"] == "response"
    }

    private static func decodeBody(unit: UInt8, pdu: Data, framing: ModbusFraming, response: Bool) throws -> ProtocolReport {
        var p = ByteReader(pdu); let function = try p.u8()
        guard function != 0 else { throw ToolboxError.invalid("Modbus function") }
        try validate(unit: unit, framing: framing, write: !response && ModbusOperationKind(rawValue: function)?.isWrite == true)
        var fields: [String: String] = ["unitID": String(unit), "function": String(function),
                                        "direction": response ? "response" : "request"]
        let name = switch framing { case .mbap: "Modbus TCP"; case .rtu: "Modbus RTU"; case .ascii: "Modbus ASCII" }
        if function & 0x80 != 0 {
            guard response, p.remaining == 1 else { throw ToolboxError.invalid("Modbus exception") }
            let code = try p.u8()
            fields["exceptionCode"] = String(code)
            if let exceptionName = exceptionName(code) { fields["exceptionName"] = exceptionName }
            return ProtocolReport(name: name, summary: "Exception response", fields: fields)
        }
        if [1, 2, 3, 4].contains(function) {
            if response {
                let byteCount = Int(try p.u8())
                guard byteCount == p.remaining, byteCount > 0, byteCount <= 250,
                      function < 3 || byteCount.isMultiple(of: 2) else { throw ToolboxError.invalid("Modbus byte count") }
                fields["byteCount"] = String(byteCount)
                if function >= 3 {
                    var values: [String] = []
                    while p.remaining > 0 { values.append(String(try p.u16())) }
                    fields["registerValues"] = values.joined(separator: ",")
                    fields["byteOrder"] = "big-endian"
                } else {
                    let bytes = try p.take(byteCount)
                    fields["packedCoilsHex"] = Data(bytes).hex
                    fields["bitOrder"] = "LSB-first"
                }
            } else {
                guard p.remaining == 4 else { throw ToolboxError.invalid("Modbus read request length") }
                let address = try p.u16(), quantity = try p.u16()
                guard quantity > 0, Int(quantity) <= (function < 3 ? 2000 : 125),
                      Int(address) + Int(quantity) <= 65536 else { throw ToolboxError.invalid("Modbus read range") }
                fields["zeroBasedAddress"] = String(address); fields["quantity"] = String(quantity)
            }
        } else if [5, 6, 15, 16].contains(function) {
            guard p.remaining >= 4 else { throw ToolboxError.truncated("Modbus write") }
            let address = try p.u16(), value = try p.u16()
            fields["zeroBasedAddress"] = String(address); fields["valueOrQuantity"] = String(value)
            if function == 5, ![0, 0xff00].contains(value) { throw ToolboxError.invalid("Modbus coil value") }
            if function >= 15 {
                guard value > 0, Int(value) <= (function == 15 ? 1968 : 123),
                      Int(address) + Int(value) <= 65536 else { throw ToolboxError.invalid("Modbus write range") }
            }
            if function <= 6 || response {
                guard p.remaining == 0 else { throw ToolboxError.invalid("Modbus write length") }
            } else {
                let size = Int(try p.u8())
                let expected = function == 15 ? (Int(value) + 7) / 8 : Int(value) * 2
                guard size == p.remaining, size == expected else { throw ToolboxError.invalid("Modbus write byte count") }
                let payload = try p.take(size)
                if function == 15, size > 0, Int(value) % 8 != 0, let last = payload.last {
                    let mask = UInt8(0xff) << UInt8(Int(value) % 8)
                    if last & mask != 0 { throw ToolboxError.invalid("Modbus coil padding") }
                }
                fields["payloadHex"] = Data(payload).hex
            }
        } else {
            return ProtocolReport(name: name, summary: "Unrecognized function", fields: fields,
                                  warnings: ["Payload preserved; unsupported function is not inferred."])
        }
        if [5, 6].contains(function) { fields["direction"] = "requestOrEcho" }
        let summary = [5, 6].contains(function) ? "Request or write echo" : (response ? "Response" : "Request")
        return ProtocolReport(name: name, summary: summary, fields: fields)
    }

    public static func exceptionName(_ code: UInt8) -> String? {
        switch code {
        case 0x01: "ILLEGAL FUNCTION"
        case 0x02: "ILLEGAL DATA ADDRESS"
        case 0x03: "ILLEGAL DATA VALUE"
        case 0x04: "SERVER DEVICE FAILURE"
        case 0x05: "ACKNOWLEDGE"
        case 0x06: "SERVER DEVICE BUSY"
        case 0x08: "MEMORY PARITY ERROR"
        case 0x0a: "GATEWAY PATH UNAVAILABLE"
        case 0x0b: "GATEWAY TARGET DEVICE FAILED TO RESPOND"
        default: nil
        }
    }

    // MARK: Construction helpers

    public static func readRequest(unit: UInt8, function: UInt8 = 3, address: UInt16, count: UInt16,
                                   transactionID: UInt16 = 1, rtu: Bool = false) throws -> Data {
        try readRequest(unit: unit, function: function, address: address, count: count,
                        transactionID: transactionID, framing: rtu ? .rtu : .mbap)
    }
    public static func readRequest(unit: UInt8, function: UInt8 = 3, address: UInt16, count: UInt16,
                                   transactionID: UInt16 = 1, framing: ModbusFraming) throws -> Data {
        guard [1, 2, 3, 4].contains(function), count > 0,
              Int(count) <= (function <= 2 ? 2000 : 125), Int(address) + Int(count) <= 65536 else {
            throw ToolboxError.invalid("Modbus read range")
        }
        try validate(unit: unit, framing: framing, write: false)
        let pdu = Data([function, UInt8(address >> 8), UInt8(address & 255), UInt8(count >> 8), UInt8(count & 255)])
        return try encode(unit: unit, pdu: pdu, framing: framing, transactionID: transactionID)
    }

    /// The official serial-line address space is 1...247; 0 is broadcast and
    /// 248...255 are reserved. MBAP's unit identifier keeps the full byte range.
    public static func validate(unit: UInt8, framing: ModbusFraming, write: Bool) throws {
        guard framing.isSerialLine else { return }
        if unit == 0 {
            guard write else { throw ToolboxError.invalid("Broadcast is only valid for writes") }
            return
        }
        guard (1...247).contains(unit) else { throw ToolboxError.invalid("Modbus serial unit address") }
    }

    public static func packCoils(_ values: [Bool]) -> Data {
        guard !values.isEmpty else { return Data() }
        var packed = Data(repeating: 0, count: (values.count + 7) / 8)
        for (index, value) in values.enumerated() where value {
            packed[index / 8] |= 1 << UInt8(index % 8)
        }
        return packed
    }
    public static func unpackCoils(_ data: Data, count: Int) throws -> [Bool] {
        guard count >= 0, count <= 2000, data.count == (count + 7) / 8 else { throw ToolboxError.invalid("Modbus coil count") }
        return (0..<count).map { index in
            (data[data.startIndex + index / 8] & (1 << UInt8(index % 8))) != 0
        }
    }
    public static func registerValues(_ data: Data) throws -> [UInt16] {
        guard data.count.isMultiple(of: 2) else { throw ToolboxError.invalid("Modbus register bytes") }
        var reader = ByteReader(data), values: [UInt16] = []
        while reader.remaining > 0 { values.append(try reader.u16()) }
        return values
    }
}
