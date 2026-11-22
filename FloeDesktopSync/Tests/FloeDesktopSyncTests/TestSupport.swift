import Foundation
import XCTest
@testable import FloeDesktopSync

enum TestIDs {
    static func uuid(_ value: Int) -> String {
        String(format: "%08x-0000-4000-8000-%012x", value, value)
    }

    static func device(_ value: Int) throws -> DeviceID {
        try DeviceID(validating: uuid(value))
    }

    static func task(_ value: Int) throws -> TaskID {
        try TaskID(validating: uuid(value))
    }

    static func run(_ value: Int) throws -> RunID {
        try RunID(validating: uuid(value))
    }

    static func workspace(_ value: Int) throws -> WorkspaceID {
        try WorkspaceID(validating: uuid(value))
    }

    static func command(_ value: Int) throws -> CommandID {
        try CommandID(validating: uuid(value))
    }

    static func entity(_ value: Int) throws -> EntityID {
        try EntityID(validating: uuid(value))
    }

    static func revision(_ value: Int64) throws -> Revision {
        try Revision(value)
    }

    static func epoch(_ value: Int64) throws -> ExecutionEpoch {
        try ExecutionEpoch(value)
    }

    static func cursor(_ value: Int64) throws -> ChangeCursor {
        try ChangeCursor(value)
    }
}

/// A clock that can be advanced without sleeping.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        current = date
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }

    var reader: @Sendable () -> Date {
        { [self] in now() }
    }
}

final class TestDatabase: Sendable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeDesktopSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }

    var path: String {
        directory.appendingPathComponent("sync.sqlite").path
    }

    func makeStore(
        deviceID: DeviceID,
        clock: TestClock? = nil,
        configuration: SyncStoreConfiguration = SyncStoreConfiguration(),
        testHooks: SyncStoreTestHooks = SyncStoreTestHooks(),
        incrementalAuthenticator: (any IncrementalAuthenticator)? = nil
    ) throws -> SyncStore {
        let reader: @Sendable () -> Date
        if let clock {
            reader = clock.reader
        } else {
            reader = { Date() }
        }
        return try SyncStore(
            path: path,
            deviceID: deviceID,
            configuration: configuration,
            clock: reader,
            testHooks: testHooks,
            incrementalAuthenticator: incrementalAuthenticator
        )
    }

    func rawConnection() throws -> SQLiteConnection {
        try SQLiteConnection(path: path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    var walFamilySize: Int64 {
        let names = ["sync.sqlite", "sync.sqlite-wal", "sync.sqlite-shm"]
        return names.reduce(into: Int64(0)) { total, name in
            let path = directory.appendingPathComponent(name).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
    }
}

extension SyncRecord {
    static func test(
        kind: SyncEntityKind = .task,
        entityID: EntityID,
        revision: Int64,
        baseRevision: Int64? = nil,
        baseDigest: ContentDigest? = nil,
        originDeviceID: DeviceID,
        taskID: TaskID? = nil,
        workspaceID: WorkspaceID? = nil,
        payload: JSONValue = .object(["title": .string("sample")]),
        deleted: Bool = false
    ) throws -> SyncRecord {
        SyncRecord(
            kind: kind,
            entityID: entityID,
            taskID: taskID,
            workspaceID: workspaceID,
            revision: try Revision(revision),
            baseRevision: try baseRevision.map { try Revision($0) },
            baseDigest: baseDigest,
            originDeviceID: originDeviceID,
            payload: payload,
            deleted: deleted
        )
    }
}

func XCTAssertSyncError<T>(
    _ expression: @autoclosure () throws -> T,
    _ expected: SyncStoreError,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        _ = try expression()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as SyncStoreError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}

func XCTAssertThrowsSyncError<T>(
    _ expected: SyncStoreError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as SyncStoreError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}

func XCTAssertEqualAsync<T: Equatable>(
    _ actual: () async throws -> T,
    _ expected: T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let value = try await actual()
        XCTAssertEqual(value, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}
