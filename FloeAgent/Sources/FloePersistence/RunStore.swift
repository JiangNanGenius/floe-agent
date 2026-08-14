// FloePersistence — Run / event-thread / usage / error / checkpoint store.
// See docs/ALPHA_DAILY_PLAN.md (Persistence v3). Append-only event thread;
// no secret-bearing payload is ever persisted.

import Foundation
import GRDB
import FloeCore
import FloeModels

/// A persisted agent run header.
public struct RunRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var state: String
    public var goal: String
    public var startedAt: Date
    public var endedAt: Date?

    public init(
        id: UUID,
        conversationID: UUID,
        state: String,
        goal: String,
        startedAt: Date,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.state = state
        self.goal = goal
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// Durable run + event-thread access. Events are append-only and ordered by
/// a per-run monotonic sequence; checkpoints upsert by run.
public protocol RunStore: Sendable {
    func saveRun(_ run: RunRecord) async throws
    func run(id: UUID) async throws -> RunRecord?
    func runs(conversationID: UUID) async throws -> [RunRecord]
    func updateRunState(id: UUID, state: String, endedAt: Date?) async throws

    /// Appends an event using the next sequence for the run (atomic per writer).
    @discardableResult
    func appendEvent(runID: UUID, kind: RunEventRecord.Kind, payloadJSON: String) async throws -> RunEventRecord
    func events(runID: UUID) async throws -> [RunEventRecord]

    func recordUsage(_ usage: RunUsageRecord) async throws
    func usage(runID: UUID) async throws -> [RunUsageRecord]

    func recordError(_ error: RunErrorRecord) async throws
    func errors(runID: UUID) async throws -> [RunErrorRecord]

    func saveCheckpoint(runID: UUID, conversationID: UUID, formatVersion: Int, state: String, bodyJSON: String) async throws
    func checkpointBody(runID: UUID) async throws -> String?
    func deleteCheckpoint(runID: UUID) async throws
}

/// SQLite/GRDB implementation of `RunStore`.
public actor SQLiteRunStore: RunStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func saveRun(_ run: RunRecord) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO runs (id, conversation_id, state, goal, started_at, ended_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        state = excluded.state,
                        goal = excluded.goal,
                        ended_at = excluded.ended_at
                    """,
                arguments: [
                    run.id.uuidString,
                    run.conversationID.uuidString,
                    run.state,
                    run.goal,
                    PersistenceCodec.encode(run.startedAt),
                    run.endedAt.map(PersistenceCodec.encode)
                ]
            )
        }
    }

    public func run(id: UUID) async throws -> RunRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM runs WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.run(from: row)
        }
    }

    public func runs(conversationID: UUID) async throws -> [RunRecord] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM runs WHERE conversation_id = ? ORDER BY started_at DESC, id",
                arguments: [conversationID.uuidString]
            ).map(Self.run(from:))
        }
    }

    public func updateRunState(id: UUID, state: String, endedAt: Date?) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "UPDATE runs SET state = ?, ended_at = ? WHERE id = ?",
                arguments: [state, endedAt.map(PersistenceCodec.encode), id.uuidString]
            )
        }
    }

    @discardableResult
    public func appendEvent(runID: UUID, kind: RunEventRecord.Kind, payloadJSON: String) async throws -> RunEventRecord {
        try await database.writer { db in
            let next = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM run_events WHERE run_id = ?",
                arguments: [runID.uuidString]
            ) ?? 1
            let record = RunEventRecord(
                runID: runID,
                sequence: next,
                kind: kind,
                payloadJSON: payloadJSON
            )
            try db.execute(
                sql: """
                    INSERT INTO run_events (id, run_id, sequence, kind, payload_json, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id.uuidString,
                    runID.uuidString,
                    record.sequence,
                    record.kind.rawValue,
                    record.payloadJSON,
                    PersistenceCodec.encode(record.createdAt)
                ]
            )
            return record
        }
    }

    public func events(runID: UUID) async throws -> [RunEventRecord] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM run_events WHERE run_id = ? ORDER BY sequence",
                arguments: [runID.uuidString]
            ).map(Self.event(from:))
        }
    }

    public func recordUsage(_ usage: RunUsageRecord) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO run_usage (id, run_id, input_tokens, output_tokens, cost_estimate, recorded_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    usage.id.uuidString,
                    usage.runID.uuidString,
                    usage.inputTokens,
                    usage.outputTokens,
                    usage.costEstimate,
                    PersistenceCodec.encode(usage.recordedAt)
                ]
            )
        }
    }

    public func usage(runID: UUID) async throws -> [RunUsageRecord] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM run_usage WHERE run_id = ? ORDER BY recorded_at, id",
                arguments: [runID.uuidString]
            ).map(Self.usage(from:))
        }
    }

    public func recordError(_ error: RunErrorRecord) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO run_errors (id, run_id, kind, message, http_status, recoverable, recorded_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    error.id.uuidString,
                    error.runID.uuidString,
                    error.kind,
                    error.message,
                    error.httpStatus,
                    error.recoverable,
                    PersistenceCodec.encode(error.recordedAt)
                ]
            )
        }
    }

    public func errors(runID: UUID) async throws -> [RunErrorRecord] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM run_errors WHERE run_id = ? ORDER BY recorded_at, id",
                arguments: [runID.uuidString]
            ).map(Self.error(from:))
        }
    }

    public func saveCheckpoint(
        runID: UUID,
        conversationID: UUID,
        formatVersion: Int,
        state: String,
        bodyJSON: String
    ) async throws {
        let now = PersistenceCodec.encode(Date())
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO checkpoints (run_id, conversation_id, format_version, state, body_json, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(run_id) DO UPDATE SET
                        format_version = excluded.format_version,
                        state = excluded.state,
                        body_json = excluded.body_json,
                        updated_at = excluded.updated_at
                    """,
                arguments: [runID.uuidString, conversationID.uuidString, formatVersion, state, bodyJSON, now, now]
            )
        }
    }

    public func checkpointBody(runID: UUID) async throws -> String? {
        try await database.reader { db in
            try String.fetchOne(
                db,
                sql: "SELECT body_json FROM checkpoints WHERE run_id = ?",
                arguments: [runID.uuidString]
            )
        }
    }

    public func deleteCheckpoint(runID: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM checkpoints WHERE run_id = ?", arguments: [runID.uuidString])
        }
    }

    // MARK: - Row mapping

    private static func run(from row: Row) throws -> RunRecord {
        guard
            let id = UUID(uuidString: row["id"]),
            let conversationID = UUID(uuidString: row["conversation_id"])
        else {
            throw FloeError.storageCorrupted("Invalid run identifiers")
        }
        let endedAt: Date? = try (row["ended_at"] as String?).map(PersistenceCodec.decodeDate)
        return RunRecord(
            id: id,
            conversationID: conversationID,
            state: row["state"],
            goal: row["goal"],
            startedAt: try PersistenceCodec.decodeDate(row["started_at"]),
            endedAt: endedAt
        )
    }

    private static func event(from row: Row) throws -> RunEventRecord {
        guard
            let id = UUID(uuidString: row["id"]),
            let runID = UUID(uuidString: row["run_id"]),
            let kind = RunEventRecord.Kind(rawValue: row["kind"])
        else {
            throw FloeError.storageCorrupted("Invalid run event")
        }
        return RunEventRecord(
            id: id,
            runID: runID,
            sequence: row["sequence"],
            kind: kind,
            payloadJSON: row["payload_json"],
            createdAt: try PersistenceCodec.decodeDate(row["created_at"])
        )
    }

    private static func usage(from row: Row) throws -> RunUsageRecord {
        guard
            let id = UUID(uuidString: row["id"]),
            let runID = UUID(uuidString: row["run_id"])
        else {
            throw FloeError.storageCorrupted("Invalid usage record")
        }
        return RunUsageRecord(
            id: id,
            runID: runID,
            inputTokens: row["input_tokens"],
            outputTokens: row["output_tokens"],
            costEstimate: row["cost_estimate"],
            recordedAt: try PersistenceCodec.decodeDate(row["recorded_at"])
        )
    }

    private static func error(from row: Row) throws -> RunErrorRecord {
        guard
            let id = UUID(uuidString: row["id"]),
            let runID = UUID(uuidString: row["run_id"])
        else {
            throw FloeError.storageCorrupted("Invalid error record")
        }
        return RunErrorRecord(
            id: id,
            runID: runID,
            kind: row["kind"],
            message: row["message"],
            httpStatus: row["http_status"],
            recoverable: row["recoverable"],
            recordedAt: try PersistenceCodec.decodeDate(row["recorded_at"])
        )
    }
}
