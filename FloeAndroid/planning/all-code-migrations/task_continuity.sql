-- C02 durable task continuity declarative fragment.
--
-- Main owns the ONE coordinated schema registration. Current registered
-- version is 51; register this fragment ONCE as v52 together with the other
-- approved pending fragments (C06 todos, C02 execution targets, C07 inputs)
-- and pair it with `PRAGMA user_version = 52` in the SAME migration closure.
-- Do NOT edit V1-V51, the G09-R2 `selected_at` column or the existing
-- `task_execution_targets` / `task_remote_command_receipts` tables.
--
-- The Swift store fails closed with `schemaUnavailable` until this table
-- exists; the bounded recovery sidecar remains the honest fallback while the
-- database itself is unreachable.
--
-- Semantics:
--   * one row per run (UNIQUE run_id); a new pause generation replaces a
--     historical `.resumed` row;
--   * `state='resumeInProgress'` is a single-writer CAS claim, so a duplicate
--     tap or a restart during resume cannot launch the run twice;
--   * `body_json` is the complete nonsecret marker (IDs/reason/timestamps/
--     target pin only; never question text, approval text, tool output,
--     paths or secrets);
--   * `root_fingerprint` is SHA-256 of the normalized app-private root path,
--     not the process owner token.

CREATE TABLE IF NOT EXISTS task_continuity_pauses (
    marker_id TEXT PRIMARY KEY NOT NULL,
    task_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
    root_epoch INTEGER NOT NULL CHECK(root_epoch > 0),
    root_fingerprint TEXT NOT NULL,
    reason TEXT NOT NULL CHECK(reason IN (
        'permissionRevoked','volumeMissing','volumeReadOnly',
        'volumeFull','databaseUnavailable')),
    state TEXT NOT NULL CHECK(state IN (
        'awaitingStorageRecovery','resumeInProgress',
        'resumeFailed','resumed')),
    durability TEXT NOT NULL CHECK(durability IN (
        'taskDatabase','recoveryMetadata','memoryOnly')),
    detected_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    resume_attempt INTEGER NOT NULL CHECK(resume_attempt >= 0),
    target_revision INTEGER,
    target_root_epoch INTEGER,
    environment_id TEXT,
    workspace_id TEXT,
    run_checkpointed INTEGER NOT NULL CHECK(run_checkpointed IN (0,1)),
    unknown_outcome_count INTEGER NOT NULL DEFAULT 0,
    body_json TEXT NOT NULL,
    UNIQUE (run_id)
) STRICT;

CREATE INDEX IF NOT EXISTS task_continuity_pauses_task
ON task_continuity_pauses(task_id, state, updated_at);

CREATE INDEX IF NOT EXISTS task_continuity_pauses_run
ON task_continuity_pauses(run_id, state);
