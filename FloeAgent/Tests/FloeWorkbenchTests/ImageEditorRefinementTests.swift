// FloeWorkbench — Image editor refinement tests (Build265).
// Real pixels for masks, selections, fills, flips, adjustments and typography.

#if canImport(CoreImage)
import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FloeCore
@testable import FloeWorkbench

@Suite("Image editor refinements")
struct ImageEditorRefinementTests {
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

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Reads one RGBA pixel from a top-leading coordinate.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let row = image.height - 1 - y
        let offset = (row * image.width + x) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    private func blueProject(root: URL) throws -> MediaProject {
        let url = root.appendingPathComponent("base.png")
        try writePNG(makeImage(width: 100, height: 100, color: (0, 0, 1, 1)), to: url)
        var project = MediaProject(kind: .image, name: "Refine", canvas: MediaCanvas(width: 100, height: 100))
        let asset = MediaAssetReference(kind: .image, relativePath: "base.png", originalName: "base.png")
        try MediaTransactions.apply(.addAsset(asset), to: &project)
        try MediaTransactions.apply(.addImageLayer(ImageLayer(kind: .image, name: "Base", assetID: asset.id)),
                                    to: &project)
        return project
    }

    private func resolve(_ project: MediaProject, root: URL) -> @Sendable (UUID) -> URL? {
        { id in
            guard let relative = project.asset(id)?.relativePath else { return nil }
            return root.appendingPathComponent(relative)
        }
    }

    private func render(_ project: MediaProject, root: URL) async throws -> CGImage {
        try await WorkbenchImageRenderer().render(project: project, canvas: CGSize(width: 100, height: 100),
                                                  resolveAsset: resolve(project, root: root), previewMaxEdge: nil)
    }

    @Test("erase mask hides pixels; a later restore reveals them; source stays intact")
    func maskEraseAndRestore() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try blueProject(root: root)
        let erase = ImageMaskStroke(points: [.init(x: 0.2, y: 0.5), .init(x: 0.8, y: 0.5)],
                                    width: 20, hardness: 0, restore: false)
        var erasedLayer = project.imageLayers[0]
        erasedLayer.mask = ImageLayerMask(strokes: [erase])
        project.imageLayers[0] = erasedLayer
        let erased = try await render(project, root: root)
        let erasedCenter = pixel(erased, x: 50, y: 50)
        #expect(erasedCenter.a < 40, "erase mask must clear the covered pixels")
        let corner = pixel(erased, x: 5, y: 5)
        #expect(corner.b > 200 && corner.a > 200, "pixels outside the mask stay intact")

        let restore = ImageMaskStroke(points: [.init(x: 0.2, y: 0.5), .init(x: 0.8, y: 0.5)],
                                      width: 20, hardness: 0, restore: true)
        erasedLayer.mask = ImageLayerMask(strokes: [erase, restore])
        project.imageLayers[0] = erasedLayer
        let restored = try await render(project, root: root)
        #expect(pixel(restored, x: 50, y: 50).a > 200, "restore stroke must reveal the original pixels again")
    }

    @Test("selection mask limits a fill layer and feather softens the edge")
    func selectionScopedFill() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try blueProject(root: root)
        let selection = ImageSelection(shapes: [
            ImageSelectionShape(kind: .rectangle, operation: .replace,
                                points: [.init(x: 0.25, y: 0.25), .init(x: 0.75, y: 0.75)])
        ], feather: 0, inverted: false)
        try MediaTransactions.apply(.addImageLayer(ImageLayer(
            kind: .fill, name: "Fill", selectionMask: selection, fillColorHex: "#FF0000")), to: &project)
        let image = try await render(project, root: root)
        let inside = pixel(image, x: 50, y: 50)
        #expect(inside.r > 200 && inside.b < 40, "fill must cover the selected center")
        let outside = pixel(image, x: 5, y: 5)
        #expect(outside.b > 200 && outside.r < 40, "pixels outside the selection keep the base layer")
    }

    @Test("empty non-inverted selection has no effect; inverted empty selects everything")
    func selectionInversion() {
        let canvas = CGSize(width: 64, height: 64)
        #expect(ImageSelectionRasterizer.maskImage(for: ImageSelection(), canvas: canvas) == nil)
        let all = ImageSelectionRasterizer.maskImage(for: ImageSelection(inverted: true), canvas: canvas)
        #expect(all != nil, "inverted empty selection selects the whole canvas")
    }

    @Test("flip transform mirrors the layer non-destructively")
    func flipTransform() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let leftRed = root.appendingPathComponent("halves.png")
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
        try writePNG(ctx.makeImage()!, to: leftRed)

        var project = MediaProject(kind: .image, name: "Flip", canvas: MediaCanvas(width: 100, height: 100))
        let asset = MediaAssetReference(kind: .image, relativePath: "halves.png", originalName: "halves.png")
        try MediaTransactions.apply(.addAsset(asset), to: &project)
        var layer = ImageLayer(kind: .image, name: "Halves", assetID: asset.id)
        layer.transform.flipX = true
        try MediaTransactions.apply(.addImageLayer(layer), to: &project)
        let flipped = try await render(project, root: root)
        // Left edge (CI bottom-left origin: x=10,y=50) must be the formerly right blue half.
        let left = pixel(flipped, x: 10, y: 50)
        #expect(left.b > 200 && left.r < 40, "flipX mirrors the image horizontally")
    }

    @Test("temperature, hue and levels adjustments change real pixels")
    func colorAdjustments() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try blueProject(root: root)
        var layer = project.imageLayers[0]
        layer.adjustment = ImageLayerAdjustment(hueDegrees: 120, levels: ImageLevels(black: 0.1, white: 0.9, gamma: 0.8))
        project.imageLayers[0] = layer
        let adjusted = try await render(project, root: root)
        let plain = try await render(try blueProject(root: root), root: root)
        let adjustedPixel = pixel(adjusted, x: 50, y: 50)
        let plainPixel = pixel(plain, x: 50, y: 50)
        #expect(adjustedPixel != plainPixel, "hue/levels must change the rendered pixels")
    }

    @Test("text typography fields (tracking/stroke/shadow) render non-empty pixels")
    func textTypography() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var project = try blueProject(root: root)
        let text = ImageTextContent(text: "Floe 图纸", fontSize: 30, colorHex: "#FFFFFF",
                                    tracking: 4, leading: 8, alignment: .center,
                                    strokeColorHex: "#000000", strokeWidth: 2,
                                    shadow: ImageTextShadow(colorHex: "#00000080", blur: 3, offsetX: 1, offsetY: 1))
        try MediaTransactions.apply(.addImageLayer(ImageLayer(kind: .text, name: "Text", text: text)), to: &project)
        let image = try await render(project, root: root)
        var nonBlue = 0
        var maxR: UInt8 = 0
        var maxG: UInt8 = 0
        for y in stride(from: 0, to: 100, by: 2) {
            for x in stride(from: 0, to: 100, by: 2) {
                let sample = pixel(image, x: x, y: y)
                maxR = max(maxR, sample.r)
                maxG = max(maxG, sample.g)
                if sample.r > 150 || sample.g > 150 { nonBlue += 1 }
            }
        }
        #expect(nonBlue > 0, "styled text must render visible pixels (maxR=\(maxR) maxG=\(maxG))")
    }

    @Test("commands validate fill layers and mask geometry")
    func commandValidation() throws {
        var project = MediaProject(kind: .image, name: "Validation")
        let fillWithoutSelection = ImageLayer(kind: .fill, name: "Fill", fillColorHex: "#FF0000")
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(.addImageLayer(fillWithoutSelection), to: &project)
        }
        let validSelection = ImageSelection(shapes: [
            ImageSelectionShape(kind: .ellipse, points: [.init(x: 0.1, y: 0.1), .init(x: 0.9, y: 0.9)])
        ])
        let fill = ImageLayer(kind: .fill, name: "Fill", selectionMask: validSelection, fillColorHex: "#FF0000")
        try MediaTransactions.apply(.addImageLayer(fill), to: &project)
        #expect(project.imageLayers.count == 1)
        let badMask = ImageLayerMask(strokes: [ImageMaskStroke(points: [.init(x: 0.1, y: 0.1)], width: 10)])
        let masked = ImageLayer(kind: .image, name: "Masked", assetID: UUID(), mask: badMask)
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(.addImageLayer(masked), to: &project)
        }
    }

    @Test("brush pressure/hardness/opacity survive Codable round-trips")
    func brushStrokeCodable() throws {
        let stroke = ImageFreehandStroke(
            points: [.init(x: 0, y: 0, pressure: 0.4), .init(x: 1, y: 1, pressure: 0.9)],
            width: 12, colorHex: "#112233", hardness: 0.7, opacity: 0.5)
        let data = try JSONEncoder().encode(stroke)
        let decoded = try JSONDecoder().decode(ImageFreehandStroke.self, from: data)
        #expect(decoded == stroke)
        #expect(decoded.points[1].pressure == 0.9)
    }
}
#endif
