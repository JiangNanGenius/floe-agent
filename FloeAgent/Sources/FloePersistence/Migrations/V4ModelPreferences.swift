// FloePersistence — Schema v4: stable model identity and routing preferences.

import GRDB

enum V4ModelPreferences {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4") { db in
            // Older discovery runs could insert the same remote model more
            // than once. Keep the most recently inserted configuration.
            try db.execute(sql: """
                DELETE FROM models
                WHERE rowid NOT IN (
                    SELECT MAX(rowid) FROM models GROUP BY provider_id, remote_model_id
                );

                CREATE UNIQUE INDEX idx_models_provider_remote
                    ON models(provider_id, remote_model_id);

                CREATE TABLE model_preferences (
                    id TEXT PRIMARY KEY CHECK (id = 'default'),
                    onboarding_status TEXT NOT NULL DEFAULT 'unseen',
                    default_agent_model_id TEXT REFERENCES models(id) ON DELETE SET NULL,
                    auxiliary_image_mode TEXT NOT NULL DEFAULT 'shared',
                    shared_image_model_id TEXT REFERENCES models(id) ON DELETE SET NULL,
                    image_generation_model_id TEXT REFERENCES models(id) ON DELETE SET NULL,
                    image_editing_model_id TEXT REFERENCES models(id) ON DELETE SET NULL,
                    updated_at TEXT NOT NULL,
                    sync_revision INTEGER NOT NULL DEFAULT 0
                ) STRICT;

                INSERT INTO model_preferences (
                    id, onboarding_status, auxiliary_image_mode, updated_at
                ) VALUES ('default', 'unseen', 'shared', '1970-01-01T00:00:00.000Z');

                PRAGMA user_version = 4;
                """)
        }
    }
}
