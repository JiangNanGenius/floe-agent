import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeTools
#if canImport(ImageIO) && canImport(CoreGraphics)
import ImageIO
import CoreGraphics
#endif

@Suite("Verified tool image storage and delivery")
struct VerifiedToolImageArtifactTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP4z8DAwPAfAAcAAf9+CLHQAAAAAElFTkSuQmCC")!

    private func write(_ data: Data, path: String, root: URL) throws -> ToolArtifactReference {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return ToolArtifactReference(id: UUID(), relativePath: path, mimeType: "image/png",
                                     byteCount: data.count, sha256: FloeDigest.sha256Hex(data))
    }

    @Test func cadFramesAndViewportUseTheSameVerifiedBoundaryAsChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for namespace in VerifiedToolImageArtifact.namespaces {
            let ref = try write(png, path: "\(namespace)/run/frame.png", root: root)
            let loaded = try VerifiedToolImageArtifact.load(ref, root: root)
            #expect(loaded.data == png)
            let delivery = try loaded.providerDelivery()
            #expect(!delivery.isPreview)
            #expect(delivery.sourceSHA256 == delivery.attachedSHA256)
        }
    }

    @Test func symlinkAndChangedReceiptAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ref = try write(png, path: "CADViewportArtifacts/run/frame.png", root: root)
        let alias = root.appendingPathComponent("CADViewportArtifacts/run/alias.png")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent(ref.relativePath))
        let linked = ToolArtifactReference(id: UUID(), relativePath: "CADViewportArtifacts/run/alias.png",
            mimeType: ref.mimeType, byteCount: ref.byteCount, sha256: ref.sha256)
        #expect(throws: (any Error).self) { try VerifiedToolImageArtifact.load(linked, root: root) }
        try Data("changed".utf8).write(to: root.appendingPathComponent(ref.relativePath))
        #expect(throws: (any Error).self) { try VerifiedToolImageArtifact.load(ref, root: root) }
    }

#if canImport(ImageIO) && canImport(CoreGraphics)
    private func shadedPNG(transparentPixel: Bool = false, orientation: Int = 1) throws -> Data {
        let width = 512, height = 384
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var noise: UInt32 = 0x2A18B035
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * context.bytesPerRow + x * 4
                for channel in 0..<3 {
                    noise ^= noise << 13
                    noise ^= noise >> 17
                    noise ^= noise << 5
                    let shade = channel == 0 ? x * 200 / width
                        : (channel == 1 ? y * 200 / height : (x + y) * 200 / (width + height))
                    pixels[offset + channel] = UInt8(shade) + UInt8(noise & 15)
                }
                pixels[offset + 3] = 255
            }
        }
        if transparentPixel {
            for channel in 0..<4 { pixels[channel] = 0 }
        }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let data = output as Data
        #expect(data.count >= 64 * 1_024)
        return data
    }

    @Test func cadCaptureTransportPreservesPixelsAndTheLosslessArtifact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try shadedPNG()
        let reference = try write(original, path: "CADViewportArtifacts/run/shaded.png", root: root)
        let loaded = try VerifiedToolImageArtifact.load(reference, root: root)
        let delivery = try loaded.providerDelivery()
        #expect(delivery.isPreview)
        #expect(delivery.mimeType == "image/jpeg")
        #expect(delivery.data.count < original.count)
        #expect(delivery.sourceGeometry == delivery.attachedGeometry)
        #expect(delivery.attachedGeometry?.width == 512)
        #expect(delivery.attachedGeometry?.height == 384)
        #expect(delivery.receipt.contains("scaleX=1 scaleY=1"))
        #expect(delivery.sourceSHA256 == reference.sha256)
        #expect(delivery.attachedSHA256 == FloeDigest.sha256Hex(delivery.data))
        #expect(delivery.attachedSHA256 != reference.sha256)
        #expect(try Data(contentsOf: loaded.fileURL) == original)
        let source = try #require(CGImageSourceCreateWithData(delivery.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 512 && decoded.height == 384)
    }

    @Test func transportOptimizationDoesNotDiscardTransparencyOrOrientation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, original) in [
            ("transparent", try shadedPNG(transparentPixel: true)),
            ("rotated", try shadedPNG(orientation: 6))
        ] {
            let reference = try write(original, path: "CADViewportArtifacts/run/\(name).png", root: root)
            let delivery = try VerifiedToolImageArtifact.load(reference, root: root).providerDelivery()
            #expect(!delivery.isPreview)
            #expect(delivery.data == original)
            #expect(delivery.attachedSHA256 == reference.sha256)
        }
    }

    @Test func transportOptimizationLeavesOtherImageNamespacesUnchanged() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try shadedPNG()
        for namespace in VerifiedToolImageArtifact.namespaces.subtracting(["CADViewportArtifacts"]) {
            let reference = try write(original, path: "\(namespace)/run/image.png", root: root)
            let delivery = try VerifiedToolImageArtifact.load(reference, root: root).providerDelivery()
            #expect(!delivery.isPreview)
            #expect(delivery.data == original)
        }
    }

    @Test func previewIsSeparatelyHashedAndNeverReplacesTheOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        // A valid PNG with an oversized retained trailer exercises the real
        // size boundary without allocating a huge decoded bitmap in the test.
        var original = encoded as Data
        original.append(Data(repeating: 0, count: 8192))
        let ref = try write(original, path: "CADAnimationFrames/run/frame.png", root: root)
        let loaded = try VerifiedToolImageArtifact.load(ref, root: root)
        let delivery = try loaded.providerDelivery(byteLimit: 4096)
        #expect(delivery.isPreview)
        #expect(delivery.data.count <= 4096)
        #expect(delivery.mimeType == "image/jpeg")
        #expect(delivery.sourceSHA256 == ref.sha256)
        #expect(delivery.attachedSHA256 == FloeDigest.sha256Hex(delivery.data))
        #expect(delivery.attachedSHA256 != delivery.sourceSHA256)
        #expect(try Data(contentsOf: loaded.fileURL) == original)
        #expect(delivery.sourceGeometry?.width == 8)
        #expect(delivery.sourceGeometry?.height == 8)
        #expect(delivery.attachedGeometry?.width == 8)
        #expect(delivery.attachedGeometry?.height == 8)
        #expect(delivery.receipt.contains("scaleX=1 scaleY=1"))
    }

    @Test func defaultBudgetPreviewRecordsRealPixelScalingAndRetainsTheOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try #require(CGContext(data: nil, width: 4096, height: 256, bitsPerComponent: 8,
            bytesPerRow: 4096 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4096, height: 256))
        let image = try #require(context.makeImage())
        let encoded = NSMutableData()
        let encoder = try #require(CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        #expect(CGImageDestinationFinalize(encoder))
        var original = encoded as Data
        original.append(Data(repeating: 0, count: ProviderImageEvidencePolicy.maximumImageBytes + 1024))
        let ref = try write(original, path: "CADAnimationFrames/run/scaled.png", root: root)
        let loaded = try VerifiedToolImageArtifact.load(ref, root: root)
        let delivery = try loaded.providerDelivery()
        #expect(delivery.isPreview)
        #expect(delivery.data.count <= ProviderImageEvidencePolicy.maximumImageBytes)
        #expect(delivery.sourceGeometry?.width == 4096)
        #expect(delivery.sourceGeometry?.height == 256)
        #expect(delivery.attachedGeometry?.width == 2048)
        #expect(delivery.attachedGeometry?.height == 128)
        #expect(delivery.receipt.contains("sourcePixels=4096x256"))
        #expect(delivery.receipt.contains("attachedPixels=2048x128"))
        #expect(delivery.receipt.contains("scaleX=0.5 scaleY=0.5"))
        #expect(delivery.sourceSHA256 == ref.sha256)
        #expect(delivery.attachedSHA256 == FloeDigest.sha256Hex(delivery.data))
        #expect(delivery.attachedSHA256 != ref.sha256)
        #expect(try Data(contentsOf: loaded.fileURL) == original)
    }
#endif
}
