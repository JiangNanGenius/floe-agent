// FloeExecution — lifecycle latch serializing Linux boot-asset commits
// against guest starts.
//
// A boot-asset adoption/rollback (LinuxGuestBootAssetUpdateService) must
// never interleave with a guest start that already resolved its boot pair,
// and a start must never observe a half-committed pair. Snapshots alone
// cannot promise that (a quiet probe can pass and a start can still begin
// before the commit lands), so this latch provides the real mutual
// exclusion:
//
//  - Every guest start acquires a START LEASE for its image from before
//    boot-path resolution until the session is registered. Leases carry a
//    unique identity (never an environment key), so two overlapping leases
//    for the same environment release independently and one release can
//    never drop a stranger's lease. Starts for an image with an active
//    COMMIT wait; a cancelled start wakes, removes its waiter, and throws
//    CancellationError WITHOUT running its operation.
//  - An adoption/rollback runs under an EXCLUSIVE PASS for the image:
//    FIFO-serialized per image (two services sharing one gate can never
//    co-run), waits for all outstanding start leases, blocks new starts
//    until the pass completes, then runs the operation (which re-proves
//    quiet and commits). The commit window is small (verified file copies
//    plus one sidecar write), so starts only ever wait seconds.
//
// Environments CREATED while a commit is in flight take their lease after
// the commit and therefore resolve the newly committed pair — consistent
// by construction; no enumeration of "future" environments is needed.
//
// `imageID == nil` (descriptor-less environment) takes no lease: it cannot
// boot this image, so it can never race a commit for it.
//
// Reentrancy: performExclusive refuses to run inside a start lease held by
// the same task; the real App never adopts during a start, and a typed
// refusal beats a self-deadlock.

import Foundation

private enum BootAssetLeaseContext {
    @TaskLocal static var heldStartLeaseImage: String?
}

public actor LinuxGuestBootAssetGate {
    /// Default instance shared by the registry and the update service.
    /// Tests inject their own.
    public static let `default` = LinuxGuestBootAssetGate()

    private struct StartLease: Hashable {
        var id: Int
        var imageID: String
    }

    private var nextLeaseID: Int = 0
    private var nextWaiterSeq: Int = 0
    private var activeStarts: [String: Set<StartLease>] = [:]
    /// FIFO of commit passes per image; only the head runs.
    private var commitQueue: [String: [UUID]] = [:]
    /// Ordered waiters (FIFO resume); dictionary form only for cancel.
    private var startWaiterList: [String: [(id: UUID, seq: Int, resume: CheckedContinuation<Void, Swift.Error>)]] = [:]
    private var commitWaiterList: [String: [(id: UUID, seq: Int, resume: CheckedContinuation<Void, Never>)]] = [:]

    public init() {}

    /// Runs `operation` (a guest start) while holding this start's lease
    /// for `imageID`. A nil imageID runs without a lease. Cancellation
    /// while waiting for a commit discards the start: no lease is taken,
    /// the operation never runs, and CancellationError propagates.
    public func withStartLease<T: Sendable>(
        imageID: String?,
        environmentID: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        guard let imageID, !imageID.isEmpty else {
            return try await operation()
        }
        let lease = try await acquireStart(imageID: imageID, environmentID: environmentID)
        do {
            let result = try await BootAssetLeaseContext.$heldStartLeaseImage
                .withValue(imageID) {
                    try await operation()
                }
            await releaseStart(lease)
            return result
        } catch {
            await releaseStart(lease)
            throw error
        }
    }

    /// Runs `operation` (an adoption/rollback commit) with exclusive access
    /// to `imageID`: FIFO-serialized against other passes for the image,
    /// waits for every outstanding start lease, blocks new starts until the
    /// pass completes, then runs the operation. The caller performs its
    /// quiet re-proof and the file commit inside `operation`.
    ///
    /// Fails fast with `.imageBusy` when called from inside a start lease
    /// for the same image: the real App never adopts during a start, and a
    /// typed refusal beats a self-deadlock.
    public func performExclusive<T: Sendable>(
        imageID: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        if BootAssetLeaseContext.heldStartLeaseImage == imageID {
            throw LinuxGuestBootAssetUpdateError.imageBusy(id: imageID)
        }
        let token = enqueueCommit(imageID: imageID)
        do {
            await waitForCommitTurn(imageID: imageID, token: token)
            let result = try await operation()
            await finishCommit(imageID: imageID, token: token)
            return result
        } catch {
            await finishCommit(imageID: imageID, token: token)
            throw error
        }
    }

    /// True while an exclusive pass for `imageID` holds the gate (tests and
    /// diagnostics).
    public func isCommitting(imageID: String) -> Bool {
        (commitQueue[imageID]?.first) != nil
    }

    /// Test/diagnostic visibility into outstanding start leases.
    public func activeStartCount(imageID: String) -> Int {
        activeStarts[imageID]?.count ?? 0
    }

    /// Test/diagnostic visibility into exclusive passes waiting for (or
    /// holding) one image. Enqueue order is the FIFO order passes run in, so
    /// a test can line two independent services up deterministically.
    public func queuedCommitCount(imageID: String) -> Int {
        commitQueue[imageID]?.count ?? 0
    }

    // MARK: internals

    private func makeLease(imageID: String) -> StartLease {
        nextLeaseID &+= 1
        return StartLease(id: nextLeaseID, imageID: imageID)
    }

    private func acquireStart(
        imageID: String,
        environmentID: String
    ) async throws -> StartLease {
        // environmentID is accepted for signature stability/diagnostics;
        // identity is what releases, never the environment key.
        _ = environmentID
        while true {
            if commitQueue[imageID]?.isEmpty == false {
                try await waitForStartSlot(imageID: imageID, waitID: UUID())
                continue
            }
            let lease = makeLease(imageID: imageID)
            activeStarts[imageID, default: []].insert(lease)
            return lease
        }
    }

    /// Suspends until the image has no active commit pass. Throws
    /// CancellationError (without taking a lease) when the waiting task is
    /// cancelled.
    private func waitForStartSlot(
        imageID: String,
        waitID: UUID
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                nextWaiterSeq &+= 1
                startWaiterList[imageID, default: []].append(
                    (id: waitID, seq: nextWaiterSeq, resume: continuation)
                )
            }
        } onCancel: {
            Task { await self.cancelStartWait(imageID: imageID, waitID: waitID) }
        }
        // After any wake (commit finished): re-check above in the loop.
    }

    private func cancelStartWait(imageID: String, waitID: UUID) {
        guard var list = startWaiterList[imageID],
              let index = list.firstIndex(where: { $0.id == waitID }) else { return }
        let waiter = list.remove(at: index)
        startWaiterList[imageID] = list.isEmpty ? nil : list
        waiter.resume.resume(throwing: CancellationError())
    }

    private func releaseStart(_ lease: StartLease) {
        var leases = activeStarts[lease.imageID] ?? []
        leases.remove(lease)
        activeStarts[lease.imageID] = leases.isEmpty ? nil : leases
        if leases.isEmpty {
            let drained = commitWaiterList[lease.imageID] ?? []
            commitWaiterList[lease.imageID] = nil
            for waiter in drained { waiter.resume.resume() }
        }
    }

    private func enqueueCommit(imageID: String) -> UUID {
        let token = UUID()
        commitQueue[imageID, default: []].append(token)
        return token
    }

    /// Waits until the image's start leases drain AND this pass is at the
    /// head of the FIFO. Registration and the state check are one
    /// actor-synchronous step, so a completion poke can never be missed.
    private func waitForCommitTurn(imageID: String, token: UUID) async {
        while true {
            let startsPending = !(activeStarts[imageID]?.isEmpty ?? true)
            let atHead = commitQueue[imageID]?.first == token
            if !startsPending && atHead { return }
            await withCheckedContinuation { continuation in
                nextWaiterSeq &+= 1
                commitWaiterList[imageID, default: []].append(
                    (id: UUID(), seq: nextWaiterSeq, resume: continuation)
                )
            }
        }
    }

    private func finishCommit(imageID: String, token: UUID) {
        guard var queue = commitQueue[imageID] else { return }
        queue.removeAll { $0 == token }
        commitQueue[imageID] = queue.isEmpty ? nil : queue
        // Wake everyone: start waiters resume when the queue is empty; the
        // next queued pass re-checks its head position in its loop.
        let starts = startWaiterList[imageID] ?? []
        startWaiterList[imageID] = nil
        for waiter in starts { waiter.resume.resume() }
        let commits = commitWaiterList[imageID] ?? []
        commitWaiterList[imageID] = nil
        for waiter in commits { waiter.resume.resume() }
    }
}
