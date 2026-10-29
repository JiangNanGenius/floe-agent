// FloePersistence — Schema v1.
// See blazing-aurora-darwin.md §9: 13 STRICT tables + message_fts FTS5
// virtual table + indexes. This migration is published and must NEVER be
// modified; changes go into "v2" etc.

import Foundation
import GRDB

/// Registers the initial schema under migration identifier "v1".
enum V1Initial {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.execute(sql: V1Initial.sql)
            // Align user_version with the applied migration set.
            try db.execute(sql: "PRAGMA user_version = 1")
        }
    }

    static let sql = """
    -- Model configuration (never stores secret bodies).
    CREATE TABLE providers (
        id TEXT PRIMARY KEY,
        kind TEXT NOT NULL,
        wire_protocol TEXT NOT NULL,
        base_url TEXT NOT NULL,
        secret_ref_account TEXT,
        secret_ref_synchronizable INTEGER,
        region TEXT,
        non_secret_headers_json TEXT NOT NULL DEFAULT '{}',
        is_enabled INTEGER NOT NULL DEFAULT 1,
        allows_plain_http INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        sync_revision INTEGER NOT NULL DEFAULT 0
    ) STRICT;

    CREATE TABLE models (
        id TEXT PRIMARY KEY,
        provider_id TEXT NOT NULL REFERENCES providers(id) ON DELETE CASCADE,
        remote_model_id TEXT NOT NULL,
        display_name TEXT NOT NULL,
        context_tokens INTEGER NOT NULL,
        max_output_tokens INTEGER NOT NULL,
        pricing_json TEXT,
        capabilities INTEGER NOT NULL DEFAULT 1,
        is_enabled INTEGER NOT NULL DEFAULT 1
    ) STRICT;
    CREATE INDEX idx_models_provider ON models(provider_id);

    -- Conversation history.
    CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    ) STRICT;

    CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        created_at TEXT NOT NULL
    ) STRICT;
    CREATE INDEX idx_messages_conversation ON messages(conversation_id, created_at);

    CREATE VIRTUAL TABLE message_fts USING fts5(
        content,
        content='messages',
        content_rowid='rowid',
        tokenize='unicode61'
    );

    CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
        INSERT INTO message_fts(rowid, content) VALUES (new.rowid, new.content);
    END;
    CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
        INSERT INTO message_fts(message_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
    END;
    CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
        INSERT INTO message_fts(message_fts, rowid, content) VALUES ('delete', old.rowid, old.content);
        INSERT INTO message_fts(rowid, content) VALUES (new.rowid, new.content);
    END;

    -- Agent runs.
    CREATE TABLE runs (
        id TEXT PRIMARY KEY,
        conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
        state TEXT NOT NULL,
        goal TEXT NOT NULL,
        started_at TEXT NOT NULL,
        ended_at TEXT
    ) STRICT;
    CREATE INDEX idx_runs_conversation ON runs(conversation_id);

    CREATE TABLE tool_calls (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
        tool_name TEXT NOT NULL,
        arguments_json BLOB NOT NULL,
        scope_json TEXT NOT NULL,
        idempotency_key TEXT NOT NULL,
        status TEXT NOT NULL,
        output_summary TEXT NOT NULL DEFAULT '',
        output_digest TEXT NOT NULL DEFAULT '',
        exit_status INTEGER,
        created_at TEXT NOT NULL,
        UNIQUE(run_id, idempotency_key)
    ) STRICT;
    CREATE INDEX idx_tool_calls_run ON tool_calls(run_id);

    CREATE TABLE approvals (
        id TEXT PRIMARY KEY,
        run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
        tool_name TEXT NOT NULL,
        host_id TEXT,
        paths_json TEXT NOT NULL DEFAULT '[]',
        single_use INTEGER NOT NULL DEFAULT 1,
        decision TEXT NOT NULL,
        policy_name TEXT NOT NULL,
        decided_at TEXT NOT NULL,
        expires_at TEXT
    ) STRICT;
    CREATE INDEX idx_approvals_run ON approvals(run_id);

    -- Append-only, hash-chained audit log. UPDATE/DELETE raise via
    -- triggers (GRDB exposes no public sqlite3 authorizer surface).
    CREATE TABLE audit_entries (
        id TEXT PRIMARY KEY,
        sequence INTEGER NOT NULL UNIQUE,
        timestamp TEXT NOT NULL,
        run_id TEXT NOT NULL,
        model_remote_id TEXT NOT NULL,
        tool_name TEXT NOT NULL,
        target TEXT NOT NULL DEFAULT '',
        policy_used TEXT NOT NULL DEFAULT '',
        decision TEXT NOT NULL DEFAULT '',
        exit_status INTEGER,
        output_digest_sha256 TEXT NOT NULL DEFAULT '',
        prev_hash_sha256 TEXT NOT NULL,
        entry_hash_sha256 TEXT NOT NULL
    ) STRICT;
    CREATE INDEX idx_audit_entries_run ON audit_entries(run_id);

    CREATE TRIGGER audit_entries_no_update
    BEFORE UPDATE ON audit_entries BEGIN
        SELECT RAISE(ABORT, 'audit_entries is append-only');
    END;
    CREATE TRIGGER audit_entries_no_delete
    BEFORE DELETE ON audit_entries BEGIN
        SELECT RAISE(ABORT, 'audit_entries is append-only');
    END;

    -- Remote hosts.
    CREATE TABLE hosts (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        address TEXT NOT NULL,
        port INTEGER NOT NULL DEFAULT 22,
        user TEXT NOT NULL,
        auth_json TEXT NOT NULL,
        jump_chain_json TEXT NOT NULL DEFAULT '[]',
        host_key_policy TEXT NOT NULL DEFAULT 'trustOnFirstUse',
        allows_legacy_algorithms INTEGER NOT NULL DEFAULT 0,
        vnc_endpoint_json TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    ) STRICT;

    CREATE TABLE known_hosts (
        id TEXT PRIMARY KEY,
        host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
        address TEXT NOT NULL,
        port INTEGER NOT NULL,
        key_type TEXT NOT NULL,
        fingerprint_sha256 TEXT NOT NULL,
        first_seen_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL,
        UNIQUE(address, port, key_type)
    ) STRICT;

    CREATE TABLE vnc_sessions (
        id TEXT PRIMARY KEY,
        host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
        started_at TEXT NOT NULL,
        ended_at TEXT,
        action_count INTEGER NOT NULL DEFAULT 0
    ) STRICT;
    CREATE INDEX idx_vnc_sessions_host ON vnc_sessions(host_id);

    -- Document/image metadata. url_bookmark stores security-scoped
    -- URL bookmark data (iOS).
    CREATE TABLE documents (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        url_bookmark BLOB,
        uti TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    ) STRICT;

    CREATE TABLE images (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        url_bookmark BLOB,
        width INTEGER NOT NULL DEFAULT 0,
        height INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    ) STRICT;
    """
}
