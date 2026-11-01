//
//  OBJBundleExporter.swift
//  FloeCADKit
//
//  Complete Wavefront OBJ export: model.obj + model.mtl + relative texture
//  resources in one ZIP. This is the truthful "OBJ with materials" path; the
//  legacy single-file `OBJExporter.obj` remains a real OBJ containing geometry
//  and UVs only and never returns ZIP bytes under a .obj name.
//
//  Geometry contract (unchanged from the other exporters):
//    * one `o <name>` object per body, positions and normals baked to world
//      space, model unit = millimetre;
//    * positions and normals stay welded 1:1, so `v`/`vn` share an index;
//    * `vt` uses the OBJ bottom-left convention (the model's mesh UVs use the
//      Metal top-left convention, so V is flipped exactly once here);
//    * per-face material groups use separate `vt` entries, even when two groups
//      project the same vertex differently. Faces are always `v/vt/vn`.
//
//  Material contract:
//    * Kd/map_Kd, d/map_d, Pr/map_Pr, Pm/map_Pm, Ke/map_Ke and norm follow the
//      Wavefront/tinyobjloader PBR MTL extension. Those channels are extensions,
//      not universal MTL; the receipt says so instead of claiming every viewer
//      understands them;
//    * base alpha and the separate opacity map/factor become one grayscale
//      `map_d` (+ scalar `d`), because MTL has only one opacity channel;
//    * a scalar map declared sRGB is converted to linear luminance; a colour
//      map declared linear is encoded to sRGB. `.bottomLeft` maps are flipped
//      into top-row-first bytes. No metadata is silently relabelled;
//    * unsupported image orientation, HDR emission > 1, a declared-but-missing
//      image, a stale image identity, or a texture with no usable UVs refuses
//      the WHOLE export with an actionable diagnostic. There is no partial
//      bundle and no success-with-missing-files.
//
//  Container contract:
//    * a minimal STORED-entry ZIP built with the existing `MinimalZipWriter`
//      (no new ZIP dependency), deterministic entry order and names derived
//      from the slot + final SHA-256;
//    * every resource path is relative ASCII (`textures/...`), has no `..`,
//      no leading slash and no control/newline characters;
//    * the exporter validates the complete byte set before returning it. The
//      host still owns atomic single-file promotion/digest/read-back.
//

import Foundation
import CoreGraphics
import ImageIO
import simd

// MARK: - Result values

nonisolated struct OBJBundleDiagnostic: Sendable, Equatable {
    var code: String
    var bodyID: UUID?
    var textureSlot: MaterialTextureSlot?
    var message: String
}

nonisolated struct OBJBundleEntry: Sendable, Equatable {
    var path: String
    /// "obj", "mtl" or "texture".
    var role: String
    var byteCount: Int
    var sha256: String
    var mimeType: String?
}

nonisolated struct OBJBundleTexture: Sendable, Equatable {
    var path: String
    var mimeType: String
    var byteCount: Int
    var sha256: String
    /// Digest of the authored bytes, before any orientation/colour transform.
    var sourceSha256: String
    /// Slots that reference this exact resource after deduplication.
    var slots: [String]
    var normalized: Bool
    var note: String?
}

nonisolated struct OBJBundleMaterial: Sendable, Equatable {
    var name: String
    var sourceName: String
    var baseColor: [Double]
    var metallic: Double
    var roughness: Double
    var opacity: Double
    var emissive: [Double]
    var textures: [String: String]
    var bodyIDs: [UUID]
    var notes: [String]
}

nonisolated struct OBJBundleGroup: Sendable, Equatable {
    var material: String
    var faceIndex: Int?
    var triangleCount: Int
    var uvSource: String
    var generatedUV: Bool
}

nonisolated struct OBJBundleBody: Sendable, Equatable {
    var bodyID: UUID
    var name: String
    var vertexCount: Int
    var triangleCount: Int
    var vtCount: Int
    var groups: [OBJBundleGroup]
    var unresolvedFaceBindings: [String]
}

nonisolated struct OBJBundleReceipt: Sendable, Equatable {
    var entries: [OBJBundleEntry]
    var bodies: [OBJBundleBody]
    var materials: [OBJBundleMaterial]
    var textures: [OBJBundleTexture]
    var warnings: [String]
    var notes: [String]
    var totalBytes: Int
    var triangleCount: Int
    var vertexCount: Int
    var bundleSHA256: String

    /// JSON-safe receipt used by reports/tests. It deliberately contains no
    /// image bytes, only identities, counts and relative paths.
    var jsonObject: [String: Any] {
        [
            "format": "obj_bundle",
            "container": "zip",
            "unit": "mm",
            "up_axis": "+Y",
            "uv_convention": "OBJ bottom-left vt; image rows normalized top-row-first",
            "mtl_pbr_extension": ["Pr", "Pm", "Ke", "norm",
                                  "map_Pr", "map_Pm", "map_Ke"],
            "entry_count": entries.count,
            "entries": entries.map { entry -> [String: Any] in
                ["path": entry.path,
                 "role": entry.role,
                 "byte_count": entry.byteCount,
                 "sha256": entry.sha256,
                 "mime_type": entry.mimeType ?? ""]
            },
            "bodies": bodies.map { body -> [String: Any] in
                ["body_id": body.bodyID.uuidString,
                 "name": body.name,
                 "vertex_count": body.vertexCount,
                 "triangle_count": body.triangleCount,
                 "vt_count": body.vtCount,
                 "groups": body.groups.map { group -> [String: Any] in
                     ["material": group.material,
                      "face_index": group.faceIndex ?? -1,
                      "triangle_count": group.triangleCount,
                      "uv_source": group.uvSource,
                      "generated_uv": group.generatedUV]
                 },
                 "unresolved_face_bindings": body.unresolvedFaceBindings]
            },
            "materials": materials.map { material -> [String: Any] in
                ["name": material.name,
                 "source_name": material.sourceName,
                 "base_color": material.baseColor,
                 "metallic": material.metallic,
                 "roughness": material.roughness,
                 "opacity": material.opacity,
                 "emissive": material.emissive,
                 "textures": material.textures,
                 "body_ids": material.bodyIDs.map(\.uuidString),
                 "notes": material.notes]
            },
            "textures": textures.map { texture -> [String: Any] in
                ["path": texture.path,
                 "mime_type": texture.mimeType,
                 "byte_count": texture.byteCount,
                 "sha256": texture.sha256,
                 "source_sha256": texture.sourceSha256,
                 "slots": texture.slots,
                 "normalized": texture.normalized,
                 "note": texture.note ?? ""]
            },
            "warnings": warnings,
            "notes": notes,
            "total_bytes": totalBytes,
            "triangle_count": triangleCount,
            "vertex_count": vertexCount,
            "bundle_sha256": bundleSHA256,
        ]
    }

    var noteText: String {
        var parts = ["OBJ bundle (ZIP): model.obj + model.mtl + \(textures.count) texture(s)",
                     "\(materials.count) material(s)",
                     "\(triangleCount) triangle(s)"]
        if !warnings.isEmpty { parts.append("\(warnings.count) warning(s)") }
        return parts.joined(separator: ", ") + "; self-contained relative paths"
    }
}

nonisolated struct OBJBundleExportResult: Sendable, Equatable {
    var data: Data?
    var diagnostics: [OBJBundleDiagnostic]
    var receipt: OBJBundleReceipt?

    var succeeded: Bool { data != nil && diagnostics.isEmpty }
    var firstDiagnostic: OBJBundleDiagnostic? { diagnostics.first }
}

// MARK: - UI-facing plan / preflight

nonisolated struct OBJBundlePlanItem: Sendable, Equatable {
    var name: String
    var result: OBJBundleExportResult
}

/// One preflight build for the whole document or one bundle per body. The UI
/// presents this exact plan, and the confirm reuses it when the document has
/// not changed; no detached ad-hoc download is produced from a second path.
nonisolated struct OBJBundlePlan: Sendable, Equatable {
    var perBody: Bool
    var single: OBJBundleExportResult?
    var items: [OBJBundlePlanItem]

    var results: [OBJBundleExportResult] {
        if perBody { return items.map(\.result) }
        return single.map { [$0] } ?? []
    }

    var hasRefusal: Bool { results.contains { !$0.succeeded } }

    var firstDiagnostic: OBJBundleDiagnostic? {
        for result in results {
            if let diagnostic = result.firstDiagnostic { return diagnostic }
        }
        return nil
    }

    var warnings: [String] {
        Array(Set(results.compactMap(\.receipt).flatMap(\.warnings))).sorted()
    }

    var preflight: OBJBundlePreflight {
        let receipts = results.compactMap(\.receipt)
        return OBJBundlePreflight(
            perBody: perBody,
            // Per-body bundles are independent files; sum their contents so
            // the summary cannot imply one shared material/texture resource.
            materialCount: receipts.reduce(0) { $0 + $1.materials.count },
            textureCount: receipts.reduce(0) { $0 + $1.textures.count },
            fileCount: receipts.reduce(0) { $0 + $1.entries.count },
            byteCount: results.reduce(0) { $0 + ($1.data?.count ?? 0) },
            warnings: warnings,
            refusal: firstDiagnostic,
            isEmpty: results.isEmpty)
    }
}

nonisolated struct OBJBundlePreflight: Sendable, Equatable {
    var perBody: Bool
    var materialCount: Int
    var textureCount: Int
    var fileCount: Int
    var byteCount: Int
    var warnings: [String]
    var refusal: OBJBundleDiagnostic?
    var isEmpty: Bool

    var isReady: Bool { !isEmpty && refusal == nil }
}

// MARK: - Exporter

nonisolated enum OBJBundleExporter {
    static let formatName = "obj_bundle"
    static let objEntryPath = "model.obj"
    static let mtlEntryPath = "model.mtl"

    /// Bounded in-memory assembly. The host's own workspace write cap remains
    /// authoritative; this only prevents an unbounded bitmap/zip allocation.
    static let maximumBundleBytes = 96 * 1024 * 1024
    static let maximumGeometryBytes = 32 * 1024 * 1024
    static let maximumBodies = 512
    static let maximumMaterials = 1024
    static let maximumTextures = 512

    static let pbrExtensionWarning = "mtl_pbr_extension"
    static let uvConventionWarning = "obj_uv_bottom_left"
    static let faceFallbackWarning = "face_material_fallback"
    static let generatedUVWarning = "texture_uv_generated"
    static let scalarNormalizedWarning = "scalar_map_normalized"
    static let baseAlphaBakedWarning = "base_alpha_baked_to_map_d"
    static let opacitySemanticsWarning = "opacity_map_semantics"
    static let textureNormalizedWarning = "texture_rows_or_color_normalized"

    static func export(bodies: [Body],
                       faceTables: [BodyID: FaceTable] = [:],
                       faceTableRevisions: [BodyID: UInt64] = [:]) -> OBJBundleExportResult {
        if Task.isCancelled { return cancelledResult() }
        guard bodies.count <= maximumBodies else {
            return failure([diagnostic("obj_bundle_too_many_bodies",
                                      "The export is limited to \(maximumBodies) bodies; select fewer bodies and try again.")])
        }
        let candidates = bodies.filter {
            !$0.render.positions.isEmpty && !$0.render.indices.isEmpty
        }
        guard !candidates.isEmpty else {
            return failure([diagnostic("obj_bundle_empty_model",
                                      "Nothing to export — the design has no solid bodies.")])
        }

        var state = BuildState()
        state.warnings.insert(pbrExtensionWarning)
        state.warnings.insert(uvConventionWarning)
        if candidates.count < bodies.count {
            state.warnings.insert("empty_body_skipped")
        }
        state.obj.reserveCapacity(candidates.reduce(0) {
            $0 + $1.render.indices.count * 20 + $1.render.positions.count * 64
        })
        state.obj += objHeader

        for body in candidates {
            if Task.isCancelled { return cancelledResult() }
            if let issue = meshIssue(body) {
                state.diagnostics.append(diagnostic(
                    "obj_bundle_invalid_mesh",
                    "“\(body.name)” can't be exported: \(issue). Check the body in Edit and try again.",
                    bodyID: body.id.raw))
                continue
            }
            let resolved = resolveGroups(body: body,
                                         table: faceTables[body.id],
                                         tableRevision: faceTableRevisions[body.id],
                                         warnings: &state.warnings)
            var prepared: [(group: PreparedGroup, material: MaterialRef)] = []
            var materialFailure = false
            for group in resolved.groups {
                guard let material = prepareMaterial(group.material,
                                                     body: body,
                                                     state: &state) else {
                    materialFailure = true
                    break
                }
                prepared.append((group, material))
            }
            if materialFailure { continue }

            var bodyVTLines: [String] = []
            var vtTable: [UVKey: Int] = [:]
            var groupVTIndices: [[Int]] = []
            var groupReports: [OBJBundleGroup] = []
            var uvFailure = false
            for (group, material) in prepared {
                let outcome = effectiveUVs(for: body,
                                           material: group.material,
                                           needsUV: material.hasMaps)
                let uv: UVResolution
                switch outcome {
                case .resolved(let value):
                    uv = value
                case .failed(let code, let message):
                    state.diagnostics.append(diagnostic(code, message,
                                                       bodyID: body.id.raw))
                    uvFailure = true
                    continue
                }
                if let warning = uv.warning { state.warnings.insert(warning) }
                if uv.generated { state.warnings.insert(generatedUVWarning) }
                var indices: [Int] = []
                if let uvs = uv.uvs {
                    indices.reserveCapacity(group.triangles.count * 3)
                    for triangle in group.triangles {
                        let base = triangle * 3
                        guard base + 2 < body.render.indices.count else { continue }
                        for corner in 0..<3 {
                            let vertex = Int(body.render.indices[base + corner])
                            guard vertex >= 0, vertex < uvs.count else { continue }
                            let raw = uvs[vertex]
                            let u = raw.x == 0 ? Float(0) : raw.x
                            let v = raw.y == 0 ? Float(0) : raw.y
                            let key = UVKey(u: u.bitPattern, v: v.bitPattern)
                            if let existing = vtTable[key] {
                                indices.append(existing)
                            } else {
                                let index = vtTable.count
                                vtTable[key] = index
                                bodyVTLines.append("vt \(decimal(Double(u))) "
                                    + "\(decimal(1.0 - Double(v)))\n")
                                indices.append(index)
                            }
                        }
                    }
                }
                groupVTIndices.append(indices)
                groupReports.append(OBJBundleGroup(
                    material: material.name,
                    faceIndex: group.faceIndex,
                    triangleCount: group.triangles.count,
                    uvSource: uv.source,
                    generatedUV: uv.generated))
            }
            if uvFailure { continue }

            var bodyText = ""
            bodyText.reserveCapacity(bodyVTLines.count * 32
                + body.render.positions.count * 64
                + body.render.indices.count * 24)
            bodyText += "o \(objObjectName(body.name))\n"
            bodyText += "s off\n"
            let transform = body.transform
            for point in body.render.positions {
                let world = transform.applying(to: SIMD3<Double>(point))
                bodyText += "v \(decimal(world.x)) \(decimal(world.y)) \(decimal(world.z))\n"
            }
            for normal in body.render.normals {
                let world = simd_normalize(transform.rotation.act(SIMD3<Double>(normal)))
                bodyText += "vn \(decimal(world.x)) \(decimal(world.y)) \(decimal(world.z))\n"
            }
            for line in bodyVTLines { bodyText += line }
            for (index, entry) in prepared.enumerated() {
                bodyText += "usemtl \(entry.material.name)\n"
                let vts = groupVTIndices[index]
                for (corner, triangle) in entry.group.triangles.enumerated() {
                    let base = triangle * 3
                    guard base + 2 < body.render.indices.count else { continue }
                    let a = Int(body.render.indices[base]) + state.vertexOffset + 1
                    let b = Int(body.render.indices[base + 1]) + state.vertexOffset + 1
                    let c = Int(body.render.indices[base + 2]) + state.vertexOffset + 1
                    if vts.isEmpty {
                        bodyText += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
                    } else {
                        let offset = corner * 3
                        guard offset + 2 < vts.count else { continue }
                        let ta = vts[offset] + state.vtOffset + 1
                        let tb = vts[offset + 1] + state.vtOffset + 1
                        let tc = vts[offset + 2] + state.vtOffset + 1
                        bodyText += "f \(a)/\(ta)/\(a) \(b)/\(tb)/\(b) \(c)/\(tc)/\(c)\n"
                    }
                }
            }
            state.obj += bodyText
            state.vertexOffset += body.render.positions.count
            state.vtOffset += vtTable.count
            state.vertexCount += body.render.positions.count
            state.triangleCount += body.render.indices.count / 3
            state.bodyReports.append(OBJBundleBody(
                bodyID: body.id.raw,
                name: body.name,
                vertexCount: body.render.positions.count,
                triangleCount: body.render.indices.count / 3,
                vtCount: vtTable.count,
                groups: groupReports,
                unresolvedFaceBindings: resolved.unresolved))
        }

        if !state.diagnostics.isEmpty {
            return failure(state.diagnostics)
        }
        guard state.vertexOffset > 0, state.triangleCount > 0 else {
            return failure([diagnostic("obj_bundle_empty_model",
                                      "Nothing to export — the design has no solid bodies.")])
        }
        if Task.isCancelled { return cancelledResult() }

        let mtl = mtlText(state)
        guard let objData = state.obj.data(using: .utf8),
              let mtlData = mtl.data(using: .utf8) else {
            return failure([diagnostic("obj_bundle_encode_failed",
                                      "The OBJ text could not be encoded; nothing was written.")])
        }
        guard objData.count <= maximumGeometryBytes else {
            return failure([diagnostic("obj_bundle_too_large",
                                      "The OBJ geometry exceeds the \(maximumGeometryBytes / (1024 * 1024)) MB geometry limit. Reduce the mesh density and try again.")])
        }
        let textures = state.textureOrder.compactMap { state.textures[$0] }
        guard textures.count <= maximumTextures else {
            return failure([diagnostic("obj_bundle_too_large",
                                      "The bundle contains more than \(maximumTextures) texture resources. Reduce the number of distinct material images and try again.")])
        }
        if Task.isCancelled { return cancelledResult() }

        var projected = objData.count + mtlData.count
        for texture in textures { projected += texture.data.count }
        projected += 30 * (2 + textures.count) + 46 + (2 + textures.count) * 46
        guard projected <= maximumBundleBytes else {
            return failure([diagnostic("obj_bundle_too_large",
                                      "The OBJ bundle would be larger than \(maximumBundleBytes / (1024 * 1024)) MB. Reduce the texture sizes and try again; the source document is unchanged.")])
        }

        var zip = MinimalZipWriter()
        zip.addFile(path: objEntryPath, data: objData)
        zip.addFile(path: mtlEntryPath, data: mtlData)
        for texture in textures {
            zip.addFile(path: texture.path, data: texture.data)
        }
        let archive = zip.finish()
        guard archive.count <= maximumBundleBytes else {
            return failure([diagnostic("obj_bundle_too_large",
                                      "The final OBJ bundle exceeds \(maximumBundleBytes / (1024 * 1024)) MB. Reduce the texture sizes and try again; the source document is unchanged.")])
        }
        if Task.isCancelled { return cancelledResult() }

        var entries: [OBJBundleEntry] = [
            OBJBundleEntry(path: objEntryPath, role: "obj",
                           byteCount: objData.count,
                           sha256: CADMaterialTexture.digest(objData),
                           mimeType: "text/plain"),
            OBJBundleEntry(path: mtlEntryPath, role: "mtl",
                           byteCount: mtlData.count,
                           sha256: CADMaterialTexture.digest(mtlData),
                           mimeType: "text/plain"),
        ]
        for texture in textures {
            entries.append(OBJBundleEntry(path: texture.path, role: "texture",
                                          byteCount: texture.data.count,
                                          sha256: texture.sha256,
                                          mimeType: texture.mimeType))
        }
        let materials = state.mtlMaterials.enumerated().map { _, material in
            OBJBundleMaterial(
                name: material.name,
                sourceName: material.sourceName,
                baseColor: material.baseColor,
                metallic: material.metallic,
                roughness: material.roughness,
                opacity: material.opacity,
                emissive: material.emissive,
                textures: Dictionary(uniqueKeysWithValues: material.maps.map {
                    ($0.key.rawValue, $0.value)
                }),
                bodyIDs: material.bodyIDs.sorted { $0.uuidString < $1.uuidString },
                notes: material.notes.sorted())
        }
        let receipt = OBJBundleReceipt(
            entries: entries,
            bodies: state.bodyReports,
            materials: materials,
            textures: textures.map { texture in
                OBJBundleTexture(
                    path: texture.path,
                    mimeType: texture.mimeType,
                    byteCount: texture.data.count,
                    sha256: texture.sha256,
                    sourceSha256: texture.sourceSha256,
                    slots: texture.slots.map(\.rawValue).sorted(),
                    normalized: texture.normalized,
                    note: texture.note)
            },
            warnings: state.warnings.sorted(),
            notes: [
                "self_contained_relative_paths",
                "source_document_and_material_library_not_mutated",
                "plain_obj_remains_a_single_obj_without_materials",
            ],
            totalBytes: entries.reduce(0) { $0 + $1.byteCount },
            triangleCount: state.triangleCount,
            vertexCount: state.vertexCount,
            bundleSHA256: CADMaterialTexture.digest(archive))
        return OBJBundleExportResult(data: archive, diagnostics: [], receipt: receipt)
    }

    // MARK: - Headers

    private static let objHeader = """
    # Floe OBJ bundle (units: mm; up axis +Y)
    # Geometry is the world-space tessellation. UVs use the OBJ bottom-left vt
    # convention; image rows are normalized top-row-first.
    # Materials are in model.mtl (Wavefront MTL with the tinyobjloader PBR
    # extension: Pr/Pm/Ke/norm and map_Pr/map_Pm/map_Ke).
    mtllib model.mtl

    """

    private static let mtlHeader = """
    # Floe material library for model.obj (units: mm)
    # Kd/map_Kd, d/map_d, Pr/map_Pr, Pm/map_Pm, Ke/map_Ke and norm follow the
    # Wavefront/tinyobjloader PBR MTL extension. Some viewers only read
    # Kd/map_Kd/d/map_d; the export report lists that capability limit.
    # Kd/Ke are the applied display-encoded factors; map_Kd/map_Ke are sRGB.
    # Scalar maps are linear grayscale; map_d is grayscale luminance with the
    # scalar d factor applied by the viewer.

    """

    // MARK: - State

    private struct MaterialKey: Hashable {
        var baseColor: [Double]
        var metallic: Double
        var roughness: Double
        var opacity: Double
        var emissive: [Double]
        var mapDigests: [String]
    }

    private struct MaterialBuild {
        var name: String
        var sourceName: String
        var baseColor: [Double]
        var metallic: Double
        var roughness: Double
        var opacity: Double
        var emissive: [Double]
        var maps: [MaterialTextureSlot: String]
        var bodyIDs: Set<UUID>
        var notes: Set<String>
    }

    private struct TextureBuild {
        var path: String
        var mimeType: String
        var data: Data
        var sha256: String
        var sourceSha256: String
        var normalized: Bool
        var slots: Set<MaterialTextureSlot>
        var note: String?
    }

    private struct BuildState {
        var obj = ""
        var mtlMaterials: [MaterialBuild] = []
        var materialIndexByKey: [MaterialKey: Int] = [:]
        var usedMaterialNames = Set<String>()
        var textures: [String: TextureBuild] = [:]
        var textureOrder: [String] = []
        var warnings = Set<String>()
        var diagnostics: [OBJBundleDiagnostic] = []
        var bodyReports: [OBJBundleBody] = []
        var vertexOffset = 0
        var vtOffset = 0
        var vertexCount = 0
        var triangleCount = 0
    }

    private struct MaterialRef {
        var name: String
        var hasMaps: Bool
    }

    private struct PreparedGroup {
        var faceIndex: Int?
        var material: BodyMaterialSpec
        var triangles: [Int]
    }

    private struct UVKey: Hashable {
        var u: UInt32
        var v: UInt32
    }

    private struct UVResolution {
        var uvs: [SIMD2<Float>]?
        var source: String
        var generated: Bool
        var warning: String?
    }

    private enum UVOutcome {
        case resolved(UVResolution)
        case failed(code: String, message: String)
    }

    // MARK: - Groups

    private static func resolveGroups(body: Body,
                                      table: FaceTable?,
                                      tableRevision: UInt64?,
                                      warnings: inout Set<String>)
        -> (groups: [PreparedGroup], unresolved: [String]) {
        let triangleCount = body.render.indices.count / 3
        guard triangleCount > 0 else { return ([], []) }
        let tableIsFresh = table != nil && tableRevision == body.meshRevision
        let candidates = CADFaceMaterialResolver.candidates(for: body)
        var claimed = Set<Int>()
        var faceGroups: [PreparedGroup] = []
        var unresolved: [String] = []

        for binding in body.materialFaceBindings {
            let materialName = binding.material.materialName ?? "Material"
            let captured = binding.key.capturedIndex ?? -1
            switch CADFaceMaterialResolver.match(binding.key, candidates: candidates) {
            case .resolved(let faceIndex, _):
                guard tableIsFresh, let table else {
                    unresolved.append("face \(faceIndex) [\(materialName)]: face_triangle_table_unavailable")
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
                    unresolved.append("face \(faceIndex) [\(materialName)]: face_triangle_map_missing")
                    continue
                }
                if scored.count > 1,
                   best.score - scored[1].score < CADFaceMaterialResolver.ambiguityMargin {
                    unresolved.append("face \(faceIndex) [\(materialName)]: face_triangle_map_ambiguous")
                    continue
                }
                let triangles = best.triangles
                guard !triangles.isEmpty,
                      triangles.allSatisfy({ $0 >= 0 && $0 < triangleCount }),
                      triangles.allSatisfy({ !claimed.contains($0) }) else {
                    unresolved.append("face \(faceIndex) [\(materialName)]: face_triangle_map_overlap_or_invalid")
                    continue
                }
                for triangle in triangles { claimed.insert(triangle) }
                faceGroups.append(PreparedGroup(faceIndex: faceIndex,
                                                material: binding.material.clamped,
                                                triangles: triangles))
            case .ambiguous:
                unresolved.append("face \(captured) [\(materialName)]: ambiguous_face_signature")
            case .unresolved(let reason):
                unresolved.append("face \(captured) [\(materialName)]: face_signature_unresolved (\(reason))")
            }
        }

        if !unresolved.isEmpty { warnings.insert(faceFallbackWarning) }

        var groups: [PreparedGroup] = []
        let remaining = (0..<triangleCount).filter { !claimed.contains($0) }
        if !remaining.isEmpty {
            groups.append(PreparedGroup(faceIndex: nil,
                                        material: (body.material ?? .default).clamped,
                                        triangles: remaining))
        }
        groups.append(contentsOf: faceGroups)
        return (groups, unresolved)
    }

    // MARK: - UVs

    private static func effectiveUVs(for body: Body,
                                     material: BodyMaterialSpec,
                                     needsUV: Bool) -> UVOutcome {
        let mapping = material.uvMapping
        if needsUV, let mapping, mapping.source == .mesh,
           mapping.rotationDegrees != 0 || mapping.offset != .zero
               || mapping.flipU || mapping.flipV {
            return .failed(
                code: "obj_bundle_unsupported_mesh_uv_transform",
                message: "“\(material.materialName ?? "Material")” uses a mesh UV transform that OBJ can't carry. Choose a planar or box projection in Material and try again.")
        }
        if let uvs = MaterialUVProjector.effectiveUVs(
            meshTexcoords: body.render.texcoords,
            positions: body.render.positions,
            normals: body.render.normals,
            indices: body.render.indices,
            mapping: mapping) {
            if uvs.count == body.render.positions.count,
               uvs.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) {
                return .resolved(UVResolution(uvs: uvs,
                                              source: mapping?.source.rawValue ?? MaterialUVSource.mesh.rawValue,
                                              generated: false,
                                              warning: nil))
            }
            if needsUV {
                return .failed(
                    code: "obj_bundle_invalid_uvs",
                    message: "“\(material.materialName ?? "Material")” has UV coordinates that don't match its vertices. Choose a projection in Material and try again.")
            }
            return .resolved(UVResolution(uvs: nil, source: "none", generated: false,
                                          warning: "invalid_uvs_dropped"))
        }
        if needsUV, (mapping?.source ?? .mesh) == .mesh {
            // Same deterministic fallback the GLB exporter uses for a textured
            // material with no authored UVs: an export-only box projection.
            if let fallback = MaterialUVProjector.project(
                positions: body.render.positions,
                normals: body.render.normals,
                indices: body.render.indices,
                mapping: CADMaterialUVMapping(source: .boxProjection, axis: .y,
                                              scaleMM: SIMD2(100, 100))),
               fallback.count == body.render.positions.count,
               fallback.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) {
                return .resolved(UVResolution(uvs: fallback,
                                              source: "boxProjection",
                                              generated: true,
                                              warning: nil))
            }
        }
        if needsUV {
            return .failed(
                code: "obj_bundle_missing_uvs",
                message: "“\(material.materialName ?? "Material")” uses a texture but the body has no usable UVs. Choose a projection in Material and try again.")
        }
        return .resolved(UVResolution(uvs: nil, source: "none", generated: false,
                                      warning: nil))
    }

    // MARK: - Materials and textures

    private static func prepareMaterial(_ rawSpec: BodyMaterialSpec,
                                        body: Body,
                                        state: inout BuildState) -> MaterialRef? {
        let spec = rawSpec.clamped
        let materialName = spec.materialName ?? "Material"
        let values = [spec.baseColor.x, spec.baseColor.y, spec.baseColor.z,
                      spec.metallic, spec.roughness, spec.effectiveOpacity,
                      spec.emissive?.x ?? 0, spec.emissive?.y ?? 0,
                      spec.emissive?.z ?? 0, spec.emissiveStrength ?? 0]
        guard values.allSatisfy({ $0.isFinite }) else {
            state.diagnostics.append(diagnostic(
                "obj_bundle_invalid_material",
                "“\(materialName)” has factors outside the supported range. Check its settings and try again.",
                bodyID: body.id.raw))
            return nil
        }

        let declared = spec.textureMetadata ?? []
        let declaredSlots = declared.map(\.slot)
        if Set(declaredSlots).count != declaredSlots.count {
            state.diagnostics.append(diagnostic(
                "obj_bundle_ambiguous_texture_metadata",
                "“\(materialName)” has more than one record for the same image slot. Reapply its images and try again.",
                bodyID: body.id.raw))
            return nil
        }

        let strength = spec.emissiveStrength ?? 0
        let emissiveRGB = spec.emissive ?? .zero
        let hasEmission = strength > 0 && (emissiveRGB.x > 0 || emissiveRGB.y > 0 || emissiveRGB.z > 0)
        if hasEmission && strength > 1 {
            state.diagnostics.append(diagnostic(
                "obj_bundle_unsupported_emissive_strength",
                "“\(materialName)” uses emission strength above 1, which MTL can't represent. Lower it to 1 or less, or export GLB.",
                bodyID: body.id.raw, slot: .emissive))
            return nil
        }
        let effectiveEmission = hasEmission
            ? SIMD3(emissiveRGB.x * strength, emissiveRGB.y * strength, emissiveRGB.z * strength)
            : .zero

        var maps: [MaterialTextureSlot: String] = [:]
        var notes = Set<String>()

        var baseSource: Data?
        var baseDecoded: CADExportImage.Decoded?
        var basePixels: CADExportImage.Pixels?
        var baseOrientation: MaterialTextureOrientation = .topLeft
        var baseColorSpace: MaterialTextureColorSpace = .srgb

        var opacitySource: Data?
        var opacityDecoded: CADExportImage.Decoded?
        var opacityPixels: CADExportImage.Pixels?
        var opacityOrientation: MaterialTextureOrientation = .topLeft
        var opacityColorSpace: MaterialTextureColorSpace = .linear

        for slot in MaterialTextureSlot.allCases {
            guard let data = spec.textureData(for: slot) else {
                if declared.contains(where: { $0.slot == slot }) {
                    state.diagnostics.append(diagnostic(
                        "obj_bundle_missing_texture",
                        "“\(materialName)” is missing its \(slot.rawValue) image. Reapply the image and try again.",
                        bodyID: body.id.raw, slot: slot))
                    return nil
                }
                continue
            }
            if data.isEmpty {
                state.diagnostics.append(diagnostic(
                    "obj_bundle_missing_texture",
                    "“\(materialName)” is missing its \(slot.rawValue) image. Reapply the image and try again.",
                    bodyID: body.id.raw, slot: slot))
                return nil
            }
            if data.count > CADMaterialLimits.maximumTextureBytes {
                state.diagnostics.append(diagnostic(
                    "obj_bundle_texture_too_large",
                    "The \(slot.rawValue) image on “\(materialName)” is larger than the supported 8 MB material limit. Reduce it and try again.",
                    bodyID: body.id.raw, slot: slot))
                return nil
            }
            guard MaterialImageSniffer.mimeType(of: data) != nil else {
                state.diagnostics.append(diagnostic(
                    "obj_bundle_invalid_texture",
                    "The \(slot.rawValue) image on “\(materialName)” can't be read. Replace it and try again.",
                    bodyID: body.id.raw, slot: slot))
                return nil
            }
            if let metadata = declared.first(where: { $0.slot == slot }),
               metadata.verifiedDigest(for: data) == nil {
                state.diagnostics.append(diagnostic(
                    "obj_bundle_texture_identity_mismatch",
                    "The \(slot.rawValue) image on “\(materialName)” no longer matches its saved version. Reapply it and try again.",
                    bodyID: body.id.raw, slot: slot))
                return nil
            }
            guard hasEmission || slot != .emissive else {
                state.warnings.insert("emissive_map_unused_zero_factor")
                continue
            }

            let decoded: CADExportImage.Decoded
            switch CADExportImage.decode(data) {
            case .success(let value):
                decoded = value
            case .failure(.unsupportedOrientation):
                state.diagnostics.append(diagnostic(
                    "obj_bundle_unsupported_image_orientation",
                    "The \(slot.rawValue) image on “\(materialName)” has camera rotation metadata that OBJ can't carry. Remove the rotation and try again.",
                    bodyID: body.id.raw, slot: slot))
                return nil
            case .failure:
                state.diagnostics.append(diagnostic(
                    "obj_bundle_invalid_texture",
                    "The \(slot.rawValue) image on “\(materialName)” can't be read. Replace it and try again.",
                    bodyID: body.id.raw, slot: slot))
                return nil
            }

            let orientation = spec.textureOrientation(for: slot)
            let colorSpace = spec.textureColorSpace(for: slot)

            switch slot {
            case .baseColor:
                guard let pixels = CADExportImage.pixels(decoded, orientation: orientation) else {
                    return textureEncodingFailure(materialName, slot, body, &state)
                }
                baseSource = data
                baseDecoded = decoded
                basePixels = colorSpace == .linear ? CADExportImage.colorToSRGB(pixels) : pixels
                baseOrientation = orientation
                baseColorSpace = colorSpace

            case .opacity:
                guard let pixels = CADExportImage.pixels(decoded, orientation: orientation) else {
                    return textureEncodingFailure(materialName, slot, body, &state)
                }
                opacitySource = data
                opacityDecoded = decoded
                opacityPixels = pixels
                opacityOrientation = orientation
                opacityColorSpace = colorSpace

            case .metallic, .roughness:
                guard let pixels = CADExportImage.pixels(decoded, orientation: orientation) else {
                    return textureEncodingFailure(materialName, slot, body, &state)
                }
                if orientation == .topLeft,
                   colorSpace == .linear,
                   CADExportImage.isGrayscaleOpaque(pixels) {
                    guard let path = registerTexture(data: data,
                                                     mimeType: MaterialImageSniffer.mimeType(of: data) ?? "image/png",
                                                     sourceData: data,
                                                     normalized: false,
                                                     slot: slot,
                                                     note: nil,
                                                 state: &state) else { return nil }
                    maps[slot] = path
                } else {
                    let gray = CADExportImage.grayscale(pixels, srgb: colorSpace == .srgb)
                    guard let encoded = CADExportImage.encodePNG(gray) else {
                        return textureEncodingFailure(materialName, slot, body, &state)
                    }
                    guard let path = registerTexture(data: encoded,
                                                     mimeType: "image/png",
                                                     sourceData: data,
                                                     normalized: true,
                                                     slot: slot,
                                                     note: "normalized to a linear grayscale scalar map",
                                                     state: &state) else { return nil }
                    maps[slot] = path
                    state.warnings.insert(scalarNormalizedWarning)
                }

            case .normal:
                guard colorSpace != .srgb else {
                    state.diagnostics.append(diagnostic(
                        "obj_bundle_unsupported_normal_color_space",
                        "The normal map on “\(materialName)” must use linear color values.",
                        bodyID: body.id.raw, slot: .normal))
                    return nil
                }
                guard let pixels = CADExportImage.pixels(decoded, orientation: orientation) else {
                    return textureEncodingFailure(materialName, slot, body, &state)
                }
                if orientation == .topLeft {
                    guard let path = registerTexture(data: data,
                                                     mimeType: MaterialImageSniffer.mimeType(of: data) ?? "image/png",
                                                     sourceData: data,
                                                     normalized: false,
                                                     slot: slot,
                                                     note: nil,
                                                 state: &state) else { return nil }
                    maps[slot] = path
                } else {
                    guard let encoded = CADExportImage.encodePNG(pixels) else {
                        return textureEncodingFailure(materialName, slot, body, &state)
                    }
                    guard let path = registerTexture(data: encoded,
                                                     mimeType: "image/png",
                                                     sourceData: data,
                                                     normalized: true,
                                                     slot: slot,
                                                     note: "bottom-left rows flipped to top-row-first",
                                                     state: &state) else { return nil }
                    maps[slot] = path
                    state.warnings.insert(textureNormalizedWarning)
                }

            case .emissive:
                guard let pixels = CADExportImage.pixels(decoded, orientation: orientation) else {
                    return textureEncodingFailure(materialName, slot, body, &state)
                }
                let color = colorSpace == .linear
                    ? CADExportImage.colorToSRGB(pixels)
                    : pixels
                if colorSpace == .linear || orientation == .bottomLeft {
                    guard let encoded = CADExportImage.encodePNG(color) else {
                        return textureEncodingFailure(materialName, slot, body, &state)
                    }
                    guard let path = registerTexture(data: encoded,
                                                     mimeType: "image/png",
                                                     sourceData: data,
                                                     normalized: true,
                                                     slot: slot,
                                                     note: "normalized color rows for sRGB MTL sampling",
                                                     state: &state) else { return nil }
                    maps[slot] = path
                    state.warnings.insert(textureNormalizedWarning)
                } else {
                    guard let path = registerTexture(data: data,
                                                     mimeType: MaterialImageSniffer.mimeType(of: data) ?? "image/png",
                                                     sourceData: data,
                                                     normalized: false,
                                                     slot: slot,
                                                     note: nil,
                                                 state: &state) else { return nil }
                    maps[slot] = path
                }
            }
        }

        // Base colour / opacity: MTL has ONE opacity channel. Combine the
        // authored base alpha and the separate opacity map into map_d, then
        // remove the base alpha so a viewer reading both cannot apply it twice.
        let baseHasAlpha = basePixels.map(CADExportImage.hasTransparentPixel) ?? false
        let hasOpacityMap = opacityPixels != nil
        if baseHasAlpha || hasOpacityMap {
            let targetWidth = max(baseHasAlpha ? (basePixels?.width ?? 0) : 0,
                                  hasOpacityMap ? (opacityPixels?.width ?? 0) : 0)
            let targetHeight = max(baseHasAlpha ? (basePixels?.height ?? 0) : 0,
                                   hasOpacityMap ? (opacityPixels?.height ?? 0) : 0)
            guard targetWidth > 0, targetHeight > 0 else {
                return textureEncodingFailure(materialName, .opacity, body, &state)
            }
            var alpha = [UInt8](repeating: 255, count: targetWidth * targetHeight)
            if baseHasAlpha, let decoded = baseDecoded {
                guard let pixels = CADExportImage.pixels(
                    decoded, width: targetWidth, height: targetHeight,
                    orientation: baseOrientation) else {
                    return textureEncodingFailure(materialName, .baseColor, body, &state)
                }
                let values = CADExportImage.alphaValues(pixels)
                for index in 0..<min(alpha.count, values.count) {
                    alpha[index] = values[index]
                }
            }
            if hasOpacityMap, let decoded = opacityDecoded {
                guard let pixels = CADExportImage.pixels(
                    decoded, width: targetWidth, height: targetHeight,
                    orientation: opacityOrientation) else {
                    return textureEncodingFailure(materialName, .opacity, body, &state)
                }
                let srgb = opacityColorSpace == .srgb
                for index in 0..<alpha.count {
                    let value = CADExportImage.luminance(pixels, index, srgb: srgb)
                    alpha[index] = UInt8((Int(alpha[index]) * Int(value) + 127) / 255)
                }
            }
            var alphaPixels = [UInt8](repeating: 255, count: targetWidth * targetHeight * 4)
            for index in 0..<alpha.count {
                let offset = index * 4
                alphaPixels[offset] = alpha[index]
                alphaPixels[offset + 1] = alpha[index]
                alphaPixels[offset + 2] = alpha[index]
            }
            let pixels = CADExportImage.Pixels(width: targetWidth, height: targetHeight,
                                               rgba: alphaPixels)
            guard let encoded = CADExportImage.encodePNG(pixels),
                  let path = registerTexture(data: encoded,
                                             mimeType: "image/png",
                                             sourceData: opacitySource ?? baseSource ?? Data(),
                                             normalized: true,
                                             slot: .opacity,
                                             note: "combined base alpha, opacity map and alpha channel",
                                             state: &state) else {
                return textureEncodingFailure(materialName, .opacity, body, &state)
            }
            maps[.opacity] = path
            state.warnings.insert(opacitySemanticsWarning)
            if baseHasAlpha {
                state.warnings.insert(baseAlphaBakedWarning)
                notes.insert("base alpha baked into map_d")
            } else if hasOpacityMap, opacitySource == nil {
                // Defensive: hasOpacityMap implies opacitySource.
                state.warnings.insert(textureNormalizedWarning)
            }
        }

        if let source = baseSource, let pixels = basePixels {
            let needsEncode = baseColorSpace == .linear
                || baseOrientation == .bottomLeft
                || baseHasAlpha
            if needsEncode {
                guard let encoded = CADExportImage.encodePNG(
                    baseHasAlpha ? CADExportImage.flattenAlpha(pixels) : pixels) else {
                    return textureEncodingFailure(materialName, .baseColor, body, &state)
                }
                guard let path = registerTexture(data: encoded,
                                                 mimeType: "image/png",
                                                 sourceData: source,
                                                 normalized: true,
                                                 slot: .baseColor,
                                                 note: "normalized base colour rows/alpha",
                                                 state: &state) else { return nil }
                maps[.baseColor] = path
                state.warnings.insert(textureNormalizedWarning)
            } else {
                guard let path = registerTexture(data: source,
                                                 mimeType: MaterialImageSniffer.mimeType(of: source) ?? "image/png",
                                                 sourceData: source,
                                                 normalized: false,
                                                 slot: .baseColor,
                                                 note: nil,
                                                 state: &state) else { return nil }
                maps[.baseColor] = path
            }
        }

        let mapDigests = MaterialTextureSlot.allCases.compactMap { slot -> String? in
            guard let path = maps[slot] else { return nil }
            return "\(slot.rawValue):\(path)"
        }
        let key = MaterialKey(
            baseColor: [spec.baseColor.x, spec.baseColor.y, spec.baseColor.z],
            metallic: spec.metallic,
            roughness: spec.roughness,
            opacity: spec.effectiveOpacity,
            emissive: [effectiveEmission.x, effectiveEmission.y, effectiveEmission.z],
            mapDigests: mapDigests.sorted())
        if let index = state.materialIndexByKey[key] {
            state.mtlMaterials[index].bodyIDs.insert(body.id.raw)
            return MaterialRef(name: state.mtlMaterials[index].name,
                               hasMaps: !state.mtlMaterials[index].maps.isEmpty)
        }

        let sanitized = sanitizeMTLName(spec.materialName ?? "Material")
        let digest = materialDigest(key)
        var name = "\(sanitized)_\(digest)"
        var suffix = 2
        while state.usedMaterialNames.contains(name) {
            name = "\(sanitized)_\(digest)_\(suffix)"
            suffix += 1
        }
        state.usedMaterialNames.insert(name)
        let build = MaterialBuild(
            name: name,
            sourceName: spec.materialName ?? "Material",
            baseColor: [spec.baseColor.x, spec.baseColor.y, spec.baseColor.z],
            metallic: spec.metallic,
            roughness: spec.roughness,
            opacity: spec.effectiveOpacity,
            emissive: [effectiveEmission.x, effectiveEmission.y, effectiveEmission.z],
            maps: maps,
            bodyIDs: [body.id.raw],
            notes: notes)
        state.materialIndexByKey[key] = state.mtlMaterials.count
        state.mtlMaterials.append(build)
        guard state.mtlMaterials.count <= maximumMaterials else {
            state.diagnostics.append(diagnostic(
                "obj_bundle_too_many_materials",
                "The export is limited to \(maximumMaterials) materials. Reduce the number of distinct appearances and try again.",
                bodyID: body.id.raw))
            return nil
        }
        return MaterialRef(name: name, hasMaps: !maps.isEmpty)
    }

    private static func registerTexture(data: Data,
                                        mimeType: String,
                                        sourceData: Data,
                                        normalized: Bool,
                                        slot: MaterialTextureSlot,
                                        note: String?,
                                        state: inout BuildState) -> String? {
        let digest = CADMaterialTexture.digest(data)
        let ext = mimeType == "image/jpeg" ? "jpg" : "png"
        let path = "textures/\(slot.rawValue)_\(digest.prefix(12)).\(ext)"
        guard isSafeResourcePath(path) else {
            state.diagnostics.append(diagnostic(
                "obj_bundle_unsafe_resource_name",
                "A generated texture name was not safe; nothing was written."))
            return nil
        }
        if var existing = state.textures[digest] {
            existing.slots.insert(slot)
            state.textures[digest] = existing
            return existing.path
        }
        state.textures[digest] = TextureBuild(
            path: path,
            mimeType: mimeType,
            data: data,
            sha256: digest,
            sourceSha256: CADMaterialTexture.digest(sourceData),
            normalized: normalized,
            slots: [slot],
            note: note)
        state.textureOrder.append(digest)
        return path
    }

    private static func textureEncodingFailure(_ materialName: String,
                                               _ slot: MaterialTextureSlot,
                                               _ body: Body,
                                               _ state: inout BuildState) -> MaterialRef? {
        state.diagnostics.append(diagnostic(
            "obj_bundle_texture_encoding_failed",
            "The \(slot.rawValue) image on “\(materialName)” could not be prepared for OBJ export. Replace it and try again.",
            bodyID: body.id.raw, slot: slot))
        return nil
    }

    // MARK: - Text

    private static func mtlText(_ state: BuildState) -> String {
        var out = mtlHeader
        for material in state.mtlMaterials {
            out += "newmtl \(material.name)\n"
            out += "Ka 0 0 0\n"
            out += "Kd \(decimal(material.baseColor[0])) \(decimal(material.baseColor[1])) \(decimal(material.baseColor[2]))\n"
            out += "Pr \(decimal(material.roughness))\n"
            out += "Pm \(decimal(material.metallic))\n"
            if material.emissive.contains(where: { $0 > 0 }) {
                out += "Ke \(decimal(material.emissive[0])) \(decimal(material.emissive[1])) \(decimal(material.emissive[2]))\n"
            }
            out += "d \(decimal(material.opacity))\n"
            out += "illum 2\n"
            for slot in MaterialTextureSlot.allCases {
                guard let path = material.maps[slot] else { continue }
                switch slot {
                case .baseColor: out += "map_Kd \(path)\n"
                case .metallic: out += "map_Pm \(path)\n"
                case .roughness: out += "map_Pr \(path)\n"
                case .normal: out += "norm \(path)\n"
                case .emissive: out += "map_Ke \(path)\n"
                case .opacity: out += "map_d \(path)\n"
                }
            }
            out += "\n"
        }
        return out
    }

    // MARK: - Validation / naming / formatting

    private static func meshIssue(_ body: Body) -> String? {
        if let issue = CADExchangeMeshValidator.issue(for: body) { return issue }
        let transform = body.transform
        for point in body.render.positions {
            let world = transform.applying(to: SIMD3<Double>(point))
            guard world.x.isFinite, world.y.isFinite, world.z.isFinite else {
                return "non-finite world position"
            }
        }
        for normal in body.render.normals {
            let world = transform.rotation.act(SIMD3<Double>(normal))
            guard world.x.isFinite, world.y.isFinite, world.z.isFinite else {
                return "non-finite world normal"
            }
        }
        return nil
    }

    private static func materialDigest(_ key: MaterialKey) -> String {
        var text = key.baseColor.map { decimal($0, places: 8) }.joined(separator: ",")
        text += "|\(decimal(key.metallic, places: 8))"
        text += "|\(decimal(key.roughness, places: 8))"
        text += "|\(decimal(key.opacity, places: 8))"
        text += "|" + key.emissive.map { decimal($0, places: 8) }.joined(separator: ",")
        text += "|" + key.mapDigests.joined(separator: ";")
        return String(CADMaterialTexture.digest(Data(text.utf8)).prefix(10))
    }

    private static func sanitizeMTLName(_ raw: String) -> String {
        var result = ""
        var lastWasSeparator = false
        for scalar in raw.unicodeScalars {
            let value = scalar.value
            let allowed = (value >= 48 && value <= 57)
                || (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122)
                || value == 95 || value == 45 || value == 46
            if allowed, !(result.isEmpty && value == 46) {
                result.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !result.isEmpty, !lastWasSeparator {
                result.append("_")
                lastWasSeparator = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        let limited = String(trimmed.prefix(48))
        return limited.isEmpty ? "Material" : limited
    }

    private static func objObjectName(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace || scalar.value < 32
                || scalar.value == 35 || scalar.value == 127 {
                result.append("_")
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Body" : trimmed).prefix(120))
    }

    private static func isSafeResourcePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 180,
              !path.hasPrefix("/"), !path.hasPrefix("\\"),
              !path.contains("\\"), !path.contains("\0"),
              !path.contains("\n"), !path.contains("\r") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return false
        }
        return path.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 }
    }

    /// Locale-independent OBJ/MTL decimal formatting. A comma decimal
    /// separator would corrupt both formats.
    private static func decimal(_ value: Double, places: Int = 6) -> String {
        let normalized = value == 0 ? 0 : value
        return String(format: "%.\(places)f",
                      locale: Locale(identifier: "en_US_POSIX"),
                      normalized)
    }

    private static func diagnostic(_ code: String,
                                   _ message: String,
                                   bodyID: UUID? = nil,
                                   slot: MaterialTextureSlot? = nil)
        -> OBJBundleDiagnostic {
        OBJBundleDiagnostic(code: code, bodyID: bodyID, textureSlot: slot,
                            message: message)
    }

    private static func failure(_ diagnostics: [OBJBundleDiagnostic])
        -> OBJBundleExportResult {
        OBJBundleExportResult(data: nil, diagnostics: diagnostics, receipt: nil)
    }

    private static func cancelledResult() -> OBJBundleExportResult {
        failure([diagnostic("obj_bundle_cancelled",
                            "Export cancelled; nothing was written.")])
    }
}
