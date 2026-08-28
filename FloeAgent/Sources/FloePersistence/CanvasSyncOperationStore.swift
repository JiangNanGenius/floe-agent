import Foundation
import GRDB
import FloeCore

public enum CanvasSyncOperationState: String, Sendable, Codable, Hashable {
    case pending, sending, confirmed, failed
}

public struct PendingCanvasSyncOperation: Sendable, Hashable {
    public var operation: CanvasSyncOperation
    public var state: CanvasSyncOperationState
    public var retryCount: Int
    public var lastError: String?
}

public actor CanvasSyncOperationStore {
    private let database: DatabaseManager
    private let encoder = JSONEncoder()

    public init(database: DatabaseManager) { self.database = database }

    public func enqueue(_ operation: CanvasSyncOperation) async throws {
        let hashes = try encoder.encode(operation.assetHashes)
        try await database.writer { db in
            try db.execute(sql: """
                INSERT INTO canvas_sync_operations (
                    operation_id, canvas_id, entity_kind, entity_id, mutation,
                    revision, payload, asset_hashes_json, state, retry_count,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                ON CONFLICT(operation_id) DO NOTHING
                """, arguments: [
                    operation.operationID.uuidString, operation.canvasID.uuidString,
                    operation.entityKind.rawValue, operation.entityID.uuidString,
                    operation.mutation.rawValue, operation.revision,
                    operation.payload, hashes, operation.createdAt, operation.createdAt
                ])
            if operation.mutation == .delete {
                try db.execute(sql: """
                    INSERT INTO canvas_deletion_tombstones (
                        id, canvas_id, operation_id, revision, deleted_at
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(operation_id) DO NOTHING
                    """, arguments: [
                        UUID().uuidString, operation.canvasID.uuidString,
                        operation.operationID.uuidString, operation.revision,
                        operation.createdAt
                    ])
            }
        }
    }

    public func pending(limit: Int = 100) async throws -> [PendingCanvasSyncOperation] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM canvas_sync_operations
                WHERE state IN ('pending','failed')
                ORDER BY revision, created_at, operation_id LIMIT ?
                """, arguments: [max(1, min(limit, 500))]).compactMap(Self.decode)
        }
    }

    public func mark(
        operationID: UUID, state: CanvasSyncOperationState,
        error: String? = nil
    ) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE canvas_sync_operations SET state = ?, last_error = ?,
                    retry_count = retry_count + CASE WHEN ? = 'failed' THEN 1 ELSE 0 END,
                    updated_at = ? WHERE operation_id = ?
                """, arguments: [state.rawValue, error, state.rawValue, Date(), operationID.uuidString])
        }
    }

    public func confirm(operationID: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: "UPDATE canvas_sync_operations SET state = 'confirmed', last_error = NULL, updated_at = ? WHERE operation_id = ?", arguments: [Date(), operationID.uuidString])
            try db.execute(sql: "UPDATE canvas_deletion_tombstones SET confirmed_at = ? WHERE operation_id = ?", arguments: [Date(), operationID.uuidString])
        }
    }

    private static func decode(_ row: Row) -> PendingCanvasSyncOperation? {
        guard let operationID = UUID(uuidString: row["operation_id"]),
              let canvasID = UUID(uuidString: row["canvas_id"]),
              let entityKind = CanvasSyncEntityKind(rawValue: row["entity_kind"]),
              let entityID = UUID(uuidString: row["entity_id"]),
              let mutation = CanvasSyncMutation(rawValue: row["mutation"]),
              let state = CanvasSyncOperationState(rawValue: row["state"]),
              let hashesData: Data = row["asset_hashes_json"],
              let hashes = try? JSONDecoder().decode([String].self, from: hashesData)
        else { return nil }
        return PendingCanvasSyncOperation(
            operation: CanvasSyncOperation(
                operationID: operationID, canvasID: canvasID,
                entityKind: entityKind, entityID: entityID,
                mutation: mutation, revision: row["revision"],
                payload: row["payload"], assetHashes: hashes,
                createdAt: row["created_at"]
            ),
            state: state, retryCount: row["retry_count"],
            lastError: row["last_error"]
        )
    }
}
