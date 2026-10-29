//
//  CADFaceMaterialRenderGroups.swift
//  FloeCADKit
//
//  Per-face material ranges for the engineering viewport.
//
//  The document keeps the authoritative face→triangle table in the session
//  (`lastFaceTables` + `lastNamingRevisions`, the same source the scene
//  snapshot uses). A binding is rendered only when that table is valid for the
//  body's current mesh revision and exactly one table entry matches above the
//  stable-binding threshold/margin. Otherwise the face material stays saved but
//  is not painted on a guessed range.
//

#if canImport(UIKit)
import Foundation

@MainActor
extension EditorViewModel {
    func faceRenderGroups(for body: Body) -> [BodyFaceMaterial] {
        guard !body.materialFaceBindings.isEmpty, !body.render.indices.isEmpty else {
            return []
        }
        guard let table = session.lastFaceTables[body.id],
              session.lastNamingRevisions[body.id] == body.meshRevision else {
            return []
        }
        var usedEntries = Set<Int>()
        let preview = materialDraftPreview
        var groups: [BodyFaceMaterial] = []
        for binding in body.materialFaceBindings {
            var scored: [(index: Int, score: Double, triangles: [Int])] = []
            for (index, entry) in table.entries.enumerated() {
                guard let score = CADFaceMaterialResolver.score(
                    binding.key.signature, entry.signature) else { continue }
                scored.append((index, score, entry.triangles))
            }
            scored.sort { $0.score > $1.score }
            guard let best = scored.first,
                  best.score >= CADFaceMaterialResolver.matchThreshold,
                  (scored.count == 1
                    || best.score - scored[1].score
                        >= CADFaceMaterialResolver.ambiguityMargin),
                  !usedEntries.contains(best.index),
                  !best.triangles.isEmpty else { continue }
            usedEntries.insert(best.index)
            var spec = binding.material
            if let preview, preview.faceBodyID == nil,
               preview.bodyIDs.contains(body.id) {
                // A body-level draft replaces the whole body appearance, which
                // on Apply clears its face bindings.
                spec = preview.spec
            } else if let preview, preview.faceBodyID == body.id,
                      let picked = preview.faceTriangles {
                let pickedTriangles = Set(picked)
                if best.triangles.allSatisfy({ pickedTriangles.contains($0) }) {
                    spec = preview.spec
                }
            }
            groups.append(BodyFaceMaterial(
                faceIndex: binding.key.capturedIndex ?? (best.index + 1),
                triangles: best.triangles,
                material: BodyMaterial(
                    spec: spec,
                    meshHasTexcoords: body.render.texcoords != nil,
                    revision: body.meshRevision)))
        }
        return groups
    }

}
#endif
