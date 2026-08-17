import GRDB

/// Adds durable queue/steer input state. `position` is conversation-local;
/// lifecycle transitions use conditional UPDATEs for exactly-once promotion.
enum V12RunningInputs {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v12") { db in
            try db.execute(sql: """
                CREATE TABLE pending_user_inputs (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL
                        REFERENCES conversations(id) ON DELETE CASCADE,
                    target_run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
                    content TEXT NOT NULL,
                    mode TEXT NOT NULL CHECK(mode IN ('queue', 'steer')),
                    status TEXT NOT NULL CHECK(status IN (
                        'queued', 'promoting', 'steerPending', 'consumed', 'cancelled'
                    )),
                    position INTEGER NOT NULL,
                    attachments_json TEXT NOT NULL DEFAULT '[]',
                    selected_model_id TEXT REFERENCES models(id) ON DELETE SET NULL,
                    workspace_id TEXT REFERENCES workspaces(id) ON DELETE SET NULL,
                    execution_mode TEXT NOT NULL DEFAULT 'agent',
                    consumed_run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    consumed_at TEXT
                ) STRICT;
                CREATE INDEX idx_pending_inputs_conversation
                    ON pending_user_inputs(conversation_id, status, position, created_at);
                CREATE INDEX idx_pending_inputs_target_run
                    ON pending_user_inputs(target_run_id, status);
                PRAGMA user_version = 12;
                """)
        }
    }
}
