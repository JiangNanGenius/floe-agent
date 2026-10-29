//
//  CADPresentationResourceCache.swift
//  FloeCADKit
//
//  Rebuildable RealityKit resources for the presentation surface. Everything
//  is keyed by content identity (mesh buffers, image SHA-256, environment
//  settings), so changing the camera, selection or inspector state reuses
//  GPU resources instead of rebuilding them per SwiftUI body evaluation.
//  The cache is owned by the presentation surface and released when the
//  document leaves Present mode.
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import CoreGraphics
import Foundation
import ImageIO
import RealityKit
import UIKit
import simd

@MainActor
final class CADPresentationResourceCache {
    private var meshes: [String: MeshResource] = [:]
    private var meshOrder: [String] = []
    private var textures: [String: TextureResource] = [:]
    private var textureOrder: [String] = []
    private var textureBytes: Int = 0
    private var environments: [String: EnvironmentResource] = [:]
    private var environmentOrder: [String] = []
    private var imageCache: [String: CGImage] = [:]
    private var failedImages: Set<String> = []

    private(set) var isDisposed = false

    var meshCount: Int { meshes.count }
    var textureCount: Int { textures.count }
    var cachedTextureBytes: Int { textureBytes }

    // MARK: Mesh

    func mesh(for mesh: CADPresentationMesh) async throws -> MeshResource {
        try Task.checkCancellation()
        guard !isDisposed else { throw CancellationError() }
        let key = mesh.cacheKey
        if let cached = meshes[key] { return cached }
        var descriptor = MeshDescriptor(name: "cad-body")
        descriptor.positions = MeshBuffers.Positions(mesh.positions)
        descriptor.normals = mesh.normals.isEmpty ? nil : MeshBuffers.Normals(mesh.normals)
        descriptor.primitives = .triangles(mesh.indices)
        if let uvs = mesh.uvs, uvs.count == mesh.positions.count {
            descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        }
        // Tangents are only meaningful with UVs; RealityKit uses them for
        // normal-mapped materials. Compute once here rather than per frame.
        if let uvs = mesh.uvs, uvs.count == mesh.positions.count,
           mesh.normals.count == mesh.positions.count {
            let tangents = Self.tangents(positions: mesh.positions,
                                         normals: mesh.normals,
                                         uvs: uvs,
                                         indices: mesh.indices)
            if tangents.count == mesh.positions.count {
                descriptor.tangents = MeshBuffers.Tangents(tangents)
            }
        }
        let resource = try await MeshResource(from: [descriptor])
        try Task.checkCancellation()
        guard !isDisposed else { throw CancellationError() }
        meshes[key] = resource
        meshOrder.append(key)
        trimMeshes()
        return resource
    }

    // MARK: Textures

    /// Decode + upload one encoded image for the requested semantic. A failed
    /// decode is remembered (never retried on every frame) and reported to the
    /// caller as nil; it never becomes a fabricated placeholder texture.
    func texture(for image: CADPresentationImage,
                 semantic: TextureResource.Semantic) async -> TextureResource? {
        guard !Task.isCancelled, !isDisposed else { return nil }
        let key = "\(image.id)-\(semanticName(semantic))"
        if let cached = textures[key] { return cached }
        guard !failedImages.contains(key) else { return nil }
        guard let cgImage = decode(image) else {
            failedImages.insert(key)
            return nil
        }
        do {
            let options = TextureResource.CreateOptions(semantic: semantic)
            let resource = try await TextureResource.generate(from: cgImage, options: options)
            // Cancellation is not a decode failure: never poison the failure
            // set or cache a resource for an abandoned build.
            guard !Task.isCancelled, !isDisposed else { return nil }
            textures[key] = resource
            textureOrder.append(key)
            textureBytes += image.byteCount
            trimTextures()
            return resource
        } catch {
            if Task.isCancelled || isDisposed { return nil }
            failedImages.insert(key)
            return nil
        }
    }

    func decodeFailureIDs() -> Set<String> {
        failedImages
    }

    func environment(for environment: CADPresentationEnvironment) async -> EnvironmentResource? {
        guard !Task.isCancelled, !isDisposed else { return nil }
        let key = environment.stableKey
        if let cached = environments[key] { return cached }
        guard let image = CADPresentationEnvironmentImage.make(for: environment) else {
            return nil
        }
        do {
            let resource = try await EnvironmentResource(equirectangular: image)
            guard !Task.isCancelled, !isDisposed else { return nil }
            environments[key] = resource
            environmentOrder.append(key)
            trimEnvironments()
            return resource
        } catch {
            return nil
        }
    }

    // MARK: Release

    func dispose() {
        meshes.removeAll()
        meshOrder.removeAll()
        textures.removeAll()
        textureOrder.removeAll()
        environments.removeAll()
        environmentOrder.removeAll()
        imageCache.removeAll()
        failedImages.removeAll()
        textureBytes = 0
        isDisposed = true
    }

    // MARK: Internals

    private func decode(_ image: CADPresentationImage) -> CGImage? {
        if let cached = imageCache[image.id] { return cached }
        guard let source = CGImageSourceCreateWithData(image.bytes as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        imageCache[image.id] = cgImage
        return cgImage
    }

    private func semanticName(_ semantic: TextureResource.Semantic) -> String {
        switch semantic {
        case .color: return "color"
        case .hdrColor: return "hdr"
        case .normal: return "normal"
        case .raw: return "raw"
        case .scalar: return "scalar"
        @unknown default: return "unknown"
        }
    }

    private func trimMeshes() {
        while meshOrder.count > CADPresentationLimits.maximumCachedMeshes {
            let key = meshOrder.removeFirst()
            meshes.removeValue(forKey: key)
        }
    }

    private func trimTextures() {
        while textureOrder.count > CADPresentationLimits.maximumCachedTextures
                || textureBytes > CADPresentationLimits.maximumCachedTextureBytes {
            guard let key = textureOrder.first else { break }
            textureOrder.removeFirst()
            textures.removeValue(forKey: key)
            // Byte accounting is approximated from the source images still
            // referenced; exact per-texture byte sizes are not exposed by
            // RealityKit. Recompute conservatively so the cap still holds.
            textureBytes = max(0, textureBytes - (CADMaterialLimits.maximumTextureBytes / 8))
        }
    }

    private func trimEnvironments() {
        while environmentOrder.count > 3 {
            let key = environmentOrder.removeFirst()
            environments.removeValue(forKey: key)
        }
    }

    /// Per-vertex tangents for normal mapping. Deterministic, bounded and
    /// derived from the render buffer — it does not change the mesh.
    private static func tangents(positions: [SIMD3<Float>],
                                 normals: [SIMD3<Float>],
                                 uvs: [SIMD2<Float>],
                                 indices: [UInt32]) -> [SIMD3<Float>] {
        guard positions.count == normals.count, positions.count == uvs.count else { return [] }
        var accumulated = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var triangle = 0
        while triangle + 2 < indices.count {
            let i0 = Int(indices[triangle]), i1 = Int(indices[triangle + 1]),
                i2 = Int(indices[triangle + 2])
            triangle += 3
            guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }
            let p0 = positions[i0], p1 = positions[i1], p2 = positions[i2]
            let uv0 = uvs[i0], uv1 = uvs[i1], uv2 = uvs[i2]
            let edge1 = p1 - p0, edge2 = p2 - p0
            let duv1 = uv1 - uv0, duv2 = uv2 - uv0
            let determinant = duv1.x * duv2.y - duv2.x * duv1.y
            guard abs(determinant) > 1e-9 else { continue }
            let inverse = 1 / determinant
            let tangent = (edge1 * duv2.y - edge2 * duv1.y) * inverse
            accumulated[i0] += tangent
            accumulated[i1] += tangent
            accumulated[i2] += tangent
        }
        return accumulated.indices.map { index in
            let n = normals[index]
            var t = accumulated[index]
            t -= n * simd_dot(n, t)
            let lengthSquared = simd_length_squared(t)
            return lengthSquared > 1e-12 ? t / sqrt(lengthSquared) : SIMD3(1, 0, 0)
        }
    }
}

// MARK: - Environment image

/// Small equirectangular gradient generated from the persisted appearance.
/// It provides real image-based ambient light and reflections for the PBR
/// materials; the key light stays an explicit directional light so its
/// direction/intensity remain the authored values.
nonisolated enum CADPresentationEnvironmentImage {
    static func make(for environment: CADPresentationEnvironment) -> CGImage? {
        let width = 256
        let height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let background = environment.backgroundColor
        let floor = environment.floorColor
        let light = environment.lightDirectionModel
        // Sky gradient above the horizon, floor bounce below it, plus a soft
        // sun lobe around the authored key direction.
        for y in 0..<height {
            let v = Float(y) / Float(height - 1)
            let latitude = (0.5 - v) * .pi // +pi/2 at the top
            for x in 0..<width {
                let u = Float(x) / Float(width - 1)
                let longitude = (u - 0.5) * 2 * .pi
                let direction = SIMD3<Float>(
                    cos(latitude) * sin(longitude),
                    sin(latitude),
                    cos(latitude) * cos(longitude))
                let sky = background
                let ground = simd_mix(background, floor, SIMD3(repeating: 0.55))
                var color = simd_mix(ground, sky, SIMD3(repeating: smoothstep(-0.25, 0.25, direction.y)))
                let sun = max(simd_dot(direction, light), 0)
                let lobe = pow(sun, 24) * max(environment.lightIntensity, 0) * 0.9
                color += SIMD3(repeating: lobe)
                color = simd_clamp(color, SIMD3(repeating: 0), SIMD3(repeating: 4))
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(min(max(color.x, 0), 1) * 255)
                pixels[offset + 1] = UInt8(min(max(color.y, 0), 1) * 255)
                pixels[offset + 2] = UInt8(min(max(color.z, 0), 1) * 255)
                pixels[offset + 3] = 255
            }
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue:
                                      CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return image
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
#endif
