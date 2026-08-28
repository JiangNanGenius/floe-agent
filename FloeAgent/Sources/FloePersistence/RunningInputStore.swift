// FloePersistence — durable running-input queue and steer promotion store.

import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeSecurity

public protocol RunningInputStore: Sendable {
    func enqueue(_ input: PendingUserInput) async throws -> PendingUserInput
    func pending(conversationID: UUID) async throws -> [PendingUserInput]
    func input(id: UUID) async throws -> PendingUserInput?
    func updateContent(id: UUID, content: String) async throws
    func cancel(id: UUID) async throws
    func reorder(conversationID: UUID, orderedIDs: [UUID]) async throws
    func claimNextQueued(conversationID: UUID) async throws -> PendingUserInput?
    func beginSteerPromotion(id: UUID, expectedRunID: UUID) async throws -> PendingUserInput?
    func markSteerAccepted(id: UUID, runID: UUID) async throws
    func markConsumed(id: UUID, runID: UUID) async throws
    func restoreQueued(id: UUID) async throws
    func recoverTransientInputs() async throws
}

public actor SQLiteRunningInputStore: RunningInputStore {
    public static let maximumPendingPerConversation = 100
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    public func enqueue(_ input: PendingUserInput) async throws -> PendingUserInput {
        let trimmed = SecretIngressScanner.scan(
            input.content.trimmingCharacters(in: .whitespacesAndNewlines)
        ).sanitizedText
        guard !trimmed.isEmpty else { throw FloeError.validationFailed("Input must not be empty") }
        return try await database.writer { db in
            let count = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM pending_user_inputs
                WHERE conversation_id = ? AND status IN ('queued', 'promoting', 'steerPending')
                """, arguments: [input.conversationID.uuidString]) ?? 0
            guard count < Self.maximumPendingPerConversation else {
                throw FloeError.validationFailed("The running-input queue is full")
            }
            let position = (try Int64.fetchOne(db, sql: """
                SELECT COALESCE(MAX(position), 0) + 1 FROM pending_user_inputs
                WHERE conversation_id = ? AND status IN ('queued', 'promoting', 'steerPending')
                """, arguments: [input.conversationID.uuidString])) ?? 1
            var value = input
            value.content = trimmed
            value.position = position
            value.updatedAt = Date()
            try Self.insert(value, db: db)
            return value
        }
    }

    public func pending(conversationID: UUID) async throws -> [PendingUserInput] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM pending_user_inputs
                WHERE conversation_id = ? AND status IN ('queued', 'promoting', 'steerPending')
                ORDER BY position, created_at, id
                """, arguments: [conversationID.uuidString]).map(Self.decode)
        }
    }

    public func input(id: UUID) async throws -> PendingUserInput? {
        try await database.reader { db in
            try Row.fetchOne(db, sql: "SELECT * FROM pending_user_inputs WHERE id = ?", arguments: [id.uuidString])
                .map(Self.decode)
        }
    }

    public func updateContent(id: UUID, content: String) async throws {
        let trimmed = SecretIngressScanner.scan(
            content.trimmingCharacters(in: .whitespacesAndNewlines)
        ).sanitizedText
        guard !trimmed.isEmpty else { throw FloeError.validationFailed("Input must not be empty") }
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE pending_user_inputs SET content = ?, updated_at = ?
                WHERE id = ? AND status = 'queued'
                """, arguments: [trimmed, PersistenceCodec.encode(Date()), id.uuidString])
            guard db.changesCount == 1 else {
                throw FloeError.validationFailed("Only queued input can be edited")
            }
        }
    }

    public func cancel(id: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE pending_user_inputs SET status = 'cancelled', updated_at = ?
                WHERE id = ? AND status = 'queued'
                """, arguments: [PersistenceCodec.encode(Date()), id.uuidString])
            guard db.changesCount == 1 else {
                throw FloeError.validationFailed("Only queued input can be removed")
            }
        }
    }

    public func reorder(conversationID: UUID, orderedIDs: [UUID]) async throws {
        try await database.writer { db in
            let current = try String.fetchAll(db, sql: """
                SELECT id FROM pending_user_inputs
                WHERE conversation_id = ? AND status = 'queued'
                ORDER BY position, created_at, id
                """, arguments: [conversationID.uuidString])
            guard Set(current) == Set(orderedIDs.map(\.uuidString)), current.count == orderedIDs.count else {
                throw FloeError.validationFailed("Queue changed while it was being reordered")
            }
            let now = PersistenceCodec.encode(Date())
            for (index, id) in orderedIDs.enumerated() {
                try db.execute(sql: """
                    UPDATE pending_user_inputs SET position = ?, updated_at = ?
                    WHERE id = ? AND conversation_id = ? AND status = 'queued'
                    """, arguments: [index + 1, now, id.uuidString, conversationID.uuidString])
            }
        }
    }

    public func claimNextQueued(conversationID: UUID) async throws -> PendingUserInput? {
        try await database.writer { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM pending_user_inputs
                WHERE conversation_id = ? AND status = 'queued'
                ORDER BY position, created_at, id LIMIT 1
                """, arguments: [conversationID.uuidString]) else { return nil }
            let value = try Self.decode(row)
            try db.execute(sql: """
                UPDATE pending_user_inputs SET status = 'promoting', updated_at = ?
                WHERE id = ? AND status = 'queued'
                """, arguments: [PersistenceCodec.encode(Date()), value.id.uuidString])
            guard db.changesCount == 1 else { return nil }
            var claimed = value
            claimed.status = .promoting
            return claimed
        }
    }

    public func beginSteerPromotion(id: UUID, expectedRunID: UUID) async throws -> PendingUserInput? {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE pending_user_inputs
                SET status = 'promoting', mode = 'steer', target_run_id = ?, updated_at = ?
                WHERE id = ? AND status = 'queued'
                """, arguments: [expectedRunID.uuidString, PersistenceCodec.encode(Date()), id.uuidString])
            guard db.changesCount == 1,
                  let row = try Row.fetchOne(db, sql: "SELECT * FROM pending_user_inputs WHERE id = ?", arguments: [id.uuidString])
            else { return nil }
            return try Self.decode(row)
        }
    }

    public func markSteerAccepted(id: UUID, runID: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE pending_user_inputs
                SET status = 'steerPending', target_run_id = ?, updated_at = ?
                WHERE id = ? AND status = 'promoting'
                """, arguments: [runID.uuidString, PersistenceCodec.encode(Date()), id.uuidString])
        }
    }

    public func markConsumed(id: UUID, runID: UUID) async throws {
        try await database.writer { db in
            let now = PersistenceCodec.encode(Date())
            try db.execute(sql: """
                UPDATE pending_user_inputs
                SET status = 'consumed', consumed_run_id = ?, consumed_at = ?, updated_at = ?
                WHERE id = ? AND status IN ('promoting', 'steerPending')
                """, arguments: [runID.uuidString, now, now, id.uuidString])
        }
    }

    public func restoreQueued(id: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE pending_user_inputs
                SET status = 'queued', mode = 'queue', target_run_id = NULL, updated_at = ?
                WHERE id = ? AND status = 'promoting'
                """, arguments: [PersistenceCodec.encode(Date()), id.uuidString])
        }
    }

    public func recoverTransientInputs() async throws {
        try await database.writer { db in
            try db.execute(sql: """
                UPDATE pending_user_inputs
                SET status = 'queued', mode = 'queue', target_run_id = NULL, updated_at = ?
                WHERE status IN ('promoting', 'steerPending') AND consumed_run_id IS NULL
                """, arguments: [PersistenceCodec.encode(Date())])
        }
    }

    private static func insert(_ value: PendingUserInput, db: Database) throws {
        let attachments = try String(decoding: JSONEncoder().encode(value.attachments), as: UTF8.self)
        try db.execute(sql: """
            INSERT INTO pending_user_inputs (
                id, conversation_id, target_run_id, content, mode, status, position,
                attachments_json, selected_model_id, workspace_id, execution_mode,
                consumed_run_id, created_at, updated_at, consumed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                value.id.uuidString, value.conversationID.uuidString, value.targetRunID?.uuidString,
                value.content, value.mode.rawValue, value.status.rawValue, value.position,
                attachments, value.selectedModelID?.uuidString, value.workspaceID?.uuidString,
                value.executionMode, value.consumedRunID?.uuidString,
                PersistenceCodec.encode(value.createdAt), PersistenceCodec.encode(value.updatedAt),
                value.consumedAt.map(PersistenceCodec.encode)
            ])
    }

    private static func decode(_ row: Row) throws -> PendingUserInput {
        guard let id = UUID(uuidString: row["id"]),
              let conversationID = UUID(uuidString: row["conversation_id"]),
              let mode = RunningInputMode(rawValue: row["mode"]),
              let status = PendingUserInputStatus(rawValue: row["status"])
        else { throw FloeError.storageCorrupted("Invalid pending user input") }
        let rawAttachments: String = row["attachments_json"]
        let attachments = try JSONDecoder().decode([AttachmentRef].self, from: Data(rawAttachments.utf8))
        return PendingUserInput(
            id: id,
            conversationID: conversationID,
            targetRunID: (row["target_run_id"] as String?).flatMap(UUID.init(uuidString:)),
            content: row["content"], mode: mode, status: status, position: row["position"],
            attachments: attachments,
            selectedModelID: (row["selected_model_id"] as String?).flatMap(UUID.init(uuidString:)),
            workspaceID: (row["workspace_id"] as String?).flatMap(UUID.init(uuidString:)),
            executionMode: row["execution_mode"],
            consumedRunID: (row["consumed_run_id"] as String?).flatMap(UUID.init(uuidString:)),
            createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
            updatedAt: try PersistenceCodec.decodeDate(row["updated_at"]),
            consumedAt: (row["consumed_at"] as String?).flatMap { try? PersistenceCodec.decodeDate($0) }
        )
    }
}
