//
//  PolygonTriangulator.swift
//  openshape3d
//
//  Triangulation of a simple polygon with holes — hole bridging then ear
//  clipping (Eberly's construction). Pure 2D value math for the sketch fill
//  overlay, which used to hand the loops to a mesh CSG union: exponential on
//  a 1,000-vertex spline outline, and it ran on the main thread (gotcha 24).
//

import Foundation
import simd

nonisolated enum PolygonTriangulator {

    /// Triangles of `outer` minus `holes`, as index triples into the returned
    /// vertex list (counter-clockwise). Loops may come in either winding;
    /// consecutive duplicates are dropped; a loop with fewer than three
    /// distinct points is ignored. Degenerate input never loops forever: when
    /// no ear can be found the flattest corner is dropped.
    static func triangulate(outer: [SIMD2<Double>],
                            holes: [[SIMD2<Double>]]) -> (vertices: [SIMD2<Double>], triangles: [Int]) {
        var ring = cleaned(outer)
        guard ring.count >= 3 else { return ([], []) }
        if Profile.signedArea(ring) < 0 { ring.reverse() }
        var holeRings = holes.map(cleaned).filter { $0.count >= 3 }
        for i in holeRings.indices where Profile.signedArea(holeRings[i]) > 0 { holeRings[i].reverse() }
        // Bridge holes rightmost-first, so a bridge never has to cross a hole
        // that has not been merged yet.
        holeRings.sort { ($0.map(\.x).max() ?? 0) > ($1.map(\.x).max() ?? 0) }
        for hole in holeRings {
            ring = bridged(ring, hole: hole)
        }
        return (ring, earClip(ring))
    }

    // MARK: - Internals

    private static func cleaned(_ loop: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = []
        for p in loop where out.last.map({ simd_distance($0, p) > 1e-9 }) ?? true { out.append(p) }
        while out.count > 1, simd_distance(out[0], out[out.count - 1]) <= 1e-9 { out.removeLast() }
        return out
    }

    private static func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    private static func inside(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
        cross(a, b, p) > 1e-12 && cross(b, c, p) > 1e-12 && cross(c, a, p) > 1e-12
    }

    /// Splice `hole` (CW) into `ring` (CCW) through a bridge from the hole's
    /// rightmost vertex to a visible outer vertex.
    private static func bridged(_ ring: [SIMD2<Double>], hole: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let n = ring.count
        var mIndex = 0
        for i in hole.indices where hole[i].x > hole[mIndex].x { mIndex = i }
        let m = hole[mIndex]
        // Closest intersection of the ray from m along +x with an outer edge.
        var bestX = Double.infinity, bestEdge = -1, hit = m
        for i in 0..<n {
            let a = ring[i], b = ring[(i + 1) % n]
            guard (a.y <= m.y && b.y >= m.y) || (b.y <= m.y && a.y >= m.y), abs(b.y - a.y) > 1e-15 else { continue }
            let t = (m.y - a.y) / (b.y - a.y)
            let x = a.x + t * (b.x - a.x)
            if x >= m.x - 1e-12, x < bestX { bestX = x; bestEdge = i; hit = SIMD2(x, m.y) }
        }
        guard bestEdge >= 0 else {
            // No outer edge to the right: fall back to the nearest outer vertex.
            var p = 0
            for i in 0..<n where simd_distance(ring[i], m) < simd_distance(ring[p], m) { p = i }
            return splice(ring, at: p, hole: hole, from: mIndex)
        }
        let a = bestEdge, b = (bestEdge + 1) % n
        var p = ring[a].x > ring[b].x ? a : b
        if simd_distance(hit, ring[p]) > 1e-12 {
            // A reflex outer vertex inside the triangle (m, hit, p) would be
            // crossed by the bridge: take the one with the smallest angle to +x.
            var bestAngle = Double.infinity
            for i in 0..<n where i != p {
                let v = ring[i]
                guard cross(ring[(i - 1 + n) % n], v, ring[(i + 1) % n]) <= 0 else { continue }   // reflex only
                let tri = inside(v, m, hit, ring[p]) || inside(v, m, ring[p], hit)
                guard tri else { continue }
                let angle = abs(atan2(v.y - m.y, v.x - m.x))
                if angle < bestAngle || (abs(angle - bestAngle) < 1e-12 && simd_distance(v, m) < simd_distance(ring[p], m)) {
                    bestAngle = angle; p = i
                }
            }
        }
        return splice(ring, at: p, hole: hole, from: mIndex)
    }

    private static func splice(_ ring: [SIMD2<Double>], at p: Int,
                               hole: [SIMD2<Double>], from mIndex: Int) -> [SIMD2<Double>] {
        var out: [SIMD2<Double>] = Array(ring[0...p])
        let h = hole.count
        for k in 0...h { out.append(hole[(mIndex + k) % h]) }     // m … around … back to m
        out.append(ring[p])
        if p + 1 < ring.count { out.append(contentsOf: ring[(p + 1)...]) }
        return out
    }

    /// Ear clipping on a CCW simple polygon (bridge vertices may repeat).
    private static func earClip(_ poly: [SIMD2<Double>]) -> [Int] {
        let n = poly.count
        guard n >= 3 else { return [] }
        var next = (0..<n).map { ($0 + 1) % n }
        var prev = (0..<n).map { ($0 - 1 + n) % n }
        func isConvex(_ i: Int) -> Bool { cross(poly[prev[i]], poly[i], poly[next[i]]) > 1e-12 }
        var reflex = Set((0..<n).filter { !isConvex($0) })
        var out: [Int] = []
        out.reserveCapacity((n - 2) * 3)
        var remaining = n
        var i = 0
        var stalled = 0
        while remaining > 3 {
            let a = prev[i], c = next[i]
            var ear = isConvex(i)
            if ear {
                for r in reflex where r != a && r != i && r != c {
                    let v = poly[r]
                    // a duplicated bridge vertex sits ON a corner, never strictly inside
                    if inside(v, poly[a], poly[i], poly[c]) { ear = false; break }
                }
            }
            if ear || stalled > remaining {
                out += [a, i, c]
                next[a] = c; prev[c] = a
                remaining -= 1
                reflex.remove(i)
                if reflex.contains(a), isConvex(a) { reflex.remove(a) }
                if reflex.contains(c), isConvex(c) { reflex.remove(c) }
                i = c
                stalled = 0
            } else {
                i = c
                stalled += 1
            }
        }
        out += [prev[i], i, next[i]]
        return out
    }
}
