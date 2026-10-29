import GRDB

enum V22RemoteDevices {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v22") { db in
            try db.alter(table: "hosts") { table in
                table.add(column: "device_kind", .text).notNull().defaults(to: "unspecified")
                // `hosts` is STRICT, so SQLite accepts INTEGER rather than
                // the BOOLEAN type alias. GRDB still decodes 0/1 as Bool.
                table.add(column: "is_remote_execution_environment", .integer).notNull().defaults(to: 1)
                table.add(column: "vnc_endpoints_json", .text)
                table.add(column: "auxiliary_connections_json", .text)
            }
            try db.execute(sql: "PRAGMA user_version = 22")
        }
    }
}
