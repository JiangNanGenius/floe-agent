import GRDB

/// Schema v51 — conversation-local chat preferences (fast conversation lane).
///
/// `conversation_chat_preferences` keeps exactly ONE JSON snapshot per
/// conversation. Every field inside the snapshot is optional, so an absent
/// row or an absent key resolves to the product default (`.fast` for chat)
/// without any backfill, and the table is only ever written when the
/// conversation itself is durable. Draft identities chosen before a
/// conversation exists live in the app's RAM only — this table's foreign key
/// guarantees a row can never reference a missing conversation, so a fake
/// draft conversation cannot leak into SQLite.
///
/// The stored value is a conversation presentation setting, never a model
/// global: `ModelProfile.reasoningEffort` stays exactly as the user saved it
/// in the model editor. Cascade deletion with the conversation removes the
/// row automatically.
enum V51ChatPreferences {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v51_chat_preferences") { db in
            try db.execute(sql: """
                CREATE TABLE conversation_chat_preferences (
                    conversation_id TEXT PRIMARY KEY
                        REFERENCES conversations(id) ON DELETE CASCADE,
                    preferences_json TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                ) STRICT
                """)
        }
    }
}
