//
//  CADMaterialDraftPreview.swift
//  FloeCADKit
//
//  Transient material preview for the engineering viewport. The inspector
//  writes a draft here while the user drags sliders; Cancel clears it and
//  Apply replaces it with one real document command. There is no persistence
//  and no undo record on this path.
//

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation

/// One in-flight material draft. Value type so the viewport scene rebuild is
/// cheap and Equatable, and so it can be compared against `Body.material`
/// without copying image data.
nonisolated struct MaterialDraftPreview: Equatable {
    var bodyIDs: Set<BodyID>
    var faceBodyID: BodyID?
    /// Resolved 1-based kernel face index when the pick mapped exactly.
    var faceIndex: Int?
    /// Triangles of the picked face (nil for a whole-body target). Kept so a
    /// per-face renderer can highlight the exact picked region.
    var faceTriangles: [Int]?
    var spec: BodyMaterialSpec
}

@MainActor
extension EditorViewModel {
    /// Appearance used to draw `body`: the transient draft when that body is
    /// targeted, otherwise its applied snapshot.
    func materialSpec(for body: Body) -> BodyMaterialSpec? {
        if let preview = materialDraftPreview,
           preview.bodyIDs.contains(body.id),
           preview.faceBodyID == nil || preview.faceTriangles == nil {
            return preview.spec
        }
        return body.material
    }

    func renderMaterial(for body: Body) -> BodyMaterial? {
        materialSpec(for: body).map {
            BodyMaterial(spec: $0,
                         meshHasTexcoords: body.render.texcoords != nil,
                         revision: body.meshRevision)
        }
    }

    /// Set a whole-body draft preview for every target body.
    func setMaterialDraftPreview(_ spec: BodyMaterialSpec,
                                 bodyIDs: Set<BodyID>) {
        guard !bodyIDs.isEmpty else { return }
        materialDraftPreview = MaterialDraftPreview(
            bodyIDs: bodyIDs, faceBodyID: nil, faceIndex: nil,
            faceTriangles: nil, spec: spec.clamped)
    }

    /// Set a face-target draft. The picked face is recorded so a per-face
    /// renderer can use it; until then the viewport keeps the body's applied
    /// appearance and Present mode renders the draft.
    func setMaterialDraftPreview(_ spec: BodyMaterialSpec,
                                 faceBodyID: BodyID,
                                 faceIndex: Int?,
                                 faceTriangles: [Int]) {
        materialDraftPreview = MaterialDraftPreview(
            bodyIDs: [faceBodyID], faceBodyID: faceBodyID,
            faceIndex: faceIndex, faceTriangles: faceTriangles,
            spec: spec.clamped)
    }

    func clearMaterialDraftPreview() {
        materialDraftPreview = nil
    }
}
#endif
