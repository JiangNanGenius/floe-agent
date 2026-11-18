// SPDX-License-Identifier: MPL-2.0
// Internal transaction primitive; never an authorization or dispatch permit.
import Foundation
import GRDB
import FloePersistence

struct FloeMacSelfPreparedRequestResult: Sendable {
    let replayed: Bool
    let journalID: UUID
    let userMessageID: UUID
}

enum FloeMacSelfPreparedRequestError: Error, Equatable {
    case invalidInput
    case unsupportedScope
    case admissionMismatch
    case missingBinding
    case corruptedBinding
    case runNotStartable
    case dispatchNotRecorded
    case unsupportedSchema
}

/// A narrow pure-text, existing-conversation primitive. The caller must own a
/// trusted SQLite write transaction and provide separately authenticated scope.
/// Labels/principal here are identity assertions, not authentication. Neither
/// the return nor a successful enclosing writer proves final commit when the
/// caller can roll back an enclosing savepoint. Never dispatch from this API.
/// No production installation, entry point, or authority is enabled.
enum FloeMacSelfPreparedRequest {
    private static let schema = """
        CREATE TABLE floe_mac_self_prepared_request (
            request_id TEXT PRIMARY KEY NOT NULL,
            journal_id TEXT NOT NULL UNIQUE,
            user_message_id TEXT NOT NULL UNIQUE
        )
        """

    static func installSchema(in db: Database) throws {
        guard db.isInsideTransaction else { throw FloeMacSelfRequestJournalError.notInsideTransaction }
        let existing = try String.fetchOne(db, sql: "SELECT sql FROM main.sqlite_schema WHERE type='table' AND name='floe_mac_self_prepared_request'")
        if let existing {
            guard existing == schema else { throw FloeMacSelfPreparedRequestError.unsupportedSchema }
        } else {
            try db.execute(sql: schema)
        }
    }

    static func prepare(db: Database, requestID: UUID,
                        scope: FloeMacSelfRequestJournalScope,
                        principal: FloeMacSelfRequestJournalPrincipal,
                        goal: String) throws -> FloeMacSelfPreparedRequestResult {
        guard db.isInsideTransaction else { throw FloeMacSelfRequestJournalError.notInsideTransaction }
        guard try String.fetchOne(db, sql: "SELECT sql FROM main.sqlite_schema WHERE type='table' AND name='floe_mac_self_prepared_request'") == schema else {
            throw FloeMacSelfPreparedRequestError.unsupportedSchema
        }
        guard scope.operation == .startRun else { throw FloeMacSelfPreparedRequestError.unsupportedScope }
        let (canonical, bytes) = try canonicalGoal(goal)
        var result: FloeMacSelfPreparedRequestResult?
        try db.inSavepoint {
            let reservation = try FloeMacSelfRequestJournal.reserve(db: db, requestID: requestID,
                scope: scope, principal: principal, payload: bytes)
            if reservation.disposition == .replayed {
                guard let binding = try readBinding(db: db, requestID: requestID) else {
                    throw FloeMacSelfPreparedRequestError.missingBinding
                }
                try verify(db: db, binding: binding, record: reservation.record, bytes: bytes)
                result = .init(replayed: true, journalID: binding.journalID, userMessageID: binding.messageID)
                return .commit
            }
            // These are consistency checks, not host authentication.
            try verifyAdmission(db: db, scope: scope, principal: principal)
            guard try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM main.conversations c
                    JOIN main.conversation_workspace_ownership o ON o.conversation_id=c.id
                    WHERE c.id=? AND c.mode='chat' AND o.workspace_id=?)
                """, arguments: [scope.conversationID.uuidString, scope.workspaceID.uuidString]) == true else {
                throw FloeMacSelfPreparedRequestError.unsupportedScope
            }
            let prepared = try SQLiteRunLaunchStore.prepare(.init(conversationID: scope.conversationID,
                runID: scope.runID, goal: canonical, workspaceID: scope.workspaceID), in: db)
            guard prepared.conversation.id == scope.conversationID, prepared.workspace.id == scope.workspaceID,
                  prepared.run.id == scope.runID, prepared.userMessage.conversationID == scope.conversationID,
                  prepared.userMessage.runID == scope.runID,
                  Data(prepared.userMessage.content.utf8) == bytes else {
                throw FloeMacSelfPreparedRequestError.corruptedBinding
            }
            try db.execute(sql: """
                INSERT INTO main.floe_mac_self_prepared_request
                (request_id,journal_id,user_message_id)
                VALUES (?,?,?)
                """, arguments: [requestID.uuidString, reservation.record.journalID.uuidString,
                    prepared.userMessage.id.uuidString])
            guard db.changesCount == 1, let binding = try readBinding(db: db, requestID: requestID),
                  let record = try FloeMacSelfRequestJournal.record(db: db, requestID: requestID),
                  record == reservation.record else { throw FloeMacSelfPreparedRequestError.corruptedBinding }
            try verifyAdmission(db: db, scope: scope, principal: principal)
            try verify(db: db, binding: binding, record: record, bytes: bytes)
            result = .init(replayed: false, journalID: binding.journalID, userMessageID: binding.messageID)
            return .commit
        }
        guard let result else { throw FloeMacSelfPreparedRequestError.corruptedBinding }
        return result
    }

    /// Binds the dispatch-intent CAS to the exact previously prepared input.
    /// The supplied principal and scope are consistency assertions, not host
    /// authentication or workspace authorization. The result is provisional
    /// until the outermost transaction commits and cannot authorize execution.
    /// A replay is historical and must never trigger another provider call.
    static func claimBoundStart(db: Database, requestID: UUID,
                                scope: FloeMacSelfRequestJournalScope,
                                principal: FloeMacSelfRequestJournalPrincipal,
                                userMessageID: UUID, goal: String) throws -> FloeMacSelfRequestJournalDispatchReservation {
        guard db.isInsideTransaction else { throw FloeMacSelfRequestJournalError.notInsideTransaction }
        guard scope.operation == .startRun else { throw FloeMacSelfPreparedRequestError.unsupportedScope }
        let (_, bytes) = try canonicalGoal(goal)
        var result: FloeMacSelfRequestJournalDispatchReservation?
        try db.inSavepoint {
            // `reserve` can create a new row; check first so this method never
            // creates an unbound request when no prepared record exists.
            guard try FloeMacSelfRequestJournal.record(db: db, requestID: requestID) != nil else {
                throw FloeMacSelfPreparedRequestError.missingBinding
            }
            let existing = try FloeMacSelfRequestJournal.reserve(db: db, requestID: requestID,
                scope: scope, principal: principal, payload: bytes)
            guard existing.disposition == .replayed,
                  let binding = try readBinding(db: db, requestID: requestID),
                  binding.messageID == userMessageID else {
                throw FloeMacSelfPreparedRequestError.missingBinding
            }
            try verify(db: db, binding: binding, record: existing.record, bytes: bytes)
            // The launch store inserts this narrow request as `preparing`
            // with no ended_at. A historical replay may be terminal and is
            // read-only; only a first claim needs a currently startable run.
            if existing.record.phase == .accepted {
                try verifyStartableRun(db: db, scope: scope)
            }
            let claimed = try FloeMacSelfRequestJournal.commitStartDispatch(db: db, requestID: requestID,
                scope: scope, principal: principal, fingerprint: existing.record.fingerprint)
            // Triggers fired by the CAS may change the input or binding. Such
            // a change must roll back both transitions, even if caught by the
            // caller and the outer transaction subsequently commits.
            let after = try FloeMacSelfRequestJournal.reserve(db: db, requestID: requestID,
                scope: scope, principal: principal, payload: bytes)
            guard after.disposition == .replayed, after.record == claimed.record,
                  let rebound = try readBinding(db: db, requestID: requestID),
                  rebound.journalID == binding.journalID,
                  rebound.messageID == userMessageID else {
                throw FloeMacSelfPreparedRequestError.corruptedBinding
            }
            try verify(db: db, binding: rebound, record: after.record, bytes: bytes)
            if claimed.recorded {
                // The CAS may fire triggers that end or otherwise advance the
                // run; rejecting here rolls back all writes in this savepoint.
                try verifyStartableRun(db: db, scope: scope)
            }
            result = claimed
            return .commit
        }
        guard let result else { throw FloeMacSelfPreparedRequestError.corruptedBinding }
        return result
    }

    /// Reconciles a recorded start against the exact prepared input and
    /// persisted run in one read snapshot. The receipt describes the run.
    /// It does not update the request journal or grant another dispatch.
    static func readBoundStartTerminal(db: Database, requestID: UUID,
                                       scope: FloeMacSelfRequestJournalScope,
                                       principal: FloeMacSelfRequestJournalPrincipal,
                                       userMessageID: UUID,
                                       goal: String) throws -> FloeMacSelfTerminalReceipt {
        guard db.isInsideTransaction else { throw FloeMacSelfRequestJournalError.notInsideTransaction }
        guard scope.operation == .startRun else { throw FloeMacSelfPreparedRequestError.unsupportedScope }
        let (_, bytes) = try canonicalGoal(goal)
        guard try String.fetchOne(db, sql: """
            SELECT sql FROM main.sqlite_schema
            WHERE type='table' AND name='floe_mac_self_prepared_request'
            """) == schema else {
            throw FloeMacSelfPreparedRequestError.unsupportedSchema
        }
        guard let record = try FloeMacSelfRequestJournal.record(db: db, requestID: requestID),
              let binding = try readBinding(db: db, requestID: requestID),
              binding.messageID == userMessageID else {
            throw FloeMacSelfPreparedRequestError.missingBinding
        }
        let version = FloeMacSelfRequestJournal.supportedProtocolVersion
        let fingerprint = try FloeMacSelfRequestJournal.makeFingerprint(
            protocolVersion: version, scope: scope, principal: principal, payload: bytes)
        guard record.protocolVersion == version, record.scope == scope, record.principal == principal,
              record.fingerprint == fingerprint else {
            throw FloeMacSelfPreparedRequestError.corruptedBinding
        }
        guard record.phase == .dispatchMayHaveStarted || record.phase == .unknown,
              record.dispatchRecordedAt != nil else {
            throw FloeMacSelfPreparedRequestError.dispatchNotRecorded
        }
        try verify(db: db, binding: binding, record: record, bytes: bytes)
        return try FloeMacSelfDurableRunProbe.evaluate(
            db: db, conversationID: scope.conversationID, runID: scope.runID,
            expectedUserMessageID: userMessageID)
    }

    private static func canonicalGoal(_ goal: String) throws -> (String, Data) {
        let canonical = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Data(canonical.utf8)
        guard !canonical.isEmpty, !goal.utf8.contains(0),
              bytes.count <= FloeMacSelfRequestJournal.maximumPayloadBytes else {
            throw FloeMacSelfPreparedRequestError.invalidInput
        }
        return (canonical, bytes)
    }

    private static func verifyStartableRun(db: Database, scope: FloeMacSelfRequestJournalScope) throws {
        guard try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM main.runs
                WHERE id=? AND conversation_id=? AND state='preparing' AND ended_at IS NULL)
            """, arguments: [scope.runID.uuidString, scope.conversationID.uuidString]) == true else {
            throw FloeMacSelfPreparedRequestError.runNotStartable
        }
    }

    private static func verifyAdmission(db: Database, scope: FloeMacSelfRequestJournalScope,
                                        principal: FloeMacSelfRequestJournalPrincipal) throws {
        let admission = try Row.fetchOne(db, sql: """
            SELECT run_id,epoch,phase,owner_host_id,owner_pid,stop_requested_at
            FROM main.floe_mac_self_admission WHERE conversation_id=?
            """, arguments: [scope.conversationID.uuidString])
        guard let admission,
              (admission["run_id"] as String?) == scope.runID.uuidString,
              (admission["epoch"] as Int?) == scope.runGeneration,
              (admission["phase"] as String?) == "admitting",
              (admission["owner_host_id"] as String?) == principal.hostInstanceID.uuidString,
              (admission["owner_pid"] as Int?) == Int(principal.processIdentifier),
              (admission["stop_requested_at"] as Double?) == nil else {
            throw FloeMacSelfPreparedRequestError.admissionMismatch
        }
    }

    private struct Binding {
        let journalID: UUID
        let messageID: UUID
    }

    private static func readBinding(db: Database, requestID: UUID) throws -> Binding? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM main.floe_mac_self_prepared_request WHERE request_id=?", arguments: [requestID.uuidString]) else { return nil }
        guard let journalID = UUID(uuidString: row["journal_id"]),
              let messageID = UUID(uuidString: row["user_message_id"]) else {
            throw FloeMacSelfPreparedRequestError.corruptedBinding
        }
        return Binding(journalID: journalID, messageID: messageID)
    }

    private static func verify(db: Database, binding: Binding,
                               record: FloeMacSelfRequestJournalRecord, bytes: Data) throws {
        guard binding.journalID == record.journalID else { throw FloeMacSelfPreparedRequestError.corruptedBinding }
        let scope = record.scope
        let row = try Row.fetchOne(db, sql: """
            SELECT CAST(m.content AS BLOB) AS message_bytes, CAST(r.goal AS BLOB) AS run_bytes,
                   (SELECT COUNT(*) FROM main.message_parts p WHERE p.message_id=m.id) AS part_count,
                   (SELECT COUNT(*) FROM main.attachments a WHERE a.message_id=m.id) AS attachment_count,
                   (SELECT CAST(p.metadata_json AS BLOB) FROM main.message_parts p WHERE p.message_id=m.id AND p.part_index=0) AS metadata_bytes,
                   (SELECT CAST(p.text AS BLOB) FROM main.message_parts p WHERE p.message_id=m.id AND p.part_index=0 AND p.kind='text' AND p.attachment_id IS NULL) AS part_bytes
            FROM main.messages m
            JOIN main.runs r ON r.id=m.run_id AND r.conversation_id=m.conversation_id
            JOIN main.conversation_workspace_ownership o ON o.conversation_id=m.conversation_id
            WHERE m.id=? AND m.role='user' AND m.conversation_id=? AND r.id=? AND o.workspace_id=?
            """, arguments: [binding.messageID.uuidString, scope.conversationID.uuidString,
                              scope.runID.uuidString, scope.workspaceID.uuidString])
        guard let row, (row["message_bytes"] as Data?) == bytes,
              (row["run_bytes"] as Data?) == bytes, (row["part_bytes"] as Data?) == bytes,
              (row["part_count"] as Int?) == 1, (row["attachment_count"] as Int?) == 0,
              (row["metadata_bytes"] as Data?) == Data("{}".utf8) else { throw FloeMacSelfPreparedRequestError.corruptedBinding }
    }
}
