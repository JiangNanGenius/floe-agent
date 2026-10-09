//
//  SplitKit.swift
//  openshape3d
//
//  Split Body (spec §4.9): divide a solid into parts WITHOUT removing
//  material. Plane splits subtract half-space cutters (large boxes on each
//  side of the plane); profile splits extrude the sketch profile through the
//  whole body and subtract/intersect for the two sides.
//

import Foundation
import simd
import Euclid

nonisolated enum SplitKit {

    /// Split `mesh` by an infinite plane. `kept` is the half on the plane's
    /// +normal side, `other` the -normal side. Either half is empty when the
    /// plane misses the body.
    static func split(
        mesh: Euclid.Mesh,
        byPlane plane: SketchPlane
    ) -> (kept: Euclid.Mesh, other: Euclid.Mesh) {
        let radius = boundingRadius(of: mesh, about: plane.origin)
        guard radius > 0 else { return (mesh, Euclid.Mesh([])) }
        let kept = mesh
            .subtracting(halfSpaceBox(plane: plane, radius: radius, positiveSide: false))
            .makeWatertight()
        let other = mesh
            .subtracting(halfSpaceBox(plane: plane, radius: radius, positiveSide: true))
            .makeWatertight()
        return (kept, other)
    }

    /// Split `mesh` by a sketch profile (with optional holes): the profile is
    /// extruded through the whole body along the plane normal, both sides
    /// (Shapr3D projects splitting tools through the body — no contact
    /// needed), then intersect/subtract yield the two parts.
    static func split(
        mesh: Euclid.Mesh,
        byProfile profile: Profile,
        holes: [Profile] = [],
        in plane: SketchPlane
    ) -> (inside: Euclid.Mesh, outside: Euclid.Mesh) {
        let radius = boundingRadius(of: mesh, about: plane.origin)
        guard radius > 0 else { return (Euclid.Mesh([]), mesh) }
        let cutter = KernelOps.extrude(
            profile: profile,
            holes: holes,
            in: plane,
            distance: radius * 2,
            symmetric: true
        )
        let inside = mesh.intersection(cutter).makeWatertight()
        let outside = mesh.subtracting(cutter).makeWatertight()
        return (inside, outside)
    }

    // MARK: - Cutter construction

    /// Half-space cutter: a large box covering everything within
    /// 1.5×`radius` of the plane origin on one side of the plane.
    private static func halfSpaceBox(
        plane: SketchPlane,
        radius: Double,
        positiveSide: Bool
    ) -> Euclid.Mesh {
        let r = radius * 1.5
        let cube = Euclid.Mesh.cube(
            center: Vector(0, 0, positiveSide ? r : -r),
            size: Vector(r * 4, r * 4, r * 2)
        )
        return cube.transformed(by: KernelOps.planeToWorld(plane))
    }

    /// Distance from `origin` to the farthest bounds corner: a sphere radius
    /// guaranteed to contain the whole mesh. Zero for empty meshes.
    private static func boundingRadius(
        of mesh: Euclid.Mesh,
        about origin: SIMD3<Double>
    ) -> Double {
        let bounds = mesh.bounds
        guard !bounds.isEmpty else { return 0 }
        var radius = 0.0
        for i in 0..<8 {
            let corner = SIMD3(
                (i & 1) == 0 ? bounds.min.x : bounds.max.x,
                (i & 2) == 0 ? bounds.min.y : bounds.max.y,
                (i & 4) == 0 ? bounds.min.z : bounds.max.z
            )
            radius = max(radius, simd_length(corner - origin))
        }
        return radius
    }
}

// MARK: - KernelOps facade

nonisolated extension KernelOps {

    /// Split a body mesh by an infinite plane; see `SplitKit.split(mesh:byPlane:)`.
    static func split(
        body: Euclid.Mesh,
        byPlane plane: SketchPlane
    ) -> (kept: Euclid.Mesh, other: Euclid.Mesh) {
        SplitKit.split(mesh: body, byPlane: plane)
    }

    /// Split a body mesh by a through-extruded sketch profile; see
    /// `SplitKit.split(mesh:byProfile:holes:in:)`.
    static func split(
        body: Euclid.Mesh,
        byProfile profile: Profile,
        holes: [Profile] = [],
        in plane: SketchPlane
    ) -> (inside: Euclid.Mesh, outside: Euclid.Mesh) {
        SplitKit.split(mesh: body, byProfile: profile, holes: holes, in: plane)
    }
}
