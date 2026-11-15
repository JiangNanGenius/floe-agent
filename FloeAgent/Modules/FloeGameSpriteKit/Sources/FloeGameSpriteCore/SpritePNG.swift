// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import ImageIO
import Darwin

public struct SpritePNGLimits: Equatable, Sendable {
    public var maximumDimension: Int
    public var maximumPixelCount: Int
    public var maximumEncodedBytes: Int
    public var maximumDecodedBytes: Int

    public init(maximumDimension: Int = 8_192,
                maximumPixelCount: Int = 16_777_216,
                maximumEncodedBytes: Int = 64 * 1_024 * 1_024,
                maximumDecodedBytes: Int = 64 * 1_024 * 1_024) {
        self.maximumDimension = maximumDimension
        self.maximumPixelCount = maximumPixelCount
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumDecodedBytes = maximumDecodedBytes
    }

    public static let `default` = SpritePNGLimits()
}

public enum SpritePNGError: Error, Equatable, Sendable {
    case emptyData
    case encodedBytesExceeded(Int)
    case dimensionsExceeded(width: Int, height: Int)
    case invalidPNG
    case unsupportedBitDepth(Int)
    case truncated
    case encodeFailed
    case roundtripMismatch
}

/// PNG decode/encode through native ImageIO. Stored pixels are straight-alpha
/// RGBA; dimensions, encoded size and decoded size are checked before a bitmap
/// is allocated. Encoding verifies the exact pixel roundtrip by default.
public enum SpritePNG {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func makeColorSpace() -> CGColorSpace {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Reject non-PNG and unsupported bit depth from the IHDR before ImageIO
    /// allocates a decoded bitmap. 16-bit PNG editing would otherwise reduce
    /// precision or exceed the decoded-byte budget.
    private static func validateHeader(_ data: Data) throws {
        guard data.count >= 8 else { throw SpritePNGError.invalidPNG }
        let prefix = Array(data.prefix(8))
        guard prefix == signature else { throw SpritePNGError.invalidPNG }
        guard data.count >= 33 else { throw SpritePNGError.truncated }
        let header = Array(data.prefix(33))
        guard Array(header[8..<12]) == [0, 0, 0, 13],
              Array(header[12..<16]) == Array("IHDR".utf8) else {
            throw SpritePNGError.truncated
        }
        let bitDepth = Int(header[24])
        let colorType = Int(header[25])
        // Pixel-art PNGs commonly use 1/2/4-bit palette indices. Their
        // palette channels are still 8-bit and can be edited without losing
        // precision; grayscale also expands exactly to 8-bit samples.
        let supported = bitDepth == 8
            || ([0, 3].contains(colorType) && [1, 2, 4].contains(bitDepth))
        guard supported else { throw SpritePNGError.unsupportedBitDepth(bitDepth) }
    }

    public static func decode(_ data: Data, limits: SpritePNGLimits = .default) throws -> SpritePixelImage {
        guard !data.isEmpty else { throw SpritePNGError.emptyData }
        guard data.count <= limits.maximumEncodedBytes else {
            throw SpritePNGError.encodedBytesExceeded(data.count)
        }
        try validateHeader(data)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw SpritePNGError.invalidPNG }
        let firstStatus = CGImageSourceGetStatus(source)
        if firstStatus == .statusIncomplete || firstStatus == .statusUnexpectedEOF {
            throw SpritePNGError.truncated
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw SpritePNGError.invalidPNG
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { throw SpritePNGError.invalidPNG }
        try validate(width: width, height: height, limits: limits)

        let options: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false
        ]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            let status = CGImageSourceGetStatus(source)
            if status == .statusIncomplete || status == .statusUnexpectedEOF {
                throw SpritePNGError.truncated
            }
            throw SpritePNGError.invalidPNG
        }
        let finalStatus = CGImageSourceGetStatus(source)
        if finalStatus == .statusIncomplete || finalStatus == .statusUnexpectedEOF {
            throw SpritePNGError.truncated
        }
        guard image.width > 0, image.height > 0 else { throw SpritePNGError.invalidPNG }
        try validate(width: image.width, height: image.height, limits: limits)
        return try extractPixels(from: image, limits: limits)
    }

    public static func encode(_ image: SpritePixelImage, limits: SpritePNGLimits = .default,
                              verify: Bool = true) throws -> Data {
        try validate(width: image.width, height: image.height, limits: limits)
        guard let cgImage = image.makeCGImage() else { throw SpritePNGError.encodeFailed }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.png" as CFString, 1, nil) else {
            throw SpritePNGError.encodeFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw SpritePNGError.encodeFailed }
        let data = output as Data
        guard !data.isEmpty else { throw SpritePNGError.encodeFailed }
        guard data.count <= limits.maximumEncodedBytes else {
            throw SpritePNGError.encodedBytesExceeded(data.count)
        }
        if verify {
            let decoded = try decode(data, limits: limits)
            guard decoded == image else { throw SpritePNGError.roundtripMismatch }
        }
        return data
    }

    static func validate(width: Int, height: Int, limits: SpritePNGLimits) throws {
        guard width > 0, height > 0,
              width <= limits.maximumDimension, height <= limits.maximumDimension,
              width <= SpritePixelImage.maximumDimension, height <= SpritePixelImage.maximumDimension else {
            throw SpritePNGError.dimensionsExceeded(width: width, height: height)
        }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow,
              pixels <= limits.maximumPixelCount,
              pixels <= SpritePixelImage.maximumPixelCount else {
            throw SpritePNGError.dimensionsExceeded(width: width, height: height)
        }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: SpritePixelImage.bytesPerPixel)
        guard !byteOverflow, bytes <= limits.maximumDecodedBytes else {
            throw SpritePNGError.dimensionsExceeded(width: width, height: height)
        }
    }

    private static func extractPixels(from image: CGImage, limits: SpritePNGLimits) throws -> SpritePixelImage {
        let width = image.width
        let height = image.height
        try validate(width: width, height: height, limits: limits)
        let rowBytes = width * SpritePixelImage.bytesPerPixel
        guard image.bitsPerComponent == 8 else {
            throw SpritePNGError.unsupportedBitDepth(image.bitsPerComponent)
        }

        // Fast path: ImageIO commonly hands PNGs back as 8-bit straight-alpha
        // RGBA. Copying the decoded bytes directly preserves hidden RGB under
        // zero alpha, unlike a premultiplied redraw.
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32,
           image.bytesPerRow >= rowBytes,
           image.colorSpace?.model == .rgb,
           image.bitmapInfo.intersection(.byteOrder32Little).isEmpty,
           let provider = image.dataProvider?.data {
            let providerData = provider as Data
            let alphaInfo = image.alphaInfo
            if providerData.count >= image.bytesPerRow * height,
               alphaInfo == .last || alphaInfo == .premultipliedLast || alphaInfo == .noneSkipLast {
                var result = [UInt8](repeating: 0, count: rowBytes * height)
                providerData.withUnsafeBytes { rawBuffer in
                    result.withUnsafeMutableBytes { destination in
                        guard let source = rawBuffer.baseAddress,
                              let target = destination.baseAddress else { return }
                        for y in 0..<height {
                            _ = memcpy(target.advanced(by: y * rowBytes),
                                       source.advanced(by: y * image.bytesPerRow), rowBytes)
                        }
                    }
                }
                if alphaInfo == .premultipliedLast {
                    unpremultiply(&result)
                } else if alphaInfo == .noneSkipLast {
                    for index in stride(from: 3, to: result.count, by: 4) {
                        result[index] = 255
                    }
                }
                return try SpritePixelImage(width: width, height: height, rgba: result)
            }
        }

        if image.bitsPerComponent == 8, image.bitsPerPixel == 24,
           image.alphaInfo == .none,
           image.colorSpace?.model == .rgb,
           image.bitmapInfo.intersection(.byteOrder32Little).isEmpty,
           image.bytesPerRow >= width * 3,
           let provider = image.dataProvider?.data {
            let providerData = provider as Data
            if providerData.count >= image.bytesPerRow * height {
                var result = [UInt8](repeating: 0, count: rowBytes * height)
                providerData.withUnsafeBytes { rawBuffer in
                    result.withUnsafeMutableBytes { destination in
                        guard let source = rawBuffer.baseAddress,
                              let target = destination.baseAddress else { return }
                        for y in 0..<height {
                            let sourceRow = source.advanced(by: y * image.bytesPerRow)
                            let targetRow = target.advanced(by: y * rowBytes)
                            for x in 0..<width {
                                targetRow.storeBytes(of: sourceRow.load(fromByteOffset: x * 3, as: UInt8.self),
                                                     toByteOffset: x * 4, as: UInt8.self)
                                targetRow.storeBytes(of: sourceRow.load(fromByteOffset: x * 3 + 1, as: UInt8.self),
                                                     toByteOffset: x * 4 + 1, as: UInt8.self)
                                targetRow.storeBytes(of: sourceRow.load(fromByteOffset: x * 3 + 2, as: UInt8.self),
                                                     toByteOffset: x * 4 + 2, as: UInt8.self)
                                targetRow.storeBytes(of: UInt8(255), toByteOffset: x * 4 + 3, as: UInt8.self)
                            }
                        }
                    }
                }
                return try SpritePixelImage(width: width, height: height, rgba: result)
            }
        }

        var result = [UInt8](repeating: 0, count: rowBytes * height)
        let colorSpace = makeColorSpace()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        try result.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: rowBytes,
                                          space: colorSpace, bitmapInfo: bitmapInfo) else {
                throw SpritePNGError.invalidPNG
            }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        unpremultiply(&result)
        return try SpritePixelImage(width: width, height: height, rgba: result)
    }

    private static func unpremultiply(_ pixels: inout [UInt8]) {
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[index + 3])
            if alpha == 0 {
                pixels[index] = 0
                pixels[index + 1] = 0
                pixels[index + 2] = 0
            } else if alpha < 255 {
                pixels[index] = UInt8(min(255, (Int(pixels[index]) * 255 + alpha / 2) / alpha))
                pixels[index + 1] = UInt8(min(255, (Int(pixels[index + 1]) * 255 + alpha / 2) / alpha))
                pixels[index + 2] = UInt8(min(255, (Int(pixels[index + 2]) * 255 + alpha / 2) / alpha))
            }
        }
    }
}
