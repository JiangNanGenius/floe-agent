import GRDB

/// Adds the Agent's default video-generation route without changing existing
/// image or vision selections. Deleting the model clears the route safely.
enum V24VideoModelRouting {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v24") { db in
            try db.alter(table: "model_preferences") { table in
                table.add(column: "default_video_model_id", .text)
                    .references("models", onDelete: .setNull)
            }
            try db.execute(sql: "PRAGMA user_version = 24")
        }
    }
}
