import Foundation
import Testing
import FloeCore
@testable import FloeApp

private final class StorageLeaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
private final class HandoffProbe {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

private actor AssertionHandoffGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func enterAndWait() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@Suite("Finite storage operation ownership")
struct StorageOperationBudgetTests {
    @Test("Completion is idempotent and a late expiration cannot cancel a new operation")
    func finishedOperationIsFenced() {
        let ended = StorageLeaseCounter()
        let expired = StorageLeaseCounter()
        let lease = StorageOperationLease { ended.increment() }
        lease.whenExpired { expired.increment() }
        lease.finish()
        lease.finish()
        lease.expire()
        #expect(ended.count == 1)
        #expect(expired.count == 0)
    }

    @Test("Expiration cancels the actual owner once and prevents acquiring its file lock")
    func expirationBeforeMutation() {
        let count = StorageLeaseCounter()
        let lease = StorageOperationLease()
        lease.whenExpired { count.increment() }
        lease.expire()
        lease.expire()
        #expect(count.count == 1)
        do {
            try lease.check()
            Issue.record("Expired budget allowed a mutation")
        } catch is CancellationError { }
        catch { Issue.record("Unexpected cancellation vocabulary") }
        lease.finish()
    }

    @Test("Background admission is fenced only while canceling or finalizing")
    func admissionPolicy() {
        #expect(StorageSuspensionAdmission.permitsOperation(
            backgroundNow: true, needsForeground: false, finalizingHandoff: false))
        #expect(!StorageSuspensionAdmission.permitsOperation(
            backgroundNow: true, needsForeground: true, finalizingHandoff: false))
        #expect(!StorageSuspensionAdmission.permitsOperation(
            backgroundNow: true, needsForeground: false, finalizingHandoff: true))
        // Ordinary inactive/foreground work and multiwindow use are untouched.
        #expect(StorageSuspensionAdmission.permitsOperation(
            backgroundNow: false, needsForeground: true, finalizingHandoff: true))
    }

    @Test("The last lease defers while owners drain and fences before its assertion ends")
    func leaseExitOrdering() {
        #expect(StorageSuspensionLeaseExit.decide(
            isBackground: false, quiescenceComplete: true, leaseCount: 1,
            connectionsSuspended: false, finalizingHandoff: false) == .endNow)
        #expect(StorageSuspensionLeaseExit.decide(
            isBackground: true, quiescenceComplete: true, leaseCount: 2,
            connectionsSuspended: false, finalizingHandoff: false) == .endNow)
        // Owners are still draining: do not return the final assertion yet.
        #expect(StorageSuspensionLeaseExit.decide(
            isBackground: true, quiescenceComplete: false, leaseCount: 1,
            connectionsSuspended: false, finalizingHandoff: false) == .deferUntilQuiescence)
        // Quiesced final lease: SQLite fence/drain must precede the return.
        #expect(StorageSuspensionLeaseExit.decide(
            isBackground: true, quiescenceComplete: true, leaseCount: 1,
            connectionsSuspended: false, finalizingHandoff: false) == .fenceThenEnd)
        #expect(StorageSuspensionLeaseExit.decide(
            isBackground: true, quiescenceComplete: true, leaseCount: 1,
            connectionsSuspended: true, finalizingHandoff: false) == .endNow)
        #expect(StorageSuspensionLeaseExit.decide(
            isBackground: true, quiescenceComplete: true, leaseCount: 1,
            connectionsSuspended: false, finalizingHandoff: true) == .endNow)
    }

    @Test("A stale background handoff cannot fence a newer lifecycle generation")
    func handoffOwnership() {
        #expect(StorageSuspensionHandoffOwnership.mayFence(
            isBackground: true, startedGeneration: 7, currentGeneration: 7))
        #expect(!StorageSuspensionHandoffOwnership.mayFence(
            isBackground: false, startedGeneration: 7, currentGeneration: 7))
        // Foreground resume and a later background both bump the generation.
        #expect(!StorageSuspensionHandoffOwnership.mayFence(
            isBackground: true, startedGeneration: 7, currentGeneration: 8))
    }

    @Test("A new background generation can protect itself while an old drain finishes")
    func oldDrainDoesNotBlockNewProtection() {
        let oldHandoff: UInt64? = 7
        #expect(!StorageSuspensionAdmission.permitsOperation(
            backgroundNow: true, needsForeground: false,
            finalizingHandoff: StorageSuspensionHandoffOwnership.isCurrent(
                handoffGeneration: oldHandoff, currentGeneration: 7)))
        // Foreground then background again: the old asynchronous drain can
        // still exist, but it must not prevent the new protection assertion.
        #expect(StorageSuspensionAdmission.permitsOperation(
            backgroundNow: true, needsForeground: false,
            finalizingHandoff: StorageSuspensionHandoffOwnership.isCurrent(
                handoffGeneration: oldHandoff, currentGeneration: 9)))
        #expect(!StorageSuspensionHandoffOwnership.isCurrent(
            handoffGeneration: nil, currentGeneration: 9))
    }

    @Test("The last background assertion is returned only after the storage fence drains")
    @MainActor
    func assertionFollowsFence() async {
        let gate = AssertionHandoffGate()
        let probe = HandoffProbe()
        let task = Task { @MainActor in
            await StorageBackgroundAssertionHandoff.finish(
                fence: {
                    probe.record("fence.start")
                    await gate.enterAndWait()
                    probe.record("fence.end")
                },
                endAssertion: {
                    probe.record("assertion.end")
                }
            )
        }
        await gate.waitForEntry()
        #expect(probe.events == ["fence.start"])
        await gate.release()
        await task.value
        #expect(probe.events == ["fence.start", "fence.end", "assertion.end"])
    }

    @Test("A main-thread lifecycle notification is handled before it returns")
    @MainActor
    func lifecycleNotificationIsSynchronous() {
        let center = NotificationCenter()
        let observer = StorageLifecycleObserver(center: center)
        let probe = HandoffProbe()
        let name = Notification.Name("org.floeagent.tests.storage-suspension")
        observer.observe(name) { probe.record("entered") }
        center.post(name: name, object: nil)
        // A Task or OperationQueue hop would still be pending here; the real
        // protection assertion and admission fence must already exist.
        #expect(probe.events == ["entered"])
        observer.stop()
    }
}
