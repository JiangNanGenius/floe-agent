// SPDX-License-Identifier: MPL-2.0
//
// Qualification-only RGBA image primitive shared by the PSD/ORA codecs and
// the strict selection compositor. Straight (non-premultiplied) 8-bit RGBA.

import Foundation

public struct RGBA: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

public struct RGBAImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) throws {
        guard width > 0, height > 0 else {
            throw ImageError.invalidDimensions(width: width, height: height)
        }
        guard width <= ImageLimits.maxDimension, height <= ImageLimits.maxDimension else {
            throw ImageError.dimensionsExceedLimit(
                width: width,
                height: height,
                limit: ImageLimits.maxDimension
            )
        }
        let expected = try ImageLimits.byteCount(width: width, height: height)
        guard pixels.count == expected else {
            throw ImageError.invalidPixelCount(expected: expected, actual: pixels.count)
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(
        width: Int,
        height: Int,
        transform: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) throws {
        let count = try ImageLimits.byteCount(width: width, height: height)
        var pixels = [UInt8](repeating: 0, count: count)
        var i = 0
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = transform(x, y)
                pixels[i] = r
                pixels[i + 1] = g
                pixels[i + 2] = b
                pixels[i + 3] = a
                i += 4
            }
        }
        try self.init(width: width, height: height, pixels: pixels)
    }

    public init(width: Int, height: Int, fill: UInt8 = 0) throws {
        let count = try ImageLimits.byteCount(width: width, height: height)
        try self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: count))
    }

    public var byteCount: Int { pixels.count }

    @inline(__always)
    public func offset(x: Int, y: Int) -> Int {
        (y * width + x) * 4
    }

    @inline(__always)
    public func pixel(x: Int, y: Int) -> RGBA {
        let i = offset(x: x, y: y)
        return RGBA(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2], a: pixels[i + 3])
    }

    public mutating func setPixel(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let i = offset(x: x, y: y)
        pixels[i] = r
        pixels[i + 1] = g
        pixels[i + 2] = b
        pixels[i + 3] = a
    }

    /// Returns a copy with every RGBA byte replaced by `transform`.
    public func mapPixels(_ transform: (Int, Int, UInt8, UInt8, UInt8, UInt8) -> (UInt8, UInt8, UInt8, UInt8)) -> RGBAImage {
        var out = pixels
        var i = 0
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = transform(x, y, out[i], out[i + 1], out[i + 2], out[i + 3])
                out[i] = r
                out[i + 1] = g
                out[i + 2] = b
                out[i + 3] = a
                i += 4
            }
        }
        return try! RGBAImage(width: width, height: height, pixels: out)
    }

    /// Crops to `rect` using zero (transparent black) outside the image.
    /// Used when a layer's stored rectangle extends beyond the canvas.
    public func croppedOrPadded(to rect: PixelRect) throws -> RGBAImage {
        guard rect.width > 0, rect.height > 0 else {
            throw ImageError.invalidDimensions(width: rect.width, height: rect.height)
        }
        var out = [UInt8](repeating: 0, count: try ImageLimits.byteCount(width: rect.width, height: rect.height))
        for y in 0..<rect.height {
            let sy = rect.y + y
            guard sy >= 0, sy < height else { continue }
            for x in 0..<rect.width {
                let sx = rect.x + x
                guard sx >= 0, sx < width else { continue }
                let src = offset(x: sx, y: sy)
                let dst = (y * rect.width + x) * 4
                out[dst] = pixels[src]
                out[dst + 1] = pixels[src + 1]
                out[dst + 2] = pixels[src + 2]
                out[dst + 3] = pixels[src + 3]
            }
        }
        return try RGBAImage(width: rect.width, height: rect.height, pixels: out)
    }
}

public struct PixelRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    public func isWithin(width: Int, height: Int) -> Bool {
        guard x >= 0, y >= 0, self.width > 0, self.height > 0 else { return false }
        let (right, rightOverflow) = x.addingReportingOverflow(self.width)
        let (bottom, bottomOverflow) = y.addingReportingOverflow(self.height)
        guard !rightOverflow, !bottomOverflow else { return false }
        return right <= width && bottom <= height
    }

    public func intersection(width: Int, height: Int) -> PixelRect? {
        let (rawRight, rightOverflow) = x.addingReportingOverflow(self.width)
        let (rawBottom, bottomOverflow) = y.addingReportingOverflow(self.height)
        guard !rightOverflow, !bottomOverflow else { return nil }
        let left = max(0, x)
        let top = max(0, y)
        let right = min(width, rawRight)
        let bottom = min(height, rawBottom)
        guard right > left, bottom > top else { return nil }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

public enum ImageLimits {
    public static let maxDimension = 16_384
    public static let maxPixels = 64_000_000
    public static let maxBytes = maxPixels * 4

    public static func byteCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else {
            throw ImageError.invalidDimensions(width: width, height: height)
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxPixels else {
            throw ImageError.pixelCountExceedLimit(width: width, height: height, limit: maxPixels)
        }
        return pixels * 4
    }
}

public enum ImageError: Error, Equatable, CustomStringConvertible {
    case invalidDimensions(width: Int, height: Int)
    case dimensionsExceedLimit(width: Int, height: Int, limit: Int)
    case pixelCountExceedLimit(width: Int, height: Int, limit: Int)
    case invalidPixelCount(expected: Int, actual: Int)
    case invalidPNG(String)

    public var description: String {
        switch self {
        case let .invalidDimensions(width, height):
            return "invalid image dimensions \(width)x\(height)"
        case let .dimensionsExceedLimit(width, height, limit):
            return "image dimensions \(width)x\(height) exceed limit \(limit)"
        case let .pixelCountExceedLimit(width, height, limit):
            return "image pixel count \(width)x\(height) exceeds limit \(limit)"
        case let .invalidPixelCount(expected, actual):
            return "invalid pixel count: expected \(expected), got \(actual)"
        case let .invalidPNG(reason):
            return "invalid PNG: \(reason)"
        }
    }
}
