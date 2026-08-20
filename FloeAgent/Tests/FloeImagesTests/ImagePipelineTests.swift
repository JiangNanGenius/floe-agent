import Foundation
import Testing
import CoreGraphics
import CoreImage
@testable import FloeImages
@testable import FloeCore

@Suite("FloeImages.ImagePipeline")
struct ImagePipelineTests {

    /// Builds a deterministic solid-color test image.
    private func makeSource(width: Int = 64, height: Int = 64) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4 + 0] = 200 // R
            pixels[i * 4 + 1] = 100 // G
            pixels[i * 4 + 2] = 50  // B
            pixels[i * 4 + 3] = 255 // A
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// Renders a CGImage to raw RGBA bytes for byte-level comparison.
    private func bytes(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &buffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    @Test("Determinism: same op + same source → identical output bytes")
    func determinism() throws {
        let pipeline = ImagePipeline()
        let source = makeSource()
        let op = ImageOperation.adjustColor(saturation: 1.2, contrast: 1.1, brightness: 0.05)

        let a = try pipeline.apply(op, to: source)
        let b = try pipeline.apply(op, to: source)

        #expect(a.width == b.width)
        #expect(a.height == b.height)
        #expect(bytes(a) == bytes(b))
    }

    @Test("Resize produces the requested dimensions")
    func resize() throws {
        let pipeline = ImagePipeline()
        let source = makeSource(width: 64, height: 64)
        let out = try pipeline.apply(.resize(width: 32, height: 32, preserveAspect: false), to: source)
        #expect(out.width == 32)
        #expect(out.height == 32)
    }

    @Test("Crop produces the normalized sub-rect")
    func crop() throws {
        let pipeline = ImagePipeline()
        let source = makeSource(width: 100, height: 100)
        let rect = ImageOperation.NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let out = try pipeline.apply(.crop(rect: rect), to: source)
        #expect(out.width == 50)
        #expect(out.height == 50)
    }

    @Test("Invalid operation throws validationFailed and does not render")
    func validation() throws {
        let pipeline = ImagePipeline()
        let source = makeSource()
        let bad = ImageOperation.compress(quality: 5.0) // out of 0.01...1.0
        #expect(throws: FloeError.self) {
            _ = try pipeline.apply(bad, to: source)
        }
    }

    @Test("Edit session undo/redo reproduces deterministic renders")
    func editSessionUndoRedo() throws {
        let pipeline = ImagePipeline()
        let source = makeSource()
        var session = ImageEditSession(source: source)

        try session.apply(.resize(width: 32, height: 32, preserveAspect: false))
        try session.apply(.adjustExposure(ev: 0.5))
        #expect(session.appliedOperations.count == 2)
        let full = try session.render(using: pipeline)

        session.undo()
        #expect(session.appliedOperations.count == 1)
        let undone = try session.render(using: pipeline)
        #expect(undone.width == 32)

        session.redo()
        let redone = try session.render(using: pipeline)
        #expect(bytes(redone) == bytes(full))
    }

    @Test("Render with no operations returns the source dimensions")
    func renderIdentity() throws {
        let pipeline = ImagePipeline()
        let source = makeSource(width: 48, height: 24)
        let session = ImageEditSession(source: source)
        let out = try session.render(using: pipeline)
        #expect(out.width == 48)
        #expect(out.height == 24)
    }
}
