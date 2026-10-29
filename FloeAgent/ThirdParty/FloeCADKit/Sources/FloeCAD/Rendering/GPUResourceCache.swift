//
//  GPUResourceCache.swift
//  openshape3d
//
//  Per-body MTLBuffers, keyed by body ID and invalidated by mesh revision and
//  material identity. Meshes and materials change at user-action rate
//  (extrude/boolean commits, material edits), so buffers are simply
//  reallocated fresh when the identity changes.
//
//  Face materials share the body's vertex buffers and split the SAME index
//  buffer into ranges; each range carries its own material and (when its
//  mapping differs) its own texcoord buffer and image-map bindings. Nothing
//  here changes geometry or the document.
//

import Foundation
import ImageIO
import Metal
import MetalKit
import simd

final class BodyGPUResources {
    /// One image map as the renderer needs it: which fragment texture unit to
    /// bind, which BodyUniforms flag to set, and how to interpret the image.
    /// The bytes themselves live in `BodyTextureCache`, keyed by `cacheKey`.
    struct MapBinding: Equatable {
        let slot: MaterialTextureSlot
        let cacheKey: String
        let flag: UInt32
        let textureUnit: Int
        let flipsV: Bool
        let isSRGB: Bool
    }

    /// One indexed draw of a body: either the whole body (minus bound faces)
    /// or one resolved face material. `faceIndex` is nil for the base range.
    ///
    /// The range deliberately stores an INDEX into the drawable's material
    /// rather than a material copy: scalar factors change at slider rate and
    /// must reach the uniforms without rebuilding buffers, while the cached
    /// texcoords/map bindings only change when `materialKey` changes.
    struct Range {
        /// Resolved face index; nil for the body-level base range.
        let faceIndex: Int?
        /// -1 = the drawable's body material; otherwise the index into
        /// `BodyDrawable.faceMaterials`.
        let materialIndex: Int
        let triangles: [Int]
        let indexBuffer: MTLBuffer
        let indexCount: Int
        let texcoordBuffer: MTLBuffer?
        let maps: [MapBinding]

        var isFaceRange: Bool { faceIndex != nil }

        /// The CURRENT material for this range in `drawable` (never a stale
        /// copy). Nil only when a face material index no longer resolves.
        func material(in drawable: BodyDrawable) -> BodyMaterial? {
            guard materialIndex >= 0 else { return drawable.material }
            guard materialIndex < drawable.faceMaterials.count else { return nil }
            return drawable.faceMaterials[materialIndex].material
        }

        func isTransparent(in drawable: BodyDrawable) -> Bool {
            material(in: drawable)?.isTransparent ?? false
        }
    }

    let meshRevision: UInt64
    /// Identity of every render-relevant material/mapping/face input. A change
    /// rebuilds this body's ranges and texcoords without touching the mesh.
    let materialKey: UInt64
    let positionBuffer: MTLBuffer
    let normalBuffer: MTLBuffer
    /// Triangles not covered by a face binding. Nil when every triangle has a
    /// face material (or the mesh has none).
    let baseRange: Range?
    /// Resolved per-face ranges, in `BodyDrawable.faceMaterials` order.
    let faceRanges: [Range]
    let edgeVertexBuffer: MTLBuffer?
    let edgeVertexCount: Int

    init?(drawable: BodyDrawable, device: MTLDevice) {
        let mesh = drawable.renderMesh
        guard !mesh.positions.isEmpty, !mesh.indices.isEmpty else { return nil }
        let positionLength = mesh.positions.count * MemoryLayout<SIMD3<Float>>.stride
        let normalLength = mesh.normals.count * MemoryLayout<SIMD3<Float>>.stride
        guard !mesh.normals.isEmpty,
              let positions = mesh.positions.withUnsafeBytes({ raw in
                  device.makeBuffer(bytes: raw.baseAddress!, length: positionLength,
                                    options: .storageModeShared)
              }),
              let normals = mesh.normals.withUnsafeBytes({ raw in
                  device.makeBuffer(bytes: raw.baseAddress!, length: normalLength,
                                    options: .storageModeShared)
              })
        else { return nil }

        meshRevision = drawable.meshRevision
        materialKey = Self.materialKey(for: drawable)
        positionBuffer = positions
        normalBuffer = normals

        if let edges = drawable.edges, !edges.segments.isEmpty {
            let edgeLength = edges.segments.count * MemoryLayout<SIMD3<Float>>.stride
            edgeVertexBuffer = edges.segments.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: edgeLength,
                                  options: .storageModeShared)
            }
            edgeVertexCount = edges.segments.count
        } else {
            edgeVertexBuffer = nil
            edgeVertexCount = 0
        }

        var claimed = Set<Int>()
        var ranges: [Range] = []
        for (index, face) in drawable.faceMaterials.enumerated() {
            let triangles = face.triangles.filter {
                $0 >= 0 && $0 * 3 + 2 < mesh.indices.count && !claimed.contains($0)
            }
            guard !triangles.isEmpty else { continue }
            claimed.formUnion(triangles)
            guard let buffer = Self.makeIndexBuffer(
                triangles: triangles, indices: mesh.indices, device: device) else {
                continue
            }
            ranges.append(Self.makeRange(
                faceIndex: face.faceIndex,
                materialIndex: index,
                material: face.material,
                triangles: triangles,
                indexBuffer: buffer,
                mesh: mesh,
                device: device))
        }
        faceRanges = ranges

        var baseTriangles: [Int] = []
        baseTriangles.reserveCapacity(mesh.triangleCount)
        for triangle in 0..<mesh.triangleCount where !claimed.contains(triangle) {
            baseTriangles.append(triangle)
        }
        if !baseTriangles.isEmpty,
           let buffer = Self.makeIndexBuffer(triangles: baseTriangles,
                                             indices: mesh.indices, device: device) {
            baseRange = Self.makeRange(
                faceIndex: nil,
                materialIndex: -1,
                material: drawable.material,
                triangles: baseTriangles,
                indexBuffer: buffer,
                mesh: mesh,
                device: device)
        } else {
            baseRange = nil
        }
    }

    private static func makeRange(faceIndex: Int?,
                                  materialIndex: Int,
                                  material: BodyMaterial?,
                                  triangles: [Int],
                                  indexBuffer: MTLBuffer,
                                  mesh: RenderMesh,
                                  device: MTLDevice) -> Range {
        let texcoords = makeTexcoordBuffer(mesh: mesh, material: material, device: device)
        // A map can only be sampled with a UV set. Without one the material's
        // scalar factors still shade this range and the maps are simply not
        // bound (BodyMaterial already reports the unusable slots).
        let maps: [MapBinding] = texcoords == nil ? [] : (material?.maps.map {
            MapBinding(slot: $0.slot,
                       cacheKey: $0.textureCacheKey,
                       flag: $0.uniformFlag,
                       textureUnit: $0.slot.textureUnit,
                       flipsV: $0.flipsV,
                       isSRGB: $0.isSRGB)
        } ?? [])
        return Range(faceIndex: faceIndex,
                     materialIndex: materialIndex,
                     triangles: triangles,
                     indexBuffer: indexBuffer,
                     indexCount: triangles.count * 3,
                     texcoordBuffer: texcoords,
                     maps: maps)
    }

    /// Cache identity for everything a range needs beyond the mesh buffers:
    /// the per-range mapping (which changes the texcoords), the image maps
    /// (which change the texture bindings) and the face triangle ranges.
    static func materialKey(for drawable: BodyDrawable) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(drawable.material?.uvMapping?.source.rawValue)
        hasher.combine(drawable.material?.uvMapping?.axis.rawValue)
        hasher.combine(drawable.material?.uvMapping?.scaleMM)
        hasher.combine(drawable.material?.uvMapping?.rotationDegrees)
        hasher.combine(drawable.material?.uvMapping?.offset)
        hasher.combine(drawable.material?.uvMapping?.flipU)
        hasher.combine(drawable.material?.uvMapping?.flipV)
        appendMaps(drawable.material, to: &hasher)
        for face in drawable.faceMaterials {
            hasher.combine(face.faceIndex)
            hasher.combine(face.triangles.count)
            hasher.combine(face.triangles.first ?? -1)
            hasher.combine(face.triangles.last ?? -1)
            hasher.combine(face.material.uvMapping?.source.rawValue)
            hasher.combine(face.material.uvMapping?.axis.rawValue)
            hasher.combine(face.material.uvMapping?.scaleMM)
            hasher.combine(face.material.uvMapping?.rotationDegrees)
            hasher.combine(face.material.uvMapping?.offset)
            hasher.combine(face.material.uvMapping?.flipU)
            hasher.combine(face.material.uvMapping?.flipV)
            appendMaps(face.material, to: &hasher)
        }
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private static func appendMaps(_ material: BodyMaterial?, to hasher: inout Hasher) {
        guard let material else {
            hasher.combine(0)
            return
        }
        hasher.combine(material.maps.count)
        for map in material.maps {
            hasher.combine(map.slot.rawValue)
            hasher.combine(map.textureCacheKey)
            hasher.combine(map.orientation.rawValue)
            hasher.combine(map.colorSpace.rawValue)
        }
    }

    /// Projected or authored UVs for one appearance. Projection uses the shared
    /// core `MaterialUVProjector` and physical millimetres from the existing
    /// positions; it never mutates the mesh. Image row orientation is handled
    /// by the shader (a per-map V flip), so all maps share one UV set.
    static func projectedTexcoords(mesh: RenderMesh,
                                   material: BodyMaterial?) -> [SIMD2<Float>]? {
        if let authored = mesh.texcoords, authored.count == mesh.positions.count {
            return authored
        }
        guard let mapping = material?.uvMapping, mapping.source != .mesh else {
            return nil
        }
        return MaterialUVProjector.project(positions: mesh.positions,
                                           normals: mesh.normals,
                                           indices: mesh.indices,
                                           mapping: mapping)
    }

    private static func makeTexcoordBuffer(mesh: RenderMesh,
                                           material: BodyMaterial?,
                                           device: MTLDevice) -> MTLBuffer? {
        // Mesh UVs are pass-through; a projected set is generated only when the
        // material actually asks for a non-mesh source.
        guard let uvs = projectedTexcoords(mesh: mesh, material: material),
              uvs.count == mesh.positions.count else { return nil }
        let length = uvs.count * MemoryLayout<SIMD2<Float>>.stride
        return uvs.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: length,
                              options: .storageModeShared)
        }
    }

    private static func makeIndexBuffer(triangles: [Int],
                                        indices: [UInt32],
                                        device: MTLDevice) -> MTLBuffer? {
        var output: [UInt32] = []
        output.reserveCapacity(triangles.count * 3)
        for triangle in triangles {
            guard triangle >= 0, triangle * 3 + 2 < indices.count else { continue }
            output.append(indices[triangle * 3])
            output.append(indices[triangle * 3 + 1])
            output.append(indices[triangle * 3 + 2])
        }
        guard !output.isEmpty else { return nil }
        return output.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!,
                              length: output.count * MemoryLayout<UInt32>.stride,
                              options: .storageModeShared)
        }
    }
}

final class GPUResourceCache {
    private var cache: [BodyID: BodyGPUResources] = [:]

    func sync(with scene: ViewportScene, device: MTLDevice) {
        var liveIDs = Set<BodyID>()
        for drawable in scene.bodies {
            liveIDs.insert(drawable.id)
            let materialKey = BodyGPUResources.materialKey(for: drawable)
            if let existing = cache[drawable.id],
               existing.meshRevision == drawable.meshRevision,
               existing.materialKey == materialKey {
                continue
            }
            cache[drawable.id] = BodyGPUResources(drawable: drawable, device: device)
        }
        cache = cache.filter { liveIDs.contains($0.key) }
    }

    func resources(for id: BodyID) -> BodyGPUResources? {
        cache[id]
    }
}

/// Decoded MTLTextures for Insert-Image quads, keyed by quad ID and
/// invalidated by textureRevision (same pattern as BodyGPUResources: images
/// change at user-action rate, so a stale texture is simply re-decoded).
/// Nonisolated: an isolated deinit is both unnecessary and currently trips a
/// Swift-runtime malloc fault when the cache is deallocated under XCTest.
nonisolated final class ImageQuadTextureCache {
    private struct Entry {
        let revision: UInt64
        let texture: MTLTexture?
    }

    private var cache: [UUID: Entry] = [:]
    private var loader: MTKTextureLoader?

    func sync(quads: [ImageQuadDrawable], device: MTLDevice) {
        var liveIDs = Set<UUID>()
        for quad in quads {
            liveIDs.insert(quad.id)
            if let existing = cache[quad.id], existing.revision == quad.textureRevision {
                continue
            }
            let loader = self.loader ?? MTKTextureLoader(device: device)
            self.loader = loader
            // Decode via ImageIO first — MTKTextureLoader's data path is not
            // safe against undecodable bytes. Failed decodes are cached as
            // nil so a bad image doesn't retry every frame.
            var texture: MTLTexture?
            if let source = CGImageSourceCreateWithData(quad.textureData as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                // The viewport renders into a non-sRGB target, so load
                // without sRGB conversion to keep image colors consistent
                // with body colors.
                texture = try? loader.newTexture(cgImage: image, options: [
                    .SRGB: false,
                    .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                    .textureStorageMode: MTLStorageMode.shared.rawValue,
                ])
            }
            cache[quad.id] = Entry(revision: quad.textureRevision, texture: texture)
        }
        cache = cache.filter { liveIDs.contains($0.key) }
    }

    func texture(for id: UUID) -> MTLTexture? {
        cache[id]?.texture
    }

    /// Live entries — test hook for revision/eviction behavior.
    var entryCount: Int { cache.count }
}

/// Decoded material image maps, keyed by content identity + slot + declared
/// colour space. Equal maps share one upload; a changed map re-uploads exactly
/// once and the previous entry is evicted as soon as no body references it, so
/// a map can never leak from one body (or face) to another.
///
/// The cache is BOUNDED: it keeps at most `maximumEntries` textures / roughly
/// `maximumDecodedBytes` of decoded pixels and evicts least-recently-used
/// entries. Byte content never reaches the log; only cache keys do.
final class BodyTextureCache {
    private struct Entry {
        let texture: MTLTexture
        let decodedBytes: Int
    }

    private var entries: [String: Entry] = [:]
    private var failed: Set<String> = []
    private var loader: MTKTextureLoader?
    private var neutral: MTLTexture?

    /// Bounds. Six maps per material and a handful of live bodies fit well
    /// inside these; a large model cannot grow the cache without limit.
    static let maximumEntries = 64
    static let maximumDecodedBytes = 64 * 1024 * 1024
    /// Per-image bound (4096 x 4096 RGBA), checked BEFORE decoding so a small
    /// compressed file cannot expand into an unbounded allocation.
    static let maximumDecodedPixels = 4096 * 4096

    /// 1x1 white texture bound to every unused slot so the textured fragment
    /// function never samples an unbound texture.
    func neutralTexture(device: MTLDevice) -> MTLTexture? {
        if let neutral { return neutral }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pixel: [UInt8] = [255, 255, 255, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: pixel, bytesPerRow: 4)
        neutral = texture
        return texture
    }

    /// Load every map the scene references that fits the budget, and prune
    /// everything the scene no longer references. Loads happen only on first
    /// sight (or after a previous decode failure is gone).
    ///
    /// Capacity policy: the cache never evicts an entry the current scene still
    /// references — silently dropping a visible body's map would make the
    /// viewport flicker — so once the entry/byte budget is full, further NEW
    /// maps are deferred and retried on a later frame once other bodies leave
    /// the scene. Already loaded maps keep rendering throughout.
    func sync(bodies: [BodyDrawable], device: MTLDevice) {
        var order: [BodyMaterialMap] = []
        var live: Set<String> = []
        func collect(_ material: BodyMaterial?) {
            guard let material else { return }
            for map in material.maps where !live.contains(map.textureCacheKey) {
                live.insert(map.textureCacheKey)
                order.append(map)
            }
        }
        for body in bodies {
            collect(body.material)
            for face in body.faceMaterials { collect(face.material) }
        }

        entries = entries.filter { live.contains($0.key) }
        failed = failed.filter { live.contains($0) }

        var decodedBytes = entries.values.reduce(0) { $0 + $1.decodedBytes }
        for map in order {
            let key = map.textureCacheKey
            if entries[key] != nil || failed.contains(key) { continue }
            guard entries.count < Self.maximumEntries,
                  decodedBytes < Self.maximumDecodedBytes else { break }
            guard let texture = Self.loadTexture(data: map.data, device: device,
                                                 loader: &loader) else {
                // A corrupt/undecodable/oversized image is remembered as a
                // failure: the map's flag stays off, so the range degrades to
                // its scalar factors instead of retrying every frame. Capacity
                // deferral is NOT a failure and is retried later.
                failed.insert(key)
                continue
            }
            let bytes = texture.width * texture.height * 4
            entries[key] = Entry(texture: texture, decodedBytes: bytes)
            decodedBytes += bytes
        }
    }

    func texture(forKey key: String?) -> MTLTexture? {
        guard let key else { return nil }
        return entries[key]?.texture
    }

    /// Decode through ImageIO (MTKTextureLoader's raw-data path is not safe
    /// for undecodable bytes) and upload WITHOUT a hardware sRGB transfer:
    /// the shader applies the declared colour space, which keeps colour and
    /// scalar maps on the same code-value path as the existing body colours.
    private static func loadTexture(data: Data,
                                    device: MTLDevice,
                                    loader: inout MTKTextureLoader?) -> MTLTexture? {
        guard !data.isEmpty, data.count <= CADMaterialLimits.maximumTextureBytes else {
            return nil
        }
        guard MaterialImageSniffer.mimeType(of: data) != nil else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0,
              width * height <= Self.maximumDecodedPixels else {
            return nil
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        if loader == nil {
            loader = MTKTextureLoader(device: device)
        }
        return try? loader?.newTexture(cgImage: image, options: [
            .SRGB: false,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.shared.rawValue,
            .generateMipmaps: true,
        ])
    }

    /// Live entries — test hook for eviction/leak behavior.
    var entryCount: Int { entries.count }
    /// Keys that failed to decode — test hook; never contains image bytes.
    var failedKeys: Set<String> { failed }
    /// Approximate decoded pixel bytes — test hook for the bound.
    var decodedByteCount: Int { entries.values.reduce(0) { $0 + $1.decodedBytes } }
}
