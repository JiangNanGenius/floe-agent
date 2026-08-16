import GRDB

/// Adds task archiving, a dedicated approval model and secret-free credential
/// metadata. Secret bodies remain exclusively in Keychain.
enum V11ArchiveCredentials {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v11") { db in
            try db.execute(sql: """
                ALTER TABLE conversations ADD COLUMN archived_at TEXT;
                CREATE INDEX idx_conversations_archive
                    ON conversations(archived_at, updated_at DESC);

                ALTER TABLE model_preferences ADD COLUMN approval_model_id TEXT
                    REFERENCES models(id) ON DELETE SET NULL;

                CREATE TABLE credential_records (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL CHECK (kind IN (
                        'providerAPIKey', 'sshPassword', 'sshPrivateKey',
                        'vncPassword', 'websitePassword', 'genericToken'
                    )),
                    owner_kind TEXT NOT NULL CHECK (owner_kind IN (
                        'conversation', 'workspace', 'vault'
                    )),
                    conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE,
                    workspace_id TEXT REFERENCES workspaces(id) ON DELETE CASCADE,
                    host_id TEXT REFERENCES hosts(id) ON DELETE SET NULL,
                    origin TEXT,
                    label TEXT NOT NULL,
                    keychain_account TEXT NOT NULL UNIQUE,
                    synchronizable INTEGER NOT NULL DEFAULT 0,
                    device_bound INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    CHECK (
                        (owner_kind = 'conversation' AND conversation_id IS NOT NULL AND workspace_id IS NULL)
                        OR (owner_kind = 'workspace' AND workspace_id IS NOT NULL AND conversation_id IS NULL)
                        OR (owner_kind = 'vault' AND conversation_id IS NULL AND workspace_id IS NULL)
                    )
                ) STRICT;
                CREATE INDEX idx_credentials_conversation
                    ON credential_records(conversation_id) WHERE conversation_id IS NOT NULL;
                CREATE INDEX idx_credentials_workspace
                    ON credential_records(workspace_id) WHERE workspace_id IS NOT NULL;
                CREATE INDEX idx_credentials_vault
                    ON credential_records(owner_kind, updated_at DESC);

                CREATE TABLE credential_deletion_queue (
                    keychain_account TEXT PRIMARY KEY,
                    synchronizable INTEGER NOT NULL,
                    enqueued_at TEXT NOT NULL,
                    last_error TEXT
                ) STRICT;

                CREATE TRIGGER credential_delete_queue
                BEFORE DELETE ON credential_records
                BEGIN
                    INSERT OR IGNORE INTO credential_deletion_queue (
                        keychain_account, synchronizable, enqueued_at
                    ) VALUES (OLD.keychain_account, OLD.synchronizable, datetime('now'));
                END;

                PRAGMA user_version = 11;
                """)
        }
    }
}
