// FloeCore — Completion dwell and generation-safe teardown policy for the
// optional status Picture-in-Picture surface.
//
// Requirements encoded here:
//  * A successful task transitions to a Completed state *before* teardown and
//    keeps the success visible for a short dwell (3s), so the user sees the
//    outcome instead of the surface vanishing mid-completion.
//  * Failures and checkpoints remain actionable: the surface is retained for
//    recovery, never auto-torn-down on a failure timer.
//  * Delayed teardown is bound to a run-generation identity. A newer task
//    bumps the generation, so a stale timer from an old run cannot close the
//    surface that now belongs to the new run.

import Foundation

public struct CompletionDwellPlan: Sendable, Equatable {
    public enum Disposition: String, Sendable, Equatable {
        /// Show the Completed state, then tear the surface down after `delay`.
        case dwellThenTearDown
        /// Keep the surface visible because the work is unfinished and
        /// resumable (failure/checkpoint).
        case retainForRecovery
        /// Tear down at once (nothing to retain).
        case tearDownImmediately
    }

    public let disposition: Disposition
    public let delay: TimeInterval
    public let generation: UInt64

    public init(disposition: Disposition, delay: TimeInterval = 0, generation: UInt64) {
        self.disposition = disposition
        self.generation = generation
        self.delay = delay
    }
}

public enum BackgroundSurfaceCompletionPolicy {
    /// Success is held on screen for 3 seconds before the surface tears down.
    public static let successDwell: TimeInterval = 3

    /// Pure decision for a finishing run.
    /// - Parameters:
    ///   - succeeded: terminal success vs failure.
    ///   - retainsSurfaceOnFailure: whether this run family keeps the surface
    ///     for recovery after failure/checkpoint (model runs do; one-shot
    ///     media jobs do not).
    ///   - generation: the current run-generation identity captured by the
    ///     caller so the delayed teardown can be validated later.
    public static func plan(
        succeeded: Bool,
        retainsSurfaceOnFailure: Bool,
        generation: UInt64
    ) -> CompletionDwellPlan {
        if succeeded {
            return CompletionDwellPlan(
                disposition: .dwellThenTearDown,
                delay: successDwell,
                generation: generation
            )
        }
        if retainsSurfaceOnFailure {
            return CompletionDwellPlan(disposition: .retainForRecovery, generation: generation)
        }
        return CompletionDwellPlan(disposition: .tearDownImmediately, generation: generation)
    }

    /// A delayed teardown is valid only while no newer run has taken over the
    /// surface. `setRunContext` for a newer run bumps the generation, which
    /// invalidates the captured schedule.
    public static func teardownIsCurrent(
        scheduledGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        scheduledGeneration == currentGeneration
    }
}
