// SPDX-License-Identifier: MPL-2.0
// Foundation + GRDB only (no UIKit): the binding store compiles unchanged on
// every Apple platform, which keeps the binding queries directly testable.
import CryptoKit
import Foundation
import GRDB

/// One durable document → assistant binding. Binding truth lives only in
/// `document_assistants`; titles, archive flags and message content can
/// never substitute for it.
struct StudioAssistantBinding: Codable, Sendable, Hashable {
    var projectID: UUID
    var conversationID: UUID
}

/// Native selection bindings live outside documents and exported preferences.
/// Imported work packages and model-authored metadata can never mint grants.
actor StudioDocumentAccess {
    private let pool: DatabasePool
    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pool = try DatabasePool(path: root.appendingPathComponent("access.sqlite").path)
        try pool.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS document_access (
                    conversation_id TEXT NOT NULL,
                    project_id TEXT NOT NULL,
                    can_edit INTEGER NOT NULL,
                    PRIMARY KEY(conversation_id, project_id)
                );
                CREATE TABLE IF NOT EXISTS document_assistants (
                    project_id TEXT PRIMARY KEY NOT NULL,
                    conversation_id TEXT UNIQUE NOT NULL
                );
                CREATE TABLE IF NOT EXISTS document_creations (
                    operation_key TEXT PRIMARY KEY NOT NULL,
                    project_id TEXT NOT NULL,
                    payload_digest TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS document_file_lifecycles (
                    operation_id TEXT PRIMARY KEY NOT NULL,
                    entry_id TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    file_committed INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS document_file_lifecycle_members (
                    project_id TEXT PRIMARY KEY NOT NULL,
                    conversation_id TEXT UNIQUE,
                    operation_id TEXT NOT NULL
                );
                CREATE UNIQUE INDEX IF NOT EXISTS document_file_lifecycle_entry ON document_file_lifecycles(entry_id);
                """)
        }
    }
    func canAccess(conversationID: UUID, projectID: UUID, editing: Bool) throws -> Bool {
        try pool.read { db in
            guard let row = try Row.fetchOne(db,
                sql: "SELECT can_edit FROM document_access WHERE conversation_id=? AND project_id=?",
                arguments: [conversationID.uuidString, projectID.uuidString]) else { return false }
            let editable: Bool = row["can_edit"]
            return !editing || editable
        }
    }
    func revokeAccess(conversationID: UUID, projectID: UUID) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM document_access WHERE conversation_id=? AND project_id=?",
                arguments: [conversationID.uuidString, projectID.uuidString])
        }
    }
    func projectIDs(conversationID: UUID) throws -> [UUID] {
        try pool.read { db in
            try String.fetchAll(db, sql: "SELECT project_id FROM document_access WHERE conversation_id=? ORDER BY project_id",
                arguments: [conversationID.uuidString]).compactMap(UUID.init(uuidString:))
        }
    }
    func assistant(projectID: UUID) throws -> UUID? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT conversation_id FROM document_assistants WHERE project_id=?",
                arguments: [projectID.uuidString]).flatMap(UUID.init(uuidString:))
        }
    }
    /// Every live binding, for task-center grouping and foreground recovery.
    /// Read-only and allocation-bounded by the table's one-row-per-project key.
    func assistantBindings() throws -> [StudioAssistantBinding] {
        try pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT project_id, conversation_id FROM document_assistants ORDER BY project_id
                """).compactMap { row in
                guard let projectID = UUID(uuidString: row["project_id"]),
                      let conversationID = UUID(uuidString: row["conversation_id"]) else { return nil }
                return StudioAssistantBinding(projectID: projectID, conversationID: conversationID)
            }
        }
    }
    /// Removes one document's assistant binding (never the conversation's
    /// transcripts or runs). The file-deletion lifecycle package uses this
    /// when a file and its assistant are cleaned up together; callers own
    /// stopping that file's runs first.
    func removeAssistant(projectID: UUID) throws {
        try pool.write { db in
            let pending = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM document_file_lifecycle_members WHERE project_id=?)",
                arguments: [projectID.uuidString]) ?? false
            guard !pending else { throw PersonalFileAssistantLifecycleError.pending }
            try db.execute(sql: "DELETE FROM document_assistants WHERE project_id=?",
                arguments: [projectID.uuidString])
        }
    }
    func assistantProject(conversationID: UUID) throws -> UUID? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT project_id FROM document_assistants WHERE conversation_id=?",
                arguments: [conversationID.uuidString]).flatMap(UUID.init(uuidString:))
        }
    }
    func bindAssistant(conversationID: UUID, projectID: UUID) throws {
        try pool.write { db in
            guard try !Self.hasLifecycle(db, projectID: projectID, conversationID: conversationID) else {
                throw PersonalFileAssistantLifecycleError.pending
            }
            try db.execute(sql: "INSERT INTO document_assistants(project_id,conversation_id) VALUES (?,?) ON CONFLICT(project_id) DO UPDATE SET conversation_id=excluded.conversation_id",
                arguments: [projectID.uuidString, conversationID.uuidString])
            try db.execute(sql: "INSERT INTO document_access(conversation_id,project_id,can_edit) VALUES (?,?,1) ON CONFLICT(conversation_id,project_id) DO UPDATE SET can_edit=1",
                arguments: [conversationID.uuidString, projectID.uuidString])
        }
    }
    /// Reservations bind a native-created document to one exact approved call.
    /// A retry can reopen the same completed original after a process restart.
    func reserveCreation(operationKey: String, digest: String) throws -> UUID {
        try pool.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT project_id,payload_digest FROM document_creations WHERE operation_key=?",
                arguments: [operationKey]) {
                let stored: String = row["payload_digest"]
                let project: String = row["project_id"]
                guard stored == digest, let id = UUID(uuidString: project) else { throw PersonalContentError.changedDocument }
                return id
            }
            let id = UUID()
            try db.execute(sql: "INSERT INTO document_creations(operation_key,project_id,payload_digest) VALUES (?,?,?)",
                arguments: [operationKey, id.uuidString, digest])
            return id
        }
    }
    /// Idempotent companion creation reuses an already authorized parent.
    /// This records replay identity only; it never grants document access.
    func reserveCompanionCreation(operationKey: String, digest: String, parentID: UUID) throws {
        try pool.write { db in
            if let row = try Row.fetchOne(db, sql: "SELECT project_id,payload_digest FROM document_creations WHERE operation_key=?", arguments: [operationKey]) {
                let storedID: String = row["project_id"], storedDigest: String = row["payload_digest"]
                guard UUID(uuidString: storedID) == parentID, storedDigest == digest else { throw PersonalContentError.changedDocument }
                return
            }
            try db.execute(sql: "INSERT INTO document_creations(operation_key,project_id,payload_digest) VALUES (?,?,?)",
                arguments: [operationKey, parentID.uuidString, digest])
        }
    }
    func finishCreation(conversationID: UUID, projectID: UUID) throws {
        try pool.write { db in
            guard try !Self.hasLifecycle(db, projectID: projectID, conversationID: conversationID) else {
                throw PersonalFileAssistantLifecycleError.pending
            }
            try db.execute(sql: """
                INSERT INTO document_access(conversation_id,project_id,can_edit) VALUES (?,?,1)
                ON CONFLICT(conversation_id,project_id) DO NOTHING
                """, arguments: [conversationID.uuidString, projectID.uuidString])
        }
    }

    private static func hasLifecycle(_ db: Database, projectID: UUID, conversationID: UUID) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM document_file_lifecycle_members WHERE project_id=? OR conversation_id=?)",
            arguments: [projectID.uuidString, conversationID.uuidString]) ?? false
    }

    func requireNoFileLifecycle(projectID: UUID, conversationID: UUID) throws {
        try pool.read { db in
            guard try !Self.hasLifecycle(db, projectID: projectID, conversationID: conversationID) else {
                throw PersonalFileAssistantLifecycleError.pending
            }
        }
    }

    func pendingFileLifecycleConversationIDs() throws -> Set<UUID> {
        try pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT conversation_id FROM document_file_lifecycle_members WHERE conversation_id IS NOT NULL")
                .compactMap(UUID.init(uuidString:)))
        }
    }

    func beginFileLifecycle(action: PersonalFileAssistantLifecycleIntent.Action, entryID: UUID,
        rootPath: String, relativePath: String, members: [PersonalContentRecord]) throws -> PersonalFileAssistantLifecycleIntent {
        try pool.write { db in
            let sorted = members.sorted { $0.id.uuidString < $1.id.uuidString }
            guard Set(sorted.map(\.id)).count == sorted.count else { throw PersonalFileAssistantLifecycleError.changed }
            if let saved = try Data.fetchOne(db, sql: "SELECT payload FROM document_file_lifecycles WHERE entry_id=?",
                arguments: [entryID.uuidString]) {
                let value = try JSONDecoder().decode(PersonalFileAssistantLifecycleIntent.self, from: saved)
                guard value.action == action, value.rootPath == rootPath, value.relativePath == relativePath,
                      value.members == sorted else { throw PersonalFileAssistantLifecycleError.changed }
                return value
            }
            var bindings: [StudioAssistantBinding] = []
            for member in sorted {
                let pending = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM document_file_lifecycle_members WHERE project_id=?)",
                    arguments: [member.id.uuidString]) ?? false
                guard !pending else { throw PersonalFileAssistantLifecycleError.pending }
                if let raw = try String.fetchOne(db, sql: "SELECT conversation_id FROM document_assistants WHERE project_id=?",
                    arguments: [member.id.uuidString]), let conversationID = UUID(uuidString: raw) {
                    bindings.append(.init(projectID: member.id, conversationID: conversationID))
                }
            }
            let intent = PersonalFileAssistantLifecycleIntent(id: UUID(), entryID: entryID, action: action,
                rootPath: rootPath, relativePath: relativePath, members: sorted, bindings: bindings)
            let payload = try JSONEncoder().encode(intent)
            try db.execute(sql: "INSERT INTO document_file_lifecycles(operation_id,entry_id,payload) VALUES (?,?,?)",
                arguments: [intent.id.uuidString, entryID.uuidString, payload])
            for member in sorted {
                let conversationID = bindings.first { $0.projectID == member.id }?.conversationID.uuidString
                try db.execute(sql: "INSERT INTO document_file_lifecycle_members(project_id,conversation_id,operation_id) VALUES (?,?,?)",
                    arguments: [member.id.uuidString, conversationID, intent.id.uuidString])
            }
            return intent
        }
    }

    func pendingFileLifecycles(entryID: UUID? = nil) throws -> [PersonalFileAssistantLifecycleIntent] {
        try pool.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM document_file_lifecycles WHERE ? IS NULL OR entry_id=? ORDER BY operation_id",
                arguments: [entryID?.uuidString, entryID?.uuidString])
                .map { try JSONDecoder().decode(PersonalFileAssistantLifecycleIntent.self, from: $0) }
        }
    }

    private static func validateFileLifecycle(_ intent: PersonalFileAssistantLifecycleIntent, db: Database) throws {
        guard let payload = try Data.fetchOne(db, sql: "SELECT payload FROM document_file_lifecycles WHERE operation_id=?",
            arguments: [intent.id.uuidString]),
              try JSONDecoder().decode(PersonalFileAssistantLifecycleIntent.self, from: payload) == intent else {
            throw PersonalFileAssistantLifecycleError.changed
        }
        for binding in intent.bindings {
            let current = try String.fetchOne(db, sql: "SELECT conversation_id FROM document_assistants WHERE project_id=?",
                arguments: [binding.projectID.uuidString]).flatMap(UUID.init(uuidString:))
            guard current == binding.conversationID || (intent.action == .purge && current == nil) else {
                throw PersonalFileAssistantLifecycleError.changed
            }
        }
    }

    func validateFileLifecycle(_ intent: PersonalFileAssistantLifecycleIntent) throws {
        try pool.read { try Self.validateFileLifecycle(intent, db: $0) }
    }

    func markFileLifecycleCommitted(_ intent: PersonalFileAssistantLifecycleIntent) throws {
        try pool.write { db in
            try Self.validateFileLifecycle(intent, db: db)
            try db.execute(sql: "UPDATE document_file_lifecycles SET file_committed=1 WHERE operation_id=?", arguments: [intent.id.uuidString])
        }
    }

    func finishFileLifecycle(_ intent: PersonalFileAssistantLifecycleIntent) throws {
        try pool.write { db in
            try Self.validateFileLifecycle(intent, db: db)
            try db.execute(sql: "DELETE FROM document_file_lifecycle_members WHERE operation_id=?", arguments: [intent.id.uuidString])
            try db.execute(sql: "DELETE FROM document_file_lifecycles WHERE operation_id=?", arguments: [intent.id.uuidString])
        }
    }

    /// Exact CAS acknowledgement AFTER the existing conversation cleanup.
    /// A delayed completion can neither revoke nor remove a replacement.
    @discardableResult func removeAssistant(projectID: UUID, expectedConversationID: UUID) throws -> Bool {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM document_assistants WHERE project_id=? AND conversation_id=?",
                arguments: [projectID.uuidString, expectedConversationID.uuidString])
            return db.changesCount == 1
        }
    }

    func finishPurgedAssistant(_ binding: StudioAssistantBinding) throws {
        try pool.write { db in
            let raw = try String.fetchOne(db, sql: "SELECT conversation_id FROM document_assistants WHERE project_id=?",
                arguments: [binding.projectID.uuidString])
            if let raw, raw != binding.conversationID.uuidString { throw PersonalFileAssistantLifecycleError.changed }
            try db.execute(sql: "DELETE FROM document_assistants WHERE project_id=? AND conversation_id=?",
                arguments: [binding.projectID.uuidString, binding.conversationID.uuidString])
            try db.execute(sql: "DELETE FROM document_access WHERE conversation_id=?", arguments: [binding.conversationID.uuidString])
        }
    }

    func revokePurgedFileAuthority(projectIDs: Set<UUID>) throws {
        try pool.write { db in
            for id in projectIDs {
                try db.execute(sql: "DELETE FROM document_access WHERE project_id=?", arguments: [id.uuidString])
                try db.execute(sql: "DELETE FROM document_creations WHERE project_id=?", arguments: [id.uuidString])
            }
        }
    }
}
