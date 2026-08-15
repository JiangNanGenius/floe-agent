// FloeMarkdown — Line-oriented block-level Markdown parser.
//
// SPDX-License-Identifier: MPL-2.0
//
// Parses the enumerable Markdown subset that agent output produces:
// ATX headings, paragraphs, unordered/ordered lists (with nesting by
// indentation), block quotes (recursively parsed), fenced code blocks,
// GFM pipe tables and thematic breaks. Inline styling is delegated to
// `InlineRenderer` (system AttributedString parser). The parser is a
// pure function: no state survives between calls, malformed input
// degrades to paragraphs instead of crashing.
//
// Deliberate decisions beyond the base spec (noted per "边界自决"):
// - Only fenced code blocks are supported; 4-space indented code blocks
//   are treated as paragraphs (agent output uses fences).
// - GFM table delimiter alignment markers (`:---`, `:--:`, `---:`) are
//   accepted but alignment is discarded — the renderer left-aligns.
// - `~~~` is accepted as a code fence equivalent to ``` (CommonMark).
// - Thematic breaks accept `---`, `***`, `___` (3+ markers, optional
//   spaces), but only when the line is not a table delimiter row.

import Foundation

/// Pure-function, line-oriented block-level Markdown parser.
public enum MarkdownBlockParser {

    /// Keeps hostile provider output from creating an unbounded Swift stack.
    public static let maximumQuoteDepth = 24

    /// Streaming output is reparsed whenever a provider delivers another
    /// delta. Bound that work so a very long response cannot make every new
    /// token progressively more expensive. The completed response is still
    /// rendered in full once streaming ends.
    public static let maximumStreamingCharacters = 131_072

    // MARK: - Public entry points

    /// Parses a full Markdown document into a block tree. Always
    /// succeeds; unparseable fragments degrade to paragraphs.
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        parse(markdown, quoteDepth: 0)
    }

    private static func parse(_ markdown: String, quoteDepth: Int) -> [MarkdownBlock] {
        var parser = Parser(lines: Self.splitLines(markdown), quoteDepth: quoteDepth)
        return parser.parseBlocks(indent: 0, isTopLevel: true)
    }

    /// Incremental variant for streaming text (see §1.2): re-parses only
    /// the trailing, possibly-unfinished block. All content up to and
    /// including the last newline is parsed as `completed`; the
    /// remainder is parsed as `tail`. A renderer can cache the
    /// completed prefix and re-render only the tail while tokens arrive.
    public static func parseStreaming(
        _ markdown: String
    ) -> (completed: [MarkdownBlock], tail: [MarkdownBlock]) {
        let visibleWindow = markdown.suffix(maximumStreamingCharacters)
        guard let lastNewline = visibleWindow.lastIndex(of: "\n") else {
            return ([], parse(String(visibleWindow)))
        }
        let completedSource = String(visibleWindow[...lastNewline])
        let tailSource = String(visibleWindow[visibleWindow.index(after: lastNewline)...])
        return (parse(completedSource), parse(tailSource))
    }

    // MARK: - Line model

    /// One physical line, split into semantic parts.
    private struct Line {
        /// Leading indentation in columns (tab = rounded up to a
        /// multiple of 4 — CommonMark tab stops).
        let indent: Int
        /// The line content with leading whitespace removed.
        let trimmedLeading: Substring
        /// The line content with leading and trailing whitespace removed.
        let trimmed: Substring
        /// Whether the line contains only whitespace.
        let isBlank: Bool
    }

    private static func splitLines(_ source: String) -> [Line] {
        source.split(separator: "\n", omittingEmptySubsequences: false).map(makeLine)
    }

    private static func makeLine(_ raw: Substring) -> Line {
        var indent = 0
        var bodyStart = raw.startIndex
        while bodyStart < raw.endIndex {
            let char = raw[bodyStart]
            if char == " " {
                indent += 1
            } else if char == "\t" {
                indent = ((indent / 4) + 1) * 4
            } else {
                break
            }
            bodyStart = raw.index(after: bodyStart)
        }
        let leadingTrimmed = raw[bodyStart...]
        let trailingTrimmed = leadingTrimmed.reversed()
            .drop(while: { $0 == " " || $0 == "\t" })
        return Line(
            indent: indent,
            trimmedLeading: leadingTrimmed,
            trimmed: Substring(trailingTrimmed.reversed()),
            isBlank: trailingTrimmed.isEmpty
        )
    }

    /// A recognized list marker on one line.
    private struct ListMarker {
        let ordered: Bool
        /// Width of the marker run itself ("- " = 2, "12. " = 4).
        let markerWidth: Int
        /// Item text after the marker.
        let body: Substring
    }

    // MARK: - Parser state

    private struct Parser {
        let lines: [Line]
        let quoteDepth: Int
        var index: Int = 0

        // MARK: Core loop

        /// Parses consecutive blocks until the input is exhausted or
        /// (when not top level) a dedented line ends the container.
        /// `indent` is the minimum indentation a line must have to
        /// belong to this container.
        mutating func parseBlocks(indent: Int, isTopLevel: Bool) -> [MarkdownBlock] {
            var blocks: [MarkdownBlock] = []
            var paragraphParts: [Substring] = []

            func flushParagraph() -> MarkdownBlock? {
                guard !paragraphParts.isEmpty else { return nil }
                let source = paragraphParts.map(String.init).joined(separator: "\n")
                paragraphParts = []
                return .paragraph(InlineRenderer.render(source))
            }

            while index < lines.count {
                let line = lines[index]

                if line.isBlank {
                    if let paragraph = flushParagraph() { blocks.append(paragraph) }
                    index += 1
                    continue
                }

                // A dedented non-blank line ends a nested container.
                if !isTopLevel && line.indent < indent {
                    break
                }

                // Block starters always interrupt a paragraph (the
                // current line is not consumed — the starter re-reads it).
                if let heading = Self.parseHeading(line) {
                    if let paragraph = flushParagraph() { blocks.append(paragraph) }
                    index += 1
                    blocks.append(heading)
                } else if Self.isThematicBreak(line.trimmed) {
                    if let paragraph = flushParagraph() { blocks.append(paragraph) }
                    index += 1
                    blocks.append(.thematicBreak)
                } else if let fence = Self.fenceMarker(line.trimmed) {
                    if let paragraph = flushParagraph() { blocks.append(paragraph) }
                    blocks.append(parseCodeBlock(fence: fence))
                } else if Self.quoteStripped(line) != nil {
                    if let paragraph = flushParagraph() { blocks.append(paragraph) }
                    blocks.append(parseQuote())
                } else if let marker = Self.listMarker(line) {
                    if let paragraph = flushParagraph() { blocks.append(paragraph) }
                    blocks.append(parseList(marker: marker, indent: line.indent))
                } else if paragraphParts.isEmpty, let table = tryParseTable() {
                    blocks.append(table)
                } else {
                    // Paragraph text. CommonMark would allow a lazy
                    // continuation to absorb the next line; we keep the
                    // simpler rule that the block starters above always
                    // interrupt, which is safer for streaming reparsing.
                    paragraphParts.append(line.trimmed)
                    index += 1
                }
            }

            if let paragraph = flushParagraph() { blocks.append(paragraph) }
            return blocks
        }

        // MARK: Heading

        static func parseHeading(_ line: Line) -> MarkdownBlock? {
            // ATX only: `#`…`######` followed by a space or end of line.
            // `#nospace` stays paragraph text (CommonMark).
            guard line.indent < 4 else { return nil }
            var level = 0
            for char in line.trimmed {
                if char == "#" { level += 1 } else { break }
            }
            guard (1...6).contains(level) else { return nil }
            var rest = line.trimmed.dropFirst(level)
            if !rest.isEmpty {
                guard rest.first == " " || rest.first == "\t" else { return nil }
                rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            }
            // Strip an optional closing sequence: `## Title ##`.
            var text = rest
            var closingStart = text.endIndex
            while closingStart > text.startIndex,
                  text[text.index(before: closingStart)] == "#" {
                closingStart = text.index(before: closingStart)
            }
            if closingStart < text.endIndex {
                // Closing run must be preceded by a space (or be the
                // entire remainder, i.e. an empty heading).
                if closingStart == text.startIndex {
                    text = text[text.startIndex..<text.startIndex]
                } else if text[text.index(before: closingStart)] == " " {
                    text = text[..<closingStart]
                    text = Substring(text.reversed()
                        .drop(while: { $0 == " " || $0 == "\t" }).reversed())
                }
            }
            return .heading(
                level: level,
                text: InlineRenderer.render(String(text))
            )
        }

        // MARK: Thematic break

        static func isThematicBreak(_ trimmed: Substring) -> Bool {
            guard let marker = trimmed.first,
                  marker == "-" || marker == "*" || marker == "_" else { return false }
            var count = 0
            for char in trimmed {
                if char == marker {
                    count += 1
                } else if char != " " && char != "\t" {
                    return false
                }
            }
            return count >= 3
        }

        // MARK: Fenced code block

        /// Returns the fence when the line opens a code fence.
        static func fenceMarker(
            _ trimmed: Substring
        ) -> (char: Character, length: Int)? {
            guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
            var length = 0
            for char in trimmed {
                if char == first { length += 1 } else { break }
            }
            return length >= 3 ? (first, length) : nil
        }

        mutating func parseCodeBlock(
            fence: (char: Character, length: Int)
        ) -> MarkdownBlock {
            let opener = lines[index]
            index += 1
            // Info string: text after the fence run; the first word is
            // the language tag (remaining words are attributes, dropped).
            let info = String(opener.trimmed.dropFirst(fence.length))
                .trimmingCharacters(in: .whitespaces)
            let language = info.split(separator: " ").first.map(String.init)
                .flatMap { $0.isEmpty ? nil : $0 }

            var codeLines: [Substring] = []
            while index < lines.count {
                let line = lines[index]
                // Closing fence: same char, >= opener length, nothing
                // else on the line, at any indentation.
                if line.trimmed.count >= fence.length,
                   line.trimmed.allSatisfy({ $0 == fence.char }) {
                    index += 1
                    break
                }
                codeLines.append(line.trimmedLeading)
                index += 1
            }
            // An unclosed fence (streaming tail / malformed input) still
            // yields a code block — never crash, never drop content.
            return .codeBlock(
                language: language,
                code: codeLines.map(String.init).joined(separator: "\n")
            )
        }

        // MARK: GFM pipe table

        /// A table is `header row` + `delimiter row` + `body rows`. The
        /// delimiter row (`| --- | :---: |`) is required by GFM;
        /// alignment markers are accepted but discarded.
        mutating func tryParseTable() -> MarkdownBlock? {
            let headerLine = lines[index]
            guard headerLine.trimmed.contains("|"),
                  index + 1 < lines.count,
                  Self.isTableDelimiter(lines[index + 1].trimmed) else { return nil }

            let headerCells = Self.splitTableRow(headerLine.trimmed)
            guard !headerCells.isEmpty else { return nil }

            index += 2
            var bodyRows: [[AttributedString]] = []
            while index < lines.count {
                let line = lines[index]
                if line.isBlank || !line.trimmed.contains("|") { break }
                bodyRows.append(Self.splitTableRow(line.trimmed).map(InlineRenderer.render))
                index += 1
            }
            // Normalize to the header column count so the renderer can
            // rely on a rectangular grid.
            let width = headerCells.count
            let normalized = bodyRows.map { row -> [AttributedString] in
                if row.count >= width { return Array(row.prefix(width)) }
                return row + Array(repeating: AttributedString(), count: width - row.count)
            }
            return .table(
                header: headerCells.map(InlineRenderer.render),
                rows: normalized
            )
        }

        /// `| --- | :---: | ---: |` — every cell must be dashes with an
        /// optional leading/trailing alignment colon. 1+ dashes accepted
        /// (GFM says 3+; sloppy agent output stays robust).
        static func isTableDelimiter(_ trimmed: Substring) -> Bool {
            guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix("-")
                    || trimmed.hasPrefix(":") || trimmed.hasPrefix("|") else { return false }
            let cells = splitTableRow(trimmed)
            guard !cells.isEmpty else { return false }
            for cell in cells {
                var body = Substring(cell.trimmingCharacters(in: .whitespaces))
                if body.first == ":" { body = body.dropFirst() }
                if body.last == ":" { body = body.dropLast() }
                guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return false }
            }
            return true
        }

        /// Splits a pipe row into cell strings, tolerating a missing
        /// trailing pipe. Escaped pipes (`\|`) do not split.
        static func splitTableRow(_ trimmed: Substring) -> [String] {
            var row = trimmed
            if row.first == "|" { row = row.dropFirst() }
            if row.last == "|" { row = row.dropLast() }
            var cells: [String] = []
            var current = ""
            var escaped = false
            for char in row {
                if escaped {
                    current.append(char)
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "|" {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(char)
                }
            }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }

        // MARK: Block quote

        /// Strips one `>` quote marker, returning the remaining content
        /// (indentation preserved) or nil when the line is not quoted.
        static func quoteStripped(_ line: Line) -> Substring? {
            var rest = line.trimmedLeading
            guard rest.first == ">" else { return nil }
            rest = rest.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
            return rest
        }

        mutating func parseQuote() -> MarkdownBlock {
            var innerLines: [String] = []
            while index < lines.count {
                let line = lines[index]
                if line.isBlank {
                    // A blank line ends the quote unless the next line
                    // continues it. Lazy continuation across blanks is
                    // not applied — keeps streaming reparsing stable.
                    if index + 1 < lines.count,
                       Self.quoteStripped(lines[index + 1]) != nil {
                        innerLines.append("")
                        index += 1
                        continue
                    }
                    break
                }
                if let stripped = Self.quoteStripped(line) {
                    innerLines.append(String(stripped))
                    index += 1
                } else {
                    // Lazy continuation (CommonMark): a plain paragraph
                    // line directly under the quote belongs to it, but a
                    // line that starts a new block ends the quote.
                    let startsBlock = Self.parseHeading(line) != nil
                        || Self.isThematicBreak(line.trimmed)
                        || Self.fenceMarker(line.trimmed) != nil
                        || Self.listMarker(line) != nil
                    if startsBlock { break }
                    innerLines.append(String(line.trimmedLeading))
                    index += 1
                }
            }
            let source = innerLines.joined(separator: "\n")
            guard quoteDepth < MarkdownBlockParser.maximumQuoteDepth else {
                return .paragraph(InlineRenderer.render(source))
            }
            let inner = MarkdownBlockParser.parse(source, quoteDepth: quoteDepth + 1)
            return .quote(inner)
        }

        // MARK: Lists

        static func listMarker(_ line: Line) -> ListMarker? {
            guard line.indent < 4 else { return nil }
            let rest = line.trimmedLeading
            guard let first = rest.first else { return nil }
            // Unordered: `- `, `* `, `+ ` (marker + at least one space,
            // or a bare marker = empty item).
            if first == "-" || first == "*" || first == "+" {
                let after = rest.dropFirst()
                if after.isEmpty {
                    return ListMarker(ordered: false, markerWidth: 1, body: "")
                }
                guard after.first == " " || after.first == "\t" else { return nil }
                let body = after.drop(while: { $0 == " " || $0 == "\t" })
                return ListMarker(
                    ordered: false,
                    markerWidth: rest.count - body.count,
                    body: body
                )
            }
            // Ordered: 1–9 digits + `.` or `)` + space. The start number
            // is discarded (the renderer renumbers), matching the common
            // reading of CommonMark for agent output.
            var digits = 0
            for char in rest {
                if char.isASCII, char.isNumber {
                    digits += 1
                } else {
                    break
                }
            }
            guard (1...9).contains(digits) else { return nil }
            let afterDigits = rest.dropFirst(digits)
            guard let delimiter = afterDigits.first,
                  delimiter == "." || delimiter == ")" else { return nil }
            let after = afterDigits.dropFirst()
            if after.isEmpty {
                return ListMarker(ordered: true, markerWidth: digits + 1, body: "")
            }
            guard after.first == " " || after.first == "\t" else { return nil }
            let body = after.drop(while: { $0 == " " || $0 == "\t" })
            return ListMarker(
                ordered: true,
                markerWidth: rest.count - body.count,
                body: body
            )
        }

        /// Parses a contiguous list run. `marker` is the first item's
        /// marker (fixes ordered-ness); `indent` is the column of the
        /// first item's marker. Sibling items must share both.
        mutating func parseList(marker: ListMarker, indent: Int) -> MarkdownBlock {
            var items: [MarkdownBlock.ListItem] = []
            while index < lines.count {
                let line = lines[index]
                if line.isBlank {
                    // The list ends unless the next non-blank line still
                    // belongs to it (continuation or sibling item).
                    if let next = Self.nextNonBlankLine(lines, from: index + 1),
                       next.indent > indent
                        || (next.indent == indent && Self.listMarker(next) != nil) {
                        index += 1
                        continue
                    }
                    break
                }
                guard line.indent == indent,
                      let itemMarker = Self.listMarker(line),
                      itemMarker.ordered == marker.ordered else { break }
                items.append(parseListItem(
                    contentIndent: indent + itemMarker.markerWidth,
                    listIndent: indent
                ))
            }
            return .list(ordered: marker.ordered, items: items)
        }

        /// Consumes one list item plus its continuation lines and any
        /// nested blocks (nested lists, quotes, fences).
        mutating func parseListItem(
            contentIndent: Int,
            listIndent: Int
        ) -> MarkdownBlock.ListItem {
            let firstLine = lines[index]
            // Guaranteed non-nil by the caller.
            guard let marker = Self.listMarker(firstLine) else {
                index += 1
                return MarkdownBlock.ListItem(content: AttributedString())
            }
            index += 1

            var textParts: [Substring] = marker.body.isEmpty ? [] : [marker.body]
            var childSources: [String] = []

            while index < lines.count {
                let line = lines[index]
                if line.isBlank {
                    if let next = Self.nextNonBlankLine(lines, from: index + 1),
                       next.indent > listIndent {
                        index += 1
                        continue
                    }
                    break
                }
                if line.indent > listIndent {
                    if Self.listMarker(line) != nil || Self.quoteStripped(line) != nil
                        || Self.fenceMarker(line.trimmed) != nil {
                        // A structural line inside the item starts a
                        // nested block (nested list / quote / fence),
                        // collected and parsed recursively once the
                        // item's lines are gathered.
                        childSources.append(String(line.trimmedLeading))
                    } else {
                        // Continuation text of the item.
                        textParts.append(line.trimmed)
                    }
                    index += 1
                } else {
                    break
                }
            }

            let text = textParts.map(String.init).joined(separator: "\n")
            let children = childSources.isEmpty
                ? []
                : MarkdownBlockParser.parse(childSources.joined(separator: "\n"))
            return MarkdownBlock.ListItem(
                content: InlineRenderer.render(text),
                children: children
            )
        }

        // MARK: Helpers

        private static func nextNonBlankLine(_ lines: [Line], from start: Int) -> Line? {
            var cursor = start
            while cursor < lines.count {
                if !lines[cursor].isBlank { return lines[cursor] }
                cursor += 1
            }
            return nil
        }
    }
}
