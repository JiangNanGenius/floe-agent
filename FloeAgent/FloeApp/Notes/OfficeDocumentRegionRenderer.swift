// SPDX-License-Identifier: MPL-2.0
// FloeApp — assistant-requested Office document REGION rendering.
//
// This is the build-283 region route for the Notes Office assistant: the
// model deliberately asks for a specific document region (a Word page +
// point rectangle, a PowerPoint slide page + rectangle, or an exact workbook
// sheet + canonical cell range — including content that is offscreen in any
// editor viewport). The pipeline is a REAL rendering path:
//
//   saved CAS resource → verified private copy → service-owned read-only
//   engine session (OfficeAutomaticExecutionGate serialized, hidden window)
//   → real engine PDF export → PDFKitGate + exception-guarded page render
//   → bounded PNG artifact bytes under the existing GeneratedImages
//   namespace → ToolArtifactReference on ToolExecutionOutput.artifacts, so
//   the existing provider vision evidence resolver attaches the actual
//   returned image to the NEXT provider request.
//
// It never moves or screenshots the live editor viewport, never changes the
// user's document, revision, print settings or zoom, and never fabricates
// per-cell pixel geometry: the fit-to-page copy's region→PDF-page/point/
// pixel transform is REPORTED from the actual exported PDF. For workbooks,
// the copy is prepared by `OfficeRegionExport` (FloeDocuments) with a scoped
// `_xlnm.Print_Area` + fitToPage in a private immutable export copy only;
// suppressed other sheets, removed print titles and unknown/oversized
// regions are returned as honest bounds/continuation, never a silent
// cut-off or a wrong-sheet image.
//
// Ownership boundary: this file owns the region READ/RENDER pipeline and its
// scratch/artifact lifecycle. The producer-owned OfficeDocumentCommandTool
// and OfficeDocumentTools are not touched; internal read-evidence renders
// are NOT S3-D outputFiles.

#if canImport(UIKit)
import Foundation
import CoreGraphics
import UIKit
import PDFKit
import FloeCore
import FloeDocuments
import FloeModels
import FloeTools
#if canImport(FloeOfficeNative)
import FloeOfficeNative
#endif

enum OfficeDocumentRegionRenderer {
    // MARK: - Limits (bounded memory / pixels / bytes / time)

    /// Region discovery + render ceiling for one call.
    static let maximumPNGBytes = ProviderImageEvidencePolicy.maximumImageBytes   // 8 MiB decoded, guard-enforced
    static let maximumPixelDimension = 2_400
    static let defaultPixelWidth = 1_400
    static let minimumPixelWidth = 320
    static let maximumExportedPDFBytes = 64 * 1024 * 1024
    /// Discovery lists at most this many pages even when the export has more;
    /// the total is always reported truthfully.
    static let maximumDiscoveredPages = 64
    /// Reject pathological requests before the engine is even touched.
    static let maximumRequestedPoints = 30_000.0

    // MARK: - Requests

    struct Target {
        /// Workbook tab identity: exactly one of `sheetName` / `sheetIndex`
        /// for .xlsx; both nil for Word/PowerPoint.
        var sheetName: String?
        var sheetIndex: Int?
        /// Canonical A1-style bounded range (.xlsx required).
        var cellRange: String?
        /// 0-based page into the ACTUAL PDF print output (Word/PPT; the
        /// rendered page of the workbook copy when its region spans pages).
        var pageIndex: Int?
        /// PDF points rect (cropBox space, y-up from the page bottom-left)
        /// for Word/PPT. Never fabricated for workbook cells: the mapping
        /// reported for a workbook render comes from the real exported page.
        var pointsRect: CGRect?
        var pixelWidth: Int?
    }

    struct Request {
        /// Task-owned staged COPY of the immutable Notes resource, carrying
        /// the validated extension. The renderer never writes to it.
        var stagedCopyURL: URL
        /// Exact resource digest the staged copy was made from.
        var sourceSHA256: String
        var format: OfficeDocumentFormat
        var target: Target
        /// Stable artifact filename identity for diagnostics (not shown bytes).
        var documentID: UUID
    }

    // MARK: - Outcomes

    struct PageGeometry: Encodable, Sendable {
        var pageIndex: Int
        var widthPoints: Double
        var heightPoints: Double
    }

    struct Discovery: Encodable, Sendable {
        var kind: String                    // "workbookSheets" | "printPages"
        var sheets: [OfficeRegionWorkbookSheet]?
        var pages: [PageGeometry]?
        var pageCount: Int?
        var pagesListed: Int?
        var pagesTruncated: Bool?
        var rangeLimits: [String: Int]?
    }

    struct Rendered: Sendable {
        var pngData: Data
        var pixelWidth: Int
        var pixelHeight: Int
        var pageIndex: Int
        var pageCount: Int
        var pageWidthPoints: Double
        var pageHeightPoints: Double
        /// The actual PDF-points rectangle rasterized (clamped to the crop
        /// box; the whole crop box when no rect was requested).
        var renderedRectPoints: CGRect
        /// The requested rect as given (nil for whole-page renders).
        var requestedRectPoints: CGRect?
        /// scale = pixels per PDF point of THIS render.
        var pixelsPerPoint: Double
        var pdfSHA256: String
        var pngSHA256: String
        var printPlan: OfficeRegionPrintPlan?
        var ocrRegions: [VisualTextRegion]
        var ocrError: String?
    }

    enum Outcome: Sendable {
        case discovery(Discovery)
        case rendered(Rendered)
    }

    enum RegionError: LocalizedError {
        case engineUnavailable
        case sheetRequired(String)
        case rangeRequired(String)
        case invalidRegion(String)
        case pageIndexOutOfRange(index: Int, pageCount: Int)
        case rectOutsidePage(requested: String, page: String)
        case renderFailed(String)
        case pngOverBudget(attempt: Int, bytes: Int)

        var errorDescription: String? {
            switch self {
            case .engineUnavailable:
                "The pinned Office engine is not available in this build; region rendering cannot run."
            case .sheetRequired(let available):
                "Workbook region reads need an explicit sheet identity. Available sheets (tab order): \(available). Re-issue with sheet or sheetIndex, or call again without region arguments for discovery."
            case .rangeRequired(let hint):
                "Workbook region reads need a canonical bounded cellRange like \(hint); unknown or missing ranges are refused instead of printing a guessed or whole-sheet area."
            case .invalidRegion(let reason):
                "The requested region is not renderable as given: \(reason)"
            case .pageIndexOutOfRange(let index, let pageCount):
                "Page index \(index) is outside the actual print output (\(pageCount) page(s); valid indices 0…\(max(0, pageCount - 1)))."
            case .rectOutsidePage(let requested, let page):
                "The requested points rect \(requested) does not intersect the actual page \(page)."
            case .renderFailed(let reason):
                "Region rendering failed: \(reason)"
            case .pngOverBudget(let attempt, let bytes):
                "The rendered PNG (\(bytes) bytes at \(attempt) attempt(s)) exceeds the provider image evidence budget; request a smaller range, page or pixelWidth."
            }
        }
    }

    // MARK: - Entry point

    /// Executes discovery or one bounded region render. `discoveryOnly`
    /// returns real page/sheet identity without PNG output.
    static func execute(request: Request, discoveryOnly: Bool) async throws -> Outcome {
        #if canImport(FloeOfficeNative) && canImport(WebKit)
        try await executeNative(request: request, discoveryOnly: discoveryOnly)
        #else
        throw RegionError.engineUnavailable
        #endif
    }

    #if canImport(FloeOfficeNative) && canImport(WebKit)
    private static func executeNative(request: Request, discoveryOnly: Bool) async throws -> Outcome {
        let ownedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-office-region-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: ownedDirectory) }

        switch request.format {
        case .xlsx:
            return try await executeWorkbook(request: request, ownedDirectory: ownedDirectory,
                                             discoveryOnly: discoveryOnly)
        case .docx, .pptx:
            return try await executePaginated(request: request, ownedDirectory: ownedDirectory,
                                              discoveryOnly: discoveryOnly)
        }
    }

    /// Word/PowerPoint: the saved resource exports to its ACTUAL print
    /// output; page selection is against that real PDF, crop happens in PDF
    /// points. Offscreen content is inherent — the engine lays out the whole
    /// document from the saved bytes, independent of any editor viewport.
    private static func executePaginated(request: Request, ownedDirectory: URL,
                                         discoveryOnly: Bool) async throws -> Outcome {
        if !discoveryOnly, request.target.cellRange != nil {
            throw RegionError.invalidRegion(
                "cellRange is a workbook argument; \(request.format.rawValue) region reads select pageIndex and an optional pointsRect instead")
        }
        if request.target.sheetName != nil || request.target.sheetIndex != nil {
            throw RegionError.invalidRegion(
                "sheet identity is a workbook argument; \(request.format.rawValue) region reads select pageIndex (and optionally pointsRect)")
        }
        guard request.sourceSHA256.count == 64 else { throw RegionError.renderFailed("source identity is not a validated digest") }
        let pdfURL = try await OfficeIsolatedPDFExport.run(sourceURL: request.stagedCopyURL,
                                                           format: request.format,
                                                           ownedDirectory: ownedDirectory,
                                                           cancellation: nil)
        guard request.format == .docx || request.format == .pptx else {
            throw RegionError.invalidRegion("unsupported paginated format")
        }
        if discoveryOnly {
            let pages = try await Task.detached(priority: .userInitiated) {
                try pageGeometries(ofPDFAt: pdfURL)
            }.value
            let listed = pages.prefix(maximumDiscoveredPages)
            return .discovery(Discovery(kind: "printPages", sheets: nil,
                                         pages: Array(listed), pageCount: pages.count,
                                         pagesListed: listed.count,
                                         pagesTruncated: pages.count > listed.count,
                                         rangeLimits: nil))
        }
        let pageIndex = request.target.pageIndex ?? 0
        let rendered = try await Task.detached(priority: .userInitiated) {
            try render(pdfURL: pdfURL, pageIndex: pageIndex, rect: request.target.pointsRect,
                       pixelWidth: request.target.pixelWidth ?? defaultPixelWidth)
        }.value
        return .rendered(rendered)
    }

    /// Excel: explicit sheet identity + canonical bounded cellRange. The
    /// engine renders a PRIVATE print-area copy only; the source package's
    /// own print settings and other sheets are untouched.
    private static func executeWorkbook(request: Request, ownedDirectory: URL,
                                        discoveryOnly: Bool) async throws -> Outcome {
        guard request.sourceSHA256.count == 64 else { throw RegionError.renderFailed("source identity is not a validated digest") }
        let sheets = try OfficeRegionExport.workbookSheets(sourceURL: request.stagedCopyURL,
                                                           expectedSHA256: request.sourceSHA256)
        if discoveryOnly {
            if request.target.cellRange != nil || request.target.pointsRect != nil {
                throw RegionError.invalidRegion(
                    "discovery takes no region arguments; re-issue without cellRange/pointsRect to render, or with them once the sheet list is known")
            }
            return .discovery(Discovery(kind: "workbookSheets", sheets: sheets,
                                        pages: nil, pageCount: nil, pagesListed: nil,
                                        pagesTruncated: nil,
                                        rangeLimits: [
                                            "maximumColumns": OfficeRegionExport.maximumRangeColumns,
                                            "maximumRows": OfficeRegionExport.maximumRangeRows,
                                            "maximumCells": OfficeRegionExport.maximumRangeCells,
                                        ]))
        }
        if request.target.pointsRect != nil {
            throw RegionError.invalidRegion(
                "pointsRect is a Word/PowerPoint argument; workbook regions select sheet + cellRange, and the returned page mapping is reported from the actual export")
        }
        let target = request.target
        if target.sheetName == nil, target.sheetIndex == nil {
            let available = sheets.map(\.name).joined(separator: ", ")
            throw RegionError.sheetRequired(available.isEmpty ? "(none resolvable)" : available)
        }
        guard let cellRange = target.cellRange, !cellRange.isEmpty else {
            throw RegionError.rangeRequired("A1:N30")
        }
        // The print-area COPY is prepared in the task-owned directory; the
        // engine opens the copy, never the Notes resource or the staged copy.
        let copyURL = ownedDirectory.appendingPathComponent("region-copy.xlsx")
        let plan: OfficeRegionPrintPlan
        do {
            let prepared = try OfficeRegionExport.preparePrintAreaCopy(
                sourceURL: request.stagedCopyURL,
                destinationURL: copyURL,
                expectedSHA256: request.sourceSHA256,
                sheetIndex: target.sheetIndex,
                sheetName: target.sheetName,
                cellRange: cellRange)
            plan = prepared.plan
        } catch let error as OfficeRegionExportError {
            throw RegionError.invalidRegion(error.localizedDescription)
        }
        let pdfURL = try await OfficeIsolatedPDFExport.run(sourceURL: copyURL,
                                                           format: .xlsx,
                                                           ownedDirectory: ownedDirectory,
                                                           cancellation: nil)
        let pageIndex = target.pageIndex ?? 0
        let rendered: Rendered
        do {
            rendered = try await Task.detached(priority: .userInitiated) {
                var value = try render(pdfURL: pdfURL, pageIndex: pageIndex, rect: nil,
                                       pixelWidth: target.pixelWidth ?? defaultPixelWidth)
                value.printPlan = plan
                return value
            }.value
        } catch let error as RegionError {
            // A single-sheet print area normally fits one page; if the real
            // engine output spanned more (or none), the honest bounds are
            // reported from the actual PDF, never a silent crop claim.
            throw error
        } catch {
            throw RegionError.renderFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        return .rendered(rendered)
    }

    // MARK: - PDFKit render (gate + exception guarded)

    private static func pageGeometries(ofPDFAt url: URL) throws -> [PageGeometry] {
        try PDFKitGate.run {
            try withPDFExceptionGuard {
                guard let document = PDFDocument(url: url), !document.isLocked,
                      document.pageCount > 0 else {
                    throw RegionError.renderFailed("the exported PDF did not open as a readable document")
                }
                return (0..<document.pageCount).compactMap { index -> PageGeometry? in
                    guard let page = document.page(at: index) else { return nil }
                    let bounds = page.bounds(for: .cropBox)
                    guard bounds.width.isFinite, bounds.height.isFinite,
                          bounds.width > 0, bounds.height > 0 else { return nil }
                    return PageGeometry(pageIndex: index,
                                        widthPoints: Double(bounds.width),
                                        heightPoints: Double(bounds.height))
                }
            }
        }
    }

    /// Rasters ONE page of the real exported PDF into a bounded PNG. The
    /// reported geometry is the actual cropBox intersect of the requested
    /// rect — if the request was clamped, the response says so.
    private static func render(pdfURL: URL, pageIndex: Int, rect: CGRect?,
                               pixelWidth: Int) throws -> Rendered {
        let pixelWidth = min(max(pixelWidth, minimumPixelWidth), maximumPixelDimension)
        var attempt = 0
        var effectiveWidth = pixelWidth
        while true {
            attempt += 1
            let result: Rendered = try PDFKitGate.run {
                try withPDFExceptionGuard {
                    guard let document = PDFDocument(url: pdfURL), !document.isLocked,
                          document.pageCount > 0 else {
                        throw RegionError.renderFailed("the exported PDF did not open as a readable document")
                    }
                    let pageCount = document.pageCount
                    guard pageIndex >= 0, pageIndex < pageCount else {
                        throw RegionError.pageIndexOutOfRange(index: pageIndex, pageCount: pageCount)
                    }
                    guard let page = document.page(at: pageIndex) else {
                        throw RegionError.renderFailed("the exported PDF has no page at index \(pageIndex)")
                    }
                    let crop = page.bounds(for: .cropBox)
                    guard crop.width.isFinite, crop.height.isFinite,
                          crop.width > 0, crop.height > 0,
                          crop.width <= maximumRequestedPoints,
                          crop.height <= maximumRequestedPoints else {
                        throw RegionError.renderFailed("the exported page bounds are not usable")
                    }
                    var target = crop
                    var requestedRect: CGRect?
                    if let rect {
                        guard rect.width.isFinite, rect.height.isFinite,
                              rect.minX.isFinite, rect.minY.isFinite,
                              rect.width > 0, rect.height > 0,
                              rect.width <= maximumRequestedPoints,
                              rect.height <= maximumRequestedPoints else {
                            throw RegionError.invalidRegion("pointsRect must be finite and positive")
                        }
                        requestedRect = rect
                        let intersect = rect.intersection(crop)
                        guard !intersect.isNull, intersect.width > 0.5, intersect.height > 0.5 else {
                            throw RegionError.rectOutsidePage(
                                requested: "\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height))",
                                page: "0,0 \(Int(crop.width))x\(Int(crop.height))")
                        }
                        target = intersect
                    }
                    var scale = Double(effectiveWidth) / Double(target.width)
                    let heightPixels = Double(target.height) * scale
                    if heightPixels > Double(maximumPixelDimension) {
                        scale = Double(maximumPixelDimension) / Double(target.height)
                    }
                    let pixelW = max(1, min(maximumPixelDimension, Int((target.width * scale).rounded())))
                    let pixelH = max(1, min(maximumPixelDimension, Int((target.height * scale).rounded())))
                    guard let context = CGContext(data: nil, width: pixelW, height: pixelH,
                                                  bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                                    | CGBitmapInfo.byteOrder32Big.rawValue) else {
                        throw RegionError.renderFailed("could not allocate the render context")
                    }
                    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
                    context.translateBy(x: 0, y: CGFloat(pixelH))
                    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
                    context.translateBy(x: -target.minX, y: -target.minY)
                    page.draw(with: .cropBox, to: context)
                    guard let cg = context.makeImage() else {
                        throw RegionError.renderFailed("the renderer produced no image")
                    }
                    let image = UIImage(cgImage: cg)
                    guard let png = image.pngData() else {
                        throw RegionError.renderFailed("the rendered image could not be encoded as PNG")
                    }
                    return Rendered(pngData: png, pixelWidth: pixelW, pixelHeight: pixelH,
                                    pageIndex: pageIndex, pageCount: pageCount,
                                    pageWidthPoints: Double(crop.width),
                                    pageHeightPoints: Double(crop.height),
                                    renderedRectPoints: target,
                                    requestedRectPoints: requestedRect,
                                    pixelsPerPoint: scale,
                                    pdfSHA256: "", pngSHA256: "",
                                    printPlan: nil, ocrRegions: [], ocrError: nil)
                }
            }
            if result.pngData.count <= maximumPNGBytes {
                var final = result
                let pdfDigest = (try? FloeDigest.sha256Hex(ofFileAt: pdfURL)) ?? ""
                final.pdfSHA256 = pdfDigest
                final.pngSHA256 = FloeDigest.sha256Hex(final.pngData)
                // Auxiliary on-device OCR ONLY: the image itself is the
                // evidence; OCR can misread handwriting and proves nothing.
                do {
                    final.ocrRegions = try VisualTextRecognizer.recognize(
                        imageData: final.pngData,
                        pixelWidth: final.pixelWidth, pixelHeight: final.pixelHeight,
                        referencePrefix: "region", limit: 60)
                } catch {
                    final.ocrError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
                return final
            }
            if attempt >= 3 {
                throw RegionError.pngOverBudget(attempt: attempt, bytes: result.pngData.count)
            }
            effectiveWidth = max(minimumPixelWidth, effectiveWidth * 3 / 4)
        }
    }
    #endif
}

/// Bounded writer for region read-evidence PNGs. Uses the EXISTING
/// `GeneratedImages` artifact namespace that the runtime's provider vision
/// evidence resolver already authorizes (containment + MIME sniff + SHA-256
/// + byte budget re-checked there); these are internal read evidence, never
/// S3-D outputFiles or user deliverables, and no new storage authority is
/// introduced. Cleanup only ever touches files matching this lane's own
/// prefix: on normal operation the freshest bounded window of our artifacts
/// is retained (the provider reads them asynchronously after the tool
/// result settles), older ones are removed. A render whose result never
/// reaches the artifact step is cleaned by the caller explicitly.
enum OfficeRegionArtifactStore {
    static let namespace = "GeneratedImages"
    static let filePrefix = "office-region-"
    static let retainedArtifacts = 64
    static let maximumArtifactAge: TimeInterval = 24 * 60 * 60

    private static func directory() throws -> URL {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else {
            throw OfficeDocumentRegionRenderer.RegionError.renderFailed(
                "application storage is unavailable for region artifacts")
        }
        let directory = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func write(pngData: Data) throws -> ToolArtifactReference {
        guard pngData.count > 0,
              pngData.count <= OfficeDocumentRegionRenderer.maximumPNGBytes else {
            throw OfficeDocumentRegionRenderer.RegionError.pngOverBudget(
                attempt: 1, bytes: pngData.count)
        }
        let directory = try directory()
        cleanup(directory: directory)
        let id = UUID()
        let name = "\(filePrefix)\(id.uuidString).png"
        try pngData.write(to: directory.appendingPathComponent(name), options: .atomic)
        return ToolArtifactReference(id: id,
                                     relativePath: "\(namespace)/\(name)",
                                     mimeType: "image/png",
                                     byteCount: pngData.count,
                                     sha256: FloeDigest.sha256Hex(pngData))
    }

    /// Removes ONE owned artifact (used when a result is discarded by a
    /// post-render fence). Silent: the file may already be gone.
    static func remove(_ reference: ToolArtifactReference) {
        guard reference.relativePath.hasPrefix("\(namespace)/\(filePrefix)"),
              let support = try? FileManager.default.url(
                  for: .applicationSupportDirectory, in: .userDomainMask,
                  appropriateFor: nil, create: false) else { return }
        try? FileManager.default.removeItem(
            at: support.appendingPathComponent("FloeAgent", isDirectory: true)
                .appendingPathComponent(reference.relativePath))
    }

    private static func cleanup(directory: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }
        var owned: [(name: String, modified: Date, size: Int)] = []
        for name in names where name.hasPrefix(filePrefix) && name.hasSuffix(".png") {
            let url = directory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let modified = values?.contentModificationDate ?? Date.distantPast
            owned.append((name, modified, values?.fileSize ?? 0))
        }
        let now = Date()
        var removed = 0
        // Age band first, then keep only the freshest window by count.
        for entry in owned.sorted(by: { $0.modified < $1.modified }) {
            if now.timeIntervalSince(entry.modified) > maximumArtifactAge {
                try? manager.removeItem(at: directory.appendingPathComponent(entry.name))
                removed += 1
            }
        }
        let survivors = owned.count - removed
        if survivors > retainedArtifacts {
            let fresh = owned.filter { now.timeIntervalSince($0.modified) <= maximumArtifactAge }
                .sorted { $0.modified > $1.modified }
            for entry in fresh.dropFirst(retainedArtifacts) {
                try? manager.removeItem(at: directory.appendingPathComponent(entry.name))
            }
        }
    }
}
#endif
