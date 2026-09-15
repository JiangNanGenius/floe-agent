import GRDB

public enum V41ConversationPurpose {
    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v41_conversation_purpose") { db in
            try db.execute(sql: "ALTER TABLE conversations ADD COLUMN purpose TEXT NOT NULL DEFAULT 'ordinary' CHECK(purpose IN ('ordinary','notes'))")
            try db.execute(sql: "CREATE INDEX conversations_purpose_updated ON conversations(purpose, updated_at)")
            try db.execute(sql: "PRAGMA user_version = 41")
        }
    }
}
