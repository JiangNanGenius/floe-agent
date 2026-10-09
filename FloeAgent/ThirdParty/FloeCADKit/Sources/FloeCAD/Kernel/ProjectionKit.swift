//
//  ProjectionKit.swift
//  openshape3d
//
//  Unlinked sketch projection (plan §B8, spec §1.13 v1): flattens a body's
//  geometry onto a sketch plane along the plane normal, emitting plain line
//  entities. `project` flattens the feature-edge set; `projectSilhouette`
//  walks the boundary of the projected triangle soup (outline only).
//  Both dedupe near-duplicates and merge collinear chains.
//

import Foundation
import simd

nonisolated enum ProjectionKit {

    /// Segments shorter than this (plane units) are treated as points and
    /// dropped (edges parallel to the plane normal).
    private static let lengthEpsilon = 1e-5
    /// Tolerance for grouping segments onto one infinite line (direction
    /// components and perpendicular offset). Feature-edge positions are
    /// Float32-derived, so exact doubles cannot be assumed.
    private static let lineQuantum = 1e-4

    // MARK: Edge projection

    /// Projects the body's feature edges onto `plane` along its normal,
    /// in world space (body transform applied). Collinear overlapping pieces
    /// merge into single lines; degenerate (normal-parallel) edges drop out.
    static func project(body: Body, onto plane: SketchPlane) -> [SketchEntity] {
        let transform = body.transform
        let source = body.edges.segments
        var segments: [(SIMD2<Double>, SIMD2<Double>)] = []
        segments.reserveCapacity(source.count / 2)
        var i = 0
        while i + 1 < source.count {
            let a = plane.toLocal(transform.applying(to: SIMD3<Double>(source[i])))
            let b = plane.toLocal(transform.applying(to: SIMD3<Double>(source[i + 1])))
            i += 2
            if simd_length(b - a) > lengthEpsilon {
                segments.append((a, b))
            }
        }
        return mergedLineEntities(from: segments)
    }

    // MARK: Silhouette projection (v1: outline of the projected triangle soup)

    /// Projects every triangle of the body onto `plane` and returns the
    /// boundary of their union as line entities. Boundary test: split each
    /// candidate edge at its intersections with all other edges, then keep
    /// sub-segments covered by triangles on exactly one side.
    static func projectSilhouette(body: Body, onto plane: SketchPlane) -> [SketchEntity] {
        let transform = body.transform
        let mesh = body.render
        guard mesh.triangleCount > 0 else { return [] }

        func planePoint(_ index: Int) -> SIMD2<Double> {
            plane.toLocal(transform.applying(to: SIMD3<Double>(mesh.positions[index])))
        }

        // 1. Project triangles, dropping edge-on (near-zero-area) ones.
        var triangles: [(SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)] = []
        var scale = 0.0
        for t in 0..<mesh.triangleCount {
            let a = planePoint(Int(mesh.indices[t * 3]))
            let b = planePoint(Int(mesh.indices[t * 3 + 1]))
            let c = planePoint(Int(mesh.indices[t * 3 + 2]))
            let ab = b - a
            let ac = c - a
            let area2 = abs(ab.x * ac.y - ab.y * ac.x)
            scale = max(scale, simd_length(ab), simd_length(ac))
            if area2 > 1e-9 * max(scale * scale, 1) {
                triangles.append((a, b, c))
            }
        }
        guard !triangles.isEmpty else { return [] }
        let epsilon = max(scale, 1) * 1e-6

        // 2. Unique candidate edges (quantized undirected dedupe).
        struct EdgeKey: Hashable {
            let ax, ay, bx, by: Int64
        }
        func quantized(_ p: SIMD2<Double>) -> (Int64, Int64) {
            (MeshQuantize.key64(p.x, quantum: epsilon), MeshQuantize.key64(p.y, quantum: epsilon))
        }
        var seen = Set<EdgeKey>()
        var edges: [(SIMD2<Double>, SIMD2<Double>)] = []
        for (a, b, c) in triangles {
            for (p, q) in [(a, b), (b, c), (c, a)] {
                let qp = quantized(p)
                let qq = quantized(q)
                let forward = qp <= qq
                let key = forward
                    ? EdgeKey(ax: qp.0, ay: qp.1, bx: qq.0, by: qq.1)
                    : EdgeKey(ax: qq.0, ay: qq.1, bx: qp.0, by: qp.1)
                if seen.insert(key).inserted, simd_length(q - p) > lengthEpsilon {
                    edges.append((p, q))
                }
            }
        }

        // 3. Coverage test: point inside (inclusive) any projected triangle.
        func covered(_ p: SIMD2<Double>) -> Bool {
            for (a, b, c) in triangles {
                let d0 = cross2(b - a, p - a)
                let d1 = cross2(c - b, p - b)
                let d2 = cross2(a - c, p - c)
                let tol = epsilon * max(scale, 1)
                let hasNeg = d0 < -tol || d1 < -tol || d2 < -tol
                let hasPos = d0 > tol || d1 > tol || d2 > tol
                if !(hasNeg && hasPos) { return true }
            }
            return false
        }

        // 4. Split each edge at intersections with the others; keep pieces
        //    covered on exactly one perpendicular side.
        var boundary: [(SIMD2<Double>, SIMD2<Double>)] = []
        for (index, edge) in edges.enumerated() {
            let (a, b) = edge
            let dir = b - a
            let length = simd_length(dir)
            let unit = dir / length
            let normal = SIMD2(-unit.y, unit.x)

            var cuts: [Double] = [0, 1]
            for (other, otherEdge) in edges.enumerated() where other != index {
                let (p, q) = otherEdge
                let denominator = cross2(dir, q - p)
                guard abs(denominator) > 1e-12 else { continue }
                let t = cross2(p - a, q - p) / denominator
                let u = cross2(p - a, dir) / denominator
                if t > 1e-9, t < 1 - 1e-9, u >= -1e-9, u <= 1 + 1e-9 {
                    cuts.append(t)
                }
            }
            cuts.sort()

            for i in 0..<(cuts.count - 1) {
                let t0 = cuts[i]
                let t1 = cuts[i + 1]
                guard (t1 - t0) * length > lengthEpsilon else { continue }
                let mid = a + dir * ((t0 + t1) / 2)
                let offset = normal * (epsilon * 10)
                let left = covered(mid + offset)
                let right = covered(mid - offset)
                if left != right {
                    boundary.append((a + dir * t0, a + dir * t1))
                }
            }
        }
        return mergedLineEntities(from: boundary)
    }

    // MARK: Collinear merge

    private static func cross2(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        a.x * b.y - a.y * b.x
    }

    /// Groups segments by their carrier line (canonical direction + signed
    /// offset, quantized), merges overlapping/touching parameter intervals
    /// per line, and emits one `.line` entity per merged interval.
    static func mergedLineEntities(
        from segments: [(SIMD2<Double>, SIMD2<Double>)]
    ) -> [SketchEntity] {
        struct LineKey: Hashable {
            let dx, dy, offset: Int64
        }

        struct Interval {
            var t0: Double
            var t1: Double
            var direction: SIMD2<Double>
            var normal: SIMD2<Double>
            var offsetSum: Double
            var count: Int
        }

        var groups = [LineKey: [Interval]]()
        for (a, b) in segments {
            let delta = b - a
            let length = simd_length(delta)
            guard length > lengthEpsilon else { continue }
            var direction = delta / length
            // Canonical sign so opposite-direction duplicates coincide.
            if direction.x < -1e-12 || (abs(direction.x) <= 1e-12 && direction.y < 0) {
                direction = -direction
            }
            let normal = SIMD2(-direction.y, direction.x)
            let offset = simd_dot(a, normal)
            let key = LineKey(
                dx: MeshQuantize.key64(direction.x, quantum: lineQuantum),
                dy: MeshQuantize.key64(direction.y, quantum: lineQuantum),
                offset: MeshQuantize.key64(offset, quantum: lineQuantum)
            )
            let ta = simd_dot(a, direction)
            let tb = simd_dot(b, direction)
            groups[key, default: []].append(Interval(
                t0: min(ta, tb), t1: max(ta, tb),
                direction: direction, normal: normal,
                offsetSum: (simd_dot(a, normal) + simd_dot(b, normal)) / 2,
                count: 1
            ))
        }

        var entities: [SketchEntity] = []
        for intervals in groups.values {
            let sorted = intervals.sorted { $0.t0 < $1.t0 }
            var merged: [Interval] = []
            for interval in sorted {
                if var last = merged.last, interval.t0 <= last.t1 + lengthEpsilon {
                    last.t1 = max(last.t1, interval.t1)
                    last.offsetSum += interval.offsetSum
                    last.count += interval.count
                    merged[merged.count - 1] = last
                } else {
                    merged.append(interval)
                }
            }
            for interval in merged {
                let offset = interval.offsetSum / Double(interval.count)
                let base = interval.normal * offset
                entities.append(.line(
                    id: UUID(),
                    a: base + interval.direction * interval.t0,
                    b: base + interval.direction * interval.t1
                ))
            }
        }
        return entities
    }
}
