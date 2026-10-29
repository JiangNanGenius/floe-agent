import GRDB

/// Persists provider tool-name compatibility and the model used to review
/// managed Python package installations. Both values are secret-free.
enum V16ProviderCompatibilityAndPackageReview {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v16") { db in
            try db.execute(sql: """
                ALTER TABLE providers ADD COLUMN tool_name_compatibility INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE model_preferences ADD COLUMN package_review_model_id TEXT
                    REFERENCES models(id) ON DELETE SET NULL;
                PRAGMA user_version = 16;
                """)
        }
    }
}
