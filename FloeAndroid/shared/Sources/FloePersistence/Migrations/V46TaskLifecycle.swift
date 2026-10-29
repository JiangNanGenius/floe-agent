import GRDB

/// Schema v46 — run-lifecycle closure.
///
/// This migration adds durable truth for four previously in-memory or
/// truncated surfaces. It is additive except for one targeted table rebuild
/// (`run_relations`, which had a foreign-key/UNIQUE shape that made the
/// relation row impossible to write without also inventing a `runs` row for
/// every child); no existing data is deleted or reset.
///
///  * `task_schedules` gains the extended cadence fields (fixed interval and
///    upstream-success), the calendar timezone anchor, and the explicit
///    model/environment/permission binding frozen at schedule time.
///  * `task_schedule_occurrences` is the durable execution-instance ledger:
///    one row per logical fire time with a stable deterministic id, claimed
///    atomically BEFORE a task is launched, so foreground/background/
///    notification wakeups can never double-launch the same occurrence.
///  * `run_dependencies` records the parent-run → background-job dependency
///    edges that keep a required finite job's parent run nonterminal without a
///    live in-memory shadow store.
///  * `child_runs` / `child_run_entries` persist delegated child identity and
///    a bounded transcript (state transitions, messages, tool I/O, result)
///    with an owner/root/conversation binding written BEFORE the first child
///    turn.
///  * `background_jobs` gains `output_path`/`output_bytes` for the full
///    bounded output artifact spooled before any summary truncation.
enum V46TaskLifecycle {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v46_task_lifecycle") { db in
            // 1. Extended schedule fields. The historical table's CHECK
            //    constraint only admitted once/daily/weekly, so it is rebuilt
            //    (existing rows preserved verbatim) with the extended cadence
            //    set plus the new binding columns. Existing rows keep NULL in
            //    the new columns and decode with their historical semantics.
            try db.execute(sql: """
                CREATE TABLE task_schedules_v46 (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL,
                    prompt TEXT NOT NULL,
                    workspace_id TEXT REFERENCES workspaces(id) ON DELETE SET NULL,
                    cadence TEXT NOT NULL CHECK (cadence IN (
                        'once', 'daily', 'weekly', 'interval', 'afterSuccess'
                    )),
                    scheduled_at TEXT NOT NULL,
                    weekday INTEGER,
                    is_enabled INTEGER NOT NULL DEFAULT 1,
                    last_started_at TEXT,
                    next_expected_at TEXT,
                    policy_json TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    interval_seconds INTEGER,
                    anchor_timezone TEXT,
                    upstream_run_id TEXT,
                    model_id TEXT,
                    environment_id TEXT,
                    permission_json TEXT
                ) STRICT;
                INSERT INTO task_schedules_v46 (
                    id, title, prompt, workspace_id, cadence, scheduled_at,
                    weekday, is_enabled, last_started_at, next_expected_at,
                    policy_json, created_at, updated_at
                )
                SELECT
                    id, title, prompt, workspace_id, cadence, scheduled_at,
                    weekday, is_enabled, last_started_at, next_expected_at,
                    policy_json, created_at, updated_at
                FROM task_schedules;
                DROP TABLE task_schedules;
                ALTER TABLE task_schedules_v46 RENAME TO task_schedules;
                CREATE INDEX idx_task_schedules_next
                    ON task_schedules(is_enabled, next_expected_at);
                """)

            // 2. Execution instances. `id` is the stable logical occurrence id
            //    derived from (schedule, logical fire time); the UNIQUE dedupe
            //    key keeps a notification/foreground/background race from
            //    inserting two instances for one fire time.
            try db.execute(sql: """
                CREATE TABLE task_schedule_occurrences (
                    id TEXT PRIMARY KEY,
                    schedule_id TEXT NOT NULL,
                    scheduled_for TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN (
                        'pending', 'claimed', 'running', 'completed',
                        'failed', 'cancelled', 'skipped', 'interrupted'
                    )),
                    dedupe_key TEXT NOT NULL,
                    run_id TEXT,
                    conversation_id TEXT,
                    claimed_at TEXT,
                    started_at TEXT,
                    finished_at TEXT,
                    summary TEXT,
                    error_text TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(schedule_id, dedupe_key)
                ) STRICT;
                CREATE INDEX idx_schedule_occurrences_schedule
                    ON task_schedule_occurrences(schedule_id, scheduled_for);
                CREATE INDEX idx_schedule_occurrences_state
                    ON task_schedule_occurrences(state, scheduled_for);
                CREATE INDEX idx_schedule_occurrences_run
                    ON task_schedule_occurrences(run_id);
                """)

            // 3. Parent-run dependencies on finite background work.
            try db.execute(sql: """
                CREATE TABLE run_dependencies (
                    job_id TEXT PRIMARY KEY,
                    run_id TEXT NOT NULL,
                    conversation_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK(kind IN ('job', 'service')),
                    state TEXT NOT NULL CHECK(state IN (
                        'pending', 'resolved', 'failed', 'cancelled', 'interrupted'
                    )),
                    created_at TEXT NOT NULL,
                    resolved_at TEXT,
                    note TEXT
                ) STRICT;
                CREATE INDEX idx_run_dependencies_run
                    ON run_dependencies(run_id, state);
                """)

            // 4. Delegated child identity + bounded transcript.
            try db.execute(sql: """
                CREATE TABLE child_runs (
                    id TEXT PRIMARY KEY,
                    parent_run_id TEXT NOT NULL,
                    root_run_id TEXT NOT NULL,
                    conversation_id TEXT NOT NULL,
                    child_index INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    task_summary TEXT NOT NULL,
                    state TEXT NOT NULL,
                    iteration_count INTEGER NOT NULL DEFAULT 0,
                    started_at TEXT NOT NULL,
                    ended_at TEXT,
                    result_summary TEXT,
                    error_text TEXT,
                    digest TEXT,
                    updated_at TEXT NOT NULL
                ) STRICT;
                CREATE INDEX idx_child_runs_parent
                    ON child_runs(parent_run_id, started_at);
                CREATE INDEX idx_child_runs_conversation
                    ON child_runs(conversation_id, started_at);

                CREATE TABLE child_run_entries (
                    id TEXT PRIMARY KEY,
                    child_run_id TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    UNIQUE(child_run_id, sequence)
                ) STRICT;
                CREATE INDEX idx_child_run_entries_child
                    ON child_run_entries(child_run_id, sequence);
                """)

            // 5. Rebuild run_relations without the FK to `runs` (delegated
            //    children are persisted in `child_runs`, not as ordinary runs)
            //    and with the root/conversation/state columns the inspector and
            //    the transcript query both read. Existing rows are preserved
            //    verbatim.
            try db.execute(sql: """
                CREATE TABLE run_relations_v46 (
                    parent_run_id TEXT NOT NULL,
                    child_run_id TEXT NOT NULL UNIQUE,
                    child_index INTEGER NOT NULL,
                    task_summary TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    root_run_id TEXT,
                    conversation_id TEXT,
                    state TEXT,
                    updated_at TEXT,
                    -- The provider tool-call id of the delegate call that
                    -- created this child (callID → child run id mapping for
                    -- the delegate tool card).
                    delegate_call_id TEXT,
                    PRIMARY KEY(parent_run_id, child_index)
                ) STRICT;
                INSERT INTO run_relations_v46 (
                    parent_run_id, child_run_id, child_index, task_summary, created_at
                )
                SELECT parent_run_id, child_run_id, child_index, task_summary, created_at
                FROM run_relations;
                DROP TABLE run_relations;
                ALTER TABLE run_relations_v46 RENAME TO run_relations;
                """)

            // 6. Full-output spool location for background jobs.
            try db.alter(table: "background_jobs") { table in
                table.add(column: "output_path", .text)
                table.add(column: "output_bytes", .integer)
            }

            // 7. Provider capability provenance (lane C contract): the bits a
            //    user explicitly decided, plus bits applied by the reviewed
            //    catalog migration. NULL for every existing row — NULL is the
            //    legacy "no provenance" state and must never be backfilled
            //    with 0 (an empty non-nil mask means "reviewed, nothing
            //    owned"). Catalog/discovery refresh and sync must never flip
            //    an owned bit.
            try db.execute(sql: "ALTER TABLE models ADD COLUMN explicit_capabilities INTEGER")

            try db.execute(sql: "PRAGMA user_version = 46")
        }
    }
}
