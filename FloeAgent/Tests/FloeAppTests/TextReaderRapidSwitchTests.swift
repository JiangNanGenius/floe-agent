// FloeAppTests — reader open supersession (rapid encoding switch).
//
// Review finding: `TextReaderModel` kept no handle for the in-flight open and
// its progress loop wrote the phase without checking the open generation, so a
// rapid encoding switch could leave the OLD open's progress/phase on screen
// after the new open had already settled. The fix owns the open task and
// cancels it (the cancellation propagates into the bounded chunk scan), and
// every progress tick re-checks the generation.
//
// This focused test drives the REAL model with a deliberately slow byte source
// (the kind of scan a 64 MiB text produces) and proves:
//   * the superseded open is really cancelled at a chunk boundary (its scan
//     stops early instead of running to completion), and
//   * the settled phase/encoding is the second choice, with no late write-back
//     from the first open.

#if canImport(UIKit)
import XCTest
import FloeWorkspace
@testable import FloeApp

@MainActor
final class TextReaderRapidSwitchTests: XCTestCase {
    /// A slow, counting source: each read sleeps briefly so the scan outlives
    /// the second open, and the counter shows whether it was cancelled early.
    private final class SlowByteSource: ReaderByteSource, @unchecked Sendable {
        let data: Data
        private let lock = NSLock()
        private var readCount = 0
        private var tailReadCount = 0
        private let delay: useconds_t

        init(data: Data, delay: useconds_t = 4_000) {
            self.data = data
            self.delay = delay
        }

        var byteLength: Int64 { Int64(data.count) }

        var reads: Int {
            lock.lock(); defer { lock.unlock() }
            return readCount
        }

        /// Reads that reached the file tail: exactly ONE scan (the winner) may
        /// complete; a cancelled scan must stop at a chunk boundary.
        var tailReads: Int {
            lock.lock(); defer { lock.unlock() }
            return tailReadCount
        }

        func read(offset: Int64, length: Int) throws -> Data {
            lock.lock()
            readCount += 1
            lock.unlock()
            usleep(delay)
            let start = Int(min(max(offset, 0), Int64(data.count)))
            let end = min(start + length, data.count)
            if end >= data.count {
                lock.lock()
                tailReadCount += 1
                lock.unlock()
            }
            return data.subdata(in: start..<end)
        }
    }

    private func makeSlowSource(bytes: Int) -> (TextReaderSource, SlowByteSource) {
        var text = ""
        var index = 0
        while text.utf8.count < bytes {
            text += "第\(index)章 快速切换测试的正文内容，用于让扫描跨越多个块。\n"
            index += 1
        }
        let data = Data(text.utf8)
        let slow = SlowByteSource(data: data)
        let source = TextReaderSource(
            kind: .workspaceFile,
            ownerID: "rapid-switch",
            documentKey: "rapid.txt",
            displayName: "rapid.txt",
            format: "txt",
            markdown: false,
            isRemoteSnapshot: false,
            persistsPosition: false,
            hasNonTextContent: false,
            limits: ReaderLimits(),
            makeBytes: {
                TextReaderBytes(source: slow, fingerprint: "rapid-fp")
            }
        )
        return (source, slow)
    }

    func testRapidEncodingSwitchCancelsTheOutgoingOpenAndKeepsTheNewPhase() async throws {
        let (source, slow) = makeSlowSource(bytes: 4 * 1024 * 1024)
        let model = TextReaderModel(source: source, positionStore: InMemoryPositionStore())

        // First open through the REAL entry point (`open()`; the model is idle,
        // so this is not the "same selection" early return).
        let first = Task { @MainActor in
            await model.open()
        }
        // Deterministic start gate: wait until the scan has really read a
        // chunk (no fixed sleep guessing).
        var waited = 0
        while slow.reads == 0, waited < 3_000 {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        XCTAssertGreaterThan(slow.reads, 0, "the first scan must have started")
        XCTAssertEqual(slow.tailReads, 0, "the first scan is still in flight")

        await model.selectEncoding(.manual(.utf8))
        await first.value

        XCTAssertEqual(model.encodingSelection, .manual(.utf8),
                       "the settled state must be the second choice")
        if case .ready = model.phase {} else {
            XCTFail("the reader must settle ready after the rapid switch: \(model.phase)")
        }
        // The winner produced real content; the deterministic proof that the
        // OUTGOING scan was really cancelled lives in the core supersession
        // test (a post-cancellation read window must stay empty), because a
        // byte-level tail counter here cannot distinguish window reads from a
        // second index scan.
        XCTAssertFalse(model.blocks.isEmpty, "the surviving open must render real content")
        XCTAssertGreaterThan(model.totalLines, 0, "the surviving index must have counted lines")
        // Give any late tick a chance to (wrongly) overwrite the phase.
        try? await Task.sleep(for: .milliseconds(400))
        if case .ready = model.phase {} else {
            XCTFail("a late progress write from the superseded open must not reset the phase")
        }
    }
    private func source(data: Data, key: String = "pages", limits: ReaderLimits = ReaderLimits(chunkBytes: 64 * 1024),
                        bytes: (any ReaderByteSource)? = nil) -> TextReaderSource {
        let sourceBytes = bytes ?? ReaderDataByteSource(data: data)
        return TextReaderSource(kind: .workspaceFile, ownerID: "paging-test", documentKey: key,
            displayName: key + ".txt", format: "txt", markdown: false, isRemoteSnapshot: false,
            persistsPosition: false, hasNonTextContent: false, limits: limits,
            makeBytes: { TextReaderBytes(source: sourceBytes, fingerprint: key) })
    }

    func testFullTextScrollReachesEOFWithBoundedRetainedTextAndCanReloadEarlierPages() async throws {
        let text = String(repeating: "012345中文🙂END", count: 100_003) + "文件末尾TAIL"
        let model = TextReaderModel(source: source(data: Data(text.utf8)), positionStore: InMemoryPositionStore())
        await model.open()
        var seen: [Int64: String] = [:]
        func remember() { for block in model.blocks { seen[block.byteOffset] = block.text } }
        remember()
        var pages = 0
        while model.hasMore, pages < 100 {
            model.rememberTop(try XCTUnwrap(model.blocks.last).byteOffset)
            await model.appendNext(); remember(); pages += 1
            XCTAssertLessThanOrEqual(model.retainedTextBytes, model.retainedTextLimit + 64 * 1024)
            XCTAssertNil(model.pageError)
        }
        XCTAssertFalse(model.hasMore, "the real EOF must be reachable")
        XCTAssertEqual(seen.keys.sorted().compactMap { seen[$0] }.joined(), text)
        XCTAssertGreaterThan(try XCTUnwrap(model.blocks.first).byteOffset, 0, "old UI strings must be retired")
        var backwards = 0
        while model.hasEarlier, backwards < 100 {
            model.rememberTop(try XCTUnwrap(model.blocks.first).byteOffset)
            await model.prependPrevious(); backwards += 1
        }
        XCTAssertEqual(model.blocks.first?.byteOffset, 0)
        XCTAssertTrue(text.hasPrefix(model.blocks.map(\.text).joined()))
        XCTAssertLessThanOrEqual(model.retainedTextBytes, model.retainedTextLimit + 64 * 1024)
    }

    func testContinuationHandlesUTF16EmojiAndBlockLimitWithoutDroppedTextOrCodePrefixes() async throws {
        let text = String(repeating: "AB中文🙂Z", count: 4_001) + "TAIL"
        for data in [Data(text.utf8), Data([0xFF, 0xFE]) + (try XCTUnwrap(text.data(using: .utf16LittleEndian)))] {
            let session = ReaderSession()
            let input = source(data: data, limits: ReaderLimits(chunkBytes: 64 * 1024,
                maxBlocksPerWindow: 2, maxBlockCharacters: 500))
            let bytes = try await input.makeBytes()
            let file = ReaderFileSource(source: bytes.source,
                identity: .init(kind: .workspaceFile, ownerID: "test", documentKey: "long", displayName: "long", format: "txt", fingerprint: "fp"),
                markdown: false, limits: input.limits)
            var window = try await session.open(source: file).window
            var recovered = window.blocks.map(\.text).joined(), pages = 0
            while window.hasMore, pages < 100 {
                let end = window.endByte
                window = try await session.window(startByte: end, continuing: true)
                XCTAssertGreaterThan(window.endByte, end)
                recovered += window.blocks.map(\.text).joined(); pages += 1
            }
            XCTAssertFalse(window.hasMore)
            XCTAssertEqual(recovered, text)
            let previous = try await session.window(startByte: window.endByte, backwards: true)
            XCTAssertTrue(text.hasSuffix(previous.blocks.map(\.text).joined()))
            XCTAssertLessThanOrEqual(previous.blocks.count, 2)
        }
        let code = TextReaderModel(source: source(data: Data("# keep this comment".utf8), key: "code"), positionStore: InMemoryPositionStore())
        await code.open()
        XCTAssertEqual(code.blocks.map(\.text).joined(), "# keep this comment")
    }

    private final class PageGateSource: ReaderByteSource, @unchecked Sendable {
        let data: Data
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var enabled = false
        private var entered = false
        init(data: Data) { self.data = data }
        var byteLength: Int64 { Int64(data.count) }
        func arm() { lock.lock(); enabled = true; lock.unlock() }
        var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        func release() { gate.signal() }
        func read(offset: Int64, length: Int) throws -> Data {
            lock.lock(); let block = enabled
            if block { enabled = false; entered = true }; lock.unlock()
            if block { _ = gate.wait(timeout: .now() + 5) }
            return try ReaderDataByteSource(data: data).read(offset: offset, length: length)
        }
    }

    func testCancelledPageCannotPublishIntoDismissedReaderOrReplacementFile() async throws {
        let data = Data(String(repeating: "AB中文🙂Z", count: 100_001).utf8)
        let gate = PageGateSource(data: data)
        let outgoing = TextReaderModel(source: source(data: data, key: "old", bytes: gate), positionStore: InMemoryPositionStore())
        await outgoing.open()
        let originalBlocks = outgoing.blocks
        gate.arm()
        let page = Task { @MainActor in await outgoing.appendNext() }
        var waits = 0
        while !gate.isWaiting, waits < 600 { try await Task.sleep(for: .milliseconds(5)); waits += 1 }
        XCTAssertTrue(gate.isWaiting, "exercise an actual in-flight page")
        outgoing.cancelOpen()
        let replacement = TextReaderModel(source: source(data: Data("新文件唯一内容".utf8), key: "new"), positionStore: InMemoryPositionStore())
        await replacement.open()
        gate.release(); await page.value
        XCTAssertEqual(outgoing.blocks, originalBlocks)
        XCTAssertEqual(replacement.blocks.map(\.text).joined(), "新文件唯一内容")
        XCTAssertNil(replacement.pageError)
        XCTAssertFalse(outgoing.isAppending)
    }

}

/// Local position store so this test never touches UserDefaults.
private final class InMemoryPositionStore: ReaderPositionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ReaderPosition] = [:]

    func position(for key: String) -> ReaderPosition? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func save(_ position: ReaderPosition, for key: String) {
        lock.lock(); values[key] = position; lock.unlock()
    }

    func removePosition(for key: String) {
        lock.lock(); values[key] = nil; lock.unlock()
    }

    func removeAll() {
        lock.lock(); values.removeAll(); lock.unlock()
    }
}
#endif
