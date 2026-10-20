import Foundation
import GRDB

/// One exact-run text projection without loading conversation history or
/// reasoning parts. The caller still verifies ordinary ownership, terminal
/// state and missing-final-reply markers before treating this as a result.
///
/// The read is deliberately a single ordered row instead of "the last
/// non-empty text": a run whose final reply was empty must not fall back to an
/// earlier pre-tool assistant step, and a different run's later reply can
/// never fill the gap because both the run and its conversation are part of
/// the predicate.
public struct SQLiteRunReplyReader: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    /// The newest assistant row persisted for exactly this run and owner.
    /// Insertion order (`rowid`) survives a device-clock correction between an
    /// assistant's tool step and its final saved answer; role and run filters
    /// keep tool output and other runs out of the projection.
    public func latestAssistantText(runID: UUID, conversationID: UUID) async throws -> String? {
        try await database.reader { db in
            try String.fetchOne(db, sql: """
                SELECT content FROM messages
                WHERE run_id = ? AND conversation_id = ? AND role = 'assistant'
                ORDER BY rowid DESC LIMIT 1
                """, arguments: [runID.uuidString, conversationID.uuidString])
        }
    }

    /// The exact message the runtime's terminal marker designated as this
    /// run's final reply. Resolution requires all four identity columns:
    /// primary key id, the run that produced it, the owning conversation,
    /// and the assistant role. A missing row (wrong run/conversation,
    /// foreign or forged id, non-assistant role, or deleted row) returns nil
    /// so the caller reports an honest absence instead of falling back to
    /// "the latest assistant row".
    public func provenFinalReplyText(
        runID: UUID,
        conversationID: UUID,
        messageID: UUID
    ) async throws -> String? {
        try await database.reader { db in
            try String.fetchOne(db, sql: """
                SELECT content FROM messages
                WHERE id = ? AND run_id = ? AND conversation_id = ? AND role = 'assistant'
                """, arguments: [
                    messageID.uuidString,
                    runID.uuidString,
                    conversationID.uuidString
                ])
        }
    }
}
