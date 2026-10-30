import GRDB

/// Durable task-bound user questions.
///
/// One row per request plus one row per question. Question text, options,
/// draft state and accepted answers live in the bounded JSON payload; the
/// duplicated columns exist only for ownership/status queries and CAS
/// updates. Temporary conversations never insert here.
enum V56UserQuestions {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v56") { db in
            try db.execute(sql: """
                CREATE TABLE user_question_requests (
                    request_id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                    tool_call_id TEXT NOT NULL,
                    request_digest TEXT NOT NULL,
                    wait_policy TEXT NOT NULL,
                    state TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    request_json TEXT NOT NULL,
                    UNIQUE (run_id, tool_call_id)
                ) STRICT;

                CREATE TABLE user_questions (
                    question_id TEXT PRIMARY KEY,
                    request_id TEXT NOT NULL REFERENCES user_question_requests(request_id) ON DELETE CASCADE,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    revision INTEGER NOT NULL CHECK (revision > 0),
                    status TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    delivered_at REAL,
                    UNIQUE (request_id, ordinal)
                ) STRICT;

                CREATE INDEX user_question_requests_conversation
                    ON user_question_requests (conversation_id, state, created_at);
                CREATE INDEX user_question_requests_run
                    ON user_question_requests (run_id, state);
                CREATE INDEX user_questions_request
                    ON user_questions (request_id, ordinal);
                CREATE INDEX user_questions_pending
                    ON user_questions (conversation_id, status);
                PRAGMA user_version = 56;
                """)
        }
    }
}
