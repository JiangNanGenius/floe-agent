import Foundation
import FloeCanvasCore
import FloeDiagramCore

/// Pure geometry adapters between the canvas snapshot model (center-anchored
/// frames, optional rotation) and the diagram layout engine (origin-anchored
/// rects). Adapters are sign-preserving: negative centers, extents and
/// rotations round-trip without flips or normalization.
public enum CanvasLayoutGeometry {
    /// Largest absolute world coordinate this module will pass to the
    /// diagram spatial index. Together with `safeWorldSpan` this keeps the
    /// index's Double→Int cell conversion AND its
    /// `(x1-x0+1) * (y1-y0+1)` Int multiplication inside Int64: cells per
    /// axis ≤ safeWorldSpan/32 ≈ 3.1e5, so the product ≤ ~1e11 ≪ Int64.max.
    public static let safeWorldExtent: Double = 1e15

    /// Largest width/height this module will pass to the spatial index.
    /// Matches the diagram size validity cap (1e7) so oversized extents are
    /// rejected before the cell-count multiplication can overflow Int.
    public static let safeWorldSpan: Double = 1e7

    /// True when a world rect is finite, positive-sized, within the safe
    /// span on both axes AND within the safe extent on every corner — i.e.
    /// safe to insert into or query against the diagram spatial index
    /// without trapping on Double→Int conversion or cell-count overflow.
    public static func isSafeWorldRect(_ rect: DiagramRect) -> Bool {
        guard rect.isValid else { return false }
        guard rect.width <= safeWorldSpan, rect.height <= safeWorldSpan else { return false }
        return abs(rect.x) <= safeWorldExtent
            && abs(rect.y) <= safeWorldExtent
            && abs(rect.maxX) <= safeWorldExtent
            && abs(rect.maxY) <= safeWorldExtent
    }

    /// True when a query rect is safe to hand to the spatial index (same
    /// guards as insertion; viewport-sized queries are far below them).
    public static func isSafeQueryRect(_ rect: DiagramRect) -> Bool {
        isSafeWorldRect(rect)
    }

    /// True when all four coordinates are finite and the size is positive —
    /// the "well-formed" test that separates `.degenerateNodeFrame` /
    /// `.degenerateRegionFrame` from the range-based
    /// `.coordinatesOutOfRange`.
    public static func isFinitePositiveRect(_ rect: DiagramRect) -> Bool {
        rect.width > 0 && rect.height > 0
            && rect.x.isFinite && rect.y.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
    }

    /// World-space rect of a center-anchored snapshot frame.
    public static func rect(from frame: CanvasGeometry.Frame) -> DiagramRect {
        DiagramRect(
            x: frame.center.x - frame.size.width / 2,
            y: frame.center.y - frame.size.height / 2,
            width: frame.size.width,
            height: frame.size.height)
    }

    /// Center-anchored snapshot frame of a world-space rect.
    public static func frame(from rect: DiagramRect) -> CanvasGeometry.Frame {
        CanvasGeometry.Frame(
            center: .init(x: rect.x + rect.width / 2, y: rect.y + rect.height / 2),
            size: .init(width: rect.width, height: rect.height))
    }

    /// Axis-aligned world bounds of a possibly rotated node frame. The canvas
    /// spatial index and hit tests operate on these bounds; fine-grained
    /// rotated containment stays a UI concern.
    public static func rotatedBounds(
        _ frame: CanvasGeometry.Frame,
        rotationDegrees: Double
    ) -> DiagramRect {
        let base = rect(from: frame)
        let angle = rotationDegrees.truncatingRemainder(dividingBy: 360)
        guard angle != 0 else { return base }
        let radians = angle * .pi / 180
        // Half extents of the rotated rectangle projected onto the axes.
        let cosTheta = abs(cos(radians)), sinTheta = abs(sin(radians))
        let halfWidth = (frame.size.width * cosTheta + frame.size.height * sinTheta) / 2
        let halfHeight = (frame.size.width * sinTheta + frame.size.height * cosTheta) / 2
        return DiagramRect(
            x: frame.center.x - halfWidth,
            y: frame.center.y - halfHeight,
            width: halfWidth * 2,
            height: halfHeight * 2)
    }

    /// Deterministic innermost-region rule: a point belongs to the smallest
    /// region whose rect contains it; ties break on the smaller region ID.
    public static func innermostRegion(
        containing point: DiagramPoint,
        among candidates: [(id: UUID, rect: DiagramRect)]
    ) -> UUID? {
        candidates
            .filter { $0.rect.contains(point) }
            .sorted {
                let areaA = $0.rect.width * $0.rect.height
                let areaB = $1.rect.width * $1.rect.height
                if areaA != areaB { return areaA < areaB }
                return $0.id.uuidString < $1.id.uuidString
            }
            .first?.id
    }
}
