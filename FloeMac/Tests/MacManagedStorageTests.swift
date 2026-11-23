// SPDX-License-Identifier: MPL-2.0

import FloeCore
import XCTest

// Focused tests for Mac managed storage: bounded scan of a synthetic fixture
// tree, truthful per-category totals, outside-root rejection, and confirmed
// cleanup that keeps in-use, recent and foreign-prefix content.
//
// These tests compile into the same module as the unified sources (the
// FloeMacBridgeServiceTests pattern); no app-module import is used. An
// isolated StorageCleanupLeaseCenter is injected — no shared state, no real
// user directories.

final class MacManagedStorageTests: XCTestCase {
    private var fixtureRoot: URL?

    override func tearDown() {
        if let fixtureRoot { try? FileManager.default.removeItem(at: fixtureRoot) }
        fixtureRoot = nil
        super.tearDown()
    }

    private struct Fixture {
        let roots: MacManagedStorageRoots
        let managed: URL
        let scratchRoot: URL
        let oldScratch: URL
        let recentScratch: URL
        let foreignScratch: URL
    }

    private func makeFixture() throws -> Fixture {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-managed-storage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fixtureRoot = base

        let support = base.appendingPathComponent("Library/Application Support", isDirectory: true)
        let library = base.appendingPathComponent("Library", isDirectory: true)
        let temporary = base.appendingPathComponent("tmp", isDirectory: true)
        let managed = support.appendingPathComponent("Floe Mac Agent", isDirectory: true)
        let runtime = support.appendingPathComponent("FloeAgent", isDirectory: true)
        let caches = library.appendingPathComponent("Caches/org.floeagent.macbridge", isDirectory: true)
        let webKit = library.appendingPathComponent("WebKit/org.floeagent.macbridge", isDirectory: true)
        let scratchRoot = temporary.appendingPathComponent("FloeAgent/scratch", isDirectory: true)
        let oldScratch = scratchRoot.appendingPathComponent("task-aaaa", isDirectory: true)
        let recentScratch = scratchRoot.appendingPathComponent("notes-bbbb", isDirectory: true)
        let foreignScratch = scratchRoot.appendingPathComponent("unknown-cccc", isDirectory: true)
        for directory in [managed, runtime, caches, webKit, scratchRoot,
                          managed.appendingPathComponent("Drafts", isDirectory: true),
                          managed.appendingPathComponent("Images", isDirectory: true),
                          oldScratch, recentScratch, foreignScratch] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Real bytes in distinct categories (sizes are block multiples; exact
        // assertions use logical bytes, allocated assertions use >=).
        try Data(count: 40_960).write(to: managed.appendingPathComponent("Drafts/draft.bin"))
        try Data(count: 81_920).write(to: managed.appendingPathComponent("Images/image.bin"))
        try Data(count: 4_096).write(to: runtime.appendingPathComponent("runtime.bin"))
        try Data(count: 2_048).write(to: caches.appendingPathComponent("cache.bin"))
        try Data(count: 1_024).write(to: webKit.appendingPathComponent("webkit.bin"))
        // The agent database plus a WAL companion.
        try Data(count: 8_192).write(to: managed.appendingPathComponent("floe.sqlite"))
        try Data(count: 1_024).write(to: managed.appendingPathComponent("floe.sqlite-wal"))
        // An unattributed stray file under the managed root.
        try Data(count: 512).write(to: managed.appendingPathComponent("stray.bin"))

        // Scratch children: one old + quiescent, one recent, one foreign-prefix.
        try Data(count: 16_384).write(to: oldScratch.appendingPathComponent("work.bin"))
        try Data(count: 16_384).write(to: recentScratch.appendingPathComponent("work.bin"))
        try Data(count: 16_384).write(to: foreignScratch.appendingPathComponent("work.bin"))
        let past = Date().addingTimeInterval(-25 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: oldScratch.path)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: oldScratch.appendingPathComponent("work.bin").path)

        let roots = MacManagedStorageRoots(
            managed: managed,
            runtime: runtime,
            caches: caches,
            webKit: webKit,
            scratch: scratchRoot,
            temporary: temporary,
            allowedBases: [base]
        )
        return Fixture(roots: roots, managed: managed, scratchRoot: scratchRoot,
                       oldScratch: oldScratch, recentScratch: recentScratch, foreignScratch: foreignScratch)
    }

    @MainActor
    private func waitForReport(_ service: MacManagedStorageService, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(20)
        while service.report == nil, !service.scanFailed, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if service.scanFailed {
            XCTFail("scan failed", file: file, line: line)
        }
    }

    // MARK: - Bounded scan

    @MainActor
    func testScanReportsTruthfulCategoryTotals() async throws {
        let fixture = try makeFixture()
        let service = MacManagedStorageService(roots: fixture.roots,
                                               leaseCenter: .shared)
        service.refresh()
        try await waitForReport(service)

        let report = try XCTUnwrap(service.report)
        let byID = Dictionary(uniqueKeysWithValues: report.categories.map { ($0.id, $0) })
        XCTAssertEqual(byID["drafts"]?.fileCount, 1)
        XCTAssertEqual(byID["drafts"]?.logicalBytes, 40_960)
        XCTAssertGreaterThanOrEqual(byID["drafts"]?.allocatedBytes ?? 0, 40_960)
        XCTAssertEqual(byID["images"]?.logicalBytes, 81_920)
        XCTAssertEqual(byID["runtime"]?.logicalBytes, 4_096)
        XCTAssertEqual(byID["caches"]?.logicalBytes, 2_048)
        XCTAssertEqual(byID["webKit"]?.logicalBytes, 1_024)
        // The database row is measured as its own category (file + WAL).
        XCTAssertEqual(byID["database"]?.fileCount, 2)
        XCTAssertEqual(byID["database"]?.logicalBytes, 8_192 + 1_024)
        // The stray file under the managed root is "other", NOT part of any
        // child category and NOT silently dropped.
        XCTAssertEqual(report.other?.fileCount, 1)
        XCTAssertEqual(report.other?.logicalBytes, 512)

        // Reconciliation: rows sum to the reported total exactly, on both
        // bases.
        let allocatedSum = report.categories.reduce(Int64(0)) { $0 + $1.allocatedBytes }
            + (report.other?.allocatedBytes ?? 0)
        let logicalSum = report.categories.reduce(Int64(0)) { $0 + $1.logicalBytes }
            + (report.other?.logicalBytes ?? 0)
        XCTAssertEqual(allocatedSum, report.totalAllocatedBytes)
        XCTAssertEqual(logicalSum, report.totalLogicalBytes)
    }

    @MainActor
    func testDisallowedRootsAreRejected() throws {
        let fixture = try makeFixture()
        let roots = fixture.roots
        // A root outside every allowed base must be refused by the backstop.
        XCTAssertFalse(MacManagedStorageRootPolicy.isAllowed(URL(fileURLWithPath: "/var/tmp"), bases: roots.allowedBases))
        // Home root itself is always refused.
        XCTAssertFalse(MacManagedStorageRootPolicy.isAllowed(URL(fileURLWithPath: NSHomeDirectory()),
                                                             bases: roots.allowedBases))
        // Roots under the fixture base are accepted.
        XCTAssertTrue(MacManagedStorageRootPolicy.isAllowed(fixture.managed, bases: roots.allowedBases))
    }

    @MainActor
    func testRevealFailsClosedBeforeScanAndForUnknownCategories() async throws {
        let fixture = try makeFixture()
        let service = MacManagedStorageService(roots: fixture.roots,
                                               leaseCenter: .shared)
        XCTAssertFalse(service.reveal(categoryID: "drafts"), "nothing is revealed before a scan")
        service.refresh()
        try await waitForReport(service)
        XCTAssertFalse(service.reveal(categoryID: "does-not-exist"))
    }

    // MARK: - Confirmed cleanup

    @MainActor
    func testCleanupRemovesOnlyIdleOldOwnedScratch() async throws {
        let fixture = try makeFixture()
        let service = MacManagedStorageService(roots: fixture.roots, leaseCenter: .shared)

        await service.estimateCleanup()
        let estimate = try XCTUnwrap(service.estimate)
        // Only the old, quiescent, purpose-prefixed directory is eligible.
        // The per-item estimate is the top-level item's own allocated
        // bytes; on APFS a directory's own blocks are 0, so the truthful
        // freed figure is the census-based observed change below.
        XCTAssertEqual(estimate.eligibleItemCount, 1)
        XCTAssertNotNil(estimate.perCandidateBytes["floe.scratch"])

        await service.performCleanup()
        let result = try XCTUnwrap(service.cleanupResult)
        XCTAssertFalse(result.wasCancelled)
        XCTAssertTrue(result.rejectedCandidateIDs.isEmpty)
        XCTAssertTrue(result.busyCandidateIDs.isEmpty)
        let scratch = result.perCandidate["floe.scratch"]
        XCTAssertEqual(scratch?.deletedCount, 1)
        XCTAssertEqual(scratch?.skippedRecentCount, 1, "the recent directory stays")
        XCTAssertEqual(scratch?.skippedProtectedCount, 1, "the foreign-prefix directory stays")
        XCTAssertEqual(scratch?.skippedOwnerBusyCount, 0)
        XCTAssertGreaterThan(result.observedAllocatedChangeBytes, 0)

        var isDirectory: ObjCBool = false
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.oldScratch.path, isDirectory: &isDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.recentScratch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.foreignScratch.path))
    }

    @MainActor
    func testCleanupSkipsLeasedScratch() async throws {
        let fixture = try makeFixture()
        let leaseCenter = StorageCleanupLeaseCenter.shared
        // Lease a fresh old-looking scratch directory: cleanup must fail
        // closed at the candidate and keep everything.
        let leased = try await leaseCenter.makeLeasedScratch(
            purpose: "task",
            temporary: fixture.roots.temporary
        )
        let past = Date().addingTimeInterval(-25 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: leased.url.path)

        let service = MacManagedStorageService(roots: fixture.roots, leaseCenter: leaseCenter)
        await service.performCleanup()
        let result = try XCTUnwrap(service.cleanupResult)
        XCTAssertTrue(result.busyCandidateIDs.contains("floe.scratch"),
                      "a live lease blocks the candidate (fail closed)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leased.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.oldScratch.path),
                      "no item is deleted while the candidate owner is busy")
        leased.lease.release()
    }

    @MainActor
    func testCleanupPlanRetainsRealStores() throws {
        let fixture = try makeFixture()
        let service = MacManagedStorageService(roots: fixture.roots,
                                               leaseCenter: .shared)
        let plan = service.cleanupPlan()
        XCTAssertEqual(plan.candidates.map(\.id), ["floe.scratch"])
        let retainedIDs = Set(plan.retained.map(\.id))
        XCTAssertTrue(retainedIDs.contains("floe.managedRoot"))
        XCTAssertTrue(retainedIDs.contains("floe.runtimeRoot"))
        XCTAssertTrue(retainedIDs.contains("floe.cacheRoot"))
        XCTAssertTrue(retainedIDs.contains("floe.webKitRoot"))
        // The whole tmp root is never a candidate; only the dedicated scratch.
        XCTAssertFalse(plan.candidates.contains { $0.root.path == fixture.roots.temporary.path })
    }
}
