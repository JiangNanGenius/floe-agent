// Synthetic native integration. No user/device DB or disk is opened.
// These tests use real SQLite WAL, FD identity, Crypto and Core clone/punch.
#if canImport(Darwin) && DEBUG
import Foundation
import Darwin
import SQLite3
import XCTest
@testable import FloeCore
@testable import FloeExecution

private final class RecoveryOptimizationEvidence: @unchecked Sendable {
    let domain: RuntimeV2MaintenanceDomain
    let closure: RuntimeV2RecoveryClosureAuthority
    weak var coordinator: RuntimeV2MaintenanceCoordinator?
    let lock = NSLock()
    var active = false
    var referenceVersion = 1
    var changeReferenceOnAdmission = false
    var admissions = 0
    var ownerAvailable = true
    var referenceComplete = true
    var referenceBlockers: [String] = []
    var referenceFingerprintAvailable = true
    var unattributedLiveUnknownCount = 0
    var admissionObserver: (@Sendable (Int) throws -> Void)?
    init(domain: RuntimeV2MaintenanceDomain, state: URL) {
        self.domain = domain
        closure = RuntimeV2RecoveryClosureAuthority(domain: domain, stateDirectory: state)
    }
    func raw() async -> RuntimeV2MaintenanceOwnerEvidence {
        let values = lock.withLock {
            (active: active, version: referenceVersion, ownerAvailable: ownerAvailable,
             referenceComplete: referenceComplete, referenceBlockers: referenceBlockers,
             fingerprintAvailable: referenceFingerprintAvailable,
             liveUnknownCount: unattributedLiveUnknownCount)
        }
        do {
            let rows = try await RuntimeV2LegacyRegistryReader.readAsync(domain: domain)
            return .init(isComplete: values.ownerAvailable && values.referenceComplete,
                blockers: values.ownerAvailable ? [] : ["synthetic_owner_unavailable"],
                registry: .init(isComplete: true),
                integrator: .init(storeRootPath: domain.root.path,
                                  leaseRegistryEnvironments: rows.leaseEnvironmentIDs, isComplete: true),
                references: .init(isComplete: values.referenceComplete,
                                  blockers: values.referenceBlockers,
                                  activeEnvironmentIDs: values.active ? ["env-a"] : [],
                                  unattributedLiveUnknownCount: values.liveUnknownCount,
                                  fingerprint: values.fingerprintAvailable
                                    ? FloeDigest.sha256Hex(Data("synthetic-refs-\(values.version)-active-\(values.active)".utf8)) : ""),
                filesystem: .init(leaseEnvironmentIDs: rows.leaseEnvironmentIDs,
                                  legacyRegistryFingerprint: rows.fingerprint))
        } catch {
            return .init(isComplete: false, blockers: ["synthetic_registry_unavailable"])
        }
    }
    func admitted() async -> RuntimeV2MaintenanceOwnerEvidence {
        let observation = lock.withLock {
            admissions += 1
            if changeReferenceOnAdmission && admissions == 2 { referenceVersion += 1 }
            return (admissionObserver, admissions)
        }
        do { try observation.0?(observation.1) }
        catch { return .init(isComplete: false, blockers: ["synthetic_admission_observer_failed"]) }
        var evidence = await raw()
        do {
            guard let coordinator else { throw StorageSparseDiskRewriteError.needsInspection("test-authority") }
            let intent = try await coordinator.nativeClosureIntent()
            return try await closure.proveClosed(evidence: evidence, intent: intent, coordinator: coordinator)
        } catch {
            evidence.isComplete = false
            evidence.blockers.append("synthetic_closed_proof_refused")
            if case RuntimeV2MaintenanceError.ownerEvidenceIncomplete(let codes) = error {
                evidence.blockers.append(contentsOf: codes)
            }
            return evidence
        }
    }
}

private final class RecoveryOptimizationFixture: @unchecked Sendable {
    let work: URL
    let root: URL
    let state: URL
    let relative: String
    let disk: URL
    let domain: RuntimeV2MaintenanceDomain
    let evidence: RecoveryOptimizationEvidence
    let coordinator: RuntimeV2MaintenanceCoordinator
    let adapter: RuntimeV2RecoveryOptimizationAdapter
    let original: Data
    var journals: URL { state.appendingPathComponent("sparse-journals") }
    var receipts: URL { state.appendingPathComponent("sparse-receipts") }

    init(staleMarker: Bool = false, baseDrift: Bool = false, registry: Bool = true) throws {
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capacity-native-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        guard let canonical = candidate.path.withCString({ realpath($0, nil) }) else { throw POSIXError(.ENOENT) }
        let workURL = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        free(canonical)
        let rootURL = workURL.appendingPathComponent("v2", isDirectory: true)
        let stateURL = workURL.appendingPathComponent("authority", isDirectory: true)
        let relativeName = "recovery/quarantine/runtime-vm-rt-env-a-" + UUID().uuidString
        let diskURL = rootURL.appendingPathComponent(relativeName + "/disk.img")
        for item in [relativeName, "runtime/vm", "environments/env-a", "registry"] {
            try FileManager.default.createDirectory(at: rootURL.appendingPathComponent(item), withIntermediateDirectories: true)
        }
        var bytes = Data(repeating: 0, count: 4 * 1_024 * 1_024)
        bytes[0] = 0x6B; bytes[bytes.count - 1] = 0xDA
        try bytes.write(to: diskURL)
        let base = String(repeating: "a", count: 128)
        func json(_ value: [String: Any], _ path: String) throws {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                .write(to: rootURL.appendingPathComponent(path))
        }
        try json(["version": 1, "environmentID": "env-a", "runtimeID": "rt-env-a",
                  "baseImageID": "synthetic-base", "bootBaseDiskDigest": base], relativeName + "/runtime.json")
        try json(["version": 1, "environmentID": "env-a", "baseImageID": "synthetic-base",
                  "baseRootfsSHA512": baseDrift ? String(repeating: "b", count: 128) : base],
                 "environments/env-a/metadata.json")
        try json(["version": 2, "environmentID": "env-a", "runtimeID": "rt-env-a",
                  "holdID": UUID().uuidString,
                  "preservedPath": staleMarker ? "runtime/vm/rt-env-a" : relativeName],
                 "environments/env-a/repair-hold.json")
        try Data("7\n".utf8).write(to: rootURL.appendingPathComponent("environments/env-a/repair-hold.generation"))
        // 57 SYNTHETIC historical leases; no state label proves closure.
        for index in 0..<57 {
            let id = index == 0 ? "env-a" : "env-\(index)"
            try FileManager.default.createDirectory(at: rootURL.appendingPathComponent("environments/" + id), withIntermediateDirectories: true)
            try Data("{\"historical\":true}\n".utf8).write(to: rootURL.appendingPathComponent("environments/" + id + "/lease.json"))
        }
        let fixedDomain = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: rootURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        RuntimeV2RecoveryAdmission.installSyntheticDomainForTests(domain: fixedDomain, stateDirectory: stateURL)
        if registry { _ = try Self.createRegistry(at: rootURL.appendingPathComponent("registry/runtime.sqlite"), leases: 57) }
        let source = RecoveryOptimizationEvidence(domain: fixedDomain, state: stateURL)
        let authority = try RuntimeV2MaintenanceCoordinator(domain: fixedDomain, stateDirectory: stateURL,
                                                           evidenceProvider: { await source.admitted() })
        source.coordinator = authority
        _ = RuntimeV2MaintenanceRegistry.install(authority)
        let optimizer = RuntimeV2RecoveryOptimizationAdapter(
            domain: fixedDomain, coordinator: authority, closureAuthority: source.closure,
            rawEvidence: { await source.raw() }, admittedEvidence: { await source.admitted() })
        self.work = workURL; self.root = rootURL; self.state = stateURL
        self.relative = relativeName; self.disk = diskURL; self.original = bytes
        self.domain = fixedDomain; self.evidence = source; self.coordinator = authority; self.adapter = optimizer
    }
    func cleanup() {
        RuntimeV2MaintenanceRegistry.unregister(domainRoot: root)
        try? FileManager.default.removeItem(at: work) // only this test's owned UUID root
    }
    static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StorageSparseDiskRewriteError.injectedFailure("synthetic-sql")
        }
    }
    static func createRegistry(at path: URL, leases: Int, keepWAL: Bool = false) throws -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let handle else { throw StorageSparseDiskRewriteError.injectedFailure("synthetic-open") }
        do {
            try execute(handle, "PRAGMA journal_mode=WAL")
            try execute(handle, "CREATE TABLE leases(environment_id TEXT PRIMARY KEY,runtime_id TEXT,incarnation TEXT,session_token TEXT,state TEXT)")
            try execute(handle, "CREATE TABLE queue_entries(id TEXT PRIMARY KEY,environment_id TEXT,state TEXT)")
            try execute(handle, "BEGIN")
            for index in 0..<leases {
                let id = index == 0 ? "env-a" : "env-\(index)"
                let state = index % 3 == 0 ? "held" : index % 3 == 1 ? "released" : "stale"
                try execute(handle, "INSERT INTO leases VALUES('\(id)','rt-\(id)','synthetic-incarnation','synthetic-token','\(state)')")
            }
            try execute(handle, "COMMIT")
            if keepWAL { return handle }
            guard sqlite3_close(handle) == SQLITE_OK else { throw StorageSparseDiskRewriteError.injectedFailure("synthetic-close") }
            return nil
        } catch { sqlite3_close_v2(handle); throw error }
    }
    func record() async throws -> LegacyRecoveryInventoryRecord {
        let report = try await adapter.inventory()
        return try XCTUnwrap(report.records.first,
                             "inventory: \(report.stopReasons); root: \(String(describing: report.rootDiagnostic))")
    }
    func preservedMetadata() throws -> [String: Data] {
        var values: [String: Data] = [:]
        for name in ["runtime.json"] {
            values[name] = try Data(contentsOf: root.appendingPathComponent(relative + "/" + name))
        }
        for name in ["metadata.json", "repair-hold.json", "repair-hold.generation", "lease.json"] {
            values[name] = try Data(contentsOf: root.appendingPathComponent("environments/env-a/" + name))
        }
        values["registry"] = try Data(contentsOf: root.appendingPathComponent("registry/runtime.sqlite"))
        return values
    }
}

private final class SyntheticRecoveryApplicationSupportFileManager: FileManager {
    let support: URL
    init(support: URL) { self.support = support; super.init() }

    override func url(for directory: SearchPathDirectory, in domain: SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
        if directory == .applicationSupportDirectory && domain == .userDomainMask { return support }
        return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
    }
}


private struct RelocatedOptimizationSession {
    let work: URL
    let domain: RuntimeV2MaintenanceDomain
    let state: URL
    let evidence: RecoveryOptimizationEvidence
    let coordinator: RuntimeV2MaintenanceCoordinator
    let adapter: RuntimeV2RecoveryOptimizationAdapter

    init(_ fixture: RecoveryOptimizationFixture, grouped: Bool = false) throws {
        let fm = FileManager.default
        let indexed = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("MaintenanceAuthority/" + fixture.domain.domainKey)
        try fm.createDirectory(at: indexed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: fixture.state, to: indexed)
        let moved = fixture.work.deletingLastPathComponent()
            .appendingPathComponent(fixture.work.lastPathComponent + "-new-container")
        try fm.moveItem(at: fixture.work, to: moved)
        let current = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: moved.appendingPathComponent("v2"))
        let histories: RuntimeV2MaintenanceHistoryLayout?
        let selected: URL
        if grouped {
            let found = try current.authorityHistoryLayout(); histories = found; selected = found.primaryDirectory
        } else { histories = nil; selected = try current.authorityStateDirectory() }
        let source = RecoveryOptimizationEvidence(domain: current, state: selected)
        let authority = try RuntimeV2MaintenanceCoordinator(domain: current, stateDirectory: selected,
            evidenceProvider: { await source.admitted() }, historyLayout: histories)
        RuntimeV2RecoveryAdmission.installSyntheticDomainForTests(domain: current, stateDirectory: selected,
            historyLayout: authority.historyLayout)
        source.coordinator = authority
        _ = RuntimeV2MaintenanceRegistry.install(authority)
        self.work = moved; self.domain = current; self.state = selected; self.evidence = source
        self.coordinator = authority
        self.adapter = RuntimeV2RecoveryOptimizationAdapter(domain: current, coordinator: authority,
            closureAuthority: source.closure, rawEvidence: { await source.raw() },
            admittedEvidence: { await source.admitted() })
    }
    func cleanup() {
        RuntimeV2MaintenanceRegistry.unregister(domainRoot: domain.root)
        try? FileManager.default.removeItem(at: work)
    }
}

/// Explicit macOS qualification-host setup only. The production owner audit
/// stays untouched. XCTest may raise its inherited soft FD limit at startup.
private struct SyntheticDescriptorLimitScope {
    private let original: rlimit?
    init() throws {
        guard ProcessInfo.processInfo.environment["FLOE_SYNTHETIC_FD_BOUND"] == "16384" else {
            original = nil; return
        }
        func descriptors() throws -> [Int32] {
            var result: [Int32] = []
            for name in try FileManager.default.contentsOfDirectory(atPath: "/dev/fd") {
                guard let fd = Int32(name), fd >= 0 else {
                    throw StorageSparseDiskRewriteError.injectedFailure("synthetic-fd-list-unknown")
                }
                if fcntl(fd, F_GETFD, 0) >= 0 { result.append(fd) }
                else if errno != EBADF {
                    throw StorageSparseDiskRewriteError.injectedFailure("synthetic-fd-state-unknown")
                }
            }
            return result.sorted()
        }
        var saved = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &saved) == 0 else {
            throw StorageSparseDiskRewriteError.injectedFailure("synthetic-fd-limit-unmeasured")
        }
        let before = try descriptors()
        guard before.allSatisfy({ $0 < 16_384 }), saved.rlim_max >= 16_384 else {
            throw StorageSparseDiskRewriteError.injectedFailure("synthetic-high-descriptor-present")
        }
        var bounded = saved; bounded.rlim_cur = 16_384
        guard setrlimit(RLIMIT_NOFILE, &bounded) == 0 else {
            throw StorageSparseDiskRewriteError.injectedFailure("synthetic-fd-limit-refused")
        }
        do {
            let after = try descriptors()
            guard after.allSatisfy({ $0 < 16_384 }) else {
                throw StorageSparseDiskRewriteError.injectedFailure("synthetic-high-descriptor-race")
            }
            print("Synthetic descriptor-bound setup: beforeFDs=\(before), afterFDs=\(after), previousSoft=\(saved.rlim_cur), soft=16384, hard=\(saved.rlim_max)")
        } catch {
            guard setrlimit(RLIMIT_NOFILE, &saved) == 0 else {
                throw StorageSparseDiskRewriteError.injectedFailure("synthetic-fd-restore-refused")
            }
            throw error
        }
        original = saved
    }
    func restore() -> Int32 {
        guard var original else { return 0 }
        let result = setrlimit(RLIMIT_NOFILE, &original)
        print("Synthetic descriptor-bound restore: rc=\(result), soft=\(original.rlim_cur), hard=\(original.rlim_max)")
        return result
    }
}

private final class RecoveryContentReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var processed: Int64 = 0
    private var total: Int64 = 0
    private var onMain = false
    private var phaseOrder: [String] = []
    func record(_ value: StorageSparseDiskRewriteProgress) {
        lock.withLock {
            count += 1; processed = max(processed, value.processedBytes)
            total = value.totalBytes; onMain = onMain || Thread.isMainThread
            if phaseOrder.last != value.phase.rawValue, phaseOrder.count < 32 { phaseOrder.append(value.phase.rawValue) }
        }
    }
    func snapshot() -> (count: Int, processed: Int64, total: Int64, onMain: Bool) {
        lock.withLock { (count, processed, total, onMain) }
    }
    func phases() -> [String] { lock.withLock { phaseOrder } }
}

@MainActor
final class RuntimeV2RecoveryOptimizationTests: XCTestCase {
    private struct InterruptedCleanupJob {
        let receipt: RuntimeV2OptimizationJobReceipt
        let receiptURL: URL
        let journalURL: URL
        let stageURL: URL
    }

    private func prepareInterruptedCleanup(_ fixture: RecoveryOptimizationFixture,
                                           stagePresent: Bool) async throws -> InterruptedCleanupJob {
        _ = await fixture.adapter.recoverBeforeUse()
        let record = try await fixture.record()
        let relative = fixture.relative + "/disk.img"
        let source = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: relative)
        let claim = try await fixture.coordinator.acquireExclusiveMaintenance(.init(
            owner: "app-legacy-storage-optimization", reason: "lossless-legacy-recovery",
            targetRelativePath: relative,
            targetIdentity: RuntimeV2RecoveryOptimizationAdapter.runtimeIdentity(source.identity)))
        let closed = try await fixture.evidence.closure.currentReceipt(intentID: claim.intentID)
        let receipt = RuntimeV2OptimizationJobReceipt(version: 1, intentID: claim.intentID,
            authorityGeneration: claim.holdGeneration, domainKey: fixture.domain.domainKey,
            relativePath: relative, expectedSource: source.identity,
            preservationFingerprint: try RuntimeV2OptimizationPreservation(record).fingerprint(),
            repairHoldGeneration: 7, closure: closed)
        try RuntimeV2OptimizationJournalIO.writeOnce(receipt, directory: fixture.receipts, name: claim.intentID + ".json")
        try FileManager.default.createDirectory(at: fixture.journals, withIntermediateDirectories: true)
        try await claim.markCommitting()
        let fence = StorageSparseDiskMaintenanceFence(leaseID: claim.intentID, generation: claim.holdGeneration) {
            try RuntimeV2OptimizationAsyncFence.check {
                try await claim.validate()
                let fresh = await fixture.evidence.admitted()
                guard fresh.isComplete else { throw StorageSparseDiskRewriteError.needsInspection("synthetic-closure") }
                try claim.validateReferenceFingerprint(fresh.references.fingerprint)
            }
        }
        let request = StorageSparseDiskRewriteRequest(rootURL: fixture.root, relativePath: relative,
            expectedSource: source.identity, journalDirectoryURL: fixture.journals,
            jobID: claim.intentID, maintenanceLeaseID: claim.intentID,
            holdGeneration: 7, jobGeneration: claim.holdGeneration,
            mode: .cloneAndPunch, minimumReclaimBytes: 1, allowSparseCopyFallback: false)
        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.crashAt = { point in
            if stagePresent && point == .afterStaging {
                throw StorageSparseDiskRewriteError.crashInjected("synthetic-staging-left")
            }
            if !stagePresent && point == .afterVerified {
                throw StorageSparseDiskRewriteError.injectedFailure("synthetic-failed-cleaned-stage")
            }
        }
        let capturedHooks = hooks
        let worker = RuntimeV2OptimizationWorker("synthetic.precommit-cleanup", allowsSynchronousFence: true)
        do {
            _ = try await worker.run {
                try StorageSparseDiskRewrite._rewrite(request, fence: fence, hooks: capturedHooks, isCancelled: { false })
            }
            XCTFail("The exact synthetic pre-swap stop must be reached")
        } catch {
            XCTAssertEqual(error as? StorageSparseDiskRewriteError, stagePresent
                ? .crashInjected("synthetic-staging-left") : .injectedFailure("synthetic-failed-cleaned-stage"))
        }
        await claim.handoffToRecovery()
        let journalURL = fixture.journals.appendingPathComponent(claim.intentID + ".json")
        let header = try XCTUnwrap(RuntimeV2OptimizationJournalIO.read(
            RuntimeV2OptimizationCoreJournalBinding.self, directory: fixture.journals, name: claim.intentID + ".json"))
        XCTAssertEqual(header.phase, stagePresent ? "staging" : "failed")
        let stageURL = fixture.disk.deletingLastPathComponent().appendingPathComponent(try XCTUnwrap(header.stageName))
        XCTAssertEqual(FileManager.default.fileExists(atPath: stageURL.path), stagePresent)
        XCTAssertTrue(try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: relative).identity.matchesFully(source.identity))
        return .init(receipt: receipt, receiptURL: fixture.receipts.appendingPathComponent(claim.intentID + ".json"),
                     journalURL: journalURL, stageURL: stageURL)
    }

    private nonisolated static func changeOnlyRetainedMetadata(_ fixture: RecoveryOptimizationFixture) throws {
        let url = fixture.root.appendingPathComponent("environments/env-a/metadata.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["syntheticUserAnnotation"] = "Keep this current metadata; do not restore the historical fingerprint."
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private nonisolated static func changeOnlyDiskCtime(_ fixture: RecoveryOptimizationFixture) throws {
        let before = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root,
            relativePath: fixture.relative + "/disk.img").identity
        let fd = fixture.disk.path.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
        let mode = mode_t(before.mode & 0o7777)
        guard fchmod(fd, mode ^ mode_t(0o100)) == 0, fchmod(fd, mode) == 0 else { throw POSIXError(.EIO) }
        let after = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root,
            relativePath: fixture.relative + "/disk.img").identity
        guard after.matchesStable(before), !after.matchesFully(before) else {
            throw StorageSparseDiskRewriteError.injectedFailure("synthetic-disk-ctime-change-not-established")
        }
    }

    private nonisolated static func overwriteDiskKeepingStableIdentity(
        _ fixture: RecoveryOptimizationFixture, bytes: Data
    ) throws {
        let relative = fixture.relative + "/disk.img"
        let before = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: relative).identity
        guard Int64(bytes.count) == before.sizeBytes else { throw POSIXError(.EINVAL) }
        let fd = fixture.disk.path.withCString { open($0, O_RDWR | O_NOFOLLOW) }
        guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 else { throw POSIXError(.EIO) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = pwrite(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }; offset += count
            }
        }
        var times = [info.st_atimespec, info.st_mtimespec]
        guard times.withUnsafeBufferPointer({ futimens(fd, $0.baseAddress) }) == 0, fsync(fd) == 0 else {
            throw POSIXError(.EIO)
        }
        let after = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: relative).identity
        guard after.matchesStable(before), !after.matchesFully(before) else {
            throw StorageSparseDiskRewriteError.injectedFailure("synthetic-stable-overwrite-not-established")
        }
    }

    private func duplicateRetiredEvidence(_ fixture: RecoveryOptimizationFixture, name: String) throws {
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            fixture.receipts.appendingPathComponent(name))) as? [String: Any])
        var journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            fixture.journals.appendingPathComponent(name))) as? [String: Any])
        let oldID = try XCTUnwrap(receipt["intentID"] as? String), id = UUID().uuidString
        let generation = ((receipt["authorityGeneration"] as? NSNumber)?.uint64Value ?? 0) + 1
        receipt["intentID"] = id; receipt["authorityGeneration"] = generation
        var closure = try XCTUnwrap(receipt["closure"] as? [String: Any])
        closure["intentID"] = id; closure["holdGeneration"] = generation; closure["proofID"] = UUID().uuidString
        receipt["closure"] = closure
        journal["jobID"] = id; journal["maintenanceLeaseID"] = id; journal["jobGeneration"] = generation
        if let stage = journal["stageName"] as? String { journal["stageName"] = stage.replacingOccurrences(of: oldID, with: id) }
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            .write(to: fixture.receipts.appendingPathComponent(id + ".json"))
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
            .write(to: fixture.journals.appendingPathComponent(id + ".json"))
    }

    func testRetiredContentRevalidationMeasuresFreshGainAfterZeroReallocation() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let first = await fixture.adapter.optimize(try await fixture.record(), cancellation: .init())
        XCTAssertEqual(first.code, "optimized")
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: fixture.journals.path).first)
        let oldJournal = try Data(contentsOf: fixture.journals.appendingPathComponent(name))
        let oldReceipt = try Data(contentsOf: fixture.receipts.appendingPathComponent(name))
        let sparse = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: fixture.relative + "/disk.img")
        // A migration/copy can allocate former zero holes without changing
        // logical bytes. Keep the actual inode/mtime, and measure the result.
        try Self.overwriteDiskKeepingStableIdentity(fixture, bytes: fixture.original)
        try Self.changeOnlyRetainedMetadata(fixture)
        let dense = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: fixture.relative + "/disk.img")
        XCTAssertGreaterThan(dense.allocatedBytes, sparse.allocatedBytes)
        XCTAssertTrue(dense.identity.matchesStable(sparse.identity))
        let metadata = try fixture.preservedMetadata(), progress = RecoveryContentReadProbe()
        let result = await fixture.adapter.optimize(try await fixture.record(), cancellation: .init()) { progress.record($0) }
        XCTAssertEqual(progress.phases().first, "verifying"); XCTAssertFalse(progress.snapshot().onMain)
        XCTAssertTrue(progress.phases().contains("counting")); XCTAssertTrue(progress.phases().contains("staging"))
        XCTAssertEqual(result.code, "optimized"); XCTAssertTrue(result.verifiedFirstDisk)
        let report = try XCTUnwrap(result.report)
        XCTAssertNotEqual(report.jobID + ".json", name)
        XCTAssertGreaterThan(report.sourceAllocatedBytesBefore, report.stageAllocatedBytesAtVerification)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        XCTAssertEqual(try fixture.preservedMetadata(), metadata)
        XCTAssertEqual(try Data(contentsOf: fixture.journals.appendingPathComponent(name)), oldJournal)
        XCTAssertEqual(try Data(contentsOf: fixture.receipts.appendingPathComponent(name)), oldReceipt)
    }

    func testRetiredContentRevalidationRejectsDigestRaceCASAmbiguityAndCancellation() async throws {
        for fault in ["digest", "references", "sidecar", "receipt-cas", "journal-cas", "late-journal-cas", "ambiguity", "cancel"] {
            let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
            _ = await fixture.adapter.recoverBeforeUse()
            let first = await fixture.adapter.optimize(try await fixture.record(), cancellation: .init())
            XCTAssertEqual(first.code, "optimized")
            let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: fixture.journals.path).first)
            let journalURL = fixture.journals.appendingPathComponent(name), receiptURL = fixture.receipts.appendingPathComponent(name)
            let oldJournal = try Data(contentsOf: journalURL), oldReceipt = try Data(contentsOf: receiptURL)
            if fault == "digest" {
                var changed = fixture.original; changed[3] = 0xA5
                try Self.overwriteDiskKeepingStableIdentity(fixture, bytes: changed)
            } else { try Self.changeOnlyDiskCtime(fixture) }
            if fault == "ambiguity" { try duplicateRetiredEvidence(fixture, name: name) }
            let bytes = try Data(contentsOf: fixture.disk), metadata = try fixture.preservedMetadata()
            let cancellation = RuntimeV2OptimizationCancellation(), once = RuntimeV2OptimizationCancellation()
            let failedMutation = RuntimeV2OptimizationCancellation(), progress = RecoveryContentReadProbe()
            let result = await fixture.adapter.optimize(try await fixture.record(), cancellation: cancellation) { value in
                progress.record(value)
                // countSource emits progress AFTER bytes are read, never a
                // zero-byte counting event. Inject at its first real event,
                // after qualification and before Core's pre-clone fence.
                let injectNow = fault == "late-journal-cas"
                    ? value.phase == .counting : value.processedBytes == 0
                if injectNow, !once.isCancelled {
                    once.cancel()
                    do {
                        if fault == "references" { fixture.evidence.lock.withLock { fixture.evidence.referenceVersion += 1 } }
                        if fault == "sidecar" { try RuntimeV2RecoveryOptimizationTests.changeOnlyRetainedMetadata(fixture) }
                        if fault == "receipt-cas" { try (oldReceipt + Data([32])).write(to: receiptURL) }
                        if fault == "journal-cas" || fault == "late-journal-cas" { try (oldJournal + Data([32])).write(to: journalURL) }
                    } catch { failedMutation.cancel() }
                }
                if fault == "cancel", value.processedBytes > 0 { cancellation.cancel() }
            }
            let diagnostic = "fault=\(fault) code=\(result.code) phases=\(progress.phases()) injected=\(once.isCancelled)"
            XCTAssertFalse(failedMutation.isCancelled, diagnostic)
            XCTAssertNil(result.report, diagnostic)
            XCTAssertFalse(result.verifiedFirstDisk, diagnostic); XCTAssertFalse(result.verifiedUnchanged, diagnostic)
            XCTAssertNotEqual(result.code, "optimized", diagnostic); XCTAssertNotEqual(result.code, "already-optimized", diagnostic)
            XCTAssertFalse(result.recoveryPending, diagnostic)
            XCTAssertEqual(try Data(contentsOf: fixture.disk), bytes, diagnostic)
            XCTAssertEqual(try Data(contentsOf: journalURL), ["journal-cas", "late-journal-cas"].contains(fault) ? oldJournal + Data([32]) : oldJournal, diagnostic)
            XCTAssertEqual(try Data(contentsOf: receiptURL), fault == "receipt-cas" ? oldReceipt + Data([32]) : oldReceipt, diagnostic)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.journals.path).count,
                           ["ambiguity", "late-journal-cas"].contains(fault) ? 2 : 1,
                           "Late CAS may leave only the fresh aborted intent journal; qualification failures create none. " + diagnostic)
            XCTAssertFalse(progress.snapshot().onMain, diagnostic)
            if fault == "ambiguity" {
                XCTAssertEqual(progress.snapshot().count, 0, diagnostic)
                XCTAssertEqual(result.code, "needs-inspection", diagnostic)
                XCTAssertEqual(result.candidateDisposition, .retainedAndReleased, diagnostic)
            }
            else { XCTAssertEqual(progress.phases().first, "verifying", diagnostic); XCTAssertTrue(once.isCancelled, diagnostic) }
            if fault == "cancel" { XCTAssertTrue(cancellation.isCancelled, diagnostic); XCTAssertEqual(result.code, "cancelled", diagnostic) }
            if fault == "sidecar" { XCTAssertNotEqual(try fixture.preservedMetadata(), metadata) }
            else { XCTAssertEqual(try fixture.preservedMetadata(), metadata) }
        }
    }

    func testCtimeContentRecoveryClosesOldIntentThenAdmitsFreshRewrite() async throws {
        for stagePresent in [false, true] {
            let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
            let job = try await prepareInterruptedCleanup(fixture, stagePresent: stagePresent)
            let receiptBytes = try Data(contentsOf: job.receiptURL)
            let old = try JSONDecoder().decode(StorageSparseDiskRewriteJournalRecord.self,
                from: Data(contentsOf: job.journalURL))
            try Self.changeOnlyDiskCtime(fixture)
            try Self.changeOnlyRetainedMetadata(fixture)
            let currentMetadata = try fixture.preservedMetadata()
            let before = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root,
                relativePath: job.receipt.relativePath).identity
            XCTAssertTrue(before.matchesStable(old.source)); XCTAssertFalse(before.matchesFully(old.source))
            let probe = RecoveryContentReadProbe()
            let recovered = await fixture.adapter.recoverBeforeUse(cancellation: .init(), progress: { probe.record($0) })
            XCTAssertEqual(recovered.outcome, .resolved)
            let read = probe.snapshot()
            XCTAssertGreaterThan(read.count, 0); XCTAssertFalse(read.onMain)
            XCTAssertEqual(read.processed, Int64(fixture.original.count)); XCTAssertEqual(read.total, old.logicalBytes)
            XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
            XCTAssertEqual(try Data(contentsOf: job.receiptURL), receiptBytes)
            XCTAssertEqual(try fixture.preservedMetadata(), currentMetadata)
            XCTAssertFalse(FileManager.default.fileExists(atPath: job.stageURL.path))
            let settledBytes = try Data(contentsOf: job.journalURL)
            let settled = try JSONDecoder().decode(StorageSparseDiskRewriteJournalRecord.self, from: settledBytes)
            XCTAssertEqual(settled.phase, .aborted); XCTAssertFalse(settled.stageRetired)
            XCTAssertEqual(settled.source, old.source)
            XCTAssertEqual(settled.sourceDigestSHA512, old.sourceDigestSHA512)
            XCTAssertEqual(settled.resolution, stagePresent
                ? "aborted-before-swap-content-verified" : "source-content-verified")
            XCTAssertTrue(try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root,
                relativePath: job.receipt.relativePath).identity.matchesFully(before))
            let opened = await fixture.coordinator.state(); XCTAssertEqual(opened.phase, .open)
            let fresh = try await fixture.record()
            let optimized = await fixture.adapter.optimize(fresh, cancellation: .init())
            XCTAssertEqual(optimized.code, "optimized", optimized.diagnosticCodes.joined(separator: ","))
            XCTAssertTrue(optimized.verifiedFirstDisk); XCTAssertFalse(optimized.recoveryPending)
            XCTAssertNotEqual(optimized.report?.jobID, old.jobID)
            XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
            XCTAssertEqual(try fixture.preservedMetadata(), currentMetadata)
            XCTAssertEqual(try Data(contentsOf: job.receiptURL), receiptBytes)
            XCTAssertEqual(try Data(contentsOf: job.journalURL), settledBytes,
                "Fresh work must not replace the historical source identity/hash or recount its aborted job")
        }
    }

    func testCtimeRecoveryOwnedCancellationPreservesStageAndResumesSameIntent() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        let job = try await prepareInterruptedCleanup(fixture, stagePresent: true)
        try Self.changeOnlyDiskCtime(fixture)
        let journalBytes = try Data(contentsOf: job.journalURL), receiptBytes = try Data(contentsOf: job.receiptURL)
        let stageBytes = try Data(contentsOf: job.stageURL), metadata = try fixture.preservedMetadata()
        let cancellation = RuntimeV2OptimizationCancellation(), probe = RecoveryContentReadProbe()
        let result = await fixture.adapter.recoverBeforeUse(cancellation: cancellation, progress: { value in
            probe.record(value)
            if value.processedBytes > 0 { cancellation.cancel() }
        })
        XCTAssertTrue(cancellation.isCancelled); XCTAssertEqual(result.outcome, .blocked)
        XCTAssertGreaterThan(probe.snapshot().processed, 0); XCTAssertFalse(probe.snapshot().onMain)
        XCTAssertEqual(try Data(contentsOf: job.journalURL), journalBytes)
        XCTAssertEqual(try Data(contentsOf: job.receiptURL), receiptBytes)
        XCTAssertEqual(try Data(contentsOf: job.stageURL), stageBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        XCTAssertEqual(try fixture.preservedMetadata(), metadata)
        let pending = await fixture.coordinator.state(); XCTAssertEqual(pending.phase, .recoveryPending)
        XCTAssertNil(pending.intentID, "No live exclusive claim remains while durable recovery is pending")
        let durablePending = try XCTUnwrap(RuntimeV2MaintenanceCoordinator.readHistoryIntent(directory: fixture.state))
        XCTAssertEqual(durablePending.intentID, job.receipt.intentID)
        XCTAssertTrue(durablePending.phase.isBlocking)
        let resumed = await fixture.adapter.recoverBeforeUse(cancellation: .init())
        XCTAssertEqual(resumed.outcome, .resolved); XCTAssertEqual(resumed.intentID, job.receipt.intentID)
        let durableResolved = try XCTUnwrap(RuntimeV2MaintenanceCoordinator.readHistoryIntent(directory: fixture.state))
        XCTAssertEqual(durableResolved.intentID, job.receipt.intentID)
        XCTAssertEqual(durableResolved.phase, .resolved)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        XCTAssertEqual(try Data(contentsOf: job.receiptURL), receiptBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.stageURL.path))
    }

    func testConcurrentRecoveryCallerCannotReplaceTheActiveCancellation() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        let job = try await prepareInterruptedCleanup(fixture, stagePresent: true)
        try Self.changeOnlyDiskCtime(fixture)
        let journalBytes = try Data(contentsOf: job.journalURL), stageBytes = try Data(contentsOf: job.stageURL)
        let cancellation = RuntimeV2OptimizationCancellation()
        let signal = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); signal.continuation.finish() }
        let first = Task {
            let report = await fixture.adapter.recoverBeforeUse(cancellation: cancellation, progress: { value in
                if value.processedBytes == 0 {
                    signal.continuation.yield(())
                    release.wait()
                }
            })
            signal.continuation.finish()
            return report
        }
        var reader = signal.stream.makeAsyncIterator()
        guard await reader.next() != nil else {
            let stopped = await first.value
            XCTFail("The actual owned recovery never entered its content read: \(String(describing: stopped.reason))")
            return
        }
        let second = await fixture.adapter.recoverBeforeUse(cancellation: .init())
        XCTAssertEqual(second.outcome, .blocked)
        XCTAssertEqual(second.reason, "optimizer recovery already in progress")
        cancellation.cancel(); release.signal()
        let stopped = await first.value
        XCTAssertEqual(stopped.outcome, .blocked)
        XCTAssertEqual(try Data(contentsOf: job.journalURL), journalBytes)
        XCTAssertEqual(try Data(contentsOf: job.stageURL), stageBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        let resumed = await fixture.adapter.recoverBeforeUse(cancellation: .init())
        XCTAssertEqual(resumed.outcome, .resolved)
    }

    func testFailedJobWithoutStageClosesOnlyItsIntentAndKeepsV1Metadata() async throws {
        let limit = try SyntheticDescriptorLimitScope(); defer { XCTAssertEqual(limit.restore(), 0) }
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        let job = try await prepareInterruptedCleanup(fixture, stagePresent: false)
        let originalReceipt = try Data(contentsOf: job.receiptURL)
        try Self.changeOnlyRetainedMetadata(fixture)
        let metadata = try fixture.preservedMetadata()
        let changedRecord = try await fixture.record()
        XCTAssertNotEqual(try RuntimeV2OptimizationPreservation(changedRecord).fingerprint(), job.receipt.preservationFingerprint)
        let result = await fixture.adapter.recoverBeforeUse()
        XCTAssertEqual(result.outcome, .resolved)
        XCTAssertEqual(try fixture.preservedMetadata(), metadata)
        XCTAssertEqual(try Data(contentsOf: job.receiptURL), originalReceipt)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        XCTAssertTrue(try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root,
            relativePath: job.receipt.relativePath).identity.matchesFully(job.receipt.expectedSource))
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: job.journalURL)) as? [String: Any])
        XCTAssertEqual(header["phase"] as? String, "aborted")
        XCTAssertEqual(header["resolution"] as? String, "source-unchanged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.stageURL.path))
        let again = await fixture.adapter.recoverBeforeUse()
        XCTAssertEqual(again.outcome, .notNeeded)
        let state = await fixture.coordinator.state(); XCTAssertEqual(state.phase, .open)
    }

    func testStagingJobRemovesOnlyItsExactGeneratedCopyAndKeepsOriginal() async throws {
        let limit = try SyntheticDescriptorLimitScope(); defer { XCTAssertEqual(limit.restore(), 0) }
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        let job = try await prepareInterruptedCleanup(fixture, stagePresent: true)
        let originalReceipt = try Data(contentsOf: job.receiptURL)
        try Self.changeOnlyRetainedMetadata(fixture)
        let retained = fixture.disk.deletingLastPathComponent().appendingPathComponent("user-kept.txt")
        let retainedBytes = Data("not the generated stage\n".utf8); try retainedBytes.write(to: retained)
        let metadata = try fixture.preservedMetadata()
        let result = await fixture.adapter.recoverBeforeUse()
        XCTAssertEqual(result.outcome, .resolved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: job.stageURL.path))
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        XCTAssertTrue(try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root,
            relativePath: job.receipt.relativePath).identity.matchesFully(job.receipt.expectedSource))
        XCTAssertEqual(try Data(contentsOf: retained), retainedBytes)
        XCTAssertEqual(try fixture.preservedMetadata(), metadata)
        XCTAssertEqual(try Data(contentsOf: job.receiptURL), originalReceipt)
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: job.journalURL)) as? [String: Any])
        XCTAssertEqual(header["phase"] as? String, "aborted")
        XCTAssertEqual(header["resolution"] as? String, "aborted-before-swap")
    }

    func testSourcePreservingAbortRejectsChangedSourceAndReplacedStage() async throws {
        let limit = try SyntheticDescriptorLimitScope(); defer { XCTAssertEqual(limit.restore(), 0) }
        for changeSource in [true, false] {
            let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
            let job = try await prepareInterruptedCleanup(fixture, stagePresent: true)
            if changeSource {
                var changed = fixture.original; changed[3] = 0xA5
                try changed.write(to: fixture.disk)
            } else {
                let kept = job.stageURL.appendingPathExtension("kept-original")
                try FileManager.default.moveItem(at: job.stageURL, to: kept)
                try Data("replacement inode, not this job's stage".utf8).write(to: job.stageURL)
            }
            let source = try Data(contentsOf: fixture.disk), stage = try Data(contentsOf: job.stageURL)
            let journal = try Data(contentsOf: job.journalURL), receipt = try Data(contentsOf: job.receiptURL)
            let metadata = try fixture.preservedMetadata()
            let result = await fixture.adapter.recoverBeforeUse()
            XCTAssertEqual(result.outcome, .blocked)
            XCTAssertEqual(try Data(contentsOf: fixture.disk), source)
            XCTAssertEqual(try Data(contentsOf: job.stageURL), stage)
            XCTAssertEqual(try Data(contentsOf: job.journalURL), journal)
            XCTAssertEqual(try Data(contentsOf: job.receiptURL), receipt)
            XCTAssertEqual(try fixture.preservedMetadata(), metadata)
            let state = await fixture.coordinator.state(); XCTAssertNotEqual(state.phase, .open)
        }
    }

    func testPostSwapMetadataCannotEnterRestrictedAbortOrBypassLegacyFingerprint() async throws {
        let limit = try SyntheticDescriptorLimitScope(); defer { XCTAssertEqual(limit.restore(), 0) }
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        let job = try await prepareInterruptedCleanup(fixture, stagePresent: true)
        var journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: job.journalURL)) as? [String: Any])
        journal["phase"] = "swapped"; journal["postSwapSource"] = journal["stage"]
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys]).write(to: job.journalURL)
        let journalBytes = try Data(contentsOf: job.journalURL)
        // Core-only negative classification; this inert synthetic fence grants
        // no production permission. Positive cleanup tests use the real owner.
        let refused = try StorageSparseDiskRewrite.recover(rootURL: fixture.root,
            relativePath: job.receipt.relativePath, journalDirectoryURL: fixture.journals,
            jobID: job.receipt.intentID,
            fence: .init(leaseID: job.receipt.intentID, generation: job.receipt.authorityGeneration, assertExclusive: {}),
            policy: .abortUnchangedSourceOnly)
        XCTAssertEqual(refused.resolution, .needsInspection); XCTAssertFalse(refused.stageRemoved)
        XCTAssertEqual(try Data(contentsOf: job.journalURL), journalBytes)
        try Self.changeOnlyRetainedMetadata(fixture)
        let metadata = try fixture.preservedMetadata(), receipt = try Data(contentsOf: job.receiptURL)
        let stage = try Data(contentsOf: job.stageURL)
        let result = await fixture.adapter.recoverBeforeUse()
        XCTAssertEqual(result.outcome, .blocked, "Post-swap work still requires the old strict v1 preservation proof")
        XCTAssertEqual(try Data(contentsOf: job.journalURL), journalBytes)
        XCTAssertEqual(try Data(contentsOf: job.receiptURL), receipt)
        XCTAssertEqual(try Data(contentsOf: job.stageURL), stage)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        XCTAssertEqual(try fixture.preservedMetadata(), metadata)
    }

    func testAbortCleanupStillFencesHoldGenerationAndConcurrentMetadataChanges() async throws {
        let limit = try SyntheticDescriptorLimitScope(); defer { XCTAssertEqual(limit.restore(), 0) }
        for changeDuringFence in [false, true] {
            let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
            let job = try await prepareInterruptedCleanup(fixture, stagePresent: true)
            if changeDuringFence {
                fixture.evidence.lock.withLock {
                    fixture.evidence.admissions = 0
                    fixture.evidence.admissionObserver = { number in
                        if number == 2 { try RuntimeV2RecoveryOptimizationTests.changeOnlyRetainedMetadata(fixture) }
                    }
                }
            } else {
                try Data("8\n".utf8).write(to: fixture.root.appendingPathComponent("environments/env-a/repair-hold.generation"))
            }
            let journal = try Data(contentsOf: job.journalURL), receipt = try Data(contentsOf: job.receiptURL)
            let stage = try Data(contentsOf: job.stageURL)
            let result = await fixture.adapter.recoverBeforeUse()
            fixture.evidence.lock.withLock { fixture.evidence.admissionObserver = nil }
            XCTAssertEqual(result.outcome, .blocked)
            XCTAssertEqual(try Data(contentsOf: job.journalURL), journal)
            XCTAssertEqual(try Data(contentsOf: job.receiptURL), receipt)
            XCTAssertEqual(try Data(contentsOf: job.stageURL), stage)
            XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
            let state = await fixture.coordinator.state(); XCTAssertNotEqual(state.phase, .open)
        }
    }

    func testRecoveryDiagnosticReasonsNeverEchoAttributedErrorText() {
        let attributed = "/synthetic/private/owner-do-not-log"
        XCTAssertEqual(RuntimeV2RecoveryOptimizationAdapter.recoveryDiagnosticReason(
            RuntimeV2MaintenanceError.targetIdentityMismatch(attributed)), "target-identity-unverified")
        XCTAssertEqual(RuntimeV2RecoveryOptimizationAdapter.recoveryDiagnosticReason(
            RuntimeV2MaintenanceError.claimInvalidated(attributed)), "authority-generation-unverified")
        XCTAssertEqual(RuntimeV2RecoveryOptimizationAdapter.recoveryDiagnosticReason(
            RuntimeV2MaintenanceError.targetIdentityMismatch("repair preservation inventory incomplete")), "preservation-inventory-incomplete")
        XCTAssertEqual(RuntimeV2RecoveryOptimizationAdapter.recoveryDiagnosticReason(
            RuntimeV2MaintenanceError.targetIdentityMismatch("repair preservation could not be observed")), "preservation-record-unavailable")
        XCTAssertEqual(RuntimeV2RecoveryOptimizationAdapter.recoveryDiagnosticReason(
            RuntimeV2MaintenanceError.claimInvalidated("recovery authority is not held")), "recovery-session-changed")
        XCTAssertEqual(RuntimeV2RecoveryOptimizationAdapter.recoveryDiagnosticReason(
            RuntimeV2MaintenanceError.claimInvalidated("recovery references changed after metadata read")), "recovery-reference-changed-after-read")
    }

    func testRegistryWALModeWithoutSidecarsReadsWithoutWritingSourceAndRetiresScratch() throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        let original = fixture.root.appendingPathComponent("registry/runtime.sqlite")
        // WAL/SHM may persist after the fixture writer closes on this SQLite
        // build. Prove a complete checkpoint, then put only its main bytes in
        // a fresh registry directory that SQLite has never opened. The reader
        // must handle that source without warming it with a writable open.
        do {
            var handle: OpaquePointer?
            XCTAssertEqual(sqlite3_open_v2(original.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
            let writer = try XCTUnwrap(handle)
            defer { XCTAssertEqual(sqlite3_close(writer), SQLITE_OK) }
            do {
                var statement: OpaquePointer?
                XCTAssertEqual(sqlite3_prepare_v2(writer, "SELECT COUNT(*) FROM leases", -1, &statement, nil), SQLITE_OK)
                let query = try XCTUnwrap(statement); defer { sqlite3_finalize(query) }
                XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
                XCTAssertEqual(sqlite3_column_int(query, 0), 57)
            }
            var frames: Int32 = -1, checkpointed: Int32 = -1
            XCTAssertEqual(sqlite3_wal_checkpoint_v2(writer, nil, SQLITE_CHECKPOINT_TRUNCATE, &frames, &checkpointed), SQLITE_OK)
            XCTAssertGreaterThanOrEqual(frames, 0)
            XCTAssertEqual(frames, checkpointed)
        }
        let checkpointedRoot = fixture.work.appendingPathComponent("checkpointed-main-only", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpointedRoot.appendingPathComponent("registry"), withIntermediateDirectories: true)
        let database = checkpointedRoot.appendingPathComponent("registry/runtime.sqlite")
        try Data(contentsOf: original).write(to: database)
        let checkpointedDomain = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: checkpointedRoot)
        let before = try Data(contentsOf: database)
        XCTAssertEqual(before[18], 2); XCTAssertEqual(before[19], 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-shm"))
        var scratch: URL?
        var posixScratchPath: String?
        let result = try RuntimeV2LegacyRegistryReader._read(domain: checkpointedDomain) {
            scratch = $0
            guard let actual = $0.path.withCString({ realpath($0, nil) }) else {
                return XCTFail("Temporary snapshot must have a real POSIX path")
            }
            defer { free(actual) }
            let canonical = String(cString: actual)
            posixScratchPath = canonical
            XCTAssertEqual($0.path, canonical)
            print("Legacy registry pre-open temp path: URL=\($0.path), realpath=\(canonical)")
        }
        XCTAssertEqual(result.leaseEnvironmentIDs.count, 57)
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-shm"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(scratch).path))
        let temporary = FileManager.default.temporaryDirectory
        let actualScratch = try XCTUnwrap(scratch)
        let canonical = URL(fileURLWithPath: try XCTUnwrap(posixScratchPath), isDirectory: true)
        XCTAssertEqual(actualScratch.path, canonical.path)
        print("Legacy registry temp normalization: rawParentHasAlias=\(temporary.path != temporary.resolvingSymlinksInPath().standardizedFileURL.path), returnedCanonical=\(actualScratch.path == canonical.path)")
    }

    func testRegistrySnapshotIncludesUncheckpointedWALRowsAndPreservesBothSources() throws {
        let fixture = try RecoveryOptimizationFixture(registry: false); defer { fixture.cleanup() }
        let database = fixture.root.appendingPathComponent("registry/runtime.sqlite")
        let writer = try XCTUnwrap(RecoveryOptimizationFixture.createRegistry(at: database, leases: 57, keepWAL: true))
        defer { sqlite3_close(writer) }
        let main = try Data(contentsOf: database)
        let wal = try Data(contentsOf: URL(fileURLWithPath: database.path + "-wal"))
        XCTAssertGreaterThan(wal.count, 32)
        // Prove the expected rows/schema have not reached the main file.
        let onlyMain = fixture.work.appendingPathComponent("main-without-wal.sqlite")
        try main.write(to: onlyMain)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(onlyMain.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let opened = try XCTUnwrap(handle); defer { sqlite3_close(opened) }
        try RecoveryOptimizationFixture.execute(opened, "PRAGMA query_only=ON")
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(opened, "SELECT COUNT(*) FROM sqlite_master WHERE name='leases'", -1, &statement, nil), SQLITE_OK)
        let query = try XCTUnwrap(statement); defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(query, 0), 0)
        var scratch: URL?
        let result = try RuntimeV2LegacyRegistryReader._read(domain: fixture.domain) { scratch = $0 }
        XCTAssertEqual(result.leaseEnvironmentIDs.count, 57)
        XCTAssertEqual(try Data(contentsOf: database), main)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: database.path + "-wal")), wal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(scratch).path))
    }

    func testRegistrySourceWALChangeRefusesAndRetiresInitializedPrivateSidecars() throws {
        let fixture = try RecoveryOptimizationFixture(registry: false); defer { fixture.cleanup() }
        let database = fixture.root.appendingPathComponent("registry/runtime.sqlite")
        let writer = try XCTUnwrap(RecoveryOptimizationFixture.createRegistry(at: database, leases: 57, keepWAL: true))
        defer { sqlite3_close(writer) }
        var scratch: URL?
        XCTAssertThrowsError(try RuntimeV2LegacyRegistryReader._read(domain: fixture.domain) {
            scratch = $0
            try RecoveryOptimizationFixture.execute(writer,
                "INSERT INTO leases VALUES('env-new','rt-env-new','synthetic-incarnation','synthetic-token','held')")
        }) { error in
            guard case RuntimeV2MaintenanceError.ownerEvidenceIncomplete(let codes) = error else {
                return XCTFail("Expected stable-source refusal")
            }
            XCTAssertTrue(codes.contains("legacy_registry_identity_changed"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(scratch).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path + "-wal"))
    }

    func testUnknownWALIsRefusedWithoutDroppingItAndScratchIsRetired() throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        let database = fixture.root.appendingPathComponent("registry/runtime.sqlite")
        let before = try Data(contentsOf: database)
        let wal = URL(fileURLWithPath: database.path + "-wal")
        let unknown = Data(repeating: 0, count: 32)
        try unknown.write(to: wal)
        var scratch: URL?
        XCTAssertThrowsError(try RuntimeV2LegacyRegistryReader._read(domain: fixture.domain) { scratch = $0 }) { error in
            guard case RuntimeV2MaintenanceError.ownerEvidenceIncomplete(let codes) = error else {
                return XCTFail("Expected unknown WAL refusal")
            }
            XCTAssertTrue(codes.contains("legacy_wal_shape_unknown"))
        }
        XCTAssertEqual(try Data(contentsOf: database), before)
        XCTAssertEqual(try Data(contentsOf: wal), unknown)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(scratch).path))
    }

    func testRegistrySnapshotCancellationRetiresTemporaryCopyAndPreservesSource() throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        let before = try fixture.preservedMetadata()
        var scratch: URL?
        XCTAssertThrowsError(try RuntimeV2LegacyRegistryReader._read(domain: fixture.domain) {
            scratch = $0
            throw CancellationError()
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(scratch).path))
        XCTAssertEqual(try fixture.preservedMetadata(), before)
    }

    func testCompleteReferencesDoNotBecomeUnknownWhenOwnerTemporarilyUnavailable() async throws {
        let descriptorLimit = try SyntheticDescriptorLimitScope()
        defer { XCTAssertEqual(descriptorLimit.restore(), 0) }
        var observedLimit = rlimit()
        let limitStatus = getrlimit(RLIMIT_NOFILE, &observedLimit)
        print("Synthetic actual XCTest RLIMIT_NOFILE: rc=\(limitStatus), soft=\(observedLimit.rlim_cur), hard=\(observedLimit.rlim_max)")
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let preserved = try fixture.preservedMetadata()
        fixture.evidence.lock.withLock { fixture.evidence.ownerAvailable = false }
        let record = try await fixture.record()
        XCTAssertEqual(record.currentReferenceState, .unreferenced)
        XCTAssertTrue(record.isReviewableForBytePreservingMaintenance)
        XCTAssertFalse(record.planningBlockers.contains(.currentReferencesUnknown))
        let unavailable = await fixture.adapter.optimize(record, cancellation: .init())
        XCTAssertEqual(unavailable.code, "owner-unknown")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journals.path))
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        XCTAssertEqual(try fixture.preservedMetadata(), preserved)

        // A fresh provider alone is still insufficient: a real participating
        // native use must close before the actual exclusive gate can admit IO.
        fixture.evidence.lock.withLock { fixture.evidence.ownerAvailable = true }
        let use = try XCTUnwrap(RuntimeV2RecoveryAdmission.acquire(root: fixture.root))
        let busy = await fixture.adapter.optimize(record, cancellation: .init())
        XCTAssertEqual(busy.code, "busy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journals.path))
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        use.release()

        let result = await fixture.adapter.optimize(record, cancellation: .init())
        XCTAssertEqual(result.code, "optimized", result.diagnosticCodes.joined(separator: ","))
        XCTAssertTrue(result.verifiedFirstDisk)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        XCTAssertEqual(try fixture.preservedMetadata(), preserved)
    }

    func testIncompleteOrUnattributedLiveReferencesRemainUnknownAndCannotRewrite() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        fixture.evidence.lock.withLock { fixture.evidence.referenceComplete = false }
        var record = try await fixture.record()
        XCTAssertEqual(record.currentReferenceState, .unknown)
        XCTAssertTrue(record.planningBlockers.contains(.currentReferencesUnknown))
        let incomplete = await fixture.adapter.optimize(record, cancellation: .init())
        XCTAssertEqual(incomplete.code, "source-not-eligible")
        XCTAssertEqual(incomplete.candidateDisposition, .preclaimIneligible)

        fixture.evidence.lock.withLock {
            fixture.evidence.referenceComplete = true
            fixture.evidence.referenceBlockers = ["synthetic_reference_unreadable"]
        }
        record = try await fixture.record()
        XCTAssertEqual(record.currentReferenceState, .unknown)
        fixture.evidence.lock.withLock {
            fixture.evidence.referenceBlockers = []
            fixture.evidence.referenceFingerprintAvailable = false
        }
        record = try await fixture.record()
        XCTAssertEqual(record.currentReferenceState, .unknown)
        fixture.evidence.lock.withLock {
            fixture.evidence.referenceFingerprintAvailable = true
            fixture.evidence.unattributedLiveUnknownCount = 1
        }
        record = try await fixture.record()
        XCTAssertEqual(record.currentReferenceState, .unknown)
        let unattributed = await fixture.adapter.optimize(record, cancellation: .init())
        XCTAssertEqual(unattributed.code, "source-not-eligible")
        XCTAssertEqual(unattributed.candidateDisposition, .preclaimIneligible)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journals.path))
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
    }

    func testPositiveActiveReferenceStaysProtectiveWhenOtherOwnerSourcesFail() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        fixture.evidence.lock.withLock {
            fixture.evidence.ownerAvailable = false
            fixture.evidence.referenceComplete = false
            fixture.evidence.active = true
        }
        let record = try await fixture.record()
        XCTAssertEqual(record.currentReferenceState, .active)
        XCTAssertTrue(record.planningBlockers.contains(.currentReferenceActive))
        let result = await fixture.adapter.optimize(record, cancellation: .init())
        XCTAssertEqual(result.code, "source-not-eligible")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journals.path))
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
    }

    func testSingleNativeDiskPreservesAllBytesAnd57HistoricalLeases() async throws {
        let descriptorLimit = try SyntheticDescriptorLimitScope()
        defer { XCTAssertEqual(descriptorLimit.restore(), 0) }
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let metadata = try fixture.preservedMetadata()
        let before = try StorageSparseDiskRewrite.inspectSource(
            rootURL: fixture.root, relativePath: fixture.relative + "/disk.img")
        let record = try await fixture.record()
        let result = await fixture.adapter.optimize(record, cancellation: .init())
        XCTAssertEqual(result.code, "optimized", result.diagnosticCodes.joined(separator: ","))
        XCTAssertTrue(result.verifiedFirstDisk)
        let measured = try XCTUnwrap(result.report)
        let after = try StorageSparseDiskRewrite.inspectSource(
            rootURL: fixture.root, relativePath: fixture.relative + "/disk.img")
        XCTAssertEqual(before.identity.sizeBytes, Int64(fixture.original.count))
        XCTAssertEqual(after.identity.sizeBytes, before.identity.sizeBytes)
        XCTAssertEqual(measured.logicalBytes, before.identity.sizeBytes)
        XCTAssertEqual(measured.sourceAllocatedBytesBefore, before.allocatedBytes)
        XCTAssertLessThan(measured.stageAllocatedBytesAtVerification, measured.sourceAllocatedBytesBefore)
        print("Synthetic disk logical=\(measured.logicalBytes) allocatedBefore=\(measured.sourceAllocatedBytesBefore) "
            + "allocatedStage=\(measured.stageAllocatedBytesAtVerification) "
            + "observedVolumeFreeDelta=\(measured.volumeAvailableDeltaBytes)")
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        XCTAssertEqual(try fixture.preservedMetadata(), metadata)
        let rows = try RuntimeV2LegacyRegistryReader.read(domain: fixture.domain)
        XCTAssertEqual(rows.leaseEnvironmentIDs.count, 57)
        let state = await fixture.coordinator.state()
        XCTAssertEqual(state.phase, .open)
    }

    func testTrustedPrivateVarMultiHistoryInventoryCommitsSparseDiskAndReusesAfterRestart() async throws {
        let descriptorLimit = try SyntheticDescriptorLimitScope()
        defer { XCTAssertEqual(descriptorLimit.restore(), 0) }
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        let fm = FileManager.default
        let preserved = try fixture.preservedMetadata()
        let originalDigest = FloeDigest.sha256Hex(fixture.original)
        RuntimeV2MaintenanceRegistry.unregister(domainRoot: fixture.root)

        let support = fixture.work.appendingPathComponent("Library/Application Support", isDirectory: true)
        let migratedRoot = support.appendingPathComponent("Floe/Runtime/v2", isDirectory: true)
        try fm.createDirectory(at: migratedRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: fixture.root, to: migratedRoot)
        let manager = SyntheticRecoveryApplicationSupportFileManager(support: support)
        let domain = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: migratedRoot, fileManager: manager)
        XCTAssertTrue(domain.root.path.hasPrefix("/private/var/"),
                      "Exercise the trusted realpath branch that produced the first-intent alias failure")
        defer { RuntimeV2MaintenanceRegistry.unregister(domainRoot: domain.root) }
        let disk = domain.root.appendingPathComponent(fixture.relative + "/disk.img")
        let physical = try RuntimeV2DiskIdentity.read(at: domain.root)
        let authority = domain.root.deletingLastPathComponent()
            .appendingPathComponent("MaintenanceAuthority", isDirectory: true)
        try fm.createDirectory(at: authority, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var retainedHistories: [URL: Data] = [:]
        for (index, symbol) in ["a", "b"].enumerated() {
            let directory = authority.appendingPathComponent(String(repeating: symbol, count: 64), isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            let record = RuntimeV2MaintenanceIntentRecord(
                intentID: UUID().uuidString, holdGeneration: UInt64(index + 3), phase: .resolved,
                owner: "synthetic-old", reason: "retained-history", createdAt: Date(), updatedAt: Date(),
                domainRoot: domain.root.path, domainDevice: physical.device, domainInode: physical.inode)
            let bytes = try encoder.encode(record)
            let path = directory.appendingPathComponent("intent.json")
            try bytes.write(to: path)
            retainedHistories[path] = bytes
        }
        let layout = try domain.authorityHistoryLayout()
        XCTAssertEqual(layout.historicalDirectories.count, 2)
        XCTAssertEqual(layout.pendingIntentCount, 0)
        XCTAssertFalse(fm.fileExists(atPath: layout.primaryDirectory.path))
        let source = RecoveryOptimizationEvidence(domain: domain, state: layout.primaryDirectory)
        let coordinator = try RuntimeV2MaintenanceCoordinator(domain: domain,
            stateDirectory: layout.primaryDirectory, evidenceProvider: { await source.admitted() },
            historyLayout: layout)
        RuntimeV2RecoveryAdmission.installSyntheticDomainForTests(domain: domain,
            stateDirectory: layout.primaryDirectory, historyLayout: coordinator.historyLayout)
        source.coordinator = coordinator
        _ = RuntimeV2MaintenanceRegistry.install(coordinator)
        let adapter = RuntimeV2RecoveryOptimizationAdapter(domain: domain, coordinator: coordinator,
            closureAuthority: source.closure, rawEvidence: { await source.raw() },
            admittedEvidence: { await source.admitted() })
        let recovery = await adapter.recoverBeforeUse()
        XCTAssertEqual(recovery.outcome, .notNeeded)
        let inventory = try await adapter.inventory()
        let candidate = try XCTUnwrap(inventory.records.first)
        XCTAssertEqual(inventory.records.count, 1)
        let before = try StorageSparseDiskRewrite.inspectSource(
            rootURL: domain.root, relativePath: fixture.relative + "/disk.img")
        let result = await adapter.optimize(candidate, cancellation: .init())
        XCTAssertEqual(result.code, "optimized", result.diagnosticCodes.joined(separator: ","))
        XCTAssertTrue(result.verifiedFirstDisk)
        let report = try XCTUnwrap(result.report)
        XCTAssertTrue(report.stageRetired)
        XCTAssertEqual(report.sourceDigestSHA512, report.stageDigestSHA512)
        XCTAssertLessThan(report.stageAllocatedBytesAtVerification, report.sourceAllocatedBytesBefore)
        XCTAssertEqual(FloeDigest.sha256Hex(try Data(contentsOf: disk)), originalDigest)
        let after = try StorageSparseDiskRewrite.inspectSource(
            rootURL: domain.root, relativePath: fixture.relative + "/disk.img")
        XCTAssertEqual(after.identity.sizeBytes, before.identity.sizeBytes)
        XCTAssertLessThan(after.allocatedBytes, before.allocatedBytes,
                          "The committed source, not only the temporary stage, must be sparse")
        let journals = layout.primaryDirectory.appendingPathComponent("sparse-journals")
        let receipts = layout.primaryDirectory.appendingPathComponent("sparse-receipts")
        let journalName = try XCTUnwrap(fm.contentsOfDirectory(atPath: journals.path).first)
        let journalBytes = try Data(contentsOf: journals.appendingPathComponent(journalName))
        let receiptBytes = try Data(contentsOf: receipts.appendingPathComponent(journalName))
        let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: journalBytes) as? [String: Any])
        XCTAssertEqual(journal["phase"] as? String, "retired")
        XCTAssertEqual(journal["sourceDigestSHA512"] as? String, journal["stageDigestSHA512"] as? String)
        let boundJournal = try JSONDecoder().decode(RuntimeV2OptimizationCoreJournalBinding.self, from: journalBytes)
        XCTAssertTrue(boundJournal.postSwapSource?.matchesFully(after.identity) ?? false)
        for (path, bytes) in retainedHistories { XCTAssertEqual(try Data(contentsOf: path), bytes) }
        let rows = try RuntimeV2LegacyRegistryReader.read(domain: domain)
        XCTAssertEqual(rows.leaseEnvironmentIDs.count, 57)
        for (name, bytes) in preserved {
            let relative = name == "runtime.json" ? fixture.relative + "/runtime.json"
                : (name == "registry" ? "registry/runtime.sqlite" : "environments/env-a/" + name)
            XCTAssertEqual(try Data(contentsOf: domain.root.appendingPathComponent(relative)), bytes)
        }

        RuntimeV2MaintenanceRegistry.unregister(domainRoot: domain.root)
        let reopenedLayout = try domain.authorityHistoryLayout()
        XCTAssertEqual(reopenedLayout.historicalDirectories.count, 3)
        XCTAssertEqual(reopenedLayout.pendingIntentCount, 0)
        let reopenedSource = RecoveryOptimizationEvidence(domain: domain, state: reopenedLayout.primaryDirectory)
        let reopened = try RuntimeV2MaintenanceCoordinator(domain: domain,
            stateDirectory: reopenedLayout.primaryDirectory,
            evidenceProvider: { await reopenedSource.admitted() }, historyLayout: reopenedLayout)
        reopenedSource.coordinator = reopened
        _ = RuntimeV2MaintenanceRegistry.install(reopened)
        let reopenedAdapter = RuntimeV2RecoveryOptimizationAdapter(domain: domain, coordinator: reopened,
            closureAuthority: reopenedSource.closure, rawEvidence: { await reopenedSource.raw() },
            admittedEvidence: { await reopenedSource.admitted() })
        let reopenedRecovery = await reopenedAdapter.recoverBeforeUse()
        XCTAssertEqual(reopenedRecovery.outcome, .notNeeded)
        let reopenedInventory = try await reopenedAdapter.inventory()
        let reopenedCandidate = try XCTUnwrap(reopenedInventory.records.first)
        let reused = await reopenedAdapter.optimize(reopenedCandidate, cancellation: .init()) { _ in
            XCTFail("A retired commit must be reused without a second Core rewrite")
        }
        XCTAssertEqual(reused.code, "already-optimized", reused.diagnosticCodes.joined(separator: ","))
        XCTAssertTrue(reused.verifiedUnchanged)
        XCTAssertNil(reused.report)
        XCTAssertEqual(FloeDigest.sha256Hex(try Data(contentsOf: disk)), originalDigest)
        XCTAssertEqual(try Data(contentsOf: journals.appendingPathComponent(journalName)), journalBytes)
        XCTAssertEqual(try Data(contentsOf: receipts.appendingPathComponent(journalName)), receiptBytes)
        for (path, bytes) in retainedHistories { XCTAssertEqual(try Data(contentsOf: path), bytes) }
    }

    func testStalePreservedPathAndBaseDriftRemainUnchangedThroughOptimization() async throws {
        let fixture = try RecoveryOptimizationFixture(staleMarker: true, baseDrift: true); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let before = try fixture.preservedMetadata()
        let record = try await fixture.record()
        XCTAssertEqual(record.holdPathState, .differentLocationMissingDisk)
        XCTAssertEqual(record.baseComparison, .differs)
        XCTAssertTrue(record.mustPreserveRepairEvidence)
        let result = await fixture.adapter.optimize(record, cancellation: .init())
        XCTAssertEqual(result.code, "optimized")
        XCTAssertEqual(try fixture.preservedMetadata(), before)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
    }

    func testActiveReferenceAndPreStartCancellationDoNotCreateCoreJournal() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        fixture.evidence.lock.withLock { fixture.evidence.active = true }
        let active = try await fixture.record()
        let refused = await fixture.adapter.optimize(active, cancellation: .init())
        XCTAssertEqual(refused.code, "source-not-eligible")
        fixture.evidence.lock.withLock { fixture.evidence.active = false }
        let clear = try await fixture.record()
        let cancellation = RuntimeV2OptimizationCancellation(); cancellation.cancel()
        let cancelled = await fixture.adapter.optimize(clear, cancellation: cancellation)
        XCTAssertEqual(cancelled.code, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journals.path))
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
    }

    func testChangedHoldGenerationRefusesWithoutRewritingMarker() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let record = try await fixture.record()
        let generation = fixture.root.appendingPathComponent("environments/env-a/repair-hold.generation")
        try Data("8\n".utf8).write(to: generation)
        let result = await fixture.adapter.optimize(record, cancellation: .init())
        XCTAssertEqual(result.code, "identity-changed")
        XCTAssertEqual(try Data(contentsOf: generation), Data("8\n".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journals.path))
    }

    func testFreshReferenceFingerprintIsNotCachedAdmissionPermission() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let record = try await fixture.record()
        fixture.evidence.lock.withLock { fixture.evidence.changeReferenceOnAdmission = true }
        let result = await fixture.adapter.optimize(record, cancellation: .init())
        XCTAssertEqual(result.code, "identity-changed")
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journals.path))
    }

    func testVerifiedPreSwapReferenceChangeConvergesWithoutLosingTheSource() async throws {
        let descriptorLimit = try SyntheticDescriptorLimitScope()
        defer { XCTAssertEqual(descriptorLimit.restore(), 0) }
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let preserved = try fixture.preservedMetadata()
        let record = try await fixture.record()
        let result = await fixture.adapter.optimize(record, cancellation: .init()) { progress in
            if progress.phase == .verifying, progress.processedBytes == progress.totalBytes {
                fixture.evidence.lock.withLock { fixture.evidence.referenceVersion = 2 }
            }
        }
        XCTAssertEqual(result.code, "identity-changed")
        XCTAssertEqual(result.diagnosticCodes, ["reference-projection-changed"])
        XCTAssertFalse(result.recoveryPending)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        XCTAssertEqual(try fixture.preservedMetadata(), preserved)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.journals.path)
        XCTAssertEqual(names.count, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            fixture.journals.appendingPathComponent(try XCTUnwrap(names.first)))) as? [String: Any])
        XCTAssertEqual(object["phase"] as? String, "aborted")
        XCTAssertEqual(object["sourceDigestSHA512"] as? String, object["stageDigestSHA512"] as? String)
        XCTAssertEqual((object["sourceDigestSHA512"] as? String)?.count, 128)
        XCTAssertEqual(object["resolution"] as? String, "source-unchanged")
        let state = await fixture.coordinator.state()
        XCTAssertEqual(state.phase, .open)
        let again = await fixture.adapter.recoverBeforeUse()
        XCTAssertEqual(again.outcome, .notNeeded)
    }

    func testMaintenanceFailureDiagnosticsAreClosedAndPreserveExactStage() {
        let adapter = RuntimeV2RecoveryOptimizationAdapter.self
        let persistence = RuntimeV2MaintenanceError.intentPersistenceFailed(
            "temporary open", posixErrno: ENOSPC)
        XCTAssertEqual(adapter.code(persistence), "maintenance-unavailable")
        XCTAssertEqual(adapter.diagnosticCodes(persistence),
                       ["maintenance-intent-temporary-open", "maintenance-errno-space"])
        XCTAssertEqual(adapter.diagnosticCodes(RuntimeV2MaintenanceError.intentPersistenceFailed(
            "directory fsync", posixErrno: EACCES)),
            ["maintenance-intent-directory-sync", "maintenance-errno-permission"])
        XCTAssertEqual(adapter.diagnosticCodes(RuntimeV2MaintenanceError.intentPersistenceFailed(
            "unprotected native history context")), ["maintenance-intent-context"])
        XCTAssertEqual(adapter.diagnosticCodes(RuntimeV2MaintenanceError.invalidTarget(
            "the target escapes the trusted domain through a symlink")), ["maintenance-target-symlink"])
        XCTAssertEqual(adapter.diagnosticCodes(RuntimeV2MaintenanceError.targetMissing("the target does not exist")),
                       ["maintenance-target-absent"])
        XCTAssertEqual(adapter.diagnosticCodes(RuntimeV2MaintenanceError.invalidDomain(
            "native history layout differs from the coordinator")), ["maintenance-domain-layout-mismatch"])
        XCTAssertEqual(adapter.code(RuntimeV2MaintenanceError.targetIdentityMismatch(
            "preflight identity does not match the target")), "identity-changed")
        XCTAssertEqual(adapter.diagnosticCodes(RuntimeV2MaintenanceError.targetIdentityMismatch(
            "preflight identity does not match the target")), ["maintenance-target-preflight-mismatch"])

        let attributed = "private/path/to/secret-document"
        let unknownStage = RuntimeV2MaintenanceError.intentPersistenceFailed(
            attributed, posixErrno: 12_345)
        XCTAssertEqual(adapter.diagnosticCodes(unknownStage),
                       ["maintenance-intent-other", "maintenance-errno-other"])
        XCTAssertFalse(adapter.diagnosticCodes(unknownStage).joined().contains("secret"))
        XCTAssertEqual(adapter.diagnosticCodes(RuntimeV2MaintenanceError.invalidTarget(attributed)), ["maintenance-target-invalid"])
    }

    func testPhysicalRootBindingResolvesAncestorAliasesAndRejectsWrongInodes() throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        let identity = try RuntimeV2DiskIdentity.read(at: fixture.root)
        let alias = fixture.work.appendingPathComponent("ancestor-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.work)
        let aliasRoot = alias.appendingPathComponent("v2")
        XCTAssertNotEqual(aliasRoot.path, fixture.root.path)
        XCTAssertTrue(RuntimeV2RecoveryOptimizationAdapter.matchesPhysicalRoot(aliasRoot.path,
            root: fixture.root, device: identity.device, inode: identity.inode))
        XCTAssertFalse(RuntimeV2RecoveryOptimizationAdapter.matchesPhysicalRoot(fixture.state.path,
            root: fixture.root, device: identity.device, inode: identity.inode))
        let old = fixture.work.appendingPathComponent("old-root")
        try FileManager.default.moveItem(at: fixture.root, to: old)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        XCTAssertFalse(RuntimeV2RecoveryOptimizationAdapter.matchesPhysicalRoot(aliasRoot.path,
            root: fixture.root, device: identity.device, inode: identity.inode))
    }

    func testCompletedJournalReusesExactCommittedInodeWithoutReadingDiskContentsAgain() async throws {
        let descriptorLimit = try SyntheticDescriptorLimitScope()
        defer { XCTAssertEqual(descriptorLimit.restore(), 0) }
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let first = await fixture.adapter.optimize(try await fixture.record(), cancellation: .init())
        XCTAssertEqual(first.code, "optimized")
        let before = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: fixture.relative + "/disk.img")
        let preserved = try fixture.preservedMetadata()
        let journalNames = try FileManager.default.contentsOfDirectory(atPath: fixture.journals.path)
        let receiptNames = try FileManager.default.contentsOfDirectory(atPath: fixture.receipts.path)
        let journal = try XCTUnwrap(journalNames.first)
        let receipt = try XCTUnwrap(receiptNames.first)
        let journalBytes = try Data(contentsOf: fixture.journals.appendingPathComponent(journal))
        let receiptBytes = try Data(contentsOf: fixture.receipts.appendingPathComponent(receipt))
        let second = await fixture.adapter.optimize(try await fixture.record(), cancellation: .init()) { _ in
            XCTFail("A reused commit must never enter Core counting/staging/hash IO")
        }
        XCTAssertEqual(second.code, "already-optimized")
        XCTAssertNil(second.report)
        XCTAssertTrue(second.verifiedFirstDisk)
        XCTAssertFalse(second.recoveryPending)
        let after = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: fixture.relative + "/disk.img")
        XCTAssertTrue(after.identity.matchesFully(before.identity))
        XCTAssertEqual(try Data(contentsOf: fixture.journals.appendingPathComponent(journal)), journalBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.receipts.appendingPathComponent(receipt)), receiptBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.journals.path), journalNames)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.receipts.path), receiptNames)
        XCTAssertEqual(try fixture.preservedMetadata(), preserved)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        let state = await fixture.coordinator.state()
        XCTAssertEqual(state.phase, .open)
    }

    func testRenamedContainerReusesCompletedJournalWithoutNewCoreWorkOrGain() async throws {
        let descriptorLimit = try SyntheticDescriptorLimitScope()
        defer { XCTAssertEqual(descriptorLimit.restore(), 0) }
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let first = await fixture.adapter.optimize(try await fixture.record(), cancellation: .init())
        XCTAssertEqual(first.code, "optimized")
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.journals.path)
        let receiptNames = try FileManager.default.contentsOfDirectory(atPath: fixture.receipts.path)
        let journalBytes = try Data(contentsOf: fixture.journals.appendingPathComponent(try XCTUnwrap(names.first)))
        let receiptBytes = try Data(contentsOf: fixture.receipts.appendingPathComponent(try XCTUnwrap(receiptNames.first)))
        let before = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: fixture.relative + "/disk.img")
        let metadata = try fixture.preservedMetadata()
        let current = try RelocatedOptimizationSession(fixture); defer { current.cleanup() }
        XCTAssertNotEqual(current.domain.domainKey, fixture.domain.domainKey)
        XCTAssertEqual(current.state.lastPathComponent, fixture.domain.domainKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        let recovery = await current.adapter.recoverBeforeUse()
        XCTAssertEqual(recovery.outcome, .notNeeded)
        let inventory = try await current.adapter.inventory()
        let record = try XCTUnwrap(inventory.records.first)
        let result = await current.adapter.optimize(record, cancellation: .init()) { _ in
            XCTFail("A completed relocated disk must not enter Core counting/staging/digest work")
        }
        XCTAssertEqual(result.code, "already-optimized"); XCTAssertTrue(result.verifiedUnchanged)
        XCTAssertNil(result.report, "Do not count the historical gain again")
        XCTAssertFalse(result.recoveryPending)
        let after = try StorageSparseDiskRewrite.inspectSource(rootURL: current.domain.root, relativePath: fixture.relative + "/disk.img")
        XCTAssertTrue(after.identity.matchesFully(before.identity))
        let journals = current.state.appendingPathComponent("sparse-journals")
        let receipts = current.state.appendingPathComponent("sparse-receipts")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: journals.path), names)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: receipts.path), receiptNames)
        XCTAssertEqual(try Data(contentsOf: journals.appendingPathComponent(try XCTUnwrap(names.first))), journalBytes)
        XCTAssertEqual(try Data(contentsOf: receipts.appendingPathComponent(try XCTUnwrap(receiptNames.first))), receiptBytes)
        XCTAssertEqual(try Data(contentsOf: current.domain.root.appendingPathComponent(fixture.relative + "/disk.img")), fixture.original)
        for (name, bytes) in metadata {
            let path = name == "runtime.json" ? fixture.relative + "/runtime.json"
                : (name == "registry" ? "registry/runtime.sqlite" : "environments/env-a/" + name)
            XCTAssertEqual(try Data(contentsOf: current.domain.root.appendingPathComponent(path)), bytes)
        }
        XCTAssertEqual(try current.domain.authorityStateDirectory(), current.state)
    }

    func testCrossHistoryAbortedReceiptCannotHideRetiredSuccessOrRecountGain() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let first = await fixture.adapter.optimize(try await fixture.record(), cancellation: .init())
        XCTAssertEqual(first.code, "optimized")
        let history = try makeSyntheticLaterAbortedHistory(fixture)
        let oldName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: fixture.receipts.path).first)
        let oldReceiptBytes = try Data(contentsOf: fixture.receipts.appendingPathComponent(oldName))
        let oldJournalBytes = try Data(contentsOf: fixture.journals.appendingPathComponent(oldName))
        let current = try RelocatedOptimizationSession(fixture, grouped: true); defer { current.cleanup() }
        let recovery = await current.adapter.recoverBeforeUse()
        XCTAssertEqual(recovery.outcome, .notNeeded)
        let records = try await current.adapter.inventory()
        let result = await current.adapter.optimize(try XCTUnwrap(records.records.first), cancellation: .init()) { _ in
            XCTFail("Cross-history lookup must not count/hash/stage any large body")
        }
        XCTAssertEqual(result.code, "already-optimized"); XCTAssertTrue(result.verifiedUnchanged)
        XCTAssertNil(result.report, "Historical gain must not be counted again")
        XCTAssertEqual(try Data(contentsOf: current.work.appendingPathComponent(history.relativeReceipt)), history.receipt)
        XCTAssertEqual(try Data(contentsOf: current.work.appendingPathComponent(history.relativeJournal)), history.journal)
        XCTAssertEqual(try Data(contentsOf: current.domain.root.appendingPathComponent(fixture.relative + "/disk.img")), fixture.original)
        let oldContext = current.work.appendingPathComponent("MaintenanceAuthority/" + fixture.domain.domainKey)
        XCTAssertEqual(try Data(contentsOf: oldContext.appendingPathComponent("sparse-receipts/" + oldName)), oldReceiptBytes)
        XCTAssertEqual(try Data(contentsOf: oldContext.appendingPathComponent("sparse-journals/" + oldName)), oldJournalBytes)
        try await verifyCrossHistoryPreservationChangeRequiresCurrentReadAndNoGainRecheck()
    }

    private func verifyCrossHistoryPreservationChangeRequiresCurrentReadAndNoGainRecheck() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let first = await fixture.adapter.optimize(try await fixture.record(), cancellation: .init())
        XCTAssertEqual(first.code, "optimized")
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: fixture.receipts.path).first)
        let path = fixture.receipts.appendingPathComponent(name)
        var originalReceipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        // Changed requirement: an old opaque FP cannot authorize reuse. A
        // fresh complete content proof plus today's full fences must precede
        // ordinary gain rechecking. Keep the old V1 bytes untouched.
        originalReceipt["preservationFingerprint"] = String(repeating: "c", count: 64)
        try JSONSerialization.data(withJSONObject: originalReceipt, options: [.sortedKeys]).write(to: path)
        _ = try makeSyntheticLaterAbortedHistory(fixture)
        let oldName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: fixture.receipts.path).first)
        let oldReceiptBytes = try Data(contentsOf: fixture.receipts.appendingPathComponent(oldName))
        let oldJournalBytes = try Data(contentsOf: fixture.journals.appendingPathComponent(oldName))
        let current = try RelocatedOptimizationSession(fixture, grouped: true); defer { current.cleanup() }
        _ = await current.adapter.recoverBeforeUse()
        let records = try await current.adapter.inventory()
        let progress = RecoveryContentReadProbe()
        let result = await current.adapter.optimize(try XCTUnwrap(records.records.first), cancellation: .init()) { progress.record($0) }
        XCTAssertEqual(progress.phases().first, "verifying"); XCTAssertFalse(progress.snapshot().onMain)
        XCTAssertTrue(progress.phases().contains("counting")); XCTAssertTrue(progress.phases().contains("staging"))
        XCTAssertEqual(result.code, "insufficient-reclaim"); XCTAssertTrue(result.verifiedUnchanged)
        XCTAssertNil(result.report); XCTAssertFalse(result.recoveryPending)
        XCTAssertEqual(try Data(contentsOf: current.domain.root.appendingPathComponent(fixture.relative + "/disk.img")), fixture.original)
        let oldContext = current.work.appendingPathComponent("MaintenanceAuthority/" + fixture.domain.domainKey)
        XCTAssertEqual(try Data(contentsOf: oldContext.appendingPathComponent("sparse-receipts/" + oldName)), oldReceiptBytes)
        XCTAssertEqual(try Data(contentsOf: oldContext.appendingPathComponent("sparse-journals/" + oldName)), oldJournalBytes)

    }

    private func makeSyntheticLaterAbortedHistory(_ fixture: RecoveryOptimizationFixture) throws
        -> (relativeReceipt: String, receipt: Data, relativeJournal: String, journal: Data) {
        let name = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: fixture.receipts.path).first)
        let oldJournal = fixture.journals.appendingPathComponent(name)
        var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.receipts.appendingPathComponent(name))) as? [String: Any])
        var journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: oldJournal)) as? [String: Any])
        let identity = try XCTUnwrap(journal["postSwapSource"] as? [String: Any])
        let id = UUID().uuidString
        let generation = ((receipt["authorityGeneration"] as? NSNumber)?.uint64Value ?? 0) + 1
        receipt["intentID"] = id; receipt["authorityGeneration"] = generation; receipt["expectedSource"] = identity
        receipt["repairHoldGeneration"] = generation
        var closure = try XCTUnwrap(receipt["closure"] as? [String: Any])
        closure["intentID"] = id; closure["holdGeneration"] = generation; closure["proofID"] = UUID().uuidString
        receipt["closure"] = closure
        journal["jobID"] = id; journal["maintenanceLeaseID"] = id; journal["jobGeneration"] = generation
        journal["holdGeneration"] = generation
        journal["phase"] = "aborted"; journal["resolution"] = "source-unchanged"; journal["source"] = identity
        journal["stageRetired"] = false; journal["stageRetained"] = false
        journal.removeValue(forKey: "postSwapSource"); journal.removeValue(forKey: "postSwapStage")
        let context = fixture.root.deletingLastPathComponent().appendingPathComponent("MaintenanceAuthority/" + String(repeating: "b", count: 64))
        for directory in ["sparse-receipts", "sparse-journals"] {
            try FileManager.default.createDirectory(at: context.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let receiptData = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        let journalData = try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
        try receiptData.write(to: context.appendingPathComponent("sparse-receipts/" + id + ".json"))
        try journalData.write(to: context.appendingPathComponent("sparse-journals/" + id + ".json"))
        let root = try RuntimeV2DiskIdentity.read(at: fixture.root)
        let intent = RuntimeV2MaintenanceIntentRecord(intentID: id, holdGeneration: generation, phase: .resolved,
            owner: "synthetic-later-abort", reason: "synthetic-history-only", createdAt: Date(), updatedAt: Date(),
            domainRoot: fixture.domain.root.path, domainDevice: root.device, domainInode: root.inode)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(intent).write(to: context.appendingPathComponent("intent.json"))
        let suffix = "MaintenanceAuthority/" + context.lastPathComponent
        return (suffix + "/sparse-receipts/" + id + ".json", receiptData,
                suffix + "/sparse-journals/" + id + ".json", journalData)
    }

    func testChangedCommittedDiskCannotReuseAnEarlierSuccessJournal() async throws {
        let descriptorLimit = try SyntheticDescriptorLimitScope()
        defer { XCTAssertEqual(descriptorLimit.restore(), 0) }
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let first = await fixture.adapter.optimize(try await fixture.record(), cancellation: .init())
        XCTAssertEqual(first.code, "optimized")
        var changed = fixture.original; changed[1] = 0x73
        try changed.write(to: fixture.disk)
        let second = await fixture.adapter.optimize(try await fixture.record(), cancellation: .init())
        XCTAssertNotEqual(second.code, "already-optimized")
        XCTAssertEqual(second.code, "optimized")
        XCTAssertNotNil(second.report)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), changed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.journals.path).count, 2)
    }

    func testActualSharedUseAndRWRegistryConnectionBlockExclusiveUntilClosed() async throws {
        let fixture = try RecoveryOptimizationFixture(registry: false); defer { fixture.cleanup() }
        let layout = RuntimeV2Layout(root: fixture.root)
        _ = try layout.prepare(build: "synthetic")
        let registry = RuntimeV2Registry(layout: layout)
        try await registry.open()
        XCTAssertEqual(try RuntimeV2RecoveryAdmission.snapshot(root: fixture.root).liveUses, 1)
        do {
            _ = try await fixture.coordinator.acquireExclusiveMaintenance(.init(owner: "synthetic", reason: "must-refuse"))
            XCTFail("An actual open native SQLite connection cannot be declared closed")
        } catch { XCTAssertEqual(RuntimeV2RecoveryOptimizationAdapter.code(error), "busy") }
        try await registry.close()
        XCTAssertEqual(try RuntimeV2RecoveryAdmission.snapshot(root: fixture.root).liveUses, 0)
        let claim = try await fixture.coordinator.acquireExclusiveMaintenance(.init(owner: "synthetic", reason: "closed"))
        do {
            _ = try await RuntimeV2RepairHoldStore(layout: layout).place(
                environmentID: "env-a", runtimeID: "rt-env-a", reason: "must-not-publish")
            XCTFail("An exclusive claim must refuse new repair-hold writes")
        } catch {
            XCTAssertEqual(RuntimeV2RecoveryOptimizationAdapter.code(error), "busy")
        }
        try await claim.abortAndRelease(reason: "synthetic terminal state")
    }

    func testOpenAliasIsDetectedByPhysicalIdentityOutsideRoot() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        let alias = fixture.work.appendingPathComponent("outside-selected-alias")
        try FileManager.default.linkItem(at: fixture.disk, to: alias)
        let fd = open(alias.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { if fd >= 0 { close(fd) } }
        let identity = try RuntimeV2DiskIdentity.read(at: fixture.disk)
        do {
            _ = try await fixture.coordinator.acquireExclusiveMaintenance(.init(
                owner: "synthetic", reason: "must-refuse-alias",
                targetRelativePath: fixture.relative + "/disk.img", targetIdentity: identity))
            XCTFail("Selected inode open through an outside alias was not refused")
        } catch {
            XCTAssertEqual(RuntimeV2RecoveryOptimizationAdapter.code(error), "owner-unknown")
            if case RuntimeV2MaintenanceError.ownerEvidenceIncomplete(let codes) = error {
                XCTAssertTrue(codes.contains("selected_disk_fd_open"), codes.joined(separator: ","))
            } else { XCTFail("Expected the actual physical-alias closure failure") }
        }
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
    }

    func testCommittedWALRowsAreVisibleWithoutMigrationOrRowMutation() throws {
        let fixture = try RecoveryOptimizationFixture(registry: false); defer { fixture.cleanup() }
        let db = try XCTUnwrap(RecoveryOptimizationFixture.createRegistry(
            at: fixture.root.appendingPathComponent("registry/runtime.sqlite"), leases: 1, keepWAL: true))
        defer { sqlite3_close_v2(db) }
        try RecoveryOptimizationFixture.execute(db, "INSERT INTO leases VALUES('env-wal','rt-env-wal','inc','token','held')")
        let mainBefore = try Data(contentsOf: fixture.root.appendingPathComponent("registry/runtime.sqlite"))
        let result = try RuntimeV2LegacyRegistryReader.read(domain: fixture.domain)
        XCTAssertEqual(Set(result.leaseEnvironmentIDs), Set(["env-a", "env-wal"]))
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("registry/runtime.sqlite")), mainBefore)
    }

    func testUnknownLeaseStateAndOversizedRowSetRemainUnknown() throws {
        let fixture = try RecoveryOptimizationFixture(registry: false); defer { fixture.cleanup() }
        let db = try XCTUnwrap(RecoveryOptimizationFixture.createRegistry(
            at: fixture.root.appendingPathComponent("registry/runtime.sqlite"), leases: 1, keepWAL: true))
        defer { sqlite3_close_v2(db) }
        try RecoveryOptimizationFixture.execute(db, "UPDATE leases SET state='future-owner-state'")
        XCTAssertThrowsError(try RuntimeV2LegacyRegistryReader.read(domain: fixture.domain))
        try RecoveryOptimizationFixture.execute(db, "UPDATE leases SET state='held'")
        try RecoveryOptimizationFixture.execute(db, """
            WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<4096)
            INSERT INTO leases SELECT 'large-'||x,'rt-large-'||x,'inc','token','stale' FROM n
            """)
        XCTAssertThrowsError(try RuntimeV2LegacyRegistryReader.read(domain: fixture.domain))
    }

    func testSourceProviderGenerationChangeNeedsRealRecoverySession() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let source = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: fixture.relative + "/disk.img")
        let claim = try await fixture.coordinator.acquireExclusiveMaintenance(.init(
            owner: "app-legacy-storage-optimization", reason: "lossless-legacy-recovery",
            targetRelativePath: fixture.relative + "/disk.img",
            targetIdentity: RuntimeV2RecoveryOptimizationAdapter.runtimeIdentity(source.identity)))
        RuntimeV2RecoveryAdmission.ownerSourcesChanged(root: fixture.root)
        let invalid = await fixture.evidence.admitted()
        XCTAssertFalse(invalid.isComplete)
        await claim.handoffToRecovery()
        let converged = await fixture.adapter.recoverBeforeUse()
        XCTAssertEqual(converged.outcome, .resolved)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
    }

    func testRealCoreCrashAfterSwapConvergesThroughInstalledHandler() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let record = try await fixture.record()
        let source = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: fixture.relative + "/disk.img")
        let claim = try await fixture.coordinator.acquireExclusiveMaintenance(.init(
            owner: "app-legacy-storage-optimization", reason: "lossless-legacy-recovery",
            targetRelativePath: fixture.relative + "/disk.img",
            targetIdentity: RuntimeV2RecoveryOptimizationAdapter.runtimeIdentity(source.identity)))
        let closed = try await fixture.evidence.closure.currentReceipt(intentID: claim.intentID)
        let receipt = RuntimeV2OptimizationJobReceipt(
            version: 1, intentID: claim.intentID, authorityGeneration: claim.holdGeneration,
            domainKey: fixture.domain.domainKey, relativePath: fixture.relative + "/disk.img",
            expectedSource: source.identity,
            preservationFingerprint: try RuntimeV2OptimizationPreservation(record).fingerprint(),
            repairHoldGeneration: 7, closure: closed)
        try RuntimeV2OptimizationJournalIO.writeOnce(receipt, directory: fixture.receipts, name: claim.intentID + ".json")
        try FileManager.default.createDirectory(at: fixture.journals, withIntermediateDirectories: true)
        try await claim.markCommitting()
        let fence = StorageSparseDiskMaintenanceFence(leaseID: claim.intentID, generation: claim.holdGeneration) {
            try RuntimeV2OptimizationAsyncFence.check {
                try await claim.validate()
                let fresh = await fixture.evidence.admitted()
                guard fresh.isComplete else { throw StorageSparseDiskRewriteError.needsInspection("test-proof") }
                try claim.validateReferenceFingerprint(fresh.references.fingerprint)
            }
        }
        let request = StorageSparseDiskRewriteRequest(
            rootURL: fixture.root, relativePath: receipt.relativePath, expectedSource: source.identity,
            journalDirectoryURL: fixture.journals, jobID: claim.intentID, maintenanceLeaseID: claim.intentID,
            holdGeneration: 7, jobGeneration: claim.holdGeneration, mode: .cloneAndPunch,
            minimumReclaimBytes: 1, allowSparseCopyFallback: false)
        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.crashAt = { if $0 == .afterSwap { throw StorageSparseDiskRewriteError.crashInjected("adapter-after-swap") } }
        let capturedHooks = hooks
        let worker = RuntimeV2OptimizationWorker("synthetic.real-core", allowsSynchronousFence: true)
        do {
            _ = try await worker.run {
                try StorageSparseDiskRewrite._rewrite(request, fence: fence, hooks: capturedHooks,
                                                      isCancelled: { false })
            }
            XCTFail("Expected the explicit synthetic durable crash point")
        } catch { XCTAssertEqual(error as? StorageSparseDiskRewriteError, .crashInjected("adapter-after-swap")) }
        fixture.evidence.lock.withLock { fixture.evidence.active = true }
        await claim.handoffToRecovery()
        let recovered = await fixture.adapter.recoverBeforeUse()
        XCTAssertEqual(recovered.outcome, .resolved)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        let repeatPass = await fixture.adapter.recoverBeforeUse()
        XCTAssertEqual(repeatPass.outcome, .notNeeded)
    }

    func testRenamedContainerRealCoreCrashAfterSwapConvergesThroughCurrentHeldSession() async throws {
        let descriptorLimit = try SyntheticDescriptorLimitScope()
        defer { XCTAssertEqual(descriptorLimit.restore(), 0) }
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let record = try await fixture.record()
        let source = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: fixture.relative + "/disk.img")
        let claim = try await fixture.coordinator.acquireExclusiveMaintenance(.init(
            owner: "app-legacy-storage-optimization", reason: "lossless-legacy-recovery",
            targetRelativePath: fixture.relative + "/disk.img",
            targetIdentity: RuntimeV2RecoveryOptimizationAdapter.runtimeIdentity(source.identity)))
        let closed = try await fixture.evidence.closure.currentReceipt(intentID: claim.intentID)
        let receipt = RuntimeV2OptimizationJobReceipt(
            version: 1, intentID: claim.intentID, authorityGeneration: claim.holdGeneration,
            domainKey: fixture.domain.domainKey, relativePath: fixture.relative + "/disk.img",
            expectedSource: source.identity,
            preservationFingerprint: try RuntimeV2OptimizationPreservation(record).fingerprint(),
            repairHoldGeneration: 7, closure: closed)
        try RuntimeV2OptimizationJournalIO.writeOnce(receipt, directory: fixture.receipts, name: claim.intentID + ".json")
        try FileManager.default.createDirectory(at: fixture.journals, withIntermediateDirectories: true)
        try await claim.markCommitting()
        let fence = StorageSparseDiskMaintenanceFence(leaseID: claim.intentID, generation: claim.holdGeneration) {
            try RuntimeV2OptimizationAsyncFence.check {
                try await claim.validate()
                let fresh = await fixture.evidence.admitted()
                guard fresh.isComplete else { throw StorageSparseDiskRewriteError.needsInspection("test-proof") }
                try claim.validateReferenceFingerprint(fresh.references.fingerprint)
            }
        }
        let request = StorageSparseDiskRewriteRequest(
            rootURL: fixture.root, relativePath: receipt.relativePath, expectedSource: source.identity,
            journalDirectoryURL: fixture.journals, jobID: claim.intentID, maintenanceLeaseID: claim.intentID,
            holdGeneration: 7, jobGeneration: claim.holdGeneration, mode: .cloneAndPunch,
            minimumReclaimBytes: 1, allowSparseCopyFallback: false)
        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.crashAt = { if $0 == .afterSwap { throw StorageSparseDiskRewriteError.crashInjected("adapter-after-swap") } }
        let capturedHooks = hooks
        let worker = RuntimeV2OptimizationWorker("synthetic.real-core", allowsSynchronousFence: true)
        do {
            _ = try await worker.run {
                try StorageSparseDiskRewrite._rewrite(request, fence: fence, hooks: capturedHooks,
                                                      isCancelled: { false })
            }
            XCTFail("Expected the explicit synthetic durable crash point")
        } catch { XCTAssertEqual(error as? StorageSparseDiskRewriteError, .crashInjected("adapter-after-swap")) }
        fixture.evidence.lock.withLock { fixture.evidence.active = true }
        await claim.handoffToRecovery()
        let current = try RelocatedOptimizationSession(fixture); defer { current.cleanup() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        current.evidence.lock.withLock { current.evidence.active = true }
        let recovered = await current.adapter.recoverBeforeUse()
        XCTAssertEqual(recovered.outcome, .resolved)
        XCTAssertEqual(try Data(contentsOf: current.domain.root.appendingPathComponent(receipt.relativePath)), fixture.original)
        let savedJournal = current.state.appendingPathComponent("sparse-journals/" + claim.intentID + ".json")
        let settled = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: savedJournal)) as? [String: Any])
        XCTAssertEqual(settled["phase"] as? String, "retired")
        XCTAssertEqual(settled["sourceDigestSHA512"] as? String, settled["stageDigestSHA512"] as? String)
        XCTAssertEqual(settled["rootPath"] as? String, fixture.root.path)
        let closureDirectory = current.state.appendingPathComponent("closed-receipts")
        let closureNames = try FileManager.default.contentsOfDirectory(atPath: closureDirectory.path)
        var foundFresh = false
        for name in closureNames {
            if let proof = try RuntimeV2OptimizationJournalIO.read(RuntimeV2RecoveryClosedReceipt.self,
                directory: closureDirectory, name: name), proof.isConvergenceProof {
                XCTAssertEqual(proof.domainKey, current.domain.domainKey)
                XCTAssertNotEqual(proof.proofID, closed.proofID)
                XCTAssertEqual(proof.rootDevice, closed.rootDevice); XCTAssertEqual(proof.rootInode, closed.rootInode)
                foundFresh = true
            }
        }
        XCTAssertTrue(foundFresh, "Recovery requires a new current-incarnation closure proof")
        let repeatPass = await current.adapter.recoverBeforeUse()
        XCTAssertEqual(repeatPass.outcome, .notNeeded)
        let state = await current.coordinator.state()
        XCTAssertEqual(state.phase, .open)
    }

    func testGroupedRecoveryRoutesRealPostSwapJournalToOriginalContext() async throws {
        let descriptorLimit = try SyntheticDescriptorLimitScope()
        defer { XCTAssertEqual(descriptorLimit.restore(), 0) }
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let record = try await fixture.record()
        let source = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: fixture.relative + "/disk.img")
        let claim = try await fixture.coordinator.acquireExclusiveMaintenance(.init(
            owner: "app-legacy-storage-optimization", reason: "lossless-legacy-recovery",
            targetRelativePath: fixture.relative + "/disk.img",
            targetIdentity: RuntimeV2RecoveryOptimizationAdapter.runtimeIdentity(source.identity)))
        let closed = try await fixture.evidence.closure.currentReceipt(intentID: claim.intentID)
        let receipt = RuntimeV2OptimizationJobReceipt(
            version: 1, intentID: claim.intentID, authorityGeneration: claim.holdGeneration,
            domainKey: fixture.domain.domainKey, relativePath: fixture.relative + "/disk.img",
            expectedSource: source.identity,
            preservationFingerprint: try RuntimeV2OptimizationPreservation(record).fingerprint(),
            repairHoldGeneration: 7, closure: closed)
        try RuntimeV2OptimizationJournalIO.writeOnce(receipt, directory: fixture.receipts, name: claim.intentID + ".json")
        try FileManager.default.createDirectory(at: fixture.journals, withIntermediateDirectories: true)
        try await claim.markCommitting()
        let fence = StorageSparseDiskMaintenanceFence(leaseID: claim.intentID, generation: claim.holdGeneration) {
            try RuntimeV2OptimizationAsyncFence.check {
                try await claim.validate()
                let fresh = await fixture.evidence.admitted()
                guard fresh.isComplete else { throw StorageSparseDiskRewriteError.needsInspection("test-proof") }
                try claim.validateReferenceFingerprint(fresh.references.fingerprint)
            }
        }
        let request = StorageSparseDiskRewriteRequest(
            rootURL: fixture.root, relativePath: receipt.relativePath, expectedSource: source.identity,
            journalDirectoryURL: fixture.journals, jobID: claim.intentID, maintenanceLeaseID: claim.intentID,
            holdGeneration: 7, jobGeneration: claim.holdGeneration, mode: .cloneAndPunch,
            minimumReclaimBytes: 1, allowSparseCopyFallback: false)
        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.crashAt = { if $0 == .afterSwap { throw StorageSparseDiskRewriteError.crashInjected("adapter-after-swap") } }
        let capturedHooks = hooks
        let worker = RuntimeV2OptimizationWorker("synthetic.real-core", allowsSynchronousFence: true)
        do {
            _ = try await worker.run {
                try StorageSparseDiskRewrite._rewrite(request, fence: fence, hooks: capturedHooks,
                                                      isCancelled: { false })
            }
            XCTFail("Expected the explicit synthetic durable crash point")
        } catch { XCTAssertEqual(error as? StorageSparseDiskRewriteError, .crashInjected("adapter-after-swap")) }
        fixture.evidence.lock.withLock { fixture.evidence.active = true }
        await claim.handoffToRecovery()
        // A second original namespace remains terminal. Both histories and
        // the new empty current namespace must join the same native barrier.
        let originalCoreRootPath = try XCTUnwrap(RuntimeV2OptimizationJournalIO.read(
            RuntimeV2OptimizationCoreJournalBinding.self, directory: fixture.journals,
            name: claim.intentID + ".json")).rootPath
        XCTAssertEqual(originalCoreRootPath, fixture.root.standardizedFileURL.resolvingSymlinksInPath().path)
        let neighbor = fixture.work.appendingPathComponent("MaintenanceAuthority/" + String(repeating: "b", count: 64))
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: true)
        let physical = try RuntimeV2DiskIdentity.read(at: fixture.root)
        let terminal = RuntimeV2MaintenanceIntentRecord(intentID: UUID().uuidString,
            holdGeneration: claim.holdGeneration + 1, phase: .resolved,
            owner: "synthetic-terminal-neighbor", reason: "synthetic-provenance",
            createdAt: Date(), updatedAt: Date(), domainRoot: fixture.root.path,
            domainDevice: physical.device, domainInode: physical.inode)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let terminalBytes = try encoder.encode(terminal)
        try terminalBytes.write(to: neighbor.appendingPathComponent("intent.json"))
        let current = try RelocatedOptimizationSession(fixture, grouped: true); defer { current.cleanup() }
        XCTAssertEqual(current.state.lastPathComponent, current.domain.domainKey)
        XCTAssertNotEqual(current.state.lastPathComponent, fixture.domain.domainKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        current.evidence.lock.withLock { current.evidence.active = true }
        let recovered = await current.adapter.recoverBeforeUse()
        XCTAssertEqual(recovered.outcome, .resolved)
        XCTAssertEqual(try Data(contentsOf: current.domain.root.appendingPathComponent(receipt.relativePath)), fixture.original)
        let originalContext = current.work.appendingPathComponent("MaintenanceAuthority/" + fixture.domain.domainKey)
        let savedJournal = originalContext.appendingPathComponent("sparse-journals/" + claim.intentID + ".json")
        let originalIntent = try XCTUnwrap(RuntimeV2MaintenanceCoordinator.readHistoryIntent(directory: originalContext))
        XCTAssertEqual(originalIntent.phase, .resolved)
        XCTAssertEqual(originalIntent.intentID, claim.intentID)
        XCTAssertEqual(try Data(contentsOf: current.work.appendingPathComponent("MaintenanceAuthority/" + neighbor.lastPathComponent + "/intent.json")), terminalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.state.appendingPathComponent("sparse-journals/" + claim.intentID + ".json").path),
            "Do not recover or fabricate a journal in the new empty namespace")
        let settled = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: savedJournal)) as? [String: Any])
        XCTAssertEqual(settled["phase"] as? String, "retired")
        XCTAssertEqual(settled["sourceDigestSHA512"] as? String, settled["stageDigestSHA512"] as? String)
        XCTAssertEqual(settled["rootPath"] as? String, originalCoreRootPath)
        let closureDirectory = current.state.appendingPathComponent("closed-receipts")
        let closureNames = try FileManager.default.contentsOfDirectory(atPath: closureDirectory.path)
        var foundFresh = false
        for name in closureNames {
            if let proof = try RuntimeV2OptimizationJournalIO.read(RuntimeV2RecoveryClosedReceipt.self,
                directory: closureDirectory, name: name), proof.isConvergenceProof {
                XCTAssertEqual(proof.domainKey, current.domain.domainKey)
                XCTAssertNotEqual(proof.proofID, closed.proofID)
                XCTAssertEqual(proof.rootDevice, closed.rootDevice); XCTAssertEqual(proof.rootInode, closed.rootInode)
                foundFresh = true
            }
        }
        XCTAssertTrue(foundFresh, "Recovery requires a new current-incarnation closure proof")
        let repeatPass = await current.adapter.recoverBeforeUse()
        XCTAssertEqual(repeatPass.outcome, .notNeeded)
        let state = await current.coordinator.state()
        XCTAssertEqual(state.phase, .open)
    }

    func testFutureReferenceCannotDeadlockUnchangedIntentConvergence() async throws {
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let source = try StorageSparseDiskRewrite.inspectSource(rootURL: fixture.root, relativePath: fixture.relative + "/disk.img")
        let claim = try await fixture.coordinator.acquireExclusiveMaintenance(.init(
            owner: "app-legacy-storage-optimization", reason: "lossless-legacy-recovery",
            targetRelativePath: fixture.relative + "/disk.img",
            targetIdentity: RuntimeV2RecoveryOptimizationAdapter.runtimeIdentity(source.identity)))
        fixture.evidence.lock.withLock { fixture.evidence.active = true }
        let normal = await fixture.evidence.admitted()
        XCTAssertFalse(normal.isComplete) // a NEW optimization still refuses
        await claim.handoffToRecovery()
        let result = await fixture.adapter.recoverBeforeUse()
        XCTAssertEqual(result.outcome, .resolved)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        let state = await fixture.coordinator.state()
        XCTAssertEqual(state.phase, .open)
    }
}
#endif
