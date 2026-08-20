// FloePersistence — Schema v3 (daily-use Alpha).
// Append-only migration. v1/v2 are published and NEVER modified; all new
// structure lands here. Adds typed multimodal message content, attachments,
// the persisted agent event thread, per-run usage, structured errors and
// durable checkpoints. No secret-bearing payload is ever stored.

import GRDB

/// Registers schema v3 under migration identifier "v3".
enum V3AgentDaily {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3") { db in
            try db.execute(sql: sql)
            try db.execute(sql: "PRAGMA user_version = 3")
        }
    }

    static let sql = """
    -- Typed multimodal content parts for a message. A v1/v2 `messages.content`
    -- row remains the plain-text projection; structured parts (text, image,
    -- file reference, reasoning) live here so the thread can render evidence
    -- without parsing free text. Ordering is stable via `part_index`.
    CREATE TABLE message_parts (
        id TEXT PRIMARY KEY,
        message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
        part_index INTEGER NOT NULL,
        kind TEXT NOT NULL,
        text TEXT,
        attachment_id TEXT REFERENCES attachments(id) ON DELETE SET NULL,
        metadata_json TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL,
        UNIQUE(message_id, part_index)
    ) STRICT;
    CREATE INDEX idx_message_parts_message ON message_parts(message_id, part_index);

    -- Binary/large payload references. The bytes live on disk (Application
    -- Support) or behind a security-scoped bookmark; only metadata and the
    -- content digest are persisted. Never a secret.
    CREATE TABLE attachments (
        id TEXT PRIMARY KEY,
        conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE,
        message_id TEXT REFERENCES messages(id) ON DELETE SET NULL,
        kind TEXT NOT NULL,
        display_name TEXT NOT NULL DEFAULT '',
        uti TEXT NOT NULL DEFAULT '',
        byte_count INTEGER NOT NULL DEFAULT 0,
        sha256 TEXT NOT NULL DEFAULT '',
        storage TEXT NOT NULL DEFAULT 'none',
        url_bookmark BLOB,
        relative_path TEXT,
        created_at TEXT NOT NULL
    ) STRICT;
    CREATE INDEX idx_attachments_conversation ON attachments(conversation_id);
    CREATE INDEX idx_attachments_message ON attachments(message_id);

    -- The canonical, append-only agent event thread. One row per normalized
    -- event (assistant text, tool request/result, terminal, file, approval,
    -- error, checkpoint, status). This is the durable source of truth the UI
    -- folds and replays; it is never rewritten in place.
    CREATE TABLE run_events (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
        sequence INTEGER NOT NULL,
        kind TEXT NOT NULL,
        payload_json TEXT NOT NULL DEFAULT '{}',
        created_at TEXT NOT NULL,
        UNIQUE(run_id, sequence)
    ) STRICT;
    CREATE INDEX idx_run_events_run ON run_events(run_id, sequence);

    -- Per-run token/cost usage, one row per reported checkpoint in the run.
    CREATE TABLE run_usage (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
        input_tokens INTEGER NOT NULL DEFAULT 0,
        output_tokens INTEGER NOT NULL DEFAULT 0,
        cost_estimate TEXT,
        recorded_at TEXT NOT NULL
    ) STRICT;
    CREATE INDEX idx_run_usage_run ON run_usage(run_id);

    -- Structured, provider-normalized errors attached to a run. Keeps the
    -- machine-readable kind and HTTP status alongside the human message so
    -- recovery UI can act without re-parsing.
    CREATE TABLE run_errors (
        id TEXT PRIMARY KEY,
        run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        message TEXT NOT NULL DEFAULT '',
        http_status INTEGER,
        recoverable INTEGER NOT NULL DEFAULT 0,
        recorded_at TEXT NOT NULL
    ) STRICT;
    CREATE INDEX idx_run_errors_run ON run_errors(run_id);

    -- Durable checkpoints for relaunch/recovery. The checkpoint body is the
    -- canonical-encoded JSON (see AgentCheckpoint); format_version guards
    -- forward compatibility. Persisted checkpoints never contain secrets.
    CREATE TABLE checkpoints (
        run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,
        conversation_id TEXT NOT NULL,
        format_version INTEGER NOT NULL,
        state TEXT NOT NULL,
        body_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    ) STRICT;
    CREATE INDEX idx_checkpoints_conversation ON checkpoints(conversation_id);

    -- Live remote session registry (SSH terminal / VNC). Lets the app
    -- reconnect honestly after relaunch and report suspended/unknown state
    -- rather than pretending a socket survived.
    CREATE TABLE remote_sessions (
        id TEXT PRIMARY KEY,
        host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
        kind TEXT NOT NULL,
        state TEXT NOT NULL,
        remote_session_ref TEXT,
        last_heartbeat_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
    ) STRICT;
    CREATE INDEX idx_remote_sessions_host ON remote_sessions(host_id);
    """
}
