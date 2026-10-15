// SPDX-License-Identifier: MPL-2.0
//
// Targeted checks for the bounded workbook cover plan and the settled-source
// policy behind the Notes Office thumbnails (Excel especially).
//
// They assert, deterministically and without a simulator Quick Look request:
//  * the summary chooses the first worksheet that actually shows content
//    instead of the first referenced sheet, so an empty/formatting-only cover
//    sheet cannot hide the data sheet;
//  * the rendered window is anchored at the populated region and keeps blank
//    references inside it, while cells outside the window are dropped;
//  * a workbook whose whole used extent (or chosen sheet) cannot be
//    represented by the system whole-extent page render keeps the bounded,
//    labeled native summary as its settled cover and never starts the system
//    request — the unreadable "tiny cells" render;
//  * a workbook whose first worksheet fits the stable window keeps the
//    original Quick Look-first behavior;
//  * a workbook with no visible cell never publishes a contentless summary;
//  * the stable window bounds still match the renderer geometry contract the
//    component acceptance encodes.
//
// They do not exercise the system Office renderer, a simulator or a real
// device; renderer and screenshot acceptance stay with the integration owner.
import XCTest
import UIKit
import FloeNotes
import FloeDocuments
// The same checks run in both hosts: the NativeNotes qualification project
// compiles this file against its own app module, while the existing App test
// bundle compiles it against FloeApp (the planner lives in the App target), so
// no second full qualification build is needed for the plan semantics. The
// planner symbols are identical in both modules.
#if canImport(FloeNotesNativeQualification)
@testable import FloeNotesNativeQualification
#else
@testable import FloeApp
#endif

@MainActor
final class NotesWorkbookCoverPlanTests: XCTestCase {
    private let coverSize = CGSize(width: 320, height: 420)
    private let maximumSourceBytes = 128 * 1024 * 1024

    private func fields(_ sheet: String, _ cells: [(String, String)]) -> [WorkbookCoverField] {
        cells.map { WorkbookCoverField(section: sheet, label: $0.0, text: $0.1) }
    }

    // MARK: - Selection semantics (pure, no rendering)

    func testPlanChoosesTheFirstWorksheetWithVisibleContent() throws {
        let plan = try XCTUnwrap(WorkbookCoverPlanner.plan(fields:
            fields("Sheet 1", [("A1", ""), ("B2", "")])
            + fields("Sheet 2", [("A1", "季度"), ("B1", "收入"), ("A2", "Q1"), ("B2", "120")])))
        XCTAssertEqual(plan.sheet, "Sheet 2",
                       "an empty formatting-only sheet must not hide the data sheet")
        XCTAssertFalse(plan.isFirstWorksheet)
        XCTAssertTrue(plan.prefersBoundedSummaryOverSystemRender,
                      "the system renderer targets Sheet 1, not the rendered sheet")
        XCTAssertEqual(plan.columns, 2)
        XCTAssertEqual(plan.rows, 2)
        XCTAssertEqual(plan.cells.map(\.text), ["季度", "收入", "Q1", "120"])
    }

    func testPlanAnchorsTheWindowAtThePopulatedRegion() throws {
        let plan = try XCTUnwrap(WorkbookCoverPlanner.plan(fields: fields("Sheet 1", [
            ("C10", "标题"), ("D10", "值"), ("C11", "A"), ("D11", "1")
        ])))
        XCTAssertEqual(plan.anchorColumn, 2, "the window starts at the first populated column")
        XCTAssertEqual(plan.anchorRow, 9, "the window starts at the first populated row")
        XCTAssertEqual(plan.columns, 2)
        XCTAssertEqual(plan.rows, 2)
        XCTAssertEqual(plan.cells.first, .init(column: 0, row: 0, text: "标题"))
        XCTAssertEqual(plan.cells.last, .init(column: 1, row: 1, text: "1"))
        XCTAssertFalse(plan.usedExtentExceedsWindow)
    }

    func testPlanKeepsBlankReferencesInsideTheWindow() throws {
        let plan = try XCTUnwrap(WorkbookCoverPlanner.plan(fields: fields("Sheet 1", [
            ("A1", "名称"), ("B1", ""), ("A2", "甲"), ("B2", "120")
        ])))
        XCTAssertEqual(plan.columns, 2)
        XCTAssertEqual(plan.rows, 2)
        XCTAssertEqual(plan.cells.count, 4,
                       "a referenced blank cell keeps its grid line inside the window")
        XCTAssertEqual(plan.cells.map(\.text), ["名称", "", "甲", "120"])
    }

    func testPlanFlagsDistantEmptyCellsAsWholeExtent() throws {
        let plan = try XCTUnwrap(WorkbookCoverPlanner.plan(fields: fields("Sheet 1", [
            ("Z1000", ""), ("AA2000", ""), ("XFD1048576", ""),
            ("A1", "季度"), ("B1", "收入"), ("A2", "Q1"), ("B2", "120")
        ])))
        XCTAssertEqual(plan.anchorColumn, 0)
        XCTAssertEqual(plan.anchorRow, 0)
        XCTAssertEqual(plan.columns, 2, "stray empty references must not inflate the window")
        XCTAssertEqual(plan.rows, 2)
        XCTAssertEqual(plan.cells.count, 4)
        XCTAssertTrue(plan.usedExtentExceedsWindow,
                      "the worksheet declares references far outside the bounded window")
        XCTAssertTrue(plan.prefersBoundedSummaryOverSystemRender)
    }

    func testPlanCapsTheWindowAtTheStableBounds() throws {
        let cells = (1...40).flatMap { row in
            (1...12).map { column in ("\(columnName(column))\(row)", "R\(row)C\(column)") }
        }
        let plan = try XCTUnwrap(WorkbookCoverPlanner.plan(fields: fields("Sheet 1", cells)))
        XCTAssertEqual(plan.columns, 5)
        XCTAssertEqual(plan.rows, 10)
        XCTAssertEqual(plan.cells.count, 50)
        XCTAssertEqual(plan.cells.first, .init(column: 0, row: 0, text: "R1C1"))
        XCTAssertEqual(plan.cells.last, .init(column: 4, row: 9, text: "R10C5"))
        XCTAssertTrue(plan.usedExtentExceedsWindow)
        XCTAssertTrue(plan.prefersBoundedSummaryOverSystemRender,
                      "a 12x40 table cannot fit one readable page; the bounded window is the cover")
    }

    func testPlanReturnsNilWhenNoCellHasVisibleText() throws {
        XCTAssertNil(WorkbookCoverPlanner.plan(fields: []))
        XCTAssertNil(WorkbookCoverPlanner.plan(fields: fields("Sheet 1", [
            ("A1", ""), ("B2", "   "), ("C3", "\n")
        ])), "an all-blank workbook must not publish a contentless grid")
    }

    func testPlanParsesMultiLetterColumns() throws {
        let plan = try XCTUnwrap(WorkbookCoverPlanner.plan(fields: fields("Sheet 1", [("AA10", "x")])))
        XCTAssertEqual(plan.anchorColumn, 26)
        XCTAssertEqual(plan.anchorRow, 9)
        XCTAssertEqual(plan.columns, 1)
        XCTAssertEqual(plan.rows, 1)
        XCTAssertEqual(plan.cells, [.init(column: 0, row: 0, text: "x")])
        XCTAssertNil(WorkbookCoverPlanner.cellPosition("12"), "a row-only label is not a cell")
        XCTAssertNil(WorkbookCoverPlanner.cellPosition(""))
        XCTAssertEqual(WorkbookCoverPlanner.cellPosition("AB3")?.column, 27)
        XCTAssertEqual(WorkbookCoverPlanner.cellPosition("AB3")?.row, 2)
    }

    func testSmallFirstSheetKeepsTheSystemRenderPath() throws {
        let plan = try XCTUnwrap(WorkbookCoverPlanner.plan(fields: fields("Sheet 1", [
            ("A1", "季度 Quarter"), ("B1", "收入 Revenue"), ("C1", "成本 Cost"),
            ("A2", "Q1"), ("B2", "120"), ("C2", "80"),
            ("A3", "Q2"), ("B3", "150"), ("C3", "96"),
            ("A4", "Q3"), ("B4", "168"), ("C4", "101")
        ])))
        XCTAssertTrue(plan.isFirstWorksheet)
        XCTAssertFalse(plan.usedExtentExceedsWindow)
        XCTAssertFalse(plan.prefersBoundedSummaryOverSystemRender,
                       "a workbook that fits the window keeps the system content upgrade")
    }

    /// The plan-driven renderer keeps the geometry the component acceptance
    /// encodes (`NotesCoverAcceptanceSupport.assertGridGeometry`): the 3x4
    /// fixture still draws 3 columns, 4 rows, 24 pt row height starting at
    /// y = 34, so no existing cover geometry assertion changes.
    func testWindowGeometryMatchesTheRendererContract() throws {
        let plan = try XCTUnwrap(WorkbookCoverPlanner.plan(fields: fields("Sheet 1", [
            ("A1", "季度"), ("B1", "收入"), ("C1", "成本"),
            ("A2", "Q1"), ("B2", "120"), ("C2", "80"),
            ("A3", "Q2"), ("B3", "150"), ("C3", "96"),
            ("A4", "Q3"), ("B4", "168"), ("C4", "101")
        ])))
        let boundsWidth: CGFloat = 300, boundsHeight: CGFloat = 376, boundsY: CGFloat = 34
        let cellHeight = min(boundsHeight / CGFloat(plan.rows), 24)
        XCTAssertEqual(plan.columns, 3)
        XCTAssertEqual(plan.rows, 4)
        XCTAssertEqual(cellHeight, 24)
        XCTAssertEqual(boundsY + CGFloat(plan.rows) * cellHeight, 130,
                       "the known grid bottom from the component acceptance")
        XCTAssertEqual(boundsWidth / CGFloat(plan.columns), 100, accuracy: 0.001)
    }

    // MARK: - Settled-source policy through the production service

    func testWideWorkbookKeepsTheBoundedSummaryWithoutStartingQuickLook() async throws {
        let root = makeScratchDirectory("wide-policy")
        defer { try? FileManager.default.removeItem(at: root) }
        let header = (1...9).map { "列\($0)" }
        let body = (1...24).map { row in (1...9).map { "R\(row)C\($0)" } }
        let (store, document, _) = try await makeWorkbook(
            root: root, name: "wide.xlsx", sheets: [.init(name: "宽表", rows: [header] + body)])

        var calls = 0
        var paints: [NotesDocumentCoverOutcome] = []
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes,
            request: { _, _, _ in
                calls += 1
                return NotesOfficeThumbnailGenerator.AttemptOutcome(
                    image: self.grayImage(), diagnosis: "unexpected system content",
                    timedOut: false, elapsed: .zero)
            },
            onFirstPaint: { paints.append($0) })

        XCTAssertEqual(calls, 0,
                       "a workbook that cannot fit the bounded window must not spend the shared host slot")
        XCTAssertEqual(outcome.source, .officeContentSummary)
        let image = try XCTUnwrap(outcome.image)
        XCTAssertGreaterThan(nonBlankPixelCount(in: image, below: 40), 16,
                             "the settled cover must paint the workbook's own cells")
        XCTAssertEqual(paints.count, 1, "the settled summary is also the first paint")
        let diagnostics = try XCTUnwrap(outcome.diagnostics)
        XCTAssertEqual(diagnostics.fallbackStage, .workbookWholeSheetFit)
        XCTAssertEqual(diagnostics.quickLookAttempts, 0,
                       "no system attempt may be recorded when the policy skips it")
        XCTAssertFalse(diagnostics.quickLookTimedOut)
    }

    func testWorkbookWithAnEmptyFirstSheetSummarizesTheDataSheetWithoutQuickLook() async throws {
        let root = makeScratchDirectory("empty-first-sheet")
        defer { try? FileManager.default.removeItem(at: root) }
        let table: [[String]] = [
            ["季度", "收入"], ["Q1", "120"], ["Q2", "150"], ["Q3", "168"]
        ]
        let (store, document, _) = try await makeWorkbook(root: root, name: "cover.xlsx", sheets: [
            .init(name: "封面", rows: []),
            .init(name: "数据", rows: table)
        ])

        var calls = 0
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes,
            request: { _, _, _ in
                calls += 1
                return NotesOfficeThumbnailGenerator.AttemptOutcome(
                    image: self.grayImage(), diagnosis: "unexpected system content",
                    timedOut: false, elapsed: .zero)
            })

        XCTAssertEqual(calls, 0,
                       "the system renderer targets the empty first sheet; the bounded summary must win")
        XCTAssertEqual(outcome.source, .officeContentSummary)
        let image = try XCTUnwrap(outcome.image)
        XCTAssertGreaterThan(nonBlankPixelCount(in: image, below: 40), 16,
                             "the summary must show the data sheet, not an empty grid")
        let diagnostics = try XCTUnwrap(outcome.diagnostics)
        XCTAssertEqual(diagnostics.fallbackStage, .workbookEarlierSheet)
    }

    func testSmallWorkbookStillSettlesOnTheSystemContent() async throws {
        let root = makeScratchDirectory("small-policy")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, _) = try await makeWorkbook(root: root, name: "small.xlsx", sheets: [
            .init(name: "Quarterly", rows: [
                ["季度", "收入"], ["Q1", "120"], ["Q2", "150"]
            ])
        ])

        let systemImage = grayImage()
        var calls = 0
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes,
            request: { _, _, _ in
                calls += 1
                return NotesOfficeThumbnailGenerator.AttemptOutcome(
                    image: systemImage, diagnosis: "content", timedOut: false, elapsed: .zero)
            })

        XCTAssertEqual(calls, 1, "a workbook inside the stable window keeps the bounded one-request path")
        XCTAssertEqual(outcome.source, .quickLookThumbnail)
        XCTAssertTrue(outcome.image === systemImage)
        XCTAssertEqual(outcome.diagnostics?.fallbackStage, .quickLook)
    }

    /// An all-blank workbook now settles on the explicit empty-workbook
    /// placeholder instead of a blank system page: with authoritative tab
    /// metadata the service can prove there is no visible cell content, so it
    /// neither draws a header-only grid nor spends the shared Quick Look slot
    /// on a render that could only be blank.
    func testWorkbookWithoutVisibleCellsShowsTheExplicitEmptyPlaceholder() async throws {
        let root = makeScratchDirectory("blank-workbook")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, source) = try await makeWorkbook(root: root, name: "blank.xlsx", sheets: [
            .init(name: "Sheet1", rows: [["", "", ""], ["", "", ""]])
        ])
        let resourceID = try XCTUnwrap(document.officeResourceID)
        let resource = try await store.resourceURL(resourceID)
        XCTAssertTrue(resource.pathExtension.isEmpty,
                      "precondition: the Notes resource is the extensionless CAS path")
        let snapshot = try OfficeDocumentService.inspect(url: source)
        XCTAssertFalse(snapshot.fields.isEmpty, "precondition: the blank cells are still referenced")
        XCTAssertEqual(NotesDocumentCoverService.workbookSummaryDecision(for: snapshot), .emptyVisibleWorkbook,
                       "the workbook is fully understood and has no visible cell content")
        XCTAssertNil(NotesDocumentCoverService.renderSummary(snapshot: snapshot, kind: .workbook, size: coverSize),
                     "a header-only grid must never be published as document content")

        var calls = 0
        var paints: [NotesDocumentCoverOutcome] = []
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes,
            request: { _, _, _ in
                calls += 1
                return NotesOfficeThumbnailGenerator.AttemptOutcome(
                    image: nil, diagnosis: "injected system failure", timedOut: false,
                    elapsed: .zero, errorDomain: "QLThumbnailErrorDomain", errorCode: 102)
            },
            onFirstPaint: { paints.append($0) })
        XCTAssertEqual(calls, 0,
                       "a proven-empty workbook must not spend the shared host slot on a blank page")
        XCTAssertTrue(paints.isEmpty, "an empty workbook has no content first paint")
        XCTAssertNil(outcome.image, "a workbook with no visible cell must not publish fabricated pixels")
        XCTAssertEqual(outcome.source, .unsupported)
        XCTAssertEqual(outcome.diagnostics?.fallbackStage, .workbookEmpty)
        // The copy is localized by the host (the App test bundle runs under
        // the simulator locale), so the assertion accepts the exact readable
        // placeholder in either supported language and nothing else.
        XCTAssertTrue(
            ["This workbook has no visible cell content", "此工作簿没有可见的单元格内容"]
                .contains(outcome.diagnosis ?? ""),
            "the placeholder must be the localized empty-workbook copy: \(outcome.diagnosis ?? "nil")"
        )
    }

    // MARK: - Metadata-driven worksheet selection (pure, no rendering)

    private func sheetInfo(
        _ name: String, _ section: String, visible: Bool = true,
        hiddenRows: Set<Int> = [], hiddenColumnSpans: [ClosedRange<Int>] = [],
        truncated: Bool = false
    ) -> WorkbookCoverSheet {
        WorkbookCoverSheet(name: name, section: section, isVisible: visible,
                           hiddenRows: hiddenRows, hiddenColumnSpans: hiddenColumnSpans,
                           hiddenLayoutTruncated: truncated)
    }

    private func decidedPlan(
        _ fields: [WorkbookCoverField], _ sheets: [WorkbookCoverSheet], fieldsComplete: Bool = true,
        file: StaticString = #filePath, line: UInt = #line
    ) -> WorkbookCoverPlan? {
        let decision = WorkbookCoverPlanner.decide(fields: fields, sheets: sheets,
                                                   fieldsComplete: fieldsComplete)
        guard case .plan(let plan) = decision else {
            XCTFail("expected a bounded plan, got \(decision)", file: file, line: line)
            return nil
        }
        return plan
    }

    private func metadataDecision(
        _ fields: [WorkbookCoverField], _ sheets: [WorkbookCoverSheet], fieldsComplete: Bool = true
    ) -> WorkbookCoverPlanDecision {
        WorkbookCoverPlanner.decide(fields: fields, sheets: sheets, fieldsComplete: fieldsComplete)
    }

    func testMetadataSelectionUsesTheFirstVisibleNonEmptyTab() throws {
        let plan = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("A1", "内部编号"), ("B1", "机密 200")])
                + fields("Sheet 2", [("A1", "季度"), ("B1", "收入"), ("A2", "Q1"), ("B2", "120")]),
            [sheetInfo("内部", "Sheet 1", visible: false), sheetInfo("数据", "Sheet 2")]))
        XCTAssertEqual(plan.sheet, "Sheet 2", "a hidden first tab must never be summarized")
        XCTAssertFalse(plan.isFirstWorksheet)
        XCTAssertTrue(plan.prefersBoundedSummaryOverSystemRender)
        XCTAssertEqual(plan.cells.map(\.text), ["季度", "收入", "Q1", "120"])
        XCTAssertFalse(plan.cells.contains { $0.text.contains("机密") },
                       "hidden helper data must not leak into the summary")
    }

    func testVeryHiddenHelperSheetIsNeverASummaryCandidate() throws {
        let plan = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("A1", ""), ("B2", " ")])
                + fields("Sheet 2", [("A1", "助手机密"), ("B2", "999")])
                + fields("Sheet 3", [("A1", "季度"), ("A2", "Q1")]),
            [sheetInfo("封面", "Sheet 1"),
             sheetInfo("助手", "Sheet 2", visible: false, truncated: false),
             sheetInfo("数据", "Sheet 3")]))
        XCTAssertEqual(plan.sheet, "Sheet 3",
                       "a very-hidden helper sheet is not a content candidate")
        XCTAssertEqual(plan.cells.map(\.text), ["季度", "Q1"])
    }

    func testVisibleBlankFirstSheetThenLaterDataUsesTabOrder() throws {
        let plan = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("A1", ""), ("B2", "  ")])
                + fields("Sheet 2", [("A1", "季度"), ("A2", "Q1")]),
            [sheetInfo("封面", "Sheet 1"), sheetInfo("数据", "Sheet 2")]))
        XCTAssertEqual(plan.sheet, "Sheet 2")
        XCTAssertFalse(plan.isFirstWorksheet)
        XCTAssertTrue(plan.prefersBoundedSummaryOverSystemRender)
    }

    func testActualTabOrderBeatsWorksheetPartNumbers() throws {
        let firstIsData = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("A1", "")]) + fields("Sheet 2", [("A1", "数据"), ("A2", "1")]),
            [sheetInfo("数据", "Sheet 2"), sheetInfo("未用", "Sheet 1")]))
        XCTAssertEqual(firstIsData.sheet, "Sheet 2",
                       "the workbook tab order, not the part number, selects the sheet")
        XCTAssertTrue(firstIsData.isFirstWorksheet)
        XCTAssertFalse(firstIsData.prefersBoundedSummaryOverSystemRender,
                       "the chosen sheet is the first tab and fits the window")

        let firstIsCover = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("A1", "数据"), ("A2", "1")]) + fields("Sheet 2", [("A1", "")]),
            [sheetInfo("封面", "Sheet 2"), sheetInfo("数据", "Sheet 1")]))
        XCTAssertEqual(firstIsCover.sheet, "Sheet 1")
        XCTAssertFalse(firstIsCover.isFirstWorksheet, "the chosen sheet is the second tab")
        XCTAssertTrue(firstIsCover.prefersBoundedSummaryOverSystemRender)
    }

    func testEmptyVisibleSheetsWithHiddenHelperDataIsAnEmptyWorkbook() {
        XCTAssertEqual(metadataDecision(
            fields("Sheet 1", [("A1", ""), ("B2", "   ")])
                + fields("Sheet 2", [("A1", "机密 helper"), ("B2", "内部 200")]),
            [sheetInfo("封面", "Sheet 1"), sheetInfo("助手", "Sheet 2", visible: false)]),
            .emptyVisibleWorkbook)
    }

    func testAllHiddenSheetsMakeAnEmptyVisibleWorkbook() {
        XCTAssertEqual(metadataDecision(
            fields("Sheet 1", [("A1", "数据")]),
            [sheetInfo("内部", "Sheet 1", visible: false),
             sheetInfo("助手", "Sheet 2", visible: false)]),
            .emptyVisibleWorkbook)
    }

    func testEmptySheetListIsAnEmptyVisibleWorkbook() {
        XCTAssertEqual(metadataDecision([], []), .emptyVisibleWorkbook)
    }

    func testHiddenRowsAreNeverDrawnInTheSummary() throws {
        let plan = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("A1", "公开"), ("A2", "机密行"), ("A3", "公开2")]),
            [sheetInfo("数据", "Sheet 1", hiddenRows: [2])]))
        XCTAssertEqual(plan.cells.map(\.text), ["公开", "公开2"])
        XCTAssertFalse(plan.cells.contains { $0.row == 1 },
                       "the hidden row must not be drawn, not even as an empty line")
        XCTAssertEqual(plan.rows, 3, "the visible rows keep their absolute positions")
    }

    func testHiddenColumnsAreNeverDrawnInTheSummary() throws {
        let plan = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("A1", "公开"), ("B1", "数据"), ("C1", "机密列"), ("D1", "尾")]),
            [sheetInfo("数据", "Sheet 1", hiddenColumnSpans: [3...3])]))
        XCTAssertEqual(plan.cells.map(\.text), ["公开", "数据", "尾"])
        XCTAssertFalse(plan.cells.contains { $0.column == 2 },
                       "the hidden column must not be drawn, not even as an empty line")
        XCTAssertEqual(plan.columns, 4)
    }

    /// Primary product decision: when the chosen sheet declares hidden rows
    /// or columns, the system whole-sheet page (which does not honor Floe's
    /// visibility filtering) could show the hidden content, so the filtered
    /// bounded summary stays the settled cover even for a first-tab sheet
    /// that would otherwise fit the window and upgrade to Quick Look.
    func testKnownHiddenRowsKeepTheFilteredSummaryAsTheSettledCover() throws {
        let plan = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("A1", "公开"), ("A2", "机密行"), ("A3", "公开2")]),
            [sheetInfo("数据", "Sheet 1", hiddenRows: [2])]))
        XCTAssertTrue(plan.isFirstWorksheet)
        XCTAssertFalse(plan.usedExtentExceedsWindow, "the visible extent fits the window")
        XCTAssertTrue(plan.hasKnownHiddenContent)
        XCTAssertTrue(plan.prefersBoundedSummaryOverSystemRender,
                      "a system render could expose the hidden row")
    }

    func testKnownHiddenColumnsKeepTheFilteredSummaryAsTheSettledCover() throws {
        let plan = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("A1", "公开"), ("B1", "数据"), ("C1", "机密列")]),
            [sheetInfo("数据", "Sheet 1", hiddenColumnSpans: [3...3])]))
        XCTAssertFalse(plan.usedExtentExceedsWindow, "the visible extent fits the window")
        XCTAssertTrue(plan.hasKnownHiddenContent)
        XCTAssertTrue(plan.prefersBoundedSummaryOverSystemRender,
                      "a system render could expose the hidden column")
    }

    func testASheetWithoutHiddenContentStillUpgradesToTheSystemRender() throws {
        let plan = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("A1", "公开"), ("B1", "数据"), ("A2", "1"), ("B2", "2")]),
            [sheetInfo("数据", "Sheet 1")]))
        XCTAssertTrue(plan.isFirstWorksheet)
        XCTAssertFalse(plan.hasKnownHiddenContent)
        XCTAssertFalse(plan.prefersBoundedSummaryOverSystemRender,
                       "the unchanged path: a fitting first sheet with no hidden content keeps Quick Look first")
    }

    func testASheetWhoseOnlyContentIsHiddenFallsThroughToTheNextVisibleSheet() throws {
        let plan = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("A1", "机密行")]) + fields("Sheet 2", [("A1", "公开"), ("A2", "1")]),
            [sheetInfo("数据", "Sheet 1", hiddenRows: [1]), sheetInfo("汇总", "Sheet 2")]))
        XCTAssertEqual(plan.sheet, "Sheet 2", "a fully hidden sheet exposes no visible content")
        XCTAssertFalse(plan.cells.contains { $0.text.contains("机密") })
    }

    func testHiddenLayoutTruncationDefersTheWholeWorkbookOnlyWhenASheetHasContent() throws {
        XCTAssertEqual(metadataDecision(
            fields("Sheet 1", [("A1", "公开")]),
            [sheetInfo("数据", "Sheet 1", hiddenRows: [2], truncated: true)]),
            .hiddenFilteringUnavailable)

        let plan = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("A1", "")]) + fields("Sheet 2", [("A1", "公开")]),
            [sheetInfo("空", "Sheet 1", truncated: true), sheetInfo("数据", "Sheet 2")]))
        XCTAssertEqual(plan.sheet, "Sheet 2",
                       "a truncated hidden layout on a sheet without text cannot leak anything")
    }

    func testIncompleteFieldListDefersToNativePreview() {
        XCTAssertEqual(metadataDecision(
            fields("Sheet 1", [("A1", "公开")]), [sheetInfo("数据", "Sheet 1")], fieldsComplete: false),
            .fieldListIncomplete)
    }

    func testWorkbookSnapshotsWithoutPreviewMetadataRequireTheNativePreview() {
        let snapshot = OfficeDocumentSnapshot(
            kind: .workbook,
            fields: [OfficeEditableField(id: "xl/worksheets/sheet1.xml|c|A1",
                                         section: "Sheet 1", label: "A1", text: "季度")],
            packageEntries: 3, packageBytes: 42)
        XCTAssertNil(snapshot.workbookPreview)
        XCTAssertEqual(NotesDocumentCoverService.workbookSummaryDecision(for: snapshot), .metadataRequired,
                       "without metadata the summary must not guess a sheet")
    }

    func testMetadataPathKeepsTheOffsetWindowAndA1Geometry() throws {
        let offset = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("C10", "标题"), ("D10", "值"), ("C11", "A"), ("D11", "1")]),
            [sheetInfo("数据", "Sheet 1")]))
        XCTAssertEqual(offset.anchorColumn, 2)
        XCTAssertEqual(offset.anchorRow, 9)
        XCTAssertEqual(offset.columns, 2)
        XCTAssertEqual(offset.rows, 2)
        XCTAssertFalse(offset.prefersBoundedSummaryOverSystemRender)

        let a1 = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", [("A1", "季度"), ("B1", "收入"), ("C1", "成本"),
                               ("A2", "Q1"), ("B2", "120"), ("C2", "80"),
                               ("A3", "Q2"), ("B3", "150"), ("C3", "96"),
                               ("A4", "Q3"), ("B4", "168"), ("C4", "101")]),
            [sheetInfo("数据", "Sheet 1")]))
        XCTAssertEqual(a1.columns, 3)
        XCTAssertEqual(a1.rows, 4)
    }

    func testMetadataWideAndTallWorkbooksStillPreferTheBoundedSummary() throws {
        let wide = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", (1...8).map { ("A\($0)", "R\($0)") } + [("H1", "尾")]),
            [sheetInfo("数据", "Sheet 1")]))
        XCTAssertTrue(wide.usedExtentExceedsWindow)
        XCTAssertTrue(wide.prefersBoundedSummaryOverSystemRender)

        let tall = try XCTUnwrap(decidedPlan(
            fields("Sheet 1", (1...14).map { ("A\($0)", "R\($0)") }),
            [sheetInfo("数据", "Sheet 1")]))
        XCTAssertTrue(tall.usedExtentExceedsWindow)
        XCTAssertTrue(tall.prefersBoundedSummaryOverSystemRender)
    }

    // MARK: - Codable / cross-format compatibility

    func testSnapshotWithoutPreviewMetadataDecodesUnchanged() throws {
        let json = """
        {"kind":"xlsx","fields":[{"id":"xl/worksheets/sheet1.xml|c|A1","section":"Sheet 1","label":"A1","text":"季度"},
        {"id":"xl/worksheets/sheet1.xml|c|B1","section":"Sheet 1","label":"B1","text":"120"}],
        "packageEntries":4,"packageBytes":512,"sha256":"abc"}
        """
        let snapshot = try JSONDecoder().decode(OfficeDocumentSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.workbookPreview, "an old fixture without preview metadata stays decodable")
        XCTAssertEqual(snapshot.fields.map(\.id),
                       ["xl/worksheets/sheet1.xml|c|A1", "xl/worksheets/sheet1.xml|c|B1"])
        XCTAssertEqual(snapshot.fields.map(\.section), ["Sheet 1", "Sheet 1"])
    }

    func testSnapshotWithPreviewMetadataRoundTripsThroughCodable() throws {
        let root = makeScratchDirectory("metadata-roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("roundtrip.xlsx")
        try OfficeDocumentBuilder.createWorkbook(at: url, sheets: [
            .init(name: "数据", rows: [["季度", "收入"], ["Q1", "120"]]),
            .init(name: "内部", rows: [["机密", "200"]], visibility: .hidden)
        ])
        let snapshot = try OfficeDocumentService.inspect(url: url)
        let preview = try XCTUnwrap(snapshot.workbookPreview)
        XCTAssertEqual(preview.sheets.map(\.visibility), [.visible, .hidden])
        let decoded = try JSONDecoder().decode(OfficeDocumentSnapshot.self,
                                               from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.workbookPreview?.sheets.map(\.name), ["数据", "内部"])
    }

    func testWordAndPresentationSnapshotsKeepTheirFieldsAndNoWorkbookPreview() throws {
        let root = makeScratchDirectory("non-workbook")
        defer { try? FileManager.default.removeItem(at: root) }
        let word = root.appendingPathComponent("word.docx")
        try OfficeDocumentBuilder.createWord(at: word, title: "标题", paragraphs: ["第一段", "Second"])
        let wordSnapshot = try OfficeDocumentService.inspect(url: word)
        XCTAssertNil(wordSnapshot.workbookPreview)
        XCTAssertEqual(wordSnapshot.fields.first?.id, "word/document.xml|p|0")
        XCTAssertEqual(wordSnapshot.fields.first?.section, "Document")

        let deck = root.appendingPathComponent("deck.pptx")
        try OfficeDocumentBuilder.createPresentation(at: deck, title: "路线图", slides: [
            .init(title: "路线图", bullets: ["里程碑"])
        ])
        let deckSnapshot = try OfficeDocumentService.inspect(url: deck)
        XCTAssertNil(deckSnapshot.workbookPreview)
        XCTAssertEqual(deckSnapshot.fields.first?.section, "Slide 1")
    }

    // MARK: - Real reader metadata and settled service behavior

    func testRealWorkbookMetadataReportsTabOrderNamesVisibilityAndStableSections() throws {
        let root = makeScratchDirectory("real-metadata")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tabs.xlsx")
        try OfficeDocumentBuilder.createWorkbook(at: url, sheets: [
            .init(name: "数据", rows: [["季度", "收入"], ["Q1", "120"]]),
            .init(name: "内部", rows: [["机密", "200"], ["H-01", "300"]], visibility: .hidden),
            .init(name: "助手", rows: [["隐藏助手", "9"]], visibility: .veryHidden)
        ])
        let snapshot = try OfficeDocumentService.inspect(url: url)
        let preview = try XCTUnwrap(snapshot.workbookPreview)
        XCTAssertFalse(preview.fieldsTruncated)
        XCTAssertEqual(preview.sheets.map(\.name), ["数据", "内部", "助手"])
        XCTAssertEqual(preview.sheets.map(\.visibility), [.visible, .hidden, .veryHidden])
        XCTAssertEqual(preview.sheets.map(\.section), ["Sheet 1", "Sheet 2", "Sheet 3"])
        XCTAssertEqual(preview.sheets.map(\.target),
                       ["xl/worksheets/sheet1.xml", "xl/worksheets/sheet2.xml", "xl/worksheets/sheet3.xml"])
        XCTAssertEqual(preview.sheets.map(\.isVisible), [true, false, false])
        XCTAssertTrue(preview.sheets.allSatisfy { $0.hiddenRows.isEmpty && $0.hiddenColumnSpans.isEmpty })
        // Field identifiers and sections are exactly the pre-patch reader's;
        // hidden sheets stay addressable for the editor and for search.
        XCTAssertEqual(snapshot.fields.first?.id, "xl/worksheets/sheet1.xml|c|A1")
        XCTAssertEqual(snapshot.fields.first?.section, "Sheet 1")
        XCTAssertTrue(snapshot.fields.contains {
            $0.id == "xl/worksheets/sheet2.xml|c|A1" && $0.section == "Sheet 2"
        })
    }

    func testRealHiddenFirstSheetSummarizesTheVisibleSheetWithoutQuickLook() async throws {
        let root = makeScratchDirectory("hidden-first")
        defer { try? FileManager.default.removeItem(at: root) }
        let table: [[String]] = [["季度", "收入"], ["Q1", "120"], ["Q2", "150"], ["Q3", "168"]]
        let (store, document, source) = try await makeWorkbook(root: root, name: "hidden-first.xlsx", sheets: [
            .init(name: "内部", rows: [["内部编号", "仅内部"], ["H-01", "机密 200"]], visibility: .hidden),
            .init(name: "数据", rows: table)
        ])
        let snapshot = try OfficeDocumentService.inspect(url: source)
        let decision = NotesDocumentCoverService.workbookSummaryDecision(for: snapshot)
        guard case .plan(let plan) = decision else {
            XCTFail("expected a bounded plan, got \(decision)")
            return
        }
        XCTAssertEqual(plan.sheet, "Sheet 2")
        XCTAssertFalse(plan.cells.contains { $0.text.contains("机密") })

        var calls = 0
        var paints: [NotesDocumentCoverOutcome] = []
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes,
            request: { _, _, _ in
                calls += 1
                return NotesOfficeThumbnailGenerator.AttemptOutcome(
                    image: self.grayImage(), diagnosis: "unexpected system content",
                    timedOut: false, elapsed: .zero)
            },
            onFirstPaint: { paints.append($0) })
        XCTAssertEqual(calls, 0, "the hidden first tab must never reach the system renderer")
        XCTAssertEqual(outcome.source, .officeContentSummary)
        XCTAssertEqual(outcome.diagnostics?.fallbackStage, .workbookEarlierSheet)
        XCTAssertEqual(paints.count, 1)
        let image = try XCTUnwrap(outcome.image)
        XCTAssertTrue(image === paints.first?.image)
        XCTAssertGreaterThan(nonBlankPixelCount(in: image, below: 40), 16,
                             "the settled cover must paint the visible sheet's own cells")
    }

    func testRealVeryHiddenHelperAfterAVisibleSheetIsNeverSummarized() async throws {
        let root = makeScratchDirectory("veryhidden-helper")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, source) = try await makeWorkbook(root: root, name: "helper.xlsx", sheets: [
            .init(name: "数据", rows: [["季度", "收入"], ["Q1", "120"]]),
            .init(name: "助手", rows: [["机密 helper", "200"]], visibility: .veryHidden)
        ])
        let snapshot = try OfficeDocumentService.inspect(url: source)
        XCTAssertEqual(snapshot.workbookPreview?.sheets.last?.visibility, .veryHidden)
        let summary = try XCTUnwrap(NotesDocumentCoverService.renderSummary(
            snapshot: snapshot, kind: .workbook, size: coverSize))
        let plan = try XCTUnwrap(summary.workbookPlan)
        XCTAssertEqual(plan.sheet, "Sheet 1")
        XCTAssertFalse(plan.cells.contains { $0.text.contains("机密") })

        // The chosen sheet is the workbook's first tab and fits, so the
        // original Quick Look-first upgrade stays in place.
        var calls = 0
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes,
            request: { _, _, _ in
                calls += 1
                return NotesOfficeThumbnailGenerator.AttemptOutcome(
                    image: self.grayImage(), diagnosis: "content", timedOut: false, elapsed: .zero)
            })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outcome.source, .quickLookThumbnail)
    }

    func testRealHiddenRowsAndColumnsAreFilteredFromTheBoundedSummary() async throws {
        let root = makeScratchDirectory("hidden-layout")
        defer { try? FileManager.default.removeItem(at: root) }
        let (_, _, source) = try await makeWorkbook(root: root, name: "hidden-layout.xlsx", sheets: [
            .init(name: "可见数据", rows: [
                ["项目", "数量", "备注", "隐藏列"],
                ["公开行", "12", "-", "机密列"],
                ["机密行", "999", "密钥", "机密格"]
            ], hiddenRows: [3], hiddenColumns: [4])
        ])
        let snapshot = try OfficeDocumentService.inspect(url: source)
        let sheet = try XCTUnwrap(snapshot.workbookPreview?.sheets.first)
        XCTAssertEqual(sheet.hiddenRows, [3])
        XCTAssertEqual(sheet.hiddenColumnSpans, [.init(first: 4, last: 4)])
        XCTAssertFalse(sheet.hiddenRowsTruncated)
        XCTAssertFalse(sheet.hiddenColumnsTruncated)
        let decision = NotesDocumentCoverService.workbookSummaryDecision(for: snapshot)
        guard case .plan(let plan) = decision else {
            XCTFail("expected a bounded plan, got \(decision)")
            return
        }
        XCTAssertEqual(plan.cells.map(\.text), ["项目", "数量", "备注", "公开行", "12", "-"],
                       "hidden row and hidden column cells must never be drawn")
        XCTAssertEqual(plan.columns, 3)
        XCTAssertEqual(plan.rows, 2)
        let image = try XCTUnwrap(NotesDocumentCoverService.contentSummary(
            snapshot: snapshot, kind: .workbook, size: coverSize))
        XCTAssertGreaterThan(nonBlankPixelCount(in: image, below: 40), 16)
        XCTAssertFalse(plan.cells.contains { $0.text.contains("机密") || $0.text == "隐藏列" })
    }

    func testRealEmptyVisibleWorkbookWithHiddenHelperDataShowsThePlaceholder() async throws {
        let root = makeScratchDirectory("empty-visible")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, document, source) = try await makeWorkbook(root: root, name: "empty-visible.xlsx", sheets: [
            .init(name: "封面", rows: []),
            .init(name: "助手", rows: [["机密 helper", "200"]], visibility: .veryHidden)
        ])
        let snapshot = try OfficeDocumentService.inspect(url: source)
        XCTAssertEqual(NotesDocumentCoverService.workbookSummaryDecision(for: snapshot),
                       .emptyVisibleWorkbook)
        var calls = 0
        var paints: [NotesDocumentCoverOutcome] = []
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes,
            request: { _, _, _ in
                calls += 1
                return NotesOfficeThumbnailGenerator.AttemptOutcome(
                    image: self.grayImage(), diagnosis: "unexpected system content",
                    timedOut: false, elapsed: .zero)
            },
            onFirstPaint: { paints.append($0) })
        XCTAssertEqual(calls, 0, "a blank system page is not worth the shared host slot")
        XCTAssertTrue(paints.isEmpty)
        XCTAssertNil(outcome.image)
        XCTAssertEqual(outcome.source, .unsupported)
        XCTAssertEqual(outcome.diagnostics?.fallbackStage, .workbookEmpty)
        // The copy is localized by the host (the App test bundle runs under
        // the simulator locale), so the assertion accepts the exact readable
        // placeholder in either supported language and nothing else.
        XCTAssertTrue(
            ["This workbook has no visible cell content", "此工作簿没有可见的单元格内容"]
                .contains(outcome.diagnosis ?? ""),
            "the placeholder must be the localized empty-workbook copy: \(outcome.diagnosis ?? "nil")"
        )
    }

    func testCorruptRelationshipWorkbookNeverGuessesASheet() async throws {
        let root = makeScratchDirectory("corrupt-relationships")
        defer { try? FileManager.default.removeItem(at: root) }
        let tab = RawWorkbookFixture.Tab(name: "数据", part: "xl/worksheets/sheet1.xml",
                                         rows: [["公开", "1"]], state: nil)
        var missingTarget = RawWorkbookFixture(tabs: [tab])
        missingTarget.relationshipTargets = ["worksheets/gone.xml"]
        var noRelationships = RawWorkbookFixture(tabs: [tab])
        noRelationships.includeRelationships = false
        var noWorkbookPart = RawWorkbookFixture(tabs: [tab])
        noWorkbookPart.includeWorkbook = false
        let fixtures: [(String, Data)] = [
            ("missing-target", missingTarget.data()),
            ("no-relationships", noRelationships.data()),
            ("no-workbook-part", noWorkbookPart.data())
        ]
        for (label, data) in fixtures {
            let directory = root.appendingPathComponent(label, isDirectory: true)
            let source = directory.appendingPathComponent("\(label).xlsx")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: source, options: .atomic)
            let snapshot = try OfficeDocumentService.inspect(url: source)
            XCTAssertNil(snapshot.workbookPreview, "\(label): metadata must be unavailable")
            XCTAssertFalse(snapshot.fields.isEmpty, "\(label): the cells stay readable")
            XCTAssertEqual(NotesDocumentCoverService.workbookSummaryDecision(for: snapshot),
                           .metadataRequired, "\(label): never guess the first sheet")

            let (store, document) = try await makeImportedWorkbook(documentRoot: directory,
                                                                   name: "\(label).xlsx", data: data)
            var calls = 0
            var paints: [NotesDocumentCoverOutcome] = []
            let outcome = await NotesDocumentCoverService.render(
                document: document, store: store, size: coverSize,
                maximumSourceBytes: maximumSourceBytes,
                request: { _, _, _ in
                    calls += 1
                    return NotesOfficeThumbnailGenerator.AttemptOutcome(
                        image: self.grayImage(), diagnosis: "system content",
                        timedOut: false, elapsed: .zero)
                },
                onFirstPaint: { paints.append($0) })
            XCTAssertEqual(calls, 1, "\(label): the existing native preview is used")
            XCTAssertEqual(outcome.source, .quickLookThumbnail, label)
            XCTAssertTrue(paints.isEmpty, "\(label): no guessed summary first paint")
        }
    }

    func testDuplicateRelationshipTargetsAreRejected() throws {
        var fixture = RawWorkbookFixture(tabs: [
            .init(name: "数据", part: "xl/worksheets/sheet1.xml", rows: [["公开", "1"]], state: nil),
            .init(name: "内部", part: "xl/worksheets/sheet2.xml", rows: [["机密", "2"]], state: nil)
        ])
        fixture.duplicateFirstTarget = true
        let root = makeScratchDirectory("duplicate-targets")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("duplicate.xlsx")
        try fixture.data().write(to: source, options: .atomic)
        let snapshot = try OfficeDocumentService.inspect(url: source)
        XCTAssertNil(snapshot.workbookPreview)
        XCTAssertEqual(NotesDocumentCoverService.workbookSummaryDecision(for: snapshot), .metadataRequired)
    }

    func testUnknownSheetStateIsRejected() throws {
        let fixture = RawWorkbookFixture(tabs: [
            .init(name: "数据", part: "xl/worksheets/sheet1.xml", rows: [["公开", "1"]], state: "weird")
        ])
        let root = makeScratchDirectory("unknown-state")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("unknown-state.xlsx")
        try fixture.data().write(to: source, options: .atomic)
        let snapshot = try OfficeDocumentService.inspect(url: source)
        XCTAssertNil(snapshot.workbookPreview, "an unknown visibility state must not be guessed")
    }

    func testReorderedTabsFollowTheWorkbookOrderNotPartNumbers() async throws {
        let fixture = RawWorkbookFixture(tabs: [
            .init(name: "数据", part: "xl/worksheets/sheet2.xml",
                  rows: [["季度", "收入"], ["Q1", "120"]], state: nil),
            .init(name: "封面", part: "xl/worksheets/sheet1.xml", rows: [], state: nil)
        ])
        let root = makeScratchDirectory("reordered-tabs")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("reordered.xlsx")
        try fixture.data().write(to: source, options: .atomic)
        let snapshot = try OfficeDocumentService.inspect(url: source)
        let preview = try XCTUnwrap(snapshot.workbookPreview)
        XCTAssertEqual(preview.sheets.map(\.name), ["数据", "封面"])
        XCTAssertEqual(preview.sheets.map(\.section), ["Sheet 2", "Sheet 1"],
                       "the tab order, not the part numbering, drives the sheet list")
        let decision = NotesDocumentCoverService.workbookSummaryDecision(for: snapshot)
        guard case .plan(let plan) = decision else {
            XCTFail("expected a bounded plan, got \(decision)")
            return
        }
        XCTAssertEqual(plan.sheet, "Sheet 2")
        XCTAssertTrue(plan.isFirstWorksheet, "the data sheet is the workbook's first tab")
        XCTAssertEqual(plan.cells.map(\.text), ["季度", "收入", "Q1", "120"])

        let (store, document) = try await makeImportedWorkbook(documentRoot: root,
                                                               name: "reordered.xlsx", data: fixture.data())
        var calls = 0
        let outcome = await NotesDocumentCoverService.render(
            document: document, store: store, size: coverSize,
            maximumSourceBytes: maximumSourceBytes,
            request: { _, _, _ in
                calls += 1
                return NotesOfficeThumbnailGenerator.AttemptOutcome(
                    image: self.grayImage(), diagnosis: "content", timedOut: false, elapsed: .zero)
            })
        XCTAssertEqual(calls, 1, "the first tab is the data sheet; the system render targets it")
        XCTAssertEqual(outcome.source, .quickLookThumbnail)
    }

    func testMalformedHiddenDeclarationsAreReportedTruncated() async throws {
        let fixture = RawWorkbookFixture(tabs: [
            .init(name: "数据", part: "xl/worksheets/sheet1.xml",
                  rows: [["公开", "1"], ["疑似", "2"]], state: nil,
                  hiddenAttributeOverride: (row: 2, value: "maybe"),
                  extraColumnXML: [#"<col min="1" hidden="1"/>"#])
        ])
        let root = makeScratchDirectory("malformed-hidden")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("malformed.xlsx")
        try fixture.data().write(to: source, options: .atomic)
        let snapshot = try OfficeDocumentService.inspect(url: source)
        let sheet = try XCTUnwrap(snapshot.workbookPreview?.sheets.first)
        XCTAssertTrue(sheet.hiddenRowsTruncated, "a non-boolean hidden value is not trusted")
        XCTAssertTrue(sheet.hiddenColumnSpans.isEmpty)
        XCTAssertTrue(sheet.hiddenColumnsTruncated, "an incomplete col span is not trusted")
        XCTAssertEqual(NotesDocumentCoverService.workbookSummaryDecision(for: snapshot),
                       .hiddenFilteringUnavailable,
                       "content that cannot be filtered completely must defer to the native preview")
    }

    // MARK: - Helpers

    private func makeImportedWorkbook(documentRoot: URL, name: String,
                                      data: Data) async throws -> (store: NotesStore, document: NoteDocument) {
        try FileManager.default.createDirectory(at: documentRoot, withIntermediateDirectories: true)
        let source = documentRoot.appendingPathComponent(name)
        try data.write(to: source, options: .atomic)
        let store = try NotesStore(root: documentRoot.appendingPathComponent("store", isDirectory: true))
        let draft = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
        let document = try await store.create(draft)
        XCTAssertEqual(document.kind, .office)
        return (store, document)
    }

    private func makeScratchDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-workbook-plan-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a real synthetic workbook through the shared builder, imports it
    /// through the same `NoteFileImporter` path the app uses, and returns the
    /// created document plus the on-disk source package.
    private func makeWorkbook(root: URL, name: String,
                              sheets: [OfficeWorkbookSheet]) async throws -> (store: NotesStore, document: NoteDocument, source: URL) {
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let url = sources.appendingPathComponent(name)
        try OfficeDocumentBuilder.createWorkbook(at: url, sheets: sheets)
        let store = try NotesStore(root: root.appendingPathComponent("store"))
        let draft = try await NoteFileImporter.importFile(url, notebookID: nil, store: store)
        let document = try await store.create(draft)
        XCTAssertEqual(document.kind, .office)
        XCTAssertEqual(document.officeFileName, name)
        return (store, document, url)
    }

    private func grayImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor.systemGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
    }

    private func columnName(_ oneBased: Int) -> String {
        var value = oneBased
        var result = ""
        while value > 0 {
            value -= 1
            result.insert(Character(UnicodeScalar(65 + value % 26)!), at: result.startIndex)
            value /= 26
        }
        return result
    }

    /// Bounded sampled ink count below `belowY` (the accent header band is
    /// excluded, so a header-only render cannot satisfy it).
    private func nonBlankPixelCount(in image: UIImage, below belowY: CGFloat) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let width = cgImage.width, height = cgImage.height
        guard width > 0, height > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let scale = CGFloat(width) / coverSize.width
        let startY = max(0, min(height, Int(belowY * scale)))
        var count = 0
        for y in stride(from: startY, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let offset = (y * width + x) * 4
                if Int(pixels[offset]) < 200 || Int(pixels[offset + 1]) < 200 || Int(pixels[offset + 2]) < 200 {
                    count += 1
                }
            }
        }
        return count
    }
}

// L2-HARNESS-SHARED-BEGIN
/// Test-only builder for raw OOXML workbook packages.
///
/// The component host deliberately imports no ZIP library, so the tests write
/// the minimal stored (uncompressed) ZIP themselves and then read the package
/// through the real `OfficeDocumentService.inspect`. This is fixture
/// scaffolding, not product code: it exists so hidden tabs, reordered tab
/// order, corrupt relationships and malformed hidden declarations can be
/// exercised exactly. CRC-32 is the IEEE polynomial the ZIP format requires.
private struct StoredZipPackage {
    private var entries: [(name: String, data: Data)] = []

    mutating func add(_ name: String, _ xml: String) {
        entries.append((name, Data(xml.utf8)))
    }

    func data() -> Data {
        var output = Data()
        var central = Data()
        var offsets: [Int] = []
        for entry in entries {
            offsets.append(output.count)
            let name = Data(entry.name.utf8)
            let checksum = CRC32.checksum(entry.data)
            output.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])   // local file header
            output.append(littleEndian: UInt16(20))               // version needed
            output.append(littleEndian: UInt16(0))                // flags
            output.append(littleEndian: UInt16(0))                // method: stored
            output.append(littleEndian: UInt16(0))                // modification time
            output.append(littleEndian: UInt16(0))                // modification date
            output.append(littleEndian: checksum)
            output.append(littleEndian: UInt32(entry.data.count)) // compressed size
            output.append(littleEndian: UInt32(entry.data.count)) // uncompressed size
            output.append(littleEndian: UInt16(name.count))
            output.append(littleEndian: UInt16(0))                // extra length
            output.append(name)
            output.append(entry.data)
        }
        let centralStart = output.count
        for (index, entry) in entries.enumerated() {
            let name = Data(entry.name.utf8)
            let checksum = CRC32.checksum(entry.data)
            central.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])  // central directory
            central.append(littleEndian: UInt16(20))              // version made by
            central.append(littleEndian: UInt16(20))              // version needed
            central.append(littleEndian: UInt16(0))               // flags
            central.append(littleEndian: UInt16(0))               // method
            central.append(littleEndian: UInt16(0))               // modification time
            central.append(littleEndian: UInt16(0))               // modification date
            central.append(littleEndian: checksum)
            central.append(littleEndian: UInt32(entry.data.count))
            central.append(littleEndian: UInt32(entry.data.count))
            central.append(littleEndian: UInt16(name.count))
            central.append(littleEndian: UInt16(0))               // extra length
            central.append(littleEndian: UInt16(0))               // comment length
            central.append(littleEndian: UInt16(0))               // disk number
            central.append(littleEndian: UInt16(0))               // internal attributes
            central.append(littleEndian: UInt32(0))               // external attributes
            central.append(littleEndian: UInt32(offsets[index]))  // local header offset
            central.append(name)
        }
        output.append(central)
        output.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])       // end of central directory
        output.append(littleEndian: UInt16(0))                    // disk number
        output.append(littleEndian: UInt16(0))                    // central directory disk
        output.append(littleEndian: UInt16(entries.count))
        output.append(littleEndian: UInt16(entries.count))
        output.append(littleEndian: UInt32(central.count))
        output.append(littleEndian: UInt32(centralStart))
        output.append(littleEndian: UInt16(0))                    // comment length
        return output
    }
}

private enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            var value = (crc ^ UInt32(byte)) & 0xFF
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            crc = (crc >> 8) ^ value
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func append(littleEndian value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

/// Test-only raw workbook fixture factory. Every option exists to exercise one
/// real reader/planner branch: hidden and very-hidden tabs, actual tab order
/// that differs from the part numbering, missing/corrupt relationships,
/// duplicate targets, unknown states and malformed hidden declarations.
private struct RawWorkbookFixture {
    struct Tab {
        var name: String
        var part: String
        var rows: [[String]]
        var state: String?
        var hiddenRows: [Int] = []
        var hiddenColumns: [Int] = []
        /// Writes this exact `hidden` value on one row (malformed-value test).
        var hiddenAttributeOverride: (row: Int, value: String)?
        /// Extra raw `<col>` elements (malformed-span test).
        var extraColumnXML: [String] = []
    }

    var tabs: [Tab]
    var includeWorkbook = true
    var includeRelationships = true
    /// Written instead of the default per-tab target when set.
    var relationshipTargets: [String]?
    /// Points every tab at the first tab's target.
    var duplicateFirstTarget = false

    private static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let worksheetRelationship =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"

    func data() -> Data {
        var package = StoredZipPackage()
        package.add("[Content_Types].xml", Self.contentTypes())
        package.add("_rels/.rels", Self.rootRelationships())
        for tab in tabs {
            package.add(tab.part, Self.worksheet(tab))
        }
        if includeWorkbook {
            package.add("xl/workbook.xml", Self.workbook(tabs))
        }
        if includeRelationships {
            package.add("xl/_rels/workbook.xml.rels", relationships(tabs))
        }
        return package.data()
    }

    private func relationships(_ tabs: [Tab]) -> String {
        var items = tabs.enumerated().map { index, tab -> String in
            let target: String
            if duplicateFirstTarget {
                if let override = relationshipTargets, override.indices.contains(0) {
                    target = override[0]
                } else {
                    target = "worksheets/\(Self.lastComponent(tabs[0].part))"
                }
            } else if let overrides = relationshipTargets, overrides.indices.contains(index) {
                target = overrides[index]
            } else {
                target = "worksheets/\(Self.lastComponent(tab.part))"
            }
            return #"<Relationship Id="rId\#(index + 1)" Type="\#(Self.worksheetRelationship)" Target="\#(Self.escape(target))"/>"#
        }
        items.append(#"<Relationship Id="rId\#(tabs.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#)
        return Self.xmlHeader
            + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + items.joined() + "</Relationships>"
    }

    private static func contentTypes() -> String {
        xmlHeader + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/></Types>"#
    }

    private static func rootRelationships() -> String {
        xmlHeader + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#
    }

    private static func workbook(_ tabs: [Tab]) -> String {
        let sheets = tabs.enumerated().map { index, tab -> String in
            let state = tab.state.map { #" state="\#(escape($0))""# } ?? ""
            return #"<sheet name="\#(escape(tab.name))" sheetId="\#(index + 1)"\#(state) r:id="rId\#(index + 1)"/>"#
        }.joined()
        return xmlHeader + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"# + sheets + "</sheets></workbook>"
    }

    private static func worksheet(_ tab: Tab) -> String {
        var columnXML = tab.hiddenColumns.sorted().map { column in
            #"<col min="\#(column)" max="\#(column)" hidden="1"/>"#
        }
        columnXML.append(contentsOf: tab.extraColumnXML)
        let columns = columnXML.isEmpty ? "" : "<cols>" + columnXML.joined() + "</cols>"
        let rows = tab.rows.enumerated().map { rowIndex, row -> String in
            let cells = row.enumerated().map { columnIndex, value in
                #"<c r="\#(Self.columnName(columnIndex))\#(rowIndex + 1)" t="inlineStr"><is><t xml:space="preserve">\#(Self.escape(value))</t></is></c>"#
            }.joined()
            let hidden: String
            if let override = tab.hiddenAttributeOverride, override.row == rowIndex + 1 {
                hidden = #" hidden="\#(Self.escape(override.value))""#
            } else if tab.hiddenRows.contains(rowIndex + 1) {
                hidden = #" hidden="1""#
            } else {
                hidden = ""
            }
            return #"<row r="\#(rowIndex + 1)"\#(hidden)>\#(cells)</row>"#
        }.joined()
        return xmlHeader + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"# + columns + "<sheetData>" + rows + "</sheetData></worksheet>"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func columnName(_ zeroBased: Int) -> String {
        var value = zeroBased + 1
        var result = ""
        while value > 0 {
            value -= 1
            result.insert(Character(UnicodeScalar(65 + value % 26)!), at: result.startIndex)
            value /= 26
        }
        return result
    }
}
// L2-HARNESS-SHARED-END
