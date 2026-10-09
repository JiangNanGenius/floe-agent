//
//  CatmullRomBezier.swift
//  openshape3d
//
//  The EXACT cubic Bézier spans of the centripetal Catmull–Rom that
//  `SketchEntity.splinePoints` samples — docs/SPLINE_PROFILE_DESIGN.md,
//  slice 0. A sketch spline is drawn as that Catmull–Rom; for the kernel to
//  build the same curve (one B-spline edge per spline, not a polyline), it
//  needs the curve in Bézier form. Each span of a non-uniform Catmull–Rom is
//  a cubic in its parameter, so it is exactly the cubic Bézier that shares
//  its end points and end derivatives:
//
//      C'(t₁) = [ (p₁−p₀)/(t₁−t₀)·(t₂−t₁) + (p₂−p₁)/(t₂−t₁)·(t₁−t₀) ] / (t₂−t₀)
//      C'(t₂) = [ (p₂−p₁)/(t₂−t₁)·(t₃−t₂) + (p₃−p₂)/(t₃−t₂)·(t₂−t₁) ] / (t₃−t₁)
//      B₁ = p₁ + (t₂−t₁)·C'(t₁)/3,   B₂ = p₂ − (t₂−t₁)·C'(t₂)/3
//
//  (uniform knots reduce these to the familiar (p₂−p₀)/2 and (p₃−p₁)/2).
//  Degenerate spans — duplicated points, which is what an OPEN spline's end
//  spans are, since `splinePoints` clamps its neighbours — are straight, as
//  `splinePoints` draws them.
//
//  Pure value math; tested against `splinePoints` itself.
//

import Foundation
import simd

nonisolated enum CatmullRomBezier {

    /// One cubic Bézier span: `p0`/`p3` are the interpolated control points
    /// it runs between, `p1`/`p2` the inner Bézier handles.
    struct Span: Equatable {
        var p0: SIMD2<Double>
        var p1: SIMD2<Double>
        var p2: SIMD2<Double>
        var p3: SIMD2<Double>

        /// A straight span — what a degenerate Catmull–Rom span draws.
        static func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Span {
            Span(p0: a, p1: a + (b - a) / 3, p2: b - (b - a) / 3, p3: b)
        }

        var isStraight: Bool {
            let d = p3 - p0
            return abs(d.x * (p1 - p0).y - d.y * (p1 - p0).x) < 1e-9
                && abs(d.x * (p2 - p0).y - d.y * (p2 - p0).x) < 1e-9
        }
    }

    /// The spans of the centripetal Catmull–Rom through `points`, in order —
    /// `n` spans when `closed` (the last returns to the first point), `n − 1`
    /// otherwise. Mirrors `SketchEntity.splinePoints` exactly, including its
    /// neighbour clamping and its straight degenerate spans; fewer than three
    /// points give the straight span(s) it would draw.
    static func spans(_ points: [SIMD2<Double>], closed: Bool) -> [Span] {
        let n = points.count
        guard n >= 2 else { return [] }
        guard n >= 3 else { return [.line(points[0], points[1])] }
        let spanCount = closed ? n : n - 1

        func control(_ i: Int) -> SIMD2<Double> {
            if closed { return points[((i % n) + n) % n] }
            return points[min(max(i, 0), n - 1)]
        }

        var out: [Span] = []
        out.reserveCapacity(spanCount)
        for span in 0..<spanCount {
            let p0 = control(span - 1), p1 = control(span)
            let p2 = control(span + 1), p3 = control(span + 2)
            // Centripetal parameterisation (alpha = 0.5), as splinePoints.
            let t0 = 0.0
            let t1 = t0 + simd_length(p1 - p0).squareRoot()
            let t2 = t1 + simd_length(p2 - p1).squareRoot()
            let t3 = t2 + simd_length(p3 - p2).squareRoot()
            guard t1 > t0, t2 > t1, t3 > t2 else {
                out.append(.line(p1, p2))
                continue
            }
            let d1 = ((p1 - p0) / (t1 - t0) * (t2 - t1) + (p2 - p1) / (t2 - t1) * (t1 - t0)) / (t2 - t0)
            let d2 = ((p2 - p1) / (t2 - t1) * (t3 - t2) + (p3 - p2) / (t3 - t2) * (t2 - t1)) / (t3 - t1)
            let h = t2 - t1
            out.append(Span(p0: p1, p1: p1 + d1 * (h / 3), p2: p2 - d2 * (h / 3), p3: p2))
        }
        return out
    }

    /// The point on a span at `u` ∈ [0, 1].
    static func point(_ s: Span, _ u: Double) -> SIMD2<Double> {
        let v = 1 - u
        return s.p0 * (v * v * v) + s.p1 * (3 * v * v * u) + s.p2 * (3 * v * u * u) + s.p3 * (u * u * u)
    }

    /// The derivative dB/du on a span.
    static func derivative(_ s: Span, _ u: Double) -> SIMD2<Double> {
        let v = 1 - u
        return (s.p1 - s.p0) * (3 * v * v) + (s.p2 - s.p1) * (6 * v * u) + (s.p3 - s.p2) * (3 * u * u)
    }

    /// Signed area enclosed by closed spans (CCW positive), by Green's
    /// theorem: ½ ∮ (x dy − y dx). On each span the integrand cross(B, B′) is
    /// a polynomial of degree 5, which 3-point Gauss–Legendre integrates
    /// EXACTLY — so this is closed-form, not an approximation.
    static func signedArea(_ spans: [Span]) -> Double {
        // Gauss–Legendre nodes/weights on [0, 1].
        let s = (3.0 / 5.0).squareRoot()
        let nodes = [0.5 - s / 2, 0.5, 0.5 + s / 2]
        let weights = [5.0 / 18, 8.0 / 18, 5.0 / 18]
        var total = 0.0
        for span in spans {
            for (u, w) in zip(nodes, weights) {
                let b = point(span, u), d = derivative(span, u)
                total += w * (b.x * d.y - b.y * d.x)
            }
        }
        return total / 2
    }
}
