import Foundation
import GRDB
import FloePersistence

/// Conversation-level persistence for deferred tool-schema discovery. Lets a
/// fresh run keep the exact schemas a previous run loaded, instead of
/// re-deriving them from goal keywords or another tools.list sweep.
public actor SQLiteConversationDiscoveryStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    public func load(conversationID: UUID) async throws -> (names: Set<String>, priority: [String])? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT tool_names_json, priority_json FROM conversation_discovery WHERE conversation_id = ?
                """, arguments: [conversationID.uuidString]) else { return nil }
            let namesData: Data = row["tool_names_json"]
            let priorityData: Data = row["priority_json"]
            let names = Set(try JSONDecoder().decode([String].self, from: namesData))
            let priority = try JSONDecoder().decode([String].self, from: priorityData)
            return (names, priority)
        }
    }

    public func save(conversationID: UUID, names: Set<String>, priority: [String]) async throws {
        let namesData = try JSONEncoder().encode(names.sorted())
        let priorityData = try JSONEncoder().encode(priority)
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO conversation_discovery (conversation_id, tool_names_json, priority_json, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(conversation_id) DO UPDATE SET
                    tool_names_json=excluded.tool_names_json,
                    priority_json=excluded.priority_json,
                    updated_at=excluded.updated_at
                """, arguments: [conversationID.uuidString, namesData, priorityData, Date()])
        }
    }
}
