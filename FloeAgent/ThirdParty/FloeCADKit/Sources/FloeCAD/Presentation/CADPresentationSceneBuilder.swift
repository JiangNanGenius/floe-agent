//
//  CADPresentationSceneBuilder.swift
//  FloeCADKit
//
//  Converts one immutable `CADSceneSnapshot` into renderer-neutral presentation
//  values. This file never reads a second document, never mutates geometry and
//  never derives an independent material list: every appearance comes from the
//  applied `BodyMaterialSpec` snapshot that the document already stores.
//
//  Projection UVs are generated for rendering only (`MaterialUVProjector`), so
//  changing mapping cannot change the B-rep or the persisted mesh.
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import Foundation
import simd

// MARK: - Resolved appearance

nonisolated struct CADPresentationResolvedMaterial {
    var material: CADPresentationMaterial
    var images: [CADPresentationImage]
    var issues: [CADPresentationIssue]

    static let neutral = CADPresentationResolvedMaterial(
        material: .neutral, images: [], issues: [])
}

nonisolated enum CADPresentationMaterialResolver {
    /// Turn one applied snapshot into presentation values. A corrupt or
    /// oversized image is DROPPED with a reported issue; the remaining
    /// scalars still shade the body, so appearance data can never remove
    /// geometry.
    static func resolve(spec: BodyMaterialSpec?,
                        bodyID: UUID?,
                        bodyName: String?,
                        hasMeshUVs: Bool,
                        hasProjectedUVs: Bool) -> CADPresentationResolvedMaterial {
        guard let rawSpec = spec else { return .neutral }
        let clean = rawSpec.clamped
        var issues: [CADPresentationIssue] = []
        var images: [CADPresentationImage] = []
        var textures: [CADPresentationTexture] = []

        let metadata = clean.textureMetadata ?? []
        for slot in MaterialTextureSlot.allCases {
            guard let data = clean.textureData(for: slot), !data.isEmpty else {
                // Metadata without bytes means the appearance predates the
                // encoded map or the record was truncated. Say so rather than
                // pretending the slot is painted.
                if metadata.contains(where: { $0.slot == slot }) {
                    issues.append(CADPresentationIssue(
                        id: "missing-\(slot.rawValue)-\(bodyID?.uuidString ?? "scene")",
                        kind: .missingTexture,
                        bodyID: bodyID,
                        bodyName: bodyName,
                        detail: "The \(slot.rawValue) texture record has no image bytes."))
                }
                continue
            }
            guard data.count <= CADMaterialLimits.maximumTextureBytes,
                  MaterialImageSniffer.mimeType(of: data) != nil else {
                issues.append(CADPresentationIssue(
                    id: "corrupt-\(slot.rawValue)-\(bodyID?.uuidString ?? "scene")",
                    kind: .corruptMaterial,
                    bodyID: bodyID,
                    bodyName: bodyName,
                    detail: "The \(slot.rawValue) texture is not a bounded PNG/JPEG and was ignored."))
                continue
            }
            let digest = CADMaterialTexture.digest(data)
            let typed = metadata.first { $0.slot == slot }
            let colorSpace = typed?.colorSpace
                ?? (slot == .baseColor || slot == .emissive ? .srgb : .linear)
            let orientation = typed?.orientation ?? .topLeft
            textures.append(CADPresentationTexture(
                slot: slot,
                imageID: digest,
                colorSpace: colorSpace,
                orientation: orientation,
                byteCount: data.count))
            if !images.contains(where: { $0.id == digest }) {
                images.append(CADPresentationImage(
                    id: digest,
                    mimeType: MaterialImageSniffer.mimeType(of: data) ?? "application/octet-stream",
                    bytes: data,
                    byteCount: data.count))
            }
        }

        let mapping = clean.uvMapping ?? .mesh
        if !textures.isEmpty {
            if mapping.source == .mesh && !hasMeshUVs && !hasProjectedUVs {
                issues.append(CADPresentationIssue(
                    id: "uv-missing-\(bodyID?.uuidString ?? "scene")",
                    kind: .missingMeshUV,
                    bodyID: bodyID,
                    bodyName: bodyName,
                    detail: "The assigned textures need UVs but this body has none and the material uses the mesh UV source. Choose a planar or box mapping."))
            }
            let orientations = Set(textures.map(\.orientation))
            if orientations.count > 1 {
                issues.append(CADPresentationIssue(
                    id: "uv-orientation-\(bodyID?.uuidString ?? "scene")",
                    kind: .mixedTextureOrientation,
                    bodyID: bodyID,
                    bodyName: bodyName,
                    detail: "Texture maps use different vertical orientations; the colour map's orientation is applied to the shared UV set."))
            }
        }

        let material = CADPresentationMaterial(
            name: clean.materialName,
            libraryID: clean.materialID,
            baseColor: SIMD4(Float(clean.baseColor.x), Float(clean.baseColor.y),
                             Float(clean.baseColor.z), Float(clean.effectiveOpacity)),
            metallic: Float(clean.metallic),
            roughness: Float(clean.roughness),
            opacity: Float(clean.effectiveOpacity),
            emissive: clean.emissive.map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) } ?? .zero,
            emissiveStrength: Float(clean.emissiveStrength ?? 0),
            textures: textures,
            uvMapping: mapping)
        return CADPresentationResolvedMaterial(material: material, images: images, issues: issues)
    }
}

// MARK: - Builder

@MainActor
enum CADPresentationSceneBuilder {
    static func build(snapshot: CADSceneSnapshot,
                      documentKey: String) -> CADPresentationScene {
        var bodies: [CADPresentationBody] = []
        var issues: [CADPresentationIssue] = []
        var imagesByID: [String: CADPresentationImage] = [:]
        var bounds: CADPresentationBounds?
        var triangleBudget = CADPresentationLimits.maximumTrianglesPerScene

        for (index, body) in snapshot.bodies.enumerated() {
            guard index < CADPresentationLimits.maximumBodies else {
                issues.append(CADPresentationIssue(
                    id: "body-limit", kind: .emptyBody, bodyID: body.id,
                    bodyName: body.name,
                    detail: "This scene exceeds the presentation body limit; extra bodies are omitted."))
                break
            }
            if body.isHidden { continue }
            guard let transform = CADPresentationAxes.matrix(body.transform) else {
                issues.append(CADPresentationIssue(
                    id: "xf-\(body.id.uuidString)", kind: .malformedTransform,
                    bodyID: body.id, bodyName: body.name,
                    detail: "The body transform is not a finite 4×4 matrix and was skipped."))
                continue
            }
            let mesh = body.mesh
            guard !mesh.positions.isEmpty, !mesh.normals.isEmpty,
                  !mesh.indices.isEmpty, mesh.indices.count % 3 == 0 else {
                issues.append(CADPresentationIssue(
                    id: "empty-\(body.id.uuidString)", kind: .emptyBody,
                    bodyID: body.id, bodyName: body.name,
                    detail: "The body has no drawable triangles; its model data is unchanged."))
                continue
            }
            guard mesh.indices.count / 3 <= triangleBudget else {
                issues.append(CADPresentationIssue(
                    id: "budget-\(body.id.uuidString)", kind: .emptyBody,
                    bodyID: body.id, bodyName: body.name,
                    detail: "This scene exceeds the presentation triangle budget; extra bodies are omitted."))
                break
            }
            triangleBudget -= mesh.indices.count / 3

            // The snapshot already resolves projected UVs for the body-level
            // material; fall back to the mesh's own set when no texture asks
            // for a projection.
            var uvs = mesh.renderTexcoords ?? mesh.texcoords
            let hasMeshUVs = mesh.texcoords?.isEmpty == false
            var resolved = CADPresentationMaterialResolver.resolve(
                spec: body.material,
                bodyID: body.id,
                bodyName: body.name,
                hasMeshUVs: hasMeshUVs,
                hasProjectedUVs: mesh.renderTexcoords != nil)
            if uvs == nil, let mapping = body.material?.uvMapping,
               mapping.source != .mesh, body.material?.hasAnyTexture == true {
                // The contract's snapshot already projects for the body; this
                // is a defensive recomputation for older callers and uses the
                // exact same projector (never a second geometry path).
                uvs = MaterialUVProjector.project(
                    positions: mesh.positions,
                    normals: mesh.normals,
                    indices: mesh.indices,
                    mapping: mapping)
            }
            if let flipped = uvs, resolved.material.flipsV {
                uvs = flipped.map { SIMD2($0.x, 1 - $0.y) }
            }
            for issue in resolved.issues {
                issues.append(issue)
            }

            // Face-level snapshots are applied in the document. The
            // authoritative triangle ranges come from the snapshot
            // (`CADSceneFaceMaterial.triangleIndices`); nil means there is no
            // trustworthy range, so nothing is guessed and the face is listed
            // as unresolved below.
            let faceMaterials = body.faceMaterials.map {
                CADPresentationFaceMaterial(
                    faceIndex: $0.faceIndex,
                    material: CADPresentationMaterialResolver.resolve(
                        spec: $0.material,
                        bodyID: body.id,
                        bodyName: body.name,
                        hasMeshUVs: hasMeshUVs,
                        hasProjectedUVs: false).material)
            }
            var faceGroups: [CADPresentationFaceGroup] = []
            var faceGroupsWithoutRange = 0
            for source in body.faceMaterials {
                guard let indices = source.triangleIndices,
                      !indices.isEmpty, indices.count % 3 == 0 else {
                    faceGroupsWithoutRange += 1
                    continue
                }
                guard let descriptor = faceMaterials.first(
                    where: { $0.faceIndex == source.faceIndex }) else { continue }
                // Snapshot renderTexcoords are the authoritative shared UVs.
                // Only a face-level projection (when the snapshot has no UVs)
                // is generated here, and it never changes the mesh.
                var groupUVs = mesh.renderTexcoords ?? mesh.texcoords
                if groupUVs == nil,
                   let mapping = source.material.uvMapping,
                   mapping.source != .mesh {
                    groupUVs = MaterialUVProjector.project(
                        positions: mesh.positions, normals: mesh.normals,
                        indices: mesh.indices, mapping: mapping)
                }
                if let current = groupUVs, descriptor.material.flipsV {
                    groupUVs = current.map { SIMD2($0.x, 1 - $0.y) }
                }
                faceGroups.append(CADPresentationFaceGroup(
                    faceIndex: source.faceIndex,
                    indices: indices,
                    material: descriptor.material,
                    uvs: groupUVs))
            }
            if faceGroupsWithoutRange > 0 {
                issues.append(CADPresentationIssue(
                    id: "faces-\(body.id.uuidString)",
                    kind: .faceMaterialDisplayUnsupported,
                    bodyID: body.id, bodyName: body.name,
                    detail: "\(faceGroupsWithoutRange) face material(s) have no trustworthy face range in this snapshot and are not drawn individually."))
            }
            if body.unresolvedFaceCount > 0 {
                issues.append(CADPresentationIssue(
                    id: "unresolved-\(body.id.uuidString)",
                    kind: .unresolvedFaceBindings,
                    bodyID: body.id, bodyName: body.name,
                    detail: "\(body.unresolvedFaceCount) face binding(s) no longer match a face and need reselection."))
            }
            for image in resolved.images {
                imagesByID[image.id] = image
            }

            let convertedPositions = mesh.positions.map(CADPresentationAxes.point)
            var convertedNormals = mesh.normals.map(CADPresentationAxes.direction)
            if convertedNormals.count != convertedPositions.count {
                convertedNormals = []
            }
            let convertedBoundsMin = CADPresentationAxes.point(mesh.boundsMin)
            let convertedBoundsMax = CADPresentationAxes.point(mesh.boundsMax)
            let convertedMesh = CADPresentationMesh(
                positions: convertedPositions,
                normals: convertedNormals,
                indices: mesh.indices,
                uvs: uvs,
                meshRevision: mesh.meshRevision,
                boundsMin: simd_min(convertedBoundsMin, convertedBoundsMax),
                boundsMax: simd_max(convertedBoundsMin, convertedBoundsMax))
            // `body.id` is the entity identity (an instance UUID for placed
            // parts); `sourceBodyID` only links source-body material previews.
            bodies.append(CADPresentationBody(
                id: body.id,
                sourceBodyID: body.sourceBodyID,
                name: body.name,
                transform: transform,
                mesh: convertedMesh,
                material: resolved.material,
                faceMaterials: faceMaterials,
                faceGroups: faceGroups,
                unresolvedFaceCount: body.unresolvedFaceCount,
                analyticBRep: body.analyticBRep))

            // World bounds: `convertedMesh` and `transform` are both already
            // in presentation metres, so apply the transform directly. Using
            // the millimetre corners with the metre transform (or scaling the
            // translation a second time) collapses every assembly instance
            // onto the origin and makes Fit frame one plate instead of the
            // placed layout.
            let bodyBounds = Self.worldBounds(
                min: convertedMesh.boundsMin, max: convertedMesh.boundsMax,
                transform: transform)
            if bounds == nil {
                bounds = bodyBounds
            } else {
                bounds = CADPresentationBounds(
                    min: simd_min(bounds!.min, bodyBounds.min),
                    max: simd_max(bounds!.max, bodyBounds.max))
            }
        }

        let environment = environment(from: snapshot.appearance)
        let images = imagesByID.values.sorted { $0.id < $1.id }
        return CADPresentationScene(
            schemaVersion: CADPresentationScene.currentSchemaVersion,
            documentKey: documentKey,
            documentRevision: snapshot.documentRevision,
            changeCount: snapshot.changeCount,
            contentSHA256: snapshot.contentSHA256,
            bodies: bodies,
            images: images,
            environment: environment,
            issues: issues,
            bounds: bounds,
            materialCount: snapshot.materials.count)
    }

    /// World-space bounds for one body. `min`/`max` are the converted body
    /// mesh bounds and `transform` is the converted body matrix; both are in
    /// presentation metres, so no unit scaling happens here.
    nonisolated static func worldBounds(min: SIMD3<Float>, max: SIMD3<Float>,
                                        transform: simd_float4x4) -> CADPresentationBounds {
        var worldMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var worldMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for x in [min.x, max.x] {
            for y in [min.y, max.y] {
                for z in [min.z, max.z] {
                    let world = transform * SIMD4<Float>(x, y, z, 1)
                    let point = SIMD3(world.x, world.y, world.z)
                    worldMin = simd_min(worldMin, point)
                    worldMax = simd_max(worldMax, point)
                }
            }
        }
        return CADPresentationBounds(min: worldMin, max: worldMax)
    }

    nonisolated static func environment(from appearance: CADViewAppearance) -> CADPresentationEnvironment {
        let clean = appearance.sanitized
        let settings: CADViewEnvironmentSettings
        switch clean.activeEnvironment {
        case .studio: settings = clean.studio
        case .daylight: settings = clean.daylight
        case .dark: settings = clean.dark
        }
        let direction = settings.lightDirection.count == 3
            ? SIMD3(Float(settings.lightDirection[0]),
                    Float(settings.lightDirection[1]),
                    Float(settings.lightDirection[2]))
            : SIMD3(0.35, 0.55, 0.75)
        let background = settings.backgroundColor.count == 3
            ? SIMD3(Float(settings.backgroundColor[0]),
                    Float(settings.backgroundColor[1]),
                    Float(settings.backgroundColor[2]))
            : SIMD3(0.12, 0.14, 0.18)
        let floor = clean.floorColor.count == 3
            ? SIMD3(Float(clean.floorColor[0]), Float(clean.floorColor[1]),
                    Float(clean.floorColor[2]))
            : SIMD3(0.5, 0.5, 0.52)
        return CADPresentationEnvironment(
            kind: clean.activeEnvironment,
            lightIntensity: Float(settings.lightIntensity),
            lightDirectionModel: CADPresentationAxes.direction(direction),
            backgroundColor: simd_clamp(background, SIMD3(repeating: 0), SIMD3(repeating: 1)),
            floorVisible: clean.floorVisible,
            floorColor: simd_clamp(floor, SIMD3(repeating: 0), SIMD3(repeating: 1)),
            floorSizeMM: Float(clean.floorSizeMM),
            shadowsEnabled: clean.shadowsEnabled)
    }
}
#endif
