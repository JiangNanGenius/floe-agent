//
//  ShellKit.swift
//  openshape3d
//
//  Shell (spec §4.4), mesh-kernel version: hollow a solid to a uniform wall
//  thickness, optionally opening selected planar faces. The inner cavity is
//  the body with every vertex offset inward so each adjacent face PLANE moves
//  by the wall thickness (least-squares over the vertex's distinct face
//  normals — exact for prismatic solids, mitred elsewhere).
//
//  The result is BUILT, not booleaned: the outer surface, plus the inverted
//  inner surface as a void, plus — for each open face — a band of quads in
//  the face plane joining the face's outline to the cavity's, in place of the
//  outer and inner copies of that face. There is no CSG anywhere in it.
//
//  It used to be CSG — subtract the cavity, then subtract a prism over each
//  open face inset by the wall. The prism's wall lay on the SAME plane as
//  the cavity wall, and on a Ø21 × 10 mm cylinder with a 2 mm wall and the
//  top open (bug report 6cb10527, 2026-09-05) the BSP left zero-width
//  slivers that `makeWatertight` tried to cap with a degenerate triangle: an
//  assertion in Debug, and on the iPad a crash the moment the face was
//  tapped. Merging the opening into the offset solve did not help either —
//  the mitred inner vertices of a fan-capped cylinder sit exactly on the
//  cap triangles' edges, which is the other way to make a BSP produce
//  slivers. Constructing the surface directly sidesteps all of it.
//

import Foundation
import simd
import Euclid

nonisolated extension KernelOps {

    /// Hollow `mesh` to a wall of `thickness`, opening `openFaces` (empty =
    /// fully enclosed hollow, Shapr3D's whole-body Shell). `mesh` and the
    /// faces share one (body-local) coordinate space. Returns an EMPTY mesh
    /// when the request is degenerate or the thickness eats the body — the
    /// caller treats empty as "invalid thickness" (red-arrow validity).
    static func shell(
        mesh: Euclid.Mesh,
        thickness: Double,
        openFaces: [PlanarFace] = []
    ) -> Euclid.Mesh {
        guard thickness > 1e-6, !mesh.polygons.isEmpty else { return Euclid.Mesh([]) }

        // Every opening must keep a full-width rim: a face narrower than two
        // walls cannot be opened (Shapr3D refuses rather than thinning it).
        for face in openFaces where !openingIsViable(face, thickness: thickness) {
            return Euclid.Mesh([])
        }

        // The cavity must be a real solid strictly smaller than the body;
        // a collapsed/inverted cavity means the wall ate the body. Judged on
        // the fully CLOSED cavity so the answer does not depend on which
        // faces are open.
        let closed = offsetInward(mesh: mesh, by: thickness, openFaces: [])
        let cavity = Euclid.Mesh(closed.polygons.compactMap { $0 }).makeWatertight()
        let innerVolume = signedVolume(cavity)
        guard innerVolume > 1e-9, innerVolume < signedVolume(mesh) else {
            return Euclid.Mesh([])
        }

        // Open faces stay in their own plane (target 0) so the rim band that
        // replaces them is planar; everything else moves inward by the wall.
        let offset = openFaces.isEmpty
            ? closed : offsetInward(mesh: mesh, by: thickness, openFaces: openFaces)

        var polygons = [Euclid.Polygon]()
        polygons.reserveCapacity(mesh.polygons.count * 2)
        // Edges of open polygons, keyed by welded endpoints: an edge seen from
        // only ONE open polygon is the opening's boundary and gets a rim quad.
        var openEdgeCount = [Set<OffsetKey>: Int]()
        for (i, outer) in mesh.polygons.enumerated() where offset.isOpen[i] {
            let vs = outer.vertices
            for j in vs.indices {
                let key = OffsetKey.edge(vs[j].position, vs[(j + 1) % vs.count].position)
                openEdgeCount[key, default: 0] += 1
            }
        }
        for (i, outer) in mesh.polygons.enumerated() {
            if offset.isOpen[i] {
                let vs = outer.vertices
                let normal = outer.plane.normal
                for j in vs.indices {
                    let a = vs[j].position, b = vs[(j + 1) % vs.count].position
                    guard openEdgeCount[OffsetKey.edge(a, b)] == 1 else { continue }
                    // Outer edge a→b runs CCW seen from outside, interior on
                    // its left; the inset points sit on that side, so
                    // a → b → b' → a' faces the same way as the face did.
                    let a2 = offset.moved(a), b2 = offset.moved(b)
                    if let band = Euclid.Polygon([
                        Vertex(a, normal), Vertex(b, normal), Vertex(b2, normal), Vertex(a2, normal),
                    ]) {
                        polygons.append(band)
                    }
                }
                continue
            }
            polygons.append(outer)
            if let inner = offset.polygons[i] {
                polygons.append(inner.inverted())
            }
        }
        // Offsetting can collapse a polygon (thin features) — those were
        // skipped above; welding heals the small gaps they leave.
        let result = Euclid.Mesh(polygons).makeWatertight()
        // Never hand NaN geometry to the renderer or the quantizing edge
        // extractor: a result that came apart numerically reads as invalid.
        guard isFinite(result) else { return Euclid.Mesh([]) }
        return result
    }

    /// Every vertex finite.
    static func isFinite(_ mesh: Euclid.Mesh) -> Bool {
        for polygon in mesh.polygons {
            for vertex in polygon.vertices {
                let p = vertex.position
                if !(p.x.isFinite && p.y.isFinite && p.z.isFinite) { return false }
            }
        }
        return true
    }

    /// Whether `face` can be opened at this wall: its outline inset by the
    /// thickness must survive (a rim narrower than the wall would collapse).
    private static func openingIsViable(_ face: PlanarFace, thickness: Double) -> Bool {
        guard let outline = offsetLoop(face.outline, by: -thickness) else { return false }
        return abs(Profile.signedArea(outline)) > 1e-9
    }

    // MARK: - Inner cavity (vertex offset)

    /// Welded-vertex key at a fixed quantum, and an order-free edge key.
    struct OffsetKey: Hashable {
        static let quantum = 1e-6
        let x, y, z: Int64
        init(_ p: Vector) {
            let inv = 1 / Self.quantum
            x = MeshQuantize.key64(p.x, inverseQuantum: inv)
            y = MeshQuantize.key64(p.y, inverseQuantum: inv)
            z = MeshQuantize.key64(p.z, inverseQuantum: inv)
        }
        static func edge(_ a: Vector, _ b: Vector) -> Set<OffsetKey> { [OffsetKey(a), OffsetKey(b)] }
    }

    /// One polygon of the cavity per polygon of the source (nil where the
    /// offset collapsed it), which polygons lie on an open face, and the
    /// per-vertex displacement so callers can move any source point.
    struct OffsetResult {
        var polygons: [Euclid.Polygon?]
        var isOpen: [Bool]
        var displacement: [OffsetKey: SIMD3<Double>]

        func moved(_ p: Vector) -> Vector {
            let d = displacement[OffsetKey(p)] ?? .zero
            return Vector(p.x + d.x, p.y + d.y, p.z + d.z)
        }
    }

    /// Every welded vertex moved so each adjacent face plane shifts INWARD by
    /// `distance` — or, for a plane that is one of `openFaces`, not at all:
    /// solve `nᵢ · d = tᵢ` over the vertex's distinct polygon normals in
    /// least squares. One normal gives `d = t·n` (face interior), two the
    /// mitred edge offset, three+ the corner intersection.
    private static func offsetInward(
        mesh: Euclid.Mesh, by distance: Double, openFaces: [PlanarFace]
    ) -> OffsetResult {
        // Distinct adjacent plane normals per welded vertex, each with the
        // signed distance its plane moves (negative = inward).
        struct Constraint {
            let normal: SIMD3<Double>
            var target: Double
        }
        var constraints = [OffsetKey: [Constraint]]()
        var isOpen = [Bool](repeating: false, count: mesh.polygons.count)
        for (i, polygon) in mesh.polygons.enumerated() {
            let pn = polygon.plane.normal
            let n = SIMD3(pn.x, pn.y, pn.z)
            let open = Self.isOpen(polygon, normal: n, in: openFaces)
            isOpen[i] = open
            let target = open ? 0 : -distance
            for vertex in polygon.vertices {
                let key = OffsetKey(vertex.position)
                var list = constraints[key] ?? []
                if let k = list.firstIndex(where: { simd_dot($0.normal, n) > 0.9995 }) {
                    // The same plane seen from an open and a closed polygon
                    // cannot happen for a flood-filled face; keep the larger
                    // (open) target if it ever does.
                    list[k].target = max(list[k].target, target)
                } else {
                    list.append(Constraint(normal: n, target: target))
                }
                constraints[key] = list
            }
        }

        // Per-vertex displacement: d = (Σ nᵢnᵢᵀ + εI)⁻¹ · Σ nᵢ·tᵢ.
        var displacement = [OffsetKey: SIMD3<Double>]()
        let maxShift = distance * 8   // mitre blow-up guard (near-parallel planes)
        for (key, list) in constraints {
            var a = simd_double3x3(diagonal: SIMD3(repeating: 1e-9))
            var b = SIMD3<Double>()
            for c in list {
                let n = c.normal
                a += simd_double3x3(columns: (n * n.x, n * n.y, n * n.z))
                b += n * c.target
            }
            var d = a.inverse * b
            let len = simd_length(d)
            if len > maxShift { d *= maxShift / len }
            displacement[key] = d
        }

        var result = OffsetResult(polygons: [], isOpen: isOpen, displacement: displacement)
        result.polygons.reserveCapacity(mesh.polygons.count)
        for polygon in mesh.polygons {
            let vertices = polygon.vertices.map { vertex -> Euclid.Vertex in
                Euclid.Vertex(result.moved(vertex.position), vertex.normal)
            }
            result.polygons.append(Euclid.Polygon(vertices))
        }
        return result
    }

    /// Whether `polygon` lies on one of the open faces: same plane, and its
    /// centroid inside that face's outline (and outside its holes) — the
    /// outline test keeps a coplanar-but-separate face, like the other step
    /// of a stepped block, closed.
    private static func isOpen(
        _ polygon: Euclid.Polygon, normal n: SIMD3<Double>, in openFaces: [PlanarFace]
    ) -> Bool {
        guard !openFaces.isEmpty else { return false }
        let planeTolerance = 1e-3
        for face in openFaces {
            let fn = SIMD3(Double(face.normal.x), Double(face.normal.y), Double(face.normal.z))
            guard simd_dot(n, fn) > 0.9995 else { continue }
            var centroid = SIMD3<Double>.zero
            var onPlane = true
            for vertex in polygon.vertices {
                let p = SIMD3(vertex.position.x, vertex.position.y, vertex.position.z)
                if abs(simd_dot(p - face.origin, fn)) > planeTolerance { onPlane = false; break }
                centroid += p
            }
            guard onPlane else { continue }
            centroid /= Double(max(polygon.vertices.count, 1))
            let local = centroid - face.origin
            let uv = SIMD2(simd_dot(local, face.basisX), simd_dot(local, face.basisY))
            guard pointInLoopInclusive(uv, face.outline) else { continue }
            if face.holes.contains(where: { pointStrictlyInLoop(uv, $0) }) { continue }
            return true
        }
        return false
    }

    /// Signed volume via the divergence theorem (positive for an outward-
    /// oriented closed mesh).
    private static func signedVolume(_ mesh: Euclid.Mesh) -> Double {
        var total = 0.0
        for polygon in mesh.polygons {
            let vertices = polygon.vertices
            guard vertices.count >= 3 else { continue }
            let pa = vertices[0].position
            let a = SIMD3(pa.x, pa.y, pa.z)
            for i in 1..<(vertices.count - 1) {
                let pb = vertices[i].position
                let pc = vertices[i + 1].position
                let b = SIMD3(pb.x, pb.y, pb.z)
                let c = SIMD3(pc.x, pc.y, pc.z)
                total += simd_dot(a, simd_cross(b, c)) / 6
            }
        }
        return total
    }

    // MARK: - Loop offset

    /// Offset a simple closed loop: positive `amount` GROWS the enclosed
    /// region, negative shrinks it. Mitred joins; vertices whose adjacent
    /// offset edges reversed direction (collapsed through the far wall) drop
    /// out. Nil when fewer than 3 vertices survive or the loop inverted.
    static func offsetLoop(
        _ loop: [SIMD2<Double>], by amount: Double
    ) -> [SIMD2<Double>]? {
        guard loop.count >= 3 else { return nil }
        // Normalize to CCW so "outward" is a fixed side.
        let ccw = Profile.signedArea(loop) >= 0 ? loop : Array(loop.reversed())
        let n = ccw.count

        // Offset line per edge: point + outward normal · amount.
        // CCW travel keeps the interior on the LEFT, so outward = right
        // normal = (dy, -dx).
        var offsetPoints = [SIMD2<Double>]()
        offsetPoints.reserveCapacity(n)
        for i in 0..<n {
            let prev = ccw[(i + n - 1) % n]
            let point = ccw[i]
            let next = ccw[(i + 1) % n]
            var dirIn = point - prev
            var dirOut = next - point
            let lenIn = simd_length(dirIn), lenOut = simd_length(dirOut)
            guard lenIn > 1e-12, lenOut > 1e-12 else { continue }
            dirIn /= lenIn; dirOut /= lenOut
            let normalIn = SIMD2(dirIn.y, -dirIn.x)
            let normalOut = SIMD2(dirOut.y, -dirOut.x)
            // Mitre: the offset vertex w satisfies w·nIn = w·nOut = amount
            // (signed distance `amount` from BOTH adjacent edges). 2×2 solve;
            // near-parallel edges (det → 0) fall back to the shared normal.
            let det = normalIn.x * normalOut.y - normalIn.y * normalOut.x
            if abs(det) < 1e-9 {
                offsetPoints.append(point + normalOut * amount)
            } else {
                let w = SIMD2(
                    amount * (normalOut.y - normalIn.y) / det,
                    amount * (normalIn.x - normalOut.x) / det
                )
                offsetPoints.append(point + w)
            }
        }

        // Drop vertices whose adjacent edge FLIPPED direction relative to the
        // source loop (they collapsed through the opposite wall).
        guard offsetPoints.count == n else { return nil }
        var result = [SIMD2<Double>]()
        for i in 0..<n {
            let a = offsetPoints[i]
            let b = offsetPoints[(i + 1) % n]
            let sa = ccw[i]
            let sb = ccw[(i + 1) % n]
            if simd_dot(b - a, sb - sa) > 0 {
                result.append(a)
            }
        }
        guard result.count >= 3, Profile.signedArea(result) > 1e-12 else { return nil }
        return result
    }
}
