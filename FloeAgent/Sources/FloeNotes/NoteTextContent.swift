// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Shared extraction preserves plain historical text and source ownership.
public enum NoteTextContent {
    public static func source(for element: NoteElement, in document: NoteDocument) -> String {
        element.textSourceID.flatMap { document.textSources?[$0.uuidString] } ?? element.text
    }

    public static func reading(_ document: NoteDocument) -> (text: String, markdown: Bool) {
        let elements = document.pages.flatMap(\.elements).filter { $0.kind == .text }
        let markdown = elements.contains { $0.isMarkdown }
        let grouped = Dictionary(grouping: elements.filter { $0.textSourceID != nil }, by: { $0.textSourceID! })
        let completeSources = Set(grouped.compactMap { (id, values) -> UUID? in
            let slices = values.compactMap(\.textSlice).sorted { $0.start < $1.start }
            var next = 0
            guard slices.count == values.count, !slices.isEmpty else { return nil }
            for slice in slices {
                guard slice.start == next, slice.count > 0 else { return nil }
                next += slice.count
            }
            return next == slices.first?.total ? id : nil
        })
        var emitted: Set<UUID> = []
        func escaped(_ text: String) -> String {
            guard markdown else { return text }
            return text.reduce(into: "") { result, character in
                if "\\`*_{}[]<>()#+-.!|>".contains(character) { result.append("\\") }
                result.append(character)
            }
        }
        var segments: [String] = []
        for element in elements {
            if element.isMarkdown, let id = element.textSourceID,
               let source = document.textSources?[id.uuidString] {
                if completeSources.contains(id) {
                    if emitted.insert(id).inserted { segments.append(source) }
                } else {
                    // A page was removed/copied. Read the surviving visible
                    // content, never resurrect deleted text from the source.
                    segments.append(escaped(element.text))
                }
            } else {
                segments.append(element.isMarkdown ? element.text : escaped(element.text))
            }
        }
        return (segments.joined(separator: "\n\n"), markdown)
    }

    /// Reader windows are bounded. Repeat table headers at paragraph
    /// boundaries so a long GFM table never becomes naked pipe rows when a
    /// reader block reaches its 4k-character limit. Stored source is untouched.
    public static func readerMarkdown(_ source: String, blockBudget: Int = 2_400) -> String {
        let lines = source.components(separatedBy: "\n")
        var output: [String] = [], index = 0
        var fence: String?
        func delimiter(_ line: String) -> Bool {
            let cells = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                .split(separator: "|", omittingEmptySubsequences: false)
            return !cells.isEmpty && cells.allSatisfy { cell in
                let value = cell.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                return value.count >= 3 && value.allSatisfy { $0 == "-" }
            }
        }
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
            }
            if fence == nil, index + 1 < lines.count, lines[index].contains("|"), delimiter(lines[index + 1]) {
                let header = [lines[index], lines[index + 1]]
                let headerCount = header.joined(separator: "\n").count + 1
                output += header; index += 2
                var used = headerCount
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    if used > headerCount, used + lines[index].count + 1 > max(256, blockBudget) {
                        output.append(""); output += header; used = headerCount
                    }
                    output.append(lines[index]); used += lines[index].count + 1; index += 1
                }
            } else { output.append(lines[index]); index += 1 }
        }
        return output.joined(separator: "\n")
    }

}
