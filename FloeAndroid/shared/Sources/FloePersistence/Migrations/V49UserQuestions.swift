// SPDX-License-Identifier: MPL-2.0
//
// Durable task-bound user questions (Android schema position 49).
//
// The iOS reference registers this shape as V56; the Android overlay's
// current highest migration is V48, so the same reviewed tables are added
// here as v49. No table, column or index is renamed: the store's SQL is the
// exact frozen iOS statement set. Temporary conversations never insert here
// (UserQuestionStore keeps their rows in RAM only).
import GRDB

enum V49UserQuestions {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v49_user_questions") { db in
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
                PRAGMA user_version = 49;
                """)
        }
    }
}
