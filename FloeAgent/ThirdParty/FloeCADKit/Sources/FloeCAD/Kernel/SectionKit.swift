//
//  SectionKit.swift
//  openshape3d
//
//  A plane cut through a solid, as the 2D loops a drawing would show. The
//  kernel (`OCCTKernel.sectionPolylines`) hands back the cut's edges as
//  unordered 3D polylines; this chains them into loops in the plane's own
//  frame, merges collinear runs, and signs the areas — pure value math, so a
//  rebuild can be checked section-for-section against a reference
//  (docs/AGENT_CONTROL.md, `GET /v1/section`).
//

import Foundation
import simd

/// One loop of a section: plane-local points, closed or not, signed area
/// (shoelace; 0 for an open chain).
nonisolated struct SectionLoop: Equatable, Sendable {
    var closed: Bool
    var points: [SIMD2<Double>]
    var area: Double
}

nonisolated enum SectionKit {

    /// An orthonormal in-plane frame for `normal`: `xAxisHint` projected into
    /// the plane when it has a component there, else the world axis least
    /// aligned with the normal. `yAxis = normal × xAxis`, so (x, y, normal)
    /// is right-handed — the same convention as a sketch plane.
    static func frame(normal: SIMD3<Double>,
                      xAxisHint: SIMD3<Double>?) -> (xAxis: SIMD3<Double>, yAxis: SIMD3<Double>) {
        let n = simd_normalize(normal)
        var hint = xAxisHint ?? SIMD3(1, 0, 0)
        hint -= simd_dot(hint, n) * n
        if simd_length(hint) < 1e-9 {
            let pick: SIMD3<Double> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            hint = pick - simd_dot(pick, n) * n
        }
        let x = simd_normalize(hint)
        return (x, simd_cross(n, x))
    }

    /// Chain the kernel's section pieces into loops in the plane frame:
    /// pieces whose ends meet within `tolerance` are joined (reversed as
    /// needed), a chain whose two ends meet is closed, collinear runs are
    /// merged (a box section is four points, not a dozen). Largest area first.
    static func loops(from polylines: [[SIMD3<Double>]], origin: SIMD3<Double>,
                      xAxis: SIMD3<Double>, yAxis: SIMD3<Double>,
                      tolerance: Double = 1e-4) -> [SectionLoop] {
        var chains: [[SIMD2<Double>]] = polylines.compactMap { piece in
            let pts = piece.map { p -> SIMD2<Double> in
                let d = p - origin
                return SIMD2(simd_dot(d, xAxis), simd_dot(d, yAxis))
            }
            return pts.count >= 2 ? pts : nil
        }
        var loops: [SectionLoop] = []
        while !chains.isEmpty {
            var chain = chains.removeFirst()
            var grew = true
            while grew {
                grew = false
                if chain.count > 2, simd_distance(chain[0], chain[chain.count - 1]) <= tolerance { break }
                for (k, other) in chains.enumerated() {
                    let head = chain[0], tail = chain[chain.count - 1]
                    if simd_distance(tail, other[0]) <= tolerance {
                        chain += other.dropFirst()
                    } else if simd_distance(tail, other[other.count - 1]) <= tolerance {
                        chain += other.dropLast().reversed()
                    } else if simd_distance(head, other[other.count - 1]) <= tolerance {
                        chain = other.dropLast() + chain
                    } else if simd_distance(head, other[0]) <= tolerance {
                        chain = other.dropFirst().reversed() + chain
                    } else {
                        continue
                    }
                    chains.remove(at: k)
                    grew = true
                    break
                }
            }
            let closed = chain.count > 2 && simd_distance(chain[0], chain[chain.count - 1]) <= tolerance
            if closed { chain.removeLast() }
            let simplified = mergeCollinear(chain, closed: closed, tolerance: tolerance)
            let area = closed && simplified.count >= 3 ? Profile.signedArea(simplified) : 0
            loops.append(SectionLoop(closed: closed, points: simplified, area: area))
        }
        return loops.sorted { abs($0.area) > abs($1.area) }
    }

    /// Drop points that repeat their predecessor or sit on the straight run
    /// between their neighbours (within `tolerance` of it).
    static func mergeCollinear(_ pts: [SIMD2<Double>], closed: Bool,
                               tolerance: Double) -> [SIMD2<Double>] {
        guard pts.count > 2 else { return pts }
        let n = pts.count
        var out: [SIMD2<Double>] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let p = pts[i]
            let prev: SIMD2<Double>? = closed ? pts[(i - 1 + n) % n] : (i > 0 ? pts[i - 1] : nil)
            let next: SIMD2<Double>? = closed ? pts[(i + 1) % n] : (i + 1 < n ? pts[i + 1] : nil)
            if let prev {
                let a = p - prev
                let la = simd_length(a)
                if la <= tolerance { continue }                              // duplicate
                if let next {
                    let b = next - p
                    let lb = simd_length(b)
                    // perpendicular distance of p from the line prev→next
                    let chord = next - prev
                    let lc = simd_length(chord)
                    if lb > tolerance, lc > tolerance,
                       abs(chord.x * a.y - chord.y * a.x) / lc <= tolerance,
                       simd_dot(a, b) > 0 { continue }                       // collinear run
                }
            }
            out.append(p)
        }
        return out
    }
}
