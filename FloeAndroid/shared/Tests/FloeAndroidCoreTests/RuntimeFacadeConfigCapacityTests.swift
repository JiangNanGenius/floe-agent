// SPDX-License-Identifier: MPL-2.0
//
// MC-CAPACITY-1 + MC-CAPACITY-2 authored tests (job-97a740a3dbb946ce).
// AUTHORED ONLY: NOT compiled, NOT executed by this source package; Main's
// serialized qualification lane runs them against the real toolchain.
//
// MC-CAPACITY-1 (ProviderOperationCoordinator): bounded per-operation
// reservation taken BEFORE effects; truthful `.capacityUnavailable`
// refusal; exact-ticket park ALWAYS retains receipt/lease; settle without
// restart after REAL completion; new admission after settle.
//
// MC-CAPACITY-2 (SecretRequestMailbox): the physical ledger preserves each
// observed operation's proof until explicit consumer resolve, refuses
// exhausted observing capacity BEFORE queue/dispatch/effect, and wakes
// settlement subscribers exactly once per terminal transition (queued
// cancel / watchdog drain / old-generation rebind / real completion /
// duplicate completion / RootStop reset) through the notification channel
// (the retired 20 ms poll is gone). The mailbox races here drive the REAL
// SecretRequestMailbox + MailboxSecretGateway + registry, exactly like the
// parent physical suite (the TEST plays the trusted HOST role).

import XCTest
import Foundation
import GRDB
@testable import FloeAndroidCore
import FloeCore
import FloePersistence

final class RuntimeFacadeConfigCapacityTests: XCTestCase {

    private final class PhysicalClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 10_000
        var now: UInt64 { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ milliseconds: UInt64) { lock.lock(); value += milliseconds; lock.unlock() }
    }

    private var clock: PhysicalClock!

    override func setUp() async throws {
        _ = floeSecretGatewayRemove()
        SecretGatewayRegistry.shared.unregister()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        ProviderOperationCoordinatorRegistry.shared.removeAllForTesting()
        let testClock = PhysicalClock()
        clock = testClock
        SecretRequestMailbox.shared.configureForTesting(
            clock: { testClock.now },
            heartbeatStaleMillis: 60_000,
            watchdogStaleMillis: 30,
            watchdogTickMillis: 2,
            backendProgressWindowMillis: 10_000)
        XCTAssertEqual(floeSecretMailboxBind(1), 0)
        XCTAssertEqual(floeSecretGatewayInstall(), 0)
    }

    override func tearDown() async throws {
        _ = floeSecretGatewayRemove()
        SecretGatewayRegistry.shared.unregister()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        ProviderOperationCoordinatorRegistry.shared.removeAllForTesting()
    }

    // MARK: MC-CAPACITY-1 — reservation before effects

    func testBeginRefusesAtCapacityBeforeAnyEffectAndSettleReadmits() async {
        let coordinator = ProviderOperationCoordinator()
        var tickets: [ProviderOperationTicket] = []
        tickets.reserveCapacity(Int(ProviderOperationCoordinator.maximumPending))
        // Fill the bounded reservation with RUNNING operations (nothing has
        // had any effect yet — the reservation itself is the guard).
        for index in 0..<ProviderOperationCoordinator.maximumPending {
            let providerID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index))!
            let outcome = await coordinator.beginOperation(providerID: providerID, kind: .save)
            guard case .attached(let ticket) = outcome else {
                return XCTFail("operation \(index) must attach, got \(outcome)")
            }
            tickets.append(ticket)
        }
        // The 65th distinct operation is refused TRUTHFULLY before any effect.
        let overflowID = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let overflow = await coordinator.beginOperation(providerID: overflowID, kind: .save)
        guard case .capacityUnavailable = overflow else {
            return XCTFail("saturation must refuse capacityUnavailable, got \(overflow)")
        }
        let activeAtCapacity = await coordinator.activeOperationCount()
        XCTAssertEqual(activeAtCapacity, ProviderOperationCoordinator.maximumPending)
        let overflowPending = await coordinator.pendingRecord(providerID: overflowID)
        XCTAssertNil(overflowPending)
        // No ticket exists for the refused attempt: nothing can leak.
        // Settle ONE owner exactly → one new admission succeeds.
        await coordinator.endOperation(tickets[0])
        let admitted = await coordinator.beginOperation(providerID: overflowID, kind: .save)
        guard case .attached = admitted else {
            return XCTFail("admission after settle must attach, got \(admitted)")
        }
    }

    func testParkPendingAlwaysRetainsExactReceiptAndLease() async throws {
        let coordinator = ProviderOperationCoordinator()
        let providerID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        guard case .attached(let ticket) = await coordinator.beginOperation(
            providerID: providerID, kind: .delete) else {
            return XCTFail("begin must attach")
        }
        let receipt = PhysicalOperationReceipt(
            claim: 41, epoch: 1,
            reference: SecretGatewayNaming.opaqueReference(
                namespace: "keychainAccount", account: "provider.\(providerID.uuidString)"),
            kind: .delete, tracked: true)
        let lease = ConfigOwnedWorkLease(
            token: RuntimeOwnedWorkToken(
                receipt: "work:v1:" + String(repeating: "a", count: 32),
                epoch: 1, kind: .vaultMaintenance, ownerID: providerID.uuidString))
        // The exact-ticket park ALWAYS succeeds (reservation was taken at
        // begin): the completed operation's receipt/lease are retained for
        // the reconciler — the parent's capacity refusal at this point is
        // gone.
        let parked = await coordinator.parkPending(ticket, intent: .providerDelete,
                                                   receipt: receipt, lease: lease, witness: nil)
        XCTAssertTrue(parked)
        let pending = await coordinator.pendingRecord(providerID: providerID)
        XCTAssertEqual(pending?.ticket, ticket)
        XCTAssertEqual(pending?.receipt?.claim, 41)
        XCTAssertNotNil(pending?.lease)
        // Newer operations see pendingReconciliation, not a silent nil.
        let next = await coordinator.beginOperation(providerID: providerID, kind: .save)
        guard case .pendingReconciliation = next else {
            return XCTFail("parked owner must block newer operations, got \(next)")
        }
        // Exact-ticket settle releases; a STALE ticket releases nothing.
        let stale = ProviderOperationTicket(providerID: providerID, kind: .delete,
                                            claimID: UUID())
        let staleSettled = await coordinator.settlePending(providerID: providerID,
                                                           ticket: stale)
        XCTAssertFalse(staleSettled)
        let exactSettled = await coordinator.settlePending(providerID: providerID,
                                                           ticket: ticket)
        XCTAssertTrue(exactSettled)
        let postSettlePending = await coordinator.pendingRecord(providerID: providerID)
        XCTAssertNil(postSettlePending)
        guard case .attached = await coordinator.beginOperation(providerID: providerID, kind: .save)
        else {
            return XCTFail("new admission after exact settle must attach")
        }
    }

    func testSaturatedCoordinatorRecoveryReconcilesAfterRealCompletionWithoutRestart() async throws {
        // The MC-CAPACITY-1 defect: at 64 pending owners the parent's
        // parkPending refused AFTER effects, dropped receipt/lease from the
        // pending record and stranded the running slot — reconciliation was
        // restart-only. Now: fill every slot with PENDING owners that carry
        // their receipts, prove pendingRecord sees each exact receipt, then
        // settle each on its individual truth and admit fresh work.
        let coordinator = ProviderOperationCoordinator()
        var tickets: [ProviderOperationTicket] = []
        for index in 0..<ProviderOperationCoordinator.maximumPending {
            let providerID = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 0x1000))!
            guard case .attached(let ticket) = await coordinator.beginOperation(
                providerID: providerID, kind: .save) else {
                return XCTFail("begin \(index) must attach")
            }
            let receipt = PhysicalOperationReceipt(
                claim: Int64(index + 1), epoch: 1,
                reference: SecretGatewayNaming.opaqueReference(
                    namespace: "keychainAccount", account: "provider.\(providerID.uuidString)"),
                kind: .write, tracked: true)
            let parked = await coordinator.parkPending(ticket, intent: .secretWrite,
                                                       receipt: receipt, lease: nil, witness: nil)
            XCTAssertTrue(parked)
            tickets.append(ticket)
        }
        // The reservation is full: new work refuses BEFORE effects.
        let extraID = UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        guard case .capacityUnavailable = await coordinator.beginOperation(
            providerID: extraID, kind: .cleanup) else {
            return XCTFail("full reservation must refuse capacityUnavailable")
        }
        // Late REAL completions settle owners one by one (no restart); each
        // settle frees exactly one reservation.
        for (index, ticket) in tickets.enumerated() {
            let settled = await coordinator.settlePending(providerID: ticket.providerID,
                                                          ticket: ticket)
            XCTAssertTrue(settled, "settle \(index) must succeed with the exact ticket")
        }
        let drainedCount = await coordinator.activeOperationCount()
        XCTAssertEqual(drainedCount, 0)
        guard case .attached = await coordinator.beginOperation(providerID: extraID, kind: .cleanup)
        else {
            return XCTFail("post-drain admission must attach")
        }
    }

    // MARK: MC-CAPACITY-2 — physical ledger retention + refusal

    /// Drive the REAL mailbox + observed gateway through one write cycle
    /// WITHOUT consumer resolve, leaving a terminal record behind.
    @discardableResult
    private func driveObservedWriteLeavingRecord() async throws -> (claim: Int64, reference: String) {
        let account = "capacity.\(UUID().uuidString)"
        let reference = SecretGatewayNaming.opaqueReference(
            namespace: "org.floeagent.ios.web-search", account: account)
        let box = ReceiptCapture()
        // The observed write awaits the REAL host completion: run it in an
        // owned Task, then independently claim and complete the actual
        // mailbox ticket before awaiting the producer. (The previous order
        // awaited an unreachable synthetic completion in the same helper.)
        let writeTask = Task {
            try await MailboxSecretGateway.shared.writeObserved(
                reference: reference, value: Data("v".utf8)) { receipt in
                box.set(receipt)
            }
        }
        let claim = try await requireClaim()
        XCTAssertGreaterThan(claim, 0)
        XCTAssertEqual(hostComplete(claim: claim, status: 3), 0)
        try await writeTask.value
        let receipt = try XCTUnwrap(box.receipt)
        return (receipt.claim, reference)
    }

    private func hostClaim() async -> Int64 {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let claim = SecretRequestMailbox.shared.awaitClaim(timeoutMillis: 0)
            if claim > 0 { return claim }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return 0
    }

    private func hostComplete(claim: Int64, status: Int32) -> Int32 {
        SecretRequestMailbox.shared.complete(claim: claim, status: status,
                                             value: nil, valueLen: 0)
    }

    private func requireClaim(file: StaticString = #filePath, line: UInt = #line) async throws -> Int64 {
        let claim = await hostClaim()
        return try XCTUnwrap(claim > 0 ? claim : nil, "host must claim the queued ticket", file: file, line: line)
    }

    func testPhysicalLedgerRefusesObservedPublishAtCapacityBeforeQueue() async throws {
        // Fill all 512 records with UNCONSUMED terminal records (consumers
        // never resolved) — the exact MC-CAPACITY-2 scenario the parent's
        // eviction got wrong.
        var claims: [Int64] = []
        claims.reserveCapacity(512)
        for _ in 0..<512 {
            let cycle = try await driveObservedWriteLeavingRecord()
            claims.append(cycle.claim)
        }
        for claim in claims {
            XCTAssertEqual(MailboxSecretGateway.shared.physicalSnapshot(claim: claim),
                           .settled(status: 3), "terminal proof must be PRESERVED unread")
        }
        // The 513th observed publish refuses BEFORE queue/dispatch/effect:
        // the caller gets the frozen saturation error and NO receipt — the
        // absence itself is the per-attempt never-queued proof.
        let saturatedReference = SecretGatewayNaming.opaqueReference(
            namespace: "org.floeagent.ios.web-search", account: "capacity.saturated")
        let saturatedBox = ReceiptCapture()
        do {
            try await MailboxSecretGateway.shared.writeObserved(
                reference: saturatedReference, value: Data("x".utf8)) { receipt in
                saturatedBox.set(receipt)
            }
            XCTFail("saturated observed publish must refuse")
        } catch {
            XCTAssertEqual(error as? SecretBackendError, SecretBackendError.mailboxSaturated)
        }
        XCTAssertNil(saturatedBox.receipt)
        // Nothing queued: the host never sees a claim for the refused op.
        let strayClaim = await hostClaim()
        XCTAssertEqual(strayClaim, 0)
        // Consumer acknowledgement frees capacity honestly.
        for claim in claims {
            XCTAssertTrue(MailboxSecretGateway.shared.resolvePhysical(claim: claim))
        }
        XCTAssertEqual(MailboxSecretGateway.shared.physicalSnapshot(claim: claims[0]),
                       .notRecorded)
        let after = try await driveObservedWriteLeavingRecord()
        XCTAssertGreaterThan(after.claim, 0, "admission after consumer ack")
    }

    func testTerminalRecordSurvivesUntilConsumerResolveAndSnapshotIsStable() async throws {
        let account = "capacity.single.\(UUID().uuidString)"
        let reference = SecretGatewayNaming.opaqueReference(
            namespace: "org.floeagent.ios.web-search", account: account)
        let box = ReceiptCapture()
        // Run the blocking observed write in an owned Task; the test itself
        // plays the host (claim + real completion), then awaits the producer.
        let writeTask = Task {
            try await MailboxSecretGateway.shared.writeObserved(
                reference: reference, value: Data("v".utf8)) { receipt in box.set(receipt) }
        }
        // Queue-accept delivers the receipt; the record is still QUEUED and
        // unclaimed at that instant (the assertion the parent fixture meant).
        var captured: PhysicalOperationReceipt?
        let receiptDeadline = Date().addingTimeInterval(2.0)
        while captured == nil && Date() < receiptDeadline {
            captured = box.receipt
            if captured == nil { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        let receipt = try XCTUnwrap(captured)
        XCTAssertEqual(MailboxSecretGateway.shared.physicalSnapshot(claim: receipt.claim), .queued)
        let claim = try await requireClaim()
        XCTAssertEqual(claim, receipt.claim)
        XCTAssertEqual(hostComplete(claim: claim, status: 3), 0)
        try await writeTask.value
        // The settlement proof is RETAINED until the consumer acknowledges —
        // it is never evicted by the mailbox itself.
        XCTAssertEqual(MailboxSecretGateway.shared.physicalSnapshot(claim: claim),
                       .settled(status: 3))
        // The notification-based await returns the terminal truth promptly
        // (no 20 ms polling dependence).
        let awaited = await MailboxSecretGateway.shared.awaitPhysicalSettlement(claim: claim)
        XCTAssertEqual(awaited, .settled(status: 3))
        XCTAssertTrue(MailboxSecretGateway.shared.resolvePhysical(claim: claim))
        XCTAssertEqual(MailboxSecretGateway.shared.physicalSnapshot(claim: claim), .notRecorded)
        // A duplicate completion after resolve settles nothing and reports stale.
        XCTAssertEqual(hostComplete(claim: claim, status: 3), -101)
    }

    func testAwaitSettlementNotificationNoLostEventAcrossCancelRebindCompleteAndReset() async throws {
        // claimed → caller-cancel does NOT manufacture absence; the REAL
        // completion wakes the subscriber with the settled truth.
        let account = "capacity.race.\(UUID().uuidString)"
        let reference = SecretGatewayNaming.opaqueReference(
            namespace: "org.floeagent.ios.web-search", account: account)
        let writeTask = Task {
            try await MailboxSecretGateway.shared.writeObserved(
                reference: reference, value: Data("v".utf8)) { _ in }
        }
        let claim = try await requireClaim()
        // Caller cancels while CLAIMED: record stays claimedOutstanding.
        writeTask.cancel()
        _ = try? await writeTask.value
        XCTAssertEqual(MailboxSecretGateway.shared.physicalSnapshot(claim: claim),
                       .claimedOutstanding)
        // Subscriber registers AFTER the cancel, BEFORE the real completion.
        let awaitedBox = PhysicalSnapshotBox()
        let waitTask = Task {
            await awaitedBox.set(MailboxSecretGateway.shared.awaitPhysicalSettlement(claim: claim))
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        // A CLAIMED ticket whose caller was already settled by cancellation
        // takes the frozen retired path: the late real completion reports
        // -103 and still settles the PHYSICAL record exactly once.
        XCTAssertEqual(hostComplete(claim: claim, status: 3), -103)
        // The notification channel wakes the subscriber EXACTLY with the
        // real settled truth — no lost event across cancel→complete.
        let deadline = Date().addingTimeInterval(2.0)
        while awaitedBox.current == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(awaitedBox.current, .settled(status: 3))
        waitTask.cancel()

        // RootStop reset wakes a pending subscriber with honest .notRecorded.
        let account2 = "capacity.reset.\(UUID().uuidString)"
        let reference2 = SecretGatewayNaming.opaqueReference(
            namespace: "org.floeagent.ios.web-search", account: account2)
        let box2 = ReceiptCapture()
        let write2 = Task {
            try await MailboxSecretGateway.shared.writeObserved(
                reference: reference2, value: Data("v".utf8)) { receipt in box2.set(receipt) }
        }
        _ = try await requireClaim()
        let claim2 = try XCTUnwrap(box2.receipt?.claim)
        let resetBox = PhysicalSnapshotBox()
        let resetWait = Task {
            await resetBox.set(MailboxSecretGateway.shared.awaitPhysicalSettlement(claim: claim2))
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        SecretRequestMailbox.shared.resetForTesting()
        let resetDeadline = Date().addingTimeInterval(2.0)
        while resetBox.current == nil && Date() < resetDeadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(resetBox.current, .notRecorded)
        resetWait.cancel()
        write2.cancel()
        _ = try? await write2.value
    }

    // MARK: - Shared box

    private final class PhysicalSnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: PhysicalOperationSnapshot?
        var current: PhysicalOperationSnapshot? { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ snapshot: PhysicalOperationSnapshot) {
            lock.lock(); value = snapshot; lock.unlock()
        }
    }
}
