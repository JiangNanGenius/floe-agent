// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeNotes

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
