import GRDB

/// Schema v48 — durable, task-owned system AlarmKit alarm/timer ledger.
///
/// `system_alarms` is the app-private durability boundary for the S5 C3
/// `apple.alarm.*` tools. Each row records one intended native mutation with
/// the exact stable app-owned alarm id, the runtime-trusted owner provenance
/// (conversation task id, else the run id), the trusted per-call operation
/// identity (provider tool-call id + idempotency key), a canonical request
/// payload digest (never the raw title), the user-intended timezone and the
/// derived native schedule, and the reconciled native outcome. The CHECK
/// pairs keep a row's schedule columns consistent with its `kind`; the unique
/// `(operation_id, idempotency_key)` index is the idempotency boundary that
/// makes a crash-and-retry of the same approved call converge instead of
/// duplicating. State transitions are compare-and-set, mirroring the
/// exactly-once shape of `task_schedule_occurrences`.
///
/// PRIMARY REGISTRATION (DatabaseManager.swift, owned by the integrator):
///   1. Bump `currentSchemaVersion` from 47 to 48.
///   2. Add `V48SystemAlarms.register(into: &migrator)` immediately after
///      `V47ShortcutInbox.register(into: &migrator)`.
enum V48SystemAlarms {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v48_system_alarms") { db in
            try SystemAlarmSchema.apply(db)
            try db.execute(sql: "PRAGMA user_version = 48")
        }
    }
}
