//
//  DeleteFaceKit.swift
//  openshape3d
//
//  Delete Face (spec §4.16) — the direct-modeling gesture that removes a face
//  and lets the neighbouring surfaces extend to re-close the solid, so a hole
//  or a pocket can be deleted without unwinding the history that made it.
//
//  This kit is the pure half: it turns a PICKED face into the two things the
//  rest of the system needs, and nothing else.
//
//    1. A `samplePoint` — a body-local point lying ON that face, which is how
//       OCCT is told which face to remove. Never a centroid-of-triangles: for
//       a cylinder that lands on the AXIS, inside the solid, and OCCT would
//       either remove nothing or remove the wrong face.
//    2. A `FaceSignature`, minted by `SignatureNaming`'s own builders rather
//       than re-derived here, so the `FaceRef` recorded for the feature node
//       matches what a rebuild will enumerate.
//
//  The healing itself is `OCCTKernel.removingFaces`; the parametric replay is
//  `FeatureGraph.evalDeleteFace`. Both already existed — this is what lets a
//  live pick reach them.
//

import Foundation
import simd

nonisolated enum DeleteFaceKit {

    /// A face picked for deletion, reduced to what the kernel and the feature
    /// graph each need. `triangles` is kept for the on-screen highlight and to
    /// recognise a second tap on the same face as "unpick me".
    nonisolated struct Target: Equatable, Sendable {
        var triangles: [Int]
        /// Body-LOCAL, and ON the surface. Body-local because `Body.brep` is:
        /// handing OCCT a world point for a moved body would miss.
        var samplePoint: SIMD3<Double>
        var signature: FaceSignature

        /// Two picks are the same face when they cover the same triangles —
        /// the same test the shell pick uses.
        static func == (lhs: Target, rhs: Target) -> Bool {
            Set(lhs.triangles) == Set(rhs.triangles)
        }
    }

    /// A planar face. The sample point is the outline centroid, which is
    /// interior for the convex outlines the picker produces.
    static func target(planar face: PlanarFace) -> Target? {
        guard !face.triangles.isEmpty, !face.outline.isEmpty else { return nil }
        let c = face.outline.reduce(SIMD2<Double>.zero, +) / Double(face.outline.count)
        return Target(
            triangles: face.triangles,
            samplePoint: face.origin + face.basisX * c.x + face.basisY * c.y,
            signature: SignatureNaming.signature(planar: face))
    }

    /// A cylindrical face — the wall of a hole, which is the whole point of
    /// this tool. The sample point steps OUT from the axis at mid-height, so
    /// it lands on the surface instead of inside the solid.
    static func target(cylindrical cyl: CylindricalFace) -> Target? {
        guard !cyl.triangles.isEmpty, cyl.radius > 1e-9 else { return nil }
        let axis = simd_normalize(cyl.axisDir)
        // Any unit vector perpendicular to the axis reaches the surface.
        let seed = abs(axis.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let radial = simd_normalize(simd_cross(axis, seed))
        let mid = (cyl.minT + cyl.maxT) / 2
        // `axisPoint` sits at an arbitrary axial position; re-anchor it to the
        // mid-height plane before stepping outward.
        let onAxis = cyl.axisPoint + axis * (mid - simd_dot(cyl.axisPoint, axis))
        return Target(
            triangles: cyl.triangles,
            samplePoint: onAxis + radial * cyl.radius,
            signature: SignatureNaming.signature(cylinder: cyl))
    }

    /// The face under a tap: a cylindrical wall wins over the coplanar sliver
    /// `planarFace` would return for it, because on a curved surface no two
    /// facets are coplanar and that sliver is never what the user meant.
    static func target(in mesh: RenderMesh, seedTriangle: Int) -> Target? {
        if let cyl = FaceTopology.cylindricalFace(in: mesh, seedTriangle: seedTriangle),
           let target = target(cylindrical: cyl) {
            return target
        }
        if let planar = FaceTopology.planarFace(in: mesh, seedTriangle: seedTriangle) {
            return target(planar: planar)
        }
        return nil
    }

}
