import GRDB

/// Durable, optional sidebar pin for conversations (user round 2026-10-27).
///
/// `pinned_at` stores the instant a row moved into the pinned group; NULL
/// means "not pinned", which is exactly the value every pre-v55 row already
/// has, so historical data decodes unchanged with no backfill. Pinned rows
/// sort FIRST WITHIN their existing group, most recent pin first; the rest
/// keep the current `updated_at` recency order. Additive ALTER TABLE only:
/// the published columns, constraints, triggers and indices are untouched,
/// and no new sort index is claimed (the list is small and every projection
/// already re-reads the full set). The column lives on the conversation row
/// itself — deliberately NOT a parallel per-device UI store — so rename,
/// archive, restore and workspace moves (which write other tables/columns)
/// preserve the pin, and promotion of a temporary chat simply starts
/// unpinned.
public enum V55ConversationPinning {
    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v55_conversation_pinning") { db in
            try db.execute(sql: "ALTER TABLE conversations ADD COLUMN pinned_at TEXT")
            try db.execute(sql: "PRAGMA user_version = 55")
        }
    }
}
