// FloeWorkbench — Pure layer layout geometry.
//
// Rendered layer bounds and edge/center alignment math, kept free of
// CoreGraphics so it is identical on macOS tests and iOS and exactly matches
// the renderer's placement transform (see `WorkbenchImageRenderer.place`):
//
//   p' = center + R(rotation) · S(scale, flip) · (p - naturalCenter)
//
// Coordinates are canvas pixels internally; centers are converted back to the
// normalized 0...1 anchor space the model stores. Unit Y is top-leading.

import Foundation

public struct LayerLayoutBox: Sendable, Hashable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var centerX: Double { (minX + maxX) / 2 }
    public var centerY: Double { (minY + maxY) / 2 }
}

public enum LayerLayout {
    /// Transformed canvas-space corner positions (normalized units) of a layer.
    /// Rotation/scale are performed in PIXEL space (natural pixel corners plus
    /// a pixel-space center) and the result is normalized back, so rotated
    /// bounds are not distorted on a non-square canvas — matching the renderer.
    public static func corners(naturalWidth: Double, naturalHeight: Double,
                               canvasSize: (width: Double, height: Double),
                               transform: ImageLayerTransform) -> (x0: Double, y0: Double,
                                                                   x1: Double, y1: Double,
                                                                   x2: Double, y2: Double,
                                                                   x3: Double, y3: Double) {
        let hw = naturalWidth / 2
        let hh = naturalHeight / 2
        let local: [(Double, Double)] = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
        let radians = -transform.rotationDegrees * .pi / 180
        let cosR = cos(radians)
        let sinR = sin(radians)
        let sx = transform.scale * (transform.flipX == true ? -1 : 1)
        let sy = transform.scale * (transform.flipY == true ? -1 : 1)
        let centerPixelX = transform.centerX * canvasSize.width
        let centerPixelY = transform.centerY * canvasSize.height
        var out: [(Double, Double)] = []
        for (lx, ly) in local {
            // Natural Y is top-leading positive-down; renderer flips it to CI
            // bottom-leading before rotation, so negate before the rotation.
            let scaledX = lx * sx
            let scaledY = -ly * sy
            let rx = scaledX * cosR - scaledY * sinR
            let ry = scaledX * sinR + scaledY * cosR
            // Map back to top-leading normalized units.
            let nx = (centerPixelX + rx) / max(1, canvasSize.width)
            let ny = (centerPixelY - ry) / max(1, canvasSize.height)
            out.append((nx, ny))
        }
        return (out[0].0, out[0].1, out[1].0, out[1].1,
                out[2].0, out[2].1, out[3].0, out[3].1)
    }

    /// Axis-aligned rendered bounding box in normalized canvas units. Rotated
    /// layers use the bounding box of the four rotated pixel-space corners.
    public static func renderedBounds(naturalWidth: Double, naturalHeight: Double,
                                      canvasSize: (width: Double, height: Double),
                                      transform: ImageLayerTransform) -> LayerLayoutBox {
        let c = corners(naturalWidth: naturalWidth, naturalHeight: naturalHeight,
                        canvasSize: canvasSize, transform: transform)
        let xs = [c.x0, c.x1, c.x2, c.x3]
        let ys = [c.y0, c.y1, c.y2, c.y3]
        return LayerLayoutBox(minX: xs.min()!, minY: ys.min()!,
                              maxX: xs.max()!, maxY: ys.max()!)
    }

    /// Pixel-space rendered box (used for renderer-parity checks).
    public static func renderedBoundsPixels(naturalWidth: Double, naturalHeight: Double,
                                            canvasSize: (width: Double, height: Double),
                                            transform: ImageLayerTransform) -> LayerLayoutBox {
        let normalized = renderedBounds(naturalWidth: naturalWidth, naturalHeight: naturalHeight,
                                        canvasSize: canvasSize, transform: transform)
        return LayerLayoutBox(minX: normalized.minX * canvasSize.width,
                              minY: normalized.minY * canvasSize.height,
                              maxX: normalized.maxX * canvasSize.width,
                              maxY: normalized.maxY * canvasSize.height)
    }

    /// Center delta (normalized units) each layer must receive so its rendered
    /// edge/center lines up. `entries` carry id, measured natural pixel size
    /// and current transform. Returns id → (dx, dy).
    public static func alignmentDeltas<Entries: Collection>(
        _ entries: Entries,
        alignment: LayerAlignment,
        canvasSize: (width: Double, height: Double)
    ) -> [UUID: (dx: Double, dy: Double)]
    where Entries.Element == LayerLayoutEntry {
        let boxes = entries.map { entry -> (id: UUID, box: LayerLayoutBox) in
            (entry.id, renderedBounds(naturalWidth: entry.naturalWidth,
                                      naturalHeight: entry.naturalHeight,
                                      canvasSize: canvasSize, transform: entry.transform))
        }
        guard boxes.count >= 2 else { return [:] }
        let target: Double
        let keyPath: (LayerLayoutBox) -> Double
        let axisIsX: Bool
        switch alignment {
        case .left: target = boxes.map(\.box.minX).min()!; keyPath = { $0.minX }; axisIsX = true
        case .right: target = boxes.map(\.box.maxX).max()!; keyPath = { $0.maxX }; axisIsX = true
        case .centerX:
            target = boxes.map(\.box.centerX).reduce(0, +) / Double(boxes.count)
            keyPath = { $0.centerX }; axisIsX = true
        case .top: target = boxes.map(\.box.minY).min()!; keyPath = { $0.minY }; axisIsX = false
        case .bottom: target = boxes.map(\.box.maxY).max()!; keyPath = { $0.maxY }; axisIsX = false
        case .centerY:
            target = boxes.map(\.box.centerY).reduce(0, +) / Double(boxes.count)
            keyPath = { $0.centerY }; axisIsX = false
        }
        var deltas: [UUID: (dx: Double, dy: Double)] = [:]
        for item in boxes {
            let delta = target - keyPath(item.box)
            deltas[item.id] = axisIsX ? (delta, 0) : (0, delta)
        }
        return deltas
    }
}

public struct LayerLayoutEntry: Sendable, Hashable {
    public var id: UUID
    public var naturalWidth: Double
    public var naturalHeight: Double
    public var transform: ImageLayerTransform

    public init(id: UUID, naturalWidth: Double, naturalHeight: Double, transform: ImageLayerTransform) {
        self.id = id; self.naturalWidth = naturalWidth
        self.naturalHeight = naturalHeight; self.transform = transform
    }
}
