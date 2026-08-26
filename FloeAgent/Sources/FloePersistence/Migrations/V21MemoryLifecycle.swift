// FloePersistence — Schema v21: durable memory ownership and recall aging.

import Foundation
import GRDB

enum V21MemoryLifecycle {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v21") { db in
            try db.execute(sql: """
                ALTER TABLE memory_entries ADD COLUMN origin_workspace_id TEXT;
                ALTER TABLE memory_entries ADD COLUMN origin_conversation_id TEXT;
                ALTER TABLE memory_entries ADD COLUMN origin_owner_label TEXT;
                ALTER TABLE memory_entries ADD COLUMN owner_deleted_at TEXT;
                ALTER TABLE memory_entries ADD COLUMN last_recalled_at TEXT;
                ALTER TABLE memory_entries ADD COLUMN retained_until TEXT;
                ALTER TABLE memory_entries ADD COLUMN recall_count INTEGER NOT NULL DEFAULT 0;

                DROP INDEX IF EXISTS idx_memory_entries_unique_global_v8;
                DROP INDEX IF EXISTS idx_memory_entries_unique_workspace_v8;
                DROP INDEX IF EXISTS idx_memory_entries_unique_task_v8;
                CREATE UNIQUE INDEX idx_memory_entries_unique_global_v21
                    ON memory_entries(scope, normalized_content)
                    WHERE workspace_id IS NULL AND conversation_id IS NULL
                      AND origin_workspace_id IS NULL AND origin_conversation_id IS NULL;
                CREATE UNIQUE INDEX idx_memory_entries_unique_workspace_v21
                    ON memory_entries(scope, workspace_id, normalized_content)
                    WHERE workspace_id IS NOT NULL;
                CREATE UNIQUE INDEX idx_memory_entries_unique_task_v21
                    ON memory_entries(scope, conversation_id, normalized_content)
                    WHERE conversation_id IS NOT NULL;
                CREATE UNIQUE INDEX idx_memory_entries_unique_orphan_workspace_v21
                    ON memory_entries(scope, origin_workspace_id, normalized_content)
                    WHERE origin_workspace_id IS NOT NULL;
                CREATE UNIQUE INDEX idx_memory_entries_unique_orphan_task_v21
                    ON memory_entries(scope, origin_conversation_id, normalized_content)
                    WHERE origin_conversation_id IS NOT NULL;
                CREATE INDEX idx_memory_entries_aging_v21
                    ON memory_entries(owner_deleted_at, retained_until, last_recalled_at);
                PRAGMA user_version = 21;
                """)
        }
    }
}
