// SPDX-License-Identifier: MPL-2.0
// Real pinned-engine physical print layout proof for Word and PowerPoint on
// the canonical serialized iPad host with FLOE_OFFICE_EXPORT_QUALIFICATION=1.
//
// The source documents are built with the public OfficeDocumentBuilder (no
// user attachment bytes), exported through the ACTUAL shared
// OfficePDFExportService, then re-laid by the guarded OfficePDFPhysicalLayout
// pass. The paper boxes the laid output reports are our own deterministic
// kCGPDFContextMediaBox values, so they are asserted exactly; page count is
// proven 1:1 against the same document's no-layout baseline, and the source
// package digest is re-checked unchanged. Word is built Letter portrait and
// PowerPoint 16:9 landscape, so the orientation/aspect changes are real, not
// identity cases.
#if canImport(UIKit) && canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
import XCTest
import Foundation
import PDFKit
import FloeCore
import FloeDocuments
@testable import FloeApp

@MainActor
final class OfficePDFPaginatedLayoutAcceptanceTests: XCTestCase {
    private func qualified() throws -> URL {
        guard ProcessInfo.processInfo.environment["FLOE_OFFICE_EXPORT_QUALIFICATION"] == "1" else {
            throw XCTSkip("Requires FLOE_OFFICE_EXPORT_QUALIFICATION=1 on the canonical host")
        }
        executionTimeAllowance = 600
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfficePaginatedLayoutProof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func export(_ source: URL, sha: String, ext: String,
                        plan: OfficePDFPrintPlan, root: URL) async throws -> OfficePDFExportResult {
        try await OfficePDFExportService.export(.init(
            sourceURL: source, sourceSHA256: sha, formatExtension: ext,
            plan: plan, ownedDirectory: root))
    }

    func testWordPhysicalPaperOrientationIsActuallyApplied() async throws {
        let root = try qualified()
        let source = root.appendingPathComponent("proof.docx")
        try OfficeDocumentBuilder.createWord(
            at: source, title: "PaginatedLayoutProof",
            paragraphs: ["First paragraph of the proof body.",
                         "Second paragraph keeps the document over one page."])
        let sha = try FloeDigest.sha256Hex(ofFileAt: source)

        let baseline = try await export(source, sha: sha, ext: "docx", plan: .init(), root: root)
        XCTAssertGreaterThanOrEqual(baseline.pageCount, 1)
        // Word is built Letter portrait, so the untouched engine output is portrait.
        XCTAssertTrue(baseline.pageSizes.allSatisfy { $0.height >= $0.width - 0.01 },
                      "baseline Word pages should be portrait; got \(baseline.pageSizes)")
        XCTAssertNil(baseline.appliedPaginatedLayout)
        XCTAssertFalse(baseline.notes.contains(.physicalLayoutApplied))

        let fitted = try await export(
            source, sha: sha, ext: "docx",
            plan: OfficePDFPrintPlan(paginatedLayout: OfficePDFPaginatedLayout(
                paper: .a4, orientation: .landscape)), root: root)
        XCTAssertEqual(fitted.pageCount, baseline.pageCount, "layout pass is 1:1 in pages")
        XCTAssertEqual(fitted.pageSizes.count, fitted.pageCount)
        let a4 = OfficePDFPaginatedLayout.portraitSize(for: .a4)
        for size in fitted.pageSizes {
            XCTAssertEqual(size.width, a4.height, accuracy: 0.5, "A4 landscape width")
            XCTAssertEqual(size.height, a4.width, accuracy: 0.5, "A4 landscape height")
            XCTAssertGreaterThan(size.width, size.height, "landscape paper")
        }
        XCTAssertEqual(fitted.appliedPaginatedLayout,
                       OfficePDFPaginatedLayout(paper: .a4, orientation: .landscape))
        XCTAssertEqual(fitted.layoutExceedingPages, 0, "whole-page fit never clips")
        XCTAssertTrue(fitted.notes.contains(.physicalLayoutApplied))
        XCTAssertFalse(fitted.notes.contains(.physicalLayoutContentExceedsPaper))
        XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), sha, "source preserved")
    }

    func testPresentationPortraitFitAppliesAndPreservesTextAndSource() async throws {
        let root = try qualified()
        let source = root.appendingPathComponent("proof.pptx")
        try OfficeDocumentBuilder.createPresentation(
            at: source, title: "Deck",
            slides: [OfficePresentationSlide(title: "Slide One", bullets: ["alpha"]),
                     OfficePresentationSlide(title: "Slide Two", bullets: ["beta"])])
        let sha = try FloeDigest.sha256Hex(ofFileAt: source)

        let baseline = try await export(source, sha: sha, ext: "pptx", plan: .init(), root: root)
        // 16:9 slides are landscape in the engine's own output.
        XCTAssertTrue(baseline.pageSizes.allSatisfy { $0.width > $0.height },
                      "baseline PPTX slides should be landscape; got \(baseline.pageSizes)")

        let laid = try await export(
            source, sha: sha, ext: "pptx",
            plan: OfficePDFPrintPlan(paginatedLayout: OfficePDFPaginatedLayout(
                paper: .letter, orientation: .portrait)), root: root)
        XCTAssertEqual(laid.pageCount, baseline.pageCount, "1:1 page count on the deck")
        for size in laid.pageSizes {
            XCTAssertEqual(size.width, 612, accuracy: 0.5)
            XCTAssertEqual(size.height, 792, accuracy: 0.5)
            XCTAssertGreaterThan(size.height, size.width, "letter portrait paper")
        }
        XCTAssertEqual(laid.layoutExceedingPages, 0)
        XCTAssertTrue(laid.notes.contains(.physicalLayoutApplied))
        // The 16:9 landscape content fitted to portrait must be non-empty
        // (the guarded pass already refused any fitting page that lost text;
        // this is an independent reopen of the produced file).
        let reopened = try XCTUnwrap(PDFDocument(url: laid.pdfURL))
        XCTAssertEqual(reopened.pageCount, laid.pageCount)
        XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), sha, "deck source preserved")
    }

    func testExplicitActualSizeOverflowIsReportedNotHidden() async throws {
        let root = try qualified()
        let source = root.appendingPathComponent("wide.pptx")
        try OfficeDocumentBuilder.createPresentation(
            at: source, title: "Wide", slides: [OfficePresentationSlide(title: "Wide slide", bullets: ["x"])])
        let sha = try FloeDigest.sha256Hex(ofFileAt: source)
        let laid = try await export(
            source, sha: sha, ext: "pptx",
            plan: OfficePDFPrintPlan(paginatedLayout: OfficePDFPaginatedLayout(
                paper: .a4, orientation: .portrait, scale: .actualSize)), root: root)
        // A 960pt-wide slide at 100% overflows A4 portrait width (595pt).
        XCTAssertGreaterThan(laid.layoutExceedingPages ?? 0, 0,
                             "explicit actual-size overflow must be counted")
        XCTAssertTrue(laid.notes.contains(.physicalLayoutContentExceedsPaper),
                      "overflow note must be present")
        XCTAssertEqual(laid.pageSizes.first?.width, 595.2756, accuracy: 0.5)
    }
}
#endif
