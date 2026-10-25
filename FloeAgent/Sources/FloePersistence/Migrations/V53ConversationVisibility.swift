import GRDB

/// Feature-owned durable conversations retain ordinary runtime ownership but
/// stay out of the normal chat list until an explicit visibility conversion.
/// Additive: preserve the published purpose constraint, table identity,
/// existing messages, FKs, triggers and indices rather than rebuilding them.
public enum V53ConversationVisibility {
    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v53_conversation_visibility") { db in
            try db.execute(sql: "ALTER TABLE conversations ADD COLUMN visibility TEXT NOT NULL DEFAULT 'normal' CHECK(visibility IN ('normal','skillAuthoring') AND (visibility = 'normal' OR purpose = 'ordinary'))")
            try db.execute(sql: "CREATE INDEX conversations_visibility_updated ON conversations(purpose, visibility, archived_at, updated_at DESC, id)")
            try db.execute(sql: "PRAGMA user_version = 53")
        }
    }
}
