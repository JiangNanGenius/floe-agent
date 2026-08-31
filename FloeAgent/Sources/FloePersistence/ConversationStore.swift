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
    public var titleOrigin: ConversationTitleOrigin
    public var archivedAt: Date?

    public init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        titleOrigin: ConversationTitleOrigin = .autoPending,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.titleOrigin = titleOrigin
        self.archivedAt = archivedAt
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
    public var runID: UUID?

    public init(
        id: UUID,
        conversationID: UUID,
        role: String,
        content: String,
        createdAt: Date,
        parts: [MessagePart] = [],
        runID: UUID? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.parts = parts
        self.runID = runID
    }
}

/// Stable keyset cursor for long conversation timelines. UUID is the
/// deterministic tie-breaker when several events share a timestamp.
public struct ConversationMessageCursor: Sendable, Codable, Hashable {
    public var createdAt: Date
    public var messageID: UUID

    public init(createdAt: Date, messageID: UUID) {
        self.createdAt = createdAt
        self.messageID = messageID
    }
}

public struct ConversationMessagePage: Sendable, Hashable {
    /// Chronological rows for direct insertion into the UI timeline.
    public var messages: [PersistedMessage]
    public var earlierCursor: ConversationMessageCursor?
    public var hasEarlier: Bool

    public init(
        messages: [PersistedMessage],
        earlierCursor: ConversationMessageCursor?,
        hasEarlier: Bool
    ) {
        self.messages = messages
        self.earlierCursor = earlierCursor
        self.hasEarlier = hasEarlier
    }
}

/// Durable conversation, message, content-part and attachment access.
/// Deterministic ordering throughout; writes are cancellation-safe because
/// GRDB serialises writers.
public protocol ConversationStore: Sendable {
    func saveConversation(_ conversation: ConversationRecord) async throws
    func conversations() async throws -> [ConversationRecord]
    func conversations(includeArchived: Bool) async throws -> [ConversationRecord]
    func conversation(id: UUID) async throws -> ConversationRecord?
    func renameConversation(id: UUID, title: String) async throws
    @discardableResult
    func setAutomaticTitle(id: UUID, title: String) async throws -> Bool
    func deleteConversation(id: UUID) async throws
    func setArchived(id: UUID, archived: Bool) async throws

    func appendMessage(_ message: PersistedMessage) async throws
    func messages(conversationID: UUID) async throws -> [PersistedMessage]
    /// Fast first-screen page in chronological order. Full history remains
    /// available through `messages(conversationID:)` and is hydrated later.
    func recentMessages(conversationID: UUID, limit: Int) async throws -> [PersistedMessage]
    func messagePage(
        conversationID: UUID,
        before cursor: ConversationMessageCursor?,
        limit: Int
    ) async throws -> ConversationMessagePage
    func parts(messageID: UUID) async throws -> [MessagePart]

    func saveAttachment(_ attachment: AttachmentRef) async throws
    func attachment(id: UUID) async throws -> AttachmentRef?
    func attachments(conversationID: UUID) async throws -> [AttachmentRef]
}

public extension ConversationStore {
    func conversations(includeArchived: Bool) async throws -> [ConversationRecord] {
        guard !includeArchived else {
            throw FloeError.invalidConfiguration("This conversation store does not support archives")
        }
        return try await conversations()
    }

    func setArchived(id: UUID, archived: Bool) async throws {
        throw FloeError.invalidConfiguration("This conversation store does not support archives")
    }

    func recentMessages(conversationID: UUID, limit: Int) async throws -> [PersistedMessage] {
        Array(try await messages(conversationID: conversationID).suffix(max(1, limit)))
    }

    func messagePage(
        conversationID: UUID,
        before cursor: ConversationMessageCursor?,
        limit: Int
    ) async throws -> ConversationMessagePage {
        let ordered = try await messages(conversationID: conversationID).sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
        let eligible = cursor.map { cursor in
            ordered.filter {
                ($0.createdAt, $0.id.uuidString) < (cursor.createdAt, cursor.messageID.uuidString)
            }
        } ?? ordered
        let bounded = max(1, limit)
        let page = Array(eligible.suffix(bounded))
        return ConversationMessagePage(
            messages: page,
            earlierCursor: page.first.map {
                ConversationMessageCursor(createdAt: $0.createdAt, messageID: $0.id)
            },
            hasEarlier: eligible.count > page.count
        )
    }
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
        try await conversations(includeArchived: false)
    }

    public func conversations(includeArchived: Bool) async throws -> [ConversationRecord] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: includeArchived
                    ? "SELECT * FROM conversations ORDER BY updated_at DESC, id"
                    : "SELECT * FROM conversations WHERE archived_at IS NULL ORDER BY updated_at DESC, id"
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
                sql: "UPDATE conversations SET title = ?, title_origin = 'manual', updated_at = ? WHERE id = ?",
                arguments: [title, PersistenceCodec.encode(Date()), id.uuidString]
            )
        }
    }

    @discardableResult
    public func setAutomaticTitle(id: UUID, title: String) async throws -> Bool {
        try await database.writer { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET title = ?, title_origin = 'automatic', updated_at = ?
                    WHERE id = ? AND title_origin = 'autoPending'
                    """,
                arguments: [title, PersistenceCodec.encode(Date()), id.uuidString]
            )
            return db.changesCount > 0
        }
    }

    public func deleteConversation(id: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func setArchived(id: UUID, archived: Bool) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "UPDATE conversations SET archived_at = ?, updated_at = ? WHERE id = ?",
                arguments: [
                    archived ? PersistenceCodec.encode(Date()) : nil,
                    PersistenceCodec.encode(Date()),
                    id.uuidString
                ]
            )
        }
    }

    public func appendMessage(_ message: PersistedMessage) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO messages (id, conversation_id, role, content, created_at, run_id)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        content = excluded.content
                    """,
                arguments: [
                    message.id.uuidString,
                    message.conversationID.uuidString,
                    message.role,
                    message.content,
                    PersistenceCodec.encode(message.createdAt),
                    message.runID?.uuidString
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
            let messageIDs = try rows.map(Self.messageID(from:))
            let partsByMessage = try Self.fetchParts(messageIDs: messageIDs, db: db)
            return try rows.map { row in
                let id = try Self.messageID(from: row)
                return PersistedMessage(
                    id: id,
                    conversationID: conversationID,
                    role: row["role"],
                    content: row["content"],
                    createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
                    parts: partsByMessage[id, default: []],
                    runID: (row["run_id"] as String?).flatMap(UUID.init(uuidString:))
                )
            }
        }
    }

    public func recentMessages(conversationID: UUID, limit: Int) async throws -> [PersistedMessage] {
        // The thread UI grows this window in bounded increments while the
        // user explicitly asks for older history. Capping this method at 500
        // made the UI believe another page had loaded while returning the
        // same rows forever, and orphaned the corresponding historical tool
        // events from the timeline.
        let bounded = min(10_000, max(1, limit))
        return try await database.reader { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM (
                        SELECT messages.*, rowid AS stable_order FROM messages
                        WHERE conversation_id = ?
                        ORDER BY created_at DESC, rowid DESC
                        LIMIT ?
                    ) ORDER BY created_at, stable_order
                    """,
                arguments: [conversationID.uuidString, bounded]
            )
            let messageIDs = try rows.map(Self.messageID(from:))
            let partsByMessage = try Self.fetchParts(messageIDs: messageIDs, db: db)
            return try rows.map { row in
                let id = try Self.messageID(from: row)
                return PersistedMessage(
                    id: id,
                    conversationID: conversationID,
                    role: row["role"],
                    content: row["content"],
                    createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
                    parts: partsByMessage[id, default: []],
                    runID: (row["run_id"] as String?).flatMap(UUID.init(uuidString:))
                )
            }
        }
    }

    public func messagePage(
        conversationID: UUID,
        before cursor: ConversationMessageCursor?,
        limit: Int
    ) async throws -> ConversationMessagePage {
        let bounded = min(500, max(1, limit))
        return try await database.reader { db in
            let predicate: String
            var arguments: StatementArguments = [conversationID.uuidString]
            if let cursor {
                predicate = """
                    AND (created_at < ? OR (created_at = ? AND id < ?))
                    """
                let date = PersistenceCodec.encode(cursor.createdAt)
                arguments += [date, date, cursor.messageID.uuidString]
            } else {
                predicate = ""
            }
            arguments += [bounded + 1]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM messages
                    WHERE conversation_id = ? \(predicate)
                    ORDER BY created_at DESC, id DESC
                    LIMIT ?
                    """,
                arguments: arguments
            )
            let hasEarlier = rows.count > bounded
            let pageRows = Array(rows.prefix(bounded).reversed())
            let messageIDs = try pageRows.map(Self.messageID(from:))
            let partsByMessage = try Self.fetchParts(messageIDs: messageIDs, db: db)
            let messages = try pageRows.map { row in
                let id = try Self.messageID(from: row)
                return PersistedMessage(
                    id: id,
                    conversationID: conversationID,
                    role: row["role"],
                    content: row["content"],
                    createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
                    parts: partsByMessage[id, default: []],
                    runID: (row["run_id"] as String?).flatMap(UUID.init(uuidString:))
                )
            }
            return ConversationMessagePage(
                messages: messages,
                earlierCursor: messages.first.map {
                    ConversationMessageCursor(createdAt: $0.createdAt, messageID: $0.id)
                },
                hasEarlier: hasEarlier
            )
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
            updatedAt: try PersistenceCodec.decodeDate(row["updated_at"]),
            titleOrigin: ConversationTitleOrigin(rawValue: row["title_origin"] as String? ?? "autoPending")
                ?? .autoPending,
            archivedAt: (row["archived_at"] as String?).flatMap { try? PersistenceCodec.decodeDate($0) }
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
            try part(from: row, messageID: messageID)
        }
    }

    /// Hydrates a message window with a bounded number of SQL statements.
    /// SQLite's bind limit varies by build, so large histories are chunked
    /// instead of falling back to one query per message.
    private static func fetchParts(
        messageIDs: [UUID],
        db: Database
    ) throws -> [UUID: [MessagePart]] {
        guard !messageIDs.isEmpty else { return [:] }
        var result: [UUID: [MessagePart]] = [:]
        for chunkStart in stride(from: 0, to: messageIDs.count, by: 400) {
            let chunk = Array(messageIDs[chunkStart..<min(chunkStart + 400, messageIDs.count)])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM message_parts
                    WHERE message_id IN (\(placeholders))
                    ORDER BY message_id, part_index
                    """,
                arguments: StatementArguments(chunk.map(\.uuidString))
            )
            for row in rows {
                guard let messageID = UUID(uuidString: row["message_id"]) else {
                    throw FloeError.storageCorrupted("Invalid message part owner")
                }
                result[messageID, default: []].append(try part(from: row, messageID: messageID))
            }
        }
        return result
    }

    private static func part(from row: Row, messageID: UUID) throws -> MessagePart {
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
