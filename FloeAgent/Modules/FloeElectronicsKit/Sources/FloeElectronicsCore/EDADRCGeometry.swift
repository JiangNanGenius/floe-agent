// SPDX-License-Identifier: MPL-2.0
import Foundation

// Analytic capsules and transformed polygons. No bounding boxes or tessellation
// are used as copper geometry. A centred drilled aperture is subtracted when
// present; it must be strictly contained in the outer contour.
enum EDADRCOuterShape {
    case capsule(EDAPoint, EDAPoint, Double)
    case polygon([EDAPoint])

    var sample: EDAPoint {
        switch self {
        case let .capsule(a, b, r):
            let d = b - a, n = d.length
            return a + (n > EDAGeometry.tolerance ? EDAPoint(-d.y / n, d.x / n) : EDAPoint(1, 0)) * r
        case .polygon(let p): return p[0]
        }
    }
    func farthest(from p: EDAPoint) -> EDAPoint {
        switch self {
        case let .capsule(a, b, r):
            let c = a.distance(to: p) >= b.distance(to: p) ? a : b
            let d = c - p, n = d.length
            return c + (n > EDAGeometry.tolerance ? d * (1 / n) : EDAPoint(1, 0)) * r
        case .polygon(let points): return points.max { $0.distance(to: p) < $1.distance(to: p) }!
        }
    }
}

struct EDADRCShape {
    let outer: EDADRCOuterShape
    var hole: (center: EDAPoint, radius: Double)? = nil
}

struct EDADRCWitness {
    let a: EDAPoint
    let b: EDAPoint
    var distance: Double { a.distance(to: b) }
    var midpoint: EDAPoint { (a + b) * 0.5 }
    var reversed: Self { .init(a: b, b: a) }
}

final class EDADRCBudget {
    var remaining = 20_000_000
    let cancelled: @Sendable () -> Bool
    init(cancelled: @escaping @Sendable () -> Bool) { self.cancelled = cancelled }
    func step() throws {
        if cancelled() { throw EDAError.cancelled }
        remaining -= 1
        if remaining < 0 { throw EDAError.invalid("board DRC geometry budget") }
    }
}

enum EDADRCGeometry {
    static func projection(_ p: EDAPoint, _ a: EDAPoint, _ b: EDAPoint) -> EDAPoint {
        let d = b - a, n = EDAGeometry.dot(d, d)
        if n <= EDAGeometry.tolerance * EDAGeometry.tolerance { return a }
        return a + d * min(1, max(0, EDAGeometry.dot(p - a, d) / n))
    }

    static func segments(_ a: EDAPoint, _ b: EDAPoint, _ c: EDAPoint, _ d: EDAPoint,
                         budget: EDADRCBudget) throws -> EDADRCWitness {
        try budget.step()
        if EDAGeometry.intersects(a, b, c, d) {
            let ab = b - a, cd = d - c, denominator = EDAGeometry.cross(ab, cd)
            if abs(denominator) > EDAGeometry.tolerance * EDAGeometry.tolerance {
                let p = a + ab * min(1, max(0, EDAGeometry.cross(c - a, cd) / denominator))
                return .init(a: p, b: p)
            }
            for p in [a, b] where EDAGeometry.onSegment(p, c, d) { return .init(a: p, b: p) }
            for p in [c, d] where EDAGeometry.onSegment(p, a, b) { return .init(a: p, b: p) }
        }
        return [.init(a: a, b: projection(a, c, d)), .init(a: b, b: projection(b, c, d)),
                .init(a: projection(c, a, b), b: c), .init(a: projection(d, a, b), b: d)]
            .min { $0.distance < $1.distance }!
    }

    private static func segmentPolygon(_ a: EDAPoint, _ b: EDAPoint, _ polygon: [EDAPoint],
                                       budget: EDADRCBudget) throws -> EDADRCWitness {
        if EDAGeometry.contains(a, polygon: polygon) { return .init(a: a, b: a) }
        if EDAGeometry.contains(b, polygon: polygon) { return .init(a: b, b: b) }
        var nearest: EDADRCWitness?
        for (c, d) in EDAGeometry.edges(polygon) {
            let pair = try segments(a, b, c, d, budget: budget)
            if pair.distance <= EDAGeometry.tolerance { return pair }
            if nearest == nil || pair.distance < nearest!.distance { nearest = pair }
        }
        return nearest!
    }

    private static func expanded(_ pair: EDADRCWitness, _ ra: Double, _ rb: Double) -> EDADRCWitness {
        let distance = pair.distance
        guard distance > EDAGeometry.tolerance else { return pair }
        let u = (pair.b - pair.a) * (1 / distance)
        if distance <= ra + rb {
            let p = pair.a + u * min(ra, max(0, distance - rb))
            return .init(a: p, b: p)
        }
        return .init(a: pair.a + u * ra, b: pair.b - u * rb)
    }

    private static func outer(_ a: EDADRCOuterShape, _ b: EDADRCOuterShape,
                              budget: EDADRCBudget) throws -> EDADRCWitness {
        switch (a, b) {
        case let (.capsule(a0, a1, ra), .capsule(b0, b1, rb)):
            return expanded(try segments(a0, a1, b0, b1, budget: budget), ra, rb)
        case let (.capsule(a0, a1, r), .polygon(p)):
            return expanded(try segmentPolygon(a0, a1, p, budget: budget), r, 0)
        case (.polygon, .capsule): return try outer(b, a, budget: budget).reversed
        case let (.polygon(pa), .polygon(pb)):
            if EDAGeometry.contains(pa[0], polygon: pb) { return .init(a: pa[0], b: pa[0]) }
            if EDAGeometry.contains(pb[0], polygon: pa) { return .init(a: pb[0], b: pb[0]) }
            var nearest: EDADRCWitness?
            for (a0, a1) in EDAGeometry.edges(pa) {
                for (b0, b1) in EDAGeometry.edges(pb) {
                    let pair = try segments(a0, a1, b0, b1, budget: budget)
                    if pair.distance <= EDAGeometry.tolerance { return pair }
                    if nearest == nil || pair.distance < nearest!.distance { nearest = pair }
                }
            }
            return nearest!
        }
    }

    static func distance(_ a: EDADRCShape, _ b: EDADRCShape,
                         budget: EDADRCBudget) throws -> EDADRCWitness {
        try budget.step()
        // A connected outer contour can be disjoint from the other's copper
        // despite overlapping its envelope only when wholly inside its hole.
        if let hole = b.hole {
            let p = a.outer.farthest(from: hole.center), d = p.distance(to: hole.center)
            if d < hole.radius {
                let u = d > EDAGeometry.tolerance ? (p - hole.center) * (1 / d) : EDAPoint(1, 0)
                return .init(a: p, b: hole.center + u * hole.radius)
            }
        }
        if let hole = a.hole {
            let p = b.outer.farthest(from: hole.center), d = p.distance(to: hole.center)
            if d < hole.radius {
                let u = d > EDAGeometry.tolerance ? (p - hole.center) * (1 / d) : EDAPoint(1, 0)
                return .init(a: hole.center + u * hole.radius, b: p)
            }
        }
        return try outer(a.outer, b.outer, budget: budget)
    }

    static func pad(_ pad: EDAPad, in footprint: EDAFootprint) -> EDADRCShape? {
        let sx = pad.size.x, sy = pad.size.y, center = footprint.point(pad.position)
        func point(_ p: EDAPoint) -> EDAPoint {
            footprint.point(p.transformed(origin: pad.position, angle: pad.angle))
        }
        let outer: EDADRCOuterShape
        switch pad.shape {
        case .circle:
            guard abs(sx - sy) <= EDAGeometry.tolerance else { return nil }
            outer = .capsule(center, center, sx / 2)
        case .rectangle:
            outer = .polygon([point(.init(-sx / 2, -sy / 2)), point(.init(sx / 2, -sy / 2)),
                              point(.init(sx / 2, sy / 2)), point(.init(-sx / 2, sy / 2))])
        case .oval:
            let halfLine = abs(sx - sy) / 2
            outer = sx >= sy ? .capsule(point(.init(-halfLine, 0)), point(.init(halfLine, 0)), sy / 2)
                : .capsule(point(.init(0, -halfLine)), point(.init(0, halfLine)), sx / 2)
        case .polygon:
            guard let vertices = EDAPolygonPadGeometry.vertices(pad, in: footprint) else { return nil }
            outer = .polygon(vertices)
        case .roundRectangle:
            guard let vertices = try? EDARoundedPadGeometry.vertices(pad, in: footprint, containing: true) else { return nil }
            outer = .polygon(vertices)
        }
        return .init(outer: outer, hole: pad.drill.map { (center, $0 / 2) })
    }
}
