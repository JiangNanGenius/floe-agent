import GRDB

enum V38ImageAutonomy {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v38") { db in
            try db.alter(table: "model_preferences") { table in
                table.add(column: "autonomous_image_routing", .integer)
            }
            try db.execute(sql: "PRAGMA user_version = 38")
        }
    }
}
