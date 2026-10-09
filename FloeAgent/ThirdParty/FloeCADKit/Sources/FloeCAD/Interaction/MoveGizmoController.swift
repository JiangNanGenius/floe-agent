//
//  MoveGizmoController.swift
//  openshape3d
//
//  Move gizmo interaction: analytic hit-testing of axis arrows and plane
//  handles (in gizmo-local space), and drag math that turns rays into
//  translation deltas.
//

import Foundation
import simd

nonisolated enum GizmoPart: CaseIterable, Equatable {
    case xAxis, yAxis, zAxis
    case xyPlane, yzPlane, zxPlane
    /// Rotation rings; the axis is the axis of rotation (ring plane normal).
    case xRing, yRing, zRing

    var axisDirection: SIMD3<Float> {
        switch self {
        case .xAxis, .yzPlane, .xRing: SIMD3(1, 0, 0)
        case .yAxis, .zxPlane, .yRing: SIMD3(0, 1, 0)
        case .zAxis, .xyPlane, .zRing: SIMD3(0, 0, 1)
        }
    }

    var isPlane: Bool {
        switch self {
        case .xyPlane, .yzPlane, .zxPlane: true
        default: false
        }
    }

    var isRing: Bool {
        switch self {
        case .xRing, .yRing, .zRing: true
        default: false
        }
    }

    var isArrow: Bool {
        switch self {
        case .xAxis, .yAxis, .zAxis: true
        default: false
        }
    }

    /// Axis display name for numeric entry ("Move X").
    var axisName: String {
        switch self {
        case .xAxis, .yzPlane, .xRing: "X"
        case .yAxis, .zxPlane, .yRing: "Y"
        case .zAxis, .xyPlane, .zRing: "Z"
        }
    }
}

/// Gizmo state rendered by the viewport and hit by drags.
nonisolated struct GizmoState: Equatable {
    var origin: SIMD3<Float>
    /// World-units-per-gizmo-unit, chosen for constant on-screen size.
    var scale: Float
    var highlighted: GizmoPart?
}

nonisolated enum GizmoGeometry {
    /// Hit radius around an axis arrow, in gizmo units (inflated for touch).
    static let axisHitRadius: Float = 0.16
    static let axisLength: Float = 1.0
    /// Plane handles span [planeMin, planeMax]² on their plane — clustered
    /// close to the centre (Shapr3D style), but chunky enough to hit: a tile
    /// seen at an angle projects to a narrow parallelogram, and a near-miss on
    /// a skinny tile used to fall through to something else entirely.
    static let planeMin: Float = 0.13
    static let planeMax: Float = 0.38
    /// Rotation arcs sit at this radius from the origin (gizmo units), outside
    /// the plane handles and clear of the arrow shafts. The hit test uses the
    /// full circle here (forgiving for touch) while a prominent quarter-arc
    /// curved arrow is drawn as the grab affordance.
    static let ringRadius: Float = 0.62
    /// Radial hit tolerance around a ring (inflated for touch — a fat band so
    /// the rotation handle is easy to grab, which was the whole complaint).
    static let ringHitWidth: Float = 0.22

    /// Nearest gizmo part hit by the ray, if any. Ray and state in world space.
    static func hitTest(ray: Ray, gizmo: GizmoState) -> GizmoPart? {
        // Work in gizmo space: unit scale, origin at zero.
        let localOrigin = (ray.origin - gizmo.origin) / gizmo.scale
        let localRay = Ray(origin: localOrigin, direction: ray.direction)

        var best: (part: GizmoPart, t: Float)?

        // Plane handles first — they sit inside the arrows and are easier to
        // hit accidentally with the capsule test otherwise.
        for part in GizmoPart.allCases where part.isPlane {
            let normal = part.axisDirection
            if let t = localRay.intersect(planePoint: .zero, planeNormal: normal) {
                let p = localRay.point(at: t)
                let coords = planeCoordinates(of: p, normal: part)
                if coords.x >= planeMin, coords.x <= planeMax,
                   coords.y >= planeMin, coords.y <= planeMax {
                    if best == nil || t < best!.t {
                        best = (part, t)
                    }
                }
            }
        }

        for part in [GizmoPart.xAxis, .yAxis, .zAxis] {
            if let t = distanceAlongRayToAxisCapsule(ray: localRay, axis: part.axisDirection) {
                if best == nil || t < best!.t {
                    best = (part, t)
                }
            }
        }

        // Rings last: where a ring crosses an arrow, the tie goes to the
        // arrow (strict < above), keeping translation drags stable.
        for part in [GizmoPart.xRing, .yRing, .zRing] {
            if let t = localRay.intersect(planePoint: .zero, planeNormal: part.axisDirection) {
                let p = localRay.point(at: t)
                if abs(simd_length(p) - ringRadius) <= ringHitWidth {
                    if best == nil || t < best!.t {
                        best = (part, t)
                    }
                }
            }
        }
        return best?.part
    }

    /// In-plane basis of a ring: angle 0 along `u`, growing toward `v`
    /// (right-handed about the ring's rotation axis: axis × u = v).
    static func ringBasis(for part: GizmoPart) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
        switch part {
        case .xRing: (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        case .yRing: (SIMD3(0, 0, 1), SIMD3(1, 0, 0))
        default: (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        }
    }

    private static func planeCoordinates(of p: SIMD3<Float>, normal part: GizmoPart) -> SIMD2<Float> {
        switch part {
        case .xyPlane: SIMD2(p.x, p.y)
        case .yzPlane: SIMD2(p.y, p.z)
        case .zxPlane: SIMD2(p.z, p.x)
        default: .zero
        }
    }

    /// Ray-vs-capsule around the axis segment [0, axisLength].
    private static func distanceAlongRayToAxisCapsule(ray: Ray, axis: SIMD3<Float>) -> Float? {
        // Closest points between the ray and the axis line.
        let w0 = ray.origin
        let a = simd_dot(ray.direction, ray.direction)
        let b = simd_dot(ray.direction, axis)
        let c = simd_dot(axis, axis)
        let d = simd_dot(ray.direction, w0)
        let e = simd_dot(axis, w0)
        let denom = a * c - b * b
        guard abs(denom) > 1e-9 else { return nil }
        var tRay = (b * e - c * d) / denom
        var tAxis = (a * e - b * d) / denom
        tAxis = min(max(tAxis, 0), axisLength)
        // Re-project for the clamped axis point.
        tRay = simd_dot(axis * tAxis - w0, ray.direction) / a
        guard tRay > 0 else { return nil }
        let separation = simd_length(w0 + ray.direction * tRay - axis * tAxis)
        return separation <= axisHitRadius ? tRay : nil
    }
}

/// One in-flight gizmo drag: anchors on begin, yields world-space translation
/// deltas as the ray moves.
nonisolated struct GizmoDragSession {
    let part: GizmoPart
    let startOrigin: SIMD3<Float>
    private let anchor: SIMD3<Float>
    /// Ring drags only: running unwrapped total, and the previous sample it
    /// was accumulated from (see `rotationDelta`).
    private var accumulatedRotation: Float = 0
    private var lastAngle: Float?

    init?(part: GizmoPart, gizmo: GizmoState, ray: Ray) {
        self.part = part
        self.startOrigin = gizmo.origin
        guard let anchor = Self.constrainedPoint(part: part, origin: gizmo.origin, ray: ray) else {
            return nil
        }
        self.anchor = anchor
    }

    func translationDelta(for ray: Ray) -> SIMD3<Float>? {
        guard !part.isRing,
              let current = Self.constrainedPoint(part: part, origin: startOrigin, ray: ray)
        else {
            return nil
        }
        return current - anchor
    }

    /// Total rotation since the drag began (radians, right-handed about the
    /// ring axis), UNWRAPPED — it keeps growing past ±π so a user can spin a
    /// body more than half a turn in one gesture.
    ///
    /// Measuring `current - anchor` and wrapping to (-π, π] (as this did)
    /// caps a drag at ±180° and flips sign at the boundary: passing half a
    /// turn snapped the body ~358° backwards, because both callers apply the
    /// result as an ABSOLUTE angle against the pre-drag transform
    /// (2026-08-25 review round 2). Instead accumulate the per-frame step,
    /// which is always well under π at gesture sample rates.
    mutating func rotationDelta(for ray: Ray) -> Float? {
        guard part.isRing,
              let current = Self.constrainedPoint(part: part, origin: startOrigin, ray: ray)
        else {
            return nil
        }
        let currentAngle = Self.ringAngle(of: current - startOrigin, part: part)
        let previous = lastAngle ?? Self.ringAngle(of: anchor - startOrigin, part: part)
        var step = currentAngle - previous
        if step > .pi { step -= 2 * .pi }
        if step <= -.pi { step += 2 * .pi }
        accumulatedRotation += step
        lastAngle = currentAngle
        return accumulatedRotation
    }

    /// Angle (radians, in the ring's own basis) where this ring drag was
    /// grabbed. The rotation orbit draws its swept arc from here, so the arc
    /// starts under the user's finger the way Shapr3D's does.
    var ringStartAngle: Float? {
        guard part.isRing else { return nil }
        return Self.ringAngle(of: anchor - startOrigin, part: part)
    }

    private static func ringAngle(of offset: SIMD3<Float>, part: GizmoPart) -> Float {
        let (u, v) = GizmoGeometry.ringBasis(for: part)
        return atan2(simd_dot(offset, v), simd_dot(offset, u))
    }

    /// Point on the drag constraint (axis line, plane, or ring plane) nearest
    /// to the ray.
    private static func constrainedPoint(
        part: GizmoPart, origin: SIMD3<Float>, ray: Ray
    ) -> SIMD3<Float>? {
        if part.isPlane || part.isRing {
            guard let t = ray.intersect(planePoint: origin, planeNormal: part.axisDirection) else {
                return nil
            }
            return ray.point(at: t)
        }
        // Closest point on the axis line to the ray.
        let axis = part.axisDirection
        let w0 = ray.origin - origin
        let a = simd_dot(ray.direction, ray.direction)
        let b = simd_dot(ray.direction, axis)
        let c = simd_dot(axis, axis)
        let d = simd_dot(ray.direction, w0)
        let e = simd_dot(axis, w0)
        let denom = a * c - b * b
        guard abs(denom) > 1e-6 else { return nil } // ray parallel to axis
        let tAxis = (a * e - b * d) / denom
        return origin + axis * tAxis
    }
}
