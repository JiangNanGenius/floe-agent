//
//  GLBExporter.swift
//  openshape3d
//
//  glTF 2.0 binary (.glb) export from RenderMesh buffers. One node + mesh per
//  body (transform baked into world space, matching the other exporters), one
//  glTF material per distinct applied appearance, a real TEXCOORD_0 set when
//  the mesh has UVs or the material needs a generated projection, and embedded
//  PNG/JPEG image maps.
//
//  PBR: baseColorFactor (RGBA), metallicFactor, roughnessFactor, base colour
//  map, normal map, emissive map/factor (+ KHR_materials_emissive_strength) and
//  a packed metallic-roughness map when either scalar map is present. The
//  authored scalar stays on the material and multiplies the packed channel
//  (a missing channel is white). A zero emissive strength means no emission.
//  Declared map colour space is mapped to glTF's fixed slot semantics
//  (baseColor/emissive sRGB, scalar/normal linear); a bottom-up authored map
//  uses KHR_texture_transform. Packed opacity/MR maps are normalised to
//  top-left and combine straight-alpha RGB without a colour shift. A texture
//  never changes body geometry or its persisted `RenderMesh`.
//
//  Units/axes: FloeCAD model space is millimetres with +Y up (the ground plane
//  is XZ). glTF 2.0 is metres with +Y up, so the exported scene carries a root
//  node scale of 0.001 (mm -> m); the up axis already agrees and is not rotated.
//  No per-body transform is baked differently: positions are body-local mm and
//  the root converts them for every external viewer.
//

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import simd

/// Decode limits shared by GLB export/import image packing. They match the
/// viewport texture cache's bound (4096×4096, 64 MiB RGBA) so a compressed
/// image cannot make export allocate an unbounded bitmap. Checked from the
/// ImageIO header before creating a CGImage.
nonisolated enum CADImagePackingLimits {
    static let maximumDimension = 4096
    static let maximumPixelCount = 4096 * 4096
    static let maximumDecodedBytes = 64 * 1024 * 1024
}

nonisolated enum GLBExporter {

    // GLB container constants (glTF 2.0 §4: Binary glTF layout).
    static let magic: UInt32 = 0x46546C67          // "glTF"
    static let containerVersion: UInt32 = 2
    static let jsonChunkType: UInt32 = 0x4E4F534A  // "JSON"
    static let binChunkType: UInt32 = 0x004E4942   // "BIN\0"

    // Component types / targets from the glTF spec.
    private static let componentFloat = 5126
    private static let componentUInt32 = 5125
    private static let componentUInt16 = 5123
    private static let targetArrayBuffer = 34962
    private static let targetElementArrayBuffer = 34963

    private struct MaterialKey: Hashable {
        var name: String
        var baseColor: [Double]
        var metallic: Double
        var roughness: Double
        var opacity: Double
        var emissive: [Double]
        var emissiveStrength: Double
        var textures: [String]
    }

    private struct ExportMaterial {
        var key: MaterialKey
        var spec: BodyMaterialSpec
    }

    private struct TextureRecord {
        var imageIndex: Int
        var textureIndex: Int
    }

    static func glb(bodies: [Body],
                    faceTables: [BodyID: FaceTable] = [:],
                    faceTableRevisions: [BodyID: UInt64] = [:]) -> Data {
        var bin = Data()
        var bufferViews = [[String: Any]]()
        var accessors = [[String: Any]]()
        var meshes = [[String: Any]]()
        var nodes = [[String: Any]]()
        var images = [[String: Any]]()
        var textures = [[String: Any]]()
        var materialsJSON = [[String: Any]]()
        var textureRecords: [String: TextureRecord] = [:]
        var materialIndices: [MaterialKey: Int] = [:]
        var exportMaterials: [ExportMaterial] = []
        var extensionsUsed = Set<String>()

        func textureRecord(for data: Data) -> TextureRecord? {
            guard let mime = MaterialImageSniffer.mimeType(of: data),
                  Self.imageHeaderDimensions(data) != nil else {
                // A malformed/oversized image is omitted from the map list;
                // the material factors and all unrelated geometry still export.
                return nil
            }
            let key = MaterialTexture.digest(data)
            if let existing = textureRecords[key] { return existing }
            let view = appendView(data, to: &bin, views: &bufferViews, target: nil)
            let imageIndex = images.count
            images.append(["bufferView": view, "mimeType": mime])
            let textureIndex = textures.count
            textures.append(["sampler": 0, "source": imageIndex])
            let record = TextureRecord(imageIndex: imageIndex, textureIndex: textureIndex)
            textureRecords[key] = record
            return record
        }

        /// The glTF texture info for one record. glTF has no per-texture
        /// orientation field, so a bottom-up authored map uses the standard
        /// KHR_texture_transform V flip. The bytes stay untouched.
        func textureInfo(_ record: TextureRecord,
                         orientation: MaterialTextureOrientation) -> [String: Any] {
            var info: [String: Any] = ["index": record.textureIndex]
            if orientation == .bottomLeft {
                extensionsUsed.insert("KHR_texture_transform")
                info["extensions"] = [
                    "KHR_texture_transform": [
                        "offset": [0.0, 1.0],
                        "scale": [1.0, -1.0],
                    ],
                ]
            }
            return info
        }

        func materialIndex(for rawSpec: BodyMaterialSpec) -> Int {
            let spec = rawSpec.clamped
            var textureKeys: [String] = []
            for slot in MaterialTextureSlot.allCases {
                if let data = spec.textureData(for: slot) {
                    let metadata = Self.textureMetadata(slot: slot, in: spec)
                    textureKeys.append("\(slot.rawValue):\(MaterialTexture.digest(data)):"
                        + "\(metadata?.colorSpace.rawValue ?? "default"):"
                        + "\(metadata?.orientation.rawValue ?? "default")")
                }
            }
            let opacity = spec.effectiveOpacity
            let emission = Self.emissiveExport(spec)
            let key = MaterialKey(name: spec.materialName ?? "Material",
                                  baseColor: [spec.baseColor.x, spec.baseColor.y,
                                              spec.baseColor.z, opacity],
                                  metallic: spec.metallic,
                                  roughness: spec.roughness,
                                  opacity: opacity,
                                  emissive: emission?.factor ?? [0, 0, 0],
                                  emissiveStrength: emission?.strength ?? 0,
                                  textures: textureKeys.sorted())
            if let existing = materialIndices[key] { return existing }
            let index = exportMaterials.count
            exportMaterials.append(ExportMaterial(key: key, spec: spec))
            materialIndices[key] = index
            return index
        }

        /// UVs for one primitive. An explicit non-mesh mapping WINS (the
        /// caller asked for a projection); otherwise mesh UVs are used. A
        /// textured material with neither gets a deterministic box projection
        /// so the exported map is sampleable without changing geometry.
        func uvAccessor(for body: Body, material: BodyMaterialSpec?) -> Int? {
            let uvs: [SIMD2<Float>]?
            if let mapping = material?.uvMapping, mapping.source != .mesh {
                uvs = MaterialUVProjector.project(positions: body.render.positions,
                                                  normals: body.render.normals,
                                                  indices: body.render.indices,
                                                  mapping: mapping)
            } else if let meshUVs = body.render.texcoords,
                      meshUVs.count == body.render.positions.count {
                uvs = meshUVs
            } else if material?.hasAnyTexture == true {
                uvs = MaterialUVProjector.project(
                    positions: body.render.positions,
                    normals: body.render.normals,
                    indices: body.render.indices,
                    mapping: CADMaterialUVMapping(source: .boxProjection, axis: .y,
                                                  scaleMM: SIMD2(100, 100)))
            } else {
                uvs = nil
            }
            guard let uvs, uvs.count == body.render.positions.count else { return nil }
            let view = appendView(packed(uvs), to: &bin, views: &bufferViews,
                                  target: targetArrayBuffer)
            let accessor = accessors.count
            accessors.append([
                "bufferView": view,
                "componentType": componentFloat,
                "count": uvs.count,
                "type": "VEC2",
            ])
            return accessor
        }

        for body in bodies where !body.render.positions.isEmpty && !body.render.indices.isEmpty {
            let transform = body.transform
            var positions = [SIMD3<Float>]()
            positions.reserveCapacity(body.render.positions.count)
            var lo = SIMD3<Double>(repeating: .infinity)
            var hi = SIMD3<Double>(repeating: -.infinity)
            for p in body.render.positions {
                let world = transform.applying(to: SIMD3<Double>(p))
                lo = simd_min(lo, world)
                hi = simd_max(hi, world)
                positions.append(SIMD3<Float>(world))
            }
            var normals = [SIMD3<Float>]()
            normals.reserveCapacity(body.render.normals.count)
            for n in body.render.normals {
                // Uniform scale: rotating the normal is sufficient.
                let world = simd_normalize(transform.rotation.act(SIMD3<Double>(n)))
                normals.append(SIMD3<Float>(world))
            }

            let positionView = appendView(
                packed(positions), to: &bin, views: &bufferViews, target: targetArrayBuffer
            )
            let normalView = appendView(
                packed(normals), to: &bin, views: &bufferViews, target: targetArrayBuffer
            )

            let positionAccessor = accessors.count
            accessors.append([
                "bufferView": positionView,
                "componentType": componentFloat,
                "count": positions.count,
                "type": "VEC3",
                "min": [lo.x, lo.y, lo.z],
                "max": [hi.x, hi.y, hi.z],
            ])
            let normalAccessor = accessors.count
            accessors.append([
                "bufferView": normalView,
                "componentType": componentFloat,
                "count": normals.count,
                "type": "VEC3",
            ])

            let triangleCount = body.render.indices.count / 3
            var claimedTriangles = Set<Int>()
            struct FaceGroup {
                var faceIndex: Int
                var material: BodyMaterialSpec
                var triangles: [Int]
            }
            var faceGroups: [FaceGroup] = []
            var unresolvedFaceBindings: [[String: Any]] = []
            let table = faceTables[body.id]
            let tableIsFresh = table != nil
                && faceTableRevisions[body.id] == body.meshRevision
            let candidates = CADFaceMaterialResolver.candidates(for: body)

            for binding in body.materialFaceBindings {
                let materialName = binding.material.materialName ?? "Material"
                switch CADFaceMaterialResolver.match(binding.key, candidates: candidates) {
                case .resolved(let faceIndex, _):
                    guard tableIsFresh, let table else {
                        unresolvedFaceBindings.append([
                            "face_index": faceIndex,
                            "material": materialName,
                            "reason": "face_triangle_table_unavailable",
                        ])
                        continue
                    }
                    var scored: [(score: Double, triangles: [Int])] = []
                    for entry in table.entries {
                        guard let score = CADFaceMaterialResolver.score(
                            binding.key.signature, entry.signature) else { continue }
                        scored.append((score, entry.triangles))
                    }
                    scored.sort { $0.score > $1.score }
                    guard let best = scored.first,
                          best.score >= CADFaceMaterialResolver.matchThreshold else {
                        unresolvedFaceBindings.append([
                            "face_index": faceIndex,
                            "material": materialName,
                            "reason": "face_triangle_map_missing",
                        ])
                        continue
                    }
                    if scored.count > 1,
                       best.score - scored[1].score < CADFaceMaterialResolver.ambiguityMargin {
                        unresolvedFaceBindings.append([
                            "face_index": faceIndex,
                            "material": materialName,
                            "reason": "face_triangle_map_ambiguous",
                        ])
                        continue
                    }
                    let triangles = best.triangles
                    guard !triangles.isEmpty,
                          triangles.allSatisfy({ $0 >= 0 && $0 < triangleCount }),
                          triangles.allSatisfy({ !claimedTriangles.contains($0) }) else {
                        unresolvedFaceBindings.append([
                            "face_index": faceIndex,
                            "material": materialName,
                            "reason": "face_triangle_map_overlap_or_invalid",
                        ])
                        continue
                    }
                    for triangle in triangles { claimedTriangles.insert(triangle) }
                    faceGroups.append(FaceGroup(faceIndex: faceIndex,
                                                material: binding.material,
                                                triangles: triangles))
                case .ambiguous(let indices):
                    unresolvedFaceBindings.append([
                        "face_index": -1,
                        "candidate_indices": indices,
                        "material": materialName,
                        "reason": "ambiguous_face_signature",
                    ])
                case .unresolved(let reason):
                    unresolvedFaceBindings.append([
                        "face_index": binding.key.capturedIndex ?? -1,
                        "material": materialName,
                        "reason": reason,
                    ])
                }
            }

            func primitive(triangles: [Int], material: BodyMaterialSpec) -> [String: Any]? {
                var indices = [UInt32]()
                indices.reserveCapacity(triangles.count * 3)
                for triangle in triangles {
                    let base = triangle * 3
                    guard base + 2 < body.render.indices.count else { continue }
                    indices.append(body.render.indices[base])
                    indices.append(body.render.indices[base + 1])
                    indices.append(body.render.indices[base + 2])
                }
                guard !indices.isEmpty else { return nil }
                let indexView = appendView(packed(indices), to: &bin, views: &bufferViews,
                                           target: targetElementArrayBuffer)
                let indexAccessor = accessors.count
                accessors.append([
                    "bufferView": indexView,
                    "componentType": componentUInt32,
                    "count": indices.count,
                    "type": "SCALAR",
                ])
                var attributes: [String: Any] = [
                    "POSITION": positionAccessor,
                    "NORMAL": normalAccessor,
                ]
                if let uv = uvAccessor(for: body, material: material) {
                    attributes["TEXCOORD_0"] = uv
                }
                return [
                    "attributes": attributes,
                    "indices": indexAccessor,
                    "material": materialIndex(for: material),
                    "mode": 4,  // TRIANGLES
                ]
            }

            var primitives: [[String: Any]] = []
            let allTriangles = Array(0..<triangleCount)
            let remaining = allTriangles.filter { !claimedTriangles.contains($0) }
            if !remaining.isEmpty {
                let base = body.material ?? (faceGroups.isEmpty ? .default : BodyMaterialSpec.default)
                if let basePrimitive = primitive(triangles: remaining, material: base) {
                    primitives.append(basePrimitive)
                }
            }
            for group in faceGroups {
                if let facePrimitive = primitive(triangles: group.triangles,
                                                 material: group.material) {
                    primitives.append(facePrimitive)
                }
            }
            if primitives.isEmpty {
                // Degenerate indices: keep the exported node but no primitive.
                continue
            }

            var meshObject: [String: Any] = [
                "name": body.name,
                "primitives": primitives,
            ]
            if !body.materialFaceBindings.isEmpty {
                meshObject["extras"] = [
                    "floe_face_materials": faceGroups.map { group -> [String: Any] in
                        ["face_index": group.faceIndex,
                         "material": group.material.materialName ?? "Material",
                         "material_id": group.material.materialID ?? "",
                         "triangle_count": group.triangles.count]
                    },
                    "floe_unresolved_face_bindings": unresolvedFaceBindings,
                ]
            }
            let meshIndex = meshes.count
            meshes.append(meshObject)
            let node: [String: Any] = [
                "name": body.name,
                "mesh": meshIndex,
            ]
            nodes.append(node)
        }

        // glTF 2.0 is METRES with +Y up. The model is Y-up already; a single
        // root scale converts mm -> m for every downstream app. Keeping the
        // conversion at the root (instead of editing vertices) also makes the
        // unit contract inspectable in the JSON and reversible on import.
        var sceneRoots: [Int] = []
        if !nodes.isEmpty {
            let rootIndex = nodes.count
            nodes.append([
                "name": "FloeRoot",
                "children": Array(0..<rootIndex),
                "scale": [0.001, 0.001, 0.001],
                "extras": [
                    "floe_source_units": "millimetres",
                    "floe_source_up_axis": "+Y",
                    "gltf_units": "metres",
                    "gltf_up_axis": "+Y",
                ] as [String: Any],
            ])
            sceneRoots = [rootIndex]
        }

        // Build the material JSON now that every referenced texture exists.
        for entry in exportMaterials {
            let spec = entry.spec
            // glTF's base-colour alpha is the transparency channel. If the
            // material carries a separate opacity map, pack it into RGBA so
            // the transparency is actually exported instead of ignored.
            let baseMetadata = Self.textureMetadata(slot: .baseColor, in: spec)
            let opacityMetadata = Self.textureMetadata(slot: .opacity, in: spec)
            let packedBase = spec.opacityTexture == nil ? nil
                : packBaseColorWithOpacity(
                    base: spec.baseColorTexture,
                    baseOrientation: baseMetadata?.orientation ?? .topLeft,
                    baseColorSpace: baseMetadata?.colorSpace ?? .srgb,
                    opacity: spec.opacityTexture,
                    opacityOrientation: opacityMetadata?.orientation ?? .topLeft,
                    opacityColorSpace: opacityMetadata?.colorSpace ?? .linear,
                    alpha: spec.effectiveOpacity)
            let baseData: Data?
            if let packedBase {
                baseData = packedBase
            } else if let rawBase = spec.baseColorTexture {
                // glTF's base-colour texture is sRGB. A map declared linear
                // must be encoded once so external viewers see the same code
                // values the engineering shader samples. This also keeps the
                // base colour when a separate opacity map could not be packed.
                baseData = Self.colorTextureData(
                    rawBase, colorSpace: baseMetadata?.colorSpace ?? .srgb)
                    ?? rawBase
            } else {
                baseData = nil
            }
            let baseOrientation: MaterialTextureOrientation
            if spec.opacityTexture != nil, packedBase != nil {
                // The packer already normalised both inputs to top-left.
                baseOrientation = .topLeft
            } else {
                baseOrientation = baseMetadata?.orientation ?? .topLeft
            }
            var baseColorFactor = entry.key.baseColor
            if spec.opacityTexture != nil {
                // The packed RGBA already contains the opacity factor; a
                // failed pack falls back to the scalar alpha instead.
                baseColorFactor[3] = packedBase == nil ? spec.effectiveOpacity : 1.0
            }
            var pbr: [String: Any] = [
                "baseColorFactor": baseColorFactor,
                "metallicFactor": spec.metallic,
                "roughnessFactor": spec.roughness,
            ]
            if let baseData, let record = textureRecord(for: baseData) {
                pbr["baseColorTexture"] = textureInfo(record, orientation: baseOrientation)
            }
            // Packed glTF metallic-roughness map (G = roughness, B = metal).
            // The authored scalar factor applies to the channel exactly like
            // glTF/RealityKit/engineering (`factor × map`); it is never reset
            // to 1 just because a map exists. A missing map channel is white
            // (255), which is the identity for its factor.
            let metallicMetadata = Self.textureMetadata(slot: .metallic, in: spec)
            let roughnessMetadata = Self.textureMetadata(slot: .roughness, in: spec)
            let packedMR = packMetallicRoughness(
                metallic: spec.metallicTexture,
                metallicOrientation: metallicMetadata?.orientation ?? .topLeft,
                metallicColorSpace: metallicMetadata?.colorSpace ?? .linear,
                roughness: spec.roughnessTexture,
                roughnessOrientation: roughnessMetadata?.orientation ?? .topLeft,
                roughnessColorSpace: roughnessMetadata?.colorSpace ?? .linear)
            if let packedMR, let record = textureRecord(for: packedMR) {
                // packMetallicRoughness emits top-left rows.
                pbr["metallicRoughnessTexture"] = textureInfo(record, orientation: .topLeft)
            }
            var material: [String: Any] = [
                "name": entry.key.name,
                "pbrMetallicRoughness": pbr,
            ]
            if let data = spec.normalTexture, let record = textureRecord(for: data) {
                let orientation = Self.textureMetadata(slot: .normal, in: spec)?
                    .orientation ?? .topLeft
                var info = textureInfo(record, orientation: orientation)
                info["scale"] = 1.0
                material["normalTexture"] = info
            }
            if let emission = Self.emissiveExport(spec) {
                // Engineering/Present use emissive.rgb × strength; a zero
                // strength therefore means no emission even when RGB is set.
                // glTF's emissiveFactor is bounded to 1, so strengths ≤ 1
                // scale the factor and strengths > 1 use the KHR extension.
                material["emissiveFactor"] = emission.factor
                if let data = spec.emissiveTexture {
                    let metadata = Self.textureMetadata(slot: .emissive, in: spec)
                    let exportData = Self.colorTextureData(
                        data, colorSpace: metadata?.colorSpace ?? .srgb) ?? data
                    if let record = textureRecord(for: exportData) {
                        material["emissiveTexture"] = textureInfo(
                            record, orientation: metadata?.orientation ?? .topLeft)
                    }
                }
                if emission.strength > 1 {
                    extensionsUsed.insert("KHR_materials_emissive_strength")
                    material["extensions"] = [
                        "KHR_materials_emissive_strength": [
                            "emissiveStrength": emission.strength,
                        ],
                    ]
                }
            }
            if entry.key.opacity < 0.999 || spec.opacityTexture != nil {
                material["alphaMode"] = "BLEND"
            }
            materialsJSON.append(material)
        }

        var json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "FloeCAD"],
            "scene": 0,
            "scenes": [["nodes": sceneRoots]],
            "nodes": nodes,
            "meshes": meshes,
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": bin.count]],
            "materials": materialsJSON,
        ]
        if !images.isEmpty {
            json["images"] = images
            json["textures"] = textures
            json["samplers"] = [[
                "magFilter": 9729,   // LINEAR
                "minFilter": 9987,   // LINEAR_MIPMAP_LINEAR
                "wrapS": 10497,      // REPEAT
                "wrapT": 10497,
            ]]
        }
        if !extensionsUsed.isEmpty {
            json["extensionsUsed"] = extensionsUsed.sorted()
        }

        // JSONSerialization never fails for this plist-safe dictionary.
        var jsonData = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
            ?? Data()
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }  // pad with spaces
        while bin.count % 4 != 0 { bin.append(0x00) }
        // Keep the declared buffer length consistent with the padded chunk.
        if var buffers = json["buffers"] as? [[String: Any]], !buffers.isEmpty {
            buffers[0]["byteLength"] = bin.count
            json["buffers"] = buffers
            jsonData = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
                ?? Data()
            while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        }

        var out = Data()
        appendU32(magic, to: &out)
        appendU32(containerVersion, to: &out)
        appendU32(UInt32(12 + 8 + jsonData.count + 8 + bin.count), to: &out)
        appendU32(UInt32(jsonData.count), to: &out)
        appendU32(jsonChunkType, to: &out)
        out.append(jsonData)
        appendU32(UInt32(bin.count), to: &out)
        appendU32(binChunkType, to: &out)
        out.append(bin)
        return out
    }

    // MARK: - Helpers

    /// Appends `payload` to the BIN blob at a 4-byte boundary and records the
    /// bufferView; returns the view's index. `target == nil` for image bytes.
    private static func appendView(
        _ payload: Data, to bin: inout Data, views: inout [[String: Any]], target: Int?
    ) -> Int {
        while bin.count % 4 != 0 { bin.append(0x00) }
        let index = views.count
        var view: [String: Any] = [
            "buffer": 0,
            "byteOffset": bin.count,
            "byteLength": payload.count,
        ]
        if let target { view["target"] = target }
        views.append(view)
        bin.append(payload)
        return index
    }

    /// SIMD3<Float> has 16-byte stride; write tightly packed 12-byte triples.
    private static func packed(_ vectors: [SIMD3<Float>]) -> Data {
        var data = Data(capacity: vectors.count * 12)
        for v in vectors {
            withUnsafeBytes(of: v.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: v.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: v.z) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func packed(_ vectors: [SIMD2<Float>]) -> Data {
        var data = Data(capacity: vectors.count * 8)
        for v in vectors {
            withUnsafeBytes(of: v.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: v.y) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func packed(_ indices: [UInt32]) -> Data {
        var data = Data(capacity: indices.count * 4)
        for i in indices {
            withUnsafeBytes(of: i.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    // MARK: - PBR / image packing

    private struct EmissiveExport {
        /// `emissiveFactor` as glTF stores it (0…1).
        var factor: [Double]
        /// > 1 only when KHR_materials_emissive_strength is required.
        var strength: Double
    }

    /// The typed description for one slot, if the material carries one. The
    /// bytes stay authoritative; this only supplies colour space/orientation.
    private static func textureMetadata(slot: MaterialTextureSlot,
                                        in spec: BodyMaterialSpec)
        -> CADMaterialTextureMetadata? {
        spec.textureMetadata?.first { $0.slot == slot }
    }

    /// Engineering and Present both multiply emissive RGB by the strength
    /// (zero strength = no emission). Encode the same effective emission as
    /// one bounded glTF factor plus, only above 1, the KHR multiplier.
    private static func emissiveExport(_ spec: BodyMaterialSpec) -> EmissiveExport? {
        let strength = spec.emissiveStrength ?? 0
        let rgb = spec.emissive ?? .zero
        guard strength.isFinite, strength > 0,
              rgb.x > 0 || rgb.y > 0 || rgb.z > 0 else { return nil }
        if strength > 1 {
            return EmissiveExport(factor: [rgb.x, rgb.y, rgb.z], strength: strength)
        }
        return EmissiveExport(factor: [rgb.x * strength,
                                       rgb.y * strength,
                                       rgb.z * strength], strength: 0)
    }

    /// glTF has ONE metallic-roughness image (G = roughness, B = metallic).
    /// Combine the maps' luminance into that standard layout. Missing maps
    /// use white (1.0), the identity for the authored factor. The authored
    /// factors remain on the material; the renderers all compute factor×map.
    private static func packMetallicRoughness(
        metallic: Data?, metallicOrientation: MaterialTextureOrientation,
        metallicColorSpace: MaterialTextureColorSpace,
        roughness: Data?, roughnessOrientation: MaterialTextureOrientation,
        roughnessColorSpace: MaterialTextureColorSpace
    ) -> Data? {
        guard metallic != nil || roughness != nil else { return nil }
        let metalImage = metallic.flatMap(decodeImage)
        let roughImage = roughness.flatMap(decodeImage)
        guard metalImage != nil || roughImage != nil else { return nil }
        let width = min(max(metalImage?.width ?? 0, roughImage?.width ?? 0), 2048)
        let height = min(max(metalImage?.height ?? 0, roughImage?.height ?? 0), 2048)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let metalPixels = metalImage.flatMap {
            rgbaBytes($0, width: width, height: height, orientation: metallicOrientation)
        }
        let roughPixels = roughImage.flatMap {
            rgbaBytes($0, width: width, height: height, orientation: roughnessOrientation)
        }
        if metallic != nil, metalImage != nil, metalPixels == nil { return nil }
        if roughness != nil, roughImage != nil, roughPixels == nil { return nil }
        for pixel in 0..<(width * height) {
            let r = roughPixels.map {
                luminance($0, pixel, srgb: roughnessColorSpace == .srgb)
            } ?? 255
            let m = metalPixels.map {
                luminance($0, pixel, srgb: metallicColorSpace == .srgb)
            } ?? 255
            pixels[pixel * 4] = 255
            pixels[pixel * 4 + 1] = r
            pixels[pixel * 4 + 2] = m
            pixels[pixel * 4 + 3] = 255
        }
        return encodePNG(pixels: pixels, width: width, height: height)
    }

    /// glTF base-colour alpha also carries opacity. Pack the straight albedo
    /// RGB and the opacity map's luminance into one RGBA PNG. Changing the
    /// combined alpha must not change the base RGB: ImageIO backgrounds use
    /// premultiplied bytes, so `rgbaBytes` un-premultiplies and `encodePNG`
    /// re-premultiplies only for encoding (PNG itself stays straight alpha).
    private static func packBaseColorWithOpacity(
        base: Data?, baseOrientation: MaterialTextureOrientation,
        baseColorSpace: MaterialTextureColorSpace,
        opacity: Data?, opacityOrientation: MaterialTextureOrientation,
        opacityColorSpace: MaterialTextureColorSpace,
        alpha: Double
    ) -> Data? {
        guard opacity != nil else { return base }
        let baseImage = base.flatMap(decodeImage)
        let opacityImage = opacity.flatMap(decodeImage)
        // A supplied map that cannot be decoded (corrupt or over the bounded
        // decode limit) must not be replaced by white: fall back to the raw
        // base texture + scalar opacity instead of inventing new pixels.
        if base != nil, baseImage == nil { return nil }
        guard let opacityImage else { return nil }
        let width = min(max(baseImage?.width ?? 0, opacityImage.width), 2048)
        let height = min(max(baseImage?.height ?? 0, opacityImage.height), 2048)
        guard width > 0, height > 0 else { return nil }
        let basePixels = baseImage.flatMap {
            rgbaBytes($0, width: width, height: height, orientation: baseOrientation)
        }
        if baseImage != nil, basePixels == nil { return nil }
        guard let opacityPixels = rgbaBytes(opacityImage, width: width, height: height,
                                            orientation: opacityOrientation) else {
            return nil
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let factor = UInt8(((min(max(alpha, 0), 1)) * 255).rounded())
        let baseIsLinear = baseColorSpace == .linear
        for pixel in 0..<(width * height) {
            let base = pixel * 4
            let r = basePixels.map {
                encodedColorChannel($0[base], fromLinear: baseIsLinear)
            } ?? 255
            let g = basePixels.map {
                encodedColorChannel($0[base + 1], fromLinear: baseIsLinear)
            } ?? 255
            let b = basePixels.map {
                encodedColorChannel($0[base + 2], fromLinear: baseIsLinear)
            } ?? 255
            let baseAlpha = basePixels.map { $0[base + 3] } ?? 255
            let opacityValue = luminance(opacityPixels, pixel,
                                         srgb: opacityColorSpace == .srgb)
            pixels[base] = r
            pixels[base + 1] = g
            pixels[base + 2] = b
            // Combine albedo alpha, opacity map and the material factor into
            // the one channel glTF reads, without touching RGB.
            let product = Int(baseAlpha) * Int(opacityValue) * Int(factor)
            let combined = (product + (255 * 255 / 2)) / (255 * 255)
            pixels[base + 3] = UInt8(min(max(combined, 0), 255))
        }
        return encodePNG(pixels: pixels, width: width, height: height)
    }

    /// Exact sRGB transfer, matching `Shaders.metal`. Used only when a
    /// declared map colour space differs from glTF's fixed slot semantics.
    private static func linearToSRGB(_ value: Double) -> Double {
        let c = min(max(value, 0), 1)
        return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    private static func srgbToLinear(_ value: Double) -> Double {
        let c = min(max(value, 0), 1)
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func encodedColorChannel(_ value: UInt8,
                                            fromLinear: Bool) -> UInt8 {
        guard fromLinear else { return value }
        let converted = linearToSRGB(Double(value) / 255.0)
        return UInt8((min(max(converted, 0), 1) * 255).rounded())
    }

    /// Convert a declared-linear colour map to the sRGB encoding glTF expects
    /// for baseColor/emissive. sRGB maps and non-colour maps pass through
    /// byte-for-byte; a failed bounded decode falls back to the raw bytes.
    private static func colorTextureData(_ data: Data,
                                         colorSpace: MaterialTextureColorSpace) -> Data? {
        guard colorSpace == .linear else { return data }
        guard let decoded = decodeImage(data) else { return nil }
        let width = decoded.width
        let height = decoded.height
        guard let pixels = rgbaBytes(decoded, width: width, height: height,
                                     orientation: .topLeft) else { return nil }
        var converted = pixels
        var pixel = 0
        while pixel < converted.count {
            for channel in 0..<3 {
                converted[pixel + channel] = encodedColorChannel(
                    converted[pixel + channel], fromLinear: true)
            }
            pixel += 4
        }
        return encodePNG(pixels: converted, width: width, height: height)
    }

    /// Encode straight-alpha RGBA pixels as PNG. CGImage bitmap data is
    /// premultiplied, so premultiply a copy for the provider only; ImageIO
    /// then writes the straight-alpha PNG glTF expects.
    private static func encodePNG(pixels: [UInt8], width: Int, height: Int) -> Data? {
        guard pixels.count == width * height * 4 else { return nil }
        var premultiplied = pixels
        var pixel = 0
        while pixel < premultiplied.count {
            let a = Int(premultiplied[pixel + 3])
            if a == 0 {
                premultiplied[pixel] = 0
                premultiplied[pixel + 1] = 0
                premultiplied[pixel + 2] = 0
            } else if a < 255 {
                for channel in 0..<3 {
                    let value = Int(premultiplied[pixel + channel]) * a
                    premultiplied[pixel + channel] = UInt8((value + 127) / 255)
                }
            }
            pixel += 4
        }
        guard let provider = CGDataProvider(data: Data(premultiplied) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private struct DecodedImage {
        var width: Int
        var height: Int
        var image: CGImage
    }

    /// Header-only bounds check; no bitmap is allocated. Used both before
    /// decoding and before embedding an untouched texture.
    private static func imageHeaderDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= CADImagePackingLimits.maximumDimension,
              height <= CADImagePackingLimits.maximumDimension,
              width * height <= CADImagePackingLimits.maximumPixelCount,
              width * height * 4 <= CADImagePackingLimits.maximumDecodedBytes else {
            return nil
        }
        return (width, height)
    }

    private static func decodeImage(_ data: Data) -> DecodedImage? {
        guard imageHeaderDimensions(data) != nil,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0,
              image.width <= CADImagePackingLimits.maximumDimension,
              image.height <= CADImagePackingLimits.maximumDimension,
              image.width * image.height <= CADImagePackingLimits.maximumPixelCount,
              image.width * image.height * 4 <= CADImagePackingLimits.maximumDecodedBytes else {
            // A malformed/oversized header is rejected before ImageIO creates
            // a bitmap. Callers treat that slot as missing, so unrelated
            // geometry and the other material channels still export.
            return nil
        }
        return DecodedImage(width: image.width, height: image.height, image: image)
    }

    /// Decode one image into **straight-alpha**, top-left RGBA code values.
    /// `orientation == .bottomLeft` flips rows because packing needs a common
    /// row order; a single exported texture keeps its bytes and uses KHR
    /// transform instead.
    private static func rgbaBytes(_ decoded: DecodedImage, width: Int, height: Int,
                                  orientation: MaterialTextureOrientation = .topLeft)
        -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var drew = false
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .none
            context.draw(decoded.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            drew = true
        }
        guard drew else { return nil }
        unpremultiply(&bytes)
        if orientation == .bottomLeft {
            flipRows(&bytes, width: width, height: height)
        }
        return bytes
    }

    /// CGContext drawing stores premultiplied pixels; recover straight RGBA
    /// so luminance/copied RGB match what a GPU samples from the PNG.
    private static func unpremultiply(_ bytes: inout [UInt8]) {
        var pixel = 0
        while pixel < bytes.count {
            let a = Int(bytes[pixel + 3])
            if a == 0 {
                bytes[pixel] = 0
                bytes[pixel + 1] = 0
                bytes[pixel + 2] = 0
            } else if a < 255 {
                for channel in 0..<3 {
                    let value = Int(bytes[pixel + channel]) * 255
                    bytes[pixel + channel] = UInt8(min(255, (value + a / 2) / a))
                }
            }
            pixel += 4
        }
    }

    private static func flipRows(_ bytes: inout [UInt8], width: Int, height: Int) {
        let rowBytes = width * 4
        guard rowBytes > 0, height > 1 else { return }
        var flipped = bytes
        for row in 0..<height {
            let source = row * rowBytes
            let target = (height - 1 - row) * rowBytes
            flipped.replaceSubrange(target..<(target + rowBytes),
                                    with: bytes[source..<(source + rowBytes)])
        }
        bytes = flipped
    }

    private static func luminance(_ bytes: [UInt8], _ pixel: Int,
                                  srgb: Bool = false) -> UInt8 {
        let base = pixel * 4
        if srgb {
            // Declared sRGB scalar data: recover the linear code value first,
            // exactly like `sampleScalarMap` in Shaders.metal.
            let r = srgbToLinear(Double(bytes[base]) / 255.0)
            let g = srgbToLinear(Double(bytes[base + 1]) / 255.0)
            let b = srgbToLinear(Double(bytes[base + 2]) / 255.0)
            let value = (r * 54.0 + g * 183.0 + b * 19.0) / 256.0
            return UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        let value = (Int(bytes[base]) * 54 + Int(bytes[base + 1]) * 183
                     + Int(bytes[base + 2]) * 19) >> 8
        return UInt8(min(max(value, 0), 255))
    }
}

/// Local alias so this file does not depend on the naming of the shared
/// texture digest helper.
private enum MaterialTexture {
    static func digest(_ data: Data) -> String {
        CADMaterialTexture.digest(data)
    }
}
