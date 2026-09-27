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
    /// Time allowed for the known-long silent phases: weight mapping,
    /// tokenization and the chunked prompt prefill. The pinned mlx-swift-lm
    /// revision exposes no per-window prefill callback, so prefill is a single
    /// synchronous call; cloud qualification 36326672449 measured a legitimate
    /// 4215-token batch-8 prompt at 158.3 s to first token on a macOS host
    /// (`device-constrained-batch8`), so this phase must not be governed by
    /// the decode idle deadline. Generous by design: a legitimate cold load or
    /// long prefill must not be aborted. Bounded, not extended on activity.
    var firstActivitySeconds: TimeInterval
    /// Time allowed between progress/output observations once the turn has
    /// reached a phase where progress is expected per delivered chunk
    /// (awaiting the first decoded token, decoding, generation bookkeeping).
    var idleSeconds: TimeInterval
    /// How often the supervisor wakes to evaluate the deadline.
    var pollIntervalSeconds: TimeInterval
    /// Bounded diagnostic marks for a silent prompt prefill. Each configured
    /// mark logs at most once per generation and never resets the deadline or
    /// pretends progress. An empty array disables the marks.
    var prefillDiagnosticSeconds: [TimeInterval] = [60, 120, 240]

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
        pollIntervalSeconds: 1,
        prefillDiagnosticSeconds: []
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
        var prefillDiagnosticsEmitted = 0
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

    /// Records engine progress. Counts as activity.
    ///
    /// Deadline semantics are phase-aware:
    /// * `preparing` (weight mapping, tokenization) and `prefill` (the single
    ///   silent chunked-prefill call) keep the generous first-activity budget;
    /// * a `.prefill` report whose tokens are already complete means prefill
    ///   landed and the turn is waiting for the first decoded token, so it
    ///   switches to the idle budget and is labelled `awaitingFirstToken`;
    /// * `decoding` switches to the idle budget because progress is expected
    ///   per delivered chunk.
    func noteProgress(_ progress: LocalInferenceProgress) {
        state.withLock { state in
            state.phase = Self.phaseLabel(for: progress)
            state.lastActivityAt = Date()
            switch progress.stage {
            case .preparing:
                break
            case .prefill:
                if progress.totalInputTokens > 0,
                   progress.prefilledTokens >= progress.totalInputTokens {
                    state.sawActivity = true
                }
            case .decoding:
                state.sawActivity = true
            }
            state.emittedChunks = max(state.emittedChunks, progress.emittedChunks)
            state.inputTokens = max(state.inputTokens, progress.totalInputTokens)
        }
    }

    /// Maps a progress report to the watchdog's stage label. Only the
    /// completed-prefill case is renamed; every other stage keeps its raw
    /// value so existing diagnostics stay stable.
    private static func phaseLabel(for progress: LocalInferenceProgress) -> String {
        if progress.stage == .prefill,
           progress.totalInputTokens > 0,
           progress.prefilledTokens >= progress.totalInputTokens {
            return "awaitingFirstToken"
        }
        return progress.stage.rawValue
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

    /// Returns the next bounded prefill-stall diagnostic snapshot, at most
    /// once per configured mark, or nil when the turn is not in a silent
    /// prefill or every mark was already emitted.
    ///
    /// The mark is deliberately read-only with respect to the deadline:
    /// `lastActivityAt` is untouched, so logging a breadcrumb can never keep a
    /// stalled generation alive. The pinned mlx-swift-lm revision exposes no
    /// per-window prefill callback, so these marks are the only bounded
    /// evidence between the prepared marker and prefill completion.
    func nextPrefillDiagnostic(now: Date = Date()) -> Snapshot? {
        state.withLock { state in
            guard state.phase == LocalInferenceProgress.Stage.prefill.rawValue else { return nil }
            let marks = policy.prefillDiagnosticSeconds
            guard state.prefillDiagnosticsEmitted < marks.count else { return nil }
            let mark = marks[state.prefillDiagnosticsEmitted]
            let elapsed = now.timeIntervalSince(state.lastActivityAt)
            guard mark > 0, elapsed >= mark else { return nil }
            state.prefillDiagnosticsEmitted += 1
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
