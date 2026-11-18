// SPDX-License-Identifier: MPL-2.0
//
// Immutable identities, lifecycle phases and durable receipts. A receipt is
// only "confirmed" when the durable run row and its terminal event were read
// back from the host-owned database after the runtime returned; event-stream
// delivery is never treated as completion.

import Foundation
import FloeAgentRuntime

/// Provenance of the process that owns durable Mac executions. The process
/// identifier is checked by `FloeMacSelfRuntime` at construction, so the
/// forced-terminated UI child cannot silently create a new durable owner.
/// This is an in-process guard, not OS code signing or authentication.
public struct FloeMacSelfHostIdentity: Sendable, Hashable {
    public let hostInstanceID: UUID
    public let processIdentifier: Int32
    public let displayName: String

    public init(
        hostInstanceID: UUID = UUID(),
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        displayName: String
    ) {
        self.hostInstanceID = hostInstanceID
        self.processIdentifier = processIdentifier
        self.displayName = displayName
    }
}

/// Exact identities carried from `SQLiteRunLaunchStore.prepare` through
/// `ConversationRunService.startPrepared(goal:userMessageID:)`. The goal text
/// is deliberately not repeated here.
public struct FloeMacSelfSessionIdentity: Sendable, Hashable {
    public let owner: FloeMacSelfHostIdentity
    public let conversationID: UUID
    public let workspaceID: UUID
    public let runID: UUID
    public let userMessageID: UUID
    public let conversationMode: ConversationMode
    public let toolsEnabled: Bool
    /// Exact durable admission attempt this session owns. A stale epoch must
    /// never authorize a tool side effect or a second automatic run.
    public let admissionEpoch: UInt64
    public let startedAt: Date

    public init(
        owner: FloeMacSelfHostIdentity,
        conversationID: UUID,
        workspaceID: UUID,
        runID: UUID,
        userMessageID: UUID,
        conversationMode: ConversationMode,
        toolsEnabled: Bool,
        admissionEpoch: UInt64,
        startedAt: Date
    ) {
        self.owner = owner
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        self.runID = runID
        self.userMessageID = userMessageID
        self.conversationMode = conversationMode
        self.toolsEnabled = toolsEnabled
        self.admissionEpoch = admissionEpoch
        self.startedAt = startedAt
    }
}

/// Host-visible lifecycle of one Mac session object. It describes what this
/// composition layer actually knows; it is not an OS liveness guarantee.
public enum FloeMacSelfSessionPhase: String, Sendable, Hashable, CaseIterable {
    /// Durable launch committed and the run task was spawned.
    case launched
    /// The supervisor entered the existing runtime start path.
    case running
    /// A host cancel was requested; the runtime owns the terminal transition.
    case cancelling
    /// The run task returned; inspect the terminal receipt for confirmation.
    case ended
    /// Starting failed before or around the runtime start call.
    case startFailed
    /// The host closed this session object.
    case tornDown

    public var isActive: Bool {
        switch self {
        case .launched, .running, .cancelling: return true
        case .ended, .startFailed, .tornDown: return false
        }
    }

    public var isFinished: Bool {
        switch self {
        case .ended, .startFailed, .tornDown: return true
        case .launched, .running, .cancelling: return false
        }
    }
}

/// Bounded read-only view of a session for host process inspection.
public struct FloeMacSelfSessionSummary: Sendable, Hashable {
    public let identity: FloeMacSelfSessionIdentity
    public let phase: FloeMacSelfSessionPhase
    public let stateName: String
    public let isWaitingForApproval: Bool
    public let isTerminal: Bool
    public let lastFailure: FloeMacSelfFailure?

    public init(
        identity: FloeMacSelfSessionIdentity,
        phase: FloeMacSelfSessionPhase,
        stateName: String,
        isWaitingForApproval: Bool,
        isTerminal: Bool,
        lastFailure: FloeMacSelfFailure?
    ) {
        self.identity = identity
        self.phase = phase
        self.stateName = stateName
        self.isWaitingForApproval = isWaitingForApproval
        self.isTerminal = isTerminal
        self.lastFailure = lastFailure
    }
}

/// Result of the explicit, one-time database migration step.
public struct FloeMacSelfBootstrapReceipt: Sendable, Hashable {
    public let schemaVersion: Int
    public let appliedMigrationCount: Int
    public let bootstrappedAt: Date

    public init(schemaVersion: Int, appliedMigrationCount: Int, bootstrappedAt: Date) {
        self.schemaVersion = schemaVersion
        self.appliedMigrationCount = appliedMigrationCount
        self.bootstrappedAt = bootstrappedAt
    }
}

/// Durable terminal classification. `completed` means a normal provider stop
/// with a verified final message, not proof that the user's goal succeeded.
public enum FloeMacSelfTerminalOutcome: String, Sendable, Hashable, CaseIterable {
    case completed
    case failed
    case interrupted
    case cancelled
    case blocked
    case paused
    /// The composition proved the prepared run never dispatched and recorded
    /// its own durable `abortedBeforeDispatch` failed status. This is not a
    /// runtime terminal event and is never used after dispatch may have begun.
    case abortedBeforeDispatch
    case unknown
}

/// The provider's durable stop reason. Limited or tool-use endings do not
/// prove that a user request succeeded, even if they contain a final message.
public enum FloeMacSelfCompletionStopReason: String, Sendable, Hashable, CaseIterable {
    case endTurn, toolUse, maxTokens, stopSequence, cancelled, budgetLimited, noProgress
}

/// Read-back proof for one run. `confirmed` proves a matching terminal
/// boundary was found, not that the user goal or an external effect succeeded.
public struct FloeMacSelfTerminalReceipt: Sendable, Hashable {
    public let runID: UUID
    public let conversationID: UUID
    public let outcome: FloeMacSelfTerminalOutcome
    public let durableRunState: String
    public let durableEndedAt: Date?
    public let terminalEventSequence: Int?
    public let confirmed: Bool
    /// Stable reason code when `confirmed` is false. Never carries content.
    public let unconfirmedReason: String?
    /// Exact final assistant message proved by the terminal payload, when the
    /// runtime emitted one. An explicit no-final-text marker can confirm an
    /// ended run but does not confirm a successful answer.
    public let finalMessageID: UUID?
    /// True only when the final assistant row was read back with the exact
    /// run/conversation/assistant identity and non-empty content.
    public let finalMessageVerified: Bool
    /// Verified completed-run stop reason, when present. A limited result is
    /// kept separately from both the terminal fact and the outcome label.
    public let completionStopReason: FloeMacSelfCompletionStopReason?

    public init(
        runID: UUID,
        conversationID: UUID,
        outcome: FloeMacSelfTerminalOutcome,
        durableRunState: String,
        durableEndedAt: Date?,
        terminalEventSequence: Int?,
        confirmed: Bool,
        unconfirmedReason: String?,
        finalMessageID: UUID?,
        finalMessageVerified: Bool,
        completionStopReason: FloeMacSelfCompletionStopReason? = nil
    ) {
        self.runID = runID
        self.conversationID = conversationID
        self.outcome = outcome
        self.durableRunState = durableRunState
        self.durableEndedAt = durableEndedAt
        self.terminalEventSequence = terminalEventSequence
        self.confirmed = confirmed
        self.unconfirmedReason = unconfirmedReason
        self.finalMessageID = finalMessageID
        self.finalMessageVerified = finalMessageVerified
        self.completionStopReason = completionStopReason
    }
}

public enum FloeMacSelfCancelStatus: String, Sendable, Hashable {
    /// The run was already terminal before the cancel request.
    case alreadyTerminal
    /// Cancel was requested and a confirmed terminal receipt was read back.
    case stopped
    /// The runtime had not left idle when the cancel fence expired. Dispatch
    /// had not begun according to the process fence.
    case runtimeNotStarted
    /// Dispatch may have begun, but no confirmed terminal was read back
    /// within the timeout. The durable admission is retained as unknown.
    case dispatchUnknown
    /// Cancel was requested, but the terminal receipt was not confirmed in time.
    case terminalUnconfirmed
}

public struct FloeMacSelfCancelReceipt: Sendable, Hashable {
    public let runID: UUID
    public let requestedAt: Date
    public let status: FloeMacSelfCancelStatus
    public let terminal: FloeMacSelfTerminalReceipt?

    public init(
        runID: UUID,
        requestedAt: Date,
        status: FloeMacSelfCancelStatus,
        terminal: FloeMacSelfTerminalReceipt?
    ) {
        self.runID = runID
        self.requestedAt = requestedAt
        self.status = status
        self.terminal = terminal
    }
}

public struct FloeMacSelfCloseReceipt: Sendable, Hashable {
    public let runID: UUID
    public let conversationID: UUID
    public let terminalConfirmed: Bool
    public let durableRunState: String?
    /// True when the session object was released but the durable run was
    /// deliberately preserved without a confirmed terminal state.
    public let preservedUnconfirmedRun: Bool
    /// True when the durable admission row was retained (unknown) because the
    /// terminal receipt was not confirmed. Process resources may be released;
    /// an automatic rerun is not authorized.
    public let durableAdmissionRetained: Bool

    public init(
        runID: UUID,
        conversationID: UUID,
        terminalConfirmed: Bool,
        durableRunState: String?,
        preservedUnconfirmedRun: Bool,
        durableAdmissionRetained: Bool
    ) {
        self.runID = runID
        self.conversationID = conversationID
        self.terminalConfirmed = terminalConfirmed
        self.durableRunState = durableRunState
        self.preservedUnconfirmedRun = preservedUnconfirmedRun
        self.durableAdmissionRetained = durableAdmissionRetained
    }
}

public struct FloeMacSelfShutdownReceipt: Sendable, Hashable {
    public let closedSessionCount: Int
    public let preservedRunIDs: [UUID]
    public let databaseClosed: Bool
    public let alreadyClosed: Bool
    /// Unresolved durable admission rows observed before the database closed.
    /// They are retained, never cleared by shutdown.
    public let retainedAdmissionConversationIDs: [UUID]
    /// False when the admission inventory itself could not be read. The
    /// database may still have closed; the host must treat the inventory as
    /// unknown and retain the database location as evidence.
    public let admissionInventoryAvailable: Bool

    public init(
        closedSessionCount: Int,
        preservedRunIDs: [UUID],
        databaseClosed: Bool,
        alreadyClosed: Bool,
        retainedAdmissionConversationIDs: [UUID],
        admissionInventoryAvailable: Bool
    ) {
        self.closedSessionCount = closedSessionCount
        self.preservedRunIDs = preservedRunIDs
        self.databaseClosed = databaseClosed
        self.alreadyClosed = alreadyClosed
        self.retainedAdmissionConversationIDs = retainedAdmissionConversationIDs
        self.admissionInventoryAvailable = admissionInventoryAvailable
    }
}
