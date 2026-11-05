import GRDB

/// Expand the existing schedule cadence constraint without touching occurrences,
/// R2 ownership tables, selected_at or earlier migration identities.
enum V53AndroidSystemConditions {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v53_android_system_conditions") { db in
            try db.execute(sql: """
                CREATE TABLE task_schedules_v53 (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    prompt TEXT NOT NULL,
                    workspace_id TEXT REFERENCES workspaces(id) ON DELETE SET NULL,
                    cadence TEXT NOT NULL CHECK (cadence IN (
                        'once', 'daily', 'weekly', 'interval', 'afterSuccess',
                        'charging', 'networkConnected'
                    )),
                    scheduled_at TEXT NOT NULL,
                    weekday INTEGER,
                    is_enabled INTEGER NOT NULL DEFAULT 1,
                    last_started_at TEXT,
                    next_expected_at TEXT,
                    policy_json TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    interval_seconds INTEGER,
                    anchor_timezone TEXT,
                    upstream_run_id TEXT,
                    model_id TEXT,
                    environment_id TEXT,
                    permission_json TEXT
                ) STRICT;
                INSERT INTO task_schedules_v53 (
                    id, title, prompt, workspace_id, cadence, scheduled_at,
                    weekday, is_enabled, last_started_at, next_expected_at,
                    policy_json, created_at, updated_at, interval_seconds,
                    anchor_timezone, upstream_run_id, model_id, environment_id, permission_json
                ) SELECT
                    id, title, prompt, workspace_id, cadence, scheduled_at,
                    weekday, is_enabled, last_started_at, next_expected_at,
                    policy_json, created_at, updated_at, interval_seconds,
                    anchor_timezone, upstream_run_id, model_id, environment_id, permission_json
                FROM task_schedules;
                DROP TABLE task_schedules;
                ALTER TABLE task_schedules_v53 RENAME TO task_schedules;
                CREATE INDEX idx_task_schedules_next ON task_schedules(is_enabled, next_expected_at);
                """)
        }
    }
}
