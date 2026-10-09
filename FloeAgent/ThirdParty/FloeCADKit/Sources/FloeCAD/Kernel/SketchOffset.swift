//
//  SketchOffset.swift
//  openshape3d
//
//  Offset Edge, kernel half (spec §1.9): produce sketch entities offset from
//  existing ones by a signed distance. Circles/arcs/rects/polygons offset
//  radially; line chains offset with mitred joins; closed line loops clean up
//  self-intersections by dropping segments whose direction flips.
//

import Foundation
import simd

nonisolated enum SketchOffset {

    private static let epsilon = 1e-9
    private static let quantum = 1e-6

    /// Offset `entities` by the signed `distance`.
    /// - Closed shapes (circles, arcs, rects, ellipses, polygons, closed line
    ///   loops): positive grows outward, negative shrinks inward. Entities
    ///   that collapse (radius/extent <= 0, loops that vanish) are dropped;
    ///   closed line loops mitre their joins and drop segments whose direction
    ///   flips (they collapsed through the opposite wall) so the result stays
    ///   a simple loop.
    /// - Open line chains: positive offsets to the LEFT of the travel
    ///   direction (walked from a free end); UI-side loop-arrow
    ///   disambiguation picks the sign.
    /// Output entities get fresh IDs.
    static func offset(entities: [SketchEntity], by distance: Double) -> [SketchEntity] {
        var result: [SketchEntity] = []
        var lines: [(a: SIMD2<Double>, b: SIMD2<Double>)] = []

        for entity in entities {
            switch entity {
            case let .line(_, a, b):
                if simd_length(b - a) > epsilon {
                    lines.append((a, b))
                }
            case let .circle(_, center, radius):
                let r = radius + distance
                if r > epsilon {
                    result.append(.circle(id: UUID(), center: center, radius: r))
                }
            case let .arc(_, center, radius, startAngle, endAngle):
                let r = radius + distance
                if r > epsilon {
                    result.append(.arc(
                        id: UUID(), center: center, radius: r,
                        startAngle: startAngle, endAngle: endAngle
                    ))
                }
            case let .rect(_, lo, hi):
                let newLo = lo - SIMD2(repeating: distance)
                let newHi = hi + SIMD2(repeating: distance)
                // Degenerate-collapse guard: a shrink past the midlines drops
                // the rect instead of emitting an inverted one.
                if newHi.x - newLo.x > epsilon, newHi.y - newLo.y > epsilon {
                    result.append(.rect(id: UUID(), min: newLo, max: newHi))
                }
            case let .ellipse(_, center, radiusX, radiusY, rotation):
                // Radial approximation (a true ellipse offset is not an ellipse).
                let rx = radiusX + distance
                let ry = radiusY + distance
                if rx > epsilon, ry > epsilon {
                    result.append(.ellipse(
                        id: UUID(), center: center,
                        radiusX: rx, radiusY: ry, rotation: rotation
                    ))
                }
            case .spline:
                // A true offset of a spline is not a spline; skip rather than
                // emit something geometrically wrong (spec §1.9 lists offset
                // for lines/arcs/circles/rects/polygons).
                break
            case let .polygon(_, center, radius, sides, rotation):
                guard sides >= 3 else { break }
                // Edges move by `distance`, so the circumradius grows by the
                // apothem-to-circumradius factor.
                let r = radius + distance / cos(.pi / Double(sides))
                if r > epsilon {
                    result.append(.polygon(
                        id: UUID(), center: center, radius: r,
                        sides: sides, rotation: rotation
                    ))
                }
            }
        }

        for chain in chains(of: lines) {
            if chain.isClosed {
                result.append(contentsOf: offsetLoop(chain.points, by: distance))
            } else {
                result.append(contentsOf: offsetPolyline(chain.points, by: distance))
            }
        }
        return result
    }

    // MARK: - Chain building

    private struct NodeKey: Hashable {
        let x, y: Int64
        init(_ p: SIMD2<Double>) {
            x = MeshQuantize.key64(p.x, quantum: SketchOffset.quantum)
            y = MeshQuantize.key64(p.y, quantum: SketchOffset.quantum)
        }
    }

    private struct Chain {
        var points: [SIMD2<Double>]
        var isClosed: Bool
    }

    /// Group line segments into maximal chains through degree-2 endpoints;
    /// chains meeting at junctions (degree != 2) stay open, fully connected
    /// cycles come back closed (first point not repeated).
    private static func chains(
        of lines: [(a: SIMD2<Double>, b: SIMD2<Double>)]
    ) -> [Chain] {
        var adjacency: [NodeKey: [(line: Int, forward: Bool)]] = [:]
        for (index, line) in lines.enumerated() {
            adjacency[NodeKey(line.a), default: []].append((index, true))
            adjacency[NodeKey(line.b), default: []].append((index, false))
        }

        var used = Set<Int>()
        var result: [Chain] = []

        func walk(from index: Int, forward: Bool) -> [SIMD2<Double>] {
            var points = forward
                ? [lines[index].a, lines[index].b]
                : [lines[index].b, lines[index].a]
            used.insert(index)
            while true {
                guard let neighbors = adjacency[NodeKey(points.last!)],
                      neighbors.count == 2,
                      let next = neighbors.first(where: { !used.contains($0.line) }) else {
                    return points
                }
                used.insert(next.line)
                points.append(next.forward ? lines[next.line].b : lines[next.line].a)
            }
        }

        // Open chains start at junction/free endpoints (degree != 2).
        // Scanning lines in input order keeps the walk direction (and so the
        // offset side) deterministic — dictionary order is not, and would
        // flip which side of an open chain "left of travel" lands on.
        for (index, line) in lines.enumerated() where !used.contains(index) {
            let aDegree = adjacency[NodeKey(line.a)]?.count ?? 0
            let bDegree = adjacency[NodeKey(line.b)]?.count ?? 0
            if aDegree != 2 {
                result.append(Chain(points: walk(from: index, forward: true), isClosed: false))
            } else if bDegree != 2 {
                result.append(Chain(points: walk(from: index, forward: false), isClosed: false))
            }
        }
        // Remaining lines (all endpoints degree 2) form closed loops.
        for index in lines.indices where !used.contains(index) {
            var points = walk(from: index, forward: true)
            var isClosed = false
            if points.count >= 3, NodeKey(points.first!) == NodeKey(points.last!) {
                points.removeLast()
                isClosed = true
            }
            result.append(Chain(points: points, isClosed: isClosed))
        }
        return result
    }

    // MARK: - Segment offsetting

    private struct Seg {
        var a: SIMD2<Double>    // offset start
        var b: SIMD2<Double>    // offset end
        var dir: SIMD2<Double>  // unit ORIGINAL direction
        var length: Double      // original length
    }

    /// One offset segment per polyline edge, shifted `distance` along the
    /// LEFT normal of the travel direction.
    private static func makeSegs(
        _ points: [SIMD2<Double>], closed: Bool, distance: Double
    ) -> [Seg] {
        let count = closed ? points.count : points.count - 1
        var segs: [Seg] = []
        for i in 0..<count {
            let p = points[i]
            let q = points[(i + 1) % points.count]
            let delta = q - p
            let length = simd_length(delta)
            guard length > epsilon else { continue }
            let dir = delta / length
            let normal = SIMD2(-dir.y, dir.x) // left of travel
            segs.append(Seg(
                a: p + normal * distance,
                b: q + normal * distance,
                dir: dir,
                length: length
            ))
        }
        return segs
    }

    private static func cross2(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        a.x * b.y - a.y * b.x
    }

    /// Intersection of the two segments' infinite carrier lines; nil when
    /// (near-)parallel.
    private static func intersect(_ s: Seg, _ t: Seg) -> SIMD2<Double>? {
        let cross = cross2(s.dir, t.dir)
        guard abs(cross) > epsilon else { return nil }
        let delta = t.a - s.a
        let u = cross2(delta, t.dir) / cross
        return s.a + s.dir * u
    }

    /// `verts[i]` = mitre joint between `segs[i]` and its successor; the
    /// caller guarantees no adjacent pair is parallel.
    private static func mitredVertices(_ segs: [Seg]) -> [SIMD2<Double>] {
        segs.indices.map { i in
            intersect(segs[i], segs[(i + 1) % segs.count]) ?? segs[i].b
        }
    }

    // MARK: - Open chains

    private static func offsetPolyline(
        _ points: [SIMD2<Double>], by distance: Double
    ) -> [SketchEntity] {
        guard points.count >= 2 else { return [] }
        let segs = makeSegs(points, closed: false, distance: distance)
        guard !segs.isEmpty else { return [] }

        var verts: [SIMD2<Double>] = [segs[0].a]
        for i in 0..<(segs.count - 1) {
            let j = i + 1
            if let joint = intersect(segs[i], segs[j]) {
                verts.append(joint)
            } else if simd_dot(segs[i].dir, segs[j].dir) > 0 {
                verts.append(segs[j].a) // collinear continuation
            } else {
                // Hairpin turn: butt join with a connecting segment.
                verts.append(segs[i].b)
                verts.append(segs[j].a)
            }
        }
        verts.append(segs[segs.count - 1].b)

        var result: [SketchEntity] = []
        for i in 0..<(verts.count - 1) where simd_length(verts[i + 1] - verts[i]) > quantum {
            result.append(.line(id: UUID(), a: verts[i], b: verts[i + 1]))
        }
        return result
    }

    // MARK: - Closed loops

    /// Mitre-offset a closed loop, positive = outward. Cleanup drops segments
    /// whose offset direction flips against the original edge and resolves the
    /// anti-parallel neighbor pairs each drop exposes, iterating to a fixed
    /// point; loops that collapse or stay self-intersecting return [].
    private static func offsetLoop(
        _ loop: [SIMD2<Double>], by distance: Double
    ) -> [SketchEntity] {
        guard loop.count >= 3 else { return [] }
        var points = loop
        guard abs(Profile.signedArea(points)) > epsilon else { return [] }
        if Profile.signedArea(points) < 0 {
            points.reverse() // normalize CCW
        }

        // CCW travel keeps the interior on the LEFT, so outward is the RIGHT
        // normal: negate the distance for makeSegs' left-normal convention.
        var segs = makeSegs(points, closed: true, distance: -distance)

        var iterations = 0
        while segs.count >= 3, iterations <= loop.count * 2 {
            iterations += 1

            // Parallel neighbors can't be mitred: resolve them first.
            if let i = segs.indices.first(where: { index in
                let next = segs[(index + 1) % segs.count]
                return abs(cross2(segs[index].dir, next.dir)) < epsilon
            }) {
                let j = (i + 1) % segs.count
                if simd_dot(segs[i].dir, segs[j].dir) < 0 {
                    // Anti-parallel: the strip between them collapsed; drop
                    // the shorter side.
                    segs.remove(at: segs[i].length <= segs[j].length ? i : j)
                } else {
                    // Collinear continuation: merge into one segment.
                    segs[i].b = segs[j].b
                    segs[i].length += segs[j].length
                    segs.remove(at: j)
                }
                continue
            }

            let verts = mitredVertices(segs)
            if let flipped = segs.indices.first(where: { i in
                let a = verts[(i + segs.count - 1) % segs.count]
                let b = verts[i]
                return simd_dot(b - a, segs[i].dir) <= 0
            }) {
                segs.remove(at: flipped)
                continue
            }

            // Fixed point: emit if the loop survived as a simple polygon.
            var polygon: [SIMD2<Double>] = []
            for v in verts {
                if let last = polygon.last, simd_length(v - last) < quantum { continue }
                polygon.append(v)
            }
            if let first = polygon.first, polygon.count > 1,
               simd_length(first - polygon[polygon.count - 1]) < quantum {
                polygon.removeLast()
            }
            guard polygon.count >= 3,
                  Profile.signedArea(polygon) > epsilon,
                  !isSelfIntersecting(polygon) else {
                return []
            }
            return (0..<polygon.count).map { i in
                .line(id: UUID(), a: polygon[i], b: polygon[(i + 1) % polygon.count])
            }
        }
        return []
    }

    // MARK: - Simple-polygon check

    private static func isSelfIntersecting(_ loop: [SIMD2<Double>]) -> Bool {
        let n = loop.count
        guard n > 3 else { return false }
        for i in 0..<n {
            let a1 = loop[i]
            let a2 = loop[(i + 1) % n]
            for j in (i + 1)..<n {
                // Skip adjacent segments (shared endpoints).
                if j == i || (j + 1) % n == i || (i + 1) % n == j { continue }
                let b1 = loop[j]
                let b2 = loop[(j + 1) % n]
                if segmentsIntersect(a1, a2, b1, b2) {
                    return true
                }
            }
        }
        return false
    }

    private static func segmentsIntersect(
        _ p1: SIMD2<Double>, _ p2: SIMD2<Double>,
        _ p3: SIMD2<Double>, _ p4: SIMD2<Double>
    ) -> Bool {
        func orientation(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let d1 = orientation(p3, p4, p1)
        let d2 = orientation(p3, p4, p2)
        let d3 = orientation(p1, p2, p3)
        let d4 = orientation(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }
}

// MARK: - KernelOps facade

nonisolated extension KernelOps {

    /// Offset sketch entities by a signed distance; see `SketchOffset.offset`.
    static func offsetSketchEntities(
        _ entities: [SketchEntity], by distance: Double
    ) -> [SketchEntity] {
        SketchOffset.offset(entities: entities, by: distance)
    }
}

// MARK: - Seed → offset set

/// Which entities one tap contributes to an offset (spec §1.9). Mirrors the
/// manual's Offset Edge **Type** menu.
nonisolated enum SketchOffsetType: String, CaseIterable, Codable, Sendable {
    /// Only the tapped entity.
    case single
    /// The tapped entity plus everything endpoint-connected to it, so one tap
    /// on a wall of a closed profile offsets the whole loop.
    case chain

    var title: String { self == .single ? "Single" : "Chain" }
}

nonisolated extension SketchOffset {

    /// Expand tapped seed IDs into the entities an offset should consume.
    ///
    /// Returned in **sketch order**, not seed order: `offset(entities:by:)`
    /// walks line chains to mitre their joins, and feeding it a shuffled chain
    /// would break the walk.
    static func entitiesToOffset(
        seedIDs: Set<UUID>, type: SketchOffsetType, in entities: [SketchEntity]
    ) -> [SketchEntity] {
        guard !seedIDs.isEmpty else { return [] }
        var wanted = seedIDs
        if type == .chain {
            for seed in seedIDs {
                wanted.formUnion(ProfileDetector.connectedEntityIDs(from: seed, in: entities))
            }
        }
        return entities.filter { wanted.contains($0.id) }
    }
}
