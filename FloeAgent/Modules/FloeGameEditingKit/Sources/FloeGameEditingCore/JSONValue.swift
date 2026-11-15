// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// A typed, Sendable JSON tree used by all editor documents.
/// Unknown keys/values round-trip losslessly; no engine schema is implied.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var isNull: Bool { if case .null = self { return true }; return false }
    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    public var numberValue: Double? { if case .number(let value) = self { return value }; return nil }
    public var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value, abs(value) <= 9.0e15 else { return nil }
        return Int(value)
    }
    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Lossy conversion from Foundation JSON objects.
    public init(foundation value: Any) {
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber:
            // JSONSerialization represents booleans as CFBoolean, which also
            // bridges to NSNumber. Check the CoreFoundation type so numeric
            // 0/1 are not misread as booleans.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { JSONValue(foundation: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { JSONValue(foundation: $0) })
        default: self = .null
        }
    }

    /// Foundation representation for JSONSerialization.
    public var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map { $0.foundationValue }
        case .object(let values): return values.mapValues { $0.foundationValue }
        }
    }

    /// Short human-readable form for previews (not a serialization contract).
    public var displayText: String {
        switch self {
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value.rounded() == value ? String(Int(value)) : String(value)
        case .string(let value): return value
        case .array(let values): return "[" + values.map(\.displayText).joined(separator: ", ") + "]"
        case .object: return "{…}"
        }
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        guard data.count <= 64 * 1_024 * 1_024 else { throw GameProjectError.limitExceeded("jsonBytes") }
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSONValue(foundation: object)
    }

    /// Deterministic serialization (sorted keys) so undo/redo and diff
    /// comparisons stay stable across runs.
    public func serialized() throws -> Data {
        try JSONSerialization.data(withJSONObject: foundationValue, options: [.sortedKeys, .fragmentsAllowed])
    }
}

public enum JSONFieldComponent: Hashable, Sendable, Codable {
    case key(String)
    case index(Int)
}

/// A path into a JSON document. Mirrors GameJSONPathComponent semantics.
public struct JSONFieldPath: Hashable, Sendable {
    public let components: [JSONFieldComponent]
    public init(_ components: [JSONFieldComponent]) { self.components = components }
    public static func key(_ key: String) -> JSONFieldPath { JSONFieldPath([.key(key)]) }
    public func appending(_ component: JSONFieldComponent) -> JSONFieldPath {
        JSONFieldPath(components + [component])
    }

    public func lookup(in value: JSONValue) -> JSONValue? {
        var current = value
        for component in components {
            switch component {
            case .key(let key): current = current[key] ?? .null
            case .index(let index): current = current[index] ?? .null
            }
        }
        return current
    }

    /// Structural replacement; sibling/unknown entries are preserved.
    public func replacing(in root: JSONValue, with replacement: JSONValue) throws -> JSONValue {
        guard !components.isEmpty, components.count <= 64 else { throw GameProjectError.invalidEdit }
        func apply(_ object: JSONValue, _ index: Int) throws -> JSONValue {
            guard index < components.count else { return replacement }
            switch components[index] {
            case .key(let key):
                guard var dictionary = object.objectValue, let child = dictionary[key] else {
                    throw GameProjectError.invalidEdit
                }
                dictionary[key] = try apply(child, index + 1)
                return .object(dictionary)
            case .index(let position):
                guard var array = object.arrayValue, array.indices.contains(position) else {
                    throw GameProjectError.invalidEdit
                }
                array[position] = try apply(array[position], index + 1)
                return .array(array)
            }
        }
        return try apply(root, 0)
    }
}
