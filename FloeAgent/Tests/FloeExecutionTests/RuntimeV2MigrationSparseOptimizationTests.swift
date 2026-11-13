// Synthetic storage fixtures only: real SQLite, native claims/FD audit and
// Core clone/punch/recovery. Never a guest boot or physical-device acceptance.
#if canImport(Darwin) && DEBUG
import Foundation
import Darwin
import SQLite3
import XCTest
@testable import FloeCore
@testable import FloeExecution

private final class MigrationSparseEvidence: @unchecked Sendable {
    let domain: RuntimeV2MaintenanceDomain
    let closure: RuntimeV2RecoveryClosureAuthority
    weak var coordinator: RuntimeV2MaintenanceCoordinator?
    let lock = NSLock()
    var activeReference = false
    var referenceGeneration = 1
    init(domain: RuntimeV2MaintenanceDomain, state: URL) {
        self.domain = domain; closure = .init(domain: domain, stateDirectory: state)
    }
    func raw() async -> RuntimeV2MaintenanceOwnerEvidence {
        let values = lock.withLock { (activeReference, referenceGeneration) }
        do {
            let rows = try await RuntimeV2LegacyRegistryReader.readAsync(domain: domain)
            return .init(isComplete: true, registry: .init(isComplete: true),
                integrator: .init(storeRootPath: domain.root.path, leaseRegistryEnvironments: rows.leaseEnvironmentIDs),
                references: .init(isComplete: true, activeEnvironmentIDs: values.0 ? ["env-0"] : [],
                    fingerprint: FloeDigest.sha256Hex(Data("synthetic-migration-ref-\(values.0)-\(values.1)".utf8))),
                filesystem: .init(leaseEnvironmentIDs: rows.leaseEnvironmentIDs,
                                  legacyRegistryFingerprint: rows.fingerprint))
        } catch { return .init(isComplete: false, blockers: ["synthetic_registry_unavailable"]) }
    }
    func admitted() async -> RuntimeV2MaintenanceOwnerEvidence {
        var evidence = await raw()
        do {
            guard let coordinator else { throw StorageSparseDiskRewriteError.injectedFailure("synthetic-authority") }
            let intent = try await coordinator.nativeClosureIntent()
            return try await closure.proveClosed(evidence: evidence, intent: intent, coordinator: coordinator)
        } catch {
            evidence.isComplete = false; evidence.blockers.append("synthetic_closed_proof_refused")
            if case RuntimeV2MaintenanceError.ownerEvidenceIncomplete(let codes) = error {
                evidence.blockers.append(contentsOf: codes)
            }
            return evidence
        }
    }
}

private final class MigrationSparseFixture: @unchecked Sendable {
    let work: URL
    let root: URL
    let domain: RuntimeV2MaintenanceDomain
    let state: URL
    let evidence: MigrationSparseEvidence
    let coordinator: RuntimeV2MaintenanceCoordinator
    let adapter: RuntimeV2RecoveryOptimizationAdapter
    let originals: [String: Data]
    var journals: URL { state.appendingPathComponent("image-sparse-journals") }
    var receipts: URL { state.appendingPathComponent("image-sparse-receipts") }

    init() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("migration-sparse-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let canonical = directory.path.withCString({ realpath($0, nil) }) else { throw POSIXError(.ENOENT) }
        let work = URL(fileURLWithPath: String(cString: canonical)); free(canonical)
        let root = work.appendingPathComponent("v2")
        let state = work.appendingPathComponent("authority")
        for relative in ["registry", "images/manifests", "environments", "recovery/quarantine"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(relative), withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        var originals: [String: Data] = [:]
        var manifestByID: [String: RuntimeV2ImageStore.Manifest] = [:]
        for (index, target) in RuntimeV2MigrationSparseCatalog.targets.enumerated() {
            let parent = root.appendingPathComponent(target.parent)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            var data = Data(repeating: 0, count: 4 << 20)
            data[0] = UInt8(index + 11); data[data.count - 1] = 0xBA
            // The two branches deliberately contain different nonzero bytes.
            // This is lossless sparsification, never presumed deduplication.
            try data.write(to: parent.appendingPathComponent("disk.img")); originals[target.relativePath] = data
            let bios = Data("synthetic-bios-\(index)".utf8)
            try bios.write(to: parent.appendingPathComponent("bios.bin"))
            let image = LinuxGuestImage(id: target.imageID, biosPath: "bios.bin", diskPath: "disk.img",
                qualified: true, qualificationRun: "synthetic-migration-storage-only",
                artifacts: [
                    .init(role: .bios, path: "bios.bin", sha512: FloeDigest.sha512Hex(bios), bytes: Int64(bios.count)),
                    .init(role: .disk, path: "disk.img", sha512: FloeDigest.sha512Hex(data), bytes: Int64(data.count))
                ])
            let legacy = try encoder.encode(image)
            try legacy.write(to: parent.appendingPathComponent("manifest.json"))
            let current = RuntimeV2ImageStore.Manifest(imageID: target.imageID, createdAt: Date(),
                artifacts: ["rootfs": .init(sha512: FloeDigest.sha512Hex(data), bytes: Int64(data.count), expandedPath: "disk.img")],
                legacyManifestData: legacy)
            manifestByID[target.imageID] = current
            try Data("keep unique rollback metadata".utf8).write(to: parent.appendingPathComponent("rollback-note.txt"))
        }
        let layout = RuntimeV2Layout(root: root)
        let registry = RuntimeV2Registry(layout: layout)
        try await registry.open()
        do {
            for (index, id) in RuntimeV2MigrationSparseCatalog.imageIDs.enumerated() {
                let manifest = try XCTUnwrap(manifestByID[id])
                try encoder.encode(manifest).write(to: root.appendingPathComponent("images/manifests/" + id + ".json"))
                try await registry.registerStagedImage(id: id, manifestPath: "images/manifests/" + id + ".json", bytes: 4 << 20)
                try await registry.markImageVerified(id: id, expandedPath: "images/expanded/" + id,
                                                     baseRootfsDigest: try XCTUnwrap(manifest.rootfsDigest))
                try await registry.beginMigration(id: "legacy-image-" + id, kind: "legacy-image",
                    sourcePath: "/retired-test-container/Library/Application Support/FloeAgent/LinuxGuest/images/" + id,
                    targetPath: "/retired-test-container/Library/Application Support/Floe/Runtime/v2/images/expanded/" + id,
                    detail: nil)
                try await registry.setMigrationPhase(id: "legacy-image-" + id,
                                                      phase: index == 3 ? .failed : .cleanupPending)
                let env = "env-\(index)"
                try FileManager.default.createDirectory(at: root.appendingPathComponent("environments/" + env),
                                                       withIntermediateDirectories: true)
                try await registry.upsertEnvironment(.init(id: env, kind: "synthetic", ownerID: nil, name: nil,
                    baseImageID: id, baseRootfsDigest: manifest.rootfsDigest, state: "active", dataPath: "environments/" + env,
                    compatHostFHS: false, repairReason: nil, createdAt: Date(), lastUsedAt: Date()))
            }
            try await registry.close()
        } catch { try? await registry.close(); throw error }
        let domain = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: root)
        RuntimeV2RecoveryAdmission.installSyntheticDomainForTests(domain: domain, stateDirectory: state)
        let evidence = MigrationSparseEvidence(domain: domain, state: state)
        let coordinator = try RuntimeV2MaintenanceCoordinator(domain: domain, stateDirectory: state,
            evidenceProvider: { await evidence.admitted() })
        evidence.coordinator = coordinator
        _ = RuntimeV2MaintenanceRegistry.install(coordinator)
        self.work = work; self.root = root; self.state = state; self.domain = domain
        self.evidence = evidence; self.coordinator = coordinator; self.originals = originals
        adapter = .init(domain: domain, coordinator: coordinator, closureAuthority: evidence.closure,
                        rawEvidence: { await evidence.raw() }, admittedEvidence: { await evidence.admitted() })
    }
    func cleanup() {
        RuntimeV2MaintenanceRegistry.unregister(domainRoot: domain.root)
        try? FileManager.default.removeItem(at: work)
    }
    func records() async throws -> [RuntimeV2MigrationSparseRecord] {
        let report = try await adapter.migrationInventory()
        XCTAssertTrue(report.isComplete, report.codes.joined(separator: ","))
        XCTAssertEqual(report.blockedPaths, 0)
        return report.records
    }
    func metadataBytes() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey]))
        for case let path as URL in enumerator {
            if path.lastPathComponent != "disk.img", try path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[String(path.path.dropFirst(root.path.count + 1))] = try Data(contentsOf: path)
            }
        }
        return result
    }
    func sql(_ sql: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(root.appendingPathComponent("registry/runtime.sqlite").path,
                                      &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let db = try XCTUnwrap(database); defer { XCTAssertEqual(sqlite3_close(db), SQLITE_OK) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
}

private struct MovedMigrationSparseFixture {
    let work: URL
    let domain: RuntimeV2MaintenanceDomain
    let state: URL
    let evidence: MigrationSparseEvidence
    let coordinator: RuntimeV2MaintenanceCoordinator
    let adapter: RuntimeV2RecoveryOptimizationAdapter
    init(_ fixture: MigrationSparseFixture) throws {
        let indexed = fixture.root.deletingLastPathComponent().appendingPathComponent("MaintenanceAuthority/" + fixture.domain.domainKey)
        try FileManager.default.createDirectory(at: indexed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.state, to: indexed)
        let moved = fixture.work.deletingLastPathComponent().appendingPathComponent(fixture.work.lastPathComponent + "-moved")
        try FileManager.default.moveItem(at: fixture.work, to: moved)
        let domain = try RuntimeV2MaintenanceDomain(trustedLegacyRoot: moved.appendingPathComponent("v2"))
        let state = try domain.authorityStateDirectory()
        RuntimeV2RecoveryAdmission.installSyntheticDomainForTests(domain: domain, stateDirectory: state)
        let evidence = MigrationSparseEvidence(domain: domain, state: state)
        let coordinator = try RuntimeV2MaintenanceCoordinator(domain: domain, stateDirectory: state,
            evidenceProvider: { await evidence.admitted() })
        evidence.coordinator = coordinator
        _ = RuntimeV2MaintenanceRegistry.install(coordinator)
        self.work = moved; self.domain = domain; self.state = state
        self.evidence = evidence; self.coordinator = coordinator
        adapter = .init(domain: domain, coordinator: coordinator, closureAuthority: evidence.closure,
                        rawEvidence: { await evidence.raw() }, admittedEvidence: { await evidence.admitted() })
    }
    func cleanup() {
        RuntimeV2MaintenanceRegistry.unregister(domainRoot: domain.root)
        try? FileManager.default.removeItem(at: work)
    }
}

@MainActor final class RuntimeV2MigrationSparseOptimizationTests: XCTestCase {
    // Same explicit synthetic-host condition as the existing real-Core suite.
    // Production audit is unchanged and no high descriptor may be ignored.
    private var originalLimit: rlimit?
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["FLOE_SYNTHETIC_FD_BOUND"] == "16384" else { return }
        var limit = rlimit(); XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &limit), 0)
        for name in try FileManager.default.contentsOfDirectory(atPath: "/dev/fd") {
            let fd = try XCTUnwrap(Int32(name))
            if fcntl(fd, F_GETFD, 0) >= 0 { XCTAssertLessThan(fd, 16_384); guard fd < 16_384 else { throw POSIXError(.EMFILE) } }
            else { XCTAssertEqual(errno, EBADF) }
        }
        guard limit.rlim_max >= 16_384 else { throw POSIXError(.EMFILE) }
        var bounded = limit; bounded.rlim_cur = 16_384
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &bounded), 0); originalLimit = limit
    }
    override func tearDownWithError() throws {
        if var limit = originalLimit { XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &limit), 0) }
    }

    func testSixFixedMigrationShapesRewriteLosslesslyAndKeepAllRegistryAndRollbackMetadata() async throws {
        let fixture = try await MigrationSparseFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let records = try await fixture.records()
        XCTAssertEqual(records.count, 6)
        let metadata = try fixture.metadataBytes()
        for record in records {
            let result = await fixture.adapter.optimizeMigration(record, cancellation: .init())
            XCTAssertEqual(result.code, "optimized", result.diagnosticCodes.joined(separator: ","))
            XCTAssertTrue(result.verifiedFirstDisk); XCTAssertFalse(result.recoveryPending)
        }
        XCTAssertEqual(try fixture.metadataBytes(), metadata)
        for (path, expected) in fixture.originals {
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(path)), expected)
        }
        let current = try await fixture.records()
        XCTAssertEqual(current.count, 6)
        for record in current {
            let result = await fixture.adapter.optimizeMigration(record, cancellation: .init()) { _ in
                XCTFail("Completed migration receipt must bypass Core byte-reading work")
            }
            XCTAssertEqual(result.code, "already-optimized"); XCTAssertNil(result.report)
            XCTAssertTrue(result.verifiedUnchanged)
        }
    }

    func testChangedMigrationGenerationManifestAndUnknownPhaseNeverBecomeAdmission() async throws {
        let fixture = try await MigrationSparseFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let originalRecords = try await fixture.records()
        let first = try XCTUnwrap(originalRecords.first)
        let relative = first.target.relativePath
        try fixture.sql("UPDATE migrations SET updated_at='2030-01-01T00:00:01.000Z' WHERE id='\(first.target.migrationID)'")
        let changed = await fixture.adapter.optimizeMigration(first, cancellation: .init())
        XCTAssertEqual(changed.code, "identity-changed")
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(relative)), fixture.originals[relative])
        let refreshedRecords = try await fixture.records()
        let fresh = try XCTUnwrap(refreshedRecords.first)
        let manifest = fixture.root.appendingPathComponent(fresh.target.parent + "/manifest.json")
        let before = try Data(contentsOf: manifest)
        try Data("{}".utf8).write(to: manifest)
        let invalid = await fixture.adapter.optimizeMigration(fresh, cancellation: .init())
        XCTAssertNotEqual(invalid.code, "optimized")
        XCTAssertEqual(try Data(contentsOf: manifest), Data("{}".utf8))
        try before.write(to: manifest)
        try fixture.sql("UPDATE migrations SET phase='unknown-phase' WHERE id='\(first.target.migrationID)'")
        do { _ = try await fixture.adapter.migrationInventory(); XCTFail("Unknown phase cannot be projected") }
        catch { XCTAssertEqual(RuntimeV2RecoveryOptimizationAdapter.code(error), "owner-unknown") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journals.path))
    }

    func testRealSharedUseAndOpenNativeSourcePreventMigrationRewrite() async throws {
        let fixture = try await MigrationSparseFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let records = try await fixture.records()
        let record = try XCTUnwrap(records.first)
        let use = try XCTUnwrap(RuntimeV2RecoveryAdmission.acquire(root: fixture.root))
        let busy = await fixture.adapter.optimizeMigration(record, cancellation: .init())
        XCTAssertEqual(busy.code, "busy"); use.release()
        let fd = open(fixture.root.appendingPathComponent(record.target.relativePath).path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(fd, 0); guard fd >= 0 else { throw POSIXError(.EIO) }
        let openOwner = await fixture.adapter.optimizeMigration(record, cancellation: .init())
        close(fd)
        XCTAssertEqual(openOwner.code, "owner-unknown")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journals.path))
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(record.target.relativePath)), fixture.originals[record.target.relativePath])
    }

    func testCancellationAfterVerificationRecoversOriginalAndPreservesTheOtherBranch() async throws {
        let fixture = try await MigrationSparseFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let records = try await fixture.records()
        let record = try XCTUnwrap(records.first)
        let cancellation = RuntimeV2OptimizationCancellation()
        let metadata = try fixture.metadataBytes()
        let result = await fixture.adapter.optimizeMigration(record, cancellation: cancellation) { progress in
            if progress.phase == .verifying, progress.processedBytes == progress.totalBytes { cancellation.cancel() }
        }
        XCTAssertEqual(result.code, "cancelled"); XCTAssertFalse(result.recoveryPending)
        XCTAssertEqual(try fixture.metadataBytes(), metadata)
        for (path, original) in fixture.originals {
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(path)), original)
        }
        let state = await fixture.coordinator.state(); XCTAssertEqual(state.phase, .open)
    }

    func testAfterSwapCrashRecoversThroughSameHandlerAfterContainerRelocation() async throws {
        let fixture = try await MigrationSparseFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let records = try await fixture.records()
        let record = try XCTUnwrap(records.first)
        let claim = try await fixture.coordinator.acquireExclusiveMaintenance(.init(owner: RuntimeV2MigrationSparseOptimizer.owner,
            reason: RuntimeV2MigrationSparseOptimizer.reason, targetRelativePath: record.target.relativePath,
            targetIdentity: RuntimeV2RecoveryOptimizationAdapter.runtimeIdentity(record.source)))
        let closure = try await fixture.evidence.closure.currentReceipt(intentID: claim.intentID)
        let coreGeneration = try XCTUnwrap(Int64(exactly: claim.holdGeneration))
        let receipt = RuntimeV2MigrationSparseReceipt(schema: 1, producer: "FloeMigrationSparse/1", intentID: claim.intentID,
            authorityGeneration: claim.holdGeneration, coreHoldGeneration: coreGeneration, domainKey: fixture.domain.domainKey,
            record: record, preservationFingerprint: try record.preservationFingerprint(), closure: closure)
        try RuntimeV2OptimizationJournalIO.writeOnce(receipt, directory: fixture.receipts, name: claim.intentID + ".json")
        try FileManager.default.createDirectory(at: fixture.journals, withIntermediateDirectories: true)
        try await claim.markCommitting()
        let fence = StorageSparseDiskMaintenanceFence(leaseID: claim.intentID, generation: claim.holdGeneration) {
            try RuntimeV2OptimizationAsyncFence.check {
                try await claim.validate()
                let fresh = await fixture.evidence.admitted()
                guard fresh.isComplete else { throw StorageSparseDiskRewriteError.needsInspection("synthetic-proof") }
                try claim.validateReferenceFingerprint(fresh.references.fingerprint)
            }
        }
        let request = StorageSparseDiskRewriteRequest(rootURL: fixture.root, relativePath: record.target.relativePath,
            expectedSource: record.source, journalDirectoryURL: fixture.journals, jobID: claim.intentID,
            maintenanceLeaseID: claim.intentID, holdGeneration: coreGeneration, jobGeneration: claim.holdGeneration,
            mode: .cloneAndPunch, minimumReclaimBytes: 1, allowSparseCopyFallback: false)
        var hooks = StorageSparseDiskRewrite.TestHooks()
        hooks.crashAt = { if $0 == .afterSwap { throw StorageSparseDiskRewriteError.crashInjected("migration-after-swap") } }
        let copiedHooks = hooks
        let worker = RuntimeV2OptimizationWorker("synthetic.migration-crash", allowsSynchronousFence: true)
        do {
            _ = try await worker.run { try StorageSparseDiskRewrite._rewrite(request, fence: fence, hooks: copiedHooks, isCancelled: { false }) }
            XCTFail("Expected the explicit Core crash point")
        } catch { XCTAssertEqual(error as? StorageSparseDiskRewriteError, .crashInjected("migration-after-swap")) }
        await claim.handoffToRecovery()
        let moved = try MovedMigrationSparseFixture(fixture); defer { moved.cleanup() }
        let recovered = await moved.adapter.recoverBeforeUse()
        XCTAssertEqual(recovered.outcome, .resolved)
        XCTAssertEqual(moved.state.lastPathComponent, fixture.domain.domainKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.path))
        for (path, expected) in fixture.originals {
            XCTAssertEqual(try Data(contentsOf: moved.domain.root.appendingPathComponent(path)), expected)
        }
        let again = await moved.adapter.recoverBeforeUse(); XCTAssertEqual(again.outcome, .notNeeded)
        let current = try await moved.adapter.migrationInventory()
        let fresh = try XCTUnwrap(current.records.first(where: { $0.target == record.target }))
        let reuse = await moved.adapter.optimizeMigration(fresh, cancellation: .init()) { _ in
            XCTFail("Recovered committed receipt must not rewrite bytes")
        }
        XCTAssertEqual(reuse.code, "already-optimized"); XCTAssertNil(reuse.report)
    }

    func testChangedCompletedDiskNeverUsesAnOldSuccessAsPermission() async throws {
        let fixture = try await MigrationSparseFixture(); defer { fixture.cleanup() }
        _ = await fixture.adapter.recoverBeforeUse()
        let records = try await fixture.records()
        let record = try XCTUnwrap(records.first)
        let first = await fixture.adapter.optimizeMigration(record, cancellation: .init())
        XCTAssertEqual(first.code, "optimized")
        var changed = try XCTUnwrap(fixture.originals[record.target.relativePath]); changed[1] = 0xED
        try changed.write(to: fixture.root.appendingPathComponent(record.target.relativePath))
        let stale = await fixture.adapter.optimizeMigration(record, cancellation: .init())
        XCTAssertEqual(stale.code, "identity-changed")
        let freshRecords = try await fixture.records()
        let fresh = try XCTUnwrap(freshRecords.first)
        let second = await fixture.adapter.optimizeMigration(fresh, cancellation: .init())
        XCTAssertEqual(second.code, "optimized"); XCTAssertNotNil(second.report)
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(record.target.relativePath)), changed)
    }

    func testExistingV1ReceiptSurvivesMigrationQueueWithoutCoreWorkOrRecounting() async throws {
        let fixture = try await MigrationSparseFixture(); defer { fixture.cleanup() }
        let relative = "recovery/quarantine/runtime-vm-rt-repair-env-" + UUID().uuidString
        let env = "environments/repair-env"
        for path in [relative, env, "runtime/vm"] {
            try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let base = String(repeating: "d", count: 128)
        func json(_ object: [String: Any], _ path: String) throws {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                .write(to: fixture.root.appendingPathComponent(path))
        }
        try json(["version": 1, "environmentID": "repair-env", "runtimeID": "rt-repair-env",
                  "baseImageID": "synthetic-repair-base", "bootBaseDiskDigest": base], relative + "/runtime.json")
        try json(["version": 1, "environmentID": "repair-env", "baseImageID": "synthetic-repair-base",
                  "baseRootfsSHA512": base], env + "/metadata.json")
        try json(["version": 2, "environmentID": "repair-env", "runtimeID": "rt-repair-env",
                  "holdID": UUID().uuidString, "preservedPath": relative], env + "/repair-hold.json")
        try Data("7\n".utf8).write(to: fixture.root.appendingPathComponent(env + "/repair-hold.generation"))
        var bytes = Data(repeating: 0, count: 4 << 20); bytes[0] = 0xCD; bytes[bytes.count - 1] = 0xEF
        try bytes.write(to: fixture.root.appendingPathComponent(relative + "/disk.img"))
        _ = await fixture.adapter.recoverBeforeUse()
        let oldInventory = try await fixture.adapter.inventory()
        let oldRecord = try XCTUnwrap(oldInventory.records.first(where: { $0.relativeDirectory == relative }))
        let oldResult = await fixture.adapter.optimize(oldRecord, cancellation: .init())
        XCTAssertEqual(oldResult.code, "optimized")
        let oldJournals = fixture.state.appendingPathComponent("sparse-journals")
        let oldReceipts = fixture.state.appendingPathComponent("sparse-receipts")
        let journalName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: oldJournals.path).first)
        let receiptName = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: oldReceipts.path).first)
        let savedJournal = try Data(contentsOf: oldJournals.appendingPathComponent(journalName))
        let savedReceipt = try Data(contentsOf: oldReceipts.appendingPathComponent(receiptName))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RuntimeV2OptimizationJobReceipt.self, from: savedReceipt)
        XCTAssertEqual(decoded.version, 1)
        let migrations = try await fixture.records()
        let migration = try XCTUnwrap(migrations.first)
        let result = await fixture.adapter.optimizeMigration(migration, cancellation: .init())
        XCTAssertEqual(result.code, "optimized")
        let refreshed = try await fixture.adapter.inventory()
        let current = try XCTUnwrap(refreshed.records.first(where: { $0.relativeDirectory == relative }))
        let reused = await fixture.adapter.optimize(current, cancellation: .init()) { _ in
            XCTFail("The pre-existing v1 receipt must not be rewritten through the new typed branch")
        }
        XCTAssertEqual(reused.code, "already-optimized"); XCTAssertTrue(reused.verifiedUnchanged)
        XCTAssertNil(reused.report, "A historical gain must not be counted again")
        XCTAssertEqual(try Data(contentsOf: oldJournals.appendingPathComponent(journalName)), savedJournal)
        XCTAssertEqual(try Data(contentsOf: oldReceipts.appendingPathComponent(receiptName)), savedReceipt)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: oldJournals.path), [journalName])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: oldReceipts.path), [receiptName])
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(relative + "/disk.img")), bytes)
    }

    func testMigrationProjectionReadsUncheckpointedWALWithoutMutatingRegistryOrSource() async throws {
        let fixture = try await MigrationSparseFixture(); defer { fixture.cleanup() }
        let path = fixture.root.appendingPathComponent("registry/runtime.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        let writer = try XCTUnwrap(handle); defer { XCTAssertEqual(sqlite3_close(writer), SQLITE_OK) }
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA wal_autocheckpoint=0", nil, nil, nil), SQLITE_OK)
        let id = try XCTUnwrap(RuntimeV2MigrationSparseCatalog.imageIDs.first)
        XCTAssertEqual(sqlite3_exec(writer,
            "UPDATE migrations SET updated_at='2031-01-01T00:00:00.000Z' WHERE id='legacy-image-\(id)'", nil, nil, nil), SQLITE_OK)
        let wal = URL(fileURLWithPath: path.path + "-wal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wal.path))
        let before = try Data(contentsOf: path), beforeWAL = try Data(contentsOf: wal)
        let projection = try await RuntimeV2LegacyRegistryReader.readMigrationProjectionAsync(domain: fixture.domain)
        XCTAssertEqual(try projection.binding(imageID: id).updatedAt, "2031-01-01T00:00:00.000Z")
        XCTAssertEqual(try Data(contentsOf: path), before)
        XCTAssertEqual(try Data(contentsOf: wal), beforeWAL)
        for (relative, original) in fixture.originals {
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(relative)), original)
        }
    }
}
#endif
