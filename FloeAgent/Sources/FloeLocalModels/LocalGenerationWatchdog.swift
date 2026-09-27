import Foundation
import Synchronization

/// Bounded no-progress supervision policy for one on-device generation.
///
/// Build 230 on-device feedback reported an indefinite wait with no reply and
/// no terminal state: the adapter used to await the whole buffered generation
/// (plus a possible missing-tool repair) before emitting anything, and
/// `AgentRuntime` deliberately disables its cloud watchdog for local
/// providers. These limits bound that wait with an explicit terminal error
/// while never releasing a model container that is still running GPU work:
/// expiry only cancels the Swift task, and cancellation is cooperative
/// (mlx-swift-lm checks `Task.checkCancellation()` between prefill windows
/// and between decode events), after which the engine's own teardown drains
/// the GPU stream before anything is freed.
struct LocalGenerationWatchdogPolicy: Sendable, Equatable {
    /// Time allowed before the first progress/output observation, covering
    /// weight mapping, tokenization and the silent chunked prefill on a cold
    /// iPad. Generous by design: a legitimate cold load must not be aborted.
    var firstActivitySeconds: TimeInterval
    /// Time allowed between progress/output observations once the turn has
    /// produced any observable activity.
    var idleSeconds: TimeInterval
    /// How often the supervisor wakes to evaluate the deadline.
    var pollIntervalSeconds: TimeInterval

    static let production = LocalGenerationWatchdogPolicy(
        firstActivitySeconds: 300,
        idleSeconds: 180,
        pollIntervalSeconds: 1
    )

    /// A policy that never expires; used by focused tests that must not
    /// interfere with their scripted engine.
    static let disabled = LocalGenerationWatchdogPolicy(
        firstActivitySeconds: 0,
        idleSeconds: 0,
        pollIntervalSeconds: 1
    )
}

/// Thread-safe progress ledger shared by the generation call and its
/// supervisor. Records only bounded numeric/categorical values: phase names,
/// elapsed seconds, upstream chunk counts and token counts.
final class LocalGenerationWatchdogState: @unchecked Sendable {
    struct Snapshot: Sendable, Equatable {
        var phase: String
        var elapsedSeconds: TimeInterval
        var emittedChunks: Int
        var inputTokens: Int
        var sawActivity: Bool
    }

    private struct State {
        var phase: String = "starting"
        var lastActivityAt: Date
        var emittedChunks = 0
        var inputTokens = 0
        var sawActivity = false
        var timedOut = false
    }

    let policy: LocalGenerationWatchdogPolicy
    private let state: Mutex<State>

    init(policy: LocalGenerationWatchdogPolicy, now: Date = Date()) {
        self.policy = policy
        state = Mutex(State(lastActivityAt: now))
    }

    /// Records a stage transition (for example `generationFinished` or
    /// `toolInvocationRepair`). Counts as activity.
    func notePhase(_ phase: String) {
        state.withLock { state in
            state.phase = phase
            state.lastActivityAt = Date()
        }
    }

    /// Records engine progress. Counts as activity. A bare `preparing` stage
    /// (weight mapping, tokenization) extends the generous first-activity
    /// window instead of switching to the shorter idle window: a cold
    /// multi-gigabyte load must not be aborted by a decode-stall deadline.
    func noteProgress(_ progress: LocalInferenceProgress) {
        state.withLock { state in
            state.phase = progress.stage.rawValue
            state.lastActivityAt = Date()
            if progress.stage != .preparing {
                state.sawActivity = true
            }
            state.emittedChunks = max(state.emittedChunks, progress.emittedChunks)
            state.inputTokens = max(state.inputTokens, progress.totalInputTokens)
        }
    }

    /// Records a delivered output chunk. Counts as activity.
    func noteOutput() {
        state.withLock { state in
            state.lastActivityAt = Date()
            state.sawActivity = true
        }
    }

    /// Marks the timeout. Returns false when another party already marked it,
    /// so only one terminal error is published.
    func markTimedOut() -> Bool {
        state.withLock { state in
            guard !state.timedOut else { return false }
            state.timedOut = true
            return true
        }
    }

    var timedOut: Bool {
        state.withLock { $0.timedOut }
    }

    /// Returns the observed state when the applicable deadline has passed.
    func expiredSnapshot(now: Date = Date()) -> Snapshot? {
        state.withLock { state in
            let elapsed = now.timeIntervalSince(state.lastActivityAt)
            let deadline = state.sawActivity ? policy.idleSeconds : policy.firstActivitySeconds
            guard deadline > 0, elapsed >= deadline else { return nil }
            return Snapshot(
                phase: state.phase,
                elapsedSeconds: elapsed,
                emittedChunks: state.emittedChunks,
                inputTokens: state.inputTokens,
                sawActivity: state.sawActivity
            )
        }
    }
}
