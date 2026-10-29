import Foundation
import Testing
import FloeCore

private final class StorageLeaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
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
}
