import Foundation
import XCTest
@testable import FloeDesktopSync
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif

private final class CanonicalFeedFixture {
    let db: OpaquePointer
    let path: String
    init(path: String = ":memory:", createSchema: Bool = true) throws {
        self.path = path
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else { throw FixtureError.failure("open \(status)") }
        db = handle
        sqlite3_busy_timeout(db, 3_000)
        try execute("PRAGMA foreign_keys=ON")
        if path != ":memory:" { try execute("PRAGMA journal_mode=WAL") }
        if createSchema {
            try execute("""
              CREATE TABLE conversations(id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL DEFAULT 't', updated_at TEXT NOT NULL DEFAULT 't') STRICT;
              CREATE TABLE messages(id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, role TEXT NOT NULL, content TEXT NOT NULL, created_at TEXT NOT NULL, run_id TEXT) STRICT;
              CREATE TABLE message_parts(id TEXT PRIMARY KEY, message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE, part_index INTEGER NOT NULL, kind TEXT NOT NULL, text TEXT, attachment_id TEXT, metadata_json TEXT NOT NULL DEFAULT '{}', created_at TEXT NOT NULL, UNIQUE(message_id,part_index)) STRICT;
              """)
        }
    }
    deinit { sqlite3_close_v2(db) }
    enum FixtureError: Error { case failure(String), rollback }
    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        guard status == SQLITE_OK else {
            let text = error.map { String(cString: $0) } ?? "sqlite error"
            if let error { sqlite3_free(error) }
            throw FixtureError.failure("\(status): \(text)")
        }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
}

final class CanonicalMessageFeedTests: XCTestCase {
    private let conversationA = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001")!
    private let conversationB = UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000002")!
    private let message1 = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let message2 = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    private let message3 = UUID(uuidString: "30000000-0000-4000-8000-000000000003")!
    private let part = UUID(uuidString: "40000000-0000-4000-8000-000000000004")!

    private func setup() throws -> (CanonicalFeedFixture, UUID) {
        let f = try CanonicalFeedFixture()
        try f.execute("INSERT INTO conversations(id) VALUES('\(conversationA.uuidString)'),('\(conversationB.uuidString)')")
        let generation = try f.transaction { try CanonicalMessageFeed.install(on: f.db) }
        return (f, generation)
    }
    private func position(_ generation: UUID, _ sequence: Int64 = 0) -> CanonicalMessageFeed.Position {
        .init(generation: generation, sequence: sequence)
    }
    private func insert(_ f: CanonicalFeedFixture, id: UUID, conversation: UUID, content: String = "hello") throws {
        try f.execute("INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES('\(id.uuidString)','\(conversation.uuidString)','user','\(content)','2026-01-01')")
    }
    func testInstallRequiresTransactionAndRollsBackWithHostMigration() throws {
        let f = try CanonicalFeedFixture()
        XCTAssertThrowsError(try CanonicalMessageFeed.install(on: f.db)) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .transactionRequired) }
        try f.execute("BEGIN")
        _ = try CanonicalMessageFeed.install(on: f.db)
        try f.execute("ROLLBACK")
        let generation = try f.transaction { try CanonicalMessageFeed.install(on: f.db) }
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.install(on: f.db) }) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .alreadyInstalled) }
        XCTAssertNotEqual(generation, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }
    func testInstallationRejectsDisabledForeignKeys() throws {
        let f = try CanonicalFeedFixture()
        try f.execute("PRAGMA foreign_keys=OFF")
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.install(on: f.db) }) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .foreignKeysRequired) }
    }
    func testPositionRequiresTransactionAndTracksRollbackAndRotation() throws {
        let (f, generation) = try setup()
        XCTAssertThrowsError(try CanonicalMessageFeed.position(on: f.db)) {
            XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .transactionRequired)
        }
        let start = try f.transaction { try CanonicalMessageFeed.position(on: f.db) }
        XCTAssertEqual(start, position(generation))
        XCTAssertThrowsError(try f.transaction {
            try insert(f, id: message1, conversation: conversationA)
            XCTAssertEqual(try CanonicalMessageFeed.position(on: f.db).sequence, 1)
            throw CanonicalFeedFixture.FixtureError.rollback
        })
        XCTAssertEqual(try f.transaction { try CanonicalMessageFeed.position(on: f.db) }, start)
        try insert(f, id: message1, conversation: conversationA)
        let prior = try f.transaction { try CanonicalMessageFeed.position(on: f.db) }
        let rotated = try f.transaction { try CanonicalMessageFeed.rotateHistory(on: f.db) }
        XCTAssertNotEqual(prior.generation, rotated.generation)
        XCTAssertEqual(prior.sequence, rotated.sequence)
        XCTAssertEqual(try f.transaction { try CanonicalMessageFeed.position(on: f.db) }, rotated)
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: prior, limit: 10) }) {
            XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .wrongGeneration)
        }
        try f.execute("DROP TRIGGER floe_msgfeed_messages_insert_v1")
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.position(on: f.db) }) {
            XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .unavailable)
        }
    }
    func testHistoryRotationInvalidatesOldCursorsAndRollsBackWithHost() throws {
        let (f, generation) = try setup()
        try insert(f, id: message1, conversation: conversationA)
        let old = try f.transaction { try CanonicalMessageFeed.beginBootstrap(on: f.db, conversationID: conversationA) }
        XCTAssertThrowsError(try CanonicalMessageFeed.rotateHistory(on: f.db)) {
            XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .transactionRequired)
        }
        XCTAssertThrowsError(try f.transaction {
            _ = try CanonicalMessageFeed.rotateHistory(on: f.db)
            throw CanonicalFeedFixture.FixtureError.rollback
        })
        let afterRollback = try f.transaction { try CanonicalMessageFeed.bootstrapPage(on: f.db, bootstrap: old, after: nil, limit: 10) }
        XCTAssertEqual(afterRollback.messages.map(\.id), [message1])
        let rotation = try f.transaction { try CanonicalMessageFeed.rotateHistory(on: f.db) }
        XCTAssertNotEqual(rotation.generation, generation)
        XCTAssertEqual(rotation.sequence, old.start.sequence)
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.bootstrapPage(on: f.db, bootstrap: old, after: nil, limit: 10) }) {
            XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .wrongGeneration)
        }
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: old.start, limit: 10) }) {
            XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .wrongGeneration)
        }
        let fresh = try f.transaction { try CanonicalMessageFeed.beginBootstrap(on: f.db, conversationID: conversationA) }
        XCTAssertEqual(fresh.start, rotation)
        let snapshot = try f.transaction { try CanonicalMessageFeed.bootstrapPage(on: f.db, bootstrap: fresh, after: nil, limit: 10) }
        XCTAssertEqual(snapshot.messages.map(\.id), [message1])
        try f.execute("DELETE FROM messages WHERE id='\(message1.uuidString)'")
        let changes = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: fresh.start, limit: 10) }
        XCTAssertEqual(changes.changes.count, 1)
        XCTAssertEqual(changes.changes.first?.messageID, message1)
        XCTAssertNil(changes.changes.first?.message)
        XCTAssertEqual(changes.next.sequence, rotation.sequence + 1)
    }
    func testRotatedBootstrapReconcilesPagedChangesAndDeletedRows() throws {
        let (f, _) = try setup()
        try insert(f, id: message2, conversation: conversationA)
        try insert(f, id: message3, conversation: conversationA)
        _ = try f.transaction { try CanonicalMessageFeed.rotateHistory(on: f.db) }
        let bootstrap = try f.transaction { try CanonicalMessageFeed.beginBootstrap(on: f.db, conversationID: conversationA) }
        let first = try f.transaction { try CanonicalMessageFeed.bootstrapPage(on: f.db, bootstrap: bootstrap, after: nil, limit: 1) }
        XCTAssertEqual(first.messages.map(\.id), [message2])
        try f.execute("DELETE FROM messages WHERE id='\(message2.uuidString)'")
        try f.execute("UPDATE messages SET content='edited' WHERE id='\(message3.uuidString)'")
        try insert(f, id: message1, conversation: conversationA)
        let second = try f.transaction { try CanonicalMessageFeed.bootstrapPage(on: f.db, bootstrap: bootstrap, after: first.nextMessageID, limit: 1) }
        XCTAssertEqual(second.messages.map(\.id), [message3])
        XCTAssertNil(second.nextMessageID)
        // A consumer must replace its prior projection with a staged full
        // snapshot, then replay every invalidation from the saved watermark.
        var staged = Dictionary(uniqueKeysWithValues: (first.messages + second.messages).map { ($0.id, $0.content) })
        var cursor = bootstrap.start
        while true {
            let page = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: cursor, limit: 1) }
            for change in page.changes { staged[change.messageID] = change.message?.content }
            cursor = page.next
            if !page.hasMore { break }
        }
        XCTAssertEqual(staged, [message1: "hello", message3: "edited"])
    }
    func testWritesAndRollbackCreateCanonicalSnapshotsAndTombstones() throws {
        let (f, generation) = try setup()
        try f.transaction {
            try insert(f, id: message1, conversation: conversationA)
            try f.execute("INSERT INTO message_parts(id,message_id,part_index,kind,text,metadata_json,created_at) VALUES('\(part.uuidString)','\(message1.uuidString)',0,'text','first','{}','t')")
            try f.execute("UPDATE message_parts SET text='final',metadata_json='{\"k\":\"1\"}' WHERE id='\(part.uuidString)'")
            try f.execute("UPDATE messages SET content='updated' WHERE id='\(message1.uuidString)'")
        }
        let first = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 100) }
        XCTAssertEqual(first.changes.count, 4)
        XCTAssertEqual(first.changes.last?.message?.content, "updated")
        XCTAssertEqual(first.changes.last?.message?.parts.first?.text, "final")
        XCTAssertEqual(first.changes.last?.message?.parts.first?.metadataJSON, "{\"k\":\"1\"}")
        XCTAssertThrowsError(try f.transaction { try f.execute("DELETE FROM messages WHERE id='\(message1.uuidString)'"); throw CanonicalFeedFixture.FixtureError.rollback })
        let rolledBack = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: first.next, limit: 100) }
        XCTAssertTrue(rolledBack.changes.isEmpty)
        try f.execute("DELETE FROM messages WHERE id='\(message1.uuidString)'")
        let deleted = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: first.next, limit: 100) }
        XCTAssertEqual(deleted.changes.last?.messageID, message1)
        XCTAssertNil(deleted.changes.last?.message)
    }
    func testConversationMoveDeliversOldTombstoneAndNewRecord() throws {
        let (f, generation) = try setup()
        try insert(f, id: message1, conversation: conversationA)
        let before = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 100) }.next
        try f.execute("UPDATE messages SET conversation_id='\(conversationB.uuidString)' WHERE id='\(message1.uuidString)'")
        let old = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: before, limit: 100) }
        let new = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationB, after: before, limit: 100) }
        XCTAssertEqual(old.changes.count, 1); XCTAssertNil(old.changes[0].message)
        XCTAssertEqual(new.changes.count, 1); XCTAssertEqual(new.changes[0].message?.conversationID, conversationB)
    }
    func testReplaceAcrossConversationsKeepsOldTombstoneWithoutRecursiveTriggers() throws {
        let (f, generation) = try setup()
        try f.execute("PRAGMA recursive_triggers=OFF")
        try insert(f, id: message1, conversation: conversationA)
        let before = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 100) }.next
        try f.execute("INSERT OR REPLACE INTO messages(id,conversation_id,role,content,created_at) VALUES('\(message1.uuidString)','\(conversationB.uuidString)','user','moved','2026-01-01')")
        let old = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: before, limit: 100) }
        let new = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationB, after: before, limit: 100) }
        XCTAssertEqual(old.changes.count, 1); XCTAssertNil(old.changes[0].message)
        XCTAssertEqual(new.changes.count, 1); XCTAssertEqual(new.changes[0].message?.content, "moved")
    }
    func testReplacingPartAcrossMessagesNotifiesBothOwners() throws {
        let (f, generation) = try setup()
        try f.execute("PRAGMA recursive_triggers=OFF")
        try insert(f, id: message1, conversation: conversationA)
        try insert(f, id: message2, conversation: conversationB)
        try f.execute("INSERT INTO message_parts(id,message_id,part_index,kind,text,metadata_json,created_at) VALUES('\(part.uuidString)','\(message1.uuidString)',0,'text','first','{}','t')")
        let before = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 100) }.next
        try f.execute("INSERT OR REPLACE INTO message_parts(id,message_id,part_index,kind,text,metadata_json,created_at) VALUES('\(part.uuidString)','\(message2.uuidString)',0,'text','moved','{}','t')")
        let old = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: before, limit: 100) }
        let new = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationB, after: before, limit: 100) }
        XCTAssertEqual(old.changes.count, 1); XCTAssertEqual(old.changes[0].message?.parts, [])
        XCTAssertEqual(new.changes.count, 1); XCTAssertEqual(new.changes[0].message?.parts.first?.text, "moved")
    }
    func testCascadeDeletionAndGlobalBoundedPagination() throws {
        let (f, generation) = try setup()
        try insert(f, id: message1, conversation: conversationA)
        try insert(f, id: message2, conversation: conversationB)
        try insert(f, id: message3, conversation: conversationA)
        let one = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 1) }
        XCTAssertEqual(one.changes.map(\.messageID), [message1]); XCTAssertTrue(one.hasMore)
        let two = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: one.next, limit: 1) }
        XCTAssertTrue(two.changes.isEmpty); XCTAssertEqual(two.next.sequence, 2); XCTAssertTrue(two.hasMore)
        let three = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: two.next, limit: 1) }
        XCTAssertEqual(three.changes.map(\.messageID), [message3]); XCTAssertFalse(three.hasMore)
        try f.execute("DELETE FROM conversations WHERE id='\(conversationA.uuidString)'")
        let tombstones = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: three.next, limit: 100) }
        XCTAssertEqual(Set(tombstones.changes.map(\.messageID)), Set([message1, message3]))
        XCTAssertTrue(tombstones.changes.allSatisfy { $0.message == nil })
    }
    func testConversationReplaceCascadesMessageTombstone() throws {
        let (f, generation) = try setup()
        try f.execute("PRAGMA recursive_triggers=OFF")
        try insert(f, id: message1, conversation: conversationA)
        let before = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 100) }.next
        try f.execute("INSERT OR REPLACE INTO conversations(id) VALUES('\(conversationA.uuidString)')")
        let result = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: before, limit: 100) }
        XCTAssertEqual(result.changes.map(\.messageID), [message1])
        XCTAssertNil(result.changes.first?.message)
    }
    func testBootstrapReplaysConcurrentInsertsUpdatesAndDeletes() throws {
        let f = try CanonicalFeedFixture()
        try f.execute("INSERT INTO conversations(id) VALUES('\(conversationA.uuidString)')")
        try insert(f, id: message2, conversation: conversationA)
        try insert(f, id: message3, conversation: conversationA)
        let generation = try f.transaction { try CanonicalMessageFeed.install(on: f.db) }
        let start = try f.transaction { try CanonicalMessageFeed.beginBootstrap(on: f.db, conversationID: conversationA) }
        XCTAssertEqual(start.start, position(generation))
        XCTAssertEqual(try JSONDecoder().decode(CanonicalMessageFeed.Bootstrap.self, from: JSONEncoder().encode(start)), start)
        let first = try f.transaction { try CanonicalMessageFeed.bootstrapPage(on: f.db, bootstrap: start, after: nil, limit: 1) }
        XCTAssertEqual(first.messages.map(\.id), [message2]); XCTAssertEqual(first.nextMessageID, message2)
        try insert(f, id: message1, conversation: conversationA)
        try f.execute("UPDATE messages SET content='edited' WHERE id='\(message2.uuidString)'")
        try f.execute("DELETE FROM messages WHERE id='\(message3.uuidString)'")
        let last = try f.transaction { try CanonicalMessageFeed.bootstrapPage(on: f.db, bootstrap: start, after: first.nextMessageID, limit: 1) }
        XCTAssertTrue(last.messages.isEmpty); XCTAssertNil(last.nextMessageID)
        let replay = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: start.start, limit: 100) }
        var materialized = Dictionary(uniqueKeysWithValues: first.messages.map { ($0.id, $0.content) })
        for change in replay.changes { materialized[change.messageID] = change.message?.content }
        XCTAssertEqual(materialized, [message1: "hello", message2: "edited"])
    }
    func testMissingChangeAndMissingTriggerFailClosed() throws {
        let (f, generation) = try setup()
        try insert(f, id: message1, conversation: conversationA)
        try insert(f, id: message2, conversation: conversationB)
        try insert(f, id: message3, conversation: conversationA)
        try f.execute("DELETE FROM floe_msgfeed_changes_v1 WHERE sequence=2")
        let first = try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 1) }
        XCTAssertTrue(first.hasMore)
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: first.next, limit: 1) }) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .invalidSourceRow) }
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 100) }) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .invalidSourceRow) }
        try f.execute("DROP TRIGGER floe_msgfeed_parts_update_v1")
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 100) }) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .unavailable) }
    }
    func testRejectsWrongGenerationInvalidLimitAndOversizeWithoutAdvancing() throws {
        let (f, generation) = try setup()
        try insert(f, id: message1, conversation: conversationA)
        try f.execute("UPDATE messages SET content=printf('%0.*d',\(CanonicalMessageFeed.maximumMessageBytes + 1),0) WHERE id='\(message1.uuidString)'")
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 100) }) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .oversizedMessage) }
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(UUID()), limit: 1) }) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .wrongGeneration) }
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 0) }) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .invalidPageSize) }
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation, 99), limit: 1) }) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .invalidCursor) }
    }
    func testAmbiguousMessageUUIDIsRejected() throws {
        let (f, generation) = try setup()
        let raw = "abcdefab-0000-4000-8000-000000000005"
        try f.execute("INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES('\(raw)','\(conversationA.uuidString)','user','a','t'),('\(raw.uppercased())','\(conversationA.uuidString)','user','b','t')")
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 100) }) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .ambiguousIdentifier) }
    }
    func testMalformedPartMetadataIsRejectedRatherThanExported() throws {
        let (f, generation) = try setup()
        try insert(f, id: message1, conversation: conversationA)
        try f.execute("INSERT INTO message_parts(id,message_id,part_index,kind,text,metadata_json,created_at) VALUES('\(part.uuidString)','\(message1.uuidString)',0,'text','value','{\"k\":1}','t')")
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 100) }) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .invalidSourceRow) }
    }

    func testInvalidUTF8MessageIsRejectedRatherThanReplaced() throws {
        let (f, generation) = try setup()
        try f.execute("INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES('\(message1.uuidString)','\(conversationA.uuidString)','user',CAST(X'80' AS TEXT),'2026-01-01')")
        XCTAssertThrowsError(try f.transaction {
            try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 100)
        }) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .invalidSourceRow) }
    }

    func testEmbeddedNULInMessageIsPreserved() throws {
        let (f, generation) = try setup()
        try f.execute("INSERT INTO messages(id,conversation_id,role,content,created_at) VALUES('\(message1.uuidString)','\(conversationA.uuidString)','user',CAST(X'610062' AS TEXT),'2026-01-01')")
        let page = try f.transaction {
            try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 100)
        }
        XCTAssertEqual(page.changes.first?.message?.content, "a\0b")
    }
    func testAmbiguousPartUUIDIsRejected() throws {
        let (f, generation) = try setup()
        try insert(f, id: message1, conversation: conversationA)
        let raw = "abcdefab-0000-4000-8000-000000000005"
        try f.execute("INSERT INTO message_parts(id,message_id,part_index,kind,metadata_json,created_at) VALUES('\(raw)','\(message1.uuidString)',0,'text','{}','t'),('\(raw.uppercased())','\(message1.uuidString)',1,'text','{}','t')")
        XCTAssertThrowsError(try f.transaction { try CanonicalMessageFeed.changes(on: f.db, conversationID: conversationA, after: position(generation), limit: 100) }) { XCTAssertEqual($0 as? CanonicalMessageFeed.FeedError, .ambiguousIdentifier) }
    }
    func testSeparateConnectionCommitRespectsReadSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloeMessageFeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let path = directory.appendingPathComponent("messages.sqlite").path
        let first = try CanonicalFeedFixture(path: path)
        try first.execute("INSERT INTO conversations(id) VALUES('\(conversationA.uuidString)')")
        let generation = try first.transaction { try CanonicalMessageFeed.install(on: first.db) }
        let second = try CanonicalFeedFixture(path: path, createSchema: false)
        try first.execute("BEGIN")
        let start = try CanonicalMessageFeed.beginBootstrap(on: first.db, conversationID: conversationA)
        try insert(second, id: message1, conversation: conversationA)
        let oldSnapshot = try CanonicalMessageFeed.changes(on: first.db, conversationID: conversationA, after: position(generation), limit: 100)
        XCTAssertTrue(oldSnapshot.changes.isEmpty)
        try first.execute("COMMIT")
        let next = try first.transaction { try CanonicalMessageFeed.changes(on: first.db, conversationID: conversationA, after: start.start, limit: 100) }
        XCTAssertEqual(next.changes.map(\.messageID), [message1])
    }
}
