import GRDB

enum V37TaskChecklists {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v37") { db in
            try db.execute(sql: """
                CREATE TABLE task_checklist_revisions (
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    revision INTEGER NOT NULL CHECK (revision > 0),
                    run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                    operation_id TEXT NOT NULL,
                    request_digest TEXT NOT NULL,
                    body_json TEXT NOT NULL,
                    PRIMARY KEY (conversation_id, revision),
                    UNIQUE (run_id, operation_id)
                ) STRICT;
                PRAGMA user_version = 37;
                """)
        }
    }
}
