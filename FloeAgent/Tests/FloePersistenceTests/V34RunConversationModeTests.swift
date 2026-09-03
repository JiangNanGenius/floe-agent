import Foundation
import GRDB
import Testing
@testable import FloePersistence

@Suite("V34 immutable run conversation modes")
struct V34RunConversationModeTests {
    @Test("Migration leaves every legacy run NULL instead of trusting mutable or SQLite evidence")
    func leavesAllLegacyRunsAmbiguous() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE conversations (
                    id TEXT PRIMARY KEY,
                    mode TEXT
                );
                CREATE TABLE runs (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL,
                    started_at TEXT NOT NULL
                );
                CREATE TABLE checkpoints (
                    run_id TEXT PRIMARY KEY,
                    body_json TEXT NOT NULL
                );
                INSERT INTO conversations (id, mode) VALUES ('c', 'plan');
                INSERT INTO runs (id, conversation_id, started_at) VALUES
                    ('checkpoint-goal', 'c', '2026-01-01T00:00:00Z'),
                    ('checkpoint-chat', 'c', '2026-01-01T00:01:00Z'),
                    ('missing-old', 'c', '2026-01-01T00:02:00Z'),
                    ('malformed', 'c', '2026-01-01T00:03:00Z'),
                    ('unsupported', 'c', '2026-01-01T00:04:00Z'),
                    ('missing-latest', 'c', '2026-01-01T00:05:00Z');
                INSERT INTO checkpoints (run_id, body_json) VALUES
                    ('checkpoint-goal', '{"conversationMode":"goal"}'),
                    ('checkpoint-chat', '{"conversationMode":"chat"}'),
                    ('malformed', '{'),
                    ('unsupported', '{"conversationMode":"agent"}');
                """)
        }

        var migrator = DatabaseMigrator()
        V34RunConversationModes.register(into: &migrator)
        try migrator.migrate(queue)

        try queue.read { db in
            for runID in [
                "checkpoint-goal", "checkpoint-chat", "missing-old",
                "malformed", "unsupported", "missing-latest"
            ] {
                let mode: String? = try String.fetchOne(
                    db,
                    sql: "SELECT conversation_mode FROM runs WHERE id = ?",
                    arguments: [runID]
                )
                #expect(mode == nil)
            }
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 34)
        }

        #expect(throws: (any Error).self) {
            try queue.write { db in
                try db.execute(
                    sql: "UPDATE runs SET conversation_mode = 'agent' WHERE id = 'missing-latest'"
                )
            }
        }
    }

    @Test("Run mode round trips and no upsert can replace or invent evidence")
    func runStoreRoundTripAndImmutableUpsert() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationID = UUID()
        try await SQLiteConversationStore(database: database).saveConversation(
            ConversationRecord(
                id: conversationID,
                title: "Mode",
                createdAt: Date(),
                updatedAt: Date()
            )
        )
        let store = SQLiteRunStore(database: database)
        let knownID = UUID()
        let startedAt = Date()
        try await store.saveRun(RunRecord(
            id: knownID,
            conversationID: conversationID,
            state: "preparing",
            goal: "known",
            startedAt: startedAt,
            conversationMode: "plan"
        ))
        #expect(try await store.run(id: knownID)?.conversationMode == "plan")

        try await store.saveRun(RunRecord(
            id: knownID,
            conversationID: conversationID,
            state: "running",
            goal: "known",
            startedAt: startedAt,
            conversationMode: "chat"
        ))
        #expect(try await store.run(id: knownID)?.conversationMode == "plan")

        let legacyID = UUID()
        try await store.saveRun(RunRecord(
            id: legacyID,
            conversationID: conversationID,
            state: "preparing",
            goal: "legacy",
            startedAt: startedAt
        ))
        try await store.saveRun(RunRecord(
            id: legacyID,
            conversationID: conversationID,
            state: "running",
            goal: "legacy",
            startedAt: startedAt,
            conversationMode: "goal"
        ))
        #expect(try await store.run(id: legacyID)?.conversationMode == nil)
    }
}
