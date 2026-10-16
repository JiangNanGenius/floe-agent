// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit
import FloeMarkdown
import FloeNotes

/// Deterministic vector layout shared by page preview and PDF export. Raw
/// Markdown stays in the document; page slices refer to these visual lines.
@MainActor enum NotesMarkdownLayout {
    struct Line {
        var cells: [NSAttributedString]
        var height: CGFloat
        var table: Bool = false
        var header: Bool = false
        var plainText: String { cells.map(\.string).joined(separator: "\t") }
    }
    private struct Cached {
        var source: String; var width: CGFloat; var fontSize: CGFloat
        var color: UIColor; var lines: [Line]
    }
    private static var cache: [Cached] = []

    static func lines(_ source: String, width: CGFloat, fontSize: CGFloat, color: UIColor) -> [Line] {
        if let hit = cache.first(where: { $0.source == source && $0.width == width && $0.fontSize == fontSize && $0.color == color }) { return hit.lines }
        let font = UIFont.systemFont(ofSize: fontSize)
        var result: [Line] = []
        func styled(_ value: AttributedString, font: UIFont) -> NSAttributedString {
            let text = NSMutableAttributedString(string: String(value.characters), attributes: [.font: font, .foregroundColor: color])
            for run in value.runs {
                let start = String(value.characters[..<run.range.lowerBound]).utf16.count
                let length = String(value.characters[run.range]).utf16.count
                var traits: UIFontDescriptor.SymbolicTraits = []
                if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { traits.insert(.traitBold) }
                if run.inlinePresentationIntent?.contains(.emphasized) == true { traits.insert(.traitItalic) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits), !traits.isEmpty {
                    text.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: NSRange(location: start, length: length))
                }
                if run.inlinePresentationIntent?.contains(.code) == true {
                    text.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular), range: NSRange(location: start, length: length))
                }
                if let link = run.link { text.addAttribute(.link, value: link, range: NSRange(location: start, length: length)) }
            }
            return text
        }
        func wrapped(_ text: NSAttributedString, width: CGFloat) -> [NSAttributedString] {
            guard text.length > 0 else { return [NSAttributedString(string: "")] }
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: max(8, width), height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0; container.lineBreakMode = .byCharWrapping
            manager.addTextContainer(container); storage.addLayoutManager(manager)
            let glyphs = manager.glyphRange(for: container)
            var lines: [NSAttributedString] = []
            manager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, range, _ in
                lines.append(text.attributedSubstring(from: manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)))
            }
            return lines
        }
        func appendText(_ text: NSAttributedString, font: UIFont) {
            for line in wrapped(text, width: width) { result.append(Line(cells: [line], height: ceil(font.lineHeight) + 3)) }
            result.append(Line(cells: [NSAttributedString(string: "")], height: 8))
        }
        func appendTable(_ row: [AttributedString], columns: Int, header: Bool) {
            let tableFont = header ? UIFont.boldSystemFont(ofSize: fontSize) : font
            let cellWidth = max(8, width / CGFloat(max(1, columns)) - 12)
            let cells = (0..<columns).map { index in
                wrapped(styled(index < row.count ? row[index] : AttributedString(), font: tableFont), width: cellWidth)
            }
            for lineIndex in 0..<(cells.map(\.count).max() ?? 1) {
                result.append(Line(cells: cells.map { lineIndex < $0.count ? $0[lineIndex] : NSAttributedString(string: "") }, height: ceil(tableFont.lineHeight) + 10, table: true, header: header))
            }
        }
        func append(_ blocks: [MarkdownBlock], depth: Int = 0) {
            for block in blocks {
                switch block {
                case .heading(let level, let text):
                    let heading = UIFont.boldSystemFont(ofSize: fontSize * (level == 1 ? 1.45 : level == 2 ? 1.25 : 1.1))
                    appendText(styled(text, font: heading), font: heading)
                case .paragraph(let text): appendText(styled(text, font: font), font: font)
                case .list(let ordered, let items):
                    for (index, item) in items.enumerated() {
                        let prefix = String(repeating: "  ", count: depth) + (ordered ? "\(index + 1). " : "• ")
                        let value = NSMutableAttributedString(string: prefix, attributes: [.font: font, .foregroundColor: color])
                        value.append(styled(item.content, font: font)); appendText(value, font: font)
                        append(item.children, depth: depth + 1)
                    }
                case .quote(let children): append(children, depth: depth + 1)
                case .codeBlock(_, let code):
                    let codeFont = UIFont.monospacedSystemFont(ofSize: fontSize * 0.9, weight: .regular)
                    appendText(NSAttributedString(string: code, attributes: [.font: codeFont, .foregroundColor: color]), font: codeFont)
                case .table(let header, let rows):
                    appendTable(header, columns: header.count, header: true)
                    for row in rows { appendTable(row, columns: header.count, header: false) }
                    result.append(Line(cells: [NSAttributedString(string: "")], height: 8))
                case .thematicBreak: appendText(NSAttributedString(string: "────────", attributes: [.font: font, .foregroundColor: color]), font: font)
                }
            }
        }
        append(MarkdownBlockParser.parse(source))
        cache.append(Cached(source: source, width: width, fontSize: fontSize, color: color, lines: result))
        if cache.count > 4 { cache.removeFirst() }
        return result
    }

    static func draw(source: String, slice: NoteTextSlice?, frame: CGRect, fontSize: CGFloat, color: UIColor) {
        let all = lines(source, width: frame.width, fontSize: fontSize, color: color)
        let lower = min(all.count, max(0, slice?.start ?? 0))
        let upper = min(all.count, lower + max(0, slice?.count ?? all.count))
        guard lower < upper, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.clip(to: frame)
        var y = frame.minY
        for line in all[lower..<upper] {
            let width = frame.width / CGFloat(max(1, line.cells.count))
            for (index, cell) in line.cells.enumerated() {
                let rect = CGRect(x: frame.minX + CGFloat(index) * width, y: y, width: width, height: line.height)
                if line.table {
                    if line.header { UIColor(white: 0.94, alpha: 1).setFill(); context.fill(rect) }
                    UIColor(white: 0.76, alpha: 1).setStroke(); context.setLineWidth(0.5); context.stroke(rect)
                }
                cell.draw(in: rect.insetBy(dx: line.table ? 6 : 0, dy: line.table ? 5 : 0))
            }
            y += line.height
        }
    }
}
#endif
