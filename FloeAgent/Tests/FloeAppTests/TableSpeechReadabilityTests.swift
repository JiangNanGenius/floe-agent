// FloeAppTests — semantic table read-aloud projection fixtures.
#if canImport(UIKit)
import XCTest
@testable import FloeApp

final class TableSpeechReadabilityTests: XCTestCase {
    // MARK: - Acceptance fixture 1: Chinese table, empty cell, totals

    func testChineseTableAttachesHeadingsAndKeepsTotals() {
        let source = "| 项目 | 数量 | 金额（元） |\n| --- | ---: | ---: |\n| 苹果 | 2 | 3.50 |\n| 香蕉 | | 8 |\n| 合计 | 2 | 11.50 |"
        let spoken = AnswerSpeechTableText.expanding(source)
        XCTAssertEqual(spoken, "苹果: 数量 2, 金额（元） 3.50。\n香蕉: 金额（元） 8。\n合计: 数量 2, 金额（元） 11.50。")
    }

    func testEmptyCellNeverShiftsLaterValuesOrReadsAsZero() {
        let spoken = AnswerSpeechTableText.expanding(
            "| 项目 | 数量 | 金额（元） |\n| --- | ---: | ---: |\n| 香蕉 | | 8 |"
        )
        XCTAssertTrue(spoken.contains("金额（元） 8"))
        XCTAssertFalse(spoken.contains("数量"))
        XCTAssertFalse(spoken.contains(" 0"))
    }

    func testWhitespaceOutsideOuterPipesDoesNotCreateExtraColumn() {
        let source = "  | 项目 | 数量 |  \n | --- | ---: |\t\n | 苹果 | 2 |   "
        XCTAssertEqual(AnswerSpeechTableText.expanding(source), "苹果: 数量 2。")
    }

    // MARK: - Acceptance fixture 2: English headings, no outer pipes, alignment colons

    func testEnglishTableKeepsSignsDecimalsAndPercentages() {
        let source = "Name | Margin | Change\n:---|---:|:---:\nAlpha | 12.50% | -3.2\nBeta | 0% | +4.00"
        let spoken = AnswerSpeechTableText.expanding(source)
        XCTAssertEqual(spoken, "Alpha: Margin 12.50%, Change -3.2.\nBeta: Margin 0%, Change +4.00.")
    }

    // MARK: - Acceptance fixture 3: escaped and inline-code pipes are content

    func testEscapedAndCodeSpanPipesStayInsideCells() {
        let source = "| Key | Value |\n|---|---|\n| a\\|b | `x|y` |"
        let spoken = AnswerSpeechTableText.expanding(source)
        XCTAssertEqual(spoken, "a|b: Value `x|y`.")
        XCTAssertEqual(spoken.filter { $0 == "|" }.count, 2)
    }

    // MARK: - Acceptance fixture 4: fenced code never becomes a table

    func testFencedTableIsNotExpanded() {
        let source = "Before.\n\n```text\n| hidden | code |\n|---|---|\n| x | y |\n```\n\nAfter."
        let spoken = AnswerSpeechTableText.expanding(source)
        XCTAssertFalse(spoken.contains("hidden"))
        XCTAssertTrue(spoken.contains("Before."))
        XCTAssertTrue(spoken.contains("After."))
    }

    // MARK: - False-positive guards

    func testOrdinaryProseWithPipesIsUntouched() {
        let source = "Use Vim | Emacs daily.\nThe pipe | separates columns in regex."
        XCTAssertEqual(AnswerSpeechTableText.expanding(source), source)
    }

    func testHeadingOverHorizontalRuleIsNotATable() {
        let source = "Title\n---\nBody text."
        XCTAssertEqual(AnswerSpeechTableText.expanding(source), source)
    }

    func testTwoProseLinesWithPipesButNoDelimiterRowAreUntouched() {
        let source = "A | B\nC | D"
        XCTAssertEqual(AnswerSpeechTableText.expanding(source), source)
    }

    // MARK: - Conservative cell-count fallbacks

    func testMissingAndExtraCellsKeepPositionalPairing() {
        let source = "| A | B | C |\n|---|---|---|\n| x | 1 |\n| y | 2 | 3 | 4 |"
        let spoken = AnswerSpeechTableText.expanding(source)
        XCTAssertEqual(spoken, "x: B 1.\ny: B 2, C 3, 4.")
    }

    func testHeaderOnlyTableSpeaksColumnNamesOnce() {
        let source = "| 参数 | 默认值 |\n| --- | --- |"
        XCTAssertEqual(AnswerSpeechTableText.expanding(source), "参数, 默认值。")
    }

    func testSingleColumnPipeTableUsesRowSubjectOnly() {
        let source = "| 状态 |\n|:---|\n| 完成 |"
        XCTAssertEqual(AnswerSpeechTableText.expanding(source), "完成。")
    }

    func testEmptyBodyRowDoesNotSplitTheTable() {
        let source = "| 名 | 值 |\n|---|---|\n| a | 1 |\n|  |  |\n| b | 2 |"
        let spoken = AnswerSpeechTableText.expanding(source)
        XCTAssertTrue(spoken.contains("b: 值 2"))
        XCTAssertFalse(spoken.contains("|"))
    }

    // MARK: - Numeric fidelity and structure preservation

    func testNumericTextIsPreservedCharacterForCharacter() {
        let source = "| 编号 | 引用 |\n|---|---|\n| 007 | 1,024.50 |"
        let spoken = AnswerSpeechTableText.expanding(source)
        XCTAssertTrue(spoken.contains("007: 引用 1,024.50"))
    }

    func testMultipleTablesWithAdjacentProse() {
        let source = "First:\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nMiddle prose.\n\n| C | D |\n|:--|--:|\n| 3 | 4 |"
        let spoken = AnswerSpeechTableText.expanding(source)
        XCTAssertTrue(spoken.contains("First:"))
        XCTAssertTrue(spoken.contains("1: B 2."))
        XCTAssertTrue(spoken.contains("Middle prose."))
        XCTAssertTrue(spoken.contains("3: D 4."))
        XCTAssertFalse(spoken.contains("|"))
    }

    func testExpansionIsIdempotent() {
        let once = AnswerSpeechTableText.expanding("Name | Margin\n:---|---:\nAlpha | 12.50%")
        XCTAssertEqual(AnswerSpeechTableText.expanding(once), once)
    }

    // MARK: - Integration seam (requires the one-line AnswerSpeechTableText
    // call inside AnswerSpeechText.plainText, after fenced-code exclusion and
    // before inline cleanup). These fail on an unintegrated branch by design.

    func testSpokenAnswerExpandsSemanticTables() {
        let source = "结论：\n\n| 项目 | 数量 |\n| --- | ---: |\n| 苹果 | 2 |\n\n**完**。"
        let spoken = AnswerSpeechText.plainText(source)
        XCTAssertTrue(spoken.contains("苹果: 数量 2"))
        XCTAssertFalse(spoken.contains("|"))
        XCTAssertFalse(spoken.contains("---"))
        XCTAssertTrue(spoken.contains("结论："))
        XCTAssertTrue(spoken.contains("完"))
    }

    func testSpokenAnswerKeepsFencedTableSilentAndProseReadable() {
        let source = "Before.\n\n```text\n| hidden | code |\n|---|---|\n| x | y |\n```\n\nAfter."
        let spoken = AnswerSpeechText.plainText(source)
        XCTAssertFalse(spoken.contains("hidden"))
        XCTAssertTrue(spoken.contains("Before."))
        XCTAssertTrue(spoken.contains("After."))
    }
}
#endif
