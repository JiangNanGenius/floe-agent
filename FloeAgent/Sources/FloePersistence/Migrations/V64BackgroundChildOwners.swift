// SPDX-License-Identifier: MPL-2.0
import GRDB

/// Durable owner index for newly created background children. Existing child
/// histories are left untouched; ownership and provenance are written together.
enum V64BackgroundChildOwners {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v64_background_child_owners") { db in
            try db.execute(sql: """
                CREATE TABLE child_background_owners (
                    child_run_id TEXT PRIMARY KEY REFERENCES child_runs(id) ON DELETE CASCADE,
                    parent_run_id TEXT NOT NULL,
                    conversation_id TEXT NOT NULL
                ) STRICT;
                CREATE INDEX idx_background_child_parent ON child_background_owners(parent_run_id, conversation_id);
                PRAGMA user_version = 64;
                """)
        }
    }
}
