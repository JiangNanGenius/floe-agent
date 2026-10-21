// SPDX-License-Identifier: MPL-2.0
//
// FloeApp — adopt a committed system-opened document into the visible Notes
// session (S5 P3).
//
// `select` already refuses to switch away from a note with unsaved edits or a
// save in flight. This helper therefore never discards editor state: a failed
// adoption leaves the current note mounted and the imported document is still
// available in the Notes library.

#if canImport(UIKit)
import Foundation
import FloeNotes
import FloeCore

@MainActor
extension NotesSession {
    /// Opens the exact imported document after a real Notes commit. Returns
    /// false when the store cannot be read, the document is gone, or the
    /// current note must be saved/closed first.
    @discardableResult
    func adoptImportedDocument(_ documentID: UUID) async -> Bool {
        if store == nil { await open() }
        guard let store else { return false }
        do { _ = try await store.document(documentID) }
        catch { return false }
        do { try await reload() }
        catch { return false }
        guard let value = documents.first(where: { $0.id == documentID && $0.deletedAt == nil }) else {
            return false
        }
        return await select(value)
    }
}
#endif
