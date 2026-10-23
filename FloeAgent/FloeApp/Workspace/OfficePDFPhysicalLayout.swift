// SPDX-License-Identifier: MPL-2.0
// FloeApp — physical print layout for generated Word/Presentation PDFs.
//
// The shared export runs the existing guarded isolated engine export first;
// this pass then re-lays the GENERATED PDF's pages on the requested paper
// through one bounded, exception-guarded PDFKit/CoreGraphics operation,
// exactly mirroring `OfficePDFPageSelection`'s discipline:
//
//  * every PDFKit touch runs inside `PDFKitGate.run` + `withPDFExceptionGuard`
//    (no new unguarded PDFKit path);
//  * the source PDF is only read — its bytes are never rewritten, and the
//    Office package was already digest-verified by the caller;
//  * output goes to a caller-supplied, never-existing path in the same
//    task-owned directory; on ANY failure the partial output is removed and
//    the caller's original produced PDF stays untouched;
//  * after writing, the result is REOPENED and verified: page count 1:1,
//    every final crop box measured against the planned paper box (±0.01 pt),
//    and every page's extracted text compared to the source page's text —
//    nonempty source text that disappears or changes proves the layout
//    failed; the reported facts are these measurements, never the request.
//
// Drawing semantics that make this truthful (PDFKit/CoreGraphics public
// contracts): `CGPDFPageGetDrawingTransform(.cropBox,…)` maps the page's
// crop∩media box rotated according to its `/Rotate` entry, centred on the
// destination rect. The pass therefore bakes the source page's own rotation
// into an upright output page, replays the content as vector drawing
// operations (`CGContextDrawPDFPage` into a PDF context), and centres the
// page's complete rendered area inside the new paper box at the scale
// computed by `OfficePDFPaginatedLayout` — a `fitWholePage` request can
// never clip, while an explicit `actualSize`/`percent` that exceeds the
// paper is counted and reported, not silently re-fitted.
//
// Boundary: this re-lays PRINT output. It does not reflow Word text, does
// not restyle slides and carries no annotations/widgets (the isolated
// engine's print output is flat content).
#if canImport(PDFKit) && canImport(CoreGraphics)
import Foundation
import CoreGraphics
import PDFKit
#if canImport(FloeCore)
import FloeCore
#endif
#if canImport(FloeTools)
import FloeTools
#endif
#if canImport(FloeDocuments)
import FloeDocuments
#endif

enum OfficePDFPhysicalLayout {
    struct Outcome: Sendable, Equatable {
        var pageCount: Int
        /// Final cropBox size of every page, measured after reopening.
        var pageSizes: [CGSize]
        /// Pages whose explicitly scaled content is larger than the paper
        /// (0 for any `fitWholePage` request).
        var exceedingPages: Int
    }

    enum LayoutError: LocalizedError, Sendable, Equatable {
        case sourceUnreadable
        case implausiblePageCount(Int)
        case invalidGeometry(page: Int, reason: String)
        case contentLost(page: Int)
        case writeFailed
        case verificationFailed(reason: String)
        case outputExists

        var errorDescription: String? {
            switch self {
            case .sourceUnreadable:
                "The generated PDF could not be opened for print layout."
            case .implausiblePageCount(let count):
                "The generated PDF has an implausible page count (\(count))."
            case .invalidGeometry(let page, let reason):
                "Page \(page) has unusable geometry for print layout (\(reason))."
            case .contentLost(let page):
                "Page \(page) lost rendered content during print layout; nothing was kept."
            case .writeFailed:
                "The laid-out PDF could not be written."
            case .verificationFailed(let reason):
                "The laid-out PDF failed verification (\(reason))."
            case .outputExists:
                "The print-layout output already exists and is never overwritten."
            }
        }
    }

    /// Same per-page bound `OfficePDFPageSelection` validates with.
    static let maximumPagePoints: CGFloat = 200_000
    /// Mirrors `OfficePDFExportService.maximumResultPages`; the shared
    /// validator re-checks the final file against its own bound anyway.
    static let maximumPages = 20_000

    /// Applies `layout` to the pages of `sourceURL`, writing one new PDF to
    /// `outputURL`. Synchronous; the caller owns both URLs and the cleanup
    /// policy of its directory. Throws without leaving a partial output.
    /// `cancellation` is checked before, INSIDE the per-page render loop and
    /// again inside the verification loop, so a cancelled large export
    /// releases promptly (the `defer` removes the partial file on every
    /// throw, including `FloeError.cancelled`).
    static func apply(layout: OfficePDFPaginatedLayout,
                      sourceURL: URL,
                      outputURL: URL,
                      cancellation: CancellationToken? = nil) throws -> Outcome {
        try PDFKitGate.run {
            try withPDFExceptionGuard {
                try applyGuarded(layout: layout,
                                 sourceURL: sourceURL,
                                 outputURL: outputURL,
                                 cancellation: cancellation)
            }
        }
    }

    private static func checkCancellation(_ cancellation: CancellationToken?) throws {
        if cancellation?.isCancelled == true || Task.isCancelled { throw FloeError.cancelled }
    }

    private static func applyGuarded(layout: OfficePDFPaginatedLayout,
                                     sourceURL: URL,
                                     outputURL: URL,
                                     cancellation: CancellationToken?) throws -> Outcome {
        try checkCancellation(cancellation)
        guard layout.hasOverrides else {
            // Document settings must keep the existing route untouched; this
            // pass is only ever entered for real overrides.
            throw LayoutError.verificationFailed(reason: "no-overrides-requested")
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw LayoutError.outputExists
        }
        guard let sourceDocument = PDFDocument(url: sourceURL),
              !sourceDocument.isLocked else {
            throw LayoutError.sourceUnreadable
        }
        let pageCount = sourceDocument.pageCount
        guard pageCount > 0 else { throw LayoutError.sourceUnreadable }
        guard pageCount <= maximumPages else {
            throw LayoutError.implausiblePageCount(pageCount)
        }
        guard let cgSource = CGPDFDocument(sourceURL as CFURL) else {
            throw LayoutError.sourceUnreadable
        }
        guard let writer = CGContext(outputURL as CFURL, mediaBox: nil, nil) else {
            throw LayoutError.writeFailed
        }
        var closed = false
        var verified = false
        defer {
            if !closed { writer.closePDF() }
            // A failed pass never keeps a partial PDF; the caller's
            // original produced file stays untouched for its own
            // error-path rules.
            if !verified { try? FileManager.default.removeItem(at: outputURL) }
        }

        var plannedSizes: [CGSize] = []
        plannedSizes.reserveCapacity(pageCount)
        var sourceTexts: [String] = []
        sourceTexts.reserveCapacity(pageCount)
        // Text retention is required only where the page fits the paper. An
        // explicit actual-size/percent choice that deliberately overflows is
        // counted and left clipped (that is the user's own chosen operation,
        // matching the preview), never reported as content lost.
        var retainText: [Bool] = []
        retainText.reserveCapacity(pageCount)
        var exceeding = 0

        for index in 0..<pageCount {
            try checkCancellation(cancellation)
            guard let pdfPage = sourceDocument.page(at: index),
                  let cgPage = cgSource.page(at: index + 1) else {
                throw LayoutError.invalidGeometry(page: index + 1, reason: "missing-page")
            }
            let crop = cgPage.getBoxRect(.cropBox)
            let media = cgPage.getBoxRect(.mediaBox)
            let effective = crop.intersection(media)
            guard !crop.isNull, !media.isNull,
                  !effective.isNull, !effective.isEmpty,
                  effective.width.isFinite, effective.height.isFinite,
                  effective.width > 0, effective.height > 0,
                  effective.width <= maximumPagePoints,
                  effective.height <= maximumPagePoints else {
                throw LayoutError.invalidGeometry(page: index + 1, reason: "invalid-box")
            }
            let angle = normalizeAngle(cgPage.rotationAngle)
            let displaySize = angle == 90 || angle == 270
                ? CGSize(width: effective.height, height: effective.width)
                : CGSize(width: effective.width, height: effective.height)
            let placement = layout.placement(forSourceDisplaySize: displaySize)
            guard placement.targetSize.width.isFinite, placement.targetSize.height.isFinite,
                  placement.targetSize.width > 0, placement.targetSize.height > 0,
                  placement.targetSize.width <= maximumPagePoints,
                  placement.targetSize.height <= maximumPagePoints,
                  placement.scaleFactor.isFinite, placement.scaleFactor > 0 else {
                throw LayoutError.invalidGeometry(page: index + 1, reason: "invalid-target")
            }
            if placement.contentExceedsPaper { exceeding += 1 }
            plannedSizes.append(placement.targetSize)
            sourceTexts.append(normalizedText(pdfPage.string ?? ""))
            retainText.append(!placement.contentExceedsPaper)

            var box = CGRect(origin: .zero, size: placement.targetSize)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            writer.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            writer.setFillColor(CGColor(gray: 1, alpha: 1))
            writer.fill(box)
            writer.saveGState()
            writer.translateBy(x: placement.contentOrigin.x, y: placement.contentOrigin.y)
            writer.scaleBy(x: placement.scaleFactor, y: placement.scaleFactor)
            let fit = cgPage.getDrawingTransform(
                .cropBox, rect: CGRect(origin: .zero, size: displaySize),
                rotate: 0, preserveAspectRatio: true)
            guard fit.a.isFinite, fit.d.isFinite, fit.tx.isFinite, fit.ty.isFinite else {
                writer.restoreGState()
                writer.endPDFPage()
                throw LayoutError.invalidGeometry(page: index + 1,
                                                  reason: "unusable-drawing-transform")
            }
            writer.concatenate(fit)
            writer.drawPDFPage(cgPage)
            writer.restoreGState()
            writer.endPDFPage()
        }
        writer.closePDF()
        closed = true

        guard let laid = PDFDocument(url: outputURL), !laid.isLocked else {
            throw LayoutError.verificationFailed(reason: "reopen")
        }
        guard laid.pageCount == pageCount else {
            throw LayoutError.verificationFailed(
                reason: "page-count \(laid.pageCount) != \(pageCount)")
        }
        var measured: [CGSize] = []
        measured.reserveCapacity(pageCount)
        for index in 0..<pageCount {
            try checkCancellation(cancellation)
            guard let laidPage = laid.page(at: index) else {
                throw LayoutError.verificationFailed(reason: "missing-page")
            }
            let box = laidPage.bounds(for: .cropBox)
            let planned = plannedSizes[index]
            guard abs(box.width - planned.width) < 0.01,
                  abs(box.height - planned.height) < 0.01,
                  abs(box.minX) < 0.01, abs(box.minY) < 0.01 else {
                throw LayoutError.verificationFailed(
                    reason: "page \(index + 1) measured \(Int(box.width))x\(Int(box.height))pt, planned \(Int(planned.width))x\(Int(planned.height))pt")
            }
            measured.append(CGSize(width: box.width, height: box.height))
            let laidText = normalizedText(laidPage.string ?? "")
            // Content retention: any text the source page carried must be
            // present, in the same order, on the laid-out page — for every
            // page that fits the paper. A page an explicit scale chose to
            // overflow is legitimately clipped and reported by exceedingPages,
            // so its (partly clipped) text is not re-checked here.
            if retainText[index], !sourceTexts[index].isEmpty,
               laidText != sourceTexts[index] {
                throw LayoutError.contentLost(page: index + 1)
            }
        }
        verified = true
        return Outcome(pageCount: pageCount, pageSizes: measured,
                       exceedingPages: exceeding)
    }

    private static func normalizeAngle(_ angle: Int32) -> Int {
        let value = Int(angle) % 360
        return value < 0 ? value + 360 : value
    }

    private static func normalizedText(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).joined()
    }
}
#endif
