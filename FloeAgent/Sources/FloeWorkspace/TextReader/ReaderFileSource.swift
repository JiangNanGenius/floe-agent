// FloeWorkspace — Streaming text reader engine (index, windows, find).
//
// SPDX-License-Identifier: MPL-2.0
//
// One pass over the encoded bytes builds a bounded line/chapter index while
// validating the encoding; rendering then reads line-aligned windows of at
// most `windowBytes` and decodes only the visible blocks. No step loads the
// whole document, and no step writes to the source.
//
// Sources are value types over `ReaderByteSource`: a local file, a staged
// remote copy, or a Notes text document encoded to UTF-8 all use the exact
// same index/window/find code.

import Foundation

/// Bounded index of one document.
public struct ReaderFileIndex: Sendable, Equatable {
    public var encoding: ReaderTextEncoding
    /// Bytes of byte-order mark at the start (content starts after it).
    public var bomLength: Int
    public var byteLength: Int64
    public var totalLines: Int
    /// Raw offsets of line starts (bounded by `ReaderLimits.maxIndexedLines`).
    public var lineStarts: [Int64]
    public var lineTableTruncated: Bool
    public var chapters: [ReaderChapterHeading]
    public var chaptersTruncated: Bool
    public var notices: [ReaderNotice]
    public init(
        encoding: ReaderTextEncoding,
        bomLength: Int,
        byteLength: Int64,
        totalLines: Int,
        lineStarts: [Int64],
        lineTableTruncated: Bool,
        chapters: [ReaderChapterHeading],
        chaptersTruncated: Bool,
        notices: [ReaderNotice]
    ) {
        self.encoding = encoding
        self.bomLength = bomLength
        self.byteLength = byteLength
        self.totalLines = totalLines
        self.lineStarts = lineStarts
        self.lineTableTruncated = lineTableTruncated
        self.chapters = chapters
        self.chaptersTruncated = chaptersTruncated
        self.notices = notices
    }
}

public struct ReaderFileSource: Sendable {
    public let source: any ReaderByteSource
    public let identity: ReaderDocumentIdentity
    /// Markdown files gain setext headings; TXT keeps its own deterministic
    /// chapter rules only.
    public let markdown: Bool
    public let limits: ReaderLimits

    public init(
        source: any ReaderByteSource,
        identity: ReaderDocumentIdentity,
        markdown: Bool,
        limits: ReaderLimits = .default
    ) {
        self.source = source
        self.identity = identity
        self.markdown = markdown
        self.limits = limits
    }

    // MARK: - Open

    /// Parses the encoding and builds the index, then returns the first
    /// window at the restored position (only when the fingerprint and the
    /// encoding the position was measured in both match). The full index
    /// travels back with the result so a session can retain it.
    public func open(
        preferredEncoding: ReaderEncodingSelection = .auto,
        restoring: ReaderPosition? = nil,
        cancellation: ReaderCancellation = .never,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> ReaderOpenBundle {
        let index = try buildIndex(
            preferredEncoding: preferredEncoding,
            cancellation: cancellation,
            progress: progress
        )
        var startByte = Int64(index.bomLength)
        var restored: ReaderPosition?
        if let candidate = restoring,
           candidate.schemaVersion == ReaderPosition.currentSchemaVersion,
           candidate.fingerprint == identity.fingerprint,
           positionEncodingMatches(candidate, resolved: index.encoding, selection: preferredEncoding) {
            startByte = min(max(candidate.anchorByte, Int64(index.bomLength)), index.byteLength)
            restored = candidate
        }
        var window = try makeWindow(startByte: startByte, index: index, backwards: false, cancellation: cancellation)
        if window.blocks.isEmpty, startByte > Int64(index.bomLength) {
            let retreat: Int64 = index.encoding.isUTF16 ? 2 : 1
            window = try makeWindow(startByte: startByte - retreat, index: index, backwards: true, cancellation: cancellation)
        }
        let result = ReaderOpenResult(
            identity: identity,
            encoding: index.encoding,
            byteLength: index.byteLength,
            totalLines: index.totalLines,
            chapters: index.chapters,
            notices: index.notices,
            window: window,
            restoredPosition: restored,
            encodingSelection: preferredEncoding
        )
        return ReaderOpenBundle(result: result, index: index)
    }

    /// A stored position is scoped by the encoding it was measured in: an
    /// untagged (older) position is only used for an automatic open, and a
    /// tagged position only for the exact same resolved encoding. The same
    /// bytes read in two different encodings therefore never cross-restore an
    /// anchor that was measured in the other byte space.
    private func positionEncodingMatches(
        _ position: ReaderPosition,
        resolved: ReaderTextEncoding,
        selection: ReaderEncodingSelection
    ) -> Bool {
        guard let stored = position.encoding else { return selection == .auto }
        return stored == resolved
    }

    // MARK: - Index

    /// Single streaming pass: encodes the probe, validates the whole stream,
    /// records line starts and deterministic chapter headings.
    ///
    /// `preferredEncoding` defaults to `.auto`, which keeps the original
    /// probe order. A `.manual` choice is validated, never trusted: it must
    /// have a real codec, must not contradict the file's encoding mark, and
    /// it is the only backend tried — no silent fallback to another encoding.
    public func buildIndex(
        preferredEncoding: ReaderEncodingSelection = .auto,
        cancellation: ReaderCancellation = .never,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> ReaderFileIndex {
        try cancellation.throwIfCancelled()
        let byteLength = source.byteLength
        guard byteLength > 0 else { throw ReaderError.emptyDocument }
        guard byteLength <= limits.maxFileBytes else { throw ReaderError.fileTooLarge(limit: limits.maxFileBytes) }

        let sampleLength = Int(min(byteLength, 64 * 1024))
        let sample = try source.read(offset: 0, length: sampleLength)
        var probe: ReaderEncodingProbe
        switch preferredEncoding {
        case .auto:
            if let detected = ReaderTextCodec.probe(sample) {
                probe = detected
            } else {
                throw ReaderError.unrecognizedEncoding
            }
        case .manual(let chosen):
            guard chosen.stringEncoding != nil else { throw ReaderError.encodingInvalid(chosen) }
            if ReaderTextCodec.manualChoiceConflictsWithBOM(chosen, sample: sample) {
                throw ReaderError.encodingConflict(chosen)
            }
            let bom = Self.bomLength(of: chosen, in: sample)
            guard let sampleText = ReaderTextCodec.sampleText(sample, as: chosen, bomLength: bom),
                  ReaderTextCodec.looksLikeText(sampleText) else {
                throw ReaderError.encodingInvalid(chosen)
            }
            probe = ReaderEncodingProbe(encoding: chosen, bomLength: bom, fromBOM: bom > 0)
        }
        guard byteLength > Int64(probe.bomLength) else { throw ReaderError.emptyDocument }

        var attempts: [ReaderTextEncoding] = [probe.encoding]
        if preferredEncoding == .auto,
           probe.encoding == .utf8, !probe.fromBOM, ReaderTextCodec.gb18030CodecAvailable {
            // A UTF-8 declaration that fails later can still be a valid
            // GB18030 document (concatenated sources); retry once. A manual
            // choice never gains this fallback candidate.
            attempts.append(.gb18030)
        }
        let rejectsNUL = preferredEncoding.isManual && probe.encoding.isASCIICompatible

        for (attempt, encoding) in attempts.enumerated() {
            if attempt > 0 {
                probe = ReaderEncodingProbe(encoding: encoding, bomLength: 0, fromBOM: false)
            }
            do {
                return try scanIndex(
                    probe: probe,
                    byteLength: byteLength,
                    cancellation: cancellation,
                    progress: progress,
                    rejectsNUL: rejectsNUL,
                    autoDetected: preferredEncoding == .auto
                )
            } catch is ValidationFailure {
                // The stream was not valid in this encoding; an automatic
                // open may try the next defensible candidate while a manual
                // choice fails explicitly (never a silent replacement decode).
                if attempt + 1 >= attempts.count {
                    switch preferredEncoding {
                    case .auto: throw ReaderError.unrecognizedEncoding
                    case .manual(let chosen): throw ReaderError.encodingInvalid(chosen)
                    }
                }
            }
        }
        throw ReaderError.unrecognizedEncoding
    }

    /// Internal marker: the encoded stream failed full-stream validation.
    private struct ValidationFailure: Error {}

    private func scanIndex(
        probe: ReaderEncodingProbe,
        byteLength: Int64,
        cancellation: ReaderCancellation,
        progress: (@Sendable (Double) -> Void)?,
        rejectsNUL: Bool,
        autoDetected: Bool
    ) throws -> ReaderFileIndex {
        var validator = ReaderTextValidator(
            encoding: probe.encoding,
            startOffset: Int64(probe.bomLength),
            rejectsNUL: rejectsNUL
        )
        var splitter = ReaderLineSplitter(
            encoding: probe.encoding,
            startOffset: Int64(probe.bomLength),
            lineByteLimit: limits.maxDisplayLineBytes
        )
        var scanner = ReaderLineScanner(markdown: markdown, limits: limits)
        var lineStarts: [Int64] = []
        var lineTableTruncated = false
        var offset = Int64(probe.bomLength)
        let chunkBytes = max(16 * 1024, limits.chunkBytes)

        while offset < byteLength {
            try cancellation.throwIfCancelled()
            let data = try source.read(offset: offset, length: chunkBytes)
            guard !data.isEmpty else { break }
            let isLast = offset + Int64(data.count) >= byteLength
            if validator.consume(data, isLast: isLast) != nil {
                throw ValidationFailure()
            }
            for line in splitter.consume(data, isLast: isLast) {
                if !lineTableTruncated {
                    if lineStarts.count < limits.maxIndexedLines {
                        lineStarts.append(line.start)
                    } else {
                        lineTableTruncated = true
                    }
                }
                scanner.consume(line) { data in
                    ReaderTextCodec.decode(data, as: probe.encoding)
                }
            }
            offset += Int64(data.count)
            progress?(Double(offset) / Double(byteLength))
        }
        guard !lineStarts.isEmpty else { throw ReaderError.emptyDocument }

        var notices: [ReaderNotice] = []
        if probe.fromBOM { notices.append(.byteOrderMarkStripped) }
        // Only an automatic open can "recover" an encoding heuristically; a
        // manual choice is reported as user-chosen, not as a guess.
        if autoDetected, !probe.fromBOM, probe.encoding != .utf8 { notices.append(.encodingRecovered) }
        if lineTableTruncated { notices.append(.lineTableTruncated) }
        if scanner.chaptersTruncated { notices.append(.chaptersTruncated) }

        return ReaderFileIndex(
            encoding: probe.encoding,
            bomLength: probe.bomLength,
            byteLength: byteLength,
            totalLines: scanner.lineCount,
            lineStarts: lineStarts,
            lineTableTruncated: lineTableTruncated,
            chapters: scanner.chapters,
            chaptersTruncated: scanner.chaptersTruncated,
            notices: notices
        )
    }

    // MARK: - Line numbers

    /// 1-based line number for a raw byte offset; 0 when the line table was
    /// truncated past that point (the number is then genuinely unknown).
    public func lineNumber(forByteOffset offset: Int64, in index: ReaderFileIndex) -> Int {
        guard !index.lineStarts.isEmpty else { return 0 }
        if let first = index.lineStarts.first, offset < first { return 1 }
        if let last = index.lineStarts.last {
            if offset >= last {
                return index.lineTableTruncated ? 0 : index.lineStarts.count
            }
        }
        var low = 0
        var high = index.lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if index.lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    // MARK: - Windows

    /// Line-aligned bounded window. `backwards` returns the region before
    /// `startByte` and keeps the exact same byte space, so scroll anchors
    /// never shift.
    public func window(
        startByte: Int64,
        index: ReaderFileIndex,
        backwards: Bool = false,
        cancellation: ReaderCancellation = .never
    ) throws -> ReaderWindow {
        try cancellation.throwIfCancelled()
        return try makeWindow(startByte: startByte, index: index, backwards: backwards, cancellation: cancellation)
    }

    private func makeWindow(
        startByte: Int64,
        index: ReaderFileIndex,
        backwards: Bool,
        cancellation: ReaderCancellation
    ) throws -> ReaderWindow {
        let contentStart = Int64(index.bomLength)
        let byteLength = index.byteLength
        let anchor = min(max(startByte, contentStart), byteLength)
        let step = index.encoding.isUTF16
            ? max(2, limits.windowBytes & ~1)
            : max(1, limits.windowBytes)

        if backwards {
            guard anchor > contentStart else {
                return try makeWindow(startByte: contentStart, index: index, backwards: false, cancellation: cancellation)
            }
            let target = max(contentStart, anchor - Int64(step))
            let alignedCandidate = try alignedLineStart(for: target, index: index)
            if alignedCandidate < anchor, anchor - alignedCandidate <= Int64(step) * 2 {
                return try buildWindow(start: alignedCandidate, end: anchor, index: index, cancellation: cancellation)
            }
            // Pathological layout (one line longer than the window): fall back
            // to a bounded byte window whose seam is decode-aligned.
            let raw = try source.read(offset: target, length: Int(anchor - target))
            let aligned = alignedStart(raw, offset: target, encoding: index.encoding)
            return try buildWindow(start: min(aligned, anchor), end: anchor, index: index, cancellation: cancellation)
        }

        let alignedAnchor = try alignedLineStart(for: anchor, index: index)
        guard alignedAnchor < byteLength else {
            // Nothing after this offset; the session loads backwards instead.
            return ReaderWindow(
                startByte: anchor, endByte: anchor, blocks: [], hasMore: false,
                truncatedAtLimit: false, startLineNumber: 0, totalLines: index.totalLines,
                notices: [], progress: byteLength > 0 ? Double(anchor) / Double(byteLength) : 0
            )
        }
        let slack = index.encoding.isUTF16 ? 4 : 2
        let raw = try source.read(offset: alignedAnchor, length: step + slack)
        guard !raw.isEmpty else {
            return ReaderWindow(
                startByte: alignedAnchor, endByte: alignedAnchor, blocks: [], hasMore: false,
                truncatedAtLimit: false, startLineNumber: 0, totalLines: index.totalLines,
                notices: [], progress: byteLength > 0 ? Double(alignedAnchor) / Double(byteLength) : 0
            )
        }
        if let breakEnd = lastLineBreakEnd(in: raw, encoding: index.encoding, baseOffset: alignedAnchor) {
            return try buildWindow(start: alignedAnchor, end: breakEnd, index: index, cancellation: cancellation)
        }
        // No break inside the window: a single line longer than `windowBytes`
        // (or the document's last line). Cut at the next safe sequence
        // boundary so nothing is ever decoded from a split sequence.
        let consumed = alignedConsumed(raw, encoding: index.encoding)
        let end = min(byteLength, alignedAnchor + Int64(max(1, consumed)))
        return try buildWindow(start: alignedAnchor, end: end, index: index, cancellation: cancellation)
    }

    /// Start of the line containing `offset`: exact through the line table
    /// when it is complete, otherwise a bounded backward scan. This keeps
    /// find/chapter/position jumps rendering whole lines.
    private func alignedLineStart(for offset: Int64, index: ReaderFileIndex) throws -> Int64 {
        let contentStart = Int64(index.bomLength)
        guard offset > contentStart else { return contentStart }
        if !index.lineStarts.isEmpty, !index.lineTableTruncated {
            var low = 0
            var high = index.lineStarts.count - 1
            if index.lineStarts[low] > offset { return contentStart }
            while low < high {
                let mid = (low + high + 1) / 2
                if index.lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return max(contentStart, index.lineStarts[low])
        }
        var scanLimit: Int64 = 64 * 1024
        if index.encoding.isUTF16 { scanLimit &= ~1 }
        var probeStart = offset - scanLimit
        if probeStart < contentStart { probeStart = contentStart }
        if index.encoding.isUTF16, (probeStart - contentStart) % 2 != 0 { probeStart += 1 }
        while probeStart < offset {
            let raw = try source.read(offset: probeStart, length: Int(offset - probeStart))
            if let breakEnd = lastLineBreakIn(raw, encoding: index.encoding, baseOffset: probeStart) {
                return breakEnd
            }
            if probeStart == contentStart { return contentStart }
            probeStart = max(contentStart, probeStart - scanLimit)
            if index.encoding.isUTF16, (probeStart - contentStart) % 2 != 0 { probeStart += 1 }
        }
        return offset
    }

    /// End offset (just past the break) of the LAST line break in `raw`.
    private func lastLineBreakIn(_ raw: Data, encoding: ReaderTextEncoding, baseOffset: Int64) -> Int64? {
        lastLineBreakEnd(in: raw, encoding: encoding, baseOffset: baseOffset)
    }

    private func buildWindow(
        start: Int64,
        end: Int64,
        index: ReaderFileIndex,
        cancellation: ReaderCancellation
    ) throws -> ReaderWindow {
        try cancellation.throwIfCancelled()
        guard end > start else {
            return ReaderWindow(
                startByte: start, endByte: start, blocks: [], hasMore: false,
                truncatedAtLimit: false, startLineNumber: 0, totalLines: index.totalLines,
                notices: [], progress: index.byteLength > 0 ? Double(start) / Double(index.byteLength) : 0
            )
        }
        let raw = try source.read(offset: start, length: Int(end - start))
        var splitter = ReaderLineSplitter(
            encoding: index.encoding,
            startOffset: start,
            lineByteLimit: limits.maxDisplayLineBytes
        )
        let isLast = end >= index.byteLength
        let lines = splitter.consume(raw, isLast: isLast)
        let startLineNumber = lineNumber(forByteOffset: start, in: index)
        let chunked = ReaderTextChunker.blocks(
            from: lines,
            markdown: markdown,
            startLineNumber: startLineNumber,
            limits: limits,
            encoding: index.encoding
        ) { data in
            ReaderTextCodec.decode(data, as: index.encoding)
        }
        var blocks = chunked.blocks
        var endByte = end
        var truncated = end < index.byteLength
        if blocks.count > limits.maxBlocksPerWindow {
            blocks = Array(blocks.prefix(limits.maxBlocksPerWindow))
            truncated = true
            if let last = blocks.last,
               let line = lines.last(where: { $0.start <= last.byteOffset && last.byteOffset < max($0.nextStart, $0.start + 1) }) {
                endByte = max(last.byteOffset, line.nextStart)
            } else if let last = blocks.last {
                endByte = max(last.byteOffset, start)
            }
        }
        var notices = chunked.notices
        if index.lineTableTruncated, !notices.contains(.lineTableTruncated) {
            notices.append(.lineTableTruncated)
        }
        return ReaderWindow(
            startByte: start,
            endByte: endByte,
            blocks: blocks,
            hasMore: endByte < index.byteLength,
            truncatedAtLimit: truncated,
            startLineNumber: startLineNumber,
            totalLines: index.totalLines,
            notices: notices,
            progress: index.byteLength > 0 ? Double(endByte) / Double(index.byteLength) : 0
        )
    }

    // MARK: - Find

    /// Case-insensitive find over the whole document, bounded by
    /// `findLimit` and `maxFindScanBytes`. Byte offsets are verified by
    /// re-encoding the matched prefix; when verification fails the hit points
    /// at its window start with `exactOffset == false` instead of guessing.
    public func find(
        _ query: String,
        index: ReaderFileIndex,
        cancellation: ReaderCancellation = .never
    ) throws -> ReaderFindResult {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ReaderFindResult(hits: [], truncated: false) }
        guard let stringEncoding = index.encoding.stringEncoding else { throw ReaderError.unrecognizedEncoding }
        guard let needleData = needle.data(using: stringEncoding) else {
            return ReaderFindResult(hits: [], truncated: false)
        }

        let contentStart = Int64(index.bomLength)
        let byteLength = index.byteLength
        let step = Int64(max(64 * 1024, min(limits.chunkBytes, 512 * 1024)))
        let overlap = Int64(min(64 * 1024, max(16, needleData.count * 4)))
        var hits: [ReaderFindHit] = []
        var truncated = false
        var cursor = contentStart
        var scanned: Int64 = 0
        var lastHitOffset: Int64 = -1

        while cursor < byteLength {
            try cancellation.throwIfCancelled()
            let readLength = Int(min(step, byteLength - cursor))
            let raw = try source.read(offset: cursor, length: readLength + Int(overlap))
            guard !raw.isEmpty else { break }
            if let region = decodeRegion(raw, offset: cursor, encoding: index.encoding) {
                let text = region.text
                var searchStart = text.startIndex
                while searchStart < text.endIndex,
                      let range = text.range(
                        of: needle,
                        options: [.caseInsensitive, .diacriticInsensitive],
                        range: searchStart..<text.endIndex
                      ) {
                    let prefix = String(text[text.startIndex..<range.lowerBound])
                    let exact = exactOffset(
                        prefix: prefix,
                        raw: raw,
                        droppedStart: region.droppedStart,
                        regionStart: region.start,
                        regionEnd: region.end,
                        encoding: index.encoding
                    )
                    let byteOffset = exact ?? region.start
                    if byteOffset > lastHitOffset {
                        lastHitOffset = byteOffset
                        hits.append(ReaderFindHit(
                            byteOffset: byteOffset,
                            byteLength: exact == nil ? 0 : needleData.count,
                            exactOffset: exact != nil,
                            lineNumber: lineNumber(forByteOffset: byteOffset, in: index),
                            snippet: Self.snippet(in: text, around: range, limit: limits.findSnippetCharacters)
                        ))
                    }
                    searchStart = range.upperBound
                    if hits.count >= limits.findLimit { truncated = true; break }
                }
            }
            scanned += Int64(readLength)
            if hits.count >= limits.findLimit { truncated = true; break }
            if scanned >= limits.maxFindScanBytes { truncated = true; break }
            cursor += Int64(readLength)
        }
        return ReaderFindResult(hits: hits, truncated: truncated)
    }

    // MARK: - Region helpers

    private struct DecodedRegion {
        var text: String
        var start: Int64
        var end: Int64
        var droppedStart: Int
    }

    /// Decodes `raw` as one region, trimming a partial sequence at either
    /// end. Returns nil when no alignment decodes.
    private func decodeRegion(_ raw: Data, offset: Int64, encoding: ReaderTextEncoding) -> DecodedRegion? {
        for dropped in 0...3 {
            guard dropped < raw.count else { break }
            let slice = Data(raw.dropFirst(dropped))
            let consumed = alignedConsumed(slice, encoding: encoding)
            guard consumed > 0 else { continue }
            let candidate = Data(slice.prefix(consumed))
            if let text = ReaderTextCodec.decode(candidate, as: encoding) {
                return DecodedRegion(
                    text: text,
                    start: offset + Int64(dropped),
                    end: offset + Int64(dropped + consumed),
                    droppedStart: dropped
                )
            }
        }
        return nil
    }

    /// Bytes of `raw` that decode cleanly from the start (drops only a
    /// trailing partial sequence / unpaired surrogate).
    private func alignedConsumed(_ raw: Data, encoding: ReaderTextEncoding) -> Int {
        if encoding.isUTF16 {
            var count = raw.count & ~1
            var attempts = 0
            while count > 0, attempts < 4 {
                if ReaderTextCodec.decode(Data(raw.prefix(count)), as: encoding) != nil { return count }
                count -= 2
                attempts += 1
            }
            return raw.count & ~1
        }
        if ReaderTextCodec.decode(raw, as: encoding) != nil { return raw.count }
        for drop in 1...3 where drop < raw.count {
            let candidate = Data(raw.prefix(raw.count - drop))
            if ReaderTextCodec.decode(candidate, as: encoding) != nil { return candidate.count }
        }
        return raw.count
    }

    private func alignedStart(_ raw: Data, offset: Int64, encoding: ReaderTextEncoding) -> Int64 {
        for drop in 0...3 {
            guard drop < raw.count else { break }
            let slice = Data(raw.dropFirst(drop))
            if ReaderTextCodec.decode(slice, as: encoding) != nil { return offset + Int64(drop) }
        }
        return offset
    }

    private func exactOffset(
        prefix: String,
        raw: Data,
        droppedStart: Int,
        regionStart: Int64,
        regionEnd: Int64,
        encoding: ReaderTextEncoding
    ) -> Int64? {
        guard let stringEncoding = encoding.stringEncoding,
              let prefixData = prefix.data(using: stringEncoding) else { return nil }
        let count = prefixData.count
        guard count >= 0, droppedStart + count <= raw.count else { return nil }
        let rawPrefix = raw.subdata(in: droppedStart..<(droppedStart + count))
        guard rawPrefix == prefixData else { return nil }
        let candidate = regionStart + Int64(count)
        guard candidate <= regionEnd else { return nil }
        return candidate
    }

    private static func snippet(in text: String, around range: Range<String.Index>, limit: Int) -> String {
        let maxCharacters = max(16, limit)
        let before = maxCharacters / 3
        let start = text.index(range.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: maxCharacters, limitedBy: text.endIndex) ?? text.endIndex
        let raw = String(text[start..<end])
        return raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Byte scanning

    private func firstLineBreakEnd(in raw: Data, encoding: ReaderTextEncoding, baseOffset: Int64) -> Int64? {
        if encoding.isASCIICompatible {
            guard let index = raw.firstIndex(of: 0x0A) else { return nil }
            return baseOffset + Int64(raw.distance(from: raw.startIndex, to: index)) + 1
        }
        let little = encoding == .utf16LittleEndian
        var index = 0
        while index + 1 < raw.count {
            let unit: UInt16 = little
                ? UInt16(raw[raw.startIndex + index]) | (UInt16(raw[raw.startIndex + index + 1]) << 8)
                : (UInt16(raw[raw.startIndex + index]) << 8) | UInt16(raw[raw.startIndex + index + 1])
            if unit == 0x000A { return baseOffset + Int64(index) + 2 }
            index += 2
        }
        return nil
    }

    private func lastLineBreakEnd(in raw: Data, encoding: ReaderTextEncoding, baseOffset: Int64) -> Int64? {
        if encoding.isASCIICompatible {
            guard let index = raw.lastIndex(of: 0x0A) else { return nil }
            return baseOffset + Int64(raw.distance(from: raw.startIndex, to: index)) + 1
        }
        let little = encoding == .utf16LittleEndian
        var index = raw.count - 2
        while index >= 0 {
            let unit: UInt16 = little
                ? UInt16(raw[raw.startIndex + index]) | (UInt16(raw[raw.startIndex + index + 1]) << 8)
                : (UInt16(raw[raw.startIndex + index]) << 8) | UInt16(raw[raw.startIndex + index + 1])
            if unit == 0x000A { return baseOffset + Int64(index) + 2 }
            index -= 2
        }
        return nil
    }

    private static func bomLength(of encoding: ReaderTextEncoding, in sample: Data) -> Int {
        switch encoding {
        case .utf8: return sample.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        case .utf16LittleEndian: return sample.starts(with: [0xFF, 0xFE]) ? 2 : 0
        case .utf16BigEndian: return sample.starts(with: [0xFE, 0xFF]) ? 2 : 0
        case .gb18030: return 0
        }
    }
}
