import Foundation

/// Typed, bounded access to one RPC method's parameters.
///
/// The executor parses every method argument through this type before it
/// touches XCTest. It never logs or returns a raw parameter value; callers
/// decide separately which normalized facts are safe to report.
public struct BridgeEngineParameterError: Error, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

public struct BridgeEngineParameters: Sendable {
    public let values: [String: BridgeRPCJSONValue]

    public init(_ value: BridgeRPCJSONValue?) throws {
        guard let value else {
            self.values = [:]
            return
        }
        guard let object = value.objectValue else {
            throw BridgeEngineParameterError("params must be a JSON object.")
        }
        self.values = object
    }

    public init(object: [String: BridgeRPCJSONValue]) {
        self.values = object
    }

    public func has(_ key: String) -> Bool {
        values[key] != nil && values[key]?.isNull != true
    }

    public func string(_ key: String,
                       required: Bool = false,
                       maximumBytes: Int = 4_096) throws -> String? {
        guard let raw = values[key], !raw.isNull else {
            if required { throw BridgeEngineParameterError("Missing required string parameter '\(key)'.") }
            return nil
        }
        guard let text = raw.stringValue else {
            throw BridgeEngineParameterError("Parameter '\(key)' must be a string.")
        }
        guard text.utf8.count <= maximumBytes else {
            throw BridgeEngineParameterError("Parameter '\(key)' exceeds \(maximumBytes) bytes.")
        }
        return text
    }

    public func requiredString(_ key: String,
                               maximumBytes: Int = 4_096) throws -> String {
        guard let value = try string(key, required: true, maximumBytes: maximumBytes) else {
            throw BridgeEngineParameterError("Missing required string parameter '\(key)'.")
        }
        return value
    }

    public func bool(_ key: String) throws -> Bool? {
        guard let raw = values[key], !raw.isNull else { return nil }
        guard let value = raw.boolValue else {
            throw BridgeEngineParameterError("Parameter '\(key)' must be a boolean.")
        }
        return value
    }

    public func double(_ key: String) throws -> Double? {
        guard let raw = values[key], !raw.isNull else { return nil }
        guard let value = raw.doubleValue, value.isFinite else {
            throw BridgeEngineParameterError("Parameter '\(key)' must be a finite number.")
        }
        return value
    }

    public func int(_ key: String) throws -> Int? {
        guard let raw = values[key], !raw.isNull else { return nil }
        guard let value = raw.intValue else {
            throw BridgeEngineParameterError("Parameter '\(key)' must be an integer.")
        }
        return value
    }

    public func object(_ key: String) throws -> [String: BridgeRPCJSONValue]? {
        guard let raw = values[key], !raw.isNull else { return nil }
        guard let object = raw.objectValue else {
            throw BridgeEngineParameterError("Parameter '\(key)' must be an object.")
        }
        return object
    }

    public func array(_ key: String) throws -> [BridgeRPCJSONValue]? {
        guard let raw = values[key], !raw.isNull else { return nil }
        guard let array = raw.arrayValue else {
            throw BridgeEngineParameterError("Parameter '\(key)' must be an array.")
        }
        return array
    }

    /// Reads one of a fixed string set case-insensitively. The returned value
    /// is the canonical lower-case spelling, never the caller's casing.
    public func option(_ key: String,
                       allowed: [String],
                       default defaultValue: String? = nil) throws -> String? {
        guard let raw = try string(key) else { return defaultValue }
        let lower = raw.lowercased()
        guard allowed.contains(lower) else {
            throw BridgeEngineParameterError(
                "Parameter '\(key)' must be one of: \(allowed.joined(separator: ", "))."
            )
        }
        return lower
    }

    /// A bounded integer in an inclusive range, or the default.
    public func integer(_ key: String,
                        default defaultValue: Int,
                        range: ClosedRange<Int>) throws -> Int {
        guard let raw = try int(key) else { return defaultValue }
        guard range.contains(raw) else {
            throw BridgeEngineParameterError(
                "Parameter '\(key)' must be between \(range.lowerBound) and \(range.upperBound)."
            )
        }
        return raw
    }

    /// A bounded finite double in an inclusive range, or the default.
    public func number(_ key: String,
                       default defaultValue: Double,
                       range: ClosedRange<Double>) throws -> Double {
        guard let raw = try double(key) else { return defaultValue }
        guard range.contains(raw) else {
            throw BridgeEngineParameterError(
                "Parameter '\(key)' must be between \(range.lowerBound) and \(range.upperBound)."
            )
        }
        return raw
    }
}

/// Parsed settle parameters shared by actions.
public struct BridgeEngineSettleParameters: Sendable {
    public var requested: Bool
    public var timeout: TimeInterval

    public init(requested: Bool, timeout: TimeInterval) {
        self.requested = requested
        self.timeout = timeout
    }

    public static func parse(_ params: BridgeEngineParameters) throws -> BridgeEngineSettleParameters {
        let requested = try params.bool("settle") ?? true
        let timeout = try params.number("settle_timeout", default: 2, range: 0...3)
        return BridgeEngineSettleParameters(requested: requested, timeout: timeout)
    }
}
