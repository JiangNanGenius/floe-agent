//
//  CADFaceMaterialRenderGroups.swift
//  FloeCADKit
//
//  Per-face material ranges for the engineering viewport.
//
//  The document keeps the authoritative face→triangle table in the session
//  (`faceRangeTable(for:)`, the same source the scene snapshot and exporters
//  use). That table is the applied rebuild's own table when its revision is
//  current, otherwise one derived from the body's exact restored render. A
//  binding uses the same named/exact native-face assessment as both writers.
//  A display patch may span multiple coplanar native faces; each material
//  claims only its own native triangles, never the majority patch's range.
//

#if canImport(UIKit)
import Foundation

@MainActor
extension EditorViewModel {
    func faceRenderGroups(for body: Body) -> [BodyFaceMaterial] {
        guard !body.materialFaceBindings.isEmpty, !body.render.indices.isEmpty else {
            return []
        }
        guard let table = session.faceRangeTable(for: body) else {
            return []
        }
        let preview = materialDraftPreview
        var groups: [BodyFaceMaterial] = []
        let assessment = CADFaceMaterialResolver.assessGroups(in: body, table: table,
                                                              tableRevision: body.meshRevision)
        for group in assessment.groups {
            var spec = group.material
            if let preview, preview.faceBodyID == nil,
               preview.bodyIDs.contains(body.id) {
                // A body-level draft replaces the whole body appearance, which
                // on Apply clears its face bindings.
                spec = preview.spec
            } else if let preview, preview.faceBodyID == body.id,
                      let picked = preview.faceTriangles {
                let pickedTriangles = Set(picked)
                if group.triangles.allSatisfy({ pickedTriangles.contains($0) }) {
                    spec = preview.spec
                }
            }
            groups.append(BodyFaceMaterial(
                faceIndex: group.faceIndex,
                triangles: group.triangles,
                material: BodyMaterial(
                    spec: spec,
                    meshHasTexcoords: body.render.texcoords != nil,
                    revision: body.meshRevision)))
        }
        return groups
    }

}
#endif
