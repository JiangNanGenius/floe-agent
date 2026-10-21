import GRDB

/// Schema v50 — Shortcut-setup monitoring + retired-schedule cleanup records.
///
/// `task_schedule_cleanup_reminders` keeps exactly ONE row per schedule
/// (unique `schedule_id`). A row is created ONLY by an actual Shortcut
/// handoff/confirmation (silent `monitoring` status), by the "Run Scheduled
/// Task" action firing for a missing schedule (`staleTrigger` evidence), or
/// by the reconciliation of such evidence — never by an ordinary schedule
/// delete. A silent monitoring row means "this plan may have a system
/// automation": the permanent delete and the terminal retirement of a
/// one-shot then open it as the user's cleanup to-do. Plans that never
/// received a Shortcut handoff have NO row, so deleting them shows nothing.
///
/// There is deliberately no foreign key to `task_schedules`: the row must
/// survive the schedule deletion itself (with its captured title), and
/// relaunches read only this table. The table is evidence + a user-managed
/// to-do, never lifecycle: nothing in it re-enables, re-arms or launches a
/// schedule, and the claim/due/CAS path is untouched — a lingering retired
/// automation keeps failing exactly as before with its typed refusal.
///
/// Integrity rules encoded below:
///   • `monitoring` rows carry NO reason; visible rows (open/dismissed/
///     removed) always carry exactly one reason;
///   • the first reason recorded when a row opens wins; repeated events only
///     advance `last_seen_at` (dedupe — no second row, no re-notification);
///   • a `dismissed` row stays silenced; a `removed` row may reopen ONLY on
///     the direct evidence of a new stale trigger.
enum V50ScheduleCleanupReminders {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v50_schedule_cleanup_reminders") { db in
            try db.execute(sql: """
                CREATE TABLE task_schedule_cleanup_reminders (
                    id TEXT PRIMARY KEY,
                    schedule_id TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    reason TEXT CHECK (reason IS NULL OR reason IN (
                        'deleted', 'onceConsumed', 'staleTrigger'
                    )),
                    status TEXT NOT NULL DEFAULT 'monitoring' CHECK (status IN (
                        'monitoring', 'open', 'dismissed', 'removed'
                    )),
                    setup_source TEXT CHECK (setup_source IS NULL OR setup_source IN (
                        'importFlowOpened', 'handedOffToUser', 'userConfirmed'
                    )),
                    setup_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    last_seen_at TEXT NOT NULL,
                    CHECK (CASE WHEN status = 'monitoring'
                                THEN reason IS NULL
                                ELSE reason IS NOT NULL END)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_cleanup_reminders_open
                ON task_schedule_cleanup_reminders (status, last_seen_at)
                """)
        }
    }
}
