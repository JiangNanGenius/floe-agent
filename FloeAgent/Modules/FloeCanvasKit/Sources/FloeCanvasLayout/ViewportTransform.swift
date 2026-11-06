import Foundation
import FloeDiagramCore

/// Invertible world ↔ view transform for zoom, pan and Pencil input.
///
/// View coordinates are screen points; the view center maps to `center` in
/// world coordinates and one world unit is `scale` view points:
/// `view = (world - center) * scale + viewCenter`.
///
/// All values are validated: non-finite centers, scales outside `scaleRange`
/// and non-positive view sizes throw `CanvasLayoutError.invalidInput` instead
/// of producing NaN geometry.
public struct CanvasViewportTransform: Codable, Hashable, Sendable {
    /// Allowed zoom range. Wider than the persisted `CanvasViewport` clamp so
    /// hosts can offer deep overview of large canvases; hosts may narrow it.
    public static let scaleRange: ClosedRange<Double> = 0.05...8

    /// World point shown at the view center.
    public var center: DiagramPoint
    /// View points per world unit.
    public var scale: Double
    /// View size in points (e.g. 390×844 on an iPhone split view).
    public var viewSize: DiagramSize

    public init(
        center: DiagramPoint = .zero,
        scale: Double = 1,
        viewSize: DiagramSize
    ) throws {
        guard center.isFinite else {
            throw CanvasLayoutError.invalidInput("viewport center is non-finite")
        }
        guard scale.isFinite, CanvasViewportTransform.scaleRange.contains(scale) else {
            throw CanvasLayoutError.invalidInput(
                "viewport scale \(scale) outside \(CanvasViewportTransform.scaleRange)")
        }
        guard viewSize.isValid else {
            throw CanvasLayoutError.invalidInput("view size is non-positive or non-finite")
        }
        self.center = center
        self.scale = scale
        self.viewSize = viewSize
    }

    private var viewCenter: DiagramPoint {
        DiagramPoint(x: viewSize.width / 2, y: viewSize.height / 2)
    }

    public func worldToView(_ point: DiagramPoint) -> DiagramPoint {
        DiagramPoint(
            x: (point.x - center.x) * scale + viewCenter.x,
            y: (point.y - center.y) * scale + viewCenter.y)
    }

    public func viewToWorld(_ point: DiagramPoint) -> DiagramPoint {
        DiagramPoint(
            x: (point.x - viewCenter.x) / scale + center.x,
            y: (point.y - viewCenter.y) / scale + center.y)
    }

    /// World rect currently visible, expanded by `overscan` view points
    /// (converted to world units) on every side — the query rect for
    /// `CanvasPageLayoutIndex.visibleNodes`.
    public func visibleWorldRect(overscan: Double = 0) -> DiagramRect {
        let worldOverscan = max(0, overscan) / scale
        let halfWidth = viewSize.width / 2 / scale + worldOverscan
        let halfHeight = viewSize.height / 2 / scale + worldOverscan
        return DiagramRect(
            x: center.x - halfWidth, y: center.y - halfHeight,
            width: halfWidth * 2, height: halfHeight * 2)
    }

    /// Converts a constant screen hit target (points) into world units for
    /// the current zoom, so Pencil/touch hit areas stay finger-sized at any
    /// scale.
    public func worldHitTolerance(screenPoints: Double = 12) -> Double {
        max(0, screenPoints) / scale
    }

    /// Pan by a view-space drag delta (points). The world point under the
    /// user's finger stays fixed.
    public func panned(byViewDelta delta: DiagramPoint) -> CanvasViewportTransform {
        var copy = self
        copy.center = DiagramPoint(
            x: center.x - delta.x / scale,
            y: center.y - delta.y / scale)
        return copy
    }

    /// Zoom by a factor, optionally keeping the world point under a view
    /// anchor (e.g. a pinch centroid) fixed. Returns nil when the resulting
    /// scale would leave `scaleRange`.
    public func zoomed(
        byFactor factor: Double,
        anchorViewPoint: DiagramPoint? = nil
    ) -> CanvasViewportTransform? {
        guard factor.isFinite, factor > 0 else { return nil }
        let newScale = scale * factor
        guard CanvasViewportTransform.scaleRange.contains(newScale) else { return nil }
        var copy = self
        copy.scale = newScale
        if let anchor = anchorViewPoint {
            let worldAnchor = viewToWorld(anchor)
            copy.center = DiagramPoint(
                x: worldAnchor.x - (anchor.x - viewCenter.x) / newScale,
                y: worldAnchor.y - (anchor.y - viewCenter.y) / newScale)
        }
        return copy
    }

    /// Transform that fits the given world bounds into the view with padding
    /// on every side. Supports 390pt-class narrow viewports. Returns nil when
    /// the bounds are degenerate beyond a single point.
    public func fitting(
        _ bounds: DiagramRect,
        padding: Double = 32
    ) -> CanvasViewportTransform? {
        guard bounds.isValid, bounds.width > 0, bounds.height > 0 else { return nil }
        let availableWidth = viewSize.width - max(0, padding) * 2
        let availableHeight = viewSize.height - max(0, padding) * 2
        guard availableWidth > 0, availableHeight > 0 else { return nil }
        let fitScale = min(
            availableWidth / bounds.width,
            availableHeight / bounds.height)
        guard fitScale.isFinite else { return nil }
        let clamped = min(
            CanvasViewportTransform.scaleRange.upperBound,
            max(CanvasViewportTransform.scaleRange.lowerBound, fitScale))
        guard let fitted = try? CanvasViewportTransform(
            center: bounds.center,
            scale: clamped,
            viewSize: viewSize) else { return nil }
        return fitted
    }
}
