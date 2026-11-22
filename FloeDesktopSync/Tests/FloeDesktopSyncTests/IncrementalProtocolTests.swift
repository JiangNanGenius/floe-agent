import Foundation
import XCTest
@testable import FloeDesktopSync

final class IncrementalProtocolTests: XCTestCase {
    func testAuthorizedBatchAppliesAndAdvancesCursorAtomically() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(1), receiverID = try TestIDs.device(2)
        let taskA = try TestIDs.task(3), taskB = try TestIDs.task(4)
        let key = IncrementalFixture.key()
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(
            deviceID: receiverID,
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [(sourceID, "k1", key)]
            )
        )

        let entities = try (10..<13).map { try TestIDs.entity($0) }
        let bodies = entities.enumerated().map { index, entity in
            (entity, JSONValue.object(["title": .string("seed-\(index)")]))
        }
        for (entity, body) in bodies {
            _ = try await source.commitLocalRecord(
                try .test(
                    entityID: entity,
                    revision: 1,
                    originDeviceID: sourceID,
                    taskID: taskA,
                    payload: body
                )
            )
        }
        let base = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: receiver,
            sourceID: sourceID,
            scope: .task(taskA)
        )
        XCTAssertEqual(base, try TestIDs.cursor(3))
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(taskA))

        _ = try await source.commitLocalRecord(
            try .test(
                entityID: entities[0],
                revision: 2,
                baseRevision: 1,
                baseDigest: ContentDigest.compute(bodies[0].1.canonicalUTF8),
                originDeviceID: sourceID,
                taskID: taskA,
                payload: .object(["title": .string("updated")])
            )
        )
        _ = try await source.commitLocalRecord(
            try .test(
                entityID: entities[1],
                revision: 2,
                baseRevision: 1,
                baseDigest: ContentDigest.compute(bodies[1].1.canonicalUTF8),
                originDeviceID: sourceID,
                taskID: taskA,
                payload: .null,
                deleted: true
            )
        )
        _ = try await source.commitLocalRecord(
            try .test(
                entityID: try TestIDs.entity(20),
                revision: 1,
                originDeviceID: sourceID,
                taskID: taskB,
                payload: .object(["title": .string("other task")])
            )
        )
        let foreignEntity = try TestIDs.entity(20)
        _ = try await source.commitLocalRecord(
            try .test(
                entityID: try TestIDs.entity(21),
                revision: 1,
                originDeviceID: sourceID,
                taskID: taskA,
                payload: .object(["title": .string("new in task")])
            )
        )

        let unsigned = try await source.nextIncrementalBatch(
            receiverDeviceID: receiverID,
            scope: .task(taskA),
            subscriptionVersion: 1,
            after: base
        )
        XCTAssertEqual(unsigned.fromCursor, base)
        XCTAssertEqual(unsigned.throughCursor, try TestIDs.cursor(7))
        XCTAssertEqual(
            unsigned.changes.map(\.sourceCursor),
            [try TestIDs.cursor(4), try TestIDs.cursor(5), try TestIDs.cursor(7)]
        )
        XCTAssertFalse(
            unsigned.changes.contains { $0.record.entityID == foreignEntity }
        )
        let signed = try unsigned.signed(keyID: "k1", key: key)

        let result = try await receiver.applyAuthenticatedIncrementalBatch(signed)
        XCTAssertFalse(result.isDuplicate)
        XCTAssertEqual(result.fromCursor, base)
        XCTAssertEqual(result.throughCursor, try TestIDs.cursor(7))
        XCTAssertEqual(result.applied.count, 3)
        XCTAssertEqual(result.unchanged, [])
        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(result.subscriptionVersion, 1)

        let updated = try await receiver.storedRecord(kind: .task, entityID: entities[0])
        XCTAssertEqual(updated?.record.payload["title"]?.stringValue, "updated")
        XCTAssertEqual(updated?.localDirty, false)
        let tombstoned = try await receiver.storedRecord(kind: .task, entityID: entities[1])
        XCTAssertEqual(tombstoned?.record.deleted, true)
        let untouched = try await receiver.storedRecord(kind: .task, entityID: entities[2])
        XCTAssertEqual(untouched?.record.payload["title"]?.stringValue, "seed-2")
        let inserted = try await receiver.storedRecord(
            kind: .task,
            entityID: try TestIDs.entity(21)
        )
        XCTAssertEqual(inserted?.record.payload["title"]?.stringValue, "new in task")
        let foreign = try await receiver.storedRecord(
            kind: .task,
            entityID: try TestIDs.entity(20)
        )
        XCTAssertNil(foreign)
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 3)

        let subscription = try await receiver.subscription(
            peerDeviceID: sourceID,
            scope: .task(taskA)
        )
        XCTAssertEqual(subscription?.appliedCursor, try TestIDs.cursor(7))
        XCTAssertEqual(subscription?.version, 1)
        XCTAssertEqual(subscription?.established, true)
        let metadata = try await receiver.metadata()
        XCTAssertEqual(metadata.authorizedScopeCount, 1)
        XCTAssertEqual(metadata.incrementalReceiptCount, 1)

        // The snapshot commit appends three local change rows; the
        // incremental batch appends three more (one of them a tombstone).
        let changes = try await receiver.changes(after: .zero)
        XCTAssertEqual(changes.entries.count, 6)
        XCTAssertEqual(
            changes.entries.filter { $0.changeType == .delete }.count,
            1
        )
        await source.close()
        await receiver.close()
    }

    func testFilteredEmptyRangeAdvancesCursorAndExactEmptyIsNoOp() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(3), receiverID = try TestIDs.device(4)
        let taskA = try TestIDs.task(5), taskB = try TestIDs.task(6)
        let key = IncrementalFixture.key(0x11)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(
            deviceID: receiverID,
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [(sourceID, "k1", key)]
            )
        )
        _ = try await source.commitLocalRecord(
            try .test(
                entityID: try TestIDs.entity(30),
                revision: 1,
                originDeviceID: sourceID,
                taskID: taskA
            )
        )
        let base = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: receiver,
            sourceID: sourceID,
            scope: .task(taskA)
        )
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(taskA))
        _ = try await source.commitLocalRecord(
            try .test(
                entityID: try TestIDs.entity(31),
                revision: 1,
                originDeviceID: sourceID,
                taskID: taskB
            )
        )

        let unsigned = try await source.nextIncrementalBatch(
            receiverDeviceID: receiverID,
            scope: .task(taskA),
            subscriptionVersion: 1,
            after: base
        )
        XCTAssertEqual(unsigned.changes, [])
        XCTAssertEqual(unsigned.fromCursor, base)
        XCTAssertEqual(unsigned.throughCursor, try TestIDs.cursor(2))
        let result = try await receiver.applyAuthenticatedIncrementalBatch(
            try unsigned.signed(keyID: "k1", key: key)
        )
        XCTAssertEqual(result.applied, [])
        XCTAssertEqual(result.unchanged, [])
        XCTAssertEqual(result.throughCursor, try TestIDs.cursor(2))
        let advanced = try await receiver.subscription(
            peerDeviceID: sourceID,
            scope: .task(taskA)
        )
        XCTAssertEqual(advanced?.appliedCursor, try TestIDs.cursor(2))
        // The snapshot contained the single existing task record and the
        // filtered-empty interval must not remove or duplicate it.
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 1)

        let noOp = try await source.nextIncrementalBatch(
            receiverDeviceID: receiverID,
            scope: .task(taskA),
            subscriptionVersion: 1,
            after: try TestIDs.cursor(2)
        )
        XCTAssertEqual(noOp.fromCursor, try TestIDs.cursor(2))
        XCTAssertEqual(noOp.throughCursor, try TestIDs.cursor(2))
        XCTAssertEqual(noOp.changes, [])
        let noOpResult = try await receiver.applyAuthenticatedIncrementalBatch(
            try noOp.signed(keyID: "k1", key: key)
        )
        XCTAssertFalse(noOpResult.isDuplicate)
        XCTAssertEqual(noOpResult.applied, [])
        let advancedAfterNoOp = try await receiver.subscription(
            peerDeviceID: sourceID,
            scope: .task(taskA)
        )
        XCTAssertEqual(advancedAfterNoOp?.appliedCursor, try TestIDs.cursor(2))
        let metadata = try await receiver.metadata()
        XCTAssertEqual(metadata.incrementalReceiptCount, 1)
        await source.close()
        await receiver.close()
    }

    func testReplayIsIdempotentAndSurvivesKeyRotation() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(5), receiverID = try TestIDs.device(6)
        let task = try TestIDs.task(7)
        let firstKey = IncrementalFixture.key(0x22)
        let rotatedKey = IncrementalFixture.key(0x33)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(
            deviceID: receiverID,
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [
                    (sourceID, "k1", firstKey),
                    (sourceID, "k2", rotatedKey)
                ]
            )
        )
        let base = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: receiver,
            sourceID: sourceID,
            scope: .task(task)
        )
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        _ = try await source.commitLocalRecord(
            try .test(
                entityID: try TestIDs.entity(40),
                revision: 1,
                originDeviceID: sourceID,
                taskID: task,
                payload: .object(["title": .string("one")])
            )
        )
        let unsigned = try await source.nextIncrementalBatch(
            receiverDeviceID: receiverID,
            scope: .task(task),
            subscriptionVersion: 1,
            after: base
        )
        let signed = try unsigned.signed(keyID: "k1", key: firstKey)
        let first = try await receiver.applyAuthenticatedIncrementalBatch(signed)
        XCTAssertFalse(first.isDuplicate)

        let replay = try await receiver.applyAuthenticatedIncrementalBatch(signed)
        XCTAssertTrue(replay.isDuplicate)
        XCTAssertEqual(replay.applied, first.applied)
        XCTAssertEqual(replay.throughCursor, first.throughCursor)
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 1)

        let resigned = try unsigned.signed(keyID: "k2", key: rotatedKey)
        XCTAssertNotEqual(signed.authenticationDigest(), resigned.authenticationDigest())
        XCTAssertEqual(signed.contentDigest(), resigned.contentDigest())
        let afterRotation = try await receiver.applyAuthenticatedIncrementalBatch(resigned)
        XCTAssertTrue(afterRotation.isDuplicate)
        XCTAssertEqual(afterRotation.applied, first.applied)
        let metadata = try await receiver.metadata()
        XCTAssertEqual(metadata.incrementalReceiptCount, 1)
        await source.close()
        await receiver.close()
    }

    func testScopeGrantsArePeerSpecificIdempotentAndRevocable() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(8), peerA = try TestIDs.device(9)
        let peerB = try TestIDs.device(10), task = try TestIDs.task(11)
        let store = try database.makeStore(deviceID: device)
        let first = try await store.grantScopeAccess(
            peerDeviceID: peerA,
            scope: .task(task)
        )
        let second = try await store.grantScopeAccess(
            peerDeviceID: peerA,
            scope: .task(task)
        )
        XCTAssertEqual(first.grantedAt, second.grantedAt)
        XCTAssertEqual(second.scope, .task(task))
        let authorizedA = try await store.isScopeAuthorized(
            peerDeviceID: peerA,
            scope: .task(task)
        )
        let authorizedB = try await store.isScopeAuthorized(
            peerDeviceID: peerB,
            scope: .task(task)
        )
        XCTAssertTrue(authorizedA)
        XCTAssertFalse(authorizedB)
        let grantsA = try await store.scopeAuthorizations(peerDeviceID: peerA)
        let grantsB = try await store.scopeAuthorizations(peerDeviceID: peerB)
        XCTAssertEqual(grantsA.count, 1)
        XCTAssertEqual(grantsB.count, 0)
        let revoked = try await store.revokeScopeAccess(
            peerDeviceID: peerA,
            scope: .task(task)
        )
        let revokedAgain = try await store.revokeScopeAccess(
            peerDeviceID: peerA,
            scope: .task(task)
        )
        XCTAssertTrue(revoked)
        XCTAssertFalse(revokedAgain)
        let stillAuthorized = try await store.isScopeAuthorized(
            peerDeviceID: peerA,
            scope: .task(task)
        )
        XCTAssertFalse(stillAuthorized)
        await XCTAssertThrowsSyncError(
            .invalidScopeGrant("a device cannot grant scope access to itself")
        ) {
            try await store.grantScopeAccess(peerDeviceID: device, scope: .task(task))
        }
        await store.close()
    }

    func testResubscriptionRejectsOldGenerationProofAndRequiresNewSnapshot() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(12), receiverID = try TestIDs.device(13)
        let task = try TestIDs.task(14)
        let key = IncrementalFixture.key(0x44)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(
            deviceID: receiverID,
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [(sourceID, "k1", key)]
            )
        )
        _ = try await source.commitLocalRecord(
            try .test(
                entityID: try TestIDs.entity(50),
                revision: 1,
                originDeviceID: sourceID,
                taskID: task,
                payload: .object(["title": .string("v1")])
            )
        )
        let base = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: receiver,
            sourceID: sourceID,
            scope: .task(task)
        )
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        _ = try await source.commitLocalRecord(
            try .test(
                entityID: try TestIDs.entity(51),
                revision: 1,
                originDeviceID: sourceID,
                taskID: task
            )
        )
        let v1Batch = try await source.nextIncrementalBatch(
            receiverDeviceID: receiverID,
            scope: .task(task),
            subscriptionVersion: 1,
            after: base
        )
        _ = try await receiver.applyAuthenticatedIncrementalBatch(
            try v1Batch.signed(keyID: "k1", key: key)
        )
        _ = try await receiver.resetSubscription(
            peerDeviceID: sourceID,
            scope: .task(task),
            version: 2
        )
        await XCTAssertThrowsSyncError(
            .subscriptionVersionMismatch(sourceID, .task(task), expected: 1, found: 2)
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(
                try v1Batch.signed(keyID: "k1", key: key)
            )
        }
        let reset = try await receiver.subscription(
            peerDeviceID: sourceID,
            scope: .task(task)
        )
        XCTAssertEqual(reset?.version, 2)
        XCTAssertEqual(reset?.established, false)
        XCTAssertEqual(reset?.appliedCursor, .zero)
        let resetMetadata = try await receiver.metadata()
        XCTAssertEqual(resetMetadata.incrementalReceiptCount, 0)

        let v2BatchBeforeSnapshot = try IncrementalFixture.makeBatch(
            peer: sourceID,
            receiver: receiverID,
            scope: .task(task),
            version: 2,
            from: .zero,
            through: try TestIDs.cursor(2),
            changes: []
        )
        await XCTAssertThrowsSyncError(
            .subscriptionNotEstablished(sourceID, .task(task))
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(
                try v2BatchBeforeSnapshot.signed(keyID: "k1", key: key)
            )
        }
        let v2Base = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: receiver,
            sourceID: sourceID,
            scope: .task(task),
            version: 2
        )
        let v2Batch = try await source.nextIncrementalBatch(
            receiverDeviceID: receiverID,
            scope: .task(task),
            subscriptionVersion: 2,
            after: v2Base
        )
        XCTAssertEqual(v2Batch.throughCursor, v2Batch.fromCursor)
        let v2Result = try await receiver.applyAuthenticatedIncrementalBatch(
            try v2Batch.signed(keyID: "k1", key: key)
        )
        XCTAssertFalse(v2Result.isDuplicate)
        XCTAssertEqual(v2Result.subscriptionVersion, 2)
        await source.close()
        await receiver.close()
    }

    func testEmptyAndFilteredScansRespectCursorBounds() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(15)
        let store = try database.makeStore(deviceID: device)
        await XCTAssertThrowsSyncError(.invalidSubscriptionVersion(0)) {
            try await store.nextIncrementalBatch(
                receiverDeviceID: try TestIDs.device(999),
                scope: .all,
                subscriptionVersion: 0,
                after: .zero
            )
        }
        await XCTAssertThrowsSyncError(
            .cursorAhead(current: .zero, received: try TestIDs.cursor(1))
        ) {
            try await store.nextIncrementalBatch(
                receiverDeviceID: try TestIDs.device(999),
                scope: .all,
                subscriptionVersion: 1,
                after: try TestIDs.cursor(1)
            )
        }
        for value in 60..<63 {
            _ = try await store.commitLocalRecord(
                try .test(
                    entityID: try TestIDs.entity(value),
                    revision: 1,
                    originDeviceID: device,
                    taskID: try TestIDs.task(17)
                )
            )
        }
        _ = try await store.pruneChanges(through: try TestIDs.cursor(2))
        await XCTAssertThrowsSyncError(
            .cursorExpired(try TestIDs.cursor(1), retainedFrom: try TestIDs.cursor(2))
        ) {
            try await store.nextIncrementalBatch(
                receiverDeviceID: try TestIDs.device(999),
                scope: .all,
                subscriptionVersion: 1,
                after: try TestIDs.cursor(1)
            )
        }
        let remaining = try await store.nextIncrementalBatch(
            receiverDeviceID: try TestIDs.device(999),
            scope: .all,
            subscriptionVersion: 1,
            after: try TestIDs.cursor(2)
        )
        XCTAssertEqual(remaining.changes.map(\.sourceCursor), [try TestIDs.cursor(3)])
        await store.close()
    }

    func testSenderScanAdvancesInBoundedWindowsAcrossForeignScopeRows() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(24)
        let taskA = try TestIDs.task(25), taskB = try TestIDs.task(26)
        let store = try database.makeStore(
            deviceID: device,
            configuration: SyncStoreConfiguration(maxIncrementalScanRows: 2)
        )
        let records: [(Int, TaskID)] = [
            (1, taskA),
            (2, taskB),
            (3, taskA),
            (4, taskA)
        ]
        for (value, task) in records {
            _ = try await store.commitLocalRecord(
                try .test(
                    entityID: try TestIDs.entity(110 + value),
                    revision: 1,
                    originDeviceID: device,
                    taskID: task
                )
            )
        }
        let first = try await store.nextIncrementalBatch(
            receiverDeviceID: try TestIDs.device(999),
            scope: .task(taskA),
            subscriptionVersion: 1,
            after: .zero
        )
        XCTAssertEqual(first.fromCursor, .zero)
        XCTAssertEqual(first.throughCursor, try TestIDs.cursor(2))
        XCTAssertEqual(first.changes.map(\.sourceCursor), [try TestIDs.cursor(1)])
        let second = try await store.nextIncrementalBatch(
            receiverDeviceID: try TestIDs.device(999),
            scope: .task(taskA),
            subscriptionVersion: 1,
            after: first.throughCursor
        )
        XCTAssertEqual(second.fromCursor, try TestIDs.cursor(2))
        XCTAssertEqual(second.throughCursor, try TestIDs.cursor(4))
        XCTAssertEqual(
            second.changes.map(\.sourceCursor),
            [try TestIDs.cursor(3), try TestIDs.cursor(4)]
        )
        let end = try await store.nextIncrementalBatch(
            receiverDeviceID: try TestIDs.device(999),
            scope: .task(taskA),
            subscriptionVersion: 1,
            after: second.throughCursor
        )
        XCTAssertEqual(end.fromCursor, try TestIDs.cursor(4))
        XCTAssertEqual(end.throughCursor, try TestIDs.cursor(4))
        XCTAssertEqual(end.changes, [])
        await store.close()
    }

    func testWireJSONRoundTripsAndTamperedPayloadFailsAuthentication() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(17), receiverID = try TestIDs.device(18)
        let task = try TestIDs.task(19)
        let key = IncrementalFixture.key(0x55)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(
            deviceID: receiverID,
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [(sourceID, "k1", key)]
            )
        )
        let base = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: receiver,
            sourceID: sourceID,
            scope: .task(task)
        )
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        _ = try await source.commitLocalRecord(
            try .test(
                entityID: try TestIDs.entity(70),
                revision: 1,
                originDeviceID: sourceID,
                taskID: task,
                payload: .object(["title": .string("wire")])
            )
        )
        let signed = try await source.nextIncrementalBatch(
            receiverDeviceID: receiverID,
            scope: .task(task),
            subscriptionVersion: 1,
            after: base
        ).signed(keyID: "k1", key: key)
        let wire = signed.wireJSON()
        let parsed = try IncrementalBatch(wireJSON: wire)
        XCTAssertEqual(parsed, signed)
        XCTAssertEqual(parsed.contentDigest(), signed.contentDigest())
        XCTAssertEqual(parsed.authenticationDigest(), signed.authenticationDigest())

        var object = try XCTUnwrap(signed.wireJSONValue().objectValue)
        object["futureOptionalField"] = .object(["ignored": .bool(true)])
        let extended = try IncrementalBatch(wireValue: .object(object))
        XCTAssertEqual(extended, signed)

        var tamperedObject = try XCTUnwrap(signed.wireJSONValue().objectValue)
        guard case .object(var change) = try XCTUnwrap(tamperedObject["changes"]?.arrayValue?.first),
              case .object(var record) = try XCTUnwrap(change["record"]) else {
            return XCTFail("expected change record")
        }
        record["payload"] = .object(["title": .string("tampered")])
        change["record"] = .object(record)
        tamperedObject["changes"] = .array([.object(change)])
        let tampered = try IncrementalBatch(wireValue: .object(tamperedObject))
        await XCTAssertThrowsSyncError(
            .incrementalAuthenticationFailed("proof tag does not verify")
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(tampered)
        }
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)
        await XCTAssertEqualAsync(
            { try await receiver.subscription(peerDeviceID: sourceID, scope: .task(task))?
                .appliedCursor },
            base
        )

        var truncatedObject = try XCTUnwrap(signed.wireJSONValue().objectValue)
        truncatedObject["changes"] = .array([])
        let truncated = try IncrementalBatch(wireValue: .object(truncatedObject))
        await XCTAssertThrowsSyncError(
            .incrementalAuthenticationFailed("proof tag does not verify")
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(truncated)
        }
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)
        await source.close()
        await receiver.close()
    }

    func testMigrationFromV4CreatesIncrementalRegistryWithoutRewritingRows() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(20), task = try TestIDs.task(21)
        let entity = try TestIDs.entity(22)
        let store = try database.makeStore(deviceID: device)
        _ = try await store.commitLocalRecord(
            try .test(
                entityID: entity,
                revision: 1,
                originDeviceID: device,
                taskID: task,
                payload: .object(["title": .string("preserved")])
            )
        )
        await store.close()

        let raw = try database.rawConnection()
        try raw.execute("DROP TABLE incremental_receipts")
        try raw.execute("DROP TABLE sync_scope_authorizations")
        try raw.execute("PRAGMA user_version = 4")
        raw.close()

        let migrated = try database.makeStore(deviceID: device)
        let metadata = try await migrated.metadata()
        XCTAssertEqual(metadata.schemaVersion, 5)
        XCTAssertEqual(metadata.authorizedScopeCount, 0)
        XCTAssertEqual(metadata.incrementalReceiptCount, 0)
        let preserved = try await migrated.storedRecord(kind: .task, entityID: entity)
        XCTAssertEqual(preserved?.record.payload["title"]?.stringValue, "preserved")
        _ = try await migrated.grantScopeAccess(
            peerDeviceID: try TestIDs.device(23),
            scope: .task(task)
        )
        let finalMetadata = try await migrated.metadata()
        XCTAssertEqual(finalMetadata.authorizedScopeCount, 1)
        await migrated.close()
    }
}
