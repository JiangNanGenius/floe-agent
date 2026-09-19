// FloeImages tests — format-preserving re-encode for interactive editors.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import FloeImages

@Suite("FloeImages.ImageFileEncoding")
struct ImageFileEncodingTests {

    /// Builds a deterministic RGBA test image. `alpha` 0 yields a fully
    /// transparent image so alpha flattening is observable.
    private func makeImage(width: Int = 48, height: Int = 32, alpha: UInt8 = 255) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4 + 0] = 30
            pixels[i * 4 + 1] = 120
            pixels[i * 4 + 2] = 200
            pixels[i * 4 + 3] = alpha
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
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

    private func typeIdentifier(of data: Data) -> String? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap {
            CGImageSourceGetType($0) as String?
        }
    }

    private func decodedSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image.width, image.height)
    }

    private func firstPixel(of image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var buffer = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &buffer,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (buffer[0], buffer[1], buffer[2], buffer[3])
    }

    @Test("Path extensions map only to writable raster containers")
    func pathExtensionMapping() {
        #expect(ImageFileFormat(pathExtension: "png") == .png)
        #expect(ImageFileFormat(pathExtension: ".PNG") == .png)
        #expect(ImageFileFormat(pathExtension: "jpg") == .jpeg)
        #expect(ImageFileFormat(pathExtension: "jpeg") == .jpeg)
        #expect(ImageFileFormat(pathExtension: "heic") == .heic)
        #expect(ImageFileFormat(pathExtension: "heif") == .heic)
        // Containers the editor must never overwrite with foreign bytes.
        for unsupported in ["gif", "webp", "tiff", "tif", "bmp", "svg", ""] {
            #expect(ImageFileFormat(pathExtension: unsupported) == nil)
        }
    }

    @Test("Editor PNG output round-trips into the destination container")
    func reencodesIntoDestinationContainer() throws {
        let image = makeImage()
        let png = try ImageFileEncoder.encode(image, as: .png)
        #expect(typeIdentifier(of: png) == UTType.png.identifier)

        let jpeg = try ImageFileEncoder.reencode(png, as: .jpeg)
        #expect(typeIdentifier(of: jpeg) == UTType.jpeg.identifier)
        #expect(decodedSize(of: jpeg)?.width == image.width)
        #expect(decodedSize(of: jpeg)?.height == image.height)

        let repng = try ImageFileEncoder.reencode(png, as: .png)
        #expect(typeIdentifier(of: repng) == UTType.png.identifier)
        #expect(decodedSize(of: repng)?.width == image.width)
    }

    @Test("HEIC destination is supported and decodes at the same size")
    func heicEncode() throws {
        try #require(
            ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
                .contains(UTType.heic.identifier)
        )
        let image = makeImage(width: 32, height: 24)
        let png = try ImageFileEncoder.encode(image, as: .png)
        let heic = try ImageFileEncoder.reencode(png, as: .heic)
        #expect(typeIdentifier(of: heic) == UTType.heic.identifier)
        #expect(decodedSize(of: heic)?.width == 32)
        #expect(decodedSize(of: heic)?.height == 24)
    }

    @Test("JPEG output flattens transparency instead of writing black")
    func jpegFlattensAlpha() throws {
        let transparent = makeImage(alpha: 0)
        let png = try ImageFileEncoder.encode(transparent, as: .png)
        let jpeg = try ImageFileEncoder.reencode(png, as: .jpeg)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixel = firstPixel(of: decoded)
        // White composite: every channel stays near 255, never near black.
        #expect(pixel.r > 200)
        #expect(pixel.g > 200)
        #expect(pixel.b > 200)
    }

    @Test("Unreadable payloads fail closed with decodeFailed")
    func rejectsUnreadablePayloads() {
        let garbage = Data("not an image".utf8)
        #expect(throws: ImageFileEncodingError.decodeFailed) {
            _ = try ImageFileEncoder.reencode(garbage, as: .jpeg)
        }
    }
}
