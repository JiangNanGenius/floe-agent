import Foundation
import CryptoKit
import FloeCanvasCore
import FloeCanvasIntegration

// MARK: - Flow runtime errors
//
// Every failure the runtime raises is recoverable by the host: compile
// errors carry the full issue list, run errors name the run and the
// violated rule. Nothing here logs, crashes or fabricates model results.

public enum FlowRuntimeError: Error, Hashable, Sendable {
    /// The graph (or a selected scope of it) failed compilation.
    case invalidFlowGraph([CanvasFlowIssue])
    /// A referenced run does not exist in this service instance.
    case runNotFound(UUID)
    /// The run already reached a terminal state.
    case runAlreadyFinished(UUID)
    /// Run configuration violates a runtime invariant; message explains.
    case invalidRunConfiguration(String)
    /// A required input port had no edge and no run input binding.
    case missingRequiredInputs(nodeID: UUID, ports: [String])
    /// No explicit environment was bound to the run identity.
    case environmentRequired(UUID)
    /// A host capability is required but was not injected.
    case hostCapabilityUnavailable(String)
    /// A resume was requested for a run with no recoverable journal state.
    case resumeUnavailable(UUID)
}

// MARK: - Deterministic digests

/// SHA-256 hex digest of a canonical JSON encoding. Used for run-bound
/// definition/config/input/source digests so a restarted runtime can prove
/// it is adopting the same work, never silently different work.
public enum FlowDigest {
    public static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func of<T: Encodable>(_ value: T) throws -> String {
        hex(try canonicalJSON(value))
    }
}

// MARK: - Deterministic UUID (RFC 4122 version 5, SHA-1 based)

/// Deterministic UUIDs make attempt IDs reproducible across a crash and
/// restart: the same run, node, attempt number, call path and iteration
/// always regenerate the same attempt ID, so the host-side
/// `(runID, attemptID)` dedupe in `CanvasStepExecutor` prevents duplicate
/// paid work without any central retry of unconfirmed submissions.
public enum FlowDeterministicID {
    public static let namespace = UUID(uuid: (
        0x66, 0x6c, 0x6f, 0x65, 0x63, 0x61, 0x6e, 0x76,
        0x61, 0x73, 0x66, 0x6c, 0x6f, 0x77, 0x32, 0x36))

    public static func make(
        namespace: UUID = FlowDeterministicID.namespace,
        name: String
    ) -> UUID {
        var bytes = [UInt8]()
        var namespaceBytes = namespace.uuid
        withUnsafeBytes(of: &namespaceBytes) { rawBuffer in
            bytes.append(contentsOf: rawBuffer)
        }
        bytes.append(contentsOf: Array(name.utf8))
        let digest = Array(Insecure.SHA1.hash(data: Data(bytes)))
        var uuidBytes = Array(digest.prefix(16))
        uuidBytes[6] = (uuidBytes[6] & 0x0F) | 0x50 // version 5
        uuidBytes[8] = (uuidBytes[8] & 0x3F) | 0x80 // RFC variant
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }
}

// MARK: - JSONValue → FlowValue literal decoding

public enum FlowLiteralError: Error, Hashable, Sendable {
    case typeMismatch(expected: FlowValueType, found: String)
}

public enum FlowLiterals {
    /// Converts a structured JSON literal (from node `parameters`) into the
    /// typed `FlowValue` a port expects. Hosts build nodes with structured
    /// parameters only — never free-form code strings.
    public static func value(
        _ json: JSONValue,
        as type: FlowValueType
    ) throws -> FlowValue {
        switch type {
        case .string:
            guard let string = json.stringValue else {
                throw FlowLiteralError.typeMismatch(expected: type, found: describe(json))
            }
            return .string(string)
        case .number:
            guard let literal = json.numberLiteral,
                  let number = Double(literal),
                  number.isFinite else {
                throw FlowLiteralError.typeMismatch(expected: type, found: describe(json))
            }
            return .number(number)
        case .bool:
            guard case .bool(let value) = json else {
                throw FlowLiteralError.typeMismatch(expected: type, found: describe(json))
            }
            return .bool(value)
        case .list:
            guard case .array(let elements) = json else {
                throw FlowLiteralError.typeMismatch(expected: type, found: describe(json))
            }
            return .list(try elements.map { try inferredValue($0) })
        case .table:
            guard case .object(let object) = json,
                  case .array(let header)? = object["header"],
                  case .array(let rows)? = object["rows"] else {
                throw FlowLiteralError.typeMismatch(expected: type, found: describe(json))
            }
            return .table(
                header: header.compactMap(\.stringValue),
                rows: rows.map { row in
                    (row.arrayValue ?? []).compactMap(\.stringValue)
                })
        case .asset:
            throw FlowLiteralError.typeMismatch(expected: type, found: "asset literals resolve through the host asset store")
        case .json:
            return .json(json)
        }
    }

    /// Lists carry typed primitive values; structured JSON objects keep
    /// their exact literal tree instead of losing unknown payload fields.
    private static func inferredValue(_ json: JSONValue) throws -> FlowValue {
        switch json {
        case .string(let text): return .string(text)
        case .bool(let flag): return .bool(flag)
        case .number(let literal):
            // Untyped lists must retain literals that binary64 cannot
            // represent. Explicit numeric ports still use numeric values.
            guard let number = Double(literal), number.isFinite,
                  Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX"))
                    == Decimal(string: String(number), locale: Locale(identifier: "en_US_POSIX"))
            else { return .json(json) }
            return .number(number)
        case .array: return try value(json, as: .list)
        case .object, .null: return .json(json)
        }
    }

    public static func describe(_ json: JSONValue) -> String {
        switch json {
        case .null: return "null"
        case .bool(let value): return "bool(\(value))"
        case .number(let literal): return "number(\(literal))"
        case .string(let value): return "string(\(value))"
        case .array(let value): return "array(\(value.count))"
        case .object(let value): return "object(\(value.keys.sorted().joined(separator: ",")))"
        }
    }

    /// Encodes a Codable value (FlowPredicate, FlowOperand, …) into the
    /// `JSONValue` tree stored inside `FlowNode.parameters`. The result
    /// uses real JSON primitives; number payloads keep their literal
    /// spelling inside `JSONValue`.
    public static func encodeToJSON<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONFidelity.parse(FlowDigest.canonicalJSON(value))
    }

    /// Decodes a Codable value from a `JSONValue` parameters entry. The
    /// native `JSONValue` Codable representation tags every number to
    /// preserve literals; that representation is NOT valid typed JSON, so
    /// this path serializes through `JSONFidelity.serialize` to real JSON
    /// before decoding. Non-finite numbers (e.g. a `1e400` literal) are
    /// rejected — Infinity must never reach `FlowValue`, hashing or the
    /// journal.
    public static func decodeFromJSON<T: Decodable>(
        _ json: JSONValue,
        as type: T.Type
    ) throws -> T {
        let data = try JSONFidelity.serialize(json)
        let object = try JSONSerialization.jsonObject(with: data)
        try rejectNonFiniteNumbers(object)
        let cleaned = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(T.self, from: cleaned)
    }

    static func rejectNonFiniteNumbers(_ object: Any) throws {
        switch object {
        case let number as NSNumber:
            // Bool is an NSNumber too; isFinite only applies to floats.
            let typeID = CFGetTypeID(number)
            guard typeID != CFBooleanGetTypeID() else { return }
            let double = number.doubleValue
            guard double.isFinite else {
                throw FlowLiteralError.typeMismatch(
                    expected: .number,
                    found: "non-finite number literal")
            }
        case let dictionary as [String: Any]:
            for value in dictionary.values {
                try rejectNonFiniteNumbers(value)
            }
        case let array as [Any]:
            for value in array {
                try rejectNonFiniteNumbers(value)
            }
        default:
            return
        }
    }
}

// MARK: - JSONValue convenience accessors used by the runtime

public extension JSONValue {
    var flowBool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var flowInt: Int? {
        guard let literal = numberLiteral, let value = Int64(literal) else { return nil }
        return Int(value)
    }

    var flowString: String? { stringValue }

    var flowArray: [JSONValue]? { arrayValue }

    var flowObject: [String: JSONValue]? { objectValue }
}
