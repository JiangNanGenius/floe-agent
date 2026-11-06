// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FloeCanvasCore
import FloeDiagramCore
import FloeDiagramExchange

/// Native PDF / PNG / SVG export for canvas pages. Renders the real node
/// content (Unicode text, rich runs, tables, code, formulas, media and PDF
/// page crops, shapes, regions, arrows with labels, freehand strokes and
/// PKDrawing ink) — never blank rectangles sold as rich export.
///
/// Reuse: colors and image thumbnailing come from the public DiagramKit
/// surface (`DiagramPalette`, `DiagramNativeExporter.rasterImagePNG`),
/// PencilKit rasterization from `DiagramNativeInk` (world-space bounds).
public enum CanvasNativeExporter {
    public static func previewThumbnailPNG(_ data: Data) throws -> Data {
        try DiagramNativeExporter.rasterImagePNG(data)
    }

    // MARK: PNG

    public struct RasterOptions: Sendable {
        public var scope: CanvasExportScope
        public var regionPresentation: CanvasCollapsedRegionPresentation
        public var appearance: CanvasRenderAppearance
        public var assetResolver: (any CanvasAssetResolver)?
        public init(scope: CanvasExportScope = .wholePage, regionPresentation: CanvasCollapsedRegionPresentation = .chip, appearance: CanvasRenderAppearance = .light, assetResolver: (any CanvasAssetResolver)? = nil) {
            self.scope = scope
            self.regionPresentation = regionPresentation
            self.appearance = appearance
            self.assetResolver = assetResolver
        }
    }

    @MainActor
    public static func png(snapshot: CanvasSnapshot, pageID: UUID? = nil, options: RasterOptions = RasterOptions()) async throws -> CanvasExchangeOutput {
        guard let page = snapshot.pages.first(where: { $0.id == pageID }) ?? (pageID == nil ? snapshot.selectedPage ?? snapshot.pages.first : nil) else {
            throw CanvasExchangeError.invalid("page \(pageID?.uuidString ?? "selected") not found")
        }
        let layout = try CanvasPageRenderer.layout(page: page, snapshot: snapshot, scope: options.scope, regionPresentation: options.regionPresentation)
        let width = layout.bounds.maxX - layout.bounds.minX
        let height = layout.bounds.maxY - layout.bounds.minY
        let scale = min(2, Double(CanvasExchangeLimits.maxRasterDimension) / max(width, height), sqrt(Double(CanvasExchangeLimits.maxRasterPixels) / (width * height)))
        let pixelWidth = max(1, Int(ceil(width * scale)))
        let pixelHeight = max(1, Int(ceil(height * scale)))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CanvasExchangeError.io("PNG bitmap context")
        }
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -layout.bounds.minX, y: -layout.bounds.minY)
        var issues = try await CanvasPageDrawer.draw(layout: layout, snapshot: snapshot, appearance: options.appearance, resolver: options.assetResolver, in: context)
        if scale < 1 {
            issues.append(.init("rasterScaleReduced", "PNG resolution is bounded to \(CanvasExchangeLimits.maxRasterDimension) pixels and \(CanvasExchangeLimits.maxRasterPixels) pixels total; use PDF/SVG for large canvases", contentClass: "archive", severity: .preserved))
        }
        guard let image = context.makeImage() else {
            throw CanvasExchangeError.io("PNG image encoding")
        }
        let data = try encodePNG(image)
        return CanvasExchangeOutput(files: [CanvasExchangeFile(name: CanvasExchangeFilename.sanitized("\(snapshot.name)-\(page.name)", extension: "png", fallback: "page"), data: data)], issues: issues)
    }

    static func encodePNG(_ image: CGImage) throws -> Data {
        let storage = CFDataCreateMutable(kCFAllocatorDefault, 0)!
        guard let destination = CGImageDestinationCreateWithData(storage, UTType.png.identifier as CFString, 1, nil) else {
            throw CanvasExchangeError.io("PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CanvasExchangeError.io("PNG encoding")
        }
        return storage as Data
    }

    // MARK: PDF

    public struct PDFOptions: Sendable {
        public var scope: CanvasExportScope
        public var regionPresentation: CanvasCollapsedRegionPresentation
        public var appearance: CanvasRenderAppearance
        public var assetResolver: (any CanvasAssetResolver)?
        /// Pages to export; nil exports every page (multipage PDF).
        public var pageIDs: [UUID]?
        public init(scope: CanvasExportScope = .wholePage, regionPresentation: CanvasCollapsedRegionPresentation = .chip, appearance: CanvasRenderAppearance = .light, assetResolver: (any CanvasAssetResolver)? = nil, pageIDs: [UUID]? = nil) {
            self.scope = scope
            self.regionPresentation = regionPresentation
            self.appearance = appearance
            self.assetResolver = assetResolver
            self.pageIDs = pageIDs
        }
    }

    @MainActor
    public static func pdf(snapshot: CanvasSnapshot, options: PDFOptions = PDFOptions()) async throws -> CanvasExchangeOutput {
        let pages = options.pageIDs.map { ids in snapshot.pages.filter { ids.contains($0.id) } } ?? snapshot.pages
        guard !pages.isEmpty else {
            throw CanvasExchangeError.invalid("no pages selected for PDF export")
        }
        let storage = CFDataCreateMutable(kCFAllocatorDefault, 0)!
        guard let consumer = CGDataConsumer(data: storage), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw CanvasExchangeError.io("PDF context")
        }
        var allIssues: [CanvasExchangeIssue] = []
        for page in pages {
            try Task.checkCancellation()
            let layout = try CanvasPageRenderer.layout(page: page, snapshot: snapshot, scope: options.scope, regionPresentation: options.regionPresentation)
            let width = layout.bounds.maxX - layout.bounds.minX
            let height = layout.bounds.maxY - layout.bounds.minY
            var rect = CGRect(x: 0, y: 0, width: width, height: height)
            let box = NSData(bytes: &rect, length: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
            context.saveGState()
            context.translateBy(x: 0, y: height)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -layout.bounds.minX, y: -layout.bounds.minY)
            let issues = try await CanvasPageDrawer.draw(layout: layout, snapshot: snapshot, appearance: options.appearance, resolver: options.assetResolver, in: context)
            allIssues.append(contentsOf: issues)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return CanvasExchangeOutput(
            files: [CanvasExchangeFile(name: CanvasExchangeFilename.sanitized(snapshot.name, extension: "pdf"), data: storage as Data)],
            issues: allIssues
        )
    }

    // MARK: PDF page crop helper (real PDF content where bytes are available)

    @MainActor
    static func drawPDFCrop(bytes: Data, pageRange: ClosedRange<Int>?, rect: CGRect, context: CGContext) -> Bool {
        guard !bytes.isEmpty,
              let provider = CGDataProvider(data: bytes as CFData),
              let document = CGPDFDocument(provider) else { return false }
        let first = max(1, pageRange?.lowerBound ?? 1)
        guard first <= document.numberOfPages, let page = document.page(at: first) else { return false }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return false }
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / box.width, y: rect.height / box.height)
        context.drawPDFPage(page)
        context.restoreGState()
        return true
    }
}
