// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeNotes
import FloeModels

import FloeCore
/// Shared selection payload; each product keeps its own composer and undo state.
@MainActor
enum NotesKnowledgeAttachment {
    static func prepare(document: NoteDocument, store: NotesStore, files: FilesCenter) async throws -> AttachmentRef? {
        guard let resource = document.officeResourceID, let name = document.officeFileName else { return nil }
        guard !name.isEmpty, (name as NSString).lastPathComponent == name, name != ".", name != ".." else { throw NoteError.resourceUnavailable }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-attachment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: try await store.resourceURL(resource), to: file)
        return try await files.registerPickedDocument(url: file, displayName: name, compressImage: false)
    }
    static func reference(_ document: NoteDocument) -> String {FloeL10n.l("notes.notes_knowledge_attachment.note_material_selected_documentid_use_notes", document.title, document.id.uuidString)
    }
}
#endif
