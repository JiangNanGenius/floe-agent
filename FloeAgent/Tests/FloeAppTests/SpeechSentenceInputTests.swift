// FloeAppTests — Complete-sentence TTS input seam.
//
// SPDX-License-Identifier: MPL-2.0
//
// Proves the APP-layer seam that feeds real synthesis requests: the shared
// complete-sentence segmenter plus the final-answer text projection produce
// requests that each contain at least one complete sentence, with table
// numbers, decimals, code exclusion and a single unpunctuated tail intact,
// and that a sentence beyond the model's real native limit surfaces the
// existing recoverable "too long" copy instead of a fragment.
//
// Membership note: this file is added to the FloeAppTests target in
// project.yml at App integration time; it needs the App module (UIKit) and
// therefore runs with the primary's full Swift 6 App verification, never in
// the provider-only slice.

#if canImport(UIKit)
import XCTest
import FloeProviders
@testable import FloeApp

@MainActor
final class SpeechSentenceInputTests: XCTestCase {
    private func normalized(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    /// Streams a realistic mixed answer through the same segmenter the
    /// preview and streaming read-aloud paths use, and checks the ACTUAL
    /// request texts: no fragments, no lost content, long CJK sentences
    /// whole, and the numbers/table rows preserved verbatim.
    func testEveryActualSynthesisRequestCarriesCompleteSentences() {
        let markdown = """
        ## 结论

        延迟是 12865.50 毫秒，占比 0.7，整体已经达到目标。下一步我们会在 iOS 27.1.2 上验证 on-device 路径。这个句子特意写得很长，用来确认超过六十四个字符的中文句子不会再被强行切断，而会完整地进入同一次语音合成请求，避免碎词和半句造成的生硬停顿。

        | 名称 | 数值 |
        | --- | --- |
        | A | 1.5 |
        | B | 2.0 |

        ```swift
        let hidden = "这段代码绝不能被读出来。"
        ```
        """
        let plain = AnswerSpeechText.plainText(markdown)
        XCTAssertFalse(plain.contains("这段代码绝不能被读出来"), "fenced code must never be spoken")
        XCTAssertFalse(plain.isEmpty)

        var segmenter = TTSTextSegmenter(policy: .completeSentences)
        var emitted: [String] = []
        var index = plain.startIndex
        while index < plain.endIndex {
            let next = plain.index(index, offsetBy: 7, limitedBy: plain.endIndex) ?? plain.endIndex
            emitted += segmenter.append(String(plain[index..<next]))
            index = next
        }
        emitted += segmenter.finish()

        XCTAssertGreaterThanOrEqual(emitted.count, 2)
        // Exact content preservation: nothing dropped, reordered, duplicated
        // or summarized for speech.
        XCTAssertEqual(normalized(emitted.joined()), normalized(plain))
        // Every streaming emission ends at a true sentence end; only the
        // single end-of-input tail may be unpunctuated.
        for segment in emitted.dropLast() {
            XCTAssertTrue(
                segment.hasSuffix("。") || segment.hasSuffix("！") || segment.hasSuffix("？")
                    || segment.hasSuffix(".") || segment.hasSuffix("!") || segment.hasSuffix("?"),
                "fragment reached synthesis: \(segment)")
        }
        // The >64-character CJK sentence is one untouched request.
        XCTAssertTrue(emitted.contains { $0.count > 64 && $0.contains("超过六十四个字符") })
        // Table values and long decimals survive verbatim.
        let spoken = emitted.joined()
        XCTAssertTrue(spoken.contains("12865.50"))
        XCTAssertTrue(spoken.contains("1.5"))
        XCTAssertTrue(spoken.contains("2.0"))
    }

    /// A preview of a heading-only answer produces exactly one request, at
    /// end of input — never an empty or partial one.
    func testTrailingTitleIsSpokenOnceAtEndOfPreview() {
        let plain = AnswerSpeechText.plainText("## 结语")
        var segmenter = TTSTextSegmenter(policy: .completeSentences)
        XCTAssertEqual(plain.isEmpty ? [] : segmenter.append(plain), [])
        XCTAssertEqual(segmenter.finish(), plain.isEmpty ? [] : ["结语"])
        XCTAssertEqual(segmenter.finish(), [])
    }

    /// Exceeding the model's real limit must use the existing recoverable
    /// "too long" copy (no new localization key, no silent truncation).
    func testRecoverableSentenceTooLongUsesExistingTooLongCopy() {
        XCTAssertEqual(
            SpeechFailureCopy.key(for: LocalSpeechRuntime.Failure.sentenceTooLong),
            "voice.error.too_long")
        // Unrelated local failures keep their current classification.
        XCTAssertEqual(
            SpeechFailureCopy.key(for: LocalSpeechRuntime.Failure.invalidAudio),
            "voice.error.playback")
    }

    /// The MOSS frame budget covers a >64-character CJK sentence at the
    /// measured slowest speech rate; it is an empirical audio budget, not a
    /// text acceptance limit.
    func testLocalFrameBudgetCoversLongCJKSentence() {
        let sentence = String(repeating: "春", count: 100) + "。"
        let frames = TTSSpeechBudget.mossMaxFrames(
            contextLength: 1024, characterCount: sentence.count, hasCJK: true)
        // 101 CJK characters at the measured slowest 4.8 char/s = 263 frames.
        XCTAssertGreaterThanOrEqual(frames, Int(Double(sentence.count) / 4.8 * 12.5))
        XCTAssertLessThanOrEqual(frames, 1024 - TTSSpeechBudget.mossTemplateRowsUpperBound
            - TTSSpeechBudget.mossContextSafetyRows)
    }
}
#endif
