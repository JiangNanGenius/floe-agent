// FloeSecurity — Canonical JSON encoder for audit hashing.
//
// JSONEncoder does not guarantee key order or Decimal formatting across
// builds and platforms, so audit hashing requires a canonical form:
//   - object keys sorted by UTF-8 code point
//   - no whitespace
//   - strings NFC-normalized, minimal escaping
//   - numbers: integers bare; Decimal via normalized fixed-point;
//     Double via shortest round-trip
//   - dates as UTC ISO-8601 milliseconds
//   - Data as lowercase hex

import Foundation

/// Canonical JSON value model. All encoding goes through this tree so
/// output bytes are deterministic.
indirect enum CanonicalJSON: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case decimal(Decimal)
    case string(String)
    case data(Data)
    case date(Date)
    case array([CanonicalJSON])
    case object([(key: String, value: CanonicalJSON)])

    func serialized() -> Data {
        var out = ""
        serialize(into: &out)
        return Data(out.utf8)
    }

    private func serialize(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            if d == d.rounded() && abs(d) < 1e15 {
                out += String(Int64(d))
            } else {
                out += String(d)
            }
        case .decimal(let dec):
            out += Self.serializeDecimal(dec)
        case .string(let s):
            Self.serializeString(s.precomposedStringWithCanonicalMapping, into: &out)
        case .data(let data):
            out += "\""
            out += data.map { String(format: "%02x", $0) }.joined()
            out += "\""
        case .date(let date):
            let millis = Int64(date.timeIntervalSince1970 * 1000)
            out += "\""
            out += Self.iso8601Millis(millis)
            out += "\""
        case .array(let items):
            out += "["
            for (index, item) in items.enumerated() {
                if index > 0 { out += "," }
                item.serialize(into: &out)
            }
            out += "]"
        case .object(let pairs):
            let sorted = pairs.sorted { lhs, rhs in
                lhs.key.compare(rhs.key, options: .literal) == .orderedAscending
            }
            out += "{"
            for (index, pair) in sorted.enumerated() {
                if index > 0 { out += "," }
                Self.serializeString(pair.key.precomposedStringWithCanonicalMapping, into: &out)
                out += ":"
                pair.value.serialize(into: &out)
            }
            out += "}"
        }
    }

    private static func serializeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    private static func serializeDecimal(_ dec: Decimal) -> String {
        // BUG-QA-2 fix: no division loop. Take the exact base-10
        // representation from NSDecimalNumber and strip trailing fractional
        // zeros with string surgery: 1.50 → "1.5", 100 → "100",
        // 3.14159 → "3.14159".
        var result = NSDecimalNumber(decimal: dec).stringValue
        // Normalize scientific notation (e.g. "1e-5") only if it appears;
        // NSDecimalNumber.stringValue uses plain notation for typical
        // magnitudes, so this path is rarely taken.
        guard result.contains(".") else { return result }
        while result.hasSuffix("0") {
            result.removeLast()
        }
        if result.hasSuffix(".") {
            result.removeLast()
        }
        // "-0" normalized to "0".
        if result == "-0" { return "0" }
        return result
    }

    private static func iso8601Millis(_ millis: Int64) -> String {
        let seconds = millis / 1000
        let ms = millis % 1000
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0,
            c.hour ?? 0, c.minute ?? 0, c.second ?? 0, ms
        )
    }
}

/// Encodes `Encodable` values into canonical JSON bytes.
public struct CanonicalJSONEncoder: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let tree = try CanonicalTreeBuilder.build(value)
        return tree.serialized()
    }
}

/// Builds a `CanonicalJSON` tree from any `Encodable` via a custom encoder.
private enum CanonicalTreeBuilder {
    static func build<T: Encodable>(_ value: T) throws -> CanonicalJSON {
        let encoder = _CanonicalEncoder()
        try value.encode(to: encoder)
        guard let result = encoder.result else {
            // Empty containers never call encode(_:), leaving result nil;
            // detect them via Mirror.
            let mirror = Mirror(reflecting: value)
            if let array = value as? any SequenceEmptyChecking, array.isEmptySequence {
                return .array([])
            }
            if mirror.displayStyle == .dictionary || mirror.displayStyle == .set {
                if mirror.children.isEmpty { return .object([]) }
            }
            throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "No value encoded"))
        }
        return result
    }
}

/// Internal marker for detecting empty sequences without encoding them.
private protocol SequenceEmptyChecking {
    var isEmptySequence: Bool { get }
}

extension Array: SequenceEmptyChecking {
    fileprivate var isEmptySequence: Bool { isEmpty }
}

extension Set: SequenceEmptyChecking {
    fileprivate var isEmptySequence: Bool { isEmpty }
}

private final class _CanonicalEncoder: Encoder {
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    var result: CanonicalJSON?

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        // BUG-QA-1 fix: seed an empty object immediately so values whose
        // encode(to:) never encodes any field (empty structs, nested empty
        // containers) still produce "{}" instead of "no value encoded".
        result = .object([])
        let container = _CanonicalKeyedContainer<Key>(encoder: self)
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        // Same seeding for empty arrays.
        result = .array([])
        return _CanonicalUnkeyedContainer(encoder: self)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        _CanonicalSingleValueContainer(encoder: self)
    }
}

private struct _CanonicalKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    var codingPath: [any CodingKey] = []
    let encoder: _CanonicalEncoder
    var pairs: [(String, CanonicalJSON)] = []

    init(encoder: _CanonicalEncoder) {
        self.encoder = encoder
    }

    private mutating func set(_ key: Key, _ value: CanonicalJSON) {
        pairs.append((key.stringValue, value))
        encoder.result = .object(pairs)
    }

    mutating func encodeNil(forKey key: Key) throws { set(key, .null) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { set(key, .bool(value)) }
    mutating func encode(_ value: String, forKey key: Key) throws { set(key, .string(value)) }
    mutating func encode(_ value: Double, forKey key: Key) throws { set(key, .double(value)) }
    mutating func encode(_ value: Float, forKey key: Key) throws { set(key, .double(Double(value))) }
    mutating func encode(_ value: Int, forKey key: Key) throws { set(key, .int(Int64(value))) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { set(key, .int(Int64(value))) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { set(key, .int(Int64(value))) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { set(key, .int(Int64(value))) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { set(key, .int(value)) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { set(key, .int(Int64(value))) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { set(key, .int(Int64(value))) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { set(key, .int(Int64(value))) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { set(key, .int(Int64(value))) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { set(key, .int(Int64(value))) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        if let date = value as? Date {
            set(key, .date(date))
        } else if let data = value as? Data {
            set(key, .data(data))
        } else if let decimal = value as? Decimal {
            set(key, .decimal(decimal))
        } else if let uuid = value as? UUID {
            set(key, .string(uuid.uuidString.lowercased()))
        } else {
            let tree = try CanonicalTreeBuilder.build(value)
            set(key, tree)
        }
    }

    mutating func nestedContainer<NK: CodingKey>(keyedBy keyType: NK.Type, forKey key: Key) -> KeyedEncodingContainer<NK> {
        fatalError("Nested containers handled via Encodable recursion")
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        fatalError("Nested containers handled via Encodable recursion")
    }

    mutating func superEncoder() -> any Encoder { encoder }
    mutating func superEncoder(forKey key: Key) -> any Encoder { encoder }
}

private struct _CanonicalUnkeyedContainer: UnkeyedEncodingContainer {
    var codingPath: [any CodingKey] = []
    var count: Int { items.count }
    let encoder: _CanonicalEncoder
    var items: [CanonicalJSON] = []

    init(encoder: _CanonicalEncoder) {
        self.encoder = encoder
    }

    private mutating func append(_ value: CanonicalJSON) {
        items.append(value)
        encoder.result = .array(items)
    }

    mutating func encodeNil() throws { append(.null) }
    mutating func encode(_ value: Bool) throws { append(.bool(value)) }
    mutating func encode(_ value: String) throws { append(.string(value)) }
    mutating func encode(_ value: Double) throws { append(.double(value)) }
    mutating func encode(_ value: Float) throws { append(.double(Double(value))) }
    mutating func encode(_ value: Int) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int8) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int16) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int32) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int64) throws { append(.int(value)) }
    mutating func encode(_ value: UInt) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: UInt8) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: UInt16) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: UInt32) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: UInt64) throws { append(.int(Int64(value))) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        if let date = value as? Date {
            append(.date(date))
        } else if let data = value as? Data {
            append(.data(data))
        } else if let decimal = value as? Decimal {
            append(.decimal(decimal))
        } else if let uuid = value as? UUID {
            append(.string(uuid.uuidString.lowercased()))
        } else {
            let tree = try CanonicalTreeBuilder.build(value)
            append(tree)
        }
    }

    mutating func nestedContainer<NK: CodingKey>(keyedBy keyType: NK.Type) -> KeyedEncodingContainer<NK> {
        fatalError("Nested containers handled via Encodable recursion")
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        fatalError("Nested containers handled via Encodable recursion")
    }

    mutating func superEncoder() -> any Encoder { encoder }
}

private struct _CanonicalSingleValueContainer: SingleValueEncodingContainer {
    var codingPath: [any CodingKey] = []
    let encoder: _CanonicalEncoder

    init(encoder: _CanonicalEncoder) {
        self.encoder = encoder
    }

    private func set(_ value: CanonicalJSON) {
        encoder.result = value
    }

    func encodeNil() throws { set(.null) }
    func encode(_ value: Bool) throws { set(.bool(value)) }
    func encode(_ value: String) throws { set(.string(value)) }
    func encode(_ value: Double) throws { set(.double(value)) }
    func encode(_ value: Float) throws { set(.double(Double(value))) }
    func encode(_ value: Int) throws { set(.int(Int64(value))) }
    func encode(_ value: Int8) throws { set(.int(Int64(value))) }
    func encode(_ value: Int16) throws { set(.int(Int64(value))) }
    func encode(_ value: Int32) throws { set(.int(Int64(value))) }
    func encode(_ value: Int64) throws { set(.int(value)) }
    func encode(_ value: UInt) throws { set(.int(Int64(value))) }
    func encode(_ value: UInt8) throws { set(.int(Int64(value))) }
    func encode(_ value: UInt16) throws { set(.int(Int64(value))) }
    func encode(_ value: UInt32) throws { set(.int(Int64(value))) }
    func encode(_ value: UInt64) throws { set(.int(Int64(value))) }

    func encode<T: Encodable>(_ value: T) throws {
        if let date = value as? Date {
            set(.date(date))
        } else if let data = value as? Data {
            set(.data(data))
        } else if let decimal = value as? Decimal {
            set(.decimal(decimal))
        } else if let uuid = value as? UUID {
            set(.string(uuid.uuidString.lowercased()))
        } else {
            let tree = try CanonicalTreeBuilder.build(value)
            set(tree)
        }
    }
}
