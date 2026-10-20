// FloePersistence — durable delegated-child identity and bounded transcript.
//
// A delegated child is NOT an ordinary conversation run: it has no separate
// conversation and must never appear in the parent conversation's run list.
// It therefore lives in its own tables (`child_runs`, `child_run_entries`)
// plus one `run_relations` row for the parent/child graph, all written
// BEFORE the child's first model turn so a crashed or suspended child is
// recoverable and inspectable instead of vanishing with the process.
//
// The transcript is bounded by construction: entries are appended with a
// per-child monotonic sequence and read back through a paged query that
// tolerates an in-flight writer (sequence gaps are legal; the caller pages
// until `nextSequence` is nil). Nothing here resets or rewrites other
// tables — a migration-level fix only.

import Foundation
import GRDB
import FloeCore

/// The durable child lifecycle. Mirrors `SubagentOutcome.Status` plus the
/// registration/interruption states the store itself owns.
public enum ChildRunState: String, Sendable, Codable, CaseIterable, Hashable {
    /// Identity persisted before the first provider turn.
    case registered
    case running
    case completed
    case partial
    case budgetExhausted
    case cancelled
    case providerError
    case toolError
    /// The process exited while the child was non-terminal; the outcome is
    /// unknown and the transcript is what actually happened, nothing more.
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .registered, .running: false
        default: true
        }
    }
}

/// Kinds of bounded transcript entries. Raw values are persisted; never
/// rename them.
public enum ChildRunEntryKind: String, Sendable, Codable, CaseIterable, Hashable {
    case state
    case message
    case toolRequest
    case toolResult
    case result
    case error
}

public struct ChildRunRecord: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var parentRunID: UUID
    public var rootRunID: UUID
    public var conversationID: UUID
    public var childIndex: Int
    public var kind: String
    public var taskSummary: String
    public var state: ChildRunState
    public var iterationCount: Int
    public var startedAt: Date
    public var endedAt: Date?
    public var resultSummary: String?
    public var errorText: String?
    public var digest: String?
    public var updatedAt: Date
    /// The provider tool-call id of the `delegate` call that created this
    /// child (persisted on `run_relations` as `delegate_call_id` so the
    /// delegate tool card can map callID → child run id).
    public var delegateCallID: String?

    public init(
        id: UUID,
        parentRunID: UUID,
        rootRunID: UUID,
        conversationID: UUID,
        childIndex: Int,
        kind: String,
        taskSummary: String,
        state: ChildRunState = .registered,
        iterationCount: Int = 0,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        resultSummary: String? = nil,
        errorText: String? = nil,
        digest: String? = nil,
        updatedAt: Date = Date(),
        delegateCallID: String? = nil
    ) {
        self.id = id
        self.parentRunID = parentRunID
        self.rootRunID = rootRunID
        self.conversationID = conversationID
        self.childIndex = childIndex
        self.kind = kind
        self.taskSummary = taskSummary
        self.state = state
        self.iterationCount = iterationCount
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.resultSummary = resultSummary
        self.errorText = errorText
        self.digest = digest
        self.updatedAt = updatedAt
        self.delegateCallID = delegateCallID
    }
}

public struct ChildRunEntry: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var childRunID: UUID
    public var sequence: Int
    public var kind: ChildRunEntryKind
    public var payloadJSON: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        childRunID: UUID,
        sequence: Int,
        kind: ChildRunEntryKind,
        payloadJSON: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.childRunID = childRunID
        self.sequence = sequence
        self.kind = kind
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
    }
}

/// One page of child transcript entries. `nextSequence` is the cursor for the
/// next page (nil when the caller has reached the current end — a later
/// append may still add rows).
public struct ChildRunEntryPage: Sendable, Equatable {
    public var entries: [ChildRunEntry]
    public var nextSequence: Int?

    public init(entries: [ChildRunEntry], nextSequence: Int?) {
        self.entries = entries
        self.nextSequence = nextSequence
    }
}

public protocol ChildRunStoring: Sendable {
    /// Persists identity + the parent relation BEFORE the first child turn.
    /// Returns the durable record (idempotent for a retried child id).
    @discardableResult
    func register(_ record: ChildRunRecord) async throws -> ChildRunRecord
    func transition(
        id: UUID,
        state: ChildRunState,
        iterationCount: Int?,
        endedAt: Date?
    ) async throws
    func appendEntry(id: UUID, kind: ChildRunEntryKind, payloadJSON: String) async throws
    func finish(
        id: UUID,
        state: ChildRunState,
        iterationCount: Int,
        resultSummary: String?,
        errorText: String?,
        digest: String?
    ) async throws
    func child(id: UUID) async throws -> ChildRunRecord?
    func children(parentRunID: UUID) async throws -> [ChildRunRecord]
    func children(conversationID: UUID) async throws -> [ChildRunRecord]
    func entries(childRunID: UUID, afterSequence: Int, limit: Int) async throws -> ChildRunEntryPage
    /// Marks non-terminal children interrupted at launch. Returns the count.
    @discardableResult
    func reconcileInterruptedOnLaunch() async throws -> Int
}

public actor SQLiteChildRunStore: ChildRunStoring {
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    @discardableResult
    public func register(_ record: ChildRunRecord) async throws -> ChildRunRecord {
        try await database.writer { db in
            let index: Int
            if let existing = try Row.fetchOne(
                db, sql: "SELECT child_index FROM child_runs WHERE id = ?",
                arguments: [record.id.uuidString]
            ) {
                index = existing["child_index"] ?? record.childIndex
            } else if let next = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(child_index), 0) + 1 FROM child_runs WHERE parent_run_id = ?",
                arguments: [record.parentRunID.uuidString]
            ) {
                index = next
            } else {
                index = 1
            }
            var durable = record
            durable.childIndex = index
            try db.execute(sql: """
                INSERT INTO child_runs (
                    id, parent_run_id, root_run_id, conversation_id, child_index,
                    kind, task_summary, state, iteration_count, started_at,
                    ended_at, result_summary, error_text, digest, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    state = excluded.state,
                    iteration_count = excluded.iteration_count,
                    updated_at = excluded.updated_at
                """, arguments: [
                    durable.id.uuidString,
                    durable.parentRunID.uuidString,
                    durable.rootRunID.uuidString,
                    durable.conversationID.uuidString,
                    durable.childIndex,
                    durable.kind,
                    durable.taskSummary,
                    durable.state.rawValue,
                    durable.iterationCount,
                    PersistenceCodec.encode(durable.startedAt),
                    durable.endedAt.map(PersistenceCodec.encode),
                    durable.resultSummary,
                    durable.errorText,
                    durable.digest,
                    PersistenceCodec.encode(durable.updatedAt)
                ])
            // The relation row is the parent/root/conversation binding; it
            // carries the same identity the run list and inspector read.
            try db.execute(sql: """
                INSERT INTO run_relations (
                    parent_run_id, child_run_id, child_index, task_summary,
                    created_at, root_run_id, conversation_id, state, updated_at,
                    delegate_call_id
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(parent_run_id, child_index) DO UPDATE SET
                    task_summary = excluded.task_summary,
                    root_run_id = excluded.root_run_id,
                    conversation_id = excluded.conversation_id,
                    state = excluded.state,
                    updated_at = excluded.updated_at,
                    delegate_call_id = COALESCE(
                        excluded.delegate_call_id, run_relations.delegate_call_id)
                """, arguments: [
                    durable.parentRunID.uuidString,
                    durable.id.uuidString,
                    durable.childIndex,
                    durable.taskSummary,
                    PersistenceCodec.encode(durable.startedAt),
                    durable.rootRunID.uuidString,
                    durable.conversationID.uuidString,
                    durable.state.rawValue,
                    PersistenceCodec.encode(durable.updatedAt),
                    durable.delegateCallID
                ])
            return durable
        }
    }

    public func transition(
        id: UUID,
        state: ChildRunState,
        iterationCount: Int?,
        endedAt: Date?
    ) async throws {
        let now = Date()
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE child_runs
                SET state = ?,
                    iteration_count = COALESCE(?, iteration_count),
                    ended_at = COALESCE(?, ended_at),
                    updated_at = ?
                WHERE id = ?
                """, arguments: [
                    state.rawValue,
                    iterationCount,
                    endedAt.map(PersistenceCodec.encode),
                    PersistenceCodec.encode(now),
                    id.uuidString
                ])
            try db.execute(sql: """
                UPDATE run_relations SET state = ?, updated_at = ?
                WHERE child_run_id = ?
                """, arguments: [state.rawValue, PersistenceCodec.encode(now), id.uuidString])
        }
    }

    public func appendEntry(id: UUID, kind: ChildRunEntryKind, payloadJSON: String) async throws {
        // Bounded payload: a transcript entry is evidence, never an unbounded
        // dump. Budgeting happens on VALUES and re-encodes real JSON bytes, so
        // every new row stays structurally valid and the tool/callID/status
        // pairing metadata survives. An unrepresentable payload throws instead
        // of being written half-truncated.
        let bounded = try Self.boundedPayload(payloadJSON, kind: kind)
        try await database.writer { db in
            let next = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM child_run_entries WHERE child_run_id = ?",
                arguments: [id.uuidString]
            ) ?? 1
            try db.execute(sql: """
                INSERT INTO child_run_entries (
                    id, child_run_id, sequence, kind, payload_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    UUID().uuidString,
                    id.uuidString,
                    next,
                    kind.rawValue,
                    bounded,
                    PersistenceCodec.encode(Date())
                ])
        }
    }

    public func finish(
        id: UUID,
        state: ChildRunState,
        iterationCount: Int,
        resultSummary: String?,
        errorText: String?,
        digest: String?
    ) async throws {
        let now = Date()
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE child_runs
                SET state = ?, iteration_count = ?, ended_at = ?,
                    result_summary = ?, error_text = ?, digest = ?, updated_at = ?
                WHERE id = ?
                """, arguments: [
                    state.rawValue,
                    iterationCount,
                    PersistenceCodec.encode(now),
                    resultSummary.map { Self.boundedSummary($0) },
                    errorText,
                    digest,
                    PersistenceCodec.encode(now),
                    id.uuidString
                ])
            try db.execute(sql: """
                UPDATE run_relations SET state = ?, updated_at = ?
                WHERE child_run_id = ?
                """, arguments: [state.rawValue, PersistenceCodec.encode(now), id.uuidString])
        }
    }

    public func child(id: UUID) async throws -> ChildRunRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM child_runs WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.decode(row)
        }
    }

    public func children(parentRunID: UUID) async throws -> [ChildRunRecord] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT c.*, rr.delegate_call_id AS delegate_call_id
                FROM child_runs c
                LEFT JOIN run_relations rr ON rr.child_run_id = c.id
                WHERE c.parent_run_id = ?
                ORDER BY c.child_index, c.started_at
                """, arguments: [parentRunID.uuidString]).map(Self.decode)
        }
    }

    public func children(conversationID: UUID) async throws -> [ChildRunRecord] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT c.*, rr.delegate_call_id AS delegate_call_id
                FROM child_runs c
                LEFT JOIN run_relations rr ON rr.child_run_id = c.id
                WHERE c.conversation_id = ?
                ORDER BY c.started_at DESC, c.child_index
                """, arguments: [conversationID.uuidString]).map(Self.decode)
        }
    }

    public func entries(
        childRunID: UUID,
        afterSequence: Int,
        limit: Int
    ) async throws -> ChildRunEntryPage {
        let boundedLimit = min(max(1, limit), 200)
        return try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM child_run_entries
                WHERE child_run_id = ? AND sequence > ?
                ORDER BY sequence
                LIMIT ?
                """, arguments: [childRunID.uuidString, max(0, afterSequence), boundedLimit + 1])
            var entries: [ChildRunEntry] = []
            for row in rows.prefix(boundedLimit) {
                entries.append(try Self.decodeEntry(row))
            }
            return ChildRunEntryPage(
                entries: entries,
                nextSequence: rows.count > boundedLimit ? entries.last?.sequence : nil
            )
        }
    }

    @discardableResult
    public func reconcileInterruptedOnLaunch() async throws -> Int {
        let now = Date()
        return try await database.writer { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT id FROM child_runs WHERE state IN ('registered', 'running')
                """)
            guard !ids.isEmpty else { return 0 }
            for id in ids {
                try db.execute(sql: """
                    UPDATE child_runs
                    SET state = 'interrupted', ended_at = ?, updated_at = ?,
                        error_text = COALESCE(error_text, 'The process exited before this delegated child finished. The transcript is what actually happened; the outcome is unknown.')
                    WHERE id = ?
                    """, arguments: [PersistenceCodec.encode(now), PersistenceCodec.encode(now), id])
                try db.execute(sql: """
                    UPDATE run_relations SET state = 'interrupted', updated_at = ?
                    WHERE child_run_id = ?
                    """, arguments: [PersistenceCodec.encode(now), id])
            }
            return ids.count
        }
    }

    // MARK: - Bounds

    /// 8 KiB per entry, measured on the encoded JSON. Required pairing
    /// metadata is never clipped; an unrepresentable payload throws.
    static func boundedPayload(
        _ payloadJSON: String,
        kind: ChildRunEntryKind,
        limit: Int = ChildRunPayload.maximumEntryBytes
    ) throws -> String {
        try ChildRunPayload.boundedPayload(payloadJSON, kind: kind, limit: limit)
    }

    static func boundedSummary(_ summary: String, limit: Int = 32 * 1024) -> String {
        let bytes = Array(summary.utf8)
        guard bytes.count > limit else { return summary }
        let marker = "\n[truncated: original \(bytes.count) bytes]"
        let keep = max(0, limit - marker.utf8.count)
        return String(decoding: bytes.prefix(keep), as: UTF8.self) + marker
    }

    private static func decode(_ row: Row) throws -> ChildRunRecord {
        guard let id = UUID(uuidString: row["id"]),
              let parentRunID = UUID(uuidString: row["parent_run_id"]),
              let rootRunID = UUID(uuidString: row["root_run_id"]),
              let conversationID = UUID(uuidString: row["conversation_id"]),
              let state = ChildRunState(rawValue: row["state"]),
              let startedAt = try? PersistenceCodec.decodeDate(row["started_at"]),
              let updatedAt = try? PersistenceCodec.decodeDate(row["updated_at"]) else {
            throw FloeError.storageCorrupted("Invalid child run row")
        }
        let endedRaw: String? = row["ended_at"]
        return ChildRunRecord(
            id: id,
            parentRunID: parentRunID,
            rootRunID: rootRunID,
            conversationID: conversationID,
            childIndex: row["child_index"],
            kind: row["kind"],
            taskSummary: row["task_summary"],
            state: state,
            iterationCount: row["iteration_count"],
            startedAt: startedAt,
            endedAt: endedRaw.flatMap { try? PersistenceCodec.decodeDate($0) },
            resultSummary: row["result_summary"],
            errorText: row["error_text"],
            digest: row["digest"],
            updatedAt: updatedAt,
            delegateCallID: row["delegate_call_id"]
        )
    }

    private static func decodeEntry(_ row: Row) throws -> ChildRunEntry {
        guard let id = UUID(uuidString: row["id"]),
              let childRunID = UUID(uuidString: row["child_run_id"]),
              let kind = ChildRunEntryKind(rawValue: row["kind"]),
              let createdAt = try? PersistenceCodec.decodeDate(row["created_at"]) else {
            throw FloeError.storageCorrupted("Invalid child run entry row")
        }
        return ChildRunEntry(
            id: id,
            childRunID: childRunID,
            sequence: row["sequence"],
            kind: kind,
            payloadJSON: row["payload_json"],
            createdAt: createdAt
        )
    }
}
