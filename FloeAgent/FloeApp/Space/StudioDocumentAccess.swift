// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import CryptoKit
import Foundation
import GRDB

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
    func assistantProject(conversationID: UUID) throws -> UUID? {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT project_id FROM document_assistants WHERE conversation_id=?",
                arguments: [conversationID.uuidString]).flatMap(UUID.init(uuidString:))
        }
    }
    func bindAssistant(conversationID: UUID, projectID: UUID) throws {
        try pool.write { db in
            try db.execute(sql: "INSERT INTO document_assistants(project_id,conversation_id) VALUES (?,?) ON CONFLICT(project_id) DO UPDATE SET conversation_id=excluded.conversation_id",
                arguments: [projectID.uuidString, conversationID.uuidString])
            try db.execute(sql: "INSERT INTO document_access(conversation_id,project_id,can_edit) VALUES (?,?,1)",
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
    func finishCreation(conversationID: UUID, projectID: UUID) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO document_access(conversation_id,project_id,can_edit) VALUES (?,?,1)
                ON CONFLICT(conversation_id,project_id) DO NOTHING
                """, arguments: [conversationID.uuidString, projectID.uuidString])
        }
    }
}
#endif
