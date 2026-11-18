import Foundation
import XCTest
@testable import FloeDesktopSync

final class SafetyRegressionTests: XCTestCase {
    func testConflictsRetainDistinctFullRecordsAcrossRestart() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let peer = try TestIDs.device(2)
        let otherOrigin = try TestIDs.device(3)
        let task = try TestIDs.task(4)
        let entity = try TestIDs.entity(6)
        let payload: JSONValue = .object(["title": .string("remote")])
        let store = try database.makeStore(deviceID: device)
        _ = try await store.commitLocalRecord(try .test(entityID: entity, revision: 2,
            originDeviceID: device, taskID: task, payload: .object(["title": .string("local")])))
        let versions = [
            try SyncRecord.test(entityID: entity, revision: 3, baseRevision: 1,
                originDeviceID: peer, taskID: task, payload: payload),
            try SyncRecord.test(entityID: entity, revision: 3, baseRevision: 1,
                originDeviceID: peer, taskID: task, payload: payload, deleted: true),
            try SyncRecord.test(entityID: entity, revision: 3, baseRevision: 2,
                originDeviceID: otherOrigin, taskID: task, payload: payload)
        ]
        for (index, version) in versions.enumerated() {
            _ = try await store.applyUncheckedBatchForTesting(RemoteChangeBatch(peerDeviceID: peer,
                through: try TestIDs.cursor(Int64(index + 1)), records: [version]))
        }
        await store.close()
        let reopened = try database.makeStore(deviceID: device)
        let conflicts = try await reopened.conflicts()
        XCTAssertEqual(conflicts.count, 3)
        for version in versions {
            XCTAssertTrue(conflicts.contains { $0.incoming == version })
        }
        await reopened.close()
    }

    func testResolvingSameRevisionChangesRevisionAndInvalidatesOtherConflictAndCommand() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(10)
        let peer = try TestIDs.device(11)
        let task = try TestIDs.task(12)
        let entity = try TestIDs.entity(13)
        let store = try database.makeStore(deviceID: device)
        let payload: JSONValue = .object(["title": .string("current")])
        _ = try await store.commitLocalRecord(try .test(entityID: entity, revision: 2,
            originDeviceID: device, taskID: task, payload: payload))
        let tombstone = try SyncRecord.test(entityID: entity, revision: 2,
            originDeviceID: peer, taskID: task, payload: payload, deleted: true)
        let later = try SyncRecord.test(entityID: entity, revision: 3,
            originDeviceID: peer, taskID: task, payload: .object(["title": .string("later")]))
        let a = try await store.applyUncheckedBatchForTesting(RemoteChangeBatch(peerDeviceID: peer,
            through: try TestIDs.cursor(1), records: [tombstone]))
        let b = try await store.applyUncheckedBatchForTesting(RemoteChangeBatch(peerDeviceID: peer,
            through: try TestIDs.cursor(2), records: [later]))
        let first = try XCTUnwrap(a.conflicts.first?.conflictID)
        let second = try XCTUnwrap(b.conflicts.first?.conflictID)
        let command = SyncCommand(commandID: try TestIDs.command(14), kind: .taskStop,
            taskID: task, expectedRevision: try TestIDs.revision(2),
            targetKey: RecordKey(kind: .task, entityID: entity), payload: .object([:]))
        _ = try await store.accept(command)
        _ = try await store.resolveConflict(first, resolution: .acceptRemote)
        let resolved = try await store.storedRecord(kind: .task, entityID: entity)
        XCTAssertEqual(resolved?.record.deleted, true)
        XCTAssertNotEqual(resolved?.record.revision, try TestIDs.revision(2))
        await XCTAssertThrowsSyncError(.conflictStale(second)) {
            _ = try await store.resolveConflict(second, resolution: .acceptRemote)
        }
        await XCTAssertThrowsSyncError(.expectedRevisionMismatch(
            RecordKey(kind: .task, entityID: entity), expected: try TestIDs.revision(2),
            current: resolved?.record.revision)) {
            _ = try await store.markStarted(command.commandID, authenticatedDeviceID: device)
        }
        await store.close()
    }

    func testUnverifiedSnapshotCannotAdvanceGlobalCursor() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(20)
        let peer = try TestIDs.device(21)
        let store = try database.makeStore(deviceID: device)
        await XCTAssertThrowsSyncError(.snapshotImportUnverified) {
            _ = try await store.applySnapshotPage(peerDeviceID: peer, records: [])
        }
        await XCTAssertThrowsSyncError(.snapshotImportUnverified) {
            _ = try await store.commitAppliedCursor(peerDeviceID: peer, through: try TestIDs.cursor(10))
        }
        let cursor = try await store.appliedCursor(for: peer)
        XCTAssertEqual(cursor, .zero)
        await store.close()
    }

    func testLateResultStaysOnOriginalCommandAfterOwnershipChanges() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(30)
        let nextOwner = try TestIDs.device(31)
        let task = try TestIDs.task(32)
        let run = try TestIDs.run(33)
        let store = try database.makeStore(deviceID: device)
        _ = try await store.establishExecutionHead(runID: run, taskID: task,
            epoch: try TestIDs.epoch(1), ownerDeviceID: device)
        let command = SyncCommand(commandID: try TestIDs.command(34), kind: .runStart,
            taskID: task, runID: run, executionEpoch: try TestIDs.epoch(1), payload: .object([:]))
        _ = try await store.accept(command)
        _ = try await store.markStarted(command.commandID, authenticatedDeviceID: device)
        _ = try await store.markOutcomeUnknown(command.commandID)
        _ = try await store.establishExecutionHead(runID: run, taskID: task,
            epoch: try TestIDs.epoch(2), ownerDeviceID: nextOwner)
        let receipt = try await store.complete(command.commandID, result: .object(["result": .string("done")]))
        XCTAssertEqual(receipt.state, .completed)
        let head = try await store.executionHead(for: run)
        XCTAssertEqual(head?.ownerDeviceID, nextOwner)
        XCTAssertEqual(head?.epoch, try TestIDs.epoch(2))
        await store.close()
    }
}
