//
//  KernelOps.swift
//  openshape3d
//
//  Solid-modeling operations on top of Euclid: profile extrusion and booleans.
//

import Foundation
import simd
import Euclid

nonisolated extension KernelOps {
    /// A cylinder along an arbitrary axis, base at `baseCenter`, extending
    /// `height` along `axisDir`. Used to radially grow/shrink a body that is a
    /// plain cylinder (curved-face push/pull).
    static func cylinderAlongAxis(
        baseCenter: SIMD3<Double>,
        axisDir: SIMD3<Double>,
        radius: Double,
        height: Double,
        slices: Int = 48
    ) -> Euclid.Mesh {
        // Euclid cylinder is centred at the origin along +Y; shift base to y=0.
        let cyl = Euclid.Mesh.cylinder(radius: radius, height: height, slices: slices)
            .translated(by: Vector(0, height / 2, 0))
        let rotation = Rotation(simd_quatd(from: SIMD3(0, 1, 0), to: simd_normalize(axisDir)))
        let transform = Euclid.Transform(
            rotation: rotation,
            translation: Vector(baseCenter.x, baseCenter.y, baseCenter.z)
        )
        return cyl.transformed(by: transform)
    }
}

/// Axis of revolution: a 2D line (point + direction) in sketch-plane
/// coordinates.
nonisolated struct RevolveAxis: Equatable, Sendable {
    var point: SIMD2<Double>
    var direction: SIMD2<Double>
}

nonisolated enum KernelOps {

    /// Extrude a closed profile (with optional holes) along the plane normal.
    /// Positive distance pulls along +normal; negative pushes the other way.
    /// The profile face stays on the sketch plane. `symmetric` centers the
    /// solid on the plane instead: `distance` is the per-side value, so the
    /// total depth is 2× (Shapr3D's Symmetric sides).
    static func extrude(
        profile: Profile,
        holes: [Profile] = [],
        in plane: SketchPlane,
        distance: Double,
        symmetric: Bool = false
    ) -> Euclid.Mesh {
        let depth = abs(distance) * (symmetric ? 2 : 1)
        guard depth > 1e-6 else { return Euclid.Mesh([]) }

        var solid = extrudeLoop(profile, depth: depth)
        for hole in holes {
            // Cut holes with a slightly deeper tool so coplanar caps don't
            // leave slivers.
            let tool = extrudeLoop(hole, depth: depth * 1.002)
            solid = solid.subtracting(tool).makeWatertight()
        }

        // Euclid centers extrusion on the path plane: symmetric extrudes stay
        // centered; one-sided shifts so the base sits on the sketch plane.
        let offset = symmetric ? 0 : distance / 2
        solid = solid.translated(by: Vector(0, 0, offset))

        // Map plane-local (x, y, z=normal) into world space.
        let transform = planeToWorld(plane)
        return solid.transformed(by: transform)
    }

    /// Unsigned enclosed volume via the divergence theorem (mm³ for a closed
    /// outward-oriented mesh). Used to tell a REAL boolean overlap from mere
    /// coplanar sliver contact: two bodies sharing a flush wall can intersect
    /// into zero-volume sliver polygons, which must not count as touching.
    static func volume(of mesh: Euclid.Mesh) -> Double {
        var total = 0.0
        for polygon in mesh.polygons {
            let vertices = polygon.vertices
            guard vertices.count >= 3 else { continue }
            let pa = vertices[0].position
            let a = SIMD3(pa.x, pa.y, pa.z)
            for i in 1..<(vertices.count - 1) {
                let pb = vertices[i].position
                let pc = vertices[i + 1].position
                total += simd_dot(a, simd_cross(SIMD3(pb.x, pb.y, pb.z), SIMD3(pc.x, pc.y, pc.z))) / 6
            }
        }
        return abs(total)
    }

    /// A slightly overlapped extrude prism (union of all profile prisms) for use
    /// as a boolean CUT tool: the prism is padded ~0.001–0.002 past the flush
    /// extent so coplanar / flush cut faces merge cleanly instead of leaving
    /// hanging thin walls. Shared by the live extrude-cut (EditorViewModel) and
    /// the feature-graph replay so both produce identical cut geometry.
    static func overlapExtrudeTool(
        profile: Profile,
        holes: [Profile],
        extraProfiles: [(profile: Profile, holes: [Profile])],
        in plane: SketchPlane,
        distance: Double,
        symmetric: Bool
    ) -> Euclid.Mesh {
        let n = plane.normal
        let sign: Double = distance >= 0 ? 1 : -1
        func tool(_ profile: Profile, _ holes: [Profile]) -> Euclid.Mesh {
            if symmetric {
                // Symmetric solids straddle the plane: pad both sides.
                return extrude(
                    profile: profile, holes: holes, in: plane,
                    distance: distance + sign * 0.001, symmetric: true)
            }
            return extrude(
                profile: profile, holes: holes, in: plane,
                distance: distance + sign * 0.002
            ).translated(by: Vector(-n.x * sign * 0.001, -n.y * sign * 0.001, -n.z * sign * 0.001))
        }
        var solid = tool(profile, holes)
        for extra in extraProfiles {
            solid = solid.union(tool(extra.profile, extra.holes))
        }
        return solid
    }

    private static func extrudeLoop(_ profile: Profile, depth: Double) -> Euclid.Mesh {
        let path = closedPath(for: profile)
        return Euclid.Mesh.extrude(path, depth: depth)
    }

    /// Closed CCW path in plane-local XY.
    static func closedPath(for profile: Profile) -> Euclid.Path {
        var points = profile.loop.map { PathPoint.point($0.x, $0.y) }
        if let first = points.first {
            points.append(first)
        }
        return Euclid.Path(points)
    }

    /// Rotation+translation mapping plane-local coordinates (x→xAxis, y→yAxis,
    /// z→normal) into world space.
    static func planeToWorld(_ plane: SketchPlane) -> Euclid.Transform {
        let x = plane.xAxis
        let y = plane.yAxis
        let z = plane.normal
        // Build a quaternion from the orthonormal basis matrix.
        let matrix = simd_double3x3(
            SIMD3(x.x, x.y, x.z),
            SIMD3(y.x, y.y, y.z),
            SIMD3(z.x, z.y, z.z)
        )
        let quaternion = simd_quatd(matrix)
        return Euclid.Transform(
            rotation: Rotation(quaternion),
            translation: Vector(plane.origin.x, plane.origin.y, plane.origin.z)
        )
    }

    // MARK: - Revolve

    /// Revolve a closed profile (with optional holes) about a 2D axis line in
    /// the sketch plane. `angle` is degrees; >= 360 is a full revolution,
    /// partial angles sweep right-handed about the axis direction (viewed with
    /// the profile on the local +x side). Profiles crossing the axis are
    /// rejected with an empty mesh (Shapr3D errors there too).
    static func revolve(
        profile: Profile,
        holes: [Profile] = [],
        in plane: SketchPlane,
        axis: RevolveAxis,
        angle: Double = 360
    ) -> Euclid.Mesh {
        guard angle > 1e-6 else { return Euclid.Mesh([]) }
        let dirLength = simd_length(axis.direction)
        guard dirLength > 1e-12 else { return Euclid.Mesh([]) }
        let d = axis.direction / dirLength

        // Signed distance from the axis line, positive on the +perp side.
        var perp = SIMD2(d.y, -d.x)
        let tolerance = 1e-7
        let signed = profile.loop.map { simd_dot($0 - axis.point, perp) }
        let minS = signed.min() ?? 0
        let maxS = signed.max() ?? 0
        if minS < -tolerance, maxS > tolerance { return Euclid.Mesh([]) }
        // Degenerate: profile collapsed onto the axis.
        guard max(maxS, -minS) > tolerance else { return Euclid.Mesh([]) }
        if maxS <= tolerance {
            // Mirror so the profile lands on lathe's required +x side. Winding
            // flips too; Euclid's latheProfile normalizes it.
            perp = -perp
        }

        // Lathe space: x = radial distance, y = along the axis. Euclid lathe
        // revolves an XY path around the Y axis (x >= 0), with the point at
        // sweep angle a landing on (x·cos a, y, -x·sin a).
        func lathePath(_ p: Profile) -> Euclid.Path {
            var points = p.loop.map { point -> PathPoint in
                let r = point - axis.point
                return PathPoint.point(max(0, simd_dot(r, perp)), simd_dot(r, d))
            }
            if let first = points.first {
                points.append(first)
            }
            return Euclid.Path(points)
        }

        var solid = Euclid.Mesh.lathe(lathePath(profile), slices: 48)
        for hole in holes {
            // Hole loops are strictly inside the profile, so the revolved
            // tool surfaces never coincide with the solid's — no offset fudge.
            let tool = Euclid.Mesh.lathe(lathePath(hole), slices: 48)
            solid = solid.subtracting(tool).makeWatertight()
        }

        if angle < 360 - 1e-9 {
            solid = intersectWithWedge(solid, degrees: angle)
        }

        // Lathe space → plane-local (x, y, z=normal) → world.
        let e0 = SIMD3(perp.x, perp.y, 0.0)
        let e1 = SIMD3(d.x, d.y, 0.0)
        let matrix = simd_double3x3(e0, e1, simd_cross(e0, e1))
        let latheToPlane = Euclid.Transform(
            rotation: Rotation(simd_quatd(matrix)),
            translation: Vector(axis.point.x, axis.point.y, 0)
        )
        return solid
            .transformed(by: latheToPlane)
            .transformed(by: planeToWorld(plane))
    }

    /// Intersect a lathed solid (axis = +y through the origin) with a wedge
    /// spanning `degrees` of the sweep, starting at the +x half-plane and
    /// rotating toward -z (Euclid's lathe sweep direction).
    private static func intersectWithWedge(
        _ solid: Euclid.Mesh,
        degrees: Double
    ) -> Euclid.Mesh {
        let bounds = solid.bounds
        let radius = max(bounds.min.length, bounds.max.length) * 1.5
        guard radius > 0 else { return solid }

        // Half-space { dot(p, normal) <= 0 } as a large cube; normals stay in
        // the xz-plane so the y basis vector is always valid.
        func halfSpace(_ normal: SIMD3<Double>) -> Euclid.Mesh {
            let cube = Euclid.Mesh.cube(
                center: Vector(0, 0, -radius),
                size: Vector(radius * 4, radius * 4, radius * 2)
            )
            let e0 = SIMD3(normal.z, 0, -normal.x)
            let matrix = simd_double3x3(e0, SIMD3(0, 1, 0), normal)
            return cube.rotated(by: Rotation(simd_quatd(matrix)))
        }

        let theta = degrees * Double.pi / 180
        // Start plane keeps z <= 0; end plane is { z >= 0 } rotated by theta.
        let startKeep = SIMD3<Double>(0, 0, 1)
        let endKeep = SIMD3<Double>(-sin(theta), 0, -cos(theta))
        if theta <= Double.pi + 1e-9 {
            return solid
                .intersection(halfSpace(startKeep))
                .intersection(halfSpace(endKeep))
                .makeWatertight()
        }
        // Reflex wedge: subtract the complementary (< 180°) wedge instead.
        let complement = halfSpace(-startKeep).intersection(halfSpace(-endKeep))
        return solid.subtracting(complement).makeWatertight()
    }

    // MARK: - Mirror

    /// Reflect a mesh across a plane (spec §5.6): mirror positions and
    /// normals, flip winding so faces stay outward, and heal the result.
    static func mirror(mesh: Euclid.Mesh, across plane: SketchPlane) -> Euclid.Mesh {
        let n = simd_normalize(plane.normal)
        let origin = plane.origin

        func reflectPoint(_ v: Vector) -> Vector {
            let p = SIMD3(v.x, v.y, v.z)
            let r = p - 2 * simd_dot(p - origin, n) * n
            return Vector(r.x, r.y, r.z)
        }
        func reflectDirection(_ v: Vector) -> Vector {
            let d = SIMD3(v.x, v.y, v.z)
            let r = d - 2 * simd_dot(d, n) * n
            return Vector(r.x, r.y, r.z)
        }

        var polygons = [Euclid.Polygon]()
        polygons.reserveCapacity(mesh.polygons.count)
        for polygon in mesh.polygons {
            let vertices = polygon.vertices.reversed().map { vertex in
                Euclid.Vertex(reflectPoint(vertex.position), reflectDirection(vertex.normal))
            }
            if let mirrored = Euclid.Polygon(vertices) {
                polygons.append(mirrored)
            }
        }
        return Euclid.Mesh(polygons).makeWatertight()
    }

    // MARK: - Booleans

    static func boolean(
        _ kind: BooleanKind,
        target: Body,
        tool: Body,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> Euclid.Mesh {
        let a = target.euclidMesh().transformed(by: target.transform.euclid)
        let b = tool.euclidMesh().transformed(by: tool.transform.euclid)
        let result: Euclid.Mesh
        switch kind {
        case .union:
            result = a.union(b, isCancelled: isCancelled)
        case .subtract:
            result = a.subtracting(b, isCancelled: isCancelled)
        case .intersect:
            result = a.intersection(b, isCancelled: isCancelled)
        }
        // CSG can leave T-junction cracks along cut seams; heal them.
        return result.makeWatertight()
    }
}

// MARK: - Chamfer / Fillet (edge blends)

/// One straight edge (or one segment of a tessellated curved edge) to blend:
/// endpoints plus the outward normals of the two faces meeting there, all in
/// the mesh's coordinate space.
nonisolated struct BlendEdgeSpec: Sendable {
    var p0: SIMD3<Double>
    var p1: SIMD3<Double>
    var normalA: SIMD3<Double>
    var normalB: SIMD3<Double>
    /// True when the solid fills the wedge between the faces (an external
    /// edge). A convex blend REMOVES the corner; a concave one FILLS it, so
    /// this decides whether the tool is subtracted or unioned — see
    /// `blendEdges`.
    var isConvex: Bool

    init(p0: SIMD3<Double>, p1: SIMD3<Double>,
         normalA: SIMD3<Double>, normalB: SIMD3<Double>, isConvex: Bool = true) {
        self.p0 = p0
        self.p1 = p1
        self.normalA = normalA
        self.normalB = normalB
        self.isConvex = isConvex
    }

    /// Same edge walked the other way. A helper rather than a re-init at each
    /// site, so a field added later cannot be silently dropped while the chain
    /// is being oriented.
    func reversed() -> BlendEdgeSpec {
        BlendEdgeSpec(p0: p1, p1: p0, normalA: normalA, normalB: normalB,
                      isConvex: isConvex)
    }

    /// Same edge with the A and B faces exchanged.
    func swappingFaces() -> BlendEdgeSpec {
        BlendEdgeSpec(p0: p0, p1: p1, normalA: normalB, normalB: normalA,
                      isConvex: isConvex)
    }
}

nonisolated extension KernelOps {

    /// Chamfer a single convex straight edge by `setback` (the flat width on
    /// each face). Builds a triangular "corner wedge" prism — cross-section
    /// `(edgePoint, edgePoint + tangentA·setback, edgePoint + tangentB·setback)`
    /// lying in the plane perpendicular to the edge — extruded along the edge and
    /// subtracted from `mesh`. `normalA`/`normalB` are the OUTWARD normals of the
    /// two faces meeting at the edge; the mesh and edge share one coordinate
    /// space. Returns `mesh` unchanged for a degenerate/non-convex request.
    static func chamferEdge(
        mesh: Euclid.Mesh,
        p0: SIMD3<Double>,
        p1: SIMD3<Double>,
        normalA: SIMD3<Double>,
        normalB: SIMD3<Double>,
        setback: Double
    ) -> Euclid.Mesh {
        blendEdges(
            mesh: mesh,
            edges: [BlendEdgeSpec(p0: p0, p1: p1, normalA: normalA, normalB: normalB)],
            amount: setback, isFillet: false)
    }

    /// Fillet (round) a single convex straight edge to `radius`. Subtracts the
    /// corner wedge MINUS the fillet cylinder, so the cylinder's surface remains
    /// as the rounded blend. The setback equals `radius` for the tangent arc on
    /// a right-angle edge; general edges use the same setback (a v1 prismatic
    /// approximation). Returns `mesh` unchanged for a degenerate request.
    static func filletEdge(
        mesh: Euclid.Mesh,
        p0: SIMD3<Double>,
        p1: SIMD3<Double>,
        normalA: SIMD3<Double>,
        normalB: SIMD3<Double>,
        radius: Double
    ) -> Euclid.Mesh {
        blendEdges(
            mesh: mesh,
            edges: [BlendEdgeSpec(p0: p0, p1: p1, normalA: normalA, normalB: normalB)],
            amount: radius, isFillet: true)
    }

    /// Blend many edges at once. Edges are first grouped into tangent-continuous
    /// CHAINS (a tessellated cylinder rim arrives as ~48 short segments); each
    /// multi-segment chain becomes ONE swept tool — the blend cross-section
    /// mitred along the chain — subtracted in a single boolean. Per-segment
    /// corner wedges overlap near-tangentially on a curved rim, and unioning or
    /// serially subtracting dozens of them is both slow and crashes Euclid's
    /// healer; the swept tool avoids the pile-up entirely. Isolated straight
    /// edges keep the original corner-wedge path. Degenerate edges are skipped;
    /// returns `mesh` unchanged when nothing yields a tool.
    static func blendEdges(
        mesh: Euclid.Mesh,
        edges: [BlendEdgeSpec],
        amount: Double,
        isFillet: Bool
    ) -> Euclid.Mesh {
        guard amount > 1e-6 else { return mesh }
        var result = mesh
        // Convex and concave edges are chained SEPARATELY. They are never
        // continuations of one another even when they meet end to end and run
        // parallel — the tool for one is subtracted and the tool for the other
        // unioned — and a chain that mixed them would be swept as a single
        // solid and then applied one way for both.
        for convex in [true, false] {
            let group = edges.filter { $0.isConvex == convex }
            guard !group.isEmpty else { continue }
            for chain in chainedSpecs(group) {
                let tool: Euclid.Mesh?
                if chain.segments.count == 1 {
                    let s = chain.segments[0]
                    tool = cornerWedge(
                        p0: s.p0, p1: s.p1, normalA: s.normalA, normalB: s.normalB,
                        setback: amount, round: isFillet ? amount : nil,
                        isConvex: convex)
                } else {
                    // A blend bigger than the curve it sits on cannot be built,
                    // and handing the attempt to Euclid CRASHES rather than
                    // failing: the lofted tool self-intersects and the BSP
                    // clipper trips an assertion (SIGTRAP inside
                    // `Polygon.clip`). Measured on a Ø10 cylinder rim — 3 mm
                    // builds, 6 mm killed the process. Refuse first.
                    guard chainAllowsBlend(chain, amount: amount) else {
                        // Empty, not "unchanged": callers treat an empty mesh
                        // as failure and show the blend as invalid, which is
                        // what OCCT already does for the same request (it
                        // returns nil). Silently returning the untouched mesh
                        // would let the user commit a blend that did nothing.
                        return Euclid.Mesh([])
                    }
                    tool = sweptBlendTool(chain: chain, amount: amount, isFillet: isFillet)
                }
                guard let tool, !tool.polygons.isEmpty else { continue }
                // The whole point of the convex/concave split: a convex blend
                // takes the corner AWAY, a concave one FILLS it in.
                result = convex
                    ? result.subtracting(tool).makeWatertight()
                    : result.union(tool).makeWatertight()
            }
        }
        return result
    }

    // MARK: Chain assembly (multi-segment blends)

    /// An ordered head-to-tail run of blend segments. `closed` means the last
    /// segment's end meets the first segment's start (a full rim loop).
    private struct BlendChain {
        var segments: [BlendEdgeSpec]   // oriented: segments[i].p1 == segments[i+1].p0
        var closed: Bool
    }

    // NOTE — a rim blend is SLOW (~1.6 s for a Ø10 cylinder: 989 ms in
    // `subtracting`, 572 ms in `makeWatertight`, only 37 ms building the tool),
    // because the sweep emits a cross-section at every one of the body's 158
    // rim facets and the tool ends up five times the size of the body it cuts.
    //
    // Decimating those sections to what the CURVE needs was tried and WITHDRAWN
    // (2026-08-30). It did work — 1595 ms → 455 ms, error bounded to 2% of the
    // blend radius — but it moved the tool's apex line off the body surface,
    // and the near-tangential contact that produced tripped an assertion inside
    // Euclid's `makeWatertight` (`capPolygons` → `Polygon.init(unchecked:)`).
    // Measured against the identical radius sweep: decimated died on iteration
    // 17, undecimated was still going at 55. A faster blend that crashes is not
    // a faster blend.
    //
    // Safe directions, in preference order: give revolve/sweep/loft a B-rep so
    // this path stops carrying real work (the same fillet costs 9 ms in OCCT,
    // ~50× faster); move the preview off the main actor (S1); or coarsen only
    // the tool's ARC steps, which leaves the apex line and the flat contact
    // faces exactly where they are.

    /// Whether `amount` is small enough to blend along this chain.
    ///
    /// The blend tool reaches `amount / sin(halfAngle)` along the inward
    /// bisector at each vertex. Where the chain CURVES, that reach is bounded
    /// by the local radius of curvature: past it the cross-sections cross the
    /// centre of curvature, the swept solid folds through itself, and the CSG
    /// that follows dies on an assertion instead of returning a bad answer.
    ///
    /// Curvature is measured as the circumradius of each three consecutive
    /// vertices, so a straight run reports no limit (collinear points have an
    /// infinite circumradius) and only genuinely curved chains are restricted.
    private static func chainAllowsBlend(_ chain: BlendChain, amount: Double) -> Bool {
        let segs = chain.segments
        guard segs.count >= 2, amount > 0 else { return true }

        // Chain vertices, in order.
        var points = segs.map(\.p0)
        if let last = segs.last { points.append(last.p1) }

        for i in 1..<(points.count - 1) {
            let a = points[i - 1], b = points[i], c = points[i + 1]
            let ab = simd_length(b - a), bc = simd_length(c - b), ca = simd_length(a - c)
            guard ab > 1e-12, bc > 1e-12, ca > 1e-12 else { continue }
            // Circumradius = abc / 4·area; area via the cross product.
            let area = simd_length(simd_cross(b - a, c - a)) / 2
            guard area > 1e-12 else { continue }   // collinear: no curvature limit
            let circumradius = (ab * bc * ca) / (4 * area)

            // Half the angle between the two faces at this vertex, from the
            // same construction the tool uses.
            let nA = simd_normalize(segs[i - 1].normalA)
            let nB = simd_normalize(segs[i - 1].normalB)
            let cosFull = max(-0.999, min(0.999, simd_dot(nA, nB)))
            let sinHalf = max(sin((Double.pi - acos(cosFull)) / 2), 1e-3)

            guard amount / sinHalf < circumradius else { return false }
        }
        return true
    }

    /// Group loose edge specs into tangent-continuous chains, mirroring
    /// `EdgeTopology.smoothChain`'s rules (shared endpoint, direction and
    /// face-normal turns under ~35°), then orient each chain head-to-tail with
    /// the A/B normal assignment kept consistent from segment to segment (the
    /// sweep needs "face A" to mean the SAME physical surface all along).
    private static func chainedSpecs(_ specs: [BlendEdgeSpec]) -> [BlendChain] {
        guard !specs.isEmpty else { return [] }
        let cosTurn = cos(35.0 * Double.pi / 180)

        struct QKey: Hashable { let x, y, z: Int64 }
        func key(_ p: SIMD3<Double>) -> QKey {
            let s = 1e5
            return QKey(x: MeshQuantize.key64(p.x, inverseQuantum: s),
                        y: MeshQuantize.key64(p.y, inverseQuantum: s),
                        z: MeshQuantize.key64(p.z, inverseQuantum: s))
        }
        func dir(_ s: BlendEdgeSpec) -> SIMD3<Double> {
            let d = s.p1 - s.p0
            let l = simd_length(d)
            return l > 1e-12 ? d / l : SIMD3(0, 0, 1)
        }
        func continues(_ a: BlendEdgeSpec, _ b: BlendEdgeSpec) -> Bool {
            guard abs(simd_dot(dir(a), dir(b))) >= cosTurn else { return false }
            let direct = min(simd_dot(a.normalA, b.normalA), simd_dot(a.normalB, b.normalB))
            let swapped = min(simd_dot(a.normalA, b.normalB), simd_dot(a.normalB, b.normalA))
            return max(direct, swapped) >= cosTurn
        }

        var byEndpoint = [QKey: [Int]]()
        for (i, s) in specs.enumerated() {
            byEndpoint[key(s.p0), default: []].append(i)
            byEndpoint[key(s.p1), default: []].append(i)
        }

        var assigned = [Bool](repeating: false, count: specs.count)
        var chains = [BlendChain]()

        for start in specs.indices where !assigned[start] {
            // Collect the connected continuity component.
            var component = [start]
            assigned[start] = true
            var frontier = [start]
            while let i = frontier.popLast() {
                for k in [key(specs[i].p0), key(specs[i].p1)] {
                    for j in byEndpoint[k] ?? [] where !assigned[j] {
                        if continues(specs[i], specs[j]) {
                            assigned[j] = true
                            component.append(j)
                            frontier.append(j)
                        }
                    }
                }
            }
            if component.count == 1 {
                chains.append(BlendChain(segments: [specs[start]], closed: false))
                continue
            }

            // Order the component head-to-tail. Walk neighbor-to-neighbor from
            // an endpoint touched by only one member (open chain) or anywhere
            // (loop), flipping segments and their A/B normals as needed.
            let members = Set(component)
            var degree = [QKey: Int]()
            for i in component {
                degree[key(specs[i].p0), default: 0] += 1
                degree[key(specs[i].p1), default: 0] += 1
            }
            let first = component.first {
                degree[key(specs[$0].p0)] == 1 || degree[key(specs[$0].p1)] == 1
            } ?? component[0]
            var used: Set<Int> = [first]
            var seg = specs[first]
            if degree[key(seg.p1)] == 1 {   // orient so the open end trails
                seg = seg.reversed()
            }
            var ordered = [seg]
            while ordered.count < component.count {
                let tailKey = key(ordered[ordered.count - 1].p1)
                guard let nextIndex = (byEndpoint[tailKey] ?? []).first(where: {
                    members.contains($0) && !used.contains($0)
                }) else { break }
                used.insert(nextIndex)
                var next = specs[nextIndex]
                if key(next.p0) != tailKey {
                    next = next.reversed()
                }
                // Keep the A/B faces consistent along the sweep.
                let prev = ordered[ordered.count - 1]
                let direct = simd_dot(prev.normalA, next.normalA)
                    + simd_dot(prev.normalB, next.normalB)
                let swapped = simd_dot(prev.normalA, next.normalB)
                    + simd_dot(prev.normalB, next.normalA)
                if swapped > direct {
                    next = next.swappingFaces()
                }
                ordered.append(next)
            }
            let closed = ordered.count > 2
                && key(ordered[ordered.count - 1].p1) == key(ordered[0].p0)
            chains.append(BlendChain(segments: ordered, closed: closed))
        }
        return chains
    }

    // MARK: Swept blend tool

    /// The removal solid for a multi-segment chain: the corner cross-section
    /// (triangle for chamfer; corner-minus-arc for fillet) placed at every chain
    /// vertex on the mitred frame (adjacent segment frames averaged), lofted
    /// segment-by-segment, capped at open ends. One well-formed solid replaces
    /// dozens of overlapping per-segment wedges.
    private static func sweptBlendTool(
        chain: BlendChain,
        amount: Double,
        isFillet: Bool
    ) -> Euclid.Mesh? {
        let segs = chain.segments
        guard segs.count >= 2 else { return nil }

        // Per-segment frames: edge direction + into-face tangents (same
        // construction as cornerWedge).
        struct Frame { var e, tA, tB: SIMD3<Double> }
        var frames = [Frame]()
        for s in segs {
            let axis = s.p1 - s.p0
            let len = simd_length(axis)
            guard len > 1e-9 else { return nil }
            let e = axis / len
            let nA = simd_normalize(s.normalA), nB = simd_normalize(s.normalB)
            var tA = simd_cross(nA, e), tB = simd_cross(nB, e)
            let lA = simd_length(tA), lB = simd_length(tB)
            guard lA > 1e-6, lB > 1e-6 else { return nil }
            tA /= lA; tB /= lB
            // Sign flips with convexity — see `cornerWedge`. The chain is all
            // one or all the other, so `segs[0]` speaks for it.
            let want: Double = s.isConvex ? -1 : 1
            if simd_dot(tA, nB) * want < 0 { tA = -tA }
            if simd_dot(tB, nA) * want < 0 { tB = -tB }
            frames.append(Frame(e: e, tA: tA, tB: tB))
        }

        // Cross-section at one vertex from a (possibly averaged) frame. Points
        // run apex → faceA setback → (arc samples) → faceB setback; every
        // section must emit the SAME count for the loft.
        let arcSteps = 8
        func section(at apex: SIMD3<Double>, frame: Frame) -> [SIMD3<Double>]? {
            let sa = apex + frame.tA * amount
            let sb = apex + frame.tB * amount
            var bis = frame.tA + frame.tB
            let bl = simd_length(bis)
            guard bl > 1e-6 else { return nil }
            bis /= bl
            // Nudge the apex back along −bis so the tool's flat faces sit just
            // proud of the body's faces, making every contact transversal
            // rather than exactly coplanar — the case Euclid's CSG healer is
            // flakiest about. One formula serves both senses: on a convex edge
            // −bis leaves the solid (the sliver is outside it, so the removed
            // region is unchanged), and on a concave one it enters the solid,
            // which is the overlap a union wants anyway.
            let apexOut = apex - bis * max(amount * 0.02, 1e-4)
            guard isFillet else { return [apexOut, sa, sb] }
            // Center on the inward bisector at r/sin(h), h = half the angle
            // between the face tangents — the inscribed circle tangent to both
            // faces (cos 2h = tA·tB; same math as cornerWedge via normals).
            let cosT = max(-0.999, min(0.999, simd_dot(frame.tA, frame.tB)))
            let sinHalf = max(((1 - cosT) / 2).squareRoot(), 1e-3)
            let center = apex + bis * (amount / sinHalf)
            var u = sa - center
            let w = sb - center
            let cross = simd_cross(u, w)
            let crossLen = simd_length(cross)
            guard crossLen > 1e-12 else { return nil }
            let axis = cross / crossLen
            let angle = atan2(crossLen, simd_dot(u, w))
            var points = [apexOut, sa]
            let rot = simd_quatd(angle: angle / Double(arcSteps), axis: axis)
            for _ in 1..<arcSteps {
                u = rot.act(u)
                points.append(center + u)
            }
            points.append(sb)
            return points
        }

        // Mitred vertex frames: average the neighbor segments' frames. Open
        // ends extend past the chain by the usual boolean-overlap epsilon.
        func averaged(_ a: Frame, _ b: Frame) -> Frame {
            Frame(e: simd_normalize(a.e + b.e),
                  tA: simd_normalize(a.tA + b.tA),
                  tB: simd_normalize(a.tB + b.tB))
        }
        var sections = [[SIMD3<Double>]]()
        if chain.closed {
            for i in segs.indices {
                let prev = (i + segs.count - 1) % segs.count
                guard let s = section(at: segs[i].p0,
                                      frame: averaged(frames[prev], frames[i]))
                else { return nil }
                sections.append(s)
            }
        } else {
            let lenFirst = simd_length(segs[0].p1 - segs[0].p0)
            let lenLast = simd_length(segs[segs.count - 1].p1 - segs[segs.count - 1].p0)
            let epsStart = max(lenFirst * 0.02, 1e-3)
            let epsEnd = max(lenLast * 0.02, 1e-3)
            guard let head = section(
                at: segs[0].p0 - frames[0].e * epsStart, frame: frames[0])
            else { return nil }
            sections.append(head)
            for i in 1..<segs.count {
                guard let s = section(at: segs[i].p0,
                                      frame: averaged(frames[i - 1], frames[i]))
                else { return nil }
                sections.append(s)
            }
            guard let tail = section(
                at: segs[segs.count - 1].p1 + frames[segs.count - 1].e * epsEnd,
                frame: frames[segs.count - 1])
            else { return nil }
            sections.append(tail)
        }

        // Loft: lateral triangles between consecutive sections (wrapping the
        // section ring), end caps when open. Windings are made consistent by
        // sign-checking the enclosed volume below.
        var triangles = [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]()
        let ringCount = chain.closed ? sections.count : sections.count - 1
        let pointCount = sections[0].count
        for i in 0..<ringCount {
            let a = sections[i], b = sections[(i + 1) % sections.count]
            for j in 0..<pointCount {
                let k = (j + 1) % pointCount
                triangles.append((a[j], a[k], b[k]))
                triangles.append((a[j], b[k], b[j]))
            }
        }
        if !chain.closed {
            let head = sections[0], tail = sections[sections.count - 1]
            for j in 1..<(pointCount - 1) {
                triangles.append((head[0], head[j + 1], head[j]))
                triangles.append((tail[0], tail[j], tail[j + 1]))
            }
        }

        var signedVolume = 0.0
        for (a, b, c) in triangles {
            signedVolume += simd_dot(a, simd_cross(b, c)) / 6
        }
        let flip = signedVolume < 0

        var polygons = [Euclid.Polygon]()
        polygons.reserveCapacity(triangles.count)
        for (a, b, c) in triangles {
            let (v0, v1, v2) = flip ? (a, c, b) : (a, b, c)
            let n = simd_cross(v1 - v0, v2 - v0)
            let nl = simd_length(n)
            guard nl > 1e-14 else { continue }   // mitring can collapse a sliver
            let normal = Vector(n.x / nl, n.y / nl, n.z / nl)
            if let poly = Euclid.Polygon([
                Euclid.Vertex(Vector(v0.x, v0.y, v0.z), normal),
                Euclid.Vertex(Vector(v1.x, v1.y, v1.z), normal),
                Euclid.Vertex(Vector(v2.x, v2.y, v2.z), normal),
            ]) {
                polygons.append(poly)
            }
        }
        guard !polygons.isEmpty else { return nil }
        return Euclid.Mesh(polygons)
    }

    /// The corner-removal tool shared by chamfer and fillet. Without `round` it
    /// is the solid triangular wedge (chamfer). With `round`, the fillet cylinder
    /// (radius = round, axis = the edge, tangent to both faces) is subtracted
    /// from the wedge so the rounded surface survives the body subtraction.
    private static func cornerWedge(
        p0: SIMD3<Double>,
        p1: SIMD3<Double>,
        normalA: SIMD3<Double>,
        normalB: SIMD3<Double>,
        setback: Double,
        round: Double?,
        isConvex: Bool = true
    ) -> Euclid.Mesh? {
        guard setback > 1e-6 else { return nil }
        let axis = p1 - p0
        let edgeLen = simd_length(axis)
        guard edgeLen > 1e-6 else { return nil }
        let e = axis / edgeLen

        let nA = simd_normalize(normalA)
        let nB = simd_normalize(normalB)

        // Tangents into each face, perpendicular to the edge, oriented so each
        // points INTO its face and away from the other face.
        //
        // The SIGN of that test flips with convexity, and this is the whole
        // geometric difference between the two cases. On a convex edge the
        // faces fall away from each other, so "into face A" points away from
        // B's outward normal; on a concave edge they close toward each other
        // and it points along it.
        //
        // Getting it wrong does not fail loudly. Measured, by running the
        // concave tests against the convex-only rule: the wedge is built on
        // the far side of the edge, which for a concave edge puts it entirely
        // INSIDE the solid, so the union is a silent no-op — the blend simply
        // does nothing and the volume does not move.
        var tA = simd_cross(nA, e)
        var tB = simd_cross(nB, e)
        let lA = simd_length(tA), lB = simd_length(tB)
        guard lA > 1e-6, lB > 1e-6 else { return nil }
        tA /= lA; tB /= lB
        let want: Double = isConvex ? -1 : 1
        if simd_dot(tA, nB) * want < 0 { tA = -tA }
        if simd_dot(tB, nA) * want < 0 { tB = -tB }

        let apex = (p0 + p1) / 2
        let sa = apex + tA * setback
        let sb = apex + tB * setback
        // A subtracted tool overshoots both ends so the cut runs clean past the
        // edge. A UNIONED one must not: the overshoot would be material added
        // beyond where the edge stops, left standing proud of the end faces as
        // a pair of small tabs.
        let overlap = max(edgeLen * 0.02, 1e-3)
        let depth = isConvex ? edgeLen + 2 * overlap : edgeLen

        // Cross-section in the plane perpendicular to the edge. A chamfer removes
        // the triangle (apex, sa, sb) — the sharp corner behind the flat. A
        // fillet removes the corner PARALLELOGRAM (apex, sa, far, sb) out to the
        // tangent points and then keeps the fillet cylinder, so the rounded
        // surface survives. Euclid centers the extrusion on the path plane
        // (normal = ±edge); depth = edgeLen + 2·overlap spans the edge cleanly.
        func extrudeSection(_ pts: [SIMD3<Double>]) -> Euclid.Mesh {
            var path = pts.map { PathPoint.point($0.x, $0.y, $0.z) }
            if let first = path.first { path.append(first) }
            return Euclid.Mesh.extrude(Euclid.Path(path), depth: depth)
        }

        guard let radius = round else {
            let wedge = extrudeSection([apex, sa, sb])
            return wedge.polygons.isEmpty ? nil : wedge
        }

        // Fillet: parallelogram corner minus the tangent cylinder.
        let far = apex + tA * setback + tB * setback
        var corner = extrudeSection([apex, sa, far, sb])
        if corner.polygons.isEmpty { return nil }

        // Cylinder tangent to both faces, on the inward bisector at distance
        // radius / sin(halfAngle) from the apex. cos(2·halfAngle) = nA·nB.
        let cosFull = max(-0.999, min(0.999, simd_dot(nA, nB)))
        let halfAngle = (Double.pi - acos(cosFull)) / 2
        let sinHalf = max(sin(halfAngle), 1e-3)
        var bis = tA + tB
        let bl = simd_length(bis)
        guard bl > 1e-6 else { return nil }
        bis /= bl
        let center = apex + bis * (radius / sinHalf)
        // Center the cylinder along the edge to match Euclid's centered
        // extrusion of the corner parallelogram (base sits depth/2 back).
        let cyl = cylinderAlongAxis(
            baseCenter: center - e * (depth / 2), axisDir: e, radius: radius, height: depth
        )
        corner = corner.subtracting(cyl).makeWatertight()
        return corner.polygons.isEmpty ? nil : corner
    }
}

// MARK: - Planar face push/pull (feature-graph replay)

nonisolated extension KernelOps {

    /// Push/pull a body's planar `face` by `distance` along the face normal — the
    /// pure-geometry core of `EditorViewModel.faceModifiedMesh`'s planar branch,
    /// extracted so the feature graph can replay it.
    ///
    /// `mesh` and `face` must live in the SAME coordinate space (the face's
    /// `origin`/`basisX`/`basisY`/`outline` were measured from `mesh`); unlike
    /// the live tool there is no body transform to bake in.
    ///
    /// - `distance > 0` (outward pull): unions a flush prism extruded from the
    ///   face outline (with holes) by `distance` along the normal.
    /// - `distance < 0` (inward push): truncates the body with the half-space at
    ///   the face plane moved `|distance|` inward, keeping the interior (−normal)
    ///   side. The half-space cut is coincident-wall safe — it leaves no hanging
    ///   walls the way a same-cross-section boolean subtract would.
    /// - `distance == 0`: returns `mesh` unchanged.
    static func pushPullPlanarFace(
        mesh: Euclid.Mesh,
        face: FaceTopology.PlanarFace,
        distance: Double
    ) -> Euclid.Mesh {
        guard distance != 0 else { return mesh }

        // Reconstruct the sketch plane + profile the live face push/pull builds
        // from the picked planar face.
        let plane = SketchPlane(
            origin: face.origin, xAxis: face.basisX, yAxis: face.basisY
        )
        let profile = Profile(
            loop: face.outline, kind: .polygonal, sourceEntityIDs: []
        )
        let holes = face.holes.map {
            Profile(loop: $0, kind: .polygonal, sourceEntityIDs: [])
        }
        // plane.normal == basisX × basisY == the face normal (mirrors the
        // viewmodel, which reads context.plane.normal).
        let n = plane.normal

        if distance < 0 {
            // Move the face plane into the body; keep the interior (−n) side.
            let cutOrigin = plane.origin + n * distance
            let cutPlane = SketchPlane(
                origin: cutOrigin, xAxis: plane.xAxis, yAxis: plane.yAxis
            )
            return SplitKit.split(mesh: mesh, byPlane: cutPlane).other
        } else {
            let prism = KernelOps.extrude(
                profile: profile, holes: holes, in: plane, distance: distance
            )
            guard !prism.polygons.isEmpty else { return mesh }
            return mesh.union(prism).makeWatertight()
        }
    }

    /// Move a planar face by an arbitrary world-space `delta`, deforming the
    /// solid — the general Shapr3D "Move" on a face. Every mesh vertex that
    /// lies ON the face (on its plane and inside its outline, holes excluded)
    /// is translated by `delta`; the side walls that share those vertices skew
    /// to follow, so moving a box's top face laterally turns it into a
    /// parallelepiped, while moving it along the normal thickens it (matching
    /// `pushPullPlanarFace`'s positive branch on its own axis).
    ///
    /// This is a topology-preserving vertex edit: it works for prismatic solids
    /// where the moved face's boundary vertices are shared with the adjacent
    /// walls (the common case). It does not add or remove faces.
    /// Which mesh vertices a face deform moves, resolved ONCE.
    ///
    /// The test — on the face's plane, inside its outline, outside its holes —
    /// depends only on the mesh and the face, never on how far the face is
    /// being dragged. A live drag holds both fixed for its whole duration, so
    /// recomputing the partition every frame was pure re-derivation: measured
    /// at 231 ms/frame on a filleted cylinder (13k polygons, ~4 fps) against
    /// 0.28 ms on a box. Build one of these at touch-down and hand it to the
    /// per-frame call instead.
    nonisolated struct FaceVertexMask {
        /// Kept so a mask handed a mesh it does not describe can rebuild
        /// itself rather than silently deform the wrong vertices.
        let face: FaceTopology.PlanarFace
        /// The face's centroid in world space — scale deforms about it.
        fileprivate let center: Vector
        /// Per polygon, per vertex: is this vertex part of the face?
        fileprivate let flags: [[Bool]]

        /// Does the deform move this polygon's vertex? (Test-facing: lets the
        /// render-buffer classifier be checked against this one.)
        func moves(polygon: Int, vertex: Int) -> Bool {
            guard polygon < flags.count, vertex < flags[polygon].count else { return false }
            return flags[polygon][vertex]
        }

        fileprivate func describes(_ mesh: Euclid.Mesh) -> Bool {
            guard flags.count == mesh.polygons.count else { return false }
            for (i, polygon) in mesh.polygons.enumerated()
            where flags[i].count != polygon.vertices.count {
                return false
            }
            return true
        }
    }

    /// Classify `mesh`'s vertices against `face`. A vertex belongs to the face
    /// if it sits on the face's plane and its projection lies within the
    /// outline (and outside every hole). The boundary is inclusive — the
    /// face's own corner vertices lie exactly on the outline, and so do the
    /// top rim vertices of the adjoining walls, so all copies of a shared
    /// corner move together and the mesh stays welded.
    static func faceVertexMask(
        mesh: Euclid.Mesh,
        face: FaceTopology.PlanarFace
    ) -> FaceVertexMask {
        let onFace = faceContainment(face)
        return FaceVertexMask(
            face: face,
            center: faceCentroid(face),
            flags: mesh.polygons.map { polygon in
                polygon.vertices.map { v in
                    onFace(SIMD3(v.position.x, v.position.y, v.position.z))
                }
            })
    }

    /// The same classification over RENDER buffers: which vertex indices of
    /// `positions` (world space) belong to `face`.
    ///
    /// This is what a live drag PREVIEW wants. Deforming through Euclid means
    /// rebuilding every `Euclid.Polygon` (153 ms on a 13k-polygon body),
    /// welding it watertight (84 ms) and copying it again to re-pivot (84 ms)
    /// — none of which a preview needs, since the commit re-runs the real
    /// deform anyway. Translating the picked vertices of a flat position
    /// array instead costs 0.5 ms, so the drag stays interactive on blended
    /// geometry.
    static func faceVertexIndices(
        in positions: [SIMD3<Float>],
        face: FaceTopology.PlanarFace
    ) -> [Int] {
        let onFace = faceContainment(face)
        return positions.indices.filter { i in
            let p = positions[i]
            return onFace(SIMD3(Double(p.x), Double(p.y), Double(p.z)))
        }
    }

    /// The face's centroid in world space — scale/rotate deform about it.
    static func faceCentroid(_ face: FaceTopology.PlanarFace) -> Vector {
        let plane = SketchPlane(
            origin: face.origin, xAxis: face.basisX, yAxis: face.basisY
        )
        var c2 = SIMD2<Double>.zero
        for p in face.outline { c2 += p }
        c2 /= Double(max(face.outline.count, 1))
        let cw = plane.toWorld(c2)
        return Vector(cw.x, cw.y, cw.z)
    }

    /// "Does this world point belong to the face?" — on the face's plane,
    /// inside its outline, outside its holes. One definition, shared by the
    /// Euclid and render-buffer classifiers so a preview can never disagree
    /// with the commit about which vertices move.
    private static func faceContainment(
        _ face: FaceTopology.PlanarFace
    ) -> (SIMD3<Double>) -> Bool {
        let plane = SketchPlane(
            origin: face.origin, xAxis: face.basisX, yAxis: face.basisY
        )
        let normal = simd_normalize(plane.normal)
        return { w in
            guard abs(simd_dot(w - face.origin, normal)) <= Self.moveFacePlaneTolerance
            else { return false }
            let local = plane.toLocal(w)
            guard Self.pointInLoopInclusive(local, face.outline) else { return false }
            for hole in face.holes where Self.pointStrictlyInLoop(local, hole) {
                return false
            }
            return true
        }
    }

    static func moveFace(
        mesh: Euclid.Mesh,
        face: FaceTopology.PlanarFace,
        delta: SIMD3<Double>
    ) -> Euclid.Mesh {
        applyMove(mesh: mesh, mask: faceVertexMask(mesh: mesh, face: face), delta: delta)
    }

    /// `moveFace` with the classification already done — the per-frame call in
    /// a face drag. A mask from a different mesh is rebuilt rather than
    /// misapplied, so this is never less correct than the `face:` overload.
    static func moveFace(
        mesh: Euclid.Mesh,
        mask: FaceVertexMask,
        delta: SIMD3<Double>
    ) -> Euclid.Mesh {
        applyMove(mesh: mesh,
                  mask: mask.describes(mesh)
                      ? mask : faceVertexMask(mesh: mesh, face: mask.face),
                  delta: delta)
    }

    private static func applyMove(
        mesh: Euclid.Mesh,
        mask: FaceVertexMask,
        delta: SIMD3<Double>
    ) -> Euclid.Mesh {
        guard simd_length(delta) > 1e-9 else { return mesh }
        let d = Vector(delta.x, delta.y, delta.z)

        var polygons = [Euclid.Polygon]()
        polygons.reserveCapacity(mesh.polygons.count)
        for (i, polygon) in mesh.polygons.enumerated() {
            let flags = mask.flags[i]
            let vertices = polygon.vertices.enumerated().map { j, vertex -> Euclid.Vertex in
                flags[j] ? Euclid.Vertex(vertex.position + d, vertex.normal) : vertex
            }
            // A lateral move keeps each face planar (rigid translate of its
            // moved vertices); still guard degenerate polygons defensively.
            if let moved = Euclid.Polygon(vertices) {
                polygons.append(moved)
            }
        }
        guard !polygons.isEmpty else { return mesh }
        return Euclid.Mesh(polygons).makeWatertight()
    }

    /// Uniformly scale a planar face about its own centre, deforming the solid —
    /// the Shapr3D "Scale" on a face. Every mesh vertex ON the face is scaled by
    /// `factor` about the face centroid; because the centroid and those vertices
    /// all lie in the face plane, the scaled vertices stay in-plane, so the face
    /// grows/shrinks in place and the side walls taper to follow (a box top
    /// scaled < 1 becomes a frustum, > 1 a flared shape). Topology-preserving,
    /// like `moveFace`.
    static func scaleFace(
        mesh: Euclid.Mesh,
        face: FaceTopology.PlanarFace,
        factor: Double
    ) -> Euclid.Mesh {
        applyScale(mesh: mesh, mask: faceVertexMask(mesh: mesh, face: face), factor: factor)
    }

    /// `scaleFace` with the classification already done — the per-frame call in
    /// a face-scale drag. See `FaceVertexMask`.
    static func scaleFace(
        mesh: Euclid.Mesh,
        mask: FaceVertexMask,
        factor: Double
    ) -> Euclid.Mesh {
        applyScale(mesh: mesh,
                   mask: mask.describes(mesh)
                       ? mask : faceVertexMask(mesh: mesh, face: mask.face),
                   factor: factor)
    }

    private static func applyScale(
        mesh: Euclid.Mesh,
        mask: FaceVertexMask,
        factor: Double
    ) -> Euclid.Mesh {
        guard factor > 1e-6, abs(factor - 1) > 1e-9 else { return mesh }
        let center = mask.center

        var polygons = [Euclid.Polygon]()
        polygons.reserveCapacity(mesh.polygons.count)
        for (i, polygon) in mesh.polygons.enumerated() {
            let flags = mask.flags[i]
            let vertices = polygon.vertices.enumerated().map { j, vertex -> Euclid.Vertex in
                guard flags[j] else { return vertex }
                let scaled = center + (vertex.position - center) * factor
                return Euclid.Vertex(scaled, vertex.normal)
            }
            if let np = Euclid.Polygon(vertices) { polygons.append(np) }
        }
        guard !polygons.isEmpty else { return mesh }
        return Euclid.Mesh(polygons).makeWatertight()
    }

    /// Rotate a planar face about an axis line through its own centre, deforming
    /// the solid — the Shapr3D "Rotate" on a face. Every mesh vertex ON the face
    /// is rotated by `angle` (radians) about the world line through the face
    /// centroid along unit `axis`; the side walls that share those vertices follow.
    ///
    /// Two behaviours, picked from the axis:
    ///  • an IN-PLANE axis TILTS the solid — the walls stay planar, giving a clean
    ///    wedge, so the face's vertices simply rotate and nothing is subdivided;
    ///  • the face's own NORMAL axis TWISTS it — the face's plane maps to itself,
    ///    so the walls MUST become ruled screw surfaces. The walls are subdivided
    ///    and each sub-vertex rotates proportionally to how far it lies onto the
    ///    face, making every cross-section the original rotated by its share of
    ///    the angle: a real twisted prism rather than two big triangular facets.
    ///
    /// The mesh is triangulated first so every polygon stays planar under an
    /// arbitrary per-vertex rotation, keeping the result watertight.
    static func rotateFace(
        mesh: Euclid.Mesh,
        face: FaceTopology.PlanarFace,
        angle: Double,
        axis: SIMD3<Double>
    ) -> Euclid.Mesh {
        let axisLen = simd_length(axis)
        guard abs(angle) > 1e-9, axisLen > 1e-9 else { return mesh }
        let a = axis / axisLen
        let plane = SketchPlane(
            origin: face.origin, xAxis: face.basisX, yAxis: face.basisY
        )
        let normal = simd_normalize(plane.normal)

        // Rotate about the face centroid (average of its outline), in world.
        var c2 = SIMD2<Double>.zero
        for p in face.outline { c2 += p }
        c2 /= Double(max(face.outline.count, 1))
        let cw = plane.toWorld(c2)
        let center = Vector(cw.x, cw.y, cw.z)

        let av = Vector(a.x, a.y, a.z)
        // Rodrigues rotation of `v` about unit `av` by an arbitrary angle — the
        // angle varies per vertex so a twist can screw progressively (below).
        func rotate(_ v: Vector, by ang: Double) -> Vector {
            let c = cos(ang), s = sin(ang)
            return v * c + av.cross(v) * s + av * (v.dot(av) * (1 - c))
        }

        func onFace(_ position: Vector) -> Bool {
            let w = SIMD3<Double>(position.x, position.y, position.z)
            guard abs(simd_dot(w - face.origin, normal)) <= Self.moveFacePlaneTolerance
            else { return false }
            let local = plane.toLocal(w)
            guard Self.pointInLoopInclusive(local, face.outline) else { return false }
            for hole in face.holes where Self.pointStrictlyInLoop(local, hole) {
                return false
            }
            return true
        }

        // Rotating a face about its OWN NORMAL is a TWIST: the face's plane maps to
        // itself, so the side walls have to become ruled (screw) surfaces. Left as
        // one quad per wall that reads as two huge triangular facets, not a twist —
        // so subdivide the deformed triangles and rotate each sub-vertex by
        // angle × t, where t is how far it sits ONTO the face (0 at the far end,
        // 1 on the face). Every cross-section is then the original rotated
        // proportionally: a real twisted prism.
        //
        // A rotation about an IN-PLANE axis is a TILT, where the walls stay planar
        // and a clean wedge is correct — that path uses n = 1 (no subdivision),
        // which reduces exactly to "rotate the on-face vertices, leave the rest".
        let isTwist = abs(simd_dot(a, normal)) > 0.98
        let degrees = abs(angle) * 180 / .pi
        var n = isTwist ? min(max(Int((degrees / 8).rounded(.up)), 3), 12) : 1
        // The grid costs n² per deformed triangle, and the Rotate tool stays live
        // so the same face gets twisted again and again on an ever-denser mesh.
        // Trade resolution for a bounded result rather than letting it compound:
        // the first twist of a simple body gets the full grid, a repeat twist of
        // an already-dense one gets a coarser (eventually n = 1) rotation.
        let budget = 40_000
        while n > 1, mesh.polygons.count * n * n > budget { n -= 1 }

        var polygons = [Euclid.Polygon]()
        for polygon in EuclidBridge.triangles(of: mesh) {
            let verts = polygon.vertices
            // Untouched triangles keep their original (possibly smooth) normals so
            // curved faces elsewhere on the body aren't flattened.
            guard verts.count == 3, verts.contains(where: { onFace($0.position) }) else {
                polygons.append(polygon)
                continue
            }
            let p = verts.map(\.position)
            let f = verts.map { onFace($0.position) ? 1.0 : 0.0 }

            // Each emitted triangle gets ONE flat normal recomputed from its moved
            // geometry. Carrying the old per-vertex normals here mis-lights the
            // walls — a wall's rim vertex would wear the rotated FACE normal
            // instead of the wall's — and reads as a dark "hole"; a flat normal
            // always matches the winding. `smoothingNormals` below then blends
            // them back across the fine wall so it shades as one smooth surface.
            func emit(_ x: Vector, _ y: Vector, _ z: Vector) {
                let nrm = Self.newellNormal([x, y, z])
                if let tri = Euclid.Polygon(
                    [Euclid.Vertex(x, nrm), Euclid.Vertex(y, nrm), Euclid.Vertex(z, nrm)]) {
                    polygons.append(tri)
                }
            }

            // Barycentric grid over the whole triangle, EVERY deformed triangle
            // subdivided the same way. Two properties matter and both come from
            // that uniformity:
            //  • a sub-vertex depends only on the shared corner positions/flags,
            //    so two triangles meeting on an edge generate identical points
            //    along it and the result stays sealed;
            //  • the grid refines in both directions, so it tracks the screw
            //    surface. (A cheaper fan converging on one corner runs its strips
            //    corner-ward instead of along the ruling; consecutive strips then
            //    fold against each other — measured up to a 140° dihedral, which
            //    is exactly the banding it was meant to remove.)
            func point(_ i: Int, _ j: Int) -> Vector {
                let w1 = Double(i) / Double(n), w2 = Double(j) / Double(n)
                let w0 = 1 - w1 - w2
                let pos = p[0] * w0 + p[1] * w1 + p[2] * w2
                let t = f[0] * w0 + f[1] * w1 + f[2] * w2
                return t > 1e-9 ? center + rotate(pos - center, by: angle * t) : pos
            }
            var grid = [[Vector]]()
            for i in 0...n {
                grid.append((0...(n - i)).map { point(i, $0) })
            }
            for i in 0..<n {
                for j in 0..<(n - i) {
                    emit(grid[i][j], grid[i + 1][j], grid[i][j + 1])
                    if i + j < n - 1 {
                        emit(grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1])
                    }
                }
            }
        }
        guard !polygons.isEmpty else { return mesh }
        // Blend normals across folds gentler than the box's real edges (~44°,
        // matching FaceTopology's edge threshold) so the subdivided walls shade as
        // one smooth surface while the true 90° box edges stay crisp.
        return Euclid.Mesh(polygons).makeWatertight()
            .smoothingNormals(forAnglesGreaterThan: .degrees(44))
    }

    /// Draft (taper) an existing face by `degrees` about the line where its
    /// plane meets the neutral plane — the mould-making operation SOLIDWORKS
    /// calls Draft, and what "ALL DRAFT 5°" on a cast part means.
    ///
    /// It is a SHEAR, not a rotation, and that distinction is the whole reason
    /// this is not just `rotateFace` with a pivot (which is what it was first
    /// written as, 2026-09-03). A rigid rotation of a wall carries its top edge
    /// along an ARC: the edge drops by h(1 − cos θ), which drags the adjacent
    /// top face out of its own plane and shortens the part. Draft has to leave
    /// every neighbouring face where it is — only the drafted wall's slope
    /// changes — so each vertex moves within its own height instead:
    ///
    ///     p' = p − tan(θ) · h · f⊥ ,  h = (p − neutralOrigin) · n̂
    ///
    /// where `f⊥` is the face normal with the neutral direction removed. Points
    /// ON the neutral plane (h = 0) do not move, and the wall meets the top
    /// face at h·tanθ in — the number a draft callout means.
    ///
    /// A positive angle leans the face INWARD as it recedes along the neutral
    /// normal, so the body narrows away from the parting line (the sign a mould
    /// wants); negative widens it.
    ///
    /// Returns the mesh unchanged when the face is parallel to the neutral
    /// plane (no hinge exists) or the angle is zero.
    static func draftFace(
        mesh: Euclid.Mesh,
        face: FaceTopology.PlanarFace,
        neutralOrigin: SIMD3<Double>,
        neutralNormal: SIMD3<Double>,
        degrees: Double
    ) -> Euclid.Mesh {
        guard abs(degrees) > 1e-9, simd_length(neutralNormal) > 1e-9 else { return mesh }
        let n = simd_normalize(neutralNormal)
        let plane = SketchPlane(origin: face.origin, xAxis: face.basisX, yAxis: face.basisY)
        let faceNormal = simd_normalize(plane.normal)
        // The component of the face normal lying IN the neutral plane. It
        // vanishes exactly when the face is parallel to the neutral plane,
        // which is the case with no hinge to draft about.
        let perpendicular = faceNormal - simd_dot(faceNormal, n) * n
        guard simd_length(perpendicular) > 1e-6 else { return mesh }
        let slide = simd_normalize(perpendicular) * tan(degrees * .pi / 180)

        func onFace(_ position: Vector) -> Bool {
            let w = SIMD3<Double>(position.x, position.y, position.z)
            guard abs(simd_dot(w - face.origin, faceNormal)) <= Self.moveFacePlaneTolerance
            else { return false }
            let local = plane.toLocal(w)
            guard Self.pointInLoopInclusive(local, face.outline) else { return false }
            for hole in face.holes where Self.pointStrictlyInLoop(local, hole) {
                return false
            }
            return true
        }

        func drafted(_ position: Vector) -> Vector {
            let w = SIMD3<Double>(position.x, position.y, position.z)
            let height = simd_dot(w - neutralOrigin, n)
            let moved = w - height * slide
            return Vector(moved.x, moved.y, moved.z)
        }

        var polygons = [Euclid.Polygon]()
        for polygon in EuclidBridge.triangles(of: mesh) {
            let verts = polygon.vertices
            guard verts.count == 3, verts.contains(where: { onFace($0.position) }) else {
                polygons.append(polygon)
                continue
            }
            // The drafted wall stays planar, so no subdivision is needed: move
            // the on-face vertices and re-normal from the moved geometry (a
            // carried-over normal would light the wall as if it had not moved).
            let moved = verts.map { onFace($0.position) ? drafted($0.position) : $0.position }
            let normal = Self.newellNormal(moved)
            if let tri = Euclid.Polygon(moved.map { Euclid.Vertex($0, normal) }) {
                polygons.append(tri)
            }
        }
        guard !polygons.isEmpty else { return mesh }
        return Euclid.Mesh(polygons).makeWatertight()
    }

    /// Robust polygon normal via Newell's method — consistent with the vertex
    /// winding and stable for near-degenerate triangles (unlike a single cross
    /// product). Used to re-normal deformed faces so shading matches the winding.
    static func newellNormal(_ vertices: [Vector]) -> Vector {
        var n = Vector.zero
        let count = vertices.count
        guard count >= 3 else { return Vector(0, 0, 1) }
        for i in 0..<count {
            let cur = vertices[i], nxt = vertices[(i + 1) % count]
            n = Vector(
                n.x + (cur.y - nxt.y) * (cur.z + nxt.z),
                n.y + (cur.z - nxt.z) * (cur.x + nxt.x),
                n.z + (cur.x - nxt.x) * (cur.y + nxt.y))
        }
        let len = n.length
        return len > 1e-12 ? n / len : Vector(0, 0, 1)
    }

    /// On-plane tolerance for `moveFace`. Generous enough to catch float noise
    /// on a face's own vertices, far tighter than any real face-to-face gap.
    static let moveFacePlaneTolerance: Double = 1e-3

    /// Point-in-polygon (ray cast) that also returns true on the boundary, so a
    /// vertex sitting exactly on an outline edge or corner counts as "on the
    /// face". `loop` is a closed CCW polygon in the face's 2D basis.
    static func pointInLoopInclusive(_ p: SIMD2<Double>, _ loop: [SIMD2<Double>]) -> Bool {
        guard loop.count >= 3 else { return false }
        for i in 0..<loop.count {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            if distanceToSegment(p, a, b) <= moveFacePlaneTolerance { return true }
        }
        return pointStrictlyInLoop(p, loop)
    }

    /// Strict ray-cast point-in-polygon (boundary excluded, used for holes).
    static func pointStrictlyInLoop(_ p: SIMD2<Double>, _ loop: [SIMD2<Double>]) -> Bool {
        guard loop.count >= 3 else { return false }
        var inside = false
        var j = loop.count - 1
        for i in 0..<loop.count {
            let a = loop[i], b = loop[j]
            if (a.y > p.y) != (b.y > p.y) {
                let t = (p.y - a.y) / (b.y - a.y)
                if p.x < a.x + t * (b.x - a.x) { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    static func distanceToSegment(
        _ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>
    ) -> Double {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        guard len2 > 1e-18 else { return simd_length(p - a) }
        let t = max(0, min(1, simd_dot(p - a, ab) / len2))
        return simd_length(p - (a + ab * t))
    }
}
