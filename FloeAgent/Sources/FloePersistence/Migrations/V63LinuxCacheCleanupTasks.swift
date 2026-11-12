// SPDX-License-Identifier: MPL-2.0
import GRDB

/// Durable purpose row for the one-tap Linux cache-cleanup task.
///
/// The row is create-only. A check constraint fixes the literal profile and
/// Linux backend so a later writer cannot silently reinterpret an old task as
/// a broader capability. Conversation deletion cascades.
enum V63LinuxCacheCleanupTasks {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v63_linux_cache_cleanup_tasks") { db in
            try db.execute(sql: """
                CREATE TABLE linux_cache_cleanup_tasks (
                    conversation_id TEXT PRIMARY KEY
                        REFERENCES conversations(id) ON DELETE CASCADE,
                    profile TEXT NOT NULL
                        CHECK (profile = 'linuxCacheCleanup.v1'),
                    environment_id TEXT NOT NULL
                        CHECK (length(environment_id) > 0),
                    backend TEXT NOT NULL
                        CHECK (backend = 'linuxVM'),
                    runtime_generation TEXT,
                    created_at TEXT NOT NULL,
                    revision INTEGER NOT NULL DEFAULT 1
                        CHECK (revision = 1)
                ) STRICT;
                CREATE INDEX idx_linux_cache_cleanup_environment
                    ON linux_cache_cleanup_tasks(environment_id);
                PRAGMA user_version = 63;
                """)
        }
    }
}
