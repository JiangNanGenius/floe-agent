// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameEditingCore

public enum SpriteTool: String, CaseIterable, Codable, Sendable {
    case brush, eraser, fill, eyedropper

    public var title: GameEditCopy {
        switch self {
        case .brush: return GameEditCopy("Brush", "画笔")
        case .eraser: return GameEditCopy("Eraser", "橡皮擦")
        case .fill: return GameEditCopy("Fill", "填充")
        case .eyedropper: return GameEditCopy("Pick color", "取色")
        }
    }

    public var symbolName: String {
        switch self {
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .fill: return "drop.fill"
        case .eyedropper: return "eyedropper"
        }
    }

    public var editsPixels: Bool { self != .eyedropper }

    public var summary: GameEditCopy {
        switch self {
        case .brush: return GameEditCopy("Paint pixels", "绘制像素")
        case .eraser: return GameEditCopy("Erase pixels", "擦除像素")
        case .fill: return GameEditCopy("Fill area", "填充区域")
        case .eyedropper: return GameEditCopy("Pick color", "取色")
        }
    }
}

/// One gesture's bounded pixel operation. The UI previews points cheaply and
/// the final commit applies this operation to the session's fresh bytes, so a
/// concurrent edit elsewhere in the sheet is not overwritten by a stale copy.
@MainActor
public final class SpriteStroke {
    public let tool: SpriteTool
    public let color: SpriteRGBA
    public let brushSize: Int
    public let clip: SpritePixelRect
    public let frameIndex: Int
    public let originalSize: SpritePixelSize
    public let seed: SpritePixelPoint
    public private(set) var points: [SpritePixelPoint]
    public let fillPreview: SpritePixelImage?

    private static let maximumPoints = 16_384

    public init(tool: SpriteTool, color: SpriteRGBA, brushSize: Int,
                clip: SpritePixelRect, frameIndex: Int,
                originalSize: SpritePixelSize, seed: SpritePixelPoint,
                image: SpritePixelImage) {
        self.tool = tool
        self.color = color
        self.brushSize = min(max(brushSize, 1), 8)
        self.clip = clip
        self.frameIndex = frameIndex
        self.originalSize = originalSize
        self.seed = seed
        self.points = [seed]
        if tool == .fill {
            var preview = image
            _ = preview.floodFill(from: seed, color: color, clip: clip)
            self.fillPreview = preview
        } else {
            self.fillPreview = nil
        }
    }

    public var summary: GameEditCopy { tool.summary }
    public var clampedBrushSize: Int { min(max(brushSize, 1), 8) }

    public func append(_ point: SpritePixelPoint) {
        guard tool == .brush || tool == .eraser else { return }
        guard points.count < Self.maximumPoints else { return }
        if points.last == point { return }
        points.append(point)
    }

    /// Returns the number of changed pixels. Callers validate the image size
    /// before invoking this; a size mismatch would make coordinates unsafe.
    @discardableResult
    public func apply(to image: inout SpritePixelImage) -> Int {
        guard image.size == originalSize, tool.editsPixels else { return 0 }
        let paintColor = tool == .eraser ? SpriteRGBA.clear : color
        switch tool {
        case .brush, .eraser:
            guard let first = points.first else { return 0 }
            var changed = image.drawBrush(at: first, color: paintColor,
                                          brushSize: clampedBrushSize, clip: clip)
            for index in 1..<points.count {
                changed += image.drawStroke(from: points[index - 1], to: points[index],
                                            color: paintColor, brushSize: clampedBrushSize,
                                            clip: clip)
            }
            return changed
        case .fill:
            return image.floodFill(from: seed, color: color, clip: clip)
        case .eyedropper:
            return 0
        }
    }
}
