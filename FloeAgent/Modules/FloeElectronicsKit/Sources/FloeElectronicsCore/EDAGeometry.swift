// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum EDAGeometry {
    public static let tolerance = 0.000_001
    public static func dot(_ a: EDAPoint, _ b: EDAPoint) -> Double { a.x * b.x + a.y * b.y }
    public static func cross(_ a: EDAPoint, _ b: EDAPoint) -> Double { a.x * b.y - a.y * b.x }
    public static func pointDistance(_ p: EDAPoint, to a: EDAPoint, _ b: EDAPoint) -> Double {
        let d = b - a, n = dot(d, d)
        if n <= tolerance * tolerance { return p.distance(to: a) }
        let t = min(1, max(0, dot(p - a, d) / n))
        return p.distance(to: a + d * t)
    }
    public static func onSegment(_ p: EDAPoint, _ a: EDAPoint, _ b: EDAPoint) -> Bool {
        pointDistance(p, to: a, b) <= tolerance
    }
    public static func intersects(_ a: EDAPoint, _ b: EDAPoint, _ c: EDAPoint, _ d: EDAPoint) -> Bool {
        let ab = b - a, cd = d - c, denominator = cross(ab, cd)
        if abs(denominator) <= tolerance * tolerance {
            return onSegment(a, c, d) || onSegment(b, c, d) || onSegment(c, a, b) || onSegment(d, a, b)
        }
        let t = cross(c - a, cd) / denominator, u = cross(c - a, ab) / denominator
        return t >= -tolerance && t <= 1 + tolerance && u >= -tolerance && u <= 1 + tolerance
    }
    public static func segmentDistance(_ a: EDAPoint, _ b: EDAPoint, _ c: EDAPoint, _ d: EDAPoint) -> Double {
        if intersects(a, b, c, d) { return 0 }
        return min(pointDistance(a, to: c, d), pointDistance(b, to: c, d),
                   pointDistance(c, to: a, b), pointDistance(d, to: a, b))
    }
    public static func edges(_ polygon: [EDAPoint]) -> [(EDAPoint, EDAPoint)] {
        guard polygon.count >= 2 else { return [] }
        return polygon.indices.map { (polygon[$0], polygon[($0 + 1) % polygon.count]) }
    }
    public static func contains(_ point: EDAPoint, polygon: [EDAPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        for (a, b) in edges(polygon) {
            if onSegment(point, a, b) { return true }
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }
    public static func signedArea(_ polygon: [EDAPoint]) -> Double {
        edges(polygon).reduce(0) { $0 + cross($1.0, $1.1) } / 2
    }
    public static func simplePolygon(_ points: [EDAPoint]) -> Bool {
        guard points.count >= 3, points.count <= 20_000, points.allSatisfy(\.isValid),
              abs(signedArea(points)) > tolerance else { return false }
        let segments = edges(points)
        for i in segments.indices {
            for j in segments.indices where j > i + 1 && !(i == 0 && j == segments.count - 1) {
                if intersects(segments[i].0, segments[i].1, segments[j].0, segments[j].1) { return false }
            }
        }
        return true
    }
    public static func bounds(_ points: [EDAPoint]) -> (min: EDAPoint, max: EDAPoint)? {
        guard let first = points.first else { return nil }
        return points.dropFirst().reduce((first, first)) { b, p in
            (.init(min(b.0.x, p.x), min(b.0.y, p.y)), .init(max(b.1.x, p.x), max(b.1.y, p.y)))
        }
    }
    public static func arc(center: EDAPoint, radius: Double, start: Double, sweep: Double,
                           tolerance: Double = 0.01) -> [EDAPoint] {
        guard center.isValid, radius.isFinite, radius > 0, radius <= 100_000,
              start.isFinite, sweep.isFinite, abs(sweep) <= 360, tolerance.isFinite, tolerance > 0 else { return [] }
        let angle = abs(sweep) * .pi / 180
        let step = max(0.000_1, 2 * acos(max(-1, min(1, 1 - tolerance / radius))))
        let count = min(20_000, max(1, Int(ceil(angle / step))))
        return (0...count).map { index in
            let r = (start + sweep * Double(index) / Double(count)) * .pi / 180
            return center + EDAPoint(cos(r), sin(r)) * radius
        }
    }
}

struct EDAUnionFind {
    private var parent: [Int] = []
    mutating func add() -> Int { parent.append(parent.count); return parent.count - 1 }
    mutating func root(_ value: Int) -> Int {
        var n = value
        while parent[n] != n { parent[n] = parent[parent[n]]; n = parent[n] }
        return n
    }
    mutating func join(_ a: Int, _ b: Int) { let x = root(a), y = root(b); if x != y { parent[max(x, y)] = min(x, y) } }
}
