import Foundation
import GRDB
import FloeCore
import FloeModels

/// Shared idempotent SQL used by BOTH the cleanup store's own transactions
/// and the schedule store's writers (delete / one-shot terminal, inside the
/// SAME writer for atomicity).
///
/// One row per schedule (unique `schedule_id`) with three honest event
/// classes:
///   • `recordSetup` — an ACTUAL Shortcut handoff or explicit user
///     confirmation (re)starts silent monitoring. This is the only creation
///     path without direct stale-fire evidence, so a plan that was never
///     configured through Shortcuts gets no row and therefore no reminder
///     on delete. A fresh handoff starts a fresh round even after an
///     earlier resolved marker — the user's dismissal belonged to the
///     previous lifecycle, it does not suppress all future lifecycle.
///   • `retire` — the permanent delete or the TERMINAL retirement of a
///     one-shot. Opens only a row that is already monitoring; an already
///     open row keeps its FIRST reason and only advances `last_seen_at`
///     (dedupe). A resolved row is untouched: dismissing silences the same
///     event permanently, and the user's "removed" mark is not rewritten
///     by another retirement echo of that same event.
///   • `recordStaleTrigger` — the system automation actually fired for a
///     schedule the durable store cannot find. This is direct evidence, so
///     it may create a row even with no recorded setup, and it may REOPEN
///     a row the user marked removed (a fresh fire contradicts that claim).
///     It never reopens a `dismissed` row — the chosen minimal semantics:
///     repeated fires of the SAME stale automation must not re-nag a
///     silenced event, only advance its invisible evidence timestamp.
///
/// None of these writes touch `task_schedules` or
/// `task_schedule_occurrences`: recording can never restart, re-arm or
/// bypass the claim/due/CAS fence.
enum TaskScheduleCleanupReminderSQL {
    static func recordSetup(
        _ db: Database,
        scheduleID: UUID,
        title: String,
        source: TaskScheduleSetupSource,
        at date: Date
    ) throws {
        let encoded = PersistenceCodec.encode(date)
        try db.execute(sql: """
            INSERT INTO task_schedule_cleanup_reminders (
                id, schedule_id, title, reason, status, setup_source, setup_at,
                created_at, updated_at, last_seen_at
            ) VALUES (?, ?, ?, NULL, 'monitoring', ?, ?, ?, ?, ?)
            ON CONFLICT(schedule_id) DO UPDATE SET
                title = excluded.title,
                reason = NULL,
                status = 'monitoring',
                setup_source = excluded.setup_source,
                setup_at = excluded.setup_at,
                updated_at = excluded.updated_at,
                last_seen_at = excluded.last_seen_at
            """, arguments: [
                TaskScheduleCleanupReminder.stableID(scheduleID: scheduleID).uuidString,
                scheduleID.uuidString,
                cleaned(title),
                source.rawValue,
                encoded,
                encoded, encoded, encoded
            ])
    }

    /// Delete / one-shot-terminal event: monitoring opens, open dedupes,
    /// resolved and never-monitored rows are NOT touched.
    static func retire(
        _ db: Database,
        scheduleID: UUID,
        title: String,
        reason: TaskScheduleCleanupReason,
        at date: Date
    ) throws {
        let encoded = PersistenceCodec.encode(date)
        try db.execute(sql: """
            UPDATE task_schedule_cleanup_reminders
            SET status = CASE WHEN status = 'monitoring' THEN 'open' ELSE status END,
                reason = CASE WHEN status = 'monitoring' THEN ? ELSE reason END,
                title = ?,
                updated_at = ?,
                last_seen_at = ?
            WHERE schedule_id = ? AND status IN ('monitoring', 'open')
            """, arguments: [
                reason.rawValue,
                cleaned(title),
                encoded,
                encoded,
                scheduleID.uuidString
            ])
    }

    /// Direct stale-fire evidence: open (or create), dedupe an open row,
    /// keep a dismissed row silenced, reopen a removed row.
    static func recordStaleTrigger(
        _ db: Database,
        scheduleID: UUID,
        title: String,
        at date: Date
    ) throws {
        let encoded = PersistenceCodec.encode(date)
        try db.execute(sql: """
            UPDATE task_schedule_cleanup_reminders
            SET status = CASE WHEN status = 'dismissed' THEN 'dismissed' ELSE 'open' END,
                reason = CASE WHEN status IN ('open', 'dismissed') THEN reason
                              ELSE 'staleTrigger' END,
                title = ?,
                updated_at = ?,
                last_seen_at = ?
            WHERE schedule_id = ?
            """, arguments: [
                cleaned(title),
                encoded,
                encoded,
                scheduleID.uuidString
            ])
        if db.changesCount == 0 {
            try db.execute(sql: """
                INSERT INTO task_schedule_cleanup_reminders (
                    id, schedule_id, title, reason, status, setup_source, setup_at,
                    created_at, updated_at, last_seen_at
                ) VALUES (?, ?, ?, 'staleTrigger', 'open', NULL, NULL, ?, ?, ?)
                ON CONFLICT(schedule_id) DO NOTHING
                """, arguments: [
                    TaskScheduleCleanupReminder.stableID(scheduleID: scheduleID).uuidString,
                    scheduleID.uuidString,
                    cleaned(title),
                    encoded, encoded, encoded
                ])
        }
    }

    /// Crash / write-loss safety net. Every monitoring row whose plan has
    /// SINCE become retired opens here on the next load/foreground pass:
    /// permanently deleted (the captured title survives — no foreign key),
    /// or a one-shot left disabled by its launch with no live occurrence
    /// instance remaining. Reversible pauses (a never-started one-shot or a
    /// disabled recurring plan) and live plans are NEVER opened.
    static func reconcileMonitoring(_ db: Database, at date: Date) throws -> Int {
        let encoded = PersistenceCodec.encode(date)
        try db.execute(sql: """
            UPDATE task_schedule_cleanup_reminders
            SET status = 'open',
                reason = CASE WHEN EXISTS (
                    SELECT 1 FROM task_schedules s
                    WHERE s.id = task_schedule_cleanup_reminders.schedule_id
                      AND s.cadence = 'once' AND s.is_enabled = 0
                      AND s.last_started_at IS NOT NULL
                      AND NOT EXISTS (
                          SELECT 1 FROM task_schedule_occurrences o
                          WHERE o.schedule_id = s.id
                            AND o.state IN ('pending', 'claimed', 'running')
                      )
                ) THEN 'onceConsumed' ELSE 'deleted' END,
                updated_at = ?,
                last_seen_at = ?
            WHERE status = 'monitoring'
              AND (
                NOT EXISTS (
                    SELECT 1 FROM task_schedules s
                    WHERE s.id = task_schedule_cleanup_reminders.schedule_id
                )
                OR EXISTS (
                    SELECT 1 FROM task_schedules s
                    WHERE s.id = task_schedule_cleanup_reminders.schedule_id
                      AND s.cadence = 'once' AND s.is_enabled = 0
                      AND s.last_started_at IS NOT NULL
                      AND NOT EXISTS (
                          SELECT 1 FROM task_schedule_occurrences o
                          WHERE o.schedule_id = s.id
                            AND o.state IN ('pending', 'claimed', 'running')
                      )
                )
              )
            """, arguments: [encoded, encoded])
        return db.changesCount
    }

    private static func cleaned(_ title: String) -> String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }
}

/// Durable read/manage surface for Shortcut-setup monitoring and the
/// retired-schedule cleanup reminders.
///
/// Deliberately read + user-transition + event-recording only: it cannot
/// touch `task_schedules` or `task_schedule_occurrences`, so a lingering
/// record — or the lingering system automation behind it — can never
/// restart a deleted/disabled schedule or skip the due/CAS claim fence.
/// Floe has no API to delete or even detect a system automation, so
/// `markRemoved` records the USER's own confirmation and `dismiss` simply
/// silences the row.
public actor TaskScheduleCleanupReminderStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    /// Every OPEN reminder, most recently seen first — the FULL list. No
    /// hidden preview cap: the ordinary UI shows all of it and every row is
    /// actionable, so nothing is silently truncated. Silent monitoring rows
    /// are NEVER included: they are the private marker that a cleanup may
    /// become meaningful later, not a to-do. A malformed row is skipped
    /// quietly so one bad record can never blank the schedule list.
    public func openReminders() async throws -> [TaskScheduleCleanupReminder] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM task_schedule_cleanup_reminders
                WHERE status = 'open'
                ORDER BY last_seen_at DESC
                """).compactMap(Self.decodeQuietly)
        }
    }

    public func reminder(id: UUID) async throws -> TaskScheduleCleanupReminder? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM task_schedule_cleanup_reminders WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.decode(row)
        }
    }

    /// The single record for one schedule identity, whatever its status
    /// (monitoring rows included — this is the internal read, never a
    /// second visible list).
    public func reminder(scheduleID: UUID) async throws -> TaskScheduleCleanupReminder? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM task_schedule_cleanup_reminders WHERE schedule_id = ?",
                arguments: [scheduleID.uuidString]
            ) else { return nil }
            return try Self.decode(row)
        }
    }

    /// Silence without claiming anything happened in Shortcuts.
    public func dismiss(id: UUID) async throws {
        try await resolve(id: id, to: .dismissed)
    }

    /// The user says they removed the automation themselves. Floe does not
    /// and cannot verify it; the row simply records that human choice.
    public func markRemoved(id: UUID) async throws {
        try await resolve(id: id, to: .removed)
    }

    /// An ACTUAL Shortcut handoff (system import opened, file handed off via
    /// the share sheet) or the user's explicit confirmation started — or is
    /// restarting — monitoring for this schedule. Failed/cancelled imports
    /// are not this event and must never arrive here.
    public func recordSetup(
        scheduleID: UUID, title: String, source: TaskScheduleSetupSource, at date: Date
    ) async throws {
        try await database.writer { db in
            try TaskScheduleCleanupReminderSQL.recordSetup(
                db, scheduleID: scheduleID, title: title, source: source, at: date)
        }
    }

    /// Evidence that an automation still fired for a schedule the store
    /// cannot find (deduplicated into that schedule's single row; creates
    /// the row when no setup was ever recorded; reopens a `removed` row;
    /// leaves a `dismissed` row silenced).
    public func recordStaleTrigger(
        scheduleID: UUID, title: String, at date: Date
    ) async throws {
        try await database.writer { db in
            try TaskScheduleCleanupReminderSQL.recordStaleTrigger(
                db, scheduleID: scheduleID, title: title, at: date)
        }
    }

    /// Load/foreground safety net: opens monitoring rows whose retirement
    /// write was lost to a crash or a failed auxiliary write. Returns the
    /// number of rows opened. Cannot enable, arm or launch anything.
    @discardableResult
    public func reconcileMonitoring() async throws -> Int {
        try await database.writer { db in
            try TaskScheduleCleanupReminderSQL.reconcileMonitoring(db, at: Date())
        }
    }

    // MARK: - Internals

    /// Transitions only ever move an OPEN row; an already-resolved row is
    /// never reopened or rewritten by a second tap. (The ONLY way a resolved
    /// row returns is the durable evidence paths: a new stale trigger on a
    /// `removed` row, or a new actual handoff starting a fresh monitoring
    /// round — never a repeated echo of the same event.)
    private func resolve(id: UUID, to status: TaskScheduleCleanupStatus) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE task_schedule_cleanup_reminders
                SET status = ?, updated_at = ?
                WHERE id = ? AND status = 'open'
                """, arguments: [
                    status.rawValue,
                    PersistenceCodec.encode(Date()),
                    id.uuidString
                ])
        }
    }

    private static func decode(_ row: Row) throws -> TaskScheduleCleanupReminder {
        guard let id = UUID(uuidString: row["id"]),
              let scheduleID = UUID(uuidString: row["schedule_id"]),
              let title: String = row["title"],
              let status = TaskScheduleCleanupStatus(rawValue: row["status"]) else {
            throw FloeError.storageCorrupted("Invalid schedule cleanup reminder row")
        }
        // A status other than 'monitoring' must carry a valid reason; a
        // monitoring row must not. Anything else is corruption.
        let reasonRaw: String? = row["reason"]
        let reason: TaskScheduleCleanupReason?
        if status == .monitoring {
            guard reasonRaw == nil else {
                throw FloeError.storageCorrupted("Monitoring cleanup row carries a reason")
            }
            reason = nil
        } else {
            guard let raw = reasonRaw,
                  let parsed = TaskScheduleCleanupReason(rawValue: raw) else {
                throw FloeError.storageCorrupted("Missing or invalid cleanup reminder reason")
            }
            reason = parsed
        }
        let sourceRaw: String? = row["setup_source"]
        let setupSource = sourceRaw.flatMap(TaskScheduleSetupSource.init(rawValue:))
        let setupRaw: String? = row["setup_at"]
        guard let createdAt = try? PersistenceCodec.decodeDate(row["created_at"]),
              let updatedAt = try? PersistenceCodec.decodeDate(row["updated_at"]),
              let lastSeenAt = try? PersistenceCodec.decodeDate(row["last_seen_at"]) else {
            throw FloeError.storageCorrupted("Invalid schedule cleanup reminder dates")
        }
        return TaskScheduleCleanupReminder(
            id: id, scheduleID: scheduleID, title: title,
            reason: reason, status: status,
            setupSource: setupSource,
            setupAt: setupRaw.flatMap { try? PersistenceCodec.decodeDate($0) },
            createdAt: createdAt, updatedAt: updatedAt, lastSeenAt: lastSeenAt)
    }

    private static func decodeQuietly(_ row: Row) -> TaskScheduleCleanupReminder? {
        try? decode(row)
    }
}
