import GRDB

/// Separates permanent material deletion from removing only the private
/// CloudKit copy. The latter must retain the local catalog row and file.
enum V27CloudReleaseModes {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v27") { db in
            try db.alter(table: "cloud_asset_releases") { table in
                table.add(column: "delete_local_after_release", .boolean)
                    .notNull().defaults(to: true)
            }
            try db.execute(sql: "PRAGMA user_version = 27")
        }
    }
}
