import GRDB

/// Durable CloudKit bookkeeping. Secret bodies are deliberately excluded.
enum V2ConfigSync {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2") { db in
            try db.execute(sql: sql)
            try db.execute(sql: "PRAGMA user_version = 2")
        }
    }

    static let sql = """
    CREATE TABLE config_sync_metadata (
        record_type TEXT NOT NULL,
        record_id TEXT NOT NULL,
        field_timestamps_json TEXT NOT NULL DEFAULT '{}',
        cloud_change_tag TEXT,
        cloud_system_fields BLOB,
        pending_action TEXT,
        deleted_at TEXT,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (record_type, record_id)
    ) STRICT;
    CREATE INDEX idx_config_sync_pending
        ON config_sync_metadata(pending_action, updated_at);

    CREATE TABLE sync_engine_state (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        serialization BLOB NOT NULL,
        updated_at TEXT NOT NULL
    ) STRICT;
    """
}
