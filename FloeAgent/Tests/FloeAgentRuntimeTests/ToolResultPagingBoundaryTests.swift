// FloeAgentRuntimeTests — exact UTF-8 byte paging over retained tool results.
//
// Regression for the observed 40,652-byte capture: `offset=40352` with
// `length=300` was rejected as offsetOutOfRange while a later read at 40,552
// succeeded. The start byte fell inside a multi-byte character, so the old
// window produced an invalid tail and makePage reported the valid byte
// position as out of range. These tests pin scalar-boundary rounding, exact
// start/end/next cursors, non-advancing-page prevention, retention and
// ownership honesty. All text is synthetic (Chinese, emoji, accented Latin
// and ASCII); no user transcript content is stored here.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeAgentRuntime

@Suite("Captured result UTF-8 paging boundaries")
struct ToolResultPagingBoundaryTests {
    private let mixed =
        "ASCII start\n中文段落：日本語のテキスト。\nemoji 😀🚀🧪\naccent café naïve résumé\nend ASCII"

    private func makeStore() -> ToolResultCaptureStore {
        ToolResultCaptureStore(durableRoot: nil)
    }

    private func capture(
        _ store: ToolResultCaptureStore,
        task: UUID,
        run: UUID,
        callID: String,
        text: String,
        executionReportedTruncation: Bool = false
    ) async {
        await store.capture(
            conversationID: task,
            runID: run,
            callID: callID,
            toolName: "web.fetch",
            status: "ok",
            text: text,
            temporary: false,
            executionReportedTruncation: executionReportedTruncation
        )
    }

    private func isScalarBoundary(_ offset: Int, in bytes: [UInt8]) -> Bool {
        offset == 0 || offset == bytes.count || (bytes[offset] & 0xC0) != 0x80
    }

    @Test("small pages reconstruct mixed Chinese/emoji/accent/ASCII text exactly")
    func mixedTextReconstructsExactly() async throws {
        let store = makeStore()
        let task = UUID(), run = UUID()
        await capture(store, task: task, run: run, callID: "mixed", text: mixed)
        let total = mixed.utf8.count
        var offset = 0
        var rebuilt = ""
        var pages = 0
        while true {
            guard case .page(let page) = await store.page(
                conversationID: task, runID: run, callID: "mixed", offset: offset, maxBytes: 7
            ) else {
                Issue.record("missing page at offset \(offset)")
                return
            }
            pages += 1
            #expect(page.totalBytes == total)
            #expect(page.offset == offset, "a cursor produced by nextOffset is already a scalar boundary")
            #expect(page.endOffset == page.offset + page.text.utf8.count)
            #expect(page.endOffset > page.offset)
            // A whole character may cross the requested limit by at most
            // three bytes; it is never split or dropped.
            #expect(page.text.utf8.count <= 10)
            #expect(String(decoding: Array(page.text.utf8), as: UTF8.self) == page.text)
            rebuilt += page.text
            if let next = page.nextOffset {
                #expect(next == page.endOffset)
                #expect(next > offset)
                offset = next
            } else {
                #expect(page.endOffset == total)
                break
            }
            #expect(pages < total + 1)
        }
        #expect(rebuilt == mixed)
        let retained = await store.retainedText(
            conversationID: task,
            ref: ToolResultCaptureStore.reference(runID: run, callID: "mixed")
        )
        #expect(retained == mixed)
    }

    @Test("every byte position inside every synthetic scalar yields progress, never outOfRange")
    func everyBytePositionYieldsAWholeScalarPage() async throws {
        let store = makeStore()
        let task = UUID(), run = UUID()
        let text = "A中😀é🚀Z"
        await capture(store, task: task, run: run, callID: "bytes", text: text)
        let bytes = Array(text.utf8)
        for requested in 0..<bytes.count {
            guard case .page(let page) = await store.page(
                conversationID: task, runID: run, callID: "bytes", offset: requested, maxBytes: 1
            ) else {
                Issue.record("valid byte offset \(requested) was reported as out of range")
                return
            }
            #expect(isScalarBoundary(page.offset, in: bytes))
            #expect(page.offset <= requested)
            #expect(requested < page.endOffset)
            #expect(page.endOffset == page.offset + page.text.utf8.count)
            #expect(!page.text.isEmpty)
            #expect(page.nextOffset == (page.endOffset < bytes.count ? page.endOffset : nil))
            // Read from the effective range start and the requested byte is
            // part of the delivered character.
            let textBytes = Array(page.text.utf8)
            #expect(!textBytes.isEmpty)
            #expect(page.offset + textBytes.count == page.endOffset)
            // A page never begins with a continuation byte.
            #expect(isScalarBoundary(page.offset, in: bytes))
        }
    }

    @Test("the observed 40652-byte start-inside-character boundary now pages")
    func observedLongCaptureBoundaryPages() async {
        let store = makeStore()
        let task = UUID(), run = UUID()
        // Synthetic shape only: a 3-byte character begins at byte 40,350, so
        // the observed request offset 40,352 is its final continuation byte.
        // The reported total was 40,652 bytes; the later 40,552/100 read was
        // already accepted and must keep working.
        let text = String(repeating: "A", count: 40_350)
            + "中"
            + String(repeating: "B", count: 299)
        #expect(text.utf8.count == 40_652)
        await capture(store, task: task, run: run, callID: "long", text: text)

        guard case .page(let page) = await store.page(
            conversationID: task, runID: run, callID: "long", offset: 40_352, maxBytes: 300
        ) else {
            Issue.record("offset 40352 is a valid byte position and must not be out of range")
            return
        }
        #expect(page.offset == 40_350)
        #expect(page.endOffset == 40_650)
        #expect(page.nextOffset == 40_650)
        #expect(page.totalBytes == 40_652)
        #expect(page.text.utf8.count == 300)
        #expect(page.text.hasPrefix("中"))
        #expect(!page.text.contains("\u{FFFD}"))
        let tail = Array(page.text.utf8.dropFirst(3))
        #expect(String(decoding: tail, as: UTF8.self) == String(repeating: "B", count: 297))

        guard case .page(let second) = await store.page(
            conversationID: task, runID: run, callID: "long", offset: page.nextOffset!, maxBytes: 300
        ) else {
            Issue.record("the two remaining bytes must page")
            return
        }
        #expect(second.offset == 40_650)
        #expect(second.text == "BB")
        #expect(second.nextOffset == nil)

        // The transcript's successful read (40,552 + 100 = exactly 40,652)
        // remains accepted and reaches the end.
        guard case .page(let later) = await store.page(
            conversationID: task, runID: run, callID: "long", offset: 40_552, maxBytes: 100
        ) else {
            Issue.record("offset 40552 with length 100 must page")
            return
        }
        #expect(later.endOffset == 40_652)
        #expect(later.nextOffset == nil)
        #expect(later.text.utf8.count == 100)
    }

    @Test("an end boundary at totalBytes is accepted at any scalar position")
    func exactEndBoundaryIsNotOutOfRange() async {
        let store = makeStore()
        let task = UUID(), run = UUID()
        let text = "A中B"
        await capture(store, task: task, run: run, callID: "edge", text: text)
        // Offsets 2 and 3 are inside the three-byte 中; 2+3 and 3+2 both
        // reach totalBytes (5). The old code rejected 2 with length 3.
        for (requested, length) in [(2, 3), (3, 2)] {
            guard case .page(let page) = await store.page(
                conversationID: task, runID: run, callID: "edge", offset: requested, maxBytes: length
            ) else {
                Issue.record("offset \(requested) with maxBytes \(length) must page")
                return
            }
            #expect(page.offset == 1)
            #expect(page.text == "中")
            #expect(page.endOffset == 4)
            #expect(page.nextOffset == 4)
        }
        // Exactly totalBytes is still out of range; no byte exists there.
        if case .outOfRange(let total, _) = await store.page(
            conversationID: task, runID: run, callID: "edge", offset: text.utf8.count, maxBytes: 4
        ) {
            #expect(total == text.utf8.count)
        } else {
            Issue.record("offset == totalBytes must stay out of range")
        }
        // Empty captures still return the one empty page at zero.
        await capture(store, task: task, run: run, callID: "empty", text: "")
        if case .page(let empty) = await store.page(
            conversationID: task, runID: run, callID: "empty", offset: 0, maxBytes: 4
        ) {
            #expect(empty.text.isEmpty)
            #expect(empty.totalBytes == 0)
            #expect(empty.nextOffset == nil)
        } else {
            Issue.record("an empty capture must return an empty page")
        }
    }

    @Test("tool header reports the effective range and no unobservable compaction claim")
    func toolHeaderReportsOnlyObservedFacts() async throws {
        let store = makeStore()
        let task = UUID(), run = UUID()
        let text = "左😀右"
        await capture(store, task: task, run: run, callID: "header", text: text)
        let tool = ToolResultPagingTool(store: store)
        let context = ToolContext(runID: run, cancellation: CancellationToken(), conversationID: task)
        // Byte 1 starts inside 左 (3 bytes); length 1 still returns the whole
        // character and is reported as an adjusted, non-dropping page.
        let args = try JSONDecoder().decode(
            ToolResultPagingTool.Arguments.self,
            from: Data(#"{"callID":"header","offset":1,"length":1}"#.utf8)
        )
        let output = try await tool.execute(args, context: context)
        let summary = output.summary
        #expect(!summary.contains("offsetOutOfRange"))
        #expect(summary.contains("offset=0 "))
        #expect(summary.contains("returnedBytes=3"))
        #expect(summary.contains("endOffset=3"))
        #expect(summary.contains("nextOffset=3"))
        #expect(summary.contains("capture=complete"))
        #expect(summary.contains("offsetNote=requested offset 1 is inside a UTF-8 character"))
        #expect(summary.contains("windowNote=this page includes one complete UTF-8 character"))
        #expect(!summary.contains("contextNote"))
        #expect(!summary.contains("provider context compaction"))
        #expect(summary.contains("--- output ---\n左"))

        // An aligned page inside the same capture carries neither adjustment
        // note and still makes no claim about provider-internal compaction.
        let aligned = try JSONDecoder().decode(
            ToolResultPagingTool.Arguments.self,
            from: Data(#"{"callID":"header","offset":3,"length":4}"#.utf8)
        )
        let alignedOutput = try await tool.execute(aligned, context: context)
        #expect(!alignedOutput.summary.contains("offsetNote="))
        #expect(!alignedOutput.summary.contains("contextNote"))
        #expect(!alignedOutput.summary.contains("provider context compaction"))
        #expect(alignedOutput.summary.contains("--- output ---\n😀"))
    }

    @Test("search excerpts and match offsets stay on whole scalars")
    func searchExcerptsStayOnScalarBoundaries() async throws {
        let store = makeStore()
        let task = UUID(), run = UUID()
        await capture(store, task: task, run: run, callID: "search", text: mixed)
        let read = await store.search(conversationID: task, query: "🚀", limit: 5)
        guard case .search(let result) = read else {
            Issue.record("expected a search result")
            return
        }
        let hit = try #require(result.hits.first)
        let emojiRange = try #require(mixed.range(of: "🚀"))
        let expectedOffset = mixed.utf8.distance(
            from: mixed.utf8.startIndex,
            to: emojiRange.lowerBound
        )
        #expect(hit.matchOffset == expectedOffset)
        #expect(hit.excerpt.contains("🚀"))
        #expect(!hit.excerpt.contains("\u{FFFD}"))
        #expect(hit.totalBytes == mixed.utf8.count)
    }

    @Test("ownership, cancellation and duplicate-history bounds remain enforced")
    func ownershipCancellationAndHistoryBoundsRemain() async throws {
        let store = makeStore()
        let owner = UUID(), other = UUID(), run = UUID()
        await capture(store, task: owner, run: run, callID: "owned", text: "owner bytes")
        if case .missing = await store.page(
            conversationID: other, runID: run, callID: "owned", offset: 0, maxBytes: 64
        ) {
            // Expected: a sibling task cannot read the owner's capture.
        } else {
            Issue.record("another task must not read an owned capture")
        }
        let tool = ToolResultPagingTool(store: store)
        let token = CancellationToken()
        token.cancel()
        let context = ToolContext(runID: run, cancellation: token, conversationID: owner)
        let args = try JSONDecoder().decode(
            ToolResultPagingTool.Arguments.self,
            from: Data(#"{"callID":"owned","offset":0}"#.utf8)
        )
        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(args, context: context)
        }
        // Bounded history: the newest page remains addressable; an evicted
        // capture is missing rather than silently fabricated.
        let tight = ToolResultCaptureStore(
            durableRoot: nil,
            caps: .init(perResultBytes: 64, perTaskBytes: 10_000, perTaskResults: 1)
        )
        await capture(tight, task: owner, run: run, callID: "first", text: "first")
        await capture(tight, task: owner, run: run, callID: "second", text: "second")
        if case .missing(_, let reason) = await tight.page(
            conversationID: owner, runID: run, callID: "first", offset: 0, maxBytes: 64
        ) {
            #expect(reason.contains("evicted"))
        } else {
            Issue.record("the evicted first capture must be missing")
        }
        if case .page(let newest) = await tight.page(
            conversationID: owner, runID: run, callID: "second", offset: 0, maxBytes: 64
        ) {
            #expect(newest.text == "second")
        } else {
            Issue.record("the newest capture must remain readable")
        }
    }

    @Test("execution and retention truncation are reported as distinct capture facts")
    func truncationNotesAreDistinctAndTruthful() async throws {
        let store = makeStore()
        let task = UUID(), run = UUID()
        await capture(
            store, task: task, run: run, callID: "cut", text: "partial output",
            executionReportedTruncation: true
        )
        let tool = ToolResultPagingTool(store: store)
        let context = ToolContext(runID: run, cancellation: CancellationToken(), conversationID: task)
        let args = try JSONDecoder().decode(
            ToolResultPagingTool.Arguments.self,
            from: Data(#"{"callID":"cut","offset":0}"#.utf8)
        )
        let output = try await tool.execute(args, context: context)
        #expect(output.summary.contains("capture=executionOutputTruncated"))
        #expect(output.summary.contains("captureNote=the tool itself reported truncating this output"))
        #expect(!output.summary.contains("contextNote"))
        #expect(!output.summary.contains("provider context compaction"))

        let tight = ToolResultCaptureStore(
            durableRoot: nil,
            caps: .init(perResultBytes: 8, perTaskBytes: 10_000, perTaskResults: 10)
        )
        await capture(tight, task: task, run: run, callID: "retained", text: "0123456789")
        if case .page(let page) = await tight.page(
            conversationID: task, runID: run, callID: "retained", offset: 0, maxBytes: 64
        ) {
            #expect(page.capture.retentionTruncated)
            #expect(page.totalBytes == 8)
            #expect(page.text == "01234567")
            #expect(page.nextOffset == nil)
        } else {
            Issue.record("retained prefix must page")
        }
    }
}
