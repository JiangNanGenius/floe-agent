import GRDB

/// Adds a user-editable display name to providers. Existing rows keep their
/// preset label as the effective name (the column stays NULL, and the UI
/// falls back to the kind's preset label).
enum V15ProviderDisplayName {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v15") { db in
            try db.execute(sql: """
                ALTER TABLE providers ADD COLUMN display_name TEXT;
                PRAGMA user_version = 15;
                """)
        }
    }
}
