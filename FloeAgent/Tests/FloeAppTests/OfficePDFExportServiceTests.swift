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

        for ext in ["docx", "pptx"] {
            let capability = try #require(OfficePDFExportService.capability(forExtension: ext))
            #expect(capability.savedIsolatedExport && capability.liveSessionFinalize)
            #expect(!capability.sheetScope && !capability.customPageSetup)
            #expect(!capability.selectedSheetsScope && !capability.printAreaScope)
            #expect(!capability.exactScale && !capability.fitPageCount)
            #expect(capability.finalPageRange)
        }

        for ext in ["xls", "ods", "doc", "odt", "rtf", "ppt", "odp"] {
            let capability = try #require(OfficePDFExportService.capability(forExtension: ext))
            #expect(!capability.savedIsolatedExport, "\(ext) must not claim saved isolation")
            #expect(capability.liveSessionFinalize, "\(ext) must remain exportable from a live session")
            #expect(!capability.sheetScope && !capability.customPageSetup)
            #expect(!capability.selectedSheetsScope && !capability.printAreaScope)
            #expect(!capability.exactScale && !capability.fitPageCount)
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
#endif
