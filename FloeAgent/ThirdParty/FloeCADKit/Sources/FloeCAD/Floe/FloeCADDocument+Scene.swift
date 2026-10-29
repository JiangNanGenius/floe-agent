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
    /// UVs a renderer should actually sample: mesh UVs when present, else the
    /// material's deterministic projection. Never mutates the mesh.
    var renderTexcoords: [SIMD2<Float>]?
    var meshRevision: UInt64
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>
}

nonisolated struct CADSceneFaceMaterial: Sendable, Equatable {
    var faceIndex: Int
    var material: BodyMaterialSpec
    var signature: FaceSignature
    /// Mesh index-buffer values for this face when the feature graph's face
    /// table is still valid for the body's current mesh revision. Nil means
    /// the snapshot has a saved face appearance but no trustworthy triangle
    /// range; a presentation must not guess one.
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
        ]
    }
}

@MainActor
extension FloeCADDocument {
    /// Schema version of `sceneSnapshot()` (public so the app host can
    /// advertise it without exposing the internal value types).
    public static var sceneSnapshotSchemaVersion: Int { CADSceneSnapshot.currentSchemaVersion }

    /// Bounded public summary of the live scene (no mesh/image bytes) for the
    /// native `snapshot`/`query kind=scene` replies.
    public func sceneSummaryJSON() -> [String: Any] {
        sceneSnapshot().summaryJSON
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
        let before = session.document.sceneSettingsData
        var settings = before.flatMap {
            try? JSONDecoder().decode(CADSceneSettings.self, from: $0)
        } ?? CADSceneSettings()
        settings.presentation = appearance.sanitized
        guard let after = try? JSONEncoder().encode(settings), after != before else {
            return false
        }
        session.perform(SetSceneSettingsDataCommand(before: before, after: after))
        return true
    }

    /// Immutable value snapshot from the live document. CoW mesh arrays make
    /// this cheap until a mesh actually changes.
    func sceneSnapshot() -> CADSceneSnapshot {
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
            let resolved = CADFaceMaterialResolver.resolve(body.materialFaceBindings, in: body)
            var faceMaterials: [CADSceneFaceMaterial] = []
            for entry in resolved {
                guard let index = entry.resolvedIndex else {
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
                if let table = session.lastFaceTables[body.id],
                   session.lastNamingRevisions[body.id] == body.meshRevision {
                    var scored: [(score: Double, triangles: [Int])] = []
                    for tableEntry in table.entries {
                        guard let score = CADFaceMaterialResolver.score(
                            entry.binding.key.signature, tableEntry.signature) else { continue }
                        scored.append((score, tableEntry.triangles))
                    }
                    scored.sort { $0.score > $1.score }
                    // Same stable-binding ambiguity rule as the B-rep resolver:
                    // a runner-up within the margin means NO triangle range is
                    // trustworthy. Nil makes the presentation keep the saved
                    // face material in the inspector but never paint a guessed
                    // face.
                    let unambiguous = scored.first.map { best in
                        best.score >= CADFaceMaterialResolver.matchThreshold
                            && (scored.count == 1
                                || best.score - scored[1].score
                                    >= CADFaceMaterialResolver.ambiguityMargin)
                    } ?? false
                    if unambiguous, let best = scored.first {
                        var indices: [UInt32] = []
                        indices.reserveCapacity(best.triangles.count * 3)
                        for triangle in best.triangles {
                            let base = triangle * 3
                            guard base + 2 < body.render.indices.count else { continue }
                            indices.append(body.render.indices[base])
                            indices.append(body.render.indices[base + 1])
                            indices.append(body.render.indices[base + 2])
                        }
                        triangleIndices = indices.isEmpty ? nil : indices
                        triangleNumbers = indices.isEmpty ? nil : best.triangles
                    }
                }
                faceMaterials.append(CADSceneFaceMaterial(
                    faceIndex: index, material: entry.binding.material,
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
                unresolvedFaceCount: resolved.filter { $0.resolvedIndex == nil }.count,
                analyticBRep: body.brep != nil))
        }

        // Match the engineering viewport: assembly placements share the
        // source mesh/material snapshot, with independent entity identity and
        // composed world placement. A hidden definition may still have a
        // visible instance, so copy it before filtering hidden renderables.
        if let assembly = try? CADAssembly.decode(from: session.document.assemblyData) {
            let definitions = Dictionary(uniqueKeysWithValues: bodies.map { ($0.id, $0) })
            let sourceBodies = Dictionary(uniqueKeysWithValues: session.document.bodies.map { ($0.id.raw, $0) })
            var placedIDs = Set(bodies.map(\.id))
            for instance in assembly.instances where !instance.isHidden {
                let sourceID = instance.copiedBodyID ?? instance.bodyID
                guard var placed = definitions[sourceID], let source = sourceBodies[sourceID],
                      instance.transform.isPlaceable, placedIDs.insert(instance.id).inserted else { continue }
                let m = instance.transform.placement3D().composed(onto: source.transform).matrix
                placed.id = instance.id
                placed.sourceBodyID = sourceID
                placed.name = instance.name
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

        return CADSceneSnapshot(
            schemaVersion: CADSceneSnapshot.currentSchemaVersion,
            documentRevision: revision,
            changeCount: session.changeCount,
            contentSHA256: contentSHA256,
            modelSHA256: store.modelSHA256,
            unit: "mm",
            coordinateSystem: "right-handed-y-up-mm",
            bodies: bodies,
            materials: library.entries,
            images: images.values.sorted { $0.id < $1.id },
            appearance: viewAppearance,
            unresolvedFaceBindings: unresolved)
    }
}
