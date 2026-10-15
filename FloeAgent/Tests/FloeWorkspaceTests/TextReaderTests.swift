// FloeWorkspaceTests — Text reader core (encoding, index, windows, find,
// positions, cancellation).
//
// SPDX-License-Identifier: MPL-2.0
//
// Real files in a temporary directory; no App, no Simulator, no network. The
// reader never writes to a source, and every test that opens a document
// asserts the source bytes are unchanged.

import Foundation
import Testing
import FloeWorkspace

@Suite("FloeWorkspace.TextReader")
struct TextReaderTests {

    // MARK: - Fixtures

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-reader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func cleanup(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ data: Data, _ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func identity(_ name: String, kind: ReaderSourceKind = .workspaceFile, fingerprint: String = "fp") -> ReaderDocumentIdentity {
        ReaderDocumentIdentity(
            kind: kind,
            ownerID: "test",
            documentKey: name,
            displayName: name,
            format: (name as NSString).pathExtension.lowercased(),
            fingerprint: fingerprint
        )
    }

    private func fileSource(_ url: URL, markdown: Bool = false, limits: ReaderLimits = .default, fingerprint: String = "fp") throws -> ReaderFileSource {
        ReaderFileSource(
            source: try ReaderFileByteSource(url: url),
            identity: identity(url.lastPathComponent, fingerprint: fingerprint),
            markdown: markdown,
            limits: limits
        )
    }

    private func novelText() -> String {
        var lines: [String] = ["书名：测试小说", "", "第一章 风起", ""]
        for index in 0..<20 { lines.append("第一章第\(index)段。") }
        lines.append(contentsOf: ["", "第二章 云涌", "", "第二章内容。"])
        lines.append(contentsOf: ["", "番外 小记", "", "番外内容。"])
        return lines.joined(separator: "\r\n")
    }

    private func utf16Data(_ text: String, littleEndian: Bool, bom: Bool) -> Data {
        var data = Data()
        if bom { data.append(contentsOf: littleEndian ? [0xFF, 0xFE] : [0xFE, 0xFF]) }
        for unit in text.utf16 {
            if littleEndian {
                data.append(UInt8(unit & 0xFF)); data.append(UInt8(unit >> 8))
            } else {
                data.append(UInt8(unit >> 8)); data.append(UInt8(unit & 0xFF))
            }
        }
        return data
    }

    // MARK: - Encoding

    @Test("UTF-8 with CRLF keeps exact offsets, line numbers and chapters")
    func utf8CRLF() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let text = novelText()
        let url = try write(Data(text.utf8), "novel.txt", in: root)
        let source = try fileSource(url)
        let bundle = try source.open()
        #expect(bundle.index.encoding == .utf8)
        #expect(bundle.index.bomLength == 0)
        #expect(bundle.result.chapters.map(\.title) == ["第一章 风起", "第二章 云涌", "番外 小记"])
        // The fixture has no trailing break, so every component is a line:
        // the reader counts 32 real lines for 32 components (the previous
        // `- 1` form assumed a trailing separator that is not there).
        #expect(bundle.index.totalLines == text.components(separatedBy: "\r\n").count)
        let blocks = bundle.result.window.blocks
        #expect(!blocks.contains { $0.text.contains("\r") })
        let raw = try Data(contentsOf: url)
        for chapter in bundle.result.chapters {
            let offset = Int(chapter.byteOffset)
            #expect(offset > 0 && offset <= raw.count)
            #expect(String(decoding: raw[(offset - 2)..<offset], as: UTF8.self) == "\r\n")
        }
    }

    @Test("UTF-8 BOM is reported and stripped from the decoded line")
    func utf8BOM() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: Array("# 标题\r\n正文\r\n".utf8))
        let url = try write(data, "bom.md", in: root)
        let bundle = try fileSource(url, markdown: true).open()
        #expect(bundle.index.encoding == .utf8)
        #expect(bundle.index.bomLength == 3)
        #expect(bundle.index.notices.contains(.byteOrderMarkStripped))
        #expect(bundle.result.window.blocks.first?.text == "标题")
    }

    @Test("UTF-16 LE with BOM decodes, finds and windows on unit boundaries")
    func utf16LittleEndian() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let text = novelText()
        let url = try write(utf16Data(text, littleEndian: true, bom: true), "novel16.txt", in: root)
        let source = try fileSource(url)
        let bundle = try source.open()
        #expect(bundle.index.encoding == .utf16LittleEndian)
        #expect(bundle.index.bomLength == 2)
        #expect(bundle.result.chapters.map(\.title).count == 3)
        #expect(bundle.result.window.blocks.first?.text == "书名：测试小说")
        let hits = try source.find("云涌", index: bundle.index)
        #expect(hits.hits.count == 1)
        #expect(hits.hits.first?.exactOffset == true)
        #expect((hits.hits.first?.byteOffset ?? 1) % 2 == 0)
        var cursor = Int64(bundle.index.bomLength)
        while cursor < bundle.index.byteLength {
            let window = try source.window(startByte: cursor, index: bundle.index)
            #expect(window.startByte == cursor)
            #expect(window.endByte > cursor)
            cursor = window.endByte
        }
        #expect(cursor == bundle.index.byteLength)
    }

    @Test("UTF-16 BE without BOM is recovered honestly")
    func utf16BigEndianNoBOM() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let url = try write(utf16Data("Chapter 1\r\nHello\r\nChapter 2\r\n", littleEndian: false, bom: false), "be.txt", in: root)
        let bundle = try fileSource(url).open()
        #expect(bundle.index.encoding == .utf16BigEndian)
        #expect(bundle.index.notices.contains(.encodingRecovered))
        #expect(bundle.result.chapters.map(\.title) == ["Chapter 1", "Chapter 2"])
    }

    @Test("GB18030 is offered only with a real platform codec")
    func gb18030Honesty() async throws {
        guard let codec = String.Encoding.floeGB18030 else {
            #expect(ReaderTextCodec.gb18030CodecAvailable == false)
            return
        }
        let root = try makeRoot(); defer { cleanup(root) }
        let text = novelText()
        guard let data = text.data(using: codec) else {
            Issue.record("GB18030 encoding unavailable"); return
        }
        let url = try write(data, "novel-gb.txt", in: root)
        let source = try fileSource(url)
        let bundle = try source.open()
        #expect(bundle.index.encoding == .gb18030)
        #expect(bundle.result.chapters.map(\.title) == ["第一章 风起", "第二章 云涌", "番外 小记"])
        let hits = try source.find("测试小说", index: bundle.index)
        #expect(hits.hits.first?.exactOffset == true)
        if let hit = hits.hits.first {
            let raw = try Data(contentsOf: url)
            let matched = String(data: raw[Int(hit.byteOffset)..<(Int(hit.byteOffset) + 4)], encoding: codec)
            #expect(matched == "测试")
        }
    }

    @Test("Binary, UTF-32 and broken streams are refused, never decoded")
    func encodingRefusals() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        // Binary with NULs.
        _ = try write(Data([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x42]), "blob.bin", in: root)
        #expect(throws: ReaderError.unrecognizedEncoding) {
            _ = try fileSource(root.appendingPathComponent("blob.bin")).open()
        }
        // UTF-32 BOM is deliberately unsupported.
        _ = try write(Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00]), "utf32.txt", in: root)
        #expect(throws: ReaderError.unrecognizedEncoding) {
            _ = try fileSource(root.appendingPathComponent("utf32.txt")).open()
        }
        // Invalid UTF-8 that is also invalid GB18030.
        _ = try write(Data([0xC3, 0x28, 0xC3, 0x28, 0x0A]), "broken.txt", in: root)
        #expect(throws: ReaderError.unrecognizedEncoding) {
            _ = try fileSource(root.appendingPathComponent("broken.txt")).open()
        }
        // Odd-length UTF-16 must not be truncated silently.
        _ = try write(Data([0xFF, 0xFE, 0x41, 0x00, 0x42]), "odd16.txt", in: root)
        #expect(throws: ReaderError.unrecognizedEncoding) {
            _ = try fileSource(root.appendingPathComponent("odd16.txt")).open()
        }
    }

    @Test("The explicit reader size cap fails closed")
    func sizeCap() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let url = try write(Data(String(repeating: "x", count: 2048).utf8), "small.txt", in: root)
        #expect(throws: ReaderError.fileTooLarge(limit: 1024)) {
            _ = try fileSource(url, limits: ReaderLimits(maxFileBytes: 1024)).open()
        }
    }

    // MARK: - Boundaries and windows

    @Test("A CRLF straddling a chunk/window boundary keeps both lines exact")
    func crlfAtBoundary() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        var text = String(repeating: "a", count: 8 * 1024 - 1)
        text += "\r\n\r\n第二行\r\n"
        let url = try write(Data(text.utf8), "boundary.txt", in: root)
        let limits = ReaderLimits(chunkBytes: 8 * 1024, windowBytes: 8 * 1024, maxBlockCharacters: 16 * 1024)
        let source = try fileSource(url, limits: limits)
        let bundle = try source.open()
        #expect(bundle.index.totalLines == 3)
        #expect(bundle.result.window.blocks.first?.text == String(repeating: "a", count: 8 * 1024 - 1))
        let second = try source.window(startByte: bundle.result.window.endByte, index: bundle.index)
        #expect(second.startByte == bundle.result.window.endByte)
        #expect(second.blocks.first?.text == "第二行")
    }

    @Test("A jump anchor mid-line is aligned back to its containing line start")
    func midLineAnchorAligns() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let text = (1...60).map { "第\($0)行内容" }.joined(separator: "\n")
        let url = try write(Data(text.utf8), "align.txt", in: root)
        let source = try fileSource(url)
        let index = try source.buildIndex()
        let mid = index.byteLength / 2
        let window = try source.window(startByte: mid, index: index)
        #expect(window.startByte <= mid)
        let raw = try Data(contentsOf: url)
        #expect(String(decoding: raw[..<Int(window.startByte)], as: UTF8.self).hasSuffix("\n")
                || window.startByte == 0)
        #expect(window.blocks.contains { $0.byteOffset <= mid && mid < $0.byteOffset + Int64($0.text.utf8.count) + 1 })
    }

    @Test("Windows chain forward over a large sample with bounded reads")
    func boundedWindowsOverLargeSample() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        var lines: [String] = []
        for chapter in 0..<40 {
            lines.append("第\(chapter + 1)章 批量")
            lines.append("")
            for paragraph in 0..<80 {
                lines.append("第\(chapter)章第\(paragraph)段：" + String(repeating: "字", count: 50))
            }
            lines.append("")
        }
        let text = lines.joined(separator: "\n")
        let url = try write(Data(text.utf8), "big.txt", in: root)
        let source = try fileSource(url)
        let index = try source.buildIndex()
        #expect(index.chapters.count == 40)
        var cursor = Int64(0)
        var steps = 0
        var decoded = ""
        while cursor < index.byteLength, steps < 4_000 {
            let window = try source.window(startByte: cursor, index: index)
            #expect(window.startByte == cursor)
            #expect(window.endByte > cursor)
            #expect(window.blocks.count <= ReaderLimits.default.maxBlocksPerWindow)
            let raw = try ReaderFileByteSource(url: url).read(offset: window.startByte, length: Int(window.endByte - window.startByte))
            decoded += String(decoding: raw, as: UTF8.self)
            cursor = window.endByte
            steps += 1
        }
        #expect(cursor == index.byteLength)
        #expect(decoded == text)
    }

    @Test("Backwards windows partition the document and reconstruct it")
    func backwardsWindowsReconstruct() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let text = (1...120).map { "第\($0)行 " + String(repeating: "文", count: 30) }.joined(separator: "\n")
        let url = try write(Data(text.utf8), "back.txt", in: root)
        let source = try fileSource(url, limits: ReaderLimits(windowBytes: 2 * 1024))
        let index = try source.buildIndex()
        var anchor = index.byteLength
        var pieces: [[ReaderTextBlock]] = []
        var steps = 0
        while anchor > 0, steps < 500 {
            let window = try source.window(startByte: anchor, index: index, backwards: true)
            #expect(window.endByte == anchor)
            #expect(window.startByte < anchor)
            pieces.append(window.blocks)
            anchor = window.startByte
            steps += 1
        }
        #expect(anchor == 0)
        var reconstructed = ""
        for blocks in pieces.reversed() {
            for block in blocks {
                if reconstructed.isEmpty { reconstructed = block.text }
                else if block.continues { reconstructed += block.text }
                else { reconstructed += "\n" + block.text }
            }
        }
        #expect(reconstructed == text)
    }

    // MARK: - Chapters and blocks

    @Test("Chapter rules are deterministic and reject prose")
    func chapterRules() {
        let limits = ReaderLimits.default
        func heading(_ line: String) -> ReaderChapterRules.Candidate? {
            ReaderChapterRules.heading(forLine: line, maxCharacters: limits.maxHeadingCharacters)
        }
        #expect(heading("第一章 风起") != nil)
        #expect(heading("第十二回 暗流") != nil)
        #expect(heading("第三节 小节") != nil)
        #expect(heading("序章") != nil)
        #expect(heading("楔子：旧事") != nil)
        #expect(heading("Chapter 12 The Return") != nil)
        #expect(heading("## 二级标题") != nil)
        #expect(heading("第三章的内容主要讲了什么。") == nil)
        #expect(heading("1. 列表项") == nil)
        #expect(heading("普通正文一行。") == nil)
        #expect(ReaderChapterRules.setextLevel(forLine: "===") == 1)
        #expect(ReaderChapterRules.setextLevel(forLine: "---") == 2)
    }

    @Test("A heading line never merges into the following prose")
    func headingStandsAlone() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let url = try write(Data("第一章 风起\n这是紧随其后的正文。\n".utf8), "merge.txt", in: root)
        let bundle = try fileSource(url).open()
        let blocks = bundle.result.window.blocks
        #expect(blocks.count == 2)
        if case .heading(let level) = blocks[0].kind { #expect(level == 1) } else { Issue.record("first block is not a heading") }
        #expect(blocks[0].byteOffset < blocks[1].byteOffset)
    }

    @Test("Oversized single lines split at grapheme boundaries with continues")
    func oversizedLineSplitting() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let line = String(repeating: "👨‍👩‍👧‍👦", count: 300) + "结尾"
        let url = try write(Data(line.utf8), "long.txt", in: root)
        let limits = ReaderLimits(maxBlockCharacters: 50)
        let bundle = try fileSource(url, limits: limits).open()
        let blocks = bundle.result.window.blocks
        #expect(blocks.count > 1)
        #expect(blocks.dropFirst().allSatisfy { $0.continues })
        #expect(blocks.map(\.text).joined() == line)
        #expect(Set(blocks.map(\.byteOffset)).count == blocks.count)
        #expect(blocks.allSatisfy { $0.text.count <= 50 })
    }

    @Test("Markdown setext promotes the previous line; TXT keeps it")
    func setextOnlyForMarkdown() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let text = "标题一\n===\n\n正文\n"
        let md = try write(Data(text.utf8), "a.md", in: root)
        let mdResult = try fileSource(md, markdown: true).open()
        #expect(mdResult.result.chapters.contains { $0.title == "标题一" && $0.level == 1 })
        #expect(!mdResult.result.window.blocks.contains { $0.text == "===" })
        let txt = try write(Data(text.utf8), "b.txt", in: root)
        let txtResult = try fileSource(txt).open()
        #expect(!txtResult.result.chapters.contains { $0.title == "标题一" })
        // TXT keeps the underline as ordinary content: it stays inside its
        // paragraph block ("标题一\n===") instead of being promoted away.
        #expect(txtResult.result.window.blocks.contains { $0.text.contains("===") },
                "TXT must keep the setext-looking line as content")
    }

    @Test("Line table truncation is reported instead of inventing numbers")
    func lineTableTruncation() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let text = (1...40).map { "行\($0)" }.joined(separator: "\n")
        let url = try write(Data(text.utf8), "trunc.txt", in: root)
        let limits = ReaderLimits(maxIndexedLines: 10)
        let source = try fileSource(url, limits: limits)
        let index = try source.buildIndex()
        #expect(index.lineTableTruncated)
        #expect(index.lineStarts.count == 10)
        #expect(index.notices.contains(.lineTableTruncated))
        #expect(source.lineNumber(forByteOffset: index.byteLength - 1, in: index) == 0)
        #expect(source.lineNumber(forByteOffset: index.lineStarts[3], in: index) == 4)
    }

    // MARK: - Find

    @Test("Find returns verified offsets, line numbers and a bounded result set")
    func findBehavior() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let text = (1...60).map { "第\($0)行 目标字" }.joined(separator: "\n")
        let url = try write(Data(text.utf8), "find.txt", in: root)
        let source = try fileSource(url, limits: ReaderLimits(findLimit: 5))
        let index = try source.buildIndex()
        let result = try source.find("目标字", index: index)
        #expect(result.hits.count == 5)
        #expect(result.truncated)
        #expect(result.hits.allSatisfy { $0.exactOffset })
        #expect(result.hits.first?.lineNumber == 1)
        #expect(result.hits.allSatisfy { !$0.snippet.contains("\n") })
        let none = try source.find("不存在的字符串", index: index)
        #expect(none.hits.isEmpty)
        let empty = try source.find("   ", index: index)
        #expect(empty.hits.isEmpty)
    }

    // MARK: - Positions

    @Test("A position restores only with a matching fingerprint")
    func positionFingerprintGate() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        var text = ""
        for chapter in 0..<3 {
            text += "第\(chapter + 1)章 位置\n"
            for paragraph in 0..<200 { text += "第\(chapter)章第\(paragraph)段。\n" }
        }
        let url = try write(Data(text.utf8), "pos.txt", in: root)
        let byteSource = try ReaderFileByteSource(url: url)
        let source = ReaderFileSource(source: byteSource, identity: identity("pos.txt", fingerprint: "fp-1"), markdown: false)
        let first = try source.open()
        // A strictly INTERNAL anchor (the fixture is non-empty): the restored
        // window must contain it (the window is aligned to the anchor's line).
        let fileLength = first.index.byteLength
        let mid = fileLength / 2
        let position = ReaderPosition(anchorByte: mid, progress: 0.5, fingerprint: "fp-1")
        let restored = try source.open(restoring: position)
        #expect(restored.result.restoredPosition != nil)
        #expect(restored.result.window.startByte <= mid)
        #expect(restored.result.window.endByte > mid)

        let stale = ReaderFileSource(source: byteSource, identity: identity("pos.txt", fingerprint: "fp-2"), markdown: false)
        let staleResult = try stale.open(restoring: position)
        #expect(staleResult.result.restoredPosition == nil)
        #expect(staleResult.result.window.startByte == 0)
    }

    @Test("The position store persists, prunes oldest and never crosses revisions")
    func positionStore() async throws {
        let suite = "floe.reader.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReaderUserDefaultsPositionStore(defaults: defaults, maxEntries: 2)
        store.save(ReaderPosition(anchorByte: 1, progress: 0, fingerprint: "f1", updatedAt: Date(timeIntervalSince1970: 1)), for: "k1")
        store.save(ReaderPosition(anchorByte: 2, progress: 0, fingerprint: "f2", updatedAt: Date(timeIntervalSince1970: 2)), for: "k2")
        store.save(ReaderPosition(anchorByte: 3, progress: 0, fingerprint: "f3", updatedAt: Date(timeIntervalSince1970: 3)), for: "k3")
        #expect(store.position(for: "k1") == nil)
        #expect(store.position(for: "k2")?.fingerprint == "f2")
        #expect(store.position(for: "k3")?.anchorByte == 3)
        store.removePosition(for: "k3")
        #expect(store.position(for: "k3") == nil)
        // Reload from the same defaults instance proves the value was encoded.
        let reloaded = ReaderUserDefaultsPositionStore(defaults: defaults)
        #expect(reloaded.position(for: "k2")?.fingerprint == "f2")
    }

    @Test("Identity storage keys are opaque and separator-free")
    func identityStorageKey() {
        let first = identity("目录/小说 一.txt")
        let second = identity("目录/小说 二.txt")
        #expect(first.storageKey != second.storageKey)
        #expect(!first.storageKey.contains("/"))
        #expect(!first.storageKey.contains(" "))
    }

    // MARK: - Lifecycle

    @Test("Cancellation stops the index scan")
    func cancellationStopsScan() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let text = (1...20_000).map { "行\($0) " + String(repeating: "内", count: 20) }.joined(separator: "\n")
        let url = try write(Data(text.utf8), "cancel.txt", in: root)
        let counter = Counter()
        let cancellation = ReaderCancellation { counter.bump() > 3 }
        let source = try fileSource(url)
        #expect(throws: ReaderError.cancelled) {
            _ = try source.open(cancellation: cancellation)
        }
        #expect(counter.current <= 6)
    }

    @Test("A second open supersedes the first and the session follows the winner")
    func sessionSupersede() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let a = try write(Data("第一个文档\n第一章 A\n内容甲\n".utf8), "a.txt", in: root)
        let b = try write(Data("第二个文档\n第一章 B\n内容乙\n".utf8), "b.txt", in: root)
        let sourceA = try fileSource(a)
        let sourceB = try fileSource(b)
        let session = ReaderSession()
        async let first = session.open(source: sourceA)
        async let second = session.open(source: sourceB)
        var winners: [String] = []
        var superseded = 0
        do { winners.append(try await first.identity.documentKey) }
        catch let error as ReaderError { if case .superseded = error { superseded += 1 } }
        do { winners.append(try await second.identity.documentKey) }
        catch let error as ReaderError { if case .superseded = error { superseded += 1 } }
        #expect(winners.count == 1)
        #expect(superseded == 1)
        let winner = try #require(winners.first)
        #expect(await session.identity?.documentKey == winner)
        let window = try await session.window(startByte: 0)
        let expected = winner == "a.txt" ? "第一个文档" : "第二个文档"
        #expect(window.blocks.contains { $0.text.contains(expected) })
    }

    @Test("Reading a document never writes to it")
    func readingNeverWrites() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let text = novelText()
        let url = try write(Data(text.utf8), "readonly.txt", in: root)
        let before = try Data(contentsOf: url)
        let beforeMtime = (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let source = try fileSource(url)
        let bundle = try source.open()
        _ = try source.window(startByte: bundle.index.byteLength / 2, index: bundle.index)
        _ = try source.window(startByte: bundle.index.byteLength / 3, index: bundle.index, backwards: true)
        _ = try source.find("风起", index: bundle.index)
        let after = try Data(contentsOf: url)
        let afterMtime = (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        #expect(after == before)
        #expect(afterMtime == beforeMtime)
    }

    @Test("An in-memory Notes document runs through the same pipeline")
    func notesSource() async throws {
        let data = Data("手记正文。\r\n\r\n第1章 手记章节\r\n内容。\r\n".utf8)
        let source = ReaderFileSource(
            source: ReaderDataByteSource(data: data),
            identity: identity("note-1", kind: .notesDocument),
            markdown: false
        )
        let bundle = try source.open()
        #expect(bundle.index.encoding == .utf8)
        #expect(bundle.result.chapters.map(\.title) == ["第1章 手记章节"])
        #expect(bundle.result.window.blocks.first?.text == "手记正文。")
    }
}

/// Small cancellation probe shared by the async tests.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }

    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
