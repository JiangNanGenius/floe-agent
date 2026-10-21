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

// MARK: - Durable child checkpoints (S7 audit17)

/// Which safe boundary produced the checkpoint. `preCall` is persisted AFTER
/// the provider requested tools and BEFORE any side effect crosses the
/// executor boundary; `postCall` is persisted AFTER the tools settled and
/// BEFORE the next provider request. A resumed child therefore never has to
/// guess whether an in-flight call ran: either its real result is durable
/// (`postCall`) or its intent is (`preCall`, resolved by the explicit
/// recovery-hold contract at resume).
public enum ChildRunCheckpointKind: String, Sendable, Codable, Equatable {
    case preCall
    case postCall
}

/// Bounded, always-legal-JSON snapshot of one child loop's continuation
/// state. This is DATA, never authority: no dispatcher, grant, credential or
/// runtime handle is ever persisted here. The resuming parent revalidates
/// rights/environment/model/tool availability against its OWN live state
/// before any persisted content is used again.
public struct ChildRunCheckpoint: Sendable, Equatable, Codable {
    /// Bump when the persisted shape changes; older revisions are refused
    /// (truthful `unsupportedRevision`), never guessed.
    public static let currentSchemaRevision = 1
    /// Whole-document bound, enforced through the shared payload codec.
    public static let maximumCheckpointBytes = 192 * 1024
    /// Mirrors the child's own wire/request bounds so a checkpoint can never
    /// carry more than the loop itself could hold.
    public static let maximumMessages = 64
    public static let maximumReplayedPairs = 48
    public static let maximumPendingCalls = 16
    public static let maximumReferences = 24

    public struct Message: Sendable, Equatable, Codable {
        public var role: String
        public var content: String
        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    /// Persisted form of one provider tool-call intent (never execution
    /// output): the exact call id the model was given, the tool name and the
    /// bounded argument JSON the durable transcript already persists.
    public struct CallIntent: Sendable, Equatable, Codable {
        public var id: String
        public var toolName: String
        public var argumentsJSON: String
        public init(id: String, toolName: String, argumentsJSON: String) {
            self.id = id
            self.toolName = toolName
            self.argumentsJSON = argumentsJSON
        }
    }

    /// Persisted form of one settled tool result: the REAL status string is
    /// kept verbatim (denied/failed/cancelled included — never rewritten) so
    /// a replayed pair or a fed-back pending pair reads exactly what happened.
    public struct SettledResult: Sendable, Equatable, Codable {
        public var callID: String
        public var status: String
        public var outputSummary: String
        public var outputDigest: String
        public var exitStatus: Int32?
        public init(
            callID: String,
            status: String,
            outputSummary: String,
            outputDigest: String,
            exitStatus: Int32? = nil
        ) {
            self.callID = callID
            self.status = status
            self.outputSummary = outputSummary
            self.outputDigest = outputDigest
            self.exitStatus = exitStatus
        }
    }

    public struct SettledPair: Sendable, Equatable, Codable {
        public var call: CallIntent
        public var result: SettledResult
        public init(call: CallIntent, result: SettledResult) {
            self.call = call
            self.result = result
        }
    }

    /// One archived (call, result, reasoning) triple for the bounded replay
    /// history, same shape the request composer replays on the wire.
    public struct ReplayPair: Sendable, Equatable, Codable {
        public var call: CallIntent
        public var result: SettledResult
        public var assistantReasoning: String?
        public init(
            call: CallIntent,
            result: SettledResult,
            assistantReasoning: String? = nil
        ) {
            self.call = call
            self.result = result
            self.assistantReasoning = assistantReasoning
        }
    }

    /// Persisted child-side discovery state. The offered universe is NOT
    /// stored: it is re-derived from the CURRENT parent's effective ceiling
    /// at resume and intersected with `loadedNames`, so a resumed child can
    /// never carry a schema the current parent does not offer. Names that
    /// drop out of the intersection are listed in `droppedFromRestore` and
    /// surfaced to the model as an explicit note, never silently.
    public struct DiscoveryState: Sendable, Equatable, Codable {
        public var loadedNames: [String]
        public var priorityNames: [String]
        public var revision: Int
        public var droppedFromRestore: [String]
        public init(
            loadedNames: [String],
            priorityNames: [String],
            revision: Int,
            droppedFromRestore: [String] = []
        ) {
            self.loadedNames = loadedNames
            self.priorityNames = priorityNames
            self.revision = revision
            self.droppedFromRestore = droppedFromRestore
        }
    }

    // MARK: Fields

    public var childID: UUID
    public var schemaRevision: Int
    public var kind: ChildRunCheckpointKind
    /// Iterations actually consumed before this checkpoint (never reset on
    /// resume — the spent total survives process death).
    public var iterationsUsed: Int
    /// The EFFECTIVE ceiling the original run computed
    /// (`max(1, min(request.maxIterations, budget.maximumIterations, 20))`).
    /// Resume continues inside this ceiling; no fresh 20-turn budget is ever
    /// minted per resume.
    public var hardCeiling: Int
    public var requestKind: String
    public var task: String
    public var context: String?
    /// The exact bounded conversation the next request would send.
    public var messages: [Message]
    public var replayedPairs: [ReplayPair]
    /// Intent only (preCall) — resolved at resume by the recovery contract.
    public var pendingCalls: [CallIntent]
    /// REAL settled results awaiting first feedback (postCall).
    public var pendingSettled: [SettledPair]
    public var pendingReasoning: String?
    public var discovery: DiscoveryState
    /// Child-local skill revision ledger (ids this child actually read).
    public var skillRevisions: [String: String]
    public var activeSkillIDs: [String]
    public var droppedReplayedPairs: Int
    public var droppedAssistantMessages: Int
    public var truncatedResultOutputs: Int
    public var peerMessagesDelivered: Int
    public var evidence: [String]
    public var pendingRoutes: [String]
    public var lastAssistantText: String
    /// Trusted provenance: which provider/model produced this history. The
    /// resuming parent revalidates against its OWN binding; a switch is
    /// allowed (messages are provider-agnostic text) and recorded.
    public var providerID: String
    public var modelID: String
    /// ORIGINAL historical parent — retained separately from the ACTIVE
    /// authorized resuming parent below. The child run row and its relation
    /// are never rewritten.
    public var originalParentRunID: UUID
    public var rootRunID: UUID
    public var conversationID: UUID
    public var startedAt: Date
    public var savedAt: Date
    // Resume provenance (nil/0 for a checkpoint written by the original run).
    public var resumedParentRunID: UUID?
    public var resumeCount: Int
    /// Calls resolved through the explicit recovery hold at resume (their
    /// effect is unknown; they were NOT re-executed). Persisted so the
    /// transcript can prove the hold happened.
    public var recoveryHoldCallIDs: [String]

    public init(
        childID: UUID,
        schemaRevision: Int = ChildRunCheckpoint.currentSchemaRevision,
        kind: ChildRunCheckpointKind,
        iterationsUsed: Int,
        hardCeiling: Int,
        requestKind: String,
        task: String,
        context: String?,
        messages: [Message],
        replayedPairs: [ReplayPair],
        pendingCalls: [CallIntent],
        pendingSettled: [SettledPair],
        pendingReasoning: String?,
        discovery: DiscoveryState,
        skillRevisions: [String: String],
        activeSkillIDs: [String],
        droppedReplayedPairs: Int,
        droppedAssistantMessages: Int,
        truncatedResultOutputs: Int,
        peerMessagesDelivered: Int,
        evidence: [String],
        pendingRoutes: [String],
        lastAssistantText: String,
        providerID: String,
        modelID: String,
        originalParentRunID: UUID,
        rootRunID: UUID,
        conversationID: UUID,
        startedAt: Date,
        savedAt: Date,
        resumedParentRunID: UUID?,
        resumeCount: Int,
        recoveryHoldCallIDs: [String]
    ) {
        self.childID = childID
        self.schemaRevision = schemaRevision
        self.kind = kind
        self.iterationsUsed = iterationsUsed
        self.hardCeiling = hardCeiling
        self.requestKind = requestKind
        self.task = task
        self.context = context
        self.messages = messages
        self.replayedPairs = replayedPairs
        self.pendingCalls = pendingCalls
        self.pendingSettled = pendingSettled
        self.pendingReasoning = pendingReasoning
        self.discovery = discovery
        self.skillRevisions = skillRevisions
        self.activeSkillIDs = activeSkillIDs
        self.droppedReplayedPairs = droppedReplayedPairs
        self.droppedAssistantMessages = droppedAssistantMessages
        self.truncatedResultOutputs = truncatedResultOutputs
        self.peerMessagesDelivered = peerMessagesDelivered
        self.evidence = evidence
        self.pendingRoutes = pendingRoutes
        self.lastAssistantText = lastAssistantText
        self.providerID = providerID
        self.modelID = modelID
        self.originalParentRunID = originalParentRunID
        self.rootRunID = rootRunID
        self.conversationID = conversationID
        self.startedAt = startedAt
        self.savedAt = savedAt
        self.resumedParentRunID = resumedParentRunID
        self.resumeCount = resumeCount
        self.recoveryHoldCallIDs = recoveryHoldCallIDs
    }
}

/// Lease lifecycle of one checkpoint row. Transitions are compare-and-swap:
/// `none → leased` (acquire, only from an `.interrupted` child with no live
/// lease), `leased → resumed` (the loop actually started), `* → finished`
/// (terminal settle). `reconcileInterruptedOnLaunch` resets stale rows to
/// `none` so a crash mid-resume converges back to resumable.
public enum ChildRunResumeState: String, Sendable, Codable, Equatable {
    case none
    case leased
    case resumed
    case finished
}

/// Checkpoint persistence plus the durable resume lease/CAS boundary.
///
/// `acquireResume` is the ONLY resume entry point and is atomic: it refuses
/// finished children (finished-child refusal), grants the lease to exactly
/// one caller (concurrent resume convergence) and flips the child row back
/// to `running` bound to the ACTUAL current authorized resuming parent — all
/// in one GRDB transaction, so a partial grant can never exist.
public protocol ChildRunCheckpointStoring: Sendable {
    func saveCheckpoint(_ checkpoint: ChildRunCheckpoint) async throws
    func saveCheckpoint(_ checkpoint: ChildRunCheckpoint, owner: UUID, leaseExpiresAt: Date) async throws
    func finishResumedChild(id: UUID, owner: UUID, state: ChildRunState, iterationCount: Int,
                            resultSummary: String?, errorText: String?, digest: String?) async throws
    func checkpoint(childRunID: UUID) async throws -> ChildRunCheckpoint?
    func deleteCheckpoint(childRunID: UUID) async throws

    /// Atomic resume begin. Returns false when the child is not `.interrupted`,
    /// has no checkpoint, or a live lease belongs to another owner.
    @discardableResult
    func acquireResume(
        childRunID: UUID,
        owner: UUID,
        resumingParentRunID: UUID,
        leaseExpiresAt: Date,
        expectedCheckpoint: ChildRunCheckpoint?
    ) async throws -> Bool
    /// Marks a leased resume as actually running. False when the lease was
    /// lost (cancel or concurrent takeover after expiry).
    @discardableResult
    func markResumeStarted(childRunID: UUID, owner: UUID) async throws -> Bool
    /// Renews the lease while a resumed loop is alive (called after each
    /// successful checkpoint save during a resumed run).
    func extendResumeLease(childRunID: UUID, owner: UUID, leaseExpiresAt: Date) async throws
    /// Terminal settle of a resumed run: clears the lease, stamps `finished`.
    func finishResume(childRunID: UUID, owner: UUID) async throws
    /// Explicit pre-start cancellation: releases the lease and restores the
    /// child to `.interrupted` so it stays honestly resumable.
    func cancelResume(childRunID: UUID, owner: UUID) async throws
}

/// Table definition, identical to the v49 migration body so an isolated test
/// database can provision the table without the central migration list.
public enum ChildRunCheckpointSchema {
    public static func apply(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS child_run_checkpoints (
                child_run_id TEXT PRIMARY KEY
                    REFERENCES child_runs(id) ON DELETE CASCADE,
                payload_json TEXT NOT NULL,
                resume_state TEXT NOT NULL DEFAULT 'none'
                    CHECK (resume_state IN ('none', 'leased', 'resumed', 'finished')),
                lease_owner TEXT,
                lease_expires_at TEXT,
                resume_parent_run_id TEXT,
                resume_count INTEGER NOT NULL DEFAULT 0
                    CHECK (resume_count >= 0),
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                CHECK (resume_state != 'leased' OR lease_owner IS NOT NULL),
                CHECK (resume_state != 'resumed' OR lease_owner IS NOT NULL)
            );
            CREATE INDEX IF NOT EXISTS idx_child_run_checkpoints_state
                ON child_run_checkpoints(resume_state, lease_expires_at);
            """)
    }
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
            // A terminal child never resumes: drop its checkpoint row so
            // stale resumable state cannot accumulate (the resumed-run
            // settle also deletes; both are idempotent).
            try db.execute(sql: """
                DELETE FROM child_run_checkpoints WHERE child_run_id = ?
                """, arguments: [id.uuidString])
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
                // Reset any stale resume lease on the now-interrupted child so
                // a crash mid-resume converges back to honestly resumable
                // instead of wedging behind a dead owner's lease.
                try db.execute(sql: """
                    UPDATE child_run_checkpoints
                    SET resume_state = 'none', lease_owner = NULL,
                        lease_expires_at = NULL, resume_parent_run_id = NULL,
                        updated_at = ?
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

// MARK: - Checkpoint store conformance

private enum ChildLeaseRefusal: Error { case unavailable }

extension SQLiteChildRunStore: ChildRunCheckpointStoring {
    fileprivate static let checkpointEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Same fractional-second ISO-8601 the rest of the persistence layer
        // uses, so checkpoint dates round trip identically.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PersistenceCodec.encode(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    fileprivate static let checkpointDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            return try PersistenceCodec.decodeDate(value)
        }
        return decoder
    }()

    /// Exact continuation data must fit its bound; no executable field is clipped.
    static func encodeCheckpoint(_ checkpoint: ChildRunCheckpoint) throws -> String {
        // This is executable continuation state, not a transcript excerpt.
        // Never clip pending arguments, identities, budget or protocol pairs.
        guard checkpoint.pendingCalls.count <= ChildRunCheckpoint.maximumPendingCalls,
              checkpoint.pendingSettled.count <= ChildRunCheckpoint.maximumPendingCalls,
              checkpoint.replayedPairs.count <= ChildRunCheckpoint.maximumReplayedPairs else {
            throw FloeError.validationFailed("Child checkpoint exceeds its protocol pair limit")
        }
        let data = try checkpointEncoder.encode(checkpoint)
        guard data.count <= ChildRunCheckpoint.maximumCheckpointBytes else {
            throw FloeError.validationFailed("Child checkpoint exceeds its exact-state storage limit")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeCheckpoint(_ json: String) throws -> ChildRunCheckpoint {
        guard let data = json.data(using: .utf8), data.count <= ChildRunCheckpoint.maximumCheckpointBytes else {
            throw FloeError.storageCorrupted("Child checkpoint encoding or size is invalid")
        }
        do {
            return try checkpointDecoder.decode(ChildRunCheckpoint.self, from: data)
        } catch {
            throw FloeError.storageCorrupted("Child checkpoint payload is undecodable: \(error)")
        }
    }

    public func saveCheckpoint(_ checkpoint: ChildRunCheckpoint) async throws {
        let bounded = try Self.encodeCheckpoint(checkpoint)
        let now = PersistenceCodec.encode(Date())
        // The lease/CAS columns are owned by acquireResume/markResumeStarted/
        // finishResume/cancelResume; a plain checkpoint save updates the
        // payload only and never rewrites lease state.
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO child_run_checkpoints (
                    child_run_id, payload_json, resume_state, created_at, updated_at
                ) VALUES (?, ?, 'none', ?, ?)
                ON CONFLICT(child_run_id) DO UPDATE SET
                    payload_json = excluded.payload_json,
                    updated_at = excluded.updated_at
                WHERE child_run_checkpoints.lease_owner IS NULL
                """, arguments: [
                    checkpoint.childID.uuidString,
                    bounded,
                    now,
                    now
                ])
            guard db.changesCount == 1 else {
                throw FloeError.storageCorrupted("child checkpoint is owned by a resumed execution")
            }
        }
    }

    public func saveCheckpoint(_ checkpoint: ChildRunCheckpoint, owner: UUID,
                               leaseExpiresAt: Date) async throws {
        let payload = try Self.encodeCheckpoint(checkpoint)
        let now = PersistenceCodec.encode(Date())
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE child_run_checkpoints
                SET payload_json = ?, lease_expires_at = ?, updated_at = ?
                WHERE child_run_id = ? AND lease_owner = ? AND resume_state = 'resumed'
                    AND lease_expires_at > ?
                """, arguments: [payload, PersistenceCodec.encode(leaseExpiresAt), now,
                                 checkpoint.childID.uuidString, owner.uuidString, now])
            guard db.changesCount == 1 else {
                throw FloeError.storageCorrupted("child resume lease expired or changed")
            }
        }
    }

    public func finishResumedChild(id: UUID, owner: UUID, state: ChildRunState,
                                   iterationCount: Int, resultSummary: String?,
                                   errorText: String?, digest: String?) async throws {
        let now = PersistenceCodec.encode(Date())
        try await database.writer { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT child_run_id FROM child_run_checkpoints
                WHERE child_run_id = ? AND lease_owner = ? AND resume_state = 'resumed'
                    AND lease_expires_at > ?
                """, arguments: [id.uuidString, owner.uuidString, now]) else {
                throw FloeError.storageCorrupted("child resume cannot settle without its live lease")
            }
            _ = row
            try db.execute(sql: """
                UPDATE child_runs SET state = ?, iteration_count = ?, ended_at = ?,
                    result_summary = ?, error_text = ?, digest = ?, updated_at = ?
                WHERE id = ? AND state = 'running'
                """, arguments: [state.rawValue, iterationCount, now,
                                 resultSummary.map { Self.boundedSummary($0) }, errorText, digest, now, id.uuidString])
            guard db.changesCount == 1 else {
                throw FloeError.storageCorrupted("child run changed before resumed settlement")
            }
            try db.execute(sql: "UPDATE run_relations SET state = ?, updated_at = ? WHERE child_run_id = ?",
                           arguments: [state.rawValue, now, id.uuidString])
            try db.execute(sql: "DELETE FROM child_run_checkpoints WHERE child_run_id = ? AND lease_owner = ?",
                           arguments: [id.uuidString, owner.uuidString])
        }
    }

    public func checkpoint(childRunID: UUID) async throws -> ChildRunCheckpoint? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT payload_json FROM child_run_checkpoints WHERE child_run_id = ?",
                arguments: [childRunID.uuidString]
            ) else { return nil }
            let json: String = row["payload_json"]
            let checkpoint = try Self.decodeCheckpoint(json)
            guard checkpoint.childID == childRunID else {
                throw FloeError.storageCorrupted("child checkpoint identity differs from its row")
            }
            return checkpoint
        }
    }

    public func deleteCheckpoint(childRunID: UUID) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "DELETE FROM child_run_checkpoints WHERE child_run_id = ?",
                arguments: [childRunID.uuidString]
            )
        }
    }

    public func acquireResume(
        childRunID: UUID,
        owner: UUID,
        resumingParentRunID: UUID,
        leaseExpiresAt: Date,
        expectedCheckpoint: ChildRunCheckpoint? = nil
    ) async throws -> Bool {
        let now = Date()
        do {
            try await database.writer { db in
                if let expectedCheckpoint {
                    guard let payload = try String.fetchOne(db,
                        sql: "SELECT payload_json FROM child_run_checkpoints WHERE child_run_id = ?",
                        arguments: [childRunID.uuidString]),
                          try Self.decodeCheckpoint(payload) == expectedCheckpoint else {
                        throw ChildLeaseRefusal.unavailable
                    }
                }
                let lease = PersistenceCodec.encode(leaseExpiresAt)
                let nowEncoded = PersistenceCodec.encode(now)
                // Lease CAS: grant only when no live lease exists. An expired
                // lease (or a finished/stale row) is re-acquirable — this is
                // what makes a crash mid-resume converge instead of deadlock.
                try db.execute(sql: """
                    UPDATE child_run_checkpoints
                    SET resume_state = 'leased',
                        lease_owner = ?,
                        lease_expires_at = ?,
                        resume_parent_run_id = ?,
                        resume_count = resume_count + 1,
                        updated_at = ?
                    WHERE child_run_id = ?
                        AND (
                            resume_state = 'none'
                            OR resume_state = 'finished'
                            OR lease_expires_at < ?
                        )
                    """, arguments: [
                        owner.uuidString,
                        lease,
                        resumingParentRunID.uuidString,
                        nowEncoded,
                        childRunID.uuidString,
                        nowEncoded
                    ])
                guard db.changesCount > 0 else {
                    throw ChildLeaseRefusal.unavailable
                }
                // Child-state CAS in the SAME transaction: only an interrupted
                // child may resume (finished-child refusal) and the row flips
                // back to running bound to the actual resuming parent. If this
                // fails the lease grant above rolls back with the throw.
                try db.execute(sql: """
                    UPDATE child_runs
                    SET state = 'running', ended_at = NULL, updated_at = ?
                    WHERE id = ? AND state = 'interrupted'
                    """, arguments: [nowEncoded, childRunID.uuidString])
                guard db.changesCount > 0 else {
                    throw ChildLeaseRefusal.unavailable
                }
                try db.execute(sql: "UPDATE run_relations SET state = 'running', updated_at = ? WHERE child_run_id = ?",
                               arguments: [nowEncoded, childRunID.uuidString])
            }
            return true
        } catch ChildLeaseRefusal.unavailable {
            return false
        }
    }

    @discardableResult
    public func markResumeStarted(childRunID: UUID, owner: UUID) async throws -> Bool {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE child_run_checkpoints
                SET resume_state = 'resumed', updated_at = ?
                WHERE child_run_id = ? AND lease_owner = ? AND resume_state = 'leased' AND lease_expires_at > ?
                """, arguments: [
                    PersistenceCodec.encode(Date()),
                    childRunID.uuidString,
                    owner.uuidString,
                    PersistenceCodec.encode(Date())
                ])
            return db.changesCount > 0
        }
    }

    public func extendResumeLease(
        childRunID: UUID,
        owner: UUID,
        leaseExpiresAt: Date
    ) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE child_run_checkpoints
                SET lease_expires_at = ?, updated_at = ?
                WHERE child_run_id = ? AND lease_owner = ?
                    AND resume_state IN ('leased', 'resumed')
                """, arguments: [
                    PersistenceCodec.encode(leaseExpiresAt),
                    PersistenceCodec.encode(Date()),
                    childRunID.uuidString,
                    owner.uuidString
                ])
        }
    }

    public func finishResume(childRunID: UUID, owner: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE child_run_checkpoints
                SET resume_state = 'finished', lease_owner = NULL,
                    lease_expires_at = NULL, updated_at = ?
                WHERE child_run_id = ? AND lease_owner = ?
                """, arguments: [
                    PersistenceCodec.encode(Date()),
                    childRunID.uuidString,
                    owner.uuidString
                ])
        }
    }

    public func cancelResume(childRunID: UUID, owner: UUID) async throws {
        let now = PersistenceCodec.encode(Date())
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE child_run_checkpoints
                SET resume_state = 'none', lease_owner = NULL,
                    lease_expires_at = NULL, resume_parent_run_id = NULL,
                    updated_at = ?
                WHERE child_run_id = ? AND lease_owner = ?
                """, arguments: [now, childRunID.uuidString, owner.uuidString])
            guard db.changesCount == 1 else {
                throw FloeError.storageCorrupted("child resume lease changed before cancellation")
            }
            // Restore the honest interrupted state so the child stays
            // resumable; a child that already moved on (terminal) is left
            // untouched by this second CAS.
            try db.execute(sql: """
                UPDATE child_runs
                SET state = 'interrupted', updated_at = ?
                WHERE id = ? AND state = 'running'
                """, arguments: [now, childRunID.uuidString])
            try db.execute(sql: "UPDATE run_relations SET state = 'interrupted', updated_at = ? WHERE child_run_id = ?",
                           arguments: [now, childRunID.uuidString])
        }
    }
}
