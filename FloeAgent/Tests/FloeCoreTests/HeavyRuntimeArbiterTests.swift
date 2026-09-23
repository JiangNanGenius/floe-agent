// FloeCoreTests — Build 222 heavy-runtime arbitration.
//
// MLX inference and the TinyEMU Linux guest must never overlap: Linux
// admission is reserved atomically against local-model entry, an idle-but-
// mapped model is physically released (or honestly reported retained) before
// any guest is admitted, queued starts never masquerade as stoppable VMs,
// and cancellation never leaves a dangling waiter or a leaked registration.
// These tests pin every branch of that contract with deterministic gates and
// state predicates — no device, and no timing-only assertions.

import Foundation
import Testing
@testable import FloeCore

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool = false) { self.value = value }

    var isSet: Bool { lock.withLock { value } }

    func set() { lock.withLock { value = true } }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) { lock.withLock { events.append(event) } }
    var recorded: [String] { lock.withLock { events } }
}

/// Async barrier for deterministic interleavings: a handler can park on
/// `wait()` until the test opens the gate, so ordering is controlled by the
/// test instead of by sleeps.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

/// Scripted drain outcomes with an invocation counter. Each step runs when
/// the corresponding drain call happens, so a step can park on a `Gate`.
private final class ScriptedDrain: @unchecked Sendable {
    typealias Step = @Sendable () async -> HeavyRuntimeArbiter.LinuxDrainOutcome

    private let lock = NSLock()
    private let steps: [Step]
    private var calls = 0

    init(_ steps: [Step]) { self.steps = steps }

    var callCount: Int { lock.withLock { calls } }

    func next() async -> HeavyRuntimeArbiter.LinuxDrainOutcome {
        let index: Int = lock.withLock {
            let index = calls
            calls += 1
            return index
        }
        let step = steps.isEmpty ? nil : steps[min(index, steps.count - 1)]
        guard let step else { return .nothingResident }
        return await step()
    }
}

/// Bounded state-driven wait: the predicate is the mechanism, the deadline is
/// only a safety bound so a broken implementation fails instead of hanging.
private func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// A wait bounded by a wall-clock deadline: on expiry the awaited task is
/// cancelled (which resumes a parked arbiter waiter with `CancellationError`)
/// and the test fails with `DeadlineExceeded` instead of hanging the suite.
private struct DeadlineExceeded: Error {}

private func awaitWithin(
    seconds: Double = 5,
    _ task: Task<Void, Error>
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await task.value }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            task.cancel()
            throw DeadlineExceeded()
        }
        _ = try await group.next()
        group.cancelAll()
    }
}

@Suite("Heavy runtime arbitration")
struct HeavyRuntimeArbiterTests {
    private func emptyProbe() -> HeavyRuntimeArbiter.ActivityProbe {
        { HeavyRuntimeArbiter.LinuxActivity() }
    }

    private func allowHandler() -> HeavyRuntimeArbiter.DecisionHandler {
        { _ in .stopGuestsAndProceed }
    }

    @Test("A guest start waits until the last local inference session ends")
    func guestStartWaitsForInference() async throws {
        let arbiter = HeavyRuntimeArbiter()
        arbiter.configure(
            activityProbe: emptyProbe(),
            guestStopper: { _ in },
            decisionHandler: allowHandler()
        )
        #expect(!arbiter.isLocalInferenceActive)

        try await arbiter.beginLocalInferenceSession()
        #expect(arbiter.isLocalInferenceActive)

        let gate = Flag()
        let waiter = Task {
            try await arbiter.waitForLocalInferenceIdle()
            gate.set()
        }
        // The queued admission is observable state, not a sleep: it must be
        // registered and must not proceed while the session is open.
        let queued = await waitUntil { arbiter.linuxWaiterCount == 1 }
        #expect(queued)
        #expect(!gate.isSet)

        arbiter.endLocalInferenceSession()
        try await awaitWithin(waiter)
        #expect(gate.isSet)
        #expect(!arbiter.isLocalInferenceActive)
        #expect(arbiter.linuxWaiterCount == 0)
    }

    @Test("A waiting guest start is cancellable and never proceeds later")
    func guestStartWaitIsCancellable() async throws {
        let arbiter = HeavyRuntimeArbiter()
        arbiter.configure(
            activityProbe: emptyProbe(),
            guestStopper: { _ in },
            decisionHandler: allowHandler()
        )
        try await arbiter.beginLocalInferenceSession()

        let waiter = Task { try await arbiter.waitForLocalInferenceIdle() }
        #expect(await waitUntil { arbiter.linuxWaiterCount == 1 })
        waiter.cancel()
        do {
            try await awaitWithin(waiter)
            Issue.record("A cancelled wait must not return normally")
        } catch {
            #expect(error is CancellationError)
        }

        // Ending the session later must not resurrect the cancelled waiter.
        arbiter.endLocalInferenceSession()
        #expect(!arbiter.isLocalInferenceActive)
        #expect(arbiter.linuxWaiterCount == 0)
    }

    @Test("Active guests are reported and stopped only after confirmation")
    func guestsStopOnlyAfterConfirmation() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let log = OrderLog()
        arbiter.configure(
            activityProbe: {
                // Active until the stopper runs.
                log.recorded.contains("stop")
                    ? HeavyRuntimeArbiter.LinuxActivity()
                    : HeavyRuntimeArbiter.LinuxActivity(
                        guestEnvironmentIDs: ["env-1", "env-2"],
                        localServices: ["env-1:1"]
                    )
            },
            guestStopper: { activity in
                log.append("stop")
                #expect(activity.guestEnvironmentIDs == ["env-1", "env-2"])
            },
            decisionHandler: { activity in
                log.append("decide:\(activity.summary)")
                return .stopGuestsAndProceed
            },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(200)
        )

        let activity = try await arbiter.beginLocalInferenceSession()
        #expect(activity.guestEnvironmentIDs == ["env-1", "env-2"])
        // The decision precedes the stop: no guest is touched without it.
        #expect(log.recorded.first?.hasPrefix("decide:") == true)
        #expect(log.recorded.contains("stop"))
        #expect(arbiter.stoppedGuestCount == 2)
        #expect(arbiter.conflictCount == 1)
        arbiter.endLocalInferenceSession()
    }

    @Test("A declined conflict defers the local model and never stops a guest")
    func deferDecisionDoesNotStopGuests() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let log = OrderLog()
        arbiter.configure(
            activityProbe: {
                HeavyRuntimeArbiter.LinuxActivity(guestEnvironmentIDs: ["env-1"])
            },
            guestStopper: { _ in log.append("stop") },
            decisionHandler: { _ in .deferLocalModel }
        )

        do {
            try await arbiter.beginLocalInferenceSession()
            Issue.record("A deferred conflict must not return normally")
        } catch {
            #expect(error as? HeavyRuntimeArbiter.ArbiterError == .deferredByCaller)
        }
        #expect(log.recorded.isEmpty)
        // The refused session is released: Linux is not left waiting forever.
        #expect(!arbiter.isLocalInferenceActive)
    }

    @Test("Without a decision handler nothing is stopped and the request is refused")
    func missingHandlerRefusesWithoutStopping() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let log = OrderLog()
        arbiter.configure(
            activityProbe: {
                HeavyRuntimeArbiter.LinuxActivity(guestEnvironmentIDs: ["env-1"])
            },
            guestStopper: { _ in log.append("stop") }
        )

        do {
            try await arbiter.beginLocalInferenceSession()
            Issue.record("A conflict with no confirmable handler must be refused")
        } catch {
            #expect(error as? HeavyRuntimeArbiter.ArbiterError == .confirmationUnavailable)
        }
        #expect(log.recorded.isEmpty)
        #expect(!arbiter.isLocalInferenceActive)
    }

    @Test("A confirmed stop that never settles refuses the local request")
    func unsettledStopRefuses() async throws {
        let arbiter = HeavyRuntimeArbiter()
        arbiter.configure(
            activityProbe: {
                HeavyRuntimeArbiter.LinuxActivity(guestEnvironmentIDs: ["env-1"])
            },
            guestStopper: { _ in },
            decisionHandler: { _ in .stopGuestsAndProceed },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(60)
        )

        do {
            try await arbiter.beginLocalInferenceSession()
            Issue.record("A guest that never stops must not admit local inference")
        } catch {
            #expect(error as? HeavyRuntimeArbiter.ArbiterError == .linuxStopIncomplete)
        }
        #expect(!arbiter.isLocalInferenceActive)
    }

    @Test("No configured probe means no Linux activity and no report")
    func unconfiguredArbiterAdmitsLocally() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let activity = try await arbiter.beginLocalInferenceSession()
        #expect(activity.isEmpty)
        #expect(arbiter.conflictCount == 0)
        arbiter.endLocalInferenceSession()
        #expect(!arbiter.isLocalInferenceActive)
    }

    // MARK: - Atomic Linux-start reservation (B2)

    /// A probe with the same lease-based shape the app installs: union of
    /// reservations and admitted arbiter starts.
    private func leaseProbe(_ arbiter: HeavyRuntimeArbiter) -> HeavyRuntimeArbiter.ActivityProbe {
        {
            let ids = await arbiter.pendingLinuxStartEnvironmentIDs
            return HeavyRuntimeArbiter.LinuxActivity(guestEnvironmentIDs: ids)
        }
    }

    @Test("An admitted Linux start is visible to every racing local-model probe")
    func admittedStartVisibleToRacingBegins() async throws {
        let arbiter = HeavyRuntimeArbiter()
        arbiter.configure(
            activityProbe: leaseProbe(arbiter),
            guestStopper: { activity in
                for id in activity.guestEnvironmentIDs {
                    arbiter.releaseLinuxStart(environmentID: id)
                }
            },
            decisionHandler: { _ in .deferLocalModel }
        )

        // Admitted atomically with the (immediately satisfied) idle check.
        try await arbiter.waitForLocalInferenceIdle(registeringStart: "env-starting")
        #expect(arbiter.pendingLinuxStartEnvironmentIDs == ["env-starting"])

        // Every racing begin that runs while the registration is held must
        // report the starting guest — an empty snapshot is never allowed.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await arbiter.beginLocalInferenceSession()
                }
            }
        }
        #expect(arbiter.conflictCount == 8)
        #expect(!arbiter.isLocalInferenceActive)

        arbiter.releaseLinuxStart(environmentID: "env-starting")
        #expect(arbiter.pendingLinuxStartEnvironmentIDs.isEmpty)

        // After release a begin sees nothing: no phantom conflict.
        let quiet = try await arbiter.beginLocalInferenceSession()
        #expect(quiet.isEmpty)
        #expect(arbiter.conflictCount == 8)
        arbiter.endLocalInferenceSession()
    }

    @Test("A queued Linux start is never advertised as a stoppable VM")
    func queuedStartIsNotAdvertised() async throws {
        let arbiter = HeavyRuntimeArbiter()
        arbiter.configure(
            activityProbe: leaseProbe(arbiter),
            guestStopper: { _ in },
            decisionHandler: { _ in .deferLocalModel }
        )
        try await arbiter.beginLocalInferenceSession()

        let waiter = Task {
            try await arbiter.waitForLocalInferenceIdle(registeringStart: "env-queued")
        }
        #expect(await waitUntil { arbiter.linuxWaiterCount == 1 })
        // Queued: it owns no VM and must not be offered for a stop
        // confirmation that would deadlock a model continuation.
        #expect(arbiter.pendingLinuxStartEnvironmentIDs.isEmpty)

        arbiter.endLocalInferenceSession()
        try await awaitWithin(waiter)
        // Admitted only now, after the model session ended.
        #expect(arbiter.pendingLinuxStartEnvironmentIDs == ["env-queued"])
        arbiter.releaseLinuxStart(environmentID: "env-queued")
    }

    @Test("A wait cancelled before its waiter registers throws instead of dangling")
    func cancelBeforeRegisterThrows() async throws {
        let arbiter = HeavyRuntimeArbiter()
        arbiter.configure(
            activityProbe: emptyProbe(),
            guestStopper: { _ in },
            decisionHandler: allowHandler()
        )
        try await arbiter.beginLocalInferenceSession()

        // Park the task on a gate, cancel it while parked, then open the
        // gate: the wait enters with cancellation already set, i.e. the
        // cancel-before-register interleaving, deterministically.
        let gate = Gate()
        let waiter = Task {
            await gate.wait()
            try await arbiter.waitForLocalInferenceIdle()
        }
        waiter.cancel()
        gate.open()
        do {
            try await awaitWithin(waiter)
            Issue.record("A pre-cancelled wait must not return normally")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(arbiter.linuxWaiterCount == 0)
        #expect(arbiter.pendingLinuxStartEnvironmentIDs.isEmpty)

        arbiter.endLocalInferenceSession()
        #expect(!arbiter.isLocalInferenceActive)
    }

    @Test("A stop cancels a Linux start queued behind active inference")
    func stopCancelsQueuedStart() async throws {
        let arbiter = HeavyRuntimeArbiter()
        arbiter.configure(
            activityProbe: emptyProbe(),
            guestStopper: { _ in },
            decisionHandler: allowHandler()
        )
        try await arbiter.beginLocalInferenceSession()

        let waiter = Task {
            try await arbiter.waitForLocalInferenceIdle(registeringStart: "env-stopped")
        }
        #expect(await waitUntil { arbiter.linuxWaiterCount == 1 })

        // The registry's teardown path: a stop must reach the queued start
        // now, not when the model happens to finish.
        arbiter.cancelLinuxStart(environmentID: "env-stopped")
        do {
            try await awaitWithin(waiter)
            Issue.record("A cancelled queued start must throw")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(arbiter.linuxWaiterCount == 0)
        #expect(arbiter.pendingLinuxStartEnvironmentIDs.isEmpty)
        // The still-active session is untouched by the start cancellation.
        #expect(arbiter.isLocalInferenceActive)
        arbiter.endLocalInferenceSession()
    }

    @Test("A start that fails after admission releases its lease on every exit path")
    func failedStartReleasesLease() async throws {
        let arbiter = HeavyRuntimeArbiter()
        arbiter.configure(
            activityProbe: leaseProbe(arbiter),
            guestStopper: { _ in },
            decisionHandler: { _ in .deferLocalModel }
        )

        // Admitted (idle check passed, registration recorded), then the start
        // fails before publishing its guest reservation: the registry's defer
        // releases the registration.
        try await arbiter.waitForLocalInferenceIdle(registeringStart: "env-failed")
        #expect(arbiter.pendingLinuxStartEnvironmentIDs == ["env-failed"])
        arbiter.releaseLinuxStart(environmentID: "env-failed")
        // Idempotent on the failure path.
        arbiter.releaseLinuxStart(environmentID: "env-failed")
        #expect(arbiter.pendingLinuxStartEnvironmentIDs.isEmpty)

        // Once released, admission is quiet again.
        let activity = try await arbiter.beginLocalInferenceSession()
        #expect(activity.isEmpty)
        #expect(arbiter.conflictCount == 0)
        arbiter.endLocalInferenceSession()
    }

    @Test("An idle but mapped model blocks Linux until the release is verified")
    func idleResidentBlocksAdmissionUntilVerified() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let gate = Gate()
        let drain = ScriptedDrain([
            {
                await gate.wait()
                return .released(modelID: "test-model")
            }
        ])
        arbiter.configure(
            activityProbe: leaseProbe(arbiter),
            guestStopper: { _ in },
            decisionHandler: { _ in .deferLocalModel },
            idleDrainHandler: { await drain.next() }
        )

        // One model session ran and ended: the process may still hold the
        // mapping even though no session is active.
        try await arbiter.beginLocalInferenceSession()
        arbiter.endLocalInferenceSession()
        #expect(!arbiter.isLocalInferenceActive)

        let resumed = Flag()
        let waiter = Task {
            try await arbiter.waitForLocalInferenceIdle(registeringStart: "env-idle-resident")
            resumed.set()
        }
        // The drain must run and the arrival must stay queued behind it.
        #expect(await waitUntil { arbiter.isLinuxDrainInFlight })
        #expect(!resumed.isSet)
        #expect(arbiter.pendingLinuxStartEnvironmentIDs.isEmpty)

        gate.open()
        try await awaitWithin(waiter)
        #expect(resumed.isSet)
        #expect(drain.callCount == 1)
        #expect(arbiter.pendingLinuxStartEnvironmentIDs == ["env-idle-resident"])
        arbiter.releaseLinuxStart(environmentID: "env-idle-resident")
    }

    @Test("A model retained by a durable task keeps Linux queued until released")
    func retainedDrainKeepsWaitingThenAdmits() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let gate = Gate()
        let drain = ScriptedDrain([
            { .retained },
            {
                // The retry parks here: the test controls exactly when the
                // claim is observed as gone, so "not admitted after a
                // retained verdict" is a state assertion, not a race.
                await gate.wait()
                return .nothingResident
            }
        ])
        arbiter.configure(
            activityProbe: leaseProbe(arbiter),
            guestStopper: { _ in },
            decisionHandler: { _ in .deferLocalModel },
            idleDrainHandler: { await drain.next() },
            drainRetryInterval: .milliseconds(1)
        )
        try await arbiter.beginLocalInferenceSession()
        arbiter.endLocalInferenceSession()

        let resumed = Flag()
        let waiter = Task {
            try await arbiter.waitForLocalInferenceIdle(registeringStart: "env-retained")
            resumed.set()
        }
        // First outcome is .retained, second verdict is parked: the mapping
        // is still claimed, so the guest must not be admitted.
        #expect(await waitUntil { drain.callCount == 2 })
        #expect(!resumed.isSet)
        #expect(arbiter.pendingLinuxStartEnvironmentIDs.isEmpty)

        // The claim goes away; the retry verifies and admits.
        gate.open()
        try await awaitWithin(waiter)
        #expect(resumed.isSet)
        #expect(drain.callCount == 2)
        #expect(arbiter.pendingLinuxStartEnvironmentIDs == ["env-retained"])
        arbiter.releaseLinuxStart(environmentID: "env-retained")
    }

    @Test("A retention that outlasts the drain budget refuses Linux with an actionable error")
    func retainedPastBudgetRefusesTruthfully() async throws {
        let arbiter = HeavyRuntimeArbiter()
        // A durable task keeps the model claimed past the budget: Linux must
        // fail recoverably instead of waiting forever (the task could itself
        // be waiting for this Linux tool).
        let drain = ScriptedDrain([{ .retained }])
        arbiter.configure(
            activityProbe: leaseProbe(arbiter),
            guestStopper: { _ in },
            decisionHandler: { _ in .deferLocalModel },
            idleDrainHandler: { await drain.next() },
            drainRetryInterval: .milliseconds(5),
            drainRetainTimeout: .milliseconds(60)
        )
        try await arbiter.beginLocalInferenceSession()
        arbiter.endLocalInferenceSession()

        do {
            try await arbiter.waitForLocalInferenceIdle(registeringStart: "env-retained-too-long")
            Issue.record("A permanently retained model must refuse Linux admission")
        } catch {
            #expect(error as? HeavyRuntimeArbiter.ArbiterError == .linuxModelRetained)
        }
        #expect(drain.callCount >= 2)
        #expect(arbiter.linuxWaiterCount == 0)
        #expect(!arbiter.isLinuxDrainInFlight)
        #expect(arbiter.pendingLinuxStartEnvironmentIDs.isEmpty)
        #expect(!arbiter.isLocalInferenceActive)
    }

    @Test("Concurrent Linux arrivals share one drain and all wait for its verdict")
    func concurrentArrivalsShareOneDrain() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let gate = Gate()
        let drain = ScriptedDrain([
            {
                await gate.wait()
                return .released(modelID: "test-model")
            }
        ])
        arbiter.configure(
            activityProbe: leaseProbe(arbiter),
            guestStopper: { _ in },
            decisionHandler: { _ in .deferLocalModel },
            idleDrainHandler: { await drain.next() }
        )
        try await arbiter.beginLocalInferenceSession()
        arbiter.endLocalInferenceSession()

        let resumed = OrderLog()
        let first = Task {
            try await arbiter.waitForLocalInferenceIdle(registeringStart: "env-a")
            resumed.append("a")
        }
        #expect(await waitUntil { arbiter.isLinuxDrainInFlight })
        let second = Task {
            try await arbiter.waitForLocalInferenceIdle(registeringStart: "env-b")
            resumed.append("b")
        }
        #expect(await waitUntil { arbiter.linuxWaiterCount == 2 })
        // Both arrivals queue behind the single in-flight drain.
        #expect(drain.callCount == 1)
        #expect(resumed.recorded.isEmpty)

        gate.open()
        try await awaitWithin(first)
        try await awaitWithin(second)
        #expect(drain.callCount == 1)
        #expect(resumed.recorded.sorted() == ["a", "b"])
        #expect(arbiter.pendingLinuxStartEnvironmentIDs == ["env-a", "env-b"])
        arbiter.releaseLinuxStart(environmentID: "env-a")
        arbiter.releaseLinuxStart(environmentID: "env-b")
    }

    @Test("A session that begins while the drain runs re-blocks the queued starts")
    func newSessionDuringDrainReblocksWaiters() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let gate = Gate()
        let resumed = Flag()
        let drain = ScriptedDrain([
            {
                await gate.wait()
                return .released(modelID: "first")
            },
            { .nothingResident }
        ])
        arbiter.configure(
            activityProbe: leaseProbe(arbiter),
            guestStopper: { _ in },
            decisionHandler: { _ in .deferLocalModel },
            idleDrainHandler: { await drain.next() },
            drainRetryInterval: .milliseconds(1)
        )
        try await arbiter.beginLocalInferenceSession()
        arbiter.endLocalInferenceSession()

        let waiter = Task {
            try await arbiter.waitForLocalInferenceIdle(registeringStart: "env-blocked")
            resumed.set()
        }
        #expect(await waitUntil { arbiter.isLinuxDrainInFlight })

        // A new model session begins while the drain is mid-flight: the
        // verified release must NOT admit the queued guest.
        try await arbiter.beginLocalInferenceSession()
        gate.open()
        // The cycle ends because a session is active again — an observable
        // state, not a sleep — and the guest is still queued.
        #expect(await waitUntil { !arbiter.isLinuxDrainInFlight })
        #expect(drain.callCount == 1)
        #expect(!resumed.isSet)
        #expect(arbiter.pendingLinuxStartEnvironmentIDs.isEmpty)

        arbiter.endLocalInferenceSession()
        try await awaitWithin(waiter)
        #expect(resumed.isSet)
        #expect(drain.callCount == 2)
        #expect(arbiter.pendingLinuxStartEnvironmentIDs == ["env-blocked"])
        arbiter.releaseLinuxStart(environmentID: "env-blocked")
    }

    @Test("A verdict from before a newer session began is stale: re-drained, never applied")
    func staleVerdictIsDiscardedAndRedrained() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let gate = Gate()
        let drain = ScriptedDrain([
            {
                // Suspended verifier: its release evidence was taken before
                // the session below ever mapped.
                await gate.wait()
                return .released(modelID: "old")
            },
            { .released(modelID: "new") }
        ])
        arbiter.configure(
            activityProbe: leaseProbe(arbiter),
            guestStopper: { _ in },
            decisionHandler: { _ in .deferLocalModel },
            idleDrainHandler: { await drain.next() },
            drainRetryInterval: .milliseconds(1)
        )
        try await arbiter.beginLocalInferenceSession()
        arbiter.endLocalInferenceSession()

        let resumed = Flag()
        let waiter = Task {
            try await arbiter.waitForLocalInferenceIdle(registeringStart: "env-aba")
            resumed.set()
        }
        #expect(await waitUntil { arbiter.isLinuxDrainInFlight })

        // A full begin+end while the verifier is suspended: the newer
        // mapping came and went without the suspended verdict observing it,
        // so that verdict must not clear residency or admit the guest.
        try await arbiter.beginLocalInferenceSession()
        arbiter.endLocalInferenceSession()
        gate.open()
        // The stale verdict is discarded and the queue re-drained; only the
        // verdict taken against the current residency admits.
        try await awaitWithin(waiter)
        #expect(resumed.isSet)
        #expect(drain.callCount == 2)
        #expect(arbiter.pendingLinuxStartEnvironmentIDs == ["env-aba"])
        arbiter.releaseLinuxStart(environmentID: "env-aba")
    }

    @Test("Stop failure keeps the guest truthful: no forced quarantine clear, no admission")
    func stopFailureRefusesAdmissionWithoutForceClear() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let log = OrderLog()
        // The stopper releases the admitted-start lease (the start is gone)
        // but the reservation probe keeps reporting the environment — exactly
        // what a stop-quarantined guest looks like: its slot and disk stay
        // owned, so local inference must be refused, never admitted over it.
        let probe: HeavyRuntimeArbiter.ActivityProbe = {
            log.recorded.contains("released")
                ? HeavyRuntimeArbiter.LinuxActivity(guestEnvironmentIDs: ["env-quarantined"])
                : HeavyRuntimeArbiter.LinuxActivity(guestEnvironmentIDs: ["env-booting"])
        }
        arbiter.configure(
            activityProbe: probe,
            guestStopper: { activity in
                #expect(activity.guestEnvironmentIDs == ["env-booting"])
                log.append("stop")
                for id in activity.guestEnvironmentIDs {
                    arbiter.releaseLinuxStart(environmentID: id)
                }
                log.append("released")
            },
            decisionHandler: { _ in .stopGuestsAndProceed },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(60)
        )

        try await arbiter.waitForLocalInferenceIdle(registeringStart: "env-booting")
        do {
            try await arbiter.beginLocalInferenceSession()
            Issue.record("A guest that never finished stopping must not admit local inference")
        } catch {
            #expect(error as? HeavyRuntimeArbiter.ArbiterError == .linuxStopIncomplete)
        }
        // The quarantined environment was reported again after the stopper
        // ran: nothing was force-cleared to make the test pass.
        #expect(log.recorded.contains("stop"))
        #expect(arbiter.pendingLinuxStartEnvironmentIDs.isEmpty)
        #expect(!arbiter.isLocalInferenceActive)
    }

    @Test("Bidirectional contention settles without phantom state")
    func bidirectionalContentionSweep() async throws {
        for round in 0..<16 {
            let arbiter = HeavyRuntimeArbiter()
            arbiter.configure(
                activityProbe: leaseProbe(arbiter),
                guestStopper: { _ in },
                decisionHandler: { _ in .deferLocalModel },
                settleInterval: .milliseconds(1),
                settleTimeout: .milliseconds(50)
            )
            let environmentID = "env-\(round)"
            try await arbiter.beginLocalInferenceSession()
            let linuxWait = Task {
                try await arbiter.waitForLocalInferenceIdle(registeringStart: environmentID)
            }
            if round % 2 == 0 {
                #expect(await waitUntil { arbiter.linuxWaiterCount == 1 })
            }
            let inference = Task {
                try? await arbiter.beginLocalInferenceSession()
            }
            if round % 2 == 1 {
                #expect(await waitUntil { arbiter.linuxWaiterCount == 1 })
            }
            // Let the racing begin finish (it either returns or is deferred —
            // it can add a session, never hang), then drain every session the
            // round actually holds so the guest start is admitted: whichever
            // interleaving ran, both sides settle.
            _ = await inference.value
            for _ in 0..<4 where arbiter.activeInferenceSessionCount > 0 {
                arbiter.endLocalInferenceSession()
            }
            try await awaitWithin(linuxWait)
            // Whichever interleaving ran, the admitted guest start holds its
            // registration until its owner releases it and the session
            // accounting is back to zero — no phantom waiters, no leak.
            #expect(arbiter.activeInferenceSessionCount == 0)
            #expect(arbiter.linuxWaiterCount == 0)
            arbiter.releaseLinuxStart(environmentID: environmentID)
            #expect(arbiter.pendingLinuxStartEnvironmentIDs.isEmpty)
        }
    }

    // MARK: logical-run ownership: own transient guest vs real conflict

    @Test("A run's own transient tool guest is released without a user decision")
    func ownTransientGuestIsAutoReleased() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let log = OrderLog()
        let released = Flag()
        let runID = UUID()
        arbiter.configure(
            activityProbe: {
                released.isSet
                    ? HeavyRuntimeArbiter.LinuxActivity()
                    : HeavyRuntimeArbiter.LinuxActivity(
                        guestEnvironmentIDs: ["env-own"],
                        guests: [HeavyRuntimeArbiter.LinuxGuestActivity(
                            environmentID: "env-own",
                            ownerRunID: runID.uuidString,
                            isTransientToolGuest: true
                        )]
                    )
            },
            guestStopper: { _ in log.append("confirmedStop") },
            decisionHandler: { _ in
                log.append("decide")
                return .deferLocalModel
            },
            transientGuestReleaser: { activity in
                log.append("release:\(activity.guestEnvironmentIDs.joined(separator: ","))")
                released.set()
            },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(200)
        )

        let activity = try await arbiter.beginLocalInferenceSession(requestingRunID: runID)
        #expect(activity.guestEnvironmentIDs == ["env-own"])
        // Only the scoped release ran: no user decision, no confirmed stop.
        #expect(log.recorded == ["release:env-own"])
        #expect(arbiter.autoReleaseAttemptCount == 1)
        #expect(arbiter.autoReleasedGuestCount == 1)
        #expect(arbiter.conflictCount == 0)
        #expect(arbiter.stoppedGuestCount == 0)
        #expect(arbiter.isLocalInferenceActive)
        arbiter.endLocalInferenceSession()
    }

    @Test("A foreign run's transient guest is never auto-released")
    func foreignRunTransientGuestIsNeverAutoReleased() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let log = OrderLog()
        let released = Flag()
        let requestingRun = UUID()
        let otherRun = UUID()
        arbiter.configure(
            activityProbe: {
                released.isSet
                    ? HeavyRuntimeArbiter.LinuxActivity()
                    : HeavyRuntimeArbiter.LinuxActivity(
                        guestEnvironmentIDs: ["env-other"],
                        guests: [HeavyRuntimeArbiter.LinuxGuestActivity(
                            environmentID: "env-other",
                            ownerRunID: otherRun.uuidString,
                            isTransientToolGuest: true
                        )]
                    )
            },
            guestStopper: { _ in
                log.append("stop")
                released.set()
            },
            decisionHandler: { _ in
                log.append("decide")
                return .stopGuestsAndProceed
            },
            transientGuestReleaser: { _ in log.append("release") },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(200)
        )

        _ = try await arbiter.beginLocalInferenceSession(requestingRunID: requestingRun)
        #expect(log.recorded == ["decide", "stop"])
        #expect(arbiter.autoReleaseAttemptCount == 0)
        #expect(arbiter.autoReleasedGuestCount == 0)
        #expect(arbiter.stoppedGuestCount == 1)
        arbiter.endLocalInferenceSession()
    }

    @Test("A live service keeps the explicit decision even for the run's own guest")
    func ownGuestWithServiceStillRequiresConfirmation() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let log = OrderLog()
        let released = Flag()
        let runID = UUID()
        arbiter.configure(
            activityProbe: {
                released.isSet
                    ? HeavyRuntimeArbiter.LinuxActivity()
                    : HeavyRuntimeArbiter.LinuxActivity(
                        guestEnvironmentIDs: ["env-own"],
                        localServices: ["env-own:1"],
                        guests: [HeavyRuntimeArbiter.LinuxGuestActivity(
                            environmentID: "env-own",
                            ownerRunID: runID.uuidString,
                            isTransientToolGuest: true
                        )]
                    )
            },
            guestStopper: { _ in
                log.append("stop")
                released.set()
            },
            decisionHandler: { _ in
                log.append("decide")
                return .stopGuestsAndProceed
            },
            transientGuestReleaser: { _ in log.append("release") },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(200)
        )

        _ = try await arbiter.beginLocalInferenceSession(requestingRunID: runID)
        #expect(log.recorded == ["decide", "stop"])
        #expect(arbiter.autoReleaseAttemptCount == 0)
        #expect(arbiter.autoReleasedGuestCount == 0)
        #expect(arbiter.stoppedGuestCount == 1)
        arbiter.endLocalInferenceSession()
    }

    @Test("A refused scoped release falls back to the explicit decision, never to overlap")
    func refusedAutoReleaseFallsBackToConfirmation() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let log = OrderLog()
        let stopped = Flag()
        let runID = UUID()
        arbiter.configure(
            activityProbe: {
                stopped.isSet
                    ? HeavyRuntimeArbiter.LinuxActivity()
                    : HeavyRuntimeArbiter.LinuxActivity(
                        guestEnvironmentIDs: ["env-own"],
                        guests: [HeavyRuntimeArbiter.LinuxGuestActivity(
                            environmentID: "env-own",
                            ownerRunID: runID.uuidString,
                            isTransientToolGuest: true
                        )]
                    )
            },
            guestStopper: { _ in
                log.append("stop")
                stopped.set()
            },
            decisionHandler: { _ in
                log.append("decide")
                return .stopGuestsAndProceed
            },
            // Refuses: the guest stays reported, so the arbiter must not
            // admit the model behind it.
            transientGuestReleaser: { _ in log.append("release") },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(40),
            autoReleaseSettleTimeout: .milliseconds(40)
        )

        _ = try await arbiter.beginLocalInferenceSession(requestingRunID: runID)
        #expect(log.recorded == ["release", "decide", "stop"])
        #expect(arbiter.autoReleaseAttemptCount == 1)
        #expect(arbiter.autoReleasedGuestCount == 0)
        #expect(arbiter.stoppedGuestCount == 1)
        #expect(arbiter.conflictCount == 1)
        arbiter.endLocalInferenceSession()
    }

    @Test("Without a requesting run id the confirmation path is unchanged")
    func missingRequestingRunKeepsConfirmation() async throws {
        let arbiter = HeavyRuntimeArbiter()
        let log = OrderLog()
        let released = Flag()
        arbiter.configure(
            activityProbe: {
                released.isSet
                    ? HeavyRuntimeArbiter.LinuxActivity()
                    : HeavyRuntimeArbiter.LinuxActivity(
                        guestEnvironmentIDs: ["env-own"],
                        guests: [HeavyRuntimeArbiter.LinuxGuestActivity(
                            environmentID: "env-own",
                            ownerRunID: UUID().uuidString,
                            isTransientToolGuest: true
                        )]
                    )
            },
            guestStopper: { _ in
                log.append("stop")
                released.set()
            },
            decisionHandler: { _ in
                log.append("decide")
                return .stopGuestsAndProceed
            },
            transientGuestReleaser: { _ in log.append("release") },
            settleInterval: .milliseconds(1),
            settleTimeout: .milliseconds(200)
        )

        // Legacy callers that cannot name their run keep the explicit path.
        _ = try await arbiter.beginLocalInferenceSession()
        #expect(log.recorded == ["decide", "stop"])
        #expect(arbiter.autoReleasedGuestCount == 0)
        arbiter.endLocalInferenceSession()
    }
}
