//
//  CADPresentationEntityBuilder.swift
//  FloeCADKit
//
//  Builds the RealityKit entity tree from one `CADPresentationScene` value.
//  Every mesh/material/image here is a render-side representation of the SAME
//  scene snapshot the Metal viewport uses — there is no second geometry store,
//  no document mutation and no undo record. Face-level overrides use the
//  authoritative index ranges from the snapshot; a nil range is reported and
//  never guessed.
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import Foundation
import RealityFoundation
import RealityKit
import UIKit
import simd

@MainActor
final class CADPresentationBodyNodes {
    let parent: Entity
    let entities: [ModelEntity]
    let faceEntities: [Int: ModelEntity]

    init(parent: Entity, entities: [ModelEntity], faceEntities: [Int: ModelEntity]) {
        self.parent = parent
        self.entities = entities
        self.faceEntities = faceEntities
    }
}

@MainActor
final class CADPresentationBuildResult {
    let stage: Entity
    let bodyEntities: [UUID: CADPresentationBodyNodes]
    let issues: [CADPresentationIssue]
    let buildKey: String
    let meshCount: Int
    let textureCount: Int

    init(stage: Entity,
         bodyEntities: [UUID: CADPresentationBodyNodes],
         issues: [CADPresentationIssue],
         buildKey: String,
         meshCount: Int,
         textureCount: Int) {
        self.stage = stage
        self.bodyEntities = bodyEntities
        self.issues = issues
        self.buildKey = buildKey
        self.meshCount = meshCount
        self.textureCount = textureCount
    }
}

@MainActor
final class CADPresentationEntityBuilder {
    private let cache: CADPresentationResourceCache

    init(cache: CADPresentationResourceCache) {
        self.cache = cache
    }

    /// Build the complete stage. Awaiting textures is bounded by the scene's
    /// referenced images; cancellation between bodies leaves nothing applied
    /// because the caller only swaps the stage after this returns.
    func build(scene: CADPresentationScene) async throws -> CADPresentationBuildResult {
        try Task.checkCancellation()
        let stage = Entity()
        stage.name = "CADPresentationStage"
        var issues = scene.issues
        var entities: [UUID: CADPresentationBodyNodes] = [:]
        var imagesByID: [String: CADPresentationImage] = [:]
        for image in scene.images { imagesByID[image.id] = image }

        for body in scene.bodies {
            try Task.checkCancellation()
            let mesh: MeshResource
            do {
                mesh = try await cache.mesh(for: body.mesh)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                issues.append(CADPresentationIssue(
                    id: "mesh-\(body.id.uuidString)", kind: .emptyBody,
                    bodyID: body.id, bodyName: body.name,
                    detail: "The body's render buffers could not become a GPU mesh; other bodies and the model data are unaffected."))
                continue
            }
            try Task.checkCancellation()
            let nodes = try await bodyNodes(
                for: body,
                baseMesh: mesh,
                images: imagesByID,
                castsShadow: scene.environment.shadowsEnabled,
                issues: &issues)
            // Never publish a body entity from a superseded or cancelled
            // build; the caller additionally fences the whole result by
            // scene.buildKey before swapping the stage.
            try Task.checkCancellation()
            stage.addChild(nodes.parent)
            entities[body.id] = nodes
        }

        try Task.checkCancellation()
        addFloor(to: stage, environment: scene.environment)
        addLights(to: stage, environment: scene.environment)

        // A corrupt image is a real missing resource: report the exact image
        // rather than silently drawing an untextured body.
        for id in cache.decodeFailureIDs() where imagesByID[id] != nil {
            issues.append(CADPresentationIssue(
                id: "image-\(id)", kind: .imageDecodeFailed,
                bodyID: nil, bodyName: nil,
                detail: "A referenced material image could not be decoded on this device."))
        }
        try Task.checkCancellation()
        return CADPresentationBuildResult(
            stage: stage,
            bodyEntities: entities,
            issues: issues,
            buildKey: scene.buildKey,
            meshCount: cache.meshCount,
            textureCount: cache.textureCount)
    }

    /// Environment/lighting changes reuse the same body entities: only the
    /// floor, lights and background are replaced. This keeps camera and
    /// selection stable when switching Studio/Daylight/Dark.
    func applyEnvironment(_ environment: CADPresentationEnvironment,
                          to stage: Entity,
                          cache: CADPresentationResourceCache) async {
        stage.children.filter { $0.name.hasPrefix("CADPresentationLight")
            || $0.name.hasPrefix("CADPresentationFloor") }
            .forEach { $0.removeFromParent() }
        addFloor(to: stage, environment: environment)
        addLights(to: stage, environment: environment)
        _ = await cache.environment(for: environment)
    }

    // MARK: Body

    /// One body can carry several materials. Face groups reuse the SAME vertex
    /// buffers and transforms; only the index subsets differ, so this is one
    /// render-side decomposition, not a second geometry store.
    private func bodyNodes(for body: CADPresentationBody,
                          baseMesh: MeshResource,
                          images: [String: CADPresentationImage],
                          castsShadow: Bool,
                          issues: inout [CADPresentationIssue]) async throws -> CADPresentationBodyNodes {
        try Task.checkCancellation()
        if body.faceGroups.isEmpty {
            let material = await pbrMaterial(for: body.material,
                                             images: images,
                                             hasUVs: body.mesh.uvs != nil,
                                             bodyID: body.id,
                                             bodyName: body.name,
                                             issues: &issues)
            try Task.checkCancellation()
            let entity = ModelEntity(mesh: baseMesh, materials: [material])
            entity.name = body.name
            entity.transform = Transform(matrix: body.transform)
            entity.components.set(GroundingShadowComponent(
                castsShadow: castsShadow, receivesShadow: true))
            return CADPresentationBodyNodes(parent: entity, entities: [entity],
                                            faceEntities: [:])
        }

        let parent = Entity()
        parent.name = body.name
        parent.transform = Transform(matrix: body.transform)
        var entities: [ModelEntity] = []
        var faceEntities: [Int: ModelEntity] = [:]
        let baseTriangles = Self.baseTriangles(for: body.mesh,
                                               excluding: body.faceGroups)
        if !baseTriangles.isEmpty,
           let mesh = try await Self.makeMesh(body.mesh, triangles: baseTriangles,
                                              uvs: body.mesh.uvs) {
            try Task.checkCancellation()
            let material = await pbrMaterial(for: body.material,
                                             images: images,
                                             hasUVs: body.mesh.uvs != nil,
                                             bodyID: body.id,
                                             bodyName: body.name,
                                             issues: &issues)
            try Task.checkCancellation()
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.name = body.name
            entity.components.set(GroundingShadowComponent(
                castsShadow: castsShadow, receivesShadow: true))
            parent.addChild(entity)
            entities.append(entity)
        }
        for group in body.faceGroups {
            try Task.checkCancellation()
            guard let mesh = try await Self.makeMesh(body.mesh, indices: group.indices,
                                                     uvs: group.uvs) else {
                issues.append(CADPresentationIssue(
                    id: "face-range-\(body.id.uuidString)-\(group.faceIndex)",
                    kind: .faceMaterialDisplayUnsupported,
                    bodyID: body.id, bodyName: body.name,
                    detail: "Face \(group.faceIndex) has an invalid index range in this snapshot and is not drawn individually."))
                continue
            }
            try Task.checkCancellation()
            let material = await pbrMaterial(for: group.material,
                                             images: images,
                                             hasUVs: group.uvs != nil,
                                             bodyID: body.id,
                                             bodyName: body.name,
                                             issues: &issues)
            try Task.checkCancellation()
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.name = "\(body.name) · \(group.faceIndex)"
            entity.components.set(GroundingShadowComponent(
                castsShadow: castsShadow, receivesShadow: true))
            parent.addChild(entity)
            entities.append(entity)
            faceEntities[group.faceIndex] = entity
        }
        try Task.checkCancellation()
        return CADPresentationBodyNodes(parent: parent, entities: entities,
                                        faceEntities: faceEntities)
    }

    /// Triangles that are not claimed by an authoritative face range. The
    /// range arrays are compared as ordered index triples (the exact values the
    /// document snapshot reports), so a shared vertex between faces cannot make
    /// an unrelated triangle disappear.
    static func baseTriangles(for body: CADPresentationMesh,
                              excluding groups: [CADPresentationFaceGroup]) -> [Int] {
        var remaining: [[UInt32]: Int] = [:]
        for group in groups {
            var index = 0
            while index + 2 < group.indices.count {
                let key = [group.indices[index], group.indices[index + 1],
                           group.indices[index + 2]]
                remaining[key, default: 0] += 1
                index += 3
            }
        }
        var result: [Int] = []
        result.reserveCapacity(body.triangleCount)
        for triangle in 0..<body.triangleCount {
            let base = triangle * 3
            guard base + 2 < body.indices.count else { continue }
            let key = [body.indices[base], body.indices[base + 1], body.indices[base + 2]]
            if let count = remaining[key], count > 0 {
                remaining[key] = count - 1
            } else {
                result.append(triangle)
            }
        }
        return result
    }

    /// Use the authoritative face index list directly; vertex buffers and the
    /// body transform are still shared.
    static func makeMesh(_ body: CADPresentationMesh,
                         indices: [UInt32],
                         uvs: [SIMD2<Float>]?) async throws -> MeshResource? {
        try Task.checkCancellation()
        guard !indices.isEmpty, indices.count % 3 == 0 else { return nil }
        var descriptor = MeshDescriptor(name: "cad-body-face")
        descriptor.positions = MeshBuffers.Positions(body.positions)
        descriptor.normals = body.normals.isEmpty
            ? nil : MeshBuffers.Normals(body.normals)
        descriptor.primitives = .triangles(indices)
        if let uvs, uvs.count == body.positions.count {
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        }
        do {
            let resource = try await MeshResource(from: [descriptor])
            try Task.checkCancellation()
            return resource
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return nil
        }
    }

    /// Index a subset of the body's triangles without changing the vertex
    /// buffers or the body transform.
    static func makeMesh(_ body: CADPresentationMesh,
                         triangles: [Int],
                         uvs: [SIMD2<Float>]?) async throws -> MeshResource? {
        try Task.checkCancellation()
        guard !triangles.isEmpty else { return nil }
        var indices: [UInt32] = []
        indices.reserveCapacity(triangles.count * 3)
        for (offset, triangle) in triangles.enumerated() {
            if offset & 0xFFF == 0 { try Task.checkCancellation() }
            guard triangle >= 0, triangle * 3 + 2 < body.indices.count else { continue }
            indices.append(body.indices[triangle * 3])
            indices.append(body.indices[triangle * 3 + 1])
            indices.append(body.indices[triangle * 3 + 2])
        }
        guard !indices.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "cad-body-face")
        descriptor.positions = MeshBuffers.Positions(body.positions)
        descriptor.normals = body.normals.isEmpty
            ? nil : MeshBuffers.Normals(body.normals)
        descriptor.primitives = .triangles(indices)
        if let uvs, uvs.count == body.positions.count {
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        }
        do {
            let resource = try await MeshResource(from: [descriptor])
            try Task.checkCancellation()
            return resource
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return nil
        }
    }

    // MARK: Material preview

    /// Build the material for an uncommitted draft. The caller swaps it onto
    /// the live body entity without touching the document or the mesh.
    func previewMaterial(spec: BodyMaterialSpec,
                         bodyID: UUID,
                         bodyName: String,
                         hasUVs: Bool) async -> PhysicallyBasedMaterial {
        let resolved = CADPresentationMaterialResolver.resolve(
            spec: spec, bodyID: bodyID, bodyName: bodyName,
            hasMeshUVs: hasUVs,
            hasProjectedUVs: spec.uvMapping?.source != .mesh)
        var imagesByID: [String: CADPresentationImage] = [:]
        for image in resolved.images { imagesByID[image.id] = image }
        var issues: [CADPresentationIssue] = []
        let effectiveUVs = hasUVs || resolved.material.usesProjectedUVs
        return await pbrMaterial(for: resolved.material,
                                 images: imagesByID,
                                 hasUVs: effectiveUVs,
                                 bodyID: bodyID,
                                 bodyName: bodyName,
                                 issues: &issues)
    }

    /// Neutral material with no image lookup (used only to restore an
    /// entity whose original materials were empty).
    static func placeholderMaterial(for descriptor: CADPresentationMaterial) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(
            red: CGFloat(descriptor.baseColor.x),
            green: CGFloat(descriptor.baseColor.y),
            blue: CGFloat(descriptor.baseColor.z), alpha: 1))
        material.metallic = .init(scale: descriptor.metallic)
        material.roughness = .init(scale: descriptor.roughness)
        if descriptor.opacity < 0.999 {
            material.blending = .transparent(
                opacity: .init(scale: descriptor.opacity))
        }
        return material
    }

    // MARK: Material

    private func pbrMaterial(for descriptor: CADPresentationMaterial,
                             images: [String: CADPresentationImage],
                             hasUVs: Bool,
                             bodyID: UUID,
                             bodyName: String,
                             issues: inout [CADPresentationIssue]) async -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        let tint = UIColor(
            red: CGFloat(min(max(descriptor.baseColor.x, 0), 1)),
            green: CGFloat(min(max(descriptor.baseColor.y, 0), 1)),
            blue: CGFloat(min(max(descriptor.baseColor.z, 0), 1)),
            alpha: 1)
        material.baseColor = PhysicallyBasedMaterial.BaseColor(tint: tint)
        material.metallic = PhysicallyBasedMaterial.Metallic(scale: descriptor.metallic)
        material.roughness = PhysicallyBasedMaterial.Roughness(scale: descriptor.roughness)
        material.emissiveColor = PhysicallyBasedMaterial.EmissiveColor(color: .black)
        material.emissiveIntensity = 0
        if descriptor.emissiveStrength > 0 {
            let color = UIColor(
                red: CGFloat(min(max(descriptor.emissive.x, 0), 1)),
                green: CGFloat(min(max(descriptor.emissive.y, 0), 1)),
                blue: CGFloat(min(max(descriptor.emissive.z, 0), 1)),
                alpha: 1)
            material.emissiveColor = PhysicallyBasedMaterial.EmissiveColor(color: color)
            material.emissiveIntensity = descriptor.emissiveStrength
        }
        if descriptor.opacity < 0.999 || descriptor.texture(for: .opacity) != nil {
            material.blending = .transparent(
                opacity: PhysicallyBasedMaterial.Opacity(scale: descriptor.opacity))
        }

        guard hasUVs else {
            if !descriptor.textures.isEmpty {
                issues.append(CADPresentationIssue(
                    id: "uvskip-\(bodyID.uuidString)", kind: .missingMeshUV,
                    bodyID: bodyID, bodyName: bodyName,
                    detail: "Textures were not sampled because this body has no render UVs."))
            }
            return material
        }

        func resource(for slot: MaterialTextureSlot,
                      semantic: TextureResource.Semantic) async -> PhysicallyBasedMaterial.Texture? {
            guard let reference = descriptor.texture(for: slot),
                  let image = images[reference.imageID] else { return nil }
            guard let texture = await cache.texture(for: image, semantic: semantic) else {
                return nil
            }
            return PhysicallyBasedMaterial.Texture(texture)
        }

        if let base = await resource(for: .baseColor, semantic: .color) {
            material.baseColor = PhysicallyBasedMaterial.BaseColor(tint: tint, texture: base)
        }
        if let opacity = await resource(for: .opacity, semantic: .raw) {
            material.blending = .transparent(opacity: .init(scale: descriptor.opacity,
                                                            texture: opacity))
        }
        if let metallic = await resource(for: .metallic, semantic: .raw) {
            material.metallic = PhysicallyBasedMaterial.Metallic(
                scale: descriptor.metallic, texture: metallic)
        }
        if let roughness = await resource(for: .roughness, semantic: .raw) {
            material.roughness = PhysicallyBasedMaterial.Roughness(
                scale: descriptor.roughness, texture: roughness)
        }
        if let normal = await resource(for: .normal, semantic: .normal) {
            material.normal = PhysicallyBasedMaterial.Normal(texture: normal)
        }
        if descriptor.emissiveStrength > 0,
           let emissive = await resource(for: .emissive, semantic: .color) {
            material.emissiveColor.texture = emissive
        }
        return material
    }

    // MARK: Floor / lights

    private func addFloor(to stage: Entity, environment: CADPresentationEnvironment) {
        guard environment.floorVisible else { return }
        let size = min(max(environment.floorSizeMM / CADPresentationAxes.millimetresPerMeter,
                           0.02), 500)
        let mesh = MeshResource.generatePlane(width: size, depth: size)
        var floorMaterial = PhysicallyBasedMaterial()
        floorMaterial.baseColor = .init(tint: UIColor(
            red: CGFloat(environment.floorColor.x),
            green: CGFloat(environment.floorColor.y),
            blue: CGFloat(environment.floorColor.z),
            alpha: 1))
        floorMaterial.roughness = 0.88
        floorMaterial.metallic = 0.0
        let floor = ModelEntity(mesh: mesh, materials: [floorMaterial])
        floor.name = "CADPresentationFloor"
        floor.position = SIMD3(0, -0.0005, 0)
        floor.components.set(GroundingShadowComponent(
            castsShadow: false, receivesShadow: environment.shadowsEnabled))
        stage.addChild(floor)
    }

    private func addLights(to stage: Entity, environment: CADPresentationEnvironment) {
        let key = DirectionalLight()
        key.name = "CADPresentationLightKey"
        let keyDirection = CADPresentationAxes.direction(environment.lightDirectionModel)
        key.light = DirectionalLightComponent(
            color: .white,
            intensity: min(max(environment.lightIntensity, 0), 16) * 2_200,
            isRealWorldProxy: false)
        key.look(at: keyDirection, from: .zero, relativeTo: nil, forward: .negativeZ)
        if environment.shadowsEnabled {
            key.shadow = DirectionalLightComponent.Shadow(
                shadowProjection: .automatic(maximumDistance: 20),
                depthBias: 1)
        }
        stage.addChild(key)

        let fill = DirectionalLight()
        fill.name = "CADPresentationLightFill"
        let fillDirection = simd_normalize(
            SIMD3(-keyDirection.x * 0.4 + 0.15,
                  max(-keyDirection.y, -0.2),
                  -keyDirection.z * 0.4 - 0.25))
        fill.light = DirectionalLightComponent(
            color: UIColor(red: 0.82, green: 0.88, blue: 1.0, alpha: 1),
            intensity: max(environment.lightIntensity, 0.25) * 420,
            isRealWorldProxy: false)
        fill.look(at: fillDirection, from: .zero, relativeTo: nil, forward: .negativeZ)
        stage.addChild(fill)
    }
}
#endif
