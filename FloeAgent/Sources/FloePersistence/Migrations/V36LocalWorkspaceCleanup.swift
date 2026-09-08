import GRDB

/// Cleanup intent commits with deletion, and survives both FK cascades and a
/// process exit between removing the task and removing its private files.
enum V36LocalWorkspaceCleanup {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v36") { db in
            try db.execute(sql: """
                CREATE TABLE local_workspace_cleanup (
                    workspace_id TEXT PRIMARY KEY,
                    relative_path TEXT NOT NULL
                ) STRICT;
                CREATE TRIGGER queue_private_task_cleanup BEFORE DELETE ON conversations
                BEGIN
                    INSERT OR IGNORE INTO local_workspace_cleanup
                    SELECT w.id, w.internal_relative_path FROM workspaces w
                    JOIN conversation_workspace_ownership o ON o.workspace_id = w.id
                    WHERE o.conversation_id = OLD.id AND w.kind = 'privateTask'
                      AND w.internal_relative_path IS NOT NULL;
                END;
                CREATE TRIGGER queue_private_workspace_cleanup BEFORE DELETE ON workspaces
                WHEN OLD.kind = 'privateTask' AND OLD.internal_relative_path IS NOT NULL
                BEGIN
                    INSERT OR IGNORE INTO local_workspace_cleanup
                    VALUES (OLD.id, OLD.internal_relative_path);
                END;
                PRAGMA user_version = 36;
                """)
        }
    }
}
