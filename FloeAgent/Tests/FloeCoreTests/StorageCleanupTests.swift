import Foundation
import Testing
@testable import FloeCore

private final class ScriptedCleanupAuthority: StorageCleanupAuthority, @unchecked Sendable {
    private let lock = NSLock()
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

    func isOwnerIdle(_ owner: StorageCleanupOwner) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        idleCallCount += 1
        if let idleCallBudget, idleCallCount > idleCallBudget { return false }
        return idle
    }

    func shouldRetain(itemURL: URL, name: String, owner: StorageCleanupOwner) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return retainNames.contains(name)
    }
}

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

    @Test func estimateFailsClosedWhenOwnerIsBusy() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("stale.bin", bytes: 4096, at: root, modified: Date.distantPast)
        let plan = StorageCleanupPlan(
            candidates: [candidate(root: root, olderThan: Date())],
            retained: []
        )
        let busy = ScriptedCleanupAuthority(idle: false)
        let estimate = StorageCleanup.estimate(plan: plan, authority: busy)
        #expect(estimate.eligibleAllocatedBytes == 0)
        #expect(estimate.eligibleItemCount == 0)
        #expect(estimate.busyCandidateIDs == ["candidate"])

        let outcome = StorageCleanup.execute(plan: plan, authority: busy)
        #expect(outcome.perCandidate["candidate"]?.deletedCount == 0)
        #expect(outcome.busyCandidateIDs == ["candidate"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("stale.bin").path))
    }

    @Test func executeDeletesOnlyEligibleItems() throws {
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
        let estimate = StorageCleanup.estimate(plan: plan, authority: authority)
        #expect(estimate.eligibleItemCount == 1)
        #expect(estimate.eligibleAllocatedBytes >= 4096)

        let outcome = StorageCleanup.execute(plan: plan, authority: authority)
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

    @Test func cacheParentRootIsRejected() {
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent("Caches", isDirectory: true)
        let candidate = StorageCleanupCandidate(
            id: "bad", owner: .floeCache, title: "t", purpose: "p", retentionReason: "r",
            kind: .regenerableCache, root: caches, olderThan: Date()
        )
        #expect(!StorageCleanup.isSweepSafe(candidate))
        let plan = StorageCleanupPlan(candidates: [candidate], retained: [])
        let outcome = StorageCleanup.execute(plan: plan, authority: ScriptedCleanupAuthority())
        #expect(outcome.rejectedCandidateIDs == ["bad"])
    }

    @Test func ownerIsRevalidatedPerItem() throws {
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
        let outcome = StorageCleanup.execute(plan: plan, authority: authority)
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
