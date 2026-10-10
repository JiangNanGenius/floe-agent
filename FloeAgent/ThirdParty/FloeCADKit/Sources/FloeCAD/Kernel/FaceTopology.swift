//
//  FaceTopology.swift
//  openshape3d
//
//  Planar-face extraction from triangle meshes: flood-fill coplanar connected
//  triangles from a picked seed, and recover the face's boundary loops so the
//  face can be re-extruded (Shapr3D's push/pull on faces — planar faces only).
//

import Foundation
import simd

/// A planar face of a body, in body-local coordinates.
nonisolated struct PlanarFace {
    /// Triangle indices (into the body's RenderMesh) forming the face.
    var triangles: [Int]
    /// Unit face normal (local space).
    var normal: SIMD3<Float>
    /// Plane basis in local space; normal = basisX × basisY.
    var origin: SIMD3<Double>
    var basisX: SIMD3<Double>
    var basisY: SIMD3<Double>
    /// Outer boundary in basis coordinates, CCW.
    var outline: [SIMD2<Double>]
    /// Inner boundaries (holes) in basis coordinates.
    var holes: [[SIMD2<Double>]]
}

nonisolated extension FaceTopology {
    /// `PlanarFace` lives at module scope; expose it under the `FaceTopology`
    /// namespace so the feature graph / topo-naming layers can spell
    /// `FaceTopology.PlanarFace` (frozen contract) without moving the type.
    typealias PlanarFace = FloeCAD.PlanarFace
}

/// `CylindricalFace`'s canonical home is `FaceTopology` (the frozen contract
/// spelling `FaceTopology.CylindricalFace`); expose it at module scope too so
/// enumeration callers can spell it unqualified, mirroring `PlanarFace`.
typealias CylindricalFace = FaceTopology.CylindricalFace

nonisolated enum FaceTopology {
    private static let normalTolerance: Float = 0.9995   // ~1.8°
    private static let planeTolerance: Float = 1e-3
    private static let weldQuantum: Float = 1e-5

    private struct PositionKey: Hashable {
        let x, y, z: Int64
        init(_ p: SIMD3<Float>) {
            let inv = 1 / FaceTopology.weldQuantum
            // key64: a raw Int32/Int64(_: Float) traps on NaN, and an Int32
            // key at this quantum saturates at ±21 m — which silently WELDED
            // far-apart vertices together instead. Int64 + NaN guard.
            x = MeshQuantize.key64(p.x, inverseQuantum: inv)
            y = MeshQuantize.key64(p.y, inverseQuantum: inv)
            z = MeshQuantize.key64(p.z, inverseQuantum: inv)
        }
    }

    private struct EdgeKey: Hashable {
        let a, b: PositionKey
        init(_ p: SIMD3<Float>, _ q: SIMD3<Float>) {
            let kp = PositionKey(p)
            let kq = PositionKey(q)
            // Order-independent
            if kp.x < kq.x || (kp.x == kq.x && (kp.y < kq.y || (kp.y == kq.y && kp.z <= kq.z))) {
                a = kp; b = kq
            } else {
                a = kq; b = kp
            }
        }
    }

    /// Drop collinear midpoints (CSG healing inserts them along straight
    /// edges) so outlines stay minimal.
    private static func simplifyCollinear(_ loop: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard loop.count > 3 else { return loop }
        var result: [SIMD2<Double>] = []
        let n = loop.count
        for i in 0..<n {
            let prev = loop[(i + n - 1) % n]
            let point = loop[i]
            let next = loop[(i + 1) % n]
            let a = point - prev
            let b = next - point
            let cross = a.x * b.y - a.y * b.x
            let lengths = simd_length(a) * simd_length(b)
            if lengths < 1e-12 || abs(cross) / lengths > 1e-6 {
                result.append(point)
            }
        }
        return result.count >= 3 ? result : loop
    }

    /// Extract the planar face containing `seedTriangle`, or nil when the
    /// surface there isn't planar (curved regions can't be push/pulled).
    static func planarFace(in mesh: RenderMesh, seedTriangle: Int) -> PlanarFace? {
        planarFace(in: mesh, seedTriangle: seedTriangle, adjacency: nil)
    }

    private static func planarFace(in mesh: RenderMesh, seedTriangle: Int,
                                   adjacency: [EdgeKey: [Int]]?) -> PlanarFace? {
        guard seedTriangle >= 0, seedTriangle < mesh.triangleCount else { return nil }

        func triangleVertices(_ t: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
            (
                mesh.positions[Int(mesh.indices[t * 3])],
                mesh.positions[Int(mesh.indices[t * 3 + 1])],
                mesh.positions[Int(mesh.indices[t * 3 + 2])]
            )
        }

        func triangleNormal(_ t: Int) -> SIMD3<Float>? {
            let (a, b, c) = triangleVertices(t)
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            return length > 1e-12 ? cross / length : nil
        }

        guard let seedNormal = triangleNormal(seedTriangle) else { return nil }
        let (s0, _, _) = triangleVertices(seedTriangle)
        let planeOffset = simd_dot(seedNormal, s0)

        func isCoplanar(_ t: Int) -> Bool {
            guard let n = triangleNormal(t), simd_dot(n, seedNormal) > normalTolerance else {
                return false
            }
            let (a, b, c) = triangleVertices(t)
            return abs(simd_dot(seedNormal, a) - planeOffset) < planeTolerance
                && abs(simd_dot(seedNormal, b) - planeOffset) < planeTolerance
                && abs(simd_dot(seedNormal, c) - planeOffset) < planeTolerance
        }

        // Edge → triangles adjacency (welded positions).
        let edgeTriangles = adjacency ?? Self.edgeAdjacency(in: mesh)

        // Flood fill coplanar connected triangles.
        var faceTriangles = Set<Int>()
        var queue = [seedTriangle]
        while let t = queue.popLast() {
            guard !faceTriangles.contains(t), isCoplanar(t) else { continue }
            faceTriangles.insert(t)
            let (a, b, c) = triangleVertices(t)
            for edge in [EdgeKey(a, b), EdgeKey(b, c), EdgeKey(c, a)] {
                for neighbor in edgeTriangles[edge] ?? [] where !faceTriangles.contains(neighbor) {
                    queue.append(neighbor)
                }
            }
        }
        guard !faceTriangles.isEmpty else { return nil }

        // Boundary edges: appear in exactly one face triangle (directed order
        // preserved from the triangle winding so loops come out oriented).
        struct DirectedEdge {
            let from: PositionKey
            let to: PositionKey
            let fromPos: SIMD3<Float>
            let toPos: SIMD3<Float>
        }
        var boundaryCount = [EdgeKey: Int]()
        for t in faceTriangles {
            let (a, b, c) = triangleVertices(t)
            for edge in [EdgeKey(a, b), EdgeKey(b, c), EdgeKey(c, a)] {
                boundaryCount[edge, default: 0] += 1
            }
        }
        var outgoing = [PositionKey: [DirectedEdge]]()
        var edgeTotal = 0
        for t in faceTriangles {
            let (a, b, c) = triangleVertices(t)
            for (p, q) in [(a, b), (b, c), (c, a)] where boundaryCount[EdgeKey(p, q)] == 1 {
                let edge = DirectedEdge(
                    from: PositionKey(p), to: PositionKey(q), fromPos: p, toPos: q
                )
                outgoing[edge.from, default: []].append(edge)
                edgeTotal += 1
            }
        }

        // Chain directed boundary edges into loops. CSG healing can pinch a
        // boundary through a welded vertex (two boundary edges leaving one
        // node), so keep every outgoing edge and split a closed sub-loop off
        // the walk whenever it revisits a vertex; degenerate out-and-back
        // spurs fall out as sub-loops with fewer than 3 vertices.
        var loops3D: [[SIMD3<Float>]] = []
        func takeEdge(from key: PositionKey) -> DirectedEdge? {
            guard var edges = outgoing[key], let edge = edges.popLast() else { return nil }
            outgoing[key] = edges
            return edge
        }
        for start in Array(outgoing.keys) {
            while let firstEdge = takeEdge(from: start) {
                var pathKeys = [firstEdge.from]
                var pathPositions = [firstEdge.fromPos]
                var indexOf = [firstEdge.from: 0]
                var currentKey = firstEdge.to
                var currentPos = firstEdge.toPos
                var steps = 0
                while steps <= edgeTotal {
                    steps += 1
                    if let at = indexOf[currentKey] {
                        let loop = Array(pathPositions[at...])
                        if loop.count >= 3 {
                            loops3D.append(loop)
                        }
                        for key in pathKeys[at...] {
                            indexOf[key] = nil
                        }
                        pathKeys.removeSubrange(at...)
                        pathPositions.removeSubrange(at...)
                        if pathKeys.isEmpty { break }
                    }
                    guard let edge = takeEdge(from: currentKey) else { break }
                    indexOf[currentKey] = pathKeys.count
                    pathKeys.append(currentKey)
                    pathPositions.append(currentPos)
                    currentKey = edge.to
                    currentPos = edge.toPos
                }
            }
        }
        guard !loops3D.isEmpty else { return nil }

        // Face basis: origin at the OUTER loop's centroid, X toward a
        // canonical neighbour of its lexicographically-least vertex.
        //
        // Determinism is the point (review R4-N1/R2-4): `loops3D` arrives in
        // Dictionary-traversal order, which is randomized per process, and
        // downstream `.moveFace`/`.rotateFace` deltas are STORED in this
        // basis — so a basis hung off "whichever loop came out of the hash
        // first, along whichever direction the walk happened to go" replays
        // a lateral move rotated by an arbitrary amount after a relaunch.
        // Largest-area loop + least vertex + lexicographic neighbour are all
        // properties of the face itself, not of the traversal.
        func lexLess(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            if a.x != b.x { return a.x < b.x }
            if a.y != b.y { return a.y < b.y }
            return a.z < b.z
        }
        func loopArea3D(_ loop: [SIMD3<Float>]) -> Double {
            guard loop.count >= 3 else { return 0 }
            let o = SIMD3<Double>(Double(loop[0].x), Double(loop[0].y), Double(loop[0].z))
            var cross = SIMD3<Double>.zero
            for i in 1..<(loop.count - 1) {
                let a = SIMD3<Double>(Double(loop[i].x), Double(loop[i].y), Double(loop[i].z)) - o
                let b = SIMD3<Double>(Double(loop[i + 1].x), Double(loop[i + 1].y), Double(loop[i + 1].z)) - o
                cross += simd_cross(a, b)
            }
            return simd_length(cross) * 0.5
        }
        let normalD = SIMD3<Double>(Double(seedNormal.x), Double(seedNormal.y), Double(seedNormal.z))
        var outerLoop = loops3D[0]
        var outerArea3D = loopArea3D(outerLoop)
        for loop in loops3D.dropFirst() {
            let area = loopArea3D(loop)
            if area > outerArea3D + 1e-12 {
                outerLoop = loop; outerArea3D = area
            } else if abs(area - outerArea3D) <= 1e-12,
                      let a = loop.min(by: lexLess), let b = outerLoop.min(by: lexLess),
                      lexLess(a, b) {
                outerLoop = loop  // deterministic tie-break
            }
        }
        var centroid = SIMD3<Double>.zero
        for p in outerLoop {
            centroid += SIMD3(Double(p.x), Double(p.y), Double(p.z))
        }
        centroid /= Double(outerLoop.count)

        var edgeDir = SIMD3<Double>(1, 0, 0)
        if outerLoop.count >= 2 {
            var start = 0
            for i in outerLoop.indices where lexLess(outerLoop[i], outerLoop[start]) {
                start = i
            }
            // The walk's direction is traversal-dependent too, so pick the
            // canonical NEIGHBOUR rather than "the next vertex".
            let n = outerLoop.count
            let prev = outerLoop[(start + n - 1) % n]
            let next = outerLoop[(start + 1) % n]
            let second = lexLess(prev, next) ? prev : next
            let a = outerLoop[start]
            let d = SIMD3<Double>(Double(second.x - a.x), Double(second.y - a.y),
                                  Double(second.z - a.z))
            if simd_length(d) > 1e-9 {
                edgeDir = simd_normalize(d)
            }
        }
        // Orthonormalize against the normal.
        var basisX = edgeDir - normalD * simd_dot(edgeDir, normalD)
        if simd_length(basisX) < 1e-9 {
            basisX = abs(normalD.y) < 0.9
                ? simd_normalize(simd_cross(SIMD3(0, 1, 0), normalD))
                : simd_normalize(simd_cross(SIMD3(1, 0, 0), normalD))
        } else {
            basisX = simd_normalize(basisX)
        }
        let basisY = simd_cross(normalD, basisX)

        func project(_ loop: [SIMD3<Float>]) -> [SIMD2<Double>] {
            let projected = loop.map { p -> SIMD2<Double> in
                let d = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) - centroid
                return SIMD2(simd_dot(d, basisX), simd_dot(d, basisY))
            }
            return simplifyCollinear(projected)
        }

        // Largest |area| loop is the outer boundary; orient CCW, holes too.
        var projected = loops3D.map(project)
        projected.sort { abs(Profile.signedArea($0)) > abs(Profile.signedArea($1)) }
        var outer = projected[0]
        let outerArea = abs(Profile.signedArea(outer))
        if Profile.signedArea(outer) < 0 { outer.reverse() }
        var holes: [[SIMD2<Double>]] = []
        for var hole in projected.dropFirst() {
            // CSG healing can leave near-zero-area sliver loops; drop them.
            guard abs(Profile.signedArea(hole)) > outerArea * 1e-7 else { continue }
            if Profile.signedArea(hole) < 0 { hole.reverse() }
            holes.append(hole)
        }

        return PlanarFace(
            triangles: Array(faceTriangles).sorted(),
            normal: seedNormal,
            origin: centroid,
            basisX: basisX,
            basisY: basisY,
            outline: outer,
            holes: holes
        )
    }

    // MARK: - Cylindrical surface recognition (curved face push/pull)

    /// A cylindrical side surface fitted from a smooth run of facets, in
    /// body-local coordinates. Push/pull on this surface edits the radius.
    nonisolated struct CylindricalFace {
        var triangles: [Int]          // side facets (for the selection highlight)
        var axisPoint: SIMD3<Double>  // a point on the axis
        var axisDir: SIMD3<Double>    // unit axis
        var radius: Double
        var minT: Double              // axial extent: min/max of (vertex · axisDir)
        var maxT: Double
        var segments: Int             // side-facet columns ≈ the circle tessellation
        /// True when the whole body IS this cylinder (a rebuilt cylinder of the
        /// fitted params matches the mesh) — only then is a radial grow safe.
        var matchesWholeBody: Bool

        var diameter: Double { radius * 2 }
        var height: Double { maxT - minT }
        /// Base cap centre (min end of the axis).
        var baseCenter: SIMD3<Double> {
            let mid = (axisPoint - axisDir * simd_dot(axisPoint, axisDir))
            return mid + axisDir * minT
        }
    }

    private static let smoothDihedralCos: Float = 0.72 // ~44°: joins tessellated
                                                       // wall facets, stops at rims

    /// The connected SMOOTH surface containing `seedTriangle`: triangles joined
    /// across soft edges (dihedral under ~44°), stopping at real rims. This is
    /// the whole curved face a user means when they tap a twisted or otherwise
    /// non-planar wall — `planarFace` would return only the coplanar sliver
    /// under the finger, because a curved surface has no two coplanar facets.
    ///
    /// Returns the triangle indices, plus whether the region is genuinely curved
    /// (some facet tilts away from the seed by more than the coplanar tolerance).
    static func smoothRegion(
        in mesh: RenderMesh, seedTriangle: Int
    ) -> (triangles: [Int], isCurved: Bool)? {
        smoothRegion(in: mesh, seedTriangle: seedTriangle, adjacency: nil)
    }

    private static func smoothRegion(
        in mesh: RenderMesh, seedTriangle: Int, adjacency: [EdgeKey: [Int]]?
    ) -> (triangles: [Int], isCurved: Bool)? {
        guard seedTriangle >= 0, seedTriangle < mesh.triangleCount else { return nil }

        func tri(_ t: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
            (mesh.positions[Int(mesh.indices[t * 3])],
             mesh.positions[Int(mesh.indices[t * 3 + 1])],
             mesh.positions[Int(mesh.indices[t * 3 + 2])])
        }
        func normal(_ t: Int) -> SIMD3<Float>? {
            let (a, b, c) = tri(t)
            let x = simd_cross(b - a, c - a)
            let len = simd_length(x)
            return len > 1e-12 ? x / len : nil
        }
        guard let seedN = normal(seedTriangle) else { return nil }

        let edgeTriangles = adjacency ?? Self.edgeAdjacency(in: mesh)

        var surface = Set<Int>()
        var queue = [seedTriangle]
        var maxDot: Float = 1
        while let t = queue.popLast() {
            guard !surface.contains(t), let nt = normal(t) else { continue }
            surface.insert(t)
            maxDot = min(maxDot, simd_dot(nt, seedN))
            let (a, b, c) = tri(t)
            for edge in [EdgeKey(a, b), EdgeKey(b, c), EdgeKey(c, a)] {
                for nb in edgeTriangles[edge] ?? [] where !surface.contains(nb) {
                    if let nn = normal(nb), simd_dot(nn, nt) > smoothDihedralCos {
                        queue.append(nb)
                    }
                }
            }
        }
        guard !surface.isEmpty else { return nil }
        return (surface.sorted(), maxDot < normalTolerance)
    }

    /// Recognize the curved cylindrical surface under `seedTriangle`, or nil if
    /// the region is planar or not a clean cylinder.
    static func cylindricalFace(in mesh: RenderMesh, seedTriangle: Int) -> CylindricalFace? {
        cylindricalFace(in: mesh, seedTriangle: seedTriangle, adjacency: nil)
    }

    private static func cylindricalFace(in mesh: RenderMesh, seedTriangle: Int,
                                        adjacency: [EdgeKey: [Int]]?) -> CylindricalFace? {
        guard seedTriangle >= 0, seedTriangle < mesh.triangleCount else { return nil }

        func tri(_ t: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
            (mesh.positions[Int(mesh.indices[t * 3])],
             mesh.positions[Int(mesh.indices[t * 3 + 1])],
             mesh.positions[Int(mesh.indices[t * 3 + 2])])
        }
        func normal(_ t: Int) -> SIMD3<Float>? {
            let (a, b, c) = tri(t)
            let x = simd_cross(b - a, c - a)
            let len = simd_length(x)
            return len > 1e-12 ? x / len : nil
        }
        guard let seedN = normal(seedTriangle) else { return nil }

        let edgeTriangles = adjacency ?? Self.edgeAdjacency(in: mesh)

        // Flood-fill the smooth surface: neighbours join across soft edges.
        var surface = Set<Int>()
        var queue = [seedTriangle]
        var maxDot: Float = 1 // how flat is it? (1 = all coplanar = a real plane)
        while let t = queue.popLast() {
            guard !surface.contains(t), let nt = normal(t) else { continue }
            surface.insert(t)
            maxDot = min(maxDot, simd_dot(nt, seedN))
            let (a, b, c) = tri(t)
            for edge in [EdgeKey(a, b), EdgeKey(b, c), EdgeKey(c, a)] {
                for nb in edgeTriangles[edge] ?? [] where !surface.contains(nb) {
                    if let nn = normal(nb), let nt2 = normal(t),
                       simd_dot(nn, nt2) > smoothDihedralCos {
                        queue.append(nb)
                    }
                }
            }
        }
        // A genuinely planar patch (all facets coplanar) isn't a cylinder.
        guard surface.count >= 6, maxDot < normalTolerance else { return nil }

        // Collect surface vertices and normals.
        var verts: [SIMD3<Double>] = []
        var norms: [SIMD3<Double>] = []
        var seen = Set<PositionKey>()
        for t in surface {
            guard let nt = normal(t) else { continue }
            let nd = SIMD3<Double>(Double(nt.x), Double(nt.y), Double(nt.z))
            let (a, b, c) = tri(t)
            for p in [a, b, c] {
                let key = PositionKey(p)
                if seen.insert(key).inserted {
                    verts.append(SIMD3(Double(p.x), Double(p.y), Double(p.z)))
                }
            }
            norms.append(nd)
        }
        guard verts.count >= 6 else { return nil }

        // Axis = eigenvector of Σ nᵢnᵢᵀ with the SMALLEST eigenvalue (the one
        // direction all radial normals are perpendicular to).
        var m = simd_double3x3(0)
        for n in norms { m += outer(n, n) }
        guard let axisDir0 = smallestEigenvector(m) else { return nil }
        let axisDir = simd_normalize(axisDir0)
        // Reject if normals aren't actually perpendicular to the axis.
        let axialLeak = norms.map { abs(simd_dot($0, axisDir)) }.reduce(0, +) / Double(norms.count)
        guard axialLeak < 0.12 else { return nil }

        // Axis point (centroid) and radius (mean distance to the axis line).
        var centroid = SIMD3<Double>.zero
        for v in verts { centroid += v }
        centroid /= Double(verts.count)
        func distToAxis(_ v: SIMD3<Double>) -> Double {
            let d = v - centroid
            let along = simd_dot(d, axisDir)
            return simd_length(d - axisDir * along)
        }
        let radii = verts.map(distToAxis)
        let radius = radii.reduce(0, +) / Double(radii.count)
        guard radius > 1e-4 else { return nil }
        // Fit quality: radial spread must be tight relative to the radius.
        let spread = sqrt(radii.map { ($0 - radius) * ($0 - radius) }.reduce(0, +) / Double(radii.count))
        guard spread < radius * 0.06 else { return nil }

        let ts = verts.map { simd_dot($0, axisDir) }
        let minT = ts.min() ?? 0
        let maxT = ts.max() ?? 0
        guard maxT - minT > 1e-4 else { return nil }

        // Whole-body check: does a rebuilt cylinder of these params match?
        let matches = rebuiltCylinderMatches(
            mesh: mesh, axisPoint: centroid, axisDir: axisDir,
            radius: radius, minT: minT, maxT: maxT
        )

        return CylindricalFace(
            triangles: Array(surface).sorted(),
            axisPoint: centroid, axisDir: axisDir, radius: radius,
            minT: minT, maxT: maxT,
            segments: max(surface.count / 2, 12),
            matchesWholeBody: matches
        )
    }

    /// A rebuilt cylinder matches the body when the mesh's volume is (nearly)
    /// the full analytic cylinder volume — the safe signal that the body is a
    /// plain cylinder we can rebuild. A pocket/notch removes volume and fails.
    private static func rebuiltCylinderMatches(
        mesh: RenderMesh, axisPoint: SIMD3<Double>, axisDir: SIMD3<Double>,
        radius: Double, minT: Double, maxT: Double
    ) -> Bool {
        // Bounds sanity: two cross-axis extents ≈ diameter, one ≈ height.
        let aabb = mesh.localAABB
        let dims = [Double(aabb.max.x - aabb.min.x),
                    Double(aabb.max.y - aabb.min.y),
                    Double(aabb.max.z - aabb.min.z)].sorted()
        let height = maxT - minT
        let diameter = radius * 2
        let nearDia = dims.filter { abs($0 - diameter) < diameter * 0.08 }.count
        let hasHeight = dims.contains { abs($0 - height) < max(height * 0.1, 1e-3) }
        guard nearDia >= 2, hasHeight else { return false }

        // Volume: a tessellated cylinder is ~0.997× the analytic volume; a
        // notch/pocket removes materially more. 0.95 leaves tessellation margin.
        let analytic = Double.pi * radius * radius * height
        guard analytic > 1e-9 else { return false }
        return meshVolume(mesh) / analytic > 0.95
    }

    /// Signed-tetrahedron volume of a triangle mesh (Double).
    private static func meshVolume(_ mesh: RenderMesh) -> Double {
        var v = 0.0
        var t = 0
        while t < mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[t * 3])]
            let b = mesh.positions[Int(mesh.indices[t * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[t * 3 + 2])]
            let ad = SIMD3<Double>(Double(a.x), Double(a.y), Double(a.z))
            let bd = SIMD3<Double>(Double(b.x), Double(b.y), Double(b.z))
            let cd = SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z))
            v += simd_dot(ad, simd_cross(bd, cd)) / 6
            t += 1
        }
        return abs(v)
    }

    // MARK: - Whole-mesh face enumeration

    /// Partition every triangle of `mesh` into faces: cylindrical side surfaces
    /// and planar faces. Each triangle is claimed by exactly one face (no
    /// double-claim, no orphan).
    ///
    /// Strategy: walk triangles in index order and seed each one not yet claimed
    /// by an earlier face. For a fresh seed, first try `cylindricalFace` (a
    /// smooth flood across soft edges) — if it recognizes a clean cylindrical
    /// surface, claim that run. Otherwise fall back to `planarFace` (a coplanar
    /// flood) and claim the coplanar patch. A seed whose surface is neither
    /// (degenerate triangle) is claimed on its own so enumeration terminates
    /// with no orphaned triangles. Because faces meet at hard edges, only the
    /// seed's own unclaimed region is ever claimed, and every seed advances the
    /// frontier, so the loop covers all triangles in one pass.
    /// Edge → triangles, built ONCE per mesh.
    ///
    /// `planarFace`, `smoothRegion` and `cylindricalFace` each used to build
    /// this for themselves, and `enumerateFaces` calls them once per unclaimed
    /// triangle — so the enumeration was O(n²) in the triangle count, hashing
    /// three edge keys per triangle every time. It only bit on surfaces where
    /// seeds keep FAILING to claim anything: a torus has no planar faces and
    /// fits no cylinder, so all 4,608 of its triangles paid a full rebuild
    /// each and `faceTable` took ~65 SECONDS. A revolved circle was therefore
    /// a minute-long hang on a completely ordinary operation.
    private static func edgeAdjacency(in mesh: RenderMesh) -> [EdgeKey: [Int]] {
        var edgeTriangles = [EdgeKey: [Int]]()
        edgeTriangles.reserveCapacity(mesh.triangleCount * 3)
        for t in 0..<mesh.triangleCount {
            let a = mesh.positions[Int(mesh.indices[t * 3])]
            let b = mesh.positions[Int(mesh.indices[t * 3 + 1])]
            let c = mesh.positions[Int(mesh.indices[t * 3 + 2])]
            edgeTriangles[EdgeKey(a, b), default: []].append(t)
            edgeTriangles[EdgeKey(b, c), default: []].append(t)
            edgeTriangles[EdgeKey(c, a), default: []].append(t)
        }
        return edgeTriangles
    }

    /// Partition triangles into SMOOTH-connected components, once.
    ///
    /// `cylindricalFace` floods exactly this component from its seed before it
    /// attempts a cylinder fit, and the flood depends only on the mesh — not on
    /// which triangle inside it started. So when the fit fails, it will fail
    /// for every other seed in the same component too, and re-flooding for each
    /// of them is pure waste.
    ///
    /// That waste was the rest of the torus hang. Sharing the edge map took
    /// `faceTable` from ~65 s to ~41 s; it is this that takes it to well under
    /// a second, because a torus is ONE smooth component of 4,608 triangles
    /// that no cylinder fits — so the old code flooded all 4,608 triangles once
    /// per seed, 2,304 times over.
    ///
    /// Returns a component id per triangle (-1 for a degenerate triangle).
    private static func smoothComponents(in mesh: RenderMesh,
                                         adjacency: [EdgeKey: [Int]]) -> [Int] {
        let count = mesh.triangleCount
        var component = [Int](repeating: -2, count: count)   // -2 = unvisited
        func tri(_ t: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
            (mesh.positions[Int(mesh.indices[t * 3])],
             mesh.positions[Int(mesh.indices[t * 3 + 1])],
             mesh.positions[Int(mesh.indices[t * 3 + 2])])
        }
        func normal(_ t: Int) -> SIMD3<Float>? {
            let (a, b, c) = tri(t)
            let x = simd_cross(b - a, c - a)
            let len = simd_length(x)
            return len > 1e-12 ? x / len : nil
        }
        var next = 0
        for seed in 0..<count where component[seed] == -2 {
            guard normal(seed) != nil else { component[seed] = -1; continue }
            let id = next; next += 1
            var queue = [seed]
            component[seed] = id
            while let t = queue.popLast() {
                guard let nt = normal(t) else { continue }
                let (a, b, c) = tri(t)
                for edge in [EdgeKey(a, b), EdgeKey(b, c), EdgeKey(c, a)] {
                    for nb in adjacency[edge] ?? [] where component[nb] == -2 {
                        guard let nn = normal(nb) else { continue }
                        if simd_dot(nn, nt) > smoothDihedralCos {
                            component[nb] = id
                            queue.append(nb)
                        }
                    }
                }
            }
        }
        return component
    }

    static func enumerateFaces(in mesh: RenderMesh) -> (planar: [PlanarFace], cylindrical: [CylindricalFace]) {
        var planar: [PlanarFace] = []
        var cylindrical: [CylindricalFace] = []
        let count = mesh.triangleCount
        guard count > 0 else { return (planar, cylindrical) }

        var claimed = [Bool](repeating: false, count: count)
        // Both built once and shared: see `edgeAdjacency` / `smoothComponents`.
        let adjacency = edgeAdjacency(in: mesh)
        let component = smoothComponents(in: mesh, adjacency: adjacency)
        // Components whose cylinder fit already failed. The fit floods the
        // whole component before deciding, and the verdict cannot differ
        // between seeds inside one component, so one refusal settles it for all
        // of them.
        var cylinderRefused = Set<Int>()

        for seed in 0..<count where !claimed[seed] {
            // Cylindrical first: a smooth run of facets fitting a cylinder.
            let region = component[seed]
            if !cylinderRefused.contains(region) {
                if let cyl = cylindricalFace(in: mesh, seedTriangle: seed, adjacency: adjacency) {
                    let fresh = cyl.triangles.filter { $0 >= 0 && $0 < count && !claimed[$0] }
                    if fresh.contains(seed), fresh.count >= 6 {
                        for t in fresh { claimed[t] = true }
                        var face = cyl
                        face.triangles = fresh.sorted()
                        cylindrical.append(face)
                        continue
                    }
                } else if region >= 0 {
                    // The FIT itself refused, which is a property of the
                    // component, not of this seed. Do not re-flood it 2,303
                    // more times.
                    cylinderRefused.insert(region)
                }
            }

            // Planar coplanar patch.
            if let flat = planarFace(in: mesh, seedTriangle: seed, adjacency: adjacency) {
                let fresh = flat.triangles.filter { $0 >= 0 && $0 < count && !claimed[$0] }
                if fresh.contains(seed) {
                    for t in fresh { claimed[t] = true }
                    var face = flat
                    face.triangles = fresh.sorted()
                    planar.append(face)
                    continue
                }
            }

            // Neither recognized the surface (degenerate seed): claim it alone
            // so the walk makes progress and leaves no orphan.
            claimed[seed] = true
        }

        return (planar, cylindrical)
    }

    // MARK: - Small linear-algebra helpers

    private static func outer(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> simd_double3x3 {
        simd_double3x3(columns: (a * b.x, a * b.y, a * b.z))
    }

    /// Eigenvector for the smallest eigenvalue of a symmetric 3×3 matrix, via
    /// cyclic Jacobi rotations.
    private static func smallestEigenvector(_ input: simd_double3x3) -> SIMD3<Double>? {
        var a = input
        var v = matrix_identity_double3x3
        for _ in 0..<24 {
            // Largest off-diagonal.
            let a01 = abs(a[1][0]), a02 = abs(a[2][0]), a12 = abs(a[2][1])
            var p = 0, q = 1, maxv = a01
            if a02 > maxv { p = 0; q = 2; maxv = a02 }
            if a12 > maxv { p = 1; q = 2; maxv = a12 }
            if maxv < 1e-14 { break }
            let app = a[p][p], aqq = a[q][q], apq = a[q][p]
            let phi = 0.5 * atan2(2 * apq, aqq - app)
            let c = cos(phi), s = sin(phi)
            var j = matrix_identity_double3x3
            j[p][p] = c; j[q][q] = c; j[q][p] = s; j[p][q] = -s
            a = j.transpose * a * j
            v = v * j
        }
        let eig = [a[0][0], a[1][1], a[2][2]]
        var minIdx = 0
        if eig[1] < eig[minIdx] { minIdx = 1 }
        if eig[2] < eig[minIdx] { minIdx = 2 }
        let col = v.columns
        let e = [col.0, col.1, col.2][minIdx]
        return simd_length(e) > 1e-9 ? e : nil
    }
}
