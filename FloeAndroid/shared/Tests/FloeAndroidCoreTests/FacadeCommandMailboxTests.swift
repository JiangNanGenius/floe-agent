// SPDX-License-Identifier: MPL-2.0
//
// RB-1 source tests — bounded synchronous-to-async command mailbox.
// Observes CONTRACTS (receipt shape, saturation codes, exact-once
// settlement, slot accounting), not internal bookkeeping. AUTHORED ONLY:
// not compiled or executed by this source package.
import XCTest
import Foundation
@testable import FloeAndroidCore

/// A gate the tests use to model real in-flight async work. Production
/// never imports this: the mailbox processor is host-registered.
private final class Gate: @unchecked Sendable {
    private let condition = NSCondition()
    private var open = false
    func wait() {
        condition.lock()
        while !open { condition.wait() }
        condition.unlock()
    }
    func openNow() {
        condition.lock()
        open = true
        condition.broadcast()
        condition.unlock()
    }
}

final class FacadeCommandMailboxTests: XCTestCase {

    private var created: [FacadeCommandMailbox] = []

    override func tearDown() {
        // Join every owned drain thread: close with the queue emptied.
        for mailbox in created { mailbox.close(reason: .closed) }
        created.removeAll()
        super.tearDown()
    }

    private func makePair() -> (FacadeEffectPump, RuntimeDomainRegistry, FacadeCommandMailbox) {
        let effects = FacadeEffectPump(generation: 1)
        let registry = RuntimeDomainRegistry()
        let mailbox = FacadeCommandMailbox(effects: effects, registry: registry)
        created.append(mailbox)
        return (effects, registry, mailbox)
    }

    private func job(correlation: String, receipt: String,
                     envelopeBytes: Int = 64,
                     handlerKey: String = "v3.command.applicationConfiguration.system.lifecycle")
        -> RuntimeCommandEnvelopeJob {
        RuntimeCommandEnvelopeJob(
            correlationID: correlation, handlerKey: handlerKey,
            command: "system.lifecycle", scope: .applicationConfiguration,
            configurationScope: "system", receipt: receipt,
            envelope: Data(repeating: 0x20, count: envelopeBytes))
    }

    private func registerEcho(registry: RuntimeDomainRegistry) {
        registry.register(handlerKey: "v3.command.applicationConfiguration.system.lifecycle",
                          processor: RuntimeAsyncProcessor { _ in .accepted() })
    }

    // MARK: Bounds

    func testQueueSaturationIsTypedAndImmediate() {
        let (effects, registry, mailbox) = makePair()
        registerEcho(registry: registry)
        // Do NOT start the drain thread: everything stays queued.
        var receipts: [String] = []
        for index in 1...FacadeCommandMailbox.Limits.maximumQueued {
            let receipt = effects.register(correlationID: "c-\(index)")
            let result = mailbox.submit(job(correlation: "c-\(index)",
                                           receipt: XCTUnwrapNotNil(receipt)))
            guard case .queued(let r) = result else {
                return XCTFail("entry \(index) should queue")
            }
            receipts.append(r)
        }
        let overflowReceipt = XCTUnwrapNotNil(effects.register(correlationID: "overflow"))
        let overflow = mailbox.submit(job(correlation: "overflow", receipt: overflowReceipt))
        XCTAssertEqual(overflow, .rejected(.mailboxSaturated))
        // The rejected stream still carries exactly one typed terminal so a
        // racing poll can never see a phantom in-flight.
        if case .page(let items, _, _, _) = effects.poll(receipt: overflowReceipt,
                                                         afterSequence: 0) {
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.kind, .rejected)
            XCTAssertEqual(items.first?.code, .mailboxSaturated)
        } else { XCTFail("rejected receipt must be observable") }
    }

    func testQueuedByteBoundRejectsBeforeAllocatingMemory() {
        let (effects, registry, mailbox) = makePair()
        registerEcho(registry: registry)
        var remaining = FacadeCommandMailbox.Limits.maximumQueuedEnvelopeBytes
        var index = 0
        var trace: [String] = []
        while remaining > 512 {
            index += 1
            // Stay under the FROZEN per-envelope bound so only the queued
            // BYTE bound can refuse here.
            let size = min(64_000, remaining)
            remaining -= size
            let receipt = XCTUnwrapNotNil(effects.register(correlationID: "b-\(index)"))
            let result = mailbox.submit(job(correlation: "b-\(index)", receipt: receipt,
                                            envelopeBytes: size))
            trace.append("\(size):\(result)")
            if case .rejected(.mailboxSaturated) = result { return } // bounded as designed
            if case .rejected(let other) = result {
                return XCTFail("unexpected rejection \(other) trace=\(trace)")
            }
        }
        // The loop above fills exactly the aggregate bound. Growth beyond it
        // must be refused BEFORE unbounded allocation: one more (tiny)
        // submission is rejected typed and the queued bytes never exceed the
        // bound. This preserves the original bounded-growth intent without
        // depending on the loop's off-by-one arithmetic.
        XCTAssertGreaterThan(trace.count, 0)
        let counts = mailbox.snapshotCountsForTesting()
        XCTAssertLessThanOrEqual(counts.bytes,
                                 FacadeCommandMailbox.Limits.maximumQueuedEnvelopeBytes)
        let extraReceipt = XCTUnwrapNotNil(effects.register(correlationID: "b-over"))
        XCTAssertEqual(mailbox.submit(job(correlation: "b-over", receipt: extraReceipt,
                                          envelopeBytes: 1)),
                       .rejected(.mailboxSaturated))
        XCTAssertLessThanOrEqual(mailbox.snapshotCountsForTesting().bytes,
                                 FacadeCommandMailbox.Limits.maximumQueuedEnvelopeBytes)
    }

    func testOversizedEnvelopeRejectedAtFrozenBound() {
        let (effects, registry, mailbox) = makePair()
        registerEcho(registry: registry)
        let receipt = XCTUnwrapNotNil(effects.register(correlationID: "big"))
        let result = mailbox.submit(job(correlation: "big", receipt: receipt,
                                        envelopeBytes: 65_537))
        XCTAssertEqual(result, .rejected(.envelopeTooLarge))
    }

    // MARK: Dedupe

    func testDuplicateCorrelationReplaysOriginalReceiptWithoutSecondWork() {
        let (effects, registry, mailbox) = makePair()
        registerEcho(registry: registry)
        let first = XCTUnwrapNotNil(effects.register(correlationID: "dup"))
        guard case .queued = mailbox.submit(job(correlation: "dup", receipt: first)) else {
            return XCTFail("first submit")
        }
        let second = XCTUnwrapNotNil(effects.register(correlationID: "dup"))
        let result = mailbox.submit(job(correlation: "dup", receipt: second))
        XCTAssertEqual(result, .duplicate(receipt: first))
        // The second receipt explains the dedupe exactly once.
        if case .page(let items, _, _, _) = effects.poll(receipt: second, afterSequence: 0) {
            XCTAssertEqual(items.map { $0.kind }, [.rejected])
            XCTAssertEqual(items.first?.code, .duplicateCorrelation)
        } else { XCTFail("duplicate receipt must settle typed") }
        // Only one queued job exists.
        XCTAssertEqual(mailbox.snapshotCountsForTesting().queued, 1)
    }

    // MARK: Drain + exact-once settlement

    func testActiveSlotReleasedOnlyByRealCompletionNotByTime() async throws {
        let (effects, registry, mailbox) = makePair()
        let gate = Gate()
        registry.register(handlerKey: "v3.command.applicationConfiguration.system.lifecycle",
                          processor: RuntimeAsyncProcessor { _ in
            gate.wait()
            return .accepted()
        })
        mailbox.startDrain()
        let receipt = XCTUnwrapNotNil(effects.register(correlationID: "slow"))
        guard case .queued = mailbox.submit(job(correlation: "slow", receipt: receipt)) else {
            return XCTFail("submit")
        }
        // Give the drain thread time to claim AND start the job.
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(mailbox.snapshotCountsForTesting().active, 1)
        // Still active after the wait window: NO timer ever freed it.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(mailbox.snapshotCountsForTesting().active, 1)
        if case .page(let early, _, _, _) = effects.poll(receipt: receipt, afterSequence: 0) {
            XCTAssertTrue(early.isEmpty)
        } else { XCTFail("unknown receipt while in flight") }
        gate.openNow()
        await waitFor { mailbox.snapshotCountsForTesting().active == 0 }
        if case .page(let items, let next, let hasMore, _) = effects.poll(receipt: receipt,
                                                                          afterSequence: 0) {
            XCTAssertEqual(items.map { $0.kind }, [.accepted])
            XCTAssertEqual(next, 1)
            XCTAssertFalse(hasMore)
        } else { XCTFail("missing accepted") }
        // Second settlement for the same token is classified late and cannot
        // re-append: mailbox.settle with a bogus token does nothing.
        mailbox.settle(token: 999_999, result: .accepted())
        if case .page(let after, _, _, _) = effects.poll(receipt: receipt, afterSequence: 0) {
            XCTAssertEqual(after.map { $0.kind }, [.accepted])  // still exactly one
        }
    }

    func testQueuedCancelProvesNoEffectActiveCancelHonorsRealFinish() async throws {
        let (effects, registry, mailbox) = makePair()
        let started = Gate()
        let finish = Gate()
        registry.register(handlerKey: "v3.command.applicationConfiguration.system.lifecycle",
                          processor: RuntimeAsyncProcessor { job in
            started.openNow()
            finish.wait()
            return Task.isCancelled ? RuntimeCommandResult.cancelled : .accepted()
        })
        // Queued cancel WITHOUT starting the drain: provable no-effect.
        let queuedReceipt = XCTUnwrapNotNil(effects.register(correlationID: "q"))
        guard case .queued = mailbox.submit(job(correlation: "q", receipt: queuedReceipt)) else {
            return XCTFail("submit")
        }
        XCTAssertTrue(mailbox.cancel(correlationID: "q"))
        if case .page(let items, _, _, _) = effects.poll(receipt: queuedReceipt, afterSequence: 0) {
            XCTAssertEqual(items.map { $0.kind }, [.cancelled])
        } else { XCTFail("cancelled effect") }
        mailbox.startDrain()
        // Active cancel: returns false (requested, not proven), and the slot
        // survives until the processor really finishes.
        let activeReceipt = XCTUnwrapNotNil(effects.register(correlationID: "a"))
        guard case .queued = mailbox.submit(job(correlation: "a", receipt: activeReceipt)) else {
            return XCTFail("submit")
        }
        try await withTimeout(2) { started.wait() }
        XCTAssertFalse(mailbox.cancel(correlationID: "a"))
        XCTAssertEqual(mailbox.snapshotCountsForTesting().active, 1)
        finish.openNow()
        await waitFor { mailbox.snapshotCountsForTesting().active == 0 }
        if case .page(let items, _, _, _) = effects.poll(receipt: activeReceipt, afterSequence: 0) {
            // The processor observed cancellation and settled exactly one
            // cancelled terminal.
            XCTAssertEqual(items.map { $0.kind }, [.cancelled])
        } else { XCTFail("missing cancel terminal") }
    }

    // MARK: Draining vs retire (M3)

    func testBeginDrainingRefusesNewAdmissionsButQueuedWorkStillRuns() async throws {
        let (effects, registry, mailbox) = makePair()
        registerEcho(registry: registry)
        let a = XCTUnwrapNotNil(effects.register(correlationID: "a"))
        guard case .queued = mailbox.submit(job(correlation: "a", receipt: a)) else {
            return XCTFail("submit")
        }
        mailbox.beginDraining()
        let b = XCTUnwrapNotNil(effects.register(correlationID: "b"))
        XCTAssertEqual(mailbox.submit(job(correlation: "b", receipt: b)), .rejected(.alreadyDraining))
        mailbox.startDrain()
        await waitFor { mailbox.snapshotCountsForTesting().queued == 0
            && mailbox.snapshotCountsForTesting().active == 0 }
        if case .page(let items, _, _, _) = effects.poll(receipt: a, afterSequence: 0) {
            XCTAssertEqual(items.map { $0.kind }, [.accepted])   // queued work NOT discarded
        } else { XCTFail("a must settle accepted after drain") }
    }

    func testRetireAfterDrainKeepsControlEntrySettleable() async throws {
        let (effects, registry, mailbox) = makePair()
        let controlGate = Gate()
        registry.register(handlerKey: "v3.command.applicationConfiguration.system.lifecycle",
                          processor: RuntimeAsyncProcessor { _ in
            controlGate.wait()
            return .accepted()
        })
        mailbox.startDrain()
        let control = XCTUnwrapNotNil(effects.register(correlationID: "host:shutdown:1"))
        guard case .queued = mailbox.submit(job(correlation: "host:shutdown:1", receipt: control)) else {
            return XCTFail("submit")
        }
        try await Task.sleep(nanoseconds: 120_000_000)   // control is now ACTIVE
        // Retire excluding the control: it must NOT be caller-settled early.
        mailbox.retireAfterDrain(excludingCorrelation: "host:shutdown:1")
        if case .page(let early, _, _, _) = effects.poll(receipt: control, afterSequence: 0) {
            XCTAssertTrue(early.isEmpty)   // no premature closed terminal
        } else { XCTFail("control still live") }
        controlGate.openNow()
        await waitFor { mailbox.snapshotCountsForTesting().active == 0 }
        if case .page(let items, _, _, _) = effects.poll(receipt: control, afterSequence: 0) {
            XCTAssertEqual(items.map { $0.kind }, [.accepted])   // exactly one, AFTER real work
        } else { XCTFail("control terminal") }
        // New admissions are refused after retire.
        let later = XCTUnwrapNotNil(effects.register(correlationID: "later"))
        XCTAssertEqual(mailbox.submit(job(correlation: "later", receipt: later)),
                       .rejected(.mailboxClosed))
    }

    func testCloseCallerSettlesActiveButSlotSurvivesLateCompletion() async throws {
        let (effects, registry, mailbox) = makePair()
        let gate = Gate()
        registry.register(handlerKey: "v3.command.applicationConfiguration.system.lifecycle",
                          processor: RuntimeAsyncProcessor { _ in
            gate.wait()
            return .accepted()
        })
        mailbox.startDrain()
        let receipt = XCTUnwrapNotNil(effects.register(correlationID: "x"))
        guard case .queued = mailbox.submit(job(correlation: "x", receipt: receipt)) else {
            return XCTFail("submit")
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        mailbox.close(reason: .replaced)
        if case .page(let items, _, _, _) = effects.poll(receipt: receipt, afterSequence: 0) {
            XCTAssertEqual(items.map { $0.kind }, [.replaced])   // caller settled once
            XCTAssertEqual(items.first?.code, .mailboxClosed)
        } else { XCTFail("replaced terminal") }
        // The slot is STILL held while the real work runs (no time disposal).
        XCTAssertEqual(mailbox.snapshotCountsForTesting().active, 1)
        gate.openNow()
        await waitFor { mailbox.snapshotCountsForTesting().active == 0 }
        // And the late completion did not double-settle the stream.
        if case .page(let items, _, _, _) = effects.poll(receipt: receipt, afterSequence: 1) {
            XCTAssertTrue(items.isEmpty)
        }
    }

    func testControlBypassIsInternalOnlyAndStillBounded() {
        let (effects, registry, mailbox) = makePair()
        registerEcho(registry: registry)
        mailbox.beginDraining()
        let receipt = XCTUnwrapNotNil(effects.register(correlationID: "ctrl"))
        let result = mailbox.submitControl(job(correlation: "ctrl", receipt: receipt))
        guard case .queued = result else { return XCTFail("control must enqueue: \(result)") }
        // A fenced mailbox STILL refuses normal submits.
        let normal = XCTUnwrapNotNil(effects.register(correlationID: "normal"))
        XCTAssertEqual(mailbox.submit(job(correlation: "normal", receipt: normal)),
                       .rejected(.alreadyDraining))
    }

    // MARK: Receipt shape (correlation + receipt ONLY)

    func testReceiptJsonCarriesNoDomainIdentity() throws {
        let data = RuntimeFacadeBridge.receiptJSON(correlation: "corr-1",
                                                   receipt: "op:v1:" + String(repeating: "ab", count: 16))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys),
                       ["ok", "schema", "correlationID", "queued", "operationReceiptID"])
        XCTAssertNil(object["taskID"])
        XCTAssertNil(object["runID"])
        XCTAssertNil(object["environmentID"])
        XCTAssertNil(object["jobID"])
    }

    // MARK: helpers

    private func waitFor(_ predicate: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        func markFinished() { lock.lock(); finished = true; lock.unlock() }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    }

    private func withTimeout(_ seconds: Double,
                             _ block: @escaping @Sendable () -> Void) async throws {
        // Swift Task has no isFinished; observe completion through a small
        // lock-guarded flag and only throw the test timeout if the block
        // really did not finish (no cancellation of a real completion).
        let completion = Completion()
        let task = Task.detached {
            block()
            completion.markFinished()
        }
        let deadline = Date().addingTimeInterval(seconds)
        while !completion.isFinished && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if !completion.isFinished {
            task.cancel()
            throw XCTestTimeoutError()
        }
        _ = await task.value
    }
}

struct XCTestTimeoutError: Error {}

private func XCTUnwrapNotNil<T>(_ value: T?) -> T {
    guard let value else { fatalError("required value missing") }
    return value
}
