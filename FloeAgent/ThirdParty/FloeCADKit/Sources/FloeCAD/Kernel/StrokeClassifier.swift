//
//  StrokeClassifier.swift
//  openshape3d
//
//  Spec §1.2 — Line/Arc Automatic mode. A pen stroke on a sketch plane becomes
//  either a straight line or a circular arc, decided from the stroke itself so
//  the user never has to pick a tool first. Wiggling mid-stroke flips whichever
//  answer the classifier reached, which is the spec's escape hatch when it
//  guesses wrong.
//
//  Everything here is pure geometry over the sampled stroke, in sketch-plane
//  coordinates — no gesture state, so the decision is unit-testable and the
//  same code can re-classify a stroke as it grows.
//

import Foundation
import simd

/// The "Line Type" menu: Automatic (default) | Line | Arc.
nonisolated enum LineType: String, Codable, Sendable, CaseIterable {
    case automatic, line, arc

    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .line: "Line"
        case .arc: "Arc"
        }
    }
}

nonisolated enum StrokeClassifier {

    /// What a stroke was read as.
    nonisolated enum Shape: Equatable, Sendable {
        case line(a: SIMD2<Double>, b: SIMD2<Double>)
        /// Angles are CCW-from-start, matching `SketchEntity.arc`.
        case arc(center: SIMD2<Double>, radius: Double, startAngle: Double, endAngle: Double)
    }

    // MARK: Tuning
    //
    // Both thresholds are RELATIVE to the stroke's chord, so classification does
    // not change with zoom level or how big the user drew.

    /// A stroke must bow at least this fraction of its chord to be an arc. Hand
    /// tremor on a "straight" pen line runs well under 1%.
    static let minBowRatio: Double = 0.02
    /// …and the circle fit must be at least this much tighter than the straight
    /// fit. Stops a nearly-straight stroke with one stray sample from arcing.
    static let maxFitRatio: Double = 0.6
    /// Direction reversal sharper than this (cosine) counts as a wiggle turn.
    static let wiggleTurnCosine: Double = -0.5
    /// Turns needed to read as a deliberate wiggle rather than one hooked end.
    static let wiggleTurnCount: Int = 3

    // MARK: - Entry point

    /// The sketch entity a finished stroke should produce, honouring the Line
    /// Type override. Nil for a stroke too short or too degenerate to be either.
    ///
    /// In `.automatic`, a mid-stroke wiggle TOGGLES the detected shape (spec
    /// §1.2); the wiggle's own samples are excluded from the fit so the scribble
    /// does not drag the geometry with it.
    static func entity(from points: [SIMD2<Double>], lineType: LineType) -> SketchEntity? {
        guard let shape = shape(from: points, lineType: lineType) else { return nil }
        switch shape {
        case let .line(a, b):
            return .line(id: UUID(), a: a, b: b)
        case let .arc(center, radius, start, end):
            return .arc(id: UUID(), center: center, radius: radius,
                        startAngle: start, endAngle: end)
        }
    }

    /// As `entity(from:lineType:)`, but returns the geometric decision — used by
    /// the live preview, which re-runs this every few samples.
    static func shape(from points: [SIMD2<Double>], lineType: LineType) -> Shape? {
        let clean = deduplicated(points)
        guard clean.count >= 2 else { return nil }
        let a = clean[0], b = clean[clean.count - 1]
        guard simd_length(b - a) > 1e-9 else { return nil }

        switch lineType {
        case .line:
            return .line(a: a, b: b)
        case .arc:
            return fitArc(clean) ?? .line(a: a, b: b)
        case .automatic:
            let wiggled = isWiggled(clean)
            let trimmed = wiggled ? withoutWiggle(clean) : clean
            var detected = detect(trimmed) ?? .line(a: a, b: b)
            if wiggled { detected = toggled(detected, points: trimmed) }
            return detected
        }
    }

    // MARK: - Automatic detection

    /// Arc when the stroke bows meaningfully AND a circle explains it better
    /// than a straight line does.
    private static func detect(_ points: [SIMD2<Double>]) -> Shape? {
        guard points.count >= 2 else { return nil }
        let a = points[0], b = points[points.count - 1]
        let chord = simd_length(b - a)
        guard chord > 1e-9 else {
            // A closed stroke has no chord to bow off; read it as an arc if a
            // circle fits it at all.
            return fitArc(points)
        }
        guard points.count >= 3 else { return .line(a: a, b: b) }

        let straight = residualToChord(points)
        guard straight / chord > minBowRatio, let arc = fitArc(points) else {
            return .line(a: a, b: b)
        }
        guard case let .arc(center, radius, _, _) = arc else { return .line(a: a, b: b) }
        let curved = residualToCircle(points, center: center, radius: radius)
        return curved < straight * maxFitRatio ? arc : .line(a: a, b: b)
    }

    /// Flip line ⇄ arc, keeping the same endpoints. The toggled arc uses the
    /// stroke's own bow so it still passes through the samples.
    private static func toggled(_ shape: Shape, points: [SIMD2<Double>]) -> Shape {
        switch shape {
        case let .line(a, b):
            // A straight stroke carries no bow to fit — and a near-straight one
            // fits a circle so large the "arc" would look identical to the line
            // the user just rejected. Either way, fall back to a visible default
            // bow they can then drag (§1.3 bulge adjust).
            let chord = simd_length(b - a)
            if let arc = fitArc(points), case let .arc(_, radius, _, _) = arc,
               radius < chord * 20 {
                return arc
            }
            return defaultArc(from: a, to: b, bowingToward: points)
        case .arc:
            return .line(a: points[0], b: points[points.count - 1])
        }
    }

    /// A shallow arc through `a` and `b`, bulging to whichever side the samples
    /// lean (left of travel when they lean neither way). Sagitta is a tenth of
    /// the chord: unmistakably curved, still close to what was drawn.
    private static func defaultArc(
        from a: SIMD2<Double>, to b: SIMD2<Double>, bowingToward points: [SIMD2<Double>]
    ) -> Shape {
        let ab = b - a
        let chord = simd_length(ab)
        let left = SIMD2(-ab.y / chord, ab.x / chord)

        var lean = 0.0
        for p in points { lean += simd_dot(p - a, left) }
        let normal = lean < 0 ? -left : left

        let sagitta = chord / 10
        // Circle through the chord ends with that sagitta.
        let radius = (chord * chord / 4 + sagitta * sagitta) / (2 * sagitta)
        let center = (a + b) / 2 - normal * (radius - sagitta)

        var start = atan2(a.y - center.y, a.x - center.x)
        var end = atan2(b.y - center.y, b.x - center.x)
        // The centre sits OPPOSITE the bulge, so bulging left is walked a → b
        // clockwise; the entity's CCW-only sweep stores that swapped. Bulging
        // right is already CCW and stays as drawn.
        if lean >= 0 { swap(&start, &end) }
        return .arc(center: center, radius: radius, startAngle: start, endAngle: end)
    }

    // MARK: - Circle fitting

    /// Kåsa algebraic circle fit: minimises |p|² - 2c·p - k over the samples,
    /// which is linear in (cx, cy, k) and needs no initial guess. Good enough
    /// for a hand stroke, and cheap enough to re-run live.
    ///
    /// Returns the arc through the samples, swept in the direction the stroke
    /// was actually drawn.
    static func fitArc(_ points: [SIMD2<Double>]) -> Shape? {
        guard points.count >= 3 else { return nil }
        let n = Double(points.count)
        var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
        var sxz = 0.0, syz = 0.0, sz = 0.0
        for p in points {
            let z = p.x * p.x + p.y * p.y
            sx += p.x; sy += p.y
            sxx += p.x * p.x; syy += p.y * p.y; sxy += p.x * p.y
            sxz += p.x * z; syz += p.y * z; sz += z
        }
        // Normal equations for [2cx, 2cy, k].
        let m = simd_double3x3(
            SIMD3(sxx, sxy, sx), SIMD3(sxy, syy, sy), SIMD3(sx, sy, n))
        guard abs(m.determinant) > 1e-12 else { return nil }  // collinear samples
        let solution = m.inverse * SIMD3(sxz, syz, sz)
        let center = SIMD2(solution.x / 2, solution.y / 2)
        let radiusSquared = solution.z + center.x * center.x + center.y * center.y
        guard radiusSquared > 1e-12 else { return nil }
        let radius = radiusSquared.squareRoot()
        guard radius.isFinite, radius < 1e9 else { return nil }

        let first = points[0], last = points[points.count - 1]
        var start = atan2(first.y - center.y, first.x - center.x)
        var end = atan2(last.y - center.y, last.x - center.x)
        // `SketchEntity.arc` always sweeps CCW, so a clockwise stroke is stored
        // as the same arc walked the other way.
        if signedSweep(points, center: center) < 0 { swap(&start, &end) }
        return .arc(center: center, radius: radius, startAngle: start, endAngle: end)
    }

    /// Total turning of the samples about `center` — sign gives the direction.
    private static func signedSweep(_ points: [SIMD2<Double>], center: SIMD2<Double>) -> Double {
        var total = 0.0
        for i in 1..<points.count {
            let a = points[i - 1] - center, b = points[i] - center
            total += atan2(a.x * b.y - a.y * b.x, simd_dot(a, b))
        }
        return total
    }

    // MARK: - Wiggle

    /// Does the stroke contain a deliberate back-and-forth scribble?
    static func isWiggled(_ points: [SIMD2<Double>]) -> Bool {
        turnIndices(points).count >= wiggleTurnCount
    }

    /// Sample indices where the stroke doubles back on itself.
    private static func turnIndices(_ points: [SIMD2<Double>]) -> [Int] {
        guard points.count >= 3 else { return [] }
        // A wiggle is small relative to the stroke; ignore reversals made of
        // segments long enough to be intentional strokes of their own.
        let span = simd_length(points[points.count - 1] - points[0])
        let maxSegment = max(span * 0.25, 1e-9)

        var turns = [Int]()
        var previous: SIMD2<Double>?
        for i in 1..<points.count {
            let delta = points[i] - points[i - 1]
            let length = simd_length(delta)
            guard length > 1e-9 else { continue }
            let direction = delta / length
            if let previous, length < maxSegment,
               simd_dot(previous, direction) < wiggleTurnCosine {
                turns.append(i)
            }
            previous = direction
        }
        return turns
    }

    /// The stroke with its wiggle removed: everything from the first turn to
    /// the last is dropped, so the fit sees only the approach and the exit.
    private static func withoutWiggle(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let turns = turnIndices(points)
        guard let first = turns.first, let last = turns.last else { return points }
        let head = Array(points[..<max(first, 1)])
        let tail = Array(points[min(last + 1, points.count)...])
        let kept = head + tail
        return kept.count >= 2 ? kept : points
    }

    // MARK: - Residuals

    /// Mean distance from the samples to the straight chord.
    private static func residualToChord(_ points: [SIMD2<Double>]) -> Double {
        let a = points[0], b = points[points.count - 1]
        let ab = b - a
        let length = simd_length(ab)
        guard length > 1e-12 else { return 0 }
        let n = SIMD2(-ab.y / length, ab.x / length)
        var total = 0.0
        for p in points { total += abs(simd_dot(p - a, n)) }
        return total / Double(points.count)
    }

    /// Mean distance from the samples to the fitted circle.
    private static func residualToCircle(
        _ points: [SIMD2<Double>], center: SIMD2<Double>, radius: Double
    ) -> Double {
        var total = 0.0
        for p in points { total += abs(simd_length(p - center) - radius) }
        return total / Double(points.count)
    }

    /// Drop repeated samples — a stationary pen emits many, and they skew both
    /// the fit and the turn detection toward wherever the user paused.
    private static func deduplicated(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var out = [SIMD2<Double>]()
        for p in points where out.isEmpty || simd_length(p - out[out.count - 1]) > 1e-9 {
            out.append(p)
        }
        return out
    }
}
