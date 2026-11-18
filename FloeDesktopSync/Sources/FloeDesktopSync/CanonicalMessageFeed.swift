// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif

/// A host-owned, SQLite-transaction-bound source of canonical Floe messages.
///
/// Install only from the host's migration transaction on its authoritative
/// conversation database. The six SQLite triggers then append identities in
/// the *same transaction* as changes to `messages` and `message_parts`.
/// This module neither opens that database nor grants access to it. Every
/// method borrows a live connection synchronously; the caller must serialize
/// use of that connection and own the enclosing transaction. A host must
/// authorize the selected conversation, exclude temporary/editor-owned data,
/// and commit its own projection/checkpoint with an appropriate recovery
/// protocol. A separate SyncStore transaction is not atomic with this feed.
public enum CanonicalMessageFeed {
    public static let maximumPageSize = 100
    public static let maximumMessageBytes = 256 * 1024
    public static let maximumParts = 256

    public enum FeedError: Error, Equatable, Sendable {
        case transactionRequired
        case foreignKeysRequired
        case alreadyInstalled
        case unavailable
        case invalidPageSize
        case wrongGeneration
        case invalidCursor
        case invalidIdentifier
        case ambiguousIdentifier
        case oversizedMessage
        case invalidSourceRow
        case sqlite(code: Int32, message: String)
    }

    public struct Position: Codable, Equatable, Sendable {
        public let generation: UUID
        public let sequence: Int64
        public init(generation: UUID, sequence: Int64) {
            self.generation = generation; self.sequence = sequence
        }
    }
    public struct Part: Equatable, Sendable {
        public let id: UUID
        public let index: Int64
        public let kind: String
        public let text: String?
        public let attachmentID: UUID?
        /// Stored JSON from the source. Attachment bytes are not included.
        public let metadataJSON: String
        public let createdAt: String
    }
    public struct Message: Equatable, Sendable {
        public let id: UUID
        public let conversationID: UUID
        public let role: String
        public let content: String
        public let createdAt: String
        public let runID: UUID?
        public let parts: [Part]
    }
    public struct Change: Equatable, Sendable {
        public let sequence: Int64
        public let messageID: UUID
        /// Current canonical state in this read snapshot, or a tombstone when
        /// the message no longer belongs to the selected conversation.
        public let message: Message?
    }
    public struct ChangePage: Equatable, Sendable {
        public let changes: [Change]
        public let next: Position
        public let hasMore: Bool
    }
    public struct Bootstrap: Codable, Equatable, Sendable {
        public let conversationID: UUID
        /// Replay changes after this position when the initial scan ends.
        public let start: Position
        public init(conversationID: UUID, start: Position) {
            self.conversationID = conversationID; self.start = start
        }
    }
    public struct BootstrapPage: Equatable, Sendable {
        public let messages: [Message]
        public let nextMessageID: UUID?
    }

    private static let objectNames = [
        "floe_msgfeed_meta_v1", "floe_msgfeed_changes_v1", "floe_msgfeed_scope_v1",
        "floe_msgfeed_advance_v1",
        "floe_msgfeed_messages_id_v1", "floe_msgfeed_messages_scope_v1",
        "floe_msgfeed_parts_id_v1", "floe_msgfeed_parts_owner_v1", "floe_msgfeed_conversations_id_v1",
        "floe_msgfeed_messages_before_insert_v1",
        "floe_msgfeed_parts_before_insert_v1",
        "floe_msgfeed_messages_insert_v1", "floe_msgfeed_messages_update_v1",
        "floe_msgfeed_messages_delete_v1", "floe_msgfeed_parts_insert_v1",
        "floe_msgfeed_parts_update_v1", "floe_msgfeed_parts_delete_v1"
    ]
    private static let installationSQL = """
        CREATE TABLE floe_msgfeed_meta_v1 (singleton INTEGER PRIMARY KEY CHECK(singleton=1), generation TEXT NOT NULL, head INTEGER NOT NULL CHECK(head>=0)) STRICT;
        CREATE TABLE floe_msgfeed_changes_v1 (sequence INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT NOT NULL, message_id TEXT NOT NULL) STRICT;
        CREATE INDEX floe_msgfeed_scope_v1 ON floe_msgfeed_changes_v1(conversation_id COLLATE NOCASE, sequence);
        CREATE INDEX floe_msgfeed_messages_id_v1 ON messages(id COLLATE NOCASE);
        CREATE INDEX floe_msgfeed_messages_scope_v1 ON messages(conversation_id COLLATE NOCASE, id COLLATE NOCASE);
        CREATE INDEX floe_msgfeed_parts_id_v1 ON message_parts(id COLLATE NOCASE);
        CREATE INDEX floe_msgfeed_parts_owner_v1 ON message_parts(message_id COLLATE NOCASE, part_index);
        CREATE INDEX floe_msgfeed_conversations_id_v1 ON conversations(id COLLATE NOCASE);
        CREATE TRIGGER floe_msgfeed_advance_v1 AFTER INSERT ON floe_msgfeed_changes_v1 BEGIN
          SELECT CASE WHEN (SELECT head FROM floe_msgfeed_meta_v1 WHERE singleton=1) IS NOT NEW.sequence - 1 THEN RAISE(ABORT, 'message feed sequence gap') END;
          UPDATE floe_msgfeed_meta_v1 SET head=NEW.sequence WHERE singleton=1;
        END;
        -- SQLite REPLACE may suppress DELETE triggers when recursive triggers
        -- are disabled. Preserve the old scope before any conflicting insert.
        CREATE TRIGGER floe_msgfeed_messages_before_insert_v1 BEFORE INSERT ON messages BEGIN
          INSERT INTO floe_msgfeed_changes_v1(conversation_id,message_id)
            SELECT conversation_id,id FROM messages WHERE id=NEW.id AND conversation_id != NEW.conversation_id COLLATE NOCASE;
        END;
        CREATE TRIGGER floe_msgfeed_parts_before_insert_v1 BEFORE INSERT ON message_parts BEGIN
          INSERT INTO floe_msgfeed_changes_v1(conversation_id,message_id)
            SELECT m.conversation_id,m.id FROM message_parts p JOIN messages m ON m.id=p.message_id
            WHERE p.id=NEW.id AND p.message_id != NEW.message_id COLLATE NOCASE;
        END;
        CREATE TRIGGER floe_msgfeed_messages_insert_v1 AFTER INSERT ON messages BEGIN
          INSERT INTO floe_msgfeed_changes_v1(conversation_id,message_id) VALUES(NEW.conversation_id,NEW.id);
        END;
        CREATE TRIGGER floe_msgfeed_messages_update_v1 AFTER UPDATE ON messages BEGIN
          INSERT INTO floe_msgfeed_changes_v1(conversation_id,message_id)
            SELECT OLD.conversation_id,OLD.id WHERE OLD.id != NEW.id COLLATE NOCASE OR OLD.conversation_id != NEW.conversation_id COLLATE NOCASE;
          INSERT INTO floe_msgfeed_changes_v1(conversation_id,message_id) VALUES(NEW.conversation_id,NEW.id);
        END;
        CREATE TRIGGER floe_msgfeed_messages_delete_v1 AFTER DELETE ON messages BEGIN
          INSERT INTO floe_msgfeed_changes_v1(conversation_id,message_id) VALUES(OLD.conversation_id,OLD.id);
        END;
        CREATE TRIGGER floe_msgfeed_parts_insert_v1 AFTER INSERT ON message_parts BEGIN
          INSERT INTO floe_msgfeed_changes_v1(conversation_id,message_id) SELECT conversation_id,id FROM messages WHERE id=NEW.message_id;
        END;
        CREATE TRIGGER floe_msgfeed_parts_update_v1 AFTER UPDATE ON message_parts BEGIN
          INSERT INTO floe_msgfeed_changes_v1(conversation_id,message_id) SELECT conversation_id,id FROM messages WHERE id=OLD.message_id AND OLD.message_id != NEW.message_id COLLATE NOCASE;
          INSERT INTO floe_msgfeed_changes_v1(conversation_id,message_id) SELECT conversation_id,id FROM messages WHERE id=NEW.message_id;
        END;
        CREATE TRIGGER floe_msgfeed_parts_delete_v1 AFTER DELETE ON message_parts BEGIN
          INSERT INTO floe_msgfeed_changes_v1(conversation_id,message_id) SELECT conversation_id,id FROM messages WHERE id=OLD.message_id;
        END;
        """

    /// Installs new feed objects atomically inside the caller's transaction.
    /// Existing or partial objects are rejected; no legacy table is rewritten.
    @discardableResult
    public static func install(on db: OpaquePointer) throws -> UUID {
        try requireTransaction(db)
        guard try scalar(db, "PRAGMA foreign_keys") == 1 else { throw FeedError.foreignKeysRequired }
        let occupied = try scalar(db, "SELECT COUNT(*) FROM sqlite_schema WHERE name GLOB 'floe_msgfeed_*_v1'")
        guard occupied == 0 else { throw FeedError.alreadyInstalled }
        // Confirm the actual Floe source schema, including v10 run_id.
        let source = try prepare(db, "SELECT m.id,m.conversation_id,m.role,m.content,m.created_at,m.run_id,p.id,p.message_id,p.part_index,p.kind,p.text,p.attachment_id,p.metadata_json,p.created_at FROM messages m LEFT JOIN message_parts p ON p.message_id=m.id LIMIT 0")
        _ = try source.step()
        let savepoint = "floe_msgfeed_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try execute(db, "SAVEPOINT \(savepoint)")
        do {
            try execute(db, installationSQL)
            let generation = UUID()
            let insert = try prepare(db, "INSERT INTO floe_msgfeed_meta_v1(singleton,generation,head) VALUES(1,?,0)")
            try insert.bind(1, generation.uuidString)
            _ = try insert.step()
            try execute(db, "RELEASE \(savepoint)")
            return generation
        } catch {
            do { try execute(db, "ROLLBACK TO \(savepoint)"); try execute(db, "RELEASE \(savepoint)") }
            catch { throw FeedError.unavailable }
            throw error
        }
    }

    /// Reads the currently installed feed generation and its global head in
    /// the caller's existing transaction. This is an opaque local watermark,
    /// not an authorization, snapshot, or proof of object integrity. The
    /// caller must not turn it into a consumer cursor without establishing a
    /// complete authorized snapshot and the corresponding recovery protocol.
    public static func position(on db: OpaquePointer) throws -> Position {
        try requireTransaction(db)
        let generation = try checkedGeneration(db)
        let sequence = try head(db)
        guard sequence >= 0 else { throw FeedError.invalidSourceRow }
        return Position(generation: generation, sequence: sequence)
    }

    /// Explicitly discards retained invalidations and rotates the generation.
    /// The caller owns the enclosing write transaction and the decision to
    /// rotate. Every old cursor/bootstrap then fails with `wrongGeneration`.
    /// Consumers MUST replace/reconcile their entire authorized projection,
    /// including deletions, before resuming from a new bootstrap watermark.
    /// This primitive is not an automatic retention policy or an account,
    /// device, restore-generation or checkpoint authorization mechanism.
    @discardableResult
    public static func rotateHistory(on db: OpaquePointer) throws -> Position {
        try requireTransaction(db)
        let previous = try checkedGeneration(db)
        let currentHead = try head(db)
        let savepoint = "floe_msgfeed_rotate_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        try execute(db, "SAVEPOINT \(savepoint)")
        do {
            var generation = UUID()
            while generation == previous { generation = UUID() }
            let update = try prepare(db, "UPDATE floe_msgfeed_meta_v1 SET generation=? WHERE singleton=1 AND generation=? COLLATE NOCASE AND head=?")
            try update.bind(1, generation.uuidString)
            try update.bind(2, previous.uuidString)
            try update.bind(3, currentHead)
            _ = try update.step()
            guard sqlite3_changes(db) == 1 else { throw FeedError.unavailable }
            try execute(db, "DELETE FROM floe_msgfeed_changes_v1")
            try execute(db, "RELEASE \(savepoint)")
            return Position(generation: generation, sequence: currentHead)
        } catch {
            do { try execute(db, "ROLLBACK TO \(savepoint)"); try execute(db, "RELEASE \(savepoint)") }
            catch { throw FeedError.unavailable }
            throw error
        }
    }

    /// Establishes a replay watermark before scanning existing rows. A host
    /// must complete the scan and then consume changes after `start`.
    public static func beginBootstrap(on db: OpaquePointer, conversationID: UUID) throws -> Bootstrap {
        try requireTransaction(db)
        let generation = try checkedGeneration(db)
        let statement = try prepare(db, "SELECT CASE WHEN length(CAST(id AS BLOB))=36 THEN id ELSE NULL END FROM conversations WHERE id = ? COLLATE NOCASE LIMIT 2")
        try statement.bind(1, conversationID.uuidString)
        guard try statement.step(), let raw = statement.strictUTF8Text(0), UUID(uuidString: raw) == conversationID else { throw FeedError.invalidIdentifier }
        guard try !statement.step() else { throw FeedError.ambiguousIdentifier }
        return Bootstrap(conversationID: conversationID, start: Position(generation: generation, sequence: try head(db)))
    }

    /// Keyset pagination is bounded. Concurrent inserts/updates/deletes are
    /// reconciled by replaying the entire feed from the bootstrap watermark.
    public static func bootstrapPage(on db: OpaquePointer, bootstrap: Bootstrap,
                                     after: UUID?, limit: Int) throws -> BootstrapPage {
        try requireTransaction(db); try validateLimit(limit)
        guard try checkedGeneration(db) == bootstrap.start.generation else { throw FeedError.wrongGeneration }
        guard bootstrap.start.sequence >= 0, bootstrap.start.sequence <= (try head(db)) else { throw FeedError.invalidCursor }
        let predicate = after == nil ? "" : " AND id > ? COLLATE NOCASE"
        let statement = try prepare(db, "SELECT CASE WHEN length(CAST(id AS BLOB))=36 THEN id ELSE NULL END FROM messages WHERE conversation_id = ? COLLATE NOCASE\(predicate) ORDER BY id COLLATE NOCASE LIMIT ?")
        try statement.bind(1, bootstrap.conversationID.uuidString)
        if let after { try statement.bind(2, after.uuidString); try statement.bind(3, Int64(limit + 1)) }
        else { try statement.bind(2, Int64(limit + 1)) }
        var ids: [UUID] = []
        while try statement.step() {
            guard let raw = statement.strictUTF8Text(0), let id = UUID(uuidString: raw) else { throw FeedError.invalidIdentifier }
            ids.append(id)
        }
        let hasMore = ids.count > limit
        let selected = Array(ids.prefix(limit))
        var messages: [Message] = []
        for id in selected {
            guard let message = try message(db, id: id, conversationID: bootstrap.conversationID) else { throw FeedError.invalidSourceRow }
            messages.append(message)
        }
        return BootstrapPage(messages: messages, nextMessageID: hasMore ? selected.last : nil)
    }

    /// Reads bounded invalidations for one conversation and resolves each to
    /// the current canonical row in the same SQLite read snapshot. Multiple
    /// events for one message may resolve to the same latest state. A consumer
    /// must apply events in order and atomically save its projection + cursor.
    public static func changes(on db: OpaquePointer, conversationID: UUID,
                               after position: Position, limit: Int) throws -> ChangePage {
        try requireTransaction(db); try validateLimit(limit)
        guard try checkedGeneration(db) == position.generation else { throw FeedError.wrongGeneration }
        let currentHead = try head(db)
        guard position.sequence >= 0, position.sequence <= currentHead else { throw FeedError.invalidCursor }
        // Scan the global sequence so a missing row cannot silently advance
        // a scoped cursor. Unrelated conversation IDs are never returned.
        let statement = try prepare(db, "SELECT sequence,CASE WHEN length(CAST(conversation_id AS BLOB))=36 THEN conversation_id ELSE NULL END,CASE WHEN length(CAST(message_id AS BLOB))=36 THEN message_id ELSE NULL END FROM floe_msgfeed_changes_v1 WHERE sequence > ? AND sequence <= ? ORDER BY sequence LIMIT ?")
        try statement.bind(1, position.sequence); try statement.bind(2, currentHead); try statement.bind(3, Int64(limit))
        var entries: [(Int64, UUID)] = []
        var scanned = position.sequence
        var scanCount = 0
        while try statement.step() {
            guard let sequence = statement.int64(0), scanned < Int64.max, sequence == scanned + 1,
                  let rawConversation = statement.strictUTF8Text(1), let owner = UUID(uuidString: rawConversation),
                  let raw = statement.strictUTF8Text(2), let id = UUID(uuidString: raw) else { throw FeedError.invalidSourceRow }
            scanned = sequence; scanCount += 1
            if owner == conversationID { entries.append((sequence, id)) }
        }
        if scanned < currentHead && scanCount < limit { throw FeedError.invalidSourceRow }
        let hasMore = scanned < currentHead
        var results: [Change] = []
        for (sequence, id) in entries {
            results.append(Change(sequence: sequence, messageID: id,
                                  message: try message(db, id: id, conversationID: conversationID)))
        }
        return ChangePage(changes: results,
                          next: Position(generation: position.generation,
                                         sequence: scanned),
                          hasMore: hasMore)
    }

    private static func message(_ db: OpaquePointer, id: UUID, conversationID: UUID) throws -> Message? {
        // Case-insensitive UUID comparison matches Foundation UUID semantics;
        // refuse ambiguous legacy rows rather than choosing one arbitrarily.
        let count = try prepare(db, "SELECT COUNT(*) FROM messages WHERE id = ? COLLATE NOCASE")
        try count.bind(1, id.uuidString); guard try count.step(), let n = count.int64(0), n <= 1 else { throw FeedError.ambiguousIdentifier }
        if n == 0 { return nil }
        let query = try prepare(db, """
          SELECT CASE WHEN length(CAST(id AS BLOB))=36 THEN id ELSE NULL END,
                 CASE WHEN length(CAST(conversation_id AS BLOB))=36 THEN conversation_id ELSE NULL END,
                 CASE WHEN length(CAST(role AS BLOB))<=128 THEN role ELSE NULL END,
                 CASE WHEN length(CAST(content AS BLOB)) <= ? THEN content ELSE NULL END,
                 CASE WHEN length(CAST(created_at AS BLOB))<=128 THEN created_at ELSE NULL END,
                 CASE WHEN run_id IS NULL OR length(CAST(run_id AS BLOB))=36 THEN run_id ELSE NULL END,
                 run_id IS NOT NULL
          FROM messages WHERE id = ? COLLATE NOCASE AND conversation_id = ? COLLATE NOCASE LIMIT 1
          """)
        try query.bind(1, Int64(maximumMessageBytes)); try query.bind(2, id.uuidString); try query.bind(3, conversationID.uuidString)
        guard try query.step() else { return nil }
        guard let rawID = query.strictUTF8Text(0), UUID(uuidString: rawID) == id,
              let rawConversation = query.strictUTF8Text(1), UUID(uuidString: rawConversation) == conversationID,
              let role = query.strictUTF8Text(2), let created = query.strictUTF8Text(4) else { throw FeedError.invalidSourceRow }
        guard let content = query.strictUTF8Text(3) else {
            throw query.isNull(3) ? FeedError.oversizedMessage : FeedError.invalidSourceRow
        }
        let runID: UUID?
        if let run = query.strictUTF8Text(5) { guard let parsed = UUID(uuidString: run) else { throw FeedError.invalidIdentifier }; runID = parsed }
        else if query.int64(6) != 0 { throw FeedError.invalidIdentifier }
        else { runID = nil }
        var budget = content.utf8.count + role.utf8.count + created.utf8.count
        guard budget <= maximumMessageBytes else { throw FeedError.oversizedMessage }
        let partsQuery = try prepare(db, """
          SELECT CASE WHEN length(CAST(id AS BLOB))=36 THEN id ELSE NULL END,part_index,
                 CASE WHEN length(CAST(kind AS BLOB))<=128 THEN kind ELSE NULL END,
                 CASE WHEN length(CAST(text AS BLOB)) <= ? THEN text ELSE NULL END,
                 CASE WHEN attachment_id IS NULL OR length(CAST(attachment_id AS BLOB))=36 THEN attachment_id ELSE NULL END,
                 CASE WHEN length(CAST(metadata_json AS BLOB)) <= ? THEN metadata_json ELSE NULL END,
                 CASE WHEN length(CAST(created_at AS BLOB))<=128 THEN created_at ELSE NULL END,
                 text IS NOT NULL, attachment_id IS NOT NULL
          FROM message_parts WHERE message_id = ? COLLATE NOCASE ORDER BY part_index LIMIT ?
          """)
        try partsQuery.bind(1, Int64(maximumMessageBytes)); try partsQuery.bind(2, Int64(maximumMessageBytes))
        try partsQuery.bind(3, id.uuidString); try partsQuery.bind(4, Int64(maximumParts + 1))
        var parts: [Part] = []
        while try partsQuery.step() {
            guard parts.count < maximumParts else { throw FeedError.oversizedMessage }
            guard let raw = partsQuery.strictUTF8Text(0), let partID = UUID(uuidString: raw),
                  let index = partsQuery.int64(1), let kind = partsQuery.strictUTF8Text(2),
                  let metadata = partsQuery.strictUTF8Text(5), let partCreated = partsQuery.strictUTF8Text(6),
                  let hasText = partsQuery.int64(7) else { throw FeedError.invalidSourceRow }
            let partCount = try prepare(db, "SELECT COUNT(*) FROM message_parts WHERE id = ? COLLATE NOCASE")
            try partCount.bind(1, partID.uuidString)
            guard try partCount.step(), partCount.int64(0) == 1 else { throw FeedError.ambiguousIdentifier }
            let text = partsQuery.strictUTF8Text(3)
            if hasText != 0 && text == nil {
                throw partsQuery.isNull(3) ? FeedError.oversizedMessage : FeedError.invalidSourceRow
            }
            let attachment: UUID?
            if let rawAttachment = partsQuery.strictUTF8Text(4) {
                guard let parsed = UUID(uuidString: rawAttachment) else { throw FeedError.invalidIdentifier }; attachment = parsed
            } else if partsQuery.int64(8) != 0 { throw FeedError.invalidIdentifier }
            else { attachment = nil }
            guard ["text", "reasoning", "image", "file", "interactive"].contains(kind),
                  (try? JSONDecoder().decode([String: String].self, from: Data(metadata.utf8))) != nil else { throw FeedError.invalidSourceRow }
            budget += kind.utf8.count + (text?.utf8.count ?? 0) + metadata.utf8.count + partCreated.utf8.count
            guard budget <= maximumMessageBytes else { throw FeedError.oversizedMessage }
            parts.append(Part(id: partID, index: index, kind: kind, text: text,
                              attachmentID: attachment, metadataJSON: metadata, createdAt: partCreated))
        }
        return Message(id: id, conversationID: conversationID, role: role, content: content,
                       createdAt: created, runID: runID, parts: parts)
    }

    private static func validateLimit(_ limit: Int) throws {
        guard (1...maximumPageSize).contains(limit) else { throw FeedError.invalidPageSize }
    }
    private static func requireTransaction(_ db: OpaquePointer) throws {
        guard sqlite3_get_autocommit(db) == 0 else { throw FeedError.transactionRequired }
    }
    private static func checkedGeneration(_ db: OpaquePointer) throws -> UUID {
        let placeholders = objectNames.map { _ in "?" }.joined(separator: ",")
        let objects = try prepare(db, "SELECT COUNT(*) FROM sqlite_schema WHERE name IN (\(placeholders))")
        for (offset, name) in objectNames.enumerated() { try objects.bind(offset + 1, name) }
        guard try objects.step(), objects.int64(0) == Int64(objectNames.count) else { throw FeedError.unavailable }
        let result = try prepare(db, "SELECT generation FROM floe_msgfeed_meta_v1 WHERE singleton=1")
        guard try result.step(), let text = result.strictUTF8Text(0), let generation = UUID(uuidString: text), try !result.step() else { throw FeedError.unavailable }
        return generation
    }
    private static func head(_ db: OpaquePointer) throws -> Int64 {
        try scalar(db, "SELECT head FROM floe_msgfeed_meta_v1 WHERE singleton=1")
    }
    private static func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        let statement = try prepare(db, sql)
        guard try statement.step(), let value = statement.int64(0) else { throw FeedError.invalidSourceRow }
        return value
    }
    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw FeedError.sqlite(code: status, message: String(cString: sqlite3_errmsg(db))) }
        return SQLiteStatement(handle: statement, database: db)
    }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &message)
        guard status == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let message { sqlite3_free(message) }
            throw FeedError.sqlite(code: status, message: text)
        }
    }
}
