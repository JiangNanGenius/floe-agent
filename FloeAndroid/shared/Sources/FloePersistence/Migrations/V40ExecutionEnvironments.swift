import GRDB

public enum V40ExecutionEnvironments {
    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v40_execution_environments") { db in
            try db.alter(table: "background_jobs") { table in table.add(column: "environment_id", .text) }
            try db.create(index: "background_jobs_environment", on: "background_jobs", columns: ["environment_id", "state"])
            try db.execute(sql: "PRAGMA user_version = 40")
        }
    }
}
