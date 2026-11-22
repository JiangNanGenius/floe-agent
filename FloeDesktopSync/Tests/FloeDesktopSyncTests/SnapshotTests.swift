import Foundation
import XCTest
@testable import FloeDesktopSync

final class SnapshotTests: XCTestCase {
    func testSnapshotPagesStayConsistentWhileWritesContinue() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let clock = TestClock()
        let store = try database.makeStore(
            deviceID: device,
            clock: clock,
            configuration: SyncStoreConfiguration(maxPageSize: 100)
        )

        for offset in 0..<12 {
            let record = try SyncRecord.test(
                entityID: try TestIDs.entity(100 + offset),
                revision: 1,
                originDeviceID: device,
                taskID: task,
                payload: .object(["title": .string("v1-\(offset)")])
            )
            _ = try await store.commitLocalRecord(record)
        }

        let descriptor = try await store.openSnapshot()
        XCTAssertEqual(descriptor.recordCount, 12)
        XCTAssertEqual(descriptor.baseCursor, try TestIDs.cursor(12))

        let firstPage = try await store.snapshotPage(
            descriptor.snapshotID,
            after: nil,
            limit: 5
        )
        XCTAssertEqual(firstPage.records.count, 5)
        XCTAssertEqual(firstPage.baseCursor, descriptor.baseCursor)
        XCTAssertNotNil(firstPage.nextToken)

        // A write during paging must not appear in this snapshot, and a later
        // revision of a paged record must not alter the frozen page.
        let newRecord = try SyncRecord.test(
            entityID: try TestIDs.entity(500),
            revision: 1,
            originDeviceID: device,
            taskID: task,
            payload: .object(["title": .string("during-snapshot")])
        )
        _ = try await store.commitLocalRecord(newRecord)

        let updatedRecord = try SyncRecord.test(
            entityID: try TestIDs.entity(100),
            revision: 2,
            originDeviceID: device,
            taskID: task,
            payload: .object(["title": .string("v2")])
        )
        _ = try await store.commitLocalRecord(updatedRecord)

        var collected = firstPage.records
        var token = firstPage.nextToken
        var pageCount = 1
        while let currentToken = token {
            let page = try await store.snapshotPage(
                descriptor.snapshotID,
                after: currentToken,
                limit: 5
            )
            pageCount += 1
            collected.append(contentsOf: page.records)
            XCTAssertEqual(page.baseCursor, descriptor.baseCursor)
            token = page.nextToken
        }
        XCTAssertEqual(pageCount, 3)
        XCTAssertEqual(collected.count, 12)
        XCTAssertEqual(Set(collected.map(\.entityID)).count, 12)
        let duringSnapshotID = try TestIDs.entity(500)
        let pagedEntityID = try TestIDs.entity(100)
        XCTAssertFalse(collected.contains { $0.entityID == duringSnapshotID })

        let firstRecord = try XCTUnwrap(
            collected.first { $0.entityID == pagedEntityID }
        )
        XCTAssertEqual(firstRecord.revision, try TestIDs.revision(1))
        XCTAssertEqual(firstRecord.payload["title"]?.stringValue, "v1-0")

        let changes = try await store.changes(
            after: descriptor.baseCursor,
            limit: 100
        )
        XCTAssertEqual(changes.entries.count, 2)
        XCTAssertTrue(
            changes.entries.contains {
                $0.key.entityID == duringSnapshotID
            }
        )
        let updatedRevision = try TestIDs.revision(2)
        XCTAssertTrue(
            changes.entries.contains {
                $0.key.entityID == pagedEntityID
                    && $0.revision == updatedRevision
            }
        )
        XCTAssertEqual(changes.nextCursor, try TestIDs.cursor(14))

        // Applying the frozen snapshot plus the post-base changes converges to
        // the live state with no gap and no duplicated identity.
        var state: [EntityID: SyncRecord] = [:]
        for record in collected {
            state[record.entityID] = record
        }
        for entry in changes.entries {
            guard let record = entry.makeRecord() else { continue }
            state[entry.key.entityID] = record
        }
        XCTAssertEqual(state.count, 13)
        XCTAssertEqual(
            state[pagedEntityID]?.payload["title"]?.stringValue,
            "v2"
        )
        XCTAssertEqual(
            state[duringSnapshotID]?.payload["title"]?.stringValue,
            "during-snapshot"
        )
        let liveCount = try await store.recordCount()
        XCTAssertEqual(liveCount, 13)
        await store.close()
    }

    func testSnapshotPagingResumesAfterRestartAndRejectsForeignToken() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let clock = TestClock()

        var store: SyncStore? = try database.makeStore(deviceID: device, clock: clock)
        for offset in 0..<7 {
            _ = try await store!.commitLocalRecord(
                try SyncRecord.test(
                    entityID: try TestIDs.entity(200 + offset),
                    revision: 1,
                    originDeviceID: device,
                    taskID: task
                )
            )
        }
        let firstSnapshot = try await store!.openSnapshot()
        let secondSnapshot = try await store!.openSnapshot()
        let firstPage = try await store!.snapshotPage(
            firstSnapshot.snapshotID,
            after: nil,
            limit: 3
        )
        let secondPage = try await store!.snapshotPage(
            firstSnapshot.snapshotID,
            after: firstPage.nextToken,
            limit: 3
        )
        XCTAssertEqual(firstPage.records.count, 3)
        XCTAssertEqual(secondPage.records.count, 3)
        await store!.close()
        store = nil

        let reopened = try database.makeStore(deviceID: device, clock: clock)
        let lastPage = try await reopened.snapshotPage(
            firstSnapshot.snapshotID,
            after: secondPage.nextToken,
            limit: 3
        )
        XCTAssertEqual(lastPage.records.count, 1)
        XCTAssertNil(lastPage.nextToken)

        let tokenFromOtherSnapshot = try SnapshotPageToken(
            snapshotID: secondSnapshot.snapshotID,
            position: 1
        )
        await XCTAssertThrowsSyncError(
            .snapshotTokenMismatch(
                expected: firstSnapshot.snapshotID,
                received: secondSnapshot.snapshotID
            )
        ) {
            try await reopened.snapshotPage(
                firstSnapshot.snapshotID,
                after: tokenFromOtherSnapshot,
                limit: 3
            )
        }

        try await reopened.closeSnapshot(firstSnapshot.snapshotID)
        await XCTAssertThrowsSyncError(.snapshotNotFound(firstSnapshot.snapshotID)) {
            try await reopened.snapshotPage(firstSnapshot.snapshotID, after: nil, limit: 3)
        }
        await reopened.close()
    }

    func testSnapshotExpiryAndPruningUseTheInjectedClock() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let clock = TestClock()
        let configuration = SyncStoreConfiguration(snapshotLifetime: 60)
        let store = try database.makeStore(
            deviceID: device,
            clock: clock,
            configuration: configuration
        )

        let descriptor = try await store.openSnapshot()
        XCTAssertEqual(descriptor.recordCount, 0)
        _ = try await store.snapshotPage(descriptor.snapshotID, after: nil, limit: 3)

        clock.advance(61)
        await XCTAssertThrowsSyncError(.snapshotExpired(descriptor.snapshotID)) {
            try await store.snapshotPage(descriptor.snapshotID, after: nil, limit: 3)
        }
        let pruned = try await store.pruneExpiredSnapshots()
        XCTAssertEqual(pruned, 1)
        let replacement = try await store.openSnapshot()
        XCTAssertNotEqual(replacement.snapshotID, descriptor.snapshotID)
        await store.close()
    }

    func testPageSizeBoundsAndUnknownSnapshot() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let store = try database.makeStore(
            deviceID: device,
            configuration: SyncStoreConfiguration(maxPageSize: 5)
        )
        let descriptor = try await store.openSnapshot()

        await XCTAssertThrowsSyncError(.invalidPageSize(0)) {
            try await store.snapshotPage(descriptor.snapshotID, after: nil, limit: 0)
        }
        await XCTAssertThrowsSyncError(.invalidPageSize(6)) {
            try await store.snapshotPage(descriptor.snapshotID, after: nil, limit: 6)
        }
        let missing = try SnapshotID(validating: TestIDs.uuid(999))
        await XCTAssertThrowsSyncError(.snapshotNotFound(missing)) {
            try await store.snapshotPage(missing, after: nil, limit: 3)
        }
        await store.close()
    }


    func testActiveSnapshotProtectsChangesFromPruning() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let clock = TestClock()
        let store = try database.makeStore(deviceID: device, clock: clock)

        for offset in 0..<3 {
            _ = try await store.commitLocalRecord(
                try SyncRecord.test(
                    entityID: try TestIDs.entity(300 + offset),
                    revision: 1,
                    originDeviceID: device,
                    taskID: task
                )
            )
        }
        let snapshot = try await store.openSnapshot()
        XCTAssertEqual(snapshot.baseCursor, try TestIDs.cursor(3))
        for offset in 0..<2 {
            _ = try await store.commitLocalRecord(
                try SyncRecord.test(
                    entityID: try TestIDs.entity(400 + offset),
                    revision: 1,
                    originDeviceID: device,
                    taskID: task
                )
            )
        }

        let clamped = try await store.pruneChanges(through: try TestIDs.cursor(5))
        XCTAssertEqual(clamped.prunedThrough, try TestIDs.cursor(3))
        XCTAssertEqual(clamped.removed, 3)
        let afterBase = try await store.changes(after: snapshot.baseCursor)
        XCTAssertEqual(afterBase.entries.map(\.cursor), [try TestIDs.cursor(4), try TestIDs.cursor(5)])

        try await store.closeSnapshot(snapshot.snapshotID)
        let unclamped = try await store.pruneChanges(through: try TestIDs.cursor(5))
        XCTAssertEqual(unclamped.prunedThrough, try TestIDs.cursor(5))
        XCTAssertEqual(unclamped.removed, 2)
        await store.close()
    }
}
