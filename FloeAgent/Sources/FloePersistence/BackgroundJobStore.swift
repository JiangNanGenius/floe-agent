import Foundation
import GRDB
import FloeCore

public enum BackgroundJobState: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case completed
    case failed
    case cancelled
    /// The process exited while the job was non-terminal; nothing ran to
    /// completion and the payload was never resumed. Safe to resubmit.
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: return true
        case .queued, .running: return false
        }
    }

    public func canTransition(to next: BackgroundJobState) -> Bool {
        switch (self, next) {
        case (.queued, .running), (.queued, .cancelled), (.queued, .interrupted),
             (.running, .completed), (.running, .failed), (.running, .cancelled), (.running, .interrupted):
            return true
        default:
            return false
        }
    }
}

public enum BackgroundJobKind: String, Codable, Sendable {
    /// Executes a registered in-process tool runner off the run's critical path.
    case tool
    /// Background URLSession download that survives app suspension.
    case download
}

/// A durable, model-visible background unit of work. The payload is the exact
/// arguments JSON of the target tool; secrets must remain credential
/// references because this table is not a secret store.
public struct BackgroundJob: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var runID: UUID
    public var toolCallID: String?
    public var kind: BackgroundJobKind
    public var targetTool: String
    public var payloadJSON: Data
    public var state: BackgroundJobState
    public var progressJSON: Data?
    public var resultSummary: String?
    public var resultDigest: String?
    public var resultPath: String?
    public var lastError: String?
    public var workspaceRootPath: String?
    public var environmentID: String?
    public var retryCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        runID: UUID,
        toolCallID: String? = nil,
        kind: BackgroundJobKind,
        targetTool: String,
        payloadJSON: Data,
        state: BackgroundJobState = .queued,
        progressJSON: Data? = nil,
        resultSummary: String? = nil,
        resultDigest: String? = nil,
        resultPath: String? = nil,
        lastError: String? = nil,
        workspaceRootPath: String? = nil,
        environmentID: String? = nil,
        retryCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.runID = runID
        self.toolCallID = toolCallID
        self.kind = kind
        self.targetTool = targetTool
        self.payloadJSON = payloadJSON
        self.state = state
        self.progressJSON = progressJSON
        self.resultSummary = resultSummary
        self.resultDigest = resultDigest
        self.resultPath = resultPath
        self.lastError = lastError
        self.workspaceRootPath = workspaceRootPath
        self.environmentID = environmentID
        self.retryCount = retryCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

public enum BackgroundJobStoreError: Error, Sendable, Equatable {
    case invalidStateTransition(from: BackgroundJobState, to: BackgroundJobState)
    case missingJob(UUID)
}

/// Transactional persistence for jobs.* background work. Submitting the same
/// (runID, toolCallID) twice returns the original job, never a duplicate.
public actor BackgroundJobStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    @discardableResult
    public func save(_ job: BackgroundJob) async throws -> BackgroundJob {
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO background_jobs (
                    id, conversation_id, run_id, tool_call_id, kind, target_tool,
                    payload_json, state, progress_json, result_summary,
                    result_digest, result_path, last_error,
                    workspace_root_path, environment_id, retry_count,
                    created_at, updated_at, completed_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    state=excluded.state, progress_json=excluded.progress_json,
                    result_summary=excluded.result_summary, result_digest=excluded.result_digest,
                    result_path=excluded.result_path, last_error=excluded.last_error,
                    retry_count=excluded.retry_count,
                    updated_at=excluded.updated_at, completed_at=excluded.completed_at
                """, arguments: [
                    job.id.uuidString, job.conversationID.uuidString, job.runID.uuidString,
                    job.toolCallID, job.kind.rawValue, job.targetTool, job.payloadJSON,
                    job.state.rawValue, job.progressJSON, job.resultSummary, job.resultDigest,
                    job.resultPath, job.lastError, job.workspaceRootPath, job.environmentID, job.retryCount,
                    job.createdAt, job.updatedAt, job.completedAt
                ])
        }
        return job
    }

    /// Idempotent submit path keyed by the durable tool call. A relaunched or
    /// retried delivery returns the original job instead of enqueueing twice.
    public func submit(_ job: BackgroundJob) async throws -> BackgroundJob {
        if let toolCallID = job.toolCallID,
           let existing = try await self.job(runID: job.runID, toolCallID: toolCallID) {
            return existing
        }
        return try await save(job)
    }

    @discardableResult
    public func transition(
        id: UUID, to state: BackgroundJobState,
        mutate: @Sendable (inout BackgroundJob) -> Void = { _ in }
    ) async throws -> BackgroundJob {
        guard var job = try await job(id: id) else { throw BackgroundJobStoreError.missingJob(id) }
        guard job.state.canTransition(to: state) else {
            throw BackgroundJobStoreError.invalidStateTransition(from: job.state, to: state)
        }
        mutate(&job)
        job.state = state
        job.updatedAt = Date()
        if state.isTerminal { job.completedAt = job.completedAt ?? Date() }
        return try await save(job)
    }

    public func job(id: UUID) async throws -> BackgroundJob? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM background_jobs WHERE id = ?", arguments: [id.uuidString]) else { return nil }
            return try Self.decode(row)
        }
    }

    public func job(runID: UUID, toolCallID: String) async throws -> BackgroundJob? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM background_jobs WHERE run_id = ? AND tool_call_id = ?", arguments: [runID.uuidString, toolCallID]) else { return nil }
            return try Self.decode(row)
        }
    }

    public func jobs(conversationID: UUID, limit: Int = 24) async throws -> [BackgroundJob] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM background_jobs WHERE conversation_id = ?
                ORDER BY created_at DESC LIMIT ?
                """, arguments: [conversationID.uuidString, max(1, min(limit, 100))]).map { try Self.decode($0) }
        }
    }

    /// Non-terminal jobs across all conversations, used to mark interrupted
    /// work after a process restart.
    public func activeJobs(limit: Int = 200) async throws -> [BackgroundJob] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM background_jobs WHERE state IN ('queued','running')
                ORDER BY created_at LIMIT ?
                """, arguments: [max(1, min(limit, 1_000))]).map { try Self.decode($0) }
        }
    }

    /// Maps a run to its owning task, the same join task checklists use.
    public func conversationID(runID: UUID) async throws -> UUID? {
        try await database.reader { db in
            try String.fetchOne(db, sql: "SELECT conversation_id FROM runs WHERE id = ?", arguments: [runID.uuidString])
        }.flatMap(UUID.init(uuidString:))
    }

    private static func decode(_ row: Row) throws -> BackgroundJob {
        guard let id = UUID(uuidString: row["id"]),
              let conversationID = UUID(uuidString: row["conversation_id"]),
              let runID = UUID(uuidString: row["run_id"]),
              let kind = BackgroundJobKind(rawValue: row["kind"]),
              let state = BackgroundJobState(rawValue: row["state"]) else {
            throw FloeError.storageCorrupted("Invalid background job row")
        }
        return BackgroundJob(
            id: id, conversationID: conversationID, runID: runID,
            toolCallID: row["tool_call_id"], kind: kind,
            targetTool: row["target_tool"], payloadJSON: row["payload_json"],
            state: state, progressJSON: row["progress_json"],
            resultSummary: row["result_summary"], resultDigest: row["result_digest"],
            resultPath: row["result_path"], lastError: row["last_error"],
            workspaceRootPath: row["workspace_root_path"], environmentID: row["environment_id"], retryCount: row["retry_count"],
            createdAt: row["created_at"], updatedAt: row["updated_at"],
            completedAt: row["completed_at"]
        )
    }
}
