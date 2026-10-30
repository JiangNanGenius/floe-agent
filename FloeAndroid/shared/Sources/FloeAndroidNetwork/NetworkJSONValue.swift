// SPDX-License-Identifier: MPL-2.0
//
// G07.1/G07.2 network diagnostics — a small, exact JSON value model.
//
// The Android platform service owns the NetworkObservationV1 envelope and
// every measured number. This module NEVER synthesizes a measurement: it
// decodes what the phone reported, validates the envelope identity, keeps
// unmodeled fields intact for honest export, and renders a bounded summary.
// `NetworkJSONValue` exists so the open `network` / `observations` objects can
// be preserved without turning the whole result into an opaque string.
import Foundation

public enum NetworkJSONValue: Sendable, Equatable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([NetworkJSONValue])
    case object([String: NetworkJSONValue])
}

extension NetworkJSONValue: Decodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Int.self) {
            self = .int(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([NetworkJSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: NetworkJSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "unsupported JSON value")
    }
}

public extension NetworkJSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value) where value.rounded() == value
            && value >= Double(Int.min) && value <= Double(Int.max):
            return Int(value)
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    var arrayValue: [NetworkJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: NetworkJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Foundation JSON object for `JSONSerialization` only. Never crosses an
    /// isolation boundary; used to export the already-validated envelope.
    var foundationObject: Any {
        switch self {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map(\.foundationObject)
        case .object(let values): return values.mapValues(\.foundationObject)
        }
    }

    /// First present key with a usable value (services may spell optional
    /// fields slightly differently; absent stays absent — nothing is guessed).
    static func first(_ object: [String: NetworkJSONValue], _ keys: [String]) -> NetworkJSONValue? {
        for key in keys {
            if let value = object[key], value != .null { return value }
        }
        return nil
    }

    static func firstString(_ object: [String: NetworkJSONValue], _ keys: [String]) -> String? {
        first(object, keys)?.stringValue
    }

    static func firstInt(_ object: [String: NetworkJSONValue], _ keys: [String]) -> Int? {
        first(object, keys)?.intValue
    }

    static func firstDouble(_ object: [String: NetworkJSONValue], _ keys: [String]) -> Double? {
        first(object, keys)?.doubleValue
    }

    static func firstBool(_ object: [String: NetworkJSONValue], _ keys: [String]) -> Bool? {
        first(object, keys)?.boolValue
    }

    static func firstArray(_ object: [String: NetworkJSONValue], _ keys: [String]) -> [NetworkJSONValue]? {
        first(object, keys)?.arrayValue
    }
}
