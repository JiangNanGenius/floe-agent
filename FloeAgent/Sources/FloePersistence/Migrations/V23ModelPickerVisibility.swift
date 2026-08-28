import GRDB

/// Separates model availability from primary-picker presentation. Existing
/// rows stay visible; auxiliary-only models can be hidden without disabling
/// them or invalidating historical runs.
enum V23ModelPickerVisibility {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v23") { db in
            try db.alter(table: "models") { table in
                table.add(column: "is_hidden_from_primary_picker", .integer)
                    .notNull()
                    .defaults(to: 0)
            }
            try db.execute(sql: "PRAGMA user_version = 23")
        }
    }
}
