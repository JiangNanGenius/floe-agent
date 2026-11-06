// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import Foundation
import simd

@MainActor
public extension FloeCADDocument {
    /// Freeze the same visible scene/face bindings/saved camera as Present.
    /// Later execution owns this immutable package, not the view's lifetime.
    func prepareOfflineRender(settings: CADOfflineRenderSettings) async throws -> CADOfflineRenderPackage {
        try settings.validate(); try Task.checkCancellation()
        guard !isClosed else { throw CADOfflineRenderError.sourceChanged }
        let count = liveChangeCount, revision = revision, sha = contentSHA256
        let snapshot = sceneSnapshot()
        let scene = CADPresentationSceneBuilder.build(snapshot: snapshot, documentKey: url.standardizedFileURL.path)
        guard !scene.issues.contains(where: { $0.id == "body-limit" || $0.id.hasPrefix("budget-") }) else {
            throw CADOfflineRenderError.tooLarge
        }
        guard !scene.issues.contains(where: { $0.kind == .malformedTransform }) else {
            throw CADOfflineRenderError.invalidScene
        }
        guard scene.section == nil else { throw CADOfflineRenderError.unsupportedSection }
        let aspect = Float(settings.width) / Float(settings.height)
        var camera = activeSavedCamera?.presentationCamera
            ?? CADPresentationCamera.fitted(to: scene.bounds, aspect: aspect)
        if let saved = activeSavedCamera {
            camera.transientHalfHeightScale = Float(max(1, saved.frameAspect / Double(aspect)))
        }
        let exchange = try CADOfflineRenderSnapshot.make(scene: scene, camera: camera)
        let worker = Task.detached(priority: .userInitiated) {
            try CADNativeSceneExporter.export(exchange, settings: settings, revision: revision,
                changeCount: count, sourceSHA256: sha)
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard !isClosed, liveChangeCount == count, self.revision == revision, contentSHA256 == sha else {
            throw CADOfflineRenderError.sourceChanged
        }
        return result
    }
}

@MainActor
enum CADOfflineRenderSnapshot {
    static func make(scene: CADPresentationScene, camera: CADPresentationCamera) throws -> CADOfflineRenderScene {
        func xyz(_ value: SIMD3<Float>) -> [Double] { [Double(value.x), Double(value.y), Double(value.z)] }
        var exchange = CADOfflineRenderScene(camera: .init(eye: xyz(camera.position), target: xyz(camera.target),
            verticalFOV: Double(camera.effectiveFovYDegrees),
            orthographicHalfHeight: camera.projection.isOrthographic
                ? Double(camera.halfHeightAtTarget * camera.transientHalfHeightScale) : nil), meshes: [])
        exchange.warnings = scene.issues.map(\.detail)
        var imageNames: [String: String] = [:]
        for image in scene.images {
            let name = "assets/\(image.id).\(image.mimeType == "image/png" ? "png" : "jpg")"
            exchange.assets[name] = image.bytes; imageNames[image.id] = name
        }
        func material(_ value: CADPresentationMaterial) -> CADOfflineRenderScene.Material {
            let base = value.textures.first { $0.slot == .baseColor }
            if value.textures.contains(where: { $0.slot != .baseColor }) {
                exchange.warnings.append("Only base-color images are transferred; other texture maps use their scalar material values.")
            }
            if value.advanced != nil {
                exchange.warnings.append("Advanced material layers use the base PBR material in this offline preview.")
            }
            return .init(color: xyz(SIMD3(value.baseColor.x, value.baseColor.y, value.baseColor.z)),
                metallic: Double(value.metallic), roughness: Double(value.roughness), opacity: Double(value.opacity),
                emissive: xyz(value.emissive * value.emissiveStrength),
                baseColorImage: base.flatMap { imageNames[$0.imageID] },
                imageIsLinear: base?.colorSpace == .linear,
                flipImageV: base?.orientation == .topLeft)
        }
        for body in scene.bodies {
            try Task.checkCancellation()
            let matrix = body.transform
            let linear = simd_float3x3(SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
            let determinant = simd_determinant(linear)
            guard determinant.isFinite, abs(determinant) > 1e-12 else { throw CADOfflineRenderError.invalidScene }
            let normalMatrix = linear.inverse.transpose
            let positions = body.mesh.positions.flatMap { point -> [Double] in
                let p = matrix * SIMD4(point, 1)
                return [Double(p.x), Double(p.y), Double(p.z)]
            }
            let normals = body.mesh.normals.flatMap { normal -> [Double] in
                let n = simd_normalize(normalMatrix * normal)
                return xyz(n)
            }
            func add(indices: [UInt32], appearance: CADPresentationMaterial, uvs: [SIMD2<Float>]?) {
                guard !indices.isEmpty else { return }
                // A mirrored instance changes geometric handedness. Preserve
                // outward faces for glass/emitters after flattening its matrix.
                var ordered = indices
                if determinant < 0 {
                    for i in stride(from: 0, to: ordered.count - 2, by: 3) { ordered.swapAt(i + 1, i + 2) }
                }
                exchange.meshes.append(.init(positions: positions, normals: normals,
                    uvs: uvs?.flatMap { [Double($0.x), Double($0.y)] } ?? [],
                    indices: ordered, material: material(appearance)))
            }
            if body.faceGroups.isEmpty {
                add(indices: body.mesh.indices, appearance: body.material, uvs: body.mesh.uvs)
            } else {
                let ordinals = CADPresentationEntityBuilder.baseTriangles(for: body.mesh, excluding: body.faceGroups)
                add(indices: ordinals.flatMap { Array(body.mesh.indices[($0 * 3)..<($0 * 3 + 3)]) },
                    appearance: body.material, uvs: body.mesh.uvs)
                for group in body.faceGroups { add(indices: group.indices, appearance: group.material, uvs: group.uvs) }
            }
        }
        let environment = scene.environment
        exchange.backgroundColor = xyz(environment.backgroundColor)
        if let map = environment.environmentMap {
            let bytes = try map.checkedBytes()
            // The bundled image loaders accept Radiance HDR, EXR, PNG and JPEG. Original
            // bytes stay intact and are identified by digest, never a path from a document.
            let isHDR = bytes.starts(with: Data("#?".utf8))
            let isPNG = bytes.starts(with: [137, 80, 78, 71])
            let isEXR = bytes.starts(with: [0x76, 0x2f, 0x31, 0x01])
            let isJPEG = bytes.starts(with: [0xff, 0xd8, 0xff])
            guard isHDR || isPNG || isEXR || isJPEG else { throw CADOfflineRenderError.unsupportedEnvironmentImage }
            let name = "assets/environment.\(isHDR ? "hdr" : (isEXR ? "exr" : (isPNG ? "png" : "jpg")))"
            exchange.assets[name] = bytes; exchange.environmentImage = name
            exchange.environmentRotation = map.rotationDegrees; exchange.environmentIntensity = map.intensity
            exchange.environmentShowsBackground = map.showsBackground
        }
        if let authored = environment.sceneLights {
            for light in authored where light.enabled {
                try light.validate()
                exchange.lights.append(.init(kind: .init(rawValue: light.kind.rawValue)!,
                    position: light.positionMM.map { $0 / 1000 }, direction: light.direction,
                    color: light.color, intensity: light.intensity,
                    innerAngle: light.innerAngleDegrees, outerAngle: light.outerAngleDegrees))
            }
            if authored.contains(where: { !$0.castsShadow || $0.kind != .directional }) {
                exchange.warnings.append("Offline lights cast physical shadows and have no realtime attenuation cutoff.")
            }
        } else {
            let direction = environment.lightDirectionModel
            exchange.lights = [
                .init(kind: .directional, direction: xyz(direction), intensity: Double(environment.lightIntensity) * 2200),
                .init(kind: .directional, direction: xyz(simd_normalize(SIMD3(-direction.x * 0.4 + 0.15,
                    max(-direction.y, -0.2), -direction.z * 0.4 - 0.25))), color: [0.82, 0.88, 1],
                    intensity: Double(max(environment.lightIntensity, 0.25)) * 420)
            ]
        }
        if environment.floorVisible {
            let p = CADPresentationFloorPlacement.position(for: scene.bounds)
            let half = Double(min(max(environment.floorSizeMM / 1000, 0.02), 500)) / 2
            let x = Double(p.x), y = Double(p.y), z = Double(p.z)
            exchange.meshes.append(.init(positions: [x-half,y,z-half, x-half,y,z+half, x+half,y,z+half, x+half,y,z-half],
                normals: [0,1,0, 0,1,0, 0,1,0, 0,1,0], indices: [0,1,2, 0,2,3],
                material: .init(color: xyz(environment.floorColor), roughness: 0.88)))
        }
        return exchange
    }
}
#endif
