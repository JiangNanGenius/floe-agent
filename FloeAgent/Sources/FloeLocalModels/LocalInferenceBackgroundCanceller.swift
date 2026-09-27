import Foundation
import Synchronization
#if canImport(UIKit)
import UIKit
#endif

/// A local generation that could not start, or was stopped, because iOS only
/// permits GPU submission while the app is active.
///
/// This is deliberately **not** `CancellationError`. The harness treats a
/// thrown `CancellationError` as "the caller owns the terminal transition" and
/// ignores it, which is correct only for a user stop. A lifecycle deferral has
/// no caller-owned transition: the run must instead surface a bounded,
/// retryable event so it either continues when the app returns to the
/// foreground or ends recoverably with its checkpoint. The Build 231 device
/// log showed exactly the failure this type closes: a foreground-recovery
/// resume was refused at `stage=prepare` 93 ms after the scene reported
/// inactive, and the run ended silently in `streamingModel` with no reply.
public struct LocalInferenceDeferredError: LocalizedError, Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable {
        /// Admission before any model work: the app was not active.
        case admission = "prepare"
        /// The GPU task was about to launch and the app was not active.
        case generation = "generation"
    }

    public let stage: Stage
    /// Bounded elapsed seconds at the moment of refusal/cancellation. This is
    /// diagnostic metadata only; it is never part of an admission rule.
    public let elapsedSeconds: TimeInterval

    public init(stage: Stage, elapsedSeconds: TimeInterval) {
        self.stage = stage
        self.elapsedSeconds = elapsedSeconds
    }

    public var errorDescription: String? {
        let seconds = String(format: "%.1f", max(0, elapsedSeconds))
        return "The on-device model can only generate while the app is in the foreground (stage: \(stage.rawValue), waited \(seconds)s)."
    }
}

/// Admission and cancellation for on-device MLX generation across app
/// lifecycle transitions.
///
/// mlx-swift-lm checks `Task.checkCancellation()` between prompt-prefill
/// windows (PR #423, merged 2026-07-14, present in the accepted pins). Its
/// description states the iOS failure this type addresses: GPU work submitted
/// while the app is not active is rejected by the system ("Insufficient
/// Permission (to submit GPU work in background)"), the resulting Metal
/// command-buffer failure is thrown from a completion handler where the
/// task-local `MLX.withError` handler cannot see it, and the process aborts.
/// The upstream check only helps when something actually cancels the
/// surrounding task.
///
/// The chat harness deliberately keeps agent runs alive through a short
/// background lease (see `BackgroundRunCoordinator`), which is correct for
/// remote providers but cannot extend GPU submission rights to on-device
/// inference. This registry therefore owns two responsibilities for local MLX
/// generation only:
///
/// 1. **Admission**: `registerForeground` refuses to hand out a token while
///    the app is not active. `LocalModelRuntime.completeMeasured` calls it
///    *before* creating the task that submits GPU work, so a background agent
///    continuation cannot start a local generation whose lifecycle
///    notification was already delivered, or was never observed because no
///    local generation had installed the observers yet.
/// 2. **Cancellation**: the iOS observers for `willResignActive` and
///    `didEnterBackground` cancel every registered generation, so the prefill
///    loop stops submitting chunks within one `prefillStepSize` window;
///    `didBecomeActive` clears the suspended state.
///
/// Registration order matters. The runtime registers first, creates the
/// generation task second and attaches that task's cancel forwarder third
/// through `LocalInferenceCancellationRelay`; a transition that lands in the
/// register→launch window is remembered by the relay and cancels the task
/// before its first GPU submission.
///
/// Remote providers and foreground generation are unaffected. The registry is
/// UIKit-free on non-iOS platforms: observers only exist under
/// `canImport(UIKit)`, while the admission, transition and relay logic stays
/// executable in the macOS host fixture.
final class LocalInferenceBackgroundCanceller: Sendable {
    static let shared = LocalInferenceBackgroundCanceller()

    private struct Entry: Sendable {
        let traceID: String
        let cancel: @Sendable () -> Void
    }

    private struct State {
        var entries: [UUID: Entry] = [:]
        /// Bumped by every lifecycle transition. Registration snapshots this
        /// value before awaiting the foreground probe and compares it again
        /// inside the registration lock, so a transition that lands during the
        /// await cannot be overwritten by the (already stale) probe result.
        var lifecycleEpoch: UInt64 = 0
        var isSuspended = false
        var foregroundProbe: @Sendable () async -> Bool
        #if canImport(UIKit)
        var observers: [any NSObjectProtocol] = []
        #endif
    }

    private let state: Mutex<State>

    init() {
        state = Mutex(State(foregroundProbe: Self.defaultForegroundProbe))
    }

    /// Number of generations currently eligible for background cancellation.
    var activeCount: Int {
        state.withLock { $0.entries.count }
    }

    /// Advisory foreground probe for callers that want to refuse local work
    /// before even mapping model weights. `registerForeground` performs the
    /// authoritative, race-checked decision; this only avoids wasted work.
    func isForegroundEligible() async -> Bool {
        let probe = state.withLock { $0.foregroundProbe }
        return await probe()
    }

    /// Registers one in-flight generation, but only while the app can submit
    /// GPU work. Returns `nil` when the app is not active; the caller must then
    /// not create or launch the GPU task. The returned token must be passed to
    /// `unregister` when the call finishes.
    ///
    /// Callers must register *before* creating the task that calls into MLX and
    /// attach that task's cancel closure to a
    /// `LocalInferenceCancellationRelay` afterwards, so a transition in the
    /// register→launch window is not lost.
    func registerForeground(
        traceID: String,
        cancel: @escaping @Sendable () -> Void
    ) async -> UUID? {
        // Observe first: a resign-active that starts while the probe is
        // awaiting bumps the epoch before the decision below is taken.
        let (epoch, probe): (UInt64, @Sendable () async -> Bool) = state.withLock { state in
            installObserversIfNeeded(&state)
            return (state.lifecycleEpoch, state.foregroundProbe)
        }
        let isForeground = await probe()
        let token = UUID()
        let registered = state.withLock { state -> Bool in
            let transitionedDuringProbe = state.lifecycleEpoch != epoch
            if transitionedDuringProbe && state.isSuspended {
                return false
            }
            guard isForeground else {
                // The probe positively observed an inactive app. Record the
                // suspension so concurrent registrations with a stale epoch
                // also refuse, and let the next foreground probe clear it.
                state.isSuspended = true
                state.lifecycleEpoch &+= 1
                return false
            }
            state.isSuspended = false
            state.entries[token] = Entry(traceID: traceID, cancel: cancel)
            return true
        }
        return registered ? token : nil
    }

    func unregister(_ token: UUID) {
        state.withLock { state in
            _ = state.entries.removeValue(forKey: token)
        }
    }

    /// Bounded, cancellable wait until the foreground probe reports an active
    /// app. Returns immediately when the app is already eligible.
    ///
    /// This is an **admission wait**, not a generation deadline: it never
    /// extends a running generation, never resets a watchdog deadline and
    /// never fabricates GPU permission. It exists because iOS can deliver a
    /// foreground-recovery resume while the scene is still transitioning back
    /// to `.active` (Build 231 device evidence: report inactive -> active
    /// within 5.4 s), and refusing at that instant abandoned a legitimate run.
    /// The wait is abandoned as soon as the caller's task is cancelled.
    func waitForForegroundEligibility(
        upTo timeout: TimeInterval,
        pollInterval: TimeInterval = 0.25
    ) async -> Bool {
        if await isForegroundEligible() { return true }
        guard timeout > 0 else { return false }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        let interval = Duration.seconds(max(0.01, pollInterval))
        while clock.now < deadline {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return false
            }
            if Task.isCancelled { return false }
            if await isForegroundEligible() { return true }
        }
        return await isForegroundEligible()
    }

    /// Registration variant for callers that arrive during a scene
    /// transition. Spends at most `graceSeconds` waiting for the foreground
    /// probe, then performs the authoritative race-checked
    /// `registerForeground`. Returns `nil` only when the whole bounded grace
    /// expired without an active app (or a lifecycle transition kept winning
    /// the probe), which the caller reports as a retryable deferral rather
    /// than a silent stop.
    func registerForegroundWhenEligible(
        traceID: String,
        graceSeconds: TimeInterval,
        pollIntervalSeconds: TimeInterval = 0.25,
        cancel: @escaping @Sendable () -> Void
    ) async -> UUID? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(max(0, graceSeconds)))
        while true {
            if await isForegroundEligible(),
               let token = await registerForeground(traceID: traceID, cancel: cancel) {
                return token
            }
            guard !Task.isCancelled, clock.now < deadline else { return nil }
            do {
                try await Task.sleep(for: .seconds(max(0.01, pollIntervalSeconds)))
            } catch {
                return nil
            }
        }
    }

    /// Cancels every registered generation and empties the registry. Available
    /// for callers that need an unconditional stop and used by the host
    /// fixture; the UIKit observers go through `applyLifecycleTransition` so
    /// the suspended state stays accurate.
    @discardableResult
    func cancelAll(reason: String) -> [String] {
        let entries = takeAllEntries()
        cancel(entries)
        return entries.map(\.traceID)
    }

    /// Applies the same transition the UIKit observers apply. Kept
    /// platform-independent so the macOS host fixture exercises the real
    /// production path rather than a copy. Returns the cancelled trace IDs.
    @discardableResult
    func applyLifecycleTransition(isBackground: Bool) -> [String] {
        let entries = state.withLock { state -> [Entry] in
            state.lifecycleEpoch &+= 1
            state.isSuspended = isBackground
            guard isBackground else { return [] }
            let values = Array(state.entries.values)
            state.entries.removeAll()
            return values
        }
        cancel(entries)
        return entries.map(\.traceID)
    }

    private func takeAllEntries() -> [Entry] {
        state.withLock { state -> [Entry] in
            let values = Array(state.entries.values)
            state.entries.removeAll()
            return values
        }
    }

    private func cancel(_ entries: [Entry]) {
        // Cancel outside the lock: a cancel closure may unregister or take the
        // lock again while unwinding.
        for entry in entries {
            entry.cancel()
        }
    }

    #if canImport(UIKit)
    private func installObserversIfNeeded(_ state: inout State) {
        // Observers stay installed for the process lifetime. Removing them
        // when the registry goes idle would create exactly the blind window
        // this type exists to close: the `didBecomeActive` that clears
        // `isSuspended` would be missed and a later registration would have to
        // re-learn the state from the application object.
        guard state.observers.isEmpty else { return }
        let center = NotificationCenter.default
        let backgroundNames: [Notification.Name] = [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
        ]
        state.observers = backgroundNames.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.applyLifecycleTransition(isBackground: true)
            }
        }
        state.observers.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.applyLifecycleTransition(isBackground: false)
            }
        )
    }

    /// The production foreground probe. `MainActor.run` is a non-blocking
    /// hop: the main thread may be inside the very lifecycle callback this
    /// registry reacts to, so a synchronous `DispatchQueue.main.sync` here
    /// would deadlock. Off-main callers simply await the main actor.
    private static let defaultForegroundProbe: @Sendable () async -> Bool = {
        await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
    }
    #else
    private func installObserversIfNeeded(_ state: inout State) {}

    /// Non-UIKit platforms have no application state that would reject GPU
    /// submission. The host fixture injects a probe to exercise the
    /// background branch through the same production code.
    private static let defaultForegroundProbe: @Sendable () async -> Bool = { true }
    #endif

    /// Replaces the foreground probe. Internal and used only by the local
    /// model host fixture; production keeps the UIKit probe above.
    func installForegroundProbeForTesting(_ probe: @escaping @Sendable () async -> Bool) {
        state.withLock { $0.foregroundProbe = probe }
    }
}

/// Forwards a lifecycle cancellation to a generation task that may not exist
/// yet.
///
/// The runtime must register for cancellation *before* creating the GPU task,
/// but the cancel closure must still reach that task. The relay closes the
/// gap: the canceller's closure calls `requestCancellation()`, and once the
/// task exists the runtime calls `attach`. If cancellation arrived first,
/// `attach` returns `true` and the caller cancels the task itself instead of
/// letting it submit prefill.
final class LocalInferenceCancellationRelay: Sendable {
    /// Who requested the cancellation. A caller/user stop keeps the existing
    /// silent `CancellationError` contract (the harness's `cancel()` owns the
    /// terminal transition); an app-lifecycle stop has no such owner and must
    /// surface a retryable deferral instead of ending the run invisibly.
    enum Origin: Sendable, Equatable {
        case caller
        case lifecycle
    }

    private struct State {
        var forward: (@Sendable () -> Void)?
        var requested = false
        var origin: Origin?
    }

    private let state = Mutex(State())

    /// Registers the cancellation forwarder. Returns `true` when cancellation
    /// was already requested; the caller must then cancel the task itself.
    @discardableResult
    func attach(_ forward: @escaping @Sendable () -> Void) -> Bool {
        state.withLock { state -> Bool in
            guard !state.requested else { return true }
            state.forward = forward
            return false
        }
    }

    /// Requests cancellation. Safe to call from the main thread: the
    /// forwarder only calls `Task.cancel()`. Repeated requests forward at most
    /// once; the first origin is kept so a user stop and a concurrent
    /// lifecycle transition cannot both claim the terminal semantics.
    func requestCancellation(origin: Origin = .caller) {
        let forward = state.withLock { state -> (@Sendable () -> Void)? in
            if state.origin == nil { state.origin = origin }
            guard !state.requested else { return nil }
            state.requested = true
            let forward = state.forward
            // Drop the reference so a repeated request cannot run the stale
            // forwarder again.
            state.forward = nil
            return forward
        }
        forward?()
    }

    /// The origin recorded by the first `requestCancellation`, or `nil` when
    /// nothing requested cancellation. Consulted after a generation throws so
    /// a lifecycle stop is not misreported as a caller-owned stop.
    var cancellationOrigin: Origin? {
        state.withLock { $0.origin }
    }
}
