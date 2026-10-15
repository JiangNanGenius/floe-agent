// FloeWorkspaceTests — Text reader manual encoding override (O2 lane).
//
// SPDX-License-Identifier: MPL-2.0
//
// Real files in a temporary directory; no App, no Simulator, no network.
// A manual encoding choice validates the WHOLE stream in exactly that
// encoding (no fallback candidate), refuses binary/invalid code units and
// contradictory encoding marks, and never writes to the source. Positions
// stay scoped to the encoding they were measured in.

import Foundation
import Testing
import FloeWorkspace

@Suite("FloeWorkspace.TextReader.EncodingOverride")
struct TextReaderEncodingOverrideTests {

    // MARK: - Fixtures

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-reader-encoding-tests-\(UUID().uuidString)", isDirectory: true)
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

    private func identity(
        _ name: String,
        kind: ReaderSourceKind = .workspaceFile,
        fingerprint: String = "fp"
    ) -> ReaderDocumentIdentity {
        ReaderDocumentIdentity(
            kind: kind,
            ownerID: "test",
            documentKey: name,
            displayName: name,
            format: (name as NSString).pathExtension.lowercased(),
            fingerprint: fingerprint
        )
    }

    private func fileSource(
        _ url: URL,
        markdown: Bool = false,
        limits: ReaderLimits = .default,
        fingerprint: String = "fp"
    ) throws -> ReaderFileSource {
        ReaderFileSource(
            source: try ReaderFileByteSource(url: url),
            identity: identity(url.lastPathComponent, fingerprint: fingerprint),
            markdown: markdown,
            limits: limits
        )
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

    /// BOM-less UTF-16LE whose NUL bytes are split evenly between both byte
    /// parities, so the automatic probe cannot pick an endianness: every
    /// other unit is `Ā` (00 01) and every other is `A` (41 00).
    private func ambiguousUTF16() -> (data: Data, text: String) {
        var text = ""
        for _ in 0..<5 { text += "ĀA" }
        return (utf16Data(text, littleEndian: true, bom: false), text)
    }

    /// Pure CJK text: valid UTF-16 in both endiannesses, no NUL bytes.
    private func cjkUTF16Lines() -> String {
        String(repeating: "你好世界万物生长\n", count: 40)
    }

    // MARK: - Manual choice as the recovery path

    @Test("BOM-less UTF-16 that auto cannot infer opens only with a manual choice")
    func ambiguousUTF16NeedsManualChoice() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let fixture = ambiguousUTF16()
        let url = try write(fixture.data, "ambiguous.txt", in: root)
        let source = try fileSource(url)
        #expect(throws: ReaderError.unrecognizedEncoding) {
            _ = try source.open()
        }
        let bundle = try source.open(preferredEncoding: .manual(.utf16LittleEndian))
        #expect(bundle.index.encoding == .utf16LittleEndian)
        #expect(bundle.result.encodingSelection == .manual(.utf16LittleEndian))
        #expect(bundle.result.window.blocks.first?.text == fixture.text)
        // A manual choice is reported as user-chosen, never as a heuristic.
        #expect(!bundle.result.notices.contains(.encodingRecovered))
        // The opposite endianness decodes to control characters: refused
        // instead of being shown as gibberish.
        #expect(throws: ReaderError.encodingInvalid(.utf16BigEndian)) {
            _ = try source.open(preferredEncoding: .manual(.utf16BigEndian))
        }
    }

    @Test("Explicit UTF-16 choices validate the whole stream, including a trailing half unit")
    func explicitUTF16ValidatesWholeStream() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let text = "Chapter 1\r\nManual choice\r\n"
        let le = try write(utf16Data(text, littleEndian: true, bom: false), "le.txt", in: root)
        let leBundle = try fileSource(le).open(preferredEncoding: .manual(.utf16LittleEndian))
        #expect(leBundle.index.encoding == .utf16LittleEndian)
        #expect(leBundle.result.window.blocks.first?.text == "Chapter 1")
        let be = try write(utf16Data(text, littleEndian: false, bom: false), "be.txt", in: root)
        let beBundle = try fileSource(be).open(preferredEncoding: .manual(.utf16BigEndian))
        #expect(beBundle.index.encoding == .utf16BigEndian)
        #expect(beBundle.result.window.blocks.first?.text == "Chapter 1")

        // Odd byte count: no UTF-16 interpretation is valid anywhere.
        let odd = try write(Data("Plain ASCII!\n".utf8), "odd.txt", in: root)
        #expect(throws: ReaderError.encodingInvalid(.utf16LittleEndian)) {
            _ = try fileSource(odd).open(preferredEncoding: .manual(.utf16LittleEndian))
        }
        // The same bytes are fine once the choice fits, and auto still works.
        let utf8Bundle = try fileSource(odd).open(preferredEncoding: ReaderEncodingSelection.manual(.utf8))
        #expect(utf8Bundle.result.window.blocks.first?.text == "Plain ASCII!")
        let autoBundle = try fileSource(odd).open()
        #expect(autoBundle.result.encodingSelection == .auto)
        #expect(autoBundle.index.encoding == .utf8)
    }

    @Test("Manual choices refuse binary and invalid code units without replacement characters")
    func manualRefusesBinaryAndInvalidUnits() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let binary = try write(
            Data([0x41, 0x00, 0x42, 0x00, 0x00, 0x01, 0x02, 0x03, 0x64, 0x00, 0x67, 0x00]),
            "blob.bin", in: root
        )
        #expect(throws: ReaderError.encodingInvalid(.utf8)) {
            _ = try fileSource(binary).open(preferredEncoding: .manual(.utf8))
        }

        // The sample is valid UTF-8; the failure is past the sample window,
        // so the whole stream is still validated.
        var late = Data(repeating: 0x61, count: 100_000)
        late.append(0xFF)
        let lateURL = try write(late, "late.txt", in: root)
        let smallChunks = ReaderLimits(chunkBytes: 16 * 1024)
        #expect(throws: ReaderError.encodingInvalid(.utf8)) {
            _ = try fileSource(lateURL, limits: smallChunks).open(preferredEncoding: .manual(.utf8))
        }
        #expect(throws: ReaderError.unrecognizedEncoding) {
            _ = try fileSource(lateURL, limits: smallChunks).open()
        }

        // GB18030 bytes that are not valid UTF-8: the manual UTF-8 choice
        // fails, while the matching manual and automatic choices succeed.
        if let codec = String.Encoding.floeGB18030,
           let gb = "中文𠀀测试".data(using: codec) {
            let gbURL = try write(gb, "gb.txt", in: root)
            #expect(throws: ReaderError.encodingInvalid(.utf8)) {
                _ = try fileSource(gbURL).open(preferredEncoding: .manual(.utf8))
            }
            let manual = try fileSource(gbURL).open(preferredEncoding: .manual(.gb18030))
            #expect(manual.index.encoding == .gb18030)
            #expect(manual.result.window.blocks.first?.text == "中文𠀀测试")
            let auto = try fileSource(gbURL).open()
            #expect(auto.index.encoding == .gb18030)
        }
    }

    // MARK: - Encoding marks (BOM)

    @Test("A manual choice that contradicts the file's encoding mark fails explicitly")
    func bomContradictionIsExplicit() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let leBOM = try write(utf16Data("Hi\r\n", littleEndian: true, bom: true), "le-bom.txt", in: root)
        let source = try fileSource(leBOM)
        #expect(throws: ReaderError.encodingConflict(.utf16BigEndian)) {
            _ = try source.open(preferredEncoding: .manual(.utf16BigEndian))
        }
        #expect(throws: ReaderError.encodingConflict(.utf8)) {
            _ = try source.open(preferredEncoding: .manual(.utf8))
        }
        if String.Encoding.floeGB18030 != nil {
            #expect(throws: ReaderError.encodingConflict(.gb18030)) {
                _ = try source.open(preferredEncoding: .manual(.gb18030))
            }
        }
        // The matching choice skips the mark and decodes the content.
        let matching = try source.open(preferredEncoding: .manual(.utf16LittleEndian))
        #expect(matching.index.bomLength == 2)
        #expect(matching.result.window.blocks.first?.text == "Hi")

        var utf8BOM = Data([0xEF, 0xBB, 0xBF])
        utf8BOM.append(contentsOf: Array("标题\r\n".utf8))
        let bomURL = try write(utf8BOM, "bom.txt", in: root)
        let bomSource = try fileSource(bomURL)
        #expect(throws: ReaderError.encodingConflict(.utf16LittleEndian)) {
            _ = try bomSource.open(preferredEncoding: .manual(.utf16LittleEndian))
        }
        let utf8Match = try bomSource.open(preferredEncoding: .manual(.utf8))
        #expect(utf8Match.index.bomLength == 3)
        #expect(utf8Match.result.window.blocks.first?.text == "标题")

        // UTF-32 marks have no supported match at all.
        let utf32 = try write(Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00]), "utf32.txt", in: root)
        #expect(throws: ReaderError.encodingConflict(.utf16LittleEndian)) {
            _ = try fileSource(utf32).open(preferredEncoding: .manual(.utf16LittleEndian))
        }
        #expect(throws: ReaderError.unrecognizedEncoding) {
            _ = try fileSource(utf32).open()
        }
    }

    // MARK: - Positions

    @Test("Positions are scoped by the resolved encoding and never cross-restored")
    func positionScopedByEncoding() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        // A UTF-16LE document with a BOM: auto resolves LE deterministically.
        let text = "第1章 位置\r\n" + (1...200).map { "第\($0)段内容。\r\n" }.joined()
        let url = try write(utf16Data(text, littleEndian: true, bom: true), "pos16.txt", in: root)
        let source = try fileSource(url)
        let first = try source.open()
        #expect(first.index.encoding == .utf16LittleEndian)
        let anchor = first.index.byteLength / 2 + 2
        let tagged = ReaderPosition(anchorByte: anchor, progress: 0.5, fingerprint: "fp", encoding: .utf16LittleEndian)
        let restored = try source.open(preferredEncoding: .manual(.utf16LittleEndian), restoring: tagged)
        #expect(restored.result.restoredPosition != nil)
        // An untagged (older) position is only used for an automatic open.
        let legacy = ReaderPosition(anchorByte: anchor, progress: 0.5, fingerprint: "fp")
        let autoRestored = try source.open(restoring: legacy)
        #expect(autoRestored.result.restoredPosition != nil)
        let manualLegacy = try source.open(preferredEncoding: .manual(.utf16LittleEndian), restoring: legacy)
        #expect(manualLegacy.result.restoredPosition == nil)
        #expect(manualLegacy.result.window.startByte == Int64(manualLegacy.index.bomLength))

        // The same bytes are valid UTF-16 in both endiannesses; an anchor
        // measured in LE must not be restored for a manual BE read.
        let cjk = try write(utf16Data(cjkUTF16Lines(), littleEndian: true, bom: false), "cjk16.txt", in: root)
        let cjkSource = try fileSource(cjk)
        let leOpen = try cjkSource.open(preferredEncoding: .manual(.utf16LittleEndian))
        let cjkAnchor = leOpen.index.byteLength / 2 + 2
        let cjkPosition = ReaderPosition(
            anchorByte: cjkAnchor, progress: 0.5, fingerprint: "fp", encoding: .utf16LittleEndian
        )
        let leRestored = try cjkSource.open(preferredEncoding: .manual(.utf16LittleEndian), restoring: cjkPosition)
        #expect(leRestored.result.restoredPosition != nil)
        #expect(leRestored.result.window.startByte <= cjkAnchor)
        let beOpen = try cjkSource.open(preferredEncoding: .manual(.utf16BigEndian), restoring: cjkPosition)
        #expect(beOpen.result.restoredPosition == nil)
        #expect(beOpen.result.window.startByte == 0)
    }

    @Test("A position written before encoding tagging still decodes with encoding == nil")
    func positionLegacyDecoding() throws {
        let position = ReaderPosition(anchorByte: 7, progress: 0.2, fingerprint: "fp", encoding: .gb18030)
        let data = try JSONEncoder().encode(position)
        #expect(try JSONDecoder().decode(ReaderPosition.self, from: data).encoding == .gb18030)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("position is not a JSON object"); return
        }
        object.removeValue(forKey: "encodingRaw")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(ReaderPosition.self, from: legacyData)
        #expect(legacy.encoding == nil)
        #expect(legacy.anchorByte == 7)
        #expect(legacy.fingerprint == "fp")
    }

    // MARK: - Availability and lifecycle

    @Test("Unavailable codecs are never advertised")
    func selectionHonesty() {
        let withoutGB = ReaderEncodingSelection.selectableEncodings(gb18030Available: false)
        #expect(withoutGB == [.utf8, .utf16LittleEndian, .utf16BigEndian])
        let withGB = ReaderEncodingSelection.selectableEncodings(gb18030Available: true)
        #expect(withGB.contains(.gb18030))
        #expect(ReaderTextCodec.gb18030CodecAvailable == (String.Encoding.floeGB18030 != nil))
        if !ReaderTextCodec.gb18030CodecAvailable {
            #expect(!ReaderEncodingSelection.selectableEncodings(
                gb18030Available: ReaderTextCodec.gb18030CodecAvailable).contains(.gb18030))
        }
        let manual = ReaderEncodingSelection.manual(.utf16BigEndian)
        #expect(manual.isManual)
        #expect(manual.manualEncoding == .utf16BigEndian)
        #expect(!ReaderEncodingSelection.auto.isManual)
        // A BOM only CONFLICTS with a non-matching manual choice: the
        // matching choice skips it, any other choice is refused explicitly.
        #expect(!ReaderTextCodec.manualChoiceConflictsWithBOM(.utf8, sample: Data([0xEF, 0xBB, 0xBF])),
                "a UTF-8 BOM matches the UTF-8 choice")
        #expect(ReaderTextCodec.manualChoiceConflictsWithBOM(.utf16LittleEndian,
                                                             sample: Data([0xEF, 0xBB, 0xBF])),
                "a UTF-8 BOM conflicts with the UTF-16LE choice")
        #expect(ReaderTextCodec.manualChoiceConflictsWithBOM(.utf8,
                                                             sample: Data([0xFF, 0xFE, 0x41, 0x00])),
                "a UTF-16LE BOM conflicts with the UTF-8 choice")
        #expect(!ReaderTextCodec.manualChoiceConflictsWithBOM(.utf8, sample: Data("plain".utf8)))
    }

    @Test("Cancelling the outgoing open aborts its scan and the switching open wins")
    func sessionEncodingSwitch() async throws {
        // Deterministic supersession through the REAL owner path: the first
        // open runs a gated scan, the test cancels that task (what the reader
        // view now does on a new choice), and the switching open then settles
        // the session. Two tiny concurrent opens cannot prove this: the actor
        // serializes and both could simply succeed.
        final class GatedSource: ReaderByteSource, @unchecked Sendable {
            let data: Data
            let gate: DispatchSemaphore
            private let lock = NSLock()
            private var started = false
            private var gateTimedOut = false
            /// Reads attempted while the test's post-cancellation window is
            /// open: a cancelled scan must perform NONE of them.
            private var postCancelReads = 0
            private var countingPostCancel = false

            init(data: Data, gate: DispatchSemaphore) {
                self.data = data
                self.gate = gate
            }

            var byteLength: Int64 { Int64(data.count) }
            var didStart: Bool { lock.lock(); defer { lock.unlock() }; return started }
            var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return gateTimedOut }
            var postCancelReadCount: Int { lock.lock(); defer { lock.unlock() }; return postCancelReads }

            func beginPostCancelWindow() {
                lock.lock(); countingPostCancel = true; lock.unlock()
            }

            func endPostCancelWindow() {
                lock.lock(); countingPostCancel = false; lock.unlock()
            }

            func read(offset: Int64, length: Int) throws -> Data {
                lock.lock()
                let isFirst = !started
                started = true
                if countingPostCancel { postCancelReads += 1 }
                lock.unlock()
                if isFirst {
                    // ONLY the first chunk parks (one-shot), with a bounded
                    // wait so a missing release can never hang the suite.
                    if gate.wait(timeout: .now() + 5) == .timedOut {
                        lock.lock(); gateTimedOut = true; lock.unlock()
                    }
                }
                let start = Int(min(max(offset, 0), Int64(data.count)))
                let end = min(start + length, data.count)
                return data.subdata(in: start..<end)
            }
        }

        // Deliberately LARGER than one streaming chunk (the default chunk is
        // far below 1 MiB), so the scan needs several chunk reads and the
        // cancellation lands between them.
        let text = String(repeating: "第一个文档 第一章 A 内容甲 abcdefghijklmnopqrstuvwxyz\n", count: 20_000)
        let gated = GatedSource(data: Data(text.utf8), gate: DispatchSemaphore(value: 0))
        let source = ReaderFileSource(source: gated, identity: ReaderDocumentIdentity(
            kind: .workspaceFile, ownerID: "switch", documentKey: "switch.txt",
            displayName: "switch.txt", format: "txt", fingerprint: "switch-fp"),
            markdown: false)
        let session = ReaderSession()

        let outgoing = Task { try await session.open(source: source, preferredEncoding: .auto) }
        // Wait until the scan is provably in flight (deterministic, no sleeps).
        var waited = 0
        while !gated.didStart && waited < 2_000 {
            try await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        #expect(gated.didStart, "the outgoing scan must have started")
        outgoing.cancel()
        // Open the deterministic probe window, then release the parked chunk:
        // a scan that honored cancellation performs NO further read here.
        gated.beginPostCancelWindow()
        gated.gate.signal()

        var outgoingCancelled = false
        do {
            _ = try await outgoing.value
        } catch let error as ReaderError {
            if case .cancelled = error { outgoingCancelled = true }
        } catch is CancellationError {
            outgoingCancelled = true
        }
        gated.endPostCancelWindow()
        #expect(outgoingCancelled, "the superseded open must abort as cancelled")
        #expect(!gated.didTimeOut, "the parked first read must have been released in time")
        #expect(gated.postCancelReadCount == 0,
                "a cancelled scan must stop at the chunk boundary, not read again")

        // The real second open (the winner) settles the session; the one-shot
        // gate is already consumed, so it scans freely.
        let winner = try await session.open(source: source, preferredEncoding: .manual(.utf8))
        #expect(winner.encodingSelection == .manual(.utf8))
        #expect(await session.encodingSelection == .manual(.utf8))
        #expect(await session.encoding == .utf8)
        let window = try await session.window(startByte: 0)
        #expect(window.blocks.contains { $0.text.contains("第一个文档") })
    }

    @Test("Manual reads and rereads never write to the source")
    func manualNeverWrites() async throws {
        let root = try makeRoot(); defer { cleanup(root) }
        let fixture = ambiguousUTF16()
        let url = try write(fixture.data, "readonly16.txt", in: root)
        let before = try Data(contentsOf: url)
        let beforeMtime = (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        let source = try fileSource(url)
        let bundle = try source.open(preferredEncoding: .manual(.utf16LittleEndian))
        _ = try source.window(startByte: bundle.index.byteLength / 2, index: bundle.index)
        _ = try source.find("A", index: bundle.index)
        let after = try Data(contentsOf: url)
        let afterMtime = (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        #expect(after == before)
        #expect(afterMtime == beforeMtime)
    }
}
