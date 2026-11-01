import CoreFoundation
import Foundation

public enum BridgeLANLane: String, Codable, Sendable {
    case host
    case engine

    public var commandLane: BridgeCommandLane {
        self == .host ? .host : .engine
    }
}

public enum BridgeLANIdentifier {
    /// Command IDs become file names in the existing lane inbox. Restrict them
    /// to a canonical subset that is also a fixed point of
    /// `BridgeAtomicFile.safeIdentifier`, so two distinct IDs can never alias
    /// to the same file.
    public static func isCanonical(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count) else { return false }
        guard let first = bytes.first, isAlphaNumeric(first) else { return false }
        for byte in bytes {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2E, 0x5F, 0x2D:
                continue
            default:
                return false
            }
        }
        if value == "." || value == ".." { return false }
        return BridgeAtomicFile.safeIdentifier(value) == value
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39:
            return true
        default:
            return false
        }
    }
}

public enum BridgeLANSessionID {
    public static let byteCount = 16
    public static let canonicalLength = 32

    /// Lowercase hex only. The session identifier is carried inside the
    /// authenticated/encrypted application payload; it is not the key.
    public static func isCanonical(_ value: String) -> Bool {
        value.count == canonicalLength &&
            value == value.lowercased() &&
            BridgeLANCrypto.strictHex(value, byteCount: byteCount) != nil
    }
}

public struct BridgeLANControlRequest: Equatable, Sendable {
    public var id: String
    public var lane: BridgeLANLane
    public var action: String
    public var pid: Int32
    public var generation: UInt64
    /// Fresh per-arm identifier learned from encrypted `/v1/session`.
    public var session: String
    /// Closed typed arguments for the generic automation actions. Legacy
    /// actions require this to be absent.
    public var parameters: BridgeControlParameters?

    public init(id: String, lane: BridgeLANLane, action: String,
                pid: Int32, generation: UInt64, session: String,
                parameters: BridgeControlParameters? = nil) {
        self.id = id
        self.lane = lane
        self.action = action
        self.pid = pid
        self.generation = generation
        self.session = session
        self.parameters = parameters
    }
}

public struct BridgeLANResultRequest: Equatable, Sendable {
    public var id: String
    public var pid: Int32
    public var generation: UInt64
    public var session: String

    public init(id: String, pid: Int32, generation: UInt64, session: String) {
        self.id = id
        self.pid = pid
        self.generation = generation
        self.session = session
    }
}

public struct BridgeLANDiscoveryRequest: Equatable, Sendable {
    public var version: Int

    public init(version: Int = 1) {
        self.version = version
    }
}

public struct BridgeLANRequestError: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum BridgeLANControlArmPolicy {
    /// A normal Stop is a full entrance close: the owner preference, a started
    /// server and a currently listening socket all require the disarm action.
    /// This keeps the next Start/Resume device-owner-gated even when the
    /// listener happened to be idle. It never deletes the separate key.
    public static func shouldDisarm(controlEnabled: Bool,
                                    serverStarted: Bool,
                                    listening: Bool) -> Bool {
        controlEnabled || serverStarted || listening
    }
}

public enum BridgeLANControlPolicy {
    /// The LAN path intentionally exposes only the host actions needed to drive
    /// the existing lifecycle. Download/mount/remove/rotate/pairing stay on the
    /// authenticated file channel.
    public static let hostActions: Set<String> = [
        "status",
        "start",
        "stop",
        "resume",
        "shutdown",
    ]

    public static func actions(for lane: BridgeLANLane) -> Set<String> {
        switch lane {
        case .host:
            return hostActions
        case .engine:
            return BridgeCommandPolicy.engineActions
        }
    }

    public static func validate(_ request: BridgeLANControlRequest) -> BridgeLANRequestError? {
        guard BridgeLANIdentifier.isCanonical(request.id) else {
            return BridgeLANRequestError(code: "bad_request", message: "The command ID is invalid.")
        }
        guard request.pid > 0 else {
            return BridgeLANRequestError(code: "bad_request", message: "The process identifier is invalid.")
        }
        guard BridgeLANSessionID.isCanonical(request.session) else {
            return BridgeLANRequestError(code: "session_required",
                                         message: "A current control session identifier is required.")
        }
        guard isActionName(request.action) else {
            return BridgeLANRequestError(code: "bad_request", message: "The action name is invalid.")
        }
        guard actions(for: request.lane).contains(request.action) else {
            return BridgeLANRequestError(code: "action_not_allowed",
                                         message: "This action is not available over LAN control.")
        }
        if BridgeControlAction.all.contains(request.action) {
            switch BridgeControlArguments.validate(action: request.action,
                                                   parameters: request.parameters) {
            case .failure(let error):
                return BridgeLANRequestError(code: error.code, message: error.message)
            case .success:
                break
            }
        } else if request.parameters != nil {
            return BridgeLANRequestError(code: "parameters_not_applicable",
                                         message: "This action does not accept typed parameters.")
        }
        return nil
    }

    public static func validate(_ request: BridgeLANResultRequest) -> BridgeLANRequestError? {
        guard BridgeLANIdentifier.isCanonical(request.id) else {
            return BridgeLANRequestError(code: "bad_request", message: "The command ID is invalid.")
        }
        guard request.pid > 0 else {
            return BridgeLANRequestError(code: "bad_request", message: "The process identifier is invalid.")
        }
        guard BridgeLANSessionID.isCanonical(request.session) else {
            return BridgeLANRequestError(code: "session_required",
                                         message: "A current control session identifier is required.")
        }
        return nil
    }

    private static func isActionName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...32).contains(bytes.count) else { return false }
        for byte in bytes {
            switch byte {
            case 0x61...0x7A, 0x30...0x39, 0x5F:
                continue
            default:
                return false
            }
        }
        return true
    }
}

public enum BridgeLANRequestDecoder {
    public static func control(_ data: Data,
                               limits: BridgeLANLimits = .default) throws -> BridgeLANControlRequest {
        let object = try rootObject(data, limits: limits)
        let required: Set<String> = ["v", "id", "lane", "action", "pid",
                                     "generation", "session"]
        let allowed = required.union(["params"])
        guard Set(object.keys).isSuperset(of: required),
              Set(object.keys).subtracting(allowed).isEmpty,
              integer(object["v"]) == 1,
              let id = object["id"] as? String,
              let laneRaw = object["lane"] as? String,
              let lane = BridgeLANLane(rawValue: laneRaw),
              let action = object["action"] as? String,
              let pidValue = signedInteger(object["pid"]),
              let pid = Int32(exactly: pidValue),
              let generation = unsignedInteger(object["generation"]),
              let session = object["session"] as? String else {
            throw BridgeLANRequestError(code: "bad_request", message: "The control request is malformed.")
        }
        let rawParameters = try decodeParameters(object["params"])
        let parameters: BridgeControlParameters?
        if BridgeControlAction.all.contains(action) {
            switch BridgeControlArguments.validate(action: action, parameters: rawParameters) {
            case .success(let normalized):
                parameters = normalized
            case .failure(let error):
                throw BridgeLANRequestError(code: error.code, message: error.message)
            }
        } else {
            if rawParameters != nil {
                throw BridgeLANRequestError(
                    code: "parameters_not_applicable",
                    message: "This action does not accept typed parameters."
                )
            }
            parameters = nil
        }
        return BridgeLANControlRequest(id: id, lane: lane, action: action,
                                       pid: pid, generation: generation,
                                       session: session, parameters: parameters)
    }

    public static func result(_ data: Data,
                              limits: BridgeLANLimits = .default) throws -> BridgeLANResultRequest {
        let object = try rootObject(data, limits: limits)
        guard Set(object.keys) == ["v", "id", "pid", "generation", "session"],
              integer(object["v"]) == 1,
              let id = object["id"] as? String,
              let pidValue = signedInteger(object["pid"]),
              let pid = Int32(exactly: pidValue),
              let generation = unsignedInteger(object["generation"]),
              let session = object["session"] as? String else {
            throw BridgeLANRequestError(code: "bad_request", message: "The result request is malformed.")
        }
        return BridgeLANResultRequest(id: id, pid: pid, generation: generation, session: session)
    }

    public static func discovery(_ data: Data,
                                 limits: BridgeLANLimits = .default) throws -> BridgeLANDiscoveryRequest {
        let object = try rootObject(data, limits: limits)
        guard Set(object.keys) == ["v", "kind"],
              integer(object["v"]) == 1,
              object["kind"] as? String == "session" else {
            throw BridgeLANRequestError(code: "bad_request", message: "The session request is malformed.")
        }
        return BridgeLANDiscoveryRequest()
    }

    private static func rootObject(_ data: Data,
                                   limits: BridgeLANLimits) throws -> [String: Any] {
        // Text input is bounded to 4 KiB; the whole typed request keeps a
        // separate 32 KiB ceiling so JSON escaping cannot reject a
        // legitimate maximum-length input.
        guard data.count <= min(limits.maxRequestBodyBytes,
                               BridgeControlArguments.maximumSerializedCommandBytes) else {
            throw BridgeLANRequestError(code: "bad_request", message: "The request body is too large.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw BridgeLANRequestError(code: "bad_request", message: "The request body must be a JSON object.")
        }
        return dictionary
    }

    private static func decodeParameters(_ value: Any?) throws -> BridgeControlParameters? {
        guard let value else { return nil }
        guard let dictionary = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dictionary) else {
            throw BridgeLANRequestError(code: "bad_request",
                                        message: "The typed parameters are malformed.")
        }
        let decoded: BridgeControlParameters
        do {
            decoded = try JSONDecoder().decode(BridgeControlParameters.self, from: data)
        } catch {
            throw BridgeLANRequestError(code: "bad_request",
                                        message: "The typed parameters are malformed.")
        }
        guard decoded.unknownKeys.isEmpty else {
            throw BridgeLANRequestError(code: "unknown_parameters",
                                        message: "The typed parameters contain an unknown field.")
        }
        return decoded
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        let int64 = number.int64Value
        guard Int64(Int.min) <= int64, int64 <= Int64(Int.max) else { return nil }
        return Int(int64)
    }

    private static func signedInteger(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        return number.int64Value
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number) else { return nil }
        let signed = number.int64Value
        guard signed >= 0 else { return nil }
        return number.uint64Value
    }
}

// MARK: - Bounded HTTP/1.1 framing

public struct BridgeHTTPRequestHead: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var contentLength: Int

    public init(method: String, path: String, headers: [String: String], contentLength: Int) {
        self.method = method
        self.path = path
        self.headers = headers
        self.contentLength = contentLength
    }
}

public enum BridgeHTTPInspection: Equatable, Sendable {
    case incomplete
    case invalid(status: Int, code: String)
    case ready(head: BridgeHTTPRequestHead, body: Data)
}

/// Strict, single-request HTTP/1.1 framing for the control endpoint.
///
/// It accepts exactly one Content-Length, rejects Transfer-Encoding, duplicate
/// Content-Length, request pipelining/overread, obs-fold, control characters and
/// a missing Host header. The only methods used by the prototype are GET and
/// POST; routing applies the stricter method check.
public enum BridgeHTTPParser {
    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])

    public static func inspect(_ data: Data,
                               limits: BridgeLANLimits = .default) -> BridgeHTTPInspection {
        guard let terminator = data.range(of: headerTerminator) else {
            if data.count > limits.maxRequestHeadBytes {
                return .invalid(status: 431, code: "request_head_too_large")
            }
            return .incomplete
        }
        let headerLength = terminator.lowerBound - data.startIndex
        guard headerLength <= limits.maxRequestHeadBytes else {
            return .invalid(status: 431, code: "request_head_too_large")
        }
        let headerData = data.subdata(in: data.startIndex..<terminator.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8),
              !headerText.contains("\u{0}") else {
            return .invalid(status: 400, code: "bad_request_head")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return .invalid(status: 400, code: "missing_request_line")
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else {
            return .invalid(status: 400, code: "bad_request_line")
        }
        let method = String(parts[0])
        let path = String(parts[1])
        let version = String(parts[2])
        guard method.utf8.count <= 16,
              method.utf8.allSatisfy({ (0x41...0x5A).contains($0) }) else {
            return .invalid(status: 400, code: "bad_method")
        }
        guard path.utf8.count <= 2_048,
              path.hasPrefix("/"),
              !path.contains("?"), !path.contains("#"),
              !path.utf8.contains(where: { $0 < 0x21 || $0 == 0x7F }) else {
            return .invalid(status: 400, code: "bad_path")
        }
        guard version == "HTTP/1.1" else {
            return .invalid(status: 400, code: "bad_version")
        }

        var headers: [String: String] = [:]
        var contentLength: Int?
        for line in lines.dropFirst() {
            guard !line.isEmpty else {
                return .invalid(status: 400, code: "unexpected_empty_header")
            }
            guard line.first != " ", line.first != "\t" else {
                return .invalid(status: 400, code: "folded_header")
            }
            guard let separator = line.firstIndex(of: ":") else {
                return .invalid(status: 400, code: "bad_header")
            }
            let rawName = line[..<separator]
            let rawValue = line[line.index(after: separator)...]
            let name = rawName.lowercased()
            guard isHeaderName(name), name.utf8.count <= 64 else {
                return .invalid(status: 400, code: "bad_header_name")
            }
            let value = rawValue.trimmingCharacters(in: .whitespaces)
            guard value.utf8.count <= 1_024,
                  !value.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
                return .invalid(status: 400, code: "bad_header_value")
            }
            switch name {
            case "content-length":
                guard contentLength == nil else {
                    return .invalid(status: 400, code: "duplicate_content_length")
                }
                guard isDecimal(value), value.utf8.count <= 8,
                      !(value.count > 1 && value.hasPrefix("0")),
                      let parsed = Int(value), parsed <= limits.maxRequestBodyBytes else {
                    return .invalid(status: 413, code: "bad_content_length")
                }
                contentLength = parsed
            case "transfer-encoding", "expect", "content-encoding":
                return .invalid(status: 400, code: "unsupported_transfer")
            default:
                if headers[name] != nil {
                    return .invalid(status: 400, code: "duplicate_header")
                }
                headers[name] = value
            }
        }
        guard let host = headers["host"], !host.isEmpty, host.utf8.count <= 255 else {
            return .invalid(status: 400, code: "missing_host")
        }
        let length = contentLength ?? 0
        if method != "POST", length != 0 {
            return .invalid(status: 400, code: "unexpected_body")
        }
        if length > limits.maxRequestBodyBytes {
            return .invalid(status: 413, code: "request_body_too_large")
        }
        let total = headerLength + 4 + length
        if data.count < total {
            return .incomplete
        }
        guard data.count == total else {
            return .invalid(status: 400, code: "unexpected_trailing_bytes")
        }
        let body = data.subdata(in: (data.startIndex + headerLength + 4)..<data.endIndex)
        return .ready(
            head: BridgeHTTPRequestHead(
                method: method,
                path: path,
                headers: headers,
                contentLength: length
            ),
            body: body
        )
    }

    private static func isHeaderName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty else { return false }
        for byte in bytes {
            switch byte {
            case 0x61...0x7A, 0x30...0x39, 0x21, 0x23, 0x24, 0x25, 0x26,
                 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E:
                continue
            default:
                return false
            }
        }
        return true
    }

    private static func isDecimal(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }
}

// MARK: - Command ledger

public struct BridgeLANCommandRecord: Equatable, Sendable {
    public var id: String
    public var lane: BridgeLANLane
    public var action: String
    public var pid: Int32
    public var generation: UInt64
    public var session: String
    /// Private digest over the normalized arguments including text. It never
    /// leaves the process and is never returned in a result.
    public var contentDigest: String
    /// Non-secret digest over the normalized arguments with text replaced by
    /// its byte count. The engine echoes this in its result so the broker can
    /// bind a result to the exact authorized argument shape.
    public var resultDigest: String
    public var submittedAt: Date
    public var issuedAt: Date?
    public var fileURL: URL?
    public var fenced: Bool
    public var fenceReason: String?

    public init(id: String, lane: BridgeLANLane, action: String, pid: Int32,
                generation: UInt64, session: String, submittedAt: Date,
                contentDigest: String = "",
                resultDigest: String = "",
                issuedAt: Date? = nil, fileURL: URL? = nil,
                fenced: Bool = false, fenceReason: String? = nil) {
        self.id = id
        self.lane = lane
        self.action = action
        self.pid = pid
        self.generation = generation
        self.session = session
        self.contentDigest = contentDigest
        self.resultDigest = resultDigest
        self.submittedAt = submittedAt
        self.issuedAt = issuedAt
        self.fileURL = fileURL
        self.fenced = fenced
        self.fenceReason = fenceReason
    }

    public func matches(_ request: BridgeLANControlRequest) -> Bool {
        let expected = BridgeControlArguments.contentDigest(
            action: request.action,
            parameters: request.parameters
        )
        return id == request.id && lane == request.lane &&
            action == request.action &&
            pid == request.pid && generation == request.generation &&
            session == request.session && contentDigest == expected
    }
}

public enum BridgeLANLedgerDecision: Equatable, Sendable {
    case accepted(BridgeLANCommandRecord)
    case duplicate(BridgeLANCommandRecord)
    case replayed
    case busy
}

public enum BridgeLANResultDisposition: Equatable, Sendable {
    case unknown
    case sessionMismatch
    case pending(BridgeLANCommandRecord)
    case expired
    case ready(BridgeLANCommandRecord)
    case fenced(BridgeLANCommandRecord)
    case late(BridgeLANCommandRecord)
}

/// Bounded, in-memory command ledger. It is the LAN-side replay/ownership
/// table, not a dispatcher: an accepted command is still issued through the
/// existing authenticated file lane and revalidated there.
public struct BridgeLANCommandLedger: Sendable {
    private var records: [String: BridgeLANCommandRecord] = [:]
    private var maxRecords: Int
    private var commandTTL: TimeInterval
    private var seenTTL: TimeInterval

    public init(maxRecords: Int = 256, commandTTL: TimeInterval = 900) {
        self.maxRecords = max(1, maxRecords)
        self.commandTTL = max(1, commandTTL)
        self.seenTTL = max(3_600, commandTTL * 4)
    }

    public var count: Int { records.count }

    public mutating func submit(_ request: BridgeLANControlRequest,
                                now: Date = Date()) -> BridgeLANLedgerDecision {
        pruneLocked(now: now)
        if let existing = records[request.id] {
            return existing.matches(request) ? .duplicate(existing) : .replayed
        }
        guard records.count < maxRecords else { return .busy }
        let record = BridgeLANCommandRecord(
            id: request.id,
            lane: request.lane,
            action: request.action,
            pid: request.pid,
            generation: request.generation,
            session: request.session,
            submittedAt: now,
            contentDigest: BridgeControlArguments.contentDigest(
                action: request.action,
                parameters: request.parameters
            ),
            resultDigest: BridgeControlArguments.resultDigest(
                action: request.action,
                parameters: request.parameters
            )
        )
        records[request.id] = record
        return .accepted(record)
    }

    public mutating func markIssued(id: String, fileURL: URL, now: Date = Date()) -> Bool {
        guard var record = records[id], !record.fenced else { return false }
        record.issuedAt = now
        record.fileURL = fileURL
        records[id] = record
        return true
    }

    /// Marks a command that is executed by an already-owned local service
    /// (the one-way shutdown action) as issued without writing an inbox file.
    public mutating func markIssuedWithoutFile(id: String, now: Date = Date()) -> Bool {
        guard var record = records[id], !record.fenced else { return false }
        record.issuedAt = now
        records[id] = record
        return true
    }

    public mutating func cancelSubmission(id: String) {
        guard let record = records[id], record.issuedAt == nil else { return }
        records.removeValue(forKey: id)
    }

    /// Marks every outstanding record as fenced and returns the issued records
    /// whose inbox file may still exist. The caller can remove those files;
    /// an already-claimed command keeps running but its late result is returned
    /// as `late`, never as a fresh success.
    public mutating func fence(reason: String, now: Date = Date()) -> [BridgeLANCommandRecord] {
        var affected: [BridgeLANCommandRecord] = []
        for (id, var record) in records where !record.fenced {
            record.fenced = true
            record.fenceReason = reason
            records[id] = record
            if record.issuedAt != nil { affected.append(record) }
        }
        _ = now
        return affected
    }

    public mutating func reset() {
        records.removeAll()
    }

    public func record(id: String) -> BridgeLANCommandRecord? {
        records[id]
    }

    public mutating func disposition(id: String,
                                     pid: Int32,
                                     generation: UInt64,
                                     session: String,
                                     hasResult: Bool,
                                     now: Date = Date()) -> BridgeLANResultDisposition {
        pruneLocked(now: now)
        guard let record = records[id], record.pid == pid, record.generation == generation else {
            return .unknown
        }
        guard record.session == session else {
            return .sessionMismatch
        }
        if record.fenced {
            return hasResult ? .late(record) : .fenced(record)
        }
        if now.timeIntervalSince(record.submittedAt) > commandTTL {
            return .expired
        }
        return hasResult ? .ready(record) : .pending(record)
    }

    private mutating func pruneLocked(now: Date) {
        let cutoff = now.addingTimeInterval(-seenTTL)
        records = records.filter { $0.value.submittedAt >= cutoff }
    }
}

// MARK: - Result payloads and artifact confinement

public struct BridgeLANArtifact: Sendable {
    public var name: String
    public var mediaType: String
    public var byteCount: Int
    public var sha256: String
    public var base64: String

    public init(name: String, mediaType: String, byteCount: Int, sha256: String, base64: String) {
        self.name = name
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.base64 = base64
    }
}

public struct BridgeLANCommandResultPayload: Sendable {
    public var status: String
    public var action: String
    public var processIdentifier: Int32
    public var generation: UInt64
    public var resultingGeneration: UInt64?
    public var processedAt: String
    public var details: [String: String]
    public var error: String?
    public var artifact: BridgeLANArtifact?
    public var artifactError: String?

    public init(status: String, action: String, processIdentifier: Int32,
                generation: UInt64, resultingGeneration: UInt64? = nil,
                processedAt: String, details: [String: String],
                error: String? = nil, artifact: BridgeLANArtifact? = nil,
                artifactError: String? = nil) {
        self.status = status
        self.action = action
        self.processIdentifier = processIdentifier
        self.generation = generation
        self.resultingGeneration = resultingGeneration
        self.processedAt = processedAt
        self.details = details
        self.error = error
        self.artifact = artifact
        self.artifactError = artifactError
    }
}

public struct BridgeLANLateResult: Sendable {
    public var status: String
    public var action: String
    public var processIdentifier: Int32
    public var generation: UInt64
    public var resultingGeneration: UInt64?
    public var processedAt: String
    public var error: String?

    public init(status: String, action: String, processIdentifier: Int32,
                generation: UInt64, resultingGeneration: UInt64? = nil,
                processedAt: String, error: String? = nil) {
        self.status = status
        self.action = action
        self.processIdentifier = processIdentifier
        self.generation = generation
        self.resultingGeneration = resultingGeneration
        self.processedAt = processedAt
        self.error = error
    }
}

public enum BridgeLANSubmitOutcome: Sendable {
    case accepted(id: String, lane: BridgeLANLane, action: String,
                  generation: UInt64, duplicate: Bool)
    case rejected(code: String, message: String)
}

public enum BridgeLANCommandResultOutcome: Sendable {
    case unknown
    case pending
    case expired
    case fenced
    case ready(BridgeLANCommandResultPayload)
    case late(BridgeLANLateResult)
    case rejected(code: String, message: String)
}

public struct BridgeLANCurrentState: Sendable {
    public var pid: Int32
    public var generation: UInt64

    public init(pid: Int32, generation: UInt64) {
        self.pid = pid
        self.generation = generation
    }
}

/// The only screenshot path the LAN surface will read. It must be the engine's
/// own `screenshot-<command-id>-<milliseconds>.png` file name under
/// `Documents/Bridge/diagnostics`; a result cannot request an arbitrary file.
public enum BridgeLANArtifactPolicy {
    public static func safeScreenshotFileName(commandID: String,
                                              result: BridgeCommandResult) -> String? {
        guard result.action == "screenshot", result.status == "ok",
              let raw = result.details["screenshotFile"],
              raw.utf8.count <= 192,
              !raw.contains("/"), !raw.contains("\\"),
              !raw.hasPrefix("."),
              raw == (raw as NSString).lastPathComponent else {
            return nil
        }
        let prefix = "screenshot-\(BridgeAtomicFile.safeIdentifier(commandID))-"
        guard raw.hasPrefix(prefix), raw.hasSuffix(".png") else { return nil }
        let middle = raw.dropFirst(prefix.count).dropLast(4)
        guard !middle.isEmpty, middle.utf8.count <= 13,
              middle.allSatisfy({ $0.isNumber }) else {
            return nil
        }
        return raw
    }

    public static func isConstrained(_ url: URL, to directory: URL) -> Bool {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        return candidate.deletingLastPathComponent().path == root.path
    }
}
