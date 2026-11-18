import Foundation
import XCTest
@testable import FloeDesktopSync

private final class OpenRaceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var successStorage: [DeviceID] = []
    private var failureStorage: [(DeviceID, SyncStoreError)] = []

    func recordSuccess(_ device: DeviceID) {
        lock.lock()
        successStorage.append(device)
        lock.unlock()
    }

    func recordFailure(_ device: DeviceID, _ error: SyncStoreError) {
        lock.lock()
        failureStorage.append((device, error))
        lock.unlock()
    }

    var successes: [DeviceID] {
        lock.lock()
        defer { lock.unlock() }
        return successStorage
    }

    var failures: [(DeviceID, SyncStoreError)] {
        lock.lock()
        defer { lock.unlock() }
        return failureStorage
    }
}

private final class SnapshotIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: SnapshotID?

    var value: SnapshotID? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

final class ConcurrencyAndSecurityTests: XCTestCase {
    func testTwoConnectionsRacingFirstOpenCannotBothOwnTheDatabase() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let first = try TestIDs.device(1)
        let second = try TestIDs.device(2)

        let setup = try database.rawConnection()
        try SyncSchema.migrateIfNeeded(setup)
        setup.close()

        let box = OpenRaceBox()
        let group = DispatchGroup()
        for device in [first, second] {
            DispatchQueue.global().async(group: group) {
                do {
                    let connection = try SQLiteConnection(path: database.path)
                    defer { connection.close() }
                    try SyncStore.ensureIdentity(
                        connection,
                        deviceID: device,
                        nowMillis: 1_800_000_000_000
                    )
                    box.recordSuccess(device)
                } catch let error as SyncStoreError {
                    box.recordFailure(device, error)
                } catch {
                    XCTFail("unexpected open error: \(error)")
                }
            }
        }
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) {
                continuation.resume()
            }
        }

        XCTAssertEqual(box.successes.count, 1)
        XCTAssertEqual(box.failures.count, 1)
        let winner = try XCTUnwrap(box.successes.first)
        let (loser, failure) = try XCTUnwrap(box.failures.first)
        XCTAssertEqual(
            failure,
            .deviceIdentityMismatch(expected: loser.canonical, found: winner.canonical)
        )

        let store = try database.makeStore(deviceID: winner)
        let metadata = try await store.metadata()
        XCTAssertEqual(metadata.deviceID, winner)
        await store.close()
    }

    func testSecurePermissionsAndUnsafePathRejection() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)
        let store = try database.makeStore(deviceID: device)
        _ = try await store.commitLocalRecord(
            try SyncRecord.test(
                entityID: try TestIDs.entity(10),
                revision: 1,
                originDeviceID: device,
                taskID: task
            )
        )
        _ = try await store.metadata()

        XCTAssertEqual(try permissions(at: database.directory.path), 0o700)
        XCTAssertEqual(try permissions(at: database.path), 0o600)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(
            atPath: database.path + suffix
        ) {
            XCTAssertEqual(try permissions(at: database.path + suffix), 0o600)
        }
        await store.close()

        let insecure = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeDesktopSyncInsecure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: insecure,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: insecure) }
        XCTAssertThrowsError(
            try SyncStore(path: insecure.appendingPathComponent("sync.sqlite").path, deviceID: device)
        ) { error in
            guard case .insecureDatabaseDirectory = (error as? SyncStoreError) else {
                return XCTFail("expected insecureDatabaseDirectory, got \(error)")
            }
        }

        let target = database.directory.appendingPathComponent("target.sqlite").path
        let link = database.directory.appendingPathComponent("link.sqlite").path
        FileManager.default.createFile(atPath: target, contents: Data())
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertThrowsError(try SyncStore(path: link, deviceID: device)) { error in
            XCTAssertEqual(error as? SyncStoreError, .unsafeDatabasePath(link))
        }
    }

    func testChangesCheckAndReadShareOneSnapshotAgainstConcurrentPrune() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)

        var hooks = SyncStoreTestHooks()
        hooks.afterChangesValidation = {
            let connection = try SQLiteConnection(path: database.path)
            defer { connection.close() }
            try connection.execute("BEGIN IMMEDIATE")
            do {
                try connection.execute("DELETE FROM changes WHERE sequence <= 2")
                try connection.execute(
                    "UPDATE meta SET value = '2' WHERE key = 'changes_pruned_through'"
                )
                try connection.execute("COMMIT")
            } catch {
                _ = try? connection.execute("ROLLBACK")
                throw error
            }
        }
        let store = try database.makeStore(deviceID: device, testHooks: hooks)
        for offset in 0..<3 {
            _ = try await store.commitLocalRecord(
                try SyncRecord.test(
                    entityID: try TestIDs.entity(100 + offset),
                    revision: 1,
                    originDeviceID: device,
                    taskID: task
                )
            )
        }

        let page = try await store.changes(after: .zero, limit: 10)
        XCTAssertEqual(
            page.entries.map(\.cursor),
            [try TestIDs.cursor(1), try TestIDs.cursor(2), try TestIDs.cursor(3)]
        )
        XCTAssertFalse(page.hasMore)
        await XCTAssertThrowsSyncError(
            .cursorExpired(.zero, retainedFrom: try TestIDs.cursor(2))
        ) {
            try await store.changes(after: .zero, limit: 10)
        }
        let retained = try await store.changes(after: try TestIDs.cursor(2), limit: 10)
        XCTAssertEqual(retained.entries.map(\.cursor), [try TestIDs.cursor(3)])
        await store.close()
    }

    func testSnapshotValidationAndPageReadShareOneSnapshotAgainstConcurrentClose() async throws {
        let database = try TestDatabase()
        addTeardownBlock { database.remove() }
        let device = try TestIDs.device(1)
        let task = try TestIDs.task(2)

        let snapshotID = SnapshotIDBox()
        var hooks = SyncStoreTestHooks()
        hooks.afterSnapshotValidation = {
            guard let identifier = snapshotID.value else {
                throw SyncStoreError.snapshotNotFound(SnapshotID())
            }
            let connection = try SQLiteConnection(path: database.path)
            defer { connection.close() }
            let statement = try connection.prepare(
                "DELETE FROM snapshots WHERE snapshot_id = ?"
            )
            try statement.bind(1, identifier.canonical)
            _ = try statement.step()
        }
        let store = try database.makeStore(deviceID: device, testHooks: hooks)
        for offset in 0..<3 {
            _ = try await store.commitLocalRecord(
                try SyncRecord.test(
                    entityID: try TestIDs.entity(200 + offset),
                    revision: 1,
                    originDeviceID: device,
                    taskID: task
                )
            )
        }
        let snapshot = try await store.openSnapshot()
        snapshotID.value = snapshot.snapshotID

        let page = try await store.snapshotPage(snapshot.snapshotID, after: nil, limit: 10)
        XCTAssertEqual(page.records.count, 3)
        XCTAssertNil(page.nextToken)
        await XCTAssertThrowsSyncError(.snapshotNotFound(snapshot.snapshotID)) {
            try await store.snapshotPage(snapshot.snapshotID, after: nil, limit: 10)
        }
        await store.close()
    }

    private func permissions(at path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
