// SPDX-License-Identifier: MPL-2.0
import Foundation

/// XY-plane arc solver shared by the G-code preview and the artifact
/// inspector. Supports the two centre specifications slicers actually emit
/// (IJ offsets from the start point, or an R radius), full circles (no XY
/// words, or end equal to start), helical interpolation (Z handled by the
/// caller) and P repeat counts. Returns nil for degenerate input so callers
/// can fall back to a straight move instead of dropping the extrusion.
enum PrintArcGeometry {
    struct Solution {
        let centerX: Double
        let centerY: Double
        let radius: Double
        /// Signed sweep in radians; positive is counter-clockwise (G3),
        /// negative is clockwise (G2). Magnitude already includes repeats.
        let sweep: Double
        let startAngle: Double
    }

    /// Bounded repeat count for the P word. Conversion happens only after the
    /// value is clamped so a huge or non-finite P can never trap `Int()`.
    static func boundedRepeats(_ p: Double?) -> Int {
        guard let p, p.isFinite, p > 1 else { return 1 }
        return min(1_000, Int(min(p, 1_000).rounded(.down)))
    }

    static func solve(startX: Double, startY: Double, endX: Double, endY: Double,
                      i: Double?, j: Double?, r: Double?,
                      clockwise: Bool, repeats: Int) -> Solution? {
        let twoPi = 2 * Double.pi
        let fullCircle = abs(endX - startX) < 1e-9 && abs(endY - startY) < 1e-9
        let multiplier = max(1, min(1000, repeats))
        // Centre words share the coordinate magnitude bound: extreme I/J/R
        // values are corrupt input, never a source of non-finite centres,
        // radii or sampled bounds.
        let limit = 1_000_000.0
        if let i, let j, i.isFinite, j.isFinite, abs(i) <= limit, abs(j) <= limit {
            let centerX = startX + i, centerY = startY + j
            let radius = hypot(startX - centerX, startY - centerY)
            guard radius > 1e-9, radius.isFinite, centerX.isFinite, centerY.isFinite else { return nil }
            let startAngle = atan2(startY - centerY, startX - centerX)
            let sweep: Double
            if fullCircle {
                sweep = (clockwise ? -1 : 1) * twoPi * Double(multiplier)
            } else {
                let endAngle = atan2(endY - centerY, endX - centerX)
                var raw = clockwise ? startAngle - endAngle : endAngle - startAngle
                raw = raw.truncatingRemainder(dividingBy: twoPi)
                if raw <= 0 { raw += twoPi }
                sweep = (clockwise ? -1 : 1) * raw * Double(multiplier)
            }
            return Solution(centerX: centerX, centerY: centerY, radius: radius,
                            sweep: sweep, startAngle: startAngle)
        }
        if let r, r.isFinite, abs(r) <= limit, abs(r) > 1e-9 {
            let chord = hypot(endX - startX, endY - startY)
            guard chord > 1e-9 else { return nil } // R cannot describe a full circle
            let radius = abs(r)
            guard chord <= 2 * radius else { return nil }
            let halfSweep = asin(min(1, chord / (2 * radius)))
            // R > 0 selects the minor arc, R < 0 the major arc.
            var magnitude = 2 * halfSweep
            if r < 0 { magnitude = twoPi - magnitude }
            if fullCircle { return nil }
            let midX = (startX + endX) / 2, midY = (startY + endY) / 2
            let dirX = (endX - startX) / chord, dirY = (endY - startY) / chord
            // Left normal (-dirY, dirX) holds the centre for CCW minor arcs;
            // CW minor arcs and CCW major arcs use the opposite side.
            let height = sqrt(max(0, radius * radius - (chord / 2) * (chord / 2)))
            let leftSide = (r > 0) != clockwise
            let sign = leftSide ? 1.0 : -1.0
            let centerX = midX + sign * height * -dirY
            let centerY = midY + sign * height * dirX
            let startAngle = atan2(startY - centerY, startX - centerX)
            let sweep = (clockwise ? -1 : 1) * magnitude * Double(multiplier)
            return Solution(centerX: centerX, centerY: centerY, radius: radius,
                            sweep: sweep, startAngle: startAngle)
        }
        return nil
    }
}
