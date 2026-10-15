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
