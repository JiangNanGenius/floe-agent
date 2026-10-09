//
//  SketchHitTester.swift
//  openshape3d
//
//  Plane-local hit testing for sketch entities: nearest entity by
//  distance-to-outline, and nearest control point (endpoints, centers,
//  radius handles) for drag-editing. Also applies control/translate edits
//  back onto entities.
//

import Foundation
import simd

nonisolated enum SketchHitTester {

    /// Outline picking must not swallow a small profile interior
    /// when zoomed in. A fixed millimetre floor becomes a huge screen target.
    static func screenPickTolerance(worldUnitsPerPoint: Double) -> Double {
        max(1e-6, 16 * worldUnitsPerPoint)
    }

    static func screenControlPointTolerance(worldUnitsPerPoint: Double) -> Double {
        max(1e-6, 24 * worldUnitsPerPoint)
    }

    struct EntityHit {
        var entity: SketchEntity
        var distance: Double
    }

    struct RayEntityHit {
        var entity: SketchEntity
        var distance: Float
        var outlineDistance: Double
    }

    static func nearestEntity(along ray: Ray, in sketches: [Sketch], tolerance: Double,
                              maximumDepth: Float = .infinity) -> RayEntityHit? {
        var best: RayEntityHit?
        for sketch in sketches where !sketch.isHidden {
            let plane = sketch.plane
            guard let depth = ray.intersect(
                planePoint: SIMD3<Float>(plane.origin), planeNormal: SIMD3<Float>(plane.normal)),
                depth <= maximumDepth + 0.01 else { continue }
            let local = plane.toLocal(SIMD3<Double>(ray.point(at: depth)))
            guard let hit = nearestEntity(to: local, in: sketch.entities, tolerance: tolerance)
            else { continue }
            if let best, depth > best.distance + 0.001
                || (abs(depth - best.distance) <= 0.001 && hit.distance >= best.outlineDistance) {
                continue
            }
            best = RayEntityHit(entity: hit.entity, distance: depth, outlineDistance: hit.distance)
        }
        return best
    }

    /// A draggable handle on an entity.
    enum ControlKind: Equatable, Sendable {
        case lineStart
        case lineEnd
        /// 0 = min, 1 = (max.x, min.y), 2 = max, 3 = (min.x, max.y).
        case rectCorner(Int)
        case center
        /// Circle rim / ellipse x-radius / polygon vertex 0 (radius+rotation).
        case radius
        /// Ellipse y-radius handle.
        case radiusY
        case arcStart
        case arcEnd
    }

    struct ControlHit {
        var entity: SketchEntity
        var kind: ControlKind
        var point: SIMD2<Double>
        var distance: Double
    }

    /// A selectable model point (endpoint/center) on an entity, addressed by
    /// the `PointRole` the constraint solver understands. Only the points the
    /// solver treats as variables are returned (line endpoints, rect diagonal
    /// corners as min/max, and circle/arc/ellipse/polygon centers), so a point
    /// selection maps one-to-one onto a `ConstraintRef` (plan §C3).
    struct PointHit {
        var entityID: UUID
        var role: PointRole
        var point: SIMD2<Double>
        var distance: Double
    }

    // MARK: - Queries

    static func nearestEntity(
        to p: SIMD2<Double>, in entities: [SketchEntity], tolerance: Double
    ) -> EntityHit? {
        var best: EntityHit?
        for entity in entities {
            let d = distance(from: p, to: entity)
            if d <= tolerance, best == nil || d < best!.distance {
                best = EntityHit(entity: entity, distance: d)
            }
        }
        return best
    }

    static func nearestControlPoint(
        to p: SIMD2<Double>, in entities: [SketchEntity], tolerance: Double
    ) -> ControlHit? {
        var best: ControlHit?
        for entity in entities {
            for (kind, point) in controlPoints(of: entity) {
                let d = simd_length(point - p)
                if d <= tolerance, best == nil || d < best!.distance {
                    best = ControlHit(entity: entity, kind: kind, point: point, distance: d)
                }
            }
        }
        return best
    }

    /// Nearest solver-addressable point (endpoint/center) to `p`, tagged with
    /// its `PointRole`. Used to select individual points for constraints
    /// (plan §C3).
    static func nearestPoint(
        to p: SIMD2<Double>, in entities: [SketchEntity], tolerance: Double,
        preservingLineInterior: Bool = false
    ) -> PointHit? {
        var best: PointHit?
        for entity in entities {
            for (role, point) in modelPoints(of: entity) {
                let d = simd_length(point - p)
                if d <= tolerance, best == nil || d < best!.distance {
                    best = PointHit(entityID: entity.id, role: role, point: point, distance: d)
                }
            }
        }
        if preservingLineInterior, let point = best,
           let hit = nearestEntity(to: p, in: entities, tolerance: tolerance),
           case let .line(_, a, b) = hit.entity {
            let delta = b - a, length = simd_length(delta)
            if length > 1e-6 {
                let fraction = simd_dot(p - a, delta) / (length * length)
                // Oversized endpoint targets must not consume the middle of a
                // short line. Exact points (including other geometry) still win.
                if fraction > 0.25, fraction < 0.75,
                   point.distance > length * 0.25,
                   hit.distance < point.distance { return nil }
            }
        }
        return best
    }

    /// The points the constraint solver treats as variables for an entity,
    /// paired with their `PointRole` (mirrors `SketchSolverBridge.mutableSlots`).
    static func modelPoints(of entity: SketchEntity) -> [(role: PointRole, point: SIMD2<Double>)] {
        switch entity {
        case let .line(_, a, b):
            return [(.endpointA, a), (.endpointB, b)]
        case let .rect(_, lo, hi):
            return [(.endpointA, lo), (.endpointB, hi)]
        case let .circle(_, center, _), let .arc(_, center, _, _, _),
             let .ellipse(_, center, _, _, _), let .polygon(_, center, _, _, _):
            return [(.center, center)]
        case let .spline(_, points, closed):
            guard !closed, let a = points.first, let b = points.last,
                  points.count >= 2 else { return [] }
            return [(.endpointA, a), (.endpointB, b)]
        }
    }

    static func controlPoints(of entity: SketchEntity) -> [(kind: ControlKind, point: SIMD2<Double>)] {
        switch entity {
        case let .line(_, a, b):
            return [(.lineStart, a), (.lineEnd, b)]
        case let .rect(_, lo, hi):
            return [
                (.rectCorner(0), lo),
                (.rectCorner(1), SIMD2(hi.x, lo.y)),
                (.rectCorner(2), hi),
                (.rectCorner(3), SIMD2(lo.x, hi.y)),
                (.center, (lo + hi) / 2),
            ]
        case let .circle(_, center, radius):
            return [(.center, center), (.radius, center + SIMD2(radius, 0))]
        case let .arc(_, center, radius, startAngle, endAngle):
            return [
                (.center, center),
                (.arcStart, SketchEntity.arcPoint(center: center, radius: radius, angle: startAngle)),
                (.arcEnd, SketchEntity.arcPoint(center: center, radius: radius, angle: endAngle)),
            ]
        case let .ellipse(_, center, radiusX, radiusY, rotation):
            let cosR = cos(rotation)
            let sinR = sin(rotation)
            return [
                (.center, center),
                (.radius, center + SIMD2(cosR, sinR) * radiusX),
                (.radiusY, center + SIMD2(-sinR, cosR) * radiusY),
            ]
        case let .polygon(_, center, radius, sides, rotation):
            let vertex0 = SketchEntity.polygonPoints(
                center: center, radius: radius, sides: sides, rotation: rotation
            ).first ?? center
            return [(.center, center), (.radius, vertex0)]
        case let .spline(_, points, _):
            // Every FIT point is draggable — that is how a spline is edited.
            guard let first = points.first, let last = points.last else { return [] }
            return [(.lineStart, first), (.lineEnd, last)]
        }
    }

    // MARK: - Distance to outline

    static func distance(from p: SIMD2<Double>, to entity: SketchEntity) -> Double {
        switch entity {
        case let .line(_, a, b):
            return distanceToSegment(p, a: a, b: b)
        case let .rect(_, lo, hi):
            let c0 = lo
            let c1 = SIMD2(hi.x, lo.y)
            let c2 = hi
            let c3 = SIMD2(lo.x, hi.y)
            return min(
                min(distanceToSegment(p, a: c0, b: c1), distanceToSegment(p, a: c1, b: c2)),
                min(distanceToSegment(p, a: c2, b: c3), distanceToSegment(p, a: c3, b: c0))
            )
        case let .circle(_, center, radius):
            return abs(simd_length(p - center) - radius)
        case let .arc(_, center, radius, startAngle, endAngle):
            let sweep = SketchEntity.arcSweep(startAngle: startAngle, endAngle: endAngle)
            let angle = atan2(p.y - center.y, p.x - center.x)
            if SketchEntity.arcSweep(startAngle: startAngle, endAngle: angle) <= sweep {
                return abs(simd_length(p - center) - radius)
            }
            let a = SketchEntity.arcPoint(center: center, radius: radius, angle: startAngle)
            let b = SketchEntity.arcPoint(center: center, radius: radius, angle: endAngle)
            return min(simd_length(p - a), simd_length(p - b))
        case let .ellipse(_, center, radiusX, radiusY, rotation):
            return distanceToLoop(p, SketchEntity.ellipsePoints(
                center: center, radiusX: radiusX, radiusY: radiusY,
                rotation: rotation, segments: 64
            ))
        case let .polygon(_, center, radius, sides, rotation):
            return distanceToLoop(p, SketchEntity.polygonPoints(
                center: center, radius: radius, sides: sides, rotation: rotation
            ))
        case let .spline(_, points, closed):
            let curve = SketchEntity.splinePoints(points, closed: closed)
            guard curve.count >= 2 else {
                return curve.first.map { simd_length(p - $0) } ?? .greatestFiniteMagnitude
            }
            if closed { return distanceToLoop(p, curve) }
            // Open curve: nearest of the tessellated spans.
            var best = Double.greatestFiniteMagnitude
            for i in 0..<(curve.count - 1) {
                best = min(best, distanceToSegment(p, a: curve[i], b: curve[i + 1]))
            }
            return best
        }
    }

    static func distanceToSegment(
        _ p: SIMD2<Double>, a: SIMD2<Double>, b: SIMD2<Double>
    ) -> Double {
        let ab = b - a
        let lengthSquared = simd_length_squared(ab)
        guard lengthSquared > 1e-18 else { return simd_length(p - a) }
        let t = min(max(simd_dot(p - a, ab) / lengthSquared, 0), 1)
        return simd_length(p - (a + ab * t))
    }

    private static func distanceToLoop(_ p: SIMD2<Double>, _ points: [SIMD2<Double>]) -> Double {
        guard points.count >= 2 else { return .infinity }
        var best = Double.infinity
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            best = min(best, distanceToSegment(p, a: a, b: b))
        }
        return best
    }

    // MARK: - Edits

    /// The entity with the given control point dragged to `p` (id preserved).
    static func applying(
        _ kind: ControlKind, at p: SIMD2<Double>, to entity: SketchEntity
    ) -> SketchEntity {
        switch (entity, kind) {
        case let (.line(id, _, b), .lineStart):
            return .line(id: id, a: p, b: b)
        case let (.line(id, a, _), .lineEnd):
            return .line(id: id, a: a, b: p)
        case let (.rect(_, lo, hi), .center):
            return translated(entity, by: p - (lo + hi) / 2)
        case let (.rect(id, lo, hi), .rectCorner(index)):
            let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
            let opposite = corners[(index + 2) % 4]
            return .rect(
                id: id,
                min: SIMD2(min(p.x, opposite.x), min(p.y, opposite.y)),
                max: SIMD2(max(p.x, opposite.x), max(p.y, opposite.y))
            )
        case let (.circle(id, _, radius), .center):
            return .circle(id: id, center: p, radius: radius)
        case let (.circle(id, center, _), .radius):
            return .circle(id: id, center: center, radius: max(simd_length(p - center), 1e-3))
        case let (.arc(id, _, radius, startAngle, endAngle), .center):
            return .arc(id: id, center: p, radius: radius, startAngle: startAngle, endAngle: endAngle)
        case let (.arc(id, center, radius, startAngle, endAngle), .arcStart):
            let b = SketchEntity.arcPoint(center: center, radius: radius, angle: endAngle)
            let s = sagitta(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle)
            return arcFromChord(id: id, a: p, b: b, sagitta: s) ?? entity
        case let (.arc(id, center, radius, startAngle, endAngle), .arcEnd):
            let a = SketchEntity.arcPoint(center: center, radius: radius, angle: startAngle)
            let s = sagitta(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle)
            return arcFromChord(id: id, a: a, b: p, sagitta: s) ?? entity
        case let (.ellipse(id, _, radiusX, radiusY, rotation), .center):
            return .ellipse(id: id, center: p, radiusX: radiusX, radiusY: radiusY, rotation: rotation)
        case let (.ellipse(id, center, _, radiusY, rotation), .radius):
            let local = rotated(p - center, by: -rotation)
            return .ellipse(
                id: id, center: center,
                radiusX: max(abs(local.x), 1e-3), radiusY: radiusY, rotation: rotation
            )
        case let (.ellipse(id, center, radiusX, _, rotation), .radiusY):
            let local = rotated(p - center, by: -rotation)
            return .ellipse(
                id: id, center: center,
                radiusX: radiusX, radiusY: max(abs(local.y), 1e-3), rotation: rotation
            )
        case let (.polygon(id, _, radius, sides, rotation), .center):
            return .polygon(id: id, center: p, radius: radius, sides: sides, rotation: rotation)
        case let (.polygon(id, center, _, sides, _), .radius):
            let delta = p - center
            let radius = simd_length(delta)
            guard radius > 1e-3 else { return entity }
            return .polygon(
                id: id, center: center, radius: radius,
                sides: sides, rotation: atan2(delta.y, delta.x)
            )
        default:
            return entity
        }
    }

    /// The entity shifted by `delta` (id preserved).
    static func translated(_ entity: SketchEntity, by delta: SIMD2<Double>) -> SketchEntity {
        switch entity {
        case let .line(id, a, b):
            return .line(id: id, a: a + delta, b: b + delta)
        case let .rect(id, lo, hi):
            return .rect(id: id, min: lo + delta, max: hi + delta)
        case let .circle(id, center, radius):
            return .circle(id: id, center: center + delta, radius: radius)
        case let .arc(id, center, radius, startAngle, endAngle):
            return .arc(
                id: id, center: center + delta, radius: radius,
                startAngle: startAngle, endAngle: endAngle
            )
        case let .ellipse(id, center, radiusX, radiusY, rotation):
            return .ellipse(
                id: id, center: center + delta,
                radiusX: radiusX, radiusY: radiusY, rotation: rotation
            )
        case let .polygon(id, center, radius, sides, rotation):
            return .polygon(
                id: id, center: center + delta, radius: radius,
                sides: sides, rotation: rotation
            )
        case let .spline(id, points, closed):
            return .spline(id: id, points: points.map { $0 + delta }, closed: closed)
        }
    }

    // MARK: - Arc chord math (shared with the arc drawing flow)

    /// Circular arc from endpoints + sagitta (perpendicular height of the arc
    /// midpoint over the chord midpoint; positive bulges left of a→b).
    static func arcFromChord(
        id: UUID, a: SIMD2<Double>, b: SIMD2<Double>, sagitta: Double
    ) -> SketchEntity? {
        let chord = b - a
        let halfChord = simd_length(chord) / 2
        guard halfChord > 1e-3, abs(sagitta) > 1e-4 else { return nil }
        let mid = (a + b) / 2
        let n = simd_normalize(SIMD2(-chord.y, chord.x))
        // Center on the chord's perpendicular bisector: |C-A| = |C-M_arc| = r.
        let offset = (sagitta * sagitta - halfChord * halfChord) / (2 * sagitta)
        let center = mid + n * offset
        let radius = (sagitta * sagitta + halfChord * halfChord) / (2 * abs(sagitta))
        let angleA = atan2(a.y - center.y, a.x - center.x)
        let angleB = atan2(b.y - center.y, b.x - center.x)
        let bulge = mid + n * sagitta
        let angleM = atan2(bulge.y - center.y, bulge.x - center.x)
        // Orient the CCW sweep so it passes through the bulge point.
        let sweepAB = SketchEntity.arcSweep(startAngle: angleA, endAngle: angleB)
        let sweepAM = SketchEntity.arcSweep(startAngle: angleA, endAngle: angleM)
        return sweepAM <= sweepAB
            ? .arc(id: id, center: center, radius: radius, startAngle: angleA, endAngle: angleB)
            : .arc(id: id, center: center, radius: radius, startAngle: angleB, endAngle: angleA)
    }

    /// Signed sagitta of an arc w.r.t. its chord start→end (positive = left).
    static func sagitta(
        center: SIMD2<Double>, radius: Double, startAngle: Double, endAngle: Double
    ) -> Double {
        let sweep = SketchEntity.arcSweep(startAngle: startAngle, endAngle: endAngle)
        let a = SketchEntity.arcPoint(center: center, radius: radius, angle: startAngle)
        let b = SketchEntity.arcPoint(center: center, radius: radius, angle: endAngle)
        let m = SketchEntity.arcPoint(center: center, radius: radius, angle: startAngle + sweep / 2)
        let chord = b - a
        guard simd_length(chord) > 1e-9 else { return radius * 2 }
        let n = simd_normalize(SIMD2(-chord.y, chord.x))
        return simd_dot(m - (a + b) / 2, n)
    }

    private static func rotated(_ v: SIMD2<Double>, by angle: Double) -> SIMD2<Double> {
        let c = cos(angle)
        let s = sin(angle)
        return SIMD2(v.x * c - v.y * s, v.x * s + v.y * c)
    }
}
