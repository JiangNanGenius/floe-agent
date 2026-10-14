// FloeAgentRuntime — typed bridge from authoritative lifecycle evidence to
// unknown-outcome suppression.
//
// A dispatch whose real-world outcome is unknown (app interrupted mid-flight,
// or the capability was removed/replaced while executing) is never replayed
// automatically: HarnessExecutionLedger keeps a durable unknown-outcome
// receipt that suppresses the same route. The suppression reason is recorded
// honestly — an app-restart interruption is NOT described as "capability
// removed" — and only narrowly-defined lifecycle actions may dissolve a
// receipt, through this typed seam, when authoritative read-only evidence
// proves the earlier attempt settled and the retry matches it exactly.
//
// Safety invariants:
//  * Arbitrary commands and unknown paid submits stay inhibited: the seam is
//    consulted only for receipts the reconciler explicitly recognizes, and a
//    reconciler must return `.reconciled` only with authoritative evidence.
//  * A dissolved receipt is removed from the ledger; the retry then runs the
//    normal dispatch path with all of its own guards (approval, budgets,
//    idempotency, capability checks).
//  * The overflow sentinel (bounded ledger full of unknown receipts) is never
//    reconciled here: external inspection is mandatory.

import Foundation
import FloeModels
import FloeTools

/// Why a dispatch's real-world outcome is unknown.
public enum UnknownOutcomeReason: String, Sendable, Codable, Equatable {
    /// The app/process was interrupted (force-quit, suspension) after
    /// dispatch but before the result committed. NOT a capability change.
    case interruptedDispatch
    /// The capability was removed or replaced while the call was executing.
    case capabilityRemoved
    /// Checkpoint written before reasons were attributed; kept strict.
    case unattributed
}

/// The durable identity of one unknown-outcome receipt, handed to a
/// reconciler. Carries no command bodies or sensitive arguments — only the
/// tool route and the persisted reason category.
public struct UnknownOutcomeReceipt: Sendable, Equatable {
    public var toolName: String
    public var callFingerprint: String
    public var reason: UnknownOutcomeReason

    public init(toolName: String, callFingerprint: String, reason: UnknownOutcomeReason) {
        self.toolName = toolName
        self.callFingerprint = callFingerprint
        self.reason = reason
    }
}

/// Result of one reconciliation attempt.
public enum UnknownOutcomeReconciliation: Sendable, Equatable {
    /// Evidence is insufficient or the retry is not a recognized lifecycle
    /// action: the receipt stays and the route remains suppressed.
    case suppressed
    /// Authoritative evidence proves the earlier attempt's effect settled and
    /// the retry is the matching lifecycle action: dissolve this receipt and
    /// let the normal dispatch path run. `explanation` is audit-facing text.
    case reconciled(explanation: String)
}

/// Narrowly-typed hook between authoritative environment state and the
/// runtime's unknown-outcome suppression. Implementations must be read-only,
/// must use authoritative state (exact environment/request identity,
/// launch generation, lease/ownership, verified instance exit), and must
/// return `.reconciled` only when the retry is provably the same safe
/// lifecycle action.
public protocol UnknownOutcomeReconciler: Sendable {
    func reconcileUnknownOutcome(
        receipt: UnknownOutcomeReceipt,
        retryCall: ToolCall
    ) async -> UnknownOutcomeReconciliation
}
