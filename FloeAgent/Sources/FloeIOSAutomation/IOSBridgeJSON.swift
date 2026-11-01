// FloeIOSAutomation — bounded JSON value used by the local iOS Bridge wire.
//
// The value type mirrors the released Floe iOS Bridge v1 JSON surface. Keys
// are dictionaries, so callers must never rely on object key ordering.

import Foundation

public enum IOSBridgeJSONValue: Sendable, Equatable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([IOSBridgeJSONValue])
    case object([String: IOSBridgeJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([IOSBridgeJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: IOSBridgeJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value):
            guard value.rounded() == value,
                  value >= Double(Int.min),
                  value <= Double(Int.max) else { return nil }
            return Int(value)
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value.isFinite ? value : nil
        case .int(let value):
            return Double(value)
        default:
            return nil
        }
    }

    public var arrayValue: [IOSBridgeJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: IOSBridgeJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Canonical encoding used for request bodies and digests: sorted keys,
    /// no escaped slashes and deterministic number formatting.
    public func canonicalData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public func canonicalString() -> String {
        String(decoding: canonicalData(), as: UTF8.self)
    }

    public static func decode(_ data: Data) throws -> IOSBridgeJSONValue {
        try JSONDecoder().decode(IOSBridgeJSONValue.self, from: data)
    }

    public static func object(_ pairs: (String, IOSBridgeJSONValue)...) -> IOSBridgeJSONValue {
        .object(Dictionary(uniqueKeysWithValues: pairs))
    }
}
