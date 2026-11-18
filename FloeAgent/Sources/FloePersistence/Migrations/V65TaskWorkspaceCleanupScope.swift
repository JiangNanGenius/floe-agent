import GRDB

/// App-owned project roots share the privateTask representation but are not
/// disposable task directories. Preserve them when conversations are deleted.
enum V65TaskWorkspaceCleanupScope {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v65") { db in
            try db.execute(sql: """
                DROP TRIGGER queue_private_task_cleanup;
                DROP TRIGGER queue_private_workspace_cleanup;
                CREATE TRIGGER queue_private_task_cleanup BEFORE DELETE ON conversations
                BEGIN
                    INSERT OR IGNORE INTO local_workspace_cleanup
                    SELECT w.id, w.internal_relative_path FROM workspaces w
                    JOIN conversation_workspace_ownership o ON o.workspace_id = w.id
                    WHERE o.conversation_id = OLD.id AND w.kind = 'privateTask'
                      AND w.internal_relative_path LIKE 'PrivateTasks/%';
                END;
                CREATE TRIGGER queue_private_workspace_cleanup BEFORE DELETE ON workspaces
                WHEN OLD.kind = 'privateTask' AND OLD.internal_relative_path LIKE 'PrivateTasks/%'
                BEGIN
                    INSERT OR IGNORE INTO local_workspace_cleanup
                    VALUES (OLD.id, OLD.internal_relative_path);
                END;
                DELETE FROM local_workspace_cleanup
                WHERE workspace_id IN (
                    SELECT id FROM workspaces WHERE kind = 'privateTask'
                    AND internal_relative_path NOT LIKE 'PrivateTasks/%'
                );
                PRAGMA user_version = 65;
                """)
        }
    }
}
