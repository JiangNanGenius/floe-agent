//
//  FloeCADDocument+Scene.swift
//  FloeCADKit
//
//  Immutable, versioned scene snapshot for a presentation layer. It is built
//  from the SAME live FloeCADDocument (no copied geometry store), carries
//  resolved body/face material snapshots and the deduped image bytes, and is a
//  value type so a presentation actor can own it safely.
//
//  Units are millimetres, coordinates are right-handed +Y up. Mesh buffers are
//  body-local; `transform` is a column-major 4×4. A presentation never owns an
//  undo stack or an independent material list: it calls the document's
//  `applyViewAppearance` (one undoable command) and re-reads the snapshot.
//

import Foundation
import simd

nonisolated struct CADSceneMeshResource: Sendable, Equatable {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
    /// Mesh-authored UVs (nil when the source mesh has none).
    var texcoords: [SIMD2<Float>]?
    /// UVs a renderer should actually sample: an explicit material projection
    /// when chosen (even if the mesh has authored UVs), otherwise the mesh's
    /// own UVs. Never mutates the mesh.
    var renderTexcoords: [SIMD2<Float>]?
    var meshRevision: UInt64
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
}

nonisolated struct CADSceneFaceMaterial: Sendable, Equatable {
    var faceIndex: Int
    var material: BodyMaterialSpec
    var signature: FaceSignature
    /// Mesh index-buffer values for this face when the session has a
    /// trustworthy table for the body's current mesh revision (the applied
    /// rebuild's table, or one derived from the exact restored render). Nil
    /// means the snapshot has a saved face appearance but no trustworthy
    /// triangle range; a presentation must not guess one.
    var triangleIndices: [UInt32]?
    /// The same face as triangle ordinals into `mesh.indices` (0-based), for
    /// renderers that build their own index slices. Both are nil together.
    var triangleNumbers: [Int]?
}

nonisolated struct CADSceneUnresolvedFaceBinding: Sendable, Equatable {
    var bodyID: UUID
    var bodyName: String
    var materialName: String?
    var materialID: String?
    var reason: String
    var candidateIndices: [Int]
    var signature: FaceSignature
    var capturedIndex: Int?
}

nonisolated struct CADSceneBodyResource: Sendable, Equatable {
    var id: UUID
    var name: String
    var isHidden: Bool
    /// Column-major 4×4, model space (mm).
    var transform: [Double]
    var mesh: CADSceneMeshResource
    /// Body-level applied appearance (Metal-compatible legacy fields plus the
    /// custom-material extension).
    var material: BodyMaterialSpec?
    /// Face-level snapshots that still resolve on the current B-rep.
    var faceMaterials: [CADSceneFaceMaterial]
    /// Count of bindings that need explicit reassignment.
    var unresolvedFaceCount: Int
    var analyticBRep: Bool
    /// Definition identity for a placed assembly instance. Rendering uses id;
    /// material edits/previews remain attached to the source body.
    var sourceBodyID: UUID? = nil
}

nonisolated struct CADSceneImageResource: Sendable, Equatable {
    /// Content identity (SHA-256); stable across snapshots.
    var id: String
    var slot: MaterialTextureSlot
    var mimeType: String
    var bytes: Data
    var byteCount: Int
}

nonisolated struct CADSceneSnapshot: Sendable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var documentRevision: Int
    var changeCount: Int
    var contentSHA256: String
    var modelSHA256: String
    var unit: String
    var coordinateSystem: String
    var bodies: [CADSceneBodyResource]
    var materials: [CADMaterialDefinition]
    var images: [CADSceneImageResource]
    var appearance: CADViewAppearance
    var unresolvedFaceBindings: [CADSceneUnresolvedFaceBinding]
    /// X21 saved/selected camera state. Defaulted so historical snapshot
    /// fixtures that predate cameras keep constructing without a camera list.
    var cameras: CADSceneCameraSummary = .empty
    /// X22 persisted section cut + measurement guides. Defaulted so historical
    /// fixtures keep constructing without an overlay; `.empty` is the exact
    /// pre-X22 behavior (full model, no guides).
    var viewOverlay: CADViewOverlayState = .empty

    /// Bounded JSON description (no mesh/image bytes) for `query kind=scene`
    /// and capability replies.
    var summaryJSON: [String: Any] {
        [
            "schema_version": schemaVersion,
            "document_revision": documentRevision,
            "change_count": changeCount,
            "content_sha256": contentSHA256,
            "model_sha256": modelSHA256,
            "unit": unit,
            "coordinate_system": coordinateSystem,
            "body_count": bodies.count,
            "triangle_count": bodies.reduce(0) { $0 + $1.mesh.indices.count / 3 },
            "material_count": materials.count,
            "image_count": images.count,
            "unresolved_face_bindings": unresolvedFaceBindings.count,
            "appearance": [
                "active_environment": appearance.activeEnvironment.rawValue,
                "floor_visible": appearance.floorVisible,
                "floor_size_mm": appearance.floorSizeMM,
                "shadows": appearance.shadowsEnabled,
            ],
            "cameras": cameras.summaryJSON,
            "view_overlay": viewOverlay.summaryJSON,
        ]
    }
}

@MainActor
extension FloeCADDocument {
    /// Schema version of `sceneSnapshot()` (public so the app host can
    /// advertise it without exposing the internal value types).
    public static var sceneSnapshotSchemaVersion: Int { CADSceneSnapshot.currentSchemaVersion }

    /// Bounded public summary of the live scene (no mesh/image bytes) for the
    /// native `snapshot`/`query kind=scene` replies. A previewed exploded view
    /// is reported explicitly so a caller can tell transient display offsets
    /// from the saved assembly placements.
    public func sceneSummaryJSON() -> [String: Any] {
        var summary = sceneSnapshot().summaryJSON
        guard let preview = CADExplodedViewPreview.current(for: session) else {
            return summary
        }
        let assembly = (try? CADAssembly.decode(from: session.document.assemblyData))
            ?? CADAssembly()
        guard let viewID = preview.resolvedViewID(in: assembly) else { return summary }
        summary["exploded_preview"] = [
            "id": viewID.uuidString,
            "name": preview.viewName ?? assembly.explodedView(viewID)?.name ?? "",
            "transient": true,
            "base_transforms_unchanged": true,
        ]
        return summary
    }
    /// The current appearance (persisted three-environment settings, or the
    /// mapped legacy lighting/background, or the default).
    var viewAppearance: CADViewAppearance {
        let settings = session.document.sceneSettingsData.flatMap {
            try? JSONDecoder().decode(CADSceneSettings.self, from: $0)
        }
        return CADViewAppearance.current(for: settings)
    }

    /// Replace the appearance as ONE undoable document command. Presentation
    /// must re-read `sceneSnapshot()` afterwards; it must not cache a parallel
    /// appearance store. Callers that need durability use the normal save
    /// action (the AI material/parameter bridge commits after each mutation).
    @discardableResult
    func applyViewAppearance(_ appearance: CADViewAppearance) -> Bool {
        let appearance = appearance.sanitized
        // Equality is semantic: JSON key order is not a new user edit, and
        // selecting the already active look must not add an empty undo step.
        guard !isClosed, session.writeBlock == nil, appearance != viewAppearance else { return false }
        let before = session.document.sceneSettingsData
        var settings = before.flatMap {
            try? JSONDecoder().decode(CADSceneSettings.self, from: $0)
        } ?? CADSceneSettings()
        settings.presentation = appearance
        guard let after = try? JSONEncoder().encode(settings), after != before else {
            return false
        }
        session.perform(SetSceneSettingsDataCommand(before: before, after: after))
        return true
    }

    /// Immutable value snapshot from the live document. CoW mesh arrays make
    /// this cheap until a mesh actually changes.
    ///
    /// `includeExplodedPreview` defaults to true so a live viewport/presentation
    /// shows the document's transient exploded preview exactly like the
    /// engineering viewport. Offscreen artifact producers (animation frame
    /// export, GLB-style captures) must pass false: a display-only preview must
    /// never be baked into an exported baseline. The saved assembly data is
    /// never modified either way.
    func sceneSnapshot(includeExplodedPreview: Bool = true) -> CADSceneSnapshot {
        var bodies: [CADSceneBodyResource] = []
        var unresolved: [CADSceneUnresolvedFaceBinding] = []
        var images: [String: CADSceneImageResource] = [:]

        func addImage(_ data: Data?, slot: MaterialTextureSlot) {
            guard let data, !data.isEmpty,
                  let mime = MaterialImageSniffer.mimeType(of: data) else { return }
            let sha = CADMaterialTexture.digest(data)
            if images[sha] == nil {
                images[sha] = CADSceneImageResource(id: sha, slot: slot,
                                                    mimeType: mime, bytes: data,
                                                    byteCount: data.count)
            }
        }

        func addImages(from spec: BodyMaterialSpec?) {
            guard let spec else { return }
            for slot in MaterialTextureSlot.allCases {
                addImage(spec.textureData(for: slot), slot: slot)
            }
        }

        for body in session.document.bodies {
            let m = body.transform.matrix
            let transform = [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                             m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                             m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                             m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
            let aabb = body.render.localAABB
            let faceTable = session.faceRangeTable(for: body)
            let resolved = CADFaceMaterialResolver.resolve(body.materialFaceBindings, in: body, table: faceTable)
            let assessment = CADFaceMaterialResolver.assessGroups(in: body, table: faceTable,
                                                                 tableRevision: body.meshRevision)
            let rangeByIndex = Dictionary(uniqueKeysWithValues: assessment.groups.map { ($0.faceIndex, $0) })
            var usedFaceRanges: Set<Int> = []
            var unresolvedFaceCount = 0
            var faceMaterials: [CADSceneFaceMaterial] = []
            for entry in resolved {
                guard let index = entry.resolvedIndex else {
                    unresolvedFaceCount += 1
                    var candidates: [Int] = []
                    if case .ambiguous(let indices) = entry.match { candidates = indices }
                    let reason: String
                    switch entry.match {
                    case .unresolved(let text): reason = text
                    case .ambiguous: reason = "The stored face signature matches more than one current face."
                    case .resolved: reason = ""
                    }
                    unresolved.append(CADSceneUnresolvedFaceBinding(
                        bodyID: body.id.raw, bodyName: body.name,
                        materialName: entry.binding.material.materialName,
                        materialID: entry.binding.material.materialID,
                        reason: reason, candidateIndices: candidates,
                        signature: entry.binding.key.signature,
                        capturedIndex: entry.binding.key.capturedIndex))
                    continue
                }
                var triangleIndices: [UInt32]?
                var triangleNumbers: [Int]?
                if let group = rangeByIndex[index], !usedFaceRanges.contains(index),
                   group.material == entry.binding.material.clamped {
                    usedFaceRanges.insert(index)
                    var indices: [UInt32] = []
                    indices.reserveCapacity(group.triangles.count * 3)
                    for triangle in group.triangles {
                        let base = triangle * 3
                        indices.append(contentsOf: body.render.indices[base..<(base + 3)])
                    }
                    triangleIndices = indices
                    triangleNumbers = group.triangles
                } else {
                    unresolvedFaceCount += 1
                    unresolved.append(CADSceneUnresolvedFaceBinding(
                        bodyID: body.id.raw, bodyName: body.name,
                        materialName: entry.binding.material.materialName,
                        materialID: entry.binding.material.materialID,
                        reason: "face_triangle_map_unavailable", candidateIndices: [index],
                        signature: entry.binding.key.signature,
                        capturedIndex: entry.binding.key.capturedIndex))
                }
                faceMaterials.append(CADSceneFaceMaterial(
                    faceIndex: index, material: entry.binding.material.clamped,
                    signature: entry.binding.key.signature,
                    triangleIndices: triangleIndices,
                    triangleNumbers: triangleNumbers))
                addImages(from: entry.binding.material)
            }
            addImages(from: body.material)
            let mesh = CADSceneMeshResource(
                positions: body.render.positions,
                normals: body.render.normals,
                indices: body.render.indices,
                texcoords: body.render.texcoords,
                renderTexcoords: MaterialUVProjector.renderUVs(for: body,
                                                               material: body.material),
                meshRevision: body.meshRevision,
                boundsMin: aabb.min,
                boundsMax: aabb.max)
            bodies.append(CADSceneBodyResource(
                id: body.id.raw, name: body.name, isHidden: body.isHidden,
                transform: transform, mesh: mesh, material: body.material,
                faceMaterials: faceMaterials,
                unresolvedFaceCount: unresolvedFaceCount,
                analyticBRep: body.brep != nil))
        }

        // Match the engineering viewport: assembly placements share the
        // source mesh/material snapshot, with independent entity identity and
        // composed world placement. A hidden definition may still have a
        // visible instance, so copy it before filtering hidden renderables.
        let explodedPreview = includeExplodedPreview
            ? CADExplodedViewPreview.current(for: session) : nil
        if let assembly = try? CADAssembly.decode(from: session.document.assemblyData) {
            let definitions = Dictionary(uniqueKeysWithValues: bodies.map { ($0.id, $0) })
            let sourceBodies = Dictionary(uniqueKeysWithValues: session.document.bodies.map { ($0.id.raw, $0) })
            var placedIDs = Set(bodies.map(\.id))
            let viewID = explodedPreview?.resolvedViewID(in: assembly)
            // Resolve the persisted instance tree (including nested
            // subassemblies and staged external references). A container has
            // no geometry of its own; its children are emitted with composed
            // world placements. The transient preview's offset is applied at
            // the level where it is authored, so moving a parent carries its
            // subtree and the stored base transforms are never rewritten.
            for occurrence in assembly.occurrences(viewID: viewID, includeHidden: false) {
                guard occurrence.subassemblyID == nil,
                      let sourceID = occurrence.effectiveBodyID,
                      var placed = definitions[sourceID],
                      let source = sourceBodies[sourceID],
                      placedIDs.insert(occurrence.instance.id).inserted else { continue }
                let placement = occurrence.explodedWorldTransform ?? occurrence.worldTransform
                guard placement.isPlaceable else { continue }
                let m = placement.placement3D().composed(onto: source.transform).matrix
                placed.id = occurrence.instance.id
                placed.sourceBodyID = sourceID
                placed.name = occurrence.instance.name
                placed.isHidden = false
                placed.transform = [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                                    m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                                    m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                                    m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
                bodies.append(placed)
            }
        }

        let library = CADMaterialLibraryCodec.decode(session.document.materialLibraryData)
        for entry in library.entries {
            for texture in entry.textures {
                addImage(texture.bytes, slot: texture.slot)
            }
        }

        let cameraState = savedCameraState()
        return CADSceneSnapshot(
            schemaVersion: CADSceneSnapshot.currentSchemaVersion,
            documentRevision: revision,
            changeCount: session.changeCount,
            contentSHA256: contentSHA256,
            modelSHA256: session.savedIdentity.modelSHA256,
            unit: "mm",
            coordinateSystem: "right-handed-y-up-mm",
            bodies: bodies,
            materials: library.entries,
            images: images.values.sorted { $0.id < $1.id },
            appearance: viewAppearance,
            unresolvedFaceBindings: unresolved,
            cameras: CADSceneCameraSummary(active: cameraState.active,
                                           saved: cameraState.saved),
            viewOverlay: CADViewOverlayCodec.decode(session.document.sceneSettingsData))
    }
}
