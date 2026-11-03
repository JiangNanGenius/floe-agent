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
import RealityKit
import UIKit
import simd

@MainActor
final class CADPresentationBodyNodes {
    let parent: Entity
    let entities: [ModelEntity]
    let faceEntities: [Int: ModelEntity]
    /// Exact triangle ordinals for each face entity that could be correlated
    /// unambiguously with the authoritative body mesh. A draft preview must
    /// change only these triangles; a missing entry is never widened to the
    /// whole body.
    let faceTriangles: [Int: [Int]]

    init(parent: Entity, entities: [ModelEntity], faceEntities: [Int: ModelEntity],
         faceTriangles: [Int: [Int]]) {
        self.parent = parent
        self.entities = entities
        self.faceEntities = faceEntities
        self.faceTriangles = faceTriangles
    }
}

@MainActor
final class CADPresentationBuildResult {
    let stage: Entity
    let bodyEntities: [UUID: CADPresentationBodyNodes]
    let issues: [CADPresentationIssue]
    let pickTargets: [ObjectIdentifier: CADPresentationPick]
    let buildKey: String
    let meshCount: Int
    let textureCount: Int

    init(stage: Entity,
         bodyEntities: [UUID: CADPresentationBodyNodes],
         issues: [CADPresentationIssue],
         pickTargets: [ObjectIdentifier: CADPresentationPick],
         buildKey: String,
         meshCount: Int,
         textureCount: Int) {
        self.stage = stage
        self.bodyEntities = bodyEntities
        self.issues = issues
        self.pickTargets = pickTargets
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
        let picks = CADPresentationPickIndex()
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
                picks: picks, section: scene.section, issues: &issues)
            // Never publish a body entity from a superseded or cancelled
            // build; the caller additionally fences the whole result by
            // scene.buildKey before swapping the stage.
            try Task.checkCancellation()
            // A body entirely outside the kept half of a section draws
            // nothing; the model itself is unchanged.
            if let nodes {
                stage.addChild(nodes.parent)
                entities[body.id] = nodes
            }
        }

        try Task.checkCancellation()
        addFloor(to: stage, environment: scene.environment,
                 bounds: scene.bounds)
        addLights(to: stage, environment: scene.environment)
        // X22: saved measurement guides are real stage geometry, so they are
        // in Present pixels and every exported frame — not a SwiftUI-only
        // annotation that disappears from a capture.
        addMeasurementGuides(scene.measurementGuides, to: stage)

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
            pickTargets: picks.targets,
            buildKey: scene.buildKey,
            meshCount: cache.meshCount,
            textureCount: cache.textureCount)
    }

    /// Environment/lighting changes reuse the same body entities: only the
    /// floor, lights and background are replaced. This keeps camera and
    /// selection stable when switching Studio/Daylight/Dark. `bounds` must be
    /// the bounds of what is actually visible now (including a transient
    /// animation frame), so the rebuilt ground still sits below the model.
    func applyEnvironment(_ environment: CADPresentationEnvironment,
                          to stage: Entity,
                          bounds: CADPresentationBounds?,
                          cache: CADPresentationResourceCache) async {
        stage.children.filter { $0.name.hasPrefix("CADPresentationLight")
            || $0.name.hasPrefix("CADPresentationFloor") }
            .forEach { $0.removeFromParent() }
        addFloor(to: stage, environment: environment, bounds: bounds)
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
                          picks: CADPresentationPickIndex,
                          section: CADPresentationSection?,
                          issues: inout [CADPresentationIssue]) async throws -> CADPresentationBodyNodes? {
        try Task.checkCancellation()

        // X22: the same persisted plane, converted into this body's local
        // presentation metres. Nil (no section / degenerate frame) keeps the
        // exact pre-X22 mesh path and cache identity. An authored section that
        // cannot produce a plane is NOT treated as "no section": the caller
        // gets a reported invalid-section issue instead of an uncut body.
        let localPlane: CADSectionClipPlane? = section.flatMap {
            CADSectionMeshClip.plane(originMM: $0.origin, normalMM: $0.keepNormal,
                                     transform: body.transform)
        }
        if section != nil, localPlane == nil {
            issues.append(CADPresentationIssue(
                id: "section-invalid-\(body.id.uuidString)", kind: .sectionInvalid,
                bodyID: body.id, bodyName: body.name,
                detail: "The active section plane cannot be expressed in this body's space; this body is not drawn in Present instead of showing it uncut."))
            return nil
        }
        let sectionActive = localPlane != nil
        var invalidReasons = Set<CADSectionClipInvalidReason>()

        // Value-only clip jobs. The exact body/face index buffers and their
        // group UVs travel to a detached worker; no document, B-rep or
        // RealityKit object is transferred. Jobs are built before any entity
        // so one await joins the whole body's CPU clip work.
        enum ClipKey: Hashable {
            case base
            case face(Int)
        }
        func job(indices: [UInt32], uvs: [SIMD2<Float>]?) -> CADSectionClipJob? {
            guard let localPlane else { return nil }
            return CADSectionClipJob(
                positions: body.mesh.positions, normals: body.mesh.normals,
                uvs: uvs, authoredUVs: body.mesh.authoredUVs,
                indices: indices, plane: localPlane)
        }
        let baseTriangles: [Int] = body.faceGroups.isEmpty
            ? [] : Self.baseTriangles(for: body.mesh, excluding: body.faceGroups)
        let baseIndices: [UInt32] = body.faceGroups.isEmpty
            ? body.mesh.indices : Self.indices(of: baseTriangles, in: body.mesh)
        var clipJobs: [CADSectionClipJob] = []
        var clipKeys: [ClipKey] = []
        if !baseIndices.isEmpty {
            if let value = job(indices: baseIndices, uvs: body.mesh.uvs) {
                clipJobs.append(value)
                clipKeys.append(.base)
            }
        }
        for group in body.faceGroups {
            if let value = job(indices: group.indices, uvs: group.uvs) {
                clipJobs.append(value)
                clipKeys.append(.face(group.faceIndex))
            }
        }
        var clipResults: [ClipKey: CADSectionClipOutcome] = [:]
        if !clipJobs.isEmpty {
            let outcomes = await CADSectionMeshClip.clipOffMain(clipJobs)
            try Task.checkCancellation()
            for (key, outcome) in zip(clipKeys, outcomes) {
                if case .cancelled = outcome { throw CancellationError() }
                clipResults[key] = outcome
            }
        }

        func outcome(for key: ClipKey) -> CADSectionClipOutcome {
            clipResults[key] ?? .unchanged
        }
        func noteInvalid(_ reason: CADSectionClipInvalidReason) {
            invalidReasons.insert(reason)
        }

        // While a section is shown a tap selects the body. Clipped triangle
        // ordinals are NOT the document render-mesh ordinals, so a face pick
        // could select the wrong face; there is no guessed mapping.
        func pick(for group: CADPresentationFaceGroup? = nil,
                  triangleGroups: [Int: [Int]]? = nil) -> CADPresentationPick {
            guard !sectionActive, let group else {
                return CADPresentationSelection.pick(for: body)
            }
            return CADPresentationSelection.pick(
                for: body, group: group, triangleGroups: triangleGroups)
        }

        if body.faceGroups.isEmpty {
            let resource: MeshResource
            switch outcome(for: .base) {
            case .clipped(let value) where value.isFullyClipped:
                return nil
            case .invalid(let reason):
                noteInvalid(reason)
                return nil
            case .cancelled:
                throw CancellationError()
            case .clipped(let value):
                guard let built = try await clippedResource(for: body, value: value) else {
                    issues.append(CADPresentationIssue(
                        id: "section-mesh-\(body.id.uuidString)", kind: .emptyBody,
                        bodyID: body.id, bodyName: body.name,
                        detail: "The section cut could not be built as a drawable mesh; this body is hidden in Present."))
                    return nil
                }
                resource = built
            case .unchanged:
                resource = baseMesh
            }
            try Task.checkCancellation()
            let material = await pbrMaterial(for: body.material,
                                             images: images,
                                             hasUVs: body.mesh.uvs != nil,
                                             bodyID: body.id,
                                             bodyName: body.name,
                                             issues: &issues)
            try Task.checkCancellation()
            let entity = ModelEntity(mesh: resource, materials: [material])
            entity.name = body.name
            try await picks.register(entity, mesh: resource, pick: pick())
            entity.transform = Transform(matrix: body.transform)
            entity.components.set(GroundingShadowComponent(
                castsShadow: castsShadow, receivesShadow: true))
            return CADPresentationBodyNodes(parent: entity, entities: [entity],
                                            faceEntities: [:], faceTriangles: [:])
        }

        // Correlating a large triangle table is value-only work. It is only
        // needed for face picking, which a section deliberately makes
        // body-level; skip it there. RealityKit resources stay on this actor.
        var triangleGroups: [Int: [Int]] = [:]
        if !sectionActive {
            let mapping = Task.detached(priority: .userInitiated) {
                CADPresentationSelection.triangleGroups(in: body)
            }
            triangleGroups = await withTaskCancellationHandler {
                await mapping.value
            } onCancel: { mapping.cancel() }
            try Task.checkCancellation()
        }
        let parent = Entity()
        parent.name = body.name
        parent.transform = Transform(matrix: body.transform)
        var entities: [ModelEntity] = []
        var faceEntities: [Int: ModelEntity] = [:]
        if !baseTriangles.isEmpty {
            switch outcome(for: .base) {
            case .clipped(let value) where value.isFullyClipped:
                break
            case .invalid(let reason):
                noteInvalid(reason)
            case .cancelled:
                throw CancellationError()
            case .clipped(let value):
                if let mesh = try await clippedResource(for: body, value: value) {
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
                    try await picks.register(entity, mesh: mesh, pick: pick())
                    entity.components.set(GroundingShadowComponent(
                        castsShadow: castsShadow, receivesShadow: true))
                    parent.addChild(entity)
                    entities.append(entity)
                }
            case .unchanged:
                if let mesh = try await Self.makeMesh(body.mesh, triangles: baseTriangles,
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
                    try await picks.register(entity, mesh: mesh, pick: pick())
                    entity.components.set(GroundingShadowComponent(
                        castsShadow: castsShadow, receivesShadow: true))
                    parent.addChild(entity)
                    entities.append(entity)
                }
            }
        }
        for group in body.faceGroups {
            try Task.checkCancellation()
            switch outcome(for: .face(group.faceIndex)) {
            case .clipped(let value) where value.isFullyClipped:
                continue
            case .invalid(let reason):
                noteInvalid(reason)
                continue
            case .cancelled:
                throw CancellationError()
            case .clipped(let value):
                guard let mesh = try await clippedResource(for: body, value: value) else { continue }
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
                try await picks.register(
                    entity, mesh: mesh,
                    pick: pick(for: group, triangleGroups: triangleGroups))
                entity.components.set(GroundingShadowComponent(
                    castsShadow: castsShadow, receivesShadow: true))
                parent.addChild(entity)
                entities.append(entity)
                faceEntities[group.faceIndex] = entity
            case .unchanged:
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
                try await picks.register(
                    entity, mesh: mesh,
                    pick: pick(for: group, triangleGroups: triangleGroups))
                entity.components.set(GroundingShadowComponent(
                    castsShadow: castsShadow, receivesShadow: true))
                parent.addChild(entity)
                entities.append(entity)
                faceEntities[group.faceIndex] = entity
            }
        }
        if !invalidReasons.isEmpty {
            let reasons = invalidReasons.map(\.rawValue).sorted().joined(separator: ",")
            issues.append(CADPresentationIssue(
                id: "section-invalid-\(body.id.uuidString)", kind: .sectionInvalid,
                bodyID: body.id, bodyName: body.name,
                detail: "The section plane or this body's index range could not be applied (\(reasons)); the affected part is not drawn in Present instead of showing it uncut."))
        }
        try Task.checkCancellation()
        // Keep only the faces whose exact triangle set is trustworthy. The
        // same correlation is already the pick identity, so previews can never
        // paint a wider range than a real hit could select. Under a section a
        // face pick is intentionally body-level, so no face target is offered.
        var faceTriangles: [Int: [Int]] = [:]
        if !sectionActive {
            for group in body.faceGroups {
                guard faceEntities[group.faceIndex] != nil,
                      let triangles = triangleGroups[group.faceIndex],
                      !triangles.isEmpty else { continue }
                faceTriangles[group.faceIndex] = triangles
            }
        }
        if entities.isEmpty { return nil }
        return CADPresentationBodyNodes(parent: parent, entities: entities,
                                        faceEntities: faceEntities,
                                        faceTriangles: faceTriangles)
    }

    /// Build one section-cut entity mesh from the clipped buffers. This is a
    /// method (not a nested async function) so it keeps the builder's main
    /// actor isolation while RealityKit creates the resource.
    private func clippedResource(for body: CADPresentationBody,
                                 value: CADClippedMesh) async throws -> MeshResource? {
        var mesh = body.mesh
        mesh.positions = value.positions
        mesh.normals = value.normals
        mesh.uvs = value.uvs
        mesh.authoredUVs = value.authoredUVs
        mesh.indices = value.indices
        if let first = value.positions.first {
            var minPoint = first
            var maxPoint = first
            for point in value.positions.dropFirst() {
                minPoint = simd_min(minPoint, point)
                maxPoint = simd_max(maxPoint, point)
            }
            mesh.boundsMin = minPoint
            mesh.boundsMax = maxPoint
        }
        return try await Self.makeMesh(mesh, indices: mesh.indices, uvs: mesh.uvs)
    }

    /// Expand contiguous triangle ordinals into the body index buffer.
    static func indices(of triangles: [Int], in mesh: CADPresentationMesh) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(triangles.count * 3)
        for triangle in triangles {
            let base = triangle * 3
            guard base + 2 < mesh.indices.count else { continue }
            result.append(mesh.indices[base])
            result.append(mesh.indices[base + 1])
            result.append(mesh.indices[base + 2])
        }
        return result
    }

    // MARK: X22 measurement guides

    /// Draw saved measurement guides as real stage geometry. Thin unlit boxes
    /// survive the RealityKit snapshot and every video frame; an entity-based
    /// SwiftUI overlay would not. Values stay in the document/UI, never baked
    /// into geometry.
    private func addMeasurementGuides(_ guides: [CADPresentationMeasurementGuide],
                                      to stage: Entity) {
        guard !guides.isEmpty else { return }
        let material = UnlitMaterial(
            color: UIColor(red: 0, green: 0.52, blue: 1, alpha: 1))
        let thickness: Float = 0.0012 // 1.2 mm
        for guide in guides {
            addGuideSegment(from: guide.start, to: guide.end,
                            thickness: thickness, material: material, to: stage)
            addGuideTick(at: guide.start, size: thickness * 4,
                         material: material, to: stage)
            addGuideTick(at: guide.end, size: thickness * 4,
                         material: material, to: stage)
        }
    }

    private func addGuideSegment(from start: SIMD3<Float>, to end: SIMD3<Float>,
                                 thickness: Float, material: UnlitMaterial,
                                 to stage: Entity) {
        let delta = end - start
        let length = simd_length(delta)
        guard length.isFinite, length > 1e-6 else { return }
        let mesh = MeshResource.generateBox(
            size: SIMD3(thickness, length, thickness))
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "CADPresentationMeasurementGuide"
        entity.position = (start + end) * 0.5
        entity.orientation = simd_quatf(from: SIMD3<Float>(0, 1, 0),
                                        to: delta / length)
        stage.addChild(entity)
    }

    private func addGuideTick(at point: SIMD3<Float>, size: Float,
                              material: UnlitMaterial, to stage: Entity) {
        let mesh = MeshResource.generateBox(size: SIMD3(size, size, size))
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "CADPresentationMeasurementGuideTick"
        entity.position = point
        stage.addChild(entity)
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
            if body.normals.count == body.positions.count {
                let tangents = CADPresentationResourceCache.tangents(
                    positions: body.positions, normals: body.normals,
                    uvs: uvs, indices: indices)
                if tangents.count == body.positions.count {
                    descriptor.tangents = MeshBuffers.Tangents(tangents)
                }
            }
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
            if body.normals.count == body.positions.count {
                let tangents = CADPresentationResourceCache.tangents(
                    positions: body.positions, normals: body.normals,
                    uvs: uvs, indices: indices)
                if tangents.count == body.positions.count {
                    descriptor.tangents = MeshBuffers.Tangents(tangents)
                }
            }
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

    /// One transient material for an uncommitted inspector draft plus the real
    /// issues that draft cannot preview on this device (a missing sampling UV
    /// buffer, a texture that did not decode). The caller swaps it onto a
    /// render-side mesh whose texture coordinates are built from `uvs`, so a
    /// projection/scale/offset edit can be seen before Apply.
    struct PreviewMaterial {
        var material: PhysicallyBasedMaterial
        var issues: [CADPresentationIssue]
    }

    /// Records per-slot texture failures without touching the applied build's
    /// issue reporting. Only accessed on the main actor.
    @MainActor
    final class TextureFailureRecorder {
        private(set) var slots: Set<MaterialTextureSlot> = []
        func record(_ slot: MaterialTextureSlot) { slots.insert(slot) }
    }

    /// Build the material for a draft that samples `uvs`. Passing nil means
    /// the draft genuinely has no sampling coordinates (for example a mesh
    /// source on a body without authored UVs); textures are then omitted and a
    /// real issue is returned instead of a silently untextured success.
    func previewMaterial(spec: BodyMaterialSpec,
                         bodyID: UUID,
                         bodyName: String,
                         uvs: [SIMD2<Float>]?) async -> PreviewMaterial {
        let clean = spec.clamped
        let mapping = clean.uvMapping ?? .mesh
        let resolved = CADPresentationMaterialResolver.resolve(
            spec: clean, bodyID: bodyID, bodyName: bodyName,
            hasMeshUVs: mapping.source == .mesh && uvs != nil,
            hasProjectedUVs: mapping.source != .mesh && uvs != nil)
        var imagesByID: [String: CADPresentationImage] = [:]
        for image in resolved.images { imagesByID[image.id] = image }
        var issues = resolved.issues
        let failures = TextureFailureRecorder()
        let material = await pbrMaterial(for: resolved.material,
                                         images: imagesByID,
                                         hasUVs: uvs != nil,
                                         bodyID: bodyID,
                                         bodyName: bodyName,
                                         issues: &issues,
                                         textureFailures: failures)
        for slot in failures.slots.sorted(by: { $0.rawValue < $1.rawValue }) {
            issues.append(CADPresentationIssue(
                id: "preview-image-\(bodyID.uuidString)-\(slot.rawValue)",
                kind: .imageDecodeFailed,
                bodyID: bodyID, bodyName: bodyName,
                detail: "The draft's \(slot.rawValue) image could not be decoded on this device; the rest of the draft still previews."))
        }
        // Resolver and PBR assembly both describe a missing UV source. Keep
        // the actionable resolver message once instead of two duplicate rows.
        var deduplicated: [CADPresentationIssue] = []
        var hasMissingUV = false
        var seenIDs = Set<String>()
        for issue in issues {
            if issue.kind == .missingMeshUV {
                guard !hasMissingUV else { continue }
                hasMissingUV = true
            }
            guard seenIDs.insert(issue.id).inserted else { continue }
            deduplicated.append(issue)
        }
        return PreviewMaterial(material: material, issues: deduplicated)
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
                             issues: inout [CADPresentationIssue],
                             textureFailures: TextureFailureRecorder? = nil) async -> PhysicallyBasedMaterial {
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
        CADAdvancedMaterialAdapter.apply(descriptor.advanced,to:&material,hasUVs:hasUVs)
        if (descriptor.advanced?.anisotropyLevel ?? 0) > 0, !hasUVs {
            issues.append(CADPresentationIssue(id:"advanced-uv-"+bodyID.uuidString,kind:.missingMeshUV,bodyID:bodyID,bodyName:bodyName,detail:FloeCADStrings.text("cad.advanced.uvIssue","Anisotropy needs UVs or a projected mapping; this preview keeps isotropic shading.")))
        }
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
            guard let reference = descriptor.texture(for: slot) else { return nil }
            guard let image = images[reference.imageID] else {
                textureFailures?.record(slot)
                return nil
            }
            // Each map is normalized with its own declared origin. This is the
            // only place Present turns row order into sampling data, so two
            // maps with opposite origins never share one V flip.
            guard let texture = await cache.texture(
                for: image, semantic: semantic,
                orientation: reference.orientation) else {
                textureFailures?.record(slot)
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

    private func addFloor(to stage: Entity, environment: CADPresentationEnvironment,
                          bounds: CADPresentationBounds?) {
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
        // The ground is derived from the actual transformed model, not from an
        // assumed origin. A fixed Y=0 offset cuts any geometry whose minimum
        // lies below zero (for example a 100 mm slab centred on the origin).
        floor.position = CADPresentationFloorPlacement.position(for: bounds)
        floor.components.set(GroundingShadowComponent(
            castsShadow: false, receivesShadow: environment.shadowsEnabled))
        stage.addChild(floor)
    }

    /// Move the already-built ground for a new visible-bounds value without
    /// rebuilding its mesh/material or changing its authored size/visibility.
    /// Used by animation frames and by any caller that re-dresses the scene
    /// while a transient pose is applied.
    static func updateFloor(in stage: Entity, bounds: CADPresentationBounds?, physicsFloorYMM: Double? = nil) {
        guard let floor = stage.children.first(where: {
            $0.name == "CADPresentationFloor"
        }) else { return }
        floor.position = CADPresentationFloorPlacement.position(for: bounds)
        if let y = physicsFloorYMM, y.isFinite {
            floor.position = SIMD3(0, Float(y / 1000) - CADPresentationFloorPlacement.clearance, 0)
        }
    }

    private func addLights(to stage: Entity, environment: CADPresentationEnvironment) {
        if let authored = environment.sceneLights {
            guard (try? CADSceneLight.validate(authored)) != nil else { return }
            for value in authored where value.enabled {
                let color = UIColor(red:CGFloat(value.color[0]),green:CGFloat(value.color[1]),blue:CGFloat(value.color[2]),alpha:1)
                let position = CADPresentationAxes.point(SIMD3(Float(value.positionMM[0]),Float(value.positionMM[1]),Float(value.positionMM[2])))
                let direction = simd_normalize(CADPresentationAxes.direction(SIMD3(Float(value.direction[0]),Float(value.direction[1]),Float(value.direction[2]))))
                let entity: Entity
                switch value.kind {
                case .directional:
                    let light = DirectionalLight()
                    light.light = .init(color:color,intensity:Float(value.intensity),isRealWorldProxy:false)
                    light.look(at:position+direction,from:position,relativeTo:nil,forward:.negativeZ)
                    if value.castsShadow && environment.shadowsEnabled {
                        light.shadow = .init(shadowProjection:.automatic(maximumDistance:20),depthBias:1)
                    }
                    entity = light
                case .point:
                    let light = PointLight()
                    light.light = .init(color:color,intensity:Float(value.intensity),attenuationRadius:Float(value.radiusMM/1000))
                    light.position = position
                    entity = light
                case .spot:
                    let light = SpotLight()
                    light.light = .init(color:color,intensity:Float(value.intensity),
                        innerAngleInDegrees:Float(value.innerAngleDegrees),outerAngleInDegrees:Float(value.outerAngleDegrees),
                        attenuationRadius:Float(value.radiusMM/1000))
                    light.look(at:position+direction,from:position,relativeTo:nil,forward:.negativeZ)
                    if value.castsShadow && environment.shadowsEnabled { light.shadow = .init() }
                    entity = light
                }
                entity.name = "CADPresentationLight-\(value.id.uuidString)"
                stage.addChild(entity)
            }
            return
        }
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
