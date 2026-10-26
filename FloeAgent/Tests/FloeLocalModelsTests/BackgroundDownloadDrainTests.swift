// Focused regression for the model-download background event settlement in
// FloeLocalModelCatalog. These drive the REAL entry points — the actual
// `ComponentDownloadDelegate` URLSession callbacks, the real per-identifier
// `FloeCore.BackgroundDownloadEventSettlement` instances resolved through
// `LocalModelDownloadSettlements`, the real launch-hook facade
// (`LocalModelBackgroundEvents.register` on iOS), the real
// `ModelDownloadSettlementLedger` pairing and the real primitive — instead
// of duplicating the drain logic:
//   • an underway verification/settle holds the system completion (the
//     premature-OS-completion bug),
//   • the successful operation-tail drain releases exactly once on main,
//   • failed/cancelled transfers settle through the same pairing,
//   • a late handler for an already-drained finished wake fires immediately,
//   • two session identifiers never share a wake (no cross-hold/release),
//   • next-wake ordering: a stale duplicate finish cannot pre-satisfy the
//     new wake's handler,
//   • a `began` that lands after the drain self-pairs and cannot strand a
//     future wake.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
// `settlementStateForTesting` is internal to FloeCore; @testable is required
// to read the primitive's diagnostics tuple while driving real entries.
@testable import FloeCore
@testable import FloeLocalModelCatalog

private final class FireTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var firedCount = 0
    private var mainThread = false
    var count: Int { lock.withLock { firedCount } }
    var onMain: Bool { lock.withLock { mainThread } }
    func record() { lock.withLock { firedCount += 1; mainThread = Thread.isMainThread } }
}

private struct DrainTimeout: Error {}

private func settleWait(
    _ predicate: @escaping @Sendable () -> Bool,
    timeoutMilliseconds: Int = 2_000
) async throws {
    var waited = 0
    while !predicate() {
        if waited >= timeoutMilliseconds { throw DrainTimeout() }
        try await Task.sleep(for: .milliseconds(5))
        waited += 5
    }
}

private func uniqueTestIdentifier(_ tag: String) -> String {
    "org.floeagent.local-model.drain-test.\(tag).\(UUID().uuidString)"
}

/// Deterministic gate for the bounded-bootstrap tests: the lease stays
/// pending until the test opens it, so "no fire while readiness runs" has
/// no scheduler race.
private final class GateFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func openGate() { lock.withLock { isOpen = true } }
    func waitUntilOpen() async {
        while !(lock.withLock { isOpen }) {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// Registers the system completion through the REAL iOS launch-hook entry
/// (what `AppDelegate.handleEventsForBackgroundURLSession` calls); on
/// non-iOS hosts the facade does not exist and the same primitive entry is
/// used directly.
private func registerSystemCompletion(
    identifier: String,
    settlement: BackgroundDownloadEventSettlement,
    handler: @escaping () -> Void
) {
    #if os(iOS)
    LocalModelBackgroundEvents.shared.register(identifier: identifier, completion: handler)
    #else
    settlement.registerSystemCompletionHandler(handler)
    #endif
}

@Suite("FloeLocalModelCatalog.BackgroundDownloadDrain")
struct BackgroundDownloadDrainTests {
    @MainActor
    @Test("A completed component releases its wake before the next network component")
    func checkpointsDoNotWaitForFutureDownloads() {
        let settlement = BackgroundDownloadEventSettlement(name: "component-checkpoints")
        let ledger = ModelDownloadSettlementLedger()
        let fire = FireTracker()
        settlement.registerSystemCompletionHandler { fire.record() }
        ledger.began(settlement)
        settlement.sessionDidFinishEvents()
        #expect(fire.count == 0)
        ledger.checkpoint()
        #expect(fire.count == 1)
        // Next component belongs to a later wake, while the final component's
        // verification/package commit still waits for the operation tail.
        settlement.registerSystemCompletionHandler { fire.record() }
        ledger.began(settlement)
        settlement.sessionDidFinishEvents()
        #expect(fire.count == 1)
        ledger.drain()
        #expect(fire.count == 2)
        ledger.checkpoint()
        ledger.drain()
        #expect(fire.count == 2)
    }

    private func makeDelegate(
        settlement: BackgroundDownloadEventSettlement,
        ledger: ModelDownloadSettlementLedger
    ) throws -> (delegate: ComponentDownloadDelegate, temp: URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let delegate = ComponentDownloadDelegate(
            destination: temp.appendingPathComponent("model.safetensors"),
            resumeDataURL: temp.appendingPathComponent("component.resume"),
            modelID: "drain-test-model",
            component: "file-0",
            overallBase: 0,
            overallWeight: 1,
            settlement: settlement,
            ledger: ledger,
            progress: nil
        )
        return (delegate, temp)
    }

    @Test("An underway settle holds the system completion; the operation-tail drain releases exactly once on main")
    func settleHoldsUntilOperationTail() async throws {
        let identifier = uniqueTestIdentifier("underway")
        let settlement = LocalModelDownloadSettlements.settlement(for: identifier)
        #expect(LocalModelDownloadSettlements.settlement(for: identifier) === settlement)

        let ledger = ModelDownloadSettlementLedger()
        let (delegate, temp) = try makeDelegate(settlement: settlement, ledger: ledger)
        defer { try? FileManager.default.removeItem(at: temp) }

        // REAL failed-transfer callback: its exactly-once resume schedules
        // the owning download task's settle work. The event must already be
        // registered synchronously inside the callback.
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.invalid/underway")!)
        defer { task.cancel() }
        delegate.urlSession(URLSession.shared, task: task, didCompleteWithError: URLError(.networkConnectionLost))
        #expect(settlement.settlementStateForTesting.pending == 1)

        // System finish arrives while the settle is still underway, then the
        // launch handler registers. Neither may release the wake.
        settlement.sessionDidFinishEvents()
        let fired = FireTracker()
        registerSystemCompletion(identifier: identifier, settlement: settlement) { fired.record() }
        try await Task.sleep(for: .milliseconds(60))
        #expect(fired.count == 0, "OS completion must not fire while verification/commit is underway")

        // Operation tail: durable bytes/state committed (cleanup finished on
        // the failure path) → the single drain releases.
        ledger.drain()
        try await settleWait { fired.count == 1 }
        #expect(fired.onMain, "the system completion runs on the main thread")
        try await Task.sleep(for: .milliseconds(40))
        #expect(fired.count == 1)
        ledger.drain() // idempotent — no second release
        #expect(fired.count == 1)
        #expect(settlement.settlementStateForTesting.fired)
    }

    @Test("A terminal callback before attachment replays its result and cancels the unused replacement task")
    func replayedTerminalResultDoesNotStrandAttachmentOrReplacement() async throws {
        let identifier = uniqueTestIdentifier("replay-attach")
        let settlement = LocalModelDownloadSettlements.settlement(for: identifier)
        let ledger = ModelDownloadSettlementLedger()
        let (delegate, temp) = try makeDelegate(settlement: settlement, ledger: ledger)
        defer { try? FileManager.default.removeItem(at: temp) }
        let original = URLSession.shared.downloadTask(with: URL(string: "https://example.invalid/original")!)
        let replacement = URLSession.shared.downloadTask(with: URL(string: "https://example.invalid/replacement")!)
        defer { original.cancel(); replacement.cancel(); ledger.drain() }
        delegate.urlSession(URLSession.shared, task: original,
                            didCompleteWithError: URLError(.networkConnectionLost))
        settlement.sessionDidFinishEvents()
        let fired = FireTracker()
        registerSystemCompletion(identifier: identifier, settlement: settlement) { fired.record() }
        do {
            _ = try await delegate.start(task: replacement)
            Issue.record("The replayed transfer error must reach its owning operation")
        } catch let error as URLError {
            #expect(error.code == .networkConnectionLost)
        }
        #expect(settlement.settlementStateForTesting.pending == 1)
        #expect(fired.count == 0)
        try await settleWait { replacement.state != .suspended }
        ledger.drain()
        try await settleWait { fired.count == 1 }
    }

    @Test("A late handler for an already-drained, already-finished wake fires immediately at registration")
    func lateHandlerFiresAtRegistration() async throws {
        let identifier = uniqueTestIdentifier("late-handler")
        let settlement = LocalModelDownloadSettlements.settlement(for: identifier)
        let ledger = ModelDownloadSettlementLedger()
        let (delegate, temp) = try makeDelegate(settlement: settlement, ledger: ledger)
        defer { try? FileManager.default.removeItem(at: temp) }

        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.invalid/late")!)
        defer { task.cancel() }
        delegate.urlSession(URLSession.shared, task: task, didCompleteWithError: URLError(.timedOut))
        ledger.drain()                       // settle committed BEFORE the handler arrives
        settlement.sessionDidFinishEvents()  // system finished BEFORE the handler arrives
        #expect(!settlement.settlementStateForTesting.fired)

        let fired = FireTracker()
        registerSystemCompletion(identifier: identifier, settlement: settlement) { fired.record() }
        try await settleWait { fired.count == 1 }  // registration itself releases; nothing is lost
        #expect(fired.onMain)
    }

    @Test("Two session identifiers settle independently — no cross-identifier hold, release or duplication")
    func identifiersAreIsolated() async throws {
        let idA = uniqueTestIdentifier("iso-a")
        let idB = uniqueTestIdentifier("iso-b")
        let settlementA = LocalModelDownloadSettlements.settlement(for: idA)
        let settlementB = LocalModelDownloadSettlements.settlement(for: idB)
        #expect(settlementA !== settlementB)

        let ledger = ModelDownloadSettlementLedger()
        let (delegateA, tempA) = try makeDelegate(settlement: settlementA, ledger: ledger)
        defer { try? FileManager.default.removeItem(at: tempA) }
        let taskA = URLSession.shared.downloadTask(with: URL(string: "https://example.invalid/a")!)
        defer { taskA.cancel() }
        delegateA.urlSession(URLSession.shared, task: taskA, didCompleteWithError: URLError(.cancelled))

        // A: finish + handler with the settle still underway → must hold.
        settlementA.sessionDidFinishEvents()
        let firedA = FireTracker()
        registerSystemCompletion(identifier: idA, settlement: settlementA) { firedA.record() }

        // B: same wake window, NO settle events → its wake must release
        // immediately and must not be held by A's identifier.
        settlementB.sessionDidFinishEvents()
        let firedB = FireTracker()
        registerSystemCompletion(identifier: idB, settlement: settlementB) { firedB.record() }
        try await settleWait { firedB.count == 1 }
        #expect(firedA.count == 0, "identifier A's underway settle must not be released by B's wake")

        // A releases only through its own operation-tail drain.
        ledger.drain()
        try await settleWait { firedA.count == 1 }
        #expect(firedA.onMain)
        #expect(firedB.count == 1, "B already settled; A's drain cannot re-fire B")
    }

    @Test("A stale duplicate finish cannot pre-satisfy the next wake; the next wake needs its own finish")
    func duplicateFinishDoesNotPreSatisfyNextWake() async throws {
        let identifier = uniqueTestIdentifier("dup-finish")
        let settlement = LocalModelDownloadSettlements.settlement(for: identifier)

        // Wake 1 completes normally.
        settlement.beginEvent()
        settlement.endEvent()
        settlement.sessionDidFinishEvents()
        let fired1 = FireTracker()
        registerSystemCompletion(identifier: identifier, settlement: settlement) { fired1.record() }
        try await settleWait { fired1.count == 1 }
        #expect(settlement.settlementStateForTesting.fired)

        // A stale DUPLICATE finish for the released wake arrives late.
        settlement.sessionDidFinishEvents()

        // The next wake's first REAL event rolls the cycle. The stale
        // duplicate must not have marked the new wake system-finished.
        let ledger = ModelDownloadSettlementLedger()
        let (delegate, temp) = try makeDelegate(settlement: settlement, ledger: ledger)
        defer { try? FileManager.default.removeItem(at: temp) }
        let task = URLSession.shared.downloadTask(with: URL(string: "https://example.invalid/dup")!)
        defer { task.cancel() }
        delegate.urlSession(URLSession.shared, task: task, didCompleteWithError: URLError(.cancelled))
        var state = settlement.settlementStateForTesting
        #expect(state.wakeGeneration > 1)
        #expect(state.systemDone == false)
        #expect(state.pending >= 1)

        let fired2 = FireTracker()
        registerSystemCompletion(identifier: identifier, settlement: settlement) { fired2.record() }
        settlement.sessionDidFinishEvents() // the NEW wake's own real finish
        try await Task.sleep(for: .milliseconds(40))
        #expect(fired2.count == 0, "the new wake still waits for the registered settle")

        ledger.drain()
        try await settleWait { fired2.count == 1 }
        #expect(fired2.onMain)
        #expect(fired1.count == 1, "wake 1 already released; no duplicate fire across wakes")
        state = settlement.settlementStateForTesting
        #expect(state.fired)
    }

    #if os(iOS)
    @Test("register(...,bootstrap:) tracks the bounded readiness lease BEFORE the handler; the wake releases only after it drains")
    func bootstrapLeaseHoldsUntilItDrains() async throws {
        let identifier = uniqueTestIdentifier("bootstrap")
        let settlement = LocalModelDownloadSettlements.settlement(for: identifier)
        let gate = GateFlag()
        let fired = FireTracker()

        // The wake's system side completes BEFORE the handler registers.
        // Without the bootstrap lease the stored handler would fire
        // immediately past the still-running readiness work; with it, the
        // release decision defers on the SAME wake generation.
        settlement.sessionDidFinishEvents()
        LocalModelBackgroundEvents.shared.register(
            identifier: identifier,
            completion: { fired.record() },
            bootstrap: { await gate.waitUntilOpen() }
        )
        var state = settlement.settlementStateForTesting
        #expect(state.wakeGeneration == 1)
        #expect(state.hasHandler)
        #expect(state.fired == false, "a late handler must not fire past a pending bounded bootstrap")
        try await Task.sleep(for: .milliseconds(40))
        #expect(fired.count == 0)

        gate.openGate()
        try await settleWait { fired.count == 1 }
        #expect(fired.onMain)
        #expect(fired.count == 1)
        state = settlement.settlementStateForTesting
        #expect(state.pending == 0)
    }
    #endif

    @Test("A began that lands after the operation tail self-pairs and never strands a future wake")
    func lateBeganAfterDrainSelfPairs() async throws {
        let identifier = uniqueTestIdentifier("late-began")
        let settlement = LocalModelDownloadSettlements.settlement(for: identifier)
        let ledger = ModelDownloadSettlementLedger()

        ledger.began(settlement)
        ledger.drain()
        #expect(settlement.settlementStateForTesting.pending == 0)

        // Defensive late event (stale callback after the tail): begin+end
        // self-pair so a future wake can still settle.
        ledger.began(settlement)
        #expect(settlement.settlementStateForTesting.pending == 0)

        settlement.sessionDidFinishEvents()
        let fired = FireTracker()
        registerSystemCompletion(identifier: identifier, settlement: settlement) { fired.record() }
        try await settleWait { fired.count == 1 } // the wake is NOT stranded
        #expect(fired.onMain)
    }
}
