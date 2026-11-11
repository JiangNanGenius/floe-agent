// FloePersistence — bounded read-only activity for ordinary conversation rows.
import Foundation
import GRDB
import FloeCore

/// Every signal belongs to the current run selected in this single SQLite snapshot.
public struct ConversationActivitySnapshot: Sendable, Hashable {
    public struct Run: Sendable, Hashable {
        public let id: UUID
        public let state: String
        public let startedAt: Date
        public let endedAt: Date?
        public let goalID: UUID?
        public let eventSequence: Int
        public let signalKind: String?
        public let signalMessage: String?
        public let lastError: String?
        public let stopReason: String?
        public let statusReason: String?
        public let goalStatus: String?
        public let goalVersion: String?
        public let pendingQuestionID: String?
    }
    public let conversationID: UUID
    /// Change fingerprint only, never ownership authority. Callers must use
    /// the canonical ConversationRecord.isVisibleInOrdinaryList predicate.
    public let conversationVersion: Int
    public let run: Run?
}

/// Uses DatabaseManager's existing reader. No timer, notification center,
/// second connection, worker ownership, write, or model invocation.
public struct ConversationActivityStore: Sendable {
    private let database: DatabaseManager
    public init(database: DatabaseManager) { self.database = database }

    public func current(conversationID: UUID) async throws -> ConversationActivitySnapshot {
        try await database.reader { db in try Self.fetch(db, conversationID: conversationID) }
    }

    public func observation(conversationID: UUID) async throws -> AsyncValueObservation<ConversationActivitySnapshot> {
        let reader = try await database.observationReader()
        return ValueObservation.tracking { db in
            try Self.fetch(db, conversationID: conversationID)
        }.removeDuplicates().values(in: reader)
    }

    private static func fetch(_ db: Database, conversationID: UUID) throws -> ConversationActivitySnapshot {
        // Observe the whole metadata row so a durable editor-ownership change
        // also invalidates the presentation. The fingerprint is not persisted.
        let conversation = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?",
                                            arguments: [conversationID.uuidString])
        let version = conversation?.description.hashValue ?? 0
        guard conversation != nil, let row = try Row.fetchOne(db, sql: """
            SELECT id, state, started_at, ended_at, goal_id FROM runs
            WHERE conversation_id = ? ORDER BY started_at DESC, id LIMIT 1
            """, arguments: [conversationID.uuidString]) else {
            return .init(conversationID: conversationID, conversationVersion: version, run: nil)
        }
        guard let id = UUID(uuidString: row["id"]) else { throw FloeError.storageCorrupted("Invalid current run identity") }
        let runID = id.uuidString
        // A token/usage commit must not pulse every row. Actual state/error/
        // checkpoint changes retain their sequence; first resumed progress
        // still clears an error through signalKind below.
        let sequence = try Int.fetchOne(db, sql: """
            SELECT COALESCE(MAX(sequence), 0) FROM run_events WHERE run_id = ?
            AND kind IN ('status', 'error', 'terminal', 'checkpoint')
            """, arguments: [runID]) ?? 0
        let signal = try Row.fetchOne(db, sql: """
            SELECT kind, CASE WHEN kind IN ('error', 'status', 'terminal', 'checkpoint')
                THEN substr(payload_json, 1, 4096) ELSE NULL END AS payload
            FROM run_events WHERE run_id = ? AND kind IN
                ('error','status','terminal','checkpoint','assistantText','reasoning','toolRequest','toolResult')
            ORDER BY sequence DESC LIMIT 1
            """, arguments: [runID])
        let terminal = try String.fetchOne(db, sql: """
            SELECT substr(payload_json, 1, 4096) FROM run_events
            WHERE run_id = ? AND kind = 'terminal' ORDER BY sequence DESC LIMIT 1
            """, arguments: [runID])
        let status = try String.fetchOne(db, sql: """
            SELECT substr(payload_json, 1, 4096) FROM run_events
            WHERE run_id = ? AND kind = 'status' ORDER BY sequence DESC LIMIT 1
            """, arguments: [runID])
        let error = try String.fetchOne(db, sql: """
            SELECT substr(message, 1, 500) FROM run_errors
            WHERE run_id = ? ORDER BY recorded_at DESC, id DESC LIMIT 1
            """, arguments: [runID])
        let goalID = (row["goal_id"] as String?).flatMap(UUID.init(uuidString:))
        let goal: Row?
        if let goalID {
            goal = try Row.fetchOne(db, sql: """
                SELECT status, revision, updated_at FROM conversation_goals
                WHERE id = ? AND conversation_id = ? LIMIT 1
                """, arguments: [goalID.uuidString, conversationID.uuidString])
        } else { goal = nil }
        let pendingQuestion = try String.fetchOne(db, sql: """
            SELECT r.request_id FROM user_question_requests r
            WHERE r.run_id = ? AND r.conversation_id = ? AND r.state = 'awaitingAnswer'
              AND EXISTS (SELECT 1 FROM user_questions q WHERE q.request_id = r.request_id
                          AND q.run_id = r.run_id AND q.status = 'pending')
            ORDER BY r.created_at DESC, r.request_id LIMIT 1
            """, arguments: [runID, conversationID.uuidString])
        let signalPayload = signal?["payload"] as String?
        return .init(conversationID: conversationID, conversationVersion: version, run: .init(
            id: id, state: row["state"], startedAt: try PersistenceCodec.decodeDate(row["started_at"]),
            endedAt: try (row["ended_at"] as String?).map(PersistenceCodec.decodeDate), goalID: goalID,
            eventSequence: sequence, signalKind: signal?["kind"],
            signalMessage: string("message", in: signalPayload), lastError: error,
            stopReason: string("stopReason", in: terminal), statusReason: string("reason", in: status),
            goalStatus: goal?["status"], goalVersion: goal?.description,
            pendingQuestionID: pendingQuestion))
    }

    private static func string(_ key: String, in payload: String?) -> String? {
        guard let payload, let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object[key] as? String, !value.isEmpty else { return nil }
        return String(value.prefix(500))
    }
}
