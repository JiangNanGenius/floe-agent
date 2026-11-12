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
        lock.withLock {
            admissions += 1
            if changeReferenceOnAdmission && admissions == 2 { referenceVersion += 1 }
        }
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

@MainActor
final class RuntimeV2RecoveryOptimizationTests: XCTestCase {
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
        let fixture = try RecoveryOptimizationFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let metadata = try fixture.preservedMetadata()
        let record = try await fixture.record()
        let result = await fixture.adapter.optimize(record, cancellation: .init())
        XCTAssertEqual(result.code, "optimized", result.diagnosticCodes.joined(separator: ","))
        XCTAssertTrue(result.verifiedFirstDisk)
        XCTAssertEqual(try Data(contentsOf: fixture.disk), fixture.original)
        XCTAssertEqual(try fixture.preservedMetadata(), metadata)
        let rows = try RuntimeV2LegacyRegistryReader.read(domain: fixture.domain)
        XCTAssertEqual(rows.leaseEnvironmentIDs.count, 57)
        let state = await fixture.coordinator.state()
        XCTAssertEqual(state.phase, .open)
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
