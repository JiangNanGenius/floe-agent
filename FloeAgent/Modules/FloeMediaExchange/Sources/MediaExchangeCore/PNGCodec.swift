// SPDX-License-Identifier: MPL-2.0
//
// Straight-alpha PNG files use the pinned Swift PNG codec on every platform.
// ImageIO is retained for CGImage inspection and thumbnail rendering. The ORA container keeps the original PNG
// bytes; this codec is only used when a layer/mask must be inspected or when
// a new merged image/thumbnail has to be rendered.

import Foundation
import PNG
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct PNGHeader: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bitDepth: Int
    public let colorType: Int
    public let interlaced: Bool

    public static func parse(_ data: Data) throws -> PNGHeader {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= 33 else {
            throw ImageError.invalidPNG("file is shorter than a PNG signature and IHDR")
        }
        let bytes = [UInt8](data.prefix(33))
        guard Array(bytes[0..<8]) == signature else {
            throw ImageError.invalidPNG("bad signature")
        }
        guard bytes[8..<12].elementsEqual([0, 0, 0, 13]) else {
            throw ImageError.invalidPNG("IHDR is not the first chunk")
        }
        guard bytes[12..<16].elementsEqual(Array("IHDR".utf8)) else {
            throw ImageError.invalidPNG("first chunk is not IHDR")
        }
        let width = Int(bytes[16]) << 24 | Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])
        let height = Int(bytes[20]) << 24 | Int(bytes[21]) << 16 | Int(bytes[22]) << 8 | Int(bytes[23])
        guard width > 0, height > 0 else {
            throw ImageError.invalidPNG("IHDR has zero dimension")
        }
        let bitDepth = Int(bytes[24])
        let colorType = Int(bytes[25])
        let compression = Int(bytes[26])
        let filter = Int(bytes[27])
        let interlace = Int(bytes[28])
        guard compression == 0, filter == 0 else {
            throw ImageError.invalidPNG("unsupported compression/filter method")
        }
        guard interlace == 0 || interlace == 1 else {
            throw ImageError.invalidPNG("unsupported interlace method \(interlace)")
        }
        guard [0, 2, 3, 4, 6].contains(colorType) else {
            throw ImageError.invalidPNG("unsupported color type \(colorType)")
        }
        guard [1, 2, 4, 8, 16].contains(bitDepth) else {
            throw ImageError.invalidPNG("unsupported bit depth \(bitDepth)")
        }
        guard bitDepth != 16 || colorType == 0 || colorType == 2 || colorType == 4 || colorType == 6 else {
            throw ImageError.invalidPNG("16-bit palette PNG is not valid")
        }
        return PNGHeader(
            width: width,
            height: height,
            bitDepth: bitDepth,
            colorType: colorType,
            interlaced: interlace == 1
        )
    }
}

public enum PNGCodec {
    public static func dimensions(_ data: Data) throws -> (width: Int, height: Int) {
        let header = try PNGHeader.parse(data)
        return (header.width, header.height)
    }

    public static func decode(_ data: Data, maxDimension: Int = ImageLimits.maxDimension) throws -> RGBAImage {
        try Task.checkCancellation()
        let header = try PNGHeader.parse(data)
        guard header.width <= maxDimension, header.height <= maxDimension else {
            throw ImageError.dimensionsExceedLimit(
                width: header.width,
                height: header.height,
                limit: maxDimension
            )
        }
        guard header.bitDepth == 8 else {
            throw ImageError.invalidPNG("only 8-bit PNG layers are decoded in the qualification baseline")
        }
        _ = try ImageLimits.byteCount(width: header.width, height: header.height)
        var source = Source(data: data)
        let decoded: PNG.Image
        do {
            decoded = try PNG.Image.decompress(stream: &source)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        guard decoded.size.x == header.width, decoded.size.y == header.height else {
            throw ImageError.invalidPNG("decoded dimensions disagree with IHDR")
        }
        let values = decoded.unpack(as: PNG.RGBA<UInt8>.self)
        var bytes = [UInt8](); bytes.reserveCapacity(values.count * 4)
        for value in values { bytes += [value.r, value.g, value.b, value.a] }
        return try RGBAImage(width: header.width, height: header.height, pixels: bytes)
    }

    private struct Source: PNG.BytestreamSource {
        let data: Data
        var offset = 0
        mutating func read(count: Int) -> [UInt8]? {
            guard count >= 0, count <= data.count - offset, !Task.isCancelled else { return nil }
            defer { offset += count }
            let start = data.startIndex + offset
            return Array(data[start..<(start + count)])
        }
    }
    private struct Destination: PNG.BytestreamDestination {
        var data = Data()
        mutating func write(_ buffer: [UInt8]) -> Void? {
            guard buffer.count <= 536_870_912 - data.count, !Task.isCancelled else { return nil }
            data.append(contentsOf: buffer); return ()
        }
    }

    public static func decode(cgImage image: CGImage) throws -> RGBAImage {
        // ImageIO keeps straight-alpha 8-bit RGBA PNG data in the CGImage data
        // provider. Reading those bytes directly preserves alpha=1 colours
        // exactly; drawing the image into CGContext would premultiply them and
        // destroy low-alpha colour precision. Fall back to the premultiplied
        // drawing path only for layouts that cannot be read directly.
        if let direct = try decodeStraightProvider(cgImage: image) {
            return direct
        }
        return try decodeByDrawing(cgImage: image)
    }

    /// Reads 8-bit straight RGBA/RGB directly from the CGImage provider when
    /// the bitmap layout is known. Returns nil for any other layout; callers
    /// must not interpret unknown byte orders as RGBA.
    private static func decodeStraightProvider(cgImage image: CGImage) throws -> RGBAImage? {
        guard image.bitsPerComponent == 8,
              let provider = image.dataProvider,
              let cfData = provider.data else { return nil }
        let width = image.width
        let height = image.height
        let bytes = [UInt8](cfData as Data)
        let rowBytes = image.bytesPerRow
        let colorOrder = image.bitmapInfo.intersection(.byteOrderMask)

        if image.bitsPerPixel == 32,
           image.alphaInfo == .last,
           (colorOrder.isEmpty || colorOrder == .byteOrder32Big),
           rowBytes >= width * 4,
           bytes.count >= rowBytes * height {
            var out = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                let srcRow = y * rowBytes
                let dstRow = y * width * 4
                for x in 0..<width {
                    let src = srcRow + x * 4
                    let dst = dstRow + x * 4
                    out[dst] = bytes[src]
                    out[dst + 1] = bytes[src + 1]
                    out[dst + 2] = bytes[src + 2]
                    out[dst + 3] = bytes[src + 3]
                }
            }
            return try RGBAImage(width: width, height: height, pixels: out)
        }

        if image.bitsPerPixel == 24,
           image.alphaInfo == .none,
           (colorOrder.isEmpty || colorOrder == .byteOrder32Big),
           rowBytes >= width * 3,
           bytes.count >= rowBytes * height {
            var out = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                let srcRow = y * rowBytes
                let dstRow = y * width * 4
                for x in 0..<width {
                    let src = srcRow + x * 3
                    let dst = dstRow + x * 4
                    out[dst] = bytes[src]
                    out[dst + 1] = bytes[src + 1]
                    out[dst + 2] = bytes[src + 2]
                    out[dst + 3] = 255
                }
            }
            return try RGBAImage(width: width, height: height, pixels: out)
        }

        return nil
    }

    private static func decodeByDrawing(cgImage image: CGImage) throws -> RGBAImage {
        let width = image.width
        let height = image.height
        let count = try ImageLimits.byteCount(width: width, height: height)
        var buffer = [UInt8](repeating: 0, count: count)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ImageError.invalidPNG("sRGB color space unavailable")
        }
        let success = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else {
            throw ImageError.invalidPNG("could not create an RGBA context")
        }
        // This path is intentionally a documented fallback: premultiplied
        // decoding cannot recover colour at alpha 1. PNG layers that need
        // exact straight-alpha fidelity use the provider path above.
        var i = 0
        while i < buffer.count {
            let a = buffer[i + 3]
            if a == 0 {
                buffer[i] = 0; buffer[i + 1] = 0; buffer[i + 2] = 0
            } else if a != 255 {
                buffer[i] = UInt8(min(255, (Int(buffer[i]) * 255 + Int(a) / 2) / Int(a)))
                buffer[i + 1] = UInt8(min(255, (Int(buffer[i + 1]) * 255 + Int(a) / 2) / Int(a)))
                buffer[i + 2] = UInt8(min(255, (Int(buffer[i + 2]) * 255 + Int(a) / 2) / Int(a)))
            }
            i += 4
        }
        return try RGBAImage(width: width, height: height, pixels: buffer)
    }

    public static func encode(_ image: RGBAImage) throws -> Data {
        try Task.checkCancellation()
        _ = try ImageLimits.byteCount(width: image.width, height: image.height)
        var pixels = [PNG.RGBA<UInt8>](); pixels.reserveCapacity(image.width * image.height)
        for index in stride(from: 0, to: image.pixels.count, by: 4) {
            if index.isMultiple(of: 262_144) { try Task.checkCancellation() }
            pixels.append(.init(image.pixels[index], image.pixels[index + 1], image.pixels[index + 2], image.pixels[index + 3]))
        }
        let value = PNG.Image(packing: pixels, size: (image.width, image.height), layout: .init(format: .rgba8(palette: [], fill: nil)))
        var destination = Destination()
        do {
            try value.compress(stream: &destination, level: 6)
        } catch {
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        return destination.data
    }

    public static func scaled(_ image: RGBAImage, maxDimension: Int) throws -> RGBAImage {
        guard maxDimension > 0 else {
            throw ImageError.invalidDimensions(width: maxDimension, height: 0)
        }
        let largest = max(image.width, image.height)
        guard largest > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(largest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let cgImage = try makeCGImage(image)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ImageError.invalidPNG("sRGB color space unavailable")
        }
        let count = try ImageLimits.byteCount(width: width, height: height)
        var buffer = [UInt8](repeating: 0, count: count)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else {
            throw ImageError.invalidPNG("could not create a thumbnail context")
        }
        var i = 0
        while i < buffer.count {
            let a = buffer[i + 3]
            if a == 0 {
                buffer[i] = 0; buffer[i + 1] = 0; buffer[i + 2] = 0
            } else if a != 255 {
                buffer[i] = UInt8(min(255, (Int(buffer[i]) * 255 + Int(a) / 2) / Int(a)))
                buffer[i + 1] = UInt8(min(255, (Int(buffer[i + 1]) * 255 + Int(a) / 2) / Int(a)))
                buffer[i + 2] = UInt8(min(255, (Int(buffer[i + 2]) * 255 + Int(a) / 2) / Int(a)))
            }
            i += 4
        }
        return try RGBAImage(width: width, height: height, pixels: buffer)
    }

    private static func makeCGImage(_ image: RGBAImage) throws -> CGImage {
        // ImageIO encodes straight-alpha CGImage data exactly. Supplying
        // non-premultiplied bytes avoids the 1-unit colour drift that occurs
        // when an RGBA layer is premultiplied just for PNG export.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(image.pixels) as CFData) else {
            throw ImageError.invalidPNG("could not create a CGDataProvider")
        }
        guard let cgImage = CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw ImageError.invalidPNG("could not create a CGImage")
        }
        return cgImage
    }
}
