import Foundation
import XCTest
@testable import FloeDesktopSync

private struct InjectedFailure: Error {}

private final class ThrowingHookBox: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool

    init(_ enabled: Bool) {
        self.enabled = enabled
    }

    func fire() throws {
        lock.lock()
        let shouldThrow = enabled
        lock.unlock()
        if shouldThrow { throw InjectedFailure() }
    }
}

final class SnapshotReceptionTests: XCTestCase {
    private func receiveAll(
        _ manifest: SnapshotManifest,
        source: SyncStore,
        receiver: SyncStore,
        peer: DeviceID
    ) async throws {
        for index in 0..<manifest.pageCount {
            let envelope = try await source.snapshotPageEnvelope(
                manifest.snapshotID,
                manifest: manifest,
                pageIndex: index
            )
            _ = try await receiver.receiveSnapshotPageForTesting(
                peerDeviceID: peer,
                envelope: envelope
            )
        }
    }

    func testCompleteScopedSnapshotCommitsAndAdvancesOnlyItsScopeCursor() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(1)
        let receiverDevice = try TestIDs.device(2)
        let task = try TestIDs.task(3)
        let source = try sourceDatabase.makeStore(
            deviceID: sourceDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 1)
        )
        let receiver = try receiverDatabase.makeStore(
            deviceID: receiverDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 1)
        )

        let x = try TestIDs.entity(100)
        let y = try TestIDs.entity(101)
        let z = try TestIDs.entity(102)
        for entity in [x, y, z] {
            _ = try await source.commitLocalRecord(
                try SyncRecord.test(
                    entityID: entity,
                    revision: 1,
                    originDeviceID: sourceDevice,
                    taskID: task,
                    payload: .object(["title": .string(entity.canonical)])
                )
            )
        }
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: y,
                revision: 2,
                baseRevision: 1,
                originDeviceID: sourceDevice,
                taskID: task,
                payload: .null,
                deleted: true
            )
        )

        let descriptor = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(
            descriptor.snapshotID,
            pageSize: 1
        )
        XCTAssertEqual(manifest.pageCount, 3)
        XCTAssertEqual(manifest.recordCount, 2)
        XCTAssertEqual(manifest.tombstoneCount, 1)
        XCTAssertEqual(manifest.entryCount, 3)
        XCTAssertEqual(
            try SnapshotManifest(wireJSON: manifest.wireJSON()),
            manifest
        )

        let progress = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifest,
            subscriptionVersion: 1
        )
        XCTAssertEqual(progress.state, .staging)
        XCTAssertEqual(progress.receivedPageCount, 0)
        try await receiveAll(
            manifest,
            source: source,
            receiver: receiver,
            peer: sourceDevice
        )
        let staged = try await receiver.snapshotImportStatus(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertEqual(staged?.receivedPageCount, 3)
        XCTAssertEqual(staged?.receivedEntryCount, 3)
        XCTAssertTrue(staged?.isComplete == true)

        // Staging is not visible state and holds no cursor yet.
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)
        await XCTAssertEqualAsync({ try await receiver.recordCount(includingDeleted: true) }, 0)

        let result = try await receiver.commitSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertFalse(result.isDuplicate)
        XCTAssertEqual(result.applied.count, 3)
        XCTAssertEqual(result.conflicts, [])
        XCTAssertEqual(result.unreconciledLocalKeys, [])
        XCTAssertEqual(result.baseCursor, descriptor.baseCursor)

        let storedX = try await receiver.storedRecord(kind: .task, entityID: x)
        let storedY = try await receiver.storedRecord(kind: .task, entityID: y)
        let storedZ = try await receiver.storedRecord(kind: .task, entityID: z)
        XCTAssertEqual(storedX?.record.deleted, false)
        XCTAssertEqual(storedY?.record.deleted, true)
        XCTAssertEqual(storedY?.record.revision, try TestIDs.revision(2))
        XCTAssertEqual(storedZ?.record.deleted, false)
        XCTAssertEqual(storedX?.localDirty, false)

        let subscription = try await receiver.subscription(
            peerDeviceID: sourceDevice,
            scope: .task(task)
        )
        XCTAssertEqual(subscription?.established, true)
        XCTAssertEqual(subscription?.version, 1)
        XCTAssertEqual(subscription?.appliedCursor, descriptor.baseCursor)
        XCTAssertEqual(subscription?.lastSnapshotID, descriptor.snapshotID)
        // The peer-wide legacy cursor remains untouched and cannot claim this
        // scope is complete.
        await XCTAssertEqualAsync(
            { try await receiver.appliedCursor(for: sourceDevice) },
            .zero
        )

        let duplicate = try await receiver.commitSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertTrue(duplicate.isDuplicate)
        XCTAssertEqual(duplicate.applied.count, 3)

        // Incremental sync must not advance without a verified scan interval.
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(103),
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: task,
                payload: .object(["title": .string("after")])
            )
        )
        let changes = try await source.changes(after: descriptor.baseCursor)
        XCTAssertEqual(changes.entries.count, 1)
        let records = changes.entries.compactMap { $0.makeRecord() }
        await XCTAssertThrowsSyncError(.scopedIncrementalUnverified) {
            _ = try await receiver.applyScopedRemoteBatch(
                peerDeviceID: sourceDevice, scope: .task(task),
                through: changes.nextCursor, records: records
            )
        }
        let advanced = try await receiver.subscription(
            peerDeviceID: sourceDevice,
            scope: .task(task)
        )
        XCTAssertEqual(advanced?.appliedCursor, descriptor.baseCursor)
        await XCTAssertEqualAsync(
            { try await receiver.appliedCursor(for: sourceDevice) },
            .zero
        )

        await source.close()
        await receiver.close()
    }

    func testStagingSurvivesRestartAndDualConnectionSeesPages() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(10)
        let receiverDevice = try TestIDs.device(11)
        let task = try TestIDs.task(12)
        let source = try sourceDatabase.makeStore(
            deviceID: sourceDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 2)
        )
        for offset in 0..<5 {
            _ = try await source.commitLocalRecord(
                try SyncRecord.test(
                    entityID: try TestIDs.entity(200 + offset),
                    revision: 1,
                    originDeviceID: sourceDevice,
                    taskID: task
                )
            )
        }
        let descriptor = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(
            descriptor.snapshotID,
            pageSize: 2
        )
        XCTAssertEqual(manifest.pageCount, 3)

        let first = try receiverDatabase.makeStore(
            deviceID: receiverDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 2)
        )
        var second: SyncStore? = try receiverDatabase.makeStore(
            deviceID: receiverDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 2)
        )
        _ = try await first.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifest,
            subscriptionVersion: 1
        )
        let firstEnvelope = try await source.snapshotPageEnvelope(
            descriptor.snapshotID,
            manifest: manifest,
            pageIndex: 0
        )
        _ = try await first.receiveSnapshotPageForTesting(
            peerDeviceID: sourceDevice,
            envelope: firstEnvelope
        )
        // A second SQLite connection observes the same durable staging row.
        let observed = try await second!.snapshotImportStatus(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertEqual(observed?.receivedPageCount, 1)
        let secondEnvelope = try await source.snapshotPageEnvelope(
            descriptor.snapshotID,
            manifest: manifest,
            pageIndex: 1
        )
        _ = try await second!.receiveSnapshotPageForTesting(
            peerDeviceID: sourceDevice,
            envelope: secondEnvelope
        )
        let duplicate = try await second!.receiveSnapshotPageForTesting(
            peerDeviceID: sourceDevice,
            envelope: firstEnvelope
        )
        XCTAssertEqual(duplicate.receivedPageCount, 2)
        await second!.close()
        await first.close()
        second = nil

        // Reopen after a process-style close; staging is recovered from disk.
        let reopened = try receiverDatabase.makeStore(
            deviceID: receiverDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 2)
        )
        let recovered = try await reopened.snapshotImportStatus(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertEqual(recovered?.receivedPageCount, 2)
        let lastEnvelope = try await source.snapshotPageEnvelope(
            descriptor.snapshotID,
            manifest: manifest,
            pageIndex: 2
        )
        _ = try await reopened.receiveSnapshotPageForTesting(
            peerDeviceID: sourceDevice,
            envelope: lastEnvelope
        )
        let result = try await reopened.commitSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertEqual(result.applied.count, 5)
        await XCTAssertEqualAsync({ try await reopened.recordCount() }, 5)
        await reopened.close()
        await source.close()
    }

    func testDualConnectionCommitIsIdempotentAndOnlyOnePublishes() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(20)
        let receiverDevice = try TestIDs.device(21)
        let task = try TestIDs.task(22)
        let source = try sourceDatabase.makeStore(
            deviceID: sourceDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 2)
        )
        let receiverA = try receiverDatabase.makeStore(
            deviceID: receiverDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 2)
        )
        let receiverB = try receiverDatabase.makeStore(
            deviceID: receiverDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 2)
        )
        for offset in 0..<4 {
            _ = try await source.commitLocalRecord(
                try SyncRecord.test(
                    entityID: try TestIDs.entity(300 + offset),
                    revision: 1,
                    originDeviceID: sourceDevice,
                    taskID: task
                )
            )
        }
        let descriptor = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(
            descriptor.snapshotID,
            pageSize: 2
        )
        _ = try await receiverA.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifest,
            subscriptionVersion: 1
        )
        try await receiveAll(
            manifest,
            source: source,
            receiver: receiverA,
            peer: sourceDevice
        )

        async let a = receiverA.commitSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        async let b = receiverB.commitSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        let results = try await [a, b]
        XCTAssertEqual(results.filter { !$0.isDuplicate }.count, 1)
        XCTAssertEqual(results.filter { $0.isDuplicate }.count, 1)
        let subscriptionA = try await receiverA.subscription(
            peerDeviceID: sourceDevice,
            scope: .task(task)
        )
        let subscriptionB = try await receiverB.subscription(
            peerDeviceID: sourceDevice,
            scope: .task(task)
        )
        XCTAssertEqual(subscriptionA, subscriptionB)
        await XCTAssertEqualAsync({ try await receiverB.recordCount() }, 4)
        await receiverA.close()
        await receiverB.close()
        await source.close()
    }

    func testOutOfOrderMissingTamperedAndConflictingPagesAreRejected() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(30)
        let receiverDevice = try TestIDs.device(31)
        let task = try TestIDs.task(32)
        let source = try sourceDatabase.makeStore(
            deviceID: sourceDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 2)
        )
        for offset in 0..<4 {
            _ = try await source.commitLocalRecord(
                try SyncRecord.test(
                    entityID: try TestIDs.entity(400 + offset),
                    revision: 1,
                    originDeviceID: sourceDevice,
                    taskID: task,
                    payload: .object(["title": .string("v\(offset)")])
                )
            )
        }
        let descriptor = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(
            descriptor.snapshotID,
            pageSize: 2
        )
        let receiver = try receiverDatabase.makeStore(
            deviceID: receiverDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 2)
        )
        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifest,
            subscriptionVersion: 1
        )
        let page0 = try await source.snapshotPageEnvelope(
            descriptor.snapshotID,
            manifest: manifest,
            pageIndex: 0
        )
        let page1 = try await source.snapshotPageEnvelope(
            descriptor.snapshotID,
            manifest: manifest,
            pageIndex: 1
        )

        await XCTAssertThrowsSyncError(
            .snapshotPageOutOfOrder(expected: 0, received: 1)
        ) {
            _ = try await receiver.receiveSnapshotPageForTesting(
                peerDeviceID: sourceDevice,
                envelope: page1
            )
        }
        let tampered = SnapshotPageEnvelope(
            snapshotID: page0.snapshotID,
            originDeviceID: page0.originDeviceID,
            pageIndex: page0.pageIndex,
            firstPosition: page0.firstPosition,
            lastPosition: page0.lastPosition,
            records: page0.records.map {
                SyncRecord(
                    kind: $0.kind,
                    entityID: $0.entityID,
                    taskID: $0.taskID,
                    workspaceID: $0.workspaceID,
                    revision: $0.revision,
                    baseRevision: $0.baseRevision,
                    baseDigest: $0.baseDigest,
                    originDeviceID: $0.originDeviceID,
                    payload: .object(["title": .string("y0")]),
                    deleted: $0.deleted
                )
            },
            digest: page0.digest,
            manifestDigest: manifest.digest
        )
        await XCTAssertThrowsSyncError(
            .snapshotPageDigestMismatch(
                expected: manifest.pages[0].digest,
                received: SnapshotDigest.pageDigest(tampered.records)
            )
        ) {
            _ = try await receiver.receiveSnapshotPageForTesting(
                peerDeviceID: sourceDevice,
                envelope: tampered
            )
        }
        _ = try await receiver.receiveSnapshotPageForTesting(
            peerDeviceID: sourceDevice,
            envelope: page0
        )
        await XCTAssertThrowsSyncError(
            .snapshotPagesIncomplete(received: 1, expected: 2)
        ) {
            _ = try await receiver.commitSnapshotImportForTesting(
                peerDeviceID: sourceDevice,
                snapshotID: descriptor.snapshotID
            )
        }
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)
        await XCTAssertEqualAsync(
            { try await receiver.appliedCursor(for: sourceDevice) },
            .zero
        )

        let reversedRecords = Array(page0.records.reversed())
        let conflicting = SnapshotPageEnvelope(
            snapshotID: page0.snapshotID,
            originDeviceID: page0.originDeviceID,
            pageIndex: page0.pageIndex,
            firstPosition: page0.firstPosition,
            lastPosition: page0.lastPosition,
            records: reversedRecords,
            digest: SnapshotDigest.pageDigest(reversedRecords),
            manifestDigest: manifest.digest
        )
        await XCTAssertThrowsSyncError(
            .snapshotPageConflict(
                sourceDevice,
                descriptor.snapshotID,
                pageIndex: 0
            )
        ) {
            _ = try await receiver.receiveSnapshotPageForTesting(
                peerDeviceID: sourceDevice,
                envelope: conflicting
            )
        }

        // Same snapshot identity with a different manifest is refused.
        let alteredCreatedAt = manifest.createdAt.addingTimeInterval(1)
        let alteredDigest = SnapshotDigest.manifestDigest(
            protocolVersion: manifest.protocolVersion,
            snapshotID: manifest.snapshotID,
            originDeviceID: manifest.originDeviceID,
            scope: manifest.scope,
            baseCursor: manifest.baseCursor,
            recordCount: manifest.recordCount,
            tombstoneCount: manifest.tombstoneCount,
            entryCount: manifest.entryCount,
            pageSize: manifest.pageSize,
            pages: manifest.pages,
            createdAt: alteredCreatedAt,
            expiresAt: manifest.expiresAt
        )
        let alteredManifest = SnapshotManifest(
            snapshotID: manifest.snapshotID,
            originDeviceID: manifest.originDeviceID,
            scope: manifest.scope,
            baseCursor: manifest.baseCursor,
            recordCount: manifest.recordCount,
            tombstoneCount: manifest.tombstoneCount,
            entryCount: manifest.entryCount,
            pageSize: manifest.pageSize,
            pages: manifest.pages,
            digest: alteredDigest,
            createdAt: alteredCreatedAt,
            expiresAt: manifest.expiresAt
        )
        let secondReceiver = try receiverDatabase.makeStore(deviceID: receiverDevice)
        await XCTAssertThrowsSyncError(
            .snapshotIdentityConflict(sourceDevice, descriptor.snapshotID)
        ) {
            _ = try await secondReceiver.beginSnapshotImportForTesting(
                peerDeviceID: sourceDevice,
                manifest: alteredManifest,
                subscriptionVersion: 1
            )
        }

        await receiver.close()
        await secondReceiver.close()
        await source.close()
    }

    func testTamperedManifestIsRefusedBeforeStaging() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(40)
        let receiverDevice = try TestIDs.device(41)
        let task = try TestIDs.task(42)
        let source = try sourceDatabase.makeStore(deviceID: sourceDevice)
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(500),
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: task
            )
        )
        let descriptor = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(descriptor.snapshotID)
        let tampered = SnapshotManifest(
            snapshotID: manifest.snapshotID,
            originDeviceID: manifest.originDeviceID,
            scope: manifest.scope,
            baseCursor: manifest.baseCursor,
            recordCount: manifest.recordCount,
            tombstoneCount: manifest.tombstoneCount,
            entryCount: manifest.entryCount,
            pageSize: manifest.pageSize,
            pages: manifest.pages,
            digest: ContentDigest.compute([0x00]),
            createdAt: manifest.createdAt,
            expiresAt: manifest.expiresAt
        )
        let receiver = try receiverDatabase.makeStore(deviceID: receiverDevice)
        await XCTAssertThrowsSyncError(.snapshotManifestDigestMismatch) {
            _ = try await receiver.beginSnapshotImportForTesting(
                peerDeviceID: sourceDevice,
                manifest: tampered,
                subscriptionVersion: 1
            )
        }
        // A wire manifest whose pages and digest are not self-consistent is
        // rejected by the same validation before any row is written.
        var wire = manifest.wireJSONValue()
        if case .object(var object) = wire {
            object["recordCount"] = .string(String(manifest.recordCount + 1))
            wire = .object(object)
        }
        XCTAssertThrowsError(try SnapshotManifest(wireValue: wire)) { error in
            XCTAssertEqual(error as? SyncStoreError, .snapshotManifestInvalid(
                "entry count does not equal live plus tombstone counts"
            ))
        }
        let overflowing = SnapshotManifest(
            snapshotID: manifest.snapshotID,
            originDeviceID: manifest.originDeviceID,
            scope: manifest.scope,
            baseCursor: manifest.baseCursor,
            recordCount: Int.max,
            tombstoneCount: 1,
            entryCount: 0,
            pageSize: 1,
            pages: [],
            digest: ContentDigest.compute([0x01]),
            createdAt: manifest.createdAt,
            expiresAt: manifest.expiresAt
        )
        XCTAssertThrowsError(try overflowing.validate())
        let statuses = try await receiver.subscriptions()
        XCTAssertEqual(statuses, [])
        await receiver.close()
        await source.close()
    }

    func testDirtyLocalAndUnseenLocalRecordsArePreservedWithPersistedConflict() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(50)
        let receiverDevice = try TestIDs.device(51)
        let task = try TestIDs.task(52)
        let source = try sourceDatabase.makeStore(deviceID: sourceDevice)
        let receiver = try receiverDatabase.makeStore(deviceID: receiverDevice)
        let x = try TestIDs.entity(600)

        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: x,
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: task,
                payload: .object(["title": .string("source-v1")])
            )
        )
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: x,
                revision: 2,
                baseRevision: 1,
                originDeviceID: sourceDevice,
                taskID: task,
                payload: .object(["title": .string("source-v2")])
            )
        )
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(601),
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: task
            )
        )
        _ = try await receiver.commitLocalRecord(
            try SyncRecord.test(
                entityID: x,
                revision: 1,
                originDeviceID: receiverDevice,
                taskID: task,
                payload: .object(["title": .string("local-dirty")])
            )
        )
        let localOnly = try TestIDs.entity(999)
        _ = try await receiver.commitLocalRecord(
            try SyncRecord.test(
                entityID: localOnly,
                revision: 1,
                originDeviceID: receiverDevice,
                taskID: task,
                payload: .object(["title": .string("local-only")])
            )
        )
        let ackedLocalOnly = try TestIDs.entity(998)
        _ = try await receiver.commitLocalRecord(
            try SyncRecord.test(
                entityID: ackedLocalOnly,
                revision: 1,
                originDeviceID: receiverDevice,
                taskID: task,
                payload: .object(["title": .string("acked-local-only")])
            )
        )
        _ = try await receiver.acknowledgeLocalRecord(
            kind: .task,
            entityID: ackedLocalOnly,
            revision: try TestIDs.revision(1)
        )

        let descriptor = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(
            descriptor.snapshotID,
            pageSize: 2
        )
        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifest,
            subscriptionVersion: 1
        )
        try await receiveAll(
            manifest,
            source: source,
            receiver: receiver,
            peer: sourceDevice
        )
        let result = try await receiver.commitSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertEqual(result.applied.map(\.entityID), [try TestIDs.entity(601)])
        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.conflicts.first?.reason, .localUnsyncedEdit)
        XCTAssertEqual(
            Set(result.unreconciledLocalKeys.map(\.entityID)),
            Set([localOnly, ackedLocalOnly])
        )

        let preservedX = try await receiver.storedRecord(kind: .task, entityID: x)
        XCTAssertEqual(preservedX?.record.payload["title"]?.stringValue, "local-dirty")
        XCTAssertEqual(preservedX?.localDirty, true)
        let preservedLocal = try await receiver.storedRecord(
            kind: .task,
            entityID: localOnly
        )
        XCTAssertEqual(preservedLocal?.record.payload["title"]?.stringValue, "local-only")
        let sourceRecord = try await receiver.storedRecord(
            kind: .task,
            entityID: try TestIDs.entity(601)
        )
        XCTAssertNotNil(sourceRecord)
        await receiver.close()

        let reopened = try receiverDatabase.makeStore(deviceID: receiverDevice)
        let conflicts = try await reopened.conflicts()
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.local.payload["title"]?.stringValue, "local-dirty")
        XCTAssertEqual(conflicts.first?.incoming.payload["title"]?.stringValue, "source-v2")
        XCTAssertEqual(conflicts.first?.incoming.revision, try TestIDs.revision(2))
        let committedReceipt = try await reopened.snapshotImportStatus(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertEqual(
            Set(committedReceipt?.committedResult?.unreconciledLocalKeys.map(\.entityID) ?? []),
            Set([localOnly, ackedLocalOnly])
        )
        await reopened.close()
        await source.close()
    }

    func testSnapshotTombstonesAndSameContentDirtyAcknowledgement() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(60)
        let receiverDevice = try TestIDs.device(61)
        let task = try TestIDs.task(62)
        let source = try sourceDatabase.makeStore(deviceID: sourceDevice)
        let receiver = try receiverDatabase.makeStore(deviceID: receiverDevice)
        let deleted = try TestIDs.entity(700)
        let same = try TestIDs.entity(701)
        let absentTombstone = try TestIDs.entity(702)

        let baselinePayload: JSONValue = .object(["title": .string("baseline")])
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: deleted,
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: task,
                payload: baselinePayload
            )
        )
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: deleted,
                revision: 2,
                baseRevision: 1,
                originDeviceID: sourceDevice,
                taskID: task,
                payload: .null,
                deleted: true
            )
        )
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: same,
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: task,
                payload: .object(["title": .string("same")])
            )
        )
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: absentTombstone,
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: task,
                payload: .null,
                deleted: true
            )
        )
        _ = try await receiver.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: sourceDevice,
                through: try TestIDs.cursor(1),
                records: [
                    try SyncRecord.test(
                        entityID: deleted,
                        revision: 1,
                        originDeviceID: sourceDevice,
                        taskID: task,
                        payload: baselinePayload
                    )
                ]
            )
        )
        _ = try await receiver.acknowledgeLocalRecord(
            kind: .task,
            entityID: deleted,
            revision: try TestIDs.revision(1)
        )
        _ = try await receiver.commitLocalRecord(
            try SyncRecord.test(
                entityID: same,
                revision: 1,
                originDeviceID: receiverDevice,
                taskID: task,
                payload: .object(["title": .string("same")])
            )
        )
        let sameBeforeCommit = try await receiver.storedRecord(
            kind: .task,
            entityID: same
        )
        XCTAssertEqual(sameBeforeCommit?.localDirty, true)

        let descriptor = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(descriptor.snapshotID)
        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifest,
            subscriptionVersion: 1
        )
        try await receiveAll(
            manifest,
            source: source,
            receiver: receiver,
            peer: sourceDevice
        )
        let result = try await receiver.commitSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertEqual(result.conflicts, [])
        let tombstoned = try await receiver.storedRecord(kind: .task, entityID: deleted)
        XCTAssertEqual(tombstoned?.record.deleted, true)
        XCTAssertEqual(tombstoned?.record.revision, try TestIDs.revision(2))
        let acknowledged = try await receiver.storedRecord(kind: .task, entityID: same)
        XCTAssertEqual(acknowledged?.localDirty, false)
        let insertedTombstone = try await receiver.storedRecord(
            kind: .task,
            entityID: absentTombstone
        )
        XCTAssertEqual(insertedTombstone?.record.deleted, true)

        // The committed tombstone is itself exportable by a later snapshot.
        let next = try await receiver.openSnapshot(scope: .task(task))
        XCTAssertEqual(next.tombstoneCount, 2)
        await receiver.close()
        await source.close()
    }

    func testEmptySnapshotCommitsWithoutDeletingLocalRecords() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(70)
        let receiverDevice = try TestIDs.device(71)
        let task = try TestIDs.task(72)
        let source = try sourceDatabase.makeStore(deviceID: sourceDevice)
        let receiver = try receiverDatabase.makeStore(deviceID: receiverDevice)
        let localOnly = try TestIDs.entity(800)
        _ = try await receiver.commitLocalRecord(
            try SyncRecord.test(
                entityID: localOnly,
                revision: 1,
                originDeviceID: receiverDevice,
                taskID: task
            )
        )
        let descriptor = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(descriptor.snapshotID)
        XCTAssertEqual(manifest.entryCount, 0)
        XCTAssertEqual(manifest.pageCount, 0)
        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifest,
            subscriptionVersion: 1
        )
        let result = try await receiver.commitSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertEqual(result.applied, [])
        XCTAssertEqual(result.unreconciledLocalKeys.map(\.entityID), [localOnly])
        let preserved = try await receiver.storedRecord(kind: .task, entityID: localOnly)
        XCTAssertNotNil(preserved)
        let subscription = try await receiver.subscription(
            peerDeviceID: sourceDevice,
            scope: .task(task)
        )
        XCTAssertEqual(subscription?.established, true)
        XCTAssertEqual(subscription?.appliedCursor, descriptor.baseCursor)
        await receiver.close()
        await source.close()
    }

    func testSamePeerScopeExpansionKeepsCursorsIndependentAndResetRejectsOldSnapshot() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(80)
        let receiverDevice = try TestIDs.device(81)
        let taskA = try TestIDs.task(82)
        let taskB = try TestIDs.task(83)
        let source = try sourceDatabase.makeStore(deviceID: sourceDevice)
        let receiver = try receiverDatabase.makeStore(deviceID: receiverDevice)

        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(900),
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: taskA
            )
        )
        let snapshotA = try await source.openSnapshot(scope: .task(taskA))
        let manifestA = try await source.snapshotManifest(snapshotA.snapshotID)
        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifestA,
            subscriptionVersion: 1
        )
        try await receiveAll(
            manifestA,
            source: source,
            receiver: receiver,
            peer: sourceDevice
        )
        _ = try await receiver.commitSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            snapshotID: snapshotA.snapshotID
        )
        let cursorA = try await receiver.subscription(
            peerDeviceID: sourceDevice,
            scope: .task(taskA)
        )?.appliedCursor

        // Cancelling a newer staging session must leave the already
        // established subscription and visible record untouched.
        let cancellableSnapshot = try await source.openSnapshot(scope: .task(taskA))
        let cancellableManifest = try await source.snapshotManifest(
            cancellableSnapshot.snapshotID
        )
        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: cancellableManifest,
            subscriptionVersion: 1
        )
        let cancellablePage = try await source.snapshotPageEnvelope(
            cancellableSnapshot.snapshotID,
            manifest: cancellableManifest,
            pageIndex: 0
        )
        _ = try await receiver.receiveSnapshotPageForTesting(
            peerDeviceID: sourceDevice,
            envelope: cancellablePage
        )
        let cancelled = try await receiver.abortSnapshotImport(
            peerDeviceID: sourceDevice,
            snapshotID: cancellableSnapshot.snapshotID
        )
        XCTAssertTrue(cancelled)
        let afterCancel = try await receiver.subscription(
            peerDeviceID: sourceDevice,
            scope: .task(taskA)
        )
        XCTAssertEqual(afterCancel?.established, true)
        XCTAssertEqual(afterCancel?.appliedCursor, cursorA)
        let afterCancelRecord = try await receiver.storedRecord(
            kind: .task,
            entityID: try TestIDs.entity(900)
        )
        XCTAssertEqual(afterCancelRecord?.record.deleted, false)

        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(901),
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: taskB
            )
        )
        let snapshotB = try await source.openSnapshot(scope: .task(taskB))
        let manifestB = try await source.snapshotManifest(snapshotB.snapshotID)
        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifestB,
            subscriptionVersion: 1
        )
        try await receiveAll(
            manifestB,
            source: source,
            receiver: receiver,
            peer: sourceDevice
        )
        _ = try await receiver.commitSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            snapshotID: snapshotB.snapshotID
        )
        let subscriptions = try await receiver.subscriptions(peerDeviceID: sourceDevice)
        XCTAssertEqual(subscriptions.count, 2)
        XCTAssertEqual(
            subscriptions.first { $0.scope == .task(taskA) }?.appliedCursor,
            cursorA
        )
        XCTAssertEqual(
            subscriptions.first { $0.scope == .task(taskB) }?.appliedCursor,
            snapshotB.baseCursor
        )
        let recordA = try await receiver.storedRecord(
            kind: .task,
            entityID: try TestIDs.entity(900)
        )
        XCTAssertEqual(recordA?.record.taskID, taskA)

        // A newer generation invalidates an in-flight snapshot from the old
        // generation. The old visible state and old cursor stay intact.
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(902),
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: taskA
            )
        )
        let staleSnapshot = try await source.openSnapshot(scope: .task(taskA))
        let staleManifest = try await source.snapshotManifest(staleSnapshot.snapshotID)
        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: staleManifest,
            subscriptionVersion: 1
        )
        _ = try await receiver.resetSubscription(
            peerDeviceID: sourceDevice,
            scope: .task(taskA),
            version: 2
        )
        await XCTAssertThrowsSyncError(
            .snapshotImportNotFound(sourceDevice, staleSnapshot.snapshotID)
        ) {
            _ = try await receiver.commitSnapshotImportForTesting(
                peerDeviceID: sourceDevice,
                snapshotID: staleSnapshot.snapshotID
            )
        }
        await XCTAssertThrowsSyncError(
            .subscriptionVersionMismatch(
                sourceDevice,
                .task(taskA),
                expected: 1,
                found: 2
            )
        ) {
            _ = try await receiver.beginSnapshotImportForTesting(
                peerDeviceID: sourceDevice,
                manifest: staleManifest,
                subscriptionVersion: 1
            )
        }
        let afterReset = try await receiver.subscription(
            peerDeviceID: sourceDevice,
            scope: .task(taskA)
        )
        XCTAssertEqual(afterReset?.version, 2)
        XCTAssertEqual(afterReset?.established, false)
        XCTAssertEqual(afterReset?.appliedCursor, .zero)
        let recordAfterReset = try await receiver.storedRecord(
            kind: .task,
            entityID: try TestIDs.entity(900)
        )
        XCTAssertEqual(recordAfterReset?.record.deleted, false)
        await receiver.close()
        await source.close()
    }

    func testLimitsConcurrencyExpiryAndAbortDoNotPublishPartialState() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(90)
        let receiverDevice = try TestIDs.device(91)
        let taskA = try TestIDs.task(92)
        let taskB = try TestIDs.task(93)
        let clock = TestClock()
        let source = try sourceDatabase.makeStore(
            deviceID: sourceDevice,
            clock: clock,
            configuration: SyncStoreConfiguration(snapshotLifetime: 60, maxPageSize: 1)
        )
        let receiver = try receiverDatabase.makeStore(
            deviceID: receiverDevice,
            clock: clock,
            configuration: SyncStoreConfiguration(
                snapshotLifetime: 60,
                maxPageSize: 1,
                maxConcurrentSnapshotImports: 1,
                maxSnapshotPages: 4,
                maxStagingBytes: 4_096
            )
        )
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(1_000),
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: taskA
            )
        )
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(1_001),
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: taskB
            )
        )
        let snapshotA = try await source.openSnapshot(scope: .task(taskA))
        let manifestA = try await source.snapshotManifest(snapshotA.snapshotID)
        let snapshotB = try await source.openSnapshot(scope: .task(taskB))
        let manifestB = try await source.snapshotManifest(snapshotB.snapshotID)

        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifestA,
            subscriptionVersion: 1
        )
        await XCTAssertThrowsSyncError(
            .snapshotStagingLimitExceeded(
                "at most 1 snapshots may stage at once"
            )
        ) {
            _ = try await receiver.beginSnapshotImportForTesting(
                peerDeviceID: sourceDevice,
                manifest: manifestB,
                subscriptionVersion: 1
            )
        }
        let pageA = try await source.snapshotPageEnvelope(
            snapshotA.snapshotID,
            manifest: manifestA,
            pageIndex: 0
        )
        _ = try await receiver.receiveSnapshotPageForTesting(
            peerDeviceID: sourceDevice,
            envelope: pageA
        )
        // Abort discards staging only; no visible record or cursor appears.
        let aborted = try await receiver.abortSnapshotImport(
            peerDeviceID: sourceDevice,
            snapshotID: snapshotA.snapshotID
        )
        XCTAssertTrue(aborted)
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)
        let subscriptionAfterAbort = try await receiver.subscription(
            peerDeviceID: sourceDevice,
            scope: .task(taskA)
        )
        XCTAssertEqual(subscriptionAfterAbort?.established, false)
        XCTAssertEqual(subscriptionAfterAbort?.appliedCursor, .zero)
        let abortedStatus = try await receiver.snapshotImportStatus(
            peerDeviceID: sourceDevice,
            snapshotID: snapshotA.snapshotID
        )
        XCTAssertNil(abortedStatus)

        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifestB,
            subscriptionVersion: 1
        )
        let pageB = try await source.snapshotPageEnvelope(
            snapshotB.snapshotID,
            manifest: manifestB,
            pageIndex: 0
        )
        clock.advance(61)
        await XCTAssertThrowsSyncError(
            .snapshotImportExpired(sourceDevice, snapshotB.snapshotID)
        ) {
            _ = try await receiver.receiveSnapshotPageForTesting(
                peerDeviceID: sourceDevice,
                envelope: pageB
            )
        }
        await XCTAssertThrowsSyncError(
            .snapshotImportExpired(sourceDevice, snapshotB.snapshotID)
        ) {
            _ = try await receiver.commitSnapshotImportForTesting(
                peerDeviceID: sourceDevice,
                snapshotID: snapshotB.snapshotID
            )
        }
        let pruned = try await receiver.pruneExpiredSnapshotImports()
        XCTAssertEqual(pruned, 1)
        let expiredStatus = try await receiver.snapshotImportStatus(
            peerDeviceID: sourceDevice,
            snapshotID: snapshotB.snapshotID
        )
        XCTAssertNil(expiredStatus)
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)
        await receiver.close()
        await source.close()
    }

    func testGlobalStagingBytesAreBoundedAcrossTwoScopes() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(95)
        let receiverDevice = try TestIDs.device(96)
        let taskA = try TestIDs.task(97)
        let taskB = try TestIDs.task(98)
        let source = try sourceDatabase.makeStore(
            deviceID: sourceDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 1)
        )
        let payload = JSONValue.object(["title": .string(String(repeating: "x", count: 300))])
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(1_100),
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: taskA,
                payload: payload
            )
        )
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(1_101),
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: taskB,
                payload: payload
            )
        )
        let snapshotA = try await source.openSnapshot(scope: .task(taskA))
        let manifestA = try await source.snapshotManifest(snapshotA.snapshotID)
        let snapshotB = try await source.openSnapshot(scope: .task(taskB))
        let manifestB = try await source.snapshotManifest(snapshotB.snapshotID)
        XCTAssertLessThan(
            manifestA.pages[0].byteCount + 256,
            1_024
        )
        let receiver = try receiverDatabase.makeStore(
            deviceID: receiverDevice,
            configuration: SyncStoreConfiguration(
                maxPageSize: 1,
                maxConcurrentSnapshotImports: 2,
                maxStagingBytes: 1_024
            )
        )
        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifestA,
            subscriptionVersion: 1
        )
        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifestB,
            subscriptionVersion: 1
        )
        let pageA = try await source.snapshotPageEnvelope(
            snapshotA.snapshotID,
            manifest: manifestA,
            pageIndex: 0
        )
        _ = try await receiver.receiveSnapshotPageForTesting(
            peerDeviceID: sourceDevice,
            envelope: pageA
        )
        let pageB = try await source.snapshotPageEnvelope(
            snapshotB.snapshotID,
            manifest: manifestB,
            pageIndex: 0
        )
        await XCTAssertThrowsSyncError(
            .snapshotStagingLimitExceeded("global staged byte limit reached")
        ) {
            _ = try await receiver.receiveSnapshotPageForTesting(
                peerDeviceID: sourceDevice,
                envelope: pageB
            )
        }
        let statusB = try await receiver.snapshotImportStatus(
            peerDeviceID: sourceDevice,
            snapshotID: snapshotB.snapshotID
        )
        XCTAssertEqual(statusB?.receivedPageCount, 0)
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)

        // A manifest that declares more pages than the receiver accepts is
        // refused before any page is staged.
        let tightReceiver = try receiverDatabase.makeStore(
            deviceID: receiverDevice,
            configuration: SyncStoreConfiguration(
                maxPageSize: 1,
                maxSnapshotPages: 1
            )
        )
        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(1_102),
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: taskA
            )
        )
        let wideSnapshot = try await source.openSnapshot(scope: .task(taskA))
        let wideManifest = try await source.snapshotManifest(
            wideSnapshot.snapshotID,
            pageSize: 1
        )
        await XCTAssertThrowsSyncError(
            .snapshotTooLarge(
                "snapshot has \(wideManifest.pageCount) pages, limit is 1"
            )
        ) {
            _ = try await tightReceiver.beginSnapshotImportForTesting(
                peerDeviceID: sourceDevice,
                manifest: wideManifest,
                subscriptionVersion: 1
            )
        }
        await tightReceiver.close()
        await receiver.close()
        await source.close()
    }

    func testHalfStagedPageAndCommitCrashRollBackCompletely() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(110)
        let receiverDevice = try TestIDs.device(111)
        let task = try TestIDs.task(112)
        let source = try sourceDatabase.makeStore(
            deviceID: sourceDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 1)
        )
        for offset in 0..<2 {
            _ = try await source.commitLocalRecord(
                try SyncRecord.test(
                    entityID: try TestIDs.entity(1_200 + offset),
                    revision: 1,
                    originDeviceID: sourceDevice,
                    taskID: task
                )
            )
        }
        let descriptor = try await source.openSnapshot(scope: .task(task))
        let manifest = try await source.snapshotManifest(
            descriptor.snapshotID,
            pageSize: 1
        )
        let page0 = try await source.snapshotPageEnvelope(
            descriptor.snapshotID,
            manifest: manifest,
            pageIndex: 0
        )

        let pageHook = ThrowingHookBox(true)
        var pageHooks = SyncStoreTestHooks()
        pageHooks.afterSnapshotPageStaged = { try pageHook.fire() }
        let failingPageStore = try receiverDatabase.makeStore(
            deviceID: receiverDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 1),
            testHooks: pageHooks
        )
        _ = try await failingPageStore.beginSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            manifest: manifest,
            subscriptionVersion: 1
        )
        do {
            _ = try await failingPageStore.receiveSnapshotPageForTesting(
                peerDeviceID: sourceDevice,
                envelope: page0
            )
            XCTFail("expected the injected page failure")
        } catch {
            XCTAssertFalse(error is SyncStoreError)
        }
        let afterHalfPage = try await failingPageStore.snapshotImportStatus(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertEqual(afterHalfPage?.receivedPageCount, 0)
        XCTAssertEqual(afterHalfPage?.stagedBytes, 0)
        await failingPageStore.close()

        let commitHook = ThrowingHookBox(true)
        var commitHooks = SyncStoreTestHooks()
        commitHooks.beforeSnapshotCommitFinalize = { try commitHook.fire() }
        let failingCommitStore = try receiverDatabase.makeStore(
            deviceID: receiverDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 1),
            testHooks: commitHooks
        )
        let recovered = try await failingCommitStore.snapshotImportStatus(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertEqual(recovered?.receivedPageCount, 0)
        try await receiveAll(
            manifest,
            source: source,
            receiver: failingCommitStore,
            peer: sourceDevice
        )
        do {
            _ = try await failingCommitStore.commitSnapshotImportForTesting(
                peerDeviceID: sourceDevice,
                snapshotID: descriptor.snapshotID
            )
            XCTFail("expected the injected commit failure")
        } catch {
            XCTAssertFalse(error is SyncStoreError)
        }
        await XCTAssertEqualAsync({ try await failingCommitStore.recordCount() }, 0)
        await XCTAssertEqualAsync(
            { try await failingCommitStore.appliedCursor(for: sourceDevice) },
            .zero
        )
        let conflictsAfterCrash = try await failingCommitStore.conflicts()
        XCTAssertEqual(conflictsAfterCrash, [])
        let importAfterCrash = try await failingCommitStore.snapshotImportStatus(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertEqual(importAfterCrash?.state, .staging)
        XCTAssertEqual(importAfterCrash?.receivedPageCount, 2)
        let subscriptionAfterCrash = try await failingCommitStore.subscription(
            peerDeviceID: sourceDevice,
            scope: .task(task)
        )
        XCTAssertEqual(subscriptionAfterCrash?.established, false)
        XCTAssertEqual(subscriptionAfterCrash?.appliedCursor, .zero)
        await failingCommitStore.close()

        let retry = try receiverDatabase.makeStore(
            deviceID: receiverDevice,
            configuration: SyncStoreConfiguration(maxPageSize: 1)
        )
        let result = try await retry.commitSnapshotImportForTesting(
            peerDeviceID: sourceDevice,
            snapshotID: descriptor.snapshotID
        )
        XCTAssertFalse(result.isDuplicate)
        await XCTAssertEqualAsync({ try await retry.recordCount() }, 2)
        let committedSubscription = try await retry.subscription(
            peerDeviceID: sourceDevice,
            scope: .task(task)
        )
        XCTAssertEqual(committedSubscription?.established, true)
        XCTAssertEqual(committedSubscription?.appliedCursor, descriptor.baseCursor)
        await retry.close()
        await source.close()
    }

    func testPeerAndScopeReplayAreRefused() async throws {
        let sourceADatabase = try TestDatabase()
        let sourceBDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceADatabase.remove()
            sourceBDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceADevice = try TestIDs.device(120)
        let sourceBDevice = try TestIDs.device(121)
        let receiverDevice = try TestIDs.device(122)
        let taskA = try TestIDs.task(123)
        let taskB = try TestIDs.task(124)
        let sourceA = try sourceADatabase.makeStore(deviceID: sourceADevice)
        let sourceB = try sourceBDatabase.makeStore(deviceID: sourceBDevice)
        let receiver = try receiverDatabase.makeStore(deviceID: receiverDevice)
        _ = try await sourceA.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(1_300),
                revision: 1,
                originDeviceID: sourceADevice,
                taskID: taskA
            )
        )
        _ = try await sourceB.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(1_301),
                revision: 1,
                originDeviceID: sourceBDevice,
                taskID: taskB
            )
        )
        let snapshotA = try await sourceA.openSnapshot(scope: .task(taskA))
        let manifestA = try await sourceA.snapshotManifest(snapshotA.snapshotID)
        _ = try await receiver.beginSnapshotImportForTesting(
            peerDeviceID: sourceADevice,
            manifest: manifestA,
            subscriptionVersion: 1
        )
        let pageA = try await sourceA.snapshotPageEnvelope(
            snapshotA.snapshotID,
            manifest: manifestA,
            pageIndex: 0
        )
        await XCTAssertThrowsSyncError(
            .snapshotPeerMismatch(expected: sourceBDevice, found: sourceADevice)
        ) {
            _ = try await receiver.receiveSnapshotPageForTesting(
                peerDeviceID: sourceBDevice,
                envelope: pageA
            )
        }

        // The same snapshot identity cannot be replayed through another peer.
        await XCTAssertThrowsSyncError(
            .snapshotPeerMismatch(expected: sourceBDevice, found: sourceADevice)
        ) {
            _ = try await receiver.beginSnapshotImportForTesting(
                peerDeviceID: sourceBDevice,
                manifest: manifestA,
                subscriptionVersion: 1
            )
        }

        // A page carrying a record from another task scope is rejected even
        // when its own digest is internally consistent.
        let snapshotB = try await sourceB.openSnapshot(scope: .task(taskB))
        let manifestB = try await sourceB.snapshotManifest(snapshotB.snapshotID)
        let pageB = try await sourceB.snapshotPageEnvelope(
            snapshotB.snapshotID,
            manifest: manifestB,
            pageIndex: 0
        )
        let crossScope = SnapshotPageEnvelope(
            snapshotID: pageA.snapshotID,
            originDeviceID: pageA.originDeviceID,
            pageIndex: 0,
            firstPosition: 1,
            lastPosition: 1,
            records: pageB.records,
            digest: SnapshotDigest.pageDigest(pageB.records),
            manifestDigest: manifestA.digest
        )
        await XCTAssertThrowsSyncError(
            .snapshotScopeMismatch(
                RecordKey(
                    kind: .task,
                    entityID: try TestIDs.entity(1_301)
                ),
                .task(taskA)
            )
        ) {
            _ = try await receiver.receiveSnapshotPageForTesting(
                peerDeviceID: sourceADevice,
                envelope: crossScope
            )
        }
        let status = try await receiver.snapshotImportStatus(
            peerDeviceID: sourceADevice,
            snapshotID: snapshotA.snapshotID
        )
        XCTAssertEqual(status?.receivedPageCount, 0)
        await receiver.close()
        await sourceA.close()
        await sourceB.close()
    }
}
