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
    public var goalID: UUID?
    public var providerID: UUID?
    public var modelID: UUID?
    public var providerName: String?
    public var modelName: String?

    public init(
        id: UUID,
        conversationID: UUID,
        state: String,
        goal: String,
        startedAt: Date,
        endedAt: Date? = nil,
        goalID: UUID? = nil,
        providerID: UUID? = nil,
        modelID: UUID? = nil,
        providerName: String? = nil,
        modelName: String? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.state = state
        self.goal = goal
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.goalID = goalID
        self.providerID = providerID
        self.modelID = modelID
        self.providerName = providerName
        self.modelName = modelName
    }
}

/// Durable run + event-thread access. Events are append-only and ordered by
/// a per-run monotonic sequence; checkpoints upsert by run.
public protocol RunStore: Sendable {
    func saveRun(_ run: RunRecord) async throws
    func run(id: UUID) async throws -> RunRecord?
    func runs(conversationID: UUID) async throws -> [RunRecord]
    func updateRunState(id: UUID, state: String, endedAt: Date?) async throws
    func assignGoal(runID: UUID, goalID: UUID) async throws

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

    /// Aggregated usage statistics across all runs.
    func usageStatistics() async throws -> UsageStatistics
}

/// Aggregated token/cost usage across all runs.
public struct UsageStatistics: Sendable, Codable, Hashable {
    public var totalInputTokens: Int
    public var totalOutputTokens: Int
    public var totalTokens: Int
    public var totalRuns: Int
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var reasoningTokens: Int?
    public var byDay: [DailyUsage]
    public var byConversation: [UsageBreakdown]
    public var byModel: [UsageBreakdown]
    public var byProvider: [UsageBreakdown]

    public init(
        totalInputTokens: Int,
        totalOutputTokens: Int,
        totalTokens: Int,
        totalRuns: Int,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        byDay: [DailyUsage],
        byConversation: [UsageBreakdown] = [],
        byModel: [UsageBreakdown] = [],
        byProvider: [UsageBreakdown] = []
    ) {
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.totalTokens = totalTokens
        self.totalRuns = totalRuns
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.byDay = byDay
        self.byConversation = byConversation
        self.byModel = byModel
        self.byProvider = byProvider
    }
}

public struct UsageBreakdown: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var label: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var runs: Int
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var reasoningTokens: Int?

    public init(
        id: String,
        label: String,
        inputTokens: Int,
        outputTokens: Int,
        runs: Int,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.runs = runs
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }

    public var totalTokens: Int { inputTokens + outputTokens }
}

public struct DailyUsage: Sendable, Codable, Hashable, Identifiable {
    public var id: String { date }
    public var date: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var runs: Int

    public init(date: String, inputTokens: Int, outputTokens: Int, runs: Int) {
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.runs = runs
    }
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
                    INSERT INTO runs (
                        id, conversation_id, state, goal, started_at, ended_at, goal_id,
                        provider_id, model_id, provider_name_snapshot, model_name_snapshot
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        state = excluded.state,
                        goal = excluded.goal,
                        ended_at = excluded.ended_at,
                        provider_id = COALESCE(excluded.provider_id, runs.provider_id),
                        model_id = COALESCE(excluded.model_id, runs.model_id),
                        provider_name_snapshot = COALESCE(
                            excluded.provider_name_snapshot, runs.provider_name_snapshot
                        ),
                        model_name_snapshot = COALESCE(
                            excluded.model_name_snapshot, runs.model_name_snapshot
                        )
                    """,
                arguments: [
                    run.id.uuidString,
                    run.conversationID.uuidString,
                    run.state,
                    run.goal,
                    PersistenceCodec.encode(run.startedAt),
                    run.endedAt.map(PersistenceCodec.encode),
                    run.goalID?.uuidString,
                    run.providerID?.uuidString,
                    run.modelID?.uuidString,
                    run.providerName,
                    run.modelName
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

    public func assignGoal(runID: UUID, goalID: UUID) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "UPDATE runs SET goal_id = ? WHERE id = ?",
                arguments: [goalID.uuidString, runID.uuidString]
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
                    INSERT INTO run_usage (
                        id, run_id, input_tokens, output_tokens, cost_estimate, recorded_at,
                        cache_read_tokens, cache_write_tokens, reasoning_tokens, is_estimated
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    usage.id.uuidString,
                    usage.runID.uuidString,
                    usage.inputTokens,
                    usage.outputTokens,
                    usage.costEstimate,
                    PersistenceCodec.encode(usage.recordedAt),
                    usage.cacheReadTokens,
                    usage.cacheWriteTokens,
                    usage.reasoningTokens,
                    usage.isEstimated
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
            endedAt: endedAt,
            goalID: (row["goal_id"] as String?).flatMap(UUID.init(uuidString:)),
            providerID: (row["provider_id"] as String?).flatMap(UUID.init(uuidString:)),
            modelID: (row["model_id"] as String?).flatMap(UUID.init(uuidString:)),
            providerName: row["provider_name_snapshot"],
            modelName: row["model_name_snapshot"]
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
            cacheReadTokens: row["cache_read_tokens"],
            cacheWriteTokens: row["cache_write_tokens"],
            reasoningTokens: row["reasoning_tokens"],
            isEstimated: row["is_estimated"],
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

    public func usageStatistics() async throws -> UsageStatistics {
        try await database.reader { db in
            let totalRow = try Row.fetchOne(db, sql: """
                SELECT
                    COALESCE(SUM(input_tokens), 0) AS total_input,
                    COALESCE(SUM(output_tokens), 0) AS total_output,
                    SUM(cache_read_tokens) AS cache_read,
                    SUM(cache_write_tokens) AS cache_write,
                    SUM(reasoning_tokens) AS reasoning,
                    COUNT(DISTINCT run_id) AS total_runs
                FROM run_usage
                """)
            let totalInput: Int = totalRow?["total_input"] ?? 0
            let totalOutput: Int = totalRow?["total_output"] ?? 0
            let totalRuns: Int = totalRow?["total_runs"] ?? 0
            let cacheRead: Int? = totalRow?["cache_read"]
            let cacheWrite: Int? = totalRow?["cache_write"]
            let reasoning: Int? = totalRow?["reasoning"]

            let dailyRows = try Row.fetchAll(db, sql: """
                SELECT
                    date(recorded_at) AS day,
                    COALESCE(SUM(input_tokens), 0) AS input,
                    COALESCE(SUM(output_tokens), 0) AS output,
                    COUNT(DISTINCT run_id) AS runs
                FROM run_usage
                GROUP BY date(recorded_at)
                ORDER BY day DESC
                LIMIT 30
                """)
            let byDay = dailyRows.map { row in
                DailyUsage(
                    date: row["day"],
                    inputTokens: row["input"],
                    outputTokens: row["output"],
                    runs: row["runs"]
                )
            }

            let conversationRows = try Row.fetchAll(db, sql: """
                SELECT
                    r.conversation_id AS group_id,
                    COALESCE(NULLIF(c.title, ''), '未命名会话') AS label,
                    COALESCE(SUM(u.input_tokens), 0) AS input,
                    COALESCE(SUM(u.output_tokens), 0) AS output,
                    SUM(u.cache_read_tokens) AS cache_read,
                    SUM(u.cache_write_tokens) AS cache_write,
                    SUM(u.reasoning_tokens) AS reasoning,
                    COUNT(DISTINCT r.id) AS runs
                FROM run_usage u
                JOIN runs r ON r.id = u.run_id
                JOIN conversations c ON c.id = r.conversation_id
                GROUP BY r.conversation_id, c.title
                ORDER BY (SUM(u.input_tokens) + SUM(u.output_tokens)) DESC, label
                """)
            let modelRows = try Row.fetchAll(db, sql: """
                SELECT
                    COALESCE(r.model_id, 'legacy-model') AS group_id,
                    COALESCE(
                        MAX(NULLIF(r.model_name_snapshot, '')),
                        '历史任务（模型未记录）'
                    ) AS label,
                    COALESCE(SUM(u.input_tokens), 0) AS input,
                    COALESCE(SUM(u.output_tokens), 0) AS output,
                    SUM(u.cache_read_tokens) AS cache_read,
                    SUM(u.cache_write_tokens) AS cache_write,
                    SUM(u.reasoning_tokens) AS reasoning,
                    COUNT(DISTINCT r.id) AS runs
                FROM run_usage u
                JOIN runs r ON r.id = u.run_id
                GROUP BY COALESCE(r.model_id, 'legacy-model')
                ORDER BY (SUM(u.input_tokens) + SUM(u.output_tokens)) DESC, label
                """)
            let providerRows = try Row.fetchAll(db, sql: """
                SELECT
                    COALESCE(r.provider_id, 'legacy-provider') AS group_id,
                    COALESCE(
                        MAX(NULLIF(r.provider_name_snapshot, '')),
                        '历史任务（供应商未记录）'
                    ) AS label,
                    COALESCE(SUM(u.input_tokens), 0) AS input,
                    COALESCE(SUM(u.output_tokens), 0) AS output,
                    SUM(u.cache_read_tokens) AS cache_read,
                    SUM(u.cache_write_tokens) AS cache_write,
                    SUM(u.reasoning_tokens) AS reasoning,
                    COUNT(DISTINCT r.id) AS runs
                FROM run_usage u
                JOIN runs r ON r.id = u.run_id
                GROUP BY COALESCE(r.provider_id, 'legacy-provider')
                ORDER BY (SUM(u.input_tokens) + SUM(u.output_tokens)) DESC, label
                """)

            return UsageStatistics(
                totalInputTokens: totalInput,
                totalOutputTokens: totalOutput,
                totalTokens: totalInput + totalOutput,
                totalRuns: totalRuns,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                reasoningTokens: reasoning,
                byDay: byDay,
                byConversation: conversationRows.map(Self.usageBreakdown(from:)),
                byModel: modelRows.map(Self.usageBreakdown(from:)),
                byProvider: providerRows.map(Self.usageBreakdown(from:))
            )
        }
    }

    private static func usageBreakdown(from row: Row) -> UsageBreakdown {
        UsageBreakdown(
            id: row["group_id"],
            label: row["label"],
            inputTokens: row["input"],
            outputTokens: row["output"],
            runs: row["runs"],
            cacheReadTokens: row["cache_read"],
            cacheWriteTokens: row["cache_write"],
            reasoningTokens: row["reasoning"]
        )
    }
}
