import GRDB

/// Schema v49 — durable, resumable delegated-child checkpoints and resume
/// lease/compare-and-set state.
///
/// `child_run_checkpoints` is the S7 audit17 durability boundary for TRUE
/// child checkpoint continuation (not a transcript view and not an
/// interrupted→running state flip). One row per child run carries:
///
///   * `payload_json` — the bounded, always-legal-JSON `ChildRunCheckpoint`
///     document: actual provider continuation messages, replayed tool pairs,
///     pending tool intent, discovery/skill revisions, truncation counters,
///     evidence and trusted provenance (provider/model ids, original
///     parent/root/conversation ids, spent iterations and the effective hard
///     ceiling). Exact JSON must fit `maximumCheckpointBytes`; oversized
///     continuation state is refused without clipping executable intent. Runtime handles
///     (dispatchers, peer buses, grants, credentials) are NEVER persisted —
///     the checkpoint is data, never authority.
///   * resume lease/CAS columns — `resume_state`,
///     `lease_owner`/`lease_expires_at`, `resume_parent_run_id` and
///     `resume_count`. `acquireResume` atomically (inside one GRDB
///     transaction) refuses non-`interrupted` children (finished-child
///     refusal), grants the lease only when no live lease exists (concurrent
///     resume convergence) and flips the child row back to `running` bound to
///     the ACTUAL current authorized resuming parent. An expired lease is
///     re-acquirable after process death, and `reconcileInterruptedOnLaunch`
///     resets stale lease state whenever it marks children interrupted.
///
/// The checkpoint NEVER stores credentials or approval grants: the resuming
/// parent runtime re-derives effective rights, environment, model and tool
/// availability from its own live state and intersects them with the current
/// parent allowance at resume time.
///
/// PRIMARY REGISTRATION (DatabaseManager.swift, owned by the integrator):
///   1. Bump `currentSchemaVersion` from 48 to 49 (48 is the Alarm lane's
///      `V48SystemAlarms`; this migration appends after it and never
///      renumbers or competes with it).
///   2. Add `V49ChildRunCheckpoints.register(into: &migrator)` immediately
///      after `V48SystemAlarms.register(into: &migrator)`.
enum V49ChildRunCheckpoints {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v49_child_run_checkpoints") { db in
            try ChildRunCheckpointSchema.apply(db)
            try db.execute(sql: "PRAGMA user_version = 49")
        }
    }
}
