import Foundation
import XCTest
@testable import FloeDesktopSync

final class ChangeCursorTests: XCTestCase {
    func testChangeCursorAndAppliedCursorSurviveRestartAndPruning() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let peer = try TestIDs.device(2)
        let task = try TestIDs.task(3)
        let clock = TestClock()

        var store: SyncStore? = try database.makeStore(deviceID: device, clock: clock)
        for offset in 0..<3 {
            _ = try await store!.commitLocalRecord(
                try SyncRecord.test(
                    entityID: try TestIDs.entity(300 + offset),
                    revision: 1,
                    originDeviceID: device,
                    taskID: task
                )
            )
        }
        let latest = try await store!.latestChangeCursor()
        XCTAssertEqual(latest, try TestIDs.cursor(3))
        await store!.close()
        store = nil

        let reopened = try database.makeStore(deviceID: device, clock: clock)
        await XCTAssertEqualAsync({ try await reopened.latestChangeCursor() }, try TestIDs.cursor(3))

        let page = try await reopened.changes(after: .zero, limit: 10)
        XCTAssertEqual(page.entries.map(\.cursor), [1, 2, 3].map { try! TestIDs.cursor(Int64($0)) })
        XCTAssertEqual(page.nextCursor, try TestIDs.cursor(3))
        XCTAssertFalse(page.hasMore)
        XCTAssertTrue(page.entries.allSatisfy { $0.originDeviceID == device })

        let applied = try await reopened.applyUncheckedBatchForTesting(
            RemoteChangeBatch(peerDeviceID: peer, through: try TestIDs.cursor(2), records: [])
        )
        XCTAssertEqual(applied.cursor, try TestIDs.cursor(2))
        await XCTAssertEqualAsync({ try await reopened.appliedCursor(for: peer) }, try TestIDs.cursor(2))
        await reopened.close()

        let third = try database.makeStore(deviceID: device, clock: clock)
        await XCTAssertEqualAsync({ try await third.appliedCursor(for: peer) }, try TestIDs.cursor(2))

        let replayed = try await third.applyUncheckedBatchForTesting(
            RemoteChangeBatch(peerDeviceID: peer, through: try TestIDs.cursor(2), records: [])
        )
        XCTAssertEqual(replayed.cursor, try TestIDs.cursor(2))
        await XCTAssertThrowsSyncError(
            .cursorRegression(peer, current: try TestIDs.cursor(2), received: try TestIDs.cursor(1))
        ) {
            try await third.applyUncheckedBatchForTesting(
                RemoteChangeBatch(peerDeviceID: peer, through: try TestIDs.cursor(1), records: [])
            )
        }

        await XCTAssertThrowsSyncError(
            .cursorAhead(current: try TestIDs.cursor(3), received: try TestIDs.cursor(4))
        ) {
            try await third.changes(after: try TestIDs.cursor(4))
        }

        let pruned = try await third.pruneChanges(through: try TestIDs.cursor(2))
        XCTAssertEqual(pruned.removed, 2)
        XCTAssertEqual(pruned.prunedThrough, try TestIDs.cursor(2))
        await XCTAssertThrowsSyncError(
            .cursorExpired(try TestIDs.cursor(1), retainedFrom: try TestIDs.cursor(2))
        ) {
            try await third.changes(after: try TestIDs.cursor(1))
        }
        let remaining = try await third.changes(after: try TestIDs.cursor(2))
        XCTAssertEqual(remaining.entries.map(\.cursor), [try TestIDs.cursor(3)])
        let noOp = try await third.pruneChanges(through: try TestIDs.cursor(1))
        XCTAssertEqual(noOp.removed, 0)
        XCTAssertEqual(noOp.prunedThrough, try TestIDs.cursor(2))
        let metadata = try await third.metadata()
        XCTAssertEqual(metadata.prunedThrough, try TestIDs.cursor(2))

        let allPruned = try await third.pruneChanges(through: try TestIDs.cursor(3))
        XCTAssertEqual(allPruned.removed, 1)
        await XCTAssertEqualAsync({ try await third.latestChangeCursor() }, try TestIDs.cursor(3))
        let empty = try await third.changes(after: try TestIDs.cursor(3))
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(empty.nextCursor, try TestIDs.cursor(3))
        await XCTAssertThrowsSyncError(
            .cursorAhead(current: try TestIDs.cursor(3), received: try TestIDs.cursor(9))
        ) {
            try await third.pruneChanges(through: try TestIDs.cursor(9))
        }
        await third.close()
    }

    func testRemoteBatchRollsBackWhenALaterRecordFails() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let peer = try TestIDs.device(2)
        let task = try TestIDs.task(3)
        let store = try database.makeStore(deviceID: device)

        let valid = try SyncRecord.test(
            entityID: try TestIDs.entity(400),
            revision: 1,
            originDeviceID: peer,
            taskID: task,
            payload: .object(["title": .string("valid")])
        )
        let invalid = try SyncRecord.test(
            entityID: try TestIDs.entity(401),
            revision: 1,
            originDeviceID: peer,
            taskID: task,
            payload: .object(["rootPath": .string("/Users/alice/project")])
        )
        await XCTAssertThrowsSyncError(.nonPortableField("rootPath")) {
            try await store.applyUncheckedBatchForTesting(
                RemoteChangeBatch(
                    peerDeviceID: peer,
                    through: try TestIDs.cursor(3),
                    records: [valid, invalid]
                )
            )
        }
        let validAfterRollback = try await store.storedRecord(
            kind: .task,
            entityID: valid.entityID
        )
        XCTAssertNil(validAfterRollback)
        await XCTAssertEqualAsync({ try await store.appliedCursor(for: peer) }, .zero)
        await XCTAssertEqualAsync({ try await store.latestChangeCursor() }, .zero)

        let applied = try await store.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: peer,
                through: try TestIDs.cursor(3),
                records: [valid]
            )
        )
        XCTAssertEqual(applied.applied.count, 1)
        XCTAssertEqual(applied.conflicts, [])
        await XCTAssertEqualAsync({ try await store.appliedCursor(for: peer) }, try TestIDs.cursor(3))
        await XCTAssertEqualAsync({ try await store.latestChangeCursor() }, try TestIDs.cursor(1))

        let delayed = try SyncRecord.test(
            entityID: try TestIDs.entity(402),
            revision: 1,
            originDeviceID: peer,
            taskID: task
        )
        await XCTAssertThrowsSyncError(
            .cursorRegression(peer, current: try TestIDs.cursor(3), received: try TestIDs.cursor(2))
        ) {
            try await store.applyUncheckedBatchForTesting(
                RemoteChangeBatch(
                    peerDeviceID: peer,
                    through: try TestIDs.cursor(2),
                    records: [delayed]
                )
            )
        }
        let delayedAfterRollback = try await store.storedRecord(
            kind: .task,
            entityID: delayed.entityID
        )
        XCTAssertNil(delayedAfterRollback)
        await XCTAssertEqualAsync({ try await store.appliedCursor(for: peer) }, try TestIDs.cursor(3))
        await store.close()
    }

    func testRemoteBatchPreservesUnsyncedLocalEditsAndConvergesAfterAck() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let peer = try TestIDs.device(2)
        let task = try TestIDs.task(3)
        let store = try database.makeStore(deviceID: device)
        let entityID = try TestIDs.entity(600)

        _ = try await store.commitLocalRecord(
            try SyncRecord.test(
                entityID: entityID,
                revision: 1,
                originDeviceID: device,
                taskID: task,
                payload: .object(["title": .string("local-edit")])
            )
        )

        let localBaseline = JSONValue.object(["title": .string("local-edit")])
        let remoteRevisionTwo = try SyncRecord.test(
            entityID: entityID,
            revision: 2,
            baseRevision: 1,
            baseDigest: ContentDigest.compute(localBaseline.canonicalUTF8),
            originDeviceID: peer,
            taskID: task,
            payload: .object(["title": .string("remote-edit")])
        )
        let firstApply = try await store.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: peer,
                through: try TestIDs.cursor(1),
                records: [remoteRevisionTwo]
            )
        )
        XCTAssertEqual(firstApply.applied, [])
        XCTAssertEqual(firstApply.conflicts.count, 1)
        XCTAssertEqual(firstApply.conflicts.first?.reason, .localUnsyncedEdit)
        XCTAssertEqual(firstApply.conflicts.first?.localRevision, try TestIDs.revision(1))
        XCTAssertEqual(firstApply.conflicts.first?.incomingRevision, try TestIDs.revision(2))
        await XCTAssertEqualAsync({ try await store.latestChangeCursor() }, try TestIDs.cursor(1))

        let preserved = try await store.storedRecord(kind: .task, entityID: entityID)
        XCTAssertEqual(preserved?.record.payload["title"]?.stringValue, "local-edit")
        XCTAssertEqual(preserved?.record.revision, try TestIDs.revision(1))
        XCTAssertEqual(preserved?.localDirty, true)

        let other = try SyncRecord.test(
            entityID: try TestIDs.entity(601),
            revision: 1,
            originDeviceID: peer,
            taskID: task
        )
        let secondApply = try await store.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: peer,
                through: try TestIDs.cursor(2),
                records: [remoteRevisionTwo, other]
            )
        )
        XCTAssertEqual(secondApply.applied.map(\.entityID), [other.entityID])
        XCTAssertEqual(secondApply.conflicts.count, 1)
        await XCTAssertEqualAsync({ try await store.latestChangeCursor() }, try TestIDs.cursor(2))

        let acknowledged = try await store.acknowledgeLocalRecord(
            kind: .task,
            entityID: entityID,
            revision: try TestIDs.revision(1)
        )
        XCTAssertTrue(acknowledged)
        let afterAck = try await store.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: peer,
                through: try TestIDs.cursor(3),
                records: [remoteRevisionTwo]
            )
        )
        XCTAssertEqual(afterAck.applied.map(\.entityID), [entityID])
        XCTAssertEqual(afterAck.conflicts, [])
        let converged = try await store.storedRecord(kind: .task, entityID: entityID)
        XCTAssertEqual(converged?.record.payload["title"]?.stringValue, "remote-edit")
        XCTAssertEqual(converged?.record.revision, try TestIDs.revision(2))
        XCTAssertEqual(converged?.localDirty, false)
        await XCTAssertEqualAsync({ try await store.latestChangeCursor() }, try TestIDs.cursor(3))
        await store.close()
    }

    func testDeletedRecordIsNotResurrectedByAnOlderSnapshotRevision() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let peer = try TestIDs.device(2)
        let task = try TestIDs.task(3)
        let store = try database.makeStore(deviceID: device)
        let entityID = try TestIDs.entity(700)

        _ = try await store.commitLocalRecord(
            try SyncRecord.test(
                entityID: entityID,
                revision: 1,
                originDeviceID: device,
                taskID: task
            )
        )
        _ = try await store.commitLocalRecord(
            try SyncRecord.test(
                entityID: entityID,
                revision: 2,
                originDeviceID: device,
                taskID: task,
                payload: .null,
                deleted: true
            )
        )
        let beforeApply = try await store.openSnapshot()
        XCTAssertEqual(beforeApply.recordCount, 0)

        let staleUpsert = try SyncRecord.test(
            entityID: entityID,
            revision: 1,
            originDeviceID: peer,
            taskID: task,
            payload: .object(["title": .string("old")])
        )
        let applied = try await store.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: peer,
                through: try TestIDs.cursor(1),
                records: [staleUpsert]
            )
        )
        XCTAssertEqual(applied.applied, [])
        XCTAssertEqual(applied.conflicts.first?.reason, .staleRemoteRevision)

        let stored = try await store.storedRecord(kind: .task, entityID: entityID)
        XCTAssertEqual(stored?.record.deleted, true)
        XCTAssertEqual(stored?.record.revision, try TestIDs.revision(2))
        let afterApply = try await store.openSnapshot()
        XCTAssertEqual(afterApply.recordCount, 0)

        let changes = try await store.changes(after: .zero, limit: 10)
        XCTAssertEqual(changes.entries.map(\.changeType), [.upsert, .delete])
        await store.close()
    }


    func testExpiredCursorCanRebuildSnapshotWithoutLosingLocalEdit() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let store = try database.makeStore(deviceID: device)

        for offset in 0..<5 {
            _ = try await store.commitLocalRecord(
                try SyncRecord.test(
                    entityID: try TestIDs.entity(800 + offset),
                    revision: 1,
                    originDeviceID: device,
                    taskID: task
                )
            )
        }
        _ = try await store.pruneChanges(through: try TestIDs.cursor(5))
        await XCTAssertThrowsSyncError(
            .cursorExpired(.zero, retainedFrom: try TestIDs.cursor(5))
        ) {
            try await store.changes(after: .zero)
        }

        let localEditID = try TestIDs.entity(900)
        _ = try await store.commitLocalRecord(
            try SyncRecord.test(
                entityID: localEditID,
                revision: 1,
                originDeviceID: device,
                taskID: task,
                payload: .object(["title": .string("offline-edit")])
            )
        )
        let snapshot = try await store.openSnapshot()
        XCTAssertEqual(snapshot.recordCount, 6)
        let page = try await store.snapshotPage(
            snapshot.snapshotID,
            after: nil,
            limit: 10
        )
        XCTAssertTrue(page.records.contains { $0.entityID == localEditID })
        let local = try await store.storedRecord(kind: .task, entityID: localEditID)
        XCTAssertEqual(local?.localDirty, true)
        let changes = try await store.changes(after: try TestIDs.cursor(5))
        XCTAssertEqual(changes.entries.map(\.cursor), [try TestIDs.cursor(6)])
        await store.close()
    }
}
