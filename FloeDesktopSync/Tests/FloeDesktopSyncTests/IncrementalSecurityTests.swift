import Foundation
import XCTest
@testable import FloeDesktopSync

final class IncrementalSecurityTests: XCTestCase {
    private func expectFailure<T>(
        _ expected: IncrementalTestFailure,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as IncrementalTestFailure {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    func testMissingAuthenticatorMissingProofAndWrongKeyFailClosed() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(30), receiverID = try TestIDs.device(31)
        let task = try TestIDs.task(32)
        let key = IncrementalFixture.key(0x66)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let plain = try receiverDB.makeStore(deviceID: receiverID)
        let base = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: plain,
            sourceID: sourceID,
            scope: .task(task)
        )
        _ = try await plain.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        _ = try await source.commitLocalRecord(
            try .test(
                entityID: try TestIDs.entity(80),
                revision: 1,
                originDeviceID: sourceID,
                taskID: task
            )
        )
        let unsigned = try await source.nextIncrementalBatch(
            receiverDeviceID: receiverID,
            scope: .task(task),
            subscriptionVersion: 1,
            after: base
        )
        await XCTAssertThrowsSyncError(.incrementalAuthenticationUnavailable) {
            try await plain.applyAuthenticatedIncrementalBatch(unsigned)
        }
        await XCTAssertEqualAsync({ try await plain.recordCount() }, 0)
        await XCTAssertEqualAsync(
            { try await plain.subscription(peerDeviceID: sourceID, scope: .task(task))?.appliedCursor },
            base
        )
        await XCTAssertEqualAsync(
            { try await plain.subscription(peerDeviceID: sourceID, scope: .task(task))?.established },
            .some(true)
        )

        let receiver = try receiverDB.makeStore(
            deviceID: receiverID,
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [(sourceID, "k1", key)]
            )
        )
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        await XCTAssertThrowsSyncError(
            .incrementalAuthenticationFailed("batch carries no proof")
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(unsigned)
        }
        let wrongKey = IncrementalFixture.key(0x77)
        let unregistered = try unsigned.signed(keyID: "other", key: wrongKey)
        await XCTAssertThrowsSyncError(
            .incrementalAuthenticationFailed("proof key other is not registered")
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(unregistered)
        }
        let tamperedRecord = try SyncRecord.test(
            entityID: try TestIDs.entity(80),
            revision: 1,
            originDeviceID: sourceID,
            taskID: task,
            payload: .object(["title": .string("tampered")])
        )
        let originalProof = try unsigned.signed(keyID: "k1", key: key).proof
        let tampered = try IncrementalBatch(
            protocolVersion: unsigned.protocolVersion,
            peerDeviceID: unsigned.peerDeviceID,
            receiverDeviceID: receiverID,
            scope: unsigned.scope,
            subscriptionVersion: unsigned.subscriptionVersion,
            fromCursor: unsigned.fromCursor,
            throughCursor: unsigned.throughCursor,
            changes: [
                IncrementalChange(
                    sourceCursor: unsigned.changes[0].sourceCursor,
                    record: tamperedRecord
                )
            ],
            proof: originalProof
        )
        await XCTAssertThrowsSyncError(
            .incrementalAuthenticationFailed("proof tag does not verify")
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(tampered)
        }
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)
        let after = try await receiver.subscription(
            peerDeviceID: sourceID,
            scope: .task(task)
        )
        XCTAssertEqual(after?.appliedCursor, base)

        await receiver.installIncrementalAuthenticator(
            try IncrementalFixture.authenticator(peers: [(sourceID, "k1", key)])
        )
        let applied = try await receiver.applyAuthenticatedIncrementalBatch(
            try unsigned.signed(keyID: "k1", key: key)
        )
        XCTAssertFalse(applied.isDuplicate)
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 1)
        await source.close()
        await plain.close()
        await receiver.close()
    }

    func testContentDigestAloneIsNotAcceptedAsAuthentication() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(33), receiverID = try TestIDs.device(34)
        let task = try TestIDs.task(35)
        let key = IncrementalFixture.key(0x88)
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
                entityID: try TestIDs.entity(81),
                revision: 1,
                originDeviceID: sourceID,
                taskID: task
            )
        )
        let unsigned = try await source.nextIncrementalBatch(
            receiverDeviceID: receiverID,
            scope: .task(task),
            subscriptionVersion: 1,
            after: base
        )
        let forgedTag = try IncrementalAuthenticationTag(
            validating: "hmac-sha256:\(unsigned.contentDigest().hex)"
        )
        let digestOnly = try IncrementalBatch(
            protocolVersion: unsigned.protocolVersion,
            peerDeviceID: unsigned.peerDeviceID,
            receiverDeviceID: receiverID,
            scope: unsigned.scope,
            subscriptionVersion: unsigned.subscriptionVersion,
            fromCursor: unsigned.fromCursor,
            throughCursor: unsigned.throughCursor,
            changes: unsigned.changes,
            proof: try IncrementalBatchProof(keyID: "k1", tag: forgedTag)
        )
        await XCTAssertThrowsSyncError(
            .incrementalAuthenticationFailed("proof tag does not verify")
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(digestOnly)
        }
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)
        await XCTAssertEqualAsync(
            { try await receiver.subscription(peerDeviceID: sourceID, scope: .task(task))?.appliedCursor },
            base
        )
        await source.close()
        await receiver.close()
    }

    func testWrongPeerScopeSelfClaimAndUnknownGrantCannotMutate() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(36), otherID = try TestIDs.device(37)
        let receiverID = try TestIDs.device(38)
        let taskA = try TestIDs.task(39), taskB = try TestIDs.task(40)
        let sourceKey = IncrementalFixture.key(0x99)
        let otherKey = IncrementalFixture.key(0xAA)
        let receiverKey = IncrementalFixture.key(0xBB)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(
            deviceID: receiverID,
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [
                    (sourceID, "k-source", sourceKey),
                    (otherID, "k-other", otherKey),
                    (receiverID, "k-receiver", receiverKey)
                ]
            )
        )
        let base = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: receiver,
            sourceID: sourceID,
            scope: .task(taskA)
        )
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(taskA))
        let emptyA = try IncrementalFixture.makeBatch(
            peer: sourceID,
            receiver: receiverID,
            scope: .task(taskA),
            from: base,
            through: base,
            changes: []
        )

        let otherBatch = try IncrementalFixture.makeBatch(
            peer: otherID,
            receiver: receiverID,
            scope: .task(taskA),
            from: base,
            through: base,
            changes: []
        ).signed(keyID: "k-other", key: otherKey)
        await XCTAssertThrowsSyncError(
            .incrementalScopeUnauthorized(otherID, .task(taskA))
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(otherBatch)
        }
        let wrongScope = try IncrementalFixture.makeBatch(
            peer: sourceID,
            receiver: receiverID,
            scope: .task(taskB),
            from: base,
            through: base,
            changes: []
        ).signed(keyID: "k-source", key: sourceKey)
        await XCTAssertThrowsSyncError(
            .incrementalScopeUnauthorized(sourceID, .task(taskB))
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(wrongScope)
        }

        let foreignRecord = try SyncRecord.test(
            entityID: try TestIDs.entity(82),
            revision: 1,
            originDeviceID: sourceID,
            taskID: taskB
        )
        XCTAssertThrowsError(
            try IncrementalFixture.makeBatch(
                peer: sourceID,
                receiver: receiverID,
                scope: .task(taskA),
                from: base,
                through: try TestIDs.cursor(base.rawValue + 1),
                changes: [(base.rawValue + 1, foreignRecord)]
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncStoreError,
                .snapshotScopeMismatch(
                    RecordKey(kind: .task, entityID: foreignRecord.entityID),
                    .task(taskA)
                )
            )
        }

        let relabeledPeer = try IncrementalBatch(
            protocolVersion: emptyA.protocolVersion,
            peerDeviceID: otherID,
            receiverDeviceID: receiverID,
            scope: emptyA.scope,
            subscriptionVersion: emptyA.subscriptionVersion,
            fromCursor: emptyA.fromCursor,
            throughCursor: emptyA.throughCursor,
            changes: emptyA.changes,
            proof: try emptyA.signed(keyID: "k-source", key: sourceKey).proof
        )
        await XCTAssertThrowsSyncError(
            .incrementalAuthenticationFailed(
                "proof key is not registered for the claimed peer"
            )
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(relabeledPeer)
        }

        let selfClaim = try IncrementalBatch(
            protocolVersion: emptyA.protocolVersion,
            peerDeviceID: receiverID,
            receiverDeviceID: receiverID,
            scope: emptyA.scope,
            subscriptionVersion: emptyA.subscriptionVersion,
            fromCursor: emptyA.fromCursor,
            throughCursor: emptyA.throughCursor,
            changes: emptyA.changes,
            proof: try emptyA.signed(keyID: "k-receiver", key: receiverKey).proof
        )
        await XCTAssertThrowsSyncError(
            .incrementalAuthenticationFailed(
                "a batch cannot claim the local device as its origin"
            )
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(selfClaim)
        }
        let subscription = try await receiver.subscription(
            peerDeviceID: sourceID,
            scope: .task(taskA)
        )
        XCTAssertEqual(subscription?.appliedCursor, base)
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)
        await source.close()
        await receiver.close()
    }

    func testStaleGappedAndRolledBackIntervalsAreRejected() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(39), receiverID = try TestIDs.device(40)
        let task = try TestIDs.task(41)
        let key = IncrementalFixture.key(0xCC)
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
                entityID: try TestIDs.entity(83),
                revision: 1,
                originDeviceID: sourceID,
                taskID: task
            )
        )
        let batch = try await source.nextIncrementalBatch(
            receiverDeviceID: receiverID,
            scope: .task(task),
            subscriptionVersion: 1,
            after: base
        )
        _ = try await receiver.applyAuthenticatedIncrementalBatch(
            try batch.signed(keyID: "k1", key: key)
        )
        let applied = batch.throughCursor
        XCTAssertEqual(applied, try TestIDs.cursor(1))

        let gap = try IncrementalFixture.makeBatch(
            peer: sourceID,
            receiver: receiverID,
            scope: .task(task),
            from: try TestIDs.cursor(2),
            through: try TestIDs.cursor(3),
            changes: []
        ).signed(keyID: "k1", key: key)
        await XCTAssertThrowsSyncError(
            .incrementalRangeGap(sourceID, .task(task), expected: applied, receivedFrom: try TestIDs.cursor(2))
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(gap)
        }
        let stale = try IncrementalFixture.makeBatch(
            peer: sourceID,
            receiver: receiverID,
            scope: .task(task),
            from: base,
            through: base,
            changes: []
        ).signed(keyID: "k1", key: key)
        await XCTAssertThrowsSyncError(
            .incrementalRangeGap(sourceID, .task(task), expected: applied, receivedFrom: base)
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(stale)
        }
        XCTAssertThrowsError(
            try IncrementalFixture.makeBatch(
                peer: sourceID,
                receiver: receiverID,
                scope: .task(task),
                from: applied,
                through: base,
                changes: []
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncStoreError,
                .incrementalBatchInvalid(
                    "throughCursor \(base) precedes fromCursor \(applied)"
                )
            )
        }
        let after = try await receiver.subscription(
            peerDeviceID: sourceID,
            scope: .task(task)
        )
        XCTAssertEqual(after?.appliedCursor, applied)
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 1)
        await source.close()
        await receiver.close()
    }

    func testOutOfRangeAndUnorderedEntriesAreStructurallyRejected() throws {
        let peer = try TestIDs.device(41)
        let task = try TestIDs.task(42)
        let from = try TestIDs.cursor(10)
        let through = try TestIDs.cursor(20)
        let record = try SyncRecord.test(
            entityID: try TestIDs.entity(84),
            revision: 1,
            originDeviceID: peer,
            taskID: task
        )
        XCTAssertThrowsError(
            try IncrementalFixture.makeBatch(
                peer: peer,
                receiver: try TestIDs.device(999),
                scope: .all,
                from: from,
                through: through,
                changes: [(10, record)]
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncStoreError,
                .incrementalBatchInvalid(
                    "change cursor 10 is outside the declared interval"
                )
            )
        }
        XCTAssertThrowsError(
            try IncrementalFixture.makeBatch(
                peer: peer,
                receiver: try TestIDs.device(999),
                scope: .all,
                from: from,
                through: through,
                changes: [(21, record)]
            )
        )
        XCTAssertThrowsError(
            try IncrementalFixture.makeBatch(
                peer: peer,
                receiver: try TestIDs.device(999),
                scope: .all,
                from: from,
                through: through,
                changes: [(12, record), (12, record)]
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncStoreError,
                .incrementalBatchInvalid("change cursors must be strictly increasing")
            )
        }
        XCTAssertThrowsError(
            try IncrementalFixture.makeBatch(
                peer: peer,
                receiver: try TestIDs.device(999),
                scope: .all,
                from: from,
                through: from,
                changes: [(11, record)]
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncStoreError,
                .incrementalBatchInvalid("an empty scan interval cannot carry changes")
            )
        }
        let wrongScopeRecord = try SyncRecord.test(
            kind: .workspaceFile,
            entityID: try TestIDs.entity(85),
            revision: 1,
            originDeviceID: peer,
            workspaceID: try TestIDs.workspace(43),
            payload: .object(["path": .string("note.txt")])
        )
        XCTAssertThrowsError(
            try IncrementalFixture.makeBatch(
                peer: peer,
                receiver: try TestIDs.device(999),
                scope: .workspace(try TestIDs.workspace(44)),
                from: from,
                through: through,
                changes: [(11, wrongScopeRecord)]
            )
        )
        XCTAssertThrowsError(
            try IncrementalFixture.makeBatch(
                peer: peer,
                receiver: try TestIDs.device(999),
                scope: .all,
                from: from,
                through: through,
                changes: [
                    (
                        11,
                        try SyncRecord.test(
                            entityID: try TestIDs.entity(86),
                            revision: 1,
                            originDeviceID: peer
                        )
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? SyncStoreError,
                .invalidRecord("task requires taskID")
            )
        }
    }

    func testLocalDirtyConflictsAndTombstonesArePreservedWhileCursorAdvances() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(42), receiverID = try TestIDs.device(43)
        let task = try TestIDs.task(44)
        let key = IncrementalFixture.key(0xDD)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(
            deviceID: receiverID,
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [(sourceID, "k1", key)]
            )
        )
        let dirtyEntity = try TestIDs.entity(87)
        let tombstoneEntity = try TestIDs.entity(88)
        let dirtyTombstoneEntity = try TestIDs.entity(98)
        let localBody: JSONValue = .object(["title": .string("local draft")])
        let dirtyTombstoneBody: JSONValue = .object(["title": .string("local tombstone draft")])
        _ = try await receiver.commitLocalRecord(
            try .test(
                entityID: dirtyEntity,
                revision: 1,
                originDeviceID: receiverID,
                taskID: task,
                payload: localBody
            )
        )
        _ = try await receiver.commitLocalRecord(
            try .test(
                entityID: tombstoneEntity,
                revision: 1,
                originDeviceID: receiverID,
                taskID: task,
                payload: .object(["title": .string("clean")])
            )
        )
        _ = try await receiver.commitLocalRecord(
            try .test(
                entityID: dirtyTombstoneEntity,
                revision: 1,
                originDeviceID: receiverID,
                taskID: task,
                payload: dirtyTombstoneBody
            )
        )
        _ = try await receiver.acknowledgeLocalRecord(
            kind: .task,
            entityID: tombstoneEntity,
            revision: try TestIDs.revision(1)
        )
        let base = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: receiver,
            sourceID: sourceID,
            scope: .task(task)
        )
        XCTAssertEqual(base, .zero)
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))

        let remoteUpdate = try SyncRecord.test(
            entityID: dirtyEntity,
            revision: 2,
            baseRevision: 1,
            baseDigest: ContentDigest.compute(localBody.canonicalUTF8),
            originDeviceID: sourceID,
            taskID: task,
            payload: .object(["title": .string("remote win")])
        )
        let remoteTombstone = try SyncRecord.test(
            entityID: tombstoneEntity,
            revision: 2,
            baseRevision: 1,
            baseDigest: ContentDigest.compute(
                JSONValue.object(["title": .string("clean")]).canonicalUTF8
            ),
            originDeviceID: sourceID,
            taskID: task,
            payload: .null,
            deleted: true
        )
        let remoteDirtyTombstone = try SyncRecord.test(
            entityID: dirtyTombstoneEntity,
            revision: 2,
            baseRevision: 1,
            baseDigest: ContentDigest.compute(dirtyTombstoneBody.canonicalUTF8),
            originDeviceID: sourceID,
            taskID: task,
            payload: .null,
            deleted: true
        )
        let batch = try IncrementalFixture.makeBatch(
            peer: sourceID,
            receiver: receiverID,
            scope: .task(task),
            from: base,
            through: try TestIDs.cursor(base.rawValue + 3),
            changes: [
                (base.rawValue + 1, remoteUpdate),
                (base.rawValue + 2, remoteTombstone),
                (base.rawValue + 3, remoteDirtyTombstone)
            ]
        ).signed(keyID: "k1", key: key)
        let result = try await receiver.applyAuthenticatedIncrementalBatch(batch)
        XCTAssertEqual(result.applied.count, 1)
        XCTAssertEqual(result.conflicts.count, 2)
        XCTAssertEqual(
            Set(result.conflicts.map { $0.reason.rawValue }),
            ["localUnsyncedEdit"]
        )
        XCTAssertEqual(
            Set(result.conflicts.compactMap(\.key.entityID)),
            [dirtyEntity, dirtyTombstoneEntity]
        )
        let dirty = try await receiver.storedRecord(kind: .task, entityID: dirtyEntity)
        XCTAssertEqual(dirty?.record.payload, localBody)
        XCTAssertEqual(dirty?.localDirty, true)
        let deleted = try await receiver.storedRecord(kind: .task, entityID: tombstoneEntity)
        XCTAssertEqual(deleted?.record.deleted, true)
        let dirtyTombstone = try await receiver.storedRecord(
            kind: .task,
            entityID: dirtyTombstoneEntity
        )
        XCTAssertEqual(dirtyTombstone?.record.payload, dirtyTombstoneBody)
        XCTAssertEqual(dirtyTombstone?.record.deleted, false)
        XCTAssertEqual(dirtyTombstone?.localDirty, true)
        let subscription = try await receiver.subscription(
            peerDeviceID: sourceID,
            scope: .task(task)
        )
        XCTAssertEqual(subscription?.appliedCursor, try TestIDs.cursor(base.rawValue + 3))
        let conflicts = try await receiver.conflicts()
        XCTAssertEqual(conflicts.count, 2)
        let revisionTwo = try TestIDs.revision(2)
        XCTAssertTrue(conflicts.allSatisfy { $0.incoming.revision == revisionTwo })
        let replay = try await receiver.applyAuthenticatedIncrementalBatch(batch)
        XCTAssertTrue(replay.isDuplicate)
        XCTAssertEqual(replay.conflicts.count, 2)
        let conflictsAfterReplay = try await receiver.conflicts()
        XCTAssertEqual(conflictsAfterReplay.count, 2)
        await source.close()
        await receiver.close()
    }

    func testInjectedFailureAfterRecordsAppliedRollsBackEverything() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(44), receiverID = try TestIDs.device(45)
        let task = try TestIDs.task(46)
        let key = IncrementalFixture.key(0xEE)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        var failingHooks = SyncStoreTestHooks()
        failingHooks.afterIncrementalRecordsApplied = {
            throw IncrementalTestFailure(label: "injected-after-apply")
        }
        let failing = try receiverDB.makeStore(
            deviceID: receiverID,
            testHooks: failingHooks,
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [(sourceID, "k1", key)]
            )
        )
        let base = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: failing,
            sourceID: sourceID,
            scope: .task(task)
        )
        _ = try await failing.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        _ = try await source.commitLocalRecord(
            try .test(
                entityID: try TestIDs.entity(89),
                revision: 1,
                originDeviceID: sourceID,
                taskID: task,
                payload: .object(["title": .string("rollback")])
            )
        )
        let batch = try await source.nextIncrementalBatch(
            receiverDeviceID: receiverID,
            scope: .task(task),
            subscriptionVersion: 1,
            after: base
        ).signed(keyID: "k1", key: key)
        await expectFailure(IncrementalTestFailure(label: "injected-after-apply")) {
            try await failing.applyAuthenticatedIncrementalBatch(batch)
        }
        await XCTAssertEqualAsync({ try await failing.recordCount() }, 0)
        let subscription = try await failing.subscription(
            peerDeviceID: sourceID,
            scope: .task(task)
        )
        XCTAssertEqual(subscription?.appliedCursor, base)
        let failureConflicts = try await failing.conflicts()
        XCTAssertEqual(failureConflicts.count, 0)
        let metadata = try await failing.metadata()
        XCTAssertEqual(metadata.incrementalReceiptCount, 0)
        await failing.close()

        let reopened = try receiverDB.makeStore(
            deviceID: receiverID,
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [(sourceID, "k1", key)]
            )
        )
        let applied = try await reopened.applyAuthenticatedIncrementalBatch(batch)
        XCTAssertFalse(applied.isDuplicate)
        await XCTAssertEqualAsync({ try await reopened.recordCount() }, 1)
        let advanced = try await reopened.subscription(
            peerDeviceID: sourceID,
            scope: .task(task)
        )
        XCTAssertEqual(advanced?.appliedCursor, batch.throughCursor)
        let finalMetadata = try await reopened.metadata()
        XCTAssertEqual(finalMetadata.incrementalReceiptCount, 1)
        await source.close()
        await reopened.close()
    }

    func testPartialBatchFailureRollsBackEarlierAppliedRecords() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(46), receiverID = try TestIDs.device(47)
        let taskA = try TestIDs.task(48), taskB = try TestIDs.task(49)
        let taskC = try TestIDs.task(50)
        let key = IncrementalFixture.key(0xEF)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(
            deviceID: receiverID,
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [(sourceID, "k1", key)]
            )
        )
        let existing = try TestIDs.entity(90)
        _ = try await receiver.commitLocalRecord(
            try .test(
                entityID: existing,
                revision: 1,
                originDeviceID: receiverID,
                taskID: taskA,
                payload: .object(["title": .string("receiver local")])
            )
        )
        _ = try await receiver.acknowledgeLocalRecord(
            kind: .task,
            entityID: existing,
            revision: try TestIDs.revision(1)
        )
        let base = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: receiver,
            sourceID: sourceID,
            scope: .all
        )
        _ = try await receiver.grantScopeAccess(peerDeviceID: sourceID, scope: .all)
        let first = try SyncRecord.test(
            entityID: try TestIDs.entity(91),
            revision: 1,
            originDeviceID: sourceID,
            taskID: taskC,
            payload: .object(["title": .string("must roll back")])
        )
        let moving = try SyncRecord.test(
            entityID: existing,
            revision: 2,
            baseRevision: 1,
            baseDigest: ContentDigest.compute(
                JSONValue.object(["title": .string("receiver local")]).canonicalUTF8
            ),
            originDeviceID: sourceID,
            taskID: taskB,
            payload: .object(["title": .string("moved")])
        )
        let batch = try IncrementalFixture.makeBatch(
            peer: sourceID,
            receiver: receiverID,
            scope: .all,
            from: base,
            through: try TestIDs.cursor(base.rawValue + 2),
            changes: [
                (base.rawValue + 1, first),
                (base.rawValue + 2, moving)
            ]
        ).signed(keyID: "k1", key: key)
        await XCTAssertThrowsSyncError(
            .invalidRecord(
                "existing entity cannot change task or workspace through synchronization"
            )
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(batch)
        }
        let rolledBack = try await receiver.storedRecord(
            kind: .task,
            entityID: try TestIDs.entity(91)
        )
        XCTAssertNil(rolledBack)
        let retained = try await receiver.storedRecord(kind: .task, entityID: existing)
        XCTAssertEqual(retained?.record.taskID, taskA)
        XCTAssertEqual(retained?.record.revision, try TestIDs.revision(1))
        let subscription = try await receiver.subscription(
            peerDeviceID: sourceID,
            scope: .all
        )
        XCTAssertEqual(subscription?.appliedCursor, base)
        let metadata = try await receiver.metadata()
        XCTAssertEqual(metadata.incrementalReceiptCount, 0)
        await source.close()
        await receiver.close()
    }

    func testTwoConnectionsRacingTheSameReplayApplyExactlyOnce() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(48), receiverID = try TestIDs.device(49)
        let task = try TestIDs.task(51)
        let key = IncrementalFixture.key(0xF0)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let firstStore = try receiverDB.makeStore(
            deviceID: receiverID,
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [(sourceID, "k1", key)]
            )
        )
        let base = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: firstStore,
            sourceID: sourceID,
            scope: .task(task)
        )
        _ = try await firstStore.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        let secondStore = try receiverDB.makeStore(
            deviceID: receiverID,
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [(sourceID, "k1", key)]
            )
        )
        _ = try await source.commitLocalRecord(
            try .test(
                entityID: try TestIDs.entity(92),
                revision: 1,
                originDeviceID: sourceID,
                taskID: task
            )
        )
        let batch = try await source.nextIncrementalBatch(
            receiverDeviceID: receiverID,
            scope: .task(task),
            subscriptionVersion: 1,
            after: base
        ).signed(keyID: "k1", key: key)
        let results = try await withThrowingTaskGroup(
            of: IncrementalApplyResult.self,
            returning: [IncrementalApplyResult].self
        ) { group in
            group.addTask {
                try await firstStore.applyAuthenticatedIncrementalBatch(batch)
            }
            group.addTask {
                try await secondStore.applyAuthenticatedIncrementalBatch(batch)
            }
            var values: [IncrementalApplyResult] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.filter { !$0.isDuplicate }.count, 1)
        XCTAssertEqual(results.filter { $0.isDuplicate }.count, 1)
        await XCTAssertEqualAsync({ try await firstStore.recordCount() }, 1)
        let subscription = try await firstStore.subscription(
            peerDeviceID: sourceID,
            scope: .task(task)
        )
        XCTAssertEqual(subscription?.appliedCursor, batch.throughCursor)
        let metadata = try await firstStore.metadata()
        XCTAssertEqual(metadata.incrementalReceiptCount, 1)
        await source.close()
        await firstStore.close()
        await secondStore.close()
    }

    func testBatchBoundsReceiptWindowAndGrantRevocationAreEnforced() async throws {
        let sourceDB = try TestDatabase(), receiverDB = try TestDatabase()
        addTeardownBlock { sourceDB.remove(); receiverDB.remove() }
        let sourceID = try TestIDs.device(50), receiverID = try TestIDs.device(51)
        let task = try TestIDs.task(52)
        let key = IncrementalFixture.key(0xF1)
        let source = try sourceDB.makeStore(deviceID: sourceID)
        let receiver = try receiverDB.makeStore(
            deviceID: receiverID,
            configuration: SyncStoreConfiguration(
                maxBatchRecords: 2,
                maxIncrementalReceipts: 2
            ),
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

        let tooMany = try IncrementalFixture.makeBatch(
            peer: sourceID,
            receiver: receiverID,
            scope: .task(task),
            from: base,
            through: try TestIDs.cursor(base.rawValue + 3),
            changes: [
                (base.rawValue + 1, try SyncRecord.test(
                    entityID: try TestIDs.entity(93),
                    revision: 1,
                    originDeviceID: sourceID,
                    taskID: task
                )),
                (base.rawValue + 2, try SyncRecord.test(
                    entityID: try TestIDs.entity(94),
                    revision: 1,
                    originDeviceID: sourceID,
                    taskID: task
                )),
                (base.rawValue + 3, try SyncRecord.test(
                    entityID: try TestIDs.entity(95),
                    revision: 1,
                    originDeviceID: sourceID,
                    taskID: task
                ))
            ]
        ).signed(keyID: "k1", key: key)
        await XCTAssertThrowsSyncError(.batchTooLarge(limit: 2)) {
            try await receiver.applyAuthenticatedIncrementalBatch(tooMany)
        }

        let tinyReceiverDB = try TestDatabase()
        addTeardownBlock { tinyReceiverDB.remove() }
        let tinyReceiver = try tinyReceiverDB.makeStore(
            deviceID: receiverID,
            configuration: SyncStoreConfiguration(maxBatchBytes: 64),
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [(sourceID, "k1", key)]
            )
        )
        let tinyBase = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: tinyReceiver,
            sourceID: sourceID,
            scope: .task(task)
        )
        _ = try await tinyReceiver.grantScopeAccess(peerDeviceID: sourceID, scope: .task(task))
        let oversizedPayload = try SyncRecord.test(
            entityID: try TestIDs.entity(96),
            revision: 1,
            originDeviceID: sourceID,
            taskID: task,
            payload: .object(["title": .string(String(repeating: "x", count: 200))])
        )
        let tooLarge = try IncrementalFixture.makeBatch(
            peer: sourceID,
            receiver: receiverID,
            scope: .task(task),
            from: tinyBase,
            through: try TestIDs.cursor(tinyBase.rawValue + 1),
            changes: [(tinyBase.rawValue + 1, oversizedPayload)]
        ).signed(keyID: "k1", key: key)
        await XCTAssertThrowsSyncError(.batchBytesTooLarge(limit: 64)) {
            try await tinyReceiver.applyAuthenticatedIncrementalBatch(tooLarge)
        }

        let payloadBoundDB = try TestDatabase()
        addTeardownBlock { payloadBoundDB.remove() }
        let payloadBound = try payloadBoundDB.makeStore(
            deviceID: receiverID,
            configuration: SyncStoreConfiguration(maxPayloadBytes: 32),
            incrementalAuthenticator: try IncrementalFixture.authenticator(
                peers: [(sourceID, "k1", key)]
            )
        )
        let payloadBase = try await IncrementalFixture.establishSubscription(
            source: source,
            receiver: payloadBound,
            sourceID: sourceID,
            scope: .task(task)
        )
        _ = try await payloadBound.grantScopeAccess(
            peerDeviceID: sourceID,
            scope: .task(task)
        )
        let oversizedRecord = try SyncRecord.test(
            entityID: try TestIDs.entity(97),
            revision: 1,
            originDeviceID: sourceID,
            taskID: task,
            payload: .object(["title": .string(String(repeating: "y", count: 200))])
        )
        let oversizedRecordBatch = try IncrementalFixture.makeBatch(
            peer: sourceID,
            receiver: receiverID,
            scope: .task(task),
            from: payloadBase,
            through: try TestIDs.cursor(payloadBase.rawValue + 1),
            changes: [(payloadBase.rawValue + 1, oversizedRecord)]
        ).signed(keyID: "k1", key: key)
        await XCTAssertThrowsSyncError(.payloadTooLarge(limit: 32)) {
            try await payloadBound.applyAuthenticatedIncrementalBatch(oversizedRecordBatch)
        }
        await XCTAssertEqualAsync({ try await payloadBound.recordCount() }, 0)

        for offset in 0..<3 {
            _ = try await source.commitLocalRecord(
                try .test(
                    entityID: try TestIDs.entity(100 + offset),
                    revision: 1,
                    originDeviceID: sourceID,
                    taskID: task
                )
            )
            let batch = try await source.nextIncrementalBatch(
                receiverDeviceID: receiverID,
                scope: .task(task),
                subscriptionVersion: 1,
                after: try TestIDs.cursor(base.rawValue + Int64(offset)),
                maxRecords: 1
            )
            _ = try await receiver.applyAuthenticatedIncrementalBatch(
                try batch.signed(keyID: "k1", key: key)
            )
        }
        let metadata = try await receiver.metadata()
        XCTAssertEqual(metadata.incrementalReceiptCount, 2)
        let firstAgain = try IncrementalFixture.makeBatch(
            peer: sourceID,
            receiver: receiverID,
            scope: .task(task),
            from: base,
            through: try TestIDs.cursor(base.rawValue + 1),
            changes: []
        ).signed(keyID: "k1", key: key)
        await XCTAssertThrowsSyncError(
            .incrementalRangeGap(
                sourceID,
                .task(task),
                expected: try TestIDs.cursor(base.rawValue + 3),
                receivedFrom: base
            )
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(firstAgain)
        }
        let revoked = try await receiver.revokeScopeAccess(
            peerDeviceID: sourceID,
            scope: .task(task)
        )
        XCTAssertTrue(revoked)
        let next = try await source.nextIncrementalBatch(
            receiverDeviceID: receiverID,
            scope: .task(task),
            subscriptionVersion: 1,
            after: try TestIDs.cursor(base.rawValue + 3)
        ).signed(keyID: "k1", key: key)
        await XCTAssertThrowsSyncError(
            .incrementalScopeUnauthorized(sourceID, .task(task))
        ) {
            try await receiver.applyAuthenticatedIncrementalBatch(next)
        }
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 3)
        await source.close()
        await receiver.close()
        await tinyReceiver.close()
        await payloadBound.close()
    }
}
