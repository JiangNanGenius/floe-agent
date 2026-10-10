//
//  ReplaceFaceKit.swift
//  openshape3d
//
//  Spec §4.12 Replace Face — extend or trim selected face(s) until they lie on
//  another face's surface, with Flip Alignment choosing which side to extend to.
//
//  For a planar face moving to a parallel plane, both directions are the SAME
//  operation on the same solid: the prism swept by the face's own outline
//  between the two planes. Extending fuses that prism onto the body; trimming
//  cuts it out. Working out which, and by how much, is all this kit does — the
//  boolean itself is `KernelOps`.
//
//  Non-parallel targets are refused rather than approximated: the gap between
//  the planes varies across the face, so a single prism would be wrong
//  everywhere except one line, and silently shipping that is worse than saying
//  no.
//

import Foundation
import simd
import Euclid

nonisolated enum ReplaceFaceKit {

    /// What replacing a face resolves to.
    nonisolated enum Plan: Equatable, Sendable {
        /// The target lies OUTSIDE the body past this face: grow by `distance`.
        case extend(distance: Double)
        /// The target lies inside: cut `distance` of material away.
        case trim(distance: Double)

        var distance: Double {
            switch self {
            case let .extend(d), let .trim(d): d
            }
        }
    }

    nonisolated enum Refusal: Error, Equatable, Sendable {
        /// The planes are not parallel, so no single prism describes the change.
        case targetNotParallel
        /// The target plane passes through the face itself, or coincides with it.
        case noChange
        case degenerateFace
    }

    /// Which way to move the face when the target plane is ambiguous — the
    /// spec's Flip Alignment toggle.
    static let parallelTolerance: Double = 1e-6

    // MARK: - Planning

    /// Resolve the replace into a direction and distance.
    ///
    /// `targetOrigin`/`targetNormal` describe the replacing face's plane.
    /// `flip` extends to the other side, which is what the spec's Flip
    /// Alignment does when both readings are geometrically valid.
    static func plan(
        face: PlanarFace, targetOrigin: SIMD3<Double>, targetNormal: SIMD3<Double>,
        flip: Bool = false
    ) throws -> Plan {
        guard !face.outline.isEmpty else { throw Refusal.degenerateFace }
        let normal = simd_normalize(SIMD3<Double>(
            Double(face.normal.x), Double(face.normal.y), Double(face.normal.z)))
        let target = simd_normalize(targetNormal)
        guard abs(abs(simd_dot(normal, target)) - 1) < parallelTolerance else {
            throw Refusal.targetNotParallel
        }

        // Signed gap along the FACE's outward normal: positive means the target
        // sits outside the body past this face.
        let signed = simd_dot(targetOrigin - face.origin, normal)
        guard abs(signed) > 1e-9 else { throw Refusal.noChange }

        let effective = flip ? -signed : signed
        return effective > 0 ? .extend(distance: effective) : .trim(distance: -effective)
    }

    // MARK: - The solid

    /// The prism swept by the face's outline between the old and new planes —
    /// the material that is added (extend) or removed (trim).
    ///
    /// Holes in the face are carried through, so replacing the top of a drilled
    /// boss does not fill its hole in.
    static func sweptSolid(face: PlanarFace, plan: Plan) -> Euclid.Mesh? {
        guard face.outline.count >= 3, plan.distance > 1e-9 else { return nil }
        let plane = SketchPlane(
            origin: face.origin, xAxis: face.basisX, yAxis: face.basisY)

        // The face's basis may be left-handed relative to its outward normal;
        // extruding along +z of that basis would then go INTO the body. Sign the
        // distance so the prism always spans face → target.
        let basisNormal = simd_cross(face.basisX, face.basisY)
        let outward = SIMD3<Double>(
            Double(face.normal.x), Double(face.normal.y), Double(face.normal.z))
        let sign: Double = simd_dot(basisNormal, outward) >= 0 ? 1 : -1
        // Trimming sweeps INWARD from the face; extending sweeps outward.
        let direction: Double = {
            switch plan {
            case .extend: 1
            case .trim: -1
            }
        }()

        return KernelOps.extrude(
            profile: Profile(loop: face.outline, kind: .polygonal, sourceEntityIDs: []),
            holes: face.holes.map {
                Profile(loop: $0, kind: .polygonal, sourceEntityIDs: [])
            },
            in: plane,
            distance: plan.distance * sign * direction)
    }

    /// Apply the replace to a body's mesh: fuse the prism for an extend, cut it
    /// for a trim. Nil when the prism is degenerate.
    static func apply(
        to mesh: Euclid.Mesh, face: PlanarFace, plan: Plan
    ) -> Euclid.Mesh? {
        guard let prism = sweptSolid(face: face, plan: plan),
              !prism.polygons.isEmpty else { return nil }
        switch plan {
        case .extend: return mesh.union(prism).makeWatertight()
        case .trim: return mesh.subtracting(prism).makeWatertight()
        }
    }

    // MARK: - The analytic path

    /// How far the prism reaches in the face's own plane-local z, signed the
    /// same way `sweptSolid` signs its Euclid extrude. Shared so the two paths
    /// cannot disagree about which side of the face the material goes.
    static func sweptZRange(face: PlanarFace, plan: Plan) -> (zMin: Double, zMax: Double) {
        let basisNormal = simd_cross(face.basisX, face.basisY)
        let outward = SIMD3<Double>(
            Double(face.normal.x), Double(face.normal.y), Double(face.normal.z))
        let sign: Double = simd_dot(basisNormal, outward) >= 0 ? 1 : -1
        let direction: Double = {
            switch plan {
            case .extend: 1
            case .trim: -1
            }
        }()
        let d = plan.distance * sign * direction
        return (min(0, d), max(0, d))
    }

    /// The swept prism as an OCCT solid.
    ///
    /// Without this a replace on an analytic body would run through the Euclid
    /// booleans above and hand back a body with no `brep` — the exact silent
    /// degradation the 2026-08-25 review called out (C4): the geometry still
    /// LOOKS right, and then the next save writes the tessellation as if it
    /// were the truth. Nil when OCCT cannot build it; callers fall back to the
    /// mesh path, which is honest for a body that was never analytic anyway.
    static func sweptBRep(face: PlanarFace, plan: Plan) -> BRepHandle? {
        guard face.outline.count >= 3, plan.distance > 1e-9 else { return nil }
        let z = sweptZRange(face: face, plan: plan)
        return OCCTKernel.extrudeShape(
            outerLoop: face.outline,
            holes: OCCTKernel.polylineHoles(face.holes),
            zMin: z.zMin, zMax: z.zMax,
            origin: face.origin, xAxis: face.basisX,
            yAxis: face.basisY,
            normal: simd_cross(face.basisX, face.basisY))
    }

    /// Apply the replace analytically: fuse for an extend, cut for a trim,
    /// staying in OCCT so curved neighbours keep their exact surfaces.
    static func applyBRep(
        to handle: BRepHandle, face: PlanarFace, plan: Plan
    ) -> BRepHandle? {
        applyBRepWithAncestry(to: handle, face: face, plan: plan)?.handle
    }

    /// Replace-face is a boolean with a prism (union to extend, subtract to
    /// trim), so it carries the SAME ancestry a boolean does — input ordinal 0
    /// is the body, 1 the prism — which lets the caller compose element names
    /// through it (the body's surviving faces keep their identities; the moved
    /// face and any new walls, descending only from the ephemeral unnamed
    /// prism, mint fresh). The bridge boolean already unifies WITH history
    /// (collapsing the coplanar seam the prism leaves on the replaced face),
    /// so the ancestry is over the final unified shape and no extra unify hop
    /// is needed — a second one would only desync the face indices the
    /// ancestry references.
    static func applyBRepWithAncestry(
        to handle: BRepHandle, face: PlanarFace, plan: Plan
    ) -> (handle: BRepHandle, ancestry: ShapeAncestry)? {
        guard let prism = sweptBRep(face: face, plan: plan) else { return nil }
        switch OCCTKernel.booleanResultWithAncestry(
            handle, prism, op: plan.isExtend ? 0 : 1) {
        case let .success((outcome, ancestry)):
            return (outcome.handle, ancestry)
        case .failure:
            return nil
        }
    }
}

nonisolated extension ReplaceFaceKit.Plan {
    var isExtend: Bool {
        if case .extend = self { return true }
        return false
    }
}
