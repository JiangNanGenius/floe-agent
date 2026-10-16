// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit
import FloeNotes

@MainActor enum NotesTextLayout {
    struct FormattedPages {
        var sourceID: UUID
        var source: String
        var pages: [NotePage]
    }

    static func formattedPages(text: String, source: NoteSourceReference?, width: Double = 768,
                               height: Double = 1024, fontSize: Double = 20, color: String = "#202020",
                               sourceID: UUID = UUID(), textFrame: NoteRect? = nil) -> FormattedPages {
        let frame = textFrame ?? NoteRect(x: 40, y: 50, width: max(40, width - 80), height: max(40, height - 100))
        let lines = NotesMarkdownLayout.lines(text, width: frame.width, fontSize: fontSize, color: NotePageRenderer.color(color))
        var pages: [NotePage] = []
        var start = 0
        while start < lines.count {
            var end = start, used: CGFloat = 0
            while end < lines.count, used + lines[end].height <= frame.height {
                used += lines[end].height; end += 1
            }
            // A single large font line still gets a page, without dropping text.
            if end == start { end += 1 }
            var element = NoteElement(frame: frame, text: lines[start..<end].map(\.plainText).joined(separator: "\n"),
                                      color: color, fontSize: fontSize, source: source, isAIGenerated: true)
            element.textFormat = "markdown"; element.textSourceID = sourceID
            element.textSlice = NoteTextSlice(start: start, count: end - start, total: lines.count)
            pages.append(NotePage(width: width, height: height, elements: [element]))
            start = end
        }
        return FormattedPages(sourceID: sourceID, source: text, pages: pages)
    }

    /// One existing undo/save transaction replaces the text flow, preserving
    /// all other objects, page identities, ink and backgrounds.
    static func replacementEdits(element: NoteElement, text: String, markdown: Bool,
                                 page: NotePage, document: NoteDocument) -> [NoteEdit] {
        guard element.kind == .text else { return [.upsertElement(pageID: page.id, element: element)] }
        if !markdown, element.textSourceID == nil {
            var updated = element; updated.text = text; updated.textFormat = nil; updated.textSlice = nil
            return [.upsertElement(pageID: page.id, element: updated)]
        }
        let old = document.pages.flatMap { p in p.elements.filter {
            element.textSourceID != nil ? $0.textSourceID == element.textSourceID : $0.id == element.id
        }.map { (p, $0) } }
        let result = formattedPages(text: text, source: element.source, width: page.width, height: page.height,
                                    fontSize: element.fontSize, color: element.color,
                                    sourceID: element.textSourceID ?? UUID(), textFrame: element.frame)
        var edits: [NoteEdit] = []
        let newPages: [NotePage]
        if markdown {
            edits.append(.textSource(id: result.sourceID, text: text)); newPages = result.pages
        } else {
            newPages = pages(text: text, source: element.source, width: page.width, height: page.height)
        }
        edits += old.map { .deleteElements(pageID: $0.0.id, ids: [$0.1.id]) }
        let oldPages = old.map { $0.0 }
        var insertion = (document.pages.lastIndex(where: { p in oldPages.contains(where: { $0.id == p.id }) }) ?? 0) + 1
        for (index, newPage) in newPages.enumerated() {
            var replacement = newPage.elements[0]
            replacement.isAIGenerated = element.isAIGenerated
            if index == 0 { replacement.id = element.id }
            if index < oldPages.count {
                edits.append(.upsertElement(pageID: oldPages[index].id, element: replacement))
            } else {
                var added = newPage; added.elements = [replacement]
                edits.append(.insertPage(added, at: insertion)); insertion += 1
            }
        }
        return edits
    }

    /// Pagination uses the same font and line-fragment measurement as the PDF/page renderer.
    static func pages(text: String, source: NoteSourceReference?, width: Double = 768, height: Double = 1024) -> [NotePage] {
        let characters = Array(text)
        var offset = 0
        var pages: [NotePage] = []
        let frame = NoteRect(x: 40, y: 50, width: max(40, width - 80), height: max(40, height - 100))
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 20)]
        while offset < characters.count {
            var low = 1, high = min(8_192, characters.count - offset), fits = 1
            while low <= high {
                let count = (low + high) / 2
                let candidate = String(characters[offset..<(offset + count)]) as NSString
                let bounds = candidate.boundingRect(with: CGSize(width: frame.width, height: .greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
                if ceil(bounds.height) <= frame.height - 4 { fits = count; low = count + 1 }
                else { high = count - 1 }
            }
            let body = String(characters[offset..<(offset + fits)])
            pages.append(NotePage(width: width, height: height, elements: [.init(frame: frame, text: body, source: source, isAIGenerated: true)]))
            offset += fits
        }
        return pages
    }
}
#endif
