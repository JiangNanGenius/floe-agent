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
//       OCCT is told which face to remove. Never the whole region's centroid: for
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
        var elementName: ElementName? = nil
        /// History edits keep the original operand when it is still valid;
        /// merely opening and accepting a pick must not remint its identity
        /// from an approximate tessellation.
        var sourceReference: FaceRef? = nil

        /// Two picks are the same face when they cover the same triangles —
        /// the same test the shell pick uses.
        static func == (lhs: Target, rhs: Target) -> Bool {
            Set(lhs.triangles) == Set(rhs.triangles)
        }
    }

    /// Replay and picking use the same interior surface-point helper as
    /// Shell. Outline centroids may lie in holes, and an arbitrary cylinder
    /// radial direction may lie on the missing half of a trimmed cylinder.
    static func target(resolved face: ResolvedFace, mesh: RenderMesh) -> Target? {
        guard !face.triangles.isEmpty,
              let point = FeatureGraph.pointOnFace(face, mesh: mesh) else { return nil }
        let signature: FaceSignature
        if let planar = face.planar {
            signature = SignatureNaming.signature(planar: planar)
        } else if let cylinder = face.cylinder {
            signature = SignatureNaming.signature(cylinder: cylinder)
        } else { return nil }
        return Target(triangles: face.triangles, samplePoint: point,
                      signature: signature, elementName: face.elementName)
    }

    /// The face under a tap: a cylindrical wall wins over the coplanar sliver
    /// `planarFace` would return for it, because on a curved surface no two
    /// facets are coplanar and that sliver is never what the user meant.
    static func target(in mesh: RenderMesh, seedTriangle: Int) -> Target? {
        if let cyl = FaceTopology.cylindricalFace(in: mesh, seedTriangle: seedTriangle),
           let target = target(resolved: ResolvedFace(cylinder: cyl, confidence: 1), mesh: mesh) {
            return target
        }
        if let planar = FaceTopology.planarFace(in: mesh, seedTriangle: seedTriangle) {
            return target(resolved: ResolvedFace(planar: planar, confidence: 1), mesh: mesh)
        }
        return nil
    }

}
