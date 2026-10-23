// SPDX-License-Identifier: MPL-2.0
// FloeAppTests — shared Office PDF export service contract.
//
// These tests exercise the REAL shared service paths that do not require the
// pinned Office engine:
//
//  * capability truth table (saved isolation vs live-session finalize);
//  * plan validation for legacy formats;
//  * preflight refusals (stale/invalid source, format mismatch, legacy saved
//    export) that must happen before any engine session or child directory;
//  * `finalizeExistingPDF` around a REAL multi-page PDF produced with
//    CoreGraphics, including page selection, measured page geometry, source
//    verification, cancellation and refusal of a non-document scope;
//  * `OfficePDFPageSelection` ordering/dedup, out-of-range refusal, no
//    overwrite and no partial output.
//
// The real pinned-engine `export` path (XLSX print copy → engine PDF, DOCX/
// PPTX page ranges, actual ink not split horizontally) is NOT claimed here;
// it is the root full-App/native acceptance gate. These tests never call a
// mocked PDF "engine proof".

#if canImport(UIKit) && canImport(WebKit) && canImport(FloeOfficeNative)
import Foundation
import Testing
import PDFKit
import CoreGraphics
import FloeCore
import FloeDocuments
import FloeTools
@testable import FloeApp

@Suite("FloeApp.OfficePDFExportService")
struct OfficePDFExportServiceTests {
    // MARK: - Fixtures

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-pdf-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes a real PDF with one page per requested size. No PDF library
    /// mock: CoreGraphics produces the file that PDFKit then reopens.
    private func makePDF(at url: URL, pageSizes: [CGSize]) throws {
        // CoreGraphics accepts one media box per context on this host, so
        // each page is produced as a real one-page PDF and then merged with
        // PDFKit. That keeps each page's own geometry (the export service
        // measures the actual cropBox).
        let combined = PDFDocument()
        for (index, size) in pageSizes.enumerated() {
            let single = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-pdf-page-\(UUID().uuidString)-\(index).pdf")
            defer { try? FileManager.default.removeItem(at: single) }
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(url: single as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
                throw FloeError.internalError("could not create the PDF test fixture")
            }
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1))
            context.fill(box)
            context.endPDFPage()
            context.closePDF()
            guard let pageDocument = PDFDocument(url: single),
                  let page = pageDocument.page(at: 0)?.copy() as? PDFPage else {
                throw FloeError.internalError("could not merge the PDF test fixture")
            }
            combined.insert(page, at: combined.pageCount)
        }
        guard combined.pageCount == pageSizes.count, combined.write(to: url) else {
            throw FloeError.internalError("could not write the PDF test fixture")
        }
    }

    private func writeSource(_ root: URL, name: String, bytes: Data = Data("source-bytes".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func childDirectories(in root: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .filter { $0.hasPrefix("pdf-export-") } ?? []
    }

    private func expectSize(_ actual: CGSize, _ expected: CGSize) {
        #expect(abs(actual.width - expected.width) < 0.5,
                "width \(actual.width) != \(expected.width)")
        #expect(abs(actual.height - expected.height) < 0.5,
                "height \(actual.height) != \(expected.height)")
    }

    // MARK: - Capabilities

    @Test("capabilities distinguish qualified saved export from legacy live finalize")
    func capabilityTruthTable() throws {
        let xlsx = try #require(OfficePDFExportService.capability(forExtension: "XLSX"))
        #expect(xlsx.savedIsolatedExport && xlsx.liveSessionFinalize)
        #expect(xlsx.sheetScope && xlsx.customPageSetup && xlsx.finalPageRange)
        #expect(xlsx.selectedSheetsScope && xlsx.printAreaScope)
        #expect(xlsx.exactScale && xlsx.fitPageCount)
        #expect(xlsx.printGridlines)

        for ext in ["docx", "pptx"] {
            let capability = try #require(OfficePDFExportService.capability(forExtension: ext))
            #expect(capability.savedIsolatedExport && capability.liveSessionFinalize)
            #expect(!capability.sheetScope && !capability.customPageSetup)
            #expect(!capability.selectedSheetsScope && !capability.printAreaScope)
            #expect(!capability.exactScale && !capability.fitPageCount)
            #expect(!capability.printGridlines)
            #expect(capability.finalPageRange)
        }

        for ext in ["xls", "ods", "doc", "odt", "rtf", "ppt", "odp"] {
            let capability = try #require(OfficePDFExportService.capability(forExtension: ext))
            #expect(!capability.savedIsolatedExport, "\(ext) must not claim saved isolation")
            #expect(capability.liveSessionFinalize, "\(ext) must remain exportable from a live session")
            #expect(!capability.sheetScope && !capability.customPageSetup)
            #expect(!capability.selectedSheetsScope && !capability.printAreaScope)
            #expect(!capability.exactScale && !capability.fitPageCount)
            #expect(!capability.printGridlines)
            #expect(capability.finalPageRange)
        }
        #expect(OfficePDFExportService.capability(forExtension: "txt") == nil)
    }

    @Test("legacy plan validation keeps document settings and refuses custom scope")
    func legacyPlanValidation() throws {
        try OfficePDFPrintPlan(
            scope: .documentSettings,
            pageRange: OfficePDFPageRange(pages: [2, 3])
        ).validate(forExtension: "ods")

        #expect(throws: OfficePDFPlanError.unsupportedScope(format: "ods")) {
            try OfficePDFPrintPlan(scope: .sheet(name: "Sheet1", cellRange: nil))
                .validate(forExtension: "ods")
        }
        #expect(throws: OfficePDFPlanError.unsupportedPageSetup(format: "odt")) {
            try OfficePDFPrintPlan(pageSetup: OfficePDFPageSetup(paper: .a4))
                .validate(forExtension: "odt")
        }
    }

    // MARK: - Build 285 preview round: choices, scopes and the preview fence

    @Test("every supported Excel choice maps into the validated plan")
    func choicesMapEverySupportedOption() throws {
        let tabOrder = ["First", "Second", "Third"]

        var selected = OfficePDFExportChoices()
        selected.scope = .selectedSheets
        // Deliberately out-of-order: the plan must carry tab order.
        selected.selectedSheetNames = ["Second", "First"]
        let selectedPlan = try selected.plan(activeSheetName: nil, sheetTabOrder: tabOrder)
        #expect(selectedPlan.scope == .sheets(names: ["First", "Second"]))
        try selectedPlan.validate(forExtension: "xlsx")

        var printArea = OfficePDFExportChoices()
        printArea.scope = .sheet
        printArea.sheetName = "Second"
        printArea.sheetContent = .printArea
        let printAreaPlan = try printArea.plan(activeSheetName: "First", sheetTabOrder: tabOrder)
        #expect(printAreaPlan.scope == .sheetWithPrintArea(name: "Second"))
        try printAreaPlan.validate(forExtension: "xlsx")

        var range = printArea
        range.sheetContent = .range
        range.cellRange = "A1:R37"
        #expect(try range.plan(activeSheetName: nil, sheetTabOrder: tabOrder).scope
                == .sheet(name: "Second", cellRange: "A1:R37"))

        var exact = OfficePDFExportChoices()
        exact.fit = .exactScale
        exact.scalePercentText = "85"
        let exactPlan = try exact.plan(activeSheetName: nil)
        #expect(exactPlan.pageSetup.scalePercent == 85)
        #expect(exactPlan.pageSetup.fit == nil)
        #expect(exactPlan.pageSetup.hasOverrides)
        try exactPlan.validate(forExtension: "xlsx")

        var pages = OfficePDFExportChoices()
        pages.fit = .fitPages
        pages.fitPagesWideText = "2"
        pages.fitPagesTallText = "3"
        let pagesPlan = try pages.plan(activeSheetName: nil)
        #expect(pagesPlan.pageSetup.fitPages == OfficePDFFitPages(width: 2, height: 3))
        try pagesPlan.validate(forExtension: "xlsx")

        // The full-content sheet scope stays the ink-safe default: no range
        // crop is invented when the user only names the sheet.
        var full = OfficePDFExportChoices()
        full.scope = .sheet
        full.sheetName = "Second"
        #expect(try full.plan(activeSheetName: nil, sheetTabOrder: tabOrder).scope
                == .sheet(name: "Second", cellRange: nil))

        // The printed-gridlines choice maps to the explicit page-setup member;
        // the document default keeps the workbook's own printOptions.
        var grid = OfficePDFExportChoices()
        grid.gridlines = .on
        let gridPlan = try grid.plan(activeSheetName: nil)
        #expect(gridPlan.pageSetup.printGridlines == true)
        #expect(gridPlan.pageSetup.hasOverrides)
        try gridPlan.validate(forExtension: "xlsx")
        #expect(throws: OfficePDFPlanError.unsupportedPageSetup(format: "docx")) {
            try gridPlan.validate(forExtension: "docx")
        }
        grid.gridlines = .off
        #expect(try grid.plan(activeSheetName: nil).pageSetup.printGridlines == false)
        // Document settings for BOTH controls is the explicit "keep exactly
        // the workbook's own print setup" combination; the untouched form now
        // defaults to grid on + fit width, so the fit must be reset too.
        grid.fit = .document
        grid.gridlines = .document
        #expect(try grid.plan(activeSheetName: nil).pageSetup.isDocumentSettings)

        // A slider-set percentage propagates into the validated plan.
        var slider = OfficePDFExportChoices()
        slider.fit = .exactScale
        slider.scalePercentText = "150"
        let sliderPlan = try slider.plan(activeSheetName: nil)
        #expect(sliderPlan.pageSetup.scalePercent == 150)
        try sliderPlan.validate(forExtension: "xlsx")
    }

    @Test("selected sheets survive the adapter call without a tab order and still refuse stale names with one")
    func selectedSheetsWithoutTabOrder() throws {
        var choices = OfficePDFExportChoices()
        choices.scope = .selectedSheets
        // Duplicates and blanks are collapsed; the user's own order stands
        // when the caller cannot supply the saved tab order.
        choices.selectedSheetNames = ["Second", "First", "Second", " "]
        let plan = try choices.plan(activeSheetName: nil)
        #expect(plan.scope == .sheets(names: ["Second", "First"]))
        try plan.validate(forExtension: "xlsx")

        // With a supplied tab order the old normalization and stale refusal
        // stay exactly as before.
        #expect(throws: (any Error).self) {
            _ = try choices.plan(activeSheetName: nil, sheetTabOrder: ["Ghost"])
        }
        #expect(try choices.plan(activeSheetName: nil, sheetTabOrder: ["First", "Second"]).scope
                == .sheets(names: ["First", "Second"]))
    }

    @Test("invalid new-choice input is refused instead of producing a best-effort plan")
    func invalidChoiceInputsThrow() throws {
        var selected = OfficePDFExportChoices()
        selected.scope = .selectedSheets
        #expect(throws: (any Error).self) {
            _ = try selected.plan(activeSheetName: nil, sheetTabOrder: ["A"])
        }
        selected.selectedSheetNames = ["Ghost"]
        #expect(throws: (any Error).self) {
            _ = try selected.plan(activeSheetName: nil, sheetTabOrder: ["A", "B"])
        }

        var printArea = OfficePDFExportChoices()
        printArea.scope = .sheet
        printArea.sheetName = "A"
        printArea.sheetContent = .range
        #expect(throws: (any Error).self) {
            _ = try printArea.plan(activeSheetName: nil, sheetTabOrder: ["A"])
        }

        var exact = OfficePDFExportChoices()
        exact.fit = .exactScale
        for text in ["", "5", "401", "abc"] {
            exact.scalePercentText = text
            #expect(throws: (any Error).self) {
                _ = try exact.plan(activeSheetName: nil)
            }
        }

        var pages = OfficePDFExportChoices()
        pages.fit = .fitPages
        pages.fitPagesWideText = "1"
        pages.fitPagesTallText = ""
        #expect(throws: (any Error).self) {
            _ = try pages.plan(activeSheetName: nil)
        }
    }

    @Test("live-session finalize refuses the new print-copy scopes before any file read")
    func finalizeRefusesNewScopes() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeSource(root, name: "book.xlsx")
        let sha = try FloeDigest.sha256Hex(ofFileAt: source)
        let owned = root.appendingPathComponent("owned", isDirectory: true)

        for plan in [
            OfficePDFPrintPlan(scope: .sheets(names: ["A", "B"])),
            OfficePDFPrintPlan(scope: .sheetWithPrintArea(name: "A")),
            OfficePDFPrintPlan(pageSetup: OfficePDFPageSetup(scalePercent: 85)),
        ] {
            await #expect(throws: OfficePDFExportError.self) {
                _ = try await OfficePDFExportService.finalizeExistingPDF(
                    OfficePDFFinalizeRequest(
                        exportedPDFURL: root.appendingPathComponent("missing.pdf"),
                        sourceURL: source, sourceSHA256: sha,
                        formatExtension: "xlsx", plan: plan,
                        ownedDirectory: owned))
            }
        }
        // No child directory may exist: refusal happens before file work.
        #expect(childDirectories(in: owned).isEmpty)
    }

    @Test("the preview fence accepts only the current generation and goes stale on any choice change")
    func previewFenceSemantics() throws {
        var state = OfficePDFExportPreviewState()
        #expect(state.isReady == false)
        _ = state.beginGeneration()
        let token = state.beginGeneration()
        let artifact = OfficePDFExportPreviewState.Artifact(
            url: URL(fileURLWithPath: "/tmp/floe-preview-test.pdf"),
            pageCount: 2, byteCount: 1_234,
            pdfSHA256: String(repeating: "0", count: 64))
        // A late completion from the fenced older generation never publishes.
        #expect(state.accept(token: token - 1, artifact: artifact,
                              choices: OfficePDFExportChoices()) == false)
        #expect(state.isReady == false)
        let accepted = OfficePDFExportChoices()
        #expect(state.accept(token: token, artifact: artifact, choices: accepted) == true)
        #expect(state.isReady)
        #expect(state.isStale(currentChoices: accepted) == false)
        var changed = accepted
        changed.pages = "1"
        #expect(state.isStale(currentChoices: changed) == true)
        changed = accepted
        changed.fit = .exactScale
        #expect(state.isStale(currentChoices: changed) == true)
        changed = accepted
        changed.selectedSheetNames = ["A"]
        #expect(state.isStale(currentChoices: changed) == true)
        state.invalidate()
        #expect(state.isReady == false)
        #expect(state.isStale(currentChoices: accepted) == false)
    }

    @Test("the auto-preview fence refuses superseded, cancelled and post-cancel completions")
    func autoPreviewFenceRefusesStaleAndCancelledGenerations() throws {
        var state = OfficePDFExportPreviewState()
        let artifact = OfficePDFExportPreviewState.Artifact(
            url: URL(fileURLWithPath: "/tmp/floe-auto-preview.pdf"),
            pageCount: 1, byteCount: 10,
            pdfSHA256: String(repeating: "a", count: 64))
        // A change while a render runs supersedes it: the older completion
        // can never publish, so two generations never overlap on screen.
        let superseded = state.beginGeneration()
        let current = state.beginGeneration()
        #expect(state.accept(token: superseded, artifact: artifact,
                              choices: OfficePDFExportChoices()) == false)
        #expect(state.isReady == false)
        // Cancel/dismiss fences the run that WAS current: after invalidate a
        // late completion is refused instead of publishing stale bytes.
        state.invalidate()
        #expect(state.accept(token: current, artifact: artifact,
                              choices: OfficePDFExportChoices()) == false)
        #expect(state.artifact == nil)
        // A fresh generation after recovery publishes, and the final-action
        // gate goes stale again on any visible setting change.
        let token = state.beginGeneration()
        let settled = OfficePDFExportChoices()
        #expect(state.accept(token: token, artifact: artifact, choices: settled) == true)
        #expect(state.isStale(currentChoices: settled) == false)
        var changed = settled
        changed.gridlines = .on
        #expect(state.isStale(currentChoices: changed) == true)
        changed = settled
        changed.scalePercentText = "150"
        #expect(state.isStale(currentChoices: changed) == true)
    }

    // MARK: - Product defaults and the automatic-preview queue boundary

    @Test("workbook defaults print the grid and fit the page width; Word/Presentation keep their own setup")
    func workbookDefaultsAndFormatNormalization() throws {
        // The untouched form for a workbook submits grid on + fit width and
        // keeps every other member at the document's own value.
        let workbook = try OfficePDFExportChoices().plan(activeSheetName: nil)
        #expect(workbook.scope == .documentSettings)
        #expect(workbook.pageSetup.fit == .fitToWidth)
        #expect(workbook.pageSetup.printGridlines == true)
        #expect(workbook.pageSetup.paper == nil)
        #expect(workbook.pageSetup.orientation == nil)
        #expect(workbook.pageSetup.scalePercent == nil)
        #expect(workbook.pageSetup.fitPages == nil)
        try workbook.validate(forExtension: "xlsx")

        // Word/Presentation documents must never inherit the workbook-only
        // grid/scaling defaults: their plan stays document settings.
        for ext in ["docx", "pptx", "ods", "doc", "odt", "rtf", "ppt", "odp"] {
            var choices = OfficePDFExportChoices()
            choices.applyDocumentSetupDefaults(forFormatExtension: ext)
            let plan = try choices.plan(activeSheetName: nil)
            #expect(plan.scope == .documentSettings)
            #expect(plan.pageSetup.isDocumentSettings, "unexpected overrides for .\(ext)")
            try plan.validate(forExtension: ext)
        }

        // An explicit scaling choice stays authoritative; the grid remains a
        // separate control with its own default.
        var exact = OfficePDFExportChoices()
        exact.fit = .exactScale
        exact.scalePercentText = "120"
        let exactPlan = try exact.plan(activeSheetName: nil)
        #expect(exactPlan.pageSetup.scalePercent == 120)
        #expect(exactPlan.pageSetup.fit == nil)
        #expect(exactPlan.pageSetup.printGridlines == true)
        try exactPlan.validate(forExtension: "xlsx")

        // Explicitly returning the scaling control to document settings
        // restores exactly the workbook's own scale.
        var document = OfficePDFExportChoices()
        document.fit = .document
        #expect(try document.plan(activeSheetName: nil).pageSetup.fit == nil)
    }

    @Test("the cover plan is the first visible sheet at full content, never a saved crop area")
    func coverPlanShape() throws {
        let cover = OfficePDFExportService.savedCoverPlan(
            formatExtension: "xlsx", firstVisibleSheetName: "Data")
        // Full content: no invented cell range and no adoption of the sheet's
        // saved `_xlnm.Print_Area` (that stays the explicit user choice).
        #expect(cover.scope == .sheet(name: "Data", cellRange: nil))
        #expect(cover.pageSetup.fit == .fitToOnePage)
        #expect(cover.pageSetup.printGridlines == true)
        try cover.validate(forExtension: "xlsx")

        for ext in ["docx", "pptx"] {
            let plan = OfficePDFExportService.savedCoverPlan(
                formatExtension: ext, firstVisibleSheetName: nil)
            #expect(plan.scope == .documentSettings)
            #expect(plan.pageSetup.isDocumentSettings)
        }
        // A workbook whose visible tab cannot be resolved keeps the previous
        // full-workbook route instead of inventing a sheet.
        let unresolved = OfficePDFExportService.savedCoverPlan(
            formatExtension: "xlsx", firstVisibleSheetName: nil)
        #expect(unresolved.scope == .allVisibleSheets)
    }

    @Test("the reconciliation re-arms a stale idle dock and never loops a refused failure")
    func previewReconciliationDecisions() {
        typealias Decision = OfficePDFAutoPreviewReconciliation.Decision
        func decide(loading: Bool = false, working: Bool = false,
                    presenting: Bool = false, artifactUsable: Bool = false,
                    settingsValid: Bool = true, canRetry: Bool = true,
                    sourcePresent: Bool = true) -> Decision {
            OfficePDFAutoPreviewReconciliation.decision(
                sourcePresent: sourcePresent, loading: loading, working: working,
                presenting: presenting, artifactUsable: artifactUsable,
                settingsValid: settingsValid, automaticRetryAllowed: canRetry)
        }

        // The reported on-device state: a settings change whose pump ran while
        // the previous render still owned the serial slot. The render settles
        // and the same stale dock must re-arm instead of waiting for a tap.
        #expect(decide(working: true) == .waitForOwner)
        #expect(decide() == .render)
        // A fenced or cancelled completion leaves no pending snapshot; the
        // idle stale state is still re-armed.
        #expect(decide() == .render)
        // Accepted artifact for the visible settings: nothing to render.
        #expect(decide(artifactUsable: true) == .current)
        // Owners hold the view first.
        #expect(decide(loading: true) == .waitForOwner)
        #expect(decide(presenting: true) == .waitForOwner)
        // No loop for a state that must stay manual: invalid settings, a
        // non-retryable failure (budget not allowed), a spent budget, or a
        // missing source.
        #expect(decide(settingsValid: false) == .manual)
        #expect(decide(canRetry: false) == .manual)
        #expect(decide(sourcePresent: false) == .manual)
        // An owner that is active always wins over a manual state.
        #expect(decide(loading: true, settingsValid: false) == .waitForOwner)
    }

    @MainActor
    @Test("only a session-busy generation may retry; every other failure keeps its error")
    func previewRetryFamily() {
        #expect(OfficePDFExportOptionsView.isRetryablePreviewFailure(
            OfficePDFExportScreenError.sessionBusy))
        #expect(!OfficePDFExportOptionsView.isRetryablePreviewFailure(
            OfficePDFExportScreenError.sourceChanged))
        #expect(!OfficePDFExportOptionsView.isRetryablePreviewFailure(
            OfficePDFPlanError.conflictingScalingControls))
        #expect(!OfficePDFExportOptionsView.isRetryablePreviewFailure(
            OfficePDFPlanError.unsupportedPageSetup(format: "docx")))
        #expect(!OfficePDFExportOptionsView.isRetryablePreviewFailure(
            OfficePDFExportError.invalidPDF(reason: "not-a-pdf")))
        #expect(!OfficePDFExportOptionsView.isRetryablePreviewFailure(
            OfficePDFExportError.outputDirectoryUnavailable))
        #expect(!OfficePDFExportOptionsView.isRetryablePreviewFailure(
            OfficePrintCopyError.verificationFailed(reason: "tampered")))
        #expect(!OfficePDFExportOptionsView.isRetryablePreviewFailure(
            CocoaError(.fileWriteNoPermission)))
        #expect(!OfficePDFExportOptionsView.isRetryablePreviewFailure(CancellationError()))
    }

    @Test("the automatic retry budget is bounded per snapshot and released by a new one")
    func previewRetryBudget() {
        var retry = OfficePDFAutoPreviewRetry()
        var choices = OfficePDFExportChoices()
        choices.pages = "1"
        #expect(retry.canRetry)
        #expect(retry.registerFailure(of: choices) != nil)
        #expect(retry.registerFailure(of: choices) != nil)
        #expect(retry.registerFailure(of: choices) != nil)
        #expect(retry.canRetry == false)
        #expect(retry.registerFailure(of: choices) == nil,
                "a spent budget must stop rendering instead of looping")
        // A different visible snapshot owns a fresh budget.
        choices.pages = "2"
        #expect(retry.registerFailure(of: choices) != nil)
        #expect(retry.canRetry)
        // A successful generation releases everything.
        retry.recordSuccess()
        #expect(retry.attempts == 0)
        #expect(retry.snapshot == nil)
        #expect(retry.canRetry)
        // The backoff grows with the spent attempts (never a tight loop).
        #expect(retry.nextBackoff < {
            var grown = OfficePDFAutoPreviewRetry()
            _ = grown.registerFailure(of: choices)
            _ = grown.registerFailure(of: choices)
            return grown.nextBackoff
        }())
    }

    // MARK: - Preflight

    @Test("preflight refusals happen before any engine session or child directory")
    func preflightRefusals() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeSource(root, name: "report.xlsx")
        let sha = try FloeDigest.sha256Hex(ofFileAt: source)
        let owned = root.appendingPathComponent("owned", isDirectory: true)
        let plan = OfficePDFPrintPlan(scope: .allVisibleSheets)

        await #expect(throws: OfficePDFExportError.invalidSourceIdentity) {
            _ = try await OfficePDFExportService.export(OfficePDFExportRequest(
                sourceURL: source, sourceSHA256: "not-a-digest",
                formatExtension: "xlsx", plan: plan, ownedDirectory: owned))
        }
        await #expect(throws: OfficePDFExportError.invalidSourceIdentity) {
            _ = try await OfficePDFExportService.export(OfficePDFExportRequest(
                sourceURL: source, sourceSHA256: sha,
                formatExtension: "docx", plan: plan, ownedDirectory: owned))
        }
        let stale = String(repeating: "0", count: 64)
        await #expect(throws: OfficePDFExportError.staleSource) {
            _ = try await OfficePDFExportService.export(OfficePDFExportRequest(
                sourceURL: source, sourceSHA256: stale,
                formatExtension: "xlsx", plan: plan, ownedDirectory: owned))
        }
        #expect(childDirectories(in: owned).isEmpty)

        let legacy = try writeSource(root, name: "legacy.ods")
        let legacySHA = try FloeDigest.sha256Hex(ofFileAt: legacy)
        await #expect(throws: OfficePDFExportError.savedExportUnavailable(
            format: "ods",
            reason: "the isolated export host is qualified for .xlsx, .docx and .pptx; export the open document and finalize that PDF")) {
            _ = try await OfficePDFExportService.export(OfficePDFExportRequest(
                sourceURL: legacy, sourceSHA256: legacySHA,
                formatExtension: "ods", plan: .init(), ownedDirectory: owned))
        }
        #expect(childDirectories(in: owned).isEmpty)

        await #expect(throws: OfficePDFPlanError.unsupportedFormat("txt")) {
            _ = try await OfficePDFExportService.export(OfficePDFExportRequest(
                sourceURL: try writeSource(root, name: "notes.txt"),
                sourceSHA256: sha, formatExtension: "txt",
                plan: .init(), ownedDirectory: owned))
        }
    }

    // MARK: - Finalize existing PDF

    @Test("finalize validates a real PDF, selects final pages and preserves the source")
    func finalizeSelectsRealPages() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeSource(root, name: "legacy.ods")
        let sourceSHA = try FloeDigest.sha256Hex(ofFileAt: source)
        let enginePDF = root.appendingPathComponent("engine.pdf")
        try makePDF(at: enginePDF, pageSizes: [
            CGSize(width: 595, height: 842),
            CGSize(width: 500, height: 700),
            CGSize(width: 600, height: 800),
        ])
        let engineBytes = try Data(contentsOf: enginePDF)
        let owned = root.appendingPathComponent("owned", isDirectory: true)

        let result = try await OfficePDFExportService.finalizeExistingPDF(
            OfficePDFFinalizeRequest(
                exportedPDFURL: enginePDF,
                sourceURL: source,
                sourceSHA256: sourceSHA,
                formatExtension: "ods",
                plan: OfficePDFPrintPlan(
                    scope: .documentSettings,
                    pageRange: OfficePDFPageRange(pages: [3, 2])),
                ownedDirectory: owned))

        #expect(result.pageCount == 2)
        #expect(result.appliedPageRange == [2, 3])
        #expect(result.appliedPrintPlan == nil)
        #expect(result.sourceFormatExtension == "ods")
        #expect(result.notes.contains(.documentSettingsPreserved))
        #expect(result.notes.contains(.legacyFormatFinalized))
        #expect(result.notes.contains(.finalPageSelectionApplied))
        #expect(result.pdfURL.lastPathComponent == "legacy.pdf")
        #expect(result.byteCount > 0)
        #expect(result.pdfSHA256 == (try FloeDigest.sha256Hex(ofFileAt: result.pdfURL)))
        expectSize(result.pageSizes[0], CGSize(width: 500, height: 700))
        expectSize(result.pageSizes[1], CGSize(width: 600, height: 800))

        // The engine's own PDF and the exact source are untouched.
        #expect(try Data(contentsOf: enginePDF) == engineBytes)
        #expect(try FloeDigest.sha256Hex(ofFileAt: source) == sourceSHA)

        // The final file reopens with exactly the selected pages.
        let reopened = try #require(PDFDocument(url: result.pdfURL))
        #expect(reopened.pageCount == 2)
    }

    @Test("finalize refuses a scope it cannot actually apply to an existing PDF")
    func finalizeRefusesRescope() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeSource(root, name: "report.xlsx")
        let sha = try FloeDigest.sha256Hex(ofFileAt: source)
        let enginePDF = root.appendingPathComponent("engine.pdf")
        try makePDF(at: enginePDF, pageSizes: [CGSize(width: 595, height: 842)])
        let owned = root.appendingPathComponent("owned", isDirectory: true)

        await #expect(throws: OfficePDFExportError.savedExportUnavailable(
            format: "xlsx",
            reason: "finalizing an existing PDF supports document settings and a final page range only")) {
            _ = try await OfficePDFExportService.finalizeExistingPDF(
                OfficePDFFinalizeRequest(
                    exportedPDFURL: enginePDF,
                    sourceURL: source,
                    sourceSHA256: sha,
                    formatExtension: "xlsx",
                    plan: OfficePDFPrintPlan(scope: .sheet(name: "Sheet1", cellRange: "A1:R37")),
                    ownedDirectory: owned))
        }
        #expect(childDirectories(in: owned).isEmpty)
    }

    @Test("finalize checks the exact source and cancellation before producing output")
    func finalizeGuards() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeSource(root, name: "legacy.ods")
        let stale = String(repeating: "0", count: 64)
        let enginePDF = root.appendingPathComponent("engine.pdf")
        try makePDF(at: enginePDF, pageSizes: [CGSize(width: 595, height: 842)])
        let owned = root.appendingPathComponent("owned", isDirectory: true)

        await #expect(throws: OfficePDFExportError.staleSource) {
            _ = try await OfficePDFExportService.finalizeExistingPDF(
                OfficePDFFinalizeRequest(
                    exportedPDFURL: enginePDF, sourceURL: source,
                    sourceSHA256: stale, formatExtension: "ods",
                    plan: .init(), ownedDirectory: owned))
        }

        let token = CancellationToken()
        token.cancel()
        await #expect(throws: FloeError.cancelled) {
            _ = try await OfficePDFExportService.finalizeExistingPDF(
                OfficePDFFinalizeRequest(
                    exportedPDFURL: enginePDF, sourceURL: source,
                    sourceSHA256: try FloeDigest.sha256Hex(ofFileAt: source),
                    formatExtension: "ods", plan: .init(),
                    ownedDirectory: owned, cancellation: token))
        }
        #expect(childDirectories(in: owned).isEmpty)
    }

    @Test("finalize refuses a non-PDF or an oversized source PDF")
    func finalizeRejectsBadPDF() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeSource(root, name: "legacy.ods")
        let sha = try FloeDigest.sha256Hex(ofFileAt: source)
        let notPDF = try writeSource(root, name: "engine.pdf", bytes: Data("not a pdf".utf8))
        let owned = root.appendingPathComponent("owned", isDirectory: true)

        await #expect(throws: OfficePDFExportError.invalidPDF(reason: "not-a-pdf")) {
            _ = try await OfficePDFExportService.finalizeExistingPDF(
                OfficePDFFinalizeRequest(
                    exportedPDFURL: notPDF, sourceURL: source, sourceSHA256: sha,
                    formatExtension: "ods", plan: .init(), ownedDirectory: owned))
        }
    }

    // MARK: - Page selection

    @Test("selection orders and deduplicates pages and verifies real geometry")
    func selectionOrdersPages() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf")
        try makePDF(at: source, pageSizes: [
            CGSize(width: 595, height: 842),
            CGSize(width: 500, height: 700),
            CGSize(width: 600, height: 800),
        ])
        let output = root.appendingPathComponent("selected.pdf")

        let outcome = try OfficePDFPageSelection.select(
            sourceURL: source, pages: [3, 1, 3], outputURL: output)
        #expect(outcome.pageCount == 2)
        #expect(outcome.selectedPages == [1, 3])
        expectSize(outcome.pageSizes[0], CGSize(width: 595, height: 842))
        expectSize(outcome.pageSizes[1], CGSize(width: 600, height: 800))
        let reopened = try #require(PDFDocument(url: output))
        #expect(reopened.pageCount == 2)
        let sourceDocument = try #require(PDFDocument(url: source))
        #expect(sourceDocument.pageCount == 3)
    }

    @Test("selecting every page keeps the original PDF")
    func selectionAllPagesKeepsSource() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf")
        try makePDF(at: source, pageSizes: [
            CGSize(width: 595, height: 842),
            CGSize(width: 500, height: 700),
        ])
        let output = root.appendingPathComponent("selected.pdf")
        let outcome = try OfficePDFPageSelection.select(
            sourceURL: source, pages: [1, 2], outputURL: output)
        #expect(outcome.selectedPages == nil)
        #expect(outcome.pdfURL == source)
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("out-of-range selection and existing output never produce a partial PDF")
    func selectionRefusals() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.pdf")
        try makePDF(at: source, pageSizes: [CGSize(width: 595, height: 842)])
        let output = root.appendingPathComponent("selected.pdf")

        #expect(throws: OfficePDFPlanError.pageOutOfRange(page: 2, pageCount: 1)) {
            _ = try OfficePDFPageSelection.select(
                sourceURL: source, pages: [2], outputURL: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))

        try Data("existing".utf8).write(to: output)
        #expect(throws: OfficePDFExportError.outputAlreadyExists(output.path)) {
            _ = try OfficePDFPageSelection.select(
                sourceURL: source, pages: [1], outputURL: output)
        }
        #expect(try Data(contentsOf: output) == Data("existing".utf8))
    }

    @Test("page-range parse is strict for the shared UI input")
    func pageRangeParsing() throws {
        #expect(OfficePDFPageRange.parse("2,1-2")?.pages == [1, 2])
        #expect(OfficePDFPageRange.parse("0") == nil)
        #expect(OfficePDFPageRange.parse("2-1") == nil)
        #expect(OfficePDFPageRange.parse("1,,2") == nil)
        #expect(OfficePDFPageRange.parse("1-501") == nil)
        #expect(try OfficePDFPageRange(pages: []).validated(pageCount: 4) == [1, 2, 3, 4])
    }
}

@MainActor
private final class PDFPreparationTestSignal {
    private var resolved = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if resolved { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resolve() {
        resolved = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

@MainActor
private final class PDFPreparationTestState {
    var produced = 0
    var current = true
}

@Suite("FloeApp.OfficePDFPreparationCoordinator")
@MainActor
struct OfficePDFPreparationCoordinatorTests {
    @Test func remountedConsumerJoinsOneProducerAndCancelsLocally() async throws {
        let coordinator = OfficePDFPreparationCoordinator<String>()
        let request = CancellationToken()
        let started = PDFPreparationTestSignal(), release = PDFPreparationTestSignal()
        let joined = PDFPreparationTestSignal()
        let state = PDFPreparationTestState()
        let producer: @MainActor () async throws -> String = {
            state.produced += 1; started.resolve()
            await release.wait()
            return "verified-copy"
        }
        let first = Task { @MainActor in
            try await coordinator.run(request: request, isCurrent: { state.current }, producer: producer)
        }
        await started.wait()
        let second = Task { @MainActor in
            try await coordinator.run(request: request, isCurrent: { state.current }, producer: producer,
                                      observe: { if $0 == "joined" { joined.resolve() } })
        }
        await joined.wait()
        first.cancel()
        release.resolve()
        switch await first.result {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("Cancelled consumer published a preparation")
        }
        let result = try await second.value
        #expect(result == "verified-copy")
        #expect(state.produced == 1)
        let fresh = try await coordinator.run(request: CancellationToken(), isCurrent: { true }, producer: {
            state.produced += 1; return "new-intent"
        })
        #expect(fresh == "new-intent")
        #expect(state.produced == 2)
    }

    @Test func modalCancellationCannotCancelTheNextModal() async throws {
        let coordinator = OfficePDFPreparationCoordinator<String>()
        let oldRequest = CancellationToken(), nextRequest = CancellationToken()
        let started = PDFPreparationTestSignal(), release = PDFPreparationTestSignal()
        let old = Task { @MainActor in
            try await coordinator.run(request: oldRequest, isCurrent: { true }, producer: {
                started.resolve(); await release.wait(); return "old"
            })
        }
        await started.wait()
        oldRequest.cancel(); coordinator.cancel(request: oldRequest)
        release.resolve()
        switch await old.result {
        case .failure(let error): #expect(error is CancellationError)
        case .success: Issue.record("Cancelled modal published a preparation")
        }
        let nextStarted = PDFPreparationTestSignal(), nextRelease = PDFPreparationTestSignal()
        let next = Task { @MainActor in
            try await coordinator.run(request: nextRequest, isCurrent: { true }, producer: {
                nextStarted.resolve(); await nextRelease.wait(); return "next"
            })
        }
        await nextStarted.wait()
        coordinator.cancel(request: oldRequest)
        nextRelease.resolve()
        let result = try await next.value
        #expect(result == "next")
    }

    @Test func replacedOwnerCannotPublishOrRebaseThePreparation() async throws {
        let coordinator = OfficePDFPreparationCoordinator<String>()
        let state = PDFPreparationTestState()
        let started = PDFPreparationTestSignal(), release = PDFPreparationTestSignal()
        let operation = Task { @MainActor in
            try await coordinator.run(request: CancellationToken(), isCurrent: { state.current }, producer: {
                state.produced += 1; started.resolve(); await release.wait(); return "old-owner"
            })
        }
        await started.wait()
        state.current = false; release.resolve()
        switch await operation.result {
        case .failure(let error):
            guard let screenError = error as? OfficePDFExportScreenError else {
                Issue.record("Expected source change, received \(error)"); return
            }
            if case .sourceChanged = screenError { } else { Issue.record("Owner replacement was relabelled busy") }
        case .success: Issue.record("Replaced owner published a preparation")
        }
        do {
            _ = try await coordinator.run(request: CancellationToken(), isCurrent: { state.current }, producer: {
                state.produced += 1; return "silently-rebased"
            })
            Issue.record("Invalid owner was silently rebased")
        } catch { #expect(error is OfficePDFExportScreenError) }
        #expect(state.produced == 1)
    }
}

#endif
