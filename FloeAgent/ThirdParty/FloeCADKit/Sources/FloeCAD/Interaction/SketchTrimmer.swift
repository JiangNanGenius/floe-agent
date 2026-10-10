//
//  SketchTrimmer.swift
//  openshape3d
//
//  Sketch Trim (spec §1.14): tapping an entity span deletes the span between
//  its nearest intersections with the other entities. Lines split exactly,
//  arcs split by angle, circles become arcs; rects and polygons explode into
//  lines first (they stay composite otherwise). Intersections are computed
//  against the other entities' tessellated segments.
//

import Foundation
import simd

nonisolated enum SketchTrimmer {

    /// Fragments that replace `entity` after deleting the span under `p`,
    /// or nil when the entity kind cannot be trimmed. An empty array means
    /// the whole entity goes away (no intersections bound the span).
    static func trim(
        entity: SketchEntity, at p: SIMD2<Double>, in sketch: Sketch
    ) -> [SketchEntity]? {
        let obstacles = segments(
            for: sketch.entities.filter { $0.id != entity.id }
        )
        switch entity {
        case let .line(_, a, b):
            return trimLine(a: a, b: b, at: p, obstacles: obstacles)
        case let .circle(_, center, radius):
            return trimCircle(center: center, radius: radius, at: p, obstacles: obstacles)
        case let .arc(_, center, radius, startAngle, endAngle):
            return trimArc(
                center: center, radius: radius,
                startAngle: startAngle, endAngle: endAngle,
                at: p, obstacles: obstacles
            )
        case let .rect(_, lo, hi):
            let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
            return trimExplodedLoop(corners, at: p, obstacles: obstacles)
        case let .polygon(_, center, radius, sides, rotation):
            let corners = SketchEntity.polygonPoints(
                center: center, radius: radius, sides: sides, rotation: rotation
            )
            return trimExplodedLoop(corners, at: p, obstacles: obstacles)
        case .ellipse, .spline:
            // No exact parameter split for these; trim is out of scope (a spline
            // trim would have to re-fit the curve, changing its shape).
            return nil
        }
    }

    // MARK: - Per-kind trims

    private static func trimLine(
        a: SIMD2<Double>, b: SIMD2<Double>, at p: SIMD2<Double>,
        obstacles: [(SIMD2<Double>, SIMD2<Double>)]
    ) -> [SketchEntity] {
        var params: [Double] = []
        for (s0, s1) in obstacles {
            if let t = segmentIntersectionParam(a: a, b: b, s0: s0, s1: s1) {
                params.append(t)
            }
        }
        let cuts = deduplicated(params.filter { $0 > 1e-6 && $0 < 1 - 1e-6 })
        guard !cuts.isEmpty else { return [] }

        let tapT = min(max(simd_dot(p - a, b - a) / simd_length_squared(b - a), 0), 1)
        let prev = cuts.last { $0 < tapT } ?? 0
        let next = cuts.first { $0 >= tapT } ?? 1

        var fragments: [SketchEntity] = []
        if prev > 1e-6 {
            fragments.append(.line(id: UUID(), a: a, b: a + (b - a) * prev))
        }
        if next < 1 - 1e-6 {
            fragments.append(.line(id: UUID(), a: a + (b - a) * next, b: b))
        }
        return fragments
    }

    private static func trimCircle(
        center: SIMD2<Double>, radius: Double, at p: SIMD2<Double>,
        obstacles: [(SIMD2<Double>, SIMD2<Double>)]
    ) -> [SketchEntity] {
        var angles: [Double] = []
        for (s0, s1) in obstacles {
            angles.append(contentsOf: circleIntersectionAngles(
                center: center, radius: radius, s0: s0, s1: s1
            ))
        }
        // Cyclic dedupe in angle space.
        let cuts = deduplicated(angles.map(normalizedAngle).sorted(), cyclePeriod: 2 * .pi)
        guard cuts.count >= 2 else { return [] }

        let tapAngle = normalizedAngle(atan2(p.y - center.y, p.x - center.x))
        // The removed span is [prev, next) around the tap (cyclic); what
        // remains is the complementary CCW arc next → prev.
        let next = cuts.first { $0 > tapAngle } ?? cuts[0]
        let prev = cuts.last { $0 <= tapAngle } ?? cuts[cuts.count - 1]
        return [.arc(id: UUID(), center: center, radius: radius, startAngle: next, endAngle: prev)]
    }

    private static func trimArc(
        center: SIMD2<Double>, radius: Double,
        startAngle: Double, endAngle: Double,
        at p: SIMD2<Double>,
        obstacles: [(SIMD2<Double>, SIMD2<Double>)]
    ) -> [SketchEntity] {
        let sweep = SketchEntity.arcSweep(startAngle: startAngle, endAngle: endAngle)
        guard sweep > 1e-9 else { return [] }
        var params: [Double] = []
        for (s0, s1) in obstacles {
            for angle in circleIntersectionAngles(center: center, radius: radius, s0: s0, s1: s1) {
                let t = SketchEntity.arcSweep(startAngle: startAngle, endAngle: angle) / sweep
                if t > 1e-6, t < 1 - 1e-6 {
                    params.append(t)
                }
            }
        }
        let cuts = deduplicated(params)
        guard !cuts.isEmpty else { return [] }

        let tapAngle = atan2(p.y - center.y, p.x - center.x)
        let tapT = min(SketchEntity.arcSweep(startAngle: startAngle, endAngle: tapAngle) / sweep, 1)
        let prev = cuts.last { $0 < tapT } ?? 0
        let next = cuts.first { $0 >= tapT } ?? 1

        var fragments: [SketchEntity] = []
        if prev > 1e-6 {
            fragments.append(.arc(
                id: UUID(), center: center, radius: radius,
                startAngle: startAngle, endAngle: startAngle + sweep * prev
            ))
        }
        if next < 1 - 1e-6 {
            fragments.append(.arc(
                id: UUID(), center: center, radius: radius,
                startAngle: startAngle + sweep * next, endAngle: endAngle
            ))
        }
        return fragments
    }

    /// Rect/polygon: explode the loop into edge lines, trim the edge nearest
    /// the tap (its siblings count as obstacles), keep the other edges whole.
    private static func trimExplodedLoop(
        _ corners: [SIMD2<Double>], at p: SIMD2<Double>,
        obstacles: [(SIMD2<Double>, SIMD2<Double>)]
    ) -> [SketchEntity]? {
        guard corners.count >= 3 else { return nil }
        var edges: [(a: SIMD2<Double>, b: SIMD2<Double>)] = []
        for i in 0..<corners.count {
            edges.append((corners[i], corners[(i + 1) % corners.count]))
        }
        var nearest = 0
        var nearestDistance = Double.infinity
        for (i, edge) in edges.enumerated() {
            let d = SketchHitTester.distanceToSegment(p, a: edge.a, b: edge.b)
            if d < nearestDistance {
                nearestDistance = d
                nearest = i
            }
        }
        var fragments: [SketchEntity] = []
        var allObstacles = obstacles
        for (i, edge) in edges.enumerated() where i != nearest {
            fragments.append(.line(id: UUID(), a: edge.a, b: edge.b))
            allObstacles.append(edge)
        }
        // Sibling edges only touch at shared corners (t = 0/1), which the
        // cut filter drops — real cuts come from crossing entities.
        fragments.append(contentsOf: trimLine(
            a: edges[nearest].a, b: edges[nearest].b, at: p, obstacles: allObstacles
        ))
        return fragments
    }

    // MARK: - Intersection primitives

    /// Parameter t on a→b where segment s0→s1 crosses it, or nil.
    static func segmentIntersectionParam(
        a: SIMD2<Double>, b: SIMD2<Double>,
        s0: SIMD2<Double>, s1: SIMD2<Double>
    ) -> Double? {
        let r = b - a
        let s = s1 - s0
        let denom = r.x * s.y - r.y * s.x
        guard abs(denom) > 1e-12 else { return nil } // parallel/collinear
        let d = s0 - a
        let t = (d.x * s.y - d.y * s.x) / denom
        let u = (d.x * r.y - d.y * r.x) / denom
        guard t >= -1e-9, t <= 1 + 1e-9, u >= -1e-9, u <= 1 + 1e-9 else { return nil }
        return t
    }

    /// Angles (radians) where segment s0→s1 crosses the circle.
    static func circleIntersectionAngles(
        center: SIMD2<Double>, radius: Double,
        s0: SIMD2<Double>, s1: SIMD2<Double>
    ) -> [Double] {
        let d = s1 - s0
        let f = s0 - center
        let a = simd_length_squared(d)
        guard a > 1e-18 else { return [] }
        let b = 2 * simd_dot(f, d)
        let c = simd_length_squared(f) - radius * radius
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return [] }
        let root = discriminant.squareRoot()
        var angles: [Double] = []
        for u in [(-b - root) / (2 * a), (-b + root) / (2 * a)] where u >= -1e-9 && u <= 1 + 1e-9 {
            let point = s0 + d * u
            angles.append(atan2(point.y - center.y, point.x - center.x))
        }
        return angles
    }

    // MARK: - Tessellation (plane-local)

    /// All entities as plane-local segments (arcs/circles/ellipses/polygons
    /// tessellated at the profile-detection density).
    static func segments(for entities: [SketchEntity]) -> [(SIMD2<Double>, SIMD2<Double>)] {
        var out: [(SIMD2<Double>, SIMD2<Double>)] = []
        for entity in entities {
            switch entity {
            case let .line(_, a, b):
                out.append((a, b))
            case let .rect(_, lo, hi):
                appendLoop([lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)], &out)
            case let .circle(_, center, radius):
                appendLoop(SketchEntity.ellipsePoints(
                    center: center, radiusX: radius, radiusY: radius,
                    rotation: 0, segments: 64
                ), &out)
            case let .arc(_, center, radius, startAngle, endAngle):
                let points = SketchEntity.arcPoints(
                    center: center, radius: radius,
                    startAngle: startAngle, endAngle: endAngle,
                    segmentsPerTurn: 64
                )
                for i in 1..<max(points.count, 1) {
                    out.append((points[i - 1], points[i]))
                }
            case let .ellipse(_, center, radiusX, radiusY, rotation):
                appendLoop(SketchEntity.ellipsePoints(
                    center: center, radiusX: radiusX, radiusY: radiusY,
                    rotation: rotation, segments: 64
                ), &out)
            case let .polygon(_, center, radius, sides, rotation):
                appendLoop(SketchEntity.polygonPoints(
                    center: center, radius: radius, sides: sides, rotation: rotation
                ), &out)
            case let .spline(_, points, closed):
                // A spline still ACTS as an obstacle for trimming other
                // entities, even though it cannot itself be trimmed.
                let curve = SketchEntity.splinePoints(points, closed: closed)
                if closed {
                    appendLoop(curve, &out)
                } else if curve.count >= 2 {
                    for i in 1..<curve.count { out.append((curve[i - 1], curve[i])) }
                }
            }
        }
        return out
    }

    private static func appendLoop(
        _ points: [SIMD2<Double>], _ out: inout [(SIMD2<Double>, SIMD2<Double>)]
    ) {
        guard points.count >= 2 else { return }
        for i in 0..<points.count {
            out.append((points[i], points[(i + 1) % points.count]))
        }
    }

    // MARK: - Helpers

    private static func normalizedAngle(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return a
    }

    /// Sorted values with near-duplicates merged (tessellation vertices can
    /// report the same crossing twice). `cyclePeriod` also merges the ends.
    private static func deduplicated(
        _ values: [Double], cyclePeriod: Double? = nil, tolerance: Double = 1e-4
    ) -> [Double] {
        let sorted = values.sorted()
        var out: [Double] = []
        for v in sorted {
            if let last = out.last, v - last < tolerance { continue }
            out.append(v)
        }
        if let period = cyclePeriod, out.count >= 2,
           (out[0] + period) - out[out.count - 1] < tolerance {
            out.removeLast()
        }
        return out
    }
}
