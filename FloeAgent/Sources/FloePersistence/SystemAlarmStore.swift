// FloePersistence — durable, task-owned system AlarmKit alarm/timer ledger.
//
// SPDX-License-Identifier: MPL-2.0
//
// This store is the app-private durability boundary for the S5 C3 system
// alarm/timer tools (`apple.alarm.*`). It records every intended native
// mutation BEFORE the mutation is attempted, the exact stable app-owned alarm
// identity, the runtime-trusted owner provenance, and the reconciled native
// outcome. It never stores the alarm title/label verbatim beyond a bounded
// opaque digest, and it never grants authority: source rows are input, not
// permission (the caller still derives authority from ToolContext).
//
// Identity contract (trusted, never model-minted):
//   - `ownerTaskID` is the durable conversation identity; a conversation-less
//     run falls back to `ownerRunID`. Two rows never cross owners.
//   - `alarmID` is a stable app-owned UUID derived from the exact approved
//     call (`operationID` = provider tool-call id, `idempotencyKey`) plus the
//     canonical request payload digest, so a crash-and-retry of the SAME
//     approved call converges on one alarm instead of duplicating, and a
//     different approved call can never collide. Title/text equality and the
//     current time are deliberately NOT dedup inputs.
//
// The ledger is append-oriented with compare-and-set state transitions inside
// real GRDB transactions (the same exactly-once idiom as
// `task_schedule_occurrences`). A row moves
// queued → submitted → created | unknown, and → cancelled | reconcileError,
// so a crash between the native commit and the durable save converges on a
// single recorded alarm instead of a duplicate, and a native-id mismatch is
// surfaced instead of silently adopted.

import Foundation
import GRDB
import FloeCore
import FloeModels

// MARK: - Records

/// Canonical alarm kind. A one-shot or repeating wall-clock alarm, or a
/// countdown timer. The repeating wall-clock form maps to AlarmKit's native
/// `weekly` recurrence; the timezone for a repeating alarm follows the
/// device/system calendar rules (there is no per-instance timezone in a
/// relative recurrence), which the tool surfaces honestly.
public enum SystemAlarmKind: String, Codable, Sendable, CaseIterable {
    case alarm
    case timer
}

/// Repeat semantics for a wall-clock alarm, mapped to real native schedule
/// capabilities. `.never` fires once at the absolute instant; `.weekly`
/// recurs on the given device-calendar weekdays. There is deliberately no
/// fixed-date pretend-repeat or timer-loop emulation.
public enum SystemAlarmRepeat: Equatable, Codable, Sendable {
    case never
    case weekly([Int])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "never" {
            self = .never
        } else if raw.hasPrefix("weekly:") {
            let tail = raw.dropFirst("weekly:".count)
            let days = tail.split(separator: ",").compactMap { Int($0) }
            guard !days.isEmpty, days.allSatisfy({ (1...7).contains($0) }) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "invalid weekly repeat")
            }
            self = .weekly(days)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unknown repeat '\(raw)'")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .never: try container.encode("never")
        case .weekly(let days): try container.encode("weekly:\(days.map(String.init).joined(separator: ","))")
        }
    }
}

/// Durable lifecycle of one recorded alarm row.
public enum SystemAlarmState: String, Codable, Sendable, CaseIterable {
    /// Intent persisted, native mutation not yet attempted.
    case queued
    /// Native mutation submitted; native outcome not yet reconciled.
    case submitted
    /// Native schedule confirmed and read back with the exact stable id.
    case created
    /// Native mutation was cancelled before it committed.
    case cancelled
    /// Native outcome unknown (crash / readback error) — needs reconciliation.
    case unknown
    /// Reconciliation found the native id unmapped/foreign; never adopted.
    case reconcileError
}

/// One durable alarm record (a row in `system_alarms`).
public struct SystemAlarmRecord: Sendable, Equatable, Identifiable {
    /// Stable app-owned alarm identity (also the native AlarmKit id).
    public var id: UUID
    /// Runtime-trusted owner provenance.
    public var ownerTaskID: UUID?
    public var ownerRunID: UUID
    /// Trusted per-call identity of the approved mutation.
    public var operationID: String
    public var idempotencyKey: String
    /// Canonical digest of the approved request payload (never the title).
    public var payloadDigest: String
    public var kind: SystemAlarmKind
    /// IANA timezone identifier the user-intended instant was expressed in.
    public var intendedTimezone: String
    /// User-intended absolute instant (wall clock in `intendedTimezone`).
    public var intendedFireDate: Date?
    /// Derived absolute instant actually handed to the native scheduler.
    public var nativeScheduleDate: Date?
    /// Wall-clock hour/minute for a repeating alarm.
    public var repeatHour: Int?
    public var repeatMinute: Int?
    /// Repeat semantics (`.never` or `.weekly`); stored as `repeat` column.
    public var repeatRule: SystemAlarmRepeat
    /// Bounded countdown duration for a timer.
    public var timerDuration: TimeInterval?
    /// Opaque bounded label digest (privacy: no raw title/PII in the ledger).
    public var labelDigest: String
    public var state: SystemAlarmState
    /// Native returned/readback state, preserved verbatim when known.
    public var nativeState: String?
    /// Durable operation receipt id binding this row to its mutation.
    public var operationReceiptID: UUID
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        ownerTaskID: UUID?,
        ownerRunID: UUID,
        operationID: String,
        idempotencyKey: String,
        payloadDigest: String,
        kind: SystemAlarmKind,
        intendedTimezone: String,
        intendedFireDate: Date? = nil,
        nativeScheduleDate: Date? = nil,
        repeatHour: Int? = nil,
        repeatMinute: Int? = nil,
        repeatRule: SystemAlarmRepeat = .never,
        timerDuration: TimeInterval? = nil,
        labelDigest: String,
        state: SystemAlarmState,
        nativeState: String? = nil,
        operationReceiptID: UUID,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.ownerTaskID = ownerTaskID
        self.ownerRunID = ownerRunID
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.payloadDigest = payloadDigest
        self.kind = kind
        self.intendedTimezone = intendedTimezone
        self.intendedFireDate = intendedFireDate
        self.nativeScheduleDate = nativeScheduleDate
        self.repeatHour = repeatHour
        self.repeatMinute = repeatMinute
        self.repeatRule = repeatRule
        self.timerDuration = timerDuration
        self.labelDigest = labelDigest
        self.state = state
        self.nativeState = nativeState
        self.operationReceiptID = operationReceiptID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Schema

/// Single source of truth for the `system_alarms` schema. Both the v48
/// migration and isolated store tests run this identical DDL so a test
/// exercises the exact production table shape.
public enum SystemAlarmSchema {
    /// Identical to the v48 migration body; idempotent so an isolated test
    /// database can provision the table without the central migration list.
    public static func apply(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS system_alarms (
                id TEXT PRIMARY KEY,
                owner_task_id TEXT,
                owner_run_id TEXT NOT NULL,
                operation_id TEXT NOT NULL,
                idempotency_key TEXT NOT NULL,
                payload_digest TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('alarm', 'timer')),
                intended_timezone TEXT NOT NULL,
                intended_fire_date TEXT,
                native_schedule_date TEXT,
                repeat_hour INTEGER,
                repeat_minute INTEGER,
                repeat TEXT NOT NULL DEFAULT 'never',
                timer_duration REAL,
                label_digest TEXT NOT NULL,
                state TEXT NOT NULL CHECK (state IN (
                    'queued', 'submitted', 'created', 'cancelled',
                    'unknown', 'reconcileError'
                )),
                native_state TEXT,
                operation_receipt_id TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                CHECK (
                    (kind = 'timer'
                        AND timer_duration IS NOT NULL
                        AND timer_duration > 0
                        AND intended_fire_date IS NULL
                        AND repeat_hour IS NULL AND repeat_minute IS NULL
                        AND repeat = 'never')
                    OR
                    (kind = 'alarm'
                        AND timer_duration IS NULL
                        AND repeat_hour IS NOT NULL
                        AND repeat_minute IS NOT NULL
                        AND repeat_hour BETWEEN 0 AND 23
                        AND repeat_minute BETWEEN 0 AND 59)
                )
            ) STRICT;
            CREATE INDEX IF NOT EXISTS idx_system_alarms_owner
                ON system_alarms(owner_task_id, owner_run_id);
            CREATE INDEX IF NOT EXISTS idx_system_alarms_state
                ON system_alarms(state, updated_at);
            CREATE UNIQUE INDEX IF NOT EXISTS idx_system_alarms_operation
                ON system_alarms(operation_id, idempotency_key);
            """)
    }
}

// MARK: - Store

/// Durable system-alarm ledger access. All mutations are compare-and-set
/// inside real GRDB transactions.
public protocol SystemAlarmStore: Sendable {
    /// Inserts a `queued` intent row. Returns false when the exact stable
    /// alarm id already exists (idempotent enqueue — a crash-retry of the
    /// same approved call never duplicates).
    @discardableResult
    func enqueueIntent(_ record: SystemAlarmRecord) async throws -> Bool
    /// Atomically moves a `queued` row to `submitted`, binding the durable
    /// operation receipt. Exactly one caller wins; false means the row was
    /// already moved or is gone.
    @discardableResult
    func markSubmitted(id: UUID, receiptID: UUID, at date: Date) async throws -> Bool
    /// Atomically reconciles a `submitted`/`unknown` row to `created` once the
    /// native readback confirms the exact id, preserving the native state.
    /// False when the row was not awaiting confirmation (a competing or
    /// cancelled path already settled it).
    @discardableResult
    func markCreated(id: UUID, nativeState: String, at date: Date) async throws -> Bool
    /// Atomically records an unknown native outcome (crash/readback error).
    func markUnknown(id: UUID, at date: Date) async throws
    /// Atomically cancels a still-`queued` row without any native mutation.
    /// Returns false when the row already left `queued` (committed work is
    /// reconciled, never silently dropped).
    @discardableResult
    func cancelQueued(id: UUID, at date: Date) async throws -> Bool
    /// Atomically marks a live/unconfirmed row (`created`/`submitted`/
    /// `unknown`) `cancelled` after a real native commit was undone,
    /// preserving the committed-then-cancelled outcome.
    @discardableResult
    func markCancelledAfterCommit(id: UUID, at date: Date) async throws -> Bool
    /// Records a native id mismatch/foreign alarm as `reconcileError` —
    /// the foreign native alarm is never adopted into app ownership.
    @discardableResult
    func markReconcileError(id: UUID, at date: Date) async throws -> Bool
    func record(id: UUID) async throws -> SystemAlarmRecord?
    /// Lists only the alarms owned by the given task/run provenance.
    func records(ownerTaskID: UUID?, ownerRunID: UUID) async throws -> [SystemAlarmRecord]
    /// Lists live (non-terminal) alarms for reconciliation on launch/query.
    func liveRecords(limit: Int) async throws -> [SystemAlarmRecord]
    /// Reconciles rows left `submitted`/`unknown` by a dead process: their
    /// real outcome is unknown, so they are surfaced for explicit reconcile
    /// (never auto-resumed or auto-cancelled). Returns the affected count.
    @discardableResult
    func reconcileUnfinished(at date: Date) async throws -> Int
}

public actor SQLiteSystemAlarmStore: SystemAlarmStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    // MARK: CAS transitions

    @discardableResult
    public func enqueueIntent(_ record: SystemAlarmRecord) async throws -> Bool {
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO system_alarms (
                    id, owner_task_id, owner_run_id, operation_id, idempotency_key,
                    payload_digest, kind, intended_timezone, intended_fire_date,
                    native_schedule_date, repeat_hour, repeat_minute, repeat,
                    timer_duration, label_digest, state, native_state,
                    operation_receipt_id, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'queued', NULL, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """, arguments: [
                    record.id.uuidString,
                    record.ownerTaskID?.uuidString,
                    record.ownerRunID.uuidString,
                    record.operationID,
                    record.idempotencyKey,
                    record.payloadDigest,
                    record.kind.rawValue,
                    record.intendedTimezone,
                    record.intendedFireDate.map(PersistenceCodec.encode),
                    record.nativeScheduleDate.map(PersistenceCodec.encode),
                    record.repeatHour,
                    record.repeatMinute,
                    Self.encodeRepeat(record.repeatRule),
                    record.timerDuration,
                    record.labelDigest,
                    record.operationReceiptID.uuidString,
                    PersistenceCodec.encode(record.createdAt),
                    PersistenceCodec.encode(record.updatedAt)
                ])
            return db.changesCount > 0
        }
    }

    @discardableResult
    public func markSubmitted(id: UUID, receiptID: UUID, at date: Date) async throws -> Bool {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE system_alarms
                SET state = 'submitted', operation_receipt_id = ?, updated_at = ?
                WHERE id = ? AND state = 'queued'
                """, arguments: [
                    receiptID.uuidString,
                    PersistenceCodec.encode(date),
                    id.uuidString
                ])
            return db.changesCount > 0
        }
    }

    @discardableResult
    public func markCreated(id: UUID, nativeState: String, at date: Date) async throws -> Bool {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE system_alarms
                SET state = 'created', native_state = ?, updated_at = ?
                WHERE id = ? AND state IN ('submitted', 'unknown', 'created')
                """, arguments: [
                    String(nativeState.prefix(128)),
                    PersistenceCodec.encode(date),
                    id.uuidString
                ])
            return db.changesCount > 0
        }
    }

    public func markUnknown(id: UUID, at date: Date) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE system_alarms
                SET state = 'unknown', updated_at = ?
                WHERE id = ? AND state IN ('submitted', 'created')
                """, arguments: [
                    PersistenceCodec.encode(date),
                    id.uuidString
                ])
        }
    }

    @discardableResult
    public func cancelQueued(id: UUID, at date: Date) async throws -> Bool {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE system_alarms
                SET state = 'cancelled', updated_at = ?
                WHERE id = ? AND state = 'queued'
                """, arguments: [
                    PersistenceCodec.encode(date),
                    id.uuidString
                ])
            return db.changesCount > 0
        }
    }

    @discardableResult
    public func markCancelledAfterCommit(id: UUID, at date: Date) async throws -> Bool {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE system_alarms
                SET state = 'cancelled', updated_at = ?
                WHERE id = ? AND state IN ('created', 'submitted', 'unknown')
                """, arguments: [
                    PersistenceCodec.encode(date),
                    id.uuidString
                ])
            return db.changesCount > 0
        }
    }

    @discardableResult
    public func markReconcileError(id: UUID, at date: Date) async throws -> Bool {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE system_alarms
                SET state = 'reconcileError', updated_at = ?
                WHERE id = ? AND state IN ('submitted', 'unknown')
                """, arguments: [
                    PersistenceCodec.encode(date),
                    id.uuidString
                ])
            return db.changesCount > 0
        }
    }

    // MARK: Reads

    public func record(id: UUID) async throws -> SystemAlarmRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM system_alarms WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.decode(row)
        }
    }

    public func records(ownerTaskID: UUID?, ownerRunID: UUID) async throws -> [SystemAlarmRecord] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM system_alarms
                WHERE owner_task_id IS ? AND owner_run_id = ?
                ORDER BY created_at DESC
                """, arguments: [ownerTaskID?.uuidString, ownerRunID.uuidString])
                .map(Self.decode)
        }
    }

    public func liveRecords(limit: Int) async throws -> [SystemAlarmRecord] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM system_alarms
                WHERE state IN ('submitted', 'unknown', 'created')
                ORDER BY updated_at DESC
                LIMIT ?
                """, arguments: [max(1, min(limit, 500))])
                .map(Self.decode)
        }
    }

    @discardableResult
    public func reconcileUnfinished(at date: Date) async throws -> Int {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE system_alarms
                SET updated_at = ?
                WHERE state IN ('submitted', 'unknown')
                """, arguments: [PersistenceCodec.encode(date)])
            return db.changesCount
        }
    }

    // MARK: Internals

    static func encodeRepeat(_ rule: SystemAlarmRepeat) -> String {
        switch rule {
        case .never: return "never"
        case .weekly(let days): return "weekly:\(days.map(String.init).joined(separator: ","))"
        }
    }

    private static func decode(_ row: Row) throws -> SystemAlarmRecord {
        guard let id = UUID(uuidString: row["id"]),
              let ownerRunID = UUID(uuidString: row["owner_run_id"]),
              let kind = SystemAlarmKind(rawValue: row["kind"]),
              let state = SystemAlarmState(rawValue: row["state"]),
              let receiptID = UUID(uuidString: row["operation_receipt_id"]),
              let createdAt = try? PersistenceCodec.decodeDate(row["created_at"]),
              let updatedAt = try? PersistenceCodec.decodeDate(row["updated_at"]) else {
            throw FloeError.storageCorrupted("Invalid system alarm row")
        }
        let repeatRaw: String = row["repeat"]
        guard let repeatRule = try? JSONDecoder().decode(
            SystemAlarmRepeat.self,
            from: Data("\"\(repeatRaw)\"".utf8)
        ) else {
            throw FloeError.storageCorrupted("Invalid system alarm repeat")
        }
        func date(_ column: String) -> Date? {
            (row[column] as String?).flatMap { try? PersistenceCodec.decodeDate($0) }
        }
        return SystemAlarmRecord(
            id: id,
            ownerTaskID: (row["owner_task_id"] as String?).flatMap(UUID.init(uuidString:)),
            ownerRunID: ownerRunID,
            operationID: row["operation_id"],
            idempotencyKey: row["idempotency_key"],
            payloadDigest: row["payload_digest"],
            kind: kind,
            intendedTimezone: row["intended_timezone"],
            intendedFireDate: date("intended_fire_date"),
            nativeScheduleDate: date("native_schedule_date"),
            repeatHour: row["repeat_hour"],
            repeatMinute: row["repeat_minute"],
            repeatRule: repeatRule,
            timerDuration: row["timer_duration"],
            labelDigest: row["label_digest"],
            state: state,
            nativeState: row["native_state"],
            operationReceiptID: receiptID,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
