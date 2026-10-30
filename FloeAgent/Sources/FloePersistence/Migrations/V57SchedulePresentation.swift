import GRDB

/// Schema v57 — truthful schedule presentation.
///
/// Two additive changes only; no table rebuild, backfill or deletion:
///
///  * `task_schedules.origin_conversation_id` records the ordinary chat a plan
///    was created from, captured from the submitting run's trusted context.
///    It is a plain TEXT reference with NO foreign key and NO cascade:
///    deleting the origin conversation must never delete, disable or rewrite
///    the plan, its history or its occurrences. Every pre-v57 row (and every
///    Home-created plan) stays NULL, which decodes as "unbound"; no origin is
///    ever guessed from a title, a prompt or a later run. A conversation that
///    was itself created by a planned occurrence is resolved through
///    `task_schedule_occurrences.conversation_id` instead.
///  * an index on `(conversation_id, scheduled_for)` makes that actual-ledger
///    resolution and per-conversation history reads bounded instead of
///    scanning the occurrence table.
///
/// `user_version` advances to 57; DatabaseManager registration is intentionally
/// owned by the integrating App/lane (this file only defines the migration).
public enum V57SchedulePresentation {
    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v57_schedule_presentation") { db in
            try db.execute(sql: """
                ALTER TABLE task_schedules
                ADD COLUMN origin_conversation_id TEXT
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_schedule_occurrences_conversation
                ON task_schedule_occurrences(conversation_id, scheduled_for)
                """)
            try db.execute(sql: "PRAGMA user_version = 57")
        }
    }
}
