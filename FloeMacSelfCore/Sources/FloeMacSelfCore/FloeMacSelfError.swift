// SPDX-License-Identifier: MPL-2.0
//
// Bounded errors and redacted failure identities for the Mac self-owned
// runtime composition. Error messages intentionally carry no goal text,
// provider bodies, credentials or full filesystem listings.

import Foundation
import FloeCore

/// Stable rejection reasons for approval commands. These values are part of
/// the command contract: the UI may branch on them, but they never grant
/// authority.
public enum FloeMacSelfApprovalRejection: String, Sendable, Hashable, CaseIterable {
    case conversationMismatch
    case runMismatch
    case workspaceMismatch
    case toolsDisabled
    case noPendingApproval
    case callMismatch
    case toolMismatch
    case scopeNotOwned
    case sessionEnded
    case notAccepted
}

/// Errors raised by the composition layer before or around the existing Floe
/// runtime. Once a run is admitted, provider/tool failures are reported as
/// real runtime events and durable run state instead of being rewritten here.
public enum FloeMacSelfCoreError: Error, Sendable, Hashable {
    case invalidOwner(String)
    case runtimeClosed
    case notBootstrapped
    case schemaMismatch(expected: Int, actual: Int)
    case invalidDatabaseLocation(String)
    case authorityLocked
    case authorityLockUnsafe(String)
    case hostProvenanceUnavailable(String)
    case authoritySchemaUnsupported(String)
    case authorityCorrupted(String)
    case admissionUnknown(UUID)
    case admissionConflict(UUID)
    case invalidRequest(String)
    case attachmentUnavailable(String)
    case attachmentUnreadable(String)
    case unsupportedConversationMode(String)
    case providerUnavailable(String)
    case adapterProtocolMismatch(expected: String, actual: String)
    case modelDoesNotSupportTools
    case toolCapabilityUnavailable(String)
    case goalBindingUnavailable(String)
    case invalidTaskBoundary(String)
    case executionEnvironmentUnsupported
    case hostGateUnavailable(String)
    case hostGateMismatch(String)
    case conversationBusy(UUID)
    case preparedIdentityMismatch(String)
    case sessionNotFound(UUID)
    case sessionTornDown(UUID)
    case sessionNotFinished(UUID)
    case terminalNotConfirmed(UUID)
    case activeSessions([UUID])
    case unconfirmedSessions([UUID])
    case shutdownIncomplete([UUID])
    case approvalRejected(FloeMacSelfApprovalRejection)
    case persistenceUnavailable(String)

    /// Stable machine label. Associated values are deliberately excluded.
    public var code: String {
        switch self {
        case .invalidOwner: return "invalidOwner"
        case .runtimeClosed: return "runtimeClosed"
        case .notBootstrapped: return "notBootstrapped"
        case .schemaMismatch: return "schemaMismatch"
        case .invalidDatabaseLocation: return "invalidDatabaseLocation"
        case .authorityLocked: return "authorityLocked"
        case .authorityLockUnsafe: return "authorityLockUnsafe"
        case .hostProvenanceUnavailable: return "hostProvenanceUnavailable"
        case .authoritySchemaUnsupported: return "authoritySchemaUnsupported"
        case .authorityCorrupted: return "authorityCorrupted"
        case .admissionUnknown: return "admissionUnknown"
        case .admissionConflict: return "admissionConflict"
        case .invalidRequest: return "invalidRequest"
        case .attachmentUnavailable: return "attachmentUnavailable"
        case .attachmentUnreadable: return "attachmentUnreadable"
        case .unsupportedConversationMode: return "unsupportedConversationMode"
        case .providerUnavailable: return "providerUnavailable"
        case .adapterProtocolMismatch: return "adapterProtocolMismatch"
        case .modelDoesNotSupportTools: return "modelDoesNotSupportTools"
        case .toolCapabilityUnavailable: return "toolCapabilityUnavailable"
        case .goalBindingUnavailable: return "goalBindingUnavailable"
        case .invalidTaskBoundary: return "invalidTaskBoundary"
        case .executionEnvironmentUnsupported: return "executionEnvironmentUnsupported"
        case .hostGateUnavailable: return "hostGateUnavailable"
        case .hostGateMismatch: return "hostGateMismatch"
        case .conversationBusy: return "conversationBusy"
        case .preparedIdentityMismatch: return "preparedIdentityMismatch"
        case .sessionNotFound: return "sessionNotFound"
        case .sessionTornDown: return "sessionTornDown"
        case .sessionNotFinished: return "sessionNotFinished"
        case .terminalNotConfirmed: return "terminalNotConfirmed"
        case .activeSessions: return "activeSessions"
        case .unconfirmedSessions: return "unconfirmedSessions"
        case .shutdownIncomplete: return "shutdownIncomplete"
        case .approvalRejected: return "approvalRejected"
        case .persistenceUnavailable: return "persistenceUnavailable"
        }
    }
}

extension FloeMacSelfCoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidOwner(let detail):
            return "The Mac runtime owner identity is invalid: \(detail)"
        case .runtimeClosed:
            return "The Mac runtime has already been shut down."
        case .notBootstrapped:
            return "The Mac runtime database has not been migrated for this host."
        case .schemaMismatch(let expected, let actual):
            return "The Mac runtime database schema is \(actual); this build requires \(expected)."
        case .invalidDatabaseLocation(let detail):
            return "The Mac runtime database location is unusable: \(detail)"
        case .authorityLocked:
            return "Another Floe self-core owner already holds this Mac runtime database."
        case .authorityLockUnsafe(let detail):
            return "The Mac runtime authority lock is not safely owned: \(detail)"
        case .hostProvenanceUnavailable(let detail):
            return "The host authority provenance for the Mac runtime database is unavailable: \(detail)"
        case .authoritySchemaUnsupported(let detail):
            return "The Mac runtime admission schema is unsupported: \(detail)"
        case .authorityCorrupted(let detail):
            return "The Mac runtime authority data is inconsistent: \(detail)"
        case .admissionUnknown:
            return "This conversation has an unresolved Mac run admission. Automatic retry is blocked; reconcile the recorded run first."
        case .admissionConflict:
            return "The Mac run admission changed underneath this attempt. The attempt was not started."

        case .invalidRequest(let detail):
            return "The Mac session request is invalid: \(detail)"
        case .attachmentUnavailable:
            return "The document changed or could not be opened. Attach it again."
        case .attachmentUnreadable:
            return "No readable text could be extracted within the attachment limit."
        case .unsupportedConversationMode(let detail):
            return "This Mac runtime stage does not support that conversation mode: \(detail)"
        case .providerUnavailable(let detail):
            return "The selected provider is unavailable: \(detail)"
        case .adapterProtocolMismatch(let expected, let actual):
            return "The provider adapter speaks \(actual), but the provider profile requires \(expected)."
        case .modelDoesNotSupportTools:
            return "The selected model does not declare tool calling, so a tool-enabled session cannot start."
        case .toolCapabilityUnavailable(let detail):
            return "The host tool capability is unavailable: \(detail)"
        case .goalBindingUnavailable(let detail):
            return "The durable Goal could not be bound to this run: \(detail)"
        case .invalidTaskBoundary(let detail):
            return "The task workspace boundary is invalid: \(detail)"
        case .executionEnvironmentUnsupported:
            return "Guest or remote execution environments are not wired into this Mac runtime stage."
        case .hostGateUnavailable(let detail):
            return "The Mac tool host gate is unavailable: \(detail)"
        case .hostGateMismatch(let detail):
            return "The Mac tool host gate does not match the requested task: \(detail)"
        case .conversationBusy:
            return "This conversation already has a live Mac session."
        case .preparedIdentityMismatch(let detail):
            return "The durable launch identities did not match the admitted session: \(detail)"
        case .sessionNotFound:
            return "The requested Mac session no longer exists."
        case .sessionTornDown:
            return "The Mac session has been torn down."
        case .sessionNotFinished:
            return "The Mac session still owns a live run; stop it before closing."
        case .terminalNotConfirmed:
            return "The run did not reach a durably confirmed terminal state."
        case .activeSessions:
            return "Live Mac sessions must be stopped before shutdown."
        case .unconfirmedSessions:
            return "Some ended Mac sessions have an unconfirmed durable terminal state."
        case .shutdownIncomplete:
            return "Shutdown could not confirm every owned run reached a terminal state."
        case .approvalRejected(let reason):
            return "The approval command was rejected: \(reason.rawValue)"
        case .persistenceUnavailable(let identity):
            return "The Mac runtime could not read or write its own database (\(identity))."
        }
    }
}

/// A redacted failure projection suitable for a session event or host log.
/// `code` is stable; `message` never includes provider content, tool output,
/// credentials or goal text.
public struct FloeMacSelfFailure: Sendable, Hashable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static func from(_ error: any Error) -> FloeMacSelfFailure {
        if let selfCore = error as? FloeMacSelfCoreError {
            return FloeMacSelfFailure(
                code: selfCore.code,
                message: selfCore.errorDescription ?? selfCore.code
            )
        }
        if let floe = error as? FloeError {
            return FloeMacSelfFailure(
                code: "floe.\(floe.selfCoreCode)",
                message: "The run failed before it was admitted."
            )
        }
        let ns = error as NSError
        return FloeMacSelfFailure(
            code: "\(ns.domain)#\(ns.code)",
            message: "The run failed before it was admitted."
        )
    }
}

/// Redacted error identity for persistence diagnostics. Mirrors the runtime's
/// own policy: case/domain+code only, never associated values or user content.
enum FloeMacSelfErrorIdentity {
    static func render(_ error: any Error) -> String {
        if let selfCore = error as? FloeMacSelfCoreError {
            return selfCore.code
        }
        if let floe = error as? FloeError {
            return "floe.\(floe.selfCoreCode)"
        }
        let ns = error as NSError
        return "\(ns.domain)#\(ns.code)"
    }
}

private extension FloeError {
    var selfCoreCode: String {
        switch self {
        case .invalidConfiguration: return "invalidConfiguration"
        case .validationFailed: return "validationFailed"
        case .unauthorized: return "unauthorized"
        case .notFound: return "notFound"
        case .storageCorrupted: return "storageCorrupted"
        case .syncUnavailable: return "syncUnavailable"
        case .cancelled: return "cancelled"
        case .internalError: return "internalError"
        }
    }
}
