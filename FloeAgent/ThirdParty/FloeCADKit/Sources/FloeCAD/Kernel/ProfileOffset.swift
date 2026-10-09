//
//  ProfileOffset.swift
//  openshape3d
//
//  Mitred 2D offset of a simple closed polygon — the load-bearing geometry for
//  the draft/taper extrude (docs/DRAFT_TAPER_DESIGN.md, playbook M1). A tapered
//  extrude lofts between the base profile and this offset copy at the far end,
//  where the offset distance is tan(angle)·height.
//
//  Pure value math, no kernel dependency, so it is unit-testable in isolation.
//

import Foundation
import simd

nonisolated enum ProfileOffset {

    /// Offset a simple closed polygon loop by `distance` (positive = OUTWARD /
    /// expand, negative = inward / contract), mitred at the corners. Input is a
    /// plane-local loop in traversal order (as `Profile.loop` / the detector
    /// emit); orientation is normalized internally, so the sign of `distance`
    /// means the same thing regardless of CW/CCW winding, and the result keeps
    /// the input's winding.
    ///
    /// Returns nil when the offset is not well-defined: fewer than three
    /// points, a corner whose edges are (anti)parallel so the mitre has no
    /// intersection, or an inward offset large enough to collapse or invert the
    /// loop (its signed area flips or vanishes). Draft angles are small, so the
    /// common case is a clean shrink/grow; the nil is the honest signal to fall
    /// back rather than ship a self-intersected profile.
    static func offsetLoop(_ loop: [SIMD2<Double>],
                           by distance: Double) -> [SIMD2<Double>]? {
        let n = loop.count
        guard n >= 3 else { return nil }
        if abs(distance) < 1e-12 { return loop }

        // Work CCW so "outward" is unambiguous, then restore the input winding.
        let area = Profile.signedArea(loop)
        guard abs(area) > 1e-12 else { return nil }
        let wasCW = area < 0
        let pts = wasCW ? Array(loop.reversed()) : loop

        // Each edge i (pts[i] -> pts[i+1]) offsets OUTWARD along its normal.
        // For a CCW polygon the interior is to the LEFT of the edge direction,
        // so outward is the right-hand normal (dy, -dx).
        struct Line { var p: SIMD2<Double>; var d: SIMD2<Double> }
        var lines: [Line] = []
        lines.reserveCapacity(n)
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            let edge = b - a
            let len = simd_length(edge)
            guard len > 1e-12 else { return nil }   // zero-length edge
            let dir = edge / len
            let outward = SIMD2(dir.y, -dir.x)
            lines.append(Line(p: a + outward * distance, d: dir))
        }

        // New vertex i is the intersection of offset edge (i-1) and edge i.
        var out: [SIMD2<Double>] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let l0 = lines[(i - 1 + n) % n], l1 = lines[i]
            // Solve l0.p + t·l0.d = l1.p + s·l1.d for t, using the 2D cross.
            let denom = l0.d.x * l1.d.y - l0.d.y * l1.d.x
            guard abs(denom) > 1e-9 else { return nil }  // (anti)parallel corner
            let diff = l1.p - l0.p
            let t = (diff.x * l1.d.y - diff.y * l1.d.x) / denom
            out.append(l0.p + l0.d * t)
        }

        // An edge whose offset copy runs BACKWARDS was consumed: an inward
        // offset larger than a short edge (a 2 mm corner cut under a 14 mm
        // draft — measured outlines are full of them) pulls its two mitres
        // past each other. Every kernel resolves this the same way: the edge
        // vanishes and its neighbours meet. Here the vertex COUNT must survive
        // too — the draft lofts base and offset edge-for-edge — so each run of
        // consumed edges collapses onto the meeting point of its surviving
        // neighbours' carriers, spread ε apart so the wire keeps distinct
        // vertices (the wall over a consumed edge becomes a sliver). A loop
        // that leaves fewer than three surviving edges, or whose survivors
        // still reverse, is genuinely offset past itself: nil.
        func reversed(_ i: Int, _ v: [SIMD2<Double>]) -> Bool {
            let origDir = pts[(i + 1) % n] - pts[i]
            let newDir = v[(i + 1) % n] - v[i]
            return simd_dot(origDir, newDir) <= 1e-12
        }
        var consumed = (0..<n).filter { reversed($0, out) }
        if !consumed.isEmpty {
            let survivors = n - consumed.count
            guard survivors >= 3 else { return nil }
            let eps = 1e-3
            var visited = Set<Int>()
            for start in consumed where !visited.contains(start) {
                // Walk back to the run's first consumed edge, then forward to its last.
                var first = start
                while consumed.contains((first - 1 + n) % n) && (first - 1 + n) % n != start { first = (first - 1 + n) % n }
                var last = first
                while consumed.contains((last + 1) % n) && (last + 1) % n != first { last = (last + 1) % n }
                var run = [first]
                while run.last! != last { run.append((run.last! + 1) % n) }
                run.forEach { visited.insert($0) }
                // The run's vertices are first ... last+1; their replacement is
                // where the previous surviving edge meets the next one.
                let l0 = lines[(first - 1 + n) % n], l1 = lines[(last + 1) % n]
                let denom = l0.d.x * l1.d.y - l0.d.y * l1.d.x
                guard abs(denom) > 1e-9 else { return nil }
                let diff = l1.p - l0.p
                let t = (diff.x * l1.d.y - diff.y * l1.d.x) / denom
                let meet = l0.p + l0.d * t
                let chord = pts[(last + 1) % n] - pts[first]
                let along = simd_length(chord) > 1e-12 ? simd_normalize(chord) : l0.d
                let count = run.count + 1                      // vertices first ... last+1
                for (k, vi) in (0..<count).map({ ((first + $0) % n) }).enumerated() {
                    out[vi] = meet + along * (Double(k) - Double(count - 1) / 2) * eps
                }
            }
            // Only the ε-edges themselves may now run short; every survivor
            // must run its original way, else the offset really is past itself.
            for i in 0..<n where !visited.contains(i) {
                guard !reversed(i, out) else { return nil }
            }
            consumed = []
        }
        let result = wasCW ? Array(out.reversed()) : out
        let outArea = Profile.signedArea(result)
        guard abs(outArea) > 1e-9, (outArea > 0) == (area > 0) else { return nil }
        return result
    }
}
