import Foundation
import XCTest
@testable import FloeDesktopSync

final class LocalTaskBatchTests: XCTestCase {
    private func taskRecords(
        device: DeviceID,
        task: TaskID,
        revision: Int64,
        base: Int64? = nil
    ) throws -> [SyncRecord] {
        let state = revision == 1 ? "running" : "completed"
        let text = revision == 1 ? "starting" : "finished"
        return try [
            .test(kind: .task, entityID: EntityID(validating: task.canonical),
                  revision: revision, baseRevision: base, originDeviceID: device,
                  taskID: task, payload: .object(["title": .string("synthetic task"), "state": .string(state)])),
            .test(kind: .run, entityID: TestIDs.entity(302),
                  revision: revision, baseRevision: base, originDeviceID: device,
                  taskID: task, payload: .object(["state": .string(state)])),
            .test(kind: .message, entityID: TestIDs.entity(303),
                  revision: revision, baseRevision: base, originDeviceID: device,
                  taskID: task, payload: .object(["role": .string("assistant"), "text": .string(text)]))
        ]
    }

    func testTaskRunAndMessageCommitTogetherAndIdenticalRecordsDoNotAppendChanges() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(301), task = try TestIDs.task(304)
        let store = try database.makeStore(deviceID: device)
        let records = try taskRecords(device: device, task: task, revision: 1)
        let outcomes = try await store.commitLocalRecords(records)
        XCTAssertEqual(outcomes, try [1, 2, 3].map { .appended(try ChangeCursor(Int64($0))) })
        let repeated = try await store.commitLocalRecords(records)
        XCTAssertEqual(repeated, [.unchanged, .unchanged, .unchanged])
        await XCTAssertEqualAsync({ try await store.latestChangeCursor() }, try ChangeCursor(3))
        await XCTAssertEqualAsync({ try await store.recordCount() }, 3)
        await store.close()
    }

    func testStaleSecondRecordRollsBackFirstRecordAndItsChange() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(311), task = try TestIDs.task(312)
        let store = try database.makeStore(deviceID: device)
        let existing = try SyncRecord.test(entityID: TestIDs.entity(313), revision: 2,
                                          originDeviceID: device, taskID: task)
        _ = try await store.commitLocalRecord(existing)
        let inserted = try SyncRecord.test(kind: .message, entityID: TestIDs.entity(314), revision: 1,
                                          originDeviceID: device, taskID: task)
        let stale = try SyncRecord.test(entityID: existing.entityID, revision: 1,
                                       originDeviceID: device, taskID: task)
        await XCTAssertThrowsSyncError(.staleLocalRevision(.task, existing.entityID,
                                                          current: try Revision(2), received: try Revision(1))) {
            try await store.commitLocalRecords([inserted, stale])
        }
        let absent = try await store.storedRecord(kind: .message, entityID: inserted.entityID)
        XCTAssertNil(absent)
        await XCTAssertEqualAsync({ try await store.latestChangeCursor() }, try ChangeCursor(1))
        await XCTAssertEqualAsync({ try await store.recordCount() }, 1)
        await store.close()
    }

    func testFailureBeforeCommitPersistsNeitherRowsNorChangesAfterReopen() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(321), task = try TestIDs.task(322)
        let store = try database.makeStore(deviceID: device, testHooks: SyncStoreTestHooks(
            afterLocalBatchRecordsApplied: { throw IncrementalTestFailure(label: "before-local-commit") }
        ))
        do {
            _ = try await store.commitLocalRecords(taskRecords(device: device, task: task, revision: 1))
            XCTFail("Expected the injected commit failure")
        } catch let error as IncrementalTestFailure {
            XCTAssertEqual(error.label, "before-local-commit")
        }
        await store.close()
        let reopened = try database.makeStore(deviceID: device)
        await XCTAssertEqualAsync({ try await reopened.recordCount() }, 0)
        await XCTAssertEqualAsync({ try await reopened.latestChangeCursor() }, .zero)
        await reopened.close()
    }

    func testDuplicateIdentityAndForeignOriginCannotEnterBatch() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(331), foreign = try TestIDs.device(332), task = try TestIDs.task(333)
        let store = try database.makeStore(deviceID: device)
        let record = try SyncRecord.test(entityID: TestIDs.entity(334), revision: 1,
                                        originDeviceID: device, taskID: task)
        let key = RecordKey(kind: record.kind, entityID: record.entityID)
        await XCTAssertThrowsSyncError(.invalidRecord("local batch repeats record \(key)")) {
            try await store.commitLocalRecords([record, record])
        }
        let foreignRecord = try SyncRecord.test(entityID: TestIDs.entity(335), revision: 1,
                                               originDeviceID: foreign, taskID: task)
        await XCTAssertThrowsSyncError(.recordOriginMismatch(expected: device, found: foreign)) {
            try await store.commitLocalRecords([record, foreignRecord])
        }
        await XCTAssertEqualAsync({ try await store.recordCount() }, 0)
        await XCTAssertEqualAsync({ try await store.latestChangeCursor() }, .zero)
        await store.close()
    }

    func testRecordCountAndCombinedPayloadBudgetsAreEnforced() async throws {
        let countDB = try TestDatabase(), bytesDB = try TestDatabase()
        addTeardownBlock { countDB.remove(); bytesDB.remove() }
        let device = try TestIDs.device(341), task = try TestIDs.task(342)
        let countStore = try countDB.makeStore(deviceID: device,
                                             configuration: SyncStoreConfiguration(maxBatchRecords: 1))
        let bytesStore = try bytesDB.makeStore(deviceID: device,
                                             configuration: SyncStoreConfiguration(maxBatchBytes: 5))
        let records = try [343, 344].map {
            try SyncRecord.test(entityID: TestIDs.entity($0), revision: 1, originDeviceID: device,
                                taskID: task, payload: .string("x"))
        }
        await XCTAssertThrowsSyncError(.batchTooLarge(limit: 1)) {
            try await countStore.commitLocalRecords(records)
        }
        await XCTAssertThrowsSyncError(.batchBytesTooLarge(limit: 5)) {
            try await bytesStore.commitLocalRecords(records)
        }
        await XCTAssertEqualAsync({ try await countStore.recordCount() }, 0)
        await XCTAssertEqualAsync({ try await bytesStore.recordCount() }, 0)
        await countStore.close()
        await bytesStore.close()
    }

    func testCompetingWritersCannotLeaveLosingBatchMarker() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(351), task = try TestIDs.task(352)
        let first = try database.makeStore(deviceID: device)
        let second = try database.makeStore(deviceID: device)
        let entity = try TestIDs.entity(353)
        _ = try await first.commitLocalRecord(.test(entityID: entity, revision: 1,
                                                  originDeviceID: device, taskID: task))
        let attempts = try [354, 355].map { value -> [SyncRecord] in
            [
                try .test(kind: .message, entityID: TestIDs.entity(value), revision: 1,
                          originDeviceID: device, taskID: task),
                try .test(entityID: entity, revision: 2, baseRevision: 1, originDeviceID: device,
                          taskID: task, payload: .object(["winner": .integer(Int64(value))]))
            ]
        }
        let results = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for (store, batch) in [(first, attempts[0]), (second, attempts[1])] {
                group.addTask {
                    do {
                        _ = try await store.commitLocalRecords(batch)
                        return "committed"
                    } catch SyncStoreError.localBaseMismatch {
                        return "conflict"
                    } catch {
                        return "unexpected: \(error)"
                    }
                }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.sorted(), ["committed", "conflict"])
        let markers = try await [
            first.storedRecord(kind: .message, entityID: TestIDs.entity(354)),
            first.storedRecord(kind: .message, entityID: TestIDs.entity(355))
        ]
        XCTAssertEqual(markers.compactMap { $0 }.count, 1)
        await XCTAssertEqualAsync({ try await first.recordCount() }, 2)
        await XCTAssertEqualAsync({ try await first.latestChangeCursor() }, try ChangeCursor(3))
        await first.close()
        await second.close()
    }

    func testTaskSnapshotThenIncrementalReplaySurvivesReceiverRestart() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(361), receiverID = try TestIDs.device(362), task = try TestIDs.task(363)
        let snapshotKey = IncrementalFixture.key(0x71), incrementalKey = IncrementalFixture.key(0x72)
        let incrementalAuth = try IncrementalFixture.authenticator(peers: [(sourceID, "task-delta", incrementalKey)])
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(deviceID: receiverID, incrementalAuthenticator: incrementalAuth)
        await receiver.installSnapshotAuthenticator(try HMACSnapshotAuthenticator(peerKeys: [
            .init(peerDeviceID: sourceID, keyID: "task-snapshot", key: snapshotKey)
        ]))
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        _ = try await source.commitLocalRecords(taskRecords(device: sourceID, task: task, revision: 1))
        let snapshot = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(snapshot.snapshotID)
        let signedManifest = try manifest.signedForSnapshot(receiverDeviceID: receiverID,
                                                            keyID: "task-snapshot", key: snapshotKey)
        _ = try await receiver.beginAuthenticatedSnapshotImport(signedManifest)

        // Changes during snapshot transfer remain after its frozen base cursor.
        _ = try await source.commitLocalRecords(taskRecords(device: sourceID, task: task, revision: 2, base: 1))
        for pageIndex in 0..<manifest.pageCount {
            let page = try await source.snapshotPageEnvelope(snapshot.snapshotID, manifest: manifest,
                                                              pageIndex: pageIndex)
            _ = try await receiver.receiveAuthenticatedSnapshotPage(signedManifest, envelope: page)
        }
        _ = try await receiver.commitAuthenticatedSnapshotImport(signedManifest)
        let before = try await receiver.storedRecord(kind: .message, entityID: TestIDs.entity(303))
        XCTAssertEqual(before?.record.payload["text"]?.stringValue, "starting")
        let unsigned = try await source.nextIncrementalBatch(receiverDeviceID: receiverID, scope: .task(task),
                                                               subscriptionVersion: 1, after: snapshot.baseCursor)
        let signed = try unsigned.signed(keyID: "task-delta", key: incrementalKey)
        let wire = signed.wireJSON()
        let applied = try await receiver.applyAuthenticatedIncrementalBatch(IncrementalBatch(wireJSON: wire))
        XCTAssertEqual(applied.applied.count, 3)
        XCTAssertTrue(applied.conflicts.isEmpty)
        await receiver.close()

        let reopened = try receiverDB.makeStore(deviceID: receiverID, incrementalAuthenticator: incrementalAuth)
        let replay = try await reopened.applyAuthenticatedIncrementalBatch(IncrementalBatch(wireJSON: wire))
        XCTAssertTrue(replay.isDuplicate)
        for record in try taskRecords(device: sourceID, task: task, revision: 2) {
            let stored = try await reopened.storedRecord(kind: record.kind, entityID: record.entityID)
            XCTAssertEqual(stored?.record.taskID, task)
            XCTAssertEqual(stored?.record.revision, try Revision(2))
            XCTAssertEqual(stored?.record.payload, record.payload)
        }
        let subscription = try await reopened.subscription(peerDeviceID: sourceID, scope: .task(task))
        XCTAssertEqual(subscription?.appliedCursor, unsigned.throughCursor)
        await XCTAssertEqualAsync({ try await reopened.recordCount() }, 3)
        try await source.closeSnapshot(snapshot.snapshotID)
        await source.close()
        await reopened.close()
    }
}
