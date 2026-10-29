import GRDB

/// Repairs the message full-text index for historical rows. `message_fts` is
/// an external-content FTS5 table fed by triggers since v1, but rows written
/// while the triggers were absent (imports, early builds, repaired databases)
/// never reached the index and stayed invisible to `conversation.search`.
/// A one-time `rebuild` regenerates the index from the messages table without
/// touching message bytes; the triggers keep it in sync afterwards.
public enum V44ConversationSearchIndexRepair {
    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v44_conversation_search_index_repair") { db in
            try db.execute(sql: "INSERT INTO message_fts(message_fts) VALUES('rebuild')")
            try db.execute(sql: "PRAGMA user_version = 44")
        }
    }
}
