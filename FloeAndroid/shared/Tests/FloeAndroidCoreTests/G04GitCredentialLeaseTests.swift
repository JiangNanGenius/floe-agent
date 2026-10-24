// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeAndroidCore

@Suite struct G04GitCredentialLeaseTests {
    private actor Signal {
        private var ready = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if ready { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func send() {
            ready = true
            let saved = waiters; waiters.removeAll()
            saved.forEach { $0.resume() }
        }
    }
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var live = true
        func get() -> Bool { lock.withLock { live } }
        func retire() { lock.withLock { live = false } }
    }
    private final class Owned: VaultOwnedWorkAttaching, @unchecked Sendable {
        private let lock = NSLock()
        private var tokens: [String: String] = [:]
        var count: Int { lock.withLock { tokens.count } }
        func attachVaultMaintenance(epoch: UInt64, ownerID: String) -> VaultOwnedWorkAttach {
            let receipt = UUID().uuidString
            lock.withLock { tokens[receipt] = "\(epoch):\(ownerID)" }
            return .attached(receipt: receipt)
        }
        func detachVaultMaintenance(receipt: String, epoch: UInt64, ownerID: String) -> Bool {
            lock.withLock {
                guard tokens[receipt] == "\(epoch):\(ownerID)" else { return false }
                tokens.removeValue(forKey: receipt)
                return true
            }
        }
        func isVaultMaintenanceAttached(receipt: String, epoch: UInt64, ownerID: String) -> Bool {
            lock.withLock { tokens[receipt] == "\(epoch):\(ownerID)" }
        }
    }
    private final class Observer: PhysicalObservingSecretGateway, @unchecked Sendable {
        enum BrokenRead: Error { case callerSettled }
        let started = Signal()
        let physicalWaitStarted = Signal()
        private let lock = NSLock()
        private var read: CheckedContinuation<Data?, Error>?
        private var physicalWaiters: [CheckedContinuation<PhysicalOperationSnapshot, Never>] = []
        private var snapshot: PhysicalOperationSnapshot = .claimedOutstanding
        func readObserved(reference: String, onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?) async throws -> Data? {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { read = continuation }
                onQueued?(PhysicalOperationReceipt(claim: 17, epoch: 9, reference: reference,
                                                  kind: .read, tracked: true))
                Task { await started.send() }
            }
        }
        func completeRead() {
            let saved = lock.withLock { () -> CheckedContinuation<Data?, Error>? in
                snapshot = .settled(status: 1)
                let value = read; read = nil
                return value
            }
            saved?.resume(returning: Data("fixture-git-token-only-00000".utf8))
        }
        func failCallerWhilePhysicalReadContinues() {
            let saved = lock.withLock { () -> CheckedContinuation<Data?, Error>? in
                let value = read; read = nil
                return value
            }
            saved?.resume(throwing: BrokenRead.callerSettled)
        }
        func finishPhysical() {
            let saved = lock.withLock { () -> [CheckedContinuation<PhysicalOperationSnapshot, Never>] in
                snapshot = .settled(status: -1)
                let value = physicalWaiters; physicalWaiters.removeAll()
                return value
            }
            saved.forEach { $0.resume(returning: .settled(status: -1)) }
        }
        func writeObserved(reference: String, value: Data, onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?) async throws { throw BrokenRead.callerSettled }
        func deleteObserved(reference: String, onQueued: (@Sendable (PhysicalOperationReceipt) -> Void)?) async throws { throw BrokenRead.callerSettled }
        func physicalSnapshot(claim: Int64) -> PhysicalOperationSnapshot { lock.withLock { snapshot } }
        func resolvePhysical(claim: Int64) -> Bool {
            lock.withLock {
                switch snapshot { case .settled, .neverDispatched: true; default: false }
            }
        }
        func awaitPhysicalSettlement(claim: Int64) async -> PhysicalOperationSnapshot {
            await withCheckedContinuation { continuation in
                lock.withLock { physicalWaiters.append(continuation) }
                Task { await physicalWaitStarted.send() }
            }
        }
    }

    @Test func cancellingCallerDoesNotReleaseReadOwnerBeforeRealCompletion() async throws {
        let observer = Observer(); let owned = Owned()
        let lease = G04GitCredentialLease(epoch: 9, current: { true }, observer: { observer }, owned: owned)
        let caller = Task { try await lease.leasedToken() }
        await observer.started.wait()
        caller.cancel()
        #expect(owned.count == 1)
        observer.completeRead()
        do { _ = try await caller.value; Issue.record("Cancelled caller published a token") }
        catch is CancellationError { }
        #expect(owned.count == 0)
    }

    @Test func failedReadWaitsForItsPhysicalOperationNotOnlyCallerResult() async throws {
        let observer = Observer(); let owned = Owned()
        let lease = G04GitCredentialLease(epoch: 9, current: { true }, observer: { observer }, owned: owned)
        let caller = Task { try await lease.leasedToken() }
        await observer.started.wait()
        observer.failCallerWhilePhysicalReadContinues()
        await observer.physicalWaitStarted.wait()
        #expect(owned.count == 1)
        observer.finishPhysical()
        do { _ = try await caller.value; Issue.record("Failed read returned a token") }
        catch is Observer.BrokenRead { }
        #expect(owned.count == 0)
    }

    @Test func epochRetirementFencesTokenAfterReadWithoutLosingOwnership() async throws {
        let observer = Observer(); let owned = Owned(); let flag = Flag()
        let lease = G04GitCredentialLease(epoch: 9, current: { flag.get() }, observer: { observer }, owned: owned)
        let caller = Task { try await lease.leasedToken() }
        await observer.started.wait()
        flag.retire()
        observer.completeRead()
        do { _ = try await caller.value; Issue.record("Retired root published a token") }
        catch G04GitCredentialLease.Failure.retired { }
        #expect(owned.count == 0)
    }
}
