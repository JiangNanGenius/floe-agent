// SPDX-License-Identifier: MPL-2.0
//
// Durable admission and terminal proof for the Mac self-owned runtime.
//
// The host-selected private database keeps one admission row per
// conversation. The row is the cross-instance/restart fence:
//
//   admitting  -> durable claim written, launch transaction not known to
//                 have committed. A crash here is UNKNOWN (no auto replay).
//   prepared   -> SQLiteRunLaunchStore.prepare committed and the exact
//                 identities were verified. No dispatch intent yet.
//   starting   -> dispatch intent was durably recorded. From this point a
//                 crash/timeout is UNKNOWN even if no provider event exists.
//   settledConfirmed   -> a strict durable terminal probe passed.
//   settledUnconfirmed -> the session ended without a strict terminal proof;
//                         automatic retry stays blocked.
//
// Every transition is a compare-and-set on (conversation_id, run_id, epoch)
// inside one short writer transaction. The upstream launch transaction is
// never nested inside these transactions, and no upstream table is altered.

import Foundation
import GRDB
import FloePersistence

/// Durable admission phase. Raw values are persisted; unknown values fail
/// closed rather than being treated as free.
public enum FloeMacSelfAdmissionPhase: String, Sendable, Hashable, CaseIterable {
    case admitting
    case prepared
    case starting
    case settledConfirmed
    case settledUnconfirmed

    public var isUnresolved: Bool {
        switch self {
        case .settledConfirmed: return false
        case .admitting, .prepared, .starting, .settledUnconfirmed: return true
        }
    }
}

/// Read-only projection of one durable admission row. No goal text, provider
/// body, credential or tool output is stored in this table.
public struct FloeMacSelfAdmissionRecord: Sendable, Hashable {
    public let conversationID: UUID
    public let runID: UUID
    public let phase: FloeMacSelfAdmissionPhase
    public let epoch: Int
    public let admittedAt: Date
    public let updatedAt: Date
    public let ownerHostInstanceID: UUID?
    public let ownerProcessIdentifier: Int
    public let stopRequestedAt: Date?
    public let stopEpoch: Int
    public let previousRunID: UUID?
    public let previousPhase: FloeMacSelfAdmissionPhase?
    public let detail: String?

    public init(
        conversationID: UUID,
        runID: UUID,
        phase: FloeMacSelfAdmissionPhase,
        epoch: Int,
        admittedAt: Date,
        updatedAt: Date,
        ownerHostInstanceID: UUID?,
        ownerProcessIdentifier: Int,
        stopRequestedAt: Date?,
        stopEpoch: Int,
        previousRunID: UUID?,
        previousPhase: FloeMacSelfAdmissionPhase?,
        detail: String?
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.phase = phase
        self.epoch = epoch
        self.admittedAt = admittedAt
        self.updatedAt = updatedAt
        self.ownerHostInstanceID = ownerHostInstanceID
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.stopRequestedAt = stopRequestedAt
        self.stopEpoch = stopEpoch
        self.previousRunID = previousRunID
        self.previousPhase = previousPhase
        self.detail = detail
    }
}

enum FloeMacSelfDispatchAdmission: Sendable, Hashable {
    case admitted
    /// Stop intent was already durable; the caller must not dispatch.
    case stopped
    /// The admission row no longer matches this exact attempt.
    case conflict
}

enum FloeMacSelfRunState {
    static let terminalStates: [String] = [
        "completed", "failed", "checkpointed", "interrupted", "cancelled", "canceled"
    ]

    static func isTerminal(_ state: String) -> Bool {
        terminalStates.contains(state)
    }

    static var sqlTerminalList: String {
        terminalStates.map { "'\($0)'" }.joined(separator: ",")
    }
}

enum FloeMacSelfISO8601 {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }
}

/// Strict durable terminal probe. Completion is never inferred from a live
/// event, an in-memory state name, or a merely terminal-looking run row.
///
/// A receipt is confirmed only when:
///   * the run row exists, belongs to the exact conversation, is terminal and
///     has a durable ended_at;
///   * the launch's user message exists (and matches the expected id when the
///     caller supplies one);
///   * a completed run has a terminal event carrying a valid, non-cancelled
///     stopReason, no later status row, and either a verified final assistant
///     message (exact id + run + conversation + assistant role + non-empty
///     content) or the runtime's durable `noFinalText` marker; and
///   * a failed/interrupted/checkpointed/cancelled run has a matching terminal
///     status row with no later status/terminal contradiction.
enum FloeMacSelfDurableRunProbe {
    private struct Event {
        let sequence: Int
        let kind: String
        let payload: [String: Any]?
    }

    static func evaluate(
        db: Database,
        conversationID: UUID,
        runID: UUID,
        expectedUserMessageID: UUID?
    ) throws -> FloeMacSelfTerminalReceipt {
        guard let runRow = try Row.fetchOne(
            db,
            sql: "SELECT state, ended_at FROM runs WHERE id = ? AND conversation_id = ?",
            arguments: [runID.uuidString, conversationID.uuidString]
        ) else {
            return unconfirmed(conversationID: conversationID, runID: runID, state: "unknown", reason: "run_unavailable")
        }
        let state: String = runRow["state"]
        let endedRaw: String? = runRow["ended_at"]
        let endedAt = endedRaw.flatMap(FloeMacSelfISO8601.date)

        guard FloeMacSelfRunState.isTerminal(state) else {
            return unconfirmed(
                conversationID: conversationID,
                runID: runID,
                state: state,
                reason: "run_not_terminal",
                endedAt: endedAt
            )
        }
        guard endedAt != nil else {
            return unconfirmed(
                conversationID: conversationID,
                runID: runID,
                state: state,
                reason: "run_ended_at_missing",
                endedAt: nil
            )
        }

        if let expectedUserMessageID {
            guard let message = try Row.fetchOne(
                db,
                sql: "SELECT role, content, run_id, conversation_id FROM messages WHERE id = ?",
                arguments: [expectedUserMessageID.uuidString]
            ) else {
                return unconfirmed(
                    conversationID: conversationID,
                    runID: runID,
                    state: state,
                    reason: "user_message_mismatch",
                    endedAt: endedAt
                )
            }
            let role: String = message["role"]
            let content: String = message["content"]
            let messageRunID: String? = message["run_id"]
            let messageConversationID: String = message["conversation_id"]
            guard role == "user",
                  !content.isEmpty,
                  messageRunID == runID.uuidString,
                  messageConversationID == conversationID.uuidString else {
                return unconfirmed(
                    conversationID: conversationID,
                    runID: runID,
                    state: state,
                    reason: "user_message_mismatch",
                    endedAt: endedAt
                )
            }
        } else {
            let userMessageCount = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM messages
                    WHERE run_id = ? AND conversation_id = ? AND role = 'user'
                    """,
                arguments: [runID.uuidString, conversationID.uuidString]
            ) ?? 0
            guard userMessageCount > 0 else {
                return unconfirmed(
                    conversationID: conversationID,
                    runID: runID,
                    state: state,
                    reason: "user_message_missing",
                    endedAt: endedAt
                )
            }
        }

        let rawEvents = try Row.fetchAll(
            db,
            sql: """
                SELECT sequence, kind, payload_json FROM run_events
                WHERE run_id = ? ORDER BY sequence DESC LIMIT 512
                """,
            arguments: [runID.uuidString]
        )
        let events = rawEvents.map { row -> Event in
            let sequence: Int = row["sequence"]
            let kind: String = row["kind"]
            let payloadRaw: String = row["payload_json"]
            return Event(sequence: sequence, kind: kind, payload: jsonObject(payloadRaw))
        }

        if state == "completed" {
            return try completedReceipt(
                db: db,
                conversationID: conversationID,
                runID: runID,
                state: state,
                endedAt: endedAt,
                events: events
            )
        }

        var markerSequence: Int?
        var markerPayload: [String: Any]?
        for event in events {
            if event.kind == "terminal" {
                return unconfirmed(
                    conversationID: conversationID,
                    runID: runID,
                    state: state,
                    reason: "terminal_state_conflict",
                    endedAt: endedAt
                )
            }
            if event.kind == "status" {
                if (event.payload?["state"] as? String) == state {
                    markerSequence = event.sequence
                    markerPayload = event.payload
                    break
                }
                return unconfirmed(
                    conversationID: conversationID,
                    runID: runID,
                    state: state,
                    reason: "terminal_state_conflict",
                    endedAt: endedAt
                )
            }
        }
        guard let markerSequence, let markerPayload else {
            return unconfirmed(
                conversationID: conversationID,
                runID: runID,
                state: state,
                reason: "terminal_record_missing",
                endedAt: endedAt
            )
        }

        var outcome: FloeMacSelfTerminalOutcome
        switch state {
        case "failed":
            outcome = (markerPayload["reason"] as? String) == "abortedBeforeDispatch"
                ? .abortedBeforeDispatch
                : .failed
        case "checkpointed", "interrupted":
            outcome = .interrupted
        case "cancelled", "canceled":
            outcome = .cancelled
        default:
            outcome = .unknown
        }

        return FloeMacSelfTerminalReceipt(
            runID: runID,
            conversationID: conversationID,
            outcome: outcome,
            durableRunState: state,
            durableEndedAt: endedAt,
            terminalEventSequence: markerSequence,
            confirmed: true,
            unconfirmedReason: nil,
            finalMessageID: nil,
            finalMessageVerified: false
        )
    }

    private static func completedReceipt(
        db: Database,
        conversationID: UUID,
        runID: UUID,
        state: String,
        endedAt: Date?,
        events: [Event]
    ) throws -> FloeMacSelfTerminalReceipt {
        var terminalSequence: Int?
        var terminalPayload: [String: Any]?
        for event in events {
            if event.kind == "status" {
                return unconfirmed(
                    conversationID: conversationID,
                    runID: runID,
                    state: state,
                    reason: "terminal_state_conflict",
                    endedAt: endedAt
                )
            }
            if event.kind == "terminal" {
                terminalSequence = event.sequence
                terminalPayload = event.payload
                break
            }
        }
        guard let terminalSequence, let terminalPayload else {
            return unconfirmed(
                conversationID: conversationID,
                runID: runID,
                state: state,
                reason: "terminal_record_missing",
                endedAt: endedAt
            )
        }
        guard let rawStopReason = terminalPayload["stopReason"] as? String,
              let stopReason = FloeMacSelfCompletionStopReason(rawValue: rawStopReason),
              stopReason != .cancelled else {
            return unconfirmed(
                conversationID: conversationID,
                runID: runID,
                state: state,
                reason: "terminal_stop_reason_invalid",
                endedAt: endedAt,
                sequence: terminalSequence
            )
        }

        var finalMessageID: UUID?
        var finalMessageVerified = false
        if let rawFinalID = terminalPayload["finalMessageID"] {
            guard let raw = rawFinalID as? String, let id = UUID(uuidString: raw) else {
                return unconfirmed(
                    conversationID: conversationID,
                    runID: runID,
                    state: state,
                    reason: "final_message_id_invalid",
                    endedAt: endedAt,
                    sequence: terminalSequence
                )
            }
            guard let message = try Row.fetchOne(
                db,
                sql: "SELECT role, content, run_id, conversation_id FROM messages WHERE id = ?",
                arguments: [id.uuidString]
            ) else {
                return unconfirmed(
                    conversationID: conversationID,
                    runID: runID,
                    state: state,
                    reason: "final_message_missing",
                    endedAt: endedAt,
                    sequence: terminalSequence
                )
            }
            let role: String = message["role"]
            let content: String = message["content"]
            let messageRunID: String? = message["run_id"]
            let messageConversationID: String = message["conversation_id"]
            guard role == "assistant",
                  !content.isEmpty,
                  messageRunID == runID.uuidString,
                  messageConversationID == conversationID.uuidString else {
                return unconfirmed(
                    conversationID: conversationID,
                    runID: runID,
                    state: state,
                    reason: "final_message_mismatch",
                    endedAt: endedAt,
                    sequence: terminalSequence
                )
            }
            finalMessageID = id
            finalMessageVerified = true
        } else {
            // The explicit marker proves the terminal boundary despite a
            // missing answer. It is not evidence of a successful answer.
            let hasNoFinalTextMarker = events.contains { event in
                guard event.sequence < terminalSequence, event.kind == "error" else { return false }
                return (event.payload?["message"] as? String) == "noFinalText"
            }
            guard hasNoFinalTextMarker else {
                return unconfirmed(
                    conversationID: conversationID,
                    runID: runID,
                    state: state,
                    reason: "final_message_proof_missing",
                    endedAt: endedAt,
                    sequence: terminalSequence
                )
            }
        }

        let outcome: FloeMacSelfTerminalOutcome
        switch stopReason {
        case .endTurn, .stopSequence:
            outcome = finalMessageVerified ? .completed : .unknown
        case .toolUse, .maxTokens, .budgetLimited, .noProgress, .cancelled:
            outcome = .unknown
        }
        return FloeMacSelfTerminalReceipt(
            runID: runID,
            conversationID: conversationID,
            outcome: outcome,
            durableRunState: state,
            durableEndedAt: endedAt,
            terminalEventSequence: terminalSequence,
            confirmed: true,
            unconfirmedReason: nil,
            finalMessageID: finalMessageID,
            finalMessageVerified: finalMessageVerified,
            completionStopReason: stopReason
        )
    }

    private static func unconfirmed(
        conversationID: UUID,
        runID: UUID,
        state: String,
        reason: String,
        endedAt: Date? = nil,
        sequence: Int? = nil
    ) -> FloeMacSelfTerminalReceipt {
        FloeMacSelfTerminalReceipt(
            runID: runID,
            conversationID: conversationID,
            outcome: .unknown,
            durableRunState: state,
            durableEndedAt: endedAt,
            terminalEventSequence: sequence,
            confirmed: false,
            unconfirmedReason: reason,
            finalMessageID: nil,
            finalMessageVerified: false
        )
    }

    static func jsonObject(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func jsonString(_ object: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Owns only the self-core admission/metadata tables in the host-selected
/// private database. It never alters an upstream table or migration.
actor FloeMacSelfAdmissionStore {
    private static let metadataSchemaKey = "admission_schema_version"
    private static let metadataSchemaValue = "1"

    private let database: DatabaseManager
    private let authorityLock: FloeMacSelfAuthorityLock?

    init(database: DatabaseManager, authorityLock: FloeMacSelfAuthorityLock?) {
        self.database = database
        self.authorityLock = authorityLock
    }

    // MARK: - Schema

    static func installSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS floe_mac_self_metadata (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS floe_mac_self_admission (
                conversation_id TEXT PRIMARY KEY NOT NULL,
                run_id TEXT NOT NULL,
                phase TEXT NOT NULL,
                epoch INTEGER NOT NULL,
                admitted_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                owner_host_id TEXT NOT NULL,
                owner_pid INTEGER NOT NULL,
                stop_requested_at REAL,
                stop_epoch INTEGER NOT NULL DEFAULT 0,
                previous_run_id TEXT,
                previous_phase TEXT,
                detail TEXT
            )
            """)
        let requiredColumns: Set<String> = [
            "conversation_id", "run_id", "phase", "epoch", "admitted_at",
            "updated_at", "owner_host_id", "owner_pid", "stop_requested_at",
            "stop_epoch", "previous_run_id", "previous_phase", "detail"
        ]
        let columnRows = try Row.fetchAll(db, sql: "PRAGMA table_info(floe_mac_self_admission)")
        let columns = Set(columnRows.map { row -> String in row["name"] })
        guard requiredColumns.isSubset(of: columns) else {
            throw FloeMacSelfCoreError.authoritySchemaUnsupported("admission_columns")
        }
        let existing = try String.fetchOne(
            db,
            sql: "SELECT value FROM floe_mac_self_metadata WHERE key = ?",
            arguments: [metadataSchemaKey]
        )
        if let existing {
            guard existing == metadataSchemaValue else {
                throw FloeMacSelfCoreError.authoritySchemaUnsupported("admission_version")
            }
        } else {
            try db.execute(
                sql: "INSERT INTO floe_mac_self_metadata (key, value) VALUES (?, ?)",
                arguments: [metadataSchemaKey, metadataSchemaValue]
            )
        }
    }

    // MARK: - Admission lifecycle

    /// A single CAS transaction. A recorded run may be replaced only when the
    /// strict durable terminal probe confirms it and no other non-terminal run
    /// exists for the conversation. Everything else stays unknown.
    func admit(
        conversationID: UUID,
        runID: UUID,
        owner: FloeMacSelfHostIdentity
    ) async throws -> FloeMacSelfAdmissionRecord {
        try verifyAuthority()
        let now = Date().timeIntervalSince1970

        return try await database.writer { db in
            let existing = try Self.fetchRecord(db: db, conversationID: conversationID)
            if let existing {
                guard existing.runID != runID else {
                    throw FloeMacSelfCoreError.conversationBusy(conversationID)
                }
                let previousReceipt = try FloeMacSelfDurableRunProbe.evaluate(
                    db: db,
                    conversationID: conversationID,
                    runID: existing.runID,
                    expectedUserMessageID: nil
                )
                guard previousReceipt.confirmed else {
                    throw FloeMacSelfCoreError.admissionUnknown(conversationID)
                }
                guard try !Self.hasNonTerminalRun(db: db, conversationID: conversationID) else {
                    throw FloeMacSelfCoreError.admissionUnknown(conversationID)
                }
                try db.execute(
                    sql: """
                        UPDATE floe_mac_self_admission
                        SET run_id = ?, phase = 'admitting', epoch = epoch + 1,
                            admitted_at = ?, updated_at = ?, owner_host_id = ?,
                            owner_pid = ?, stop_requested_at = NULL, stop_epoch = 0,
                            previous_run_id = ?, previous_phase = ?, detail = NULL
                        WHERE conversation_id = ? AND run_id = ? AND epoch = ?
                        """,
                    arguments: [
                        runID.uuidString,
                        now,
                        now,
                        owner.hostInstanceID.uuidString,
                        Int(owner.processIdentifier),
                        existing.runID.uuidString,
                        existing.phase.rawValue,
                        conversationID.uuidString,
                        existing.runID.uuidString,
                        existing.epoch
                    ]
                )
                guard db.changesCount == 1 else {
                    throw FloeMacSelfCoreError.admissionConflict(conversationID)
                }
                guard let updated = try Self.fetchRecord(db: db, conversationID: conversationID) else {
                    throw FloeMacSelfCoreError.authorityCorrupted("admission_row_missing")
                }
                return updated
            }

            guard try !Self.hasNonTerminalRun(db: db, conversationID: conversationID) else {
                throw FloeMacSelfCoreError.admissionUnknown(conversationID)
            }
            try db.execute(
                sql: """
                    INSERT INTO floe_mac_self_admission (
                        conversation_id, run_id, phase, epoch, admitted_at,
                        updated_at, owner_host_id, owner_pid, stop_requested_at,
                        stop_epoch, previous_run_id, previous_phase, detail
                    ) VALUES (?, ?, 'admitting', 1, ?, ?, ?, ?, NULL, 0, NULL, NULL, NULL)
                    """,
                arguments: [
                    conversationID.uuidString,
                    runID.uuidString,
                    now,
                    now,
                    owner.hostInstanceID.uuidString,
                    Int(owner.processIdentifier)
                ]
            )
            guard let created = try Self.fetchRecord(db: db, conversationID: conversationID) else {
                throw FloeMacSelfCoreError.authorityCorrupted("admission_row_missing")
            }
            return created
        }
    }

    /// Reclaims the original durable run under a new attempt epoch. The
    /// runtime has already checked the checkpoint and its exact tool wait.
    /// The writer rechecks the admission and run header before changing either
    /// invocation's authority. It never inserts a run or another user turn.
    func admitCheckpointResume(
        previous: FloeMacSelfAdmissionRecord,
        runState: String,
        owner: FloeMacSelfHostIdentity
    ) async throws -> FloeMacSelfAdmissionRecord {
        try verifyAuthority()
        let now = Date().timeIntervalSince1970
        return try await database.writer { db in
            let conversationID = previous.conversationID
            let runID = previous.runID
            let oldHost = previous.ownerHostInstanceID != nil && previous.ownerHostInstanceID != owner.hostInstanceID
            let interruptedReservation = oldHost && previous.detail == "checkpointResume"
            let canReclaimQuestion = runState == "waitingUserQuestion" && oldHost
                && (previous.phase == .starting || interruptedReservation)
            let canReclaimTerminal = ["failed", "interrupted", "checkpointed"].contains(runState)
                && (previous.phase == .settledConfirmed || interruptedReservation)
            guard canReclaimQuestion || canReclaimTerminal,
                  try Self.fetchRecord(db: db, conversationID: conversationID) == previous,
                  previous.stopRequestedAt == nil,
                  try String.fetchOne(db, sql: "SELECT state FROM runs WHERE id = ? AND conversation_id = ?",
                                      arguments: [runID.uuidString, conversationID.uuidString]) == runState,
                  try !Self.hasNonTerminalRun(db: db, conversationID: conversationID, excluding: runID) else {
                throw FloeMacSelfCoreError.admissionConflict(conversationID)
            }
            try db.execute(sql: """
                UPDATE floe_mac_self_admission
                SET phase = 'admitting', epoch = epoch + 1, admitted_at = ?, updated_at = ?,
                    owner_host_id = ?, owner_pid = ?, stop_requested_at = NULL, stop_epoch = 0,
                    previous_run_id = ?, previous_phase = ?, detail = 'checkpointResume'
                WHERE conversation_id = ? AND run_id = ? AND epoch = ?
                """, arguments: [now, now, owner.hostInstanceID.uuidString, Int(owner.processIdentifier),
                                   runID.uuidString, previous.phase.rawValue, conversationID.uuidString, runID.uuidString, previous.epoch])
            guard db.changesCount == 1, let admitted = try Self.fetchRecord(db: db, conversationID: conversationID) else {
                throw FloeMacSelfCoreError.admissionConflict(conversationID)
            }
            return admitted
        }
    }

    /// Only the caller that still holds the undispatched fence may roll back
    /// this reservation. The newer epoch keeps all earlier handles fenced.
    func releaseCheckpointResume(previous: FloeMacSelfAdmissionRecord, epoch: Int) async throws {
        try verifyAuthority()
        let now = Date().timeIntervalSince1970
        let changed = try await database.writer { db in
            try db.execute(sql: """
                UPDATE floe_mac_self_admission
                SET phase = ?, epoch = epoch + 1, admitted_at = ?, updated_at = ?, owner_host_id = ?, owner_pid = ?,
                    stop_requested_at = ?, stop_epoch = ?, previous_run_id = ?, previous_phase = ?, detail = ?
                WHERE conversation_id = ? AND run_id = ? AND epoch = ? AND detail = 'checkpointResume'
                  AND phase IN ('admitting', 'prepared', 'starting')
                """, arguments: [previous.phase.rawValue, previous.admittedAt.timeIntervalSince1970, now,
                                   previous.ownerHostInstanceID?.uuidString, previous.ownerProcessIdentifier,
                                   previous.stopRequestedAt?.timeIntervalSince1970, previous.stopEpoch,
                                   previous.previousRunID?.uuidString, previous.previousPhase?.rawValue, previous.detail,
                                   previous.conversationID.uuidString, previous.runID.uuidString, epoch])
            return db.changesCount == 1
        }
        guard changed else { throw FloeMacSelfCoreError.admissionConflict(previous.conversationID) }
    }

    /// CAS admitting -> prepared after prepare committed and all exact
    /// identities were verified.
    func markPrepared(conversationID: UUID, runID: UUID, epoch: Int) async throws {
        try verifyAuthority()
        let now = Date().timeIntervalSince1970
        let changed = try await database.writer { db in
            try db.execute(
                sql: """
                    UPDATE floe_mac_self_admission
                    SET phase = 'prepared', updated_at = ?
                    WHERE conversation_id = ? AND run_id = ? AND epoch = ? AND phase = 'admitting'
                    """,
                arguments: [now, conversationID.uuidString, runID.uuidString, epoch]
            )
            return db.changesCount == 1
        }
        guard changed else {
            throw FloeMacSelfCoreError.admissionConflict(conversationID)
        }
    }

    /// CAS prepared -> starting. No stop intent may already be durable.
    func requestDispatch(
        conversationID: UUID,
        runID: UUID,
        epoch: Int
    ) async throws -> FloeMacSelfDispatchAdmission {
        try verifyAuthority()
        let now = Date().timeIntervalSince1970
        return try await database.writer { db in
            try db.execute(
                sql: """
                    UPDATE floe_mac_self_admission
                    SET phase = 'starting', updated_at = ?
                    WHERE conversation_id = ? AND run_id = ? AND epoch = ?
                      AND phase = 'prepared' AND stop_requested_at IS NULL
                    """,
                arguments: [now, conversationID.uuidString, runID.uuidString, epoch]
            )
            if db.changesCount == 1 { return .admitted }
            guard let record = try? Self.fetchRecord(db: db, conversationID: conversationID),
                  record.runID == runID,
                  record.epoch == epoch,
                  record.phase == .prepared,
                  record.stopRequestedAt != nil else {
                return .conflict
            }
            return .stopped
        }
    }

    /// Records stop intent durably before any wait. Returns the new stop epoch
    /// when the row was still unresolved; nil when the row is already
    /// settled/replaced. Never clears an admission.
    func recordStopIntent(
        conversationID: UUID,
        runID: UUID,
        epoch: Int
    ) async throws -> Int? {
        try verifyAuthority()
        let now = Date().timeIntervalSince1970
        return try await database.writer { db in
            try db.execute(
                sql: """
                    UPDATE floe_mac_self_admission
                    SET stop_requested_at = COALESCE(stop_requested_at, ?),
                        stop_epoch = stop_epoch + 1,
                        updated_at = ?
                    WHERE conversation_id = ? AND run_id = ? AND epoch = ?
                      AND phase IN ('admitting', 'prepared', 'starting')
                    """,
                arguments: [now, now, conversationID.uuidString, runID.uuidString, epoch]
            )
            guard db.changesCount == 1 else { return nil }
            let value = try Int64.fetchOne(
                db,
                sql: """
                    SELECT stop_epoch FROM floe_mac_self_admission
                    WHERE conversation_id = ? AND run_id = ? AND epoch = ?
                    """,
                arguments: [conversationID.uuidString, runID.uuidString, epoch]
            )
            return value.map(Int.init)
        }
    }

    /// Records a settlement only after the strict probe result is known. A
    /// confirmed settlement may replace an earlier unconfirmed settlement; an
    /// unconfirmed one never overwrites a confirmed row.
    func markSettled(
        conversationID: UUID,
        runID: UUID,
        epoch: Int,
        confirmed: Bool,
        detail: String?
    ) async throws {
        try verifyAuthority()
        let now = Date().timeIntervalSince1970
        let phase = confirmed
            ? FloeMacSelfAdmissionPhase.settledConfirmed.rawValue
            : FloeMacSelfAdmissionPhase.settledUnconfirmed.rawValue
        let allowedPhases = confirmed
            ? "('admitting', 'prepared', 'starting', 'settledUnconfirmed')"
            : "('admitting', 'prepared', 'starting')"
        let boundedDetail = detail.map { String($0.prefix(200)) }
        _ = try await database.writer { db in
            try db.execute(
                sql: """
                    UPDATE floe_mac_self_admission
                    SET phase = ?, updated_at = ?, detail = ?
                    WHERE conversation_id = ? AND run_id = ? AND epoch = ?
                      AND phase IN \(allowedPhases)
                    """,
                arguments: [
                    phase, now, boundedDetail,
                    conversationID.uuidString, runID.uuidString, epoch
                ]
            )
        }
    }

    /// Process-resource release for an unconfirmed close. It never changes
    /// phase, never clears the row and never authorizes a rerun.
    func markProcessReleased(conversationID: UUID, runID: UUID, epoch: Int) async throws {
        try verifyAuthority()
        let now = Date().timeIntervalSince1970
        _ = try await database.writer { db in
            try db.execute(
                sql: """
                    UPDATE floe_mac_self_admission
                    SET updated_at = ?, detail = 'processReleasedUnconfirmed'
                    WHERE conversation_id = ? AND run_id = ? AND epoch = ?
                      AND phase = 'settledUnconfirmed'
                    """,
                arguments: [now, conversationID.uuidString, runID.uuidString, epoch]
            )
        }
    }

    /// Deletes an admitting row only when no durable run or message for that
    /// exact run exists. This is used only for an in-process error before
    /// prepare could commit; a crash leaves the row in place and blocks retry.
    func releasePrePrepare(conversationID: UUID, runID: UUID, epoch: Int) async throws -> Bool {
        try verifyAuthority()
        return try await database.writer { db in
            guard let record = try? Self.fetchRecord(db: db, conversationID: conversationID),
                  record.runID == runID,
                  record.epoch == epoch,
                  record.phase == .admitting else {
                return false
            }
            let runExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM runs WHERE id = ? AND conversation_id = ?)",
                arguments: [runID.uuidString, conversationID.uuidString]
            ) ?? true
            guard !runExists else { return false }
            let messageExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE run_id = ? AND conversation_id = ?)",
                arguments: [runID.uuidString, conversationID.uuidString]
            ) ?? true
            guard !messageExists else { return false }
            try db.execute(
                sql: """
                    DELETE FROM floe_mac_self_admission
                    WHERE conversation_id = ? AND run_id = ? AND epoch = ?
                    """,
                arguments: [conversationID.uuidString, runID.uuidString, epoch]
            )
            return db.changesCount == 1
        }
    }

    /// Explicit host reconciliation for an admission that provably never
    /// reached prepare: phase admitting, no run row, no message row. It is
    /// never called automatically.
    func abandonUnstartedAdmission(
        conversationID: UUID,
        runID: UUID,
        epoch: Int
    ) async throws {
        try verifyAuthority()
        let deleted = try await database.writer { db -> Bool in
            guard let record = try? Self.fetchRecord(db: db, conversationID: conversationID),
                  record.runID == runID,
                  record.epoch == epoch,
                  record.phase == .admitting else {
                return false
            }
            let runExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM runs WHERE id = ? AND conversation_id = ?)",
                arguments: [runID.uuidString, conversationID.uuidString]
            ) ?? true
            guard !runExists else { return false }
            let messageExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE run_id = ? AND conversation_id = ?)",
                arguments: [runID.uuidString, conversationID.uuidString]
            ) ?? true
            guard !messageExists else { return false }
            try db.execute(
                sql: """
                    DELETE FROM floe_mac_self_admission
                    WHERE conversation_id = ? AND run_id = ? AND epoch = ?
                    """,
                arguments: [conversationID.uuidString, runID.uuidString, epoch]
            )
            return db.changesCount == 1
        }
        guard deleted else {
            throw FloeMacSelfCoreError.admissionUnknown(conversationID)
        }
    }

    /// Terminal settlement for a prepared run that provably never dispatched.
    ///
    /// The caller supplies `dispatchCommitted == false` from the live fence.
    /// This function still verifies that the durable run is exactly
    /// `preparing`, has only `preparing` status rows, and has no assistant
    /// message or tool/usage/terminal event. Only then does it append the
    /// composition's `abortedBeforeDispatch` failed terminal status and update
    /// the run row. It is never used after a dispatch could have begun.
    func abandonBeforeDispatch(
        conversationID: UUID,
        runID: UUID,
        epoch: Int,
        reason: String,
        dispatchCommitted: Bool
    ) async throws -> FloeMacSelfTerminalReceipt {
        try verifyAuthority()
        guard !dispatchCommitted else {
            throw FloeMacSelfCoreError.admissionConflict(conversationID)
        }
        let now = Date()
        return try await database.writer { db in
            guard let record = try? Self.fetchRecord(db: db, conversationID: conversationID),
                  record.runID == runID,
                  record.epoch == epoch,
                  record.phase == .admitting || record.phase == .prepared || record.phase == .starting else {
                throw FloeMacSelfCoreError.admissionConflict(conversationID)
            }
            guard let runRow = try Row.fetchOne(
                db,
                sql: "SELECT state FROM runs WHERE id = ? AND conversation_id = ?",
                arguments: [runID.uuidString, conversationID.uuidString]
            ) else {
                throw FloeMacSelfCoreError.admissionConflict(conversationID)
            }
            let runState: String = runRow["state"]
            guard runState == "preparing" else {
                throw FloeMacSelfCoreError.admissionConflict(conversationID)
            }

            let eventRows = try Row.fetchAll(
                db,
                sql: "SELECT kind, payload_json FROM run_events WHERE run_id = ? ORDER BY sequence",
                arguments: [runID.uuidString]
            )
            guard !eventRows.isEmpty else {
                throw FloeMacSelfCoreError.admissionConflict(conversationID)
            }
            var sawPreparingStatus = false
            for row in eventRows {
                let kind: String = row["kind"]
                let payload: String = row["payload_json"]
                guard kind == "status",
                      let object = FloeMacSelfDurableRunProbe.jsonObject(payload),
                      (object["state"] as? String) == "preparing" else {
                    throw FloeMacSelfCoreError.admissionConflict(conversationID)
                }
                sawPreparingStatus = true
            }
            guard sawPreparingStatus else {
                throw FloeMacSelfCoreError.admissionConflict(conversationID)
            }

            let assistantCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages WHERE run_id = ? AND role = 'assistant'",
                arguments: [runID.uuidString]
            ) ?? 0
            guard assistantCount == 0 else {
                throw FloeMacSelfCoreError.admissionConflict(conversationID)
            }
            let userCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM messages WHERE run_id = ? AND role = 'user'",
                arguments: [runID.uuidString]
            ) ?? 0
            guard userCount >= 1 else {
                throw FloeMacSelfCoreError.admissionConflict(conversationID)
            }

            let nextSequence = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sequence), 0) + 1 FROM run_events WHERE run_id = ?",
                arguments: [runID.uuidString]
            ) ?? 1
            let payload = try FloeMacSelfDurableRunProbe.jsonString([
                "state": "failed",
                "reason": "abortedBeforeDispatch"
            ])
            try db.execute(
                sql: """
                    INSERT INTO run_events (id, run_id, sequence, kind, payload_json, created_at)
                    VALUES (?, ?, ?, 'status', ?, ?)
                    """,
                arguments: [
                    UUID().uuidString,
                    runID.uuidString,
                    nextSequence,
                    payload,
                    FloeMacSelfISO8601.string(now)
                ]
            )
            try db.execute(
                sql: """
                    UPDATE runs SET state = 'failed', ended_at = ?
                    WHERE id = ? AND conversation_id = ? AND state = 'preparing'
                    """,
                arguments: [
                    FloeMacSelfISO8601.string(now),
                    runID.uuidString,
                    conversationID.uuidString
                ]
            )
            guard db.changesCount == 1 else {
                throw FloeMacSelfCoreError.admissionConflict(conversationID)
            }
            try db.execute(
                sql: """
                    UPDATE floe_mac_self_admission
                    SET phase = 'settledConfirmed', detail = ?, updated_at = ?
                    WHERE conversation_id = ? AND run_id = ? AND epoch = ?
                    """,
                arguments: [
                    String(reason.prefix(200)),
                    now.timeIntervalSince1970,
                    conversationID.uuidString,
                    runID.uuidString,
                    epoch
                ]
            )
            let receipt = try FloeMacSelfDurableRunProbe.evaluate(
                db: db,
                conversationID: conversationID,
                runID: runID,
                expectedUserMessageID: nil
            )
            guard receipt.confirmed else {
                throw FloeMacSelfCoreError.terminalNotConfirmed(runID)
            }
            return receipt
        }
    }

    // MARK: - Reads

    func record(conversationID: UUID) async throws -> FloeMacSelfAdmissionRecord? {
        try verifyAuthority()
        return try await database.reader { db in
            try Self.fetchRecord(db: db, conversationID: conversationID)
        }
    }

    func unresolvedAdmissions() async throws -> [FloeMacSelfAdmissionRecord] {
        try verifyAuthority()
        return try await database.reader { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM floe_mac_self_admission ORDER BY updated_at, conversation_id"
            )
            return try rows
                .map(Self.record(from:))
                .filter { $0.phase != .settledConfirmed }
        }
    }

    func terminalReceipt(
        conversationID: UUID,
        runID: UUID,
        expectedUserMessageID: UUID
    ) async throws -> FloeMacSelfTerminalReceipt {
        try verifyAuthority()
        return try await database.reader { db in
            try FloeMacSelfDurableRunProbe.evaluate(
                db: db,
                conversationID: conversationID,
                runID: runID,
                expectedUserMessageID: expectedUserMessageID
            )
        }
    }

    // MARK: - Helpers

    private func verifyAuthority() throws {
        try authorityLock?.verifyHeld()
    }

    private static func fetchRecord(db: Database, conversationID: UUID) throws -> FloeMacSelfAdmissionRecord? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM floe_mac_self_admission WHERE conversation_id = ?",
            arguments: [conversationID.uuidString]
        ) else {
            return nil
        }
        return try record(from: row)
    }

    private static func record(from row: Row) throws -> FloeMacSelfAdmissionRecord {
        let rawConversationID: String = row["conversation_id"]
        let rawRunID: String = row["run_id"]
        let rawPhase: String = row["phase"]
        guard let conversationID = UUID(uuidString: rawConversationID),
              let runID = UUID(uuidString: rawRunID),
              let phase = FloeMacSelfAdmissionPhase(rawValue: rawPhase) else {
            throw FloeMacSelfCoreError.authorityCorrupted("admission_row")
        }
        let epochValue: Int64 = row["epoch"]
        let admittedValue: Double = row["admitted_at"]
        let updatedValue: Double = row["updated_at"]
        let ownerHostIDRaw: String = row["owner_host_id"]
        let ownerPIDValue: Int64 = row["owner_pid"]
        let stopRequestedValue: Double? = row["stop_requested_at"]
        let stopEpochValue: Int64 = row["stop_epoch"]
        let previousRunIDRaw: String? = row["previous_run_id"]
        let previousPhaseRaw: String? = row["previous_phase"]
        let detail: String? = row["detail"]
        return FloeMacSelfAdmissionRecord(
            conversationID: conversationID,
            runID: runID,
            phase: phase,
            epoch: Int(epochValue),
            admittedAt: Date(timeIntervalSince1970: admittedValue),
            updatedAt: Date(timeIntervalSince1970: updatedValue),
            ownerHostInstanceID: UUID(uuidString: ownerHostIDRaw),
            ownerProcessIdentifier: Int(ownerPIDValue),
            stopRequestedAt: stopRequestedValue.map { Date(timeIntervalSince1970: $0) },
            stopEpoch: Int(stopEpochValue),
            previousRunID: previousRunIDRaw.flatMap(UUID.init(uuidString:)),
            previousPhase: previousPhaseRaw.flatMap(FloeMacSelfAdmissionPhase.init(rawValue:)),
            detail: detail
        )
    }

    private static func hasNonTerminalRun(db: Database, conversationID: UUID, excluding runID: UUID? = nil) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM runs
                    WHERE conversation_id = ? AND id IS NOT ? AND state NOT IN (\(FloeMacSelfRunState.sqlTerminalList))
                )
                """,
            arguments: [conversationID.uuidString, runID?.uuidString]
        ) ?? true
    }
}
