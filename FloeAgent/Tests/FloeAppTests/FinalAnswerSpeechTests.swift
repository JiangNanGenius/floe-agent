#if canImport(UIKit)
import XCTest
import FloeModels
import FloePersistence
@testable import FloeApp

final class FinalAnswerSpeechTests: XCTestCase {
    func testToolRunReadsOnlyLastFinalAnswerRegardlessOfStorageOrder() {
        let run = UUID()
        let final = event(run, 8, .assistantText, "最终答案是 42。")
        let events = [final, event(run, 1, .assistantText, "我先搜索。"),
                      event(run, 3, .toolRequest, "search arguments"),
                      event(run, 4, .toolResult, "raw tool result"),
                      event(run, 6, .reasoning, "private reasoning")]
        let answer = FinalAnswerSpeech.answer(runID: run, events: events, messages: [])
        XCTAssertEqual(answer?.id, final.id)
        XCTAssertEqual(answer?.text, "最终答案是 42。")
    }

    func testMissingFinalAfterToolNeverReadsEarlierExplanation() {
        let run = UUID()
        let message = PersistedMessage(id: UUID(), conversationID: UUID(), role: "assistant", content: "我先检查。", createdAt: Date(), runID: run)
        let events = [event(run, 1, .assistantText, "我先检查。"), event(run, 2, .toolResult, "tool output")]
        XCTAssertNil(FinalAnswerSpeech.answer(runID: run, events: events, messages: [message]))
    }

    func testLegacyFallbackUsesOnlyOwnedTextParts() {
        let run = UUID(), id = UUID()
        let owned = PersistedMessage(id: id, conversationID: UUID(), role: "assistant", content: "legacy text and reasoning", createdAt: Date(), parts: [
            MessagePart(messageID: id, partIndex: 0, kind: .reasoning, text: "hidden reasoning"),
            MessagePart(messageID: id, partIndex: 1, kind: .text, text: "正文")
        ], runID: run)
        let unrelated = PersistedMessage(id: UUID(), conversationID: UUID(), role: "assistant", content: "other run", createdAt: Date(), runID: UUID())
        XCTAssertEqual(FinalAnswerSpeech.answer(runID: run, events: [], messages: [owned, unrelated])?.text, "正文")
    }

    func testMarkdownReadoutKeepsProseWithoutCodeOrImageURLs() {
        let source = "# 回答\n你好 **Floe**。看[文档](https://example.com)。\n```json\n{\"tool\":\"call\"}\n```\n![图](https://example.com/image.png)"
        let spoken = AnswerSpeechText.plainText(source)
        XCTAssertTrue(spoken.contains("你好 Floe"))
        XCTAssertTrue(spoken.contains("看文档"))
        XCTAssertFalse(spoken.contains("tool"))
        XCTAssertFalse(spoken.contains("https://"))
        XCTAssertFalse(spoken.contains("```"))
    }

    private func event(_ run: UUID, _ sequence: Int, _ kind: RunEventRecord.Kind, _ text: String) -> RunEventRecord {
        let json = String(data: try! JSONSerialization.data(withJSONObject: ["text": text]), encoding: .utf8)!
        return RunEventRecord(runID: run, sequence: sequence, kind: kind, payloadJSON: json)
    }
}
#endif
