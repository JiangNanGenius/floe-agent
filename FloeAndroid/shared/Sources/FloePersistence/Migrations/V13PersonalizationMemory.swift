// FloePersistence — Schema v13: durable memory review, vector recall and
// versioned personalization documents.

import GRDB

enum V13PersonalizationMemory {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v13") { db in
            try db.execute(sql: """
                CREATE TABLE memory_embeddings (
                    memory_id TEXT NOT NULL
                        REFERENCES memory_entries(id) ON DELETE CASCADE,
                    modality TEXT NOT NULL CHECK (modality IN ('text', 'image')),
                    model_identifier TEXT NOT NULL,
                    model_revision TEXT NOT NULL,
                    dimensions INTEGER NOT NULL CHECK (dimensions > 0 AND dimensions <= 4096),
                    vector_blob BLOB NOT NULL,
                    content_digest TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY(memory_id, modality, model_identifier, model_revision)
                ) STRICT;
                CREATE INDEX idx_memory_embeddings_model
                    ON memory_embeddings(modality, model_identifier, model_revision);

                CREATE TABLE memory_candidates (
                    id TEXT PRIMARY KEY,
                    scope TEXT NOT NULL,
                    workspace_id TEXT REFERENCES workspaces(id) ON DELETE CASCADE,
                    conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE,
                    content TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    stability REAL NOT NULL,
                    importance REAL NOT NULL,
                    sensitivity TEXT NOT NULL,
                    origin TEXT NOT NULL,
                    evidence_json TEXT NOT NULL DEFAULT '[]',
                    conflicts_json TEXT NOT NULL DEFAULT '[]',
                    source_attachment_id TEXT REFERENCES attachments(id) ON DELETE SET NULL,
                    source_mime_type TEXT,
                    status TEXT NOT NULL
                        CHECK (status IN ('pending', 'activated', 'rejected')),
                    review_reason TEXT,
                    expires_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                ) STRICT;
                CREATE INDEX idx_memory_candidates_review
                    ON memory_candidates(status, expires_at, importance DESC, created_at);
                CREATE INDEX idx_memory_candidates_scope
                    ON memory_candidates(scope, workspace_id, conversation_id, status);

                CREATE TABLE personalization_documents (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL CHECK (kind IN ('soul', 'userProfile')),
                    workspace_id TEXT REFERENCES workspaces(id) ON DELETE CASCADE,
                    revision INTEGER NOT NULL CHECK (revision > 0),
                    content TEXT NOT NULL,
                    source_kind TEXT NOT NULL,
                    evidence_digest TEXT NOT NULL DEFAULT '',
                    is_active INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL
                ) STRICT;
                CREATE UNIQUE INDEX idx_personalization_revision_global
                    ON personalization_documents(kind, revision)
                    WHERE workspace_id IS NULL;
                CREATE UNIQUE INDEX idx_personalization_revision_workspace
                    ON personalization_documents(kind, workspace_id, revision)
                    WHERE workspace_id IS NOT NULL;
                CREATE UNIQUE INDEX idx_personalization_active_global
                    ON personalization_documents(kind)
                    WHERE workspace_id IS NULL AND is_active = 1;
                CREATE UNIQUE INDEX idx_personalization_active_workspace
                    ON personalization_documents(kind, workspace_id)
                    WHERE workspace_id IS NOT NULL AND is_active = 1;

                CREATE TABLE personalization_update_cursors (
                    kind TEXT NOT NULL CHECK (kind IN ('soul', 'userProfile')),
                    workspace_key TEXT NOT NULL DEFAULT '',
                    workspace_id TEXT REFERENCES workspaces(id) ON DELETE CASCADE,
                    automatic_updates_enabled INTEGER NOT NULL DEFAULT 1,
                    last_generated_at TEXT,
                    completed_runs_since_update INTEGER NOT NULL DEFAULT 0,
                    user_messages_since_update INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY(kind, workspace_key),
                    CHECK (
                        (workspace_key = '' AND workspace_id IS NULL) OR
                        (workspace_key <> '' AND workspace_id = workspace_key)
                    )
                ) STRICT;

                PRAGMA user_version = 13;
                """)
        }
    }
}
