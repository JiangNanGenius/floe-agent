import GRDB

public enum V58TaskExecutionBindings {
    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v58_task_execution_bindings") { db in
            try db.execute(sql: """
                ALTER TABLE runs ADD COLUMN execution_binding_json TEXT;
                CREATE TABLE task_execution_bindings (
                    conversation_id TEXT PRIMARY KEY NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    generation INTEGER NOT NULL CHECK(generation > 0),
                    body_json TEXT NOT NULL
                );
                CREATE TABLE task_environment_migrations (
                    id TEXT PRIMARY KEY NOT NULL,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    phase TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    body_json TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE UNIQUE INDEX task_environment_migration_active
                ON task_environment_migrations(conversation_id)
                WHERE phase NOT IN ('completed', 'cancelled');
                CREATE TABLE task_environment_migration_checkpoints (
                    migration_id TEXT NOT NULL REFERENCES task_environment_migrations(id) ON DELETE CASCADE,
                    run_id TEXT NOT NULL,
                    body_json TEXT NOT NULL,
                    PRIMARY KEY(migration_id, run_id)
                );
                PRAGMA user_version = 58;
                """)
        }
    }
}
