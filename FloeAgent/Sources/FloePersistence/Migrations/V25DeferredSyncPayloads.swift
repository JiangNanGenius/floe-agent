import GRDB

/// Keeps dependency-sensitive remote configuration durable when CloudKit
/// delivers preferences before the provider/model records they reference.
enum V25DeferredSyncPayloads {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v25") { db in
            try db.alter(table: "config_sync_metadata") { table in
                table.add(column: "deferred_remote_payload", .blob)
            }
            try db.execute(sql: "PRAGMA user_version = 25")
        }
    }
}
