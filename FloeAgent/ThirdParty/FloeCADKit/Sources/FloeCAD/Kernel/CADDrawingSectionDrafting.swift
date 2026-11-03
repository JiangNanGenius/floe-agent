import Foundation
import simd

/// Pure drafting math after analytic B-rep/plane intersection. Coordinates
/// are section model XY, then scaled before paper-spaced hatch generation.
nonisolated enum CADDrawingSectionDrafting {
    nonisolated struct Strip {
        var origin: SIMD3<Double>
        var minX: Double
        var maxX: Double
    }

    /// Parallel offset cuts only. Oblique/rotated segments are rejected, never
    /// silently treated as a single plane. Risers do not create cut regions.
    static func strips(path: CADDrawingSectionPath?, origin: SIMD3<Double>,
                       normal: SIMD3<Double>, xAxis: SIMD3<Double>, yAxis: SIMD3<Double>) -> [Strip]? {
        guard let path else { return [Strip(origin: origin, minX: -.infinity, maxX: .infinity)] }
        guard (2...32).contains(path.points.count), path.points.allSatisfy({ p in
            p.x.isFinite && p.y.isFinite && p.z.isFinite
        }) else { return nil }
        let local = path.points.map { p -> SIMD3<Double> in
            let d = p - origin
            return SIMD3(simd_dot(d, xAxis), simd_dot(d, normal), simd_dot(d, yAxis))
        }
        guard local.allSatisfy({ abs($0.z - local[0].z) < 1e-6 }) else { return nil }
        var strips: [Strip] = []
        var direction = 0.0
        var expectCut = true
        for (a, b) in zip(local, local.dropFirst()) {
            let dx = b.x - a.x, dz = b.y - a.y
            if expectCut {
                guard abs(dx) > 1e-6, abs(dz) < 1e-6 else { return nil }
                if direction == 0 { direction = dx > 0 ? 1 : -1 }
                guard dx * direction > 0 else { return nil }
                strips.append(Strip(origin: origin + normal * a.y,
                                    minX: min(a.x, b.x), maxX: max(a.x, b.x)))
            } else {
                guard abs(dx) < 1e-6, abs(dz) > 1e-6 else { return nil }
            }
            expectCut.toggle()
        }
        guard !expectCut, !strips.isEmpty else { return nil } // ends on a cut
        // End cuts extend outward; finite mark endpoints never truncate a part.
        if direction > 0 {
            strips[0].minX = -.infinity
            strips[strips.count - 1].maxX = .infinity
        } else {
            strips[0].maxX = .infinity
            strips[strips.count - 1].minX = -.infinity
        }
        return strips
    }

    /// Clip original boundary segments; DO NOT invent vertical boundary edges
    /// at an offset-plane transition. The hatch is clipped separately.
    static func clip(_ a: SIMD2<Double>, _ b: SIMD2<Double>,
                     minX: Double, maxX: Double) -> (SIMD2<Double>, SIMD2<Double>)? {
        let dx = b.x - a.x
        if abs(dx) < 1e-12 {
            return a.x >= minX - 1e-9 && a.x <= maxX + 1e-9 ? (a, b) : nil
        }
        let lo = max(0, min((minX - a.x) / dx, (maxX - a.x) / dx))
        let hi = min(1, max((minX - a.x) / dx, (maxX - a.x) / dx))
        guard hi - lo > 1e-10 else { return nil }
        return (a + (b - a) * lo, a + (b - a) * hi)
    }

    /// Even-odd fill across ALL closed contours of one body: inner bores stay
    /// empty regardless of wire orientation. Half-open crossing avoids double
    /// counting vertices. Nil is a complexity/invalid-input failure.
    static func hatches(loops: [SectionLoop], angleDegrees: Double, spacingMM: Double,
                        minX: Double = -.infinity, maxX: Double = .infinity)
        -> [(SIMD2<Double>, SIMD2<Double>)]? {
        guard angleDegrees.isFinite, spacingMM.isFinite, (0.2...50).contains(spacingMM),
              loops.allSatisfy({ $0.closed && $0.points.count >= 3 }) else { return nil }
        let angle = angleDegrees * .pi / 180
        let u = SIMD2(cos(angle), sin(angle)), v = SIMD2(-sin(angle), cos(angle))
        let points = loops.flatMap(\.points)
        guard !points.isEmpty else { return [] }
        guard points.count <= 1000000, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let distances = points.map { simd_dot($0, v) }
        guard let lower = distances.min(), let upper = distances.max(),
              (upper - lower) / spacingMM <= 20000,
              ((upper - lower) / spacingMM + 2) * Double(points.count) <= 5000000 else { return nil }
        var result: [(SIMD2<Double>, SIMD2<Double>)] = []
        let start = floor(lower / spacingMM) * spacingMM
        for offset in stride(from: start, through: upper, by: spacingMM) {
            var crossings: [Double] = []
            for loop in loops {
                for i in loop.points.indices {
                    let a = loop.points[i], b = loop.points[(i + 1) % loop.points.count]
                    let da = simd_dot(a, v), db = simd_dot(b, v)
                    if (da <= offset && offset < db) || (db <= offset && offset < da) {
                        let point = a + (b - a) * ((offset - da) / (db - da))
                        crossings.append(simd_dot(point, u))
                    }
                }
            }
            crossings.sort()
            guard crossings.count.isMultiple(of: 2) else { return nil }
            for i in stride(from: 0, to: crossings.count, by: 2) {
                let a = u * crossings[i] + v * offset
                let b = u * crossings[i + 1] + v * offset
                if let segment = clip(a, b, minX: minX, maxX: maxX) { result.append(segment) }
                if result.count > 100000 { return nil }
            }
        }
        return result
    }
}
