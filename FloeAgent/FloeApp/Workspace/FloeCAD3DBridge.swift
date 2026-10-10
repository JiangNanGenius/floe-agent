// SPDX-License-Identifier: MPL-2.0
// FloeApp — native CAD (FloeCAD) bridge for the `cad.document` native actions.
//
// The bridge owns the open FloeCAD documents (keyed by canonical path) and the
// proposal service. It answers the generic request envelope the tool sends:
//
//   {"kind":"capabilities"}                        -> kernel + action surface
//   {"kind":"snapshot"}                            -> summary + state JSON
//   {"kind":"query","payload":{"scope":...}}       -> scoped model JSON
//   {"kind":"locate","payload":{"handle":...}}     -> body/face/edge location
//   {"kind":"check","payload":{...}}               -> model+assembly+drawing check
//   {"kind":"measure","payload":{...}}             -> deterministic measurement
//   {"kind":"measure","op":"interference",...}     -> assembly measurements
//   {"kind":"assembly","payload":{"action":...}}   -> CADAssemblyService
//   {"kind":"drawing","payload":{"action":...}}    -> CADDrawingService
//   {"kind":"script","payload":{"action":...}}     -> CADScriptService
//   {"kind":"mesh","payload":{"action":...}}       -> CADMeshService
//   {"kind":"propose","op":"feature.extrude",...}  -> proposal record JSON
//   {"kind":"preview","proposal_id":"..."}         -> stored proposal preview
//   {"kind":"save"}                                -> commit receipt (CAS)
//   {"kind":"apply","proposal_id":"...","grant_id":"..."} -> apply receipt JSON
//
// Propose never writes: it evaluates on a throwaway copy. Apply requires a
// single-use grant; grants are issued by CadDocumentCenter only from the
// interactive confirmation banner (`pending`), never from a model value.
//

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import FloeCAD

@MainActor
@Observable
final class FloeCAD3DBridge {
    static let shared = FloeCAD3DBridge()

    /// Proposal awaiting interactive confirmation, shown by the CAD preview.
    private(set) var pending: [CADProposalRecord] = []
    private(set) var lastMessage: String?

    private var documents: [String: FloeCADDocument] = [:]
    /// In-flight opens keyed by canonical path: concurrent callers share one
    /// open so two FloeCADDocument instances can never own the same file.
    private var opening: [String: Task<FloeCADDocument, Error>] = [:]
    private var proposalDocument: [UUID: URL] = [:]
    private let service = CADProposalService()

    /// One service bundle per open document: assembly/drawing/script/mesh keep
    /// their in-memory bookkeeping (script status, last pages) across calls,
    /// and the live editor and the assistant share exactly one instance.
    private struct NativeServices {
        let assembly: CADAssemblyService
        let drawing: CADDrawingService
        let script: CADScriptService
        let mesh: CADMeshService
    }

    private var services: [String: NativeServices] = [:]

    private func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func nativeServices(for url: URL, document: FloeCADDocument) -> NativeServices {
        let k = key(url)
        if let existing = services[k] { return existing }
        let bundle = NativeServices(assembly: CADAssemblyService(document: document),
                                    drawing: CADDrawingService(document: document),
                                    script: CADScriptService(document: document),
                                    mesh: CADMeshService(document: document))
        services[k] = bundle
        return bundle
    }

    private func document(at url: URL) async throws -> FloeCADDocument {
        let key = key(url)
        if let existing = documents[key], !existing.isReadOnly {
            return existing
        }
        // Reentrancy guard: one in-flight open per canonical path, shared by
        // every concurrent caller.
        if let inFlight = opening[key] {
            return try await inFlight.value
        }
        let task = Task { () throws -> FloeCADDocument in
            try await FloeCADDocument.open(at: url)
        }
        opening[key] = task
        do {
            let document = try await task.value
            opening[key] = nil
            documents[key] = document
            return document
        } catch {
            opening[key] = nil
            throw error
        }
    }

    /// Shared live session: the file preview and the assistant bridge must use
    /// the SAME FloeCADDocument instance, or an assistant proposal could be
    /// drafted against a different in-memory state than the open editor.
    func openDocument(at url: URL) async throws -> FloeCADDocument {
        try await document(at: url)
    }

    /// Release a document that the workbench/FilePreviewView closed. The cache
    /// entry is kept until the commit SUCCEEDS: a failed save must not drop
    /// the only live owner of the draft. The retained document stays open for
    /// retry/recovery and the failure is surfaced.
    func releaseDocument(at url: URL) async {
        let key = key(url)
        guard let document = documents[key] else { return }
        let outcome = await document.save()
        if let error = outcome.error {
            lastMessage = "CAD save failed (document kept open for retry): \(error)"
            return
        }
        documents[key] = nil
        services[key] = nil
        document.close()
    }

    func handle(url: URL, requestJSON: String) async throws -> String {
        guard let data = requestJSON.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = request["kind"] as? String else {
            throw CADDocumentError(code: "bad_request",
                                   message: "Native CAD request must be a JSON object with a kind.")
        }
        let document = try await document(at: url)
        let native = nativeServices(for: url, document: document)
        switch kind {
        case "capabilities":
            return try jsonString(capabilitiesObject(document))

        case "snapshot":
            return try jsonString([
                "ok": true,
                "summary": summaryObject(document),
                "state": jsonObject(document.snapshotJSON()),
            ])

        case "query":
            let payload = request["payload"] as? [String: Any] ?? [:]
            let scope = payload["scope"] as? String ?? "snapshot"
            if scope == "assembly" {
                let reply = await native.assembly.handleAsync(action: "report", args: [:])
                return try jsonString(["ok": reply["ok"] as? Bool ?? false, "result": reply])
            }
            if scope == "drawings" {
                let reply = native.drawing.handle(action: "pages", args: [:])
                return try jsonString(["ok": reply["ok"] as? Bool ?? false, "result": reply])
            }
            let outcome = document.nativeQueryJSON(payload)
            return try jsonString([
                "ok": outcome.isOK,
                "result": jsonObject(outcome.payload),
                "error": outcome.errorCode ?? "",
                "message": outcome.message ?? "",
            ])

        case "locate":
            let payload = request["payload"] as? [String: Any] ?? [:]
            let outcome = document.nativeLocateJSON(payload)
            return try jsonString([
                "ok": outcome.isOK,
                "result": jsonObject(outcome.payload),
                "error": outcome.errorCode ?? "",
                "message": outcome.message ?? "",
            ])

        case "check":
            let payload = request["payload"] as? [String: Any] ?? [:]
            let outcome = document.nativeCheckJSON(payload)
            var object = (jsonObject(outcome.payload) as? [String: Any]) ?? [:]
            object["assembly"] = await native.assembly.handleAsync(action: "report", args: [:])
            object["drawings"] = native.drawing.handle(action: "pages", args: [:])
            object["ok"] = outcome.isOK
            return try jsonString(object)

        case "measure":
            // Accept both the unified envelope (op + args) and the legacy
            // payload-only form, so the 2D-style and native-style calls agree.
            var payload = request["payload"] as? [String: Any] ?? [:]
            if let op = request["op"] as? String {
                payload["kind"] = payload["kind"] as? String ?? op
                if let args = request["args"] as? [String: Any] {
                    for (k, v) in args where payload[k] == nil { payload[k] = v }
                }
            }
            let measured = payload["kind"] as? String ?? "body"
            switch measured {
            case "dof":
                let reply = await native.assembly.handleAsync(action: "dof", args: payload)
                return try jsonString(["ok": reply["ok"] as? Bool ?? false, "result": reply])
            case "interference":
                let reply = await native.assembly.handleAsync(action: "interference", args: payload)
                return try jsonString(["ok": reply["ok"] as? Bool ?? false, "result": reply])
            case "rebuild":
                let outcome = document.nativeCheckJSON(payload)
                let result = (jsonObject(outcome.payload) as? [String: Any]) ?? [:]
                let model = result["model"] as? [String: Any] ?? [:]
                return try jsonString(["ok": true,
                                       "result": ["kind": "rebuild",
                                                  "rebuildErrors": model["rebuildErrors"] ?? [],
                                                  "issues": result["issues"] ?? []]])
            case "mesh":
                let bodyID = payload["bodyID"] as? String ?? ""
                let outcome = document.nativeCheckJSON(payload)
                let result = (jsonObject(outcome.payload) as? [String: Any]) ?? [:]
                let bodies = (result["model"] as? [String: Any])?["bodies"] as? [[String: Any]] ?? []
                guard let row = bodies.first(where: { $0["id"] as? String == bodyID }) else {
                    throw CADDocumentError(code: "unknown_body",
                                           message: "mesh measure needs a bodyID from the snapshot.")
                }
                return try jsonString(["ok": true, "result": ["kind": "mesh", "body": row]])
            default:
                let outcome = document.measureJSON(payload)
                return try jsonString([
                    "ok": outcome.isOK,
                    "result": jsonObject(outcome.payload),
                    "error": outcome.errorCode ?? "",
                    "message": outcome.message ?? "",
                ])
            }

        case "assembly":
            let payload = request["payload"] as? [String: Any] ?? [:]
            let action = payload["action"] as? String ?? "report"
            var args = payload
            args["action"] = nil
            let reply = await native.assembly.handleAsync(action: action, args: args)
            return try jsonString(reply)

        case "drawing":
            let payload = request["payload"] as? [String: Any] ?? [:]
            let action = payload["action"] as? String ?? "pages"
            var args = payload
            args["action"] = nil
            let reply = native.drawing.handle(action: action, args: args)
            return try jsonString(reply)

        case "script":
            let payload = request["payload"] as? [String: Any] ?? [:]
            let action = payload["action"] as? String ?? "list"
            var args = payload
            args["action"] = nil
            let reply = await native.script.handle(action: action, args: args)
            return try jsonString(reply)

        case "mesh":
            let payload = request["payload"] as? [String: Any] ?? [:]
            let action = payload["action"] as? String ?? "combine"
            var args = payload
            args["action"] = nil
            let reply = native.mesh.handle(action: action, args: args)
            return try jsonString(reply)

        case "propose":
            guard let op = request["op"] as? String else {
                throw CADDocumentError(code: "missing_op", message: "propose requires op.")
            }
            let args = request["args"] as? [String: Any] ?? [:]
            let operation = try jsonString(["op": op, "args": args])
            let proposal = try await service.propose(document: document,
                                                     operationJSON: operation,
                                                     summary: request["summary"] as? String ?? op)
            pending.removeAll { $0.id == proposal.id }
            pending.append(proposal)
            proposalDocument[proposal.id] = url
            let proposalData = try JSONEncoder().encode(proposal)
            let proposalObject = (try? JSONSerialization.jsonObject(with: proposalData)) as? [String: Any]
            return try jsonString([
                "ok": true,
                "proposal": proposalObject ?? [:],
                "message": "Proposal drafted on a throwaway copy; confirm it in the CAD workbench to apply.",
            ])

        case "preview":
            guard let raw = request["proposal_id"] as? String,
                  let proposalID = UUID(uuidString: raw) else {
                throw CADDocumentError(code: "bad_request", message: "preview requires proposal_id.")
            }
            guard let record = pending.first(where: { $0.id == proposalID }) else {
                throw CADDocumentError(code: "unknown_proposal",
                                       message: "No pending native CAD proposal \(raw).")
            }
            let previewData = try JSONEncoder().encode(record.preview)
            let preview = (try? JSONSerialization.jsonObject(with: previewData)) as? [String: Any] ?? [:]
            return try jsonString([
                "ok": true,
                "proposal_id": record.id.uuidString,
                "summary": record.summary,
                "base_revision": record.baseRevision,
                "base_content_sha256": record.baseContentSHA256,
                "preview": preview,
            ])

        case "save":
            let outcome = await document.save()
            guard outcome.succeeded else {
                return try jsonString([
                    "ok": false,
                    "error": "save_failed",
                    "message": outcome.error ?? "The document could not be committed.",
                    "revision": outcome.revision,
                    "content_sha256": outcome.contentSHA256,
                ])
            }
            return try jsonString([
                "ok": true,
                "revision": outcome.revision,
                "content_sha256": outcome.contentSHA256,
                "message": "Committed the native CAD package.",
            ])

        case "apply":
            // Authority lives in CadDocumentCenter's shared grant store; the
            // bridge must never consume a grant on its own. The host handles
            // apply before delegating and calls performAuthorizedApply.
            throw CADDocumentError(
                code: "grant_authority",
                message: "Native CAD apply must be authorized by CadDocumentCenter; "
                       + "the proposal service does not consume grants itself.")

        default:
            throw CADDocumentError(code: "unknown_kind",
                                   message: "Unknown native CAD request kind '\(kind)'.")
        }
    }

    // MARK: Capabilities

    private func capabilitiesObject(_ document: FloeCADDocument) -> [String: Any] {
        let summary = document.summary()
        return [
            "ok": true,
            "representation": "floecad",
            "kernel": ["name": "OpenCASCADE",
                       "version": FloeCADDocument.kernelVersion],
            "schema_version": summary.schemaVersion,
            "unit": summary.unit ?? "mm",
            "read_only": summary.isReadOnly,
            "actions": ["read", "query", "locate", "measure", "check",
                        "propose", "preview", "apply", "save", "export",
                        "status", "cancel"],
            "operation_names": FloeCADDocument.nativeOperationNames,
            "assembly_actions": ["report", "instances", "addInstance", "removeInstance",
                                 "setTransform", "setVisible", "addConstraint",
                                 "removeConstraint", "suppressConstraint", "solve",
                                 "dof", "interference", "sourceUpdate", "clear"],
            "drawing_actions": ["pages", "addPage", "updatePage", "removePage",
                                "standardSheet", "project", "dimensions", "export"],
            "script_actions": ["list", "put", "remove", "preview", "apply", "status"],
            "mesh_actions": ["combine", "boolean", "transform", "recomputeNormals",
                             "boundary", "repair", "simplify", "material", "text", "image"],
            "limits": ["max_pairs": 32,
                       "script_source_bytes": 65536,
                       "script_wall_clock_seconds": 10,
                       "script_triangles": 200000,
                       "mesh_input_triangles": 500000],
        ]
    }

    // MARK: Interactive grant loop (UI only)

    /// Binding the app's grant store validates against: the exact document
    /// path, base revision and content SHA the preview was drafted from.
    struct ProposalBinding {
        let documentPath: String
        let revision: Int
        let contentSHA256: String
    }

    func proposalBinding(proposalID: UUID) throws -> ProposalBinding {
        guard let url = proposalDocument[proposalID] else {
            throw CADDocumentError(code: "unknown_proposal", message: "No such pending proposal.")
        }
        guard let record = pending.first(where: { $0.id == proposalID }) else {
            throw CADDocumentError(code: "unknown_proposal", message: "No such pending proposal.")
        }
        return ProposalBinding(documentPath: url.standardizedFileURL.resolvingSymlinksInPath().path,
                               revision: record.baseRevision,
                               contentSHA256: record.baseContentSHA256)
    }

    /// Execute an already-authorized proposal (the app host consumed a
    /// single-use grant from the existing CadProposalGrantStore).
    @discardableResult
    func performAuthorizedApply(proposalID: UUID) async throws -> CADApplyReceipt {
        guard let url = proposalDocument[proposalID] else {
            throw CADDocumentError(code: "unknown_proposal", message: "No such pending proposal.")
        }
        let document = try await document(at: url)
        let receipt = try await service.applyAuthorized(document: document, proposalID: proposalID)
        pending.removeAll { $0.id == proposalID }
        proposalDocument[proposalID] = nil
        lastMessage = receipt.message
        return receipt
    }

    func noteError(_ message: String) {
        lastMessage = message
    }

    // MARK: Native export / import (host-guarded callers)

    struct NativeExportResult: Sendable {
        let data: Data
        let note: String
        let revision: Int
    }

    /// Exact/format export bytes for the open document. Runs on the main
    /// actor with the shared live session; the host owns path resolution,
    /// writing and verification.
    func exportNativeData(at url: URL, format: String, pageID: UUID?) async throws -> NativeExportResult {
        let document = try await document(at: url)
        switch document.nativeExportData(format: format, pageID: pageID) {
        case .success(let (data, note)):
            return NativeExportResult(data: data, note: note, revision: document.revision)
        case .failure(let error):
            throw error
        }
    }

    struct NativeImportResult: Sendable {
        let bodyIDs: [String]
        let names: [String]
        let revision: Int
        let contentSHA256: String
    }

    /// Imports exact STEP or mesh bytes as one undoable body add and commits.
    /// The host reads the bytes through its guarded workspace resolver; the
    /// bridge never opens a path on its own.
    func importNativeData(at url: URL, data: Data, format: String,
                          fileName: String?, unitScale: Double?) async throws -> NativeImportResult {
        let document = try await document(at: url)
        let outcome = document.nativeImportData(data, format: format,
                                                fileName: fileName, unitScale: unitScale)
        guard outcome.isOK else {
            throw CADDocumentError(code: outcome.errorCode ?? "import_failed",
                                   message: outcome.message ?? "The import failed.")
        }
        let save = await document.save()
        guard save.succeeded else {
            throw CADDocumentError(code: "save_failed",
                                   message: save.error ?? "The imported geometry could not be committed.")
        }
        let object = (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any]
        let imported = object?["imported"] as? [[String: Any]] ?? []
        return NativeImportResult(bodyIDs: imported.compactMap { $0["bodyID"] as? String },
                                  names: imported.compactMap { $0["name"] as? String },
                                  revision: save.revision,
                                  contentSHA256: save.contentSHA256)
    }

    func discard(proposalID: UUID) {
        service.discardProposal(proposalID)
        pending.removeAll { $0.id == proposalID }
        proposalDocument[proposalID] = nil
    }

    /// Re-registers a durably recorded pending proposal after an app restart
    /// (the in-process `pending` list is empty then). The proposal service
    /// re-adopts the frozen record — no evaluation re-runs — and the live
    /// document must still be at the recorded base revision/SHA, otherwise
    /// the restored proposal would be stale and is refused.
    func restore(proposal: CADProposalRecord, documentURL: URL) async throws {
        let document = try await document(at: documentURL)
        guard document.revision == proposal.baseRevision,
              document.contentSHA256 == proposal.baseContentSHA256 else {
            throw CADDocumentError(
                code: "stale_proposal",
                message: "The document changed after this proposal was drafted; "
                    + "re-read it and draft the change again.")
        }
        pending.removeAll { $0.id == proposal.id }
        pending.append(proposal)
        proposalDocument[proposal.id] = documentURL
        // The proposal service owns the apply path; re-register the frozen
        // record there too (it validates revision/SHA again at apply).
        service.adoptRestored(proposal)
    }

    /// Pending proposals for one document as the interactive banner shows
    /// them (sorted newest first).
    func pendingProposals(for url: URL) -> [CADProposalRecord] {
        let key = key(url)
        return pending
            .filter { proposalDocument[$0.id].map { self.key($0) == key } ?? false }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Helpers

    private func summaryObject(_ document: FloeCADDocument) -> [String: Any] {
        let summary = document.summary()
        return [
            "name": summary.name,
            "revision": summary.revision,
            "content_sha256": summary.contentSHA256,
            "schema_version": summary.schemaVersion,
            "body_count": summary.bodyCount,
            "sketch_count": summary.sketchCount,
            "feature_count": summary.featureCount,
            "variable_count": summary.variableCount,
            "read_only": summary.isReadOnly,
        ]
    }

    private func jsonObject(_ data: Data) -> Any {
        (try? JSONSerialization.jsonObject(with: data)) ?? [:]
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            throw CADDocumentError(code: "encode_failed", message: "The CAD reply could not be encoded.")
        }
        return text
    }
}

#endif
