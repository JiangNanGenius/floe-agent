// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics

public enum SpritePixelError: Error, Equatable, Sendable {
    case invalidDimensions(width: Int, height: Int)
    case dimensionLimitExceeded
    case pixelCountMismatch(expected: Int, actual: Int)
    case invalidCrop
}

/// A bounded, exact 8-bit RGBA pixel image. Rows are stored top-to-bottom and
/// pixels are straight alpha (`R, G, B, A`), so a transparent pixel keeps its
/// authored RGB values instead of being premultiplied to black.
public struct SpritePixelImage: Equatable, Sendable {
    public static let maximumDimension = 8_192
    public static let maximumPixelCount = 16_777_216
    public static let bytesPerPixel = 4

    public let width: Int
    public let height: Int
    public private(set) var pixels: [UInt8]

    public init(width: Int, height: Int, fill color: SpriteRGBA = .clear) throws {
        try Self.validate(width: width, height: height)
        let byteCount = try Self.byteCount(width: width, height: height)
        if color == .clear {
            pixels = [UInt8](repeating: 0, count: byteCount)
        } else {
            var data = [UInt8]()
            data.reserveCapacity(byteCount)
            let row = [color.red, color.green, color.blue, color.alpha]
            var rowData = [UInt8]()
            rowData.reserveCapacity(width * Self.bytesPerPixel)
            for _ in 0..<width { rowData.append(contentsOf: row) }
            for _ in 0..<height { data.append(contentsOf: rowData) }
            pixels = data
        }
        self.width = width
        self.height = height
    }

    public init(width: Int, height: Int, rgba: [UInt8]) throws {
        try Self.validate(width: width, height: height)
        let expected = try Self.byteCount(width: width, height: height)
        guard rgba.count == expected else {
            throw SpritePixelError.pixelCountMismatch(expected: expected, actual: rgba.count)
        }
        self.width = width
        self.height = height
        self.pixels = rgba
    }

    public var size: SpritePixelSize { SpritePixelSize(width: width, height: height) }
    public var bounds: SpritePixelRect { SpritePixelRect.bounds(width: width, height: height) }
    public var byteCount: Int { pixels.count }

    public func color(x: Int, y: Int) -> SpriteRGBA? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let index = (y * width + x) * Self.bytesPerPixel
        return SpriteRGBA(red: pixels[index], green: pixels[index + 1],
                          blue: pixels[index + 2], alpha: pixels[index + 3])
    }

    public func color(at point: SpritePixelPoint) -> SpriteRGBA? {
        color(x: point.x, y: point.y)
    }

    @discardableResult
    public mutating func setColor(_ color: SpriteRGBA, x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        let index = (y * width + x) * Self.bytesPerPixel
        guard pixels[index] != color.red || pixels[index + 1] != color.green
                || pixels[index + 2] != color.blue || pixels[index + 3] != color.alpha else {
            return false
        }
        pixels[index] = color.red
        pixels[index + 1] = color.green
        pixels[index + 2] = color.blue
        pixels[index + 3] = color.alpha
        return true
    }

    /// Square pixel-art brush. Size 1 is one pixel; even sizes extend one
    /// pixel down/right from the center to stay deterministic.
    @discardableResult
    public mutating func drawBrush(at point: SpritePixelPoint, color: SpriteRGBA,
                                   brushSize: Int, clip: SpritePixelRect? = nil) -> Int {
        let size = min(max(brushSize, 1), 8)
        let clipping = (clip ?? bounds).intersection(bounds)
        guard !clipping.isEmpty else { return 0 }
        let low = (size - 1) / 2
        let high = size / 2
        let minX = max(clipping.minX, point.x - low)
        let maxX = min(clipping.maxX - 1, point.x + high)
        let minY = max(clipping.minY, point.y - low)
        let maxY = min(clipping.maxY - 1, point.y + high)
        guard minX <= maxX, minY <= maxY else { return 0 }
        var changed = 0
        for y in minY...maxY {
            for x in minX...maxX {
                if setColor(color, x: x, y: y) { changed += 1 }
            }
        }
        return changed
    }

    /// Bresenham-connected brush stroke. Every pixel between two gesture
    /// samples is painted, so fast drags do not leave gaps.
    @discardableResult
    public mutating func drawStroke(from start: SpritePixelPoint, to end: SpritePixelPoint,
                                    color: SpriteRGBA, brushSize: Int,
                                    clip: SpritePixelRect? = nil) -> Int {
        var changed = drawBrush(at: start, color: color, brushSize: brushSize, clip: clip)
        var x = start.x
        var y = start.y
        let dx = abs(end.x - start.x)
        let sx = start.x < end.x ? 1 : -1
        let dy = -abs(end.y - start.y)
        let sy = start.y < end.y ? 1 : -1
        var error = dx + dy
        while x != end.x || y != end.y {
            let doubled = error * 2
            if doubled >= dy {
                error += dy
                x += sx
            }
            if doubled <= dx {
                error += dx
                y += sy
            }
            changed += drawBrush(at: SpritePixelPoint(x: x, y: y), color: color,
                                 brushSize: brushSize, clip: clip)
        }
        return changed
    }

    /// Four-way contiguous fill, restricted to `clip` so editing one frame
    /// never bleeds into a neighbouring sprite.
    @discardableResult
    public mutating func floodFill(from point: SpritePixelPoint, color replacement: SpriteRGBA,
                                   clip: SpritePixelRect? = nil) -> Int {
        let clipping = (clip ?? bounds).intersection(bounds)
        guard !clipping.isEmpty, clipping.contains(point),
              let source = color(x: point.x, y: point.y), source != replacement else { return 0 }
        var stack = [point]
        var changed = 0
        while let seed = stack.popLast() {
            guard clipping.contains(seed), color(x: seed.x, y: seed.y) == source else { continue }
            var left = seed.x
            while left > clipping.minX, color(x: left - 1, y: seed.y) == source { left -= 1 }
            var right = seed.x
            while right + 1 < clipping.maxX, color(x: right + 1, y: seed.y) == source { right += 1 }
            for x in left...right {
                if setColor(replacement, x: x, y: seed.y) { changed += 1 }
            }
            for adjacentY in [seed.y - 1, seed.y + 1] {
                guard adjacentY >= clipping.minY, adjacentY < clipping.maxY else { continue }
                var x = left
                while x <= right {
                    if color(x: x, y: adjacentY) == source {
                        var end = x
                        while end + 1 <= right, color(x: end + 1, y: adjacentY) == source {
                            end += 1
                        }
                        stack.append(SpritePixelPoint(x: end, y: adjacentY))
                        x = end + 1
                    } else {
                        x += 1
                    }
                }
            }
        }
        return changed
    }

    /// Exact crop. The rectangle must be inside the image; callers use frame
    /// rectangles computed from a validated sheet layout.
    public func cropped(to rect: SpritePixelRect) -> SpritePixelImage? {
        let clipped = rect.intersection(bounds)
        guard !rect.isEmpty, clipped == rect else { return nil }
        var data = [UInt8]()
        data.reserveCapacity(rect.width * rect.height * Self.bytesPerPixel)
        for y in rect.minY..<rect.maxY {
            let start = (y * width + rect.minX) * Self.bytesPerPixel
            let end = start + rect.width * Self.bytesPerPixel
            data.append(contentsOf: pixels[start..<end])
        }
        return try? SpritePixelImage(width: rect.width, height: rect.height, rgba: data)
    }

    public func flippedHorizontally() -> SpritePixelImage {
        var result = try! SpritePixelImage(width: width, height: height, fill: .clear)
        for y in 0..<height {
            for x in 0..<width {
                if let color = color(x: x, y: y) {
                    result.setColor(color, x: width - 1 - x, y: y)
                }
            }
        }
        return result
    }

    public func flippedVertically() -> SpritePixelImage {
        var result = try! SpritePixelImage(width: width, height: height, fill: .clear)
        for y in 0..<height {
            for x in 0..<width {
                if let color = color(x: x, y: y) {
                    result.setColor(color, x: x, y: height - 1 - y)
                }
            }
        }
        return result
    }

    /// Clockwise rotation. Pixel (x, y) moves to (height - 1 - y, x); the
    /// result's width/height swap, which matters for non-square frames.
    public func rotated90Clockwise() -> SpritePixelImage {
        var result = try! SpritePixelImage(width: height, height: width, fill: .clear)
        for y in 0..<height {
            for x in 0..<width {
                if let color = color(x: x, y: y) {
                    result.setColor(color, x: height - 1 - y, y: x)
                }
            }
        }
        return result
    }

    /// Counter-clockwise rotation. Pixel (x, y) moves to (y, width - 1 - x).
    public func rotated90Counterclockwise() -> SpritePixelImage {
        var result = try! SpritePixelImage(width: height, height: width, fill: .clear)
        for y in 0..<height {
            for x in 0..<width {
                if let color = color(x: x, y: y) {
                    result.setColor(color, x: y, y: width - 1 - x)
                }
            }
        }
        return result
    }

    /// One RGBA CGImage backed by a copied pixel buffer. Callers cache this
    /// value; do not recreate it from a SwiftUI body.
    public func makeCGImage() -> CGImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
            .union(.byteOrder32Big)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * Self.bytesPerPixel,
                       space: SpritePNG.makeColorSpace(), bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    public func pngData(limits: SpritePNGLimits = .default) throws -> Data {
        try SpritePNG.encode(self, limits: limits)
    }

    static func validate(width: Int, height: Int) throws {
        guard width > 0, height > 0,
              width <= maximumDimension, height <= maximumDimension else {
            throw SpritePixelError.invalidDimensions(width: width, height: height)
        }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, count <= maximumPixelCount else {
            throw SpritePixelError.dimensionLimitExceeded
        }
    }

    static func byteCount(width: Int, height: Int) throws -> Int {
        try validate(width: width, height: height)
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maximumPixelCount else { throw SpritePixelError.dimensionLimitExceeded }
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        guard !byteOverflow else { throw SpritePixelError.dimensionLimitExceeded }
        return bytes
    }
}
