import Foundation
import XCTest
@testable import FloeDesktopSync

final class LimitsAndMigrationTests: XCTestCase {
    func testBatchRecordAndByteLimitsAreCheckedBeforeWriting() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let peer = try TestIDs.device(2)
        let task = try TestIDs.task(3)
        let configuration = SyncStoreConfiguration(
            maxPayloadBytes: 1_024,
            maxBatchRecords: 2,
            maxBatchBytes: 40
        )
        let store = try database.makeStore(deviceID: device, configuration: configuration)

        let records = try (0..<3).map { offset in
            try SyncRecord.test(
                entityID: try TestIDs.entity(100 + offset),
                revision: 1,
                originDeviceID: peer,
                taskID: task,
                payload: .object(["title": .string("record-\(offset)")])
            )
        }
        await XCTAssertThrowsSyncError(.batchTooLarge(limit: 2)) {
            _ = try await store.applyUncheckedBatchForTesting(
                RemoteChangeBatch(
                    peerDeviceID: peer,
                    through: try TestIDs.cursor(3),
                    records: records
                )
            )
        }
        let empty = try await store.recordCount(includingDeleted: true)
        XCTAssertEqual(empty, 0)
        let cursor = try await store.appliedCursor(for: peer)
        XCTAssertEqual(cursor, .zero)

        let large = try SyncRecord.test(
            entityID: try TestIDs.entity(200),
            revision: 1,
            originDeviceID: peer,
            taskID: task,
            payload: .object(["title": .string(String(repeating: "x", count: 200))])
        )
        await XCTAssertThrowsSyncError(.batchBytesTooLarge(limit: 40)) {
            _ = try await store.applyUncheckedBatchForTesting(
                RemoteChangeBatch(
                    peerDeviceID: peer,
                    through: try TestIDs.cursor(1),
                    records: [large]
                )
            )
        }
        await store.close()
    }

    func testJSONNodeLimitAndRawWireSizeGuard() throws {
        let nodes = "[" + Array(repeating: "0", count: 1_001).joined(separator: ",") + "]"
        XCTAssertThrowsError(try JSONValue.parse(nodes, maxNodes: 1_000)) { error in
            XCTAssertEqual(error as? JSONValueParseError, .nodeLimitExceeded(1_000))
        }
        let tooLarge = String(repeating: " ", count: SyncStore.maximumWireBytes + 1)
        XCTAssertThrowsError(try SyncCommand(wireJSON: tooLarge)) { error in
            XCTAssertEqual(
                error as? SyncStoreError,
                .payloadTooLarge(limit: SyncStore.maximumWireBytes)
            )
        }
    }

    func testChangeAndSnapshotPagesRespectByteBudgetWithoutLosingRows() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let configuration = SyncStoreConfiguration(
            maxPageSize: 10,
            maxPageBytes: 64
        )
        let store = try database.makeStore(deviceID: device, configuration: configuration)
        let payload = JSONValue.object(["title": .string(String(repeating: "y", count: 200))])
        for offset in 0..<3 {
            _ = try await store.commitLocalRecord(
                try SyncRecord.test(
                    entityID: try TestIDs.entity(300 + offset),
                    revision: 1,
                    originDeviceID: device,
                    taskID: task,
                    payload: payload
                )
            )
        }

        var cursor = ChangeCursor.zero
        var changeCount = 0
        repeat {
            let page = try await store.changes(after: cursor, limit: 10)
            XCTAssertEqual(page.entries.count, 1)
            changeCount += page.entries.count
            cursor = page.nextCursor
            if !page.hasMore { break }
        } while changeCount < 3
        XCTAssertEqual(changeCount, 3)

        let snapshot = try await store.openSnapshot()
        XCTAssertEqual(snapshot.recordCount, 3)
        var token: SnapshotPageToken?
        var records = 0
        repeat {
            let page = try await store.snapshotPage(
                snapshot.snapshotID,
                after: token,
                limit: 10
            )
            XCTAssertEqual(page.records.count, 1)
            records += page.records.count
            token = page.nextToken
        } while token != nil
        XCTAssertEqual(records, 3)
        await store.close()
    }

    func testVersionOneDatabaseMigratesWithoutLosingExistingRows() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let peer = try TestIDs.device(2)
        let task = try TestIDs.task(3)
        let entityID = try TestIDs.entity(400)

        let first = try database.makeStore(deviceID: device)
        _ = try await first.commitLocalRecord(
            try SyncRecord.test(
                entityID: entityID,
                revision: 1,
                originDeviceID: device,
                taskID: task,
                payload: .object(["title": .string("v1-row")])
            )
        )
        await first.close()

        let raw = try database.rawConnection()
        try raw.execute("BEGIN IMMEDIATE")
        do {
            for statement in [
                "ALTER TABLE records DROP COLUMN base_revision",
                "ALTER TABLE records DROP COLUMN base_digest",
                "ALTER TABLE changes DROP COLUMN base_revision",
                "ALTER TABLE changes DROP COLUMN base_digest",
                "ALTER TABLE commands DROP COLUMN target_entity_kind",
                "ALTER TABLE commands DROP COLUMN target_entity_id",
                "ALTER TABLE snapshots DROP COLUMN scope_kind",
                "ALTER TABLE snapshots DROP COLUMN scope_id",
                "ALTER TABLE snapshots DROP COLUMN tombstone_count",
                "ALTER TABLE snapshots DROP COLUMN manifest_complete",
                "ALTER TABLE snapshot_entries DROP COLUMN base_revision",
                "ALTER TABLE snapshot_entries DROP COLUMN base_digest",
                "ALTER TABLE snapshot_entries DROP COLUMN deleted",
                "DROP TABLE conflicts",
                "DROP TABLE snapshot_import_records",
                "DROP TABLE snapshot_import_pages",
                "DROP TABLE snapshot_imports",
                "DROP TABLE sync_subscriptions",
                "PRAGMA user_version = 1"
            ] {
                try raw.execute(statement)
            }
            try raw.execute("COMMIT")
        } catch {
            _ = try? raw.execute("ROLLBACK")
            raw.close()
            throw error
        }
        raw.close()

        let migrated = try database.makeStore(deviceID: device)
        let metadata = try await migrated.metadata()
        XCTAssertEqual(metadata.schemaVersion, 5)
        let legacy = try await migrated.storedRecord(kind: .task, entityID: entityID)
        XCTAssertEqual(legacy?.record.payload["title"]?.stringValue, "v1-row")
        XCTAssertNil(legacy?.record.baseRevision)
        let conflicts = try await migrated.conflicts()
        XCTAssertEqual(conflicts.count, 0)
        let subscriptions = try await migrated.subscriptions()
        XCTAssertEqual(subscriptions, [])
        XCTAssertEqual(metadata.stagingSnapshotImportCount, 0)
        XCTAssertEqual(metadata.establishedSubscriptionCount, 0)

        _ = try await migrated.acknowledgeLocalRecord(
            kind: .task,
            entityID: entityID,
            revision: try TestIDs.revision(1)
        )
        let legacyBaseline = JSONValue.object(["title": .string("v1-row")])
        let update = try SyncRecord.test(
            entityID: entityID,
            revision: 2,
            baseRevision: 1,
            baseDigest: ContentDigest.compute(legacyBaseline.canonicalUTF8),
            originDeviceID: peer,
            taskID: task,
            payload: .object(["title": .string("post-migration")])
        )
        let applied = try await migrated.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: peer,
                through: try TestIDs.cursor(1),
                records: [update]
            )
        )
        XCTAssertEqual(applied.applied.count, 1)
        let updated = try await migrated.storedRecord(kind: .task, entityID: entityID)
        XCTAssertEqual(updated?.record.payload["title"]?.stringValue, "post-migration")
        XCTAssertEqual(updated?.record.revision, try TestIDs.revision(2))
        await migrated.close()
    }

    func testVersionTwoDatabaseMigratesWithoutLosingConflictsOrLegacyCursor() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(10)
        let peer = try TestIDs.device(11)
        let task = try TestIDs.task(12)
        let conflicted = try TestIDs.entity(500)
        let visible = try TestIDs.entity(501)

        let store = try database.makeStore(deviceID: device)
        _ = try await store.commitLocalRecord(
            try SyncRecord.test(
                entityID: conflicted,
                revision: 1,
                originDeviceID: device,
                taskID: task,
                payload: .object(["title": .string("local")])
            )
        )
        _ = try await store.commitLocalRecord(
            try SyncRecord.test(
                entityID: visible,
                revision: 1,
                originDeviceID: device,
                taskID: task,
                payload: .object(["title": .string("visible")])
            )
        )
        _ = try await store.acknowledgeLocalRecord(
            kind: .task,
            entityID: visible,
            revision: try TestIDs.revision(1)
        )
        _ = try await store.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: peer,
                through: try TestIDs.cursor(5),
                records: [
                    try SyncRecord.test(
                        entityID: conflicted,
                        revision: 1,
                        originDeviceID: peer,
                        taskID: task,
                        payload: .object(["title": .string("remote")])
                    )
                ]
            )
        )
        let initialConflicts = try await store.conflicts()
        XCTAssertEqual(initialConflicts.count, 1)
        await XCTAssertEqualAsync(
            { try await store.appliedCursor(for: peer) },
            try TestIDs.cursor(5)
        )
        await store.close()

        let raw = try database.rawConnection()
        try raw.execute("BEGIN IMMEDIATE")
        do {
            for statement in [
                "DROP TABLE snapshot_import_records",
                "DROP TABLE snapshot_import_pages",
                "DROP TABLE snapshot_imports",
                "DROP TABLE sync_subscriptions",
                "ALTER TABLE snapshots DROP COLUMN manifest_complete",
                "PRAGMA user_version = 2"
            ] {
                try raw.execute(statement)
            }
            try raw.execute("COMMIT")
        } catch {
            _ = try? raw.execute("ROLLBACK")
            raw.close()
            throw error
        }
        raw.close()

        let migrated = try database.makeStore(deviceID: device)
        let metadata = try await migrated.metadata()
        XCTAssertEqual(metadata.schemaVersion, 5)
        XCTAssertEqual(metadata.stagingSnapshotImportCount, 0)
        XCTAssertEqual(metadata.establishedSubscriptionCount, 0)
        let retained = try await migrated.storedRecord(kind: .task, entityID: visible)
        XCTAssertEqual(retained?.record.payload["title"]?.stringValue, "visible")
        let conflicts = try await migrated.conflicts()
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.incoming.payload["title"]?.stringValue, "remote")
        await XCTAssertEqualAsync(
            { try await migrated.appliedCursor(for: peer) },
            try TestIDs.cursor(5)
        )
        let subscriptions = try await migrated.subscriptions()
        XCTAssertEqual(subscriptions, [])
        // An old peer-wide cursor cannot stand in for a complete scope
        // subscription when scoped changes are applied.
        await XCTAssertThrowsSyncError(
            .scopedIncrementalUnverified
        ) {
            _ = try await migrated.applyScopedRemoteBatch(
                peerDeviceID: peer,
                scope: .task(task),
                through: try TestIDs.cursor(6),
                records: []
            )
        }
        await XCTAssertEqualAsync(
            { try await migrated.appliedCursor(for: peer) },
            try TestIDs.cursor(5)
        )
        await migrated.close()
    }
}
