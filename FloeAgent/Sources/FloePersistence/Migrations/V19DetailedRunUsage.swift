import GRDB

/// Optional provider-reported token dimensions. NULL deliberately means
/// "not reported"; older and incompatible providers must not look like they
/// reported a zero cache hit.
enum V19DetailedRunUsage {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v19") { db in
            try db.execute(sql: """
                ALTER TABLE run_usage ADD COLUMN cache_read_tokens INTEGER;
                ALTER TABLE run_usage ADD COLUMN cache_write_tokens INTEGER;
                ALTER TABLE run_usage ADD COLUMN reasoning_tokens INTEGER;
                ALTER TABLE run_usage ADD COLUMN is_estimated INTEGER NOT NULL DEFAULT 0;
                PRAGMA user_version = 19;
                """)
        }
    }
}
