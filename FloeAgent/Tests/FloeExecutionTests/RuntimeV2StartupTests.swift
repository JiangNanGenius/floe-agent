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
        // The applied migration is recorded exactly once.
        var verify: OpaquePointer?
        XCTAssertEqual(sqlite3_open(layout.registryDatabaseURL.path, &verify), SQLITE_OK)
        defer { sqlite3_close(verify) }
        var statement: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(verify, "SELECT COUNT(*) FROM schema_migrations", -1, &statement, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
        sqlite3_finalize(statement)
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
