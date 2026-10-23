// SPDX-License-Identifier: MPL-2.0
// FloeAppTests — the guarded physical print layout pass on real PDFKit.
//
// Synthetic multi-page PDFs (mixed aspect + one /Rotate 90 page, each with
// distinct extractable text). These prove the renderer on the iOS test host:
// measured paper boxes, 1:1 page count, text retention for every page that
// fits the paper, honest exceed counts for explicit overflow, safe
// whole-page fit (never enlarged, never clipped), per-page cancellation that
// removes the partial output, and refusal of no-override/existing/corrupt
// inputs. This is NOT a reflow or engine claim: the real pinned-engine
// DOCX/PPTX output is the OfficePDFExportAcceptance/Service gates.
#if canImport(UIKit) && canImport(PDFKit)
import XCTest
import CoreGraphics
import PDFKit
import FloeCore
import FloeTools
import FloeDocuments
@testable import FloeApp

final class OfficePDFPhysicalLayoutTests: XCTestCase {
    // MARK: - Fixture

    private func draw(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat = 20) {
        let font = UIFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: point.x, y: point.y)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func beginPage(_ context: CGContext, width: CGFloat, height: CGFloat) {
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
        context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("paginated-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// p1 595x842 portrait, p2 792x612 landscape, p3 405x720 media with
    /// /Rotate 90 (upright display 720x405).
    private func makeMixedSource(at url: URL) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw NSError(domain: "fixture", code: 1)
        }
        beginPage(context, width: 595.28, height: 841.89)
        draw("ALPHA-TOP", in: context, at: CGPoint(x: 40, y: 780))
        draw("ALPHA-BOTTOM", in: context, at: CGPoint(x: 40, y: 40))
        context.endPDFPage()
        beginPage(context, width: 792, height: 612)
        draw("BRAVO-WIDE", in: context, at: CGPoint(x: 30, y: 540))
        context.endPDFPage()
        beginPage(context, width: 405, height: 720)
        draw("CHARLIE-ROT", in: context, at: CGPoint(x: 30, y: 640))
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(url: url) else {
            throw NSError(domain: "fixture", code: 2)
        }
        document.page(at: 2)?.rotation = 90
        let rewritten = url.deletingLastPathComponent()
            .appendingPathComponent("rotated-\(UUID().uuidString).pdf")
        guard document.write(to: rewritten) else {
            throw NSError(domain: "fixture", code: 3)
        }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: rewritten, to: url)
    }

    private func normalized(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    private func render(_ layout: OfficePDFPaginatedLayout,
                        cancellation: CancellationToken? = nil) throws
        -> (source: URL, output: URL, outcome: OfficePDFPhysicalLayout.Outcome) {
        let directory = try root()
        let source = directory.appendingPathComponent("source.pdf")
        try makeMixedSource(at: source)
        let output = directory.appendingPathComponent("laid.pdf")
        let outcome = try OfficePDFPhysicalLayout.apply(layout: layout,
                                                        sourceURL: source,
                                                        outputURL: output,
                                                        cancellation: cancellation)
        return (source, output, outcome)
    }

    // MARK: - Tests

    func testFitToLandscapeLetterMeasuresEveryPageAndRetainsText() throws {
        let (source, output, outcome) = try render(
            OfficePDFPaginatedLayout(paper: .letter, orientation: .landscape))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        XCTAssertEqual(outcome.pageCount, 3)
        XCTAssertEqual(outcome.exceedingPages, 0)
        for size in outcome.pageSizes {
            XCTAssertEqual(size.width, 792, accuracy: 0.01)
            XCTAssertEqual(size.height, 612, accuracy: 0.01)
        }
        let laid = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(laid.pageCount, 3)
        let combined = (0..<laid.pageCount).map { normalized(laid.page(at: $0)?.string ?? "") }
        XCTAssertTrue(combined[0].contains("ALPHATOP") && combined[0].contains("ALPHABOTTOM"))
        XCTAssertTrue(combined[1].contains("BRAVOWIDE"))
        XCTAssertTrue(combined[2].contains("CHARLIEROT"))
        // Source is only read.
        XCTAssertEqual(PDFDocument(url: source)?.pageCount, 3)
    }

    func testPaperOnlyKeepsEachPageOwnAspectOnMixedDeck() throws {
        let (source, _, outcome) = try render(OfficePDFPaginatedLayout(paper: .a4))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        XCTAssertGreaterThan(outcome.pageSizes[0].height, outcome.pageSizes[0].width)
        XCTAssertGreaterThan(outcome.pageSizes[1].width, outcome.pageSizes[1].height)
        XCTAssertGreaterThan(outcome.pageSizes[2].width, outcome.pageSizes[2].height)
        XCTAssertEqual(outcome.exceedingPages, 0)
    }

    func testRotatedSourcePageLandsUprightWithText() throws {
        let (source, output, outcome) = try render(
            OfficePDFPaginatedLayout(paper: .letter, orientation: .portrait))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let a4 = OfficePDFPaginatedLayout.portraitSize(for: .letter)
        XCTAssertEqual(outcome.pageSizes[2].width, a4.width, accuracy: 0.01)
        let laid = try XCTUnwrap(PDFDocument(url: output))
        let page = try XCTUnwrap(laid.page(at: 2))
        XCTAssertEqual(page.rotation, 0)  // rotation baked into upright content
        XCTAssertTrue(normalized(page.string ?? "").contains("CHARLIEROT"))
    }

    func testExplicitActualSizeOverflowsAreCounted() throws {
        let (source, _, outcome) = try render(
            OfficePDFPaginatedLayout(paper: .a4, orientation: .portrait, scale: .actualSize))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        // p1 A4 fits at 100%; p2 Letter (792 wide) and p3 rotated (720 wide)
        // both exceed A4 portrait 595.
        XCTAssertEqual(outcome.exceedingPages, 2)
    }

    func testCancellationRemovesPartialOutputAndKeepsSource() throws {
        let directory = try root()
        let source = directory.appendingPathComponent("source.pdf")
        try makeMixedSource(at: source)
        let output = directory.appendingPathComponent("laid.pdf")
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try OfficePDFPhysicalLayout.apply(
            layout: OfficePDFPaginatedLayout(paper: .a4),
            sourceURL: source, outputURL: output, cancellation: token)) { error in
            XCTAssertTrue(error is FloeError, "cancellation must surface as FloeError.cancelled, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(PDFDocument(url: source)?.pageCount, 3)
        try? FileManager.default.removeItem(at: directory)
    }

    func testNoOverrideExistingAndCorruptInputsAreRefused() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.pdf")
        try makeMixedSource(at: source)
        // Document settings never reach the pass.
        XCTAssertThrowsError(try OfficePDFPhysicalLayout.apply(
            layout: .documentSettings, sourceURL: source,
            outputURL: directory.appendingPathComponent("never.pdf")))
        // Existing output is never overwritten.
        let taken = directory.appendingPathComponent("taken.pdf")
        try Data("%PDF-1.4 stub".utf8).write(to: taken)
        XCTAssertThrowsError(try OfficePDFPhysicalLayout.apply(
            layout: OfficePDFPaginatedLayout(paper: .a4), sourceURL: source, outputURL: taken))
        // Corrupt source is refused without creating output.
        let garbage = directory.appendingPathComponent("garbage.pdf")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: garbage)
        let garbageOut = directory.appendingPathComponent("garbage-out.pdf")
        XCTAssertThrowsError(try OfficePDFPhysicalLayout.apply(
            layout: OfficePDFPaginatedLayout(paper: .a4), sourceURL: garbage, outputURL: garbageOut))
        XCTAssertFalse(FileManager.default.fileExists(atPath: garbageOut.path))
    }

    func testLegalLandscapeBoxesMatchPlanOnEveryAxis() throws {
        let (source, output, outcome) = try render(
            OfficePDFPaginatedLayout(paper: .legal, orientation: .landscape))
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        for size in outcome.pageSizes {
            XCTAssertEqual(size.width, 1008, accuracy: 0.01)
            XCTAssertEqual(size.height, 612, accuracy: 0.01)
        }
        XCTAssertEqual(outcome.pageCount, 3)
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: output)).pageCount, 3)
    }
}
#endif
