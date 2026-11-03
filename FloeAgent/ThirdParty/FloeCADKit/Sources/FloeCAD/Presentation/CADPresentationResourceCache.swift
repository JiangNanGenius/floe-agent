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
import CoreImage
import Foundation
import ImageIO
import RealityKit
import UIKit
import simd

@MainActor
final class CADPresentationResourceCache {
    private let generateTexture: @MainActor (CGImage, TextureResource.CreateOptions) async throws -> TextureResource
    private var meshes: [String: MeshResource] = [:]
    private var meshOrder: [String] = []
    private var textures: [String: TextureResource] = [:]
    private var textureOrder: [String] = []
    private var textureBytes: Int = 0
    private var textureCosts: [String: Int] = [:]
    private var environments: [String: EnvironmentResource] = [:]
    private var environmentOrder: [String] = []
    private var imageCache: [String: CGImage] = [:]
    private var imageOrder: [String] = []
    private var imageCosts: [String: Int] = [:]
    private var imageBytes = 0
    private var failedImages: Set<String> = []
    private var environmentFailures: [String:String] = [:]
    private var environmentSourceBytes: [String:Data] = [:]
    private var failedEnvironmentSourceBytes: [String:Data] = [:]

    private(set) var isDisposed = false

    var meshCount: Int { meshes.count }
    var textureCount: Int { textures.count }
    var cachedTextureBytes: Int { textureBytes }
    var cachedImageBytes: Int { imageBytes }
    var cachedImageCount: Int { imageCache.count }

    init(generateTexture: @escaping @MainActor (CGImage, TextureResource.CreateOptions) async throws -> TextureResource = {
        try await TextureResource.generate(from: $0, options: $1)
    }) {
        self.generateTexture = generateTexture
    }

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

    /// Decode + upload one encoded image for the requested semantic and
    /// declared vertical origin. Orientation is part of the cache key because
    /// the same bytes can legitimately be used by two slots with opposite
    /// declared origins (for example a colour map and a normal map). A failed
    /// decode is remembered (never retried on every frame) and reported to the
    /// caller as nil; it never becomes a fabricated placeholder texture.
    func texture(for image: CADPresentationImage,
                 semantic: TextureResource.Semantic,
                 orientation: MaterialTextureOrientation) async -> TextureResource? {
        guard !Task.isCancelled, !isDisposed else { return nil }
        let key = "\(image.id)-\(semanticName(semantic))-\(orientation.rawValue)"
        if let cached = textures[key] {
            textureOrder.removeAll { $0 == key }
            textureOrder.append(key)
            return cached
        }
        guard !failedImages.contains(key) else { return nil }
        guard let cgImage = decode(image, orientation: orientation) else {
            failedImages.insert(key)
            return nil
        }
        let cost = Self.textureCost(cgImage)
        // Evict rebuildable cache references before upload. Live entities own
        // their resources independently and keep rendering during eviction.
        if cost <= Self.textureCacheLimit { trimTextures(additionalBytes: cost, additionalEntries: 1) }
        do {
            let options = TextureResource.CreateOptions(semantic: semantic)
            let resource = try await generateTexture(cgImage, options)
            // Cancellation is not a decode failure: never poison the failure
            // set or cache a resource for an abandoned build.
            guard !Task.isCancelled, !isDisposed else { return nil }
            // A second build may have completed for this key while generate()
            // suspended. Its pixels must not be counted or retained twice.
            if let cached = textures[key] { return cached }
            cacheImage(cgImage, key: "\(image.id)-\(orientation.rawValue)")
            if cost <= Self.textureCacheLimit {
                trimTextures(additionalBytes: cost, additionalEntries: 1)
                textures[key] = resource
                textureOrder.append(key)
                textureCosts[key] = cost
                textureBytes += cost
            }
            // Preserve support for older documents with one image larger than
            // the cache ceiling: return the real resource without retaining a
            // cold cache copy, rather than silently dropping its map.
            return resource
        } catch {
            if Task.isCancelled || isDisposed { return nil }
            failedImages.insert(key)
            return nil
        }
    }

    /// The original source image IDs that could not be represented. Failure
    /// keys also carry semantic/orientation, so report the shared image once
    /// rather than inventing one issue per sample.
    func decodeFailureIDs() -> Set<String> {
        Set(failedImages.compactMap { key in
            key.split(separator: "-", maxSplits: 1,
                      omittingEmptySubsequences: false).first.map(String.init)
        })
    }

    func environment(for environment: CADPresentationEnvironment) async -> EnvironmentResource? {
        guard !Task.isCancelled, !isDisposed else { return nil }
        let key = environment.environmentMap.map { "hdri-\($0.version)-\($0.sha256)-\($0.width)x\($0.height)-\($0.rotationDegrees)" } ?? environment.stableKey
        let sourceBytes = environment.environmentMap?.bytes ?? Data()
        do { try environment.environmentMap?.validate() }
        catch {
            if environmentFailures.count >= 3 { environmentFailures.removeAll(); failedEnvironmentSourceBytes.removeAll() }
            environmentFailures[key] = error.localizedDescription
            failedEnvironmentSourceBytes[key] = sourceBytes
            return nil
        }
        if let cached = environments[key], environmentSourceBytes[key] == sourceBytes { return cached }
        if environmentFailures[key] != nil, failedEnvironmentSourceBytes[key] == sourceBytes { return nil }
        environments.removeValue(forKey:key)
        environmentSourceBytes.removeValue(forKey:key)
        environmentOrder.removeAll { $0 == key }
        environmentFailures.removeValue(forKey:key)
        failedEnvironmentSourceBytes.removeValue(forKey:key)
        do {
            let image: CGImage
            if let map = environment.environmentMap {
                let worker = Task.detached(priority:.userInitiated) { try CADEnvironmentImageDecoder.decode(map) }
                image = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            } else {
                guard let generated = CADPresentationEnvironmentImage.make(for:environment) else { return nil }
                image = generated
            }
            try Task.checkCancellation()
            let resource: EnvironmentResource
            if #available(iOS 27.0, *) {
                resource = try await EnvironmentResource(equirectangular:image,
                    options:.init(samplingQuality:.normal,specularCubeDimension:512))
            } else {
                resource = try await EnvironmentResource(equirectangular:image)
            }
            guard !Task.isCancelled, !isDisposed else { return nil }
            environments[key] = resource
            environmentSourceBytes[key] = sourceBytes
            environmentOrder.append(key)
            trimEnvironments()
            return resource
        } catch {
            if !Task.isCancelled && !isDisposed {
                if environmentFailures.count >= 3 { environmentFailures.removeAll(); failedEnvironmentSourceBytes.removeAll() }
                environmentFailures[key] = error.localizedDescription
                failedEnvironmentSourceBytes[key] = sourceBytes
            }
            return nil
        }
    }

    func environmentFailure(for environment:CADPresentationEnvironment) -> String? {
        let key = environment.environmentMap.map { "hdri-\($0.version)-\($0.sha256)-\($0.width)x\($0.height)-\($0.rotationDegrees)" } ?? environment.stableKey
        return environmentFailures[key]
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
        imageOrder.removeAll()
        imageCosts.removeAll()
        imageBytes = 0
        failedImages.removeAll()
        environmentFailures.removeAll()
        environmentSourceBytes.removeAll()
        failedEnvironmentSourceBytes.removeAll()
        textureBytes = 0
        textureCosts.removeAll()
        isDisposed = true
    }

    // MARK: Internals

    /// Normalize the authored origin to the native CGImage upload convention.
    /// The absolute-UV App witnesses verify all four source quadrants: this
    /// RealityKit path samples the last CGImage row at v=0, unlike our shared
    /// top-left texture contract. Convert each map independently; do not alter
    /// the shared UVs or tangent frame to compensate for an image upload.
    private func decode(_ image: CADPresentationImage,
                        orientation: MaterialTextureOrientation) -> CGImage? {
        let key = "\(image.id)-\(orientation.rawValue)"
        if let cached = imageCache[key] {
            imageOrder.removeAll { $0 == key }
            imageOrder.append(key)
            return cached
        }
        // A small compressed file can have an enormous decoded bitmap. Check
        // the header before asking ImageIO to allocate that bitmap.
        guard image.bytes.count <= CADMaterialLimits.maximumTextureBytes,
              let source = CGImageSourceCreateWithData(image.bytes as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= CADImagePackingLimits.maximumDimension,
              height <= CADImagePackingLimits.maximumDimension,
              width <= CADImagePackingLimits.maximumPixelCount / height,
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              cgImage.width == width, cgImage.height == height else {
            return nil
        }
        let normalized: CGImage
        switch orientation {
        case .topLeft:
            guard let flipped = Self.verticallyFlipped(cgImage) else { return nil }
            normalized = flipped
        case .bottomLeft:
            normalized = cgImage
        }
        // Only a successful and uncancelled upload commits decoded images to
        // the cache. Failure releases this temporary bitmap with the call.
        return normalized
    }

    /// Lossless row reversal for the native image upload. It never changes
    /// mesh UVs or normal-channel values; colour and normal maps may retain
    /// opposite authored origins while addressing the same physical points.
    nonisolated static func verticallyFlipped(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
              width <= CADImagePackingLimits.maximumDimension,
              height <= CADImagePackingLimits.maximumDimension,
              width * height <= CADImagePackingLimits.maximumPixelCount,
              width * height * 4 <= CADImagePackingLimits.maximumDecodedBytes else {
            return nil
        }
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let context = makeContext(colorSpace)
                ?? makeContext(CGColorSpaceCreateDeviceRGB()) else { return nil }
        context.interpolationQuality = .none
        // Quartz draws images with their first row at the top of the
        // destination. Flipping the user-space Y axis before drawing produces
        // a new top-left image whose first row is the old bottom row.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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

    private static var textureCacheLimit: Int {
        min(CADPresentationLimits.maximumCachedTextureBytes, CADTextureImport.maximumResidentBytes)
    }

    private static func textureCost(_ image: CGImage) -> Int {
        let bytesPerPixel = max(4, (image.bitsPerPixel + 7) / 8)
        return CADTextureImport.mipmappedBytes(width: image.width, height: image.height) / 4 * bytesPerPixel
    }

    private func cacheImage(_ image: CGImage, key: String) {
        guard imageCache[key] == nil else { return }
        let cost = image.width * image.height * max(4, (image.bitsPerPixel + 7) / 8)
        guard cost <= CADImagePackingLimits.maximumDecodedBytes else { return }
        while imageBytes + cost > CADImagePackingLimits.maximumDecodedBytes
                || imageOrder.count >= CADPresentationLimits.maximumCachedTextures {
            guard let oldest = imageOrder.first else { break }
            imageOrder.removeFirst()
            imageCache.removeValue(forKey: oldest)
            imageBytes -= imageCosts.removeValue(forKey: oldest) ?? 0
        }
        imageCache[key] = image
        imageOrder.append(key)
        imageCosts[key] = cost
        imageBytes += cost
    }

    private func trimTextures(additionalBytes: Int = 0, additionalEntries: Int = 0) {
        while textureOrder.count + additionalEntries > CADPresentationLimits.maximumCachedTextures
                || textureBytes + additionalBytes > Self.textureCacheLimit {
            guard let key = textureOrder.first else { break }
            textureOrder.removeFirst()
            textures.removeValue(forKey: key)
            textureBytes -= textureCosts.removeValue(forKey: key) ?? 0
        }
    }

    private func trimEnvironments() {
        while environmentOrder.count > 3 {
            let key = environmentOrder.removeFirst()
            environments.removeValue(forKey: key)
            environmentSourceBytes.removeValue(forKey:key)
        }
    }

    /// Per-vertex tangents for normal mapping. Deterministic, bounded and
    /// derived from the render buffer — it does not change the mesh. Internal
    /// so the focused regression test can assert a known UV-sign expectation
    /// without launching a render surface.
    nonisolated static func tangents(positions: [SIMD3<Float>],
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

/// Keep the original HDR range and colour space; an environment is not an
/// 8-bit UI thumbnail. Rotation moves the actual lat/long image, shared by
/// lighting, background, still capture and every animation frame.
nonisolated enum CADEnvironmentImageDecoder {
    static func decode(_ map:CADEnvironmentMap) throws -> CGImage {
        try Task.checkCancellation()
        let bytes = try map.checkedBytes()
        guard let source = CGImageSourceCreateWithData(bytes as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),
              image.width == map.width, image.height == map.height else { throw CADSceneLightingError.damagedMap }
        try Task.checkCancellation()
        let angle = map.rotationDegrees.truncatingRemainder(dividingBy:360)
        guard abs(angle) > 1e-10 else { return image }
        let input = CIImage(cgImage:image)
        let translation = CGAffineTransform(translationX:CGFloat(angle/360)*CGFloat(image.width),y:0)
        let rotated = input.applyingFilter("CIAffineTile",parameters:[kCIInputTransformKey:NSValue(cgAffineTransform:translation)])
            .cropped(to:CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let colorSpace = CGColorSpace(name:CGColorSpace.extendedLinearSRGB),
              let result = CIContext(options:[.cacheIntermediates:false]).createCGImage(rotated,from:rotated.extent,
                format:.RGBAh,colorSpace:colorSpace) else { throw CADSceneLightingError.damagedMap }
        try Task.checkCancellation()
        return result
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
