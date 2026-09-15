// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeNotes
import FloePersistence

/// One lazy store per process, shared by editor windows and tool runners.
actor NotesRepository {
    static let shared = NotesRepository()
    private var instance: NotesStore?
    func runtimeContext(conversationID: UUID) async throws -> String? {
        // Ordinary chats must not initialize a new Notes library as a side effect.
        if instance == nil {
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent("FloeAgent/Notes/notes.sqlite")
            guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        }
        return try await store().assistantRuntimeContext(conversationID: conversationID)
    }

    /// Reconcile legacy bindings before publishing any ordinary chat list. Idempotent;
    /// no title heuristics, no message deletion, and no creation of a missing library.
    func reconcileAssistantOwnership(database: DatabaseManager) async throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("FloeAgent/Notes/notes.sqlite")
        guard instance != nil || FileManager.default.fileExists(atPath: root.path) else { return }
        let ids = try await store().assistantConversationIDs()
        try await Self.markAssistantOwnership(ids, database: database)
    }

    nonisolated static func markAssistantOwnership(_ ids: [UUID], database: DatabaseManager) async throws {
        try await database.writer { db in
            for id in ids {
                try db.execute(sql: "UPDATE conversations SET purpose='notes' WHERE id=? AND purpose='ordinary'", arguments: [id.uuidString])
            }
        }
    }

    func store() throws -> NotesStore {
        if let instance { return instance }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/Notes", isDirectory: true)
        let value = try NotesStore(root: root)
        instance = value
        return value
    }
}
#endif
