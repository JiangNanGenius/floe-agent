//
//  CADPresentationCore.swift
//  FloeCADKit
//
//  Renderer-neutral values for the RealityKit presentation surface.
//
//  The presentation is a pure consumer of `CADSceneSnapshot`: it owns no
//  geometry, material list or undo stack. Everything in this file is a
//  `Sendable` value so it can be built on the document's main actor and handed
//  to the rendering pipeline without sharing mutable document state.
//
//  Units and axes
//  --------------
//  The live FloeCAD model is right-handed, +Y up, in millimetres (the sketch
//  ground plane is XZ with Y up; the GLB exporter and the 2026-10-30 core
//  snapshot both declare the same convention). RealityKit is right-handed,
//  +Y up, in metres. The ONLY conversion is therefore a uniform 1/1000 scale:
//  no axis rotation, so a body never arrives on its side. A body's
//  column-major model matrix keeps its rotation and scales translation by
//  1/1000. (The older CONTRACT.md text said +Z up; the actual model and the
//  current snapshot disagree with that text, and this lane follows the actual
//  bytes and the snapshot's coordinateSystem value.)
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import CoreGraphics
import Foundation
import simd

// MARK: - Units / coordinates

nonisolated enum CADPresentationAxes {
    /// Model millimetres per RealityKit metre.
    static let millimetresPerMeter: Float = 1_000

    /// Body-local / world model point in millimetres to presentation metres.
    /// Both spaces are +Y up, so this is scale only.
    static func point(_ value: SIMD3<Float>) -> SIMD3<Float> {
        value * (1 / millimetresPerMeter)
    }

    /// Direction conversion (no scale, no axis change). Degenerate input
    /// becomes +Y.
    static func direction(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(value)
        guard lengthSquared > 1e-16, lengthSquared.isFinite else { return SIMD3(0, 1, 0) }
        return value * (1 / sqrt(lengthSquared))
    }

    /// Convert a column-major 4×4 model matrix (millimetres) to RealityKit
    /// metres. Returns nil for malformed or non-finite input so the caller can
    /// report a real problem instead of drawing a corrupt transform.
    static func matrix(_ columns: [Double]) -> simd_float4x4? {
        guard columns.count == 16, columns.allSatisfy({ $0.isFinite }) else { return nil }
        // CAD model matrix columns: c0 = X axis, c1 = Y axis, c2 = Z axis,
        // c3 = translation. The 3×3 part may carry non-uniform scale. Both
        // spaces are +Y up, so only translation needs the millimetre scale.
        let converted = simd_double3x3(
            SIMD3(columns[0], columns[1], columns[2]),
            SIMD3(columns[4], columns[5], columns[6]),
            SIMD3(columns[8], columns[9], columns[10]))
        let t = SIMD3(columns[12], columns[13], columns[14])
            * (1 / Double(millimetresPerMeter))
        return simd_float4x4(
            SIMD4(Float(converted.columns.0.x), Float(converted.columns.0.y),
                  Float(converted.columns.0.z), 0),
            SIMD4(Float(converted.columns.1.x), Float(converted.columns.1.y),
                  Float(converted.columns.1.z), 0),
            SIMD4(Float(converted.columns.2.x), Float(converted.columns.2.y),
                  Float(converted.columns.2.z), 0),
            SIMD4(Float(t.x), Float(t.y), Float(t.z), 1))
    }

    /// World-space model-millimetre point from a body transform.
    static func worldPoint(_ local: SIMD3<Float>, transform: simd_float4x4) -> SIMD3<Float> {
        let model = transform * SIMD4(local, 1)
        return point(SIMD3(model.x, model.y, model.z))
    }
}

// MARK: - Texture / material

nonisolated struct CADPresentationTexture: Equatable, Sendable {
    var slot: MaterialTextureSlot
    /// SHA-256 of the encoded image; also the presentation image cache key.
    var imageID: String
    var colorSpace: MaterialTextureColorSpace
    var orientation: MaterialTextureOrientation
    var byteCount: Int
}

nonisolated struct CADPresentationMaterial: Equatable, Sendable {
    var name: String?
    var libraryID: String?
    var baseColor: SIMD4<Float>
    var metallic: Float
    var roughness: Float
    var opacity: Float
    var emissive: SIMD3<Float>
    var emissiveStrength: Float
    var textures: [CADPresentationTexture]
    var uvMapping: CADMaterialUVMapping

    static let neutral = CADPresentationMaterial(
        name: nil,
        libraryID: nil,
        baseColor: SIMD4(0.72, 0.74, 0.78, 1),
        metallic: 0,
        roughness: 0,
        opacity: 1,
        emissive: .zero,
        emissiveStrength: 0,
        textures: [],
        uvMapping: .mesh)

    func texture(for slot: MaterialTextureSlot) -> CADPresentationTexture? {
        textures.first { $0.slot == slot }
    }

    var isTransparent: Bool { opacity < 0.999 }

    /// The UVs must be flipped when the encoded image's first row is its
    /// bottom row (Metal/RealityKit sample v=0 at the image top).
    var flipsV: Bool {
        guard let reference = texture(for: .baseColor) ?? textures.first else { return false }
        return reference.orientation == .bottomLeft
    }

    /// True when any authored image relies on a projection instead of the
    /// mesh's own UV set. The snapshot carries already-projected UVs for the
    /// body-level material; face-level materials cannot use them yet (see
    /// `CADPresentationIssue.faceMaterialDisplayUnsupported`).
    var usesProjectedUVs: Bool { uvMapping.source != .mesh }
}

// MARK: - Mesh / body

nonisolated struct CADPresentationMesh: Equatable, Sendable {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var indices: [UInt32]
    var uvs: [SIMD2<Float>]?
    var meshRevision: UInt64
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>

    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { positions.isEmpty || indices.isEmpty }

    /// Stable mesh identity for the resource cache: identical buffers reuse
    /// the same `MeshResource`; a revision bump alone does not force a rebuild
    /// when the bytes are unchanged.
    var cacheKey: String {
        var hasher = Hasher()
        hasher.combine(meshRevision)
        hasher.combine(positions.count)
        hasher.combine(normals.count)
        hasher.combine(indices.count)
        hasher.combine(uvs?.count ?? -1)
        if let first = indices.first { hasher.combine(first) }
        if let last = indices.last { hasher.combine(last) }
        if let first = positions.first { hasher.combine(first.x); hasher.combine(first.y); hasher.combine(first.z) }
        if let last = positions.last { hasher.combine(last.x); hasher.combine(last.y); hasher.combine(last.z) }
        return "mesh-\(meshRevision)-\(hasher.finalize())"
    }
}

nonisolated struct CADPresentationFaceMaterial: Equatable, Sendable {
    var faceIndex: Int
    var material: CADPresentationMaterial
}

/// A renderable face-material group: the triangles belong to the SAME body
/// mesh; they are grouped so one body can carry several materials without a
/// second geometry store.
nonisolated struct CADPresentationFaceGroup: Equatable, Sendable {
    var faceIndex: Int
    /// Authoritative mesh index-buffer values for this face, exactly as the
    /// document snapshot reports them (`CADSceneFaceMaterial.triangleIndices`).
    /// Never derived or guessed here.
    var indices: [UInt32]
    var material: CADPresentationMaterial
    /// UVs actually sampled by this face (snapshot render UVs when available,
    /// otherwise a per-face projection for a face-level mapping).
    var uvs: [SIMD2<Float>]?
}

nonisolated struct CADPresentationBody: Equatable, Sendable, Identifiable {
    /// Stable presentation entity identity. For an assembly instance this is
    /// the instance ID, never the source body's ID.
    var id: UUID
    /// Document body supplying this entity's mesh/material when the entity is
    /// an assembly instance. Nil for an ordinary body.
    var sourceBodyID: UUID? = nil
    var name: String
    var transform: simd_float4x4
    var mesh: CADPresentationMesh
    var material: CADPresentationMaterial
    /// Resolved face-level snapshots (descriptors for inspection).
    var faceMaterials: [CADPresentationFaceMaterial]
    /// Renderable groups correlated to this body's triangles. Empty when the
    /// binding could not be matched unambiguously or there are no bindings.
    var faceGroups: [CADPresentationFaceGroup]
    var unresolvedFaceCount: Int
    var analyticBRep: Bool

    var hasFaceOverrides: Bool { !faceGroups.isEmpty }

    /// Whether a material target selected in the document should preview this
    /// entity. A placed assembly instance answers for its source body's
    /// selection while keeping its own stable entity identity (`id`).
    func matchesMaterialTarget(_ ids: Set<UUID>) -> Bool {
        if ids.contains(id) { return true }
        guard let sourceBodyID else { return false }
        return ids.contains(sourceBodyID)
    }
}

// MARK: - Environment

nonisolated struct CADPresentationEnvironment: Equatable, Sendable {
    var kind: CADViewEnvironmentKind
    var lightIntensity: Float
    /// Model-space (+Z up) direction, unit length.
    var lightDirectionModel: SIMD3<Float>
    /// sRGB 0…1.
    var backgroundColor: SIMD3<Float>
    var floorVisible: Bool
    var floorColor: SIMD3<Float>
    /// Physical floor extent, millimetres.
    var floorSizeMM: Float
    var shadowsEnabled: Bool

    var backgroundColorLinear: SIMD3<Float> {
        // RealityKit renders in a linear working space; convert the authored
        // sRGB value so the floor/background match the Metal viewport and the
        // saved appearance.
        SIMD3(pow(backgroundColor.x, 2.2), pow(backgroundColor.y, 2.2),
              pow(backgroundColor.z, 2.2))
    }
}

// MARK: - Scene

nonisolated struct CADPresentationImage: Equatable, Sendable, Identifiable {
    var id: String
    var mimeType: String
    var bytes: Data
    var byteCount: Int
}

nonisolated struct CADPresentationBounds: Equatable, Sendable {
    var min: SIMD3<Float>
    var max: SIMD3<Float>

    var center: SIMD3<Float> { (min + max) * 0.5 }
    var size: SIMD3<Float> { max - min }
    var radius: Float {
        let half = size * 0.5
        return Swift.max(simd_length(half), 0.001)
    }
}

nonisolated enum CADPresentationIssueKind: String, Sendable {
    case emptyBody
    case malformedTransform
    case corruptMaterial
    case missingTexture
    case missingMeshUV
    case mixedTextureOrientation
    case faceMaterialDisplayUnsupported
    case unresolvedFaceBindings
    case imageDecodeFailed
}

nonisolated struct CADPresentationIssue: Equatable, Sendable, Identifiable {
    var id: String
    var kind: CADPresentationIssueKind
    var bodyID: UUID?
    var bodyName: String?
    var detail: String
}

nonisolated struct CADPresentationScene: Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Stable identity of the open package (absolute path); used to fence
    /// asynchronous work across documents.
    var documentKey: String
    var documentRevision: Int
    var changeCount: Int
    var contentSHA256: String
    var bodies: [CADPresentationBody]
    var images: [CADPresentationImage]
    var environment: CADPresentationEnvironment
    var issues: [CADPresentationIssue]
    var bounds: CADPresentationBounds?
    var materialCount: Int

    var isEmpty: Bool { bodies.isEmpty }

    /// Identity of everything a renderer consumes. A snapshot with an equal
    /// user-visible identity can reuse built entities.
    var buildKey: String {
        var parts: [String] = [
            documentKey, String(changeCount), String(documentRevision),
            contentSHA256, environment.stableKey,
        ]
        for body in bodies {
            parts.append("\(body.id.uuidString):\(body.sourceBodyID?.uuidString ?? "-"):\(body.mesh.cacheKey):\(body.material.stableKey):\(body.transform.stableKey)")
        }
        return parts.joined(separator: "|")
    }
}

// MARK: - Stable keys

nonisolated extension CADPresentationMaterial {
    var stableKey: String {
        var hasher = Hasher()
        hasher.combine(name)
        hasher.combine(libraryID)
        hasher.combine(baseColor)
        hasher.combine(metallic)
        hasher.combine(roughness)
        hasher.combine(opacity)
        hasher.combine(emissive)
        hasher.combine(emissiveStrength)
        for texture in textures {
            hasher.combine(texture.slot.rawValue)
            hasher.combine(texture.imageID)
            hasher.combine(texture.colorSpace.rawValue)
            hasher.combine(texture.orientation.rawValue)
        }
        hasher.combine(uvMapping.source.rawValue)
        hasher.combine(uvMapping.axis.rawValue)
        hasher.combine(uvMapping.scaleMM)
        hasher.combine(uvMapping.rotationDegrees)
        hasher.combine(uvMapping.offset)
        hasher.combine(uvMapping.flipU)
        hasher.combine(uvMapping.flipV)
        return "mat-\(hasher.finalize())"
    }
}

nonisolated extension CADPresentationEnvironment {
    var stableKey: String {
        var hasher = Hasher()
        hasher.combine(kind.rawValue)
        hasher.combine(lightIntensity)
        hasher.combine(lightDirectionModel)
        hasher.combine(backgroundColor)
        hasher.combine(floorVisible)
        hasher.combine(floorColor)
        hasher.combine(floorSizeMM)
        hasher.combine(shadowsEnabled)
        return "env-\(hasher.finalize())"
    }
}

nonisolated extension simd_float4x4 {
    var stableKey: String {
        var hasher = Hasher()
        for column in [columns.0, columns.1, columns.2, columns.3] {
            hasher.combine(column.x); hasher.combine(column.y)
            hasher.combine(column.z); hasher.combine(column.w)
        }
        return "xf-\(hasher.finalize())"
    }
}

// MARK: - Limits

nonisolated enum CADPresentationLimits {
    /// Bodies beyond this are omitted with a reported issue rather than
    /// allocating unbounded GPU resources.
    static let maximumBodies = 4_096
    static let maximumTrianglesPerScene = 8_000_000
    static let maximumCachedMeshes = 256
    static let maximumCachedTextures = 256
    static let maximumCachedTextureBytes = 256 * 1024 * 1024
    static let maximumEnvironmentLUTSize = 512
}
#endif
