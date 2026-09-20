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
        Self.pruneAssistantWorkspaces(under: root)
        return value
    }

    /// Per-conversation confined scratch for the document assistant. Staged
    /// inputs and generated outputs (charts, converted files) live only here;
    /// the run uses this root as its workspace root so the workspace ceiling
    /// and the guest share list confine every script to this task's mounts.
    /// Only copies ever land inside — never the user's original documents.
    nonisolated static func assistantWorkspace(conversationID: UUID) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/Notes/AssistantWorkspaces", isDirectory: true)
        let workspace = root.appendingPathComponent(conversationID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace
    }

    /// Scratch holds copies and generated outputs only, so abandoned
    /// workspaces (restarted or deleted assistant sessions) are pruned by
    /// age. 30 days keeps recent outputs recoverable without unbounded growth.
    private static func pruneAssistantWorkspaces(under notesRoot: URL) {
        let root = notesRoot.appendingPathComponent("AssistantWorkspaces", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < cutoff {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}
#endif
