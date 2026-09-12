// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit
import FloeNotes

@MainActor enum NotesTextLayout {
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
