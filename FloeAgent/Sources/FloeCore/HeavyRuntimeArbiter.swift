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
// This arbiter is the single admission gate with an explicit human boundary:
//
//  * **Linux admission is reserved atomically.** A guest start calls
//    `waitForLocalInferenceIdle(registeringStart:)`. The environment id is
//    admitted (and only then recorded as a pending start) in the same lock
//    step as the idle check, so a racing `beginLocalInferenceSession` probe
//    either observed the registration and reports the start as active Linux
//    work, or ran before the check and the start sees the open session and
//    queues — there is no interleaving where both sides proceed. A start that
//    is *queued* is not advertised as a running/admitted guest: it owns no
//    VM and must never be offered for a stop confirmation that would deadlock
//    a model continuation. Cancelling the surrounding task (user stop,
//    environment deletion, shutdown) throws `CancellationError` immediately,
//    and `cancelLinuxStart(environmentID:)` lets a stop reach a queued start
//    without waiting for the model to finish.
//  * **Idle is verified, not assumed.** Before ANY Linux admission — even
//    when no inference session is active — the arbiter runs the configured
//    idle-drain handler (the local-model runtime's physical
//    resident-engine release) and requires a verified outcome: nothing
//    mapped, or a mapped model confirmed released. An idle but still-mapped
//    MLX container therefore cannot overlap a booting guest, and a model
//    retained by a durable task keeps the guest queued (with a bounded
//    retry) instead of being silently ignored. Drains are serialized: new
//    Linux arrivals queue behind an in-flight drain, and a new local session
//    that begins during a drain re-blocks the queued starts.
//  * **Starting local inference reports active Linux work.** The on-device
//    runtime calls `beginLocalInferenceSession()` before mapping weights or
//    measuring headroom. The app-facing probe reports the union of the
//    registry's admission reservations (running, starting, stopping and
//    stop-quarantined guests) and the arbiter's admitted pending starts, so
//    a guest that is merely starting is offered for confirmation exactly
//    like a running one. Guests are only stopped after the handler returns
//    `.stopGuestsAndProceed`; `.deferLocalModel` or a missing handler aborts
//    the local request with a truthful error and never touches the guest.
//  * **A run's own transient tool guest is not a conflict.** The logical run
//    that just ran a Linux tool needs the heavy runtime for its continuation.
//    When the requesting run id is known and EVERY active guest is that run's
//    own verified transient tool guest (started on demand by its tool, with
//    no command, terminal, service, forward, quarantine or other owner), the
//    arbiter releases them through the scoped releaser WITHOUT a user
//    decision — and still only proceeds after the release settles. Anything
//    else (another run's guest, a user-started/pinned guest, a service, a
//    terminal, a quarantine) keeps the explicit confirmation path; a refused
//    or incomplete scoped release falls back to it rather than destroying
//    work silently.
//
// The type is deliberately a plain `Sendable` final class with a
// `Synchronization.Mutex` rather than an actor: `configure(...)` must be
// callable synchronously during app assembly (before any run can start), and
// the wait/session/drain bookkeeping must be race-free without async hops.
// The decision handler, the guest probe/stopper closures and the drain
// handler are the only async boundaries and are always invoked outside the
// lock.

import Foundation
import Synchronization

public final class HeavyRuntimeArbiter: Sendable {
    public static let shared = HeavyRuntimeArbiter()

    /// One active Linux guest with the ownership facts the arbiter needs to
    /// decide whether it is the requesting logical run's OWN disposable tool
    /// guest (released automatically for that run's own continuation) or
    /// work that still requires an explicit user decision.
    ///
    /// Every field is reported by the registry that owns the guest — never
    /// inferred by the arbiter. `ownerRunID` is the durable task UUID string
    /// whose tool started the guest on demand (case-insensitive match against
    /// the requesting run); `nil` means user-started or otherwise unowned and
    /// is never auto-released. `isTransientToolGuest` is true only when the
    /// registry verifies there is no other active owner: no running command,
    /// no interactive terminal, no managed service, no requested forward and
    /// no quarantined stop.
    public struct LinuxGuestActivity: Sendable, Equatable {
        public var environmentID: String
        public var ownerRunID: String?
        public var isTransientToolGuest: Bool

        public init(
            environmentID: String,
            ownerRunID: String? = nil,
            isTransientToolGuest: Bool = false
        ) {
            self.environmentID = environmentID
            self.ownerRunID = ownerRunID
            self.isTransientToolGuest = isTransientToolGuest
        }
    }

    /// One observation of Linux-side work inside this process. Environment
    /// IDs are opaque Floe environment identifiers (UUID strings), never
    /// filesystem paths or credentials.
    public struct LinuxActivity: Sendable, Equatable {
        public var guestEnvironmentIDs: [String]
        /// Human-readable local-service labels ("python", "node", …), already
        /// bounded by the reporter.
        public var localServices: [String]
        /// Per-guest ownership facts for the guests above. A guest listed in
        /// `guestEnvironmentIDs` without an entry here is treated as
        /// conflicting work (safe default for legacy callers).
        public var guests: [LinuxGuestActivity]

        public init(
            guestEnvironmentIDs: [String] = [],
            localServices: [String] = [],
            guests: [LinuxGuestActivity] = []
        ) {
            self.guestEnvironmentIDs = guestEnvironmentIDs
            self.localServices = localServices
            self.guests = guests
        }

        public var isEmpty: Bool {
            guestEnvironmentIDs.isEmpty && localServices.isEmpty
        }

        public var summary: String {
            "guests=\(guestEnvironmentIDs.count) services=\(localServices.count)"
        }

        /// Every reported guest, pairing the id list with the ownership facts.
        /// Ids without facts become non-transient, unowned entries so they can
        /// never be auto-released by accident.
        public var allGuests: [LinuxGuestActivity] {
            var result = guests
            let known = Set(guests.map(\.environmentID))
            for id in guestEnvironmentIDs where !known.contains(id) {
                result.append(LinuxGuestActivity(environmentID: id))
            }
            return result.sorted { $0.environmentID < $1.environmentID }
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
        /// The resident model stayed claimed (a durable task still holds it)
        /// past the drain budget, so the guest could not be admitted without
        /// overlapping mapped pages. Refused truthfully instead of waiting
        /// forever — the caller can end the task and retry.
        case linuxModelRetained

        public var errorDescription: String? {
            switch self {
            case .confirmationUnavailable:
                return "本地模型需要先停止正在运行的 Linux 环境，但当前无法确认该操作。"
            case .deferredByCaller:
                return "本地模型已取消：Linux 环境仍在运行，两者不能同时使用。"
            case .linuxStopIncomplete:
                return "Linux 环境未能在预期时间内停止，已取消本次本地模型请求。"
            case .linuxModelRetained:
                return "本地模型仍被某个任务占用，无法在释放前启动 Linux 环境；请结束该任务后重试。"
            }
        }
    }

    /// Outcome of one idle-drain attempt. Only the two verified outcomes
    /// allow Linux admission: a still-claimed model keeps the queued starts
    /// waiting. The arbiter never treats "the release call did not throw" as
    /// proof of a physical unload — a runtime that retained the mapping for a
    /// durable task must answer `.retained`.
    public enum LinuxDrainOutcome: Sendable, Equatable {
        /// The runtime verified that no local model is mapped.
        case nothingResident
        /// A mapped model was physically released (id is diagnostic).
        case released(modelID: String?)
        /// A mapped model is still claimed; admission must keep waiting.
        case retained

        /// True when Linux admission may proceed on this outcome.
        public var verifiesRelease: Bool {
            switch self {
            case .nothingResident, .released: return true
            case .retained: return false
            }
        }
    }

    public typealias ActivityProbe = @Sendable () async -> LinuxActivity
    public typealias GuestStopper = @Sendable (LinuxActivity) async -> Void
    public typealias DecisionHandler = @Sendable (LinuxActivity) async -> ConflictDecision
    /// Releases the request-scoped OWN transient guests reported in the
    /// activity. Called only when every reported guest is owned by the
    /// requesting logical run and verified transient (and no local service is
    /// active); the implementation must revalidate inside the registry and
    /// refuse rather than destroy anything that stopped being transient (a
    /// service, a command, a terminal, a user-started/pinned guest). A
    /// refusal is safe: the arbiter falls back to the explicit decision path
    /// and never proceeds while the probe still reports work.
    public typealias TransientGuestReleaser = @Sendable (LinuxActivity) async -> Void
    /// Runs before Linux admission (and after the last session ends while
    /// starts are queued). Must verify the process's model residency: release
    /// the mapped engine when unclaimed, or report `.retained` so the guest
    /// stays queued.
    public typealias IdleDrainHandler = @Sendable () async -> LinuxDrainOutcome

    /// One queued Linux admission request. `environmentID` is nil for the
    /// generic no-registration wait; a concrete start carries its id so the
    /// admission step can record it as an admitted pending start.
    private struct LinuxWaiter {
        let environmentID: String?
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var sessions = 0
        var waiters: [UUID: LinuxWaiter] = [:]
        /// Environment ids whose Linux start has been admitted by this
        /// arbiter (idle check passed) and is racing to publish its guest
        /// reservation. Probes report these as active Linux work. Entries
        /// exist only after admission; a queued start is deliberately absent
        /// so it can never masquerade as a VM that could be stopped.
        var linuxStarts: Set<String> = []
        /// A local model may still hold mapped pages: true from the first
        /// `beginLocalInferenceSession` until a drain verifies otherwise.
        /// Linux admission must run the drain while this is set even when no
        /// session is active (an idle container is still mapped memory).
        var residentMayBeMapped = false
        /// Bumped every time a local inference session begins. A drain
        /// verdict only describes the residency it was taken against, so an
        /// outcome whose captured generation no longer matches is stale (a
        /// session began — and possibly ended — during the await) and must
        /// never clear `residentMayBeMapped` or admit Linux: the cycle
        /// re-drains instead.
        var residencyGeneration: UInt64 = 0
        /// Serialized drain cycles in flight. New Linux arrivals queue behind
        /// an in-flight drain; only one cycle runs at a time.
        var drainInFlight = 0
        var drainCompletions = 0
        var activityProbe: ActivityProbe?
        var guestStopper: GuestStopper?
        var decisionHandler: DecisionHandler?
        var transientGuestReleaser: TransientGuestReleaser?
        var idleDrainHandler: IdleDrainHandler?
        var drainRetryInterval: Duration = .seconds(2)
        /// How long the queue may wait on a `.retained` verdict before Linux
        /// admission is refused with `ArbiterError.linuxModelRetained`. The
        /// wait exists for the honest "release in progress" case; it is
        /// bounded so a task that is itself waiting on its Linux tool can
        /// never deadlock the guest forever.
        var drainRetainTimeout: Duration = .seconds(120)
        var settleInterval: Duration = .milliseconds(50)
        var settleTimeout: Duration = .seconds(20)
        /// Verification budget for the scoped own-transient release. It only
        /// has to confirm the registry's own teardown (which already completed
        /// when the releaser returned), so it stays short: a guest that is
        /// still there falls back to the explicit decision instead of stalling
        /// the local request for the confirmation-path settle window.
        var autoReleaseSettleTimeout: Duration = .seconds(2)
        var conflictCount = 0
        var stoppedGuestCount = 0
        /// Diagnostics: scoped own-transient release attempts and the number
        /// of guests actually released without a user decision.
        var autoReleaseAttemptCount = 0
        var autoReleasedGuestCount = 0
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
        transientGuestReleaser: TransientGuestReleaser? = nil,
        idleDrainHandler: IdleDrainHandler? = nil,
        drainRetryInterval: Duration = .seconds(2),
        drainRetainTimeout: Duration = .seconds(120),
        settleInterval: Duration = .milliseconds(50),
        settleTimeout: Duration = .seconds(20),
        autoReleaseSettleTimeout: Duration = .seconds(2)
    ) {
        state.withLock { state in
            state.activityProbe = activityProbe
            state.guestStopper = guestStopper
            state.decisionHandler = decisionHandler
            state.transientGuestReleaser = transientGuestReleaser
            state.idleDrainHandler = idleDrainHandler
            state.drainRetryInterval = drainRetryInterval
            state.drainRetainTimeout = drainRetainTimeout
            state.settleInterval = settleInterval
            state.settleTimeout = settleTimeout
            state.autoReleaseSettleTimeout = autoReleaseSettleTimeout
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

    /// Number of Linux admissions queued behind inference/drain.
    public var linuxWaiterCount: Int {
        state.withLock { $0.waiters.count }
    }

    /// True while a drain cycle is verifying/releasing the resident model.
    public var isLinuxDrainInFlight: Bool {
        state.withLock { $0.drainInFlight > 0 }
    }

    /// Number of drain-handler invocations completed (diagnostics/tests).
    public var linuxDrainCompletionCount: Int {
        state.withLock { $0.drainCompletions }
    }

    /// Number of local-model starts that reported active Linux work.
    public var conflictCount: Int {
        state.withLock { $0.conflictCount }
    }

    /// Number of guests the arbiter stopped after a caller confirmation.
    public var stoppedGuestCount: Int {
        state.withLock { $0.stoppedGuestCount }
    }

    /// Number of logical-run-owned transient guests the arbiter released
    /// without a user decision (its own tool continuation).
    public var autoReleasedGuestCount: Int {
        state.withLock { $0.autoReleasedGuestCount }
    }

    /// Number of scoped own-transient release attempts (diagnostics/tests).
    public var autoReleaseAttemptCount: Int {
        state.withLock { $0.autoReleaseAttemptCount }
    }

    /// Environment ids whose Linux start has been admitted and not yet
    /// released. The app-facing activity probe unions this with the
    /// registry's admission reservations so starting guests are reported
    /// exactly like running ones — and queued (not yet admitted) starts are
    /// never reported.
    public var pendingLinuxStartEnvironmentIDs: [String] {
        state.withLock { $0.linuxStarts.sorted() }
    }

    /// Current Linux snapshot, empty when no probe is installed.
    public func linuxActivity() async -> LinuxActivity {
        guard let probe = state.withLock({ $0.activityProbe }) else { return LinuxActivity() }
        return await probe()
    }

    // MARK: - Linux admission

    /// Linux-side admission: suspends while any local inference session is
    /// active (or a drain is verifying residency) and resumes when the
    /// resident model is verified released and no session is active.
    /// Cancellation-aware: the continuation is removed and resumed with
    /// `CancellationError` so a cancelled guest start never boots a VM later.
    public func waitForLocalInferenceIdle() async throws {
        try await admitOrQueue(registeringStart: nil)
    }

    /// Linux-side admission for a concrete guest start. Beyond the plain
    /// wait, an admitted start registers `environmentID` atomically with the
    /// idle check, closing the TOCTOU window in which a racing
    /// `beginLocalInferenceSession` probed an empty snapshot while this start
    /// was between the check and its reservation. The registration is
    /// released with `releaseLinuxStart(environmentID:)` on every exit path;
    /// a queued (not admitted) start holds no registration.
    public func waitForLocalInferenceIdle(registeringStart environmentID: String) async throws {
        try await admitOrQueue(registeringStart: environmentID)
    }

    /// Releases one admitted-start registration. Idempotent; safe on every
    /// exit path of a guest start, including starts that never registered.
    public func releaseLinuxStart(environmentID: String) {
        _ = state.withLock { $0.linuxStarts.remove(environmentID) }
    }

    /// Cancels a queued Linux admission for one environment (user stop,
    /// environment deletion): the waiter resumes with `CancellationError` so
    /// a start queued behind a long model run does not hold its task until
    /// the model happens to finish. Admitted registrations are owned by the
    /// start's own `releaseLinuxStart` and are not touched here.
    public func cancelLinuxStart(environmentID: String) {
        let cancelled = state.withLock { state -> [CheckedContinuation<Void, Error>] in
            let matching = state.waiters.filter { $0.value.environmentID == environmentID }
            for id in matching.keys { state.waiters.removeValue(forKey: id) }
            return matching.values.map(\.continuation)
        }
        for continuation in cancelled { continuation.resume(throwing: CancellationError()) }
    }

    private enum AdmissionAction {
        case proceed
        case alreadyCancelled
        case queued
        case queuedAndDrain
    }

    private func admitOrQueue(registeringStart environmentID: String?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The cancellation check runs under the same mutex that
                // `cancelWaiter`/`cancelLinuxStart` take, so "cancelled
                // before the waiter registers" is ordered deterministically:
                // either the handler runs first and removes nothing (then
                // this closure observes `Task.isCancelled`), or the waiter is
                // stored first and the handler removes and resumes it.
                // Nothing is registered on any cancelled path, so a
                // cancellation can never leak a pending-start registration.
                let action = state.withLock { state -> AdmissionAction in
                    if Task.isCancelled { return .alreadyCancelled }
                    let drainRequired = state.idleDrainHandler != nil
                        && state.residentMayBeMapped
                    if state.sessions == 0, state.drainInFlight == 0, !drainRequired {
                        if let environmentID { state.linuxStarts.insert(environmentID) }
                        return .proceed
                    }
                    state.waiters[id] = LinuxWaiter(
                        environmentID: environmentID,
                        continuation: continuation
                    )
                    if state.sessions == 0, state.drainInFlight == 0, drainRequired {
                        // Idle but possibly still mapped: one serialized drain
                        // verifies the release before anyone is admitted.
                        state.drainInFlight += 1
                        return .queuedAndDrain
                    }
                    return .queued
                }
                switch action {
                case .proceed:
                    continuation.resume()
                case .alreadyCancelled:
                    continuation.resume(throwing: CancellationError())
                case .queued:
                    break
                case .queuedAndDrain:
                    self.startDrainCycle()
                }
            }
        } onCancel: {
            self.cancelWaiter(id)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
        waiter?.continuation.resume(throwing: CancellationError())
    }

    // MARK: - Local inference admission

    /// MLX-side admission. Increments the session count first, so a guest
    /// start that races the decision below already sees an active session and
    /// queues. Reports active Linux work through the app-facing handler and
    /// stops guests only after `.stopGuestsAndProceed`. Throws (after
    /// releasing the session) when the caller defers, no handler exists, or a
    /// confirmed stop does not settle.
    ///
    /// `requestingRunID` is the logical durable run this generation belongs
    /// to. When it is provided and EVERY reported guest is that run's own
    /// verified transient tool guest (no command, terminal, service, forward
    /// or quarantine — no other owner), the arbiter releases them through the
    /// scoped `transientGuestReleaser` without a user decision: this is the
    /// run's own tool continuation, not a conflict. Physical mutual exclusion
    /// is unchanged — the release must settle (probe empty) before the model
    /// proceeds, and a refusal or incomplete release falls back to the
    /// explicit decision path instead of overlapping anything.
    @discardableResult
    public func beginLocalInferenceSession(requestingRunID: UUID? = nil) async throws -> LinuxActivity {
        let probe = state.withLock { state -> ActivityProbe? in
            state.sessions += 1
            // A model may now become mapped: Linux admission must verify a
            // release before it is allowed through again. The generation
            // bump invalidates any drain verdict that is still in flight
            // (its release evidence predates this session's mapping).
            state.residentMayBeMapped = true
            state.residencyGeneration &+= 1
            return state.activityProbe
        }
        guard let probe else { return LinuxActivity() }

        let activity = await probe()
        guard !activity.isEmpty else { return activity }

        if let requestingRunID, !activity.guests.isEmpty,
           let releaser = state.withLock({ $0.transientGuestReleaser }) {
            let own = activity.allGuests.filter {
                $0.isTransientToolGuest && Self.matches(ownerRunID: $0.ownerRunID, runID: requestingRunID)
            }
            let ownIDs = Set(own.map(\.environmentID))
            let foreignGuests = activity.allGuests.filter { !ownIDs.contains($0.environmentID) }
            if !own.isEmpty, foreignGuests.isEmpty, activity.localServices.isEmpty {
                state.withLock { $0.autoReleaseAttemptCount += 1 }
                let scoped = LinuxActivity(
                    guestEnvironmentIDs: own.map(\.environmentID),
                    localServices: [],
                    guests: own
                )
                FloeLogger(category: .providers).info(
                    "heavyRuntimeArbiterOwnTransientLinuxRelease run=\(requestingRunID.uuidString) guests=\(own.count)"
                )
                await releaser(scoped)
                // The releaser only returns after the registry's own teardown
                // (close + Runtime v2 flush/slot release) or a refusal, so the
                // verification is a confirmation of the registry's live state,
                // not a wait for a remote process. A guest that is still there
                // (refused release, quarantine, or a racing new start) falls
                // back to the explicit decision below — it never proceeds.
                let autoReleaseTiming = state.withLock {
                    ($0.settleInterval, $0.autoReleaseSettleTimeout)
                }
                if await settleLinuxStop(probe: probe,
                                         settleInterval: autoReleaseTiming.0,
                                         settleTimeout: autoReleaseTiming.1) {
                    state.withLock { $0.autoReleasedGuestCount += own.count }
                    FloeLogger(category: .providers).info(
                        "heavyRuntimeArbiterOwnTransientLinuxReleased run=\(requestingRunID.uuidString) guests=\(own.count)"
                    )
                    return activity
                }
                // The scoped release could not prove the guests gone (a
                // service/command appeared, a stop was quarantined, or the
                // release refused). Nothing is destroyed silently: fall
                // through to the explicit decision so the user sees exactly
                // what is still running.
                FloeLogger(category: .providers).error(
                    "heavyRuntimeArbiterOwnTransientLinuxReleaseIncomplete run=\(requestingRunID.uuidString) guests=\(own.count)"
                )
            }
        }

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

    /// A guest's recorded owner matches the requesting run. Both sides use the
    /// durable run UUID string; parsing normalizes case so a differently
    /// formatted id can never silently mismatch.
    private static func matches(ownerRunID: String?, runID: UUID) -> Bool {
        guard let ownerRunID else { return false }
        if let owner = UUID(uuidString: ownerRunID) { return owner == runID }
        return ownerRunID.caseInsensitiveCompare(runID.uuidString) == .orderedSame
    }

    private enum SessionEndAction {
        case none
        case admitNow
        case drain
    }

    /// Releases one local inference session. When the last session ends and
    /// Linux starts are queued, the configured idle-drain hook runs first
    /// (physically releasing the resident model) and only a verified release
    /// admits the queued starts — a guest never boots while the model's pages
    /// are still mapped. When no hook is installed the queued starts resume
    /// inline, exactly as before.
    public func endLocalInferenceSession() {
        let action = state.withLock { state -> SessionEndAction in
            state.sessions = max(0, state.sessions - 1)
            guard state.sessions == 0, !state.waiters.isEmpty else { return .none }
            guard state.idleDrainHandler != nil else { return .admitNow }
            // A cycle is already verifying residency; it re-checks the queue
            // after every handler return, so it picks these waiters up.
            guard state.drainInFlight == 0 else { return .none }
            state.drainInFlight += 1
            return .drain
        }
        switch action {
        case .none:
            break
        case .admitNow:
            resumeLinuxWaitersIfIdle()
        case .drain:
            startDrainCycle()
        }
    }

    // MARK: - idle drain

    private func startDrainCycle() {
        Task { await self.runDrainCycle() }
    }

    private enum DrainStep {
        case stop
        case retry
        /// The model is still claimed: keep waiting, but only inside the
        /// bounded retention budget.
        case retryRetained
        case admit([LinuxWaiter])
    }

    /// One serialized drain cycle: invoke the handler, admit queued starts
    /// only on a verified outcome for the residency it was taken against,
    /// retry while a model is retained or the verdict went stale, and stop
    /// as soon as the queue is empty or a new session re-blocks admission.
    /// A retention that outlasts `drainRetainTimeout` refuses the queue with
    /// a truthful error instead of waiting forever — the self-deadlock case
    /// (a task waiting for its own Linux tool while its retention pins the
    /// model) fails recoverably instead of hanging.
    private func runDrainCycle() async {
        let clock = ContinuousClock()
        var retainedSince: ContinuousClock.Instant?
        while true {
            // Continue-or-exit is one atomic decision: either the cycle keeps
            // `drainInFlight` held and serves the queue, or it releases the
            // flag while proving there is nothing left to serve. A waiter
            // queued after an exit observes `drainInFlight == 0` and starts a
            // fresh cycle instead of waiting for a cycle that already left.
            let step = state.withLock { state -> (serve: Bool, generation: UInt64) in
                if state.sessions == 0, !state.waiters.isEmpty {
                    return (true, state.residencyGeneration)
                }
                state.drainInFlight = max(0, state.drainInFlight - 1)
                return (false, state.residencyGeneration)
            }
            guard step.serve else { return }
            guard let handler = state.withLock({ $0.idleDrainHandler }) else {
                // No verifier installed (tests/legacy): admit the queue. The
                // release and the admission share one lock step so an arrival
                // that races the end of the cycle still queues behind a live
                // drain instead of slipping past it.
                let waiters = state.withLock { state -> [LinuxWaiter] in
                    state.drainInFlight = max(0, state.drainInFlight - 1)
                    return self.admitQueuedWaitersLocked(&state)
                }
                for waiter in waiters { waiter.continuation.resume() }
                return
            }
            let outcome = await handler()
            let action = state.withLock { state -> DrainStep in
                state.drainCompletions += 1
                guard state.sessions == 0, !state.waiters.isEmpty else {
                    state.drainInFlight = max(0, state.drainInFlight - 1)
                    return .stop
                }
                // The verdict only proves the residency it was taken
                // against. A session that began (and possibly ended) while
                // the verifier ran bumped the generation: the newer mapping
                // was never observed, so the stale verdict cannot clear it —
                // re-drain instead of admitting Linux over mapped pages.
                guard outcome.verifiesRelease else { return .retryRetained }
                guard state.residencyGeneration == step.generation else { return .retry }
                state.residentMayBeMapped = false
                state.drainInFlight = max(0, state.drainInFlight - 1)
                return .admit(self.admitQueuedWaitersLocked(&state))
            }
            switch action {
            case .stop:
                return
            case .admit(let waiters):
                for waiter in waiters { waiter.continuation.resume() }
                return
            case .retry:
                retainedSince = nil
                let interval = state.withLock { $0.drainRetryInterval }
                try? await Task.sleep(for: interval)
            case .retryRetained:
                let now = clock.now
                if retainedSince == nil {
                    retainedSince = now
                    FloeLogger(category: .providers).info(
                        "heavyRuntimeArbiterLinuxWaitingForModelRelease waiters=\(state.withLock { $0.waiters.count })"
                    )
                }
                let waiting = retainedSince.map { now - $0 } ?? .zero
                let budget = state.withLock { $0.drainRetainTimeout }
                guard waiting < budget else {
                    let refused = state.withLock { state -> [LinuxWaiter] in
                        state.drainInFlight = max(0, state.drainInFlight - 1)
                        let values = Array(state.waiters.values)
                        state.waiters.removeAll()
                        return values
                    }
                    FloeLogger(category: .providers).error(
                        "heavyRuntimeArbiterLinuxRefusedModelRetained waiters=\(refused.count)"
                    )
                    for waiter in refused {
                        waiter.continuation.resume(throwing: ArbiterError.linuxModelRetained)
                    }
                    return
                }
                let interval = state.withLock { $0.drainRetryInterval }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Caller holds the lock. Removes every queued waiter, records admitted
    /// pending starts and returns the waiters to resume.
    private func admitQueuedWaitersLocked(_ state: inout State) -> [LinuxWaiter] {
        let waiters = Array(state.waiters.values)
        state.waiters.removeAll()
        for waiter in waiters {
            if let environmentID = waiter.environmentID {
                state.linuxStarts.insert(environmentID)
            }
        }
        return waiters
    }

    private func resumeLinuxWaitersIfIdle() {
        let waiters = state.withLock { state -> [LinuxWaiter] in
            guard state.sessions == 0, !state.waiters.isEmpty else { return [] }
            return self.admitQueuedWaitersLocked(&state)
        }
        for waiter in waiters { waiter.continuation.resume() }
    }

    // MARK: - settle

    /// Bounded settle verification after a confirmed guest stop: the probe
    /// must report no Linux work before local inference is admitted. A
    /// quarantined guest keeps its reservation, so it keeps failing this
    /// check — the quarantine is never force-cleared to make room.
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
}
