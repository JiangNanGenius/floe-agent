//
//  Constraints.swift
//  openshape3d
//
//  Geometric constraint residuals for the 2D sketch solver (Phase C).
//  Each type conforms to `ConstraintResidual` (declared by the solver in
//  Solver.swift) and expresses one geometric relation as a set of scalar
//  residuals that are exactly zero when the relation is satisfied.
//
//  Variable model (shared contract): a 2D point with index `i` occupies the
//  flat variable pair (2*i, 2*i+1). Scalar params kept as free variables
//  (radius) are addressed by their own flat index (`radiusVar`); scalar
//  TARGETS (distance, angle) are constants baked into the constraint.
//
//  The solver differentiates numerically, so only the residual VALUES must be
//  correct here — no analytic Jacobians are required.
//

import Foundation
import simd

// MARK: - Shared helpers

/// Read the 2D point with point-index `i` out of the flat variable vector.
private nonisolated func point(_ vars: [Double], _ i: Int) -> SIMD2<Double> {
    SIMD2(vars[2 * i], vars[2 * i + 1])
}

/// Flat variable indices occupied by point-index `i`.
private nonisolated func pointIndices(_ i: Int) -> [Int] { [2 * i, 2 * i + 1] }

/// 2D scalar cross product (z-component of the 3D cross).
private nonisolated func cross2(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    a.x * b.y - a.y * b.x
}

/// Wrap an angle difference into (-π, π].
private nonisolated func wrapAngle(_ a: Double) -> Double {
    atan2(sin(a), cos(a))
}

// MARK: - Coincidence / connection

/// Two points occupy the same location (A - B = 0).
nonisolated struct CoincidentConstraint: ConstraintResidual {
    let pA: Int
    let pB: Int
    init(pA: Int, pB: Int) { self.pA = pA; self.pB = pB }

    var variableIndices: [Int] { pointIndices(pA) + pointIndices(pB) }
    var residualCount: Int { 2 }
    func residuals(_ vars: [Double]) -> [Double] {
        let d = point(vars, pA) - point(vars, pB)
        return [d.x, d.y]
    }
}

/// Circle/arc centers coincide (identical math to `CoincidentConstraint`,
/// distinct type so callers read `center` roles clearly).
nonisolated struct ConcentricConstraint: ConstraintResidual {
    let cA: Int
    let cB: Int
    init(cA: Int, cB: Int) { self.cA = cA; self.cB = cB }

    var variableIndices: [Int] { pointIndices(cA) + pointIndices(cB) }
    var residualCount: Int { 2 }
    func residuals(_ vars: [Double]) -> [Double] {
        let d = point(vars, cA) - point(vars, cB)
        return [d.x, d.y]
    }
}

/// Point `p` sits on the infinite line through A-B (A/B extended).
nonisolated struct ColinearPointConstraint: ConstraintResidual {
    let p: Int
    let lA: Int
    let lB: Int
    init(p: Int, lA: Int, lB: Int) { self.p = p; self.lA = lA; self.lB = lB }

    var variableIndices: [Int] { pointIndices(p) + pointIndices(lA) + pointIndices(lB) }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        // Normalized: the residual is the point's perpendicular distance to
        // the line in mm — NOT cross2 raw, whose mm² value scales with the
        // line's length and made the conflict gate over-sensitive on long
        // lines and blind on short ones (playbook S1 fast-follow).
        let a = point(vars, lA)
        let dir = point(vars, lB) - a
        let len = simd_length(dir)
        guard len > 1e-12 else { return [simd_length(point(vars, p) - a)] }
        return [cross2(dir, point(vars, p) - a) / len]
    }
}

/// `p` is the midpoint of segment A-B (p = (A + B) / 2).
nonisolated struct MidpointConstraint: ConstraintResidual {
    let p: Int
    let lA: Int
    let lB: Int
    init(p: Int, lA: Int, lB: Int) { self.p = p; self.lA = lA; self.lB = lB }

    var variableIndices: [Int] { pointIndices(p) + pointIndices(lA) + pointIndices(lB) }
    var residualCount: Int { 2 }
    func residuals(_ vars: [Double]) -> [Double] {
        let mid = (point(vars, lA) + point(vars, lB)) * 0.5
        let d = point(vars, p) - mid
        return [d.x, d.y]
    }
}

// MARK: - Axis alignment

/// Points A and B share a Y coordinate (segment/pair is horizontal): yB - yA = 0.
nonisolated struct HorizontalConstraint: ConstraintResidual {
    let pA: Int
    let pB: Int
    init(pA: Int, pB: Int) { self.pA = pA; self.pB = pB }

    var variableIndices: [Int] { pointIndices(pA) + pointIndices(pB) }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        [point(vars, pB).y - point(vars, pA).y]
    }
}

/// Points A and B share an X coordinate (segment/pair is vertical): xB - xA = 0.
nonisolated struct VerticalConstraint: ConstraintResidual {
    let pA: Int
    let pB: Int
    init(pA: Int, pB: Int) { self.pA = pA; self.pB = pB }

    var variableIndices: [Int] { pointIndices(pA) + pointIndices(pB) }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        [point(vars, pB).x - point(vars, pA).x]
    }
}

// MARK: - Lock

/// Pin a point to a fixed world location (Lock).
nonisolated struct FixedPointConstraint: ConstraintResidual {
    let p: Int
    let target: SIMD2<Double>
    init(p: Int, target: SIMD2<Double>) { self.p = p; self.target = target }

    var variableIndices: [Int] { pointIndices(p) }
    var residualCount: Int { 2 }
    func residuals(_ vars: [Double]) -> [Double] {
        let d = point(vars, p) - target
        return [d.x, d.y]
    }
}

/// Fix a derived midpoint without introducing an independent point variable.
nonisolated struct FixedMidpointConstraint: ConstraintResidual {
    let a: Int
    let b: Int
    let target: SIMD2<Double>
    var variableIndices: [Int] { pointIndices(a) + pointIndices(b) }
    var residualCount: Int { 2 }
    func residuals(_ vars: [Double]) -> [Double] {
        let d = (point(vars, a) + point(vars, b)) / 2 - target
        return [d.x, d.y]
    }
}

// MARK: - Distance dimensions

/// Distance between two points equals `distance` (|B - A| - d = 0).
nonisolated struct DistanceConstraint: ConstraintResidual {
    let pA: Int
    let pB: Int
    let distance: Double
    init(pA: Int, pB: Int, distance: Double) {
        self.pA = pA; self.pB = pB; self.distance = distance
    }

    var variableIndices: [Int] { pointIndices(pA) + pointIndices(pB) }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        [simd_length(point(vars, pB) - point(vars, pA)) - distance]
    }
}

/// Distance between A and B measured along ONE axis (0 = x, 1 = y) equals
/// `distance`: sign·(vB − vA) − d = 0. `sign` is captured from the geometry
/// the constraint was built on so the pair keeps its orientation — a
/// rectangle dimensioned to a new width grows or shrinks, never flips
/// through zero and turns inside out. (A rect's two corners are its only
/// solver points; this is what makes its width and height dimensionable.)
nonisolated struct AxisDistanceConstraint: ConstraintResidual {
    let pA: Int
    let pB: Int
    let axis: Int
    let sign: Double
    let distance: Double
    init(pA: Int, pB: Int, axis: Int, sign: Double, distance: Double) {
        self.pA = pA; self.pB = pB; self.axis = axis
        self.sign = sign >= 0 ? 1 : -1
        self.distance = distance
    }

    var variableIndices: [Int] { [2 * pA + axis, 2 * pB + axis] }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        [sign * (vars[2 * pB + axis] - vars[2 * pA + axis]) - distance]
    }
}

/// Perpendicular distance from point `p` to the infinite line A-B equals
/// `distance` (unsigned distance − d = 0).
nonisolated struct PointDistanceToLineConstraint: ConstraintResidual {
    let p: Int
    let lA: Int
    let lB: Int
    let distance: Double
    init(p: Int, lA: Int, lB: Int, distance: Double) {
        self.p = p; self.lA = lA; self.lB = lB; self.distance = distance
    }

    var variableIndices: [Int] { pointIndices(p) + pointIndices(lA) + pointIndices(lB) }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        let a = point(vars, lA)
        let dir = point(vars, lB) - a
        let len = simd_length(dir)
        guard len > 1e-12 else { return [simd_length(point(vars, p) - a) - distance] }
        let perp = abs(cross2(dir, point(vars, p) - a)) / len
        return [perp - distance]
    }
}

// MARK: - Line-pair relations

/// Two segments are parallel (cross(d1, d2) = 0).
nonisolated struct ParallelConstraint: ConstraintResidual {
    let l1A: Int
    let l1B: Int
    let l2A: Int
    let l2B: Int
    init(l1A: Int, l1B: Int, l2A: Int, l2B: Int) {
        self.l1A = l1A; self.l1B = l1B; self.l2A = l2A; self.l2B = l2B
    }

    var variableIndices: [Int] {
        pointIndices(l1A) + pointIndices(l1B) + pointIndices(l2A) + pointIndices(l2B)
    }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        // Normalized: sin(angle between) — unitless, bounded, scale-free.
        // Raw cross2 is mm² and grows with BOTH segment lengths, so the same
        // angular error read as a huge residual on long lines and vanished on
        // short ones. A zero-length segment has no direction to violate.
        let d1 = point(vars, l1B) - point(vars, l1A)
        let d2 = point(vars, l2B) - point(vars, l2A)
        let l1 = simd_length(d1), l2 = simd_length(d2)
        guard l1 > 1e-12, l2 > 1e-12 else { return [0] }
        return [cross2(d1, d2) / (l1 * l2)]
    }
}

/// Two segments are perpendicular (dot(d1, d2) = 0).
nonisolated struct PerpendicularConstraint: ConstraintResidual {
    let l1A: Int
    let l1B: Int
    let l2A: Int
    let l2B: Int
    init(l1A: Int, l1B: Int, l2A: Int, l2B: Int) {
        self.l1A = l1A; self.l1B = l1B; self.l2A = l2A; self.l2B = l2B
    }

    var variableIndices: [Int] {
        pointIndices(l1A) + pointIndices(l1B) + pointIndices(l2A) + pointIndices(l2B)
    }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        // Normalized: cos(angle between) — unitless and scale-free, same
        // reasoning as ParallelConstraint.
        let d1 = point(vars, l1B) - point(vars, l1A)
        let d2 = point(vars, l2B) - point(vars, l2A)
        let l1 = simd_length(d1), l2 = simd_length(d2)
        guard l1 > 1e-12, l2 > 1e-12 else { return [0] }
        return [simd_dot(d1, d2) / (l1 * l2)]
    }
}

/// Two segments have equal length (|d1| - |d2| = 0).
nonisolated struct EqualLengthConstraint: ConstraintResidual {
    let l1A: Int
    let l1B: Int
    let l2A: Int
    let l2B: Int
    init(l1A: Int, l1B: Int, l2A: Int, l2B: Int) {
        self.l1A = l1A; self.l1B = l1B; self.l2A = l2A; self.l2B = l2B
    }

    var variableIndices: [Int] {
        pointIndices(l1A) + pointIndices(l1B) + pointIndices(l2A) + pointIndices(l2B)
    }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        let l1 = simd_length(point(vars, l1B) - point(vars, l1A))
        let l2 = simd_length(point(vars, l2B) - point(vars, l2A))
        return [l1 - l2]
    }
}

/// Directed angle from segment 1 to segment 2 equals `angle` (radians).
nonisolated struct AngleConstraint: ConstraintResidual {
    let l1A: Int
    let l1B: Int
    let l2A: Int
    let l2B: Int
    let angle: Double
    init(l1A: Int, l1B: Int, l2A: Int, l2B: Int, angle: Double) {
        self.l1A = l1A; self.l1B = l1B; self.l2A = l2A; self.l2B = l2B; self.angle = angle
    }

    var variableIndices: [Int] {
        pointIndices(l1A) + pointIndices(l1B) + pointIndices(l2A) + pointIndices(l2B)
    }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        let d1 = point(vars, l1B) - point(vars, l1A)
        let d2 = point(vars, l2B) - point(vars, l2A)
        let actual = atan2(cross2(d1, d2), simd_dot(d1, d2))
        return [wrapAngle(actual - angle)]
    }
}

// MARK: - Symmetry

/// Points A and B are mirror images across the infinite line lA-lB:
/// their midpoint lies on the line AND segment A-B is perpendicular to it.
nonisolated struct SymmetricConstraint: ConstraintResidual {
    let pA: Int
    let pB: Int
    let lA: Int
    let lB: Int
    init(pA: Int, pB: Int, lA: Int, lB: Int) {
        self.pA = pA; self.pB = pB; self.lA = lA; self.lB = lB
    }

    var variableIndices: [Int] {
        pointIndices(pA) + pointIndices(pB) + pointIndices(lA) + pointIndices(lB)
    }
    var residualCount: Int { 2 }
    func residuals(_ vars: [Double]) -> [Double] {
        let a = point(vars, pA)
        let b = point(vars, pB)
        let la = point(vars, lA)
        let dir = point(vars, lB) - la
        let mid = (a + b) * 0.5
        // Midpoint on the axis, and A→B perpendicular to the axis — both
        // normalized by the axis length so they read in mm (the midpoint's
        // perpendicular distance; A→B's projection along the axis) instead
        // of the axis-length-scaled mm² the raw forms gave.
        let len = simd_length(dir)
        guard len > 1e-12 else { return [0, 0] }
        return [cross2(dir, mid - la) / len, simd_dot(b - a, dir) / len]
    }
}

// MARK: - Radius

/// A free radius variable equals a target radius (var - r = 0).
nonisolated struct RadiusConstraint: ConstraintResidual {
    let radiusVar: Int
    let radius: Double
    init(radiusVar: Int, radius: Double) { self.radiusVar = radiusVar; self.radius = radius }

    var variableIndices: [Int] { [radiusVar] }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        [vars[radiusVar] - radius]
    }
}

/// Two free radius variables are equal.
nonisolated struct EqualRadiusConstraint: ConstraintResidual {
    let rVar1: Int
    let rVar2: Int
    init(rVar1: Int, rVar2: Int) { self.rVar1 = rVar1; self.rVar2 = rVar2 }

    var variableIndices: [Int] { [rVar1, rVar2] }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        [vars[rVar1] - vars[rVar2]]
    }
}

// MARK: - Tangency

/// A line is tangent to a circle: perpendicular distance from `center` to the
/// infinite line lA-lB equals the circle's radius variable (unsigned).
nonisolated struct TangentLineCircleConstraint: ConstraintResidual {
    let lA: Int
    let lB: Int
    let center: Int
    let radiusVar: Int
    init(lA: Int, lB: Int, center: Int, radiusVar: Int) {
        self.lA = lA; self.lB = lB; self.center = center; self.radiusVar = radiusVar
    }

    var variableIndices: [Int] {
        pointIndices(lA) + pointIndices(lB) + pointIndices(center) + [radiusVar]
    }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        let a = point(vars, lA)
        let dir = point(vars, lB) - a
        let len = simd_length(dir)
        let r = vars[radiusVar]
        guard len > 1e-12 else { return [simd_length(point(vars, center) - a) - r] }
        let dist = abs(cross2(dir, point(vars, center) - a)) / len
        return [dist - r]
    }
}

/// Persisted external/internal circle contact; radii remain independently driven.
nonisolated struct TangentCircleCircleConstraint: ConstraintResidual {
    let centerA: Int
    let centerB: Int
    let radiusA: Int
    let radiusB: Int
    var internalContact: Bool = false
    var variableIndices: [Int] { pointIndices(centerA) + pointIndices(centerB) + [radiusA, radiusB] }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        let target = internalContact ? abs(vars[radiusA] - vars[radiusB]) : vars[radiusA] + vars[radiusB]
        return [simd_length(point(vars, centerB) - point(vars, centerA)) - target]
    }
}

/// A persisted arc angle drives the CCW sweep in radians, not its radius.
nonisolated struct ArcSweepConstraint: ConstraintResidual {
    let sweepVar: Int
    let sweep: Double
    var variableIndices: [Int] { [sweepVar] }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] { [vars[sweepVar] - sweep] }
}

/// Transient numeric-edit preference: retain a line direction without fixing its length.
nonisolated struct LineDirectionConstraint: ConstraintResidual {
    let a: Int
    let b: Int
    let direction: SIMD2<Double>
    var variableIndices: [Int] { pointIndices(a) + pointIndices(b) }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        [cross2(point(vars, b) - point(vars, a), direction)]
    }
}

/// Transient application preference, not a saved geometric relationship.
nonisolated struct PointProjectionConstraint: ConstraintResidual {
    let p: Int
    let origin: SIMD2<Double>
    let direction: SIMD2<Double>
    var variableIndices: [Int] { pointIndices(p) }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        [simd_dot(point(vars, p) - origin, direction)]
    }
}

// MARK: - Connected arcs (M02)

/// Connected-arc coherence: an exposed arc endpoint stays on its own circle
/// (|e − c| − r = 0). Lowered automatically for every arc whose endpoints are
/// solver slots (see `SketchSolverBridge`); without it a solved endpoint could
/// drift off the arc and the written-back angles would describe a different
/// curve than the one the constraints were solved on. Residual in mm — the
/// bridge's row normalization divides by the sketch's characteristic length.
nonisolated struct ArcEndpointOnCircleConstraint: ConstraintResidual {
    let endpoint: Int
    let center: Int
    let radiusVar: Int
    init(endpoint: Int, center: Int, radiusVar: Int) {
        self.endpoint = endpoint; self.center = center; self.radiusVar = radiusVar
    }

    var variableIndices: [Int] {
        pointIndices(endpoint) + pointIndices(center) + [radiusVar]
    }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        [simd_length(point(vars, endpoint) - point(vars, center)) - vars[radiusVar]]
    }
}

/// Which end of an open spline a junction tangency addresses.
nonisolated enum ArcSplineTangentEnd: Sendable {
    case start
    case end
}

/// G1 tangent continuity between an arc and an open fit spline at their
/// shared (welded/coincident) junction: the spline's RENDERED end tangent is
/// perpendicular to the arc radius at the junction
/// (dot(normalize(P − c), normalize(tangent)) = 0). The tangent is the exact
/// centripetal Catmull–Rom end derivative (`CatmullRomBezier`), recomputed each
/// evaluation with the solved junction point substituted for the end fit
/// point, so a satisfied residual is true G1 continuity of the drawn curve —
/// not a chord approximation. Interior fit points are constants here (they are
/// not solver variables), which is exactly why a tangency can be satisfied by
/// sliding the junction along the arc. Unitless (a cosine); never NaN — a
/// degenerate zero-length tangent span carries no direction and reports the
/// junction unsatisfied instead of dividing by zero.
nonisolated struct ArcSplineTangentConstraint: ConstraintResidual {
    let center: Int
    let point: Int
    /// Full current fit-point array; the addressed end is replaced by the
    /// solved junction point on every evaluation.
    let splinePoints: [SIMD2<Double>]
    let end: ArcSplineTangentEnd

    init(center: Int, point: Int, splinePoints: [SIMD2<Double>], end: ArcSplineTangentEnd) {
        self.center = center
        self.point = point
        self.splinePoints = splinePoints
        self.end = end
    }

    var variableIndices: [Int] { pointIndices(center) + pointIndices(point) }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        guard splinePoints.count >= 2 else { return [0] }
        var points = splinePoints
        // Read the global helper's value directly: the `point` property would
        // otherwise shadow that helper under Swift 6 object compilation.
        let junction = SIMD2<Double>(vars[2 * self.point], vars[2 * self.point + 1])
        switch end {
        case .start: points[0] = junction
        case .end: points[points.count - 1] = junction
        }
        let spanIndex = end == .start ? 0 : points.count - 2
        let span = CatmullRomBezier.spans(points, closed: false)[spanIndex]
        let tangent = CatmullRomBezier.derivative(span, end == .start ? 0 : 1)
        let tLen = simd_length(tangent)
        let radius = junction - SIMD2<Double>(vars[2 * center], vars[2 * center + 1])
        let rLen = simd_length(radius)
        guard tLen > 1e-12, rLen > 1e-12 else { return [0] }
        return [simd_dot(radius / rLen, tangent / tLen)]
    }
}

/// Connected-arc sweep dimension: the CCW sweep between the rays from the
/// arc center to its (connected) endpoints equals `sweep` radians. Replaces
/// the free sweep scalar (`ArcSweepConstraint`) for arcs whose endpoints are
/// solver slots — those arcs carry no sweep variable; the endpoints define
/// the sweep. Unitless (radians) and scale-free.
nonisolated struct ArcEndpointSweepConstraint: ConstraintResidual {
    let endA: Int
    let endB: Int
    let center: Int
    let sweep: Double
    init(endA: Int, endB: Int, center: Int, sweep: Double) {
        self.endA = endA; self.endB = endB; self.center = center; self.sweep = sweep
    }

    var variableIndices: [Int] { pointIndices(endA) + pointIndices(endB) + pointIndices(center) }
    var residualCount: Int { 1 }
    func residuals(_ vars: [Double]) -> [Double] {
        let a = point(vars, endA) - point(vars, center)
        let b = point(vars, endB) - point(vars, center)
        let actual = SketchEntity.arcSweep(
            startAngle: atan2(a.y, a.x), endAngle: atan2(b.y, b.x))
        return [wrapAngle(actual - sweep)]
    }
}
