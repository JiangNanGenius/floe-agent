import Foundation
import XCTest
@testable import FloeDesktopSync

final class RunProjectionTests: XCTestCase {
    private struct Fixture: Sendable {
        let device = DeviceID()
        let task = TaskID()
        let run = RunID()
        let message = EntityID()

        func batch(after: Int64 = 0, through: Int64 = 1, epoch: Int64 = 1,
                   revision: Int64 = 1, text: String = "synthetic response") throws -> LocalRunProjectionBatch {
            let records = try [
                SyncRecord.test(kind: .task, entityID: EntityID(validating: task.canonical),
                                revision: revision, originDeviceID: device, taskID: task,
                                payload: .object(["title": .string("synthetic task")])),
                .test(kind: .run, entityID: EntityID(validating: run.canonical),
                      revision: revision, originDeviceID: device, taskID: task,
                      payload: .object(["state": .string("running")])),
                .test(kind: .message, entityID: message, revision: revision,
                      originDeviceID: device, taskID: task,
                      payload: .object(["text": .string(text)]))
            ]
            return LocalRunProjectionBatch(taskID: task, runID: run, executionEpoch: try ExecutionEpoch(epoch),
                                           afterSequence: after, throughSequence: through, records: records)
        }

        func bind(_ store: SyncStore, owner: DeviceID? = nil, epoch: Int64 = 1) async throws {
            _ = try await store.establishExecutionHead(runID: run, taskID: task,
                                                      epoch: ExecutionEpoch(epoch), ownerDeviceID: owner ?? device)
        }
    }

    func testRecordsAndSourceCheckpointSurviveRestartAndExactReplay() async throws {
        let database = try TestDatabase(), fixture = Fixture()
        addTeardownBlock { database.remove() }
        let store = try database.makeStore(deviceID: fixture.device)
        try await fixture.bind(store)
        let batch = try fixture.batch(through: 3)
        let committed = try await store.applyLocalRunProjection(batch)
        XCTAssertFalse(committed.isDuplicate)
        XCTAssertEqual(committed.checkpoint.sourceSequence, 3)
        XCTAssertEqual(committed.checkpoint.appendedRecords, 3)
        XCTAssertEqual(committed.checkpoint.changeCursor, try ChangeCursor(3))
        await store.close()

        let reopened = try database.makeStore(deviceID: fixture.device)
        let replay = try await reopened.applyLocalRunProjection(batch)
        XCTAssertTrue(replay.isDuplicate)
        XCTAssertEqual(replay.checkpoint, committed.checkpoint)
        await XCTAssertEqualAsync({ try await reopened.recordCount() }, 3)
        await XCTAssertEqualAsync({ try await reopened.latestChangeCursor() }, try ChangeCursor(3))
        await reopened.close()
    }

    func testFailureBeforeCheckpointRollsBackRecordsChangesAndSourcePosition() async throws {
        let database = try TestDatabase(), fixture = Fixture()
        addTeardownBlock { database.remove() }
        let initial = try database.makeStore(deviceID: fixture.device)
        try await fixture.bind(initial)
        let first = try await initial.applyLocalRunProjection(fixture.batch())
        await initial.close()
        let failing = try database.makeStore(deviceID: fixture.device, testHooks: SyncStoreTestHooks(
            beforeRunProjectionCheckpoint: { throw IncrementalTestFailure(label: "projection-before-checkpoint") }
        ))
        do {
            _ = try await failing.applyLocalRunProjection(fixture.batch(after: 1, through: 2, revision: 2,
                                                                       text: "must roll back"))
            XCTFail("Expected injected transaction failure")
        } catch let error as IncrementalTestFailure {
            XCTAssertEqual(error.label, "projection-before-checkpoint")
        }
        await failing.close()
        let reopened = try database.makeStore(deviceID: fixture.device)
        let checkpoint = try await reopened.runProjectionCheckpoint(for: fixture.run)
        XCTAssertEqual(checkpoint, first.checkpoint)
        let message = try await reopened.storedRecord(kind: .message, entityID: fixture.message)
        XCTAssertEqual(message?.record.payload["text"]?.stringValue, "synthetic response")
        XCTAssertEqual(message?.record.revision, try Revision(1))
        await XCTAssertEqualAsync({ try await reopened.latestChangeCursor() }, try ChangeCursor(3))
        await reopened.close()
    }

    func testGapRegressionAndChangedReplayDoNotAdvanceSourcePosition() async throws {
        let database = try TestDatabase(), fixture = Fixture()
        addTeardownBlock { database.remove() }
        let store = try database.makeStore(deviceID: fixture.device)
        try await fixture.bind(store)
        let first = try await store.applyLocalRunProjection(fixture.batch())
        await XCTAssertThrowsSyncError(.runProjectionCursorConflict(fixture.run, expected: 1, received: 2)) {
            try await store.applyLocalRunProjection(fixture.batch(after: 2, through: 3, revision: 2))
        }
        await XCTAssertThrowsSyncError(.runProjectionCursorConflict(fixture.run, expected: 1, received: 0)) {
            try await store.applyLocalRunProjection(fixture.batch(after: 0, through: 2, revision: 2))
        }
        await XCTAssertThrowsSyncError(.runProjectionReplayConflict(fixture.run)) {
            try await store.applyLocalRunProjection(fixture.batch(text: "changed content"))
        }
        let checkpoint = try await store.runProjectionCheckpoint(for: fixture.run)
        XCTAssertEqual(checkpoint, first.checkpoint)
        await XCTAssertEqualAsync({ try await store.latestChangeCursor() }, try ChangeCursor(3))
        await store.close()
    }

    func testExecutionOwnerEpochAndPersistedBindingAreRequired() async throws {
        let database = try TestDatabase(), fixture = Fixture(), other = DeviceID()
        addTeardownBlock { database.remove() }
        let store = try database.makeStore(deviceID: fixture.device)
        await XCTAssertThrowsSyncError(.executionHeadNotEstablished(fixture.run)) {
            try await store.applyLocalRunProjection(fixture.batch())
        }
        try await fixture.bind(store, owner: other)
        await XCTAssertThrowsSyncError(.executionOwnerMismatch(fixture.run, owner: other, authenticated: fixture.device)) {
            try await store.applyLocalRunProjection(fixture.batch())
        }
        try await fixture.bind(store, epoch: 2)
        await XCTAssertThrowsSyncError(.staleExecutionEpoch(fixture.run, try ExecutionEpoch(1), current: try ExecutionEpoch(2))) {
            try await store.applyLocalRunProjection(fixture.batch())
        }
        _ = try await store.applyLocalRunProjection(fixture.batch(epoch: 2))
        try await fixture.bind(store, epoch: 3)
        await XCTAssertThrowsSyncError(.runProjectionBindingMismatch(fixture.run)) {
            try await store.applyLocalRunProjection(fixture.batch(after: 1, through: 2, epoch: 3, revision: 2))
        }
        let checkpoint = try await store.runProjectionCheckpoint(for: fixture.run)
        XCTAssertEqual(checkpoint?.executionEpoch, try ExecutionEpoch(2))
        await store.close()
    }

    func testTaskScopeRunIdentityAndIndependentFamiliesAreChecked() async throws {
        let database = try TestDatabase(), fixture = Fixture(), otherTask = TaskID()
        addTeardownBlock { database.remove() }
        let store = try database.makeStore(deviceID: fixture.device)
        try await fixture.bind(store)
        let foreign = try SyncRecord.test(kind: .message, entityID: EntityID(), revision: 1,
                                         originDeviceID: fixture.device, taskID: otherTask)
        let scopeMismatch = LocalRunProjectionBatch(taskID: fixture.task, runID: fixture.run,
            executionEpoch: try ExecutionEpoch(1), afterSequence: 0, throughSequence: 1, records: [foreign])
        await XCTAssertThrowsSyncError(.targetTaskMismatch(RecordKey(kind: .message, entityID: foreign.entityID),
                                                          expected: fixture.task, found: otherTask)) {
            try await store.applyLocalRunProjection(scopeMismatch)
        }
        let wrongRun = try SyncRecord.test(kind: .run, entityID: EntityID(), revision: 1,
                                          originDeviceID: fixture.device, taskID: fixture.task)
        await XCTAssertThrowsSyncError(.invalidRunProjection("run record identity does not match projection")) {
            try await store.applyLocalRunProjection(LocalRunProjectionBatch(taskID: fixture.task, runID: fixture.run,
                executionEpoch: ExecutionEpoch(1), afterSequence: 0, throughSequence: 1, records: [wrongRun]))
        }
        let schedule = try SyncRecord.test(kind: .schedule, entityID: EntityID(), revision: 1,
                                          originDeviceID: fixture.device, taskID: fixture.task)
        await XCTAssertThrowsSyncError(.invalidRunProjection("record family requires its own source projection")) {
            try await store.applyLocalRunProjection(LocalRunProjectionBatch(taskID: fixture.task, runID: fixture.run,
                executionEpoch: ExecutionEpoch(1), afterSequence: 0, throughSequence: 1, records: [schedule]))
        }
        let checkpoint = try await store.runProjectionCheckpoint(for: fixture.run)
        XCTAssertNil(checkpoint)
        await XCTAssertEqualAsync({ try await store.recordCount() }, 0)
        await store.close()
    }

    func testFilteredRangeAdvancesOnlySourceCursorAndRejectsZeroLengthRange() async throws {
        let database = try TestDatabase(), fixture = Fixture()
        addTeardownBlock { database.remove() }
        let store = try database.makeStore(deviceID: fixture.device)
        try await fixture.bind(store)
        let filtered = LocalRunProjectionBatch(taskID: fixture.task, runID: fixture.run,
            executionEpoch: try ExecutionEpoch(1), afterSequence: 0, throughSequence: 5, records: [])
        let result = try await store.applyLocalRunProjection(filtered)
        XCTAssertEqual(result.checkpoint.sourceSequence, 5)
        XCTAssertEqual(result.checkpoint.changeCursor, .zero)
        XCTAssertEqual(result.checkpoint.appendedRecords, 0)
        await XCTAssertThrowsSyncError(.invalidRunProjection("source range must strictly advance from a nonnegative sequence")) {
            try await store.applyLocalRunProjection(LocalRunProjectionBatch(taskID: fixture.task, runID: fixture.run,
                executionEpoch: ExecutionEpoch(1), afterSequence: 5, throughSequence: 5, records: []))
        }
        let next = try await store.applyLocalRunProjection(fixture.batch(after: 5, through: 6))
        XCTAssertEqual(next.checkpoint.sourceSequence, 6)
        await store.close()
    }

    func testTwoConnectionsReplayingSameProjectionCommitItOnce() async throws {
        let database = try TestDatabase(), fixture = Fixture()
        addTeardownBlock { database.remove() }
        let first = try database.makeStore(deviceID: fixture.device)
        let second = try database.makeStore(deviceID: fixture.device)
        try await fixture.bind(first)
        let batch = try fixture.batch()
        let duplicates = try await withThrowingTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for store in [first, second] {
                group.addTask { try await store.applyLocalRunProjection(batch).isDuplicate }
            }
            var result: [Bool] = []
            for try await value in group { result.append(value) }
            return result
        }
        XCTAssertEqual(duplicates.filter { $0 }.count, 1)
        await XCTAssertEqualAsync({ try await first.recordCount() }, 3)
        await XCTAssertEqualAsync({ try await first.latestChangeCursor() }, try ChangeCursor(3))
        await first.close()
        await second.close()
    }

    func testSourceCheckpointIsNotTransferredWithTaskSnapshot() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase(), fixture = Fixture()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let source = try sourceDB.makeStore(deviceID: fixture.device)
        let receiver = try receiverDB.makeStore(deviceID: DeviceID())
        try await fixture.bind(source)
        _ = try await source.applyLocalRunProjection(fixture.batch())
        // Snapshot storage semantics only; public authentication has separate coverage.
        _ = try await IncrementalFixture.establishSubscription(source: source, receiver: receiver,
            sourceID: fixture.device, scope: .task(fixture.task))
        let localCheckpoint = try await source.runProjectionCheckpoint(for: fixture.run)
        let remoteCheckpoint = try await receiver.runProjectionCheckpoint(for: fixture.run)
        XCTAssertEqual(localCheckpoint?.sourceSequence, 1)
        XCTAssertNil(remoteCheckpoint)
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 3)
        await source.close()
        await receiver.close()
    }

    func testCorruptCheckpointFailsClosedBeforeFurtherWrites() async throws {
        let database = try TestDatabase(), fixture = Fixture()
        addTeardownBlock { database.remove() }
        let initial = try database.makeStore(deviceID: fixture.device)
        try await fixture.bind(initial)
        _ = try await initial.applyLocalRunProjection(fixture.batch())
        await initial.close()
        let raw = try database.rawConnection()
        let statement = try raw.prepare("UPDATE meta SET value = ? WHERE key = ?")
        try statement.bind(1, String(repeating: "x", count: 8_193))
        try statement.bind(2, "local_run_projection.v1/" + fixture.run.canonical)
        _ = try statement.step()
        raw.close()
        let reopened = try database.makeStore(deviceID: fixture.device)
        await XCTAssertThrowsSyncError(.runProjectionCheckpointCorrupt(fixture.run)) {
            try await reopened.applyLocalRunProjection(fixture.batch(after: 1, through: 2, revision: 2))
        }
        await XCTAssertEqualAsync({ try await reopened.latestChangeCursor() }, try ChangeCursor(3))
        let message = try await reopened.storedRecord(kind: .message, entityID: fixture.message)
        XCTAssertEqual(message?.record.revision, try Revision(1))
        await reopened.close()
    }
}
