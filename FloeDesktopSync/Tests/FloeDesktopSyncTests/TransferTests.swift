import Foundation
import XCTest
@testable import FloeDesktopSync

/// Two independent databases in the same process, with no network layer. This
/// verifies snapshot export and fail-closed import, then exercises the
/// independently available retained incremental change path.
final class TransferTests: XCTestCase {
    func testSnapshotImportFailsClosedAndIncrementalTransferWorks() async throws {
        let sourceDatabase = try TestDatabase()
        let receiverDatabase = try TestDatabase()
        addTeardownBlock {
            sourceDatabase.remove()
            receiverDatabase.remove()
        }
        let sourceDevice = try TestIDs.device(1)
        let receiverDevice = try TestIDs.device(2)
        let task = try TestIDs.task(3)
        let source = try sourceDatabase.makeStore(deviceID: sourceDevice)
        let receiver = try receiverDatabase.makeStore(deviceID: receiverDevice)

        for offset in 0..<5 {
            _ = try await source.commitLocalRecord(
                try SyncRecord.test(
                    entityID: try TestIDs.entity(100 + offset),
                    revision: 1,
                    originDeviceID: sourceDevice,
                    taskID: task,
                    payload: .object(["title": .string("item-\(offset)")])
                )
            )
        }

        let snapshot = try await source.openSnapshot()
        XCTAssertEqual(snapshot.recordCount, 5)
        var token: SnapshotPageToken?
        var seen = 0
        repeat {
            let page = try await source.snapshotPage(
                snapshot.snapshotID,
                after: token,
                limit: 2
            )
            await XCTAssertThrowsSyncError(.snapshotImportUnverified) {
                _ = try await receiver.applySnapshotPage(peerDeviceID: sourceDevice, records: page.records)
            }
            seen += page.records.count
            token = page.nextToken
        } while token != nil

        XCTAssertEqual(seen, 5)
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 0)
        await XCTAssertEqualAsync({ try await receiver.appliedCursor(for: sourceDevice) }, .zero)

        await XCTAssertThrowsSyncError(.snapshotImportUnverified) {
            _ = try await receiver.commitAppliedCursor(peerDeviceID: sourceDevice, through: snapshot.baseCursor)
        }
        let initial = try await source.changes(after: .zero)
        _ = try await receiver.applyUncheckedBatchForTesting(RemoteChangeBatch(
            peerDeviceID: sourceDevice, through: initial.nextCursor,
            records: initial.entries.compactMap { $0.makeRecord() }
        ))
        await XCTAssertEqualAsync(
            { try await receiver.appliedCursor(for: sourceDevice) },
            snapshot.baseCursor
        )

        _ = try await source.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(200),
                revision: 1,
                originDeviceID: sourceDevice,
                taskID: task,
                payload: .object(["title": .string("after-snapshot")])
            )
        )
        let changes = try await source.changes(after: snapshot.baseCursor)
        XCTAssertEqual(changes.entries.count, 1)
        XCTAssertEqual(changes.nextCursor, try TestIDs.cursor(6))
        let incoming = changes.entries.compactMap { $0.makeRecord() }
        XCTAssertEqual(incoming.count, 1)

        let applied = try await receiver.applyUncheckedBatchForTesting(
            RemoteChangeBatch(
                peerDeviceID: sourceDevice,
                through: changes.nextCursor,
                records: incoming
            )
        )
        XCTAssertEqual(applied.applied.count, 1)
        XCTAssertEqual(applied.conflicts, [])
        XCTAssertEqual(applied.cursor, try TestIDs.cursor(6))
        await XCTAssertEqualAsync({ try await receiver.recordCount() }, 6)
        await XCTAssertEqualAsync({ try await receiver.appliedCursor(for: sourceDevice) }, try TestIDs.cursor(6))
        let stored = try await receiver.storedRecord(
            kind: .task,
            entityID: try TestIDs.entity(200)
        )
        XCTAssertEqual(stored?.record.payload["title"]?.stringValue, "after-snapshot")
        XCTAssertEqual(stored?.localDirty, false)

        await source.close()
        await receiver.close()
    }
}
