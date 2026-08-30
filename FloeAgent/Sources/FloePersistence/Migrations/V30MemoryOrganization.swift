import GRDB

/// Stable fact slots and idempotent, content-free maintenance audit records.
enum V30MemoryOrganization {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v30") { db in
            try db.alter(table: "memory_entries") { table in
                table.add(column: "subject_key", .text)
                table.add(column: "attribute_key", .text)
            }
            try db.execute(sql: """
                CREATE INDEX idx_memory_entries_fact_v30
                    ON memory_entries(subject_key, attribute_key, status, updated_at DESC);
                CREATE TABLE memory_maintenance_batches (
                    id TEXT PRIMARY KEY,
                    operation_count INTEGER NOT NULL,
                    deleted_count INTEGER NOT NULL,
                    replaced_count INTEGER NOT NULL,
                    sync_revision INTEGER NOT NULL,
                    applied_at TEXT NOT NULL
                ) STRICT;
                PRAGMA user_version = 30;
                """)
        }
    }
}
