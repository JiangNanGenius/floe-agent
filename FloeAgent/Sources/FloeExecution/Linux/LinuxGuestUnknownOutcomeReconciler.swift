// FloeExecution — typed reconciliation for interrupted Linux lifecycle
// dispatches.
//
// When a startLinux dispatch was interrupted (app relaunch after dispatch,
// before its result committed), the runtime keeps an unknown-outcome receipt
// that suppresses the identical route. This reconciler is the narrow,
// evidence-based bridge: it dissolves the suppression ONLY for the
// start-class lifecycle route, ONLY when authoritative read-only state proves
// the environment is quietly stopped (no registered instance, engine not
// running, not quarantined) and the saved startup shape matches the retried
// request exactly. It never starts, stops or mutates anything itself; a
// reconciled retry simply runs the normal dispatch path with all of its own
// guards (approval, CPU/lease budgets, image qualification, idempotency).
//
// Arbitrary commands and unknown paid submissions are never handled here and
// stay inhibited. Hard/soft restarts are deliberately excluded: they are
// disruptive lifecycle actions, not idempotent starts.
//
// Module note: FloeExecution does not depend on FloeAgentRuntime, so this
// type is shaped 1:1 with the runtime's UnknownOutcomeReconciler seam and is
// bound to it by the app/workbench wiring layer (see the design-workflow
// repair lane's integration handoff).

import Foundation
import FloeCore
import FloeModels
import FloeTools

public enum LinuxGuestUnknownOutcomeDecision: Sendable, Equatable {
    /// Evidence is insufficient or the retry is not the matching start-class
    /// lifecycle action: keep the suppression.
    case stillSuppressed
    /// Authoritative evidence proves the earlier attempt settled quietly and
    /// the retried request matches the saved shape. Audit-facing text.
    case allowed(explanation: String)
}

/// Environment-scoped, read-only reconciler for one environment's
/// interrupted startLinux dispatch.
public struct LinuxUnknownOutcomeReconciler: Sendable {
    /// The only lifecycle route eligible for evidence-based reconciliation.
    public static let startToolName = "environment.startLinux"

    public let environmentID: String
    /// Produces the authoritative quiet-stop facts. Injected as a closure so
    /// tests can substitute fakes without a guest engine.
    private let probe: @Sendable (String) async -> LinuxGuestStoppedReconciliation

    public init(
        environmentID: String,
        lifecycle manager: LinuxGuestLifecycleManager
    ) {
        self.environmentID = environmentID
        self.probe = { environmentID in
            await manager.reconciliationSnapshot(environmentID: environmentID)
        }
    }

    /// Test seam: inject the probe directly.
    public init(
        environmentID: String,
        probe: @escaping @Sendable (String) async -> LinuxGuestStoppedReconciliation
    ) {
        self.environmentID = environmentID
        self.probe = probe
    }

    /// Decides whether a retry of a route with an unknown-outcome receipt may
    /// run. `reason` is informational; the authoritative facts gate the
    /// decision, never the model's claims.
    public func reconcile(
        reason: String,
        retryToolName: String,
        retryArgumentsJSON: Data
    ) async -> LinuxGuestUnknownOutcomeDecision {
        // Narrowly typed: only the start-class lifecycle route. Everything
        // else (arbitrary shell commands, unknown paid submits, restarts)
        // stays inhibited.
        guard retryToolName == Self.startToolName else { return .stillSuppressed }
        guard let arguments = try? JSONDecoder().decode(
            LinuxGuestShapeArguments.self,
            from: retryArgumentsJSON
        ) else { return .stillSuppressed }

        let facts = await probe(environmentID)
        // The earlier attempt's effect must be provably settled: quietly
        // stopped, no registered instance, engine not running, not
        // quarantined. Anything else keeps the unknown-outcome guard.
        guard facts.isQuietlyStopped else { return .stillSuppressed }

        // Target match: an explicit request dimension must equal the saved
        // startup shape exactly; an omitted dimension preserves the saved
        // shape by definition. A mismatch means this retry would boot a
        // different shape than the recorded route and must not be auto-run.
        if let requestedVCPUs = arguments.vcpus,
           facts.savedConfig?.vcpus != requestedVCPUs {
            return .stillSuppressed
        }
        if let requestedMemoryMB = arguments.memoryMB,
           facts.savedConfig?.memoryMB != requestedMemoryMB {
            return .stillSuppressed
        }

        let savedShape: String
        if let saved = facts.savedConfig,
           let vcpus = saved.vcpus, let memoryMB = saved.memoryMB {
            savedShape = "saved configuration \(vcpus) vCPU / \(memoryMB) MiB"
        } else {
            savedShape = "no saved configuration (the retry boots the default shape)"
        }
        return .allowed(explanation:
            "authoritative lifecycle state for environment \(environmentID) is quietly stopped " +
            "(no registered instance, engine not running, not quarantined) with \(savedShape), " +
            "matching the retried startLinux request; the interrupted dispatch's effect is settled " +
            "and the retry runs through the normal guarded dispatch path (interrupted-dispatch reason: \(reason))"
        )
    }
}
