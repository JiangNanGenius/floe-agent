// FloeExecutionTests — Runtime v2 startup + migration regression tests.
//
// Build 222/223 shipped a schema_migrations collision (migration v1 re-created
// the bootstrap table), so every fresh Runtime v2 registry failed to open and
// an installed Linux guest could never start. These tests pin the repaired
// behavior: fresh open, reopen idempotency, the exact residue shape a failed
// Build 223 launch leaves behind, the lease lifecycle, startup recovery, and
// idempotent legacy image/environment migration into the verified store.

import Foundation
import SQLite3
import XCTest
import FloeCore
@testable import FloeExecution

final class RuntimeV2StartupTests: XCTestCase {
    private var root: URL!
    private var layout: RuntimeV2Layout!
    private var store: RuntimeV2Store!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-v2-startup-\(UUID().uuidString)", isDirectory: true)
        layout = RuntimeV2Layout(root: root)
        store = RuntimeV2Store(layout: layout)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - registry open + schema migrations

    /// The Build 223 regression itself: a fresh registry must open. Before
    /// the fix this threw `table schema_migrations already exists` because
    /// migration v1 re-created the bootstrap table inside its transaction.
    func testFreshRegistryOpensAndAppliesSchema() async throws {
        let report = try await store.prepareAndRecover(build: "test")
        XCTAssertEqual(report.interruptedQueueEntries, 0)
        XCTAssertTrue(report.unreclaimableLeases.isEmpty)

        // The schema is real and usable: a full environment round trip.
        var row = RuntimeV2Registry.EnvironmentRow(
            id: "env-fresh", kind: "linuxVM", ownerID: nil, name: "Fresh",
            baseImageID: "img", baseRootfsDigest: nil, state: "active",
            dataPath: "environments/env-fresh/data", compatHostFHS: false,
            repairReason: nil, createdAt: Date(), lastUsedAt: Date()
        )
        try await store.registry.upsertEnvironment(row)
        var read = try await store.registry.environment(id: "env-fresh")
        XCTAssertEqual(read?.name, "Fresh")
        row.state = "stopped"
        try await store.registry.upsertEnvironment(row)
        read = try await store.registry.environment(id: "env-fresh")
        XCTAssertEqual(read?.state, "stopped")
        let stopped = try await store.registry.environments(state: "stopped")
        XCTAssertEqual(stopped.count, 1)
    }

    /// Reopening an applied registry (every app launch after the first) must
    /// be a no-op: migrations are never replayed, data survives.
    func testReopenIsIdempotentAndPreservesData() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await store.registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: "env-reopen", kind: "linuxVM", ownerID: "owner-1", name: nil,
                baseImageID: nil, baseRootfsDigest: nil, state: "active",
                dataPath: nil, compatHostFHS: false, repairReason: nil,
                createdAt: Date(), lastUsedAt: Date()
            )
        )

        let registry = RuntimeV2Registry(layout: layout)
        try await registry.open()
        try await registry.open() // second call is a guarded no-op
        let read = try await registry.environment(id: "env-reopen")
        XCTAssertEqual(read?.ownerID, "owner-1")
    }

    /// The exact residue a failed Build 223 launch left on disk: the
    /// bootstrap `schema_migrations` table exists (committed outside the
    /// failed migration's transaction) and no migration ever applied. The
    /// repaired registry must adopt this database, not reject it.
    func testBootstrapOnlyDatabaseFromFailedBuild223Migrates() async throws {
        _ = try layout.prepare(build: "223")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(layout.registryDatabaseURL.path, &db), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL)",
                nil, nil, nil
            ),
            SQLITE_OK
        )
        sqlite3_close(db)

        let registry = RuntimeV2Registry(layout: layout)
        try await registry.open()
        try await registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: "env-residue", kind: "linuxVM", ownerID: nil, name: nil,
                baseImageID: nil, baseRootfsDigest: nil, state: "active",
                dataPath: nil, compatHostFHS: false, repairReason: nil,
                createdAt: Date(), lastUsedAt: Date()
            )
        )
        let residue = try await registry.environment(id: "env-residue")
        XCTAssertNotNil(residue)
        // Each applied migration is recorded exactly once (v1 "initial" plus
        // the later additive migrations — the schema-migration table must
        // never contain a duplicate version).
        var verify: OpaquePointer?
        XCTAssertEqual(sqlite3_open(layout.registryDatabaseURL.path, &verify), SQLITE_OK)
        defer { sqlite3_close(verify) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                verify,
                "SELECT COUNT(*) - COUNT(DISTINCT version) FROM schema_migrations",
                -1, &statement, nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
        sqlite3_finalize(statement)
        var versionOne: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(
                verify, "SELECT COUNT(*) FROM schema_migrations WHERE version = 1",
                -1, &versionOne, nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(versionOne), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(versionOne, 0), 1)
        sqlite3_finalize(versionOne)
    }

    /// The applied SQL audit artifact is written next to the database and no
    /// longer contains the colliding bootstrap statement.
    func testMigrationAuditArtifactWritten() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let audit = layout.registryMigrationsDirectory.appendingPathComponent("0001_initial.sql")
        XCTAssertTrue(FileManager.default.fileExists(atPath: audit.path))
        let sql = try String(contentsOf: audit, encoding: .utf8)
        XCTAssertTrue(sql.contains("CREATE TABLE images"))
        XCTAssertFalse(sql.contains("CREATE TABLE schema_migrations"))
    }

    // MARK: - startup recovery

    /// Queue entries still open after a process death are explicitly marked
    /// interrupted on the next launch — never silently resumed.
    func testStartupRecoveryMarksInterruptedQueueEntries() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await store.registry.recordQueueEntry(
            RuntimeV2Registry.QueueRow(
                id: "q-1", environmentID: "env-1", requestedMB: 512,
                state: "queued", enqueuedAt: Date(), startedAt: nil, finishedAt: nil
            )
        )
        try await store.registry.recordQueueEntry(
            RuntimeV2Registry.QueueRow(
                id: "q-2", environmentID: "env-2", requestedMB: 512,
                state: "running", enqueuedAt: Date(), startedAt: Date(), finishedAt: nil
            )
        )

        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertEqual(report.interruptedQueueEntries, 2)
        let interrupted = try await relaunched.registry.queueEntries(state: "interrupted")
        XCTAssertEqual(Set(interrupted.map(\.id)), Set(["q-1", "q-2"]))
        // A third launch finds nothing new to interrupt.
        let third = RuntimeV2Store(layout: layout)
        let thirdReport = try await third.prepareAndRecover(build: "test")
        XCTAssertEqual(thirdReport.interruptedQueueEntries, 0)
    }

    // MARK: - leases

    func testLeaseAcquireReclaimAndRelease() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let leases = await store.leases

        let first = try await leases.acquire(environmentID: "env-lease", runtimeID: "rt-1")
        // Re-entrant for the same runtime.
        _ = try await leases.acquire(environmentID: "env-lease", runtimeID: "rt-1")
        // A different runtime is refused while the holder is live.
        do {
            _ = try await leases.acquire(environmentID: "env-lease", runtimeID: "rt-2")
            XCTFail("a live lease must refuse a second writer")
        } catch RuntimeV2Error.leaseHeld {
            // expected
        }
        try await leases.holder(environmentID: "env-lease").map { XCTAssertEqual($0.runtimeID, "rt-1") }
        await first.release()
        let releasedHolder = try await leases.holder(environmentID: "env-lease")
        XCTAssertNil(releasedHolder)

        // A lease from a dead incarnation with a dead pid and an expired TTL
        // is provably stale and is reclaimed, not adopted.
        let staleDirectory = try layout.environmentDirectory(environmentID: "env-lease")
        try FileManager.default.createDirectory(at: staleDirectory, withIntermediateDirectories: true)
        let stale = RuntimeV2LeaseStore.Lease(
            environmentID: "env-lease", runtimeID: "rt-old", incarnation: "dead-incarnation",
            sessionToken: "token", pid: 4_000_000, // far beyond any live pid
            acquiredAt: Date(timeIntervalSinceNow: -600), renewedAt: Date(timeIntervalSinceNow: -600),
            ttlSeconds: 30
        )
        try RuntimeV2LeaseStore.encoder.encode(stale).write(
            to: staleDirectory.appendingPathComponent("lease.json"), options: .atomic
        )
        let reclaimed = try await leases.acquire(environmentID: "env-lease", runtimeID: "rt-new")
        XCTAssertEqual(reclaimed.lease.runtimeID, "rt-new")
        await reclaimed.release()

        // A corrupt lease sidecar is quarantined, never half-trusted.
        try Data("not json".utf8).write(to: staleDirectory.appendingPathComponent("lease.json"))
        let corruptHolder = try await leases.holder(environmentID: "env-lease")
        XCTAssertNil(corruptHolder)
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("lease-env-lease") }
        XCTAssertEqual(quarantined.count, 1)
    }

    // MARK: - legacy image migration

    /// A legacy `<root>/<id>` install migrates into the content-addressed
    /// store exactly once: the second call is an explicit no-op reuse, and
    /// the legacy bytes stay recoverable in the migration rollback point.
    func testLegacyImageMigrationIsIdempotent() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, directory) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)

        let first = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)
        XCTAssertEqual(first.phase, .cleanupPending)
        XCTAssertFalse(first.reusedExisting)
        let verifiedAfterFirst = try await store.images.isImageVerified(imageID: image.id)
        XCTAssertTrue(verifiedAfterFirst)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let rollback = layout.recoveryMigrationsDirectory
            .appendingPathComponent("legacy-image-\(image.id)/legacy-images/\(image.id)", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rollback.path))

        // Second call: the legacy manifest is gone (moved aside) and the v2
        // install is verified — the migration reports the existing state
        // instead of failing on the missing source.
        let second = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)
        XCTAssertTrue(second.reusedExisting)
        XCTAssertEqual(Set(second.blobDigests), Set(first.blobDigests))
        let verifiedAfterSecond = try await store.images.isImageVerified(imageID: image.id)
        XCTAssertTrue(verifiedAfterSecond)
    }

    /// A never-installed image id still fails with the honest reason; the
    /// idempotent reuse path can never invent an install.
    func testLegacyImageMigrationWithoutAnyInstallFails() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        do {
            _ = try await store.images.migrateLegacyImage(imageID: "missing-image", legacyImagesRoot: legacyRoot)
            XCTFail("migrating a missing image must throw")
        } catch RuntimeV2Error.migrationFailed(_, let phase, _) {
            XCTAssertEqual(phase, "discovered")
        }
    }

    // MARK: - legacy environment migration

    /// A legacy environment whose disk never started migrates its layer data
    /// into the v2 data dir exactly once; user files survive every rerun.
    func testLegacyEnvironmentMigrationWithoutDiskIsIdempotent() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)

        let layer = root.appendingPathComponent("legacy-layer", isDirectory: true)
        try FileManager.default.createDirectory(
            at: layer.appendingPathComponent("home/floe", isDirectory: true), withIntermediateDirectories: true
        )
        try Data("user note".utf8).write(to: layer.appendingPathComponent("home/floe/note.txt"))
        // The legacy LinuxGuest runtime subtree is excluded from the data dir.
        try FileManager.default.createDirectory(
            at: layer.appendingPathComponent("LinuxGuest/disks/env-9", isDirectory: true), withIntermediateDirectories: true
        )
        try Data("disk".utf8).write(
            to: layer.appendingPathComponent("LinuxGuest/disks/env-9/disk.img")
        )

        let migrator = RuntimeV2EnvironmentMigrator(store: store)
        let first = try await migrator.migrateLegacyEnvironment(
            environmentID: "env-9", kind: "linuxVM", ownerID: nil, name: nil,
            baseImageID: image.id, legacyDiskDirectory: nil, legacyLayerDirectory: layer
        )
        XCTAssertEqual(first.phase, .cleanupPending)
        XCTAssertEqual(first.dataFiles, 1)
        let dataDirectory = try layout.environmentDataDirectory(environmentID: "env-9")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("home/floe/note.txt").path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("LinuxGuest").path)
        )
        let row = try await store.registry.environment(id: "env-9")
        XCTAssertEqual(row?.state, "active")
        XCTAssertEqual(row?.baseImageID, image.id)

        // Rerun: data is not duplicated, lost or switched away.
        let second = try await migrator.migrateLegacyEnvironment(
            environmentID: "env-9", kind: "linuxVM", ownerID: nil, name: nil,
            baseImageID: image.id, legacyDiskDirectory: nil, legacyLayerDirectory: layer
        )
        XCTAssertEqual(second.phase, .cleanupPending)
        XCTAssertEqual(second.dataFiles, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dataDirectory.appendingPathComponent("home/floe/note.txt").path)
        )
        // The FloeEnvironments-owned legacy layer itself was never modified.
        XCTAssertTrue(FileManager.default.fileExists(atPath: layer.appendingPathComponent("LinuxGuest/disks/env-9/disk.img").path))
    }

    /// A legacy environment disk is captured into a verified block delta and
    /// proven by a full round-trip comparison; the modified guest bytes come
    /// back on materialization.
    func testLegacyEnvironmentDiskMigratesIntoVerifiedDelta() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)
        let expanded = try await store.images.ensureExpanded(imageID: image.id)
        let baseRootfs = expanded.appendingPathComponent("rootfs.img")

        // Legacy disk: a byte clone of the verified base with one modified
        // block, plus the origin sidecar naming the verified base.
        let diskDirectory = root
            .appendingPathComponent("legacy-disks", isDirectory: true)
            .appendingPathComponent("env-disk", isDirectory: true)
        try FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        let diskURL = diskDirectory.appendingPathComponent("disk.img")
        try FileManager.default.copyItem(at: baseRootfs, to: diskURL)
        // The expanded base is deliberately read-only (0444); a legacy
        // environment disk is the writable clone, so restore write permission
        // exactly like the real preparer does.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: diskURL.path)
        let handle = try FileHandle(forUpdating: diskURL)
        try handle.seek(toOffset: 1 << 20)
        try handle.write(contentsOf: Data(repeating: 0xAB, count: 4096))
        try handle.close()
        let origin = LinuxGuestRuntimeDiskOrigin(
            imageID: image.id,
            artifactSHA512: try FloeDigest.sha512Hex(ofFileAt: baseRootfs),
            artifactBytes: Int64((try FileManager.default.attributesOfItem(atPath: baseRootfs.path)[.size] as? Int64) ?? 0)
        )
        let originEncoder = JSONEncoder()
        originEncoder.dateEncodingStrategy = .iso8601
        try originEncoder.encode(origin).write(
            to: diskDirectory.appendingPathComponent("origin.json"), options: .atomic
        )

        let migrator = RuntimeV2EnvironmentMigrator(store: store)
        let report = try await migrator.migrateLegacyEnvironment(
            environmentID: "env-disk", kind: "linuxVM", ownerID: nil, name: nil,
            baseImageID: image.id, legacyDiskDirectory: diskDirectory, legacyLayerDirectory: nil
        )
        XCTAssertEqual(report.phase, .cleanupPending)
        XCTAssertGreaterThan(report.deltaBlocks, 0)
        // The legacy disk directory became the rollback point, never deleted.
        XCTAssertFalse(FileManager.default.fileExists(atPath: diskDirectory.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.recoveryMigrationsDirectory
                    .appendingPathComponent("legacy-env-env-disk/legacy-disks", isDirectory: true).path
            )
        )

        // The delta re-materializes the guest's modified bytes exactly.
        let working = root.appendingPathComponent("rework/disk.img")
        _ = try await store.deltas.materializeWorkingDisk(
            environmentID: "env-disk", baseRootfs: baseRootfs, into: working
        )
        let check = try FileHandle(forReadingFrom: working)
        try check.seek(toOffset: 1 << 20)
        let bytes = try check.read(upToCount: 4096)
        try check.close()
        XCTAssertEqual(bytes, Data(repeating: 0xAB, count: 4096))
    }

    /// An environment disk whose origin does not descend from the verified
    /// base is quarantined and the environment is marked repairRequired —
    /// never overwritten.
    func testLegacyEnvironmentDiskOriginConflictIsQuarantined() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)

        let diskDirectory = root
            .appendingPathComponent("legacy-disks", isDirectory: true)
            .appendingPathComponent("env-conflict", isDirectory: true)
        try FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1 << 20).write(to: diskDirectory.appendingPathComponent("disk.img"))
        let origin = LinuxGuestRuntimeDiskOrigin(
            imageID: "some-other-image",
            artifactSHA512: String(repeating: "a", count: 128),
            artifactBytes: 1 << 20
        )
        let originEncoder = JSONEncoder()
        originEncoder.dateEncodingStrategy = .iso8601
        try originEncoder.encode(origin).write(
            to: diskDirectory.appendingPathComponent("origin.json"), options: .atomic
        )

        let migrator = RuntimeV2EnvironmentMigrator(store: store)
        do {
            _ = try await migrator.migrateLegacyEnvironment(
                environmentID: "env-conflict", kind: "linuxVM", ownerID: nil, name: nil,
                baseImageID: image.id, legacyDiskDirectory: diskDirectory, legacyLayerDirectory: nil
            )
            XCTFail("an origin conflict must throw")
        } catch RuntimeV2Error.deltaBaseConflict {
            // expected
        }
        let row = try await store.registry.environment(id: "env-conflict")
        XCTAssertEqual(row?.state, "repairRequired")
        // The mismatched disk was quarantined, not adopted or destroyed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: diskDirectory.path))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("disk-env-conflict") }
        XCTAssertEqual(quarantined.count, 1)
    }

    // MARK: - repairRequired fail-closed regressions

    /// Review blocker: an origin-conflict migration upserts a
    /// repairRequired row and quarantines the legacy disk, but a later
    /// `prepareWorkingDisk` treated mere row existence as "migrated" and
    /// booted a fresh empty data/delta while the real disk stayed
    /// quarantined. Every retry must now fail closed — before any lease,
    /// materialization or capture — and the preserved data must survive.
    func testRepairRequiredEnvironmentFailsClosedOnEveryPrepareRetry() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)

        // A legacy writable layer whose disk declares a foreign origin.
        let layer = root.appendingPathComponent("legacy-layer", isDirectory: true)
        let diskDirectory = layer
            .appendingPathComponent("LinuxGuest/disks/env-retry", isDirectory: true)
        try FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1 << 20).write(to: diskDirectory.appendingPathComponent("disk.img"))
        let origin = LinuxGuestRuntimeDiskOrigin(
            imageID: "some-other-image",
            artifactSHA512: String(repeating: "a", count: 128),
            artifactBytes: 1 << 20
        )
        let originEncoder = JSONEncoder()
        originEncoder.dateEncodingStrategy = .iso8601
        try originEncoder.encode(origin).write(
            to: diskDirectory.appendingPathComponent("origin.json"), options: .atomic
        )

        // First attempt: the migration itself fails with the origin conflict
        // and quarantines the disk.
        let integrator = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: legacyRoot, build: "test")
        do {
            _ = try await integrator.prepareWorkingDisk(
                environmentID: "env-retry", runtimeID: "rt-retry", imageID: image.id,
                legacyWritableDirectory: layer, targetCapacityBytes: 4 << 20
            )
            XCTFail("an origin conflict must fail the start")
        } catch RuntimeV2Error.deltaBaseConflict {
            // expected
        }
        let row = try await store.registry.environment(id: "env-retry")
        XCTAssertEqual(row?.state, "repairRequired")
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("disk-env-retry") }
        XCTAssertEqual(quarantined.count, 1)

        // The retry (e.g. the user tapping start again, or the next launch)
        // must fail closed with the explicit repair state — never boot a
        // fresh empty environment over the quarantined data.
        let relaunched = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: legacyRoot, build: "test")
        do {
            _ = try await relaunched.prepareWorkingDisk(
                environmentID: "env-retry", runtimeID: "rt-retry-2", imageID: image.id,
                legacyWritableDirectory: layer, targetCapacityBytes: 4 << 20
            )
            XCTFail("a repairRequired environment must never boot")
        } catch RuntimeV2Error.environmentRepairRequired(let environmentID, _) {
            XCTAssertEqual(environmentID, "env-retry")
        }
        // Nothing was materialized, captured or leased by the failed retry.
        let deltaAfterRetry = try await store.deltas.loadDelta(environmentID: "env-retry")
        XCTAssertNil(deltaAfterRetry)
        let leaseAfterRetry = try await store.leases.holder(environmentID: "env-retry")
        XCTAssertNil(leaseAfterRetry)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (try? layout.runtimeVMDirectory(runtimeID: "rt-retry-2"))?.path ?? ""
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (try? layout.environmentDataDirectory(environmentID: "env-retry"))?.path ?? ""
            )
        )
        // The quarantined disk is still preserved, untouched.
        let quarantinedAfterRetry = try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("disk-env-retry") }
        XCTAssertEqual(quarantinedAfterRetry.count, 1)
        let rowAfterRetry = try await store.registry.environment(id: "env-retry")
        XCTAssertEqual(rowAfterRetry?.state, "repairRequired")
    }

    /// A direct migrator retry against a repairRequired environment fails
    /// closed too: re-running the phase machine would skip the (quarantined)
    /// disk, copy the layer and activate an empty system delta.
    func testRepairRequiredMigrationRetryFailsClosed() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)

        let layer = root.appendingPathComponent("legacy-layer", isDirectory: true)
        let diskDirectory = layer
            .appendingPathComponent("LinuxGuest/disks/env-migrator-retry", isDirectory: true)
        try FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1 << 20).write(to: diskDirectory.appendingPathComponent("disk.img"))
        let origin = LinuxGuestRuntimeDiskOrigin(
            imageID: "some-other-image",
            artifactSHA512: String(repeating: "a", count: 128),
            artifactBytes: 1 << 20
        )
        let originEncoder = JSONEncoder()
        originEncoder.dateEncodingStrategy = .iso8601
        try originEncoder.encode(origin).write(
            to: diskDirectory.appendingPathComponent("origin.json"), options: .atomic
        )

        let migrator = RuntimeV2EnvironmentMigrator(store: store)
        do {
            _ = try await migrator.migrateLegacyEnvironment(
                environmentID: "env-migrator-retry", kind: "linuxVM", ownerID: nil, name: nil,
                baseImageID: image.id, legacyDiskDirectory: diskDirectory, legacyLayerDirectory: layer
            )
            XCTFail("an origin conflict must throw")
        } catch RuntimeV2Error.deltaBaseConflict {
            // expected
        }

        // Retry with the disk now quarantined (directory gone): the migrator
        // must refuse instead of activating an empty environment.
        do {
            _ = try await migrator.migrateLegacyEnvironment(
                environmentID: "env-migrator-retry", kind: "linuxVM", ownerID: nil, name: nil,
                baseImageID: image.id, legacyDiskDirectory: diskDirectory, legacyLayerDirectory: layer
            )
            XCTFail("a repairRequired environment must never re-migrate into activation")
        } catch RuntimeV2Error.environmentRepairRequired(let environmentID, _) {
            XCTAssertEqual(environmentID, "env-migrator-retry")
        }
        let row = try await store.registry.environment(id: "env-migrator-retry")
        XCTAssertEqual(row?.state, "repairRequired")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (try? layout.environmentDataDirectory(environmentID: "env-migrator-retry"))?.path ?? ""
            )
        )
    }

    /// Review blocker: install status reads the disposable
    /// `images/expanded/<id>/manifest.json`. When the registry row, v2
    /// manifest and blobs are verified but the expanded view is lost
    /// (it is excluded from backup), startup recovery must rebuild it from
    /// the verified blobs — never report uninstalled, never redownload.
    func testMissingExpandedViewRebuildsFromVerifiedBlobsOnRecovery() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)
        let expanded = try await store.images.ensureExpanded(imageID: image.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expanded.appendingPathComponent("manifest.json").path))

        // The disposable view is lost (device restore, cache prune).
        try FileManager.default.removeItem(at: expanded)

        // Relaunch: recovery rebuilds the view from the verified blobs.
        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertEqual(report.rebuiltExpandedViews, [image.id])
        XCTAssertTrue(report.notes.isEmpty)

        let rebuilt = try await relaunched.images.ensureExpanded(imageID: image.id)
        // The exact read the install-status surface performs: the verbatim
        // legacy manifest decodes again.
        let manifestData = try Data(contentsOf: rebuilt.appendingPathComponent("manifest.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LinuxGuestImage.self, from: manifestData)
        XCTAssertEqual(decoded.id, image.id)
        // Every artifact is back at its recorded digest.
        for artifact in image.artifacts ?? [] {
            let digest = try FloeDigest.sha512Hex(
                ofFileAt: rebuilt.appendingPathComponent(artifact.path)
            )
            XCTAssertEqual(digest, artifact.sha512.lowercased())
        }
        let stillVerified = try await relaunched.images.isImageVerified(imageID: image.id)
        XCTAssertTrue(stillVerified)

        // A second launch finds the intact view and rebuilds nothing.
        let third = RuntimeV2Store(layout: layout)
        let thirdReport = try await third.prepareAndRecover(build: "test")
        XCTAssertEqual(thirdReport.rebuiltExpandedViews, [])
    }

    // MARK: - integrator start/stop cycle (no VM)

    /// The full Runtime v2 ownership cycle the guest registry drives on a
    /// start: pool admission, environment migration, single-writer lease,
    /// working-disk materialization, verified delta capture on a clean stop,
    /// lease release and slot release.
    func testIntegratorStartStopCycleCapturesDeltaAndReleasesLease() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)

        let integrator = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: legacyRoot, build: "test")
        let admission = try await integrator.acquireSlot(
            environmentID: "env-cycle", runtimeID: "rt-cycle", requestedMB: 512
        )
        XCTAssertGreaterThan(admission.ramMB, 0)
        let work = try await integrator.prepareWorkingDisk(
            environmentID: "env-cycle", runtimeID: "rt-cycle", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.diskURL.path))
        let leaseHolder = try await store.leases.holder(environmentID: "env-cycle")
        XCTAssertEqual(leaseHolder?.runtimeID, "rt-cycle")
        let dataDirectory = try await integrator.environmentDataDirectory(environmentID: "env-cycle")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dataDirectory.path))

        // The guest dirties one block; a clean stop captures it into the delta.
        let handle = try FileHandle(forUpdating: work.diskURL)
        try handle.seek(toOffset: 2 << 20)
        try handle.write(contentsOf: Data(repeating: 0xCD, count: 4096))
        try handle.close()
        await integrator.completeStop(
            environmentID: "env-cycle", runtimeID: "rt-cycle", imageID: image.id, clean: true
        )
        let releasedHolder = try await store.leases.holder(environmentID: "env-cycle")
        XCTAssertNil(releasedHolder)
        let delta = try await store.deltas.loadDelta(environmentID: "env-cycle")
        XCTAssertGreaterThan(delta?.presentBlocks ?? 0, 0)
        XCTAssertEqual(delta?.header.baseImageID, image.id)
        // The temporary runtime directory was swept; runtime/ is never state.
        let runtimeDir = try layout.runtimeVMDirectory(runtimeID: "rt-cycle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtimeDir.path))
        let shutdown = try await store.deltas.lastShutdown(environmentID: "env-cycle")
        XCTAssertEqual(shutdown?.clean, true)
        await integrator.releaseSlot(environmentID: "env-cycle", runtimeID: "rt-cycle")
        let releasedSlot = await store.pool.slot(environmentID: "env-cycle")
        XCTAssertNil(releasedSlot)
    }

    // MARK: - guest registry start path (scripted substrate)

    /// The guest registry's start path drives the Runtime v2 substrate in
    /// the exact order the Workspace/IDE run relies on: pool admission,
    /// working-disk preparation, the environment data directory replacing
    /// the layer share, and on stop a verified delta capture plus slot
    /// release. No VM and no real disk are needed at this seam.
    func testRegistryStartDrivesRuntimeV2OwnershipCycle() async throws {
        let expanded = root.appendingPathComponent("expanded", isDirectory: true)
        let image = try makeQualifiedImage(id: "test-image", directory: expanded)
        let integrator = ScriptedV2Integrator(expandedRoot: expanded, root: root)
        let ledger = FakeSessionLedger()
        let factory = FakeSessionFactory(ledger: ledger) { _, token in
            token.hasPrefix("hello-") ? runtimeV2CapsReply(token) : runtimeV2OKReply(token)
        }
        let registry = TinyEMULinuxGuestRegistry(
            environments: FakeEnvironmentProvider(descriptors: [
                "env-v2": LinuxGuestEnvironmentDescriptor(id: "env-v2", ownerID: "owner", imageID: image.id)
            ]),
            images: FakeImageResolver(images: [image.id: image]),
            limits: .standard,
            factory: factory,
            runtimeV2: integrator
        )

        let started = try await registry.start(environmentID: "env-v2", taskID: "task-1")
        XCTAssertTrue(started)
        let supports = await registry.supports(environmentID: "env-v2")
        XCTAssertTrue(supports)
        let events = await integrator.events
        XCTAssertEqual(events, ["acquire:env-v2", "disk:env-v2", "data:env-v2"])
        // The 9P environment share points at the v2 data directory, never at
        // the legacy layer.
        let runtimeImage = ledger.image(for: "env-v2")
        XCTAssertNotNil(runtimeImage)

        await registry.stop(environmentID: "env-v2")
        let stopEvents = await integrator.events
        XCTAssertEqual(stopEvents, ["acquire:env-v2", "disk:env-v2", "data:env-v2", "stop:env-v2:true", "release:env-v2"])
    }

    // MARK: - P0: startup salvage failure is durably non-restartable

    /// Startup salvage failure + a registry fault at the repairRequired
    /// write: the quarantine move preserves the bytes, the durable non-
    /// expiring repair hold is placed anyway, the swallowed state write is
    /// reported truthfully in the notes, and a REPEATED launch on a new store
    /// identity still refuses any fresh start until repair is acknowledged.
    /// After acknowledgement the ordinary boot path works again.
    func testStartupSalvageFailurePlacesDurableHoldAndSurvivesRegistryFault() async throws {
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        let faulting = RuntimeV2Store(
            layout: layout,
            seams: .init(markRepairRequired: { _, _ in
                throw RuntimeV2Error.registryCorrupt("injected registry fault")
            })
        )
        _ = try await faulting.prepareAndRecover(build: "test")
        _ = try await faulting.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)
        try await registerEnvironment(in: faulting, id: "env-salvage-fault", baseImageID: image.id)

        // Leftover working disk whose ownership record lacks the boot base
        // digest: the verified salvage path refuses it (real fault, no seam).
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-salvage-fault")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8192).write(to: directory.appendingPathComponent("disk.img"))
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: "rt-salvage-fault", environmentID: "env-salvage-fault",
                baseImageID: image.id, createdAt: Date()
            ),
            to: directory
        )

        let report = try await faulting.prepareAndRecover(build: "test")
        XCTAssertTrue(report.quarantinedRuntimeDirs.contains("rt-salvage-fault"))
        XCTAssertFalse(report.preservedRuntimeDirs.contains("rt-salvage-fault"))
        // The registry fault was reported, never swallowed into a restartable
        // environment.
        XCTAssertTrue(
            report.notes.contains { $0.contains("env-salvage-fault") && $0.contains("could not be persisted") },
            "expected a truthful fault note, got \(report.notes)"
        )
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("runtime-vm-rt-salvage-fault") }
        XCTAssertEqual(quarantined.count, 1)
        let preservedDisk = layout.quarantineDirectory
            .appendingPathComponent(quarantined[0], isDirectory: true)
            .appendingPathComponent("disk.img")
        XCTAssertEqual(try Data(contentsOf: preservedDisk), Data(repeating: 0x5A, count: 8192))
        // The durable hold exists even though the registry write faulted.
        let hold = await faulting.repairHolds.hold(environmentID: "env-salvage-fault")
        XCTAssertNotNil(hold)
        let stateAfterFault = try await faulting.registry.environment(id: "env-salvage-fault")?.state
        XCTAssertNotEqual(stateAfterFault, "repairRequired")

        // REPEATED LAUNCH on a brand-new store identity (production seams):
        // the hold is non-expiring, so the environment stays non-restartable
        // and the preserved bytes stay untouched.
        let relaunched = RuntimeV2Store(layout: layout)
        let secondReport = try await relaunched.prepareAndRecover(build: "test")
        let holdAfterRelaunch = await relaunched.repairHolds.hold(environmentID: "env-salvage-fault")
        XCTAssertNotNil(holdAfterRelaunch)
        let stateAfterRelaunch = try await relaunched.registry.environment(id: "env-salvage-fault")?.state
        XCTAssertEqual(stateAfterRelaunch, "repairRequired")
        XCTAssertEqual(try Data(contentsOf: preservedDisk), Data(repeating: 0x5A, count: 8192))

        let integrator = RuntimeV2GuestIntegrator(store: relaunched, legacyImagesRoot: legacyRoot, build: "test")
        do {
            _ = try await integrator.prepareWorkingDisk(
                environmentID: "env-salvage-fault", runtimeID: "rt-salvage-fault-2", imageID: image.id,
                legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
            )
            XCTFail("a fresh VM must never boot over preserved salvage bytes")
        } catch RuntimeV2Error.environmentRepairRequired(let environmentID, _) {
            XCTAssertEqual(environmentID, "env-salvage-fault")
        }
        let freshDir = try layout.runtimeVMDirectory(runtimeID: "rt-salvage-fault-2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: freshDir.path))
        let leaseAfterRefusal = try await relaunched.leases.holder(environmentID: "env-salvage-fault")
        XCTAssertNil(leaseAfterRefusal)
        XCTAssertEqual(try Data(contentsOf: preservedDisk), Data(repeating: 0x5A, count: 8192))
        _ = secondReport

        // Explicit resolution. The preserved bytes carry NO boot-base digest,
        // so a verified restore can never prove them: restoreRepair refuses
        // and keeps the exclusion. The deliberate, named discard resolves the
        // repair (bytes moved to the discarded-evidence area, never deleted),
        // and the ordinary boot path works again afterwards.
        do {
            _ = try await relaunched.restoreRepair(environmentID: "env-salvage-fault")
            XCTFail("unprovable bytes must never be silently restored")
        } catch RuntimeV2Error.workingDirectoryProvenanceUnavailable {
            // expected: restore refuses rather than guess
        }
        let holdAfterFailedRestore = await relaunched.repairHolds.hold(environmentID: "env-salvage-fault")
        XCTAssertNotNil(holdAfterFailedRestore)
        XCTAssertEqual(try Data(contentsOf: preservedDisk), Data(repeating: 0x5A, count: 8192))

        let resolution = try await relaunched.discardRepair(
            environmentID: "env-salvage-fault", reason: "the preserved bytes cannot be attributed to any boot base; a human discarded them explicitly"
        )
        XCTAssertEqual(resolution.resolution, "discarded")
        XCTAssertTrue(resolution.preservedPath?.contains("recovery/quarantine/") ?? false)
        let holdAfterDiscard = await relaunched.repairHolds.hold(environmentID: "env-salvage-fault")
        XCTAssertNil(holdAfterDiscard)
        let stateAfterDiscard = try await relaunched.registry.environment(id: "env-salvage-fault")?.state
        XCTAssertEqual(stateAfterDiscard, "stopped")
        // The discarded bytes were preserved as evidence, not deleted.
        let discarded = try FileManager.default.contentsOfDirectory(atPath: layout.recoveryMigrationsDirectory.appendingPathComponent("discarded", isDirectory: true).path)
        XCTAssertEqual(discarded.filter { $0.hasPrefix("runtime-vm-rt-salvage-fault") }.count, 1)

        let admission = try await integrator.acquireSlot(
            environmentID: "env-salvage-fault", runtimeID: "rt-salvage-fault-3", requestedMB: 512
        )
        XCTAssertGreaterThan(admission.ramMB, 0)
        let work = try await integrator.prepareWorkingDisk(
            environmentID: "env-salvage-fault", runtimeID: "rt-salvage-fault-3", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.diskURL.path))
        await integrator.completeStop(
            environmentID: "env-salvage-fault", runtimeID: "rt-salvage-fault-3", imageID: image.id, clean: true
        )
        let delta = try await relaunched.deltas.loadDelta(environmentID: "env-salvage-fault")
        XCTAssertNotNil(delta)
    }

    /// When even the quarantine MOVE fails (real fault: a foreign file blocks
    /// the quarantine directory), the bytes stay exactly where they are, the
    /// report says preserved — not quarantined — and the durable hold still
    /// excludes every future start, idempotently across launches.
    func testStartupSalvageFailureWithQuarantineMoveFaultPreservesBytesInPlace() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-move-fault", baseImageID: "img")
        // A read-only quarantine directory: every move into it fails with a
        // real permission fault, no seam needed.
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: layout.quarantineDirectory.path)

        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-move-fault")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0xB7, count: 8192).write(to: directory.appendingPathComponent("disk.img"))
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: "rt-move-fault", environmentID: "env-move-fault",
                baseImageID: "img", createdAt: Date()
            ),
            to: directory
        )

        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(report.preservedRuntimeDirs.contains("rt-move-fault"))
        XCTAssertFalse(report.quarantinedRuntimeDirs.contains("rt-move-fault"))
        XCTAssertTrue(
            report.notes.contains { $0.contains("rt-move-fault") && $0.contains("could not be quarantined") },
            "expected a truthful quarantine-fault note, got \(report.notes)"
        )
        // The bytes are exactly where the guest left them.
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("disk.img")),
            Data(repeating: 0xB7, count: 8192)
        )
        let holdAfterRecovery = await relaunched.repairHolds.hold(environmentID: "env-move-fault")
        XCTAssertNotNil(holdAfterRecovery)
        let moveFaultState = try await relaunched.registry.environment(id: "env-move-fault")?.state
        XCTAssertEqual(moveFaultState, "repairRequired")

        // Repeated launch: idempotent preservation, still non-restartable.
        let third = RuntimeV2Store(layout: layout)
        let thirdReport = try await third.prepareAndRecover(build: "test")
        XCTAssertTrue(thirdReport.preservedRuntimeDirs.contains("rt-move-fault"))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("disk.img")),
            Data(repeating: 0xB7, count: 8192)
        )
        let holdAfterThird = await third.repairHolds.hold(environmentID: "env-move-fault")
        XCTAssertNotNil(holdAfterThird)

        let integrator = RuntimeV2GuestIntegrator(store: third, build: "test")
        do {
            _ = try await integrator.prepareWorkingDisk(
                environmentID: "env-move-fault", runtimeID: "rt-move-fault-2", imageID: "img",
                legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
            )
            XCTFail("a fresh VM must never boot while the hold exists")
        } catch RuntimeV2Error.environmentRepairRequired {
            // expected
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: (try? layout.runtimeVMDirectory(runtimeID: "rt-move-fault-2"))?.path ?? "")
        )
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("disk.img")),
            Data(repeating: 0xB7, count: 8192)
        )
    }

    // MARK: - P0: unreadable ownership record + live lease preserves the disk

    /// A damaged runtime.json NEVER grants permission to move a potentially
    /// active VM disk: ownership is attributed by directory runtimeID through
    /// the lease sidecar, a live/unexpired lease preserves every byte in
    /// place, and a second/reentrant recovery round does the same.
    func testRecoveryPreservesDiskWithUnreadableMetaUnderLiveLease() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-nometa", baseImageID: "img")
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-nometa")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0xC3, count: 8192).write(to: directory.appendingPathComponent("disk.img"))
        // Damaged ownership record.
        try Data("not json".utf8).write(to: directory.appendingPathComponent("runtime.json"))
        try writeLease(
            environmentID: "env-nometa", runtimeID: "rt-nometa", incarnation: "other-incarnation",
            pid: Int64(ProcessInfo.processInfo.processIdentifier), renewedAt: Date(), ttlSeconds: 30
        )

        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(report.preservedRuntimeDirs.contains("rt-nometa"))
        XCTAssertFalse(report.quarantinedRuntimeDirs.contains("rt-nometa"))
        XCTAssertTrue(
            report.notes.contains { $0.contains("rt-nometa") && $0.contains("lease") },
            "expected a lease-attribution preservation note, got \(report.notes)"
        )
        // Exact path, exact bytes, nothing captured or invented.
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("disk.img")),
            Data(repeating: 0xC3, count: 8192)
        )
        let nometaDelta = try await relaunched.deltas.loadDelta(environmentID: "env-nometa")
        XCTAssertNil(nometaDelta)
        // The unresolved live lease marks the environment interrupted (the
        // pre-existing unreclaimable-lease behavior); the disk itself is
        // untouched and no repair state is invented for a live owner.
        let nometaState = try await relaunched.registry.environment(id: "env-nometa")?.state
        XCTAssertEqual(nometaState, "interrupted")

        // Second + reentrant recovery rounds (a second store identity AND a
        // repeat pass on the same one) preserve it identically.
        let second = RuntimeV2Store(layout: layout)
        let secondReport = try await second.prepareAndRecover(build: "test")
        XCTAssertTrue(secondReport.preservedRuntimeDirs.contains("rt-nometa"))
        let reentrantReport = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(reentrantReport.preservedRuntimeDirs.contains("rt-nometa"))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("disk.img")),
            Data(repeating: 0xC3, count: 8192)
        )
        // No quarantine move happened in any round.
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("runtime-vm-rt-nometa") }
        XCTAssertTrue(quarantined.isEmpty)
    }

    /// A MISSING runtime.json with a dead pid is still inside the lease TTL:
    /// the owning thread may hold an open disk handle, so the disk is
    /// preserved byte-for-byte — never moved, captured or deleted.
    func testRecoveryPreservesDiskWithMissingMetaUnderUnexpiredDeadPidLease() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-nometa-ttl", baseImageID: "img")
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-nometa-ttl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0xD4, count: 8192).write(to: directory.appendingPathComponent("disk.img"))
        // No runtime.json at all; dead pid but the TTL has not expired.
        try writeLease(
            environmentID: "env-nometa-ttl", runtimeID: "rt-nometa-ttl", incarnation: "other-incarnation",
            pid: 4_000_000, renewedAt: Date(), ttlSeconds: 30
        )

        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(report.preservedRuntimeDirs.contains("rt-nometa-ttl"))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("disk.img")),
            Data(repeating: 0xD4, count: 8192)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime.json").path) == false
        )
    }

    /// A proven-stale lease attributes the runtime to a KNOWN environment but
    /// the unreadable runtime.json makes the disk unprovable against any boot
    /// base: salvage is impossible, so the same durable repair-hold protocol
    /// as a failed salvage applies — quarantine the bytes, exclude the
    /// environment until repair is acknowledged, say so truthfully.
    func testRecoveryQuarantinesUnattributableDiskWithProvenStaleLease() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-nometa-stale", baseImageID: "img")
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-nometa-stale")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0xE5, count: 8192).write(to: directory.appendingPathComponent("disk.img"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("runtime.json"))
        try writeLease(
            environmentID: "env-nometa-stale", runtimeID: "rt-nometa-stale", incarnation: "dead-incarnation",
            pid: 4_000_000, renewedAt: Date(timeIntervalSinceNow: -600), ttlSeconds: 30
        )

        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(report.quarantinedRuntimeDirs.contains("rt-nometa-stale"))
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("runtime-vm-rt-nometa-stale") }
        XCTAssertEqual(quarantined.count, 1)
        let preservedDisk = layout.quarantineDirectory
            .appendingPathComponent(quarantined[0], isDirectory: true)
            .appendingPathComponent("disk.img")
        XCTAssertEqual(try Data(contentsOf: preservedDisk), Data(repeating: 0xE5, count: 8192))
        let staleHold = await relaunched.repairHolds.hold(environmentID: "env-nometa-stale")
        XCTAssertNotNil(staleHold)
        let staleState = try await relaunched.registry.environment(id: "env-nometa-stale")?.state
        XCTAssertEqual(staleState, "repairRequired")

        // Resolution: the disk has an UNREADABLE ownership record, so its
        // bytes can never be proven against a boot base — a verified restore
        // refuses (and keeps the exclusion) rather than guess. The
        // provenance-gated discardRepair refuses too: unverifiable bytes are
        // NEVER implicitly authorized by a hold sidecar. Only the separate,
        // explicitly verified cleanup `discardUnverifiableRepairEvidence`
        // resolves them: the bytes land in the discarded-evidence area (never
        // deleted) and the hold sidecar is archived as evidence.
        do {
            _ = try await relaunched.restoreRepair(environmentID: "env-nometa-stale")
            XCTFail("an unreadable ownership record must never be silently restored")
        } catch RuntimeV2Error.workingDirectoryProvenanceUnavailable {
            // expected
        }
        let holdAfterFailedRestore2 = await relaunched.repairHolds.hold(environmentID: "env-nometa-stale")
        XCTAssertNotNil(holdAfterFailedRestore2)
        do {
            _ = try await relaunched.discardRepair(
                environmentID: "env-nometa-stale", reason: "must refuse: no matching provenance"
            )
            XCTFail("discardRepair must refuse unproven bytes, never move them on a hold's word alone")
        } catch RuntimeV2Error.workingDirectoryProvenanceUnavailable {
            // expected
        }
        // Bytes unmoved while the refusals stand.
        let quarantineEntries = try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("runtime-vm-rt-nometa-stale") }
        XCTAssertEqual(quarantineEntries.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: layout.quarantineDirectory.appendingPathComponent(quarantineEntries[0], isDirectory: true).appendingPathComponent("disk.img")),
            Data(repeating: 0xE5, count: 8192)
        )
        let resolution = try await relaunched.discardUnverifiableRepairEvidence(
            environmentID: "env-nometa-stale", reason: "unattributable bytes; explicit verified human cleanup"
        )
        XCTAssertEqual(resolution.resolution, "discarded")
        let holdAfterResolution = await relaunched.repairHolds.hold(environmentID: "env-nometa-stale")
        XCTAssertNil(holdAfterResolution)
        let stateAfterResolution = try await relaunched.registry.environment(id: "env-nometa-stale")?.state
        XCTAssertEqual(stateAfterResolution, "stopped")
        let discarded = try FileManager.default.contentsOfDirectory(
            atPath: layout.recoveryMigrationsDirectory.appendingPathComponent("discarded", isDirectory: true).path
        ).filter { $0.hasPrefix("runtime-vm-rt-nometa-stale") }
        XCTAssertEqual(discarded.count, 1)
        // The acknowledged sidecar is archived as evidence, never deleted.
        let archived = try FileManager.default.contentsOfDirectory(
            atPath: layout.recoveryMigrationsDirectory.appendingPathComponent("repair-holds", isDirectory: true).path
        ).filter { $0.hasPrefix("repair-hold-env-nometa-stale") }
        XCTAssertEqual(archived.count, 1)
    }

    // MARK: - repair holds never block a normally clean environment

    /// A clean start/stop cycle never places a repair hold: a relaunch
    /// salvages nothing and blocks nothing, and every repair-resolution entry
    /// point refuses cleanly (never a silent no-op a UI could misread as a
    /// repair) while leaving every state byte untouched.
    func testCleanStartStopLeavesNoRepairHoldAndResolutionIsUnavailable() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)

        let integrator = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: legacyRoot, build: "test")
        _ = try await integrator.acquireSlot(
            environmentID: "env-clean", runtimeID: "rt-clean", requestedMB: 512
        )
        let work = try await integrator.prepareWorkingDisk(
            environmentID: "env-clean", runtimeID: "rt-clean", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        let handle = try FileHandle(forUpdating: work.diskURL)
        try handle.seek(toOffset: 2 << 20)
        try handle.write(contentsOf: Data(repeating: 0xEF, count: 4096))
        try handle.close()
        await integrator.completeStop(
            environmentID: "env-clean", runtimeID: "rt-clean", imageID: image.id, clean: true
        )
        let delta = try await store.deltas.loadDelta(environmentID: "env-clean")
        XCTAssertNotNil(delta)
        let cleanLease = try await store.leases.holder(environmentID: "env-clean")
        XCTAssertNil(cleanLease)

        // No repair hold was ever placed; a relaunch salvages nothing and
        // blocks nothing.
        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(report.preservedRuntimeDirs.isEmpty)
        XCTAssertTrue(report.quarantinedRuntimeDirs.isEmpty)
        XCTAssertTrue(report.repairReapplied.isEmpty)
        let cleanHold = await relaunched.repairHolds.hold(environmentID: "env-clean")
        XCTAssertNil(cleanHold)

        // Inspection never mutates, and neither resolution path is available:
        // both throw `repairResolutionUnavailable` and leave the environment
        // exactly as it was.
        let recoverable = await relaunched.verifyRecoverable(environmentID: "env-clean")
        XCTAssertEqual(recoverable, .nothingToRecover)
        do {
            _ = try await relaunched.restoreRepair(environmentID: "env-clean")
            XCTFail("restore without an exclusion must throw, never silently succeed")
        } catch RuntimeV2Error.repairResolutionUnavailable {
            // expected
        }
        do {
            _ = try await relaunched.discardRepair(environmentID: "env-clean", reason: "test")
            XCTFail("discard without an exclusion must throw, never silently succeed")
        } catch RuntimeV2Error.repairResolutionUnavailable {
            // expected
        }
        let state = try await relaunched.registry.environment(id: "env-clean")?.state
        XCTAssertEqual(state, "active")
        let archive = layout.recoveryMigrationsDirectory.appendingPathComponent("repair-holds", isDirectory: true)
        let archiveEntries = FileManager.default.fileExists(atPath: archive.path)
            ? try FileManager.default.contentsOfDirectory(atPath: archive.path)
            : []
        XCTAssertTrue(archiveEntries.isEmpty)
    }

    // MARK: - C6: corrupt marker sidecar fails closed forever (P0 review #1)

    /// A corrupt repair-hold marker is NEVER moved away: every read — across
    /// arbitrary repetitions and brand-new store instances — re-detects the
    /// unreadable file and answers a synthesized hold, and no writable disk is
    /// needed to retain the exclusion. Combined with preserved quarantine
    /// bytes, a dead expired lease and SUSTAINED marker+registry write
    /// faults, no launch can ever make the environment reclaimable or
    /// bootable, and the preserved bytes never change.
    func testCorruptRepairHoldSidecarFailsClosedAcrossRepeatedReadsAndLaunches() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-corrupt", baseImageID: "img")
        // Preserved bytes naming the env (durable physical evidence).
        let quarantine = layout.quarantineDirectory
            .appendingPathComponent("runtime-vm-rt-corrupt-1", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        try Data(repeating: 0xA1, count: 8192).write(to: quarantine.appendingPathComponent("disk.img"))
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: "rt-corrupt-1", environmentID: "env-corrupt",
                baseImageID: "img", createdAt: Date()
            ),
            to: quarantine
        )
        // The corrupt marker itself.
        let holdURL = try layout.environmentRepairHoldURL(environmentID: "env-corrupt")
        try FileManager.default.createDirectory(at: holdURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: holdURL)
        // A dead pid long past its TTL: reclaimable by TTL rules alone.
        try writeLease(
            environmentID: "env-corrupt", runtimeID: "rt-corrupt-1", incarnation: "dead-incarnation",
            pid: 4_000_000, renewedAt: Date(timeIntervalSinceNow: -600), ttlSeconds: 30
        )

        // Repeated reads on independent recreated stores: every single one
        // fails closed, and the corrupt marker is never moved into quarantine
        // (the old defect moved it once, and the second read saw nothing).
        for iteration in 0..<3 {
            let fresh = RuntimeV2RepairHoldStore(layout: layout)
            let hold = await fresh.hold(environmentID: "env-corrupt")
            XCTAssertNotNil(hold, "read \(iteration) must fail closed")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: holdURL.path))
        let movedMarkers = try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("repair-hold-env-corrupt") }
        XCTAssertTrue(movedMarkers.isEmpty, "the corrupt marker must stay in place, never be moved away")

        // Sustained faults at BOTH durable re-derivation writes (the marker
        // refresh AND the registry state): every launch keeps the exclusion,
        // refuses to reclaim the stale lease, reports the failures
        // truthfully, and never materializes a fresh disk or lease.
        let faulting = RuntimeV2Store(
            layout: layout,
            seams: .init(
                markRepairRequired: { _, _ in
                    throw RuntimeV2Error.registryCorrupt("sustained registry fault")
                },
                placeRepairHold: { _, _, _, _ in
                    throw RuntimeV2Error.insufficientSpace(required: 4096, available: 0)
                }
            )
        )
        for launch in 0..<2 {
            let report = try await faulting.prepareAndRecover(build: "test")
            let leaseURL = try layout.environmentLeaseURL(environmentID: "env-corrupt")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: leaseURL.path),
                "launch \(launch): the stale lease must never be reclaimed while the evidence exists"
            )
            XCTAssertTrue(
                report.unreclaimableLeases.contains("env-corrupt"),
                "launch \(launch): the excluded environment must stay unresolved, got \(report.unreclaimableLeases)"
            )
            XCTAssertTrue(
                report.notes.contains { $0.contains("env-corrupt") && $0.contains("could not be persisted") },
                "launch \(launch): the sustained write failures must stay visible, got \(report.notes)"
            )
            let vmEntries = try FileManager.default.contentsOfDirectory(atPath: layout.runtimeVMDirectory.path)
            XCTAssertTrue(vmEntries.isEmpty, "launch \(launch): no fresh working disk may appear")
            XCTAssertEqual(
                try Data(contentsOf: quarantine.appendingPathComponent("disk.img")),
                Data(repeating: 0xA1, count: 8192),
                "launch \(launch): the preserved bytes must never change"
            )
        }

        // A direct acquire consults the same barrier BEFORE any lease logic:
        // refused, and the refused acquire never touches the stale sidecar.
        do {
            _ = try await faulting.leases.acquire(environmentID: "env-corrupt", runtimeID: "rt-corrupt-2")
            XCTFail("no boot is possible while the corrupt marker and the preserved bytes exist")
        } catch RuntimeV2Error.environmentRepairRequired(let environmentID, _) {
            XCTAssertEqual(environmentID, "env-corrupt")
        }
        let leaseURL = try layout.environmentLeaseURL(environmentID: "env-corrupt")
        let sidecarData = try Data(contentsOf: leaseURL)
        let sidecarLease = try RuntimeV2LeaseStore.decoder.decode(RuntimeV2LeaseStore.Lease.self, from: sidecarData)
        XCTAssertEqual(sidecarLease.runtimeID, "rt-corrupt-1")
        XCTAssertEqual(sidecarLease.incarnation, "dead-incarnation")
    }

    /// A corrupt marker with NO preserved bytes anywhere still excludes on
    /// every repeated read and on a fresh boot attempt — and survives until
    /// an explicit resolution, never by being read.
    func testCorruptRepairHoldSidecarWithoutPreservedBytesStillExcludes() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-corrupt-empty", baseImageID: "img")
        let holdURL = try layout.environmentRepairHoldURL(environmentID: "env-corrupt-empty")
        try FileManager.default.createDirectory(at: holdURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not a hold".utf8).write(to: holdURL)

        for _ in 0..<3 {
            let fresh = RuntimeV2RepairHoldStore(layout: layout)
            let hold = await fresh.hold(environmentID: "env-corrupt-empty")
            XCTAssertNotNil(hold)
            // The marker file is still exactly where it was.
            XCTAssertTrue(FileManager.default.fileExists(atPath: holdURL.path))
        }
        // Inspection never lifts it; only an explicit resolution can.
        let recoverable = await store.verifyRecoverable(environmentID: "env-corrupt-empty")
        XCTAssertEqual(recoverable, .nothingToRecover)
        _ = try await store.discardRepair(
            environmentID: "env-corrupt-empty", reason: "marker unreadable and nothing to recover; explicit cleanup"
        )
        let fresh = RuntimeV2RepairHoldStore(layout: layout)
        let clearedHold = await fresh.hold(environmentID: "env-corrupt-empty")
        XCTAssertNil(clearedHold)
    }

    // MARK: - C6: unknown-owner directory is never moved (P0 review #4)

    /// Damaged runtime.json + NO ownership trace anywhere (no lease sidecar,
    /// no registry row, no archived lease): the absence of a trace is not
    /// proof the owner stopped — the directory is preserved byte-for-byte IN
    /// PLACE, with a simulated live disk handle held open, across repeated
    /// launches. It blocks nothing globally (a neighbor environment boots
    /// normally), and the explicit verified cleanup `archiveUnknownRuntimeDirectory`
    /// is the only way it ever leaves runtime/vm.
    func testUnknownOwnerDirectoryPreservedInPlaceUntilExplicitVerifiedCleanup() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-ghost-neighbor", baseImageID: "img")
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-ghost")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0xB2, count: 8192).write(to: directory.appendingPathComponent("disk.img"))
        try Data("not json".utf8).write(to: directory.appendingPathComponent("runtime.json"))
        // Simulated LIVE handle: the disk stays open across recovery.
        let handle = try FileHandle(forUpdating: directory.appendingPathComponent("disk.img"))

        let relaunched = RuntimeV2Store(layout: layout)
        let report = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(report.preservedRuntimeDirs.contains("rt-ghost"))
        XCTAssertFalse(report.quarantinedRuntimeDirs.contains("rt-ghost"))
        XCTAssertTrue(
            report.notes.contains { $0.contains("rt-ghost") && $0.contains("no ownership trace") },
            "expected a truthful no-trace preservation note, got \(report.notes)"
        )
        // Byte-for-byte in place: no move, no capture, no mount, no lease.
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("disk.img")),
            Data(repeating: 0xB2, count: 8192)
        )
        let moved = try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("runtime-vm-rt-ghost") }
        XCTAssertTrue(moved.isEmpty, "a potentially live disk must never be moved without proof")
        let ghostLease = try await relaunched.leases.lease(forRuntimeID: "rt-ghost")
        XCTAssertNil(ghostLease)

        // Repeated launches: idempotent preservation, no latching state.
        let third = RuntimeV2Store(layout: layout)
        let thirdReport = try await third.prepareAndRecover(build: "test")
        XCTAssertTrue(thirdReport.preservedRuntimeDirs.contains("rt-ghost"))
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("disk.img")),
            Data(repeating: 0xB2, count: 8192)
        )

        // No global blocking: a neighbor environment boots and stops normally
        // while the unknown directory sits preserved.
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await third.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)
        let integrator = RuntimeV2GuestIntegrator(store: third, legacyImagesRoot: legacyRoot, build: "test")
        let neighbor = try await integrator.prepareWorkingDisk(
            environmentID: "env-ghost-neighbor", runtimeID: "rt-neighbor", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbor.diskURL.path))
        await integrator.completeStop(
            environmentID: "env-ghost-neighbor", runtimeID: "rt-neighbor", imageID: image.id, clean: true
        )

        // Explicit verified cleanup is the ONLY exit: it re-proves the
        // directory is still untraceable and moves it into the quarantine
        // evidence area (never deletes).
        try handle.close()
        try await third.archiveUnknownRuntimeDirectory(runtimeID: "rt-ghost")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let archived = try FileManager.default.contentsOfDirectory(atPath: layout.quarantineDirectory.path)
            .filter { $0.hasPrefix("runtime-vm-rt-ghost") }
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: layout.quarantineDirectory.appendingPathComponent(archived[0], isDirectory: true).appendingPathComponent("disk.img")),
            Data(repeating: 0xB2, count: 8192)
        )

        // Afterwards recovery has nothing to preserve; a second cleanup
        // attempt refuses (nothing there).
        let fourth = RuntimeV2Store(layout: layout)
        let fourthReport = try await fourth.prepareAndRecover(build: "test")
        XCTAssertFalse(fourthReport.preservedRuntimeDirs.contains("rt-ghost"))
        do {
            try await fourth.archiveUnknownRuntimeDirectory(runtimeID: "rt-ghost")
            XCTFail("a vanished directory must refuse cleanup, never silently succeed")
        } catch RuntimeV2Error.repairResolutionUnavailable {
            // expected
        }
    }

    /// Cleanup refuses the moment any ownership trace exists: a directory
    /// with a readable ownership record is owned state and must go through
    /// the repair flow, never the unknown-directory cleanup.
    func testUnknownDirectoryCleanupRefusesOwnedState() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-owned", baseImageID: "img")
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-owned")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0xC5, count: 8192).write(to: directory.appendingPathComponent("disk.img"))
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: "rt-owned", environmentID: "env-owned",
                baseImageID: "img", createdAt: Date()
            ),
            to: directory
        )
        do {
            try await store.archiveUnknownRuntimeDirectory(runtimeID: "rt-owned")
            XCTFail("owned state must never be cleaned up as unknown")
        } catch RuntimeV2Error.repairResolutionUnavailable {
            // expected
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - C6: verified restore returns preserved bytes to the delta (P1 review #3)

    /// Manufacture the exact durable state a failed capture leaves (the
    /// production preserveAfterFailedCapture outcome), then resolve it with
    /// the VERIFIED RESTORE: provenance + content checks, capture through the
    /// verified delta path, durable state commit, and only then the lift.
    /// The restored writes are visible on the next boot and survive further
    /// reboots — a mere acknowledgement could never promise that.
    func testRepairRestoreCapturesPreservedBytesAndSurvivesReboot() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)
        try await registerEnvironment(id: "env-restore", baseImageID: image.id)
        let integrator = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: legacyRoot, build: "test")

        // First session: write A, clean stop → the delta durably holds A.
        _ = try await integrator.acquireSlot(environmentID: "env-restore", runtimeID: "rt-restore-1", requestedMB: 512)
        let first = try await integrator.prepareWorkingDisk(
            environmentID: "env-restore", runtimeID: "rt-restore-1", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        try writeBlock(first.diskURL, offset: 2 << 20, byte: 0x41)
        await integrator.completeStop(
            environmentID: "env-restore", runtimeID: "rt-restore-1", imageID: image.id, clean: true
        )

        // Second session: the delta (A) is applied; write B (the LATEST
        // state). Then the capture fails and the disk is preserved — the
        // delta still holds only A.
        _ = try await integrator.acquireSlot(environmentID: "env-restore", runtimeID: "rt-restore-2", requestedMB: 512)
        let second = try await integrator.prepareWorkingDisk(
            environmentID: "env-restore", runtimeID: "rt-restore-2", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        XCTAssertEqual(try readBlock(second.diskURL, offset: 2 << 20), Data(repeating: 0x41, count: 4096))
        try writeBlock(second.diskURL, offset: 3 << 20, byte: 0x42)
        // Manufacture the production failed-capture state byte-for-byte:
        // quarantine the stopped disk, place the durable hold, mark
        // repairRequired (exactly what preserveAfterFailedCapture persists).
        let secondDirectory = try layout.runtimeVMDirectory(runtimeID: "rt-restore-2")
        let quarantine = layout.quarantineDirectory
            .appendingPathComponent("runtime-vm-rt-restore-2-test", isDirectory: true)
        try FileManager.default.moveItem(at: secondDirectory, to: quarantine)
        try await store.repairHolds.place(
            environmentID: "env-restore", runtimeID: "rt-restore-2",
            reason: "injected failed capture", preservedPath: "recovery/quarantine/\(quarantine.lastPathComponent)"
        )
        try await store.registry.setEnvironmentState(
            id: "env-restore", state: "repairRequired", repairReason: "injected failed capture"
        )
        // Process death + TTL expiry state, precisely what a new incarnation
        // observes.
        try writeLease(
            environmentID: "env-restore", runtimeID: "rt-restore-2", incarnation: "dead-incarnation",
            pid: 4_000_000, renewedAt: Date(timeIntervalSinceNow: -600), ttlSeconds: 30
        )

        // A fresh incarnation: the exclusion survives; the stale lease is not
        // reclaimed; the preserved bytes are untouched.
        let relaunched = RuntimeV2Store(layout: layout)
        let recoveryReport = try await relaunched.prepareAndRecover(build: "test")
        XCTAssertTrue(recoveryReport.unreclaimableLeases.contains("env-restore"))
        let preservedDisk = quarantine.appendingPathComponent("disk.img")
        XCTAssertEqual(try readBlock(preservedDisk, offset: 3 << 20), Data(repeating: 0x42, count: 4096))
        // Merely discovering the backup cannot unlock: inspection changes
        // nothing, and the environment stays excluded.
        let inspection = await relaunched.verifyRecoverable(environmentID: "env-restore")
        guard case .recoverable(let preservedPath) = inspection else {
            XCTFail("the preserved bytes must be discoverable, got \(inspection)")
            return
        }
        XCTAssertEqual(preservedPath, "recovery/quarantine/\(quarantine.lastPathComponent)")
        let statusBeforeRestore = await relaunched.repairHoldStatus(environmentID: "env-restore")
        XCTAssertNotNil(statusBeforeRestore)

        // The verified restore: provenance + content are proven, the bytes
        // are captured into the delta through the verified path, the durable
        // state commits, and only then the exclusion lifts.
        let resolution = try await relaunched.restoreRepair(environmentID: "env-restore")
        XCTAssertEqual(resolution.resolution, "restored")
        XCTAssertEqual(resolution.preservedPath, preservedPath)
        XCTAssertNotNil(resolution.diskDigestSHA512)
        XCTAssertEqual(resolution.restoredGeneration, 2)
        let statusAfterRestore = await relaunched.repairHoldStatus(environmentID: "env-restore")
        XCTAssertNil(statusAfterRestore)
        let stateAfterRestore = try await relaunched.registry.environment(id: "env-restore")?.state
        XCTAssertEqual(stateAfterRestore, "stopped")
        let shutdown = try await relaunched.deltas.lastShutdown(environmentID: "env-restore")
        XCTAssertEqual(shutdown?.clean, true)
        // The resolution is recorded durably: a later recovery pass never
        // re-derives the exclusion from the preserved evidence.
        let afterRestore = RuntimeV2Store(layout: layout)
        let afterReport = try await afterRestore.prepareAndRecover(build: "test")
        XCTAssertTrue(afterReport.repairReapplied.isEmpty)
        let statusNextLaunch = await afterRestore.repairHoldStatus(environmentID: "env-restore")
        XCTAssertNil(statusNextLaunch)

        // The restored writes are visible on the next boot (A AND B), and a
        // further reboot preserves everything: write C, stop, relaunch, read.
        let integrator2 = RuntimeV2GuestIntegrator(store: afterRestore, legacyImagesRoot: legacyRoot, build: "test")
        _ = try await integrator2.acquireSlot(environmentID: "env-restore", runtimeID: "rt-restore-3", requestedMB: 512)
        let third = try await integrator2.prepareWorkingDisk(
            environmentID: "env-restore", runtimeID: "rt-restore-3", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        XCTAssertEqual(try readBlock(third.diskURL, offset: 2 << 20), Data(repeating: 0x41, count: 4096))
        XCTAssertEqual(try readBlock(third.diskURL, offset: 3 << 20), Data(repeating: 0x42, count: 4096))
        // The restored state is now durable: overwrite A with C, stop, and a
        // further reboot must show C AND the restored B.
        try writeBlock(third.diskURL, offset: 2 << 20, byte: 0x43)
        await integrator2.completeStop(
            environmentID: "env-restore", runtimeID: "rt-restore-3", imageID: image.id, clean: true
        )

        let rebooted = RuntimeV2Store(layout: layout)
        _ = try await rebooted.prepareAndRecover(build: "test")
        let integrator3 = RuntimeV2GuestIntegrator(store: rebooted, legacyImagesRoot: legacyRoot, build: "test")
        _ = try await integrator3.acquireSlot(environmentID: "env-restore", runtimeID: "rt-restore-4", requestedMB: 512)
        let fourth = try await integrator3.prepareWorkingDisk(
            environmentID: "env-restore", runtimeID: "rt-restore-4", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        XCTAssertEqual(try readBlock(fourth.diskURL, offset: 2 << 20), Data(repeating: 0x43, count: 4096))
        XCTAssertEqual(try readBlock(fourth.diskURL, offset: 3 << 20), Data(repeating: 0x42, count: 4096))
        await integrator3.completeStop(
            environmentID: "env-restore", runtimeID: "rt-restore-4", imageID: image.id, clean: true
        )
    }

    /// An interrupted restore retains the hold: the provenance base is
    /// missing at restore time, the restore throws, the exclusion AND the
    /// preserved bytes stay fully in place, and a retry after the fault
    /// heals succeeds idempotently.
    func testRepairRestoreInterruptedRetainsHoldAndRetryIsIdempotent() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)
        try await registerEnvironment(id: "env-restore-fault", baseImageID: image.id)
        let integrator = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: legacyRoot, build: "test")
        _ = try await integrator.acquireSlot(environmentID: "env-restore-fault", runtimeID: "rt-rf-1", requestedMB: 512)
        let work = try await integrator.prepareWorkingDisk(
            environmentID: "env-restore-fault", runtimeID: "rt-rf-1", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        try writeBlock(work.diskURL, offset: 2 << 20, byte: 0x51)
        // Manufacture the failed-capture durable state with the latest write
        // ONLY in the preserved bytes.
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-rf-1")
        let quarantine = layout.quarantineDirectory
            .appendingPathComponent("runtime-vm-rt-rf-1-test", isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: quarantine)
        try await store.repairHolds.place(
            environmentID: "env-restore-fault", runtimeID: "rt-rf-1",
            reason: "injected failed capture", preservedPath: "recovery/quarantine/\(quarantine.lastPathComponent)"
        )
        try await store.registry.setEnvironmentState(
            id: "env-restore-fault", state: "repairRequired", repairReason: "injected failed capture"
        )

        // Fault the provenance base away (the v2 image manifest: without it
        // the boot base can never be proven, and the expanded view alone is
        // not provenance): the restore cannot verify anything and must
        // refuse, keeping everything in place.
        let manifestURL = try layout.imageManifestURL(imageID: image.id)
        let manifestBytes = try Data(contentsOf: manifestURL)
        try FileManager.default.removeItem(at: manifestURL)

        do {
            _ = try await store.restoreRepair(environmentID: "env-restore-fault")
            XCTFail("a restore without its provenance base must refuse")
        } catch {
            // any provenance/content failure: expected
        }
        let holdAfterInterrupt = await store.repairHolds.hold(environmentID: "env-restore-fault")
        XCTAssertNotNil(holdAfterInterrupt)
        let stateAfterInterrupt = try await store.registry.environment(id: "env-restore-fault")?.state
        XCTAssertEqual(stateAfterInterrupt, "repairRequired")
        XCTAssertEqual(
            try readBlock(quarantine.appendingPathComponent("disk.img"), offset: 2 << 20),
            Data(repeating: 0x51, count: 4096)
        )
        let deltaAfterInterrupt = try await store.deltas.loadDelta(environmentID: "env-restore-fault")
        XCTAssertNil(deltaAfterInterrupt)

        // Heal the base: the retry succeeds and the latest writes land in the
        // delta, with the hold lifted only after the durable commit.
        try manifestBytes.write(to: manifestURL, options: .atomic)
        let resolution = try await store.restoreRepair(environmentID: "env-restore-fault")
        XCTAssertEqual(resolution.resolution, "restored")
        let holdAfterRetry = await store.repairHolds.hold(environmentID: "env-restore-fault")
        XCTAssertNil(holdAfterRetry)
        let stateAfterRetry = try await store.registry.environment(id: "env-restore-fault")?.state
        XCTAssertEqual(stateAfterRetry, "stopped")
        // The retry's boot happens in a new identity: the original session's
        // lease must first look exactly as a dead process past its TTL.
        try writeLease(
            environmentID: "env-restore-fault", runtimeID: "rt-rf-1", incarnation: "dead-incarnation",
            pid: 4_000_000, renewedAt: Date(timeIntervalSinceNow: -600), ttlSeconds: 30
        )
        let relaunched = RuntimeV2Store(layout: layout)
        _ = try await relaunched.prepareAndRecover(build: "test")
        let integrator2 = RuntimeV2GuestIntegrator(store: relaunched, legacyImagesRoot: legacyRoot, build: "test")
        _ = try await integrator2.acquireSlot(environmentID: "env-restore-fault", runtimeID: "rt-rf-2", requestedMB: 512)
        let rebooted = try await integrator2.prepareWorkingDisk(
            environmentID: "env-restore-fault", runtimeID: "rt-rf-2", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        XCTAssertEqual(try readBlock(rebooted.diskURL, offset: 2 << 20), Data(repeating: 0x51, count: 4096))
        await integrator2.completeStop(
            environmentID: "env-restore-fault", runtimeID: "rt-rf-2", imageID: image.id, clean: true
        )
    }

    /// Crash-safe resolution protocol (review P0): the resolution record
    /// commits ATOMICALLY FIRST and the live marker is retired only after
    /// the commit. A sustained ENOSPC on the resolution archive therefore
    /// leaves the marker fully in place, the state is re-marked
    /// repairRequired (best effort), and the restore can be retried
    /// idempotently once the fault heals.
    func testRepairResolutionRecordFailureKeepsExclusionUntilHealed() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)
        try await registerEnvironment(id: "env-res-fault", baseImageID: image.id)
        let integrator = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: legacyRoot, build: "test")
        _ = try await integrator.acquireSlot(environmentID: "env-res-fault", runtimeID: "rt-res-1", requestedMB: 512)
        let work = try await integrator.prepareWorkingDisk(
            environmentID: "env-res-fault", runtimeID: "rt-res-1", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        try writeBlock(work.diskURL, offset: 2 << 20, byte: 0x61)
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-res-1")
        let quarantine = layout.quarantineDirectory
            .appendingPathComponent("runtime-vm-rt-res-1-test", isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: quarantine)
        try await store.repairHolds.place(
            environmentID: "env-res-fault", runtimeID: "rt-res-1",
            reason: "injected failed capture", preservedPath: "recovery/quarantine/\(quarantine.lastPathComponent)"
        )
        try await store.registry.setEnvironmentState(
            id: "env-res-fault", state: "repairRequired", repairReason: "injected failed capture"
        )

        // Sustained ENOSPC on the resolution archive: everything up to the
        // resolution record commits; the lift itself refuses.
        let archive = layout.recoveryMigrationsDirectory.appendingPathComponent("repair-holds", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: archive.path)
        do {
            _ = try await store.restoreRepair(environmentID: "env-res-fault")
            XCTFail("a resolution that cannot be persisted must not lift the exclusion")
        } catch {
            // expected: the resolution record write failed
        }
        // The crash-safe invariant: the LIVE MARKER IS STILL THERE (the
        // retirement only happens after a committed resolution), the durable
        // state was re-marked repairRequired (best effort, registry healthy),
        // and NO resolution record was committed — so the next launch still
        // answers environmentRepairRequired, not a silent lift.
        let markerURL = try layout.environmentRepairHoldURL(environmentID: "env-res-fault")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerURL.path),
            "a failed resolution must never retire the live marker"
        )
        let liveMarker = await store.repairHolds.markerHold(environmentID: "env-res-fault")
        XCTAssertNotNil(liveMarker)
        let stateAfterFailedResolution = try await store.registry.environment(id: "env-res-fault")?.state
        XCTAssertEqual(stateAfterFailedResolution, "repairRequired")
        let stillExcluded = await store.leases.excludes(environmentID: "env-res-fault")
        XCTAssertTrue(stillExcluded)
        // The capture DID commit: the delta now holds the preserved bytes,
        // and the preserved bytes themselves are untouched.
        let deltaAfterFailure = try await store.deltas.loadDelta(environmentID: "env-res-fault")
        XCTAssertNotNil(deltaAfterFailure)
        let recoverableAfterFailure = await store.verifyRecoverable(environmentID: "env-res-fault")
        XCTAssertEqual(
            recoverableAfterFailure,
            .recoverable(preservedPath: "recovery/quarantine/\(quarantine.lastPathComponent)")
        )
        XCTAssertEqual(
            try readBlock(quarantine.appendingPathComponent("disk.img"), offset: 2 << 20),
            Data(repeating: 0x61, count: 4096)
        )

        // Heal the fault: the retry captures the same bytes again (idempotent)
        // and this time the resolution commits and lifts the exclusion.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: archive.path)
        let resolution = try await store.restoreRepair(environmentID: "env-res-fault")
        XCTAssertEqual(resolution.resolution, "restored")
        let excludedAfterHealing = await store.leases.excludes(environmentID: "env-res-fault")
        XCTAssertFalse(excludedAfterHealing)
        let statusAfterHealed = await store.repairHoldStatus(environmentID: "env-res-fault")
        XCTAssertNil(statusAfterHealed)
        let stateAfterHealed = try await store.registry.environment(id: "env-res-fault")?.state
        XCTAssertEqual(stateAfterHealed, "stopped")
    }

    /// The reviewer's exact fault sequence: the resolution write fails, the
    /// process dies, a brand-new store identity + expired TTL observes the
    /// residue. Because the failed resolution never retired the marker and
    /// never committed a resolution record, the environment must remain
    /// environmentRepairRequired — no reclaim, no fresh boot, bytes intact —
    /// and an explicit resolution is still required.
    func testRepairResolutionFailureSurvivesProcessDeathAndTTLExpiry() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)
        try await registerEnvironment(id: "env-res-death", baseImageID: image.id)
        let integrator = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: legacyRoot, build: "test")
        _ = try await integrator.acquireSlot(environmentID: "env-res-death", runtimeID: "rt-rd-1", requestedMB: 512)
        let work = try await integrator.prepareWorkingDisk(
            environmentID: "env-res-death", runtimeID: "rt-rd-1", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        try writeBlock(work.diskURL, offset: 2 << 20, byte: 0x71)
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-rd-1")
        let quarantine = layout.quarantineDirectory
            .appendingPathComponent("runtime-vm-rt-rd-1-test", isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: quarantine)
        try await store.repairHolds.place(
            environmentID: "env-res-death", runtimeID: "rt-rd-1",
            reason: "injected failed capture", preservedPath: "recovery/quarantine/\(quarantine.lastPathComponent)"
        )
        try await store.registry.setEnvironmentState(
            id: "env-res-death", state: "repairRequired", repairReason: "injected failed capture"
        )
        let preservedDisk = quarantine.appendingPathComponent("disk.img")

        // The resolution write fails (sustained ENOSPC)...
        let archive = layout.recoveryMigrationsDirectory.appendingPathComponent("repair-holds", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: archive.path)
        do {
            _ = try await store.restoreRepair(environmentID: "env-res-death")
            XCTFail("the failed resolution must throw")
        } catch {
            // expected
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: archive.path)

        // ...then PROCESS DEATH + TTL expiry: the residue is exactly what a
        // brand-new incarnation observes (live marker, no resolution record,
        // preserved bytes, dead expired lease).
        try writeLease(
            environmentID: "env-res-death", runtimeID: "rt-rd-1", incarnation: "dead-incarnation",
            pid: 4_000_000, renewedAt: Date(timeIntervalSinceNow: -600), ttlSeconds: 30
        )
        let reborn = RuntimeV2Store(layout: layout)
        let report = try await reborn.prepareAndRecover(build: "test")
        // The marker survived: the environment stays environmentRepairRequired.
        let state = try await reborn.registry.environment(id: "env-res-death")?.state
        XCTAssertEqual(state, "repairRequired", "the environment must remain environmentRepairRequired across the death window")
        let hold = await reborn.repairHolds.hold(environmentID: "env-res-death")
        XCTAssertNotNil(hold, "the live marker must still answer after the failed resolution + process death")
        // No reclaim, no fresh boot, preserved bytes intact.
        XCTAssertTrue(report.unreclaimableLeases.contains("env-res-death"))
        let leaseURL = try layout.environmentLeaseURL(environmentID: "env-res-death")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leaseURL.path))
        let vmEntries = try FileManager.default.contentsOfDirectory(atPath: layout.runtimeVMDirectory.path)
        XCTAssertTrue(vmEntries.isEmpty)
        XCTAssertEqual(try readBlock(preservedDisk, offset: 2 << 20), Data(repeating: 0x71, count: 4096))
        // And a fresh start is refused with environmentRepairRequired.
        let freshIntegrator = RuntimeV2GuestIntegrator(store: reborn, legacyImagesRoot: legacyRoot, build: "test")
        do {
            _ = try await freshIntegrator.prepareWorkingDisk(
                environmentID: "env-res-death", runtimeID: "rt-rd-2", imageID: image.id,
                legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
            )
            XCTFail("no fresh VM may boot while the failed-resolution residue exists")
        } catch RuntimeV2Error.environmentRepairRequired(let held, _) {
            XCTAssertEqual(held, "env-res-death")
        }
    }

    // MARK: - C6: hold preservedPath is untrusted — containment + provenance gates

    /// A hold sidecar is untrusted content: every crafted/relative/traversal
    /// preservedPath is refused by BOTH resolution paths BEFORE anything is
    /// read or moved, the foreign directory stays byte-identical and unmoved,
    /// and the exclusion itself remains until an explicit valid resolution.
    func testRepairResolutionRejectsCraftedPreservedPaths() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-attacker", baseImageID: "img")
        // A foreign directory the crafted paths aim at.
        let foreign = try layout.runtimeVMDirectory(runtimeID: "rt-foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data(repeating: 0xF1, count: 8192).write(to: foreign.appendingPathComponent("disk.img"))

        let craftedPaths = [
            "../vm/rt-foreign",
            "/absolutely/elsewhere/rt-foreign",
            "recovery/quarantine/runtime-vm-ok/../../vm/rt-foreign",
            "recovery/quarantine/other-entry",
            "runtime/vm/",
            "runtime/vm/../vm/rt-foreign",
            "environments/env-attacker",
        ]
        let holdURL = try layout.environmentRepairHoldURL(environmentID: "env-attacker")
        try FileManager.default.createDirectory(at: holdURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        for (index, crafted) in craftedPaths.enumerated() {
            let hold = RuntimeV2RepairHoldStore.Hold(
                environmentID: "env-attacker", runtimeID: "rt-foreign",
                reason: "crafted test hold \(index)", preservedPath: crafted
            )
            try RuntimeV2RepairHoldStore.encoder.encode(hold).write(to: holdURL, options: .atomic)

            // Inspection refuses to name anything recoverable...
            let recoverable = await store.verifyRecoverable(environmentID: "env-attacker")
            XCTAssertEqual(recoverable, .nothingToRecover, "crafted path \(crafted) must never be recoverable")
            // ...and both resolution paths refuse outright.
            do {
                _ = try await store.restoreRepair(environmentID: "env-attacker")
                XCTFail("restore must refuse crafted path \(crafted)")
            } catch {
                // expected: pathEscapesRoot / repairResolutionUnavailable
            }
            do {
                _ = try await store.discardRepair(environmentID: "env-attacker", reason: "test")
                XCTFail("discard must refuse crafted path \(crafted)")
            } catch {
                // expected
            }
            // The foreign directory is byte-identical and unmoved.
            XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "crafted path \(crafted)")
            XCTAssertEqual(
                try Data(contentsOf: foreign.appendingPathComponent("disk.img")),
                Data(repeating: 0xF1, count: 8192),
                "crafted path \(crafted) must never move foreign bytes"
            )
            // Nothing landed in the discarded-evidence area.
            let discardedDir = layout.recoveryMigrationsDirectory.appendingPathComponent("discarded", isDirectory: true)
            let discarded = FileManager.default.fileExists(atPath: discardedDir.path)
                ? try FileManager.default.contentsOfDirectory(atPath: discardedDir.path)
                : []
            XCTAssertTrue(discarded.isEmpty, "crafted path \(crafted) must never move anything")
            // The exclusion itself survives every refusal.
            let holdAfter = await store.repairHolds.hold(environmentID: "env-attacker")
            XCTAssertNotNil(holdAfter, "crafted path \(crafted) must not destroy the exclusion")
        }
        // A final explicit cleanup with no quarantine evidence to account for
        // lifts the exclusion (nothing to move), leaving the foreign dir
        // untouched — the only valid way out.
        _ = try await store.discardUnverifiableRepairEvidence(
            environmentID: "env-attacker", reason: "crafted-path test cleanup"
        )
        let cleared = await store.repairHolds.hold(environmentID: "env-attacker")
        XCTAssertNil(cleared)
        XCTAssertEqual(try Data(contentsOf: foreign.appendingPathComponent("disk.img")), Data(repeating: 0xF1, count: 8192))
    }

    /// A symlinked quarantine entry that resolves OUTSIDE the runtime root is
    /// refused: neither inspection nor restore nor the verified cleanup may
    /// follow it, and the foreign bytes stay byte-identical and unmoved.
    func testRepairResolutionRejectsSymlinkEscape() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-symlink", baseImageID: "img")
        // Foreign bytes OUTSIDE the runtime root.
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("foreign-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 0xF2, count: 8192).write(to: outside.appendingPathComponent("disk.img"))
        // A quarantine entry that is a symlink to the foreign directory.
        let link = layout.quarantineDirectory.appendingPathComponent("runtime-vm-rt-escape-1", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let hold = RuntimeV2RepairHoldStore.Hold(
            environmentID: "env-symlink", runtimeID: "rt-escape-1",
            reason: "symlink escape test", preservedPath: "recovery/quarantine/runtime-vm-rt-escape-1"
        )
        let holdURL = try layout.environmentRepairHoldURL(environmentID: "env-symlink")
        try FileManager.default.createDirectory(at: holdURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try RuntimeV2RepairHoldStore.encoder.encode(hold).write(to: holdURL, options: .atomic)

        let recoverable = await store.verifyRecoverable(environmentID: "env-symlink")
        XCTAssertEqual(recoverable, .nothingToRecover, "a symlink escape must never be recoverable")
        do {
            _ = try await store.restoreRepair(environmentID: "env-symlink")
            XCTFail("restore must refuse the symlink escape")
        } catch RuntimeV2Error.pathEscapesRoot {
            // expected
        }
        do {
            _ = try await store.discardRepair(environmentID: "env-symlink", reason: "test")
            XCTFail("discard must refuse the symlink escape")
        } catch RuntimeV2Error.pathEscapesRoot {
            // expected
        }
        do {
            _ = try await store.discardUnverifiableRepairEvidence(environmentID: "env-symlink", reason: "test")
            XCTFail("even the verified cleanup must refuse the symlink escape")
        } catch RuntimeV2Error.pathEscapesRoot {
            // expected
        }
        // Foreign bytes byte-identical, unmoved; the symlink itself intact.
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("disk.img")), Data(repeating: 0xF2, count: 8192))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("disk.img").path))
        var isSymlink: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path, isDirectory: &isSymlink))
        let resolved = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        XCTAssertEqual(resolved, outside.path)
        // The exclusion remains.
        let liveHold = await store.repairHolds.hold(environmentID: "env-symlink")
        XCTAssertNotNil(liveHold)
    }

    /// A hold naming ANOTHER environment's preserved bytes is refused by
    /// both resolution paths: foreign provenance never authorizes a move, and
    /// the foreign environment's bytes stay byte-identical and unmoved for
    /// THEIR repair flow.
    func testRepairResolutionRefusesForeignEnvironmentProvenance() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-foreign", baseImageID: "img")
        try await registerEnvironment(id: "env-attacker", baseImageID: "img")
        // env-foreign's preserved bytes with valid provenance.
        let entry = layout.quarantineDirectory
            .appendingPathComponent("runtime-vm-rt-foreign-1", isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data(repeating: 0xF3, count: 8192).write(to: entry.appendingPathComponent("disk.img"))
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: "rt-foreign-1", environmentID: "env-foreign",
                baseImageID: "img", createdAt: Date()
            ),
            to: entry
        )
        // env-attacker's hold names env-foreign's bytes.
        let hold = RuntimeV2RepairHoldStore.Hold(
            environmentID: "env-attacker", runtimeID: "rt-foreign-1",
            reason: "foreign provenance test", preservedPath: "recovery/quarantine/runtime-vm-rt-foreign-1"
        )
        let holdURL = try layout.environmentRepairHoldURL(environmentID: "env-attacker")
        try FileManager.default.createDirectory(at: holdURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try RuntimeV2RepairHoldStore.encoder.encode(hold).write(to: holdURL, options: .atomic)

        do {
            _ = try await store.restoreRepair(environmentID: "env-attacker")
            XCTFail("restore must refuse another environment's bytes")
        } catch RuntimeV2Error.workingDirectoryProvenanceUnavailable {
            // expected
        }
        do {
            _ = try await store.discardRepair(environmentID: "env-attacker", reason: "test")
            XCTFail("discard must refuse another environment's bytes")
        } catch RuntimeV2Error.workingDirectoryProvenanceUnavailable {
            // expected
        }
        // The verified cleanup refuses too: the entry belongs to env-foreign.
        do {
            _ = try await store.discardUnverifiableRepairEvidence(environmentID: "env-attacker", reason: "test")
            XCTFail("the cleanup must refuse another environment's evidence")
        } catch RuntimeV2Error.workingDirectoryProvenanceUnavailable {
            // expected
        }
        // Foreign bytes byte-identical and unmoved.
        XCTAssertEqual(
            try Data(contentsOf: entry.appendingPathComponent("disk.img")),
            Data(repeating: 0xF3, count: 8192)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: entry.path))
        // env-foreign's OWN repair flow sees its bytes (physical evidence).
        let foreignStatus = await store.repairHoldStatus(environmentID: "env-foreign")
        XCTAssertNotNil(foreignStatus)
    }

    /// Normal valid recovery still works end to end with the containment
    /// gates in place: a provenanced discard of THIS environment's preserved
    /// bytes moves exactly those bytes and nothing else.
    func testRepairDiscardWithValidProvenanceStillWorks() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-valid", baseImageID: "img")
        let entry = layout.quarantineDirectory
            .appendingPathComponent("runtime-vm-rt-valid-1", isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try Data(repeating: 0xF4, count: 8192).write(to: entry.appendingPathComponent("disk.img"))
        try RuntimeV2WorkingDirectory.writeMeta(
            RuntimeV2WorkingDirectory.Meta(
                runtimeID: "rt-valid-1", environmentID: "env-valid",
                baseImageID: "img", createdAt: Date()
            ),
            to: entry
        )
        try await store.repairHolds.place(
            environmentID: "env-valid", runtimeID: "rt-valid-1",
            reason: "test", preservedPath: "recovery/quarantine/runtime-vm-rt-valid-1"
        )
        try await store.registry.setEnvironmentState(
            id: "env-valid", state: "repairRequired", repairReason: "test"
        )
        // A neighbor directory that must stay untouched.
        let neighbor = layout.quarantineDirectory
            .appendingPathComponent("runtime-vm-rt-neighbor-1", isDirectory: true)
        try FileManager.default.createDirectory(at: neighbor, withIntermediateDirectories: true)
        try Data(repeating: 0xF5, count: 8192).write(to: neighbor.appendingPathComponent("disk.img"))

        let resolution = try await store.discardRepair(
            environmentID: "env-valid", reason: "valid provenance discard"
        )
        XCTAssertEqual(resolution.resolution, "discarded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path))
        let discarded = try FileManager.default.contentsOfDirectory(
            atPath: layout.recoveryMigrationsDirectory.appendingPathComponent("discarded", isDirectory: true).path
        ).filter { $0.hasPrefix("runtime-vm-rt-valid-1") }
        XCTAssertEqual(discarded.count, 1)
        // Neighbor byte-identical and unmoved.
        XCTAssertEqual(
            try Data(contentsOf: neighbor.appendingPathComponent("disk.img")),
            Data(repeating: 0xF5, count: 8192)
        )
        let cleared = await store.repairHolds.hold(environmentID: "env-valid")
        XCTAssertNil(cleared)
        let state = try await store.registry.environment(id: "env-valid")?.state
        XCTAssertEqual(state, "stopped")
    }

    /// The reviewer's exact interleaving: resolver R1 captures hold A, an
    /// independent store places a NEWER hold B over the sidecar, then R1's
    /// stale resolution commits. The commit must leave B fully live (valid B
    /// remains; and a corrupt B is never removed either — the stale resolver
    /// observed nothing it may erase).
    func testStaleResolutionCommitNeverErasesANewerLiveMarker() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-race", baseImageID: "img")

        // R1 captures hold A.
        try await store.repairHolds.place(
            environmentID: "env-race", runtimeID: "rt-a", reason: "cycle A"
        )
        let holdA = await store.repairHolds.markerHold(environmentID: "env-race")
        let holdAID = try XCTUnwrap(holdA?.holdID)

        // An INDEPENDENT store instance places a newer hold B over the sidecar.
        let independent = RuntimeV2RepairHoldStore(layout: layout)
        try await independent.place(
            environmentID: "env-race", runtimeID: "rt-b", reason: "cycle B"
        )
        let holdB = await independent.markerHold(environmentID: "env-race")
        let holdBID = try XCTUnwrap(holdB?.holdID)
        XCTAssertNotEqual(holdAID, holdBID)

        // R1's stale resolution for A commits late.
        try await store.repairHolds.recordResolution(
            environmentID: "env-race", preservedPath: nil, resolution: "discarded",
            resolvedHoldID: holdAID
        )

        // Fresh identities: B is fully live — valid marker answers, excluded.
        let fresh = RuntimeV2RepairHoldStore(layout: layout)
        let liveAfter = await fresh.hold(environmentID: "env-race")
        XCTAssertEqual(liveAfter?.holdID, holdBID, "a stale resolution for A must never erase the newer live marker B")
        let freshStore = RuntimeV2Store(layout: layout)
        let excluded = await freshStore.leases.excludes(environmentID: "env-race")
        XCTAssertTrue(excluded, "B's exclusion must remain in force")

        // Corrupt-B variant: B's bytes are replaced by garbage; a stale
        // resolution that observed NOTHING commits — the corrupt B file must
        // stay exactly where it is (fail closed), never removed.
        let markerURL = try layout.environmentRepairHoldURL(environmentID: "env-race")
        try Data("garbage-not-a-hold".utf8).write(to: markerURL, options: .atomic)
        try await store.repairHolds.recordResolution(
            environmentID: "env-race", preservedPath: nil, resolution: "discarded",
            resolvedHoldID: holdAID
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerURL.path),
            "a stale resolution must never remove a newer corrupt marker it did not observe"
        )
        let corruptAnswers = await fresh.hold(environmentID: "env-race")
        XCTAssertNotNil(corruptAnswers, "the corrupt marker keeps failing closed")
        let excludedCorrupt = await freshStore.leases.excludes(environmentID: "env-race")
        XCTAssertTrue(excludedCorrupt)
    }

    /// C7 P0 — identical-corrupt-bytes ABA. Resolver A observes a corrupt
    /// marker (digest D, inode i, generation g). During A's repair another
    /// writer publishes a NEW marker through a temp file + atomic rename(2)
    /// carrying the EXACT same corrupt bytes (the reviewer's ABA): the digest
    /// is still D, so the old digest-only guard removed B's exclusion. The
    /// replacement is nevertheless a different file instance (new inode) and,
    /// when it went through `place()`, a newer generation — A must leave it
    /// exactly where it is (fail closed). A fresh store stays excluded for B,
    /// while a NEW explicit repair that re-observes the live instance resolves
    /// normally.
    func testIdenticalCorruptBytesABANeverErasesNewerMarker() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-aba", baseImageID: "img")
        let markerURL = try layout.environmentRepairHoldURL(environmentID: "env-aba")
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corruptBytes = Data("identical-corrupt-payload".utf8)
        // The original corrupt marker A later observes, itself published via
        // temp+rename (the crash-shaped write the recovery path produces).
        try atomicRenamePublish(corruptBytes, to: markerURL)

        // Resolver A captures the observation at the start of its flow.
        let resolverA = RuntimeV2RepairHoldStore(layout: layout)
        let observedARaw = await resolverA.corruptMarkerObservation(environmentID: "env-aba")
        let observedA = try XCTUnwrap(observedARaw)
        XCTAssertEqual(observedA.digest, FloeDigest.sha512Hex(corruptBytes))

        // --- Interleaving: another writer temp+renames IDENTICAL corrupt
        // bytes over the directory entry (new inode, same SHA-512).
        let identityBefore = observedA.fileIdentity
        try atomicRenamePublish(corruptBytes, to: markerURL)
        let replacementStore = RuntimeV2RepairHoldStore(layout: layout)
        let identityAfterRaw = await replacementStore.corruptMarkerObservation(environmentID: "env-aba")
        let identityAfter = try XCTUnwrap(identityAfterRaw?.fileIdentity)
        XCTAssertNotEqual(identityBefore.inode, identityAfter.inode, "the rename must replace the file instance")
        XCTAssertEqual(
            try FloeDigest.sha512Hex(Data(contentsOf: markerURL)), observedA.digest,
            "the ABA premise: byte identity still matches after the rename"
        )

        // NEGATIVE CONTROL for the old digest-only predicate: it would have
        // authorized removal of the newer B file.
        let oldDigestOnlyPredicate = (try? FloeDigest.sha512Hex(Data(contentsOf: markerURL))) == observedA.digest
        XCTAssertTrue(oldDigestOnlyPredicate, "the old digest-only guard demonstrably fails open on this ABA")

        // A commits late: its stale observation must NOT remove B.
        try await resolverA.recordResolution(
            environmentID: "env-aba", preservedPath: nil, resolution: "discarded",
            observedCorruptMarker: observedA
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerURL.path),
            "A's stale observation must never remove B's identical-bytes replacement"
        )

        // Fresh PROCESS identity (brand-new store) stays excluded for B.
        let reborn = RuntimeV2Store(layout: layout)
        let holdForB = await reborn.repairHolds.hold(environmentID: "env-aba")
        XCTAssertNotNil(holdForB, "B's identical-bytes replacement keeps failing closed on a fresh store")
        let excludedB = await reborn.leases.excludes(environmentID: "env-aba")
        XCTAssertTrue(excludedB, "B's exclusion remains in force after A's stale commit")

        // Generation backstop: same bytes, SAME file instance, but an
        // intervening `place()` advanced the monotonic generation — the
        // generation mismatch alone must keep the marker.
        let observedLiveRaw = await RuntimeV2RepairHoldStore(layout: layout)
            .corruptMarkerObservation(environmentID: "env-aba")
        let observedLive = try XCTUnwrap(observedLiveRaw)
        let generationURL = markerURL.deletingLastPathComponent()
            .appendingPathComponent("repair-hold.generation")
        try Data("4242".utf8).write(to: generationURL, options: .atomic)
        try await resolverA.recordResolution(
            environmentID: "env-aba", preservedPath: nil, resolution: "discarded",
            observedCorruptMarker: observedLive
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerURL.path),
            "an intervening generation bump must keep even an inode-stable marker"
        )
        try FileManager.default.removeItem(at: generationURL)

        // Legitimate explicit repair of the LIVE instance: the new flow
        // re-observes B at its own start, every identity matches at commit,
        // and the exclusion lifts cleanly (nothing to recover here).
        let resolved = try await reborn.discardRepair(
            environmentID: "env-aba", reason: "re-observed live corrupt marker; explicit cleanup"
        )
        XCTAssertEqual(resolved.resolution, "discarded")
        let after = RuntimeV2RepairHoldStore(layout: layout)
        let afterHold = await after.hold(environmentID: "env-aba")
        XCTAssertNil(afterHold, "the fresh explicit repair lifts the live exclusion")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path),
            "the matching live corrupt instance is removed by its own resolution"
        )
    }

    /// C7 P0 — when the cross-process mutation lock cannot be taken:
    ///   * a resolution must NEVER remove a corrupt marker even with an
    ///     observation whose digest/generation/inode all match (without the
    ///     flock the live entry cannot be proven equal), and
    ///   * `place()` must THROW and write NOTHING — no marker and no
    ///     generation bump — rather than publish unlocked, since an unlocked
    ///     atomic rename could be erased by a resolver that holds the lock
    ///     and has only just re-checked the previous corrupt instance.
    /// A different environment (its own lock) is unaffected.
    func testMutationLockOutageKeepsMarkerAndMakesPlaceRefuse() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        try await registerEnvironment(id: "env-nolock", baseImageID: "img")
        let envDir = try layout.environmentDirectory(environmentID: "env-nolock")
        try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)
        let markerURL = try layout.environmentRepairHoldURL(environmentID: "env-nolock")
        let generationURL = envDir.appendingPathComponent("repair-hold.generation")
        let corruptBytes = Data("locked-out-corrupt".utf8)
        try atomicRenamePublish(corruptBytes, to: markerURL)

        // Phase 1: lock usable — a genuine observation is captured.
        let holds = RuntimeV2RepairHoldStore(layout: layout)
        let observedRaw = await holds.corruptMarkerObservation(environmentID: "env-nolock")
        let observed = try XCTUnwrap(observedRaw)

        // Phase 2: block the lock open (a directory occupies the lock path so
        // open(O_RDWR|O_CREAT) fails EISDIR — the same guard a failed flock
        // hits). A new observation answers nil rather than promise an
        // identity it cannot serialize.
        let lockURL = envDir.appendingPathComponent(".repair-hold.lock")
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        let blockedStore = RuntimeV2RepairHoldStore(layout: layout)
        let blockedObservation = await blockedStore.corruptMarkerObservation(environmentID: "env-nolock")
        XCTAssertNil(
            blockedObservation,
            "without the mutation lock no removable observation is produced"
        )

        // The previously-captured, fully-matching observation must not remove
        // the corrupt marker while the lock is unavailable.
        try await blockedStore.recordResolution(
            environmentID: "env-nolock", preservedPath: nil, resolution: "discarded",
            observedCorruptMarker: observed
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: markerURL.path),
            "lock unavailable → the corrupt marker stays (fail closed)"
        )
        let reborn = RuntimeV2Store(layout: layout)
        let stillExcluded = await reborn.repairHolds.hold(environmentID: "env-nolock")
        XCTAssertNotNil(stillExcluded, "the environment stays excluded")
        let stillExcludedLease = await reborn.leases.excludes(environmentID: "env-nolock")
        XCTAssertTrue(stillExcludedLease, "the lease-side exclusion stays in force")

        // place() refuses outright and writes NEITHER the marker NOR a
        // generation: an unlocked publish is never allowed to race a locked
        // resolver.
        let beforeBytes = try Data(contentsOf: markerURL)
        do {
            try await blockedStore.place(
                environmentID: "env-nolock", runtimeID: "rt-racer", reason: "unlocked attempt"
            )
            XCTFail("place must throw when the mutation lock is unavailable")
        } catch RuntimeV2Error.layoutCorrupt {
            // expected
        }
        XCTAssertEqual(try Data(contentsOf: markerURL), beforeBytes, "the live marker is untouched")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: generationURL.path),
            "no generation sidecar may appear on a refused place"
        )

        // A DIFFERENT environment owns its own lock and places normally.
        let neighborStore = RuntimeV2RepairHoldStore(layout: layout)
        try await neighborStore.place(
            environmentID: "env-nolock-neighbor", runtimeID: "rt-x", reason: "separate lock"
        )
        let neighbor = await neighborStore.hold(environmentID: "env-nolock-neighbor")
        XCTAssertNotNil(neighbor)

        // Phase 3: lock restored — the same genuine observation now removes
        // the live corrupt instance.
        try FileManager.default.removeItem(at: lockURL)
        try await blockedStore.recordResolution(
            environmentID: "env-nolock", preservedPath: nil, resolution: "discarded",
            observedCorruptMarker: observed
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: markerURL.path),
            "with the lock restored, the matching observed instance is removed"
        )
        // The neighbor placed during the outage remains live.
        let neighborAfter = await neighborStore.hold(environmentID: "env-nolock-neighbor")
        XCTAssertNotNil(neighborAfter)
    }

    /// Publishes `data` through an explicit same-directory temp file +
    /// rename(2), the atomic-replace primitive `place()` uses: the directory
    /// entry points at a brand-new inode even when the bytes are identical.
    private func atomicRenamePublish(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".tmp-\(UUID().uuidString)")
        try data.write(to: temporary)
        let rc = rename(temporary.path, url.path)
        XCTAssertEqual(rc, 0, "rename(2) must atomically publish the marker")
    }

    /// Multi-repair cycles (review P0): resolving repair A binds to A's exact
    /// hold instance — a LATER, distinct failure B writes a live marker with a
    /// fresh holdID, and history must never suppress it. After process death +
    /// TTL expiry the environment is environmentRepairRequired again, B's
    /// bytes are intact, and no fresh boot is possible — and even a hold C
    /// reusing A's exact preservedPath is not neutralized by A's resolution.
    func testRepeatedRepairCyclesAreNotNeutralizedByHistory() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)
        try await registerEnvironment(id: "env-cycles", baseImageID: image.id)

        // --- Repair cycle A: boot, write A, fail, restore, resolve.
        let integratorA = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: legacyRoot, build: "test")
        _ = try await integratorA.acquireSlot(environmentID: "env-cycles", runtimeID: "rt-a", requestedMB: 512)
        let workA = try await integratorA.prepareWorkingDisk(
            environmentID: "env-cycles", runtimeID: "rt-a", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        try writeBlock(workA.diskURL, offset: 2 << 20, byte: 0xA1)
        let dirA = try layout.runtimeVMDirectory(runtimeID: "rt-a")
        let entryA = layout.quarantineDirectory.appendingPathComponent("runtime-vm-rt-a-aaaa", isDirectory: true)
        try FileManager.default.moveItem(at: dirA, to: entryA)
        try await store.repairHolds.place(
            environmentID: "env-cycles", runtimeID: "rt-a",
            reason: "cycle A", preservedPath: "recovery/quarantine/\(entryA.lastPathComponent)"
        )
        try await store.registry.setEnvironmentState(
            id: "env-cycles", state: "repairRequired", repairReason: "cycle A"
        )
        let holdA = await store.repairHoldStatus(environmentID: "env-cycles")
        XCTAssertNotNil(holdA)
        let resolutionA = try await store.restoreRepair(environmentID: "env-cycles")
        XCTAssertEqual(resolutionA.resolution, "restored")
        let statusAfterA = await store.repairHoldStatus(environmentID: "env-cycles")
        XCTAssertNil(statusAfterA, "cycle A resolved: the exclusion lifts")
        let stateAfterA = try await store.registry.environment(id: "env-cycles")?.state
        XCTAssertEqual(stateAfterA, "stopped")

        // --- Repair cycle B: a brand-new failure with a NEW marker instance.
        let integratorB = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: legacyRoot, build: "test")
        _ = try await integratorB.acquireSlot(environmentID: "env-cycles", runtimeID: "rt-b", requestedMB: 512)
        let workB = try await integratorB.prepareWorkingDisk(
            environmentID: "env-cycles", runtimeID: "rt-b", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        try writeBlock(workB.diskURL, offset: 3 << 20, byte: 0xB2)
        let dirB = try layout.runtimeVMDirectory(runtimeID: "rt-b")
        let entryB = layout.quarantineDirectory.appendingPathComponent("runtime-vm-rt-b-bbbb", isDirectory: true)
        try FileManager.default.moveItem(at: dirB, to: entryB)
        try await store.repairHolds.place(
            environmentID: "env-cycles", runtimeID: "rt-b",
            reason: "cycle B", preservedPath: "recovery/quarantine/\(entryB.lastPathComponent)"
        )
        try await store.registry.setEnvironmentState(
            id: "env-cycles", state: "repairRequired", repairReason: "cycle B"
        )
        try writeLease(
            environmentID: "env-cycles", runtimeID: "rt-b", incarnation: "dead-incarnation",
            pid: 4_000_000, renewedAt: Date(timeIntervalSinceNow: -600), ttlSeconds: 30
        )

        // Process death + TTL expiry: cycle B must be fully excluded — the
        // committed resolution for cycle A binds to A's hold instance only
        // and can never suppress B's live marker.
        let reborn = RuntimeV2Store(layout: layout)
        let report = try await reborn.prepareAndRecover(build: "test")
        let holdB = await reborn.repairHoldStatus(environmentID: "env-cycles")
        XCTAssertNotNil(holdB, "cycle B's distinct hold instance must survive A's resolution")
        XCTAssertNotEqual(holdB?.holdID, holdA?.holdID, "B is a different hold instance")
        XCTAssertTrue(holdB?.reason.contains("cycle B") ?? false)
        let stateB = try await reborn.registry.environment(id: "env-cycles")?.state
        XCTAssertEqual(stateB, "repairRequired")
        XCTAssertTrue(report.unreclaimableLeases.contains("env-cycles"))
        XCTAssertEqual(
            try readBlock(entryB.appendingPathComponent("disk.img"), offset: 3 << 20),
            Data(repeating: 0xB2, count: 4096)
        )
        let freshIntegrator = RuntimeV2GuestIntegrator(store: reborn, legacyImagesRoot: legacyRoot, build: "test")
        do {
            _ = try await freshIntegrator.prepareWorkingDisk(
                environmentID: "env-cycles", runtimeID: "rt-b-2", imageID: image.id,
                legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
            )
            XCTFail("cycle B must refuse a fresh boot")
        } catch RuntimeV2Error.environmentRepairRequired {
            // expected
        }

        // Resolving cycle B works normally (and binds to B's instance).
        let resolutionB = try await reborn.restoreRepair(environmentID: "env-cycles")
        XCTAssertEqual(resolutionB.resolution, "restored")
        let statusAfterB = await reborn.repairHoldStatus(environmentID: "env-cycles")
        XCTAssertNil(statusAfterB)

        // --- Same-path reuse C: a NEW hold instance naming A's EXACT
        // preservedPath must still fail closed — resolutions never neutralize
        // a marker they did not bind to.
        try await store.repairHolds.place(
            environmentID: "env-cycles", runtimeID: "rt-c",
            reason: "cycle C reusing A's path",
            preservedPath: "recovery/quarantine/\(entryA.lastPathComponent)"
        )
        let storeC = RuntimeV2Store(layout: layout)
        let holdC = await storeC.repairHoldStatus(environmentID: "env-cycles")
        XCTAssertNotNil(holdC, "a fresh hold instance reusing A's path must NOT be neutralized by A's resolution")
        let excludedC = await storeC.leases.excludes(environmentID: "env-cycles")
        XCTAssertTrue(excludedC)
    }

    /// Post-commit cleanup recovery: after A's resolution commits and the
    /// marker retirement happens (best effort), a lingering STALE marker with
    /// A's exact holdID stays dead on every read, and a recovery pass never
    /// re-derives or re-blocks the acknowledged evidence — while any NEW
    /// marker instance still fails closed (covered by the cycle test).
    func testPostCommitCleanupRecoverySuppressesOnlyTheMatchingInstance() async throws {
        _ = try await store.prepareAndRecover(build: "test")
        let legacyRoot = root.appendingPathComponent("legacy-images", isDirectory: true)
        let (image, _) = try makeLegacyImage(imageID: "test-image", root: legacyRoot)
        _ = try await store.images.migrateLegacyImage(imageID: image.id, legacyImagesRoot: legacyRoot)
        try await registerEnvironment(id: "env-stale", baseImageID: image.id)
        let integrator = RuntimeV2GuestIntegrator(store: store, legacyImagesRoot: legacyRoot, build: "test")
        _ = try await integrator.acquireSlot(environmentID: "env-stale", runtimeID: "rt-stale", requestedMB: 512)
        let work = try await integrator.prepareWorkingDisk(
            environmentID: "env-stale", runtimeID: "rt-stale", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        try writeBlock(work.diskURL, offset: 2 << 20, byte: 0x51)
        let directory = try layout.runtimeVMDirectory(runtimeID: "rt-stale")
        let entry = layout.quarantineDirectory.appendingPathComponent("runtime-vm-rt-stale-cccc", isDirectory: true)
        try FileManager.default.moveItem(at: directory, to: entry)
        try await store.repairHolds.place(
            environmentID: "env-stale", runtimeID: "rt-stale",
            reason: "stale-marker test", preservedPath: "recovery/quarantine/\(entry.lastPathComponent)"
        )
        try await store.registry.setEnvironmentState(
            id: "env-stale", state: "repairRequired", repairReason: "stale-marker test"
        )
        let markerA = await store.repairHoldStatus(environmentID: "env-stale")
        let markerABytes = try RuntimeV2RepairHoldStore.encoder.encode(markerA)

        // Resolve: the resolution commits and binds to marker A's holdID.
        let resolution = try await store.restoreRepair(environmentID: "env-stale")
        XCTAssertEqual(resolution.resolution, "restored")

        // Simulate the post-commit cleanup window: the marker retirement was
        // best-effort and a STALE marker A lingers on disk (same holdID).
        let markerURL = try layout.environmentRepairHoldURL(environmentID: "env-stale")
        try markerABytes.write(to: markerURL, options: .atomic)
        let lingering = RuntimeV2RepairHoldStore(layout: layout)
        let lingeringHold = await lingering.hold(environmentID: "env-stale")
        XCTAssertNil(lingeringHold, "a lingering stale marker with the RESOLVED holdID stays dead")
        let freshStatus = await store.repairHoldStatus(environmentID: "env-stale")
        XCTAssertNil(freshStatus)

        // The original session's lease must look exactly like a dead process
        // past its TTL to the new identity.
        try writeLease(
            environmentID: "env-stale", runtimeID: "rt-stale", incarnation: "dead-incarnation",
            pid: 4_000_000, renewedAt: Date(timeIntervalSinceNow: -600), ttlSeconds: 30
        )
        // A recovery pass on a new identity: the acknowledged evidence never
        // re-blocks the repaired environment, and no state regresses.
        let reborn = RuntimeV2Store(layout: layout)
        let report = try await reborn.prepareAndRecover(build: "test")
        XCTAssertTrue(report.repairReapplied.isEmpty, "the acknowledged entry must never re-derive the exclusion")
        let state = try await reborn.registry.environment(id: "env-stale")?.state
        XCTAssertEqual(state, "stopped")
        // And the environment boots normally again.
        let integrator2 = RuntimeV2GuestIntegrator(store: reborn, legacyImagesRoot: legacyRoot, build: "test")
        _ = try await integrator2.acquireSlot(environmentID: "env-stale", runtimeID: "rt-stale-2", requestedMB: 512)
        let rebooted = try await integrator2.prepareWorkingDisk(
            environmentID: "env-stale", runtimeID: "rt-stale-2", imageID: image.id,
            legacyWritableDirectory: nil, targetCapacityBytes: 4 << 20
        )
        XCTAssertEqual(try readBlock(rebooted.diskURL, offset: 2 << 20), Data(repeating: 0x51, count: 4096))
        await integrator2.completeStop(
            environmentID: "env-stale", runtimeID: "rt-stale-2", imageID: image.id, clean: true
        )
    }

    // MARK: - fixtures (P0 helpers)

    private func writeBlock(_ url: URL, offset: Int64, byte: UInt8, count: Int = 4096) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: Data(repeating: byte, count: count))
        try handle.synchronize()
    }

    private func readBlock(_ url: URL, offset: Int64, count: Int = 4096) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }

    private func registerEnvironment(
        in store: RuntimeV2Store? = nil, id: String, baseImageID: String, state: String = "stopped"
    ) async throws {
        let registry = await (store ?? self.store).registry
        let now = Date()
        try await registry.upsertEnvironment(
            RuntimeV2Registry.EnvironmentRow(
                id: id, kind: "linuxVM", ownerID: nil, name: id,
                baseImageID: baseImageID, baseRootfsDigest: nil, state: state,
                dataPath: "environments/\(id)/data", compatHostFHS: false,
                repairReason: nil, createdAt: now, lastUsedAt: now
            )
        )
    }

    private func writeLease(
        environmentID: String, runtimeID: String, incarnation: String,
        pid: Int64, renewedAt: Date, ttlSeconds: Int64
    ) throws {
        let environmentDir = try layout.environmentDirectory(environmentID: environmentID)
        try FileManager.default.createDirectory(at: environmentDir, withIntermediateDirectories: true)
        let lease = RuntimeV2LeaseStore.Lease(
            environmentID: environmentID, runtimeID: runtimeID, incarnation: incarnation,
            sessionToken: "token", pid: pid,
            acquiredAt: renewedAt, renewedAt: renewedAt, ttlSeconds: ttlSeconds
        )
        try RuntimeV2LeaseStore.encoder.encode(lease).write(
            to: environmentDir.appendingPathComponent("lease.json"), options: .atomic
        )
    }

    // MARK: - fixtures

    /// Scripted Runtime v2 substrate: records the exact calls the guest
    /// registry makes, with no VM, pool or disk behind it.
    private actor ScriptedV2Integrator: LinuxGuestRuntimeV2Integrating {
        private(set) var events: [String] = []
        let expandedRoot: URL
        let root: URL

        init(expandedRoot: URL, root: URL) {
            self.expandedRoot = expandedRoot
            self.root = root
        }

        func acquireSlot(environmentID: String, runtimeID: String, requestedMB: Int) async throws -> RuntimeV2Admission {
            events.append("acquire:\(environmentID)")
            return RuntimeV2Admission(runtimeID: runtimeID, ramMB: requestedMB, downgraded: false)
        }

        func releaseSlot(environmentID: String, runtimeID: String) async {
            events.append("release:\(environmentID)")
        }

        func prepareWorkingDisk(
            environmentID: String, runtimeID: String, imageID: String,
            legacyWritableDirectory: URL?, targetCapacityBytes: Int64
        ) async throws -> RuntimeV2WorkingDisk {
            events.append("disk:\(environmentID)")
            let url = root.appendingPathComponent("scripted-\(runtimeID).img")
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 1024))
            return RuntimeV2WorkingDisk(diskURL: url, capacityBytes: 1024)
        }

        func environmentDataDirectory(environmentID: String) async throws -> URL {
            events.append("data:\(environmentID)")
            let url = root.appendingPathComponent("scripted-data/\(environmentID)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func completeStop(environmentID: String, runtimeID: String, imageID: String, clean: Bool) async {
            events.append("stop:\(environmentID):\(clean)")
        }

        func expandedImageDirectory(imageID: String) async throws -> URL { expandedRoot }
        func isImageVerified(imageID: String) async -> Bool { true }
        func isImageVerifiedWithoutMigration(imageID: String) async -> Bool { true }
        func recordedRunnerCapabilities(environmentID: String) async -> String? { nil }
        func recordRunnerCapabilities(_ capabilities: String, environmentID: String) async {}
        func workingDiskCapacityBytes(environmentID: String, runtimeID: String) async -> Int64? { 1024 }
        func queuedStarts() async -> Int { 0 }
        func planRetier(environmentID: String, ramMB: Int) async throws {}
        func confirmTier(environmentID: String, ramMB: Int) async {}
    }

    /// A minimal qualified image with a relative artifact path and real
    /// digest-bound bytes, so the registry's structural qualification passes
    /// against the scripted expanded directory.
    private func makeQualifiedImage(id: String, directory: URL) throws -> LinuxGuestImage {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bios = Data("bios".utf8)
        try bios.write(to: directory.appendingPathComponent("bbl64.bin"))
        return LinuxGuestImage(
            id: id,
            biosPath: "bbl64.bin",
            qualified: true,
            qualificationRun: "runtime-v2-startup-tests",
            artifacts: [
                LinuxGuestImageArtifact(
                    role: .bios, path: "bbl64.bin",
                    sha512: FloeDigest.sha512Hex(bios), bytes: Int64(bios.count)
                )
            ]
        )
    }

    /// Fabricates a minimal qualified legacy image: manifest.json plus two
    /// small real artifacts with truthful SHA-512 digests.
    private func makeLegacyImage(
        imageID: String, root: URL
    ) throws -> (image: LinuxGuestImage, directory: URL) {
        let directory = root.appendingPathComponent(imageID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var bios = Data(count: 4096)
        for index in bios.indices { bios[index] = UInt8((index &* 31) % 251) }
        var rootfs = Data(count: 3 << 20)
        for index in rootfs.indices { rootfs[index] = UInt8((index &* 17) % 253) }
        try bios.write(to: directory.appendingPathComponent("bios.bin"))
        try rootfs.write(to: directory.appendingPathComponent("rootfs.img"))
        let image = LinuxGuestImage(
            id: imageID,
            biosPath: "bios.bin",
            diskPath: "rootfs.img",
            qualified: true,
            qualificationRun: "runtime-v2-startup-tests",
            artifacts: [
                LinuxGuestImageArtifact(
                    role: .bios, path: "bios.bin",
                    sha512: FloeDigest.sha512Hex(bios), bytes: Int64(bios.count)
                ),
                LinuxGuestImageArtifact(
                    role: .disk, path: "rootfs.img",
                    sha512: FloeDigest.sha512Hex(rootfs), bytes: Int64(rootfs.count)
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(image).write(to: directory.appendingPathComponent("manifest.json"))
        return (image, directory)
    }
}

/// Protocol-3 CAPS answer for the channel's hello probe (file-private so the
/// @Sendable factory closure never touches a class metatype).
private func runtimeV2CapsReply(_ token: String) -> [Data] {
    [Data("\u{1e}FLOE-CAPS \(token) runner=2.0.0 protocol=3 maxCommands=8 maxSessions=4\u{1e}\u{1e}FLOE-END \(token) 0\u{1e}".utf8)]
}

/// Empty successful command answer for every non-hello token.
private func runtimeV2OKReply(_ token: String) -> [Data] {
    var data = Data()
    data.append(Data("\u{1e}FLOE-BEGIN \(token)\u{1e}\u{1e}FLOE-OUT \(token)\u{1e}".utf8))
    data.append(Data("\u{1e}FLOE-END \(token) 0\u{1e}".utf8))
    return [data]
}
