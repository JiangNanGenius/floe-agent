// SPDX-License-Identifier: MPL-2.0
//
// FloeManufacturingParameters — dependency-free manufacturing parameter
// catalog + typed JSON-like values + set/preset persistence.
//
// Source-backed descriptors; see parameters-evidence/API.md for the stable
// public contract and parameters-evidence/SOURCES.md for the field-level
// provenance mapping.

import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// A JSON-like, strongly typed parameter value.
///
/// Encoding uses an explicit type tag so `integer(3)` and `number(3.0)` stay
/// distinguishable after a save/load round-trip, and so unknown nested
/// structured values (future parameter IDs, nested objects/arrays) survive
/// unchanged in both structure and meaning.
public enum ManufacturingParameterValue: Codable, Equatable, Sendable {
    case number(Double)
    case integer(Int64)
    case boolean(Bool)
    case string(String)
    case array([ManufacturingParameterValue])
    case object([String: ManufacturingParameterValue])
    case null

    private enum CodingKeys: String, CodingKey { case type, value }

    private enum ValueType: String, Codable {
        case number, integer, boolean, string, array, object, null
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(ValueType.self, forKey: .type)
        switch type {
        case .number:
            self = .number(try c.decode(Double.self, forKey: .value))
        case .integer:
            self = .integer(try c.decode(Int64.self, forKey: .value))
        case .boolean:
            self = .boolean(try c.decode(Bool.self, forKey: .value))
        case .string:
            self = .string(try c.decode(String.self, forKey: .value))
        case .array:
            self = .array(try c.decode([ManufacturingParameterValue].self, forKey: .value))
        case .object:
            self = .object(try c.decode([String: ManufacturingParameterValue].self, forKey: .value))
        case .null:
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .number(let v): try c.encode(ValueType.number, forKey: .type); try c.encode(v, forKey: .value)
        case .integer(let v): try c.encode(ValueType.integer, forKey: .type); try c.encode(v, forKey: .value)
        case .boolean(let v): try c.encode(ValueType.boolean, forKey: .type); try c.encode(v, forKey: .value)
        case .string(let v): try c.encode(ValueType.string, forKey: .type); try c.encode(v, forKey: .value)
        case .array(let v): try c.encode(ValueType.array, forKey: .type); try c.encode(v, forKey: .value)
        case .object(let v): try c.encode(ValueType.object, forKey: .type); try c.encode(v, forKey: .value)
        case .null: try c.encode(ValueType.null, forKey: .type)
        }
    }

    /// Convenience accessors (nil when the case does not match).
    public var doubleValue: Double? {
        if case .number(let v) = self { return v }
        return nil
    }
    public var intValue: Int64? {
        if case .integer(let v) = self { return v }
        return nil
    }
    public var boolValue: Bool? {
        if case .boolean(let v) = self { return v }
        return nil
    }
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }
    public var arrayValue: [ManufacturingParameterValue]? {
        if case .array(let v) = self { return v }
        return nil
    }
    public var objectValue: [String: ManufacturingParameterValue]? {
        if case .object(let v) = self { return v }
        return nil
    }
    public var isNull: Bool { self == .null }

    /// Numeric magnitude when the value is `.number` or `.integer`, else nil.
    public var numericMagnitude: Double? {
        switch self {
        case .number(let v): return v
        case .integer(let v): return Double(v)
        default: return nil
        }
    }

    /// Decode a raw (untagged) JSON value, preserving structure.
    ///
    /// Precision contract: JSON integers that fit `Int64` are preserved
    /// exactly (including values above 2^53, e.g. identifiers). JSON numbers
    /// with a fractional exponent stay `.number`. Non-integral or out-of
    /// -Int64-range values fall back to `Double` and may lose precision
    /// beyond 2^53 — this loss is documented, not silent.
    public static func fromRawJSON(_ data: Data) throws -> ManufacturingParameterValue {
        let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return Self.fromJSONObject(decoded)
    }

    static func fromJSONObject(_ object: Any) -> ManufacturingParameterValue {
        switch object {
        case is NSNull:
            return .null
        case let n as NSNumber:
            if Self.isBooleanNumber(n) { return .boolean(n.boolValue) }
            // Prefer the concrete Objective-C / CoreFoundation numeric type so
            // integer 1 and real 1.0 decode as .integer(1) / .number(1.0)
            // respectively, and integers keep full Int64 precision (no 2^53
            // clamp) whenever they are exactly representable.
            #if canImport(Darwin)
            let type = String(cString: n.objCType)
            switch type {
            case "c", "C", "s", "S", "i", "I", "l", "L", "q", "Q":
                if let exact = Int64(exactly: n) { return .integer(exact) }
                // Unsigned or out-of-range value: keep as Double with the
                // documented 2^53 precision ceiling.
                return .number(n.doubleValue)
            default:
                return .number(n.doubleValue)
            }
            #else
            let d = n.doubleValue
            if d.rounded() == d, abs(d) <= 9.007199254740992e15 {
                return .integer(n.int64Value)
            }
            return .number(d)
            #endif
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map { Self.fromJSONObject($0) })
        case let o as [String: Any]:
            return .object(o.mapValues { Self.fromJSONObject($0) })
        default:
            return .string(String(describing: object))
        }
    }

    static func isBooleanNumber(_ n: NSNumber) -> Bool {
        #if canImport(CoreFoundation)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        return false
        #endif
    }
}
