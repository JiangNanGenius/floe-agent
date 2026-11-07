// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum BiologyError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String), conflict(expected: UInt64, actual: UInt64), unavailable(String), corrupt(String), cancelled
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s), .corrupt(let s): s
        case .conflict(let expected, let actual):
            "Project changed: expected revision \(expected), found \(actual)."
        case .cancelled: "Cancelled."
        }
    }
}

/// Untyped but bounded JSON used for run options and worker-compatible results.
public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> JSONValue? { if case .object(let v) = self { v[key] } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
}
