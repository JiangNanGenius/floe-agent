// FloePersistence — durable parent-run dependencies on finite background work.
//
// A run that submits a required finite background job (or starts a long-lived
// service it must wait to become ready) stays NONTERMINAL until that
// dependency resolves. The edge is durable truth — never an in-memory shadow
// of the live job set — so an app relaunch can reconcile honestly: a
// dependency whose job was interrupted resolves as `.interrupted` and the
// resumed model turn is told the outcome is unknown instead of being lied to
// about a completion.
//
// Registration happens immediately after the job's durable row is committed
// (so a crash can never leave a pending dependency with no job) and before the
// submitting run can observe the job as pending. Resolution is exactly-once:
// the conditional UPDATE keeps the FIRST terminal outcome and ignores late
// duplicate callbacks (the job store's completion callback and the launch
// reconciler may both observe the same job).

import Foundation
import GRDB
import FloeCore

/// The dependency's durable state. `pending` is the only nonterminal state.
public enum RunDependencyState: String, Sendable, Codable, CaseIterable, Hashable {
    case pending
    case resolved
    case failed
    case cancelled
    case interrupted

    public var isTerminal: Bool { self != .pending }
}

/// One durable dependency edge. `id` is the background job's UUID so the edge
/// is idempotent under retried submissions of the same call.
public struct RunDependencyRecord: Sendable, Equatable, Identifiable {
    public var jobID: UUID
    public var runID: UUID
    public var conversationID: UUID
    /// `job` for finite work the parent waits to complete; `service` for a
    /// long-lived local service the parent waits to become READY (the service
    /// itself stays running after the wait resolves).
    public var kind: String
    public var state: RunDependencyState
    public var createdAt: Date
    public var resolvedAt: Date?
    public var note: String?

    public var id: UUID { jobID }

    public init(
        jobID: UUID,
        runID: UUID,
        conversationID: UUID,
        kind: String,
        state: RunDependencyState = .pending,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil,
        note: String? = nil
    ) {
        self.jobID = jobID
        self.runID = runID
        self.conversationID = conversationID
        self.kind = kind
        self.state = state
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.note = note
    }
}

public protocol RunDependencyStoring: Sendable {
    func register(_ dependency: RunDependencyRecord) async throws
    /// Marks the dependency terminal once. Returns the durable record (the
    /// first terminal outcome wins; a duplicate resolution is a no-op).
    func resolve(jobID: UUID, state: RunDependencyState, note: String?) async throws -> RunDependencyRecord?
    func pending(runID: UUID) async throws -> [RunDependencyRecord]
    func record(jobID: UUID) async throws -> RunDependencyRecord?
    /// Every pending dependency in the database, for launch reconciliation.
    func allPending() async throws -> [RunDependencyRecord]
}

public actor SQLiteRunDependencyStore: RunDependencyStoring {
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    public func register(_ dependency: RunDependencyRecord) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO run_dependencies (
                    job_id, run_id, conversation_id, kind, state,
                    created_at, resolved_at, note
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(job_id) DO NOTHING
                """, arguments: [
                    dependency.jobID.uuidString,
                    dependency.runID.uuidString,
                    dependency.conversationID.uuidString,
                    dependency.kind,
                    dependency.state.rawValue,
                    PersistenceCodec.encode(dependency.createdAt),
                    dependency.resolvedAt.map(PersistenceCodec.encode),
                    dependency.note
                ])
        }
    }

    @discardableResult
    public func resolve(
        jobID: UUID,
        state: RunDependencyState,
        note: String?
    ) async throws -> RunDependencyRecord? {
        guard state.isTerminal else {
            throw FloeError.validationFailed("A dependency can only resolve to a terminal state")
        }
        return try await database.writer { db in
            // Conditional update: the first terminal outcome wins.
            try db.execute(sql: """
                UPDATE run_dependencies
                SET state = ?, resolved_at = ?, note = ?
                WHERE job_id = ? AND state = 'pending'
                """, arguments: [
                    state.rawValue,
                    PersistenceCodec.encode(Date()),
                    note,
                    jobID.uuidString
                ])
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM run_dependencies WHERE job_id = ?",
                arguments: [jobID.uuidString]
            ) else { return nil }
            return try Self.decode(row)
        }
    }

    public func pending(runID: UUID) async throws -> [RunDependencyRecord] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM run_dependencies
                WHERE run_id = ? AND state = 'pending'
                ORDER BY created_at, job_id
                """, arguments: [runID.uuidString]).map { try Self.decode($0) }
        }
    }

    public func record(jobID: UUID) async throws -> RunDependencyRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM run_dependencies WHERE job_id = ?",
                arguments: [jobID.uuidString]
            ) else { return nil }
            return try Self.decode(row)
        }
    }

    public func allPending() async throws -> [RunDependencyRecord] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM run_dependencies WHERE state = 'pending'
                ORDER BY created_at, job_id
                """).map { try Self.decode($0) }
        }
    }

    private static func decode(_ row: Row) throws -> RunDependencyRecord {
        guard let jobID = UUID(uuidString: row["job_id"]),
              let runID = UUID(uuidString: row["run_id"]),
              let conversationID = UUID(uuidString: row["conversation_id"]),
              let kind: String = row["kind"],
              let state = RunDependencyState(rawValue: row["state"]),
              let createdAt = try? PersistenceCodec.decodeDate(row["created_at"]) else {
            throw FloeError.storageCorrupted("Invalid run dependency row")
        }
        let resolvedRaw: String? = row["resolved_at"]
        return RunDependencyRecord(
            jobID: jobID,
            runID: runID,
            conversationID: conversationID,
            kind: kind,
            state: state,
            createdAt: createdAt,
            resolvedAt: resolvedRaw.flatMap { try? PersistenceCodec.decodeDate($0) },
            note: row["note"]
        )
    }
}
