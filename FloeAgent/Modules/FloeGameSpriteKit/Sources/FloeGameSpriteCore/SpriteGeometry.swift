// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics

/// Integer pixel coordinate. Sprite images use a top-left origin and rows are
/// stored from top to bottom.
public struct SpritePixelPoint: Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

public struct SpritePixelSize: Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var pixelCount: Int { width * height }
    public var cgSize: CGSize { CGSize(width: width, height: height) }
}

/// An integer, half-open rectangle in sprite pixel coordinates.
public struct SpritePixelRect: Hashable, Sendable {
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

    public var minX: Int { x }
    public var minY: Int { y }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var pixelCount: Int { max(0, width) * max(0, height) }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public func contains(_ point: SpritePixelPoint) -> Bool {
        point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY
    }

    public func intersection(_ other: SpritePixelRect) -> SpritePixelRect {
        let left = max(minX, other.minX)
        let top = max(minY, other.minY)
        let right = min(maxX, other.maxX)
        let bottom = min(maxY, other.maxY)
        return SpritePixelRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }

    public func insetBy(dx: Int, dy: Int) -> SpritePixelRect {
        SpritePixelRect(x: x + dx, y: y + dy, width: width - dx * 2, height: height - dy * 2)
    }

    public static func bounds(width: Int, height: Int) -> SpritePixelRect {
        SpritePixelRect(x: 0, y: 0, width: width, height: height)
    }
}

public enum SpriteGeometry {
    public static func clamped(_ point: SpritePixelPoint, to bounds: SpritePixelRect) -> SpritePixelPoint? {
        guard !bounds.isEmpty else { return nil }
        return SpritePixelPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                                y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }
}
