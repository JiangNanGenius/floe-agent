// SPDX-License-Identifier: MPL-2.0
//
// C06 — App-local todos and local reminder plans.
//
// Todos are independently owned user data. They are NOT Notes editor state,
// NOT a chat-task projection and NOT a second Agent scheduler:
//
//   * the row survives deletion of any conversation/task that merely helped
//     create it; owner fields are provenance, never a cascade;
//   * revisions are monotonic integers and every edit/complete/delete is a
//     real SQL CAS (`WHERE id = ? AND revision = ?`), so a stale UI draft can
//     never overwrite a newer one;
//   * a due reminder produces one local notification. It never launches a
//     paid model run, an Agent schedule or a background inference;
//   * the OS wake transport (AlarmManager/notifications) is Android-owned.
//     This file only computes bounded reminder plans and asks the trusted
//     host port to arm/disarm the exact owned PendingIntent.
//
// The schema is delivered as a declarative fragment (MIGRATION_TODO.sql) for
// Main's single next coordinated migration; this file allocates no schema
// version and has no side effect at import time.
import Foundation
import GRDB
import FloeCore
import FloePersistence
import FloeTools

// MARK: - Bounds

public enum C06TodoWire {
    public static let schema = "floe.todo/1"
    public static let table = "calendar_todos"
    public static let maximumTitleBytes = 512
    public static let maximumNotesBytes = 8_192
    public static let maximumList = 100
    public static let maximumPlans = 200
    public static let maximumScan = 500
    public static let maximumReminderMinutes = 525_600
    public static let maximumRecurrenceInterval = 365
    public static let maximumOwnerBytes = 128
    public static let maximumOccurrenceBytes = 64
    public static let modelToolNames: [String] = [
        "todo.list",
        "todo.save",
        "todo.complete",
        "todo.delete",
    ]
}

public enum C06TodoSchema {
    public static let createTableSQL = """
        CREATE TABLE IF NOT EXISTS calendar_todos (
            id TEXT PRIMARY KEY NOT NULL,
            title TEXT NOT NULL,
            notes TEXT NOT NULL,
            due_at TEXT,
            due_timezone TEXT NOT NULL,
            all_day INTEGER NOT NULL,
            recurrence TEXT NOT NULL,
            recurrence_interval INTEGER NOT NULL,
            recurrence_until TEXT,
            reminder_minutes_before INTEGER,
            completed INTEGER NOT NULL,
            completed_at TEXT,
            revision INTEGER NOT NULL,
            owner_conversation_id TEXT,
            owner_task_id TEXT,
            owner_environment_id TEXT,
            last_reminder_at TEXT,
            last_reminder_occurrence TEXT,
            -- Set by a C07 backup restore. The planner ignores a suspended
            -- row until the user edits/saves it; due date, content,
            -- completion and the reminder preference all survive.
            reminders_suspended INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    public static let indexesSQL = [
        "CREATE INDEX IF NOT EXISTS calendar_todos_due ON calendar_todos(completed, due_at)",
        "CREATE INDEX IF NOT EXISTS calendar_todos_updated ON calendar_todos(updated_at)",
    ]
}

// MARK: - Errors

public enum C06TodoErrorCode: String, Codable, Sendable, Equatable {
    case coreUnavailable
    case runtimeNotInstalled
    case staleEpoch
    case invalidRequest
    case invalidOwner
    case temporaryOwnerCannotUseTodo
    case schemaUnavailable
    case storageUnavailable
    case notFound
    case revisionConflict
    case invalidTitle
    case invalidNotes
    case invalidDue
    case invalidTimezone
    case invalidRecurrence
    case invalidReminder
    case reminderArmFailed
    case notificationsBlocked
    case exactAlarmUnavailable
    case cancelled
    case internalFailure
}

public struct C06TodoError: Error, Sendable, Equatable {
    public let code: C06TodoErrorCode
    public let reason: String
    public let retryable: Bool

    public init(_ code: C06TodoErrorCode, _ reason: String? = nil, retryable: Bool = false) {
        self.code = code
        self.reason = String((reason ?? code.rawValue).prefix(120))
        self.retryable = retryable
    }
}

// MARK: - Owner (same shape as the calendar owner)

public struct C06TodoOwner: Sendable, Equatable {
    public let token: String
    public let nativeEpoch: UInt64
    public let conversationID: UUID?
    public let taskID: UUID?
    public let environmentID: String?
    public let temporary: Bool

    public init(
        token: String,
        nativeEpoch: UInt64,
        conversationID: UUID? = nil,
        taskID: UUID? = nil,
        environmentID: String? = nil,
        temporary: Bool = false
    ) throws {
        guard (8...C06TodoWire.maximumOwnerBytes).contains(token.utf8.count),
              token.unicodeScalars.allSatisfy({
                  $0.value < 128
                      && !$0.properties.isWhitespace
                      && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C06TodoError(.invalidOwner, "invalidOwnerToken")
        }
        guard nativeEpoch > 0 else { throw C06TodoError(.invalidOwner, "invalidNativeEpoch") }
        if temporary {
            throw C06TodoError(.temporaryOwnerCannotUseTodo, "temporaryOwnerCannotUseTodo")
        }
        self.token = token
        self.nativeEpoch = nativeEpoch
        self.conversationID = conversationID
        self.taskID = taskID
        self.environmentID = environmentID
        self.temporary = temporary
    }

    public static func parse(_ value: Any?) throws -> C06TodoOwner {
        guard let object = value as? [String: Any],
              let token = c06CalString(object["token"], maxBytes: C06TodoWire.maximumOwnerBytes),
              let epoch = c06CalUInt64(object["nativeEpoch"]) else {
            throw C06TodoError(.invalidOwner, "invalidOwner")
        }
        return try C06TodoOwner(
            token: token,
            nativeEpoch: epoch,
            conversationID: (object["conversationID"] as? String).flatMap(UUID.init(uuidString:)),
            taskID: (object["taskID"] as? String).flatMap(UUID.init(uuidString:)),
            environmentID: c06CalString(object["environmentID"], maxBytes: C06TodoWire.maximumOwnerBytes),
            temporary: c06CalBool(object["temporary"]) ?? false
        )
    }
}

// MARK: - Values

public enum C06TodoRecurrenceKind: String, Sendable, Codable, CaseIterable, Equatable {
    case none
    case daily
    case weekly
    case monthly

    public var isRepeating: Bool { self != .none }
}

public struct C06TodoRecurrence: Sendable, Equatable {
    public var kind: C06TodoRecurrenceKind
    public var interval: Int
    public var until: Date?

    public init(kind: C06TodoRecurrenceKind = .none, interval: Int = 1, until: Date? = nil) {
        self.kind = kind
        self.interval = interval
        self.until = until
    }

    public func validate() throws {
        guard (1...C06TodoWire.maximumRecurrenceInterval).contains(interval) else {
            throw C06TodoError(.invalidRecurrence, "invalidRecurrenceInterval")
        }
        if kind == .none && interval != 1 {
            throw C06TodoError(.invalidRecurrence, "recurrenceIntervalWithoutRecurrence")
        }
    }
}

public struct C06TodoRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var dueAt: Date?
    public var dueTimeZone: String
    public var allDay: Bool
    public var recurrence: C06TodoRecurrence
    public var reminderMinutesBefore: Int?
    public var completed: Bool
    public var completedAt: Date?
    public var revision: Int
    public var ownerConversationID: UUID?
    public var ownerTaskID: UUID?
    public var ownerEnvironmentID: String?
    public var lastReminderAt: Date?
    public var lastReminderOccurrence: String?
    /// Restored todos start suspended so no alarm/notification is armed
    /// without a fresh user action.
    public var remindersSuspended: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        dueAt: Date? = nil,
        dueTimeZone: String = TimeZone.current.identifier,
        allDay: Bool = false,
        recurrence: C06TodoRecurrence = C06TodoRecurrence(),
        reminderMinutesBefore: Int? = nil,
        completed: Bool = false,
        completedAt: Date? = nil,
        revision: Int = 1,
        ownerConversationID: UUID? = nil,
        ownerTaskID: UUID? = nil,
        ownerEnvironmentID: String? = nil,
        lastReminderAt: Date? = nil,
        lastReminderOccurrence: String? = nil,
        remindersSuspended: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueAt = dueAt
        self.dueTimeZone = dueTimeZone
        self.allDay = allDay
        self.recurrence = recurrence
        self.reminderMinutesBefore = reminderMinutesBefore
        self.completed = completed
        self.completedAt = completedAt
        self.revision = revision
        self.ownerConversationID = ownerConversationID
        self.ownerTaskID = ownerTaskID
        self.ownerEnvironmentID = ownerEnvironmentID
        self.lastReminderAt = lastReminderAt
        self.lastReminderOccurrence = lastReminderOccurrence
        self.remindersSuspended = remindersSuspended
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct C06TodoPlan: Sendable, Equatable {
    public var todoID: UUID
    public var dueAt: Date
    public var reminderAt: Date
    public var occurrenceKey: String
    public var allDay: Bool
    public var timeZone: String

    public init(todoID: UUID, dueAt: Date, reminderAt: Date, occurrenceKey: String,
                allDay: Bool, timeZone: String) {
        self.todoID = todoID
        self.dueAt = dueAt
        self.reminderAt = reminderAt
        self.occurrenceKey = occurrenceKey
        self.allDay = allDay
        self.timeZone = timeZone
    }
}

public struct C06TodoReminderArmResult: Sendable, Equatable {
    public var scheduled: Bool
    public var state: String
    public var reason: String?

    public init(scheduled: Bool, state: String, reason: String? = nil) {
        self.scheduled = scheduled
        self.state = String(state.prefix(32))
        self.reason = reason.map { String($0.prefix(120)) }
    }

    public static let none = C06TodoReminderArmResult(scheduled: false, state: "none")
}

public struct C06TodoMutationResult: Sendable, Equatable {
    public var record: C06TodoRecord
    public var plan: C06TodoPlan?
    public var reminder: C06TodoReminderArmResult
}

public struct C06TodoDue: Sendable, Equatable {
    public var record: C06TodoRecord
    public var plan: C06TodoPlan
}

// MARK: - Store protocol

public protocol C06TodoStoring: Sendable {
    func schemaReady() async throws -> Bool
    func list(includeCompleted: Bool, limit: Int, offset: Int) async throws -> (rows: [C06TodoRecord], total: Int)
    func get(id: UUID) async throws -> C06TodoRecord?
    func insert(_ record: C06TodoRecord) async throws
    func updateCAS(_ record: C06TodoRecord, expectedRevision: Int) async throws -> C06TodoRecord
    func completeCAS(id: UUID, expectedRevision: Int, completed: Bool, at: Date) async throws -> C06TodoRecord
    func deleteCAS(id: UUID, expectedRevision: Int) async throws
    func planCandidates(limit: Int) async throws -> [C06TodoRecord]
    func markReminderShown(id: UUID, occurrenceKey: String, at: Date) async throws -> Bool
}

// MARK: - Store

public actor C06TodoStore: C06TodoStoring {
    private let database: DatabaseManager
    private let formatter: ISO8601DateFormatter

    public init(database: DatabaseManager) {
        self.database = database
        self.formatter = Self.makeFormatter()
    }

    private nonisolated static func makeFormatter() -> ISO8601DateFormatter {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime]
        value.timeZone = TimeZone(secondsFromGMT: 0)
        return value
    }

    public func schemaReady() async throws -> Bool {
        try await database.reader { db in
            try db.tableExists(C06TodoWire.table)
        }
    }

    public func list(includeCompleted: Bool, limit: Int, offset: Int) async throws
        -> (rows: [C06TodoRecord], total: Int) {
        let boundedLimit = max(1, min(limit, C06TodoWire.maximumList))
        let boundedOffset = max(0, offset)
        return try await database.reader { db in
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(C06TodoWire.table) WHERE (? = 1 OR completed = 0)",
                arguments: [includeCompleted ? 1 : 0]
            ) ?? 0
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM \(C06TodoWire.table)
                    WHERE (? = 1 OR completed = 0)
                    ORDER BY (due_at IS NULL), due_at, created_at, id
                    LIMIT ? OFFSET ?
                    """,
                arguments: [includeCompleted ? 1 : 0, boundedLimit, boundedOffset]
            ).map { try Self.decode($0, formatter: Self.makeFormatter()) }
            return (rows, total)
        }
    }

    public func get(id: UUID) async throws -> C06TodoRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM \(C06TodoWire.table) WHERE id = ?",
                arguments: [id.uuidString.lowercased()]
            ) else { return nil }
            return try Self.decode(row, formatter: Self.makeFormatter())
        }
    }

    public func insert(_ record: C06TodoRecord) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO \(C06TodoWire.table) (
                        id, title, notes, due_at, due_timezone, all_day, recurrence,
                        recurrence_interval, recurrence_until, reminder_minutes_before,
                        completed, completed_at, revision, owner_conversation_id,
                        owner_task_id, owner_environment_id, last_reminder_at,
                        last_reminder_occurrence, reminders_suspended,
                        created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: StatementArguments(Self.arguments(record, formatter: Self.makeFormatter()))
            )
        }
    }

    /// Real CAS: the WHERE clause carries the revision the caller observed.
    /// Zero changed rows is a conflict, never a silent overwrite.
    public func updateCAS(_ record: C06TodoRecord, expectedRevision: Int) async throws -> C06TodoRecord {
        guard expectedRevision >= 0 else { throw C06TodoError(.revisionConflict, "invalidRevision") }
        var updated = record
        updated.revision = expectedRevision + 1
        updated.updatedAt = Date()
        // Saving through the normal editor is the explicit enable pathway.
        updated.remindersSuspended = false
        let values: [DatabaseValueConvertible?] = [
            updated.title, updated.notes,
            updated.dueAt.map { formatter.string(from: $0) } ?? nil,
            updated.dueTimeZone, updated.allDay ? 1 : 0,
            updated.recurrence.kind.rawValue, updated.recurrence.interval,
            updated.recurrence.until.map { formatter.string(from: $0) } ?? nil,
            updated.reminderMinutesBefore ?? nil,
            updated.completed ? 1 : 0,
            updated.completedAt.map { formatter.string(from: $0) } ?? nil,
            updated.revision,
            updated.ownerConversationID?.uuidString.lowercased() ?? nil,
            updated.ownerTaskID?.uuidString.lowercased() ?? nil,
            updated.ownerEnvironmentID ?? nil,
            updated.lastReminderAt.map { formatter.string(from: $0) } ?? nil,
            updated.lastReminderOccurrence ?? nil,
            updated.remindersSuspended ? 1 : 0,
            formatter.string(from: updated.createdAt),
            formatter.string(from: updated.updatedAt),
            updated.id.uuidString.lowercased(),
            expectedRevision,
        ]
        let sqlArguments = StatementArguments(values)
        let changed = try await database.writer { db -> Int in
            try db.execute(
                sql: """
                    UPDATE \(C06TodoWire.table) SET
                        title = ?, notes = ?, due_at = ?, due_timezone = ?, all_day = ?,
                        recurrence = ?, recurrence_interval = ?, recurrence_until = ?,
                        reminder_minutes_before = ?, completed = ?, completed_at = ?,
                        revision = ?, owner_conversation_id = ?, owner_task_id = ?,
                        owner_environment_id = ?, last_reminder_at = ?,
                        last_reminder_occurrence = ?, reminders_suspended = ?,
                        created_at = ?, updated_at = ?
                    WHERE id = ? AND revision = ?
                    """,
                arguments: sqlArguments
            )
            return db.changesCount
        }
        guard changed == 1 else { throw C06TodoError(.revisionConflict, "revisionConflict") }
        return updated
    }

    public func completeCAS(id: UUID, expectedRevision: Int, completed: Bool,
                            at: Date) async throws -> C06TodoRecord {
        let values: [DatabaseValueConvertible?] = [
            completed ? 1 : 0,
            completed ? formatter.string(from: at) : nil,
            formatter.string(from: at),
            id.uuidString.lowercased(),
            expectedRevision,
        ]
        let sqlArguments = StatementArguments(values)
        let changed = try await database.writer { db -> Int in
            try db.execute(
                sql: """
                    UPDATE \(C06TodoWire.table) SET
                        completed = ?, completed_at = ?, revision = revision + 1, updated_at = ?
                    WHERE id = ? AND revision = ?
                    """,
                arguments: sqlArguments
            )
            return db.changesCount
        }
        guard changed == 1 else { throw C06TodoError(.revisionConflict, "revisionConflict") }
        guard let record = try await get(id: id) else {
            throw C06TodoError(.storageUnavailable, "completedTodoMissing")
        }
        return record
    }

    public func deleteCAS(id: UUID, expectedRevision: Int) async throws {
        let changed = try await database.writer { db -> Int in
            try db.execute(
                sql: "DELETE FROM \(C06TodoWire.table) WHERE id = ? AND revision = ?",
                arguments: [id.uuidString.lowercased(), expectedRevision]
            )
            return db.changesCount
        }
        guard changed == 1 else { throw C06TodoError(.revisionConflict, "revisionConflict") }
    }

    public func planCandidates(limit: Int) async throws -> [C06TodoRecord] {
        let bounded = max(1, min(limit, C06TodoWire.maximumScan))
        return try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM \(C06TodoWire.table)
                    WHERE completed = 0 AND due_at IS NOT NULL
                      AND reminder_minutes_before IS NOT NULL
                      AND reminders_suspended = 0
                    ORDER BY due_at, id
                    LIMIT ?
                    """,
                arguments: [bounded]
            ).map { try Self.decode($0, formatter: Self.makeFormatter()) }
        }
    }

    /// Idempotent occurrence stamp. A second delivery for the same occurrence
    /// changes zero rows and is reported as already shown.
    public func markReminderShown(id: UUID, occurrenceKey: String, at: Date) async throws -> Bool {
        let timestamp = formatter.string(from: at)
        let changed = try await database.writer { db -> Int in
            try db.execute(
                sql: """
                    UPDATE \(C06TodoWire.table) SET
                        last_reminder_at = ?, last_reminder_occurrence = ?
                    WHERE id = ?
                      AND (last_reminder_occurrence IS NULL OR last_reminder_occurrence <> ?)
                    """,
                arguments: [timestamp, occurrenceKey,
                            id.uuidString.lowercased(), occurrenceKey]
            )
            return db.changesCount
        }
        return changed == 1
    }

    // MARK: Encode / decode

    private static func arguments(_ record: C06TodoRecord,
                                  formatter: ISO8601DateFormatter) -> [DatabaseValueConvertible?] {
        [
            record.id.uuidString.lowercased(),
            record.title,
            record.notes,
            record.dueAt.map { formatter.string(from: $0) } ?? nil,
            record.dueTimeZone,
            record.allDay ? 1 : 0,
            record.recurrence.kind.rawValue,
            record.recurrence.interval,
            record.recurrence.until.map { formatter.string(from: $0) } ?? nil,
            record.reminderMinutesBefore ?? nil,
            record.completed ? 1 : 0,
            record.completedAt.map { formatter.string(from: $0) } ?? nil,
            record.revision,
            record.ownerConversationID?.uuidString.lowercased() ?? nil,
            record.ownerTaskID?.uuidString.lowercased() ?? nil,
            record.ownerEnvironmentID ?? nil,
            record.lastReminderAt.map { formatter.string(from: $0) } ?? nil,
            record.lastReminderOccurrence ?? nil,
            record.remindersSuspended ? 1 : 0,
            formatter.string(from: record.createdAt),
            formatter.string(from: record.updatedAt),
        ]
    }

    private static func decode(_ row: Row, formatter: ISO8601DateFormatter) throws -> C06TodoRecord {
        guard let id = UUID(uuidString: row["id"]),
              let kind = C06TodoRecurrenceKind(rawValue: row["recurrence"]),
              let createdAt = formatter.date(from: row["created_at"]),
              let updatedAt = formatter.date(from: row["updated_at"]) else {
            throw C06TodoError(.storageUnavailable, "corruptTodoRow")
        }
        func date(_ column: String) -> Date? {
            guard let raw: String = row[column] else { return nil }
            return formatter.date(from: raw)
        }
        return C06TodoRecord(
            id: id,
            title: row["title"],
            notes: row["notes"],
            dueAt: date("due_at"),
            dueTimeZone: row["due_timezone"],
            allDay: (row["all_day"] as Int) != 0,
            recurrence: C06TodoRecurrence(
                kind: kind,
                interval: row["recurrence_interval"],
                until: date("recurrence_until")
            ),
            reminderMinutesBefore: row["reminder_minutes_before"],
            completed: (row["completed"] as Int) != 0,
            completedAt: date("completed_at"),
            revision: row["revision"],
            ownerConversationID: (row["owner_conversation_id"] as String?).flatMap(UUID.init(uuidString:)),
            ownerTaskID: (row["owner_task_id"] as String?).flatMap(UUID.init(uuidString:)),
            ownerEnvironmentID: row["owner_environment_id"],
            lastReminderAt: date("last_reminder_at"),
            lastReminderOccurrence: row["last_reminder_occurrence"],
            remindersSuspended: ((row["reminders_suspended"] as Int?) ?? 0) != 0,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

// MARK: - Reminder planning

public enum C06TodoPlanner {
    public static func normalizeDue(
        _ due: Date?,
        allDay: Bool,
        timeZoneIdentifier: String
    ) throws -> (due: Date?, zone: String) {
        guard let due else { return (nil, try C06CalendarDate.validateTimeZone(timeZoneIdentifier)) }
        if allDay {
            // The App editor and model tools both emit canonical UTC midnight
            // for the chosen calendar date. Re-projecting that instant through
            // a west-of-UTC zone would move it to the previous date.
            if C06CalendarDomain.isUTCMidnight(due) {
                return (due, "UTC")
            }
            guard let zone = TimeZone(identifier: timeZoneIdentifier) else {
                throw C06TodoError(.invalidTimezone, "invalidTimezone")
            }
            var local = Calendar(identifier: .gregorian)
            local.timeZone = zone
            let components = local.dateComponents([.year, .month, .day], from: due)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            guard let midnight = utc.date(from: DateComponents(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: 0,
                minute: 0,
                second: 0
            )) else {
                throw C06TodoError(.invalidDue, "invalidAllDayDue")
            }
            return (midnight, "UTC")
        }
        return (due, try C06CalendarDate.validateTimeZone(timeZoneIdentifier))
    }

    public static func plan(
        record: C06TodoRecord,
        now: Date
    ) -> C06TodoPlan? {
        guard !record.completed,
              let due = record.dueAt,
              let minutes = record.reminderMinutesBefore else { return nil }
        if let until = record.recurrence.until, due > until { return nil }
        let dueZone = TimeZone(identifier: record.dueTimeZone) ?? .current
        let offset = TimeInterval(max(0, minutes) * 60)
        var candidate = due
        var hops = 0
        while candidate.addingTimeInterval(-offset) <= now {
            guard let next = advance(candidate, record: record, zone: dueZone) else {
                return nil
            }
            candidate = next
            hops += 1
            if hops > 10_000 { return nil }
            if let until = record.recurrence.until, candidate > until { return nil }
        }
        return C06TodoPlan(
            todoID: record.id,
            dueAt: candidate,
            reminderAt: candidate.addingTimeInterval(-offset),
            occurrenceKey: C06CalendarDate.iso8601(candidate),
            allDay: record.allDay,
            timeZone: record.dueTimeZone
        )
    }

    /// The occurrence the current record still owns. Used when an exact alarm
    /// fires late: the plan may already have rolled to a newer occurrence, so
    /// delivery must verify the alarm's exact occurrence instead of inventing
    /// the newest one.
    public static func plan(
        record: C06TodoRecord,
        occurrenceKey: String,
        now: Date
    ) -> C06TodoPlan? {
        guard !record.completed,
              let due = record.dueAt,
              let minutes = record.reminderMinutesBefore,
              occurrenceKey.utf8.count <= C06TodoWire.maximumOccurrenceBytes else { return nil }
        if let until = record.recurrence.until, due > until { return nil }
        let dueZone = TimeZone(identifier: record.dueTimeZone) ?? .current
        var candidate = due
        var hops = 0
        while hops <= 10_000 {
            let key = C06CalendarDate.iso8601(candidate)
            if key == occurrenceKey {
                let reminderAt = candidate.addingTimeInterval(-TimeInterval(max(0, minutes) * 60))
                guard now >= reminderAt.addingTimeInterval(-60) else { return nil }
                return C06TodoPlan(
                    todoID: record.id,
                    dueAt: candidate,
                    reminderAt: reminderAt,
                    occurrenceKey: key,
                    allDay: record.allDay,
                    timeZone: record.dueTimeZone
                )
            }
            guard key < occurrenceKey else { return nil }
            guard let next = advance(candidate, record: record, zone: dueZone) else { return nil }
            candidate = next
            hops += 1
        }
        return nil
    }

    private static func advance(_ date: Date, record: C06TodoRecord, zone: TimeZone) -> Date? {
        switch record.recurrence.kind {
        case .none:
            return nil
        case .daily, .weekly, .monthly:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = record.allDay ? (TimeZone(secondsFromGMT: 0) ?? zone) : zone
            let component: Calendar.Component = switch record.recurrence.kind {
            case .daily: .day
            case .weekly: .day
            case .monthly: .month
            case .none: .day
            }
            let step = record.recurrence.kind == .weekly
                ? record.recurrence.interval * 7
                : record.recurrence.interval
            guard let next = calendar.date(byAdding: component, value: step, to: date) else {
                return nil
            }
            if record.allDay { return next }
            // Re-pin wall-clock time so a DST transition cannot shift a
            // 09:00 reminder to 08:00 or 10:00.
            let components = calendar.dateComponents([.hour, .minute, .second], from: date)
            return calendar.date(
                bySettingHour: components.hour ?? 0,
                minute: components.minute ?? 0,
                second: components.second ?? 0,
                of: next
            ) ?? next
        }
    }
}

// MARK: - Reminder port

public protocol C06TodoReminderPort: Sendable {
    func arm(plan: C06TodoPlan, owner: C06TodoOwner) async throws -> C06TodoReminderArmResult
    func disarm(todoID: UUID, owner: C06TodoOwner) async throws
    func noteReminderShown(todoID: UUID, occurrenceKey: String, epoch: UInt64) async
}

// MARK: - Availability

public struct C06TodoAvailabilitySnapshot: Sendable, Equatable {
    public var ready: Bool
    public var schemaReady: Bool
    public var count: Int
    public var epoch: UInt64?

    public init(ready: Bool = false, schemaReady: Bool = false, count: Int = 0, epoch: UInt64? = nil) {
        self.ready = ready
        self.schemaReady = schemaReady
        self.count = count
        self.epoch = epoch
    }

    public var available: Bool { ready && schemaReady }
}

public final class C06TodoAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var value = C06TodoAvailabilitySnapshot()

    public var snapshot: C06TodoAvailabilitySnapshot {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func update(ready: Bool, schemaReady: Bool, count: Int, epoch: UInt64?) {
        lock.lock()
        value = C06TodoAvailabilitySnapshot(
            ready: ready,
            schemaReady: schemaReady,
            count: max(0, count),
            epoch: epoch
        )
        lock.unlock()
    }

    public func reset() {
        lock.lock(); value = C06TodoAvailabilitySnapshot(); lock.unlock()
    }
}

// MARK: - Domain

public actor C06TodoDomain {
    public static let shared = C06TodoDomain(
        store: { epoch in try C06TodoProductionWiring.store(epoch: epoch) },
        reminders: C06TodoHostReminderPort(),
        readiness: { C06TodoProductionWiring.readiness() }
    )
    public static let availability = C06TodoAvailability()

    private let store: @Sendable (UInt64) async throws -> any C06TodoStoring
    private let reminders: any C06TodoReminderPort
    private let readiness: @Sendable () -> (ready: Bool, epoch: UInt64?)
    private let now: @Sendable () -> Date

    public init(
        store: @escaping @Sendable (UInt64) async throws -> any C06TodoStoring,
        reminders: any C06TodoReminderPort,
        readiness: @escaping @Sendable () -> (ready: Bool, epoch: UInt64?),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.reminders = reminders
        self.readiness = readiness
        self.now = now
    }

    private func authorized(_ owner: C06TodoOwner) async throws -> any C06TodoStoring {
        let current = readiness()
        guard current.ready, let epoch = current.epoch else {
            throw C06TodoError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard epoch == owner.nativeEpoch else { throw C06TodoError(.staleEpoch, "staleNativeEpoch") }
        let store = try await store(epoch)
        guard try await store.schemaReady() else {
            throw C06TodoError(.schemaUnavailable, "todoSchemaUnavailable")
        }
        C06TodoDomain.availability.update(
            ready: true,
            schemaReady: true,
            count: C06TodoDomain.availability.snapshot.count,
            epoch: owner.nativeEpoch
        )
        return store
    }

    public func refreshAvailability(epoch: UInt64) async {
        guard readiness().epoch == epoch else {
            C06TodoDomain.availability.reset()
            return
        }
        do {
            let store = try await store(epoch)
            let ready = try await store.schemaReady()
            var total = 0
            if ready {
                total = try await store.list(includeCompleted: true, limit: 1, offset: 0).total
            }
            C06TodoDomain.availability.update(ready: true, schemaReady: ready, count: total, epoch: epoch)
        } catch {
            C06TodoDomain.availability.reset()
        }
    }

    public func list(
        owner: C06TodoOwner,
        includeCompleted: Bool,
        limit: Int,
        offset: Int
    ) async throws -> (rows: [C06TodoRecord], total: Int) {
        let store = try await authorized(owner)
        return try await store.list(
            includeCompleted: includeCompleted,
            limit: limit,
            offset: offset
        )
    }

    public func get(owner: C06TodoOwner, id: UUID) async throws -> C06TodoRecord {
        let store = try await authorized(owner)
        guard let record = try await store.get(id: id) else {
            throw C06TodoError(.notFound, "todoNotFound")
        }
        return record
    }

    public func save(
        owner: C06TodoOwner,
        id: UUID?,
        expectedRevision: Int?,
        title: String,
        notes: String,
        dueAt: Date?,
        allDay: Bool,
        timeZone: String?,
        recurrence: C06TodoRecurrence,
        reminderMinutesBefore: Int?
    ) async throws -> C06TodoMutationResult {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              trimmedTitle.utf8.count <= C06TodoWire.maximumTitleBytes else {
            throw C06TodoError(.invalidTitle, "titleRequired")
        }
        guard notes.utf8.count <= C06TodoWire.maximumNotesBytes else {
            throw C06TodoError(.invalidNotes, "notesTooLong")
        }
        try recurrence.validate()
        if let reminder = reminderMinutesBefore {
            guard (0...C06TodoWire.maximumReminderMinutes).contains(reminder) else {
                throw C06TodoError(.invalidReminder, "invalidReminderOffset")
            }
            guard dueAt != nil else {
                throw C06TodoError(.invalidDue, "dueDateRequiredForReminder")
            }
        }
        if dueAt == nil && recurrence.kind != .none {
            throw C06TodoError(.invalidRecurrence, "dueDateRequiredForRecurrence")
        }
        let normalized = try C06TodoPlanner.normalizeDue(
            dueAt,
            allDay: allDay,
            timeZoneIdentifier: timeZone ?? TimeZone.current.identifier
        )
        let store = try await authorized(owner)
        let timestamp = now()
        let result: C06TodoRecord
        if let id {
            guard let expectedRevision else {
                throw C06TodoError(.invalidRequest, "expectedRevisionRequired")
            }
            guard var record = try await store.get(id: id) else {
                throw C06TodoError(.notFound, "todoNotFound")
            }
            record.title = trimmedTitle
            record.notes = notes
            record.dueAt = normalized.due
            record.dueTimeZone = normalized.zone
            record.allDay = allDay
            record.recurrence = recurrence
            record.reminderMinutesBefore = reminderMinutesBefore
            if record.completed {
                // Editing a completed todo keeps it completed; the caller can
                // explicitly reopen it with todo.complete.
                record.completedAt = record.completedAt ?? timestamp
            }
            record.updatedAt = timestamp
            result = try await store.updateCAS(record, expectedRevision: expectedRevision)
        } else {
            let record = C06TodoRecord(
                title: trimmedTitle,
                notes: notes,
                dueAt: normalized.due,
                dueTimeZone: normalized.zone,
                allDay: allDay,
                recurrence: recurrence,
                reminderMinutesBefore: reminderMinutesBefore,
                revision: 1,
                ownerConversationID: owner.conversationID,
                ownerTaskID: owner.taskID,
                ownerEnvironmentID: owner.environmentID,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            try await store.insert(record)
            result = record
        }
        return await applyReminder(record: result, owner: owner)
    }

    public func complete(
        owner: C06TodoOwner,
        id: UUID,
        expectedRevision: Int,
        completed: Bool
    ) async throws -> C06TodoMutationResult {
        let store = try await authorized(owner)
        let record = try await store.completeCAS(
            id: id,
            expectedRevision: expectedRevision,
            completed: completed,
            at: now()
        )
        if completed {
            try? await reminders.disarm(todoID: id, owner: owner)
            return C06TodoMutationResult(
                record: record,
                plan: nil,
                reminder: .none
            )
        }
        return await applyReminder(record: record, owner: owner)
    }

    public func delete(
        owner: C06TodoOwner,
        id: UUID,
        expectedRevision: Int
    ) async throws {
        let store = try await authorized(owner)
        try await store.deleteCAS(id: id, expectedRevision: expectedRevision)
        try? await reminders.disarm(todoID: id, owner: owner)
        await reminders.noteReminderShown(todoID: id, occurrenceKey: "deleted", epoch: owner.nativeEpoch)
    }

    public func reminderPlans(owner: C06TodoOwner) async throws -> [C06TodoPlan] {
        let store = try await authorized(owner)
        let records = try await store.planCandidates(limit: C06TodoWire.maximumScan)
        let timestamp = now()
        return records.compactMap { record in
            C06TodoPlanner.plan(record: record, now: timestamp)
        }.prefix(C06TodoWire.maximumPlans).map { $0 }
    }

    /// Used by the App delivery worker after an exact alarm fired. The exact
    /// occurrence is verified; a completed/deleted/stale todo returns nil and
    /// no notification is fabricated.
    public func reminderDue(
        owner: C06TodoOwner,
        id: UUID,
        occurrenceKey: String
    ) async throws -> C06TodoDue {
        let store = try await authorized(owner)
        guard let record = try await store.get(id: id) else {
            throw C06TodoError(.notFound, "todoNotFound")
        }
        guard let plan = C06TodoPlanner.plan(
            record: record,
            occurrenceKey: occurrenceKey,
            now: now()
        ) else {
            throw C06TodoError(.notFound, "reminderOccurrenceNotDue")
        }
        return C06TodoDue(record: record, plan: plan)
    }

    public func markReminderShown(
        owner: C06TodoOwner,
        id: UUID,
        occurrenceKey: String
    ) async throws -> Bool {
        let store = try await authorized(owner)
        let shown = try await store.markReminderShown(
            id: id,
            occurrenceKey: occurrenceKey,
            at: now()
        )
        if shown {
            await reminders.noteReminderShown(
                todoID: id,
                occurrenceKey: occurrenceKey,
                epoch: owner.nativeEpoch
            )
        }
        return shown
    }

    private func applyReminder(
        record: C06TodoRecord,
        owner: C06TodoOwner
    ) async -> C06TodoMutationResult {
        guard let plan = C06TodoPlanner.plan(record: record, now: now()) else {
            try? await reminders.disarm(todoID: record.id, owner: owner)
            return C06TodoMutationResult(record: record, plan: nil, reminder: .none)
        }
        do {
            let result = try await reminders.arm(plan: plan, owner: owner)
            return C06TodoMutationResult(record: record, plan: plan, reminder: result)
        } catch let error as C06TodoError {
            return C06TodoMutationResult(
                record: record,
                plan: plan,
                reminder: C06TodoReminderArmResult(
                    scheduled: false,
                    state: error.code == .notificationsBlocked ? "notificationsBlocked"
                        : error.code == .exactAlarmUnavailable ? "exactUnavailable" : "armFailed",
                    reason: error.reason
                )
            )
        } catch {
            return C06TodoMutationResult(
                record: record,
                plan: plan,
                reminder: C06TodoReminderArmResult(scheduled: false, state: "armFailed",
                                                   reason: "reminderTransportUnavailable")
            )
        }
    }
}

// MARK: - Production wiring

enum C06TodoProductionWiring {
    static func readiness() -> (ready: Bool, epoch: UInt64?) {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            return (false, nil)
        }
        return (true, composition.epoch)
    }

    static func store(epoch: UInt64) throws -> C06TodoStore {
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            throw C06TodoError(.runtimeNotInstalled, "runtimeNotInstalled", retryable: true)
        }
        guard composition.epoch == epoch else {
            throw C06TodoError(.staleEpoch, "staleNativeEpoch")
        }
        return C06TodoStore(database: composition.cluster.database)
    }
}

/// Production reminder transport: the trusted App host owns AlarmManager and
/// the notification channel, so this is a bounded mailbox request, never a
/// Kotlin business decision.
struct C06TodoHostReminderPort: C06TodoReminderPort {
    func arm(plan: C06TodoPlan, owner: C06TodoOwner) async throws -> C06TodoReminderArmResult {
        try await C06CalendarHostMailbox.shared.armTodo(plan: plan, owner: owner)
    }

    func disarm(todoID: UUID, owner: C06TodoOwner) async throws {
        try await C06CalendarHostMailbox.shared.disarmTodo(todoID: todoID, owner: owner)
    }

    func noteReminderShown(todoID: UUID, occurrenceKey: String, epoch: UInt64) async {
        C06CalendarHostMailbox.shared.noteReminderShown(
            todoID: todoID,
            occurrenceKey: occurrenceKey,
            epoch: epoch
        )
    }
}

// MARK: - todo.list

public struct C06TodoListTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var includeCompleted: Bool?
        public var limit: Int?
        public var offset: Int?

        public init(includeCompleted: Bool? = nil, limit: Int? = nil, offset: Int? = nil) {
            self.includeCompleted = includeCompleted
            self.limit = limit
            self.offset = offset
        }
    }
    public static let name = "todo.list"
    public static let toolDescription = "List this App's local todos with stable IDs and revisions. Completed items are hidden unless includeCompleted is true. limit defaults to 50 (maximum 100); the output may contain fewer whole records to fit the response. Use the returned nextOffset for the next page until it is none. Todos are independent user data and are not chat conversation state."
    public static let parametersJSON = #"{"type":"object","properties":{"includeCompleted":{"type":"boolean"},"limit":{"type":"integer","minimum":1,"maximum":100},"offset":{"type":"integer","minimum":0,"maximum":10000}},"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let environment: C06TodoToolEnvironment
    public init(environment: C06TodoToolEnvironment = C06TodoToolEnvironment()) {
        self.environment = environment
    }

    public func validate(_ args: Arguments) throws {
        if let limit = args.limit, !(1...C06TodoWire.maximumList).contains(limit) {
            throw FloeError.validationFailed("limit must be 1...100")
        }
        if let offset = args.offset, offset < 0 || offset > 10_000 {
            throw FloeError.validationFailed("offset must be 0...10000")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let owner = try c06TodoToolOwner(context)
        do {
            let page = try await environment.domain.list(
                owner: owner,
                includeCompleted: args.includeCompleted ?? false,
                limit: args.limit ?? 50,
                offset: args.offset ?? 0
            )
            return ToolExecutionOutput(digesting: Self.pageSummary(
                rows: page.rows, total: page.total, offset: args.offset ?? 0
            ))
        } catch let error as C06TodoError {
            return Self.failure(error)
        }
    }

    /// Fit whole records before the runtime's 4096-character summary clamp.
    /// Advance by records actually emitted, never by the requested page size.
    static func pageSummary(rows: [C06TodoRecord], total: Int, offset: Int) -> String {
        var lines: [String] = []
        var characters = 0
        for record in rows {
            let value = line(record)
            guard characters + value.count + 1 <= 3_840 else { break }
            lines.append(value)
            characters += value.count + 1
        }
        let next = offset + lines.count
        let hasMore = !lines.isEmpty && next < total
        let continuation = hasMore ? String(next) : "none"
        let header = "status=ok kind=todo count=\(lines.count) total=\(total) offset=\(offset) nextOffset=\(continuation)"
        return ([header] + lines).joined(separator: "\n")
    }

    static func line(_ record: C06TodoRecord) -> String {
        var value = "id=\(record.id.uuidString.lowercased()) revision=\(record.revision)"
            + " title=\(String(reflecting: record.title)) completed=\(record.completed)"
        if let due = record.dueAt {
            value += " due=\(C06CalendarDate.iso8601(due)) allDay=\(record.allDay)"
                + " timezone=\(record.dueTimeZone)"
        }
        if record.recurrence.kind != .none {
            value += " recurrence=\(record.recurrence.kind.rawValue)"
                + " interval=\(record.recurrence.interval)"
            if let until = record.recurrence.until {
                value += " until=\(C06CalendarDate.iso8601(until))"
            }
        }
        if let reminder = record.reminderMinutesBefore {
            value += " reminderMinutesBefore=\(reminder)"
        }
        if let shown = record.lastReminderOccurrence {
            value += " lastReminderOccurrence=\(shown)"
        }
        return value
    }

    static func failure(_ error: C06TodoError) -> ToolExecutionOutput {
        ToolExecutionOutput(
            digesting: "status=error code=\(error.code.rawValue) reason=\(error.reason)",
            exitStatus: 1
        )
    }
}

// MARK: - todo.save

public struct C06TodoSaveTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var action: String
        public var id: String?
        public var expectedRevision: Int?
        public var title: String?
        public var notes: String?
        public var dueAt: String?
        public var allDay: Bool?
        public var timezone: String?
        public var recurrence: String?
        public var recurrenceInterval: Int?
        public var recurrenceUntil: String?
        public var reminderMinutesBefore: Int?

        public init(
            action: String,
            id: String? = nil,
            expectedRevision: Int? = nil,
            title: String? = nil,
            notes: String? = nil,
            dueAt: String? = nil,
            allDay: Bool? = nil,
            timezone: String? = nil,
            recurrence: String? = nil,
            recurrenceInterval: Int? = nil,
            recurrenceUntil: String? = nil,
            reminderMinutesBefore: Int? = nil
        ) {
            self.action = action
            self.id = id
            self.expectedRevision = expectedRevision
            self.title = title
            self.notes = notes
            self.dueAt = dueAt
            self.allDay = allDay
            self.timezone = timezone
            self.recurrence = recurrence
            self.recurrenceInterval = recurrenceInterval
            self.recurrenceUntil = recurrenceUntil
            self.reminderMinutesBefore = reminderMinutesBefore
        }
    }
    public static let name = "todo.save"
    public static let toolDescription = "Create or edit a local todo with an optional due time, recurrence and local reminder. update/delete require the exact id and the revision returned by todo.list. The revision is a real CAS: a stale revision is refused instead of overwriting newer data. A reminder is a local notification only; it never starts a model run or an Agent schedule. Creating a reminder requires dueAt. When notification permission or exact-alarm access is missing, the todo is still saved and the reminder state is reported honestly."
    public static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["create","update"]},"id":{"type":"string","format":"uuid"},"expectedRevision":{"type":"integer","minimum":0},"title":{"type":"string","maxLength":512},"notes":{"type":"string","maxLength":8192},"dueAt":{"type":"string","maxLength":64},"allDay":{"type":"boolean"},"timezone":{"type":"string","maxLength":64},"recurrence":{"type":"string","enum":["none","daily","weekly","monthly"]},"recurrenceInterval":{"type":"integer","minimum":1,"maximum":365},"recurrenceUntil":{"type":"string","maxLength":64},"reminderMinutesBefore":{"type":"integer","minimum":0,"maximum":525600}},"required":["action","title"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .internalState

    private let environment: C06TodoToolEnvironment
    public init(environment: C06TodoToolEnvironment = C06TodoToolEnvironment()) {
        self.environment = environment
    }

    public func validate(_ args: Arguments) throws {
        guard ["create", "update"].contains(args.action) else {
            throw FloeError.validationFailed("Unsupported todo action")
        }
        guard let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            throw FloeError.validationFailed("title is required")
        }
        if args.action == "update" {
            guard args.id.flatMap(UUID.init(uuidString:)) != nil,
                  args.expectedRevision != nil else {
                throw FloeError.validationFailed("update requires id and expectedRevision")
            }
        }
        if args.reminderMinutesBefore != nil && args.dueAt == nil {
            throw FloeError.validationFailed("A reminder requires dueAt")
        }
        if let raw = args.recurrence,
           C06TodoRecurrenceKind(rawValue: raw) == nil {
            throw FloeError.validationFailed("Unknown recurrence")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        let owner = try c06TodoToolOwner(context)
        let kind = args.recurrence.flatMap(C06TodoRecurrenceKind.init(rawValue:)) ?? .none
        let recurrence = C06TodoRecurrence(
            kind: kind,
            interval: args.recurrenceInterval ?? 1,
            until: try args.recurrenceUntil.map(C06CalendarDate.parseISO8601)
        )
        do {
            let result = try await environment.domain.save(
                owner: owner,
                id: args.id.flatMap(UUID.init(uuidString:)),
                expectedRevision: args.expectedRevision,
                title: args.title ?? "",
                notes: args.notes ?? "",
                dueAt: try args.dueAt.map(C06CalendarDate.parseISO8601),
                allDay: args.allDay ?? false,
                timeZone: args.timezone,
                recurrence: recurrence,
                reminderMinutesBefore: args.reminderMinutesBefore
            )
            var value = "status=ok action=\(args.action)"
                + " id=\(result.record.id.uuidString.lowercased())"
                + " revision=\(result.record.revision)"
                + " reminderState=\(result.reminder.state)"
            if let plan = result.plan {
                value += " reminderAt=\(C06CalendarDate.iso8601(plan.reminderAt))"
                    + " occurrence=\(plan.occurrenceKey)"
            }
            if let reason = result.reminder.reason { value += " reminderReason=\(reason)" }
            return ToolExecutionOutput(digesting: value)
        } catch let error as C06TodoError {
            return C06TodoListTool.failure(error)
        }
    }
}

// MARK: - todo.complete

public struct C06TodoCompleteTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var id: String
        public var expectedRevision: Int
        public var completed: Bool?
        public init(id: String, expectedRevision: Int, completed: Bool? = nil) {
            self.id = id
            self.expectedRevision = expectedRevision
            self.completed = completed
        }
    }
    public static let name = "todo.complete"
    public static let toolDescription = "Complete or reopen a local todo with an exact revision CAS. Completing cancels its owned reminder; reopening recomputes the next future reminder from the stored due/recurrence. A stale revision is refused."
    public static let parametersJSON = #"{"type":"object","properties":{"id":{"type":"string","format":"uuid"},"expectedRevision":{"type":"integer","minimum":1},"completed":{"type":"boolean"}},"required":["id","expectedRevision"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .internalState

    private let environment: C06TodoToolEnvironment
    public init(environment: C06TodoToolEnvironment = C06TodoToolEnvironment()) {
        self.environment = environment
    }

    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.id) != nil, args.expectedRevision >= 1 else {
            throw FloeError.validationFailed("id and expectedRevision are required")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        let owner = try c06TodoToolOwner(context)
        do {
            let result = try await environment.domain.complete(
                owner: owner,
                id: UUID(uuidString: args.id)!,
                expectedRevision: args.expectedRevision,
                completed: args.completed ?? true
            )
            var value = "status=ok id=\(result.record.id.uuidString.lowercased())"
                + " revision=\(result.record.revision) completed=\(result.record.completed)"
                + " reminderState=\(result.reminder.state)"
            if let plan = result.plan {
                value += " reminderAt=\(C06CalendarDate.iso8601(plan.reminderAt))"
                    + " occurrence=\(plan.occurrenceKey)"
            }
            return ToolExecutionOutput(digesting: value)
        } catch let error as C06TodoError {
            return C06TodoListTool.failure(error)
        }
    }
}

// MARK: - todo.delete

public struct C06TodoDeleteTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var id: String
        public var expectedRevision: Int
        public init(id: String, expectedRevision: Int) {
            self.id = id
            self.expectedRevision = expectedRevision
        }
    }
    public static let name = "todo.delete"
    public static let toolDescription = "Delete a local todo with an exact revision CAS. Its owned reminder alarm and notification are cancelled. A stale revision is refused; nothing is inferred."
    public static let parametersJSON = #"{"type":"object","properties":{"id":{"type":"string","format":"uuid"},"expectedRevision":{"type":"integer","minimum":1}},"required":["id","expectedRevision"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .internalState

    private let environment: C06TodoToolEnvironment
    public init(environment: C06TodoToolEnvironment = C06TodoToolEnvironment()) {
        self.environment = environment
    }

    public func validate(_ args: Arguments) throws {
        guard UUID(uuidString: args.id) != nil, args.expectedRevision >= 1 else {
            throw FloeError.validationFailed("id and expectedRevision are required")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        let owner = try c06TodoToolOwner(context)
        do {
            try await environment.domain.delete(
                owner: owner,
                id: UUID(uuidString: args.id)!,
                expectedRevision: args.expectedRevision
            )
            return ToolExecutionOutput(
                digesting: "status=ok id=\(args.id.lowercased()) deleted=true revision=\(args.expectedRevision + 1)"
            )
        } catch let error as C06TodoError {
            return C06TodoListTool.failure(error)
        }
    }
}

// MARK: - Tool owner / environment / registration

func c06TodoToolOwner(_ context: ToolContext) throws -> C06TodoOwner {
    guard !context.temporaryReadOnly else {
        throw FloeError.validationFailed("Temporary chat cannot use todos")
    }
    guard let epoch = C06TodoDomain.availability.snapshot.epoch else {
        throw FloeError.validationFailed("Todo runtime is not ready")
    }
    return try C06TodoOwner(
        token: "tool." + context.runID.uuidString,
        nativeEpoch: epoch,
        conversationID: context.conversationID,
        taskID: context.conversationID,
        environmentID: context.environmentID
    )
}

public struct C06TodoToolEnvironment: Sendable {
    public let domain: C06TodoDomain
    public init(domain: C06TodoDomain = .shared) {
        self.domain = domain
    }
}

public func registerC06TodoTools(
    environment: C06TodoToolEnvironment = C06TodoToolEnvironment(),
    registry: ToolRunnerRegistry = .shared
) {
    func add<T: AgentTool>(_ tool: T) {
        ToolCatalog.register(T.self)
        registry.register(AnyAgentTool(tool).withAvailability {
            C06TodoDomain.availability.snapshot.available
        })
    }
    add(C06TodoListTool(environment: environment))
    add(C06TodoSaveTool(environment: environment))
    add(C06TodoCompleteTool(environment: environment))
    add(C06TodoDeleteTool(environment: environment))
}

public func unregisterC06TodoTools(registry: ToolRunnerRegistry = .shared) {
    registry.unregister { C06TodoWire.modelToolNames.contains($0) }
}
