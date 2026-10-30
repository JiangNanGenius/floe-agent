import Foundation
import GRDB
import FloeCore
import FloeModels

/// Durable scheduled-task and execution-instance access.
///
/// The protocol keeps the historical schedule CRUD (used by Shortcuts, the
/// Apple automation tools and the Home sheet) and adds the occurrence ledger
/// that makes execution exactly-once: an executor atomically CLAIMS an
/// occurrence before launching the task, so a foreground/BG/notification race
/// can never start the same logical instance twice.
public protocol TaskScheduleStore: Sendable {
    func schedules() async throws -> [TaskScheduleRecord]
    func due(at date: Date) async throws -> [TaskScheduleRecord]
    func save(_ schedule: TaskScheduleRecord) async throws
    func markStarted(id: UUID, at date: Date) async throws
    func delete(id: UUID) async throws

    // MARK: Extended schedule management

    func schedule(id: UUID) async throws -> TaskScheduleRecord?
    func setEnabled(id: UUID, enabled: Bool, at date: Date) async throws
    /// Creates (or returns) a pending one-off occurrence for an explicit
    /// user/agent "run now" action. Every explicit invocation gets its own
    /// logical instance (never coalesced with the calendar cadence).
    func runNow(id: UUID, at date: Date) async throws -> TaskScheduleOccurrence?
    /// Records the launch of an occurrence WITHOUT touching the planned
    /// calendar time. Used only for explicit Run-now instances, which are an
    /// extra execution: they must not advance, consume or re-arm
    /// `nextExpectedAt`, and a manual run of a one-shot must not retire the
    /// plan. `markStarted` remains the calendar-launch transition.
    func markManualStarted(id: UUID, at date: Date) async throws
    /// Skips exactly the next automatic occurrence of an enabled plan:
    /// records the stable occurrence as `skipped`, launches no task and
    /// advances the plan to the fire time after it. A one-shot retires
    /// (disabled) with its record and history retained. Returns nil when the
    /// plan does not exist; throws for a paused plan or an event-driven
    /// cadence that has no clock occurrence to skip. A claimed/running
    /// instance is never skipped.
    func skipNext(id: UUID, at date: Date) async throws -> TaskScheduleSkipResult?
    /// How many AUTOMATIC occurrences (calendar + upstream-armed) have
    /// actually started for this plan. Explicit Run-now rows are excluded, so
    /// the displayed automatic ordinal is truthful regardless of how much
    /// history the UI previews.
    func startedAutomaticOccurrenceCount(scheduleID: UUID) async throws -> Int
    /// Plans linked to a conversation by their TRUSTED origin binding or by an
    /// actual occurrence that owns this conversation. Never inferred from a
    /// title. Used by the in-thread schedule pill; no deletion cascade exists
    /// in either direction.
    func schedulesLinked(to conversationID: UUID) async throws -> [TaskScheduleRecord]

    // MARK: Occurrence ledger

    /// Idempotently records a logical occurrence. Returns true when the row
    /// was newly created; false when this exact logical instance already
    /// exists (any state) and must not be re-inserted.
    @discardableResult
    func enqueueOccurrence(_ occurrence: TaskScheduleOccurrence) async throws -> Bool
    /// pending → claimed, atomically. Exactly one caller wins.
    @discardableResult
    func claimOccurrence(id: UUID, at date: Date) async throws -> Bool
    /// claimed → running, bound to the launched run. False when another
    /// executor already moved past `claimed` (the launch must be abandoned).
    @discardableResult
    func markOccurrenceRunning(
        id: UUID, runID: UUID, conversationID: UUID, at date: Date
    ) async throws -> Bool
    func finishOccurrence(
        id: UUID,
        state: TaskScheduleOccurrenceState,
        summary: String?,
        errorText: String?,
        at date: Date
    ) async throws
    func occurrence(id: UUID) async throws -> TaskScheduleOccurrence?
    func occurrence(runID: UUID) async throws -> TaskScheduleOccurrence?
    func occurrences(scheduleID: UUID, limit: Int) async throws -> [TaskScheduleOccurrence]
    func recentOccurrences(limit: Int) async throws -> [TaskScheduleOccurrence]
    func pendingOccurrences(limit: Int) async throws -> [TaskScheduleOccurrence]
    /// Marks occurrences left `claimed`/`running` by a dead process as
    /// interrupted (their real outcome is unknown) and re-arms one-shot
    /// schedules that never actually launched. Returns the reconciled count.
    @discardableResult
    func reconcileInterruptedOccurrences(at date: Date) async throws -> Int
    /// Finishes the occurrence owned by `runID` when it is still `running`
    /// and, only for a SUCCESSFUL run, enqueues the `.afterSuccess` schedules
    /// bound to this schedule (one logical occurrence per upstream run).
    /// Returns the newly enqueued occurrence ids.
    @discardableResult
    func recordRunCompletion(
        runID: UUID, succeeded: Bool, cancelled: Bool, summary: String?, at date: Date
    ) async throws -> [UUID]
}

public actor SQLiteTaskScheduleStore: TaskScheduleStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    // MARK: - Schedules

    public func schedules() async throws -> [TaskScheduleRecord] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM task_schedules
                ORDER BY is_enabled DESC, next_expected_at, scheduled_at
                """).map(Self.decode)
        }
    }

    public func due(at date: Date) async throws -> [TaskScheduleRecord] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM task_schedules
                WHERE is_enabled = 1 AND next_expected_at <= ?
                ORDER BY next_expected_at, created_at
                """, arguments: [PersistenceCodec.encode(date)]).map(Self.decode)
        }
    }

    public func schedule(id: UUID) async throws -> TaskScheduleRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM task_schedules WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.decode(row)
        }
    }

    public func save(_ schedule: TaskScheduleRecord) async throws {
        try await database.writer { db in
            // An edit upsert that puts a paused/retired plan back into live
            // state is a RE-ARM exactly like `setEnabled(enabled: true)`:
            // on the disabled→enabled transition its existing monitoring/
            // open cleanup evidence returns to silent monitoring at a fresh
            // epoch (best-effort, UPDATE-only — this never creates a row,
            // so a never-setup plan stays silent forever). Creating a plan
            // or editing an already-live one changes no evidence here.
            if schedule.isEnabled {
                let previousRow = try Row.fetchOne(
                    db, sql: "SELECT is_enabled FROM task_schedules WHERE id = ?",
                    arguments: [schedule.id.uuidString]
                )
                let previousEnabled: Bool? = previousRow.flatMap { row in
                    row["is_enabled"] as Bool?
                }
                if previousEnabled == false {
                    do {
                        try TaskScheduleCleanupReminderSQL.rearm(
                            db, scheduleID: schedule.id, title: schedule.title,
                            at: schedule.updatedAt)
                    } catch {
                        // Deliberately swallowed: auxiliary evidence only.
                    }
                }
            }
            try db.execute(sql: """
                INSERT INTO task_schedules (
                    id, title, prompt, workspace_id, cadence, scheduled_at,
                    weekday, is_enabled, last_started_at, next_expected_at,
                    policy_json, created_at, updated_at,
                    interval_seconds, anchor_timezone, upstream_run_id,
                    model_id, environment_id, permission_json,
                    origin_conversation_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title, prompt = excluded.prompt,
                    workspace_id = excluded.workspace_id, cadence = excluded.cadence,
                    scheduled_at = excluded.scheduled_at, weekday = excluded.weekday,
                    is_enabled = excluded.is_enabled,
                    next_expected_at = excluded.next_expected_at,
                    policy_json = excluded.policy_json, updated_at = excluded.updated_at,
                    interval_seconds = excluded.interval_seconds,
                    anchor_timezone = excluded.anchor_timezone,
                    upstream_run_id = excluded.upstream_run_id,
                    model_id = excluded.model_id,
                    environment_id = excluded.environment_id,
                    permission_json = excluded.permission_json,
                    origin_conversation_id = excluded.origin_conversation_id
                """, arguments: [
                    schedule.id.uuidString, schedule.title, schedule.prompt,
                    schedule.workspaceID?.uuidString, schedule.cadence.rawValue,
                    PersistenceCodec.encode(schedule.scheduledAt), schedule.weekday,
                    schedule.isEnabled, schedule.lastStartedAt.map(PersistenceCodec.encode),
                    schedule.nextExpectedAt.map(PersistenceCodec.encode), schedule.policyJSON,
                    PersistenceCodec.encode(schedule.createdAt),
                    PersistenceCodec.encode(schedule.updatedAt),
                    schedule.intervalSeconds, schedule.anchorTimezone,
                    schedule.upstreamRunID?.uuidString,
                    schedule.modelID?.uuidString, schedule.environmentID,
                    schedule.permissionJSON,
                    schedule.originConversationID?.uuidString
                ])
        }
    }

    public func setEnabled(id: UUID, enabled: Bool, at date: Date) async throws {
        try await database.writer { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM task_schedules WHERE id = ?",
                arguments: [id.uuidString]
            ) else { throw FloeError.notFound("task schedule \(id.uuidString)") }
            var record = try Self.decode(row)
            record.isEnabled = enabled
            record.updatedAt = date
            if enabled {
                // Re-arm from the next real fire time at or after now.
                record.nextExpectedAt = Self.nextExpected(after: date, record: record)
                    ?? record.scheduledAt
            } else {
                record.nextExpectedAt = nil
            }
            try Self.writeRecord(db, record)
            if enabled {
                // Re-arm starts a FRESH live lifecycle: best-effort, the
                // plan's existing monitoring/open cleanup evidence returns
                // to silent monitoring with `setup_at` advanced to this
                // instant, so the PREVIOUS run's historical launch can never
                // be read as this round's retirement (a reversible pause
                // after re-enable must not remind). UPDATE-only: a plan with
                // no actual Shortcut handoff gains no row, and a resolved
                // row keeps the user's mark. Inside the SAME writer for
                // atomicity; a reminder failure never blocks the real
                // enable (same auxiliary policy as `delete`).
                do {
                    try TaskScheduleCleanupReminderSQL.rearm(
                        db, scheduleID: id, title: record.title, at: date)
                } catch {
                    // Deliberately swallowed: auxiliary evidence only.
                }
            } else {
                // A disabled schedule's future occurrences are void; pending
                // instances are cancelled so a re-enable cannot launch stale
                // intent. History rows stay.
                try db.execute(sql: """
                    UPDATE task_schedule_occurrences
                    SET state = 'cancelled', finished_at = ?, updated_at = ?,
                        error_text = 'Schedule was disabled before this occurrence ran'
                    WHERE schedule_id = ? AND state IN ('pending', 'claimed')
                    """, arguments: [
                        PersistenceCodec.encode(date),
                        PersistenceCodec.encode(date),
                        id.uuidString
                    ])
            }
        }
    }

    public func runNow(id: UUID, at date: Date) async throws -> TaskScheduleOccurrence? {
        guard try await schedule(id: id) != nil else { return nil }
        let key = "manual:\(UUID().uuidString)"
        let pending = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: id, dedupeKey: key),
            scheduleID: id,
            scheduledFor: date,
            dedupeKey: key
        )
        _ = try await enqueueOccurrence(pending)
        return try await occurrence(id: pending.id)
    }

    public func markManualStarted(id: UUID, at date: Date) async throws {
        // An explicit Run-now instance is an EXTRA execution. Record the real
        // start for truthful history, but never move the calendar: the planned
        // next time, one-shot enablement and the cadence anchor stay as they
        // were. This is deliberately a different transition from
        // `markStarted` (which advances a calendar launch).
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE task_schedules
                SET last_started_at = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [
                    PersistenceCodec.encode(date),
                    PersistenceCodec.encode(date),
                    id.uuidString
                ])
        }
    }

    public func skipNext(id: UUID, at date: Date) async throws -> TaskScheduleSkipResult? {
        try await database.writer { db in
            guard let scheduleRow = try Row.fetchOne(
                db, sql: "SELECT * FROM task_schedules WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            var record = try Self.decode(scheduleRow)
            guard record.isEnabled else {
                throw FloeError.validationFailed(
                    "This scheduled task is paused; there is no next run to skip.")
            }
            guard record.cadence != .afterSuccess else {
                throw FloeError.validationFailed(
                    "This plan runs after an upstream success and has no clock occurrence to skip.")
            }

            // The first candidate is the instance a pass would address now
            // (the coalesced most-recent due fire), then each following fire
            // date. Already started/settled or previously skipped instances
            // are stepped over, so repeated Skip next keeps advancing instead
            // of getting stuck on the same skipped row.
            var candidateFire: Date?
            if record.cadence == .once {
                candidateFire = record.scheduledAt
            } else if let lastDue = TaskSchedulePlanner.dueFireTimes(
                record: record, now: date
            ).last {
                candidateFire = lastDue
            } else {
                candidateFire = TaskSchedulePlanner.nextFireTime(after: date, record: record)
            }

            var attempts = 0
            while let fireTime = candidateFire, attempts < 16 {
                attempts += 1
                let key = TaskSchedulePlanner.dedupeKey(for: fireTime, record: record)
                let occurrenceID = TaskScheduleOccurrence.stableID(
                    scheduleID: record.id, dedupeKey: key)
                let existingRow = try Row.fetchOne(
                    db, sql: "SELECT state FROM task_schedule_occurrences WHERE id = ?",
                    arguments: [occurrenceID.uuidString])
                let existingState: TaskScheduleOccurrenceState? = existingRow
                    .flatMap { row in
                        (row["state"] as String?)
                            .flatMap(TaskScheduleOccurrenceState.init(rawValue:))
                    }
                if let existingState, existingState != .pending {
                    // Claimed/running or settled history: never overwrite the
                    // real outcome. Move on to the later fire time.
                    candidateFire = TaskSchedulePlanner.nextFireTime(
                        after: max(fireTime, date), record: record)
                    continue
                }
                // Materialize the logical instance at its stable identity so
                // the SAME row is what history shows; the insert is idempotent
                // with the background pass's materialization.
                try db.execute(sql: """
                    INSERT INTO task_schedule_occurrences (
                        id, schedule_id, scheduled_for, state, dedupe_key,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, 'pending', ?, ?, ?)
                    ON CONFLICT(schedule_id, dedupe_key) DO NOTHING
                    """, arguments: [
                        occurrenceID.uuidString,
                        record.id.uuidString,
                        PersistenceCodec.encode(fireTime),
                        key,
                        PersistenceCodec.encode(date),
                        PersistenceCodec.encode(date)
                    ])
                try db.execute(sql: """
                    UPDATE task_schedule_occurrences
                    SET state = 'skipped', summary = ?, finished_at = ?, updated_at = ?
                    WHERE id = ? AND state = 'pending'
                    """, arguments: [
                        "Skipped by the user; this occurrence did not run.",
                        PersistenceCodec.encode(date),
                        PersistenceCodec.encode(date),
                        occurrenceID.uuidString
                    ])
                guard db.changesCount > 0 else {
                    candidateFire = TaskSchedulePlanner.nextFireTime(
                        after: max(fireTime, date), record: record)
                    continue
                }
                // Advance the plan to the fire time AFTER the skipped one.
                // A repeating plan stays enabled; a one-shot has no later
                // occurrence and retires while its record/history remain.
                let nextExpected: Date?
                if record.cadence == .once {
                    record.isEnabled = false
                    nextExpected = nil
                } else {
                    nextExpected = TaskSchedulePlanner.nextFireTime(
                        after: max(fireTime, date), record: record)
                }
                record.nextExpectedAt = nextExpected
                record.updatedAt = date
                try Self.writeRecord(db, record)
                return TaskScheduleSkipResult(
                    scheduleID: record.id,
                    skippedOccurrenceID: occurrenceID,
                    skippedFor: fireTime,
                    nextExpectedAt: nextExpected,
                    planDisabled: !record.isEnabled
                )
            }
            throw FloeError.validationFailed(
                "There is no future occurrence available to skip.")
        }
    }

    public func startedAutomaticOccurrenceCount(scheduleID: UUID) async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM task_schedule_occurrences
                WHERE schedule_id = ? AND started_at IS NOT NULL
                  AND dedupe_key NOT LIKE 'manual:%'
                """, arguments: [scheduleID.uuidString]) ?? 0
        }
    }

    public func schedulesLinked(to conversationID: UUID) async throws -> [TaskScheduleRecord] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT s.* FROM task_schedules s
                WHERE s.origin_conversation_id = ?
                   OR EXISTS (
                       SELECT 1 FROM task_schedule_occurrences o
                       WHERE o.schedule_id = s.id AND o.conversation_id = ?
                   )
                ORDER BY s.is_enabled DESC, s.next_expected_at, s.scheduled_at
                """, arguments: [
                    conversationID.uuidString,
                    conversationID.uuidString
                ]).map(Self.decode)
        }
    }

    // MARK: - Occurrences

    @discardableResult
    public func enqueueOccurrence(_ occurrence: TaskScheduleOccurrence) async throws -> Bool {
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO task_schedule_occurrences (
                    id, schedule_id, scheduled_for, state, dedupe_key,
                    run_id, conversation_id, claimed_at, started_at, finished_at,
                    summary, error_text, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(schedule_id, dedupe_key) DO NOTHING
                """, arguments: [
                    occurrence.id.uuidString,
                    occurrence.scheduleID.uuidString,
                    PersistenceCodec.encode(occurrence.scheduledFor),
                    occurrence.state.rawValue,
                    occurrence.dedupeKey,
                    occurrence.runID?.uuidString,
                    occurrence.conversationID?.uuidString,
                    occurrence.claimedAt.map(PersistenceCodec.encode),
                    occurrence.startedAt.map(PersistenceCodec.encode),
                    occurrence.finishedAt.map(PersistenceCodec.encode),
                    occurrence.summary,
                    occurrence.errorText,
                    PersistenceCodec.encode(occurrence.createdAt),
                    PersistenceCodec.encode(occurrence.updatedAt)
                ])
            return db.changesCount > 0
        }
    }

    @discardableResult
    public func claimOccurrence(id: UUID, at date: Date) async throws -> Bool {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE task_schedule_occurrences
                SET state = 'claimed', claimed_at = ?, updated_at = ?
                WHERE id = ? AND state = 'pending'
                """, arguments: [
                    PersistenceCodec.encode(date),
                    PersistenceCodec.encode(date),
                    id.uuidString
                ])
            return db.changesCount > 0
        }
    }

    @discardableResult
    public func markOccurrenceRunning(
        id: UUID,
        runID: UUID,
        conversationID: UUID,
        at date: Date
    ) async throws -> Bool {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE task_schedule_occurrences
                SET state = 'running', run_id = ?, conversation_id = ?,
                    started_at = ?, updated_at = ?
                WHERE id = ? AND state = 'claimed'
                """, arguments: [
                    runID.uuidString,
                    conversationID.uuidString,
                    PersistenceCodec.encode(date),
                    PersistenceCodec.encode(date),
                    id.uuidString
                ])
            return db.changesCount > 0
        }
    }

    public func finishOccurrence(
        id: UUID,
        state: TaskScheduleOccurrenceState,
        summary: String?,
        errorText: String?,
        at date: Date
    ) async throws {
        guard state.isTerminal else {
            throw FloeError.validationFailed("Occurrences finish in a terminal state")
        }
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE task_schedule_occurrences
                SET state = ?, summary = COALESCE(?, summary),
                    error_text = COALESCE(?, error_text),
                    finished_at = ?, updated_at = ?
                WHERE id = ? AND state IN ('claimed', 'running')
                """, arguments: [
                    state.rawValue,
                    summary.map { String($0.prefix(4_096)) },
                    errorText.map { String($0.prefix(4_096)) },
                    PersistenceCodec.encode(date),
                    PersistenceCodec.encode(date),
                    id.uuidString
                ])
            if db.changesCount > 0,
               let row = try Row.fetchOne(
                   db, sql: "SELECT schedule_id FROM task_schedule_occurrences WHERE id = ?",
                   arguments: [id.uuidString]
               ), let raw: String = row["schedule_id"],
               let owner = UUID(uuidString: raw) {
                // Terminal for THIS occurrence. Only a one-shot's own
                // terminal launch retires anything (and only monitored
                // plans open); recurring completions record nothing.
                Self.recordOnceRetirementIfNeeded(db, scheduleID: owner, at: date)
            }
        }
    }

    public func occurrence(id: UUID) async throws -> TaskScheduleOccurrence? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM task_schedule_occurrences WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.decodeOccurrence(row)
        }
    }

    public func occurrence(runID: UUID) async throws -> TaskScheduleOccurrence? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM task_schedule_occurrences WHERE run_id = ? ORDER BY started_at DESC LIMIT 1",
                arguments: [runID.uuidString]
            ) else { return nil }
            return try Self.decodeOccurrence(row)
        }
    }

    public func occurrences(scheduleID: UUID, limit: Int) async throws -> [TaskScheduleOccurrence] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM task_schedule_occurrences
                WHERE schedule_id = ?
                ORDER BY scheduled_for DESC, created_at DESC
                LIMIT ?
                """, arguments: [scheduleID.uuidString, max(1, min(limit, 200))])
                .map(Self.decodeOccurrence)
        }
    }

    public func recentOccurrences(limit: Int) async throws -> [TaskScheduleOccurrence] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM task_schedule_occurrences
                ORDER BY COALESCE(started_at, scheduled_for) DESC, updated_at DESC
                LIMIT ?
                """, arguments: [max(1, min(limit, 200))]).map(Self.decodeOccurrence)
        }
    }

    public func pendingOccurrences(limit: Int) async throws -> [TaskScheduleOccurrence] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM task_schedule_occurrences
                WHERE state = 'pending'
                ORDER BY scheduled_for, created_at
                LIMIT ?
                """, arguments: [max(1, min(limit, 200))]).map(Self.decodeOccurrence)
        }
    }

    @discardableResult
    public func reconcileInterruptedOccurrences(at date: Date) async throws -> Int {
        try await database.writer { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT o.id AS occurrence_id, o.schedule_id AS schedule_id,
                       o.scheduled_for AS scheduled_for, s.cadence AS cadence
                FROM task_schedule_occurrences o
                JOIN task_schedules s ON s.id = o.schedule_id
                WHERE o.state IN ('claimed', 'running')
                """)
            guard !rows.isEmpty else { return 0 }
            for row in rows {
                let occurrenceID: String = row["occurrence_id"]
                let cadence = (row["cadence"] as String?).flatMap(TaskScheduleCadence.init(rawValue:))
                try db.execute(sql: """
                    UPDATE task_schedule_occurrences
                    SET state = 'interrupted', finished_at = ?, updated_at = ?,
                        error_text = COALESCE(error_text, 'The process exited before this scheduled task launched or finished; its outcome is unknown.')
                    WHERE id = ? AND state IN ('claimed', 'running')
                    """, arguments: [
                        PersistenceCodec.encode(date),
                        PersistenceCodec.encode(date),
                        occurrenceID
                    ])
                // A one-shot that never actually launched is re-armed rather
                // than silently consumed.
                if cadence == .once, let scheduleID: String = row["schedule_id"],
                   let scheduledForRaw: String = row["scheduled_for"],
                   let scheduledFor = try? PersistenceCodec.decodeDate(scheduledForRaw) {
                    try db.execute(sql: """
                        UPDATE task_schedules
                        SET is_enabled = 1, next_expected_at = ?, updated_at = ?
                        WHERE id = ? AND is_enabled = 1
                        """, arguments: [
                            PersistenceCodec.encode(scheduledFor),
                            PersistenceCodec.encode(date),
                            scheduleID
                        ])
                }
            }
            return rows.count
        }
    }

    @discardableResult
    public func recordRunCompletion(
        runID: UUID,
        succeeded: Bool,
        cancelled: Bool,
        summary: String?,
        at date: Date
    ) async throws -> [UUID] {
        try await database.writer { db in
            // The after-success trigger is bound to the CONCRETE upstream run
            // selected when the dependent schedule was created, so it works
            // for any successful run (scheduled or not) and can never fire
            // for a future round of a conversation or a child completion.
            var enqueued: [UUID] = []
            if succeeded {
                // The cadence filter is required: a schedule edited away from
                // after-success keeps its historical upstream_run_id column
                // (until the edit clears it), and a stale binding must never
                // fire a daily/interval schedule from an unrelated run.
                let dependents = try Row.fetchAll(db, sql: """
                    SELECT id FROM task_schedules
                    WHERE upstream_run_id = ? AND is_enabled = 1 AND cadence = 'afterSuccess'
                    """, arguments: [runID.uuidString])
                for row in dependents {
                    guard let scheduleID = UUID(uuidString: row["id"]) else { continue }
                    let key = "upstream:\(runID.uuidString)"
                    let id = TaskScheduleOccurrence.stableID(scheduleID: scheduleID, dedupeKey: key)
                    try db.execute(sql: """
                        INSERT INTO task_schedule_occurrences (
                            id, schedule_id, scheduled_for, state, dedupe_key,
                            created_at, updated_at
                        ) VALUES (?, ?, ?, 'pending', ?, ?, ?)
                        ON CONFLICT(schedule_id, dedupe_key) DO NOTHING
                        """, arguments: [
                            id.uuidString,
                            scheduleID.uuidString,
                            PersistenceCodec.encode(date),
                            key,
                            PersistenceCodec.encode(date),
                            PersistenceCodec.encode(date)
                        ])
                    if db.changesCount > 0 { enqueued.append(id) }
                }
            }
            // Settle the occurrence this run owns, if any (a scheduled run).
            guard let occurrenceRow = try Row.fetchOne(
                db, sql: "SELECT * FROM task_schedule_occurrences WHERE run_id = ? ORDER BY started_at DESC LIMIT 1",
                arguments: [runID.uuidString]
            ) else { return enqueued }
            let occurrence = try Self.decodeOccurrence(occurrenceRow)
            guard occurrence.state == .running || occurrence.state == .claimed else { return enqueued }
            let terminal: TaskScheduleOccurrenceState = succeeded
                ? .completed
                : (cancelled ? .cancelled : .failed)
            try db.execute(sql: """
                UPDATE task_schedule_occurrences
                SET state = ?, summary = COALESCE(?, summary),
                    error_text = COALESCE(?, error_text),
                    finished_at = ?, updated_at = ?
                WHERE id = ? AND state IN ('claimed', 'running')
                """, arguments: [
                    terminal.rawValue,
                    summary.map { String($0.prefix(4_096)) },
                    succeeded
                        ? nil
                        : (summary.map { String($0.prefix(4_096)) }
                            ?? (cancelled
                                ? "Scheduled task was cancelled"
                                : "Scheduled task ended without success")),
                    PersistenceCodec.encode(date),
                    PersistenceCodec.encode(date),
                    occurrence.id.uuidString
                ])
            if db.changesCount > 0 {
                // The run's terminal settle for a ONE-SHOT's bound
                // occurrence is the honest retirement moment (never
                // `markStarted`, never a recurring completion).
                Self.recordOnceRetirementIfNeeded(
                    db, scheduleID: occurrence.scheduleID, at: date)
            }
            return enqueued
        }
    }

    // MARK: - Legacy scheduling update

    public func markStarted(id: UUID, at date: Date) async throws {
        try await database.writer { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM task_schedules WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return }
            var record = try Self.decode(row)
            record.lastStartedAt = date
            switch record.cadence {
            case .once:
                record.isEnabled = false
                record.nextExpectedAt = nil
            case .afterSuccess:
                // Armed only by an upstream success; no clock schedule.
                record.nextExpectedAt = nil
            case .daily, .weekly, .interval:
                if (record.cadence == .daily || record.cadence == .weekly),
                   record.anchorTimezone == nil {
                    // Legacy row without a stored calendar anchor: keep the
                    // historical "advance from the actual start" semantics so
                    // existing schedules behave exactly as before; new
                    // schedules always carry an anchor and use the planner.
                    let step = record.cadence == .weekly ? 7 : 1
                    record.nextExpectedAt = Calendar.current.date(byAdding: .day, value: step, to: date)
                } else {
                    record.nextExpectedAt = TaskSchedulePlanner.nextFireTime(after: date, record: record)
                }
            }
            record.updatedAt = date
            try Self.writeRecord(db, record)
        }
    }

    public func delete(id: UUID) async throws {
        try await database.writer { db in
            // Permanent retirement evidence — but ONLY for plans whose
            // actual Shortcut handoff/confirmation is being monitored.
            // The UPDATE touches no row unless one already exists in
            // 'monitoring'/'open', so a plan the user never configured
            // through Shortcuts produces no reminder at all. Inside the
            // same transaction yet BEST-EFFORT: a reminder failure can
            // never block a real delete (core state always commits; the
            // load/foreground reconciliation is the crash safety net).
            if let row = try Row.fetchOne(
                db, sql: "SELECT title FROM task_schedules WHERE id = ?",
                arguments: [id.uuidString]
            ), let title: String = row["title"] {
                do {
                    try TaskScheduleCleanupReminderSQL.retire(
                        db, scheduleID: id, title: title,
                        reason: .deleted, at: Date())
                } catch {
                    // Deliberately swallowed: auxiliary evidence only.
                }
            }
            try db.execute(sql: "DELETE FROM task_schedules WHERE id = ?", arguments: [id.uuidString])
            // Occurrence history is retained deliberately: deleting a schedule
            // must not erase evidence of what already ran.
        }
    }

    // MARK: - Internals

    /// One-shot retirement is proven only when the bound occurrence has
    /// ACTUALLY TERMINATED: the launched plan stays disabled with its
    /// launch recorded, no live instance remains, AND that launch belongs
    /// to the CURRENT monitoring lifecycle — its `last_started_at` falls
    /// at or after the row's latest setup/re-arm epoch (`setup_at`), so a
    /// historical run can never consume a fresh handoff or a paused
    /// re-enable before the new round ever starts. `markStarted` alone
    /// is too early — the task may still be running. A recurring
    /// occurrence completing retires nothing, a never-started one-shot
    /// (reversible pause) retires nothing, and reversible pauses of any
    /// plan retires nothing. Best-effort inside the caller's transaction:
    /// a reminder failure can never roll back or delay occurrence
    /// bookkeeping.
    private static func recordOnceRetirementIfNeeded(
        _ db: Database, scheduleID: UUID, at date: Date
    ) {
        do {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT s.title FROM task_schedules s
                WHERE s.id = ? AND s.cadence = 'once' AND s.is_enabled = 0
                  AND s.last_started_at IS NOT NULL
                  AND EXISTS (
                      SELECT 1 FROM task_schedule_cleanup_reminders r
                      WHERE r.schedule_id = s.id
                        AND r.status IN ('monitoring', 'open')
                        AND s.last_started_at >= r.setup_at
                  )
                  AND NOT EXISTS (
                      SELECT 1 FROM task_schedule_occurrences o
                      WHERE o.schedule_id = s.id
                        AND o.state IN ('pending', 'claimed', 'running')
                  )
                """, arguments: [scheduleID.uuidString]),
                  let title: String = row["title"] else { return }
            try TaskScheduleCleanupReminderSQL.retire(
                db, scheduleID: scheduleID, title: title,
                reason: .onceConsumed, at: date)
        } catch {
            // Deliberately swallowed: auxiliary evidence only.
        }
    }

    private static func nextExpected(after date: Date, record: TaskScheduleRecord) -> Date? {
        switch record.cadence {
        case .once:
            return record.scheduledAt > date ? record.scheduledAt : nil
        case .afterSuccess:
            return nil
        case .daily, .weekly, .interval:
            return TaskSchedulePlanner.nextFireTime(after: date, record: record)
        }
    }

    private static func writeRecord(_ db: Database, _ record: TaskScheduleRecord) throws {
        try db.execute(sql: """
            UPDATE task_schedules
            SET title = ?, prompt = ?, workspace_id = ?, cadence = ?,
                scheduled_at = ?, weekday = ?, is_enabled = ?,
                last_started_at = ?, next_expected_at = ?, policy_json = ?,
                updated_at = ?, interval_seconds = ?, anchor_timezone = ?,
                upstream_run_id = ?, model_id = ?, environment_id = ?,
                permission_json = ?, origin_conversation_id = ?
            WHERE id = ?
            """, arguments: [
                record.title, record.prompt, record.workspaceID?.uuidString,
                record.cadence.rawValue, PersistenceCodec.encode(record.scheduledAt),
                record.weekday, record.isEnabled,
                record.lastStartedAt.map(PersistenceCodec.encode),
                record.nextExpectedAt.map(PersistenceCodec.encode),
                record.policyJSON, PersistenceCodec.encode(record.updatedAt),
                record.intervalSeconds, record.anchorTimezone,
                record.upstreamRunID?.uuidString, record.modelID?.uuidString,
                record.environmentID, record.permissionJSON,
                record.originConversationID?.uuidString,
                record.id.uuidString
            ])
    }

    private static func decode(_ row: Row) throws -> TaskScheduleRecord {
        guard let id = UUID(uuidString: row["id"]),
              let cadence = TaskScheduleCadence(rawValue: row["cadence"]),
              let scheduledAt = try? PersistenceCodec.decodeDate(row["scheduled_at"]),
              let createdAt = try? PersistenceCodec.decodeDate(row["created_at"]),
              let updatedAt = try? PersistenceCodec.decodeDate(row["updated_at"]) else {
            throw FloeError.storageCorrupted("Invalid task schedule row")
        }
        let lastRaw: String? = row["last_started_at"]
        let nextRaw: String? = row["next_expected_at"]
        var record = TaskScheduleRecord(
            id: id, title: row["title"], prompt: row["prompt"],
            workspaceID: (row["workspace_id"] as String?).flatMap(UUID.init(uuidString:)),
            cadence: cadence, scheduledAt: scheduledAt, weekday: row["weekday"],
            isEnabled: row["is_enabled"],
            lastStartedAt: lastRaw.flatMap { try? PersistenceCodec.decodeDate($0) },
            nextExpectedAt: nextRaw.flatMap { try? PersistenceCodec.decodeDate($0) },
            policyJSON: row["policy_json"], createdAt: createdAt, updatedAt: updatedAt,
            intervalSeconds: row["interval_seconds"],
            anchorTimezone: row["anchor_timezone"],
            upstreamRunID: (row["upstream_run_id"] as String?).flatMap(UUID.init(uuidString:)),
            modelID: (row["model_id"] as String?).flatMap(UUID.init(uuidString:)),
            environmentID: row["environment_id"],
            permissionJSON: row["permission_json"]
        )
        // An unbound record (pre-v57 or Home-created) deliberately stores
        // NULL. Never infer an origin from a title or a later run.
        record.originConversationID = (row["origin_conversation_id"] as String?)
            .flatMap(UUID.init(uuidString:))
        // A disabled one-time schedule deliberately stores NULL. The public
        // initializer defaults a newly-created schedule to scheduledAt, so
        // restore the database's explicit nil after construction.
        record.nextExpectedAt = nextRaw.flatMap { try? PersistenceCodec.decodeDate($0) }
        return record
    }

    private static func decodeOccurrence(_ row: Row) throws -> TaskScheduleOccurrence {
        guard let id = UUID(uuidString: row["id"]),
              let scheduleID = UUID(uuidString: row["schedule_id"]),
              let scheduledFor = try? PersistenceCodec.decodeDate(row["scheduled_for"]),
              let state = TaskScheduleOccurrenceState(rawValue: row["state"]),
              let dedupeKey: String = row["dedupe_key"],
              let createdAt = try? PersistenceCodec.decodeDate(row["created_at"]),
              let updatedAt = try? PersistenceCodec.decodeDate(row["updated_at"]) else {
            throw FloeError.storageCorrupted("Invalid task schedule occurrence row")
        }
        func date(_ column: String) -> Date? {
            (row[column] as String?).flatMap { try? PersistenceCodec.decodeDate($0) }
        }
        return TaskScheduleOccurrence(
            id: id,
            scheduleID: scheduleID,
            scheduledFor: scheduledFor,
            state: state,
            dedupeKey: dedupeKey,
            runID: (row["run_id"] as String?).flatMap(UUID.init(uuidString:)),
            conversationID: (row["conversation_id"] as String?).flatMap(UUID.init(uuidString:)),
            claimedAt: date("claimed_at"),
            startedAt: date("started_at"),
            finishedAt: date("finished_at"),
            summary: row["summary"],
            errorText: row["error_text"],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
