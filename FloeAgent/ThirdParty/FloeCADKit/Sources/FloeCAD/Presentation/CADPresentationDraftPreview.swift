//
//  CADPresentationDraftPreview.swift
//  FloeCADKit
//
//  Render-only sampling coordinates for an uncommitted material draft. The
//  applied stage already carries the UV set for the current appearance; a
//  draft may choose a different projection, scale, rotation, offset or the
//  mesh source. Rebuilding a small mesh from THIS function is the only way to
//  show that change before Apply.
//
//  This is not a second geometry or material store: positions, normals and
//  indices always come from the same `CADPresentationMesh` the stage was built
//  from, and the UV decision is the shared `MaterialUVProjector` rule.
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import Foundation
import simd

nonisolated enum CADPresentationDraftUV {
    /// Sampling coordinates the draft actually needs for one body mesh.
    ///
    /// * `.mesh` (or a nil mapping) samples the AUTHORED mesh UVs. It never
    ///   reuses `mesh.uvs`, because that array may already be an applied
    ///   projection from the current appearance.
    /// * An explicit planar/box projection runs the same `MaterialUVProjector`
    ///   decision the scene builder uses, including axis/scale/rotation/offset
    ///   and flips.
    /// * A missing input (no authored UVs, or malformed normals for a
    ///   projection) returns nil so the caller can report a real issue instead
    ///   of sampling garbage.
    ///
    /// The presentation mesh is stored in metres; the projector is defined in
    /// body-local millimetres. Convert a throwaway copy of the positions, never
    /// the resident buffers and never the mesh's authored coordinates.
    static func samplingUVs(for mesh: CADPresentationMesh,
                            mapping: CADMaterialUVMapping?) -> [SIMD2<Float>]? {
        let clean = mapping?.sanitized
        guard let clean, clean.source != .mesh else {
            guard let authored = mesh.authoredUVs,
                  authored.count == mesh.positions.count else { return nil }
            return authored
        }
        guard !mesh.positions.isEmpty, !mesh.normals.isEmpty,
              mesh.normals.count == mesh.positions.count,
              !mesh.indices.isEmpty, mesh.indices.count % 3 == 0 else {
            return nil
        }
        let positionsMM = mesh.positions.map {
            $0 * CADPresentationAxes.millimetresPerMeter
        }
        // `effectiveUVs` is the one shared source rule (explicit projection
        // wins over authored UVs). It never mutates either input.
        return MaterialUVProjector.effectiveUVs(
            meshTexcoords: mesh.authoredUVs,
            positions: positionsMM,
            normals: mesh.normals,
            indices: mesh.indices,
            mapping: clean)
    }
}
#endif
