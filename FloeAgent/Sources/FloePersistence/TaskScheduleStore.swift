import Foundation
import GRDB
import FloeCore
import FloeModels

public protocol TaskScheduleStore: Sendable {
    func schedules() async throws -> [TaskScheduleRecord]
    func due(at date: Date) async throws -> [TaskScheduleRecord]
    func save(_ schedule: TaskScheduleRecord) async throws
    func markStarted(id: UUID, at date: Date) async throws
    func delete(id: UUID) async throws
}

public actor SQLiteTaskScheduleStore: TaskScheduleStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

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

    public func save(_ schedule: TaskScheduleRecord) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO task_schedules (
                    id, title, prompt, workspace_id, cadence, scheduled_at,
                    weekday, is_enabled, last_started_at, next_expected_at,
                    policy_json, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title, prompt = excluded.prompt,
                    workspace_id = excluded.workspace_id, cadence = excluded.cadence,
                    scheduled_at = excluded.scheduled_at, weekday = excluded.weekday,
                    is_enabled = excluded.is_enabled,
                    next_expected_at = excluded.next_expected_at,
                    policy_json = excluded.policy_json, updated_at = excluded.updated_at
                """, arguments: [
                    schedule.id.uuidString, schedule.title, schedule.prompt,
                    schedule.workspaceID?.uuidString, schedule.cadence.rawValue,
                    PersistenceCodec.encode(schedule.scheduledAt), schedule.weekday,
                    schedule.isEnabled, schedule.lastStartedAt.map(PersistenceCodec.encode),
                    schedule.nextExpectedAt.map(PersistenceCodec.encode), schedule.policyJSON,
                    PersistenceCodec.encode(schedule.createdAt),
                    PersistenceCodec.encode(schedule.updatedAt)
                ])
        }
    }

    public func markStarted(id: UUID, at date: Date) async throws {
        try await database.writer { db in
            guard let cadenceRaw = try String.fetchOne(
                db, sql: "SELECT cadence FROM task_schedules WHERE id = ?",
                arguments: [id.uuidString]
            ), let cadence = TaskScheduleCadence(rawValue: cadenceRaw) else { return }
            let next: Date? = switch cadence {
            case .once: nil
            case .daily: Calendar.current.date(byAdding: .day, value: 1, to: date)
            case .weekly: Calendar.current.date(byAdding: .day, value: 7, to: date)
            }
            try db.execute(sql: """
                UPDATE task_schedules
                SET last_started_at = ?, next_expected_at = ?,
                    is_enabled = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [
                    PersistenceCodec.encode(date), next.map(PersistenceCodec.encode),
                    cadence == .once ? false : true, PersistenceCodec.encode(date), id.uuidString
                ])
        }
    }

    public func delete(id: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM task_schedules WHERE id = ?", arguments: [id.uuidString])
        }
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
            policyJSON: row["policy_json"], createdAt: createdAt, updatedAt: updatedAt
        )
        // A disabled one-time schedule deliberately stores NULL. The public
        // initializer defaults a newly-created schedule to scheduledAt, so
        // restore the database's explicit nil after construction.
        record.nextExpectedAt = nextRaw.flatMap { try? PersistenceCodec.decodeDate($0) }
        return record
    }
}
