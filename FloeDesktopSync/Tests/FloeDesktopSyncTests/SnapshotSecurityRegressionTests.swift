import Foundation
import XCTest
@testable import FloeDesktopSync

final class SnapshotSecurityRegressionTests: XCTestCase {
    private func rejected<T>(_ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("operation must be rejected", file: file, line: line) }
        catch { }
    }

    func testInboundRecordsCannotChangeExistingTaskOrWorkspaceIncludingTombstone() async throws {
        let db = try TestDatabase()
        addTeardownBlock { db.remove() }
        let device = try TestIDs.device(1), peer = try TestIDs.device(2)
        let taskA = try TestIDs.task(3), taskB = try TestIDs.task(4)
        let entity = try TestIDs.entity(5)
        let store = try db.makeStore(deviceID: device)
        let body: JSONValue = .object(["title": .string("private B")])
        _ = try await store.commitLocalRecord(try .test(entityID: entity, revision: 1,
            originDeviceID: device, taskID: taskB, payload: body))
        _ = try await store.acknowledgeLocalRecord(kind: .task, entityID: entity,
            revision: try TestIDs.revision(1))
        for deleted in [false, true] {
            let incoming = try SyncRecord.test(entityID: entity, revision: 2, baseRevision: 1,
                baseDigest: ContentDigest.compute(body.canonicalUTF8), originDeviceID: peer,
                taskID: taskA, payload: .null, deleted: deleted)
            await rejected {
                try await store.applyUncheckedBatchForTesting(RemoteChangeBatch(peerDeviceID: peer,
                    through: try TestIDs.cursor(1), records: [incoming]))
            }
        }
        await rejected {
            try await store.applyRemoteBatch(RemoteChangeBatch(peerDeviceID: peer,
                through: try TestIDs.cursor(100), records: []))
        }
        let original = try await store.storedRecord(kind: .task, entityID: entity)
        XCTAssertEqual(original?.record.taskID, taskB)
        XCTAssertEqual(original?.record.payload, body)
        XCTAssertEqual(original?.record.deleted, false)
        let cursor = try await store.appliedCursor(for: peer)
        XCTAssertEqual(cursor, .zero)
        await store.close()
    }

    func testInboundWorkspaceRecordCannotMoveAcrossWorkspace() async throws {
        let db = try TestDatabase()
        addTeardownBlock { db.remove() }
        let device = try TestIDs.device(6), peer = try TestIDs.device(7)
        let workspaceA = try TestIDs.workspace(8), workspaceB = try TestIDs.workspace(9)
        let entity = try TestIDs.entity(10)
        let store = try db.makeStore(deviceID: device)
        let body: JSONValue = .object(["path": .string("private.txt")])
        _ = try await store.commitLocalRecord(try .test(kind: .workspaceFile, entityID: entity, revision: 1,
            originDeviceID: device, workspaceID: workspaceB, payload: body))
        _ = try await store.acknowledgeLocalRecord(kind: .workspaceFile, entityID: entity,
            revision: try TestIDs.revision(1))
        for deleted in [false, true] {
            let incoming = try SyncRecord.test(kind: .workspaceFile, entityID: entity, revision: 2,
                baseRevision: 1, baseDigest: ContentDigest.compute(body.canonicalUTF8),
                originDeviceID: peer, workspaceID: workspaceA, payload: .null, deleted: deleted)
            await rejected {
                try await store.applyUncheckedBatchForTesting(RemoteChangeBatch(peerDeviceID: peer,
                    through: try TestIDs.cursor(1), records: [incoming]))
            }
        }
        let original = try await store.storedRecord(kind: .workspaceFile, entityID: entity)
        XCTAssertEqual(original?.record.workspaceID, workspaceB)
        XCTAssertEqual(original?.record.deleted, false)
        await store.close()
    }

    func testResetCannotRelabelOldManifestAndUnprovenIncrementCannotAdvance() async throws {
        let sourceDB = try TestDatabase(), targetDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); targetDB.remove() }
        let sourceID = try TestIDs.device(10), targetID = try TestIDs.device(11)
        let task = try TestIDs.task(12)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let target = try targetDB.makeStore(deviceID: targetID)
        let snap = try await source.openSnapshot(scope: .task(task))
        let old = try await source.snapshotManifest(snap.snapshotID)
        _ = try await target.beginSnapshotImportForTesting(peerDeviceID: sourceID, manifest: old, subscriptionVersion: 1)
        _ = try await target.commitSnapshotImportForTesting(peerDeviceID: sourceID, snapshotID: snap.snapshotID)
        _ = try await target.resetSubscription(peerDeviceID: sourceID, scope: .task(task), version: 2)
        await rejected {
            try await target.beginSnapshotImportForTesting(peerDeviceID: sourceID, manifest: old, subscriptionVersion: 2)
        }
        let sub = try await target.subscription(peerDeviceID: sourceID, scope: .task(task))
        XCTAssertEqual(sub?.version, 2)
        XCTAssertEqual(sub?.established, false)
        let freshSnapshot = try await source.openSnapshot(scope: .task(task))
        let freshManifest = try await source.snapshotManifest(freshSnapshot.snapshotID, subscriptionVersion: 2)
        _ = try await target.beginSnapshotImportForTesting(peerDeviceID: sourceID, manifest: freshManifest, subscriptionVersion: 2)
        _ = try await target.commitSnapshotImportForTesting(peerDeviceID: sourceID, snapshotID: freshSnapshot.snapshotID)
        let later = try SyncRecord.test(entityID: try TestIDs.entity(13), revision: 1,
            originDeviceID: sourceID, taskID: task)
        await rejected {
            try await target.applyScopedRemoteBatch(peerDeviceID: sourceID, scope: .task(task),
                through: try TestIDs.cursor(20), records: [later])
        }
        await rejected {
            try await target.applyScopedRemoteBatch(peerDeviceID: sourceID, scope: .task(task),
                through: try TestIDs.cursor(10), records: [])
        }
        let after = try await target.subscription(peerDeviceID: sourceID, scope: .task(task))
        XCTAssertEqual(after?.appliedCursor, freshSnapshot.baseCursor)
        await source.close(); await target.close()
    }

    func testCommittedPageReplayRecomputesContentAndScope() async throws {
        let sourceDB = try TestDatabase(), targetDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); targetDB.remove() }
        let sourceID = try TestIDs.device(20), targetID = try TestIDs.device(21)
        let task = try TestIDs.task(22), otherTask = try TestIDs.task(23)
        let entity = try TestIDs.entity(24)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let target = try targetDB.makeStore(deviceID: targetID)
        _ = try await source.commitLocalRecord(try .test(entityID: entity, revision: 1,
            originDeviceID: sourceID, taskID: task))
        let snap = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(snap.snapshotID)
        let page = try await source.snapshotPageEnvelope(snap.snapshotID, manifest: manifest, pageIndex: 0)
        _ = try await target.beginSnapshotImportForTesting(peerDeviceID: sourceID, manifest: manifest, subscriptionVersion: 1)
        _ = try await target.receiveSnapshotPageForTesting(peerDeviceID: sourceID, envelope: page)
        _ = try await target.commitSnapshotImportForTesting(peerDeviceID: sourceID, snapshotID: snap.snapshotID)
        let changed = try SyncRecord.test(entityID: entity, revision: 1, originDeviceID: sourceID,
            taskID: otherTask, payload: .object(["title": .string("tampered")]))
        let forged = SnapshotPageEnvelope(snapshotID: page.snapshotID, originDeviceID: page.originDeviceID,
            pageIndex: page.pageIndex, firstPosition: page.firstPosition, lastPosition: page.lastPosition,
            records: [changed], digest: page.digest, manifestDigest: manifest.digest)
        await rejected { try await target.receiveSnapshotPageForTesting(peerDeviceID: sourceID, envelope: forged) }
        await source.close(); await target.close()
    }

    func testPageFromOldManifestCannotReplayIntoNewSubscription() async throws {
        let sourceDB = try TestDatabase(), targetDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); targetDB.remove() }
        let sourceID = try TestIDs.device(25), targetID = try TestIDs.device(26)
        let task = try TestIDs.task(27), entity = try TestIDs.entity(28)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let target = try targetDB.makeStore(deviceID: targetID)
        _ = try await source.commitLocalRecord(try .test(entityID: entity, revision: 1,
            originDeviceID: sourceID, taskID: task))
        let snap = try await source.openSnapshot(scope: .task(task))
        let first = try await source.snapshotManifest(snap.snapshotID, subscriptionVersion: 1)
        let oldPage = try await source.snapshotPageEnvelope(snap.snapshotID, manifest: first, pageIndex: 0)
        _ = try await target.beginSnapshotImportForTesting(peerDeviceID: sourceID, manifest: first, subscriptionVersion: 1)
        _ = try await target.resetSubscription(peerDeviceID: sourceID, scope: .task(task), version: 2)
        let second = try await source.snapshotManifest(snap.snapshotID, subscriptionVersion: 2)
        XCTAssertNotEqual(first.digest, second.digest)
        _ = try await target.beginSnapshotImportForTesting(peerDeviceID: sourceID, manifest: second, subscriptionVersion: 2)
        await rejected { try await target.receiveSnapshotPageForTesting(peerDeviceID: sourceID, envelope: oldPage) }
        let currentPage = try await source.snapshotPageEnvelope(snap.snapshotID, manifest: second, pageIndex: 0)
        _ = try await target.receiveSnapshotPageForTesting(peerDeviceID: sourceID, envelope: currentPage)
        _ = try await target.commitSnapshotImportForTesting(peerDeviceID: sourceID, snapshotID: snap.snapshotID)
        await source.close(); await target.close()
    }

    func testLegacyStagingFailsClosedAndCanBeExplicitlyAborted() async throws {
        let sourceDB = try TestDatabase(), targetDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); targetDB.remove() }
        let sourceID = try TestIDs.device(70), targetID = try TestIDs.device(71)
        let task = try TestIDs.task(72), entity = try TestIDs.entity(73)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let target = try targetDB.makeStore(deviceID: targetID)
        _ = try await source.commitLocalRecord(try .test(entityID: entity, revision: 1,
            originDeviceID: sourceID, taskID: task))
        let snap = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(snap.snapshotID)
        let page = try await source.snapshotPageEnvelope(snap.snapshotID, manifest: manifest, pageIndex: 0)
        _ = try await target.beginSnapshotImportForTesting(peerDeviceID: sourceID, manifest: manifest, subscriptionVersion: 1)
        _ = try await target.receiveSnapshotPageForTesting(peerDeviceID: sourceID, envelope: page)
        guard case .object(var oldFields) = manifest.wireJSONValue() else { return XCTFail("expected manifest object") }
        oldFields.removeValue(forKey: "subscriptionVersion")
        let raw = try targetDB.rawConnection()
        let statement = try raw.prepare("UPDATE snapshot_imports SET manifest_blob = ? WHERE peer_device_id = ? AND snapshot_id = ?")
        try statement.bind(1, JSONValue.object(oldFields).canonicalUTF8)
        try statement.bind(2, sourceID.canonical)
        try statement.bind(3, snap.snapshotID.canonical)
        _ = try statement.step()
        raw.close()
        await rejected { try await target.snapshotImportStatus(peerDeviceID: sourceID, snapshotID: snap.snapshotID) }
        await rejected { try await target.commitSnapshotImportForTesting(peerDeviceID: sourceID, snapshotID: snap.snapshotID) }
        let count = try await target.recordCount()
        XCTAssertEqual(count, 0)
        let aborted = try await target.abortSnapshotImport(peerDeviceID: sourceID, snapshotID: snap.snapshotID)
        XCTAssertTrue(aborted)
        await source.close(); await target.close()
    }

    func testEmptySnapshotDoesNotAllocateUnboundedLocalReconciliation() async throws {
        let sourceDB = try TestDatabase(), targetDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); targetDB.remove() }
        let sourceID = try TestIDs.device(30), targetID = try TestIDs.device(31)
        let task = try TestIDs.task(32)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let target = try targetDB.makeStore(deviceID: targetID,
            configuration: SyncStoreConfiguration(maxSnapshotEntries: 2, maxSnapshotPages: 2))
        for value in 40..<43 {
            _ = try await target.commitLocalRecord(try .test(entityID: try TestIDs.entity(value),
                revision: 1, originDeviceID: targetID, taskID: task))
        }
        let snap = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(snap.snapshotID)
        _ = try await target.beginSnapshotImportForTesting(peerDeviceID: sourceID, manifest: manifest, subscriptionVersion: 1)
        await rejected { try await target.commitSnapshotImportForTesting(peerDeviceID: sourceID, snapshotID: snap.snapshotID) }
        let status = try await target.snapshotImportStatus(peerDeviceID: sourceID, snapshotID: snap.snapshotID)
        XCTAssertEqual(status?.state, .staging)
        let count = try await target.recordCount()
        XCTAssertEqual(count, 3)
        await source.close(); await target.close()
    }

    func testScopedSnapshotCannotOverwriteExistingEntityInAnotherTask() async throws {
        let sourceDB = try TestDatabase(), targetDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); targetDB.remove() }
        let sourceID = try TestIDs.device(40), targetID = try TestIDs.device(41)
        let taskA = try TestIDs.task(42), taskB = try TestIDs.task(43), entity = try TestIDs.entity(44)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let target = try targetDB.makeStore(deviceID: targetID)
        let original: JSONValue = .object(["title": .string("task B")])
        _ = try await target.commitLocalRecord(try .test(entityID: entity, revision: 1,
            originDeviceID: targetID, taskID: taskB, payload: original))
        _ = try await target.acknowledgeLocalRecord(kind: .task, entityID: entity, revision: try TestIDs.revision(1))
        _ = try await source.commitLocalRecord(try .test(entityID: entity, revision: 2,
            baseRevision: 1, baseDigest: ContentDigest.compute(original.canonicalUTF8),
            originDeviceID: sourceID, taskID: taskA, payload: .null, deleted: true))
        let snap = try await source.openSnapshot(scope: .task(taskA))
        let manifest = try await source.snapshotManifest(snap.snapshotID)
        let page = try await source.snapshotPageEnvelope(snap.snapshotID, manifest: manifest, pageIndex: 0)
        _ = try await target.beginSnapshotImportForTesting(peerDeviceID: sourceID, manifest: manifest, subscriptionVersion: 1)
        _ = try await target.receiveSnapshotPageForTesting(peerDeviceID: sourceID, envelope: page)
        await rejected { try await target.commitSnapshotImportForTesting(peerDeviceID: sourceID, snapshotID: snap.snapshotID) }
        let retained = try await target.storedRecord(kind: .task, entityID: entity)
        XCTAssertEqual(retained?.record.taskID, taskB)
        XCTAssertEqual(retained?.record.payload, original)
        XCTAssertEqual(retained?.record.deleted, false)
        await source.close(); await target.close()
    }

    func testLegacyConflictCannotMoveEntityAcrossTasks() async throws {
        let db = try TestDatabase()
        addTeardownBlock { db.remove() }
        let device = try TestIDs.device(50), peer = try TestIDs.device(51)
        let taskA = try TestIDs.task(52), taskB = try TestIDs.task(53), entity = try TestIDs.entity(54)
        let store = try db.makeStore(deviceID: device)
        _ = try await store.commitLocalRecord(try .test(entityID: entity, revision: 1,
            originDeviceID: device, taskID: taskA, payload: .object(["title": .string("local")])))
        let remote = try SyncRecord.test(entityID: entity, revision: 2,
            originDeviceID: peer, taskID: taskA, payload: .object(["title": .string("remote")]))
        let outcome = try await store.applyUncheckedBatchForTesting(RemoteChangeBatch(peerDeviceID: peer,
            through: try TestIDs.cursor(1), records: [remote]))
        let id = try XCTUnwrap(outcome.conflicts.first?.conflictID)
        let dbConn = try db.rawConnection()
        let statement = try dbConn.prepare("UPDATE conflicts SET incoming_task_id = ? WHERE conflict_id = ?")
        try statement.bind(1, taskB.canonical)
        try statement.bind(2, id.canonical)
        _ = try statement.step()
        dbConn.close()
        await rejected { try await store.resolveConflict(id, resolution: .acceptRemote) }
        let retained = try await store.storedRecord(kind: .task, entityID: entity)
        XCTAssertEqual(retained?.record.taskID, taskA)
        await store.close()
    }

    func testMigratedV1SnapshotWithoutTombstonesCannotProduceCompleteManifest() async throws {
        let db = try TestDatabase()
        addTeardownBlock { db.remove() }
        let device = try TestIDs.device(60), task = try TestIDs.task(61)
        let store = try db.makeStore(deviceID: device)
        _ = try await store.commitLocalRecord(try .test(entityID: try TestIDs.entity(62),
            revision: 1, originDeviceID: device, taskID: task))
        let deleted = try TestIDs.entity(63)
        _ = try await store.commitLocalRecord(try .test(entityID: deleted, revision: 1,
            originDeviceID: device, taskID: task))
        _ = try await store.commitLocalRecord(try .test(entityID: deleted, revision: 2,
            originDeviceID: device, taskID: task, payload: .null, deleted: true))
        let old = try await store.openSnapshot(scope: .task(task))
        await store.close()
        let raw = try db.rawConnection()
        try raw.execute("DELETE FROM snapshot_entries WHERE deleted = 1")
        for sql in [
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
            "DROP TABLE conflicts", "DROP TABLE snapshot_import_records",
            "DROP TABLE snapshot_import_pages", "DROP TABLE snapshot_imports",
            "DROP TABLE sync_subscriptions", "PRAGMA user_version = 1"
        ] { try raw.execute(sql) }
        raw.close()
        let migrated = try db.makeStore(deviceID: device)
        let preservedPage = try await migrated.snapshotPage(old.snapshotID)
        XCTAssertEqual(preservedPage.records.count, 1)
        await rejected { try await migrated.snapshotManifest(old.snapshotID) }
        let new = try await migrated.openSnapshot(scope: .task(task))
        _ = try await migrated.snapshotManifest(new.snapshotID)
        await migrated.close()
    }
}
