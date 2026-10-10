//
//  SketchMirror.swift
//  openshape3d
//
//  Pure geometry for sketch mirroring (Task A3): reflect a sketch entity
//  across an infinite axis line. Nonisolated + Double to match the kernel;
//  MirrorSketchEntitiesCommand (Commands.swift) consumes this to build the
//  mirrored copies plus the linking `.symmetric` constraints.
//

import Foundation
import simd

/// Reflect a plane-local point across the infinite line through `a`→`b`
/// (`reflected = 2·proj_line(p) − p`). A degenerate axis (`a == b`) falls back
/// to point reflection about `a`.
nonisolated func reflectPoint(
    _ p: SIMD2<Double>, acrossA a: SIMD2<Double>, b: SIMD2<Double>
) -> SIMD2<Double> {
    let d = b - a
    let len2 = simd_dot(d, d)
    guard len2 > 1e-18 else { return 2 * a - p }  // degenerate axis → point reflection
    let t = simd_dot(p - a, d) / len2
    let proj = a + d * t
    return 2 * proj - p
}

/// Reflect a sketch entity across the infinite line through `a`→`b`, producing
/// a NEW entity (fresh UUID) of the same case on the mirrored side.
///
/// A reflection reverses orientation, so directed data is handled per case:
/// - line: both endpoints reflect.
/// - rect: both corners reflect, then lo/hi are recomputed component-wise so
///   the axis-aligned box stays valid even when the reflection swaps corners.
/// - circle: center reflects, radius preserved.
/// - arc: center reflects; because CCW becomes CW, the start/end angles are
///   reflected AND swapped (`start' = 2φ−end`, `end' = 2φ−start`, where φ is
///   the axis direction angle) so the mirrored arc renders on the correct side.
/// - ellipse/polygon: center reflects; the rotation angle maps `rot → 2φ−rot`
///   (radii / side count / radius preserved).
nonisolated func mirroredSketchEntity(
    _ e: SketchEntity, acrossA a: SIMD2<Double>, b: SIMD2<Double>
) -> SketchEntity {
    func reflect(_ p: SIMD2<Double>) -> SIMD2<Double> {
        reflectPoint(p, acrossA: a, b: b)
    }
    // Axis direction angle φ; a direction θ reflects to 2φ − θ.
    let axisAngle = atan2(b.y - a.y, b.x - a.x)
    let newID = UUID()

    switch e {
    case let .line(_, p0, p1):
        return .line(id: newID, a: reflect(p0), b: reflect(p1))

    case let .rect(_, mn, mx):
        let r0 = reflect(mn)
        let r1 = reflect(mx)
        let lo = SIMD2<Double>(Swift.min(r0.x, r1.x), Swift.min(r0.y, r1.y))
        let hi = SIMD2<Double>(Swift.max(r0.x, r1.x), Swift.max(r0.y, r1.y))
        return .rect(id: newID, min: lo, max: hi)

    case let .circle(_, c, r):
        return .circle(id: newID, center: reflect(c), radius: r)

    case let .arc(_, c, r, startAngle, endAngle):
        // Orientation flips: reflect and swap the sweep endpoints so the
        // mirrored arc keeps the same CCW-normalized sweep magnitude.
        return .arc(
            id: newID, center: reflect(c), radius: r,
            startAngle: 2 * axisAngle - endAngle,
            endAngle: 2 * axisAngle - startAngle
        )

    case let .ellipse(_, c, rx, ry, rotation):
        return .ellipse(
            id: newID, center: reflect(c),
            radiusX: rx, radiusY: ry, rotation: 2 * axisAngle - rotation
        )

    case let .polygon(_, c, r, sides, rotation):
        return .polygon(
            id: newID, center: reflect(c),
            radius: r, sides: sides, rotation: 2 * axisAngle - rotation
        )

    case let .spline(_, points, closed):
        // Reflecting the fit points reflects the curve exactly. Reversing the
        // order preserves the traversal direction after the mirror flips
        // orientation, matching how the arc case swaps its sweep endpoints.
        return .spline(id: newID, points: points.map(reflect).reversed(), closed: closed)
    }
}

nonisolated extension SketchEntity {
    /// Solver point roles this entity exposes — must match
    /// `SketchSolverBridge.mutableSlots`. Used by `MirrorSketchEntitiesCommand`
    /// to emit one `.symmetric` constraint per corresponding original/mirror
    /// point pair.
    var symmetricPointRoles: [PointRole] {
        switch self {
        case .line, .rect: return [.endpointA, .endpointB]
        case .circle, .arc, .ellipse, .polygon: return [.center]
        // An open spline exposes its ends, matching `mutableSlots`; a closed
        // one has no distinguished point pair to mirror.
        case let .spline(_, _, closed): return closed ? [] : [.endpointA, .endpointB]
        }
    }

    /// Plane-local coordinate of the given role, or `nil` if this entity does
    /// not expose it. Mirrors the roles in `symmetricPointRoles`.
    func symmetricPoint(for role: PointRole) -> SIMD2<Double>? {
        switch (self, role) {
        case let (.line(_, a, _), .endpointA): return a
        case let (.line(_, _, b), .endpointB): return b
        case let (.rect(_, mn, _), .endpointA): return mn
        case let (.rect(_, _, mx), .endpointB): return mx
        case let (.circle(_, c, _), .center): return c
        case let (.arc(_, c, _, _, _), .center): return c
        case let (.ellipse(_, c, _, _, _), .center): return c
        case let (.polygon(_, c, _, _, _), .center): return c
        default: return nil
        }
    }
}
