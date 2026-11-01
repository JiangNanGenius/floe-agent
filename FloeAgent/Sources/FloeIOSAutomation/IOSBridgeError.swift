// FloeIOSAutomation — canonical client and server error surface.

import Foundation

public enum IOSBridgeError: Error, Equatable, Sendable {
    // Local / configuration
    case unsupportedPlatform
    case invalidEndpoint
    case invalidRequest(String)
    case requestTooLarge
    case responseTooLarge
    case actionNotAllowed(String)
    case invalidArguments(String)
    case executionWindowExpired
    case staleTaskGeneration
    case deviceBusy
    case cancelled
    case serviceFenced

    // Transport
    case transportUnavailable
    case transportNotPermitted
    case transportDenied
    case timedOut
    case connectionLost
    case invalidResponse
    case badEnvelope
    case responseTooLargeResult
    case http(status: Int, code: String, message: String)

    // Pairing and authentication
    case authRequired
    case authFailed
    case timestampSkew
    case nonceReplayed
    case nonceFlood
    case authUnavailable
    case pairingDenied
    case pairingBusy(retryAfter: Int)
    case pairingCooldown(retryAfter: Int)
    case pairingTimedOut
    case pairingInProgress
    case alreadyPaired
    case pairingResponseInvalid
    case plainPairingForbidden
    case incompatibleBridge(protocolVersion: Int)
    case pairingExpired
    case pairingRevoked

    // Injected credential storage contract
    case credentialStoreLocked
    case credentialStoreUnavailable
    case credentialStoreMissing
    case credentialRecordInvalid
    case credentialRecordMismatch
    case credentialStoreVerificationFailed

    // RPC / engine / execution
    case engineNotReady(reason: String)
    case methodNotAvailable
    case permissionDenied
    case queueFull
    case executionTimedOut
    case operationOutcomeUnknown
    case operationInProgress
    case operationIDConflict
    case operationAlreadyCompleted
    case serviceStopping
    case serverError(code: Int, message: String)
    case unexpected(String)

    // Local policy
    case protectedTarget
    case protectedTargetUnknown
    case targetNotForeground
    case authorityDenied(reason: String)
    case inputBusy

    /// Stable, non-secret code for diagnostics and tests. This is not the
    /// server's wire code; it identifies the client-side classification.
    public var canonicalCode: String {
        switch self {
        case .unsupportedPlatform: return "unsupported_platform"
        case .invalidEndpoint: return "invalid_endpoint"
        case .invalidRequest: return "invalid_request"
        case .requestTooLarge: return "request_too_large"
        case .responseTooLarge: return "response_too_large"
        case .actionNotAllowed: return "action_not_allowed"
        case .invalidArguments: return "invalid_arguments"
        case .executionWindowExpired: return "execution_window_expired"
        case .staleTaskGeneration: return "stale_task_generation"
        case .deviceBusy: return "device_busy"
        case .cancelled: return "cancelled"
        case .serviceFenced: return "fenced"
        case .transportUnavailable: return "transport_unavailable"
        case .transportNotPermitted: return "transport_not_permitted"
        case .transportDenied: return "transport_denied"
        case .timedOut: return "timed_out"
        case .connectionLost: return "connection_lost"
        case .invalidResponse: return "invalid_response"
        case .badEnvelope: return "bad_envelope"
        case .responseTooLargeResult: return "response_too_large_result"
        case .http(let status, let code, _): return "http_\(status)_\(code)"
        case .authRequired: return "auth_required"
        case .authFailed: return "auth_failed"
        case .timestampSkew: return "ts_skew"
        case .nonceReplayed: return "nonce_replayed"
        case .nonceFlood: return "nonce_flood"
        case .authUnavailable: return "auth_unavailable"
        case .pairingDenied: return "pair_denied"
        case .pairingBusy: return "pair_busy"
        case .pairingCooldown: return "pair_cooldown"
        case .pairingTimedOut: return "pair_timeout"
        case .pairingInProgress: return "pair_in_progress"
        case .alreadyPaired: return "already_paired"
        case .pairingResponseInvalid: return "pair_response_invalid"
        case .plainPairingForbidden: return "plain_forbidden"
        case .incompatibleBridge: return "incompatible_bridge"
        case .pairingExpired: return "pairing_expired"
        case .pairingRevoked: return "pairing_revoked"
        case .credentialStoreLocked: return "credential_store_locked"
        case .credentialStoreUnavailable: return "credential_store_unavailable"
        case .credentialStoreMissing: return "credential_store_missing"
        case .credentialRecordInvalid: return "credential_record_invalid"
        case .credentialRecordMismatch: return "credential_record_mismatch"
        case .credentialStoreVerificationFailed: return "credential_store_verification_failed"
        case .engineNotReady: return "engine_not_ready"
        case .methodNotAvailable: return "method_not_available"
        case .permissionDenied: return "permission_denied"
        case .queueFull: return "queue_full"
        case .executionTimedOut: return "execution_timed_out"
        case .operationOutcomeUnknown: return "operation_outcome_unknown"
        case .operationInProgress: return "operation_in_progress"
        case .operationIDConflict: return "operation_id_conflict"
        case .operationAlreadyCompleted: return "operation_already_completed"
        case .serviceStopping: return "service_stopping"
        case .serverError: return "server_error"
        case .unexpected: return "unexpected"
        case .protectedTarget: return "protected_target"
        case .protectedTargetUnknown: return "protected_target_unknown"
        case .targetNotForeground: return "target_not_foreground"
        case .authorityDenied: return "authority_denied"
        case .inputBusy: return "input_busy"
        }
    }

    /// True when the failure conclusively means the operation was not
    /// dispatched (or the local preconditions refused it).
    public var isDefiniteNonExecution: Bool {
        switch self {
        case .unsupportedPlatform, .invalidEndpoint, .invalidRequest, .requestTooLarge,
             .actionNotAllowed, .invalidArguments, .executionWindowExpired,
             .staleTaskGeneration, .deviceBusy, .transportUnavailable,
             .transportNotPermitted, .transportDenied, .badEnvelope, .timestampSkew,
             .nonceReplayed, .nonceFlood, .authUnavailable, .engineNotReady,
             .methodNotAvailable, .permissionDenied, .queueFull, .operationInProgress,
             .operationIDConflict, .serviceStopping, .protectedTarget,
             .protectedTargetUnknown, .targetNotForeground, .authorityDenied, .inputBusy, .alreadyPaired,
             .pairingInProgress:
            return true
        default:
            return false
        }
    }

    /// True when a mutation must be reported as outcome-unknown rather than a
    /// failure, because Bridge did not supply a reliable completion receipt.
    public var mayHaveTakenEffectWithoutReceipt: Bool {
        switch self {
        case .executionTimedOut, .operationOutcomeUnknown, .operationAlreadyCompleted,
             .serviceFenced, .responseTooLargeResult:
            return true
        default:
            return false
        }
    }

    public var isAuthenticationFailure: Bool {
        switch self {
        case .authRequired, .authFailed, .pairingExpired, .pairingRevoked:
            return true
        default:
            return false
        }
    }

    public var userMessage: String {
        switch self {
        case .unsupportedPlatform:
            return "Local iOS automation is available only in Floe running on a supported iPhone or iPad."
        case .invalidEndpoint:
            return "The local Bridge endpoint is invalid."
        case .invalidRequest:
            return "The Bridge request is malformed."
        case .requestTooLarge:
            return "The Bridge request exceeded its bounded size."
        case .responseTooLarge, .responseTooLargeResult:
            return "The Bridge response exceeded its bounded size."
        case .actionNotAllowed:
            return "This action is not allowed through the native automation interface."
        case .invalidArguments(let message):
            return message
        case .executionWindowExpired:
            return "The task's execution window ended before the action could start."
        case .staleTaskGeneration:
            return "This task generation is no longer active."
        case .deviceBusy:
            return "Another device action is using the Bridge connection."
        case .cancelled:
            return "The action was cancelled."
        case .serviceFenced:
            return "The action was fenced by a lifecycle change."
        case .transportUnavailable:
            return "The Bridge service is not reachable on this device."
        case .transportNotPermitted:
            return "The system blocked the local Bridge connection."
        case .transportDenied:
            return "The Bridge refused this connection type."
        case .timedOut:
            return "The Bridge did not answer in time."
        case .connectionLost:
            return "The connection to Bridge was lost."
        case .invalidResponse:
            return "Bridge returned an unreadable response."
        case .badEnvelope:
            return "Bridge rejected the encrypted request envelope."
        case .http(_, _, let message):
            return Self.bounded(message)
        case .authRequired:
            return "Pair this iPhone or iPad with Bridge first."
        case .authFailed, .pairingRevoked:
            return "The saved pairing is no longer authorized. Pair again after the owner approves."
        case .pairingExpired:
            return "The saved pairing expired after 30 days without use. Pair again."
        case .timestampSkew:
            return "The device clock is outside the Bridge time window."
        case .nonceReplayed:
            return "Bridge rejected a replayed request. Nothing was replayed by this client."
        case .nonceFlood:
            return "Bridge is receiving too many requests. Retry after the current work settles."
        case .authUnavailable:
            return "Bridge could not verify authorization state safely; nothing was executed."
        case .pairingDenied:
            return "The device owner declined the pairing request."
        case .pairingBusy:
            return "Another pairing request is waiting for the owner."
        case .pairingCooldown:
            return "A pairing request was just refused. Try again shortly."
        case .pairingTimedOut:
            return "The pairing request timed out. Check Bridge on this device before trying again."
        case .pairingInProgress:
            return "A pairing request is already in progress."
        case .alreadyPaired:
            return "This device already has a saved Bridge pairing."
        case .pairingResponseInvalid:
            return "Bridge returned an invalid pairing response. Nothing was saved."
        case .plainPairingForbidden:
            return "Bridge refused a non-local pairing mode."
        case .incompatibleBridge(let version):
            return "This Bridge uses protocol version \(version); Floe expects version \(IOSBridgeProtocol.protocolVersion)."
        case .credentialStoreLocked:
            return "Saved Bridge credentials are locked. Unlock this device and try again."
        case .credentialStoreUnavailable:
            return "Saved Bridge credentials are temporarily unavailable."
        case .credentialStoreMissing:
            return "No Bridge pairing is saved on this device."
        case .credentialRecordInvalid:
            return "The saved Bridge pairing record is invalid. Pair again."
        case .credentialRecordMismatch:
            return "The saved Bridge pairing does not match the Bridge on this device."
        case .credentialStoreVerificationFailed:
            return "The Bridge pairing could not be saved and read back reliably. Nothing was claimed as paired."
        case .engineNotReady(let reason):
            return reason.isEmpty ? "Bridge is running, but its automation engine is not ready." : Self.bounded(reason)
        case .methodNotAvailable:
            return "This Bridge build does not provide that automation method."
        case .permissionDenied:
            return "Bridge has not granted this permission."
        case .queueFull:
            return "Bridge is busy. Nothing was executed; try again after the current work settles."
        case .executionTimedOut:
            return "Bridge did not finish in time. The action may already have taken effect."
        case .operationOutcomeUnknown:
            return "Bridge could not confirm whether the action took effect. Observe the screen before deciding what to do."
        case .operationInProgress:
            return "The same Bridge operation is still running."
        case .operationIDConflict:
            return "That operation identifier was already used for a different request."
        case .operationAlreadyCompleted:
            return "The operation already completed and its result is no longer retained."
        case .serviceStopping:
            return "Bridge is stopping."
        case .serverError(_, let message), .unexpected(let message):
            return Self.bounded(message)
        case .protectedTarget:
            return "Floe and Bridge authorization surfaces cannot be controlled by automation."
        case .protectedTargetUnknown:
            return "The foreground app could not be verified, so device input was refused."
        case .targetNotForeground:
            return "The declared target app is not in the foreground."
        case .authorityDenied(let reason):
            return IOSBridgeError.bounded(reason.isEmpty ? "This task is not authorized to perform that device action." : reason)
        case .inputBusy:
            return "Another task is using device input."
        }
    }

    public var retryAfter: Int? {
        switch self {
        case .pairingBusy(let seconds), .pairingCooldown(let seconds): return seconds
        default: return nil
        }
    }

    private static func bounded(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Bridge reported an error." }
        return String(trimmed.prefix(1_024))
    }
}

extension IOSBridgeError: LocalizedError {
    public var errorDescription: String? { userMessage }
}

/// Parsed plaintext HTTP error document from the Bridge transport layer.
public struct IOSBridgeErrorDocument: Sendable, Equatable {
    public var code: String
    public var message: String
    public var retryAfter: Int?

    public static func decode(_ data: Data) -> IOSBridgeErrorDocument? {
        guard let value = try? IOSBridgeJSONValue.decode(data),
              let object = value.objectValue,
              let error = object["error"]?.objectValue,
              let code = error["code"]?.stringValue else {
            return nil
        }
        let message = error["message"]?.stringValue ?? ""
        let retryAfter = error["retry_after"]?.intValue
        return IOSBridgeErrorDocument(code: code, message: message, retryAfter: retryAfter)
    }
}

public extension IOSBridgeError {
    /// Maps a plaintext HTTP error returned before an authenticated RPC
    /// response exists. Context-specific expired/revoked classification is
    /// applied by the client, which owns the pairing record.
    static func fromHTTP(status: Int, document: IOSBridgeErrorDocument?) -> IOSBridgeError {
        let code = document?.code ?? ""
        let message = document?.message ?? ""
        switch code {
        case "pair_denied": return .pairingDenied
        case "pair_busy": return .pairingBusy(retryAfter: document?.retryAfter ?? 60)
        case "pair_cooldown": return .pairingCooldown(retryAfter: document?.retryAfter ?? 15)
        case "plain_forbidden": return .plainPairingForbidden
        case "transport_denied": return .transportDenied
        case "auth_required": return .authRequired
        case "auth_failed": return .authFailed
        case "ts_skew": return .timestampSkew
        case "nonce_replayed": return .nonceReplayed
        case "nonce_flood": return .nonceFlood
        case "auth_unavailable": return .authUnavailable
        case "bad_envelope": return .badEnvelope
        case "service_stopping": return .serviceStopping
        case "request_body_too_large", "request_head_too_large": return .requestTooLarge
        case "bad_request", "bad_request_head", "bad_request_line", "bad_method", "bad_path",
             "bad_version", "bad_header", "bad_header_name", "bad_header_value",
             "duplicate_content_length", "bad_content_length", "unsupported_transfer",
             "missing_host", "unexpected_body", "unexpected_empty_header",
             "unexpected_trailing_bytes", "missing_request_line", "folded_header",
             "duplicate_header":
            return .invalidRequest(code.isEmpty ? "Bridge rejected the HTTP request." : code)
        default:
            return .http(
                status: status,
                code: code.isEmpty ? "http_\(status)" : code,
                message: message.isEmpty ? "Bridge returned HTTP \(status)." : message
            )
        }
    }

    /// Maps a sealed JSON-RPC error object.
    static func fromJSONRPC(code: Int, message: String, data: [String: IOSBridgeJSONValue]?) -> IOSBridgeError {
        switch code {
        case -32700, -32600: return .invalidRequest(message)
        case -32601: return .methodNotAvailable
        case -32602: return .invalidArguments(message)
        case -32603: return .serverError(code: code, message: message)
        case -32010:
            let reason = data?["reason"]?.stringValue ?? message
            return .engineNotReady(reason: reason)
        case -32011: return .methodNotAvailable
        case -32012: return .permissionDenied
        case -32013: return .operationOutcomeUnknown
        case -32014: return .operationInProgress
        case -32015: return .operationIDConflict
        case -32016: return .queueFull
        case -32017: return .executionTimedOut
        case -32018: return .responseTooLargeResult
        case -32019: return .serviceStopping
        case -32020: return .operationAlreadyCompleted
        case -32021: return .serviceFenced
        case -32099: return .authFailed
        default: return .serverError(code: code, message: message)
        }
    }
}
