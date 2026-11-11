// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeNotes

@MainActor
enum ToolboxNotesExport {
    static func save(title: String, text: String) async throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 65_536,
              !title.isEmpty, title.utf8.count <= 4096 else {
            throw NoteError.invalidOperation(IDELanguageRunText.t("内容为空或过长，请调整后保存。", "The content is empty or too long. Adjust it before saving."))
        }
        var document = NoteDocument(title: title)
        let format = NotesTextLayout.formattedPages(text: text, source: nil)
        document.schemaVersion = 2
        document.pages = format.pages.map { page in
            var page = page
            page.elements = page.elements.map { element in var element = element; element.isAIGenerated = false; return element }
            return page
        }
        document.textSources = [format.sourceID.uuidString: text]
        let store = try await NotesRepository.shared.store()
        _ = try await store.create(document)
    }
}
#endif
