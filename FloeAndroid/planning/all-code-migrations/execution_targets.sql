-- C02 execution-target declarative migration fragment.
--
-- Main owns the ONE coordinated schema registration (planning/
-- ALL_CODE_MIGRATION_FRAGMENTS.json). This fragment adds tables/indexes only;
-- it does not edit V1-V51, the registered DatabaseManager version or any
-- existing row. Pair these statements with the coordinated next version and
-- `PRAGMA user_version = <coordinated version>` in the SAME migration closure.
--
-- The current registered schema is 51. The Swift store fails closed with
-- `schemaUnavailable` until this fragment is registered.
--
-- CAS semantics:
--   * task_execution_targets.conversation_id is the task identity; insert is
--     ON CONFLICT DO NOTHING (first writer wins).
--   * task_execution_targets.revision strictly advances only in the same
--     SQLite writer transaction that commits the verified migration.
--   * task_execution_target_migrations.revision is the outer CAS; a stale
--     writer changes zero rows. Failed rows are terminal for retry purposes
--     and do not block a later attempt.
--   * task_run_execution_targets pins each run to target revision + root
--     epoch. Historical completed/cancelled rows are never rewritten.
--   * task_remote_command_receipts is a bounded receipt ledger keyed by the
--     existing run/tool-call operation identity; it is not a job registry.

CREATE TABLE IF NOT EXISTS task_execution_targets (
    conversation_id TEXT PRIMARY KEY NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    revision INTEGER NOT NULL CHECK(revision > 0),
    kind TEXT NOT NULL CHECK(kind IN ('localLinux','ssh')),
    environment_id TEXT NOT NULL,
    project_id TEXT,
    workspace_id TEXT NOT NULL,
    shell_root_hash TEXT NOT NULL,
    engine_owner_hash TEXT NOT NULL,
    root_epoch INTEGER NOT NULL CHECK(root_epoch > 0),
    remote_host_id TEXT,
    remote_root_path TEXT,
    remote_os TEXT,
    remote_architecture TEXT,
    remote_generation TEXT,
    provenance TEXT NOT NULL,
    body_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    CHECK (
        (kind = 'ssh' AND remote_host_id IS NOT NULL
            AND remote_root_path IS NOT NULL
            AND remote_generation IS NOT NULL AND length(remote_generation) > 0)
        OR
        (kind = 'localLinux' AND remote_host_id IS NULL
            AND remote_root_path IS NULL AND remote_generation IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS task_execution_targets_workspace
ON task_execution_targets(workspace_id);

CREATE INDEX IF NOT EXISTS task_execution_targets_remote_host
ON task_execution_targets(remote_host_id);

CREATE TABLE IF NOT EXISTS task_execution_target_migrations (
    id TEXT PRIMARY KEY NOT NULL,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    phase TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK(revision > 0),
    source_revision INTEGER NOT NULL,
    body_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

-- One active move per task. `failed` is terminal: a retry is a new migration.
CREATE UNIQUE INDEX IF NOT EXISTS task_execution_target_migration_active
ON task_execution_target_migrations(conversation_id)
WHERE phase NOT IN ('completed', 'cancelled', 'failed');

CREATE INDEX IF NOT EXISTS task_execution_target_migration_status
ON task_execution_target_migrations(conversation_id, phase, revision);

CREATE TABLE IF NOT EXISTS task_run_execution_targets (
    run_id TEXT PRIMARY KEY NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    target_revision INTEGER NOT NULL CHECK(target_revision > 0),
    environment_id TEXT NOT NULL,
    shell_root_hash TEXT NOT NULL,
    engine_owner_hash TEXT NOT NULL,
    root_epoch INTEGER NOT NULL CHECK(root_epoch > 0),
    body_json TEXT NOT NULL,
    pinned_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS task_run_execution_targets_task
ON task_run_execution_targets(conversation_id, target_revision);

CREATE TABLE IF NOT EXISTS task_remote_command_receipts (
    operation_id TEXT PRIMARY KEY NOT NULL,
    task_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    run_id TEXT,
    tool_call_id TEXT,
    target_revision INTEGER NOT NULL CHECK(target_revision > 0),
    root_epoch INTEGER NOT NULL CHECK(root_epoch > 0),
    host_id TEXT NOT NULL,
    command_sha256 TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('dispatched','notStarted','exited','cancelled','timedOut','outcomeUnknown')),
    exit_code INTEGER,
    started_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    detail_code TEXT,
    body_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS task_remote_command_receipts_task
ON task_remote_command_receipts(task_id, updated_at);
