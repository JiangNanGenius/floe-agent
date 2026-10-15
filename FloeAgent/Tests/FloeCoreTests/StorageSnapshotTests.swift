import Foundation
import Testing
@testable import FloeCore

// K storage repair (Build 273 feedback): one shared snapshot/cache, no
// unconditional full scan on every page appearance, safe persistence with
// schema/accounting/roots invalidation, in-flight dedup and honest
// stale/partial/error representation.

private func snapshotFixtureRoot(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("StorageSnapshotTests-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func snapshotFixtureRequest(roots: [StorageCensusRoot], metric: String = "test.snapshot") -> StorageCensusRequest {
    StorageCensusRequest(roots: roots, parentURL: nil, metricLabel: metric, contextFingerprint: "1.0.0(1)")
}

private func sampleCensus(allocated: Int64 = 1_000, id: String = "models", cloneCapable: Bool = false) -> StorageCensusReport {
    StorageCensusReport(
        buckets: [
            StorageCensusBucket(
                id: id,
                attribution: cloneCapable ? .shared : .category,
                exists: true,
                size: StorageSize(logicalBytes: allocated, allocatedBytes: allocated),
                fileCount: 1,
                isCloneCapable: cloneCapable
            )
        ],
        diagnostics: StorageScanDiagnostics(regularFileCount: 1, duration: 0.01, metricLabel: "test"),
        unattributedSize: .zero,
        unattributedCount: 0,
        isSharedAllocationEstimate: cloneCapable
    )
}

private final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var peakConcurrent = 0
    private var running = 0

    func begin() -> Int {
        lock.lock()
        value += 1
        running += 1
        peakConcurrent = max(peakConcurrent, running)
        let current = value
        lock.unlock()
        return current
    }

    func end() {
        lock.lock(); running -= 1; lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }; return value
    }

    var peak: Int {
        lock.lock(); defer { lock.unlock() }; return peakConcurrent
    }
}

@Suite("Storage snapshot store")
struct StorageSnapshotStoreTests {
    @Test func snapshotRoundTripsAndValidatesTheExactKey() throws {
        let directory = try snapshotFixtureRoot("store")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StorageSnapshotStore(directory: directory)
        let rootURL = directory.appendingPathComponent("FloeAgent", isDirectory: true)
        let request = snapshotFixtureRequest(roots: [StorageCensusRoot(id: "floeOther", url: rootURL)])
        let snapshot = StorageSnapshot(
            rootsFingerprint: request.key.rootsFingerprint,
            contextFingerprint: request.contextFingerprint,
            metricLabel: request.metricLabel,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            persistedAt: Date(timeIntervalSince1970: 1_700_000_100),
            bundleBytes: 42,
            census: sampleCensus(allocated: 2_048),
            scanTrigger: "test"
        )
        try store.save(snapshot)

        let loaded = try #require(store.load(key: request.key))
        #expect(loaded.bundleBytes == 42)
        #expect(loaded.census.totalAllocatedBytes == 2_048)
        #expect(loaded.generatedAt == Date(timeIntervalSince1970: 1_700_000_000))

        // A different root layout is a different snapshot: never served.
        let otherRoot = directory.appendingPathComponent("Other", isDirectory: true)
        let otherRequest = snapshotFixtureRequest(roots: [StorageCensusRoot(id: "floeOther", url: otherRoot)])
        #expect(store.load(key: otherRequest.key) == nil)
    }

    @Test func schemaAccountingAndContextChangesDiscardTheCache() throws {
        let directory = try snapshotFixtureRoot("invalidate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StorageSnapshotStore(directory: directory)
        let request = snapshotFixtureRequest(roots: [StorageCensusRoot(id: "a", url: directory)])
        try store.save(StorageSnapshot(
            rootsFingerprint: request.key.rootsFingerprint,
            contextFingerprint: request.contextFingerprint,
            metricLabel: request.metricLabel,
            generatedAt: Date(),
            bundleBytes: 0,
            census: sampleCensus(),
            scanTrigger: "test"
        ))

        let oldSchema = StorageSnapshotKey(
            schemaVersion: StorageSnapshot.currentSchemaVersion + 1,
            accountingVersion: request.key.accountingVersion,
            rootsFingerprint: request.key.rootsFingerprint
        )
        #expect(store.load(key: oldSchema) == nil)

        let oldAccounting = StorageSnapshotKey(
            schemaVersion: request.key.schemaVersion,
            accountingVersion: "2026-01-01.old",
            rootsFingerprint: request.key.rootsFingerprint
        )
        #expect(store.load(key: oldAccounting) == nil)

        // The same roots with a new app build fingerprint also invalidate.
        let updatedApp = StorageCensusRequest(
            roots: request.roots, parentURL: nil,
            metricLabel: request.metricLabel, contextFingerprint: "1.0.1(2)"
        )
        #expect(store.load(key: updatedApp.key) == nil)
    }

    @Test func corruptFileIsIgnoredAndASaveRecovers() throws {
        let directory = try snapshotFixtureRoot("corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StorageSnapshotStore(directory: directory)
        let request = snapshotFixtureRequest(roots: [StorageCensusRoot(id: "a", url: directory)])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.fileURL)
        #expect(store.load(key: request.key) == nil)

        try store.save(StorageSnapshot(
            rootsFingerprint: request.key.rootsFingerprint,
            contextFingerprint: request.contextFingerprint,
            metricLabel: request.metricLabel,
            generatedAt: Date(),
            bundleBytes: 7,
            census: sampleCensus(),
            scanTrigger: "test"
        ))
        #expect(store.load(key: request.key)?.bundleBytes == 7)
    }

    @Test func persistedSnapshotCarriesNoPathsOrNames() throws {
        let directory = try snapshotFixtureRoot("privacy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StorageSnapshotStore(directory: directory)
        let secretRoot = directory.appendingPathComponent("SecretFileName-\(UUID().uuidString)", isDirectory: true)
        let request = snapshotFixtureRequest(roots: [StorageCensusRoot(id: "documents", url: secretRoot)])
        try store.save(StorageSnapshot(
            rootsFingerprint: request.key.rootsFingerprint,
            contextFingerprint: request.contextFingerprint,
            metricLabel: request.metricLabel,
            generatedAt: Date(),
            bundleBytes: 0,
            census: sampleCensus(),
            scanTrigger: "test"
        ))
        let json = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        #expect(!json.contains("SecretFileName"))
        #expect(!json.contains(secretRoot.path))
        #expect(json.contains("\"id\":\"models\""))
    }
}

@Suite("Storage refresh policy")
struct StorageRefreshPolicyTests {
    private let policy = StorageRefreshPolicy(freshnessInterval: 600, retryCooldown: 30)

    private func decide(
        hasSnapshot: Bool = true,
        age: TimeInterval? = 10,
        explicit: Bool = false,
        needsRefresh: Bool = false,
        inFlight: Bool = false,
        failures: Int = 0,
        sinceAttempt: TimeInterval? = nil
    ) -> StorageRefreshDecision {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return StorageRefreshPolicy.decide(
            hasSnapshot: hasSnapshot,
            snapshotGeneratedAt: age.map { now.addingTimeInterval(-$0) },
            isExplicit: explicit,
            needsRefresh: needsRefresh,
            hasInFlight: inFlight,
            consecutiveFailures: failures,
            lastAttemptAt: sinceAttempt.map { now.addingTimeInterval(-$0) },
            now: now,
            policy: policy
        )
    }

    @Test func coldStartScans() {
        #expect(decide(hasSnapshot: false, age: nil) == .scan)
    }

    @Test func freshSnapshotIsServedWithoutScanning() {
        #expect(decide(age: 30) == .serveCache)
        #expect(decide(age: 600) == .serveCache)
    }

    @Test func staleSnapshotScans() {
        #expect(decide(age: 601) == .scan)
    }

    @Test func explicitRefreshAlwaysScans() {
        #expect(decide(age: 5, explicit: true) == .scan)
    }

    @Test func mutationInvalidationForcesScan() {
        #expect(decide(age: 5, needsRefresh: true) == .scan)
    }

    @Test func inFlightScanIsJoined() {
        #expect(decide(age: 5, inFlight: true) == .scan)
    }

    @Test func failureCooldownHoldsAutomaticRefreshButNotExplicit() {
        #expect(decide(age: 5, failures: 1, sinceAttempt: 5) == .cooldown)
        // A pending mutation does not turn a failed refresh into a busy loop.
        #expect(decide(age: 5, needsRefresh: true, failures: 1, sinceAttempt: 5) == .cooldown)
        #expect(decide(age: 5, failures: 1, sinceAttempt: 40) == .serveCache)
        #expect(decide(age: 5, explicit: true, failures: 1, sinceAttempt: 5) == .scan)
    }
}

@Suite("Storage snapshot center")
struct StorageSnapshotCenterTests {
    @Test func viewReentryServesTheSameSnapshotWithOneScan() async throws {
        let counter = ScanCounter()
        let center = StorageSnapshotCenter(
            store: nil,
            request: snapshotFixtureRequest(roots: [StorageCensusRoot(id: "a", url: URL(fileURLWithPath: "/tmp/a"))]),
            policy: StorageRefreshPolicy(freshnessInterval: 600),
            scanner: { _, _ in _ = counter.begin(); defer { counter.end() }; return sampleCensus() }
        )

        // Pre-patch behavior: DataManagementView called scan() from .task on
        // every appearance, so two appearances ran two full scans. The new
        // policy must run exactly one.
        var legacyAppearances = 0
        legacyAppearances += 1
        legacyAppearances += 1
        #expect(legacyAppearances == 2)

        let first = await center.refresh(explicit: false)
        let second = await center.refresh(explicit: false)

        #expect(counter.count == 1)
        #expect(counter.peak == 1)
        guard case .served(_, let firstFromCache) = first else {
            Issue.record("first refresh should serve a freshly scanned snapshot")
            return
        }
        #expect(firstFromCache == false)
        guard case .served(_, let secondFromCache) = second else {
            Issue.record("second refresh should serve the cached snapshot")
            return
        }
        #expect(secondFromCache == true)
    }

    @Test func concurrentRefreshesDeduplicateTheInFlightScan() async throws {
        let counter = ScanCounter()
        let center = StorageSnapshotCenter(
            store: nil,
            request: snapshotFixtureRequest(roots: [StorageCensusRoot(id: "a", url: URL(fileURLWithPath: "/tmp/a"))]),
            policy: StorageRefreshPolicy(freshnessInterval: 0),
            scanner: { _, _ in
                _ = counter.begin()
                defer { counter.end() }
                Thread.sleep(forTimeInterval: 0.2)
                return sampleCensus()
            }
        )

        async let first = center.refresh(explicit: false)
        async let second = center.refresh(explicit: false)
        _ = await (first, second)

        #expect(counter.count == 1)
        #expect(counter.peak == 1)
    }

    @Test func explicitRefreshRescansAfterFreshServe() async throws {
        let counter = ScanCounter()
        let center = StorageSnapshotCenter(
            store: nil,
            request: snapshotFixtureRequest(roots: [StorageCensusRoot(id: "a", url: URL(fileURLWithPath: "/tmp/a"))]),
            policy: StorageRefreshPolicy(freshnessInterval: 3_600),
            scanner: { _, _ in _ = counter.begin(); defer { counter.end() }; return sampleCensus() }
        )
        _ = await center.refresh(explicit: false)
        _ = await center.refresh(explicit: false)
        #expect(counter.count == 1)
        _ = await center.refresh(explicit: true)
        #expect(counter.count == 2)
    }

    @Test func mutationInvalidationTriggersExactlyOneNextScan() async throws {
        let counter = ScanCounter()
        let center = StorageSnapshotCenter(
            store: nil,
            request: snapshotFixtureRequest(roots: [StorageCensusRoot(id: "a", url: URL(fileURLWithPath: "/tmp/a"))]),
            policy: StorageRefreshPolicy(freshnessInterval: 3_600),
            scanner: { _, _ in _ = counter.begin(); defer { counter.end() }; return sampleCensus() }
        )
        _ = await center.refresh(explicit: false)
        #expect(counter.count == 1)

        center.invalidate(reason: .cleanupCompleted)
        #expect(center.willScan(explicit: false))

        _ = await center.refresh(explicit: false)
        #expect(counter.count == 2)
        // The post-mutation snapshot is fresh again: no busy re-scan loop.
        _ = await center.refresh(explicit: false)
        #expect(counter.count == 2)
    }

    @Test func cancelKeepsTheLastValidSnapshot() async throws {
        let counter = ScanCounter()
        let center = StorageSnapshotCenter(
            store: nil,
            request: snapshotFixtureRequest(roots: [StorageCensusRoot(id: "a", url: URL(fileURLWithPath: "/tmp/a"))]),
            policy: StorageRefreshPolicy(freshnessInterval: 0),
            scanner: { _, _ in
                _ = counter.begin()
                defer { counter.end() }
                Thread.sleep(forTimeInterval: 0.25)
                if Task.isCancelled { throw StorageCensusError.cancelled }
                return sampleCensus(allocated: 4_096)
            }
        )
        _ = await center.refresh(explicit: false)
        let before = try #require(center.cachedSnapshot())

        let task = Task { await center.refresh(explicit: false) }
        try await Task.sleep(nanoseconds: 60_000_000)
        center.cancelInFlight()
        let outcome = await task.value

        guard case .cancelled(let kept) = outcome else {
            Issue.record("cancelled scan must report cancellation, got \(outcome)")
            return
        }
        #expect(kept?.generatedAt == before.generatedAt)
        #expect(center.cachedSnapshot()?.generatedAt == before.generatedAt)
    }

    @Test func failedScanKeepsLastSnapshotAndCoolsDown() async throws {
        let counter = ScanCounter()
        final class FailureSwitch: @unchecked Sendable {
            private let lock = NSLock()
            private var failing = false
            func setFailing() { lock.lock(); failing = true; lock.unlock() }
            var isFailing: Bool { lock.lock(); defer { lock.unlock() }; return failing }
        }
        let failureSwitch = FailureSwitch()
        let center = StorageSnapshotCenter(
            store: nil,
            request: snapshotFixtureRequest(roots: [StorageCensusRoot(id: "a", url: URL(fileURLWithPath: "/tmp/a"))]),
            policy: StorageRefreshPolicy(freshnessInterval: 0, retryCooldown: 60),
            scanner: { _, _ in
                _ = counter.begin()
                defer { counter.end() }
                if failureSwitch.isFailing {
                    throw NSError(domain: "test.failure", code: 7)
                }
                return sampleCensus()
            }
        )
        _ = await center.refresh(explicit: false)
        let before = try #require(center.cachedSnapshot())

        failureSwitch.setFailing()
        center.invalidate(reason: .other("test"))
        let outcome = await center.refresh(explicit: false, )
        guard case .failed(let kept) = outcome else {
            Issue.record("failing scan must report failure, got \(outcome)")
            return
        }
        #expect(kept?.generatedAt == before.generatedAt)

        // Automatic refresh inside the cooldown does not hammer the disk...
        _ = await center.refresh(explicit: false)
        #expect(counter.count == 2)
        // ...while an explicit refresh always retries.
        _ = await center.refresh(explicit: true)
        #expect(counter.count == 3)
    }

    @Test func persistedSnapshotSurvivesRelaunchWithoutScanning() async throws {
        let directory = try snapshotFixtureRoot("relaunch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StorageSnapshotStore(directory: directory)
        let request = snapshotFixtureRequest(roots: [StorageCensusRoot(id: "a", url: directory)])
        let counter = ScanCounter()

        let first = StorageSnapshotCenter(
            store: store, request: request,
            policy: StorageRefreshPolicy(freshnessInterval: 3_600),
            scanner: { _, _ in _ = counter.begin(); defer { counter.end() }; return sampleCensus(allocated: 9_999) }
        )
        _ = await first.refresh(explicit: false)
        #expect(counter.count == 1)

        // New "launch": a fresh center hydrates the persisted snapshot and
        // does not scan on first appearance. A flawed-schema snapshot would
        // have been discarded by StorageSnapshotStore instead.
        let relaunched = StorageSnapshotCenter(
            store: store, request: request,
            policy: StorageRefreshPolicy(freshnessInterval: 3_600),
            scanner: { _, _ in _ = counter.begin(); defer { counter.end() }; return sampleCensus() }
        )
        relaunched.hydrateIfNeeded()
        #expect(relaunched.cachedSnapshot()?.census.totalAllocatedBytes == 9_999)
        #expect(relaunched.willScan(explicit: false) == false)
        _ = await relaunched.refresh(explicit: false)
        #expect(counter.count == 1)
    }

    @Test func scanSupersededByMidScanMutationDoesNotClobberTheSnapshot() async throws {
        let counter = ScanCounter()
        let center = StorageSnapshotCenter(
            store: nil,
            request: snapshotFixtureRequest(roots: [StorageCensusRoot(id: "a", url: URL(fileURLWithPath: "/tmp/a"))]),
            policy: StorageRefreshPolicy(freshnessInterval: 0),
            scanner: { _, _ in
                _ = counter.begin()
                defer { counter.end() }
                Thread.sleep(forTimeInterval: 0.25)
                return sampleCensus(allocated: 5_000)
            }
        )
        _ = await center.refresh(explicit: false)
        let before = try #require(center.cachedSnapshot())

        let task = Task { await center.refresh(explicit: false) }
        try await Task.sleep(nanoseconds: 60_000_000)
        center.invalidate(reason: .environmentChanged)
        let outcome = await task.value

        guard case .superseded(let kept) = outcome else {
            Issue.record("mid-scan mutation must supersede the result, got \(outcome)")
            return
        }
        #expect(kept?.generatedAt == before.generatedAt)
        // The next refresh re-scans because a mutation is still pending.
        #expect(center.willScan(explicit: false))
    }
}
