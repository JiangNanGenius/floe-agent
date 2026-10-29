//
//  CADStaleReferenceGuard.swift
//  FloeCADKit
//
//  Propose-time validation of numeric face/edge references. The kernel's
//  typed ops still take 1-based indices (the same numbering `query kind=faces`
//  and `locate face:<uuid>:<index>` expose), but an index alone is NOT a
//  stable identity: a rebuild can reuse the same number for a different
//  face/edge. An index-based edit therefore needs the query generation
//  (`query_token` from query kind=faces/edges) or an explicit stable
//  signature/midpoint. A stale/missing generation is refused with
//  `requery_required`; it is never guessed from index existence alone.
//
//  A caller that read a face/edge signature from a previous query may include
//  `face_signature`/`face_signatures` or `edge_signature`/`edge_midpoints`;
//  a mismatch is also a stale reference.
//

import Foundation
import simd

nonisolated enum CADStaleReferenceGuard {

    @MainActor
    static func validate(operationJSON: String,
                         document: FloeCADDocument) throws {
        guard let data = operationJSON.data(using: .utf8),
              let operation = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let op = operation["op"] as? String else { return }
        let args = operation["args"] as? [String: Any] ?? [:]
        guard let rawBody = args["bodyID"] as? String,
              let uuid = UUID(uuidString: rawBody),
              let body = document.session.document.bodies.first(where: { $0.id.raw == uuid }) else {
            return
        }

        let singleFaceOps: Set<String> = [
            "feature.pushPull", "feature.moveFace", "feature.scaleFace",
            "feature.rotateFace", "feature.draftFace", "feature.replaceFace",
        ]
        let multiFaceOps: Set<String> = ["feature.deleteFace", "feature.shell"]
        let edgeOps: Set<String> = ["feature.fillet", "feature.chamfer"]

        if singleFaceOps.contains(op) {
            let faces = ints(args["face"])
            guard faces.count == 1 else {
                throw CADDocumentError(code: "bad_face",
                                       message: "\(op) needs args.face as one 1-based kernel face index.")
            }
            let signatures = faceSignatures(args: args)
            let tokenValid = try requireGeneration(args, scope: "faces", body: body,
                                                   document: document,
                                                   hasStableSignature: !signatures.isEmpty)
            try validateFaces(faces, op: op, body: body, signatures: signatures,
                              requireEverySignature: !tokenValid)
        } else if multiFaceOps.contains(op) {
            let key = op == "feature.shell" ? "openFaces" : "faces"
            let faces = ints(args[key])
            if faces.isEmpty && op == "feature.shell" { return }
            let signatures = faceSignatures(args: args)
            let tokenValid = try requireGeneration(args, scope: "faces", body: body,
                                                   document: document,
                                                   hasStableSignature: !signatures.isEmpty)
            try validateFaces(faces, op: op, body: body, signatures: signatures,
                              requireEverySignature: !tokenValid)
        } else if edgeOps.contains(op) {
            let edges = ints(args["edges"])
            let hasStable = !edgeMidpoints(args).isEmpty
            let tokenValid = try requireGeneration(args, scope: "edges", body: body,
                                                   document: document,
                                                   hasStableSignature: hasStable)
            try validateEdges(edges, op: op, body: body, args: args,
                              requireEveryMidpoint: !tokenValid)
        }
    }

    // MARK: - Generation

    @MainActor
    @discardableResult
    private static func requireGeneration(_ args: [String: Any],
                                          scope: String,
                                          body: Body,
                                          document: FloeCADDocument,
                                          hasStableSignature: Bool) throws -> Bool {
        let raw = (args["query_token"] as? String)
            ?? (args["query_generation_token"] as? String)
        if let raw, !raw.isEmpty {
            if let generation = CADGeometryQueryGeneration.parse(raw),
               generation.scope == scope,
               generation.matches(documentRevision: document.revision,
                                  changeCount: document.session.changeCount,
                                  bodyID: body.id.raw,
                                  meshRevision: body.meshRevision) {
                return true
            }
            // A stale/malformed token does not block a caller that supplied
            // the row's stable signature/midpoint: identity is then proven by
            // geometry, not by the generation. Without that proof, refuse.
            if hasStableSignature { return false }
            throw CADDocumentError(
                code: "requery_required",
                message: "The \(scope) query generation is stale or malformed. "
                    + "Re-query query kind=\(scope) and pass its current query_token, "
                    + "or pass the row's stable signature/midpoint. Current change_count "
                    + "\(document.session.changeCount), mesh_revision \(body.meshRevision).")
        }
        guard hasStableSignature else {
            throw CADDocumentError(
                code: "requery_required",
                message: "An index-based \(scope) edit needs the query generation or a stable identity. "
                    + "Re-query query kind=\(scope), then pass query_token with the row's current index, "
                    + "or pass the row's stable signature/midpoint. Index existence alone is not a stable identity.")
        }
        return false
    }

    // MARK: - Faces

    private static func validateFaces(_ indices: [Int], op: String,
                                      body: Body,
                                      signatures: [Int: FaceSignature],
                                      requireEverySignature: Bool) throws {
        guard !indices.isEmpty else {
            throw CADDocumentError(code: "missing_face",
                                   message: "\(op) needs 1-based face indices from query kind=faces.")
        }
        guard let brep = body.brep else {
            throw CADDocumentError(
                code: "face_requires_brep",
                message: "Body '\(body.name)' is a mesh without analytic faces; "
                    + "this operation needs an exact solid. Query kind=bodies to confirm analyticBRep.")
        }
        let faces = OCCTKernel.faceInfo(brep)
        let byIndex = Dictionary(uniqueKeysWithValues: faces.map { ($0.index, $0) })
        var stale = indices.filter { byIndex[$0] == nil }
        if stale.isEmpty, !signatures.isEmpty {
            for index in indices {
                guard let reference = signatures[index] else {
                    if requireEverySignature {
                        throw CADDocumentError(
                            code: "requery_required",
                            message: "A face signature is missing for index \(index). "
                                + "Re-query query kind=faces and pass every edited row's signature, "
                                + "or pass the current query_token.")
                    }
                    continue
                }
                guard let face = byIndex[index], let actual = face.signature else {
                    stale.append(index)
                    continue
                }
                let score = CADFaceMaterialResolver.score(reference, actual) ?? 0
                if score < CADFaceMaterialResolver.matchThreshold {
                    stale.append(index)
                }
            }
        }
        guard stale.isEmpty else {
            let available = Array(faces.map(\.index).prefix(64)).map(String.init).joined(separator: ", ")
            let detail = signatures.isEmpty ? "" :
                " One or more supplied signatures no longer match (the body changed)."
            throw CADDocumentError(
                code: "stale_face_ref",
                message: "Face reference(s) \(stale.map(String.init).joined(separator: ", ")) "
                    + "on '\(body.name)' no longer exist or no longer match.\(detail) "
                    + "Re-query query kind=faces and use the current index/signature. "
                    + "Current indices: \(available.isEmpty ? "none (no analytic faces)" : available).")
        }
    }

    /// A signature map keyed by the row's 1-based index. Accepts either the
    /// flat row fields (`index`, `kind`, `normal`, …) or a nested `signature`
    /// object, and a single `face_signature` without an index for a
    /// single-face op.
    private static func faceSignatures(args: [String: Any]) -> [Int: FaceSignature] {
        var result: [Int: FaceSignature] = [:]
        if let rows = args["face_signatures"] as? [[String: Any]] {
            for row in rows {
                guard let index = int(row["index"]) else { continue }
                let object = (row["signature"] as? [String: Any]) ?? row
                if let signature = CADFaceSignatureCodec.signature(from: object) {
                    result[index] = signature
                }
            }
        }
        if let single = args["face_signature"] as? [String: Any],
           let signature = CADFaceSignatureCodec.signature(from: single) {
            let index = int(single["index"]) ?? ints(args["face"]).first
            if let index { result[index] = signature }
        }
        return result
    }

    // MARK: - Edges

    private static func validateEdges(_ indices: [Int], op: String,
                                      body: Body, args: [String: Any],
                                      requireEveryMidpoint: Bool) throws {
        guard !indices.isEmpty else {
            throw CADDocumentError(code: "missing_edges",
                                   message: "\(op) needs 1-based kernel edge indices from query kind=edges.")
        }
        guard let brep = body.brep else {
            throw CADDocumentError(code: "edge_requires_brep",
                                   message: "Body '\(body.name)' is a mesh without analytic edges.")
        }
        let midpoints = OCCTKernel.edgeMidpoints(brep)
        var stale = indices.filter { midpoints[$0] == nil }
        if stale.isEmpty {
            let expectedMidpoints = edgeMidpoints(args)
            let tolerance = CADFaceSignatureCodec.number(args["edge_tolerance_mm"]) ?? 0.05
            if requireEveryMidpoint && expectedMidpoints.count < indices.count {
                throw CADDocumentError(
                    code: "requery_required",
                    message: "An edge midpoint is missing for one or more edited edges. "
                        + "Re-query query kind=edges and pass every edited row's midpoint, "
                        + "or pass the current query_token.")
            } else if !expectedMidpoints.isEmpty {
                for (offset, index) in indices.enumerated() {
                    guard offset < expectedMidpoints.count,
                          expectedMidpoints[offset].count == 3,
                          let actual = midpoints[index] else { continue }
                    let expected = SIMD3(expectedMidpoints[offset][0],
                                         expectedMidpoints[offset][1],
                                         expectedMidpoints[offset][2])
                    if simd_length(actual - expected) > max(tolerance, 1e-4) {
                        stale.append(index)
                    }
                }
            }
        }
        guard stale.isEmpty else {
            let available = Array(midpoints.keys.sorted().prefix(64)).map(String.init).joined(separator: ", ")
            throw CADDocumentError(
                code: "stale_edge_ref",
                message: "Edge reference(s) \(stale.map(String.init).joined(separator: ", ")) "
                    + "on '\(body.name)' no longer exist or no longer match the supplied midpoint. "
                    + "Re-query query kind=edges and use the current 1-based edge index. "
                    + "Current edge indices: \(available.isEmpty ? "none (no analytic edges)" : available).")
        }
    }

    private static func edgeMidpoints(_ args: [String: Any]) -> [[Double]] {
        if let rows = args["edge_midpoints"] as? [[Double]] { return rows }
        if let rows = args["edge_signatures"] as? [[String: Any]] {
            return rows.compactMap { row in
                (row["midpoint"] as? [Double]) ?? (row["midpoint"] as? [NSNumber])?.map(\.doubleValue)
            }
        }
        if let single = args["edge_midpoint"] as? [Double] { return [single] }
        if let single = args["edge_midpoint"] as? [NSNumber] { return [single.map(\.doubleValue)] }
        return []
    }

    // MARK: - Number helpers

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func ints(_ value: Any?) -> [Int] {
        if let values = value as? [Int] { return values }
        if let values = value as? [NSNumber] { return values.map(\.intValue) }
        if let value, let int = int(value) { return [int] }
        return []
    }
}
