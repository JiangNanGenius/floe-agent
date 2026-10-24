#if canImport(UIKit)
import XCTest
@testable import FloeApp

final class VoiceSentenceIntegrationTests: XCTestCase {
    func testLongUnfinishedVoiceSentenceNeverFlushesAtOld512Boundary() {
        var splitter = VoiceConversationSentenceSplitter()
        let text = String(repeating: "这是一段需要完整朗读的内容", count: 50)
        XCTAssertGreaterThan(text.count, 512)
        XCTAssertTrue(splitter.feed(cumulative: text, finalize: false).isEmpty)
        XCTAssertEqual(splitter.consumedCount, 0)
        XCTAssertEqual(splitter.feed(cumulative: text + "。", finalize: true), [text + "。"])
        XCTAssertEqual(splitter.consumedText, text + "。")
    }

    func testVoiceDoesNotFinishOnCommaSemicolonOrNewline() {
        var splitter = VoiceConversationSentenceSplitter()
        let text = "第一部分，第二部分；\n下一行仍属于同一句"
        XCTAssertTrue(splitter.feed(cumulative: text, finalize: false).isEmpty)
        XCTAssertEqual(splitter.feed(cumulative: text + "。 接下来。", finalize: true),
                       [text + "。", "接下来。"])
    }

    func testCumulativeVoiceFeedAndFinalTailAreConsumedExactlyOnce() {
        var splitter = VoiceConversationSentenceSplitter()
        XCTAssertEqual(splitter.feed(cumulative: "你好。 后面", finalize: false), ["你好。"])
        XCTAssertEqual(splitter.consumedText, "你好。")
        XCTAssertEqual(splitter.feed(cumulative: "你好。 后面", finalize: true), ["后面"])
        XCTAssertTrue(splitter.feed(cumulative: "你好。 后面", finalize: true).isEmpty)
    }

    func testVoiceSentenceKeepsClosingQuoteAcrossUpdates() {
        var splitter = VoiceConversationSentenceSplitter()
        XCTAssertTrue(splitter.feed(cumulative: "他说：“你好。", finalize: false).isEmpty)
        XCTAssertEqual(splitter.feed(cumulative: "他说：“你好。” 后面", finalize: false),
                       ["他说：“你好。”"])
        XCTAssertEqual(splitter.feed(cumulative: "他说：“你好。” 后面", finalize: true), ["后面"])
    }
}
#endif
