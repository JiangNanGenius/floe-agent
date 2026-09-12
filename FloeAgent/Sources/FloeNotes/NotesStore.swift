// SPDX-License-Identifier: MPL-2.0
import Foundation
import GRDB
import Crypto

/// A long-lived database independent from conversations and task workspaces.
/// All mutations, revisions, history and resource references commit in one SQLite transaction.
public actor NotesStore {
    private let database: DatabaseQueue
    private let resources: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        resources = root.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        database = try DatabaseQueue(path: root.appendingPathComponent("notes.sqlite").path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("notes.v1") { db in
            try db.execute(sql: """
                CREATE TABLE notebooks(id TEXT PRIMARY KEY NOT NULL, body BLOB NOT NULL);
                CREATE TABLE documents(id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL,
                    updated DOUBLE NOT NULL, deleted DOUBLE, body BLOB NOT NULL, cursor INTEGER NOT NULL DEFAULT 0);
                CREATE TABLE history(document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL, title TEXT NOT NULL, before BLOB NOT NULL, after BLOB NOT NULL,
                    PRIMARY KEY(document_id, position));
                CREATE TABLE resources(id TEXT PRIMARY KEY NOT NULL, hash TEXT NOT NULL UNIQUE,
                    byte_count INTEGER NOT NULL, filename TEXT NOT NULL, media_type TEXT NOT NULL);
                CREATE TABLE resource_refs(document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                    resource_id TEXT NOT NULL REFERENCES resources(id), PRIMARY KEY(document_id, resource_id));
                CREATE VIRTUAL TABLE note_search USING fts5(document_id UNINDEXED, title, body, tokenize='unicode61');
                """)
        }
        migrator.registerMigration("notes.v2.assistant") { db in
            try db.execute(sql: """
                CREATE TABLE assistant_scopes(conversation_id TEXT NOT NULL, document_id TEXT NOT NULL REFERENCES documents(id),
                    can_edit INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(conversation_id, document_id));
                CREATE TABLE assistant_threads(document_id TEXT PRIMARY KEY NOT NULL REFERENCES documents(id), conversation_id TEXT NOT NULL);
                CREATE TABLE edit_receipts(request_id TEXT PRIMARY KEY NOT NULL, document_id TEXT NOT NULL, body BLOB NOT NULL);
                """)
        }
        try migrator.migrate(database)
    }

    public func notebooks() throws -> [Notebook] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT body FROM notebooks ORDER BY rowid").map { try decoder.decode(Notebook.self, from: $0) }
        }
    }

    @discardableResult public func createNotebook(title: String) throws -> Notebook {
        defer { publishChange() }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NoteError.invalidOperation("请输入笔记本名称。") }
        let book = Notebook(title: title)
        try database.write { db in try db.execute(sql: "INSERT INTO notebooks VALUES (?, ?)", arguments: [book.id.uuidString, try encoder.encode(book)]) }
        return book
    }

    public func renameNotebook(_ id: UUID, title: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= 4096 else { throw NoteError.invalidOperation("笔记本名称为空或过长。") }
        try database.write { db in
            guard let body = try Data.fetchOne(db, sql: "SELECT body FROM notebooks WHERE id=?", arguments: [id.uuidString]) else { throw NoteError.notFound }
            var book = try decoder.decode(Notebook.self, from: body)
            book.title = title
            try db.execute(sql: "UPDATE notebooks SET body=? WHERE id=?", arguments: [try encoder.encode(book), id.uuidString])
        }
        publishChange()
    }

    public func documents(includeTrash: Bool = false) throws -> [NoteDocument] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT body FROM documents \(includeTrash ? "" : "WHERE deleted IS NULL") ORDER BY updated DESC")
                .map { try decoder.decode(NoteDocument.self, from: $0) }
        }
    }

    public func document(_ id: UUID) throws -> NoteDocument {
        try database.read { try read(id, db: $0) }
    }

    @discardableResult public func create(_ document: NoteDocument) throws -> NoteDocument {
        defer { publishChange() }
        var value = document
        value.revision = 1; value.createdAt = Date(); value.updatedAt = value.createdAt; value.deletedAt = nil
        try value.validate()
        try database.write { db in
            try validateResources(value, db: db)
            try db.execute(sql: "INSERT INTO documents(id,revision,updated,body) VALUES(?,?,?,?)",
                           arguments: [value.id.uuidString, value.revision, value.updatedAt.timeIntervalSince1970, try encoder.encode(value)])
            try updateReferencesAndSearch(value, db: db)
        }
        return value
    }

    @discardableResult public func apply(_ batch: NoteEditBatch, authorizedConversationID: UUID? = nil) throws -> NoteDocument {
        defer { publishChange() }
        guard !batch.edits.isEmpty, batch.edits.count <= 10_000 else { throw NoteError.invalidOperation("编辑批次为空或过大。") }
        return try database.write { db in
            // Recheck tool authority inside the same write transaction as its edits.
            // A native revoke while the Agent prepares a batch must win at commit.
            if let conversation = authorizedConversationID {
                guard try Bool.fetchOne(db, sql: "SELECT can_edit FROM assistant_scopes WHERE conversation_id=? AND document_id=?", arguments: [conversation.uuidString, batch.documentID.uuidString]) == true else {
                    throw NoteError.invalidOperation("此对话已没有修改该资料的授权。")
                }
            }
            if let request = batch.requestID,
               let receipt = try Row.fetchOne(db, sql: "SELECT document_id,body FROM edit_receipts WHERE request_id=?", arguments: [request]) {
                let id: String = receipt["document_id"]
                guard id == batch.documentID.uuidString else { throw NoteError.conflict }
                return try decoder.decode(NoteDocument.self, from: receipt["body"])
            }
            let before = try read(batch.documentID, db: db)
            guard before.deletedAt == nil else { throw NoteError.invalidOperation("请先从回收站恢复内容。") }
            guard before.revision == batch.expectedRevision else { throw NoteError.conflict }
            var after = before
            for edit in batch.edits { try edit.apply(to: &after) }
            after.revision += 1; after.updatedAt = Date()
            try after.validate(); try validateResources(after, db: db)
            let cursor = try Int.fetchOne(db, sql: "SELECT cursor FROM documents WHERE id=?", arguments: [before.id.uuidString]) ?? 0
            try db.execute(sql: "DELETE FROM history WHERE document_id=? AND position>?", arguments: [before.id.uuidString, cursor])
            try db.execute(sql: "INSERT INTO history VALUES(?,?,?,?,?)", arguments: [before.id.uuidString, cursor + 1, batch.title, try encoder.encode(before), try encoder.encode(after)])
            try persist(after, cursor: cursor + 1, db: db)
            if let request = batch.requestID {
                try db.execute(sql: "INSERT INTO edit_receipts VALUES(?,?,?)", arguments: [request, after.id.uuidString, try encoder.encode(after)])
            }
            return after
        }
    }

    public func editReceipt(requestID: String, documentID: UUID) throws -> NoteDocument? {
        try database.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT document_id,body FROM edit_receipts WHERE request_id=?", arguments: [requestID]) else { return nil }
            let id: String = row["document_id"]
            guard id == documentID.uuidString else { throw NoteError.conflict }
            return try decoder.decode(NoteDocument.self, from: row["body"])
        }
    }

    public func historyState(_ id: UUID) throws -> NoteHistoryState {
        try database.read { db in
            guard let cursor = try Int.fetchOne(db, sql: "SELECT cursor FROM documents WHERE id=?", arguments: [id.uuidString]) else { throw NoteError.notFound }
            let next = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM history WHERE document_id=? AND position=?)", arguments: [id.uuidString, cursor + 1]) ?? false
            return NoteHistoryState(canUndo: cursor > 0, canRedo: next)
        }
    }

    @discardableResult public func undo(_ id: UUID, expectedRevision: Int, redo: Bool = false) throws -> NoteDocument {
        defer { publishChange() }
        return try database.write { db in
            let current = try read(id, db: db)
            guard current.revision == expectedRevision else { throw NoteError.conflict }
            guard current.deletedAt == nil else { throw NoteError.invalidOperation("请先恢复内容。") }
            let cursor = try Int.fetchOne(db, sql: "SELECT cursor FROM documents WHERE id=?", arguments: [id.uuidString]) ?? 0
            let position = redo ? cursor + 1 : cursor
            guard let data = try Data.fetchOne(db, sql: "SELECT \(redo ? "after" : "before") FROM history WHERE document_id=? AND position=?", arguments: [id.uuidString, position]) else {
                throw NoteError.invalidOperation(redo ? "没有可重做的编辑。" : "没有可撤销的编辑。")
            }
            var value = try decoder.decode(NoteDocument.self, from: data)
            // History restores content, never rewinds the monotonically increasing revision.
            value.revision = current.revision + 1; value.updatedAt = Date()
            try validateResources(value, db: db)
            try persist(value, cursor: redo ? cursor + 1 : cursor - 1, db: db)
            return value
        }
    }

    @discardableResult public func setTrashed(_ id: UUID, expectedRevision: Int, trashed: Bool) throws -> NoteDocument {
        defer { publishChange() }
        return try database.write { db in
            var value = try read(id, db: db)
            guard value.revision == expectedRevision else { throw NoteError.conflict }
            value.deletedAt = trashed ? Date() : nil; value.updatedAt = Date(); value.revision += 1
            let cursor = try Int.fetchOne(db, sql: "SELECT cursor FROM documents WHERE id=?", arguments: [id.uuidString]) ?? 0
            try persist(value, cursor: cursor, db: db)
            return value
        }
    }

    /// Returns source documents, not synthesized answers. Literal substring matching also supports CJK.
    public func search(_ query: String, limit: Int = 50) throws -> [NoteDocument] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return try database.read { db in
            try Data.fetchAll(db, sql: """
                SELECT d.body FROM documents d JOIN note_search s ON s.document_id=d.id
                WHERE d.deleted IS NULL AND (s.title LIKE ? ESCAPE '\\' OR s.body LIKE ? ESCAPE '\\')
                ORDER BY d.updated DESC LIMIT ?
                """, arguments: ["%\(escaped)%", "%\(escaped)%", min(200, max(1, limit))])
                .map { try decoder.decode(NoteDocument.self, from: $0) }
        }
    }

    /// Immutable, content-addressed files are promoted before their DB registration. An interrupted
    /// import may leave an unreferenced blob, but can never expose a registered partial file.
    public func importResource(from source: URL, mediaType: String) throws -> UUID {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let info = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true else { throw NoteError.invalidOperation("只能导入普通文件。") }
        guard (info.fileSize ?? 0) <= 536_870_912 else { throw NoteError.invalidOperation("单个手记资源不能超过 512 MB。") }
        let staging = resources.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        let handle = try FileHandle(forReadingFrom: staging)
        defer { try? handle.close() }
        var hasher = SHA256(); var count = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            count += chunk.count
            guard count <= 536_870_912 else { throw NoteError.invalidOperation("资源超过导入上限。") }
            hasher.update(data: chunk)
        }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let destination = resources.appendingPathComponent(hash)
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == count else { throw NoteError.resourceUnavailable }
            let existing = try FileHandle(forReadingFrom: destination); defer { try? existing.close() }
            var check = SHA256()
            while let chunk = try existing.read(upToCount: 1_048_576), !chunk.isEmpty { check.update(data: chunk) }
            guard check.finalize().map({ String(format: "%02x", $0) }).joined() == hash else { throw NoteError.resourceUnavailable }
        } else { try FileManager.default.moveItem(at: staging, to: destination) }
        return try database.write { db in
            if let existing = try String.fetchOne(db, sql: "SELECT id FROM resources WHERE hash=?", arguments: [hash]), let id = UUID(uuidString: existing) { return id }
            let id = UUID()
            try db.execute(sql: "INSERT INTO resources VALUES(?,?,?,?,?)", arguments: [id.uuidString, hash, count, source.lastPathComponent, mediaType])
            return id
        }
    }

    public func resourceURL(_ id: UUID) throws -> URL {
        let hash = try database.read { try String.fetchOne($0, sql: "SELECT hash FROM resources WHERE id=?", arguments: [id.uuidString]) }
        guard let hash, hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw NoteError.resourceUnavailable }
        let url = resources.appendingPathComponent(hash)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == resources.resolvingSymlinksInPath(),
              (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw NoteError.resourceUnavailable }
        return url
    }

    public func assistantConversation(documentID: UUID) throws -> UUID? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT conversation_id FROM assistant_threads WHERE document_id=?", arguments: [documentID.uuidString]).flatMap(UUID.init(uuidString:))
        }
    }

    /// Called by a visible native content selection, never from a model tool.
    public func bindAssistant(conversationID: UUID, documentID: UUID, canEdit: Bool) throws {
        try database.write { db in
            let value = try read(documentID, db: db)
            guard value.deletedAt == nil else { throw NoteError.notFound }
            try db.execute(sql: "INSERT OR REPLACE INTO assistant_threads VALUES(?,?)", arguments: [documentID.uuidString, conversationID.uuidString])
            try db.execute(sql: "INSERT OR REPLACE INTO assistant_scopes VALUES(?,?,?)", arguments: [conversationID.uuidString, documentID.uuidString, canEdit])
        }
    }

    /// Explicit native picker grant. Does not replace the document's own assistant thread.
    public func grantAccess(conversationID: UUID, documentID: UUID, canEdit: Bool) throws {
        try database.write { db in
            guard try read(documentID, db: db).deletedAt == nil else { throw NoteError.notFound }
            try db.execute(sql: "INSERT OR REPLACE INTO assistant_scopes VALUES(?,?,?)",
                           arguments: [conversationID.uuidString, documentID.uuidString, canEdit])
        }
    }

    public func accessGrants(conversationID: UUID) throws -> [UUID: Bool] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT s.document_id, s.can_edit FROM assistant_scopes s JOIN documents d ON s.document_id=d.id WHERE s.conversation_id=? AND d.deleted IS NULL", arguments: [conversationID.uuidString])
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let id = UUID(uuidString: row["document_id"] as String) else { return nil }
                return (id, row["can_edit"] as Bool)
            })
        }
    }

    /// Revokes future reads and edits without removing source documents or chat history.
    public func revokeAccess(conversationID: UUID, documentID: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM assistant_scopes WHERE conversation_id=? AND document_id=?", arguments: [conversationID.uuidString, documentID.uuidString])
        }
    }

    public func scopedDocuments(conversationID: UUID) throws -> [NoteDocument] {
        try database.read { db in
            try Data.fetchAll(db, sql: "SELECT d.body FROM documents d JOIN assistant_scopes s ON s.document_id=d.id WHERE s.conversation_id=? AND d.deleted IS NULL",
                              arguments: [conversationID.uuidString]).map { try decoder.decode(NoteDocument.self, from: $0) }
        }
    }

    public func authorize(conversationID: UUID?, documentID: UUID, editing: Bool) throws {
        guard let conversationID else { throw NoteError.invalidOperation("此任务没有已选择的手记资料。") }
        try database.read { db in
            guard let canEdit = try Bool.fetchOne(db, sql: "SELECT can_edit FROM assistant_scopes WHERE conversation_id=? AND document_id=?", arguments: [conversationID.uuidString, documentID.uuidString]),
                  !editing || canEdit else { throw NoteError.invalidOperation("请先在手记中选择此文档并打开助手。") }
            guard try read(documentID, db: db).deletedAt == nil else { throw NoteError.notFound }
        }
    }

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publishChange() { for continuation in observers.values { continuation.yield(()) } }

    private func read(_ id: UUID, db: Database) throws -> NoteDocument {
        guard let data = try Data.fetchOne(db, sql: "SELECT body FROM documents WHERE id=?", arguments: [id.uuidString]) else { throw NoteError.notFound }
        let value = try decoder.decode(NoteDocument.self, from: data)
        try value.validate()
        return value
    }
    private func validateResources(_ value: NoteDocument, db: Database) throws {
        if let book = value.notebookID,
           try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM notebooks WHERE id=?)", arguments: [book.uuidString]) != true {
            throw NoteError.invalidOperation("目标笔记本不存在。")
        }
        for id in value.resourceIDs {
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM resources WHERE id=?)", arguments: [id.uuidString]) == true else { throw NoteError.resourceUnavailable }
        }
    }
    private func persist(_ value: NoteDocument, cursor: Int, db: Database) throws {
        try db.execute(sql: "UPDATE documents SET revision=?,updated=?,deleted=?,body=?,cursor=? WHERE id=?",
                       arguments: [value.revision, value.updatedAt.timeIntervalSince1970, value.deletedAt?.timeIntervalSince1970, try encoder.encode(value), cursor, value.id.uuidString])
        try updateReferencesAndSearch(value, db: db)
    }
    private func updateReferencesAndSearch(_ value: NoteDocument, db: Database) throws {
        try db.execute(sql: "DELETE FROM resource_refs WHERE document_id=?", arguments: [value.id.uuidString])
        for id in value.resourceIDs { try db.execute(sql: "INSERT INTO resource_refs VALUES(?,?)", arguments: [value.id.uuidString, id.uuidString]) }
        try db.execute(sql: "DELETE FROM note_search WHERE document_id=?", arguments: [value.id.uuidString])
        if value.deletedAt == nil { try db.execute(sql: "INSERT INTO note_search VALUES(?,?,?)", arguments: [value.id.uuidString, value.title, value.searchableText]) }
        // Retain resources referenced by undo history. Cross-space GC is deliberately not run here.
    }
}
