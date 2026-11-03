import Foundation

/// A heterogeneous, Sendable JSON value used by the Bridge RPC surface.
///
/// This is an independent implementation for the Bridge 1.0 localhost-first
/// service. It is wire-compatible with JSON-RPC 2.0 and intentionally keeps
/// object keys as a dictionary: callers must not rely on ordering.
public enum BridgeRPCJSONValue: Sendable, Equatable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([BridgeRPCJSONValue])
    case object([String: BridgeRPCJSONValue])

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
        } else if let value = try? container.decode([BridgeRPCJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: BridgeRPCJSONValue].self) {
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
            guard value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) else {
                return nil
            }
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

    public var arrayValue: [BridgeRPCJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: BridgeRPCJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Canonical encoding used for digests and equality checks. Sorted keys,
    /// no escaped slashes, deterministic number formatting for integer values.
    public func canonicalData() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    public func canonicalString() -> String {
        String(decoding: canonicalData(), as: UTF8.self)
    }

    /// Recursively replaces every string value with its UTF-8 byte count.
    /// Used to build non-secret structural summaries; the text itself never
    /// leaves the process through a receipt or log.
    public func redactedSummary() -> BridgeRPCJSONValue {
        switch self {
        case .string(let value):
            return .object(["type": .string("string"), "bytes": .int(value.utf8.count)])
        case .array(let value):
            return .array(value.map { $0.redactedSummary() })
        case .object(let value):
            return .object(value.mapValues { $0.redactedSummary() })
        default:
            return self
        }
    }
}

public enum BridgeRPCJSON {
    public static func encode(_ value: BridgeRPCJSONValue) -> Data {
        value.canonicalData()
    }

    public static func decode(_ data: Data) throws -> BridgeRPCJSONValue {
        let decoder = JSONDecoder()
        return try decoder.decode(BridgeRPCJSONValue.self, from: data)
    }

    /// SHA-256 over the canonical JSON encoding, lowercase hex. This is a
    /// non-reversible structural digest, never a place to put raw arguments.
    public static func digest(_ value: BridgeRPCJSONValue) -> String {
        BridgeRPCDigest.sha256Hex(value.canonicalData())
    }

    public static func object(_ pairs: (String, BridgeRPCJSONValue)...) -> BridgeRPCJSONValue {
        .object(Dictionary(uniqueKeysWithValues: pairs))
    }
}

public enum BridgeRPCDigest {
    public static func sha256Hex(_ data: Data) -> String {
        BridgeRPCEnvelope.hexLowercase(BridgeRPCEnvelope.sha256(data))
    }
}

// MARK: - JSON-RPC 2.0 request / response

public struct BridgeRPCRequest: Sendable, Equatable {
    public let jsonrpc: String
    public let method: String
    public let params: BridgeRPCJSONValue?
    public let id: BridgeRPCJSONValue?
    /// Optional non-standard idempotency handle. The public client surface
    /// continues to use ordinary method parameters; this only prevents an
    /// SDK action from being executed twice when a caller retries with the
    /// same operation identifier.
    public let operationID: String?

    public init(jsonrpc: String = "2.0",
                method: String,
                params: BridgeRPCJSONValue? = nil,
                id: BridgeRPCJSONValue? = nil,
                operationID: String? = nil) {
        self.jsonrpc = jsonrpc
        self.method = method
        self.params = params
        self.id = id
        self.operationID = operationID
    }

    public static func decode(_ data: Data) throws -> BridgeRPCRequest {
        let value = try BridgeRPCJSON.decode(data)
        guard let object = value.objectValue,
              let version = object["jsonrpc"]?.stringValue,
              let method = object["method"]?.stringValue,
              !method.isEmpty,
              method.utf8.count <= 128 else {
            throw BridgeRPCRequestError.malformed
        }
        let params = object["params"]
        if let params, params.objectValue == nil, !params.isNull {
            throw BridgeRPCRequestError.invalidParams
        }
        let id = object["id"]
        if let id, !isValidID(id) {
            throw BridgeRPCRequestError.invalidID
        }
        var operationID: String?
        if let raw = object["operation_id"] {
            guard let text = raw.stringValue, BridgeRPCOperationID.isCanonical(text) else {
                throw BridgeRPCRequestError.invalidOperationID
            }
            operationID = text
        }
        return BridgeRPCRequest(
            jsonrpc: version,
            method: method,
            params: params?.isNull == true ? nil : params,
            id: id?.isNull == true ? nil : id,
            operationID: operationID
        )
    }

    public func encodedData() -> Data {
        var object: [String: BridgeRPCJSONValue] = [
            "jsonrpc": .string(jsonrpc),
            "method": .string(method),
        ]
        if let params { object["params"] = params }
        if let id { object["id"] = id }
        if let operationID { object["operation_id"] = .string(operationID) }
        return BridgeRPCJSONValue.object(object).canonicalData()
    }

    private static func isValidID(_ value: BridgeRPCJSONValue) -> Bool {
        switch value {
        case .null, .string, .int, .double:
            return true
        default:
            return false
        }
    }
}

public enum BridgeRPCRequestError: Error, Equatable, Sendable {
    case malformed
    case invalidParams
    case invalidID
    case invalidOperationID
}

public enum BridgeRPCOperationID {
    public static let maximumLength = 128

    public static func isCanonical(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...maximumLength).contains(bytes.count), let first = bytes.first else { return false }
        func isAlnum(_ byte: UInt8) -> Bool {
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
        }
        guard isAlnum(first) else { return false }
        for byte in bytes {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2E, 0x5F, 0x2D:
                continue
            default:
                return false
            }
        }
        return value != "." && value != ".."
    }

    public static func makeFallback(nonceHex: String) -> String {
        "n-" + nonceHex
    }
}

public struct BridgeRPCError: Error, Sendable, Equatable, Codable {
    public let code: Int
    public let message: String
    public let data: [String: BridgeRPCJSONValue]?

    public init(code: Int, message: String, data: [String: BridgeRPCJSONValue]? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard JSON-RPC 2.0 codes.
    public static let parseError = BridgeRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = BridgeRPCError(code: -32600, message: "Invalid Request")
    public static let methodNotFound = BridgeRPCError(code: -32601, message: "Method not found")
    public static let invalidParams = BridgeRPCError(code: -32602, message: "Invalid params")
    public static let internalError = BridgeRPCError(code: -32603, message: "Internal error")

    // Bridge-specific codes. Auth and transport failures use HTTP status codes
    // and plaintext error documents; these live inside a sealed JSON-RPC reply.
    public static let unauthorized = BridgeRPCError(code: -32099, message: "Unauthorized")
    public static let engineNotReady = BridgeRPCError(
        code: -32010,
        message: "The automation engine is not ready. Device control is unavailable until it is."
    )
    public static let methodNotAvailable = BridgeRPCError(
        code: -32011,
        message: "The method is registered in the schema but not available in this build."
    )
    public static let permissionDenied = BridgeRPCError(
        code: -32012,
        message: "The device owner has not granted this permission."
    )
    public static let operationOutcomeUnknown = BridgeRPCError(
        code: -32013,
        message: "The operation was interrupted and may already have taken effect. It was not replayed."
    )
    public static let operationInProgress = BridgeRPCError(
        code: -32014,
        message: "The same operation is still in progress."
    )
    public static let operationIDConflict = BridgeRPCError(
        code: -32015,
        message: "The operation identifier was already used for a different request."
    )
    public static let queueFull = BridgeRPCError(
        code: -32016,
        message: "The automation queue is full. Nothing was executed; retry later."
    )
    public static let executionTimedOut = BridgeRPCError(
        code: -32017,
        message: "The operation did not finish in time and may have taken effect. It was not replayed."
    )
    public static let responseTooLarge = BridgeRPCError(
        code: -32018,
        message: "The response exceeded the bounded size and was not returned."
    )
    public static let serviceStopping = BridgeRPCError(
        code: -32019,
        message: "The Bridge service is stopping. The operation was not dispatched."
    )
    public static let operationAlreadyCompleted = BridgeRPCError(
        code: -32020,
        message: "The operation already completed; its result was not retained. It was not replayed."
    )
    public static let fenced = BridgeRPCError(
        code: -32021,
        message: "The operation was fenced by a lifecycle or authorization change."
    )

    public static func serverError(_ message: String,
                                   data: [String: BridgeRPCJSONValue]? = nil) -> BridgeRPCError {
        BridgeRPCError(code: -32000, message: message, data: data)
    }
}

public struct BridgeRPCResponse: Sendable, Equatable {
    public let result: BridgeRPCJSONValue?
    public let error: BridgeRPCError?
    public let id: BridgeRPCJSONValue?

    public init(result: BridgeRPCJSONValue, id: BridgeRPCJSONValue?) {
        self.result = result
        self.error = nil
        self.id = id
    }

    public init(error: BridgeRPCError, id: BridgeRPCJSONValue?) {
        self.result = nil
        self.error = error
        self.id = id
    }

    /// Encodes exactly one of result/error, always with `"jsonrpc":"2.0"`.
    public func encodedData() -> Data {
        var object: [String: BridgeRPCJSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id ?? .null,
        ]
        if let error {
            object["error"] = .object([
                "code": .int(error.code),
                "message": .string(error.message),
                "data": error.data.map { .object($0) } ?? .null,
            ])
        } else {
            object["result"] = result ?? .null
        }
        return BridgeRPCJSONValue.object(object).canonicalData()
    }

    public func encodedString() -> String {
        String(decoding: encodedData(), as: UTF8.self)
    }
}
