import GRDB

/// Exact, durable canvas ownership for one agent run. Tool execution must not
/// discover ownership by scanning every project file: that is slow for large
/// libraries and can bind a recovered run to the wrong document selection.
enum V32CanvasRunContexts {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v32") { db in
            try db.execute(sql: """
                CREATE TABLE canvas_run_contexts (
                    run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    canvas_id TEXT NOT NULL,
                    document_id TEXT,
                    selected_node_ids_json TEXT NOT NULL DEFAULT '[]',
                    project_revision INTEGER NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE INDEX idx_canvas_run_contexts_conversation_v32
                    ON canvas_run_contexts(conversation_id, created_at DESC);
                PRAGMA user_version = 32;
                """)
        }
    }
}
