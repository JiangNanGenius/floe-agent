// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeNotes

/// One lazy store per process, shared by editor windows and tool runners.
actor NotesRepository {
    static let shared = NotesRepository()
    private var instance: NotesStore?
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
