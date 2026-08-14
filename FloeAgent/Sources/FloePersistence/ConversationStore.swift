// FloePersistence — Conversation / message / content-part / attachment store.
// See docs/ALPHA_DAILY_PLAN.md (Persistence v3). Secret-free by construction.

import Foundation
import GRDB
import FloeCore
import FloeModels

/// A conversation row with its plain-text projection. Structured multimodal
/// parts are loaded separately via `parts(messageID:)`.
public struct ConversationRecord: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID, title: String, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A persisted message with its ordered typed content parts.
public struct PersistedMessage: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var conversationID: UUID
    public var role: String
    public var content: String
    public var createdAt: Date
    public var parts: [MessagePart]

    public init(
        id: UUID,
        conversationID: UUID,
        role: String,
        content: String,
        createdAt: Date,
        parts: [MessagePart] = []
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.parts = parts
    }
}

/// Durable conversation, message, content-part and attachment access.
/// Deterministic ordering throughout; writes are cancellation-safe because
/// GRDB serialises writers.
public protocol ConversationStore: Sendable {
    func saveConversation(_ conversation: ConversationRecord) async throws
    func conversations() async throws -> [ConversationRecord]
    func conversation(id: UUID) async throws -> ConversationRecord?
    func renameConversation(id: UUID, title: String) async throws
    func deleteConversation(id: UUID) async throws

    func appendMessage(_ message: PersistedMessage) async throws
    func messages(conversationID: UUID) async throws -> [PersistedMessage]
    func parts(messageID: UUID) async throws -> [MessagePart]

    func saveAttachment(_ attachment: AttachmentRef) async throws
    func attachment(id: UUID) async throws -> AttachmentRef?
    func attachments(conversationID: UUID) async throws -> [AttachmentRef]
}

/// SQLite/GRDB implementation of `ConversationStore`.
public actor SQLiteConversationStore: ConversationStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func saveConversation(_ conversation: ConversationRecord) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations (id, title, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    conversation.id.uuidString,
                    conversation.title,
                    PersistenceCodec.encode(conversation.createdAt),
                    PersistenceCodec.encode(conversation.updatedAt)
                ]
            )
        }
    }

    public func conversations() async throws -> [ConversationRecord] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM conversations ORDER BY updated_at DESC, id"
            ).map(Self.conversation(from:))
        }
    }

    public func conversation(id: UUID) async throws -> ConversationRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM conversations WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.conversation(from: row)
        }
    }

    public func renameConversation(id: UUID, title: String) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "UPDATE conversations SET title = ?, updated_at = ? WHERE id = ?",
                arguments: [title, PersistenceCodec.encode(Date()), id.uuidString]
            )
        }
    }

    public func deleteConversation(id: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func appendMessage(_ message: PersistedMessage) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (id, conversation_id, role, content, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        content = excluded.content
                    """,
                arguments: [
                    message.id.uuidString,
                    message.conversationID.uuidString,
                    message.role,
                    message.content,
                    PersistenceCodec.encode(message.createdAt)
                ]
            )
            for part in message.parts {
                try Self.insertPart(part, db: db)
            }
            // Touch the conversation so list ordering reflects activity.
            try db.execute(
                sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                arguments: [PersistenceCodec.encode(Date()), message.conversationID.uuidString]
            )
        }
    }

    public func messages(conversationID: UUID) async throws -> [PersistedMessage] {
        try await database.reader { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at, rowid",
                arguments: [conversationID.uuidString]
            )
            return try rows.map { row in
                let id = try Self.messageID(from: row)
                let parts = try Self.fetchParts(messageID: id, db: db)
                return PersistedMessage(
                    id: id,
                    conversationID: conversationID,
                    role: row["role"],
                    content: row["content"],
                    createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
                    parts: parts
                )
            }
        }
    }

    public func parts(messageID: UUID) async throws -> [MessagePart] {
        try await database.reader { db in
            try Self.fetchParts(messageID: messageID, db: db)
        }
    }

    public func saveAttachment(_ attachment: AttachmentRef) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO attachments (
                        id, conversation_id, message_id, kind, display_name, uti,
                        byte_count, sha256, storage, url_bookmark, relative_path, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        message_id = excluded.message_id,
                        display_name = excluded.display_name,
                        byte_count = excluded.byte_count,
                        sha256 = excluded.sha256,
                        storage = excluded.storage,
                        url_bookmark = excluded.url_bookmark,
                        relative_path = excluded.relative_path
                    """,
                arguments: [
                    attachment.id.uuidString,
                    attachment.conversationID?.uuidString,
                    attachment.messageID?.uuidString,
                    attachment.kind.rawValue,
                    attachment.displayName,
                    attachment.uti,
                    attachment.byteCount,
                    attachment.sha256,
                    attachment.storage.rawValue,
                    attachment.urlBookmark,
                    attachment.relativePath,
                    PersistenceCodec.encode(attachment.createdAt)
                ]
            )
        }
    }

    public func attachment(id: UUID) async throws -> AttachmentRef? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM attachments WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.attachment(from: row)
        }
    }

    public func attachments(conversationID: UUID) async throws -> [AttachmentRef] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM attachments WHERE conversation_id = ? ORDER BY created_at, id",
                arguments: [conversationID.uuidString]
            ).map(Self.attachment(from:))
        }
    }

    // MARK: - Row mapping

    private static func conversation(from row: Row) throws -> ConversationRecord {
        guard let id = UUID(uuidString: row["id"]) else {
            throw FloeError.storageCorrupted("Invalid conversation identifier")
        }
        return ConversationRecord(
            id: id,
            title: row["title"],
            createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
            updatedAt: try PersistenceCodec.decodeDate(row["updated_at"])
        )
    }

    private static func messageID(from row: Row) throws -> UUID {
        guard let id = UUID(uuidString: row["id"]) else {
            throw FloeError.storageCorrupted("Invalid message identifier")
        }
        return id
    }

    private static func insertPart(_ part: MessagePart, db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO message_parts (
                    id, message_id, part_index, kind, text, attachment_id,
                    metadata_json, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(message_id, part_index) DO UPDATE SET
                    kind = excluded.kind,
                    text = excluded.text,
                    attachment_id = excluded.attachment_id,
                    metadata_json = excluded.metadata_json
                """,
            arguments: [
                part.id.uuidString,
                part.messageID.uuidString,
                part.partIndex,
                part.kind.rawValue,
                part.text,
                part.attachmentID?.uuidString,
                try PersistenceCodec.jsonObject(part.metadata),
                PersistenceCodec.encode(part.createdAt)
            ]
        )
    }

    private static func fetchParts(messageID: UUID, db: Database) throws -> [MessagePart] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT * FROM message_parts WHERE message_id = ? ORDER BY part_index",
            arguments: [messageID.uuidString]
        )
        return try rows.map { row in
            guard
                let id = UUID(uuidString: row["id"]),
                let kind = MessagePart.Kind(rawValue: row["kind"])
            else {
                throw FloeError.storageCorrupted("Invalid message part")
            }
            let attachmentID: UUID? = (row["attachment_id"] as String?).flatMap(UUID.init(uuidString:))
            return MessagePart(
                id: id,
                messageID: messageID,
                partIndex: row["part_index"],
                kind: kind,
                text: row["text"],
                attachmentID: attachmentID,
                metadata: try PersistenceCodec.jsonDictionary(row["metadata_json"]),
                createdAt: try PersistenceCodec.decodeDate(row["created_at"])
            )
        }
    }

    private static func attachment(from row: Row) throws -> AttachmentRef {
        guard
            let id = UUID(uuidString: row["id"]),
            let kind = AttachmentRef.Kind(rawValue: row["kind"]),
            let storage = AttachmentRef.Storage(rawValue: row["storage"])
        else {
            throw FloeError.storageCorrupted("Invalid attachment record")
        }
        let conversationID: UUID? = (row["conversation_id"] as String?).flatMap(UUID.init(uuidString:))
        let messageID: UUID? = (row["message_id"] as String?).flatMap(UUID.init(uuidString:))
        return AttachmentRef(
            id: id,
            conversationID: conversationID,
            messageID: messageID,
            kind: kind,
            displayName: row["display_name"],
            uti: row["uti"],
            byteCount: row["byte_count"],
            sha256: row["sha256"],
            storage: storage,
            urlBookmark: row["url_bookmark"],
            relativePath: row["relative_path"],
            createdAt: try PersistenceCodec.decodeDate(row["created_at"])
        )
    }
}
