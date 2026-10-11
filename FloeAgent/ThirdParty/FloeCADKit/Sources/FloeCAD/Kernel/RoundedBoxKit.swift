//
//  RoundedBoxKit.swift
//  openshape3d
//
//  Convex rounded box (the Minkowski sum of a sharp box and a ball), used by
//  the legacy Canvas 3D scene import for RealityKit's
//  `generateBox(size:cornerRadius:)` primitives.
//
//  The legacy 3D Director draws its box as `generateBox(size: 1,
//  cornerRadius: 0.08)` and its "plane" as the thin slab
//  `generateBox(size: (1, 0.04, 1), cornerRadius: 0.02)`. A rounded box is a
//  convex solid whose surface is:
//
//    * 6 flat rectangles (the outer faces, the core box faces offset by r),
//    * 12 quarter cylinders (one per core edge),
//    * 8 octant spheres (one per core corner),
//
//  i.e. exactly the set of points at distance r from the sharp core box
//  `size − 2r`. RealityKit clamps the radius to half the smallest dimension;
//  the legacy plane's radius IS half its thickness, which degenerates the
//  core box to a flat rectangle and the shape to the corresponding smooth
//  "pillow" — handled here without special cases beyond skipping the
//  zero-area patches.
//
//  The surface is TESSELLATED DIRECTLY here: every vertex lies on the exact
//  analytic surface, every vertex normal is the exact outward normal
//  (the normalized offset from the core box), and the patch boundaries share
//  welded vertices, so the result is a closed, consistently wound convex
//  mesh. This is a plain mesh body — no parametric feature history, no BRep,
//  no boolean/CSG fragility — which is precisely what the import needs: the
//  geometry the legacy renderer displayed, baked exactly once.
//

import Foundation
import simd
import Euclid

nonisolated enum RoundedBoxKit {

    /// A convex rounded box centred on the origin.
    ///
    /// - Parameters:
    ///   - size: The full outer dimensions (all components positive; the
    ///     radius is clamped to half the smallest).
    ///   - cornerRadius: The edge/corner rounding radius. Clamped to
    ///     `min(size)/2`, exactly like `MeshResource.generateBox`.
    ///   - segmentsPerQuarter: Tessellation segments per 90° arc. Vertices
    ///     are always ON the analytic surface; this only controls how finely
    ///     the curved patches between vertices are faceted.
    static func mesh(size: Vector,
                     cornerRadius: Double,
                     segmentsPerQuarter: Int = 16) -> Euclid.Mesh {
        let ex = abs(size.x), ey = abs(size.y), ez = abs(size.z)
        guard ex > 1e-9, ey > 1e-9, ez > 1e-9 else { return Euclid.Mesh([]) }
        let radius = min(max(cornerRadius, 0), min(ex, ey, ez) / 2)
        guard radius > 1e-9 else {
            return Euclid.Mesh.cube(center: .zero, size: Vector(ex, ey, ez))
        }
        var builder = Builder(
            radius: radius,
            halves: SIMD3(ex / 2 - radius, ey / 2 - radius, ez / 2 - radius),
            segments: max(3, segmentsPerQuarter))
        builder.build()
        return Euclid.Mesh(builder.polygons).makeWatertight()
    }

    // MARK: - Patch builder

    /// Welds shared boundary vertices and emits the 26 patches. All
    /// orientation is derived from the analytic outward normal, so the patch
    /// enumeration never has to reason about winding.
    private nonisolated struct Builder {
        let radius: Double
        /// Half extents of the sharp core box. A component can be exactly 0
        /// (the legacy thin slab's radius is half its thickness); the
        /// affected patches are skipped or handled by the degenerate
        /// triangle guard.
        let halves: SIMD3<Double>
        let segments: Int
        var polygons: [Euclid.Polygon] = []

        private var pool: [Cell: Euclid.Vertex] = [:]
        /// Positional weld cell/tolerance (unit-scale mesh). Mathematically
        /// identical boundary points from different patches differ by at
        /// most a few ulps; distinct tessellation vertices are orders of
        /// magnitude farther apart.
        private static let cellSize = 2e-8
        private static let weldTolerance = 1e-7

        private struct Cell: Hashable {
            var x: Int; var y: Int; var z: Int
        }

        mutating func build() {
            addFaces()
            addEdges()
            addCorners()
        }

        // MARK: Flat faces

        private mutating func addFaces() {
            for axis in 0 ..< 3 {
                let t1 = (axis + 1) % 3, t2 = (axis + 2) % 3
                let u = halves[t1], v = halves[t2]
                guard u > 1e-9, v > 1e-9 else { continue }
                let face = halves[axis] + radius
                for sign in [1.0, -1.0] {
                    var p1 = SIMD3<Double>.zero, p2 = SIMD3<Double>.zero
                    var p3 = SIMD3<Double>.zero, p4 = SIMD3<Double>.zero
                    func place(_ p: inout SIMD3<Double>, _ a: Double, _ b: Double) {
                        p[axis] = sign * face
                        p[t1] = a
                        p[t2] = b
                    }
                    place(&p1, -u, -v)
                    place(&p2, u, -v)
                    place(&p3, u, v)
                    place(&p4, -u, v)
                    addQuad(p1, p2, p3, p4)
                }
            }
        }

        // MARK: Edge quarter cylinders

        private mutating func addEdges() {
            for axis in 0 ..< 3 {
                let t1 = (axis + 1) % 3, t2 = (axis + 2) % 3
                let length = halves[axis]
                guard length > 1e-9 else { continue }
                let c1 = halves[t1], c2 = halves[t2]
                func point(_ station: Int, _ j: Int,
                           _ sign1: Double, _ sign2: Double) -> SIMD3<Double> {
                    let sigma = Double(j) / Double(segments) * .pi / 2
                    var p = SIMD3<Double>.zero
                    p[axis] = station == 0 ? -length : length
                    p[t1] = sign1 * (c1 + radius * cos(sigma))
                    p[t2] = sign2 * (c2 + radius * sin(sigma))
                    return p
                }
                for sign1 in [1.0, -1.0] {
                    for sign2 in [1.0, -1.0] {
                        for j in 0 ..< segments {
                            addQuad(point(0, j, sign1, sign2),
                                    point(1, j, sign1, sign2),
                                    point(1, j + 1, sign1, sign2),
                                    point(0, j + 1, sign1, sign2))
                        }
                    }
                }
            }
        }

        // MARK: Corner octant spheres

        private mutating func addCorners() {
            for sx in [1.0, -1.0] {
                for sy in [1.0, -1.0] {
                    for sz in [1.0, -1.0] {
                        let centre = SIMD3(sx * halves.x, sy * halves.y, sz * halves.z)
                        func point(_ i: Int, _ j: Int) -> SIMD3<Double> {
                            let theta = Double(i) / Double(segments) * .pi / 2
                            let phi = Double(j) / Double(segments) * .pi / 2
                            return centre + radius * SIMD3(
                                sx * cos(theta),
                                sy * sin(theta) * cos(phi),
                                sz * sin(theta) * sin(phi))
                        }
                        for i in 0 ..< segments {
                            for j in 0 ..< segments {
                                addQuad(point(i, j), point(i + 1, j),
                                        point(i + 1, j + 1), point(i, j + 1))
                            }
                        }
                    }
                }
            }
        }

        // MARK: Polygon emission

        private mutating func addQuad(_ a: SIMD3<Double>, _ b: SIMD3<Double>,
                                      _ c: SIMD3<Double>, _ d: SIMD3<Double>) {
            addTriangle(a, b, c)
            addTriangle(a, c, d)
        }

        /// Emits one outward-wound triangle. Degenerate cells (the octant's
        /// collapsed pole row, zero-length patches) are dropped, and the
        /// winding is chosen from the analytic outward normal so mis-ordered
        /// patch loops can never produce an inside-out face.
        private mutating func addTriangle(_ a: SIMD3<Double>, _ b: SIMD3<Double>,
                                          _ c: SIMD3<Double>) {
            let faceNormal = simd_cross(b - a, c - a)
            guard simd_length_squared(faceNormal) > 1e-24 else { return }
            let outward = outwardNormal(at: (a + b + c) / 3)
            let vertices = simd_dot(faceNormal, outward) < 0
                ? [vertex(at: a), vertex(at: c), vertex(at: b)]
                : [vertex(at: a), vertex(at: b), vertex(at: c)]
            guard let polygon = Euclid.Polygon(vertices) else { return }
            polygons.append(polygon)
        }

        /// The exact outward surface normal: the normalized offset from the
        /// core box (the gradient of the distance function the solid was
        /// defined by).
        private func outwardNormal(at position: SIMD3<Double>) -> SIMD3<Double> {
            let clamped = SIMD3(
                min(max(position.x, -halves.x), halves.x),
                min(max(position.y, -halves.y), halves.y),
                min(max(position.z, -halves.z), halves.z))
            let offset = position - clamped
            let length = simd_length(offset)
            guard length > 1e-12 else { return SIMD3(0, 1, 0) }
            return offset / length
        }

        /// One shared vertex per surface position: patches are generated
        /// independently, and mathematically identical boundary points must
        /// become the SAME vertex for the mesh to be watertight.
        private mutating func vertex(at position: SIMD3<Double>) -> Euclid.Vertex {
            let cell = Cell(
                x: Int((position.x / Self.cellSize).rounded(.down)),
                y: Int((position.y / Self.cellSize).rounded(.down)),
                z: Int((position.z / Self.cellSize).rounded(.down)))
            for dx in -1 ... 1 {
                for dy in -1 ... 1 {
                    for dz in -1 ... 1 {
                        if let existing = pool[Cell(x: cell.x + dx,
                                                    y: cell.y + dy,
                                                    z: cell.z + dz)],
                           (existing.position - Vector(position.x, position.y, position.z)).length
                               <= Self.weldTolerance {
                            return existing
                        }
                    }
                }
            }
            let normal = outwardNormal(at: position)
            let vertex = Euclid.Vertex(
                Vector(position.x, position.y, position.z),
                Vector(normal.x, normal.y, normal.z))
            pool[cell] = vertex
            return vertex
        }
    }
}
