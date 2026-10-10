//
//  SweepLoftKit.swift
//  openshape3d
//
//  Sweep (profile along a 3D spine), Loft (over ordered planar profiles),
//  and Helix path generation (plan §B1/§B2/§B16, spec §4.11/§4.5/§1.17).
//  Sweep transports the profile frame manually (parallel transport with
//  mitred corner sections) so sharp spine corners behave like the union of
//  the straight legs instead of self-folding. All math in Double; results
//  are healed with makeWatertight().
//

import Foundation
import simd
import Euclid

nonisolated enum SweepLoftKit {

    // MARK: - Sweep

    /// Sweep a closed profile (with optional holes) along a 3D polyline
    /// spine in world space. The profile is anchored at the spine start:
    /// its plane-local coordinates are taken relative to the projection of
    /// `spine[0]` onto the sketch plane, so a spine starting on the plane
    /// reproduces the profile exactly at the first section (Shapr3D's
    /// "profile positioned at the path start"). The section frame is the
    /// sketch-plane basis rotated onto the first tangent, then parallel-
    /// transported along the spine; interior corners get a section on the
    /// bisector plane stretched by 1/cos(halfAngle) (mitre joint).
    static func sweep(
        profile: Profile,
        holes: [Profile] = [],
        in plane: SketchPlane,
        alongPath spine: [SIMD3<Double>]
    ) -> Euclid.Mesh {
        let spine = deduplicated(spine)
        guard spine.count >= 2, profile.loop.count >= 3 else {
            return Euclid.Mesh([])
        }
        let anchor = plane.toLocal(spine[0])
        let holeLoops = holes.map(\.loop).filter { $0.count >= 3 }

        // NO boolean, and no Euclid loft either. The bores used to be swept
        // as cutters and subtracted by BSP CSG — unbounded on a spline
        // outline's thousand samples (gotcha 24) — and Euclid's capped loft
        // of even a single loop spends seconds tessellating a thousand-gon
        // cap. Instead the outer loop (CCW) and every hole (CW) are swept as
        // walls through the SAME transported frames, so a hole's wall faces
        // into its cavity by winding alone, and the two caps are the
        // profile-with-holes triangulated in the end frames.
        let outer = Profile.signedArea(profile.loop) < 0 ? Array(profile.loop.reversed()) : profile.loop
        let holesCW = holeLoops.map { Profile.signedArea($0) > 0 ? Array($0.reversed()) : $0 }
        let frames = sweepFrames(in: plane, along: spine)
        guard frames.count >= 2 else { return Euclid.Mesh([]) }

        var polygons: [Euclid.Polygon] = []
        func walls(_ loop: [SIMD2<Double>]) {
            let rings = frames.map { frame in loop.map { frame.place($0 - anchor) } }
            let n = loop.count
            for i in 0..<(rings.count - 1) {
                for j in 0..<n {
                    let k = (j + 1) % n
                    let quad = [rings[i][j], rings[i][k], rings[i + 1][k], rings[i + 1][j]]
                    if let polygon = Euclid.Polygon(quad.map { Vector($0.x, $0.y, $0.z) }) {
                        polygons.append(polygon)
                    } else {
                        // a stretched mitre can fold a quad: two triangles still stand
                        for tri in [[quad[0], quad[1], quad[2]], [quad[0], quad[2], quad[3]]] {
                            if let polygon = Euclid.Polygon(tri.map { Vector($0.x, $0.y, $0.z) }) {
                                polygons.append(polygon)
                            }
                        }
                    }
                }
            }
        }
        walls(outer)
        holesCW.forEach(walls)

        let (vertices, triangles) = PolygonTriangulator.triangulate(
            outer: outer.map { $0 - anchor }, holes: holesCW.map { $0.map { $0 - anchor } })
        for (frame, flip) in [(frames[0], true), (frames[frames.count - 1], false)] {
            for t in stride(from: 0, to: triangles.count - 2, by: 3) {
                var pts = [triangles[t], triangles[t + 1], triangles[t + 2]].map { frame.place(vertices[$0]) }
                if flip { pts.reverse() }             // the start cap faces back along the spine
                if let polygon = Euclid.Polygon(pts.map { Vector($0.x, $0.y, $0.z) }) {
                    polygons.append(polygon)
                }
            }
        }
        return Euclid.Mesh(polygons).makeWatertight()
    }

    /// One transported section frame: where a plane-local offset lands in
    /// world space, including the mitre stretch at an interior corner.
    struct SweepFrame {
        var point: SIMD3<Double>
        var u: SIMD3<Double>
        var v: SIMD3<Double>
        var stretch: (factor: Double, axis: SIMD3<Double>)?

        func place(_ q: SIMD2<Double>) -> SIMD3<Double> {
            var offset = u * q.x + v * q.y
            if let (factor, axis) = stretch {
                offset += (factor - 1) * simd_dot(offset, axis) * axis
            }
            return point + offset
        }
    }

    /// Loft one closed loop along the spine: build transported sections and
    /// stitch them with Euclid's loft (which also caps the ends).
    private static func sweepLoop(
        _ loop: [SIMD2<Double>],
        relativeTo anchor: SIMD2<Double>,
        in plane: SketchPlane,
        along spine: [SIMD3<Double>]
    ) -> Euclid.Mesh {
        let sections = sweepSections(
            loop, relativeTo: anchor, in: plane, along: spine
        )
        guard sections.count >= 2 else { return Euclid.Mesh([]) }
        return Euclid.Mesh.loft(sections).makeWatertight()
    }

    /// Closed section paths along the spine (one per spine point), with
    /// mitre-stretched sections at interior corners.
    static func sweepSections(
        _ loop: [SIMD2<Double>],
        relativeTo anchor: SIMD2<Double>,
        in plane: SketchPlane,
        along spine: [SIMD3<Double>]
    ) -> [Euclid.Path] {
        guard loop.count >= 3 else { return [] }
        let local = loop.map { $0 - anchor }
        return sweepFrames(in: plane, along: spine).map { frame in
            var points = local.map { q -> PathPoint in
                let w = frame.place(q)
                return .point(w.x, w.y, w.z)
            }
            if let first = points.first {
                points.append(first)
            }
            return Euclid.Path(points)
        }
    }

    /// The transported section frames along the spine (one per spine point):
    /// the plane basis rotated onto the first tangent (minimal rotation, no
    /// spin), parallel-transported through each corner, with the bisector
    /// section at an interior corner stretched by 1/cos(half-angle) so the
    /// straight legs meet like extrusions (mitre joint). Every loop swept
    /// along the same spine shares these frames.
    static func sweepFrames(
        in plane: SketchPlane,
        along spine: [SIMD3<Double>]
    ) -> [SweepFrame] {
        guard spine.count >= 2 else { return [] }
        let tangents = (0..<spine.count - 1).map {
            simd_normalize(spine[$0 + 1] - spine[$0])
        }
        let r0 = rotation(from: simd_normalize(plane.normal), to: tangents[0])
        var u = simd_act(r0, plane.xAxis)
        var v = simd_act(r0, plane.yAxis)

        var frames = [SweepFrame(point: spine[0], u: u, v: v, stretch: nil)]
        for i in 1..<spine.count - 1 {
            let turn = rotation(from: tangents[i - 1], to: tangents[i])
            let angle = turn.angle
            guard angle > 1e-9 else {
                frames.append(SweepFrame(point: spine[i], u: u, v: v, stretch: nil))
                continue
            }
            let half = simd_quatd(angle: angle / 2, axis: turn.axis)
            u = simd_act(half, u)
            v = simd_act(half, v)
            // Clamp for near-reversals (the mitre would go to infinity).
            let bisector = simd_normalize(tangents[i - 1] + tangents[i])
            let axis = simd_normalize(simd_cross(bisector, turn.axis))
            let factor = 1 / max(cos(angle / 2), 0.1)
            frames.append(SweepFrame(point: spine[i], u: u, v: v, stretch: (factor, axis)))
            u = simd_act(half, u)
            v = simd_act(half, v)
        }
        frames.append(SweepFrame(point: spine[spine.count - 1], u: u, v: v, stretch: nil))
        return frames
    }

    // MARK: - Loft

    /// Loft a solid through 2+ ordered planar profiles (spec §4.5,
    /// profiles-only tier). Outlines are resampled to a common vertex count
    /// (uniform arc-length) when counts differ so sections pair ring-to-ring
    /// without fan triangles; Euclid's loft handles start-vertex alignment
    /// on parallel sections and caps the ends. Holes are lofted as compound
    /// subpaths when every section carries the same number of holes;
    /// otherwise holes are ignored (v1).
    static func loft(
        profiles: [(profile: Profile, holes: [Profile], plane: SketchPlane)]
    ) -> Euclid.Mesh {
        guard profiles.count >= 2,
              profiles.allSatisfy({ $0.profile.loop.count >= 3 })
        else { return Euclid.Mesh([]) }

        let outers = commonCountLoops(profiles.map { ccwLoop($0.profile) })

        let holeCounts = Set(profiles.map { $0.holes.count })
        var holeFamilies: [[[SIMD2<Double>]]] = []
        if let count = holeCounts.first, holeCounts.count == 1, count > 0 {
            // holeFamilies[h][s] = hole h's loop on section s.
            holeFamilies = (0..<count).map { h in
                commonCountLoops(profiles.map { ccwLoop($0.holes[h]) })
            }
        }

        // NO boolean, holes or not. Euclid's loft over subpaths is a symmetric
        // difference of the lofted subpaths — a BSP CSG, unbounded on a
        // spline outline's samples (gotcha 24) — and even its capped tube of
        // one loop spends seconds tessellating a thousand-gon cap that would
        // be thrown away. So every loop family becomes a tube of ring-to-ring
        // quads built here (each ring's start aligned to the previous ring,
        // which is what Euclid's loft did for us), a hole's tube turned to
        // face its cavity, and the profile-with-holes triangulated as the two
        // end caps. Orientation is settled by the signed volume.
        func tube(_ family: [[SIMD2<Double>]]) -> [Euclid.Polygon] {
            var rings = profiles.enumerated().map { s, entry in
                family[s].map { entry.plane.toWorld($0) }
            }
            for s in 1..<rings.count {
                let prev = rings[s - 1], ring = rings[s], n = ring.count
                guard n == prev.count, n > 0 else { continue }
                var best = 0, bestCost = Double.infinity
                for shift in 0..<n {
                    var cost = 0.0
                    for j in 0..<n {
                        cost += simd_length_squared(ring[(j + shift) % n] - prev[j])
                        if cost >= bestCost { break }
                    }
                    if cost < bestCost { bestCost = cost; best = shift }
                }
                if best != 0 { rings[s] = (0..<n).map { ring[($0 + best) % n] } }
            }
            var out: [Euclid.Polygon] = []
            for s in 0..<(rings.count - 1) {
                let a = rings[s], b = rings[s + 1], n = min(a.count, b.count)
                // Slice the band so no quad twists past ~8°. A ruled band
                // between a straight side and an arc (square → circle)
                // twists by up to 45° from ring to ring near a corner; one
                // quad carrying all of it splits into two triangles more
                // than 20° apart, which `FeatureEdges` draws as a crease
                // across a surface that is smooth (the tutorial's loft,
                // 2026-09-17). Sharing the twist over `slices` quads keeps
                // every dihedral under the threshold; a band with no twist
                // (frustum, draft extrude) stays a single row of quads.
                let slices = bandSlices(a, b, count: n)
                var sub: [[SIMD3<Double>]] = [a]
                if slices > 1 {
                    for i in 1..<slices {
                        let t = Double(i) / Double(slices)
                        sub.append((0..<n).map { a[$0] + (b[$0] - a[$0]) * t })
                    }
                }
                sub.append(b)
                for r in 0..<(sub.count - 1) {
                    let lo = sub[r], hi = sub[r + 1]
                    for j in 0..<n {
                        let k = (j + 1) % n
                        let quad = [lo[j], lo[k], hi[k], hi[j]]
                        if let polygon = Euclid.Polygon(quad.map { Vector($0.x, $0.y, $0.z) }) {
                            out.append(polygon)
                        } else {
                            for tri in [[quad[0], quad[1], quad[2]], [quad[0], quad[2], quad[3]]] {
                                if let polygon = Euclid.Polygon(tri.map { Vector($0.x, $0.y, $0.z) }) {
                                    out.append(polygon)
                                }
                            }
                        }
                    }
                }
            }
            return out
        }
        var polygons = tube(outers)
        for family in holeFamilies {
            polygons += tube(family).map { $0.inverted() }
        }
        let forward = simd_dot(profiles[profiles.count - 1].plane.origin - profiles[0].plane.origin,
                               simd_normalize(profiles[0].plane.normal)) >= 0
        for (index, flip) in [(0, forward), (profiles.count - 1, !forward)] {
            let entry = profiles[index]
            let (vertices, triangles) = PolygonTriangulator.triangulate(
                outer: outers[index], holes: holeFamilies.map { $0[index] })
            for t in stride(from: 0, to: triangles.count - 2, by: 3) {
                var pts = [triangles[t], triangles[t + 1], triangles[t + 2]].map { entry.plane.toWorld(vertices[$0]) }
                if flip { pts.reverse() }
                if let polygon = Euclid.Polygon(pts.map { Vector($0.x, $0.y, $0.z) }) {
                    polygons.append(polygon)
                }
            }
        }
        let mesh = Euclid.Mesh(polygons).makeWatertight()
        return signedVolume(of: mesh) < 0 ? mesh.inverted() : mesh
    }

    /// How many rows a ring-to-ring band needs so that no quad's two
    /// triangles differ by more than ~8°: the band's worst quad twist
    /// (angle between its two triangle normals) divided by 8°, 1…12.
    static func bandSlices(_ a: [SIMD3<Double>], _ b: [SIMD3<Double>], count n: Int) -> Int {
        var worst = 0.0
        for j in 0..<n {
            let k = (j + 1) % n
            let n1 = simd_cross(a[k] - a[j], b[k] - a[j])
            let n2 = simd_cross(b[k] - a[j], b[j] - a[j])
            let l1 = simd_length(n1), l2 = simd_length(n2)
            guard l1 > 1e-12, l2 > 1e-12 else { continue }
            let c = max(-1.0, min(1.0, simd_dot(n1, n2) / (l1 * l2)))
            worst = max(worst, acos(c) * 180 / .pi)
        }
        return max(1, min(12, Int((worst / 8).rounded(.up))))
    }

    /// Signed tetrahedron sum — positive when the normals face outward.
    static func signedVolume(of mesh: Euclid.Mesh) -> Double {
        var sum = 0.0
        for polygon in mesh.triangulate().polygons {
            let v = polygon.vertices
            let p0 = SIMD3(v[0].position.x, v[0].position.y, v[0].position.z)
            let p1 = SIMD3(v[1].position.x, v[1].position.y, v[1].position.z)
            let p2 = SIMD3(v[2].position.x, v[2].position.y, v[2].position.z)
            sum += simd_dot(p0, simd_cross(p1, p2))
        }
        return sum / 6
    }

    /// Loop with positive (CCW) signed area.
    private static func ccwLoop(_ profile: Profile) -> [SIMD2<Double>] {
        profile.area < 0 ? profile.loop.reversed() : profile.loop
    }

    /// Resample all loops to a shared vertex count when they differ.
    private static func commonCountLoops(
        _ loops: [[SIMD2<Double>]]
    ) -> [[SIMD2<Double>]] {
        let counts = Set(loops.map(\.count))
        guard counts.count > 1, let target = counts.max() else { return loops }
        return loops.map { resampleClosedLoop($0, to: target) }
    }

    /// Uniform arc-length resampling of a closed loop to `count` points,
    /// starting at the loop's first vertex. Vertices whose arc length lands
    /// exactly on a sample position (e.g. square corners with a count
    /// divisible by 4) are preserved exactly.
    static func resampleClosedLoop(
        _ loop: [SIMD2<Double>], to count: Int
    ) -> [SIMD2<Double>] {
        guard loop.count >= 3, count >= 3, loop.count != count else {
            return loop
        }
        var cumulative = [0.0]
        cumulative.reserveCapacity(loop.count + 1)
        for i in 0..<loop.count {
            let step = simd_length(loop[(i + 1) % loop.count] - loop[i])
            cumulative.append(cumulative[i] + step)
        }
        guard let total = cumulative.last, total > 1e-12 else { return loop }

        var result = [SIMD2<Double>]()
        result.reserveCapacity(count)
        var segment = 0
        for i in 0..<count {
            let target = Double(i) / Double(count) * total
            while segment < loop.count - 1, cumulative[segment + 1] < target {
                segment += 1
            }
            let a = loop[segment]
            let b = loop[(segment + 1) % loop.count]
            let span = cumulative[segment + 1] - cumulative[segment]
            let t = span > 1e-12 ? (target - cumulative[segment]) / span : 0
            result.append(a + (b - a) * t)
        }
        return result
    }

    // MARK: - Shared helpers

    /// Closed Euclid path of a plane-local loop mapped into world space.
    static func closedWorldPath(
        _ loop: [SIMD2<Double>], in plane: SketchPlane
    ) -> Euclid.Path {
        var points = loop.map { p -> PathPoint in
            let w = plane.toWorld(p)
            return .point(w.x, w.y, w.z)
        }
        if let first = points.first {
            points.append(first)
        }
        return Euclid.Path(points)
    }

    /// Minimal rotation carrying unit vector `a` onto unit vector `b`
    /// (identity when parallel; a well-defined half-turn when opposite).
    static func rotation(
        from a: SIMD3<Double>, to b: SIMD3<Double>
    ) -> simd_quatd {
        let dot = simd_dot(a, b)
        if dot > 1 - 1e-12 {
            return simd_quatd(angle: 0, axis: SIMD3(1, 0, 0))
        }
        if dot < -1 + 1e-12 {
            let helper: SIMD3<Double> =
                abs(a.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            return simd_quatd(angle: .pi, axis: simd_normalize(simd_cross(a, helper)))
        }
        return simd_quatd(from: a, to: b)
    }

    /// Drop consecutive duplicate points (they would produce NaN tangents).
    private static func deduplicated(
        _ points: [SIMD3<Double>]
    ) -> [SIMD3<Double>] {
        var result = [SIMD3<Double>]()
        result.reserveCapacity(points.count)
        for p in points where result.last.map({ simd_length(p - $0) > 1e-12 }) ?? true {
            result.append(p)
        }
        return result
    }

    private static func length(of spine: [SIMD3<Double>]) -> Double {
        (0..<spine.count - 1).reduce(0) {
            $0 + simd_length(spine[$1 + 1] - spine[$1])
        }
    }

    /// Push both endpoints outward along their segment directions (the
    /// endpoints stay collinear with their segments, so the geometry only
    /// lengthens).
    private static func extended(
        _ spine: [SIMD3<Double>], by distance: Double
    ) -> [SIMD3<Double>] {
        var result = spine
        let n = spine.count
        result[0] -= simd_normalize(spine[1] - spine[0]) * distance
        result[n - 1] += simd_normalize(spine[n - 1] - spine[n - 2]) * distance
        return result
    }
}

// MARK: - Helix

nonisolated enum HelixKit {

    /// Tessellated helical polyline usable as a Sweep spine (spec §1.17).
    /// The helix coils about the plane normal through `center` (plane-local
    /// coordinates), starting on the plane at angle `startAt` (radians from
    /// the plane's x axis) and climbing `pitch` per turn along +normal
    /// (negative pitch descends). `clockwise` reverses the coil direction
    /// as seen looking down the plane normal. Returns turns × segmentsPerTurn
    /// segments (+1 point), with the final point exactly at the helix end.
    static func path(
        radius: Double,
        pitch: Double,
        turns: Double,
        clockwise: Bool = false,
        startAt startAngle: Double = 0,
        center: SIMD2<Double> = .zero,
        in plane: SketchPlane,
        segmentsPerTurn: Int = 48
    ) -> [SIMD3<Double>] {
        guard radius > 1e-12, turns > 1e-9, segmentsPerTurn >= 3 else {
            return []
        }
        let steps = max(1, Int((turns * Double(segmentsPerTurn)).rounded(.up)))
        let normal = simd_normalize(plane.normal)
        var points = [SIMD3<Double>]()
        points.reserveCapacity(steps + 1)
        for i in 0...steps {
            // Parameter in turns, clamped so a fractional last step still
            // ends exactly at `turns`.
            let t = min(Double(i) / Double(segmentsPerTurn), turns)
            let angle = startAngle + (clockwise ? -1 : 1) * t * 2 * .pi
            let q = center + radius * SIMD2(cos(angle), sin(angle))
            points.append(plane.toWorld(q) + normal * (pitch * t))
        }
        return points
    }
}

// MARK: - KernelOps facade

nonisolated extension KernelOps {

    /// Sweep a closed profile (with optional holes) along a 3D spine
    /// polyline in world space (plan §B1). See `SweepLoftKit.sweep`.
    static func sweep(
        profile: Profile,
        holes: [Profile] = [],
        in plane: SketchPlane,
        alongPath spine: [SIMD3<Double>]
    ) -> Euclid.Mesh {
        SweepLoftKit.sweep(
            profile: profile, holes: holes, in: plane, alongPath: spine
        )
    }

    /// Loft a solid through 2+ ordered planar profiles (plan §B2). See
    /// `SweepLoftKit.loft`.
    static func loft(
        profiles: [(profile: Profile, holes: [Profile], plane: SketchPlane)]
    ) -> Euclid.Mesh {
        SweepLoftKit.loft(profiles: profiles)
    }
}
