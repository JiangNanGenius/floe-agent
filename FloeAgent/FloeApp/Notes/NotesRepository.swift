// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeNotes
import FloePersistence

/// One lazy store per process, shared by editor windows and tool runners.
actor NotesRepository {
    static let shared = NotesRepository()
    private var instance: NotesStore?
    private weak var conversationCenter: ConversationCenter?
    private var reconcilingAssistantCleanup = false

    func bindConversationCenter(_ center: ConversationCenter) { conversationCenter = center }

    func requireAssistantAvailable(conversationID: UUID) async throws {
        guard let store = try existingStore() else { throw NoteError.resourceUnavailable }
        guard try await store.assistantOriginalIsAvailable(conversationID: conversationID) == true else { throw NoteError.notFound }
    }

    func stopAssistantHistory(documentID: UUID, in suppliedStore: NotesStore? = nil) async throws -> PersonalFileAssistantStopLease {
        let selectedStore = try suppliedStore ?? store()
        let ids = try await selectedStore.assistantHistory(documentID: documentID)
        guard !ids.isEmpty else { return await PersonalFileAssistantStopLease() }
        guard let conversationCenter else { throw NoteError.resourceUnavailable }
        var leases: [PersonalFileAssistantStopLease] = []
        do {
            for id in ids {
                leases.append(try await conversationCenter.stopNotesAssistantRetainingLease(conversationID: id))
            }
            let held = leases
            return await PersonalFileAssistantStopLease { for lease in held { lease.finish() } }
        } catch {
            for lease in leases { await lease.finish() }
            throw error
        }
    }

    /// Exact cleanup IDs commit with permanent note deletion. A failed native
    /// cleanup remains durable for the next reload; no raw task data deletion.
    func reconcileAssistantCleanup(in suppliedStore: NotesStore? = nil) async throws {
        guard !reconcilingAssistantCleanup, let conversationCenter, let store = try suppliedStore ?? existingStore() else { return }
        reconcilingAssistantCleanup = true; defer { reconcilingAssistantCleanup = false }
        for id in try await store.pendingAssistantCleanup() {
            if let row = try await conversationCenter.environment.conversationStore.conversation(id: id) {
                guard row.purpose == .notes else { throw NoteError.conflict }
                try await conversationCenter.deleteConversation(id: id)
            }
            try await store.acknowledgeAssistantCleanup(id)
        }
    }

    func drainWriterForSuspension() async {
        await instance?.drainWriterForSuspension()
    }
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
        try await reconcileAssistantCleanup()
    }

    nonisolated static func markAssistantOwnership(_ ids: [UUID], database: DatabaseManager) async throws {
        try await database.writer { db in
            for id in ids {
                try db.execute(sql: "UPDATE conversations SET purpose='notes' WHERE id=? AND purpose='ordinary'", arguments: [id.uuidString])
            }
        }
    }

    /// Read-only callers never create an empty Notes library.
    func existingStore() throws -> NotesStore? {
        if let instance { return instance }
        let file = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("FloeAgent/Notes/notes.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try store()
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

    /// Test/qualification seam: point the shared repository at an isolated
    /// Notes store (pass nil to clear). Used by the NativeNotes cover tests so
    /// tool-level checks never read or write the real Notes library.
    func setStoreOverride(_ value: NotesStore?) { instance = value }

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
