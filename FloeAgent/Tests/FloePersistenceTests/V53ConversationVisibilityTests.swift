import Foundation
import GRDB
import Testing
@testable import FloePersistence

@Suite("v53 feature conversation visibility")
struct V53ConversationVisibilityTests {
    private func legacyFixture() throws -> (DatabaseQueue, DatabaseMigrator) {
        let queue = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("fixture_v52") { db in
            try db.execute(sql: """
                CREATE TABLE conversations (
                    id TEXT PRIMARY KEY, title TEXT NOT NULL,
                    created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
                    archived_at TEXT,
                    purpose TEXT NOT NULL DEFAULT 'ordinary' CHECK(purpose IN ('ordinary','notes'))
                );
                CREATE INDEX legacy_conversation_index ON conversations(purpose, updated_at);
                CREATE TABLE messages (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    content TEXT NOT NULL
                );
                INSERT INTO conversations(id,title,created_at,updated_at,purpose) VALUES
                    ('chat','Chat','t1','t2','ordinary'), ('notes','Notes','t1','t2','notes');
                INSERT INTO messages(id,conversation_id,content) VALUES ('message','chat','Keep this content');
                PRAGMA user_version = 52;
                """)
        }
        try migrator.migrate(queue)
        return (queue, migrator)
    }

    @Test("Fresh complete databases apply v53 and default existing conversation routes to normal")
    func freshDatabase() async throws {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        #expect(try await manager.userVersion() == DatabaseManager.currentSchemaVersion)
        // The constant grows with every later migration; v53 is only the
        // floor (the fresh database above already proves v53 applied).
        #expect(DatabaseManager.currentSchemaVersion >= 53)
        try await manager.writer { db in
            try db.execute(sql: "INSERT INTO conversations(id,title,created_at,updated_at) VALUES ('normal','Normal','t1','t2')")
        }
        let visibility = try await manager.reader { db in
            try String.fetchOne(db, sql: "SELECT visibility FROM conversations WHERE id='normal'")
        }
        #expect(visibility == "normal")
    }

    @Test("The additive upgrade preserves table identity, messages, old indices and foreign keys")
    func preservesLegacyData() throws {
        let (queue, original) = try legacyFixture()
        var migrator = original
        let oldRoot = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT rootpage FROM sqlite_master WHERE type='table' AND name='conversations'")
        }
        V53ConversationVisibility.register(into: &migrator)
        try migrator.migrate(queue)
        try queue.read { (db: Database) throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT rootpage FROM sqlite_master WHERE type='table' AND name='conversations'") == oldRoot)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM conversations WHERE visibility='normal'") == 2)
            #expect(try String.fetchOne(db, sql: "SELECT content FROM messages WHERE id='message'") == "Keep this content")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type='index' AND name='legacy_conversation_index'") == 1)
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 53)
        }
        try queue.write { db in try db.execute(sql: "DELETE FROM conversations WHERE id='chat'") }
        #expect(try queue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM messages") } == 0)
    }

    @Test("Feature visibility does not relax the published purpose or notes ownership constraints")
    func constraintsStayEnforced() throws {
        let (queue, original) = try legacyFixture()
        var migrator = original
        V53ConversationVisibility.register(into: &migrator)
        try migrator.migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversations(id,title,created_at,updated_at,purpose,visibility) VALUES ('author','Author','t1','t2','ordinary','skillAuthoring')")
        }
        for statement in [
            "UPDATE conversations SET purpose='temporary' WHERE id='chat'",
            "UPDATE conversations SET visibility='unknown' WHERE id='chat'",
            "UPDATE conversations SET visibility='skillAuthoring' WHERE id='notes'",
            "UPDATE conversations SET purpose='notes' WHERE id='author'"
        ] {
            #expect(throws: (any Error).self) {
                try queue.write { db in try db.execute(sql: statement) }
            }
        }
    }

    @Test("A migration failure rolls the new column back instead of leaving a partial schema")
    func migrationRollback() throws {
        let (queue, original) = try legacyFixture()
        try queue.write { db in
            // Deliberately collide with the new index AFTER its ALTER step.
            try db.execute(sql: "CREATE INDEX conversations_visibility_updated ON messages(conversation_id)")
        }
        var migrator = original
        V53ConversationVisibility.register(into: &migrator)
        #expect(throws: (any Error).self) { try migrator.migrate(queue) }
        try queue.read { (db: Database) throws -> Void in
            #expect(!(try db.columns(in: "conversations")).contains { $0.name == "visibility" })
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 52)
            #expect(try String.fetchOne(db, sql: "SELECT content FROM messages WHERE id='message'") == "Keep this content")
        }
    }
}
