//
//  LiveDimensionKit.swift
//  openshape3d
//
//  Spec §1.1/§2.2 — the dimensions Shapr3D shows WHILE you draw: a rectangle
//  reads its width and height as you drag, a circle reads Ø, a line reads its
//  length. They are a readout of the in-progress stroke, not sketch dimensions:
//  nothing is stored, nothing constrains, and they vanish on release (the
//  driving dimensions in `SketchDimension` are a separate, persisted thing).
//
//  Pure geometry over the pending entity, in plane-local coordinates. The
//  overlay projects the returned points through the camera, so the same
//  descriptors work head-on or in a rotated view.
//

import Foundation
import simd

nonisolated enum LiveDimensionKit {

    nonisolated enum Kind: String, Equatable, Sendable {
        case length, diameter, radius, angle

        /// Leader shown before the number, the way CAD reads it.
        var prefix: String {
            switch self {
            case .length, .angle: ""
            case .diameter: "Ø"
            case .radius: "R"
            }
        }

        /// Whether the dimension is terminated by a short tick ON the measured
        /// geometry. A diameter is drawn straight ACROSS the shape, so without
        /// a tick its arrowheads float against the curve with nothing marking
        /// where the measurement actually meets the circle; an offset
        /// dimension already registers via its witness lines.
        var drawsEdgeTicks: Bool { self == .diameter }
    }

    /// One measurement to draw: the dimension line runs `start + offset` to
    /// `end + offset`, with witness lines back to `start` and `end`.
    ///
    /// `offset` is zero for measurements drawn straight across the geometry
    /// (a diameter), non-zero for ones held clear of it (a rectangle's sides).
    nonisolated struct Dimension: Equatable, Sendable, Identifiable {
        var id: String
        var kind: Kind
        /// Millimetres — the caller formats it in the user's display unit.
        var value: Double
        var start: SIMD2<Double>
        var end: SIMD2<Double>
        var offset: SIMD2<Double>
        /// Pending arcs also expose their sweep. These points describe the
        /// actual arc; the overlay offsets them in screen space so the angular
        /// leader stays legible at any zoom.
        var arcCenter: SIMD2<Double>? = nil
        var arcPoints: [SIMD2<Double>] = []

        var lineStart: SIMD2<Double> { start + offset }
        var lineEnd: SIMD2<Double> { end + offset }

        /// Where the value sits. Offset measurements label their midpoint; a
        /// diameter is drawn through the centre, where the circle's own centre
        /// marker and the drag origin already live, so its label slides along
        /// the line to stay clear of them.
        var labelPoint: SIMD2<Double> {
            let mid = (lineStart + lineEnd) / 2
            guard kind.drawsEdgeTicks else { return mid }
            return mid + (lineEnd - mid) * Dimension.labelSlide
        }

        /// Fraction of the half-span the diameter label slides off centre.
        static let labelSlide: Double = 0.45
    }

    /// How far clear of the geometry an offset dimension sits, as a fraction of
    /// the measured span. Proportional rather than absolute so the annotation
    /// looks the same whether the user drew 5 mm or 5 m.
    static let offsetRatio: Double = 0.14
    /// Below this the measurement is noise from a tap, not a drawn shape.
    static let minimumSpan: Double = 1e-6

    /// Live measurements for an in-progress entity.
    ///
    /// `towards` is the cursor's current plane-local position. A circle's
    /// diameter is drawn along the drag direction, the way Shapr3D swings it
    /// with your finger; without the hint it falls back to horizontal.
    static func dimensions(
        for entity: SketchEntity, towards: SIMD2<Double>? = nil, circleUsesRadius: Bool = false
    ) -> [Dimension] {
        switch entity {
        case let .line(_, a, b):
            let span = simd_length(b - a)
            guard span > minimumSpan else { return [] }
            return [Dimension(id: "length", kind: .length, value: span,
                              start: a, end: b,
                              offset: perpendicular(from: a, to: b) * (span * offsetRatio))]

        case let .rect(_, lo, hi):
            var out = [Dimension]()
            let width = abs(hi.x - lo.x), height = abs(hi.y - lo.y)
            // Width along the bottom edge, pushed DOWN and away from the rect;
            // height along the left edge, pushed left. Same sides Shapr3D uses.
            if width > minimumSpan {
                out.append(Dimension(
                    id: "width", kind: .length, value: width,
                    start: SIMD2(lo.x, lo.y), end: SIMD2(hi.x, lo.y),
                    offset: SIMD2(0, -max(height, width) * offsetRatio)))
            }
            if height > minimumSpan {
                out.append(Dimension(
                    id: "height", kind: .length, value: height,
                    start: SIMD2(lo.x, lo.y), end: SIMD2(lo.x, hi.y),
                    offset: SIMD2(-max(height, width) * offsetRatio, 0)))
            }
            return out

        case let .circle(_, center, radius):
            guard radius > minimumSpan else { return [] }
            let axis = direction(from: center, towards: towards)
            return [Dimension(id: circleUsesRadius ? "radius" : "diameter",
                              kind: circleUsesRadius ? .radius : .diameter,
                              value: radius * (circleUsesRadius ? 1 : 2),
                              start: circleUsesRadius ? center : center - axis * radius,
                              end: center + axis * radius, offset: .zero)]

        case let .polygon(_, center, radius, sides, rotation):
            guard radius > minimumSpan, sides >= 3 else { return [] }
            // Polygons are defined by their circumscribed circle, so that is
            // what the readout has to report — measuring a flat would show a
            // number the user cannot type back in.
            let axis = SIMD2(cos(rotation), sin(rotation))
            return [Dimension(id: "diameter", kind: .diameter, value: radius * 2,
                              start: center - axis * radius, end: center + axis * radius,
                              offset: .zero)]

        case let .ellipse(_, center, radiusX, radiusY, rotation):
            var out = [Dimension]()
            let major = SIMD2(cos(rotation), sin(rotation))
            let minor = SIMD2(-major.y, major.x)
            if radiusX > minimumSpan {
                out.append(Dimension(id: "major", kind: .diameter, value: radiusX * 2,
                                     start: center - major * radiusX,
                                     end: center + major * radiusX, offset: .zero))
            }
            if radiusY > minimumSpan {
                out.append(Dimension(id: "minor", kind: .diameter, value: radiusY * 2,
                                     start: center - minor * radiusY,
                                     end: center + minor * radiusY, offset: .zero))
            }
            return out

        case let .arc(_, center, radius, startAngle, endAngle):
            guard radius > minimumSpan else { return [] }
            let sweep = SketchEntity.arcSweep(startAngle: startAngle, endAngle: endAngle)
            let end = center + SIMD2(cos(endAngle), sin(endAngle)) * radius
            let count = max(8, Int(ceil(sweep / (.pi / 64))))
            let points = (0...count).map { index in
                let angle = startAngle + sweep * Double(index) / Double(count)
                return center + SIMD2(cos(angle), sin(angle)) * radius
            }
            // Native's pending three-point arc reads both defining quantities:
            // R continues outward from the second endpoint, while the sweep
            // follows a curved leader outside the arc with two radius rays.
            return [Dimension(id: "radius", kind: .radius, value: radius,
                              start: center,
                              end: end, offset: .zero,
                              arcCenter: center),
                    Dimension(id: "sweep", kind: .angle, value: sweep * 180 / .pi,
                              start: points[0], end: points[points.count - 1],
                              offset: .zero, arcCenter: center, arcPoints: points)]

        case .spline:
            // A fit spline has no single number that defines it; showing its
            // polyline length would imply an editable dimension that is not.
            return []
        }
    }

    /// Formatted label, e.g. "Ø661.60 mm" — the caller supplies the unit so
    /// the readout follows the Units setting.
    static func label(_ dimension: Dimension, unit: DisplayUnit) -> String {
        if dimension.kind == .angle {
            let nearest = dimension.value.rounded()
            return abs(dimension.value - nearest) < 0.005
                ? String(format: "%.0f°", nearest)
                : String(format: "%.2f°", dimension.value)
        }
        return dimension.kind.prefix + unit.lengthString(fromMM: dimension.value)
    }

    // MARK: - Helpers

    /// Unit normal to a→b, to the LEFT of travel.
    private static func perpendicular(
        from a: SIMD2<Double>, to b: SIMD2<Double>
    ) -> SIMD2<Double> {
        let d = b - a
        let length = simd_length(d)
        guard length > 1e-12 else { return SIMD2(0, 1) }
        return SIMD2(-d.y / length, d.x / length)
    }

    private static func direction(
        from center: SIMD2<Double>, towards: SIMD2<Double>?
    ) -> SIMD2<Double> {
        guard let towards else { return SIMD2(1, 0) }
        let d = towards - center
        let length = simd_length(d)
        return length > 1e-12 ? d / length : SIMD2(1, 0)
    }
}
