// SPDX-License-Identifier: MPL-2.0
import Foundation

import FloeCore
/// Pure page selection for `notes.export format=pdf`. Order follows the
/// requested IDs (so "pages 3 then 1" exports in that order), duplicates and
/// unknown IDs fail closed, and a non-notebook document is rejected before any
/// file work starts.
public enum NoteExportSelection {
    public static let maximumPages = 500

    public static func pages(of document: NoteDocument, pageIDs: [UUID]?) throws -> [NotePage] {
        guard document.kind == .notebook else {
            throw NoteError.invalidOperation(FloeL10n.l("notes.note_export_selection.only_note_documents_can_be_exported"))
        }
        guard let pageIDs, !pageIDs.isEmpty else {
            guard !document.pages.isEmpty else { throw NoteError.invalidOperation(FloeL10n.l("notes.notes_export.no_pages_to_export")) }
            return document.pages
        }
        guard pageIDs.count <= maximumPages else {
            throw NoteError.invalidOperation(FloeL10n.l("notes.note_export_selection.at_most_pages_can_be_exported", maximumPages))
        }
        guard Set(pageIDs).count == pageIDs.count else {
            throw NoteError.invalidOperation(FloeL10n.l("notes.note_export_selection.the_export_page_list_contains_duplicate"))
        }
        return try pageIDs.map { id in
            guard let page = document.pages.first(where: { $0.id == id }) else { throw NoteError.notFound }
            return page
        }
    }
}
