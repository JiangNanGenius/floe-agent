// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Pure page selection for `notes.export format=pdf`. Order follows the
/// requested IDs (so "pages 3 then 1" exports in that order), duplicates and
/// unknown IDs fail closed, and a non-notebook document is rejected before any
/// file work starts.
public enum NoteExportSelection {
    public static let maximumPages = 500

    public static func pages(of document: NoteDocument, pageIDs: [UUID]?) throws -> [NotePage] {
        guard document.kind == .notebook else {
            throw NoteError.invalidOperation("只有手记文档可以导出 PDF；Office 请用 document.pdf.export，导图请用大纲导出。")
        }
        guard let pageIDs, !pageIDs.isEmpty else {
            guard !document.pages.isEmpty else { throw NoteError.invalidOperation("没有可导出的页面。") }
            return document.pages
        }
        guard pageIDs.count <= maximumPages else {
            throw NoteError.invalidOperation("一次最多导出 \(maximumPages) 页，请分批导出。")
        }
        guard Set(pageIDs).count == pageIDs.count else {
            throw NoteError.invalidOperation("导出页面列表包含重复页面。")
        }
        return try pageIDs.map { id in
            guard let page = document.pages.first(where: { $0.id == id }) else { throw NoteError.notFound }
            return page
        }
    }
}
