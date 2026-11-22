import Foundation
import XCTest
@testable import FloeDesktopSync

final class ConflictAndCausalityTests: XCTestCase {
    func testRefusedRemoteVersionPersistsBothPayloadsAcrossRestart() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let peer = try TestIDs.device(2)
        let task = try TestIDs.task(3)
        let entityID = try TestIDs.entity(100)

        var store: SyncStore? = try database.makeStore(deviceID: device)
        _ = try await store!.commitLocalRecord(
            try SyncRecord.test(
                entityID: entityID,
                revision: 1,
                originDeviceID: device,
                taskID: task,
                payload: .object(["title": .string("local-edit")])
            )
        )
        let localBaseline = JSONValue.object(["title": .string("local-edit")])
        let incoming = try SyncRecord.test(
            entityID: entityID,
            revision: 2,
            baseRevision: 1,
            baseDigest: ContentDigest.compute(localBaseline.canonicalUTF8),
            originDeviceID: peer,
            taskID: task,
            payload: .object(["title": .string("remote-edit")])
        )
        let applied = try await store!.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: peer,
                through: try TestIDs.cursor(7),
                records: [incoming]
            )
        )
        XCTAssertEqual(applied.applied, [])
        XCTAssertEqual(applied.conflicts.count, 1)
        XCTAssertEqual(applied.conflicts.first?.reason, .localUnsyncedEdit)
        XCTAssertNotNil(applied.conflicts.first?.conflictID)
        XCTAssertEqual(applied.cursor, try TestIDs.cursor(7))
        await XCTAssertEqualAsync(
            { try await store!.appliedCursor(for: peer) },
            try TestIDs.cursor(7)
        )
        // The refused version must remain recoverable even after the local
        // change log that preceded it is pruned.
        _ = try await store!.pruneChanges(through: try TestIDs.cursor(1))
        await store!.close()
        store = nil

        let reopened = try database.makeStore(deviceID: device)
        let persisted = try await reopened.conflicts()
        XCTAssertEqual(persisted.count, 1)
        let conflict = try XCTUnwrap(persisted.first)
        XCTAssertEqual(conflict.peerDeviceID, peer)
        XCTAssertEqual(conflict.reason, .localUnsyncedEdit)
        XCTAssertEqual(conflict.status, .open)
        XCTAssertEqual(conflict.observedCursor, try TestIDs.cursor(7))
        XCTAssertEqual(conflict.local.payload["title"]?.stringValue, "local-edit")
        XCTAssertEqual(conflict.local.revision, try TestIDs.revision(1))
        XCTAssertEqual(conflict.incoming.payload["title"]?.stringValue, "remote-edit")
        XCTAssertEqual(conflict.incoming.revision, try TestIDs.revision(2))
        let local = try await reopened.storedRecord(kind: .task, entityID: entityID)
        XCTAssertEqual(local?.record.payload["title"]?.stringValue, "local-edit")
        XCTAssertEqual(local?.localDirty, true)
        let appliedCursor = try await reopened.appliedCursor(for: peer)
        XCTAssertEqual(appliedCursor, try TestIDs.cursor(7))

        let resolved = try await reopened.resolveConflict(
            conflict.conflictID,
            resolution: .acceptRemote
        )
        XCTAssertEqual(resolved.status, .resolved)
        XCTAssertEqual(resolved.resolution, .acceptRemote)
        let converged = try await reopened.storedRecord(kind: .task, entityID: entityID)
        XCTAssertEqual(converged?.record.payload["title"]?.stringValue, "remote-edit")
        XCTAssertEqual(converged?.record.revision, try TestIDs.revision(2))
        XCTAssertEqual(converged?.localDirty, false)
        let openConflicts = try await reopened.conflicts(openOnly: true)
        XCTAssertEqual(openConflicts, [])
        await reopened.close()
    }

    func testMissingBaseRevisionIsRefusedInsteadOfOverwriting() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let peer = try TestIDs.device(2)
        let task = try TestIDs.task(3)
        let entityID = try TestIDs.entity(101)
        let store = try database.makeStore(deviceID: device)

        _ = try await store.commitLocalRecord(
            try SyncRecord.test(
                entityID: entityID,
                revision: 1,
                originDeviceID: device,
                taskID: task,
                payload: .object(["title": .string("local")])
            )
        )
        _ = try await store.acknowledgeLocalRecord(
            kind: .task,
            entityID: entityID,
            revision: try TestIDs.revision(1)
        )
        let incoming = try SyncRecord.test(
            entityID: entityID,
            revision: 2,
            originDeviceID: peer,
            taskID: task,
            payload: .object(["title": .string("unbased")])
        )
        let result = try await store.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: peer,
                through: try TestIDs.cursor(1),
                records: [incoming]
            )
        )
        XCTAssertEqual(result.applied, [])
        XCTAssertEqual(result.conflicts.first?.reason, .missingBaseRevision)
        let stored = try await store.storedRecord(kind: .task, entityID: entityID)
        XCTAssertEqual(stored?.record.payload["title"]?.stringValue, "local")
        XCTAssertEqual(stored?.record.revision, try TestIDs.revision(1))
        let openConflicts = try await store.conflicts()
        XCTAssertEqual(openConflicts.count, 1)
        await store.close()
    }

    func testThreeDeviceOldBaselineBranchesStayPersistedAndDoNotOverwrite() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let receiverDevice = try TestIDs.device(1)
        let deviceA = try TestIDs.device(2)
        let deviceB = try TestIDs.device(3)
        let task = try TestIDs.task(4)
        let entityID = try TestIDs.entity(200)
        let peerA = try TestIDs.device(10)
        let peerB = try TestIDs.device(11)

        var store: SyncStore? = try database.makeStore(deviceID: receiverDevice)
        _ = try await store!.commitLocalRecord(
            try SyncRecord.test(
                entityID: entityID,
                revision: 1,
                originDeviceID: receiverDevice,
                taskID: task,
                payload: .object(["title": .string("baseline")])
            )
        )
        _ = try await store!.acknowledgeLocalRecord(
            kind: .task,
            entityID: entityID,
            revision: try TestIDs.revision(1)
        )
        let baseline = JSONValue.object(["title": .string("baseline")])
        let baselineDigest = ContentDigest.compute(baseline.canonicalUTF8)
        let aTwo = try SyncRecord.test(
            entityID: entityID,
            revision: 2,
            baseRevision: 1,
            baseDigest: baselineDigest,
            originDeviceID: deviceA,
            taskID: task,
            payload: .object(["title": .string("A2")])
        )
        let appliedA = try await store!.applyUncheckedBatchForTesting(
            RemoteChangeBatch(peerDeviceID: peerA, through: try TestIDs.cursor(1), records: [aTwo])
        )
        XCTAssertEqual(appliedA.applied.count, 1)
        let cursorAfterA = try await store!.latestChangeCursor()
        XCTAssertEqual(cursorAfterA, try TestIDs.cursor(2))

        let bThree = try SyncRecord.test(
            entityID: entityID,
            revision: 3,
            baseRevision: 1,
            baseDigest: baselineDigest,
            originDeviceID: deviceB,
            taskID: task,
            payload: .object(["title": .string("B3")])
        )
        let refusedThree = try await store!.applyUncheckedBatchForTesting(
            RemoteChangeBatch(peerDeviceID: peerB, through: try TestIDs.cursor(2), records: [bThree])
        )
        XCTAssertEqual(refusedThree.applied, [])
        XCTAssertEqual(refusedThree.conflicts.first?.reason, .concurrentDivergence)

        let bFour = try SyncRecord.test(
            entityID: entityID,
            revision: 4,
            baseRevision: 1,
            baseDigest: baselineDigest,
            originDeviceID: deviceB,
            taskID: task,
            payload: .object(["title": .string("B4")])
        )
        let refusedFour = try await store!.applyUncheckedBatchForTesting(
            RemoteChangeBatch(peerDeviceID: peerB, through: try TestIDs.cursor(3), records: [bFour])
        )
        XCTAssertEqual(refusedFour.applied, [])
        XCTAssertEqual(refusedFour.conflicts.first?.reason, .concurrentDivergence)
        let stillA = try await store!.storedRecord(kind: .task, entityID: entityID)
        XCTAssertEqual(stillA?.record.payload["title"]?.stringValue, "A2")
        XCTAssertEqual(stillA?.record.revision, try TestIDs.revision(2))
        await store!.close()
        store = nil

        let reopened = try database.makeStore(deviceID: receiverDevice)
        let conflicts = try await reopened.conflicts()
        XCTAssertEqual(conflicts.count, 2)
        XCTAssertEqual(
            Set(conflicts.map { $0.incoming.payload["title"]?.stringValue ?? "" }),
            ["B3", "B4"]
        )
        let stillA2 = try await reopened.storedRecord(kind: .task, entityID: entityID)
        XCTAssertEqual(stillA2?.record.payload["title"]?.stringValue, "A2")

        let latest = try XCTUnwrap(
            conflicts.first { $0.incoming.payload["title"]?.stringValue == "B4" }
        )
        let stale = try XCTUnwrap(
            conflicts.first { $0.incoming.payload["title"]?.stringValue == "B3" }
        )
        _ = try await reopened.resolveConflict(latest.conflictID, resolution: .acceptRemote)
        let converged = try await reopened.storedRecord(kind: .task, entityID: entityID)
        XCTAssertEqual(converged?.record.payload["title"]?.stringValue, "B4")
        await XCTAssertThrowsSyncError(.conflictStale(stale.conflictID)) {
            _ = try await reopened.resolveConflict(stale.conflictID, resolution: .acceptRemote)
        }
        let kept = try await reopened.resolveConflict(stale.conflictID, resolution: .keepLocal)
        XCTAssertEqual(kept.status, .resolved)
        XCTAssertEqual(kept.resolution, .keepLocal)
        await reopened.close()
    }

    func testExecutionStartBindsTaskOwnerEpochAndAuthenticatedDevice() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let otherDevice = try TestIDs.device(2)
        let task = try TestIDs.task(3)
        let otherTask = try TestIDs.task(4)
        let run = try TestIDs.run(5)
        let store = try database.makeStore(deviceID: device)

        _ = try await store.establishExecutionHead(
            runID: run,
            taskID: task,
            epoch: try TestIDs.epoch(1),
            ownerDeviceID: otherDevice
        )
        let epochOne = SyncCommand(
            commandID: try TestIDs.command(10),
            kind: .runStop,
            taskID: task,
            runID: run,
            executionEpoch: try TestIDs.epoch(1),
            payload: .object([:])
        )
        _ = try await store.accept(epochOne)
        await XCTAssertThrowsSyncError(
            .executionOwnerMismatch(
                run,
                owner: otherDevice,
                authenticated: device
            )
        ) {
            _ = try await store.markStarted(
                epochOne.commandID,
                authenticatedDeviceID: device
            )
        }

        _ = try await store.establishExecutionHead(
            runID: run,
            taskID: task,
            epoch: try TestIDs.epoch(2),
            ownerDeviceID: device
        )
        await XCTAssertThrowsSyncError(
            .staleExecutionEpoch(run, try TestIDs.epoch(1), current: try TestIDs.epoch(2))
        ) {
            _ = try await store.markStarted(
                epochOne.commandID,
                authenticatedDeviceID: device
            )
        }

        let wrongTask = SyncCommand(
            commandID: try TestIDs.command(11),
            kind: .runStop,
            taskID: otherTask,
            runID: run,
            executionEpoch: try TestIDs.epoch(2),
            payload: .object([:])
        )
        await XCTAssertThrowsSyncError(
            .executionTaskMismatch(run, expected: task, received: otherTask)
        ) {
            _ = try await store.accept(wrongTask)
        }

        let current = SyncCommand(
            commandID: try TestIDs.command(12),
            kind: .runStop,
            taskID: task,
            runID: run,
            executionEpoch: try TestIDs.epoch(2),
            payload: .object([:])
        )
        _ = try await store.accept(current)
        await XCTAssertThrowsSyncError(
            .executionPrincipalMismatch(expected: device, authenticated: otherDevice)
        ) {
            _ = try await store.markStarted(
                current.commandID,
                authenticatedDeviceID: otherDevice
            )
        }
        let started = try await store.markStarted(
            current.commandID,
            authenticatedDeviceID: device
        )
        XCTAssertEqual(started.state, .started)
        await store.close()
    }

    func testExpectedRevisionIsCheckedAtExecutionStartInTheStartTransaction() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let entityID = try TestIDs.entity(3)
        let key = RecordKey(kind: .task, entityID: entityID)
        let store = try database.makeStore(deviceID: device)

        _ = try await store.commitLocalRecord(
            try SyncRecord.test(
                entityID: entityID,
                revision: 2,
                originDeviceID: device,
                taskID: task,
                payload: .object(["title": .string("v2")])
            )
        )
        let otherTask = try TestIDs.task(8)
        let otherEntity = try TestIDs.entity(9)
        _ = try await store.commitLocalRecord(
            try SyncRecord.test(
                entityID: otherEntity,
                revision: 1,
                originDeviceID: device,
                taskID: otherTask,
                payload: .object(["title": .string("other-task")])
            )
        )
        let crossTask = SyncCommand(
            commandID: try TestIDs.command(22),
            kind: .taskStop,
            taskID: task,
            expectedRevision: try TestIDs.revision(1),
            targetKey: RecordKey(kind: .task, entityID: otherEntity),
            payload: .object([:])
        )
        _ = try await store.accept(crossTask)
        await XCTAssertThrowsSyncError(
            .targetTaskMismatch(
                RecordKey(kind: .task, entityID: otherEntity),
                expected: task,
                found: otherTask
            )
        ) {
            _ = try await store.markStarted(
                crossTask.commandID,
                authenticatedDeviceID: device
            )
        }

        let staleExpectation = SyncCommand(
            commandID: try TestIDs.command(20),
            kind: .taskStop,
            taskID: task,
            expectedRevision: try TestIDs.revision(1),
            targetKey: key,
            payload: .object([:])
        )
        _ = try await store.accept(staleExpectation)
        await XCTAssertThrowsSyncError(
            .expectedRevisionMismatch(
                key,
                expected: try TestIDs.revision(1),
                current: try TestIDs.revision(2)
            )
        ) {
            _ = try await store.markStarted(
                staleExpectation.commandID,
                authenticatedDeviceID: device
            )
        }
        let unchanged = try await store.receipt(for: staleExpectation.commandID)
        XCTAssertEqual(unchanged?.state, .accepted)

        let currentExpectation = SyncCommand(
            commandID: try TestIDs.command(21),
            kind: .taskStop,
            taskID: task,
            expectedRevision: try TestIDs.revision(2),
            targetKey: key,
            payload: .object([:])
        )
        _ = try await store.accept(currentExpectation)
        let started = try await store.markStarted(
            currentExpectation.commandID,
            authenticatedDeviceID: device
        )
        XCTAssertEqual(started.state, .started)
        await store.close()
    }

    func testThreeRealStoresKeepConfirmedBranchAndPersistOldBaselineEdits() async throws {
        let databaseA = try TestDatabase()
        let databaseB = try TestDatabase()
        let databaseC = try TestDatabase()
        addTeardownBlock {
            databaseA.remove()
            databaseB.remove()
            databaseC.remove()
        }
        let deviceA = try TestIDs.device(1)
        let deviceB = try TestIDs.device(2)
        let deviceC = try TestIDs.device(3)
        let task = try TestIDs.task(4)
        let entityID = try TestIDs.entity(500)
        let a = try databaseA.makeStore(deviceID: deviceA)
        let b = try databaseB.makeStore(deviceID: deviceB)
        let c = try databaseC.makeStore(deviceID: deviceC)

        _ = try await a.commitLocalRecord(
            try SyncRecord.test(
                entityID: entityID,
                revision: 1,
                originDeviceID: deviceA,
                taskID: task,
                payload: .object(["title": .string("baseline")])
            )
        )
        let baselineRecord = try await a.storedRecord(kind: .task, entityID: entityID)
        let baseline = try XCTUnwrap(baselineRecord).record
        _ = try await a.commitLocalRecord(
            try SyncRecord.test(
                entityID: entityID,
                revision: 2,
                originDeviceID: deviceA,
                taskID: task,
                payload: .object(["title": .string("A2")])
            )
        )
        let aTwoRecord = try await a.storedRecord(kind: .task, entityID: entityID)
        let aTwo = try XCTUnwrap(aTwoRecord).record

        _ = try await b.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: deviceA,
                through: try TestIDs.cursor(1),
                records: [baseline]
            )
        )
        _ = try await b.commitLocalRecord(
            try SyncRecord.test(
                entityID: entityID,
                revision: 3,
                originDeviceID: deviceB,
                taskID: task,
                payload: .object(["title": .string("B3")])
            )
        )
        let bThreeRecord = try await b.storedRecord(kind: .task, entityID: entityID)
        let bThree = try XCTUnwrap(bThreeRecord).record
        _ = try await b.commitLocalRecord(
            try SyncRecord.test(
                entityID: entityID,
                revision: 4,
                originDeviceID: deviceB,
                taskID: task,
                payload: .object(["title": .string("B4")])
            )
        )
        let bFourRecord = try await b.storedRecord(kind: .task, entityID: entityID)
        let bFour = try XCTUnwrap(bFourRecord).record
        XCTAssertEqual(bFour.baseRevision, try TestIDs.revision(3))

        _ = try await c.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: deviceA,
                through: try TestIDs.cursor(1),
                records: [baseline]
            )
        )
        let appliedA = try await c.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: deviceA,
                through: try TestIDs.cursor(2),
                records: [aTwo]
            )
        )
        XCTAssertEqual(appliedA.applied.count, 1)
        let refusedThree = try await c.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: deviceB,
                through: try TestIDs.cursor(2),
                records: [bThree]
            )
        )
        XCTAssertEqual(refusedThree.conflicts.first?.reason, .concurrentDivergence)
        let refusedFour = try await c.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: deviceB,
                through: try TestIDs.cursor(3),
                records: [bFour]
            )
        )
        XCTAssertEqual(refusedFour.conflicts.first?.reason, .concurrentDivergence)
        let confirmed = try await c.storedRecord(kind: .task, entityID: entityID)
        XCTAssertEqual(confirmed?.record.payload["title"]?.stringValue, "A2")
        XCTAssertEqual(confirmed?.record.revision, try TestIDs.revision(2))

        await c.close()
        let reopenedC = try databaseC.makeStore(deviceID: deviceC)
        let conflicts = try await reopenedC.conflicts()
        XCTAssertEqual(conflicts.count, 2)
        let latest = try XCTUnwrap(
            conflicts.first { $0.incoming.payload["title"]?.stringValue == "B4" }
        )
        _ = try await reopenedC.resolveConflict(latest.conflictID, resolution: .acceptRemote)
        let resolved = try await reopenedC.storedRecord(kind: .task, entityID: entityID)
        XCTAssertEqual(resolved?.record.payload["title"]?.stringValue, "B4")
        await reopenedC.close()
        await a.close()
        await b.close()
    }

    func testSnapshotTombstonesReconcileNonEmptyTargetAndProtectDirtyLocalData() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        let dirtyDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
            dirtyDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(1)
        let receiverDevice = try TestIDs.device(2)
        let task = try TestIDs.task(3)
        let otherTask = try TestIDs.task(4)
        let source = try sourceDatabase.makeStore(deviceID: sourceDevice)

        let x = try TestIDs.entity(300)
        let y = try TestIDs.entity(301)
        let z = try TestIDs.entity(302)
        let other = try TestIDs.entity(303)
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(entityID: x, revision: 1, originDeviceID: sourceDevice, taskID: task)
        )
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(entityID: y, revision: 1, originDeviceID: sourceDevice, taskID: task)
        )
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(entityID: z, revision: 1, originDeviceID: sourceDevice, taskID: task)
        )
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(entityID: x, revision: 2, baseRevision: 1, originDeviceID: sourceDevice, taskID: task, payload: .null, deleted: true)
        )
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(entityID: other, revision: 1, originDeviceID: sourceDevice, taskID: otherTask)
        )

        let snapshot = try await source.openSnapshot(scope: .task(task))
        XCTAssertEqual(snapshot.recordCount, 2)
        XCTAssertEqual(snapshot.tombstoneCount, 1)
        XCTAssertEqual(snapshot.scope, .task(task))
        var records: [SyncRecord] = []
        var token: SnapshotPageToken?
        repeat {
            let page = try await source.snapshotPage(
                snapshot.snapshotID,
                after: token,
                limit: 10
            )
            records.append(contentsOf: page.records)
            token = page.nextToken
        } while token != nil
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records.allSatisfy { $0.taskID == task })
        XCTAssertFalse(records.contains { $0.entityID == other })

        let receiver = try receiverDatabase.makeStore(deviceID: receiverDevice)
        _ = try await receiver.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: sourceDevice,
                through: try TestIDs.cursor(2),
                records: [
                    try SyncRecord.test(entityID: x, revision: 1, originDeviceID: sourceDevice, taskID: task),
                    try SyncRecord.test(entityID: y, revision: 1, originDeviceID: sourceDevice, taskID: task)
                ]
            )
        )
        _ = try await receiver.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(999),
                revision: 1,
                originDeviceID: receiverDevice,
                taskID: task,
                payload: .object(["title": .string("local-only")])
            )
        )
        for record in records {
            _ = try await receiver.applyUncheckedBatchForTesting(RemoteChangeBatch(
                peerDeviceID: sourceDevice, through: try TestIDs.cursor(2), records: [record]
            ))
        }
        let deleted = try await receiver.storedRecord(kind: .task, entityID: x)
        XCTAssertEqual(deleted?.record.deleted, true)
        XCTAssertEqual(deleted?.record.revision, try TestIDs.revision(2))
        let storedY = try await receiver.storedRecord(kind: .task, entityID: y)
        let storedZ = try await receiver.storedRecord(kind: .task, entityID: z)
        let storedLocal = try await receiver.storedRecord(
            kind: .task,
            entityID: try TestIDs.entity(999)
        )
        XCTAssertEqual(storedY?.record.deleted, false)
        XCTAssertEqual(storedZ?.record.deleted, false)
        XCTAssertEqual(storedLocal?.record.payload["title"]?.stringValue, "local-only")

        let dirty = try dirtyDatabase.makeStore(deviceID: receiverDevice)
        _ = try await dirty.commitLocalRecord(
            try SyncRecord.test(
                entityID: x,
                revision: 1,
                originDeviceID: receiverDevice,
                taskID: task,
                payload: .object(["title": .string("dirty-local")])
            )
        )
        for record in records where record.entityID == x {
            _ = try await dirty.applyUncheckedBatchForTesting(RemoteChangeBatch(
                peerDeviceID: sourceDevice, through: .zero, records: [record]
            ))
        }
        let preserved = try await dirty.storedRecord(kind: .task, entityID: x)
        XCTAssertEqual(preserved?.record.payload["title"]?.stringValue, "dirty-local")
        XCTAssertEqual(preserved?.record.deleted, false)
        XCTAssertEqual(preserved?.localDirty, true)
        let persistedConflicts = try await dirty.conflicts()
        XCTAssertEqual(persistedConflicts.count, 1)
        XCTAssertEqual(persistedConflicts.first?.reason, .localUnsyncedEdit)
        XCTAssertEqual(persistedConflicts.first?.incoming.deleted, true)

        await source.close()
        await receiver.close()
        await dirty.close()
    }
}
