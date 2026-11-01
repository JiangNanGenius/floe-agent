//
//  MaterialFaceBinding.swift
//  FloeCADKit
//
//  Stable per-face material bindings. A binding records the kernel face's
//  geometric signature (body-local), not an index: after a parameter edit or a
//  topology-changing operation the old signature may no longer identify one
//  face. In that case the binding is reported UNRESOLVED and requires an
//  explicit reassignment — it is never silently applied to whichever face now
//  happens to carry the same index.
//

import Foundation
import CryptoKit
import simd

// MARK: - Stable key

nonisolated struct CADFaceKey: Codable, Equatable, Sendable {
    /// Body-local geometric fingerprint at assignment time.
    var signature: FaceSignature
    /// Kernel-history identity when available. A missing recorded name never
    /// falls back to geometric resemblance.
    var elementName: ElementName?
    /// The 1-based kernel index at assignment time. Provenance ONLY: it is
    /// never used to resolve after a rebuild.
    var capturedIndex: Int?

    init(signature: FaceSignature,
         elementName: ElementName? = nil,
         capturedIndex: Int? = nil) {
        self.signature = signature
        self.elementName = elementName
        self.capturedIndex = capturedIndex
    }

    init?(face: OCCTKernel.KernelFaceInfo, elementName: ElementName? = nil) {
        guard let signature = face.signature else { return nil }
        self.init(signature: signature, elementName: elementName,
                  capturedIndex: face.index)
    }
}

nonisolated struct CADFaceMaterialBinding: Codable, Equatable, Sendable {
    var key: CADFaceKey
    /// Complete applied snapshot, independent of the material library.
    var material: BodyMaterialSpec
    var assignedAt: Date

    init(key: CADFaceKey, material: BodyMaterialSpec, assignedAt: Date = Date()) {
        self.key = key
        self.material = material.clamped
        self.assignedAt = assignedAt
    }
}

/// An advisory naming/range cache bound to the EXACT stored geometry bytes.
/// This preserves a saved native face map across reload; archive bytes are
/// never used as identity across a rebuild. Authoring/model digests exclude
/// this derived cache, while the ordinary package content digest covers it.
nonisolated struct CADFaceNamingSnapshot: Codable, Sendable {
    var version: Int = 1
    var bodyID: BodyID
    var meshSHA256: String
    var brepSHA256: String
    var table: FaceTable

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encode(table: FaceTable, body: Body, mesh: Data, brep: Data?) -> Data? {
        guard let brep, body.brep != nil, table.nativeBodyID == body.id,
              table.nativeMeshRevision == body.meshRevision else { return nil }
        var stable = table
        // Session revision counters change on open/undo, not authoring intent.
        stable.nativeMeshRevision = 0
        let value = Self(bodyID: body.id, meshSHA256: digest(mesh), brepSHA256: digest(brep), table: stable)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    static func restore(_ data: Data, body: Body, mesh: Data, brep: Data?) -> FaceTable? {
        guard let brep, body.brep != nil,
              let saved = try? JSONDecoder().decode(Self.self, from: data), saved.version == 1,
              saved.bodyID == body.id, saved.table.nativeBodyID == body.id,
              saved.table.nativeMeshRevision == 0,
              saved.meshSHA256 == digest(mesh), saved.brepSHA256 == digest(brep),
              saved.table.nativeFaceNames?.values.allSatisfy(\.hasSupportedOperationIdentity) != false,
              saved.table.entries.allSatisfy({ entry in
                  entry.elementName?.hasSupportedOperationIdentity != false
                      && entry.triangles.allSatisfy({ $0 >= 0 && $0 < body.render.triangleCount })
              }),
              saved.table.nativeFaceChannel == nil
                || saved.table.nativeFaceChannel?.count == body.render.triangleCount else { return nil }
        var restored = saved.table
        // Exact saved-byte ownership was checked above, independently of a
        // previous process's session counter.
        restored.nativeMeshRevision = body.meshRevision
        return prepare(restored, for: body, names: saved.table.nativeFaceNames)
    }

    /// Called once per geometry revision, including cold legacy documents.
    /// A freshly tessellated channel is usable ONLY if its actual buffers
    /// equal the saved render. Equal triangle counts alone prove nothing.
    static func prepare(_ table: FaceTable, for body: Body,
                        names: [Int: ElementName]? = nil) -> FaceTable {
        guard let brep = body.brep else { return table }
        var result = table
        if table.nativeBodyID != nil,
           table.nativeBodyID != body.id || table.nativeMeshRevision != body.meshRevision {
            result = SignatureNaming.currentFaceTable(for: body)
        }
        result.nativeBodyID = body.id
        result.nativeMeshRevision = body.meshRevision
        result.nativeFaceNames = names ?? result.nativeFaceNames
        result.nativeFaceSignatures = Dictionary(uniqueKeysWithValues: OCCTKernel.faceInfo(brep).compactMap {
            face in face.signature.map { (face.index, $0) }
        })
        if result.nativeFaceChannel == nil {
            let native = OCCTKernel.renderMesh(from: brep)
            if native.positions == body.render.positions, native.normals == body.render.normals,
               native.indices == body.render.indices {
                let channel = OCCTKernel.renderMeshFaceChannel(from: brep)
                if channel.count == body.render.triangleCount { result.nativeFaceChannel = channel }
            }
        }
        return result
    }
}

// MARK: - Query generation / stable signatures

/// A query result's generation identity. Generated by `query kind=faces` /
/// `kind=edges`; pass the token back with an index-based edit so a rebuilt body
/// that REUSED the same numeric index for a different face/edge is rejected
/// instead of being silently accepted. This is a staleness binding, not an
/// authority token (it grants nothing).
nonisolated struct CADGeometryQueryGeneration: Codable, Equatable, Sendable {
    var scope: String          // "faces" | "edges"
    var bodyID: UUID
    var documentRevision: Int
    var changeCount: Int
    var meshRevision: UInt64

    var token: String {
        "cadq1:\(scope):\(bodyID.uuidString):\(documentRevision):\(changeCount):\(meshRevision)"
    }

    var jsonObject: [String: Any] {
        ["scope": scope,
         "body_id": bodyID.uuidString,
         "document_revision": documentRevision,
         "change_count": changeCount,
         "mesh_revision": meshRevision,
         "query_token": token]
    }

    static func parse(_ token: String) -> CADGeometryQueryGeneration? {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6, parts[0] == "cadq1",
              parts[1] == "faces" || parts[1] == "edges",
              let bodyID = UUID(uuidString: parts[2]),
              let revision = Int(parts[3]),
              let changeCount = Int(parts[4]),
              let meshRevision = UInt64(parts[5]) else { return nil }
        return CADGeometryQueryGeneration(scope: parts[1], bodyID: bodyID,
                                          documentRevision: revision,
                                          changeCount: changeCount,
                                          meshRevision: meshRevision)
    }

    /// The proposal path flushes a dirty document before drafting. That commit
    /// advances the package revision but not the in-memory change count or the
    /// body mesh revision; those two are the geometry proof. A token from a
    /// LATER revision is impossible, and an older revision is accepted only
    /// when changeCount + meshRevision still match.
    func matches(documentRevision currentRevision: Int,
                 changeCount currentChangeCount: Int,
                 bodyID currentBodyID: UUID,
                 meshRevision currentMeshRevision: UInt64) -> Bool {
        guard scope == "faces" || scope == "edges" else { return false }
        return bodyID == currentBodyID
            && documentRevision <= currentRevision
            && changeCount == currentChangeCount
            && meshRevision == currentMeshRevision
    }
}

nonisolated enum CADFaceSignatureCodec {
    static func signature(from object: [String: Any]) -> FaceSignature? {
        guard let kindName = object["kind"] as? String,
              let normal = doubles(object["normal"]), normal.count == 3,
              let centroid = doubles(object["centroid"]), centroid.count == 3,
              let area = number(object["areaMM2"] ?? object["area"]), area >= 0 else { return nil }
        let n = SIMD3(normal[0], normal[1], normal[2])
        let c = SIMD3(centroid[0], centroid[1], centroid[2])
        let offset = number(object["plane_offset"]) ?? simd_dot(n, c)
        if kindName == "planar" {
            return FaceSignature(kind: .planar, normal: n, centroid: c,
                                 area: area, planeOffset: offset)
        }
        if kindName.hasPrefix("cylindrical"),
           let radius = number(object["radius"])
            ?? Double(kindName.replacingOccurrences(of: "cylindrical:", with: "")) {
            return FaceSignature(kind: .cylindrical(radius: radius), normal: n,
                                 centroid: c, area: area, planeOffset: offset)
        }
        return nil
    }

    static func json(_ signature: FaceSignature) -> [String: Any] {
        ["kind": signature.kind.materialKindName,
         "normal": [signature.normal.x, signature.normal.y, signature.normal.z],
         "centroid": [signature.centroid.x, signature.centroid.y, signature.centroid.z],
         "areaMM2": signature.area,
         "plane_offset": signature.planeOffset]
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    static func doubles(_ value: Any?) -> [Double]? {
        if let values = value as? [Double] { return values }
        if let values = value as? [NSNumber] { return values.map(\.doubleValue) }
        return nil
    }
}

// MARK: - Resolution

nonisolated struct CADFaceCandidate: Sendable, Equatable {
    var index: Int
    var signature: FaceSignature
    var elementName: ElementName?

    init(index: Int, signature: FaceSignature, elementName: ElementName? = nil) {
        self.index = index
        self.signature = signature
        self.elementName = elementName
    }
}

nonisolated enum CADFaceMatch: Sendable, Equatable {
    case resolved(index: Int, confidence: Double)
    case ambiguous(indices: [Int])
    case unresolved(reason: String)

    var resolvedIndex: Int? {
        if case .resolved(let index, _) = self { return index }
        return nil
    }
}

/// One resolved face-material triangle group. Shared by the GLB and OBJ
/// bundle writers so both formats paint exactly the same faces.
nonisolated struct CADFaceGroup: Sendable, Equatable {
    var faceIndex: Int
    var material: BodyMaterialSpec
    var triangles: [Int]
}

/// Why one face-material binding could not claim its real triangle range.
/// The raw values are the diagnostic codes already emitted by the writers.
nonisolated enum CADFaceGroupIssueKind: String, Sendable, Equatable {
    case tableUnavailable = "face_triangle_table_unavailable"
    case missing = "face_triangle_map_missing"
    case ambiguous = "face_triangle_map_ambiguous"
    case overlapOrInvalid = "face_triangle_map_overlap_or_invalid"
    case ambiguousSignature = "ambiguous_face_signature"
    case unresolvedSignature = "face_signature_unresolved"
}

nonisolated struct CADFaceGroupIssue: Sendable, Equatable {
    var kind: CADFaceGroupIssueKind
    var faceIndex: Int?
    var materialName: String
    var capturedIndex: Int?
    var candidateIndices: [Int]?
    var detail: String?

    init(kind: CADFaceGroupIssueKind,
         faceIndex: Int? = nil,
         materialName: String,
         capturedIndex: Int? = nil,
         candidateIndices: [Int]? = nil,
         detail: String? = nil) {
        self.kind = kind
        self.faceIndex = faceIndex
        self.materialName = materialName
        self.capturedIndex = capturedIndex
        self.candidateIndices = candidateIndices
        self.detail = detail
    }

    /// The exact unresolved row the OBJ bundle receipt has always carried.
    var unresolvedDescription: String {
        switch kind {
        case .unresolvedSignature:
            return "face \(capturedIndex ?? -1) [\(materialName)]: "
                + "\(kind.rawValue) (\(detail ?? ""))"
        case .ambiguousSignature:
            return "face \(capturedIndex ?? -1) [\(materialName)]: \(kind.rawValue)"
        default:
            return "face \(faceIndex ?? capturedIndex ?? -1) [\(materialName)]: \(kind.rawValue)"
        }
    }

    /// The same issue in the GLB extras shape. A signature resolution failure
    /// keeps its actionable detail in `reason` (the historical contract).
    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "face_index": faceIndex ?? -1,
            "material": materialName,
            "reason": kind == .unresolvedSignature ? (detail ?? kind.rawValue) : kind.rawValue,
        ]
        if let candidateIndices { object["candidate_indices"] = candidateIndices }
        return object
    }
}

/// One deterministic face-range decision for a body. `groups` are the
/// bindings that actually claimed their table triangles; `issues` are the
/// real missing/ambiguous/overlapping ranges that fell back to the body
/// material. Coverage, dry-run, the GLB writer and the OBJ bundle writer all
/// consume this one assessment, so the receipt cannot disagree with the bytes.
nonisolated struct CADFaceGroupAssessment: Sendable, Equatable {
    var groups: [CADFaceGroup]
    var issues: [CADFaceGroupIssue]
    var claimedTriangles: Set<Int>
    var remainingTriangles: [Int]

    var isLossless: Bool { issues.isEmpty }
}

nonisolated enum CADFaceMaterialResolver {
    /// Retained for query/preview comparisons. Persisted bindings use names
    /// or unique exact fingerprints below, never this similarity threshold.
    static let matchThreshold: Double = 0.72
    /// A match must beat its runner-up by this margin; else the binding is
    /// ambiguous and needs explicit reassignment.
    static let ambiguityMargin: Double = 0.04

    /// Resolve every face binding against one fresh/stale face table. This is
    /// the single source of truth for both writers and the completeness
    /// receipt; no caller may infer "complete" from signature matching alone,
    /// because a fresh table can still lack, ambiguously match or overlap the
    /// exact triangle range.
    static func assessGroups(in body: Body,
                             table: FaceTable?,
                             tableRevision: UInt64?,
                             triangleCount overrideTriangleCount: Int? = nil)
        -> CADFaceGroupAssessment {
        let triangleCount = overrideTriangleCount
            ?? (body.render.indices.count / 3)
        guard triangleCount > 0 else {
            return CADFaceGroupAssessment(groups: [], issues: [],
                                          claimedTriangles: [],
                                          remainingTriangles: [])
        }
        let tableIsFresh = table != nil && tableRevision == body.meshRevision
            && (table?.nativeBodyID == nil
                || (table?.nativeBodyID == body.id && table?.nativeMeshRevision == body.meshRevision))
        let candidates = candidates(for: body, table: tableIsFresh ? table : nil)
        let byIndex = Dictionary(uniqueKeysWithValues: candidates.map { ($0.index, $0) })
        var channelGroups: [UInt32: [Int]] = [:]
        var coverage: [Int: Int] = [:]
        var invalidEntryRanges: [Set<Int>] = []
        if tableIsFresh, let table,
           table.nativeBodyID == body.id, table.nativeMeshRevision == body.meshRevision,
           let channel = table.nativeFaceChannel, channel.count == body.render.triangleCount {
            for triangle in channel.indices { channelGroups[channel[triangle], default: []].append(triangle) }
            for entry in table.entries {
                for triangle in entry.triangles { coverage[triangle, default: 0] += 1 }
                if entry.triangles.contains(where: { $0 < 0 || $0 >= triangleCount }) {
                    invalidEntryRanges.append(Set(entry.triangles))
                }
            }
        }
        var claimed = Set<Int>()
        var groups: [CADFaceGroup] = []
        var issues: [CADFaceGroupIssue] = []

        for binding in body.materialFaceBindings {
            let materialName = binding.material.materialName ?? "Material"
            let captured = binding.key.capturedIndex
            switch match(binding.key, candidates: candidates) {
            case .resolved(let faceIndex, _):
                guard tableIsFresh, let table else {
                    issues.append(CADFaceGroupIssue(
                        kind: .tableUnavailable, faceIndex: faceIndex,
                        materialName: materialName, capturedIndex: captured))
                    continue
                }
                guard let candidate = byIndex[faceIndex] else { continue }
                let triangles: [Int]
                if let native = UInt32(exactly: faceIndex), let owned = channelGroups[native] {
                    guard owned.allSatisfy({ $0 >= 0 && $0 < triangleCount }),
                          owned.allSatisfy({ coverage[$0, default: 0] <= 1 }),
                          invalidEntryRanges.allSatisfy({ $0.isDisjoint(with: owned) }) else {
                        issues.append(CADFaceGroupIssue(kind: .overlapOrInvalid, faceIndex: faceIndex,
                            materialName: materialName, capturedIndex: captured))
                        continue
                    }
                    guard owned.allSatisfy({ coverage[$0, default: 0] == 1 }) else {
                        issues.append(CADFaceGroupIssue(kind: .missing, faceIndex: faceIndex,
                            materialName: materialName, capturedIndex: captured))
                        continue
                    }
                    triangles = owned
                } else {
                    // Euclid's baked box render has no native channel, but
                    // its validated author-owned box roles are exact names.
                    let namedBox: Bool
                    if case .box? = body.primitive,
                       case .primitiveFace(.boxFace)? = candidate.elementName?.source { namedBox = true }
                    else { namedBox = false }
                    let entries = table.entries.filter {
                        namedBox ? $0.elementName == candidate.elementName
                            : SignatureNaming.exactSignature($0.signature, candidate.signature)
                    }
                    guard !entries.isEmpty else {
                        issues.append(CADFaceGroupIssue(
                            kind: .missing, faceIndex: faceIndex,
                            materialName: materialName, capturedIndex: captured))
                        continue
                    }
                    guard entries.count == 1, let entry = entries.first else {
                        issues.append(CADFaceGroupIssue(
                            kind: .ambiguous, faceIndex: faceIndex,
                            materialName: materialName, capturedIndex: captured))
                        continue
                    }
                    triangles = entry.triangles
                }
                guard !triangles.isEmpty,
                      triangles.allSatisfy({ $0 >= 0 && $0 < triangleCount }),
                      triangles.allSatisfy({ !claimed.contains($0) }) else {
                    issues.append(CADFaceGroupIssue(
                        kind: .overlapOrInvalid, faceIndex: faceIndex,
                        materialName: materialName, capturedIndex: captured))
                    continue
                }
                for triangle in triangles { claimed.insert(triangle) }
                groups.append(CADFaceGroup(faceIndex: faceIndex,
                                           material: binding.material.clamped,
                                           triangles: triangles))
            case .ambiguous(let indices):
                issues.append(CADFaceGroupIssue(
                    kind: .ambiguousSignature, faceIndex: nil,
                    materialName: materialName, capturedIndex: captured,
                    candidateIndices: indices))
            case .unresolved(let reason):
                issues.append(CADFaceGroupIssue(
                    kind: .unresolvedSignature, faceIndex: captured,
                    materialName: materialName, capturedIndex: captured,
                    detail: reason))
            }
        }

        let remaining = (0..<triangleCount).filter { !claimed.contains($0) }
        return CADFaceGroupAssessment(groups: groups, issues: issues,
                                      claimedTriangles: claimed,
                                      remainingTriangles: remaining)
    }

    static func candidates(for body: Body, table: FaceTable? = nil) -> [CADFaceCandidate] {
        guard let brep = body.brep else { return [] }
        let fresh = table?.nativeBodyID == body.id && table?.nativeMeshRevision == body.meshRevision
        let names = fresh ? table?.nativeFaceNames : nil
        if fresh, let signatures = table?.nativeFaceSignatures {
            return signatures.keys.sorted().compactMap { index in
                signatures[index].map { CADFaceCandidate(index: index, signature: $0, elementName: names?[index]) }
            }
        }
        return OCCTKernel.faceInfo(brep).compactMap { face in
            guard let signature = face.signature else { return nil }
            return CADFaceCandidate(index: face.index, signature: signature, elementName: names?[face.index])
        }
    }

    /// Selection previews consume the same actual range contract as writers.
    static func triangles(for index: Int, in body: Body, table: FaceTable) -> [Int]? {
        guard let face = candidates(for: body, table: table).first(where: { $0.index == index }) else { return nil }
        var selected = body
        selected.materialFaceBindings = [CADFaceMaterialBinding(
            key: CADFaceKey(signature: face.signature, elementName: face.elementName, capturedIndex: index),
            material: .default)]
        let assessment = assessGroups(in: selected, table: table, tableRevision: body.meshRevision)
        guard assessment.issues.isEmpty, assessment.groups.count == 1 else { return nil }
        return assessment.groups.first?.triangles
    }

    static func match(_ key: CADFaceKey,
                      candidates: [CADFaceCandidate]) -> CADFaceMatch {
        guard !candidates.isEmpty else {
            return .unresolved(reason: "The body has no analytic B-rep faces; face materials need an exact solid.")
        }
        let matches: [CADFaceCandidate]
        if let name = key.elementName {
            guard name.hasSupportedOperationIdentity else {
                return .unresolved(reason: "This face reference is not supported. Select the face again.")
            }
            let named = candidates.filter { $0.elementName == name }
            guard named.count <= 1 else { return .ambiguous(indices: named.map(\.index).sorted()) }
            matches = named.filter {
                SignatureNaming.acceptsNamedSignature(name, current: $0.signature, reference: key.signature)
            }
        } else {
            matches = candidates.filter { SignatureNaming.exactSignature($0.signature, key.signature) }
        }
        guard !matches.isEmpty else {
            return .unresolved(reason: FloeCADStrings.text("cad.material.target.reselectFaceHint",
                "This selection doesn't match one stable face. Reselect a single face."))
        }
        guard matches.count == 1, let candidate = matches.first else {
            return .ambiguous(indices: matches.map(\.index).sorted())
        }
        return .resolved(index: candidate.index, confidence: 1)
    }

    /// Scores one stored signature against a current face. Nil = incompatible
    /// surface kind or radius (a face whose fundamental geometry changed is a
    /// different face for material purposes).
    static func score(_ reference: FaceSignature,
                      _ candidate: FaceSignature) -> Double? {
        switch (reference.kind, candidate.kind) {
        case (.planar, .planar):
            break
        case let (.cylindrical(refRadius), .cylindrical(candidateRadius)):
            let base = max(abs(refRadius), 1e-6)
            guard abs(candidateRadius - refRadius) / base <= 0.35 else { return nil }
        default:
            return nil
        }
        let normalDot = min(max(simd_dot(simd_normalize(reference.normal),
                                         simd_normalize(candidate.normal)), -1), 1)
        let normalScore = max(0, normalDot)
        let scale = max((sqrt(max(reference.area, 0)) + sqrt(max(candidate.area, 0))) / 2, 1e-6)
        let centroidDistance = simd_length(candidate.centroid - reference.centroid)
        let centroidScore = max(0, 1 - min(1, centroidDistance / (2.5 * scale)))
        let areaBase = max(reference.area, 1e-9)
        let areaScore = max(0, 1 - min(1, abs(candidate.area - reference.area) / areaBase))
        var score = 0.5 * normalScore + 0.3 * centroidScore + 0.2 * areaScore
        if case .planar = reference.kind {
            let offsetDelta = abs(candidate.planeOffset - reference.planeOffset)
            let offsetScore = max(0, 1 - min(1, offsetDelta / (2.5 * scale)))
            score = score * 0.9 + offsetScore * 0.1
        }
        return min(max(score, 0), 1)
    }

    struct Resolution: Sendable, Equatable {
        var binding: CADFaceMaterialBinding
        var match: CADFaceMatch
        var resolvedIndex: Int? { match.resolvedIndex }
    }

    static func resolve(_ bindings: [CADFaceMaterialBinding],
                        in body: Body, table: FaceTable? = nil) -> [Resolution] {
        let candidates = candidates(for: body, table: table)
        return bindings.map { binding in
            Resolution(binding: binding,
                       match: match(binding.key, candidates: candidates))
        }
    }

    static func unresolved(_ bindings: [CADFaceMaterialBinding],
                           in body: Body) -> [Resolution] {
        resolve(bindings, in: body).filter { $0.resolvedIndex == nil }
    }
}

// MARK: - Typed face rows

nonisolated extension OCCTKernel.KernelFaceInfo {
    /// Stable description for a query reply: callers can copy the signature
    /// into an explicit reassignment without relying on the numeric index
    /// surviving the next rebuild.
    var stableFaceJSON: [String: Any] {
        var object: [String: Any] = [
            "index": index,
            "areaMM2": area,
            "centroid": [centroid.x, centroid.y, centroid.z],
            "normal": [normal.x, normal.y, normal.z],
        ]
        if let signature {
            object["signature"] = [
                "kind": signature.kind.materialKindName,
                "normal": [signature.normal.x, signature.normal.y, signature.normal.z],
                "centroid": [signature.centroid.x, signature.centroid.y, signature.centroid.z],
                "areaMM2": signature.area,
                "plane_offset": signature.planeOffset,
            ]
            object["stable"] = true
        } else {
            object["stable"] = false
            object["note"] = "This surface kind has no stable material signature; use the whole-body material."
        }
        return object
    }
}

nonisolated extension FaceSignature.Kind {
    var materialKindName: String {
        switch self {
        case .planar: return "planar"
        case .cylindrical(let radius): return "cylindrical:\(radius)"
        }
    }
}
