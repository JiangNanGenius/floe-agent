import GRDB

/// Adds deterministic message/run and run/goal ownership without guessing
/// ambiguous legacy relationships.
enum V10ConversationContinuity {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v10") { db in
            try db.execute(sql: """
                ALTER TABLE messages ADD COLUMN run_id TEXT
                    REFERENCES runs(id) ON DELETE SET NULL;
                ALTER TABLE runs ADD COLUMN goal_id TEXT
                    REFERENCES conversation_goals(id) ON DELETE SET NULL;
                CREATE INDEX idx_messages_run ON messages(run_id, created_at);
                CREATE INDEX idx_runs_goal ON runs(goal_id, started_at);

                UPDATE messages
                SET run_id = (
                    SELECT r.id FROM runs r
                    WHERE r.conversation_id = messages.conversation_id
                      AND r.goal = messages.content LIMIT 1
                )
                WHERE role = 'user'
                  AND 1 = (
                    SELECT COUNT(*) FROM runs r
                    WHERE r.conversation_id = messages.conversation_id
                      AND r.goal = messages.content
                  );

                UPDATE messages
                SET run_id = (
                    SELECT r.id FROM runs r
                    WHERE r.conversation_id = messages.conversation_id
                      AND julianday(messages.created_at) >= julianday(r.started_at)
                      AND r.ended_at IS NOT NULL
                      AND julianday(messages.created_at) <= julianday(r.ended_at) + (2.0 / 86400.0)
                    LIMIT 1
                )
                WHERE role = 'assistant'
                  AND 1 = (
                    SELECT COUNT(*) FROM runs r
                    WHERE r.conversation_id = messages.conversation_id
                      AND julianday(messages.created_at) >= julianday(r.started_at)
                      AND r.ended_at IS NOT NULL
                      AND julianday(messages.created_at) <= julianday(r.ended_at) + (2.0 / 86400.0)
                  );

                UPDATE runs
                SET goal_id = (
                    SELECT g.id FROM conversation_goals g
                    WHERE g.conversation_id = runs.conversation_id LIMIT 1
                )
                WHERE 1 = (
                    SELECT COUNT(*) FROM conversation_goals g
                    WHERE g.conversation_id = runs.conversation_id
                );
                PRAGMA user_version = 10;
                """)
        }
    }
}
