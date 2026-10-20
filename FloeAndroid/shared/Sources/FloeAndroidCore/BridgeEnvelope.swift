// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Bridge protocol v2 — typed, append-only command/event envelope seam.
///
/// Design rules (Main directives, 2026-10-17/18):
/// * Version 1 dispatch in Bridge.swift is frozen; this file adds a separate
///   version-2 path without changing any v1 operation, bound or error.
/// * Every v2 stateful command carries explicit identity: task/run/environment/
///   job UUIDs (task-execution scope) or an explicit host-owned application-
///   configuration scope. Global provider/model settings NEVER accept
///   fabricated task/run/environment/job UUIDs.
/// * A grantID is a reference only. Imported content, model JSON and this
///   envelope can never create a host grant; authority resolution stays with
///   the later host-side binder.
/// * Only truly executable operations are advertised. `command.submit` and
///   `event.poll` are reported under stagedOperations with bound=false while
///   no live binder is registered: typed schema support is NOT working task
///   or provider operations, and no response here fabricates success.
/// * Large/binary payloads (attachments) must use separate chunked streams —
///   the 64 KiB JSON bound is never enlarged for them.
public enum BridgeV2 {
    /// The all-zero UUID. `UUID.uuidNil` is not available across all
    /// Foundation overlays, so the rule declares it explicitly.
    static let nilUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    public static let version = 2
    public static let envelopeSchema = "floe.command-envelope/2"

    /// Operations that truly execute in this seam.
    public static let availableOperations = ["handshake", "credential.status"]

    /// Schema-only staged operations (typed validation + fail-closed refusal
    /// until the host binder packages land). `bound` is false in the current
    /// foundation: typed schema support is NOT a working domain operation.
    public struct StagedOperation: Sendable {
        public let operation: String
        public let bound: Bool
        public let schema: String
    }
    public static let stagedOperations: [StagedOperation] = [
        StagedOperation(operation: "command.submit", bound: false, schema: envelopeSchema),
        StagedOperation(operation: "event.poll", bound: false, schema: "floe.event-cursor/2"),
    ]

    static func handle(request: [String: Any], requestID: String?) -> [String: Any] {
        switch request["operation"] as? String {
        case "handshake":
            return [
                "ok": true,
                "core": "FloeAndroidCore",
                "operations": availableOperations,
                "stagedOperations": stagedOperations.map {
                    ["operation": $0.operation, "bound": $0.bound, "schema": $0.schema]
                },
                "sharedModels": ["TaskPolicy"],
                "localLLM": false,
            ]
        case "credential.status":
            let registered = SecretGatewayRegistry.shared.isRegistered
            return ["ok": true, "secretBackend": [
                "registered": registered,
                // Fail-closed: without a registered JNI gateway providers
                // report NEEDS_CONFIGURATION. There is no memory fallback and
                // the original KeychainStore RAM stub is not compiled at all.
                "availability": registered ? "AVAILABLE" : "NEEDS_CONFIGURATION",
                "memoryFallback": false,
            ]]
        case "command.submit":
            return routeCommand(request: request, requestID: requestID, requiresCursor: false)
        case "event.poll":
            return routeCommand(request: request, requestID: requestID, requiresCursor: true)
        default:
            return ["ok": false, "error": "unsupportedOperation"]
        }
    }

    private static func routeCommand(request: [String: Any], requestID: String?,
                                     requiresCursor: Bool) -> [String: Any] {
        func failure(_ code: String, _ reason: String? = nil) -> [String: Any] {
            var value: [String: Any] = ["ok": false, "error": code]
            if let reason { value["reason"] = reason }
            return value
        }
        guard let envelopeObject = request["envelope"],
              JSONSerialization.isValidJSONObject(envelopeObject),
              let envelopeData = try? JSONSerialization.data(withJSONObject: envelopeObject),
              let envelope = try? JSONSerialization.jsonObject(with: envelopeData) as? [String: Any]
        else { return failure("invalidEnvelope", "missingEnvelopeObject") }

        let validation = validateEnvelope(envelope, requestID: requestID,
                                         requiresCursor: requiresCursor)
        guard validation.isValid else {
            return failure(validation.errorCode, validation.reason)
        }
        let command = (envelope["command"] as? String) ?? ""
        if requiresCursor {
            // The cursor is structurally valid; the live event pump is bound
            // by a later package (bounded buffers/cursors), never here.
            if let handler = RuntimeCommandBinder.shared.handler(for: "event.poll") {
                return execute(handler, envelopeData: envelopeData, failure: failure)
            }
            return failure("runtimeUnavailable", "eventPumpUnbound")
        }
        if let handler = RuntimeCommandBinder.shared.handler(for: command) {
            // A live, host-registered binder executes here. In this lane no
            // handler is registered, so this branch is exercised only by
            // synthetic host tests proving the seam is real.
            return execute(handler, envelopeData: envelopeData, failure: failure)
        }
        // Fail-closed seam: validated envelope, no fake execution.
        return failure("runtimeUnavailable", "commandBinderUnbound")
    }

    /// Handlers exchange JSON bytes, keeping the strict-concurrency contract
    /// explicit ([String: Any] is not Sendable across a @Sendable boundary).
    private static func execute(_ handler: RuntimeCommandBinder.Handler, envelopeData: Data,
                                failure: (String, String?) -> [String: Any]) -> [String: Any] {
        let output = handler(envelopeData)
        guard let object = (try? JSONSerialization.jsonObject(with: output)) as? [String: Any] else {
            return failure("invalidBinderOutput", nil)
        }
        return object
    }

    public struct ValidationResult: Sendable, Equatable {
        public var isValid: Bool
        public var errorCode: String
        public var reason: String
        public init(isValid: Bool, errorCode: String, reason: String) {
            self.isValid = isValid
            self.errorCode = errorCode
            self.reason = reason
        }
    }

    /// Mirrors the frozen Kotlin RuntimeContracts identity rules
    /// (ExecutionOwner / EventCursor / Revision / OperationContext) with one
    /// production hardening: identity UUIDs must be explicit — zero/default
    /// UUIDs are rejected as fabrication. Role fields may carry equal UUID
    /// values (for example a root `jobID` that equals its `runID`): the role
    /// is the structured field, and the frozen `ExecutionOwner` contract has
    /// no value-inequality requirement.
    public static func validateEnvelope(_ envelope: [String: Any], requestID: String?,
                                        requiresCursor: Bool) -> ValidationResult {
        // Keep the original payload acceptance rule before typed decoding.
        if let payload = envelope["payload"], !JSONSerialization.isValidJSONObject(payload),
           !(payload is String), !(payload is NSNumber) {
            return ValidationResult(isValid: false, errorCode: "invalidEnvelope",
                                    reason: "invalidPayload")
        }
        // Decode through JSONDecoder instead of Foundation `as? Bool`/`as? Int`
        // bridging: the typed primitive union distinguishes JSON booleans,
        // integers, fractions, strings and null without NSNumber coercion.
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let root = try? JSONDecoder().decode(StrictJSONValue.self, from: data),
              case .object(let object) = root else {
            return ValidationResult(isValid: false, errorCode: "invalidEnvelope",
                                    reason: "malformedEnvelope")
        }
        return validateTypedEnvelope(object, requestID: requestID,
                                     requiresCursor: requiresCursor)
    }

    /// The only representation used while validating an envelope. Decoding
    /// into an explicit union keeps JSON `true` distinct from `1`, and JSON
    /// integer `1` distinct from `1.5`, on both Darwin and Android.
    private enum StrictJSONValue: Decodable {
        case object([String: StrictJSONValue])
        case array([StrictJSONValue])
        case string(String)
        case integer(Int)
        case fractional(Double)
        case boolean(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .boolean(value)
            } else if let value = try? container.decode(Int.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .fractional(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([StrictJSONValue].self) {
                self = .array(value)
            } else if let value = try? container.decode([String: StrictJSONValue].self) {
                self = .object(value)
            } else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "unsupported JSON value"))
            }
        }
    }

    private static func stringValue(_ value: StrictJSONValue?) -> String? {
        guard let value, case .string(let string) = value else { return nil }
        return string
    }

    private static func objectValue(_ value: StrictJSONValue?) -> [String: StrictJSONValue]? {
        guard let value, case .object(let object) = value else { return nil }
        return object
    }

    private static func integerValue(_ value: StrictJSONValue?) -> Int? {
        guard let value, case .integer(let integer) = value else { return nil }
        return integer
    }

    private static func booleanValue(_ value: StrictJSONValue?) -> Bool? {
        guard let value, case .boolean(let boolean) = value else { return nil }
        return boolean
    }

    private static func validateTypedEnvelope(_ envelope: [String: StrictJSONValue],
                                              requestID: String?,
                                              requiresCursor: Bool) -> ValidationResult {
        let invalid: (String) -> ValidationResult = {
            ValidationResult(isValid: false, errorCode: "invalidEnvelope", reason: $0)
        }
        guard let scope = stringValue(envelope["scope"]) else { return invalid("missingScope") }
        var hostScope: String?
        switch scope {
        case "taskExecution":
            guard envelope["configurationScope"] == nil else {
                return invalid("taskScopeMustNotCarryConfigurationScope")
            }
            guard let owner = objectValue(envelope["owner"]) else {
                return invalid("missingExecutionOwner")
            }
            // Presence, UUID parse and non-nil checks stay in force. Value
            // uniqueness is intentionally NOT required: explicitly authored
            // role IDs may alias, and shape uniqueness never proved
            // authorship or granted authority.
            for key in ["taskID", "runID", "environmentID", "jobID"] {
                guard let raw = stringValue(owner[key]), let id = UUID(uuidString: raw),
                      id != BridgeV2.nilUUID else {
                    return invalid("invalidOwner\(key)")
                }
            }
        case "applicationConfiguration":
            guard envelope["owner"] == nil else {
                // Global configuration must never smuggle fabricated task/run
                // environment/job UUIDs.
                return invalid("configurationScopeMustNotCarryOwner")
            }
            guard let value = stringValue(envelope["configurationScope"]),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 256 else {
                return invalid("missingConfigurationScope")
            }
            hostScope = value
        default:
            return invalid("unknownScope")
        }
        if envelope["owner"] != nil && scope != "taskExecution" { return invalid("ownerInWrongScope") }
        guard let command = stringValue(envelope["command"]),
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.count <= 128,
              !command.contains(" ") else {
            return invalid("invalidCommand")
        }
        guard let statefulValue = envelope["stateful"] else {
            return invalid("missingStatefulFlag")
        }
        guard let stateful = booleanValue(statefulValue) else {
            // JSON 0/1, "true" and null are not booleans. Accepting them
            // would let a stateful command bypass revision enforcement.
            return invalid("invalidStatefulFlag")
        }
        if let revisionValue = envelope["revision"] {
            guard let revision = objectValue(revisionValue),
                  let resourceID = stringValue(revision["resourceID"]),
                  !resourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let version = stringValue(revision["version"]),
                  !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return invalid("invalidRevision")
            }
            // Revision values are opaque identities: they are validated as
            // non-blank, never trimmed into a different value.
        } else if stateful {
            return invalid("missingRevisionForStatefulCommand")
        }
        if let cursorValue = envelope["cursor"] {
            guard let cursor = objectValue(cursorValue),
                  let raw = stringValue(cursor["runID"]),
                  let runID = UUID(uuidString: raw),
                  runID != BridgeV2.nilUUID,
                  let sequence = integerValue(cursor["sequence"]),
                  sequence >= 0 else {
                return invalid("invalidEventCursor")
            }
            if scope == "taskExecution", let owner = objectValue(envelope["owner"]),
               let ownerRun = stringValue(owner["runID"]),
               UUID(uuidString: ownerRun) != runID {
                return invalid("cursorRunMismatch")
            }
        } else if requiresCursor {
            return invalid("missingEventCursor")
        }
        if let grantValue = envelope["grantID"] {
            guard let string = stringValue(grantValue), let grant = UUID(uuidString: string),
                  grant != BridgeV2.nilUUID else {
                return invalid("invalidGrantReference")
            }
            // grantID is a reference only; validation never grants authority.
        }
        guard let correlation = stringValue(envelope["correlationID"]),
              !correlation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return invalid("missingCorrelation") }
        // Exact identity: opaque correlation values are never trimmed.
        guard correlation == requestID else { return ValidationResult(
            isValid: false, errorCode: "correlationMismatch", reason: "correlationNotRequestID") }
        _ = hostScope
        return ValidationResult(isValid: true, errorCode: "", reason: "")
    }
}

/// Live command executors register here from host code (Kotlin binder via JNI
/// in later packages). Registration is host-side only: model JSON, imported
/// documents and tool output cannot register handlers or grant authority.
/// In this lane the registry is intentionally empty — every validated command
/// receives a typed runtimeUnavailable refusal, never a synthetic completion.
public final class RuntimeCommandBinder: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) -> Data
    public static let shared = RuntimeCommandBinder()
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]

    public func register(_ operation: String, _ handler: @escaping Handler) {
        lock.lock(); handlers[operation] = handler; lock.unlock()
    }
    public func unregister(_ operation: String) {
        lock.lock(); handlers[operation] = nil; lock.unlock()
    }
    public func handler(for operation: String) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        return handlers[operation]
    }
    public var registeredOperationCount: Int {
        lock.lock(); defer { lock.unlock() }
        return handlers.count
    }
}
