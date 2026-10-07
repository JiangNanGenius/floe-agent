// FloeWorkbench — Real image rendering tests (Core Image / ImageIO).
// These exercise actual pixels, not configuration only.

#if canImport(CoreImage)
import Foundation
import Testing
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import FloeCore
@testable import FloeWorkbench

@Suite("Workbench image rendering")
struct WorkbenchImageRendererTests {
    // MARK: Fixtures

    private func makeImage(width: Int, height: Int, color: (CGFloat, CGFloat, CGFloat, CGFloat)) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: color.3))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// JPEG with EXIF orientation 6 (right/top-left): stored 200x100 must
    /// display as 100x200 once orientation is applied.
    private func writeRotatedJPEG(to url: URL) throws {
        let image = makeImage(width: 200, height: 100, color: (1, 0, 0, 1))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: Tests

    @Test func exifOrientationIsAppliedOnDecode() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("rotated.jpg")
        try writeRotatedJPEG(to: url)
        let renderer = WorkbenchImageRenderer()
        let probe = try await renderer.probe(url: url)
        #expect(probe.orientationDegrees == 90)
        let image = try await renderer.loadImage(url: url, maxEdge: nil)
        // Orientation 6 rotates the 200x100 stored JPEG into 100x200 display space.
        #expect(Int(image.extent.width) == 100)
        #expect(Int(image.extent.height) == 200)
    }

    @Test func layersRenderInOrderAndRespectOrderChanges() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseURL = root.appendingPathComponent("base.png")
        let topURL = root.appendingPathComponent("top.png")
        try writePNG(makeImage(width: 100, height: 100, color: (0, 0, 1, 1)), to: baseURL)   // blue
        try writePNG(makeImage(width: 100, height: 100, color: (1, 0, 0, 1)), to: topURL)    // red

        var project = MediaProject(kind: .image, name: "Layers", canvas: MediaCanvas(width: 100, height: 100))
        let base = MediaAssetReference(kind: .image, relativePath: "base.png", originalName: "base.png")
        let top = MediaAssetReference(kind: .image, relativePath: "top.png", originalName: "top.png")
        try MediaTransactions.apply(.addAsset(base), to: &project)
        try MediaTransactions.apply(.addAsset(top), to: &project)
        let baseLayer = ImageLayer(kind: .image, name: "Base", assetID: base.id)
        let topLayer = ImageLayer(kind: .image, name: "Top", assetID: top.id)
        try MediaTransactions.apply(.addImageLayer(baseLayer), to: &project)
        try MediaTransactions.apply(.addImageLayer(topLayer), to: &project)

        let renderer = WorkbenchImageRenderer()
        let resolve: @Sendable (UUID) -> URL? = { id in
            id == base.id ? baseURL : (id == top.id ? topURL : nil)
        }
        let rendered = try await renderer.render(project: project, canvas: CGSize(width: 100, height: 100),
                                                 resolveAsset: resolve)
        let center = pixel(in: rendered, x: 50, y: 50)
        #expect(center.r > 0.9 && center.b < 0.1, "top (red) layer must win at center; got \(center)")

        // Reorder: base on top now renders blue.
        try MediaTransactions.apply(.reorderLayers(orderedIDs: [topLayer.id, baseLayer.id]), to: &project)
        let reordered = try await renderer.render(project: project, canvas: CGSize(width: 100, height: 100),
                                                  resolveAsset: resolve)
        let reorderedCenter = pixel(in: reordered, x: 50, y: 50)
        #expect(reorderedCenter.b > 0.9 && reorderedCenter.r < 0.1,
                "after reorder the base (blue) layer must win; got \(reorderedCenter)")
    }

    @Test func hiddenAndOpacityLayersAffectOutput() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseURL = root.appendingPathComponent("white.png")
        let topURL = root.appendingPathComponent("black.png")
        try writePNG(makeImage(width: 64, height: 64, color: (1, 1, 1, 1)), to: baseURL)
        try writePNG(makeImage(width: 64, height: 64, color: (0, 0, 0, 1)), to: topURL)
        var project = MediaProject(kind: .image, name: "Opacity", canvas: MediaCanvas(width: 64, height: 64))
        let base = MediaAssetReference(kind: .image, relativePath: "white.png", originalName: "white.png")
        let top = MediaAssetReference(kind: .image, relativePath: "black.png", originalName: "black.png")
        try MediaTransactions.apply(.addAsset(base), to: &project)
        try MediaTransactions.apply(.addAsset(top), to: &project)
        let baseLayer = ImageLayer(kind: .image, name: "Base", assetID: base.id)
        let topLayer = ImageLayer(kind: .image, name: "Top", assetID: top.id, opacity: 0.5)
        try MediaTransactions.apply(.addImageLayer(baseLayer), to: &project)
        try MediaTransactions.apply(.addImageLayer(topLayer), to: &project)
        let resolve: @Sendable (UUID) -> URL? = { $0 == base.id ? baseURL : ($0 == top.id ? topURL : nil) }
        let renderer = WorkbenchImageRenderer()
        let blended = try await renderer.render(project: project, canvas: CGSize(width: 64, height: 64),
                                                resolveAsset: resolve)
        let mid = pixel(in: blended, x: 32, y: 32)
        #expect(mid.r > 0.2 && mid.r < 0.8, "50% black over white must be mid-gray; got \(mid)")

        try MediaTransactions.apply(.updateLayer(id: topLayer.id, transform: nil, opacity: nil,
                                                 isHidden: true, isLocked: nil, adjustment: nil, text: nil, crop: .unchanged),
                                    to: &project)
        let hidden = try await renderer.render(project: project, canvas: CGSize(width: 64, height: 64),
                                               resolveAsset: resolve)
        let hiddenPixel = pixel(in: hidden, x: 32, y: 32)
        #expect(hiddenPixel.r > 0.95, "hidden top layer must not render")
    }

    @Test func chineseTextLayerRendersActualGlyphs() async throws {
        var project = MediaProject(kind: .image, name: "Text", canvas: MediaCanvas(width: 320, height: 120))
        let layer = ImageLayer(kind: .text, name: "Title",
                               text: ImageTextContent(text: "弗洛工作台 你好", fontSize: 36, colorHex: "#000000"))
        try MediaTransactions.apply(.addImageLayer(layer), to: &project)
        let renderer = WorkbenchImageRenderer()
        let rendered = try await renderer.render(project: project, canvas: CGSize(width: 320, height: 120),
                                                 resolveAsset: { _ in nil })
        #expect(hasInk(in: rendered), "Chinese text layer must draw actual glyphs")
    }

    @Test func transparencyAndJPEGCombinationIsRejected() async throws {
        var project = MediaProject(kind: .image, name: "Alpha", canvas: MediaCanvas(width: 64, height: 64))
        let layer = ImageLayer(kind: .text, name: "T", text: ImageTextContent(text: "A"))
        try MediaTransactions.apply(.addImageLayer(layer), to: &project)
        #expect(throws: (any Error).self) {
            try MediaExportValidation.validateImage(
                ImageExportOptions(format: .jpeg, preserveTransparency: true),
                canvasSize: CGSizeLike(width: 64, height: 64), hasTransparency: true)
        }
        // PNG + transparency is valid.
        try MediaExportValidation.validateImage(
            ImageExportOptions(format: .png, preserveTransparency: true),
            canvasSize: CGSizeLike(width: 64, height: 64), hasTransparency: true)
        _ = project
    }

    @Test func exportProducesVerifiedFileWithExplicitDimensions() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseURL = root.appendingPathComponent("base.png")
        try writePNG(makeImage(width: 400, height: 200, color: (0.2, 0.8, 0.2, 1)), to: baseURL)
        var project = MediaProject(kind: .image, name: "Export", canvas: MediaCanvas(width: 400, height: 200))
        let asset = MediaAssetReference(kind: .image, relativePath: "base.png", originalName: "base.png")
        try MediaTransactions.apply(.addAsset(asset), to: &project)
        try MediaTransactions.apply(.addImageLayer(ImageLayer(kind: .image, name: "Base", assetID: asset.id)),
                                    to: &project)
        let renderer = WorkbenchImageRenderer()
        let out = root.appendingPathComponent("export.jpg")
        let receipt = try await renderer.exportImage(
            project: project,
            options: ImageExportOptions(format: .jpeg, width: 128, height: 64, quality: 0.8,
                                        preserveTransparency: false, stripMetadata: true, fileName: "export"),
            resolveAsset: { $0 == asset.id ? baseURL : nil },
            destination: out)
        #expect(receipt.width == 128 && receipt.height == 64)
        #expect(FileManager.default.fileExists(atPath: out.path))
        // Reopen verification: format and dimensions.
        let source = CGImageSourceCreateWithURL(out as CFURL, nil)
        let type = try #require(source.flatMap { CGImageSourceGetType($0) } as String?)
        #expect(UTType(type)?.conforms(to: .jpeg) == true)
        let reopened = try #require(source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(reopened.width == 128 && reopened.height == 64)
    }

    @Test func backgroundExportMatchesForegroundRender() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseURL = root.appendingPathComponent("base.png")
        try writePNG(makeImage(width: 120, height: 80, color: (0.9, 0.1, 0.1, 1)), to: baseURL)
        var project = MediaProject(kind: .image, name: "Determinism", canvas: MediaCanvas(width: 120, height: 80))
        let asset = MediaAssetReference(kind: .image, relativePath: "base.png", originalName: "base.png")
        try MediaTransactions.apply(.addAsset(asset), to: &project)
        try MediaTransactions.apply(.addImageLayer(ImageLayer(kind: .image, name: "Base", assetID: asset.id)),
                                    to: &project)
        let renderer = WorkbenchImageRenderer()
        let direct = try await renderer.render(project: project, canvas: CGSize(width: 120, height: 80),
                                               resolveAsset: { $0 == asset.id ? baseURL : nil })
        let out = root.appendingPathComponent("eq.png")
        _ = try await renderer.exportImage(
            project: project,
            options: ImageExportOptions(format: .png, width: 120, height: 80, preserveTransparency: true),
            resolveAsset: { $0 == asset.id ? baseURL : nil },
            destination: out)
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let exported = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let a = pixel(in: direct, x: 60, y: 40)
        let b = pixel(in: exported, x: 60, y: 40)
        #expect(abs(a.r - b.r) < 0.05 && abs(a.g - b.g) < 0.05 && abs(a.b - b.b) < 0.05,
                "export must match the in-app render at the same dimensions")
    }

    @Test("region mask stroke (selection cut) uses displayed-selection semantics: add, subtract, inverted, feather, undo")
    func regionMaskStrokePixels() async throws {
        let renderer = WorkbenchImageRenderer()
        let size = CGSize(width: 100, height: 100)
        let input = CIImage(cgImage: makeImage(width: 100, height: 100, color: (1, 0, 0, 1)))
        func eraseMask(_ selection: ImageSelection) async throws -> CGImage {
            let mask = ImageLayerMask(strokes: [
                ImageMaskStroke(points: [], width: 0, restore: false, region: selection)])
            let image = try await renderer.applyMask(mask, to: input, canvas: size)
            return CIContext().createCGImage(image, from: image.extent)!
        }
        let rect = ImageSelectionShape(kind: .rectangle,
                                       points: [.init(x: 0.25, y: 0.25), .init(x: 0.75, y: 0.75)])
        // Plain replace cut: inside erased, outside kept.
        let cutCG = try await eraseMask(ImageSelection(shapes: [rect]))
        #expect(pixel(in: cutCG, x: 50, y: 50).a < 0.05)
        #expect(pixel(in: cutCG, x: 5, y: 5).a > 0.95)
        #expect(pixel(in: cutCG, x: 5, y: 5).r > 0.9)

        // Overlapping ADD: union is erased — the overlap must NOT become a hole.
        let overlapping = ImageSelection(shapes: [
            rect,
            ImageSelectionShape(kind: .rectangle, operation: .add,
                                points: [.init(x: 0.55, y: 0.55), .init(x: 0.9, y: 0.9)])])
        let addCG = try await eraseMask(overlapping)
        #expect(pixel(in: addCG, x: 65, y: 65).a < 0.05, "added overlap is erased, not a hole")
        #expect(pixel(in: addCG, x: 85, y: 85).a < 0.05, "added region is erased")
        #expect(pixel(in: addCG, x: 10, y: 85).a > 0.95, "outside the union is kept")

        // SUBTRACT: the second rect removes part of the first.
        let subtracting = ImageSelection(shapes: [
            rect,
            ImageSelectionShape(kind: .rectangle, operation: .subtract,
                                points: [.init(x: 0.25, y: 0.25), .init(x: 0.6, y: 0.6)])])
        let subCG = try await eraseMask(subtracting)
        #expect(pixel(in: subCG, x: 40, y: 40).a > 0.95, "subtracted area survives")
        #expect(pixel(in: subCG, x: 70, y: 70).a < 0.05, "remaining area is erased")

        // INVERTED: everything outside the rect is erased, inside kept.
        let inverted = ImageSelection(shapes: [rect], feather: 0, inverted: true)
        let invCG = try await eraseMask(inverted)
        #expect(pixel(in: invCG, x: 50, y: 50).a > 0.95, "inverted keeps the rect")
        #expect(pixel(in: invCG, x: 5, y: 5).a < 0.05, "inverted erases outside")

        // FEATHER: a point well inside is erased; the hard center stays erased.
        let feathered = ImageSelection(shapes: [rect], feather: 0.1)
        let feaCG = try await eraseMask(feathered)
        #expect(pixel(in: feaCG, x: 50, y: 50).a < 0.05, "feathered cut still erases the core")
        #expect(pixel(in: feaCG, x: 5, y: 5).a > 0.95)

        // Restore round-trip: erase then restore returns the original pixels
        // (non-destructive undo semantics).
        let roundTrip = ImageLayerMask(strokes: [
            ImageMaskStroke(points: [], width: 0, restore: false, region: ImageSelection(shapes: [rect])),
            ImageMaskStroke(points: [], width: 0, restore: true, region: ImageSelection(shapes: [rect]))])
        let restoredImage = try await renderer.applyMask(roundTrip, to: input, canvas: size)
        let restoredCG = CIContext().createCGImage(restoredImage, from: restoredImage.extent)!
        #expect(pixel(in: restoredCG, x: 50, y: 50).a > 0.95 && pixel(in: restoredCG, x: 50, y: 50).r > 0.9)

        // Polyline strokes still behave (backward compatibility).
        let polyline = ImageLayerMask(strokes: [
            ImageMaskStroke(points: [.init(x: 0.5, y: 0.2), .init(x: 0.5, y: 0.8)],
                            width: 12, restore: false)])
        let lineImage = try await renderer.applyMask(polyline, to: input, canvas: size)
        let lineCG = CIContext().createCGImage(lineImage, from: lineImage.extent)!
        #expect(pixel(in: lineCG, x: 50, y: 50).a < 0.05)
        #expect(pixel(in: lineCG, x: 5, y: 50).a > 0.95)
    }

    // MARK: Pixel helpers

    private struct Pixel { var r: Double; var g: Double; var b: Double; var a: Double }

    private func pixel(in image: CGImage, x: Int, y: Int) -> Pixel {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Pixel(r: Double(data[0]) / 255, g: Double(data[1]) / 255,
                     b: Double(data[2]) / 255, a: Double(data[3]) / 255)
    }

    private func hasInk(in image: CGImage) -> Bool {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for index in stride(from: 3, to: data.count, by: 4) where data[index] > 16 {
            return true
        }
        return false
    }
}
#endif
