// FloeApp — bridges the runtime's typed unknown-outcome seam to the Linux
// guest's environment-scoped, evidence-gated reconciler.
//
// One instance serves one run; the environment ID is the run's bound
// environment (the same identity the execution layer binds into
// ToolContext through ToolEnvironmentRouting), never anything inferred from
// model text or tool arguments. Runs without a Linux-bound environment get
// no reconciler at all: every unknown-outcome receipt stays strictly
// suppressed until human inspection, exactly the baseline behavior.

import Foundation
import FloeAgentRuntime
import FloeExecution
import FloeModels
import FloeTools

struct LinuxUnknownOutcomeReconcilerBridge: UnknownOutcomeReconciler {
    let reconciler: LinuxUnknownOutcomeReconciler

    func reconcileUnknownOutcome(
        receipt: UnknownOutcomeReceipt,
        retryCall: ToolCall
    ) async -> UnknownOutcomeReconciliation {
        // The ledger already gates: only receipts it recognizes reach a
        // reconciler. Pass the persisted reason through for the audit text;
        // the guest-side decision is made purely from authoritative
        // lifecycle facts (quiet-stop evidence, saved shape, launch
        // generation, probe epoch consistency).
        switch await reconciler.reconcile(
            reason: receipt.reason.rawValue,
            retryToolName: retryCall.toolName,
            retryArgumentsJSON: retryCall.argumentsJSON
        ) {
        case .stillSuppressed:
            return .suppressed
        case .allowed(let explanation):
            return .reconciled(explanation: explanation)
        }
    }
}
