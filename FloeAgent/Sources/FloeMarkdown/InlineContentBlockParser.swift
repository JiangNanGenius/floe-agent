// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Ordered answer blocks. Only an entire, completed image-style reference
/// line is extracted. Ordinary images, links, code fences and text stay in
/// the existing Markdown pipeline; no URL is opened by this parser.
public enum InlineContentBlockParser {
    public struct Block: Sendable, Equatable, Identifiable {
        public enum Content: Sendable, Equatable { case markdown(String), reference(title: String, uri: String) }
        public let id: Int
        public let content: Content
    }
    public static func parse(_ source: String, streaming: Bool = false) -> [Block] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var blocks: [Block] = [], buffer = "", bufferOffset = 0, offset = 0
        var fence: Character?, fenceCount = 0
        func flush() {
            if !buffer.isEmpty { blocks.append(.init(id: bufferOffset, content: .markdown(buffer))); buffer = "" }
        }
        for (index, line) in lines.enumerated() {
            let terminated = index + 1 < lines.count
            let raw = String(line), trimmed = raw.trimmingCharacters(in: .whitespaces)
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { column, character in
                character == "\t" ? (column / 4 + 1) * 4 : column + 1
            }
            let marker = trimmed.first
            if indent < 4, marker == "`" || marker == "~" {
                let count = trimmed.prefix { $0 == marker }.count
                if count >= 3 {
                    if fence == nil { fence = marker; fenceCount = count }
                    else if marker == fence, count >= fenceCount,
                            trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                }
            }
            let candidate = fence == nil && indent < 4 && trimmed.hasPrefix("![") && trimmed.contains("](floe-content:")
            if candidate, streaming, !terminated {
                // Do not flash an unfinished protocol locator as visible text.
                flush(); break
            }
            if candidate, let reference = referenceLine(trimmed) {
                flush()
                blocks.append(.init(id: offset, content: .reference(title: reference.0, uri: reference.1)))
                bufferOffset = offset + raw.utf8.count + (terminated ? 1 : 0)
            } else {
                if buffer.isEmpty { bufferOffset = offset }
                buffer += raw + (terminated ? "\n" : "")
            }
            offset += raw.utf8.count + (terminated ? 1 : 0)
        }
        flush()
        return blocks
    }
    private static func referenceLine(_ line: String) -> (String, String)? {
        guard line.utf8.count <= 768, line.hasSuffix(")"),
              let delimiter = line.range(of: "]("),
              !line[line.index(line.startIndex, offsetBy: 2)..<delimiter.lowerBound].contains("]") else { return nil }
        let title = String(line[line.index(line.startIndex, offsetBy: 2)..<delimiter.lowerBound])
        let uri = String(line[delimiter.upperBound..<line.index(before: line.endIndex)])
        guard title.count <= 160, uri.hasPrefix("floe-content://"),
              !uri.contains(where: { $0.isWhitespace || $0 == "(" || $0 == ")" }) else { return nil }
        return (title, uri)
    }
}
