//
//  WrapKit.swift
//  openshape3d
//
//  Spec §4.15 Wrap & Emboss — map a flat sketch profile onto a cylindrical (or
//  conical) face WITHOUT stretching it, then raise or engrave it by a depth.
//
//  The distinction from Project is the whole point: Project casts a profile
//  along a straight direction, so anything it lands on gets wider the further
//  it wraps. Wrap treats the profile's local X as ARC LENGTH along the surface,
//  so a 40 mm-wide logo is 40 mm of material after wrapping, whatever the
//  cylinder's radius. That property is what the tests here pin down.
//
//  The emboss solid is built in angular BANDS. A single triangulation of the
//  profile would chord straight through the cylinder wherever a triangle spans
//  a wide angle, quietly losing volume; banding keeps every facet narrow. Cuts
//  between bands are interior, so no wall is emitted there and the bands tile
//  into one closed manifold.
//

import Foundation
import simd
import Euclid

nonisolated enum WrapKit {

    /// The cylindrical face a profile is wrapped onto.
    ///
    /// `reference` fixes where the profile's local x = 0 sits around the
    /// circumference; `axisPoint` fixes where its local y = 0 sits along the
    /// axis. Together they are the spec's "Center" (alignment origin).
    nonisolated struct Target: Sendable {
        var axisPoint: SIMD3<Double>
        var axisDir: SIMD3<Double>
        var reference: SIMD3<Double>
        var radius: Double

        init(axisPoint: SIMD3<Double>, axisDir: SIMD3<Double>,
             reference: SIMD3<Double>, radius: Double) {
            self.axisPoint = axisPoint
            self.axisDir = simd_normalize(axisDir)
            // Re-orthogonalise so a caller-supplied reference need only be
            // roughly perpendicular to the axis.
            let projected = reference - self.axisDir * simd_dot(reference, self.axisDir)
            self.reference = simd_length(projected) > 1e-12
                ? simd_normalize(projected)
                : Self.anyPerpendicular(to: self.axisDir)
            self.radius = radius
        }

        /// Built from a face the picker found on a body.
        init(face: FaceTopology.CylindricalFace) {
            let axis = simd_normalize(face.axisDir)
            let mid = (face.minT + face.maxT) / 2
            self.init(
                axisPoint: face.axisPoint + axis * (mid - simd_dot(face.axisPoint, axis)),
                axisDir: axis,
                reference: Self.anyPerpendicular(to: axis),
                radius: face.radius)
        }

        static func anyPerpendicular(to axis: SIMD3<Double>) -> SIMD3<Double> {
            let seed = abs(axis.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
            return simd_normalize(simd_cross(axis, seed))
        }
    }

    /// Spec's history params, minus the selections.
    nonisolated struct Settings: Sendable {
        /// Positive raises the profile off the surface, negative engraves it.
        var depth: Double
        /// Rotation of the profile about its own centre, radians.
        var rotation: Double = 0
        /// The profile point that lands on the target's alignment origin.
        var center: SIMD2<Double> = .zero
        /// Angular facet size of the generated solid.
        var angleStep: Double = .pi / 90  // 2°

        init(depth: Double, rotation: Double = 0,
             center: SIMD2<Double> = .zero, angleStep: Double = .pi / 90) {
            self.depth = depth
            self.rotation = rotation
            self.center = center
            self.angleStep = angleStep
        }
    }

    // MARK: - The mapping

    /// Map one profile point onto the surface, `radialOffset` off it.
    ///
    /// Local x is arc length around the cylinder, local y is distance along the
    /// axis — neither is scaled, which is what "no stretch" means.
    static func wrap(
        _ p: SIMD2<Double>, onto target: Target,
        settings: Settings = Settings(depth: 0), radialOffset: Double = 0
    ) -> SIMD3<Double> {
        let local = rotated(p - settings.center, by: settings.rotation)
        let angle = local.x / target.radius
        let perpendicular = simd_cross(target.axisDir, target.reference)
        let radial = target.reference * cos(angle) + perpendicular * sin(angle)
        return target.axisPoint
            + target.axisDir * local.y
            + radial * (target.radius + radialOffset)
    }

    /// The wrapped polyline for a profile loop or open chain.
    static func wrap(
        loop: [SIMD2<Double>], onto target: Target,
        settings: Settings = Settings(depth: 0), radialOffset: Double = 0
    ) -> [SIMD3<Double>] {
        loop.map { wrap($0, onto: target, settings: settings, radialOffset: radialOffset) }
    }

    // MARK: - The emboss solid

    /// A closed solid for the raised (or engraved) profile, ready to fuse into
    /// or cut out of the target body.
    ///
    /// Nil for a degenerate profile or a zero depth. The caller booleans it:
    /// positive depth unions, negative subtracts.
    static func embossSolid(
        loop: [SIMD2<Double>], onto target: Target, settings: Settings
    ) -> Euclid.Mesh? {
        guard loop.count >= 3, abs(settings.depth) > 1e-9, target.radius > 1e-9 else {
            return nil
        }
        // The wall spans radius..radius+depth for a raised profile, and
        // radius+depth..radius for an engraved one.
        let inner = min(0, settings.depth), outer = max(0, settings.depth)

        let dense = densified(loop, arcStep: target.radius * settings.angleStep)
        let bandWidth = target.radius * settings.angleStep
        guard let range = uRange(dense) else { return nil }

        var polygons = [Euclid.Polygon]()
        var u = range.lowerBound
        while u < range.upperBound - 1e-12 {
            let next = min(u + bandWidth, range.upperBound)
            let band = clipped(dense, uMin: u, uMax: next)
            if band.count >= 3 {
                polygons += bandPolygons(
                    band, cuts: [u, next], target: target, settings: settings,
                    inner: inner, outer: outer)
            }
            u = next
        }
        guard !polygons.isEmpty else { return nil }
        return Euclid.Mesh(polygons)
    }

    /// Surface polygons for one angular band: the two curved faces, plus walls
    /// on the profile's own edges only — a wall on a band CUT would be interior.
    private static func bandPolygons(
        _ band: [SIMD2<Double>], cuts: [Double], target: Target, settings: Settings,
        inner: Double, outer: Double
    ) -> [Euclid.Polygon] {
        var result = [Euclid.Polygon]()

        // Caps: triangulate flat, then lift each vertex onto the surface.
        let flat = band.map { Euclid.Vertex(Euclid.Vector($0.x, $0.y, 0)) }
        guard let polygon = Euclid.Polygon(flat) else { return [] }
        for triangle in polygon.triangulate() {
            let uv = triangle.vertices.map { SIMD2($0.position.x, $0.position.y) }
            if let outerFace = face(uv.map {
                wrap($0, onto: target, settings: settings, radialOffset: outer)
            }) { result.append(outerFace) }
            if let innerFace = face(uv.reversed().map {
                wrap($0, onto: target, settings: settings, radialOffset: inner)
            }) { result.append(innerFace) }
        }

        // Walls on the profile's real edges.
        for i in 0..<band.count {
            let a = band[i], b = band[(i + 1) % band.count]
            guard !isCutEdge(a, b, cuts: cuts) else { continue }
            let quad = [
                wrap(a, onto: target, settings: settings, radialOffset: inner),
                wrap(b, onto: target, settings: settings, radialOffset: inner),
                wrap(b, onto: target, settings: settings, radialOffset: outer),
                wrap(a, onto: target, settings: settings, radialOffset: outer),
            ]
            if let wall = face(quad) { result.append(wall) }
        }
        return result
    }

    /// An edge lying along a band cut is shared with the neighbouring band and
    /// must not become a wall.
    private static func isCutEdge(
        _ a: SIMD2<Double>, _ b: SIMD2<Double>, cuts: [Double]
    ) -> Bool {
        cuts.contains { abs(a.x - $0) < 1e-9 && abs(b.x - $0) < 1e-9 }
    }

    private static func face(_ points: [SIMD3<Double>]) -> Euclid.Polygon? {
        Euclid.Polygon(points.map { Euclid.Vertex(Euclid.Vector($0.x, $0.y, $0.z)) })
    }

    // MARK: - 2D helpers

    private static func rotated(_ p: SIMD2<Double>, by angle: Double) -> SIMD2<Double> {
        guard abs(angle) > 1e-12 else { return p }
        let c = cos(angle), s = sin(angle)
        return SIMD2(p.x * c - p.y * s, p.x * s + p.y * c)
    }

    private static func uRange(_ loop: [SIMD2<Double>]) -> ClosedRange<Double>? {
        guard let lo = loop.map(\.x).min(), let hi = loop.map(\.x).max(), hi > lo else {
            return nil
        }
        return lo...hi
    }

    /// Insert points so no edge spans more than `arcStep` in x — keeps every
    /// facet's chord close to the true arc.
    private static func densified(
        _ loop: [SIMD2<Double>], arcStep: Double
    ) -> [SIMD2<Double>] {
        guard arcStep > 1e-12 else { return loop }
        var out = [SIMD2<Double>]()
        for i in 0..<loop.count {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            out.append(a)
            let steps = Int((abs(b.x - a.x) / arcStep).rounded(.down))
            guard steps > 1 else { continue }
            for s in 1..<steps {
                out.append(a + (b - a) * (Double(s) / Double(steps)))
            }
        }
        return out
    }

    /// Sutherland–Hodgman clip to the vertical band `uMin...uMax`.
    private static func clipped(
        _ loop: [SIMD2<Double>], uMin: Double, uMax: Double
    ) -> [SIMD2<Double>] {
        func clip(_ polygon: [SIMD2<Double>], keep: (SIMD2<Double>) -> Bool,
                  at x: Double) -> [SIMD2<Double>] {
            guard !polygon.isEmpty else { return [] }
            var out = [SIMD2<Double>]()
            for i in 0..<polygon.count {
                let current = polygon[i], previous = polygon[(i + polygon.count - 1) % polygon.count]
                let currentIn = keep(current), previousIn = keep(previous)
                if currentIn != previousIn {
                    let dx = current.x - previous.x
                    let t = abs(dx) > 1e-15 ? (x - previous.x) / dx : 0
                    out.append(SIMD2(x, previous.y + (current.y - previous.y) * t))
                }
                if currentIn { out.append(current) }
            }
            return out
        }
        let left = clip(loop, keep: { $0.x >= uMin - 1e-12 }, at: uMin)
        return clip(left, keep: { $0.x <= uMax + 1e-12 }, at: uMax)
    }
}
