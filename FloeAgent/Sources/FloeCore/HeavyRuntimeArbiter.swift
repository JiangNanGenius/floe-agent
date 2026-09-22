// FloeCore — process-wide arbitration between the two heavy in-process
// runtimes: on-device MLX inference and the TinyEMU Linux guest.
//
// SPDX-License-Identifier: MPL-2.0
//
// Both runtimes reserve gigabytes inside the app process: a local MLX model
// maps multi-gigabyte weights plus its KV/scratch pages, and every TinyEMU
// guest owns a fixed RAM budget the OS only charges after its pages are
// touched. Build 221 device reports showed the two running at once (a Linux
// environment being prepared while an on-device model decoded), which is what
// the residency accounting alone cannot prevent: `ResidentMemoryReservations`
// only subtracts the guest budget from a *later* model load, it never stops
// either side from starting.
//
// This arbiter adds the missing mutual exclusion with an explicit human
// boundary:
//
//  * **Linux waits, cancellably.** Starting a guest calls
//    `waitForLocalInferenceIdle()` first. While any local generation session
//    is active the start suspends; cancelling the surrounding task (user stop,
//    environment deletion, shutdown) throws `CancellationError` immediately
//    instead of leaving a doomed boot in flight.
//  * **Starting local inference reports active Linux work.** The on-device
//    runtime calls `beginLocalInferenceSession()` before mapping weights or
//    measuring headroom. When active guests or local services exist, the
//    snapshot is handed to the app-facing `decisionHandler`; guests are only
//    stopped after it returns `.stopGuestsAndProceed`. `.deferLocalModel` or a
//    missing handler aborts the local request with a truthful error and never
//    touches the guest.
//
// The type is deliberately a plain `Sendable` final class with a
// `Synchronization.Mutex` rather than an actor: `configure(...)` must be
// callable synchronously during app assembly (before any run can start), and
// the wait/session bookkeeping must be race-free without async hops. The
// decision handler and the guest probe/stop closures are the only async
// boundaries and are always invoked outside the lock.

import Foundation
import Synchronization

public final class HeavyRuntimeArbiter: Sendable {
    public static let shared = HeavyRuntimeArbiter()

    /// One observation of Linux-side work inside this process. Environment
    /// IDs are opaque Floe environment identifiers (UUID strings), never
    /// filesystem paths or credentials.
    public struct LinuxActivity: Sendable, Equatable {
        public var guestEnvironmentIDs: [String]
        /// Human-readable local-service labels ("python", "node", …), already
        /// bounded by the reporter.
        public var localServices: [String]

        public init(guestEnvironmentIDs: [String] = [], localServices: [String] = []) {
            self.guestEnvironmentIDs = guestEnvironmentIDs
            self.localServices = localServices
        }

        public var isEmpty: Bool {
            guestEnvironmentIDs.isEmpty && localServices.isEmpty
        }

        public var summary: String {
            "guests=\(guestEnvironmentIDs.count) services=\(localServices.count)"
        }
    }

    /// The app-facing decision for a local-model start that collides with
    /// active Linux work.
    public enum ConflictDecision: Sendable, Equatable {
        /// The caller (user) confirmed stopping the reported guests/services.
        case stopGuestsAndProceed
        /// The caller declined; the local-model request must not proceed.
        case deferLocalModel
    }

    public enum ArbiterError: Error, Equatable, LocalizedError {
        /// Linux work is active and no decision handler is installed, so no
        /// one can confirm stopping it. The local request is refused rather
        /// than silently overlapping the guest.
        case confirmationUnavailable
        /// The app-facing decision returned `.deferLocalModel`.
        case deferredByCaller
        /// A confirmed stop did not finish within the settle window. The
        /// local request is refused rather than racing a still-running guest.
        case linuxStopIncomplete

        public var errorDescription: String? {
            switch self {
            case .confirmationUnavailable:
                return "本地模型需要先停止正在运行的 Linux 环境，但当前无法确认该操作。"
            case .deferredByCaller:
                return "本地模型已取消：Linux 环境仍在运行，两者不能同时使用。"
            case .linuxStopIncomplete:
                return "Linux 环境未能在预期时间内停止，已取消本次本地模型请求。"
            }
        }
    }

    public typealias ActivityProbe = @Sendable () async -> LinuxActivity
    public typealias GuestStopper = @Sendable (LinuxActivity) async -> Void
    public typealias DecisionHandler = @Sendable (LinuxActivity) async -> ConflictDecision

    private struct State {
        var sessions = 0
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        var activityProbe: ActivityProbe?
        var guestStopper: GuestStopper?
        var decisionHandler: DecisionHandler?
        var settleInterval: Duration = .milliseconds(50)
        var settleTimeout: Duration = .seconds(20)
        var conflictCount = 0
        var stoppedGuestCount = 0
    }

    private let state = Mutex(State())

    /// Test seam: a dedicated instance never shares production state.
    public init() {}

    /// Installs the app-facing hooks. Called once during app assembly, before
    /// any local generation or guest start can run.
    public func configure(
        activityProbe: @escaping ActivityProbe,
        guestStopper: @escaping GuestStopper,
        decisionHandler: DecisionHandler? = nil,
        settleInterval: Duration = .milliseconds(50),
        settleTimeout: Duration = .seconds(20)
    ) {
        state.withLock { state in
            state.activityProbe = activityProbe
            state.guestStopper = guestStopper
            state.decisionHandler = decisionHandler
            state.settleInterval = settleInterval
            state.settleTimeout = settleTimeout
        }
    }

    /// True once the app installed the probe/decision/stopper triple.
    public var isConfigured: Bool {
        state.withLock { $0.activityProbe != nil }
    }

    public var isLocalInferenceActive: Bool {
        state.withLock { $0.sessions > 0 }
    }

    public var activeInferenceSessionCount: Int {
        state.withLock { $0.sessions }
    }

    /// Number of local-model starts that reported active Linux work.
    public var conflictCount: Int {
        state.withLock { $0.conflictCount }
    }

    /// Number of guests the arbiter stopped after a caller confirmation.
    public var stoppedGuestCount: Int {
        state.withLock { $0.stoppedGuestCount }
    }

    /// Current Linux snapshot, empty when no probe is installed.
    public func linuxActivity() async -> LinuxActivity {
        guard let probe = state.withLock({ $0.activityProbe }) else { return LinuxActivity() }
        return await probe()
    }

    /// Linux-side admission: suspends while any local inference session is
    /// active and resumes when the last one ends. Cancellation-aware: the
    /// continuation is removed and resumed with `CancellationError` so a
    /// cancelled guest start never boots a VM later.
    public func waitForLocalInferenceIdle() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let proceedNow = state.withLock { state -> Bool in
                    guard state.sessions > 0 else { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if proceedNow { continuation.resume() }
            }
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    /// MLX-side admission. Increments the session count first, so a guest
    /// start that races the decision below already sees an active session and
    /// waits. Reports active Linux work through the app-facing handler and
    /// stops guests only after `.stopGuestsAndProceed`. Throws (after
    /// releasing the session) when the caller defers, no handler exists, or a
    /// confirmed stop does not settle.
    @discardableResult
    public func beginLocalInferenceSession() async throws -> LinuxActivity {
        let probe = state.withLock { state -> ActivityProbe? in
            state.sessions += 1
            return state.activityProbe
        }
        guard let probe else { return LinuxActivity() }

        let activity = await probe()
        guard !activity.isEmpty else { return activity }

        state.withLock { $0.conflictCount += 1 }
        guard let handler = state.withLock({ $0.decisionHandler }) else {
            endLocalInferenceSession()
            throw ArbiterError.confirmationUnavailable
        }
        let decision = await handler(activity)
        switch decision {
        case .deferLocalModel:
            endLocalInferenceSession()
            throw ArbiterError.deferredByCaller
        case .stopGuestsAndProceed:
            guard let stopper = state.withLock({ $0.guestStopper }) else {
                endLocalInferenceSession()
                throw ArbiterError.confirmationUnavailable
            }
            FloeLogger(category: .providers).info(
                "heavyRuntimeArbiterStoppingLinux \(activity.summary) guests=\(activity.guestEnvironmentIDs.count)"
            )
            await stopper(activity)
            let timing = state.withLock { ($0.settleInterval, $0.settleTimeout) }
            guard await settleLinuxStop(probe: probe,
                                        settleInterval: timing.0,
                                        settleTimeout: timing.1) else {
                endLocalInferenceSession()
                throw ArbiterError.linuxStopIncomplete
            }
            state.withLock { $0.stoppedGuestCount += activity.guestEnvironmentIDs.count }
            FloeLogger(category: .providers).info(
                "heavyRuntimeArbiterLinuxStopped \(activity.summary)"
            )
        }
        return activity
    }

    /// Releases one local inference session. The Linux waiters resume when
    /// the last session ends.
    public func endLocalInferenceSession() {
        let waiters: [CheckedContinuation<Void, Error>] = state.withLock { state in
            state.sessions = max(0, state.sessions - 1)
            guard state.sessions == 0, !state.waiters.isEmpty else { return [] }
            let values = Array(state.waiters.values)
            state.waiters.removeAll()
            return values
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Bounded settle verification after a confirmed guest stop: the probe
    /// must report no Linux work before local inference is admitted.
    private func settleLinuxStop(
        probe: ActivityProbe,
        settleInterval: Duration,
        settleTimeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + settleTimeout
        while true {
            if (await probe()).isEmpty { return true }
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: settleInterval)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
        waiter?.resume(throwing: CancellationError())
    }
}
