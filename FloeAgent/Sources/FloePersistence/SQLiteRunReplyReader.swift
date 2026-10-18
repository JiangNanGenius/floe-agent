import Foundation
import GRDB

/// One exact-run text projection without loading conversation history or
/// reasoning parts. The caller still verifies ordinary ownership, terminal
/// state and missing-final-reply markers before treating this as a result.
public struct SQLiteRunReplyReader: Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func latestAssistantText(runID: UUID, conversationID: UUID) async throws -> String? {
        try await database.reader { db in
            // Insertion order survives a device-clock correction between
            // an assistant's tool step and its final saved answer.
            try String.fetchOne(db, sql: """
                SELECT content FROM messages
                WHERE run_id = ? AND conversation_id = ? AND role = 'assistant'
                ORDER BY rowid DESC LIMIT 1
                """, arguments: [runID.uuidString, conversationID.uuidString])
        }
    }
}
