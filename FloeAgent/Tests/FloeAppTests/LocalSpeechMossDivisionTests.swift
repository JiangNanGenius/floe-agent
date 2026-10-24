// FloeAppTests — MOSS semantic block division for fused Markdown answers.
//
// Regression for the real user fixture (Local/Private/voice-search-followup-
// 20261025/feedback/read-aloud-list.md): a ~800-character Markdown answer of
// independent list items and paragraphs — almost none ending in terminal
// punctuation — was fused by the complete-sentence segmenter into ONE giant
// request, tripping the local pack's native context guard as
// `sentenceTooLong` ("文本过长"). The division below splits ONLY at semantic
// boundaries (blank-line paragraphs, then complete standalone list-item
// lines), never mid-sentence/mid-URL/mid-number, never at softwraps; order
// is preserved, no content is dropped or duplicated, and an over-budget
// single line passes through whole for the native guard to fail loudly.

#if canImport(UIKit)
import Foundation
import Testing
import FloeProviders
@testable import FloeApp

struct LocalSpeechMossDivisionTests {
    private func fitsUnder(_ limit: Int) -> (String) -> Bool {
        { $0.count <= limit }
    }

    @Test func fittingTextIsNeverDivided() {
        let text = "今天晴。明天多云。"
        let blocks = LocalSpeechRuntime.mossDividedBlocks(text, fits: fitsUnder(100))
        #expect(blocks == [text])
    }

    @Test func listFixtureDividesAtItemBoundariesWithCompleteOrderedCoverage() {
        // Shape mirror of the real fixture: heading + bullet rows + numbered
        // rows + a final paragraph. No terminal punctuation on the items.
        let heading = "**本轮实际调用**"
        let items = [
            "- `web.searchAI`（博查 AI 增强摘要）：成功，返回 5 条结果，provider 为 `bochaWeb`",
            "- `web.search`（通用检索，balanced 模式）：成功，返回 5 条结果，provider 同为 `bochaWeb`",
            "**需要坦白的局限**",
            "1. 返回的 `evidenceState` 是 `searchMetadataOnly`，即只有索引摘要",
            "2. 两路查询实际都走的是同一个 provider（bochaWeb），并没有做到多源交叉验证",
        ]
        let text = ([heading] + items).joined(separator: "\n")
        // A budget that fits single items but not the fused whole.
        let maxItem = items.map(\.count).max() ?? 0
        let blocks = LocalSpeechRuntime.mossDividedBlocks(
            text, fits: fitsUnder(maxItem + 8))
        #expect(blocks.count > 1)
        // Complete ordered coverage: every non-empty input line appears
        // exactly once, in order, across the blocks.
        let blockLines = blocks.flatMap { $0.split(separator: "\n").map(String.init) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let inputLines = text.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(blockLines == inputLines)
        // Each block is a standalone semantic unit (item or paragraph).
        for block in blocks {
            #expect(block.hasPrefix("- ") || block.hasPrefix("1. ") || block.hasPrefix("2. ")
                    || block.hasPrefix("**") || block.hasPrefix("`"))
        }
    }

    @Test func blankLineParagraphsDivideIndependentlyOfListMarkers() {
        let text = "第一段没有问题。\n\n第二段也没有问题。"
        let blocks = LocalSpeechRuntime.mossDividedBlocks(text, fits: fitsUnder(12))
        #expect(blocks.count == 2)
        #expect(blocks[0].contains("第一段"))
        #expect(blocks[1].contains("第二段"))
    }

    @Test func cleanedReadAloudInputRetainsUsableParagraphBoundaries() {
        // Exercise the ACTUAL upstream projection. It removes Markdown list
        // markers/backticks, so raw-Markdown-only divider checks are not
        // sufficient. Separate unpunctuated sections must still divide after
        // the ordinary player's complete-sentence segmenter fuses them.
        let item = String(repeating: "检查输出并保留完整内容", count: 8)
        let markdown = "开场说明。\n\n**已完成**\n- `first`：\(item)\n- `second`：\(item)\n\n**待核对**\n- `third`：\(item)\n- `fourth`：\(item)"
        let cleaned = AnswerSpeechText.plainText(markdown)
        #expect(!cleaned.contains("- "))
        #expect(!cleaned.contains("`"))
        var segmenter = TTSTextSegmenter(policy: .completeSentences)
        let units = segmenter.append(cleaned) + segmenter.finish()
        let fits: (String) -> Bool = {
            LocalSpeechRuntime.mossEstimatedFramesFit($0,
                hasCJK: TTSSpeechBudget.hasCJKCharacter($0), contextLength: 1_024)
        }
        #expect(units.contains { !fits($0) })
        let blocks = units.flatMap { LocalSpeechRuntime.mossDividedBlocks($0, fits: fits) }
        #expect(blocks.allSatisfy(fits))
        let blockLines = blocks.flatMap { $0.split(separator: "\n").map(String.init) }
        let inputLines = units.flatMap { $0.split(separator: "\n").map(String.init) }
        #expect(blockLines == inputLines)
    }

    @Test func softwrappedProseAndURLsAreNeverCutMidLine() {
        // One over-budget paragraph of plain prose with a URL and a decimal:
        // no list markers exist, so NO division happens — the whole line
        // passes through for the native guard to fail loudly.
        let text = "详见 https://example.com/a/b/c 的 3.14 倍增速与软换行续行内容"
        let blocks = LocalSpeechRuntime.mossDividedBlocks(text, fits: fitsUnder(10))
        #expect(blocks == [text])
    }

    @Test func overBudgetSingleListItemPassesThroughWhole() {
        // A single gigantic list item must NOT be chopped: semantic
        // completeness beats forced fitting.
        let text = "- " + String(repeating: "很", count: 500)
        let blocks = LocalSpeechRuntime.mossDividedBlocks(text, fits: fitsUnder(50))
        #expect(blocks == [text])
    }

    @Test func decimalAndAbbreviationHeavyEnglishStaysIntact() {
        let text = "Revenue grew 3.14x to $1,000.50 in Q3. See fig. 4 and pp. 12-14."
        let blocks = LocalSpeechRuntime.mossDividedBlocks(text, fits: fitsUnder(20))
        // Sentence boundaries exist; whole text still over budget per line —
        // no list markers, so it passes through whole, unsplit.
        #expect(blocks == [text])
    }
}
#endif
