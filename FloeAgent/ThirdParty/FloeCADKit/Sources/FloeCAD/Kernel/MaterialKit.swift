//
//  MaterialKit.swift
//  FloeCADKit
//
//  Canonical custom-material vocabulary shared by the document model, the
//  material service, the query surface and the GLB exporter.
//
//  A material is pure data: PBR scalars, image maps with semantics/colour
//  space/orientation, and a UV mapping. It contains no scripts or custom
//  shaders and never changes geometry. Applied appearances are snapshots
//  (`BodyMaterialSpec`), so deleting a library entry cannot alter a body.
//

import CryptoKit
import Foundation
import simd

// MARK: - Identity

nonisolated struct MaterialID: Hashable, Codable, Sendable {
    let raw: UUID
    init() { self.raw = UUID() }
    init(raw: UUID) { self.raw = raw }
}

nonisolated struct MaterialTextureID: Hashable, Codable, Sendable {
    let raw: UUID
    init() { self.raw = UUID() }
    init(raw: UUID) { self.raw = raw }
}

// MARK: - Texture semantics

nonisolated enum MaterialTextureSlot: String, Codable, CaseIterable, Sendable {
    case baseColor
    case metallic
    case roughness
    case normal
    case emissive
    case opacity
}

nonisolated enum MaterialTextureColorSpace: String, Codable, Sendable {
    case srgb
    case linear
}

/// Where (0,0) of the encoded image is. Metal's convention is top-left;
/// glTF's UV convention is top-left too (v grows down), while an image whose
/// rows were authored bottom-up must be marked explicitly.
nonisolated enum MaterialTextureOrientation: String, Codable, Sendable {
    case topLeft
    case bottomLeft
}

nonisolated enum MaterialUVSource: String, Codable, Sendable {
    /// Sample the mesh's own UV set; no projection is generated.
    case mesh
    /// Orthographic projection of body-local millimetres onto a plane.
    case planarProjection
    /// Per-vertex dominant-axis projection (a deterministic box projection).
    case boxProjection
}

nonisolated enum MaterialProjectionAxis: String, Codable, Sendable {
    case x, y, z
}

nonisolated struct CADMaterialUVMapping: Codable, Equatable, Sendable {
    var source: MaterialUVSource = .mesh
    var axis: MaterialProjectionAxis = .z
    /// Physical tile size in millimetres. Values are clamped to > 0.
    var scaleMM: SIMD2<Double> = SIMD2(100, 100)
    var rotationDegrees: Double = 0
    var offset: SIMD2<Double> = .zero
    var flipU: Bool = false
    var flipV: Bool = false

    static let mesh = CADMaterialUVMapping(source: .mesh)

    init(source: MaterialUVSource = .mesh,
         axis: MaterialProjectionAxis = .z,
         scaleMM: SIMD2<Double> = SIMD2(100, 100),
         rotationDegrees: Double = 0,
         offset: SIMD2<Double> = .zero,
         flipU: Bool = false,
         flipV: Bool = false) {
        self.source = source
        self.axis = axis
        self.scaleMM = scaleMM
        self.rotationDegrees = rotationDegrees
        self.offset = offset
        self.flipU = flipU
        self.flipV = flipV
    }

    var sanitized: CADMaterialUVMapping {
        var map = self
        if !(map.scaleMM.x.isFinite && map.scaleMM.x > 0) { map.scaleMM.x = 100 }
        if !(map.scaleMM.y.isFinite && map.scaleMM.y > 0) { map.scaleMM.y = 100 }
        map.scaleMM.x = min(max(map.scaleMM.x, 1e-4), 1e6)
        map.scaleMM.y = min(max(map.scaleMM.y, 1e-4), 1e6)
        if !map.rotationDegrees.isFinite { map.rotationDegrees = 0 }
        map.rotationDegrees = min(max(map.rotationDegrees, -3600), 3600)
        if !map.offset.x.isFinite { map.offset.x = 0 }
        if !map.offset.y.isFinite { map.offset.y = 0 }
        return map
    }
}

// MARK: - Textures and definitions

/// The typed description of one image map. `BodyMaterialSpec` embeds both this
/// metadata and the bytes; exporters use it to choose colour space and the
/// orientation transform.
nonisolated struct CADMaterialTextureMetadata: Codable, Equatable, Sendable {
    var assetID: UUID
    var slot: MaterialTextureSlot
    var mimeType: String
    var colorSpace: MaterialTextureColorSpace
    var orientation: MaterialTextureOrientation
    var sha256: String
    var byteCount: Int

    /// The persisted digest, but only when it actually describes `data`.
    ///
    /// Metadata can outlive the bytes it was written for (a re-encoded,
    /// truncated or swapped asset, or a copied label). A matching byte count is
    /// not proof: the digest is accepted only when it equals the actual
    /// SHA-256 of the current content. The actual digest is retained in the
    /// bounded content cache even when the claim is rejected, so a subsequent
    /// legacy/stale identity lookup does not hash the same bytes twice.
    func verifiedDigest(for data: Data) -> String? {
        guard byteCount == data.count,
              sha256.count == 64,
              sha256.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)       // 0-9
                      || (scalar.value >= 65 && scalar.value <= 70) // A-F
                      || (scalar.value >= 97 && scalar.value <= 102) // a-f
              })
        else { return nil }
        let actual = CADMaterialTexture.cachedActualContentDigest(data, assetID: assetID)
        return sha256.lowercased() == actual ? actual : nil
    }
}

nonisolated struct CADMaterialTexture: Codable, Equatable, Sendable, Identifiable {
    var id: MaterialTextureID
    var slot: MaterialTextureSlot
    var name: String
    var mimeType: String
    var colorSpace: MaterialTextureColorSpace
    var orientation: MaterialTextureOrientation
    var bytes: Data
    var sha256: String

    init(id: MaterialTextureID = MaterialTextureID(),
         slot: MaterialTextureSlot,
         name: String? = nil,
         mimeType: String? = nil,
         colorSpace: MaterialTextureColorSpace? = nil,
         orientation: MaterialTextureOrientation = .topLeft,
         bytes: Data) {
        self.id = id
        self.slot = slot
        if let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty {
            self.name = String(trimmed.prefix(120))
        } else {
            self.name = slot.rawValue
        }
        let detected = MaterialImageSniffer.mimeType(of: bytes)
        self.mimeType = MaterialImageSniffer.normalizedMimeType(mimeType) ?? detected ?? "application/octet-stream"
        self.colorSpace = colorSpace
            ?? (slot == .baseColor || slot == .emissive ? .srgb : .linear)
        self.orientation = orientation
        self.bytes = bytes
        self.sha256 = Self.digest(bytes)
    }

    var metadata: CADMaterialTextureMetadata {
        CADMaterialTextureMetadata(assetID: id.raw, slot: slot, mimeType: mimeType,
                                   colorSpace: colorSpace, orientation: orientation,
                                   sha256: sha256, byteCount: bytes.count)
    }

    func sanitized() -> CADMaterialTexture? {
        guard MaterialImageSniffer.normalizedMimeType(mimeType) != nil,
              MaterialImageSniffer.mimeType(of: bytes) != nil,
              bytes.count <= CADMaterialLimits.maximumTextureBytes else { return nil }
        var copy = self
        copy.name = String(name.prefix(120))
        copy.sha256 = Self.digest(bytes)
        return copy
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Actual full-content digest for legacy images (no metadata) and for
    /// stale/mismatched metadata. The SHA-256 is computed once per exact bytes
    /// bucket and retained (including when a claimed digest was rejected), so
    /// the Editor identity fallback never needs a second full hash for the same
    /// image. Cache hits require full `Data` equality.
    static func cachedActualContentDigest(_ data: Data, assetID: UUID?) -> String {
        let key = MaterialContentDigestCache.Key(
            assetID: assetID,
            byteCount: data.count,
            footprint: cacheFootprint(data))
        if let cached = materialContentDigestCache.digest(for: key, matching: data) {
            return cached
        }
        let digest = Self.digest(data)
        materialContentDigestCache.store(digest, data: data, for: key)
        return digest
    }

    /// Cheap sample used only to choose a candidate cache bucket. It is never
    /// trusted as an identity; full `Data` equality remains mandatory.
    static func cacheFootprint(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ slice: Data) {
            for byte in slice {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
        }
        mix(data.prefix(64))
        if data.count > 192 { mix(data.dropFirst(data.count / 2).prefix(64)) }
        mix(data.suffix(64))
        return hash
    }
}

nonisolated struct CADMaterialDefinition: Codable, Equatable, Sendable, Identifiable {
    var id: MaterialID
    var name: String
    var baseColor: SIMD4<Double>
    var metallic: Double
    var roughness: Double
    var opacity: Double
    var emissive: SIMD3<Double>
    var emissiveStrength: Double
    var textures: [CADMaterialTexture]
    var uvMapping: CADMaterialUVMapping
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    init(id: MaterialID = MaterialID(),
         name: String,
         baseColor: SIMD4<Double> = SIMD4(0.72, 0.74, 0.78, 1),
         metallic: Double = 0,
         roughness: Double = 0.5,
         opacity: Double = 1,
         emissive: SIMD3<Double> = .zero,
         emissiveStrength: Double = 0,
         textures: [CADMaterialTexture] = [],
         uvMapping: CADMaterialUVMapping = .mesh,
         revision: Int = 1,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.baseColor = baseColor
        self.metallic = metallic
        self.roughness = roughness
        self.opacity = opacity
        self.emissive = emissive
        self.emissiveStrength = emissiveStrength
        self.textures = textures
        self.uvMapping = uvMapping
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func texture(for slot: MaterialTextureSlot) -> CADMaterialTexture? {
        textures.first { $0.slot == slot }
    }

    /// One validated, bounded copy. Duplicate slots are resolved in favour of
    /// the FIRST entry, unknown/invalid images are dropped, and all scalars are
    /// clamped. Never throws: a corrupt entry becomes a safe material rather
    /// than losing the body's geometry.
    var sanitized: CADMaterialDefinition {
        var copy = self
        copy.name = Self.sanitizedName(name)
        copy.baseColor = simd_clamp(baseColor, SIMD4(repeating: 0), SIMD4(repeating: 1))
        copy.metallic = min(max(metallic.isFinite ? metallic : 0, 0), 1)
        copy.roughness = min(max(roughness.isFinite ? roughness : 0.5, 0), 1)
        copy.opacity = min(max(opacity.isFinite ? opacity : 1, 0), 1)
        copy.emissive = simd_clamp(emissive, SIMD3(repeating: 0), SIMD3(repeating: 1))
        copy.emissiveStrength = min(max(emissiveStrength.isFinite ? emissiveStrength : 0, 0), 100)
        copy.uvMapping = uvMapping.sanitized
        copy.revision = max(revision, 1)
        var seen = Set<MaterialTextureSlot>()
        var kept: [CADMaterialTexture] = []
        for texture in textures {
            guard !seen.contains(texture.slot),
                  let clean = texture.sanitized() else { continue }
            seen.insert(clean.slot)
            kept.append(clean)
            if kept.count >= MaterialTextureSlot.allCases.count { break }
        }
        copy.textures = kept
        return copy
    }

    static func sanitizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Material" : trimmed).prefix(120))
    }

    /// Build an applied body appearance. The snapshot is complete: it carries
    /// every map and its metadata, so later library edits/deletions do not
    /// retroactively change the body.
    func bodyMaterialSpec() -> BodyMaterialSpec {
        let clean = sanitized
        func bytes(_ slot: MaterialTextureSlot) -> Data? {
            clean.texture(for: slot)?.bytes
        }
        return BodyMaterialSpec(
            baseColor: clean.baseColor,
            metallic: clean.metallic,
            roughness: clean.roughness,
            baseColorTexture: bytes(.baseColor),
            materialID: clean.id.raw.uuidString,
            materialName: clean.name,
            opacity: clean.opacity,
            emissive: clean.emissive,
            emissiveStrength: clean.emissiveStrength,
            roughnessTexture: bytes(.roughness),
            metallicTexture: bytes(.metallic),
            normalTexture: bytes(.normal),
            emissiveTexture: bytes(.emissive),
            opacityTexture: bytes(.opacity),
            uvMapping: clean.uvMapping,
            textureMetadata: clean.textures.map(\.metadata)
        ).clamped
    }

    /// Convert an existing applied legacy appearance into a reusable library
    /// definition (Material sheet "Save to library").
    init(spec: BodyMaterialSpec, name: String? = nil, id: MaterialID = MaterialID()) {
        let clean = spec.clamped
        var textures: [CADMaterialTexture] = []
        func append(_ slot: MaterialTextureSlot, _ data: Data?) {
            guard let data, !data.isEmpty,
                  MaterialImageSniffer.mimeType(of: data) != nil else { return }
            textures.append(CADMaterialTexture(slot: slot, bytes: data))
        }
        append(.baseColor, clean.baseColorTexture)
        append(.roughness, clean.roughnessTexture)
        append(.metallic, clean.metallicTexture)
        append(.normal, clean.normalTexture)
        append(.emissive, clean.emissiveTexture)
        append(.opacity, clean.opacityTexture)
        let resolvedName = name ?? clean.materialName ?? "Material"
        self.init(id: id,
                  name: resolvedName,
                  baseColor: clean.baseColor,
                  metallic: clean.metallic,
                  roughness: clean.roughness,
                  opacity: clean.effectiveOpacity,
                  emissive: clean.emissive ?? .zero,
                  emissiveStrength: clean.emissiveStrength ?? 0,
                  textures: textures,
                  uvMapping: clean.uvMapping ?? .mesh)
        self.uvMapping = clean.uvMapping ?? .mesh
    }

    /// JSON-facing metadata (never includes image bytes).
    var summaryJSON: [String: Any] {
        func textureJSON(_ texture: CADMaterialTexture) -> [String: Any] {
            [
                "id": texture.id.raw.uuidString,
                "slot": texture.slot.rawValue,
                "name": texture.name,
                "mime_type": texture.mimeType,
                "color_space": texture.colorSpace.rawValue,
                "orientation": texture.orientation.rawValue,
                "sha256": texture.sha256,
                "byte_count": texture.bytes.count,
            ]
        }
        return [
            "id": id.raw.uuidString,
            "name": name,
            "base_color": [baseColor.x, baseColor.y, baseColor.z, baseColor.w],
            "metallic": metallic,
            "roughness": roughness,
            "opacity": opacity,
            "emissive": [emissive.x, emissive.y, emissive.z],
            "emissive_strength": emissiveStrength,
            "uv_mapping": uvMapping.jsonObject,
            "textures": textures.map(textureJSON),
            "revision": revision,
        ]
    }
}

// MARK: - Applied appearance JSON

nonisolated extension BodyMaterialSpec {
    /// Typed, bounded (no bytes) description for query/tool replies.
    var summaryJSON: [String: Any] {
        var object: [String: Any] = [
            "base_color": [baseColor.x, baseColor.y, baseColor.z, baseColor.w],
            "metallic": metallic,
            "roughness": roughness,
            "opacity": effectiveOpacity,
            "emissive": emissive.map { [$0.x, $0.y, $0.z] } ?? [0, 0, 0],
            "emissive_strength": emissiveStrength ?? 0,
        ]
        if let materialID { object["material_id"] = materialID }
        if let materialName { object["name"] = materialName }
        if let uvMapping { object["uv_mapping"] = uvMapping.jsonObject }
        let metadata = textureMetadata ?? []
        if !metadata.isEmpty {
            object["textures"] = metadata.map { item -> [String: Any] in
                ["asset_id": item.assetID.uuidString,
                 "slot": item.slot.rawValue,
                 "mime_type": item.mimeType,
                 "color_space": item.colorSpace.rawValue,
                 "orientation": item.orientation.rawValue,
                 "sha256": item.sha256,
                 "byte_count": item.byteCount]
            }
        } else {
            var slots: [String] = []
            for slot in MaterialTextureSlot.allCases where textureData(for: slot) != nil {
                slots.append(slot.rawValue)
            }
            if !slots.isEmpty { object["texture_slots"] = slots }
        }
        return object
    }
}

// MARK: - Library

nonisolated struct CADMaterialLibrary: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var entries: [CADMaterialDefinition]
    var updatedAt: Date

    init(schemaVersion: Int = CADMaterialLibrary.currentSchemaVersion,
         entries: [CADMaterialDefinition] = [],
         updatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.updatedAt = updatedAt
    }

    func entry(_ id: MaterialID) -> CADMaterialDefinition? {
        entries.first { $0.id == id }
    }

    func entry(named name: String) -> CADMaterialDefinition? {
        entries.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    mutating func upsert(_ definition: CADMaterialDefinition) {
        let clean = definition.sanitized
        if let index = entries.firstIndex(where: { $0.id == clean.id }) {
            entries[index] = clean
        } else {
            guard entries.count < CADMaterialLimits.maximumLibraryEntries else { return }
            entries.append(clean)
        }
        updatedAt = Date()
    }

    @discardableResult
    mutating func remove(_ id: MaterialID) -> CADMaterialDefinition? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        updatedAt = Date()
        return entries.remove(at: index)
    }

    var sanitized: CADMaterialLibrary {
        var seen = Set<MaterialID>()
        var kept: [CADMaterialDefinition] = []
        for entry in entries {
            let clean = entry.sanitized
            guard seen.insert(clean.id).inserted else { continue }
            kept.append(clean)
            if kept.count >= CADMaterialLimits.maximumLibraryEntries { break }
        }
        return CADMaterialLibrary(schemaVersion: Self.currentSchemaVersion,
                                  entries: kept,
                                  updatedAt: updatedAt)
    }

    static let empty = CADMaterialLibrary()
}

// MARK: - Limits / decoding

nonisolated enum CADMaterialLimits {
    static let maximumTextureBytes = 8 * 1024 * 1024
    static let maximumLibraryEntries = 512
    static let maximumLibraryBytes = 96 * 1024 * 1024
    static let maximumEncodedRequestBytes = 12 * 1024 * 1024
}

// MARK: - Actual texture content digest cache

/// Bounded process-local cache of actual SHA-256 digests. The candidate key
/// `(assetID, byte count, sampled footprint)` only selects a bucket; the
/// digest is reused **only after full `Data` equality** with the exact retained
/// bytes. A changed blob therefore misses and is re-hashed instead of
/// inheriting a stale identity. Both entry count and retained encoded bytes are
/// bounded, so 128 large textures cannot pin unbounded memory. A single blob
/// larger than 64 MiB is hashed but not retained.
private final class MaterialContentDigestCache: @unchecked Sendable {
    struct Key: Hashable {
        let assetID: UUID?
        let byteCount: Int
        let footprint: UInt64
    }

    private struct Entry {
        let data: Data
        let digest: String
    }

    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var retainedBytes = 0
    /// Retain at most 64 MiB of encoded image bytes (Data is COW, so this is
    /// usually shared with the document's existing texture bytes) and at most
    /// 128 distinct texture buckets.
    private let maximumEntries = 128
    private let maximumRetainedBytes = 64 * 1024 * 1024

    func digest(for key: Key, matching data: Data) -> String? {
        lock.lock()
        let entry = entries[key]
        lock.unlock()
        guard let entry, entry.data == data else { return nil }
        return entry.digest
    }

    func store(_ digest: String, data: Data, for key: Key) {
        guard data.count <= maximumRetainedBytes else { return }
        lock.lock()
        defer { lock.unlock() }
        if let replaced = entries.updateValue(Entry(data: data, digest: digest),
                                              forKey: key) {
            retainedBytes -= replaced.data.count
        } else {
            order.append(key)
        }
        retainedBytes += data.count
        while (entries.count > maximumEntries
               || retainedBytes > maximumRetainedBytes),
              let evicted = order.first {
            order.removeFirst()
            if let removed = entries.removeValue(forKey: evicted) {
                retainedBytes -= removed.data.count
            }
        }
    }
}

private let materialContentDigestCache = MaterialContentDigestCache()

nonisolated enum CADMaterialLibraryCodec {
    /// Decode a persisted library. Corrupt/oversized data yields an empty
    /// library (the geometry and legacy body appearances stay intact).
    static func decode(_ data: Data?) -> CADMaterialLibrary {
        guard let data, !data.isEmpty, data.count <= CADMaterialLimits.maximumLibraryBytes else {
            return .empty
        }
        guard let library = try? JSONDecoder().decode(CADMaterialLibrary.self, from: data) else {
            return .empty
        }
        return library.sanitized
    }

    static func encode(_ library: CADMaterialLibrary) -> Data? {
        guard let data = try? JSONEncoder().encode(library.sanitized),
              data.count <= CADMaterialLimits.maximumLibraryBytes else { return nil }
        return data
    }
}

// MARK: - Image sniffing

nonisolated enum MaterialImageSniffer {
    static func mimeType(of data: Data) -> String? {
        guard data.count >= 8 else { return nil }
        let bytes = [UInt8](data.prefix(8))
        if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47,
           bytes[4] == 0x0D, bytes[5] == 0x0A, bytes[6] == 0x1A, bytes[7] == 0x0A {
            return "image/png"
        }
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        return nil
    }

    static func normalizedMimeType(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "image/png", "png": return "image/png"
        case "image/jpeg", "image/jpg", "jpeg", "jpg": return "image/jpeg"
        default: return nil
        }
    }
}

// MARK: - UV mapping / projection

nonisolated extension CADMaterialUVMapping {
    var jsonObject: [String: Any] {
        [
            "source": source.rawValue,
            "axis": axis.rawValue,
            "scale_mm": [scaleMM.x, scaleMM.y],
            "rotation_degrees": rotationDegrees,
            "offset": [offset.x, offset.y],
            "flip_u": flipU,
            "flip_v": flipV,
        ]
    }

    init?(json: [String: Any]) {
        guard let rawSource = json["source"] as? String,
              let source = MaterialUVSource(rawValue: rawSource) else { return nil }
        var map = CADMaterialUVMapping(source: source)
        if let rawAxis = json["axis"] as? String,
           let axis = MaterialProjectionAxis(rawValue: rawAxis) { map.axis = axis }
        if let scale = json["scale_mm"] as? [Double], scale.count == 2 {
            map.scaleMM = SIMD2(scale[0], scale[1])
        } else if let scale = json["scale_mm"] as? [NSNumber], scale.count == 2 {
            map.scaleMM = SIMD2(scale[0].doubleValue, scale[1].doubleValue)
        }
        if let rotation = json["rotation_degrees"] as? Double { map.rotationDegrees = rotation }
        if let offset = json["offset"] as? [Double], offset.count == 2 {
            map.offset = SIMD2(offset[0], offset[1])
        }
        if let flip = json["flip_u"] as? Bool { map.flipU = flip }
        if let flip = json["flip_v"] as? Bool { map.flipV = flip }
        self = map.sanitized
    }
}

nonisolated enum MaterialUVProjector {
    /// Generate render UVs from body-local positions WITHOUT touching the
    /// mesh. The projection is deterministic, uses physical millimetres and
    /// the material's scale/rotation/offset. Returns nil for `.mesh`.
    static func project(positions: [SIMD3<Float>],
                        normals: [SIMD3<Float>],
                        indices: [UInt32],
                        mapping: CADMaterialUVMapping) -> [SIMD2<Float>]? {
        let map = mapping.sanitized
        guard map.source != .mesh else { return nil }
        guard positions.count == normals.count else { return nil }
        let radians = map.rotationDegrees * .pi / 180
        let cosR = cos(radians)
        let sinR = sin(radians)
        var uvs = [SIMD2<Float>]()
        uvs.reserveCapacity(positions.count)
        // Triangle-local dominant axis for box projection gives stable seams
        // within each flat face instead of switching mid-triangle.
        var faceAxis = [MaterialProjectionAxis](repeating: map.axis,
                                                count: (indices.count / 3))
        if map.source == .boxProjection {
            for triangle in 0..<(indices.count / 3) {
                let i0 = Int(indices[triangle * 3])
                let i1 = Int(indices[triangle * 3 + 1])
                let i2 = Int(indices[triangle * 3 + 2])
                guard i0 < normals.count, i1 < normals.count, i2 < normals.count else { continue }
                let n = normals[i0] + normals[i1] + normals[i2]
                let absN = SIMD3(abs(n.x), abs(n.y), abs(n.z))
                faceAxis[triangle] = absN.x >= absN.y && absN.x >= absN.z
                    ? .x : (absN.y >= absN.z ? .y : .z)
            }
        }
        var vertexAxis = [MaterialProjectionAxis](repeating: map.axis,
                                                  count: positions.count)
        if map.source == .boxProjection {
            for triangle in 0..<(indices.count / 3) {
                for k in 0..<3 {
                    let index = Int(indices[triangle * 3 + k])
                    guard index < vertexAxis.count else { continue }
                    vertexAxis[index] = faceAxis[triangle]
                }
            }
        }
        for index in positions.indices {
            let p = positions[index]
            let axis = vertexAxis[index]
            let (u, v) = planeCoordinates(p, axis: axis)
            let rotatedU = Double(u) * cosR - Double(v) * sinR
            let rotatedV = Double(u) * sinR + Double(v) * cosR
            var finalU = (rotatedU / map.scaleMM.x) + map.offset.x
            var finalV = (rotatedV / map.scaleMM.y) + map.offset.y
            if map.flipU { finalU = -finalU }
            if map.flipV { finalV = -finalV }
            guard finalU.isFinite, finalV.isFinite else {
                uvs.append(.zero)
                continue
            }
            uvs.append(SIMD2(Float(finalU), Float(finalV)))
        }
        return uvs
    }

    /// Render UVs for one body + appearance: the mesh's own set when present,
    /// otherwise the material mapping. Never mutates `body`.
    static func renderUVs(for body: Body, material: BodyMaterialSpec?) -> [SIMD2<Float>]? {
        if let texcoords = body.render.texcoords, !texcoords.isEmpty {
            return texcoords
        }
        guard let material, material.hasAnyTexture,
              let mapping = material.uvMapping, mapping.source != .mesh else { return nil }
        return project(positions: body.render.positions,
                       normals: body.render.normals,
                       indices: body.render.indices,
                       mapping: mapping)
    }

    private static func planeCoordinates(_ p: SIMD3<Float>,
                                         axis: MaterialProjectionAxis) -> (Float, Float) {
        switch axis {
        case .x: return (p.y, p.z)
        case .y: return (p.x, p.z)
        case .z: return (p.x, p.y)
        }
    }
}
