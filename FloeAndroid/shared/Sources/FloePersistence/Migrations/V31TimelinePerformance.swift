import GRDB

/// Composite indexes used by keyset timeline reads. They keep the first
/// screen and older-page fetches bounded even for very large conversations.
enum V31TimelinePerformance {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v31") { db in
            try db.execute(sql: """
                CREATE INDEX idx_messages_conversation_cursor_v31
                    ON messages(conversation_id, created_at DESC, id DESC);
                CREATE INDEX idx_runs_conversation_cursor_v31
                    ON runs(conversation_id, started_at DESC, id DESC);
                PRAGMA user_version = 31;
                """)
        }
    }
}
