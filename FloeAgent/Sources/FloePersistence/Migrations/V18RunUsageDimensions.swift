import GRDB

/// Captures the provider/model selected for every run so token accounting can
/// be grouped by conversation, model and provider without guessing from the
/// user's current defaults. Names are snapshotted for durable history even if
/// a configuration is later renamed or removed.
enum V18RunUsageDimensions {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v18") { db in
            try db.execute(sql: """
                ALTER TABLE runs ADD COLUMN provider_id TEXT
                    REFERENCES providers(id) ON DELETE SET NULL;
                ALTER TABLE runs ADD COLUMN model_id TEXT
                    REFERENCES models(id) ON DELETE SET NULL;
                ALTER TABLE runs ADD COLUMN provider_name_snapshot TEXT;
                ALTER TABLE runs ADD COLUMN model_name_snapshot TEXT;
                CREATE INDEX idx_runs_provider ON runs(provider_id);
                CREATE INDEX idx_runs_model ON runs(model_id);
                PRAGMA user_version = 18;
                """)
        }
    }
}
