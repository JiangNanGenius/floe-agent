import GRDB

/// Stores the provider-neutral reasoning-depth preference per model. NULL and
/// `automatic` both mean that adapters should preserve the provider default.
enum V17ModelReasoningEffort {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v17") { db in
            try db.execute(sql: """
                ALTER TABLE models ADD COLUMN reasoning_effort TEXT;
                PRAGMA user_version = 17;
                """)
        }
    }
}
