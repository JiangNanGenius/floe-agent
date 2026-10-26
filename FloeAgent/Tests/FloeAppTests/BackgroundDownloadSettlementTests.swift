// FloeAppTests — background download event settlement contract.
//
// These pin the exact settlement semantics the historical crash/data-loss
// bugs violated: the system completion must fire EXACTLY ONCE, on the MAIN
// thread, only after BOTH `urlSessionDidFinishEvents` AND every registered
// async settle/retry event has drained — in any registration order, across
// nested events, on error paths, and again for the NEXT wake. The
// JobDownloadCoordinator delayed-retry re-check (state + generation AFTER
// the sleep, before `.resume()`) is pinned at the same level.

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeCore
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.BackgroundDownloadEventSettlement")
struct BackgroundDownloadSettlementTests {
    /// Test-only recorder. All mutations from the completion path land on
    /// the main thread by construction (that is the property under test).
    private final class FireBox: @unchecked Sendable {
        private(set) var count = 0
        private(set) var firedOnMain = false
        func record() {
            count += 1
            firedOnMain = Thread.isMainThread
        }
    }

    private func waitUntil(
        _ condition: @Sendable () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<5_000 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("condition not reached", file: file, line: line)
    }

    @MainActor
    @Test("The completion waits for the async settle/drain, not just the finish event")
    func finishWaitsForPendingSettle() async {
        let settlement = BackgroundDownloadEventSettlement(name: "test")
        let box = FireBox()
        settlement.beginEvent()
        settlement.registerSystemCompletionHandler { box.record() }
        settlement.sessionDidFinishEvents()
        for _ in 0..<50 { await Task.yield() }
        #expect(box.count == 0, "finish-before-settle was the historical bug: the wake must not be released while a registered settle is still draining")
        settlement.endEvent()
        #expect(box.count == 1)
    }

    @MainActor
    @Test("Nested events decide together; the completion fires after the LAST end")
    func nestedEvents() {
        let settlement = BackgroundDownloadEventSettlement(name: "test")
        let box = FireBox()
        settlement.registerSystemCompletionHandler { box.record() }
        settlement.beginEvent()
        settlement.beginEvent()
        settlement.sessionDidFinishEvents()
        settlement.endEvent()
        #expect(box.count == 0)
        settlement.endEvent()
        #expect(box.count == 1)
    }

    @MainActor
    @Test("Error paths drain: an event ended from a failure route still releases the wake")
    func errorPathDrains() async {
        let settlement = BackgroundDownloadEventSettlement(name: "test")
        let box = FireBox()
        settlement.registerSystemCompletionHandler { box.record() }
        settlement.beginEvent()
        // Simulated settle throw: the deferred endEvent still runs.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { settlement.endEvent() }
        }
        settlement.sessionDidFinishEvents()
        #expect(box.count == 1)
    }

    @MainActor
    @Test("A repeated finish signal never re-releases the same wake; an early registration still waits for the drain")
    func repeatedFinishAndEarlyRegistration() {
        let settlement = BackgroundDownloadEventSettlement(name: "test")
        let box = FireBox()
        // Registration BEFORE the finish signal and before the last end.
        settlement.registerSystemCompletionHandler { box.record() }
        settlement.beginEvent()
        settlement.sessionDidFinishEvents()
        #expect(box.count == 0)
        settlement.sessionDidFinishEvents() // repeated finish signal
        settlement.endEvent()
        #expect(box.count == 1)
        // A third (duplicate) finish for the released wake must be IGNORED:
        // it cannot fabricate a new system-done cycle — see the exact
        // wake2-registration-pending test below for the unsafe history.
        settlement.sessionDidFinishEvents()
        let state = settlement.settlementStateForTesting
        #expect(state.wakeGeneration == 1)
        #expect(state.fired)
        #expect(state.systemDone)
        #expect(!state.hasHandler)
        #expect(box.count == 1)
    }

    @MainActor
    @Test("wake1 completed -> duplicate finish -> wake2 registration stays PENDING until wake2's own begin/finish/drain")
    func duplicateFinishCannotPreSatisfyNextWake() {
        let settlement = BackgroundDownloadEventSettlement(name: "test")
        let box = FireBox()
        // Wake 1: register, finish, nothing pending -> released.
        settlement.registerSystemCompletionHandler { box.record() }
        settlement.sessionDidFinishEvents()
        #expect(box.count == 1)
        // A late DUPLICATE finish signal for wake 1 arrives.
        settlement.sessionDidFinishEvents()
        // Now the next launch registers wake 2's handler. Under the unsafe
        // model (fabricating a system-done cycle from the repeated finish)
        // this registration would fire immediately, before wake 2's real
        // finish — releasing the process while its event batch is still
        // about to arrive. The second handler must stay PENDING instead.
        settlement.registerSystemCompletionHandler { box.record() }
        #expect(box.count == 1, "a wake2 handler may never fire before wake2's own finish signal")
        var state = settlement.settlementStateForTesting
        #expect(state.wakeGeneration == 2)
        #expect(!state.systemDone)
        #expect(state.hasHandler)
        // Wake 2's real cycle now runs: event, finish, drain.
        settlement.beginEvent()
        settlement.sessionDidFinishEvents()
        #expect(box.count == 1)
        settlement.endEvent()
        #expect(box.count == 2)
        state = settlement.settlementStateForTesting
        #expect(state.wakeGeneration == 2)
        #expect(state.fired)
    }

    @MainActor
    @Test("Events arriving with no stored handler still count; a spurious endEvent clamps instead of going negative")
    func noHandlerCountingIsSafe() {
        let settlement = BackgroundDownloadEventSettlement(name: "test")
        let box = FireBox()
        settlement.beginEvent()
        settlement.endEvent()
        settlement.endEvent() // extra end must clamp, never go negative
        #expect(settlement.settlementStateForTesting.pending == 0)
        #expect(!settlement.settlementStateForTesting.fired)
        settlement.registerSystemCompletionHandler { box.record() }
        settlement.sessionDidFinishEvents()
        #expect(box.count == 1)
    }

    @MainActor
    @Test("A beginEvent racing the release lands on the NEXT wake and never re-releases or corrupts the fired one")
    func beginVsCompletionRace() async {
        let settlement = BackgroundDownloadEventSettlement(name: "test")
        let box = FireBox()
        settlement.registerSystemCompletionHandler { box.record() }
        settlement.beginEvent()
        settlement.sessionDidFinishEvents()
        // `endEvent` off-main atomically decides + flips the fired flag and
        // queues the main hop; a `beginEvent` that lands immediately after
        // (before main drains) must belong to a NEW wake — the historical
        // shape checked readiness, then re-checked nothing, so the same
        // interleaving released the wake with an event outstanding.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                settlement.endEvent()
                settlement.beginEvent()
                continuation.resume()
            }
        }
        await waitUntil { box.count == 1 }
        #expect(box.count == 1)
        #expect(box.firedOnMain)
        let state = settlement.settlementStateForTesting
        #expect(state.wakeGeneration == 2)
        #expect(state.pending == 1)
        #expect(!state.fired)
        // Wake 2 needs its own finish, drain AND handler.
        settlement.sessionDidFinishEvents()
        settlement.endEvent()
        #expect(box.count == 1, "a drained next wake without a stored handler must not fire")
        settlement.registerSystemCompletionHandler { box.record() }
        #expect(box.count == 2)
        #expect(settlement.settlementStateForTesting.wakeGeneration == 2)
    }

    @MainActor
    @Test("A next-wake event arriving before that wake's handler is attributed to the new cycle, never wiped")
    func eventBeforeHandlerOnNextWake() {
        let settlement = BackgroundDownloadEventSettlement(name: "test")
        let box = FireBox()
        settlement.registerSystemCompletionHandler { box.record() }
        settlement.sessionDidFinishEvents()
        #expect(box.count == 1)
        // The system hands this live process new completions BEFORE any
        // next launch hook arrives: the events must roll into a fresh wake
        // (the shared reset in the old `register` used to wipe exactly this
        // window: begin landed on the fired wake, then `state = State()`
        // discarded the count).
        settlement.beginEvent()
        settlement.sessionDidFinishEvents()
        var state = settlement.settlementStateForTesting
        #expect(state.wakeGeneration == 2)
        #expect(state.pending == 1)
        #expect(state.systemDone)
        settlement.endEvent()
        state = settlement.settlementStateForTesting
        #expect(state.pending == 0)
        #expect(!state.fired)
        #expect(box.count == 1)
        // Late registration fires the already-drained wake.
        settlement.registerSystemCompletionHandler { box.record() }
        #expect(box.count == 2)
    }

    @MainActor
    @Test("A stray end after the release is ignored; it cannot decrement a wake it never began")
    func strayEndAfterReleaseIsIgnored() {
        let settlement = BackgroundDownloadEventSettlement(name: "test")
        let box = FireBox()
        settlement.registerSystemCompletionHandler { box.record() }
        settlement.beginEvent()
        settlement.sessionDidFinishEvents()
        settlement.endEvent()
        #expect(box.count == 1)
        // Wake 1's only end has landed; a duplicated late end (the shape a
        // double-delivered cancel drain would produce) must not touch any
        // later wake's bookkeeping.
        settlement.endEvent()
        #expect(box.count == 1)
        settlement.beginEvent()
        #expect(settlement.settlementStateForTesting.pending == 1)
    }

    @MainActor
    @Test("LATE HANDLER + BOOTSTRAP: the atomic wrapper tracks the bootstrap BEFORE storing the handler, so an already-drained wake cannot fire early and orphan it")
    func bootstrapWithLateHandlerIsAtomic() async {
        let settlement = BackgroundDownloadEventSettlement(name: "test")
        let box = FireBox()
        let flag = BootstrapFlag()
        // The whole delegate batch already drained AND the system reported
        // finish BEFORE the launch hook got to run (the late-handler case).
        settlement.beginEvent()
        settlement.endEvent()
        settlement.sessionDidFinishEvents()
        // Under the broken order (register, then trackBootstrap) the register
        // would fire the completion immediately and the bootstrap would land
        // on a NEXT wake nobody releases in time. The atomic wrapper must
        // register the pending bootstrap slot first.
        settlement.registerSystemCompletionHandler({ box.record() }) {
            try? await Task.sleep(nanoseconds: 30_000_000)
            flag.done = true
        }
        // The handler must NOT have fired yet: the bootstrap is in flight.
        #expect(box.count == 0)
        #expect(settlement.settlementStateForTesting.pending == 1)
        await waitUntil { flag.done }
        await waitUntil { box.count == 1 }
        #expect(box.count == 1, "completion fires exactly once, only after the tracked bootstrap drained")
        #expect(box.firedOnMain)
    }

    @MainActor
    @Test("trackBootstrap BEFORE register keeps the bootstrap inside the same wake (documented standalone ordering)")
    func bootstrapBeforeRegister() async {
        let settlement = BackgroundDownloadEventSettlement(name: "test")
        let box = FireBox()
        let flag = BootstrapFlag()
        settlement.trackBootstrap {
            try? await Task.sleep(nanoseconds: 10_000_000)
            flag.done = true
        }
        // Pending bootstrap blocks any immediate fire at registration.
        settlement.registerSystemCompletionHandler { box.record() }
        settlement.sessionDidFinishEvents()
        #expect(box.count == 0)
        await waitUntil { box.count == 1 }
        #expect(flag.done)
        #expect(box.count == 1)
        #expect(box.firedOnMain)
    }

    private final class BootstrapFlag: @unchecked Sendable {
        var done = false
    }

    @MainActor
    @Test("The delayed auto-retry re-checks durable state AND ownership generation after the sleep, before resume")
    func retryRecheckContract() {
        // The exact decision the coordinator makes immediately before
        // `.resume()` — the historical bug checked only BEFORE the sleep.
        #expect(JobDownloadCoordinator.shouldResumeAfterRetryDelay(
            jobState: .running,
            generationAtScheduling: 3,
            generationNow: 3,
            retryTaskCancelled: false))
        // Cancelled job → never resume.
        #expect(!JobDownloadCoordinator.shouldResumeAfterRetryDelay(
            jobState: .cancelled,
            generationAtScheduling: 3,
            generationNow: 3,
            retryTaskCancelled: false))
        // Missing row (job removed) → never resume.
        #expect(!JobDownloadCoordinator.shouldResumeAfterRetryDelay(
            jobState: nil,
            generationAtScheduling: 3,
            generationNow: 3,
            retryTaskCancelled: false))
        // Cancel bumped the ownership generation while the task slept.
        #expect(!JobDownloadCoordinator.shouldResumeAfterRetryDelay(
            jobState: .running,
            generationAtScheduling: 3,
            generationNow: 4,
            retryTaskCancelled: false))
        // The owned retry task itself was cancelled by jobs.cancel.
        #expect(!JobDownloadCoordinator.shouldResumeAfterRetryDelay(
            jobState: .running,
            generationAtScheduling: 3,
            generationNow: 3,
            retryTaskCancelled: true))
    }
}
#endif
