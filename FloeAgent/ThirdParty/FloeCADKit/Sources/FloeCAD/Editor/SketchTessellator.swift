//
//  SketchTessellator.swift
//  openshape3d
//
//  Turns sketch entities (plane-local 2D) into world-space line segments for
//  the viewport overlay.
//

import Foundation
import simd
import Euclid

nonisolated enum SketchTessellator {
    static let circleSegments = 64

    /// Triangulated fill for a closed profile (holes cut out), as world-space
    /// triangles for the viewport overlay. This is the Shapr3D "fill color"
    /// affordance showing a region can be pulled into 3D.
    static func fillTriangles(
        for profile: Profile,
        holes: [Profile],
        on plane: SketchPlane
    ) -> [SIMD3<Float>] {
        // A 2D triangulation, not a mesh CSG: `Euclid.Mesh.fill([paths])`
        // unions the filled loops and a subpath fill is a symmetric
        // difference — both BSP booleans, exponential on a thousand-vertex
        // spline outline, and this runs inside the scene getter on the main
        // thread (gotcha 24: a 72-point cam wedged the app for minutes).
        let (vertices, triangles) = PolygonTriangulator.triangulate(
            outer: profile.loop, holes: holes.map(\.loop))
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(triangles.count)
        for index in triangles {
            let world = plane.toWorld(vertices[index])
            out.append(SIMD3(Float(world.x), Float(world.y), Float(world.z)))
        }
        return out
    }

    static func segments(for entities: [SketchEntity], on plane: SketchPlane) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        for entity in entities {
            switch entity {
            case let .line(_, a, b):
                appendSegment(a, b, plane, &out)
            case let .rect(_, lo, hi):
                let c0 = lo
                let c1 = SIMD2(hi.x, lo.y)
                let c2 = hi
                let c3 = SIMD2(lo.x, hi.y)
                appendSegment(c0, c1, plane, &out)
                appendSegment(c1, c2, plane, &out)
                appendSegment(c2, c3, plane, &out)
                appendSegment(c3, c0, plane, &out)
            case let .circle(_, center, radius):
                var previous = center + SIMD2(radius, 0)
                for i in 1...circleSegments {
                    let angle = Double(i) / Double(circleSegments) * 2 * .pi
                    let point = center + SIMD2(cos(angle), sin(angle)) * radius
                    appendSegment(previous, point, plane, &out)
                    previous = point
                }
            case let .arc(_, center, radius, startAngle, endAngle):
                let points = SketchEntity.arcPoints(
                    center: center, radius: radius,
                    startAngle: startAngle, endAngle: endAngle,
                    segmentsPerTurn: circleSegments
                )
                appendPolyline(points, closed: false, plane, &out)
            case let .ellipse(_, center, radiusX, radiusY, rotation):
                let points = SketchEntity.ellipsePoints(
                    center: center, radiusX: radiusX, radiusY: radiusY,
                    rotation: rotation, segments: circleSegments
                )
                appendPolyline(points, closed: true, plane, &out)
            case let .polygon(_, center, radius, sides, rotation):
                let points = SketchEntity.polygonPoints(
                    center: center, radius: radius, sides: sides, rotation: rotation
                )
                appendPolyline(points, closed: true, plane, &out)
            case let .spline(_, points, closed):
                appendPolyline(
                    SketchEntity.splinePoints(points, closed: closed),
                    closed: closed, plane, &out
                )
            }
        }
        return out
    }

    // MARK: - Dashed rendering (construction geometry, spec §3.3)

    /// Dash pattern in plane/world units.
    static let dashLength: Float = 0.5
    static let dashGap: Float = 0.3

    /// Dashed variant of `segments(for:on:)` for construction entities.
    static func dashedSegments(
        for entities: [SketchEntity], on plane: SketchPlane,
        worldUnitsPerPoint: Double? = nil
    ) -> [SIMD3<Float>] {
        // Construction strokes are a screen annotation, not model-sized gaps.
        // Preserve the legacy pattern for callers without a viewport scale.
        let scale = worldUnitsPerPoint.flatMap { $0.isFinite && $0 > 0 ? Float($0) : nil }
        return dashed(segments(for: entities, on: plane),
                      dash: scale.map { $0 * 8 } ?? dashLength,
                      gap: scale.map { $0 * 4 } ?? dashGap)
    }

    /// Splits solid line-batch segments (point pairs) into short dashes.
    /// Pieces shorter than one dash+gap period (tessellated curves) keep the
    /// dash duty cycle so curves still read as dashed.
    static func dashed(_ segments: [SIMD3<Float>], dash: Float, gap: Float) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        let period = dash + gap
        var i = 0
        while i + 1 < segments.count {
            let a = segments[i]
            let b = segments[i + 1]
            i += 2
            let delta = b - a
            let length = simd_length(delta)
            guard length > 1e-6 else { continue }
            let direction = delta / length
            if length <= period {
                out.append(a)
                out.append(a + direction * (length * dash / period))
                continue
            }
            var t: Float = 0
            while t < length {
                let end = min(t + dash, length)
                out.append(a + direction * t)
                out.append(a + direction * end)
                t += period
            }
        }
        return out
    }

    private static func appendPolyline(
        _ points: [SIMD2<Double>], closed: Bool,
        _ plane: SketchPlane, _ out: inout [SIMD3<Float>]
    ) {
        guard points.count >= 2 else { return }
        for i in 1..<points.count {
            appendSegment(points[i - 1], points[i], plane, &out)
        }
        if closed {
            appendSegment(points[points.count - 1], points[0], plane, &out)
        }
    }

    private static func appendSegment(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>,
        _ plane: SketchPlane, _ out: inout [SIMD3<Float>]
    ) {
        let wa = plane.toWorld(a)
        let wb = plane.toWorld(b)
        out.append(SIMD3(Float(wa.x), Float(wa.y), Float(wa.z)))
        out.append(SIMD3(Float(wb.x), Float(wb.y), Float(wb.z)))
    }
}
