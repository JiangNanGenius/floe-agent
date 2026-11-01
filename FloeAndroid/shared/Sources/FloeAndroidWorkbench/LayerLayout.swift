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

public extension ImageLayerTransform {
    /// Translation that preserves mirroring, scale and rotation. Rebuilding a
    /// transform from only its center silently reset flipX/flipY (a real CUA
    /// regression), so drag/pinch/rotate gestures must go through these.
    func movedBy(dx: Double, dy: Double, clampToUnit: Bool = true) -> ImageLayerTransform {
        var copy = self
        copy.centerX = clampToUnit ? min(max(centerX + dx, 0), 1) : centerX + dx
        copy.centerY = clampToUnit ? min(max(centerY + dy, 0), 1) : centerY + dy
        return copy
    }

    func scaled(by factor: Double) -> ImageLayerTransform {
        var copy = self
        copy.scale = min(max(scale * factor, 0.1), 5)
        return copy
    }

    /// Adds degrees and normalizes into 0..<360 while preserving flips.
    func rotated(byDegrees degrees: Double) -> ImageLayerTransform {
        var copy = self
        var value = (rotationDegrees + degrees).truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        copy.rotationDegrees = value
        return copy
    }
}

/// Pure gesture→selection mapping shared by the touch UI (and unit-testable):///   * rectangle/ellipse use the drag's START and current point (the CUA bug
///     sampled only the current point, so the marquee began mid-drag);
///   * lasso accumulates samples with bounded spacing/count so a lasso can
///     actually reach the engine's 3-point minimum.
public enum ImageSelectionGesture {
    public static let defaultMinimumSpacing = 0.006
    public static let defaultMaximumPoints = 512

    /// Appends `candidate` when it is far enough from the last sample, capping
    /// the total. The first point is always preserved.
    public static func accumulateLasso(
        _ points: [ImageFreehandStroke.Point],
        candidate: ImageFreehandStroke.Point,
        minimumSpacing: Double = defaultMinimumSpacing,
        maximumPoints: Int = defaultMaximumPoints
    ) -> [ImageFreehandStroke.Point] {
        guard !points.isEmpty else { return [candidate] }
        guard points.count < maximumPoints else { return points }
        guard let last = points.last else { return [candidate] }
        let distance = ((candidate.x - last.x) * (candidate.x - last.x)
            + (candidate.y - last.y) * (candidate.y - last.y)).squareRoot()
        guard distance >= minimumSpacing else { return points }
        return points + [candidate]
    }

    /// Builds the committed shape. Rectangle/ellipse always use `start` and
    /// `current`; lasso requires at least three accumulated points.
    public static func shape(kind: ImageSelectionKind,
                             operation: ImageSelectionOperation,
                             start: ImageFreehandStroke.Point,
                             current: ImageFreehandStroke.Point,
                             lassoPoints: [ImageFreehandStroke.Point]) -> ImageSelectionShape? {
        switch kind {
        case .rectangle, .ellipse:
            return ImageSelectionShape(kind: kind, operation: operation, points: [start, current])
        case .lasso:
            var points = lassoPoints
            if points.isEmpty { points = [start] }
            if let last = points.last,
               last.x != current.x || last.y != current.y {
                points.append(current)
            }
            guard points.count >= 3 else { return nil }
            return ImageSelectionShape(kind: .lasso, operation: operation, points: points)
        }
    }
}

/// Pure brush-stroke assembly for the touch surface (unit-testable). The
/// CUA regression this fixes: `touchesEnded` committed without emitting the
/// final touch location, so every stroke ended halfway to the finger.
public struct InkStrokeBuilder: Sendable, Equatable {
    public private(set) var points: [ImageFreehandStroke.Point] = []
    public private(set) var isActive = false

    public init() {}

    public mutating func begin(_ point: ImageFreehandStroke.Point) {
        points = [point]
        isActive = true
    }

    /// Appends a sample when it is at least `minimumSpacing` from the last one
    /// (0 keeps every sample, e.g. coalesced Pencil input).
    public mutating func move(_ point: ImageFreehandStroke.Point,
                              minimumSpacing: Double = 0) {
        guard isActive else { return }
        guard let last = points.last else {
            points = [point]
            return
        }
        let distance = ((point.x - last.x) * (point.x - last.x)
            + (point.y - last.y) * (point.y - last.y)).squareRoot()
        guard minimumSpacing <= 0 || distance >= minimumSpacing else { return }
        points.append(point)
    }

    /// Emits the final touch location (even if it equals the last sample, the
    /// caller may have moved since), then ends the stroke.
    public mutating func end(_ point: ImageFreehandStroke.Point) {
        guard isActive else { return }
        if points.isEmpty {
            points = [point]
        } else {
            points.append(point)
        }
        isActive = false
    }

    /// Explicit discard: a cancelled touch never commits a partial stroke.
    public mutating func cancel() {
        points = []
        isActive = false
    }

    /// Committed geometry: a tap becomes a small dot (two nearly identical
    /// points so the round-cap stroke renders). Nil when empty.
    public func committedPoints() -> [ImageFreehandStroke.Point]? {
        guard !points.isEmpty else { return nil }
        if points.count == 1 {
            let lone = points[0]
            return [lone, ImageFreehandStroke.Point(x: lone.x + 0.0005, y: lone.y,
                                                    pressure: lone.pressure)]
        }
        var result = points
        if let first = result.first, let last = result.last,
           first.x == last.x, first.y == last.y {
            // Same-position drag: nudge the final point so a dot renders.
            result[result.count - 1] = ImageFreehandStroke.Point(
                x: last.x + 0.0005, y: last.y, pressure: last.pressure)
        }
        return result
    }
}
