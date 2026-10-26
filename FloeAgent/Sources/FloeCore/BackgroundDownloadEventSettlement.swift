// FloeCore — service-owned background URLSession event settlement primitive.
//
// SPDX-License-Identifier: MPL-2.0
//
// Foundation-only so EVERY background download owner in the app (job
// downloads, media artifacts, and — via the frozen public API — the local
// model catalog and Whisper downloaders) can share ONE corrected drain
// implementation instead of each hand-rolling the completion handoff.
//
// A background URLSession delivers `urlSessionDidFinishEvents` when the
// SYSTEM has finished handing it delegate callbacks — but each owner then
// performs its OWN asynchronous settle work (move the staged file, verify,
// commit, transition the durable job, notify) plus, on a wake launch, its
// bounded bootstrap work (metadata restore, policy-gated finite scans).
// The historical bug: the stored system completion handler was called
// directly inside `urlSessionDidFinishEvents`, so the process could be
// suspended or killed before that async work drained, losing committed
// files or leaving jobs stuck in `running`; and one path called the
// handler on the delegate thread.
//
// This type owns the ordering explicitly. A WAKE is one release cycle of
// one background session: tracked work + the system finish signal + the
// stored system completion, settled exactly once.
//  • every async follow-up (settle task, fail task, delayed retry window,
//    tracked wake bootstrap) registers as a PENDING event synchronously
//    inside the delegate callback / launch hook that schedules it — before
//    that callback returns, so it can never race the finish event;
//  • the release decision (pendingEvents == 0 AND systemEventsDone AND a
//    stored handler AND the wake not yet fired) is extracted ATOMICALLY in
//    the same lock section that flips the fired flag — a `beginEvent`
//    landing between a caller's apparent readiness and the actual fire
//    defers that fire instead of releasing the wake prematurely;
//  • after a wake has fired, only an ACTUAL new signal opens the next one:
//    a fresh `beginEvent` (a real new task event / tracked bootstrap) or a
//    fresh `registerSystemCompletionHandler` (a real new launch). Both
//    roll over explicitly BEFORE mutating, so a next-wake event can never
//    increment the completed wake and then be silently wiped by a later
//    reset; a repeated/duplicate `sessionDidFinishEvents` or `endEvent` on
//    a fired wake is IGNORED — it carries no cycle identity, and
//    fabricating a new system-done cycle from it would let the NEXT wake's
//    registration fire before that wake's real finish;
//  • registration order is irrelevant: a handler stored after its own
//    wake's events already drained fires immediately (on main), events
//    that arrive with no stored handler still count, and repeated finish
//    signals never double-fire;
//  • the completion runs EXACTLY ONCE per wake, on the main thread.
//
// The production contract is exact 1:1 begin/end pairing (a `defer` in
// each owning task). Nothing here touches the network, files or stores.

import Foundation

public final class BackgroundDownloadEventSettlement: @unchecked Sendable {
    /// Diagnostic label for logs only (never user-visible).
    public let name: String

    private struct State {
        /// Monotonic wake cycle identity. Every rollover increments this
        /// BEFORE any field of the new wake is touched, so tests (and any
        /// future audit) can tell distinct wakes apart.
        var wakeGeneration: UInt64 = 1
        var pendingEvents = 0
        var systemEventsDone = false
        var completion: (() -> Void)?
        /// True once the CURRENT wake's completion has been released.
        var wakeFired = false
    }

    private let lock = NSLock()
    private var state = State()

    public init(name: String) {
        self.name = name
    }

    // MARK: - Registration (launch hook)

    /// Stores the system completion handler for the current background wake.
    /// Safe in any order relative to the delegate callbacks: if the wake's
    /// events have already drained and the system reported finish, the
    /// handler fires immediately (on main). A register arriving after the
    /// previous wake FIRED opens a fresh wake instead of overwriting the
    /// completed record — and never discards events that already arrived
    /// for this new wake, because those rolled the state over themselves.
    public func registerSystemCompletionHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        if state.wakeFired {
            beginWakeLocked()
        }
        state.completion = handler
        let toFire = takeReadyCompletionLocked()
        lock.unlock()
        if let toFire { release(toFire) }
    }

    /// ATOMIC register + tracked bootstrap lease — the correct launch-hook
    /// form when the wake also owns bounded bootstrap work (metadata
    /// restore, a policy-gated finite scan; never a whole-agent wait).
    /// The bootstrap's pending slot is registered INSIDE the same lock
    /// section, BEFORE the handler is stored, so a finish signal that
    /// already arrived (or arrives concurrently) can never fire the
    /// completion before the bootstrap is tracked — a plain
    /// `register(handler)` followed by `trackBootstrap` loses that race:
    /// the drained wake would fire immediately and the bootstrap would
    /// open a NEXT wake that nothing releases in time. The completion
    /// fires exactly once, on main, after the system finish AND every
    /// tracked event including the bootstrap have drained.
    public func registerSystemCompletionHandler(
        _ handler: @escaping () -> Void,
        bootstrap: @escaping @Sendable () async -> Void
    ) {
        lock.lock()
        if state.wakeFired {
            beginWakeLocked()
        }
        // Pending FIRST, handler second — atomic with respect to every
        // other entry point (they all take the same lock).
        state.pendingEvents += 1
        state.completion = handler
        // takeReadyCompletionLocked cannot fire here (pending >= 1); called
        // only to keep the single release path authoritative.
        let toFire = takeReadyCompletionLocked()
        lock.unlock()
        if let toFire { release(toFire) }
        Task { [weak self] in
            await bootstrap()
            self?.endEvent()
        }
    }

    // MARK: - Event accounting (delegate thread)

    /// Registers one pending async follow-up. MUST be called synchronously
    /// inside the delegate callback / launch hook that schedules the work.
    /// If the previous wake already fired (process stayed alive and the
    /// system handed this session new completions), the event belongs to a
    /// NEW wake: roll over first so the count is attributed to the cycle the
    /// next launch's handler will release — the old shared-counter reset in
    /// `register` used to wipe exactly these early arrivals.
    public func beginEvent() {
        lock.lock()
        if state.wakeFired {
            beginWakeLocked()
        }
        state.pendingEvents += 1
        lock.unlock()
    }

    /// Settles one registered event. Every production path pairs its
    /// `beginEvent` with EXACTLY ONE `endEvent` (a `defer` in the owning
    /// async task), including error and cancellation paths — that exact
    /// pairing is the contract, because there is no per-event cycle token:
    /// a duplicated late end cannot identify which cycle it belonged to.
    /// An end arriving while the current cycle is already FIRED is ignored
    /// (it can only be a duplicate of the released cycle, whose drain
    /// necessarily preceded the release); a further extra end on an open
    /// cycle clamps at zero rather than corrupting the pending count.
    public func endEvent() {
        lock.lock()
        if state.wakeFired {
            // This end belongs to the already-released wake. Nothing left
            // to do — never touch the next wake's bookkeeping.
            lock.unlock()
            return
        }
        state.pendingEvents = max(0, state.pendingEvents - 1)
        let toFire = takeReadyCompletionLocked()
        lock.unlock()
        if let toFire { release(toFire) }
    }

    // MARK: - System finish signal (delegate thread)

    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` arrived. Does
    /// NOT finish by itself: it only marks the system side of the CURRENT
    /// wake complete; the registered events decide whether that ends the
    /// wake. A finish signal arriving while the current cycle is already
    /// FIRED is IGNORED: it cannot identify itself as belonging to a future
    /// cycle, and treating it as one would let a late/duplicate finish
    /// pre-satisfy `systemEventsDone`, so the NEXT wake's registration
    /// would fire before that wake's real finish. A new cycle is opened
    /// ONLY by an actual new event (`beginEvent`) or a new launch handler
    /// (`registerSystemCompletionHandler`).
    public func sessionDidFinishEvents() {
        lock.lock()
        if state.wakeFired {
            // Stale/duplicate finish for the released wake: ignore it. Do
            // not fabricate a system-done cycle.
            lock.unlock()
            return
        }
        state.systemEventsDone = true
        let toFire = takeReadyCompletionLocked()
        lock.unlock()
        if let toFire { release(toFire) }
    }

    // MARK: - Tracked bootstrap lease (launch-hook convenience)

    /// Tracks bounded wake-bootstrap work (metadata restore, a policy-gated
    /// finite due scan — never a whole-agent wait) as a pending settlement
    /// event. `beginEvent` is registered SYNCHRONOUSLY before the first
    /// suspension point, and the event ends exactly once regardless of what
    /// the work does.
    ///
    /// ORDERING: at a launch hook use the ATOMIC
    /// `registerSystemCompletionHandler(_:bootstrap:)` wrapper instead —
    /// calling this AFTER a plain register loses a race (an already-drained
    /// wake fires the stored handler immediately and this lease lands on
    /// the NEXT wake). Standalone use is correct only BEFORE the handler is
    /// registered, or mid-wake for additional tracked work.
    public func trackBootstrap(_ work: @escaping @Sendable () async -> Void) {
        beginEvent()
        Task {
            await work()
            endEvent()
        }
    }

    // MARK: - Diagnostics (internal; focused tests use @testable)

    /// Snapshot for focused tests; never used for behavior.
    var settlementStateForTesting: (
        wakeGeneration: UInt64,
        pending: Int,
        systemDone: Bool,
        fired: Bool,
        hasHandler: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            state.wakeGeneration,
            state.pendingEvents,
            state.systemEventsDone,
            state.wakeFired,
            state.completion != nil
        )
    }

    // MARK: - Wake cycle

    /// Caller holds the lock. Starts the next wake cycle explicitly.
    private func beginWakeLocked() {
        state.wakeGeneration &+= 1
        state.pendingEvents = 0
        state.systemEventsDone = false
        state.completion = nil
        state.wakeFired = false
    }

    /// Caller holds the lock. The READY DECISION and the fired flip happen
    /// in one lock section: whatever `pendingEvents`/`systemEventsDone`
    /// say here is the truth at release time — a concurrent `beginEvent`
    /// either happens-before (and defers this release) or happens-after
    /// the fired flag (and belongs to the next wake). There is no window
    /// where a readiness computed earlier can fire past a new event.
    private func takeReadyCompletionLocked() -> (() -> Void)? {
        guard !state.wakeFired,
              state.pendingEvents == 0,
              state.systemEventsDone,
              let completion = state.completion else { return nil }
        state.wakeFired = true
        state.completion = nil
        return completion
    }

    private func release(_ completion: @escaping () -> Void) {
        // The system completion handler belongs on the main thread. The
        // READY DECISION was already taken atomically in
        // `takeReadyCompletionLocked` (the fired flag flipped in that same
        // lock section), so anything running now can only either defer to a
        // later drain or open a later wake — this method itself never
        // re-decides and can never double-release.
        if Thread.isMainThread {
            completion()
        } else {
            DispatchQueue.main.async(execute: completion)
        }
    }
}
