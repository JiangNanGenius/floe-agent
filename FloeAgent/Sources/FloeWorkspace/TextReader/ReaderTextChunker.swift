// FloeWorkspace — Raw-byte line splitting and bounded block building.
//
// SPDX-License-Identifier: MPL-2.0
//
// Line boundaries are found in the ORIGINAL bytes (0x0A for UTF-8/GB18030,
// the 2-byte unit for UTF-16), so every offset produced here is a real source
// offset and a window can never cut a multibyte sequence. Decoding happens
// per line and per block, never over the whole document.

import Foundation

/// One source line (or the bounded prefix of a very long line).
public struct ReaderSourceLine: Sendable, Equatable {
    /// Raw byte offset of the line's first byte.
    public var start: Int64
    /// Raw byte offset just past the last content byte (line break excluded,
    /// including a CRLF's CR).
    public var contentEnd: Int64
    /// Raw byte offset of the next line (after the break), or `contentEnd`
    /// when the line is the last one in the stream.
    public var nextStart: Int64
    /// Content bytes, truncated at the splitter's byte limit.
    public var bytes: Data
    /// True when content bytes were dropped from `bytes` (offsets stay exact).
    public var truncated: Bool

    public init(start: Int64, contentEnd: Int64, nextStart: Int64, bytes: Data, truncated: Bool) {
        self.start = start
        self.contentEnd = contentEnd
        self.nextStart = nextStart
        self.bytes = bytes
        self.truncated = truncated
    }
}

/// Streaming raw-byte line splitter. Feed chunks in order and mark the last
/// chunk with `isLast: true`; it never keeps more than one line's bounded
/// prefix in memory.
public struct ReaderLineSplitter: Sendable {
    public let encoding: ReaderTextEncoding
    /// Maximum content bytes retained per line; longer lines keep their exact
    /// offsets and are marked truncated.
    public let lineByteLimit: Int

    private var lineStart: Int64
    private var lineBytes: [UInt8] = []
    private var lineTruncated = false
    private var sawContent = false
    private var cursor: Int64
    private var lastContentByte: UInt8?
    private var lastUnit: UInt16?
    private var partialUnit: UInt8?
    private let littleEndian: Bool

    public init(encoding: ReaderTextEncoding, startOffset: Int64, lineByteLimit: Int) {
        self.encoding = encoding
        self.lineStart = startOffset
        self.cursor = startOffset
        self.lineByteLimit = max(16, lineByteLimit)
        self.littleEndian = encoding == .utf16LittleEndian
    }

    /// Consumes one raw chunk and returns every complete line it produced.
    public mutating func consume(_ data: Data, isLast: Bool) -> [ReaderSourceLine] {
        var lines: [ReaderSourceLine] = []
        if encoding.isASCIICompatible {
            for byte in data {
                if byte == 0x0A {
                    lines.append(finishASCIILine(breakEnd: cursor + 1))
                } else {
                    append(byte)
                    sawContent = true
                }
                cursor += 1
            }
        } else {
            consumeUTF16(data, isLast: isLast, into: &lines)
        }
        if isLast { finishAtEnd(into: &lines) }
        return lines
    }

    /// UTF-16 path: characters are 2-byte units; a unit is never split
    /// incorrectly across chunk boundaries.
    private mutating func consumeUTF16(_ data: Data, isLast: Bool, into lines: inout [ReaderSourceLine]) {
        var bytes = data
        if let partial = partialUnit {
            bytes = Data([partial]) + bytes
            partialUnit = nil
        }
        var index = 0
        while index + 1 < bytes.count {
            let unit: UInt16 = littleEndian
                ? UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                : (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
            if unit == 0x000A {
                lines.append(finishUTF16Line(breakEnd: cursor + 2, breakPrecededByCR: lastUnit == 0x000D))
            } else {
                append(bytes[index])
                append(bytes[index + 1])
                sawContent = true
            }
            lastUnit = unit
            cursor += 2
            index += 2
        }
        if index < bytes.count {
            if !isLast {
                partialUnit = bytes[index]
            } else {
                // A validated stream never ends with half a unit; keep it so
                // offsets stay truthful even if a caller skipped validation.
                append(bytes[index])
                sawContent = true
                cursor += 1
            }
        }
    }

    private mutating func append(_ byte: UInt8) {
        if lineBytes.count < lineByteLimit {
            lineBytes.append(byte)
        } else {
            lineTruncated = true
        }
        lastContentByte = byte
    }

    private mutating func finishASCIILine(breakEnd: Int64) -> ReaderSourceLine {
        var contentEnd = breakEnd - 1
        if sawContent, lastContentByte == 0x0D {
            contentEnd -= 1
            if !lineTruncated, !lineBytes.isEmpty { lineBytes.removeLast() }
        }
        let line = ReaderSourceLine(
            start: lineStart,
            contentEnd: contentEnd,
            nextStart: breakEnd,
            bytes: Data(lineBytes),
            truncated: lineTruncated
        )
        reset(after: breakEnd)
        return line
    }

    private mutating func finishUTF16Line(breakEnd: Int64, breakPrecededByCR: Bool) -> ReaderSourceLine {
        var contentEnd = breakEnd - 2
        if sawContent, breakPrecededByCR {
            contentEnd -= 2
            if !lineTruncated, lineBytes.count >= 2 { lineBytes.removeLast(); lineBytes.removeLast() }
        }
        let line = ReaderSourceLine(
            start: lineStart,
            contentEnd: contentEnd,
            nextStart: breakEnd,
            bytes: Data(lineBytes),
            truncated: lineTruncated
        )
        reset(after: breakEnd)
        return line
    }

    private mutating func reset(after offset: Int64) {
        lineStart = offset
        lineBytes = []
        lineTruncated = false
        sawContent = false
        lastContentByte = nil
        lastUnit = nil
    }

    private mutating func finishAtEnd(into lines: inout [ReaderSourceLine]) {
        guard sawContent || lineStart < cursor else { return }
        lines.append(ReaderSourceLine(
            start: lineStart,
            contentEnd: cursor,
            nextStart: cursor,
            bytes: Data(lineBytes),
            truncated: lineTruncated
        ))
        reset(after: cursor)
    }
}

/// Streaming heading scanner: counts lines and collects deterministic chapter
/// headings without retaining document text.
public struct ReaderLineScanner: Sendable {
    public private(set) var lineCount = 0
    public private(set) var chapters: [ReaderChapterHeading] = []
    public private(set) var chaptersTruncated = false

    private let markdown: Bool
    private let limits: ReaderLimits
    private var previousText: String?
    private var previousWasHeading = false
    private var previousOffset: Int64 = 0
    private var previousLineNumber = 0

    public init(markdown: Bool, limits: ReaderLimits) {
        self.markdown = markdown
        self.limits = limits
    }

    /// Decodes only a bounded prefix of each line: headings are short and the
    /// scanner must stay cheap on huge files.
    public mutating func consume(_ line: ReaderSourceLine, decode: (Data) -> String?) {
        lineCount += 1
        let text = decode(line.bytes.prefix(prefixBytes)) ?? ""
        let isBlank = text.trimmingCharacters(in: .whitespaces).isEmpty
        if markdown, !isBlank, let level = ReaderChapterRules.setextLevel(forLine: text),
           let previous = previousText, !previous.isEmpty, !previousWasHeading {
            appendChapter(title: previous, level: level, byteOffset: previousOffset, lineNumber: previousLineNumber)
            previousWasHeading = true
            previousText = nil
            return
        }
        if !isBlank, let heading = ReaderChapterRules.heading(forLine: text, maxCharacters: limits.maxHeadingCharacters) {
            appendChapter(title: heading.title, level: heading.level, byteOffset: line.start, lineNumber: lineCount)
            previousWasHeading = true
        } else {
            previousWasHeading = false
        }
        previousText = isBlank ? nil : text.trimmingCharacters(in: .whitespaces)
        previousOffset = line.start
        previousLineNumber = lineCount
    }

    private mutating func appendChapter(title: String, level: Int, byteOffset: Int64, lineNumber: Int) {
        guard !chaptersTruncated else { return }
        guard chapters.count < limits.maxChapters else {
            chaptersTruncated = true
            return
        }
        chapters.append(ReaderChapterHeading(
            title: title,
            level: level,
            byteOffset: byteOffset,
            lineNumber: lineNumber
        ))
    }

    private var prefixBytes: Int { max(32, limits.maxHeadingCharacters * 4 + 16) }
}

/// Bounded block builder for one rendered window.
public enum ReaderTextChunker {

    public struct Result: Sendable, Equatable {
        public var blocks: [ReaderTextBlock]
        public var notices: [ReaderNotice]
        public init(blocks: [ReaderTextBlock], notices: [ReaderNotice] = []) {
            self.blocks = blocks
            self.notices = notices
        }
    }

    /// Turns decoded window lines into paragraph blocks. A block is a run of
    /// consecutive non-blank lines kept under `maxBlockCharacters`; a heading
    /// is a standalone single-line paragraph (Markdown ATX or a deterministic
    /// chapter line). With `markdown`, setext underlines promote the previous
    /// line and are not rendered themselves. An oversized single line is cut
    /// at grapheme boundaries; the continuation blocks carry `continues` so a
    /// renderer can keep the line visually whole.
    ///
    /// `startLineNumber` is the 1-based line number of the first line; 0 when
    /// the index was truncated and no exact number is known (block line
    /// numbers then stay 0 instead of being invented).
    public static func blocks(
        from lines: [ReaderSourceLine],
        markdown: Bool,
        startLineNumber: Int,
        limits: ReaderLimits,
        encoding: ReaderTextEncoding,
        decode: (Data) -> String?
    ) -> Result {
        struct PendingLine {
            var text: String
            var start: Int64
            var lineNumber: Int
        }
        var blocks: [ReaderTextBlock] = []
        var notices: Set<ReaderNotice> = []
        var paragraph: [PendingLine] = []

        func byteLength(of text: String) -> Int {
            if let stringEncoding = encoding.stringEncoding,
               let data = text.data(using: stringEncoding) {
                return data.count
            }
            return text.utf8.count
        }

        func emit(_ text: String, start: Int64, lineNumber: Int, kind: ReaderTextBlock.Kind, continues: Bool) {
            blocks.append(ReaderTextBlock(
                byteOffset: start,
                lineNumber: lineNumber,
                kind: kind,
                text: text,
                continues: continues
            ))
        }

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            var kind: ReaderTextBlock.Kind = .body
            if paragraph.count == 1,
               let heading = ReaderChapterRules.heading(
                   forLine: paragraph[0].text,
                   maxCharacters: limits.maxHeadingCharacters) {
                kind = .heading(level: heading.level)
                emit(heading.title, start: paragraph[0].start,
                     lineNumber: paragraph[0].lineNumber, kind: kind, continues: false)
                paragraph = []
                return
            }
            var current = ""
            var currentStart = paragraph[0].start
            var currentLine = paragraph[0].lineNumber
            func flushCurrent() {
                guard !current.isEmpty else { return }
                emit(current, start: currentStart, lineNumber: currentLine, kind: kind, continues: false)
                current = ""
            }
            for line in paragraph {
                if line.text.count > limits.maxBlockCharacters {
                    flushCurrent()
                    var offset = line.start
                    var first = true
                    for piece in splitOversized(line.text, limit: limits.maxBlockCharacters) {
                        emit(piece, start: offset, lineNumber: line.lineNumber, kind: .body, continues: !first)
                        offset += Int64(byteLength(of: piece))
                        first = false
                    }
                    continue
                }
                if current.isEmpty {
                    currentStart = line.start
                    currentLine = line.lineNumber
                } else if current.count + 1 + line.text.count > limits.maxBlockCharacters {
                    flushCurrent()
                    currentStart = line.start
                    currentLine = line.lineNumber
                } else {
                    current += "\n"
                }
                current += line.text
            }
            flushCurrent()
            paragraph = []
        }

        for (index, line) in lines.enumerated() {
            if line.truncated { notices.insert(.displayLineShortened) }
            let lineNumber = startLineNumber > 0 ? startLineNumber + index : 0
            let text = decode(line.bytes)
            let isBlank = (text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            if markdown, !isBlank, paragraph.count == 1, index > 0,
               let level = ReaderChapterRules.setextLevel(forLine: text ?? "") {
                // Promote the single-line paragraph immediately above and drop
                // the underline itself.
                let promoted = paragraph[0]
                paragraph = []
                emit(promoted.text.trimmingCharacters(in: .whitespaces),
                     start: promoted.start, lineNumber: promoted.lineNumber,
                     kind: .heading(level: level), continues: false)
                continue
            }
            if isBlank {
                flushParagraph()
                continue
            }
            // A deterministic heading always stands alone: a chapter title
            // followed directly by prose must not merge into one paragraph.
            if let heading = ReaderChapterRules.heading(forLine: text ?? "", maxCharacters: limits.maxHeadingCharacters) {
                flushParagraph()
                emit(heading.title, start: line.start, lineNumber: lineNumber,
                     kind: .heading(level: heading.level), continues: false)
                continue
            }
            paragraph.append(PendingLine(text: text ?? "", start: line.start, lineNumber: lineNumber))
        }
        flushParagraph()
        return Result(blocks: blocks, notices: Array(notices))
    }

    /// Splits a block at grapheme boundaries so no single block can force a
    /// huge layout; the split never breaks a surrogate pair or emoji cluster.
    public static func splitOversized(_ text: String, limit: Int) -> [String] {
        guard limit > 0, text.count > limit else { return [text] }
        var pieces: [String] = []
        var current = ""
        var currentCount = 0
        for character in text {
            if currentCount >= limit {
                pieces.append(current)
                current = ""
                currentCount = 0
            }
            current.append(character)
            currentCount += 1
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
