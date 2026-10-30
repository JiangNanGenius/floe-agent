import Foundation
import GRDB
import Testing
@testable import FloeNotes

/// Run this process-wide notification regression as an exclusive test
/// selection, separate from suites which deliberately perform database writes.
@Suite("Notes process suspension", .serialized)
struct NoteSuspensionTests {
    @Test("An independent Notes writer releases admission and resumes without losing content")
    func independentNotesWriterFollowsProcessFence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-suspension-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try NotesStore(root: root)
        let original = try await store.createNotebook(title: "Before suspension")
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
        defer { NotificationCenter.default.post(name: Database.resumeNotification, object: nil) }
        await store.drainWriterForSuspension()
        do {
            _ = try await store.createNotebook(title: "Must not commit while suspended")
            Issue.record("The independent Notes writer admitted a suspended transaction")
        } catch let error as DatabaseError {
            #expect(error.resultCode == .SQLITE_ABORT)
        }
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
        let resumed = try await store.createNotebook(title: "After resume")
        let books = try await store.notebooks()
        #expect(Set(books.map(\.id)) == Set([original.id, resumed.id]))
    }
}
