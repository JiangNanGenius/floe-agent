//
//  GPUResourceCache.swift
//  openshape3d
//
//  Per-body MTLBuffers, keyed by body ID and invalidated by mesh revision.
//  Meshes change at user-action rate (extrude/boolean commits), so buffers are
//  simply reallocated fresh when the revision bumps.
//

import Foundation
import ImageIO
import Metal
import MetalKit
import simd

final class BodyGPUResources {
    let meshRevision: UInt64
    let positionBuffer: MTLBuffer
    let normalBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    let edgeVertexBuffer: MTLBuffer?
    let edgeVertexCount: Int
    /// Present only for meshes that carry texture coordinates (imports).
    let texcoordBuffer: MTLBuffer?

    init?(drawable: BodyDrawable, device: MTLDevice) {
        let mesh = drawable.renderMesh
        guard !mesh.positions.isEmpty, !mesh.indices.isEmpty else { return nil }
        let positionLength = mesh.positions.count * MemoryLayout<SIMD3<Float>>.stride
        let normalLength = mesh.normals.count * MemoryLayout<SIMD3<Float>>.stride
        let indexLength = mesh.indices.count * MemoryLayout<UInt32>.stride
        guard
            let positions = mesh.positions.withUnsafeBytes({ raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: positionLength, options: .storageModeShared)
            }),
            let normals = mesh.normals.withUnsafeBytes({ raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: normalLength, options: .storageModeShared)
            }),
            let indices = mesh.indices.withUnsafeBytes({ raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: indexLength, options: .storageModeShared)
            })
        else { return nil }

        meshRevision = drawable.meshRevision
        positionBuffer = positions
        normalBuffer = normals
        indexBuffer = indices
        indexCount = mesh.indices.count
        if let texcoords = mesh.texcoords, texcoords.count == mesh.positions.count {
            let length = texcoords.count * MemoryLayout<SIMD2<Float>>.stride
            texcoordBuffer = texcoords.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: length, options: .storageModeShared)
            }
        } else {
            texcoordBuffer = nil
        }

        if let edges = drawable.edges, !edges.segments.isEmpty {
            let edgeLength = edges.segments.count * MemoryLayout<SIMD3<Float>>.stride
            edgeVertexBuffer = edges.segments.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: edgeLength, options: .storageModeShared)
            }
            edgeVertexCount = edges.segments.count
        } else {
            edgeVertexBuffer = nil
            edgeVertexCount = 0
        }
    }
}

final class GPUResourceCache {
    private var cache: [BodyID: BodyGPUResources] = [:]

    func sync(with scene: ViewportScene, device: MTLDevice) {
        var liveIDs = Set<BodyID>()
        for drawable in scene.bodies {
            liveIDs.insert(drawable.id)
            if let existing = cache[drawable.id], existing.meshRevision == drawable.meshRevision {
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


/// Albedo textures for imported bodies — the body-side twin of
/// `ImageQuadTextureCache`, keyed by body id and refreshed when the
/// material's `textureRevision` moves. A body without texture data (every
/// modelled body) never enters the cache.
final class BodyTextureCache {
    private struct Entry {
        let revision: UInt64
        let texture: MTLTexture?
    }

    private var cache: [BodyID: Entry] = [:]
    private var loader: MTKTextureLoader?

    func sync(bodies: [BodyDrawable], device: MTLDevice) {
        var liveIDs = Set<BodyID>()
        for body in bodies {
            guard let material = body.material, let data = material.textureData else { continue }
            liveIDs.insert(body.id)
            if let existing = cache[body.id], existing.revision == material.textureRevision {
                continue
            }
            let loader = self.loader ?? MTKTextureLoader(device: device)
            self.loader = loader
            var texture: MTLTexture?
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                texture = try? loader.newTexture(cgImage: image, options: [
                    .SRGB: false,
                    .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                    .textureStorageMode: MTLStorageMode.shared.rawValue,
                    .generateMipmaps: true,
                ])
            }
            cache[body.id] = Entry(revision: material.textureRevision, texture: texture)
        }
        cache = cache.filter { liveIDs.contains($0.key) }
    }

    func texture(for id: BodyID) -> MTLTexture? {
        cache[id]?.texture
    }

    var entryCount: Int { cache.count }
}
