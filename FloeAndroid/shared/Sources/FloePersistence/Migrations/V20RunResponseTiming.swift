import GRDB

/// Client-observed provider timing. NULL means the request did not expose a
/// measurable streaming boundary; it must not be presented as zero latency.
enum V20RunResponseTiming {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v20") { db in
            try db.execute(sql: """
                ALTER TABLE run_usage ADD COLUMN total_duration_ms INTEGER;
                ALTER TABLE run_usage ADD COLUMN time_to_first_token_ms INTEGER;
                ALTER TABLE run_usage ADD COLUMN tokens_per_second REAL;
                PRAGMA user_version = 20;
                """)
        }
    }
}
