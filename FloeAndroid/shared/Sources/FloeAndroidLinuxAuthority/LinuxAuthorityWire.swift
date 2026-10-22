// SPDX-License-Identifier: MPL-2.0
//
// G03-R2 Android isolated-runtime environment authority — wire layer.
// Owned by the independent-UID runtime component (job-9c0066307afe460f).
//
// This file is NEW Android-owned source: it is NOT a port of any iOS file and
// NOT a second registry. It defines the ONLY bounded Codable request/reply
// shape (wire version 1) that the native bridge `FloeLinuxAuthorityBridge`
// exchanges with the trusted runtime service. Every environment decision made
// through this wire lands on the ORIGINAL FloeEnvironments authority
// (`EnvironmentRegistry` / `EnvironmentExecutionCoordinator` /
// `LinuxExecutionLeaseResolver.acquireHolder`); nothing here creates records,
// invents a job/environment database, or selects a backend implicitly.
//
// Encoding is EXPLICIT (no reliance on synthesized enum- Codable shapes —
// Main WIRE_V1 review 2026-10-22): operations and results use the exact
// single-key-object / bare-string forms documented below and pinned by the
// golden-byte tests in FloeAndroidLinuxAuthorityTests.
//
// Trust model (Main decisions 2026-10-22):
// - The bridge ingress is the trusted native lifecycle path (JNI from the
//   runtime service, serialized native IO executor). `markStarted`, `cancel`,
//   `complete` and `abandon` are TRUSTED-ONLY lifecycle operations: Main's
//   composition must never route them from model command dispatch or public
//   IPC. There is deliberately NO standalone `release` operation: lease
//   release happens only inside `complete` (after an attested process
//   quiescence) or inside `abandon` (holder that never started a process).
// - A caller-supplied boolean is not proof of OS termination: `complete`
//   requires the EXACT bound process identity plus the runtime service's
//   waitpid-style quiescence attestation, and the authority treats that
//   attestation as the trusted service's assertion — it never claims to
//   observe process exit itself.
// - Untrusted, malformed, unknown-key, non-canonical or oversized traffic
//   fails closed with a typed reply; the bridge never throws across the C
//   boundary and never returns nil for non-nil input.

import Foundation

/// Wire constants and envelope codecs. Version 1 is frozen; any later version
/// must be additive and is refused here with `unsupportedVersion`.
public enum LinuxAuthorityWire {
    public static let version = 1
    /// Hard ceiling for BOTH directions, in UTF-8 bytes (matches the JNI
    /// `LinuxAuthorityNative` contract: max 64 KiB standardUTF8).
    public static let maximumBytes = 65_536

    static let maximumRequestIDBytes = 64
    static let maximumRootPathBytes = 4_096
    static let maximumBaseRevisionBytes = 64
    static let maximumIdentifierBytes = 64
    static let maximumMessageBytes = 512
    static let maximumTerminalLedger = 16

    /// Decodes the strict envelope. Throws `LinuxAuthorityWireError` (shape
    /// violations — unknown/missing keys, wrong operation name/shape, bad
    /// JSON) or a Foundation DecodingError (wrong JSON types); the bridge
    /// maps every throw to `requestTooLarge`/`invalidWire`.
    public static func decodeRequest(_ data: Data) throws -> LinuxAuthorityRequest {
        guard !data.isEmpty else { throw LinuxAuthorityWireError.emptyRequest }
        guard data.count <= maximumBytes else { throw LinuxAuthorityWireError.oversizedRequest }
        return try JSONDecoder().decode(LinuxAuthorityRequest.self, from: data)
    }

    /// Encodes a reply; an oversized reply fails closed as `replyTooLarge`
    /// (the caller must never see truncated JSON). Deterministic key order.
    static func encodeReply(_ reply: LinuxAuthorityReply) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(reply), data.count <= maximumBytes else {
            return failureData(code: .replyTooLarge, message: "the authority reply exceeded the 65536-byte wire ceiling", requestID: reply.requestID)
        }
        return data
    }

    /// Builds a failure reply for paths where no request envelope could be
    /// decoded (oversized/non-UTF8 traffic) or a typed error must be returned.
    public static func failureData(code: LinuxAuthorityErrorCode, message: String, requestID: String?) -> Data {
        let reply = LinuxAuthorityReply(version: version, requestID: requestID,
                                       outcome: .failure(LinuxAuthorityFailure(code: code, message: message)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(reply), data.count <= maximumBytes else {
            // Last-resort static encoding guard: the failure shape itself
            // always fits, so this literal exists only for a hostile
            // Foundation-encode failure. Key order mirrors .sortedKeys.
            return Data(#"{"outcome":{"failure":{"code":"replyTooLarge","message":""}},"requestID":null,"version":1}"#.utf8)
        }
        return data
    }

    static func boundedMessage(_ message: String) -> String {
        if message.utf8.count <= maximumMessageBytes { return message }
        // "…" is exactly 3 UTF-8 bytes; reserve room so the RESULT is bounded
        // by maximumMessageBytes, not just the kept prefix.
        var kept = ""
        for character in message {
            let candidate = kept + String(character)
            if candidate.utf8.count > maximumMessageBytes - 3 { break }
            kept = candidate
        }
        return kept + "…"
    }
}

/// Shape-level wire errors. Everything thrown while reading the envelope is
/// reported as `invalidWire`; the message is fixed text, never content echoes.
public enum LinuxAuthorityWireError: Error, Equatable, CustomStringConvertible {
    case emptyRequest
    case oversizedRequest
    case invalidJSON
    case missingField(String)
    case unknownField(String)
    case wrongType(String)
    case unknownOperation(String)
    case invalidOperationShape(String)
    case invalidEnvelopeShape

    public var description: String {
        switch self {
        case .emptyRequest: return "empty request"
        case .oversizedRequest: return "request exceeds the 65536-byte wire ceiling"
        case .invalidJSON: return "request is not a valid JSON object"
        case .missingField(let name): return "missing field '\(name)'"
        case .unknownField(let name): return "unknown field '\(name)'"
        case .wrongType(let name): return "field '\(name)' has the wrong type"
        case .unknownOperation(let name): return "unknown operation '\(name)'"
        case .invalidOperationShape(let name): return "operation '\(name)' must be a single-key payload object"
        case .invalidEnvelopeShape: return "request must be a JSON object envelope"
        }
    }
}

/// Stable machine-readable failure codes carried in `failure.code`.
/// Unknown/absent codes must never appear; the full set is documented in the
/// R2 handoff (WIRE_V1.md) and frozen for version 1.
public enum LinuxAuthorityErrorCode: String, Codable, Sendable {
    // Wire shape / transport.
    case invalidWire
    case requestTooLarge
    case replyTooLarge
    case unsupportedVersion
    // Configuration / roots.
    case notConfigured
    case configurationLockedByLease
    /// One configure (or lease admission) is already in flight on the actor;
    /// callers may retry after it settles.
    case configurationInFlight
    case invalidRoot
    case rootParentMissing
    case rootNotResolvable
    case rootLocationForbidden
    case rootContainmentViolation
    case invalidBaseRevision
    case stateRootUnusable
    // Lease addressing.
    case invalidUUID
    case invalidIdentifier
    case invalidProcessIdentity
    case workspaceUnavailable
    // Lease state machine.
    case leaseBusy
    case leaseNotFound
    case leaseNotStarted
    case processIdentityMismatch
    case quiescenceNotAcknowledged
    case abandonRefusedAfterStart
    case releaseIncomplete
    // Authority rejections mapped from the ORIGINAL FloeEnvironments layer.
    case authorityRejected
    case environmentNotFound
    case sessionRequiresConversation
    case foreignConversation
    case recordBackendMismatch
    case noResolvedEnvironment
    case backendNotSelectable
    case cancelled
    // Last-resort guard; never expected.
    case internalError
}

/// Public typed error of the actor API (same codes as the wire failures).
public struct LinuxAuthorityError: Error, Sendable, Equatable, CustomStringConvertible {
    public var code: LinuxAuthorityErrorCode
    public var message: String

    public init(code: LinuxAuthorityErrorCode, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

// MARK: - AnyCodingKey + strict container helpers
//
// A typed CodingKeys enum makes `container.allKeys` BLIND to unknown JSON
// keys (they cannot be converted to the enum), so an "unknown key" gate built
// on it silently never fires (Main WIRE_V1 review 2026-10-22). Every strict
// request decoder below therefore uses this permissive key type, whose
// `allKeys` exposes the full object, and fails closed on anything outside the
// documented key set.

struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
    init(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

enum LinuxAuthorityStrict {
    static func rejectUnknown(_ container: KeyedDecodingContainer<AnyCodingKey>, allowed: Set<String>) throws {
        for key in container.allKeys where !allowed.contains(key.stringValue) {
            throw LinuxAuthorityWireError.unknownField(key.stringValue)
        }
    }

    static func require<T: Decodable>(_ type: T.Type, _ key: String, in container: KeyedDecodingContainer<AnyCodingKey>) throws -> T {
        guard container.contains(AnyCodingKey(stringValue: key)) else {
            throw LinuxAuthorityWireError.missingField(key)
        }
        return try container.decode(T.self, forKey: AnyCodingKey(stringValue: key))
    }

    /// JSON null and an absent key are BOTH treated as nil (documented).
    static func optional<T: Decodable>(_ type: T.Type, _ key: String, in container: KeyedDecodingContainer<AnyCodingKey>) throws -> T? {
        guard container.contains(AnyCodingKey(stringValue: key)) else { return nil }
        return try container.decodeIfPresent(T.self, forKey: AnyCodingKey(stringValue: key))
    }
}

// MARK: - Request envelope (strict: unknown keys are rejected)

public struct LinuxAuthorityRequest: Codable, Sendable, Equatable {
    public var version: Int
    public var requestID: String?
    public var operation: LinuxAuthorityOperation

    private enum CodingKeys: String, CodingKey { case version, requestID, operation }
    private static let allowedKeys: Set<String> = ["version", "requestID", "operation"]

    public init(version: Int, requestID: String?, operation: LinuxAuthorityOperation) {
        self.version = version
        self.requestID = requestID
        self.operation = operation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try LinuxAuthorityStrict.rejectUnknown(container, allowed: Self.allowedKeys)
        version = try LinuxAuthorityStrict.require(Int.self, CodingKeys.version.rawValue, in: container)
        requestID = try LinuxAuthorityStrict.optional(String.self, CodingKeys.requestID.rawValue, in: container)
        operation = try LinuxAuthorityStrict.require(LinuxAuthorityOperation.self, CodingKeys.operation.rawValue, in: container)
    }
}

/// One operation per request. The frozen version-1 encoding is EXPLICIT:
/// - payload-free operations are bare strings: `"handshake"`, `"list"`;
/// - payload operations are single-key objects:
///   `{"configure":{…}}`, `{"acquire":{…}}`, `{"markStarted":{…}}`,
///   `{"cancel":{…}}`, `{"complete":{…}}`, `{"abandon":{…}}`.
/// Any other shape (object with 0 or ≥2 keys, wrong type, unknown name) is
/// `invalidWire` — no silent acceptance of near-miss spellings.
public enum LinuxAuthorityOperation: Codable, Sendable, Equatable {
    case handshake
    case configure(LinuxAuthorityConfigureRequest)
    case list
    case acquire(LinuxAuthorityAcquireRequest)
    case markStarted(LinuxAuthorityMarkStartedRequest)
    case cancel(LinuxAuthorityLeaseRequest)
    case complete(LinuxAuthorityCompleteRequest)
    case abandon(LinuxAuthorityLeaseRequest)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .handshake:
            var container = encoder.singleValueContainer()
            try container.encode("handshake")
        case .list:
            var container = encoder.singleValueContainer()
            try container.encode("list")
        case .configure(let payload):
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            try container.encode(payload, forKey: AnyCodingKey(stringValue: "configure"))
        case .acquire(let payload):
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            try container.encode(payload, forKey: AnyCodingKey(stringValue: "acquire"))
        case .markStarted(let payload):
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            try container.encode(payload, forKey: AnyCodingKey(stringValue: "markStarted"))
        case .cancel(let payload):
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            try container.encode(payload, forKey: AnyCodingKey(stringValue: "cancel"))
        case .complete(let payload):
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            try container.encode(payload, forKey: AnyCodingKey(stringValue: "complete"))
        case .abandon(let payload):
            var container = encoder.container(keyedBy: AnyCodingKey.self)
            try container.encode(payload, forKey: AnyCodingKey(stringValue: "abandon"))
        }
    }

    public init(from decoder: Decoder) throws {
        // Bare-string operations first (the ONLY accepted string names).
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            switch name {
            case "handshake": self = .handshake; return
            case "list": self = .list; return
            default: throw LinuxAuthorityWireError.unknownOperation(name)
            }
        }
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let keys = container.allKeys
        guard keys.count == 1 else {
            throw container.allKeys.isEmpty
                ? LinuxAuthorityWireError.invalidOperationShape("<empty object>")
                : LinuxAuthorityWireError.invalidOperationShape("<multi-key object>")
        }
        let key = keys[0]
        switch key.stringValue {
        case "configure": self = .configure(try container.decode(LinuxAuthorityConfigureRequest.self, forKey: key))
        case "acquire": self = .acquire(try container.decode(LinuxAuthorityAcquireRequest.self, forKey: key))
        case "markStarted": self = .markStarted(try container.decode(LinuxAuthorityMarkStartedRequest.self, forKey: key))
        case "cancel": self = .cancel(try container.decode(LinuxAuthorityLeaseRequest.self, forKey: key))
        case "complete": self = .complete(try container.decode(LinuxAuthorityCompleteRequest.self, forKey: key))
        case "abandon": self = .abandon(try container.decode(LinuxAuthorityLeaseRequest.self, forKey: key))
        // Bare-string names decoded above must not arrive as object keys.
        case "handshake", "list": throw LinuxAuthorityWireError.invalidOperationShape(key.stringValue)
        default: throw LinuxAuthorityWireError.unknownOperation(key.stringValue)
        }
    }
}

public struct LinuxAuthorityConfigureRequest: Codable, Sendable, Equatable {
    /// Engine-private registry/state root (the original EnvironmentRoots
    /// trusted root). Required; never defaulted.
    public var stateRoot: String
    /// Parent of per-project workspaces: acquire() creates/resolves
    /// `workspacesRoot/<canonical project UUID>` below it. Required.
    public var workspacesRoot: String
    /// Base-slice root handed to the original coordinator as
    /// `bundledBaseURL` (lookup order's base layer location). Required.
    public var baseRoot: String
    public var baseRevision: String

    public init(stateRoot: String, workspacesRoot: String, baseRoot: String, baseRevision: String) {
        self.stateRoot = stateRoot
        self.workspacesRoot = workspacesRoot
        self.baseRoot = baseRoot
        self.baseRevision = baseRevision
    }

    private static let allowedKeys: Set<String> = ["stateRoot", "workspacesRoot", "baseRoot", "baseRevision"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try LinuxAuthorityStrict.rejectUnknown(container, allowed: Self.allowedKeys)
        stateRoot = try LinuxAuthorityStrict.require(String.self, "stateRoot", in: container)
        workspacesRoot = try LinuxAuthorityStrict.require(String.self, "workspacesRoot", in: container)
        baseRoot = try LinuxAuthorityStrict.require(String.self, "baseRoot", in: container)
        baseRevision = try LinuxAuthorityStrict.require(String.self, "baseRevision", in: container)
    }
}

public struct LinuxAuthorityAcquireRequest: Codable, Sendable, Equatable {
    /// Required project identity — no hidden first-project/default selection.
    public var projectID: String
    /// Runtime-issued run identity carried unchanged into the descriptor.
    public var runID: String
    /// Optional conversation identity (session environments require it).
    public var conversationID: String?
    /// Optional explicit environment id; nil resolves through the original
    /// coordinator's project/session ensure chain for THIS workspace only.
    public var environmentID: String?

    public init(projectID: String, runID: String, conversationID: String?, environmentID: String?) {
        self.projectID = projectID
        self.runID = runID
        self.conversationID = conversationID
        self.environmentID = environmentID
    }

    private static let allowedKeys: Set<String> = ["projectID", "runID", "conversationID", "environmentID"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try LinuxAuthorityStrict.rejectUnknown(container, allowed: Self.allowedKeys)
        projectID = try LinuxAuthorityStrict.require(String.self, "projectID", in: container)
        runID = try LinuxAuthorityStrict.require(String.self, "runID", in: container)
        conversationID = try LinuxAuthorityStrict.optional(String.self, "conversationID", in: container)
        environmentID = try LinuxAuthorityStrict.optional(String.self, "environmentID", in: container)
    }
}

/// Trusted process identity minted by the runtime service when it launches the
/// owned backend process. `launcherToken` is the service's own launch-record
/// identifier; the authority stores it verbatim for exact-match completion and
/// never interprets it.
public struct LinuxAuthorityProcessIdentity: Codable, Sendable, Equatable {
    public var pid: Int
    public var pgid: Int?
    public var launcherToken: String
    public var startedAtUnixMillis: Int?

    public init(pid: Int, pgid: Int?, launcherToken: String, startedAtUnixMillis: Int?) {
        self.pid = pid
        self.pgid = pgid
        self.launcherToken = launcherToken
        self.startedAtUnixMillis = startedAtUnixMillis
    }

    private static let allowedKeys: Set<String> = ["pid", "pgid", "launcherToken", "startedAtUnixMillis"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try LinuxAuthorityStrict.rejectUnknown(container, allowed: Self.allowedKeys)
        pid = try LinuxAuthorityStrict.require(Int.self, "pid", in: container)
        pgid = try LinuxAuthorityStrict.optional(Int.self, "pgid", in: container)
        launcherToken = try LinuxAuthorityStrict.require(String.self, "launcherToken", in: container)
        startedAtUnixMillis = try LinuxAuthorityStrict.optional(Int.self, "startedAtUnixMillis", in: container)
    }
}

public struct LinuxAuthorityMarkStartedRequest: Codable, Sendable, Equatable {
    public var leaseID: String
    public var processIdentity: LinuxAuthorityProcessIdentity

    public init(leaseID: String, processIdentity: LinuxAuthorityProcessIdentity) {
        self.leaseID = leaseID
        self.processIdentity = processIdentity
    }

    private static let allowedKeys: Set<String> = ["leaseID", "processIdentity"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try LinuxAuthorityStrict.rejectUnknown(container, allowed: Self.allowedKeys)
        leaseID = try LinuxAuthorityStrict.require(String.self, "leaseID", in: container)
        processIdentity = try LinuxAuthorityStrict.require(LinuxAuthorityProcessIdentity.self, "processIdentity", in: container)
    }
}

/// Lease addressing without payload beyond the opaque id.
public struct LinuxAuthorityLeaseRequest: Codable, Sendable, Equatable {
    public var leaseID: String

    public init(leaseID: String) { self.leaseID = leaseID }

    private static let allowedKeys: Set<String> = ["leaseID"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try LinuxAuthorityStrict.rejectUnknown(container, allowed: Self.allowedKeys)
        leaseID = try LinuxAuthorityStrict.require(String.self, "leaseID", in: container)
    }
}

/// The trusted service's quiescence attestation. `exitStatus` is the raw
/// waitpid-style status the service reaped for the bound identity;
/// `reaped` must be true. The authority records the attestation and uses it
/// ONLY as the service's assertion — it is data, not OS-level proof this
/// module could verify.
public struct LinuxAuthorityQuiescence: Codable, Sendable, Equatable {
    public var exitStatus: Int
    public var reaped: Bool

    public init(exitStatus: Int, reaped: Bool) {
        self.exitStatus = exitStatus
        self.reaped = reaped
    }

    private static let allowedKeys: Set<String> = ["exitStatus", "reaped"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try LinuxAuthorityStrict.rejectUnknown(container, allowed: Self.allowedKeys)
        exitStatus = try LinuxAuthorityStrict.require(Int.self, "exitStatus", in: container)
        reaped = try LinuxAuthorityStrict.require(Bool.self, "reaped", in: container)
    }
}

public struct LinuxAuthorityCompleteRequest: Codable, Sendable, Equatable {
    public var leaseID: String
    /// Must equal the identity bound by markStarted EXACTLY.
    public var processIdentity: LinuxAuthorityProcessIdentity
    public var quiescence: LinuxAuthorityQuiescence

    public init(leaseID: String, processIdentity: LinuxAuthorityProcessIdentity, quiescence: LinuxAuthorityQuiescence) {
        self.leaseID = leaseID
        self.processIdentity = processIdentity
        self.quiescence = quiescence
    }

    private static let allowedKeys: Set<String> = ["leaseID", "processIdentity", "quiescence"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        try LinuxAuthorityStrict.rejectUnknown(container, allowed: Self.allowedKeys)
        leaseID = try LinuxAuthorityStrict.require(String.self, "leaseID", in: container)
        processIdentity = try LinuxAuthorityStrict.require(LinuxAuthorityProcessIdentity.self, "processIdentity", in: container)
        quiescence = try LinuxAuthorityStrict.require(LinuxAuthorityQuiescence.self, "quiescence", in: container)
    }
}

// MARK: - Reply envelope (frozen shapes; strictness is a request-side gate)

public struct LinuxAuthorityReply: Codable, Sendable, Equatable {
    public var version: Int
    public var requestID: String?
    public var outcome: LinuxAuthorityOutcome

    public init(version: Int, requestID: String?, outcome: LinuxAuthorityOutcome) {
        self.version = version
        self.requestID = requestID
        self.outcome = outcome
    }

    // EXPLICIT encode: WIRE_V1 freezes `requestID` as ALWAYS PRESENT (null
    // when the request carried none), so Main's Kotlin parser never has to
    // distinguish "absent" from "null". Synthesized encoding would drop the
    // key for nil.
    private enum CodingKeys: String, CodingKey { case version, requestID, outcome }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(outcome, forKey: .outcome)
    }
}

public enum LinuxAuthorityOutcome: Codable, Sendable, Equatable {
    /// Frozen: `{"ok":{…operation result…}}`.
    case ok(LinuxAuthorityResult)
    /// Frozen: `{"failure":{"code":"…","message":"…"}}`.
    case failure(LinuxAuthorityFailure)

    // EXPLICIT conformance: the synthesized encoding for single-payload enum
    // cases on this toolchain wraps the value under a `_0` key
    // ({"ok":{"_0":…}}). Main's JNI parses WIRE_V1 bytes, so the envelope
    // must freeze the documented single-key shape.
    private enum CodingKeys: String, CodingKey { case ok, failure }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok(let result): try container.encode(result, forKey: .ok)
        case .failure(let error): try container.encode(error, forKey: .failure)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch container.allKeys.first {
        case .ok: self = .ok(try container.decode(LinuxAuthorityResult.self, forKey: .ok))
        case .failure: self = .failure(try container.decode(LinuxAuthorityFailure.self, forKey: .failure))
        case nil: throw LinuxAuthorityWireError.invalidEnvelopeShape
        }
    }
}

public struct LinuxAuthorityFailure: Codable, Sendable, Equatable {
    public var code: String
    public var message: String

    public init(code: LinuxAuthorityErrorCode, message: String) {
        self.code = code.rawValue
        self.message = LinuxAuthorityWire.boundedMessage(message)
    }
}

/// Frozen version-1 result encoding: every case is a single-key object named
/// after the operation (`{"acquire":{…}}`, `{"handshake":{…}}`, …).
public enum LinuxAuthorityResult: Codable, Sendable, Equatable {
    case handshake(LinuxAuthorityHandshakeInfo)
    case configure(LinuxAuthorityConfigureInfo)
    case list(LinuxAuthorityEnvironmentList)
    case acquire(LinuxAuthorityAcquireInfo)
    case markStarted(LinuxAuthorityLeaseStateInfo)
    case cancel(LinuxAuthorityLeaseStateInfo)
    case complete(LinuxAuthorityCompleteInfo)
    case abandon(LinuxAuthorityAbandonInfo)

    private enum CodingKeys: String, CodingKey {
        case handshake, configure, list, acquire, markStarted, cancel, complete, abandon
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .handshake(let value): try container.encode(value, forKey: .handshake)
        case .configure(let value): try container.encode(value, forKey: .configure)
        case .list(let value): try container.encode(value, forKey: .list)
        case .acquire(let value): try container.encode(value, forKey: .acquire)
        case .markStarted(let value): try container.encode(value, forKey: .markStarted)
        case .cancel(let value): try container.encode(value, forKey: .cancel)
        case .complete(let value): try container.encode(value, forKey: .complete)
        case .abandon(let value): try container.encode(value, forKey: .abandon)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch container.allKeys.first {
        case .handshake: self = .handshake(try container.decode(LinuxAuthorityHandshakeInfo.self, forKey: .handshake))
        case .configure: self = .configure(try container.decode(LinuxAuthorityConfigureInfo.self, forKey: .configure))
        case .list: self = .list(try container.decode(LinuxAuthorityEnvironmentList.self, forKey: .list))
        case .acquire: self = .acquire(try container.decode(LinuxAuthorityAcquireInfo.self, forKey: .acquire))
        case .markStarted: self = .markStarted(try container.decode(LinuxAuthorityLeaseStateInfo.self, forKey: .markStarted))
        case .cancel: self = .cancel(try container.decode(LinuxAuthorityLeaseStateInfo.self, forKey: .cancel))
        case .complete: self = .complete(try container.decode(LinuxAuthorityCompleteInfo.self, forKey: .complete))
        case .abandon: self = .abandon(try container.decode(LinuxAuthorityAbandonInfo.self, forKey: .abandon))
        case nil: throw LinuxAuthorityWireError.invalidEnvelopeShape
        }
    }
}

public struct LinuxAuthorityHandshakeInfo: Codable, Sendable, Equatable {
    public var wireVersion: Int
    public var configured: Bool
    /// True while ANY holder is retained — including started, cancelled-but
    /// retained, and failed-release recoverable entries. New acquires and
    /// configuration replacement are refused globally while this is true.
    public var activeLease: Bool
    /// True while one lease admission is RESERVED but not yet committed
    /// (global concurrency 1 spans the await window, not just committed
    /// state). Also gates configuration replacement.
    public var leaseAdmissionPending: Bool
    /// True while one `configure` is applying. Lease admission and a second
    /// configuration attempt are refused while this holds.
    public var configurationInFlight: Bool
    /// Settled decision 2026-10-22: the initial linuxPRoot backend runs with
    /// ONE runtime lease globally, so materialization never mutates a live
    /// directory.
    public var maxConcurrentRuntimeLeases: Int
    /// ALWAYS false from this module: registry existence is not readiness.
    /// The original records/leases are authoritative for identity; capability
    /// enablement belongs to Main's composition after rootfs materialization,
    /// snapshot/inheritance and process-stop proof land.
    public var execShellReady: Bool

    public init(wireVersion: Int, configured: Bool, activeLease: Bool,
                leaseAdmissionPending: Bool, configurationInFlight: Bool,
                maxConcurrentRuntimeLeases: Int, execShellReady: Bool) {
        self.wireVersion = wireVersion
        self.configured = configured
        self.activeLease = activeLease
        self.leaseAdmissionPending = leaseAdmissionPending
        self.configurationInFlight = configurationInFlight
        self.maxConcurrentRuntimeLeases = maxConcurrentRuntimeLeases
        self.execShellReady = execShellReady
    }
}

public struct LinuxAuthorityConfigureInfo: Codable, Sendable, Equatable {
    public var configured: Bool
    /// False for the first configure and for an identical (no-op) repeat;
    /// true only when a different configuration replaced a lease-free one.
    public var replaced: Bool
    public var baseRevision: String
    /// Canonical (realpath-resolved) roots the authority now owns.
    public var stateRoot: String
    public var workspacesRoot: String
    public var baseRoot: String

    public init(configured: Bool, replaced: Bool, baseRevision: String,
                stateRoot: String, workspacesRoot: String, baseRoot: String) {
        self.configured = configured
        self.replaced = replaced
        self.baseRevision = baseRevision
        self.stateRoot = stateRoot
        self.workspacesRoot = workspacesRoot
        self.baseRoot = baseRoot
    }
}

public struct LinuxAuthorityEnvironmentList: Codable, Sendable, Equatable {
    public var baseRevision: String
    public var environments: [LinuxAuthorityEnvironmentMetadata]

    public init(baseRevision: String, environments: [LinuxAuthorityEnvironmentMetadata]) {
        self.baseRevision = baseRevision
        self.environments = environments
    }
}

/// Metadata ONLY — no layer paths, no variable maps, no process data.
public struct LinuxAuthorityEnvironmentMetadata: Codable, Sendable, Equatable {
    public var id: String
    public var kind: String
    public var ownerID: String?
    public var name: String?
    public var state: String
    public var baseRevision: String
    public var requiresRebuild: Bool
    public var rebuildReason: String?
    /// The record's explicit backend choice; nil means the record never made
    /// one and acquisition will be refused (never silently retargeted).
    public var executionBackend: String?
    public var bytes: Int64
    public var packageCount: Int
    public var parentID: String?
    public var templateID: String?

    public init(id: String, kind: String, ownerID: String?, name: String?, state: String,
                baseRevision: String, requiresRebuild: Bool, rebuildReason: String?,
                executionBackend: String?, bytes: Int64, packageCount: Int,
                parentID: String?, templateID: String?) {
        self.id = id
        self.kind = kind
        self.ownerID = ownerID
        self.name = name
        self.state = state
        self.baseRevision = baseRevision
        self.requiresRebuild = requiresRebuild
        self.rebuildReason = rebuildReason
        self.executionBackend = executionBackend
        self.bytes = bytes
        self.packageCount = packageCount
        self.parentID = parentID
        self.templateID = templateID
    }
}

public struct LinuxAuthorityAcquireInfo: Codable, Sendable, Equatable {
    /// Opaque holder id (canonical uppercase UUID string) — the ONLY handle
    /// for lifecycle operations.
    public var leaseID: String
    public var descriptor: LinuxAuthorityDescriptor

    public init(leaseID: String, descriptor: LinuxAuthorityDescriptor) {
        self.leaseID = leaseID
        self.descriptor = descriptor
    }
}

/// The acquired holder's validated descriptor, exactly the fields Main's
/// linuxruntime materializer + launch transport consume. `orderedLayers` is
/// LOOKUP ORDER (session > project > template > shared > base), not an
/// overlayfs and not materialization proof.
public struct LinuxAuthorityDescriptor: Codable, Sendable, Equatable {
    public var environmentID: String
    public var runID: String
    public var conversationID: String?
    public var workspaceID: String
    public var workspaceRoot: String
    public var projectContainerID: String
    public var backend: String
    public var writableLayer: String
    public var orderedLayers: [String]
    public var home: String
    public var tmp: String
    public var variables: [String: String]
    public var baseRevision: String

    public init(environmentID: String, runID: String, conversationID: String?, workspaceID: String,
                workspaceRoot: String, projectContainerID: String, backend: String,
                writableLayer: String, orderedLayers: [String], home: String, tmp: String,
                variables: [String: String], baseRevision: String) {
        self.environmentID = environmentID
        self.runID = runID
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        self.workspaceRoot = workspaceRoot
        self.projectContainerID = projectContainerID
        self.backend = backend
        self.writableLayer = writableLayer
        self.orderedLayers = orderedLayers
        self.home = home
        self.tmp = tmp
        self.variables = variables
        self.baseRevision = baseRevision
    }
}

public struct LinuxAuthorityLeaseStateInfo: Codable, Sendable, Equatable {
    public var leaseID: String
    /// "started" after markStarted, "cancelRequested" after cancel.
    public var state: String
    public var started: Bool
    /// Always false in version 1: cancellation and disconnect NEVER release.
    public var released: Bool

    public init(leaseID: String, state: String, started: Bool, released: Bool) {
        self.leaseID = leaseID
        self.state = state
        self.started = started
        self.released = released
    }
}

public struct LinuxAuthorityCompleteInfo: Codable, Sendable, Equatable {
    public var leaseID: String
    public var state: String
    /// True when the underlying coordinator lease was handed back by THIS
    /// call; false for an idempotent retry after the terminal entry.
    public var leaseHandedBack: Bool

    public init(leaseID: String, state: String, leaseHandedBack: Bool) {
        self.leaseID = leaseID
        self.state = state
        self.leaseHandedBack = leaseHandedBack
    }
}

public struct LinuxAuthorityAbandonInfo: Codable, Sendable, Equatable {
    public var leaseID: String
    public var state: String
    public var released: Bool

    public init(leaseID: String, state: String, released: Bool) {
        self.leaseID = leaseID
        self.state = state
        self.released = released
    }
}
