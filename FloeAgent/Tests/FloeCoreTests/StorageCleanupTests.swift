import Foundation
import Testing
@testable import FloeCore

private final class ScriptedCleanupAuthority: StorageCleanupAuthority {
    private var idle: Bool
    private var retainNames: Set<String>
    private var idleCallCount = 0
    /// After this many idle calls, isOwnerIdle starts returning false.
    private let idleCallBudget: Int?

    init(idle: Bool = true, retainNames: Set<String> = [], idleCallBudget: Int? = nil) {
        self.idle = idle
        self.retainNames = retainNames
        self.idleCallBudget = idleCallBudget
    }

    // MainActor isolation serializes access to the counters; no locks needed.
    @MainActor
    func isOwnerIdle(_ owner: StorageCleanupOwner) async -> Bool {
        idleCallCount += 1
        if let idleCallBudget, idleCallCount > idleCallBudget { return false }
        return idle
    }

    @MainActor
    func shouldRetain(itemURL: URL, name: String, owner: StorageCleanupOwner) async -> Bool {
        retainNames.contains(name)
    }

    /// Grants a deletion claim for every eligible item unless a name is in
    /// `claimDeniedNames` (used to exercise the busy-skip path).
    private var claimDeniedNames: Set<String> = []

    @MainActor
    func claimDeletion(itemURL: URL, name: String, owner: StorageCleanupOwner) async -> StorageCleanupDeletionClaim? {
        guard !claimDeniedNames.contains(name) else { return nil }
        return StorageCleanupDeletionClaim(id: UUID(), path: itemURL.path)
    }

    @MainActor
    func releaseDeletionClaim(_ claim: StorageCleanupDeletionClaim) async {}
}

@MainActor
@Suite("Storage cleanup safety")
struct StorageCleanupTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ name: String, bytes: Int, at root: URL, modified: Date) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 0x11, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func candidate(root: URL, olderThan: Date, protectedNames: Set<String> = []) -> StorageCleanupCandidate {
        StorageCleanupCandidate(
            id: "candidate",
            owner: .temporary,
            title: "t",
            purpose: "p",
            retentionReason: "r",
            kind: .staleTemporary,
            root: root,
            olderThan: olderThan,
            protectedNames: protectedNames
        )
    }

    @Test func estimateFailsClosedWhenOwnerIsBusy() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("stale.bin", bytes: 4096, at: root, modified: Date.distantPast)
        let plan = StorageCleanupPlan(
            candidates: [candidate(root: root, olderThan: Date())],
            retained: []
        )
        let busy = ScriptedCleanupAuthority(idle: false)
        let estimate = await StorageCleanup.estimate(plan: plan, authority: busy)
        #expect(estimate.eligibleAllocatedBytes == 0)
        #expect(estimate.eligibleItemCount == 0)
        #expect(estimate.busyCandidateIDs == ["candidate"])

        let outcome = await StorageCleanup.execute(plan: plan, authority: busy)
        #expect(outcome.perCandidate["candidate"]?.deletedCount == 0)
        #expect(outcome.busyCandidateIDs == ["candidate"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("stale.bin").path))
    }

    @Test func executeDeletesOnlyEligibleItems() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cutoff = Date().addingTimeInterval(-3_600)
        let stale = try write("stale.bin", bytes: 4096, at: root, modified: Date().addingTimeInterval(-7_200))
        let recent = try write("recent.bin", bytes: 2048, at: root, modified: Date())
        let protected = try write("keep.bin", bytes: 1024, at: root, modified: Date.distantPast)
        // Directory with an active child must not be deleted even if its own
        // mtime looks old.
        let activeDir = root.appendingPathComponent("activeDir", isDirectory: true)
        try FileManager.default.createDirectory(at: activeDir, withIntermediateDirectories: true)
        _ = try write("child.bin", bytes: 4096, at: activeDir, modified: Date())
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: activeDir.path)

        let plan = StorageCleanupPlan(
            candidates: [candidate(root: root, olderThan: cutoff, protectedNames: ["keep.bin"])],
            retained: []
        )
        let authority = ScriptedCleanupAuthority(idle: true, retainNames: ["keep.bin"])
        let estimate = await StorageCleanup.estimate(plan: plan, authority: authority)
        #expect(estimate.eligibleItemCount == 1)
        #expect(estimate.eligibleAllocatedBytes >= 4096)

        let outcome = await StorageCleanup.execute(plan: plan, authority: authority)
        let result = try #require(outcome.perCandidate["candidate"])
        #expect(result.deletedCount == 1)
        #expect(result.skippedRecentCount >= 2) // recent.bin + activeDir (active child)
        #expect(result.skippedProtectedCount >= 1) // keep.bin
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: protected.path))
        #expect(FileManager.default.fileExists(atPath: activeDir.path))
        #expect(outcome.observedAllocatedChangeBytes >= 0)
    }

    @Test func cacheParentRootIsRejected() async {
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent("Caches", isDirectory: true)
        let candidate = StorageCleanupCandidate(
            id: "bad", owner: .floeCache, title: "t", purpose: "p", retentionReason: "r",
            kind: .regenerableCache, root: caches, olderThan: Date()
        )
        #expect(!StorageCleanup.isSweepSafe(candidate))
        let plan = StorageCleanupPlan(candidates: [candidate], retained: [])
        let outcome = await StorageCleanup.execute(plan: plan, authority: ScriptedCleanupAuthority())
        #expect(outcome.rejectedCandidateIDs == ["bad"])
    }

    @Test func ownerIsRevalidatedPerItem() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let cutoff = Date().addingTimeInterval(-3_600)
        _ = try write("a.bin", bytes: 1024, at: root, modified: Date.distantPast)
        _ = try write("b.bin", bytes: 1024, at: root, modified: Date.distantPast)
        let plan = StorageCleanupPlan(
            candidates: [candidate(root: root, olderThan: cutoff)],
            retained: []
        )
        // First idle probe (candidate) and eligibility enumeration pass; the
        // per-item probe then reports busy, so nothing may be deleted.
        let authority = ScriptedCleanupAuthority(idle: true, idleCallBudget: 1)
        let outcome = await StorageCleanup.execute(plan: plan, authority: authority)
        let result = try #require(outcome.perCandidate["candidate"])
        #expect(result.deletedCount == 0)
        #expect(result.skippedOwnerBusyCount >= 1)
    }

    @Test func retainedRegistrationsAreVisibleButNeverCandidates() {
        let plan = FloeStorageCleanupTestPlan.make()
        #expect(plan.retained.contains { $0.id == "promptLibrary" })
        #expect(!plan.candidates.contains { $0.id == "promptLibrary" })
    }
}

/// Test-only mirror of the app registry shape (the app registry lives in the
/// app target; this asserts the plan/authority contract in FloeCore).
private enum FloeStorageCleanupTestPlan {
    static func make() -> StorageCleanupPlan {
        StorageCleanupPlan(
            candidates: [
                StorageCleanupCandidate(
                    id: "temporary", owner: .temporary, title: "t", purpose: "p", retentionReason: "r",
                    kind: .staleTemporary,
                    root: FileManager.default.temporaryDirectory,
                    olderThan: Date().addingTimeInterval(-3_600)
                )
            ],
            retained: [
                StorageCleanupRetained(
                    id: "promptLibrary", owner: .floeCache, title: "Prompt library",
                    retentionReason: "user data",
                    root: FileManager.default.temporaryDirectory.appendingPathComponent("PromptLibrary")
                )
            ]
        )
    }
}

// MARK: - Lease center interleavings (critical review)

@Suite("Cleanup lease coordination")
struct StorageCleanupLeaseTests {
    private func scratch(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LeaseTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }

    @Test func claimRejectedWhileLeasedAndViceVersa() async throws {
        let center = StorageCleanupLeaseCenter()
        let path = scratch("a.bin")
        await center.acquire(path: path.path)
        #expect(await center.claimForDeletion(path: path.path) == nil)
        await center.release(path: path.path)
        let claim = await center.claimForDeletion(path: path.path)
        #expect(claim != nil)
        // While the claim is held, (a) acquiring is rejected and (b) a
        // duplicate/overlapping claim is rejected.
        #expect(await center.acquire(path: path.path) == false)
        #expect(await center.acquireToken(path: path.path) == nil)
        #expect(await center.claimForDeletion(path: path.path) == nil)
        await center.releaseClaim(claim!.id)
        // After release both paths work again.
        #expect(await center.acquire(path: path.path) == true)
        await center.release(path: path.path)
        #expect(await center.claimForDeletion(path: path.path) != nil)
    }

    @Test func descendantAndAncestorLeasesBlockDirectoryClaims() async throws {
        let center = StorageCleanupLeaseCenter()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeaseTests-\(UUID().uuidString)", isDirectory: true)
        let parent = root.appendingPathComponent("dir", isDirectory: true)
        let child = parent.appendingPathComponent("inner.txt")
        // Lease on the child blocks a claim on the parent directory.
        await center.acquire(path: child.path)
        #expect(await center.claimForDeletion(path: parent.path) == nil)
        await center.release(path: child.path)
        // Lease on the parent blocks a claim on the child.
        await center.acquire(path: parent.path)
        #expect(await center.claimForDeletion(path: child.path) == nil)
        await center.release(path: parent.path)
        #expect(await center.claimForDeletion(path: parent.path) != nil)
    }

    @Test func referenceCountedLeasesDoNotUnprotectEachOther() async throws {
        let center = StorageCleanupLeaseCenter()
        let path = scratch("b.bin")
        await center.acquire(path: path.path)
        await center.acquire(path: path.path)
        await center.release(path: path.path)
        // One holder remains: still protected.
        #expect(await center.claimForDeletion(path: path.path) == nil)
        await center.release(path: path.path)
        #expect(await center.claimForDeletion(path: path.path) != nil)
    }

    @Test func tokenAcquisitionDuringClaimIsRejected() async throws {
        let center = StorageCleanupLeaseCenter()
        let path = scratch("c.bin")
        let claim = await center.claimForDeletion(path: path.path)
        #expect(claim != nil)
        // A consumer trying to take ownership mid-deletion is refused.
        #expect(await center.acquireToken(path: path.path) == nil)
        await center.releaseClaim(claim!.id)
        let token = await center.acquireToken(path: path.path)
        #expect(token != nil)
        token?.release()
    }

    @Test func leasedScratchIsProtectedFromCleanupEngine() async throws {
        let center = StorageCleanupLeaseCenter.shared
        // Hermetic candidate root (not the global scratch root): only the two
        // directories this test creates are eligible.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LeaseEngine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let past = Date().addingTimeInterval(-7_200)
        func makeOld(_ name: String) throws -> URL {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: dir.path)
            return dir
        }
        let liveDir = try makeOld("notes-\(UUID().uuidString.lowercased())")
        let staleDir = try makeOld("notes-\(UUID().uuidString.lowercased())")
        let token = await center.acquireToken(path: liveDir.path)
        #expect(token != nil)
        let candidate = StorageCleanupCandidate(
            id: "scratch", owner: .temporary, title: "t", purpose: "p", retentionReason: "r",
            kind: .staleTemporary, root: root, olderThan: Date().addingTimeInterval(-3_600),
            requiredNamePrefixes: ["notes"]
        )
        struct FailClosed: StorageCleanupAuthority {
            func isOwnerIdle(_ owner: StorageCleanupOwner) async -> Bool { true }
            func shouldRetain(itemURL: URL, name: String, owner: StorageCleanupOwner) async -> Bool { false }
            func claimDeletion(itemURL: URL, name: String, owner: StorageCleanupOwner) async -> StorageCleanupDeletionClaim? {
                await StorageCleanupLeaseCenter.shared.claimForDeletion(path: itemURL.path)
            }
            func releaseDeletionClaim(_ claim: StorageCleanupDeletionClaim) async {
                await StorageCleanupLeaseCenter.shared.releaseClaim(claim.id)
            }
        }
        let plan = { StorageCleanupPlan(candidates: [candidate], retained: []) }
        let outcome = await StorageCleanup.execute(plan: plan(), authority: FailClosed())
        #expect(outcome.perCandidate["scratch"]?.deletedCount == 1) // only the unleased one
        #expect(FileManager.default.fileExists(atPath: liveDir.path))
        #expect(!FileManager.default.fileExists(atPath: staleDir.path))
        token?.release()
        let outcome2 = await StorageCleanup.execute(plan: plan(), authority: FailClosed())
        #expect(outcome2.perCandidate["scratch"]?.deletedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: liveDir.path))
    }
}
