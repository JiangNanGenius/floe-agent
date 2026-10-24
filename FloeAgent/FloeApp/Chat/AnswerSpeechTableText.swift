// FloeApp — Read-aloud expands semantic table rows, never pipes or dash rows.
//
// Foundation-only by design: the caller integrates this inside
// `AnswerSpeechText.plainText` immediately AFTER fenced-code exclusion and
// BEFORE inline cleanup, so inline structure inside cells (code spans,
// emphasis, links) is still intact when column boundaries are decided.
// This is a bounded speech projection for pipe tables, not a general Markdown
// parser: anything that does not clearly open as a header + delimiter row
// passes through unchanged, so ordinary prose with a stray pipe is never
// reinterpreted, rows are never summarized, and cell text is never rewritten.
import Foundation

enum AnswerSpeechTableText {
    /// Rewrites each semantic Markdown table into one spoken line per row that
    /// keeps every header/value association, numeric string, sign, decimal,
    /// percentage, date, currency, unit and total exactly as authored. The
    /// first column value is the row subject when present; empty cells are
    /// skipped instead of shifting later values or being read as zero; escaped
    /// pipes and inline-code pipes are content, never column boundaries.
    /// Non-table text is preserved verbatim.
    static func expanding(_ markdown: String) -> String {
        // Defensive mirror of the caller's fenced-code exclusion so a table
        // example inside a code block is never spoken even if this is ever
        // called on pre-cleaned text. At the documented seam this is a no-op.
        let guard1 = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let guarded = guard1.replacingOccurrences(of: "(?s)```.*?```", with: "", options: .regularExpression)
        let lines = guarded.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var output: [String] = []
        var index = 0
        while index < lines.count {
            if let block = tableBlock(startingAt: index, in: lines) {
                output.append(contentsOf: block.rows)
                index = block.endIndex
            } else {
                output.append(lines[index])
                index += 1
            }
        }
        return output.joined(separator: "\n")
    }

    // MARK: - Block detection

    private struct TableBlock {
        let rows: [String]
        let endIndex: Int
    }

    /// A table opens only on `headerRow + delimiterRow` whose pipe column
    /// counts match (single-column tables require visible outer pipe syntax).
    /// Body rows continue while each line still carries pipe structure; the
    /// first blank or pipe-free line ends the block, leaving adjacent prose
    /// untouched.
    private static func tableBlock(startingAt start: Int, in lines: [String]) -> TableBlock? {
        guard start + 1 < lines.count else { return nil }
        let header = splitRow(lines[start])
        let delimiter = splitRow(lines[start + 1])
        guard let headerColumns = header.columnCount,
              let delimiterColumns = delimiter.columnCount,
              headerColumns == delimiterColumns,
              delimiter.cells.allSatisfy(isDelimiterCell)
        else { return nil }

        var bodyCells: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let row = splitRow(lines[index])
            // The first blank or pipe-free line ends the table; a row whose
            // cells are all empty is still part of the table, it just has
            // nothing to say.
            guard row.columnCount != nil else { break }
            bodyCells.append(row.cells.map { trimmed($0) })
            index += 1
        }

        let names = header.cells.map { trimmed($0) }
        let spoken: [String]
        if bodyCells.isEmpty {
            // Header + delimiter with zero data rows: speak only the column
            // names, never the structural dashes; fabricating a row is worse.
            let namesLine = names.filter { !$0.isEmpty }.joined(separator: ", ")
            spoken = namesLine.isEmpty ? [] : [terminate(namesLine)]
        } else {
            spoken = bodyCells.compactMap { rowLine(values: $0, names: names) }
        }
        return TableBlock(rows: spoken, endIndex: index)
    }

    /// `项目: 数量 2, 金额（元） 3.50。` — the first value is the subject, the
    /// rest keep their heading. Empty cells drop (no zero, no shift); values
    /// beyond the last heading fall back to bare values; a row with no content
    /// at all contributes nothing.
    private static func rowLine(values: [String], names: [String]) -> String? {
        var subject: String?
        var parts: [String] = []
        for (offset, value) in values.enumerated() {
            guard !value.isEmpty else { continue }
            if offset == 0 {
                subject = value
                continue
            }
            let name = offset < names.count ? names[offset] : ""
            parts.append(name.isEmpty ? value : "\(name) \(value)")
        }
        // Column 0 empty: the loop above still paired every remaining value
        // with its own heading positionally, so nothing shifts or duplicates.
        let body: String
        if let subject {
            body = parts.isEmpty ? subject : "\(subject): \(parts.joined(separator: ", "))"
        } else if parts.isEmpty {
            return nil
        } else {
            body = parts.joined(separator: ", ")
        }
        return terminate(body)
    }

    // MARK: - Pipe-aware row splitting

    private struct SplitRow {
        /// Raw cell contents in column order (outer optional pipes removed).
        let cells: [String]
        /// True when at least one real column boundary pipe was consumed.
        let boundarySeen: Bool

        /// Pipe-table column count, or nil when the line is not table syntax.
        /// Two-plus cells need only their separators; a single cell must show
        /// leading/trailing pipe syntax, which keeps an ordinary prose word or
        /// a dash-only horizontal rule from opening a table.
        var columnCount: Int? {
            if cells.count >= 2 { return cells.count }
            if cells.count == 1, boundarySeen { return 1 }
            return nil
        }
    }

    /// Splits on unescaped pipes outside inline-code spans. A backslash before
    /// `|` (or before another backslash) removes the boundary meaning; a
    /// backtick run only closes a code span at its equal-length run, so
    /// `` `x|y` `` stays one cell. Leading/trailing pipes are syntax, not
    /// empty cells.
    private static func splitRow(_ line: String) -> SplitRow {
        let chars = Array(line)
        var cells: [String] = []
        var current = ""
        var boundarySeen = false
        var openCodeRun: Int?
        var cursor = 0
        while cursor < chars.count {
            let character = chars[cursor]
            if character == "\\", openCodeRun == nil {
                let next = chars.index(cursor, offsetBy: 1, limitedBy: chars.count - 1)
                if next != nil, chars[next!] == "|" {
                    current.append("|")
                    cursor += 2
                } else if next != nil, chars[next!] == "\\" {
                    current.append("\\")
                    cursor += 2
                } else {
                    current.append("\\")
                    cursor += 1
                }
                continue
            }
            if character == "`" {
                var run = 0
                while cursor + run < chars.count, chars[cursor + run] == "`" { run += 1 }
                if let open = openCodeRun {
                    if open == run { openCodeRun = nil }
                } else {
                    openCodeRun = run
                }
                current.append(String(repeating: "`", count: run))
                cursor += run
                continue
            }
            if character == "|", openCodeRun == nil {
                cells.append(current)
                current = ""
                boundarySeen = true
                cursor += 1
                continue
            }
            current.append(character)
            cursor += 1
        }
        cells.append(current)

        // Optional outer pipes: the syntax pipes only when the cell they would
        // create is pure whitespace (real content survives either way).
        if cells.count > 1, trimmed(cells[0]).isEmpty, firstMeaningfulCharacter(of: line) == "|" {
            cells.removeFirst()
        }
        if cells.count > 1, trimmed(cells[cells.count - 1]).isEmpty, trimmed(line).last == "|" {
            cells.removeLast()
        }
        return SplitRow(cells: cells, boundarySeen: boundarySeen)
    }

    // MARK: - Small primitives

    private static func isDelimiterCell(_ rawCell: String) -> Bool {
        var cell = trimmed(rawCell)
        guard !cell.isEmpty else { return false }
        if cell.hasPrefix(":") { cell.removeFirst() }
        if cell.hasSuffix(":") { cell.removeLast() }
        return !cell.isEmpty && cell.allSatisfy { $0 == "-" }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{3000}")))
    }

    private static func firstMeaningfulCharacter(of line: String) -> Character? {
        trimmed(line).first
    }

    /// Each spoken row ends on a sentence stop so the existing bounded
    /// sentence pipeline pauses per row; a row whose own text already ends on
    /// one (for example a value with a trailing period) is not doubled. The
    /// stop follows the row's own script, including its headings.
    private static func terminate(_ body: String) -> String {
        let stops: Set<Character> = [".", "。", "！", "!", "？", "?", "…", "；", ";"]
        if let last = body.last, stops.contains(last) { return body }
        return containsChineseScript(body) ? "\(body)。" : "\(body)."
    }

    /// CJK/fullwidth presence picks the ideographic stop so English tables
    /// are not narrated with Chinese punctuation and vice versa.
    private static func containsChineseScript(_ text: String) -> Bool {
        let scalars: [ClosedRange<UInt32>] = [0x2E80...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                                              0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF]
        for scalar in text.unicodeScalars {
            if scalars.contains(where: { $0.contains(scalar.value) }) { return true }
        }
        return false
    }
}
