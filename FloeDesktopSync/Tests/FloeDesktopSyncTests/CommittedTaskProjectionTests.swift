import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif
@testable import FloeDesktopSync

/// Focused integration tests for the committed-task projection layer. The
/// source side is a seeded temporary SQLite database with the committed
/// SelfCore shape (conversations/messages/message_parts + the canonical
/// feed); the local side is a real SyncStore on a temporary file. No GRDB,
/// no runtime, no network.
final class CommittedTaskProjectionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCommittedTaskProjection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// Committed SelfCore-shaped source with the canonical feed installed.
    final class SourceDatabase: @unchecked Sendable {
        let connection: SQLiteConnection
        private let lock = NSLock()

        init(path: String) throws {
            connection = try SQLiteConnection(path: path)
            try connection.execute("BEGIN IMMEDIATE")
            try connection.execute("""
                CREATE TABLE conversations (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try connection.execute("""
                CREATE TABLE messages (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id),
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    run_id TEXT
                )
                """)
            try connection.execute("""
                CREATE TABLE message_parts (
                    id TEXT PRIMARY KEY,
                    message_id TEXT NOT NULL REFERENCES messages(id),
                    part_index INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    text TEXT,
                    attachment_id TEXT,
                    metadata_json TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """)
            _ = try CanonicalMessageFeed.install(on: try requireHandle())
            try connection.execute("COMMIT")
        }

        private func requireHandle() throws -> OpaquePointer {
            guard let handle = connection.rawHandle else { throw SyncStoreError.closed }
            return handle
        }

        /// Runs `body` inside a fresh SQLite transaction on this connection.
        private func inTransaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
            lock.lock()
            defer { lock.unlock() }
            try connection.execute("BEGIN IMMEDIATE")
            do {
                let value = try body(try requireHandle())
                try connection.execute("COMMIT")
                return value
            } catch {
                try? connection.execute("ROLLBACK")
                throw error
            }
        }

        private func prepare(_ handle: OpaquePointer, _ sql: String) throws -> SQLiteStatement {
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &pointer, nil) == SQLITE_OK, let prepared = pointer else {
                throw SyncStoreError.sqliteFailure(
                    code: sqlite3_errcode(handle),
                    message: String(cString: sqlite3_errmsg(handle))
                )
            }
            return SQLiteStatement(handle: prepared, database: handle)
        }

        func insertConversation(id: UUID, title: String) throws {
            try inTransaction { handle in
                var statement = try self.prepare(handle, "INSERT INTO conversations(id,title,created_at,updated_at) VALUES(?,?,?,?)")
                try statement.bind(1, id.uuidString)
                try statement.bind(2, title)
                try statement.bind(3, "2026-11-19T00:00:00.000Z")
                try statement.bind(4, "2026-11-19T00:00:00.000Z")
                _ = try statement.step()
            }
        }

        @discardableResult
        func appendMessage(
            conversationID: UUID,
            id: UUID,
            role: String,
            content: String,
            runID: UUID?,
            partText: String? = nil
        ) throws -> EntityID {
            let entity = try EntityID(validating: id.uuidString)
            try inTransaction { handle in
                var statement = try self.prepare(
                    handle,
                    "INSERT INTO messages(id,conversation_id,role,content,created_at,run_id) VALUES(?,?,?,?,?,?)"
                )
                try statement.bind(1, id.uuidString)
                try statement.bind(2, conversationID.uuidString)
                try statement.bind(3, role)
                try statement.bind(4, content)
                try statement.bind(5, "2026-11-19T00:00:00.000Z")
                if let runID { try statement.bind(6, runID.uuidString) } else { try statement.bindNull(6) }
                _ = try statement.step()
                if let partText {
                    var part = try self.prepare(
                        handle,
                        """
                        INSERT INTO message_parts(id,message_id,part_index,kind,text,attachment_id,metadata_json,created_at)
                        VALUES(?,?,?,?,?,NULL,'{}','2026-11-19T00:00:00.000Z')
                        """
                    )
                    try part.bind(1, UUID().uuidString)
                    try part.bind(2, id.uuidString)
                    try part.bind(3, Int64(0))
                    try part.bind(4, "text")
                    try part.bind(5, partText)
                    _ = try part.step()
                }
            }
            return entity
        }

        func deleteMessage(id: UUID) throws {
            try inTransaction { handle in
                var statement = try self.prepare(handle, "DELETE FROM messages WHERE id = ?")
                try statement.bind(1, id.uuidString)
                _ = try statement.step()
            }
        }

        func close() {
            connection.close()
        }
    }

    /// Transaction-bound gateway required by the canonical feed contract.
    private struct FeedGateway: CommittedCanonicalFeedSource {
        let source: SourceDatabase

        func beginBootstrap(conversationID: UUID) async throws -> CanonicalMessageFeed.Bootstrap {
            try source.bootstrap(conversationID: conversationID)
        }

        func bootstrapPage(
            _ bootstrap: CanonicalMessageFeed.Bootstrap,
            after: UUID?,
            limit: Int
        ) async throws -> CanonicalMessageFeed.BootstrapPage {
            try source.bootstrapPage(bootstrap, after: after, limit: limit)
        }

        func changes(
            conversationID: UUID,
            after position: CanonicalMessageFeed.Position,
            limit: Int
        ) async throws -> CanonicalMessageFeed.ChangePage {
            try source.changes(conversationID: conversationID, after: position, limit: limit)
        }
    }

    /// Host-classified committed run events, as the SelfCore adapter will
    /// provide: every canonical message reference is durable and explicit.
    private actor ClassifiedSource: RunProjectionSource {
        private var events: [ProjectionSourceEvent]
        private var messages: [EntityID: ProjectionCanonicalMessage]

        init(events: [ProjectionSourceEvent], messages: [EntityID: ProjectionCanonicalMessage]) {
            self.events = events
            self.messages = messages
        }

        func setEvents(_ events: [ProjectionSourceEvent]) { self.events = events }
        func setMessage(_ message: ProjectionCanonicalMessage) { messages[message.id] = message }

        func events(taskID: TaskID, runID: RunID, afterSequence: Int64, limit: Int) async throws -> [ProjectionSourceEvent] {
            Array(events.filter { $0.taskID == taskID && $0.runID == runID && $0.sequence > afterSequence }.prefix(limit))
        }

        func message(id: EntityID) async throws -> ProjectionCanonicalMessage? { messages[id] }
    }

    private struct Fixture {
        let device = try! TestIDs.device(1)
        let task = try! TestIDs.task(2)
        let run = try! TestIDs.run(3)
        let epoch = try! TestIDs.epoch(1)

        var authorization: CommittedTaskProjectionAuthorization {
            CommittedTaskProjectionAuthorization(taskID: task, runID: run, executionEpoch: epoch)
        }

        var conversationID: UUID { UUID(uuidString: task.canonical)! }
        var runUUID: UUID { UUID(uuidString: run.canonical)! }
    }

    private func makeBoundStore(_ f: Fixture, _ testDB: TestDatabase) async throws -> SyncStore {
        let store = try testDB.makeStore(deviceID: f.device)
        _ = try await store.establishExecutionHead(runID: f.run, taskID: f.task, epoch: f.epoch, ownerDeviceID: f.device)
        return store
    }

    private func summary(_ title: String = "committed task") -> CommittedTaskConversationSummary {
        CommittedTaskConversationSummary(
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    // MARK: - Tests

    func testSnapshotImportIncrementalProjectionReadBackAndRestart() async throws {
        let f = Fixture()
        let source = try SourceDatabase(path: directory.appendingPathComponent("source.sqlite").path)
        defer { source.close() }
        try source.insertConversation(id: f.conversationID, title: "committed task")
        let userID = UUID(uuidString: TestIDs.uuid(11))!
        let assistantID = UUID(uuidString: TestIDs.uuid(12))!
        let userEntity = try source.appendMessage(conversationID: f.conversationID, id: userID, role: "user", content: "first ask", runID: nil, partText: "first ask")
        let assistantEntity = try source.appendMessage(conversationID: f.conversationID, id: assistantID, role: "assistant", content: "first answer", runID: f.runUUID, partText: "first answer")

        let testDB = try TestDatabase()
        defer { testDB.remove() }
        let store = try await makeBoundStore(f, testDB)
        let driver = CommittedTaskProjectionDriver(store: store)

        // 1. Snapshot: bounded keyset scan returns both committed messages
        // plus the exact replay watermark.
        let snapshot = try await driver.bootstrapSnapshot(authorization: f.authorization, feed: FeedGateway(source: source), pageLimit: 1)
        XCTAssertEqual(snapshot.messages.map(\.id), [userID, assistantID].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(snapshot.pageCount, 2)
        // The replay watermark is exactly the feed head at bootstrap time;
        // seeded message/part inserts advanced it past zero.
        let head = try source.feedPosition()
        XCTAssertEqual(snapshot.resume, head)
        XCTAssertGreaterThan(snapshot.resume.sequence, 0)
        XCTAssertEqual(snapshot.generation, snapshot.resume.generation)
        let part = snapshot.messages.flatMap(\.parts).first { $0.text == "first answer" }
        XCTAssertNotNil(part)

        // 2. Import commits the task header plus both messages.
        let receipt = try await driver.importSnapshot(snapshot, conversation: summary())
        XCTAssertTrue(receipt.taskRecordChanged)
        XCTAssertEqual(receipt.importedMessages, 2)
        XCTAssertEqual(receipt.unchangedMessages, 0)
        XCTAssertEqual(receipt.skippedMessages, 0)

        // Re-importing an identical snapshot is a no-op.
        let replay = try await driver.importSnapshot(snapshot, conversation: summary())
        XCTAssertFalse(replay.taskRecordChanged)
        XCTAssertEqual(replay.importedMessages, 0)
        XCTAssertEqual(replay.unchangedMessages, 2)

        // 3. Incremental projection over host-classified committed events.
        // The assistant message already exists with an identical payload, so
        // the first page is unchanged yet still advances the watermark.
        let classified = ClassifiedSource(
            events: [
                ProjectionSourceEvent(taskID: f.task, runID: f.run, sequence: 1, kind: .excludedReasoning),
                ProjectionSourceEvent(taskID: f.task, runID: f.run, sequence: 2, kind: .canonicalMessage(assistantEntity)),
            ],
            messages: [assistantEntity: ProjectionCanonicalMessage(id: assistantEntity, taskID: f.task, runID: f.run, role: .assistant, text: "first answer")]
        )
        let firstCommit = try await driver.projectNextPage(authorization: f.authorization, source: classified)
        XCTAssertEqual(firstCommit?.checkpoint.sourceSequence, 2)
        XCTAssertEqual(firstCommit?.checkpoint.appendedRecords, 0)
        XCTAssertEqual(firstCommit?.checkpoint.unchangedRecords, 1)

        // A newly committed assistant message arrives in both the feed and
        // the classified event stream; the next page appends exactly one
        // record and advances the durable checkpoint.
        let assistant2ID = UUID(uuidString: TestIDs.uuid(13))!
        let assistant2Entity = try source.appendMessage(conversationID: f.conversationID, id: assistant2ID, role: "assistant", content: "second answer", runID: f.runUUID)
        await classified.setEvents([
            ProjectionSourceEvent(taskID: f.task, runID: f.run, sequence: 1, kind: .excludedReasoning),
            ProjectionSourceEvent(taskID: f.task, runID: f.run, sequence: 2, kind: .canonicalMessage(assistantEntity)),
            ProjectionSourceEvent(taskID: f.task, runID: f.run, sequence: 3, kind: .canonicalMessage(assistant2Entity)),
        ])
        await classified.setMessage(ProjectionCanonicalMessage(id: assistant2Entity, taskID: f.task, runID: f.run, role: .assistant, text: "second answer"))
        let secondCommit = try await driver.projectNextPage(authorization: f.authorization, source: classified)
        XCTAssertEqual(secondCommit?.checkpoint.sourceSequence, 3)
        XCTAssertEqual(secondCommit?.checkpoint.appendedRecords, 1)

        // 4. Verified read-back over every committed message identity.
        let readBack = try await driver.readBack(
            authorization: f.authorization,
            messageIDs: [userEntity, assistantEntity, assistant2Entity]
        )
        XCTAssertEqual(readBack.conversationTitle, "committed task")
        XCTAssertEqual(readBack.messages.count, 3)
        XCTAssertEqual(readBack.checkpointSourceSequence, 3)
        let second = readBack.messages.first { $0.id == assistant2Entity }
        XCTAssertEqual(second?.text, "second answer")
        XCTAssertEqual(second?.runID, f.run)

        // 5. Restart: a fresh store on the same file resumes from the durable
        // watermark, finds nothing new, and the read-back still verifies.
        await store.close()
        let reopened = try testDB.makeStore(deviceID: f.device)
        let restartedDriver = CommittedTaskProjectionDriver(store: reopened)
        let drained = try await restartedDriver.projectNextPage(authorization: f.authorization, source: classified)
        XCTAssertNil(drained)
        let restartedReadBack = try await restartedDriver.readBack(
            authorization: f.authorization,
            messageIDs: [userEntity, assistantEntity, assistant2Entity]
        )
        XCTAssertEqual(restartedReadBack.checkpointSourceSequence, 3)
        XCTAssertEqual(restartedReadBack.messages.count, 3)
        await reopened.close()
    }

    func testStaleAuthorizationAndRebindingAreRefused() async throws {
        let f = Fixture()
        let source = try SourceDatabase(path: directory.appendingPathComponent("source.sqlite").path)
        defer { source.close() }
        try source.insertConversation(id: f.conversationID, title: "committed task")

        let testDB = try TestDatabase()
        defer { testDB.remove() }
        let store = try await makeBoundStore(f, testDB)
        let driver = CommittedTaskProjectionDriver(store: store)
        let feed = FeedGateway(source: source)

        // No events yet; projection is authorized but empty.
        let empty = ClassifiedSource(events: [], messages: [:])
        let drainedBeforeHandoff = try await driver.projectNextPage(authorization: f.authorization, source: empty)
        XCTAssertNil(drainedBeforeHandoff)

        // A newer epoch on the same owner is the normal handoff advance;
        // every stale entry point now fails closed before any write.
        let epoch2 = try! TestIDs.epoch(2)
        _ = try await store.establishExecutionHead(runID: f.run, taskID: f.task, epoch: epoch2, ownerDeviceID: f.device)
        let stale = CommittedTaskProjectionError.staleAuthorization(taskID: f.task, claimed: f.epoch, current: epoch2)
        await XCTAssertThrowsProjectionError(stale) {
            try await driver.projectNextPage(authorization: f.authorization, source: empty)
        }
        await XCTAssertThrowsProjectionError(stale) {
            try await driver.readBack(authorization: f.authorization, messageIDs: [])
        }
        await XCTAssertThrowsProjectionError(stale) {
            try await driver.bootstrapSnapshot(authorization: f.authorization, feed: feed)
        }
        await XCTAssertThrowsProjectionError(stale) {
            try await driver.importSnapshot(
                CommittedTaskSnapshot(authorization: f.authorization, generation: UUID(), messages: [], resume: CanonicalMessageFeed.Position(generation: UUID(), sequence: 0), pageCount: 0),
                conversation: summary()
            )
        }

        // Claiming an epoch beyond the established head is also refused.
        let epoch3 = try! TestIDs.epoch(3)
        let future = CommittedTaskProjectionAuthorization(taskID: f.task, runID: f.run, executionEpoch: epoch3)
        await XCTAssertThrowsProjectionError(.executionEpochNotCurrent(runID: f.run, claimed: epoch3, current: epoch2)) {
            try await driver.verifyAuthorization(future)
        }

        // The store itself refuses re-establishing an older epoch.
        await XCTAssertThrowsSyncError(
            .staleExecutionEpoch(f.run, f.epoch, current: epoch2)
        ) {
            try await store.establishExecutionHead(runID: f.run, taskID: f.task, epoch: f.epoch, ownerDeviceID: f.device)
        }

        // Rebinding the run to a different task is refused.
        let otherTask = try! TestIDs.task(9)
        await XCTAssertThrowsProjectionError(.authorizationTaskMismatch(expected: otherTask, found: f.task)) {
            try await driver.verifyAuthorization(
                CommittedTaskProjectionAuthorization(taskID: otherTask, runID: f.run, executionEpoch: epoch2)
            )
        }

        // A durable head owned by another device is refused for projection.
        let foreignRun = try! TestIDs.run(8)
        let foreignDevice = try! TestIDs.device(7)
        _ = try await store.establishExecutionHead(runID: foreignRun, taskID: f.task, epoch: f.epoch, ownerDeviceID: foreignDevice)
        await XCTAssertThrowsProjectionError(.authorizationOwnerMismatch(expected: f.device, found: foreignDevice)) {
            try await driver.verifyAuthorization(
                CommittedTaskProjectionAuthorization(taskID: f.task, runID: foreignRun, executionEpoch: f.epoch)
            )
        }
        await store.close()
    }

    func testFeedChangesTombstonesAndRotation() async throws {
        let f = Fixture()
        let source = try SourceDatabase(path: directory.appendingPathComponent("source.sqlite").path)
        defer { source.close() }
        try source.insertConversation(id: f.conversationID, title: "committed task")
        let assistantID = UUID(uuidString: TestIDs.uuid(21))!
        let assistantEntity = try source.appendMessage(conversationID: f.conversationID, id: assistantID, role: "assistant", content: "answer", runID: f.runUUID)

        let testDB = try TestDatabase()
        defer { testDB.remove() }
        let store = try await makeBoundStore(f, testDB)
        let driver = CommittedTaskProjectionDriver(store: store)
        let feed = FeedGateway(source: source)

        let snapshot = try await driver.bootstrapSnapshot(authorization: f.authorization, feed: feed)
        let receipt = try await driver.importSnapshot(snapshot, conversation: summary("t"))
        XCTAssertEqual(receipt.importedMessages, 1)

        // A live feed change cannot be applied as a tombstone.
        let user2ID = UUID(uuidString: TestIDs.uuid(22))!
        _ = try source.appendMessage(conversationID: f.conversationID, id: user2ID, role: "user", content: "follow-up", runID: nil)
        let livePage = try await driver.changes(authorization: f.authorization, feed: feed, after: snapshot.resume)
        XCTAssertEqual(livePage.changes.count, 1)
        XCTAssertNotNil(livePage.changes[0].message)
        await XCTAssertThrowsProjectionError(.incompatibleTombstone(livePage.changes[0].messageID)) {
            try await driver.applyFeedTombstone(livePage.changes[0], authorization: f.authorization)
        }

        // Deleting the committed message yields a real tombstone; applying it
        // marks the local record deleted, and a repeated apply is a no-op.
        try source.deleteMessage(id: assistantID)
        let tombstonePage = try await driver.changes(authorization: f.authorization, feed: feed, after: livePage.next)
        XCTAssertEqual(tombstonePage.changes.count, 1)
        XCTAssertEqual(tombstonePage.changes[0].messageID, assistantID)
        XCTAssertNil(tombstonePage.changes[0].message)
        let outcome = try await driver.applyFeedTombstone(tombstonePage.changes[0], authorization: f.authorization)
        if case .appended = outcome {} else { XCTFail("expected tombstone to append a delete") }
        let stored = try await store.storedRecord(kind: .message, entityID: assistantEntity)
        XCTAssertEqual(stored?.record.deleted, true)
        let repeated = try await driver.applyFeedTombstone(tombstonePage.changes[0], authorization: f.authorization)
        XCTAssertEqual(repeated, .unchanged)

        // After a history rotation the old watermark is invalid: the changes
        // replay fails closed with `wrongGeneration`.
        let rotated = try source.bootstrapRotate()
        XCTAssertEqual(rotated.sequence, tombstonePage.next.sequence)
        do {
            _ = try await driver.changes(authorization: f.authorization, feed: feed, after: tombstonePage.next)
            XCTFail("expected wrongGeneration after rotation")
        } catch CanonicalMessageFeed.FeedError.wrongGeneration {}
        await store.close()
    }

    // MARK: - Helpers

    private func XCTAssertThrowsProjectionError<T>(
        _ expected: CommittedTaskProjectionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CommittedTaskProjectionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

private extension CommittedTaskProjectionTests.SourceDatabase {
    func feedPosition() throws -> CanonicalMessageFeed.Position {
        try inTransaction { try CanonicalMessageFeed.position(on: $0) }
    }

    func bootstrap(conversationID: UUID) throws -> CanonicalMessageFeed.Bootstrap {
        try inTransaction { try CanonicalMessageFeed.beginBootstrap(on: $0, conversationID: conversationID) }
    }

    func bootstrapPage(
        _ bootstrap: CanonicalMessageFeed.Bootstrap,
        after: UUID?,
        limit: Int
    ) throws -> CanonicalMessageFeed.BootstrapPage {
        try inTransaction { try CanonicalMessageFeed.bootstrapPage(on: $0, bootstrap: bootstrap, after: after, limit: limit) }
    }

    func changes(
        conversationID: UUID,
        after position: CanonicalMessageFeed.Position,
        limit: Int
    ) throws -> CanonicalMessageFeed.ChangePage {
        try inTransaction { try CanonicalMessageFeed.changes(on: $0, conversationID: conversationID, after: position, limit: limit) }
    }

    /// Test-only access to history rotation.
    func bootstrapRotate() throws -> CanonicalMessageFeed.Position {
        try inTransaction { try CanonicalMessageFeed.rotateHistory(on: $0) }
    }
}
