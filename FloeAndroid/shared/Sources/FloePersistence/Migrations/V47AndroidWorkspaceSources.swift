// SPDX-License-Identifier: MPL-2.0
// Android projection only: same original DatabaseManager; no parallel DB.
import GRDB

enum V47AndroidWorkspaceSources {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v47_android_workspace_sources") { db in
            try db.execute(sql: """
                CREATE TABLE android_workspace_sources (
                    id TEXT PRIMARY KEY,
                    workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
                    logical_path TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('saf', 'webdav', 'smb')),
                    source_reference TEXT NOT NULL,
                    source_document_id TEXT,
                    source_sha256 TEXT,
                    entity_tag TEXT,
                    revision TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    UNIQUE(workspace_id, logical_path)
                ) STRICT;
                -- Recovery metadata intentionally survives source/workspace
                -- deletion. Bytes remain in native-owned recovery storage;
                -- cleanup requires a separate verified reconciliation.
                CREATE TABLE android_workspace_recovery (
                    id TEXT PRIMARY KEY,
                    source_id TEXT NOT NULL,
                    workspace_id TEXT NOT NULL,
                    source_revision TEXT NOT NULL,
                    source_reference TEXT NOT NULL,
                    source_document_id TEXT,
                    backup_relative_path TEXT NOT NULL,
                    backup_sha256 TEXT NOT NULL,
                    replacement_sha256 TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('prepared', 'writing', 'committed', 'conflict', 'retained')),
                    observed_sha256 TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL
                ) STRICT;
                CREATE UNIQUE INDEX idx_android_workspace_recovery_one_prepared
                    ON android_workspace_recovery(source_id) WHERE state IN ('prepared', 'writing');
                CREATE INDEX idx_android_workspace_recovery_pending
                    ON android_workspace_recovery(state, workspace_id);
                PRAGMA user_version = 47;
                """)
        }
    }
}
