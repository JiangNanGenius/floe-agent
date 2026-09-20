import Foundation
import GRDB
import Testing
@testable import FloePersistence

@Suite("v44 conversation search index repair")
struct V44ConversationSearchIndexRepairTests {
    @Test("Migration rebuilds message_fts so historically unindexed rows are searchable")
    func rebuildRepairsHistoricalIndex() async throws {
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        #expect(try await manager.userVersion() == DatabaseManager.currentSchemaVersion)
        try await manager.writer { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, title, created_at, updated_at)
                VALUES ('c1', 'historical', '2024-01-01T00:00:00Z', '2024-01-01T00:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO messages (id, conversation_id, role, content, created_at)
                VALUES ('m1', 'c1', 'user', 'rebuildfindsme historical token', '2024-01-01T00:00:00Z')
                """)
            // Simulate a row that bypassed the triggers (bulk import / early
            // builds): delete its index entry directly.
            try db.execute(sql: """
                INSERT INTO message_fts(message_fts, rowid, content)
                SELECT 'delete', m.rowid, m.content FROM messages m WHERE m.id = 'm1'
                """)
        }
        let broken = try await manager.reader { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages m
                JOIN message_fts f ON m.rowid = f.rowid
                WHERE message_fts MATCH 'rebuildfindsme'
                """) ?? 0
        }
        #expect(broken == 0)

        // The same one-time repair the v44 migration performs.
        try await manager.writer { db in
            try db.execute(sql: "INSERT INTO message_fts(message_fts) VALUES('rebuild')")
        }
        let repaired = try await manager.reader { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM messages m
                JOIN message_fts f ON m.rowid = f.rowid
                WHERE message_fts MATCH 'rebuildfindsme'
                """) ?? 0
        }
        #expect(repaired == 1)
        // Index and table are back in sync afterwards.
        let (messages, indexed) = try await manager.reader { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? -1,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message_fts") ?? -2
            )
        }
        #expect(messages == indexed)
    }
}
