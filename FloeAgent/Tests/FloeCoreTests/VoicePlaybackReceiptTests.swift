import Foundation
import Testing
@testable import FloeCore

struct VoicePlaybackReceiptTests {
    @Test func interruptedReceiptPreservesIdentityAndUnicodePlaybackBoundary() throws {
        let runID = UUID()
        let receipt = VoicePlaybackReceipt(
            runID: runID, status: .interrupted, spokenText: "你好，👨‍👩‍👧‍👦。"
        )
        let decoded = try #require(VoicePlaybackReceipt.fromEventPayloadJSON(receipt.eventPayloadJSON()))
        #expect(decoded == receipt)
        #expect(decoded.runID == runID)
        #expect(decoded.spokenCharacterCount == 5)
    }

    @Test func longPlaybackKeepsBoundedTailAndTotalCount() throws {
        let spoken = String(repeating: "前", count: 3_000) + "最后一句。"
        let receipt = VoicePlaybackReceipt(runID: UUID(), status: .interrupted, spokenText: spoken)
        #expect(receipt.spokenTextTail.count == VoicePlaybackReceipt.maximumTailCharacters)
        #expect(receipt.spokenTextTail.hasSuffix("最后一句。"))
        #expect(receipt.spokenCharacterCount == spoken.count)
        #expect(VoicePlaybackReceipt.fromEventPayloadJSON(try receipt.eventPayloadJSON()) == receipt)
    }

    @Test func malformedAndFutureReceiptsDoNotBecomePlaybackEvidence() throws {
        let receipt = VoicePlaybackReceipt(runID: UUID(), status: .completed, spokenText: "好")
        let json = try receipt.eventPayloadJSON()
        #expect(VoicePlaybackReceipt.fromEventPayloadJSON("{invalid") == nil)
        #expect(VoicePlaybackReceipt.fromEventPayloadJSON("{}") == nil)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        for replacement in ["version": 99, "spokenCharacterCount": -1] {
            var wrapper = object
            var value = try #require(wrapper[VoicePlaybackReceipt.payloadKey] as? [String: Any])
            value[replacement.key] = replacement.value
            wrapper[VoicePlaybackReceipt.payloadKey] = value
            let malformed = String(decoding: try JSONSerialization.data(withJSONObject: wrapper), as: UTF8.self)
            #expect(VoicePlaybackReceipt.fromEventPayloadJSON(malformed) == nil)
        }
    }
}
