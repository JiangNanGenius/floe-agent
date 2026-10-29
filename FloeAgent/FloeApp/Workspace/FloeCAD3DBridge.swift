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
import FloeWorkbench

@MainActor
@Observable
final class FloeCAD3DBridge {
    static let shared = FloeCAD3DBridge()

    /// Proposal awaiting interactive confirmation, shown by the CAD preview.
    private(set) var pending: [CADProposalRecord] = []
    private(set) var lastMessage: String?

    /// Frozen specification of an import proposal. Geometry proposals are
    /// owned by `CADProposalService`; an import proposal is drafted here on a
    /// throwaway package copy and, after a UI grant, applied by re-reading the
    /// source bytes through the host's guarded resolver (the bridge never
    /// opens a workspace path itself).
    struct ImportSpec: Sendable, Equatable {
        let sourceRelativePath: String
        let format: String
        let fileName: String?
        let unitScale: Double?
        let sourceSHA256: String
    }
    private var importSpecs: [UUID: ImportSpec] = [:]

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
                "scene": document.sceneSummaryJSON(),
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

        case "material":
            var payload = request["payload"] as? [String: Any] ?? [:]
            guard let action = payload["action"] as? String, !action.isEmpty else {
                throw CADDocumentError(code: "missing_action",
                                       message: "material requires payload.action ("
                                        + CADMaterialService.actions.joined(separator: "|") + ").")
            }
            try Self.requireRevisionPin(request, document: document)
            if (action == "libraryImport" || action == "libraryList"),
               Self.bool(payload["global"]) == true {
                let url = FloeCADDocument.sharedMaterialLibraryURL
                if FileManager.default.fileExists(atPath: url.path) {
                    let data = try Data(contentsOf: url)
                    guard data.count <= CADMaterialService.maximumSharedLibraryBytes,
                          let text = String(data: data, encoding: .utf8) else {
                        throw CADDocumentError(code: "global_library_invalid",
                                               message: "The shared material library is unreadable or too large.")
                    }
                    payload["library_json"] = text
                } else if action == "libraryList" {
                    // An absent personal library is a valid empty state, not a
                    // failed read; the UI can then create the first entry.
                    payload["library_json"] = #"{"schemaVersion":1,"entries":[],"updatedAt":0}"#
                } else {
                    throw CADDocumentError(code: "global_library_missing",
                                           message: "No shared material library has been saved on this device yet.")
                }
            }
            // Capture the pre-edit generation BEFORE the service mutates, then
            // capture the exact post-edit generation. A failed save may only
            // undo while the document is still at that post-edit generation.
            let changeBefore = document.liveChangeCount
            let checkpoint = document.captureEditCheckpoint()
            var reply = CADMaterialService(document: document).handle(action: action, args: payload)
            if Self.bool(reply["mutated"]) == true {
                let changeAfter = document.liveChangeCount
                if changeAfter == changeBefore {
                    reply["saved"] = false
                    reply["note"] = "The service reported a mutation but applied no undoable document command."
                } else {
                    let commit = await CADNativeEditCommit.save(
                        document: document, changeAfterMutation: changeAfter,
                        rollback: action == "undo" ? .redo
                            : (action == "redo" ? .undo : .undo),
                        checkpoint: checkpoint)
                    if commit.saved {
                        reply["saved"] = true
                        reply["revision"] = commit.revision
                        reply["content_sha256"] = commit.contentSHA256
                    } else {
                        reply["ok"] = false
                        reply["error"] = commit.concurrentEdit ? "concurrent_edit" : "save_failed"
                        reply["message"] = commit.error
                        reply["rolled_back"] = commit.rolledBack
                        reply["concurrent_edit"] = commit.concurrentEdit
                        reply["revision"] = commit.revision
                    }
                }
            }
            if action == "libraryExport", Self.bool(payload["global"]) == true,
               let text = reply["library_json"] as? String {
                let target = FloeCADDocument.sharedMaterialLibraryURL
                let incoming = Data(text.utf8)
                // Coordinated read-merge-write on the SAME file key the UI
                // store uses. A corrupt/oversized existing library is a
                // refusal, never silently replaced by the incoming document.
                do {
                    try CADMaterialLibraryJSONMerge.mergeInPlace(
                        at: target, incoming: incoming,
                        maximumBytes: CADMaterialService.maximumSharedLibraryBytes)
                } catch let error as CADMaterialLibraryJSONMerge.MergeError {
                    throw CADDocumentError(code: error.code, message: error.message)
                }
                reply["global_saved"] = true
                // The bytes live in the shared file; do not echo a potentially
                // multi-megabyte base64 payload through the model reply.
                reply["library_json"] = nil
            }
            return try jsonString(reply)

        case "parameters":
            let payload = request["payload"] as? [String: Any] ?? [:]
            guard let action = payload["action"] as? String, !action.isEmpty else {
                throw CADDocumentError(code: "missing_action",
                                       message: "parameters requires payload.action ("
                                        + CADParameterService.actions.joined(separator: "|") + ").")
            }
            try Self.requireRevisionPin(request, document: document)
            let changeBefore = document.liveChangeCount
            let checkpoint = document.captureEditCheckpoint()
            var reply = CADParameterService(document: document).handle(action: action, args: payload)
            if Self.bool(reply["mutated"]) == true {
                let changeAfter = document.liveChangeCount
                if changeAfter == changeBefore {
                    reply["saved"] = false
                    reply["note"] = "The service reported a mutation but applied no undoable document command."
                } else {
                    let commit = await CADNativeEditCommit.save(
                        document: document, changeAfterMutation: changeAfter,
                        rollback: action == "undo" ? .redo
                            : (action == "redo" ? .undo : .undo),
                        checkpoint: checkpoint)
                    if commit.saved {
                        reply["saved"] = true
                        reply["revision"] = commit.revision
                        reply["content_sha256"] = commit.contentSHA256
                    } else {
                        reply["ok"] = false
                        reply["error"] = commit.concurrentEdit ? "concurrent_edit" : "save_failed"
                        reply["message"] = commit.error
                        reply["rolled_back"] = commit.rolledBack
                        reply["concurrent_edit"] = commit.concurrentEdit
                        reply["revision"] = commit.revision
                    }
                }
            }
            return try jsonString(reply)

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
        var object = Self.globalCapabilitiesObject()
        object["schema_version"] = document.summary().schemaVersion
        object["unit"] = document.summary().unit ?? "mm"
        object["read_only"] = document.summary().isReadOnly
        object["representation"] = "floecad"
        return object
    }

    /// Kernel/format capabilities without an open document: action surface,
    /// package creation and the per-format import/view/edit/export matrix.
    /// Shared by the no-document capability discovery and the per-document
    /// capabilities reply (which additionally reports this document's state).
    static func globalCapabilitiesObject() -> [String: Any] {
        [
            "ok": true,
            "representation": "floecad",
            "available": true,
            "kernel": ["name": "OpenCASCADE",
                       "version": FloeCADDocument.kernelVersion],
            "package_schema_version": 1,
            "actions": ["create", "read", "query", "locate", "measure", "check",
                        "import", "propose", "preview", "apply", "save", "export",
                        "status", "cancel"],
            "creation": [
                "extension": "floecad",
                "new_document_is_empty": true,
                "factory_only": true,
                "non_overwriting": true,
                "atomic_commit": true,
                "read_back_verified": true,
                "note": "Create packages with the cad.document create action or the file tree; never hand-build the directory, manifest or zip.",
            ],
            "import": [
                "requires_existing_package": true,
                "proposal_required": true,
                "source_unchanged": true,
                "symlink_safe": true,
                "parametric_history": false,
                "formats": NativeCADCapabilityMatrix.json(),
            ],
            "operation_names": FloeCADDocument.nativeOperationNames,
            "material_actions": CADMaterialService.actions,
            "parameter_actions": CADParameterService.actions,
            "scene_snapshot_schema": FloeCADDocument.sceneSnapshotSchemaVersion,
            "viewport_capture": ["formats": ["png"], "min_size": 64, "max_size": 4096],
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

    /// No-document kernel capabilities JSON (host `nativeCapabilities`).
    func globalCapabilitiesJSON() throws -> String {
        try jsonString(Self.globalCapabilitiesObject())
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

    // MARK: Native import proposals (host-guarded bytes)

    /// Formats imported as exact B-rep geometry through `nativeImportData`.
    private static let brepImportFormats: Set<String> = ["step", "stp", "iges", "igs"]
    /// Formats imported as render meshes through `nativeImportData`.
    private static let meshImportFormats: Set<String> = ["stl", "obj"]
    /// Mesh exchange formats only the command-vocabulary importer accepts
    /// (glTF/GLB reuse the kernel's `document.import` mesh path).
    private static let commandImporterFormats: Set<String> = ["glb", "gltf"]

    /// Whether an import format yields render-only mesh bodies (no analytic
    /// B-rep, no parametric feature history).
    static func isMeshImportFormat(_ format: String) -> Bool {
        meshImportFormats.contains(format) || commandImporterFormats.contains(format)
    }

    /// The frozen import specification for a pending proposal, if any. The
    /// center uses this to route an authorized apply through the import
    /// transaction (and to re-read/verify the guarded source bytes).
    func importSpec(for proposalID: UUID) -> ImportSpec? { importSpecs[proposalID] }

    /// Re-register the frozen import spec of a restored durable proposal
    /// after relaunch (the in-process `importSpecs` map is empty then).
    func registerRestoredImport(spec: ImportSpec, proposalID: UUID, documentURL: URL) {
        importSpecs[proposalID] = spec
        proposalDocument[proposalID] = documentURL
    }

    /// Draft an import proposal on a throwaway COPY of the package: the live
    /// document, its revision and its package are untouched. `data` was read
    /// by the host through its guarded workspace resolver; the bridge never
    /// opens the workspace path. `sourceSHA256` binds the exact source bytes,
    /// so an apply after the source changed is refused and re-drafted.
    ///
    /// STEP/IGES/STL/OBJ reuse `FloeCADDocument.nativeImportData`; GLB/glTF
    /// reuse the kernel's `document.import` mesh importer against a staged
    /// temp copy of the guarded bytes. No parser is implemented here, and no
    /// parametric feature history is synthesized for imported geometry.
    func proposeImport(at url: URL, sourceRelativePath: String, data: Data,
                       format rawFormat: String,
                       fileName: String?, unitScale: Double?,
                       sourceSHA256: String, summary: String) async throws -> CADProposalRecord {
        let format = rawFormat.lowercased()
        let document = try await document(at: url)
        // Mirror CADProposalService: flush live edits first so the proposal
        // binds the bytes the grant will validate; a flush failure refuses.
        // `flushIfDirty` is package-internal, so this uses the public
        // save() which is a no-op identity-refresh on a clean document.
        if document.hasUnsavedChanges {
            let flushed = await document.save()
            guard flushed.succeeded else {
                throw CADDocumentError(code: "dirty_document",
                                       message: "The document has unsaved changes that could not be flushed: "
                                        + (flushed.error ?? "unknown error"))
            }
        }
        if document.isReadOnly {
            throw CADDocumentError(
                code: "document_read_only",
                message: "This .floecad package was written by a newer version and opens read-only; "
                    + "import is not available for it in this build.")
        }
        let bodyCountBefore = document.summary().bodyCount
        let revisionBefore = document.revision
        let contentBefore = document.contentSHA256

        let cloneURL = fileManagerTempURL("floecad-import-propose")
        defer { try? FileManager.default.removeItem(at: cloneURL) }
        do {
            try FileManager.default.copyItem(at: url, to: cloneURL)
        } catch {
            throw CADDocumentError(code: "clone_failed",
                                   message: "The import preview copy could not be made: \(error.localizedDescription)")
        }
        let clone = try await FloeCADDocument.open(at: cloneURL)
        let outcome = try Self.applyImport(document: clone, data: data, format: format,
                                           fileName: fileName, unitScale: unitScale)
        guard outcome.isOK else {
            clone.close()
            throw CADDocumentError(code: outcome.errorCode ?? "import_failed",
                                   message: outcome.message ?? "The import failed on the preview copy.")
        }
        let addedNames = Self.importedBodyNames(outcome.payload)
        let bodyCountAfter = clone.summary().bodyCount
        let warnings = Self.importWarnings(outcome.payload, format: format)
        clone.close()
        guard bodyCountAfter > bodyCountBefore || !addedNames.isEmpty else {
            throw CADDocumentError(code: outcome.errorCode ?? "empty_import",
                                   message: outcome.message
                                    ?? "The file produced no importable bodies; nothing was changed.")
        }

        let geometryClass = Self.isMeshImportFormat(format) ? "mesh" : "brep"
        let message = "Import \(format.uppercased()) preview: \(addedNames.count) \(geometryClass) "
            + "body(ies) would be added; no parametric feature history is created."
            + (warnings.isEmpty ? "" : " \(warnings)")
        // CADProposalPreview has no public memberwise initializer; round-trip
        // it through its Codable conformance.
        let previewJSON: [String: Any] = [
            "bodyCountBefore": bodyCountBefore,
            "bodyCountAfter": bodyCountAfter,
            "addedBodyNames": addedNames,
            "removedBodyNames": [String](),
            "volumeBeforeMM3": 0,
            "volumeAfterMM3": 0,
            "evalErrors": warnings.isEmpty ? [] : [warnings],
            "failed": false,
            "serviceOperation": "document.import",
            "serviceMutated": true,
            "serviceMessage": message,
        ]
        let previewData = try JSONSerialization.data(withJSONObject: previewJSON)
        let preview = try JSONDecoder().decode(CADProposalPreview.self, from: previewData)

        let operation: [String: Any] = [
            "op": "document.import",
            "args": Self.importArgs(sourcePath: sourceRelativePath, format: format,
                                    fileName: fileName, unitScale: unitScale,
                                    sourceSHA256: sourceSHA256, geometryClass: geometryClass),
        ]
        let operationJSON = try jsonString(operation)
        let record = CADProposalRecord(
            documentPath: url.path,
            baseRevision: revisionBefore,
            baseContentSHA256: contentBefore,
            summary: summary,
            operationJSON: operationJSON,
            preview: preview)
        pending.removeAll { $0.id == record.id }
        pending.append(record)
        proposalDocument[record.id] = url
        importSpecs[record.id] = ImportSpec(sourceRelativePath: sourceRelativePath,
                                           format: format,
                                           fileName: fileName,
                                           unitScale: unitScale,
                                           sourceSHA256: sourceSHA256)
        return record
    }

    /// Apply an ALREADY-AUTHORIZED import proposal to the live document with
    /// the guarded, re-verified source bytes. Re-checks the base revision/SHA
    /// and source SHA, mutates once and commits. A failed commit drops the
    /// cached live session so the next open reloads the last committed
    /// package rather than keeping an uncommitted import.
    @discardableResult
    func performAuthorizedImport(proposalID: UUID, data: Data,
                                 expectedSourceSHA256: String) async throws -> CADApplyReceipt {
        guard let url = proposalDocument[proposalID],
              let spec = importSpecs[proposalID],
              let record = pending.first(where: { $0.id == proposalID }) else {
            throw CADDocumentError(code: "unknown_proposal", message: "No such pending import proposal.")
        }
        guard spec.sourceSHA256 == expectedSourceSHA256 else {
            throw CADDocumentError(
                code: "source_changed",
                message: "The source file changed after this import was proposed; re-read it and draft the import again.")
        }
        let document = try await document(at: url)
        guard document.revision == record.baseRevision,
              document.contentSHA256 == record.baseContentSHA256 else {
            throw CADDocumentError(code: "stale_proposal",
                                   message: "The document changed after this proposal was drafted; "
                                    + "re-read it and draft the import again.")
        }
        if document.isReadOnly {
            throw CADDocumentError(code: "document_read_only",
                                   message: "The package is read-only in this build; import is not available.")
        }
        let outcome = try Self.applyImport(document: document, data: data, format: spec.format,
                                           fileName: spec.fileName, unitScale: spec.unitScale)
        guard outcome.isOK else {
            throw CADDocumentError(code: outcome.errorCode ?? "import_failed",
                                   message: outcome.message ?? "The import failed; the document was not changed.")
        }
        let save = await document.save()
        guard save.succeeded else {
            // Reload the committed package on the next open so the failed
            // import cannot linger as an uncommitted draft.
            if let cached = documents[key(url)] {
                cached.close()
                documents[key(url)] = nil
                services[key(url)] = nil
            }
            throw CADDocumentError(code: "save_failed",
                                   message: save.error
                                    ?? "The imported geometry could not be committed; the document was reloaded from the last saved package.")
        }
        let receipt = CADApplyReceipt(proposalID: proposalID,
                                      revision: save.revision,
                                      contentSHA256: save.contentSHA256,
                                      message: "Imported and committed \(spec.format.uppercased()) geometry "
                                        + "(\(Self.importedBodyNames(outcome.payload).count) body/bodies).")
        pending.removeAll { $0.id == proposalID }
        proposalDocument[proposalID] = nil
        importSpecs[proposalID] = nil
        lastMessage = receipt.message
        return receipt
    }

    /// One import attempt against `document`: B-rep/mesh formats reuse
    /// `nativeImportData`. GLB/glTF external-resource reuse is NOT
    /// implemented in this round: the kernel command importer stages the
    /// guarded source bytes in a fresh temp directory (no sibling scan), so a
    /// self-contained `.glb` works, while a loose `.gltf` whose buffers/
    /// textures live beside it is reported as unsupported rather than
    /// silently losing geometry. No uncontrolled folder scan and no new
    /// parser are added here.
    private static func applyImport(document: FloeCADDocument, data: Data, format: String,
                                    fileName: String?, unitScale: Double?) throws -> CADCommandOutcome {
        if brepImportFormats.contains(format) || meshImportFormats.contains(format) {
            return document.nativeImportData(data, format: format,
                                             fileName: fileName, unitScale: unitScale)
        }
        // A JSON .gltf may be self-contained (every buffer/image URI is a
        // data: URI, or the only buffer has no URI at all) or reference
        // external .bin buffers/textures beside the file. The staged-temp
        // import copy cannot resolve siblings, so distinguish the two by
        // inspecting the JSON buffer/image URIs: self-contained bytes are
        // staged and imported by the kernel command importer; external
        // references get an explicit unsupported error (never a silent
        // geometry drop, never an unguarded sibling scan).
        if format == "gltf" {
            switch Self.gltfResourceDependency(of: data) {
            case .selfContained:
                break
            case .externalReferences(let names):
                let list = names.joined(separator: ", ")
                throw CADDocumentError(
                    code: "gltf_external_resources_unsupported",
                    message: "A loose .gltf that references external resources (\(list)) is not imported by the tool in this build. Provide a self-contained .glb or a .gltf whose buffers/images are embedded data URIs.")
            case .invalidJSON:
                throw CADDocumentError(
                    code: "gltf_invalid_json",
                    message: "The .gltf source is not valid JSON; the document was not changed.")
            }
        }
        // Self-contained binary .glb: stage the guarded bytes for the kernel
        // importer (no folder sibling scan).
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("floecad-import-stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("source.\(format)")
        try data.write(to: staged, options: .atomic)
        let operation: [String: Any] = [
            "op": "document.import",
            "args": [
                "path": staged.path,
                "fileName": fileName ?? staged.lastPathComponent,
                "unitScale": unitScale as Any,
            ].compactMapValues { $0 },
        ]
        return document.execute(operation, documentName: fileName)
    }

    /// How a JSON .gltf sources its buffers/images. `.selfContained` means
    /// every present URI is an embedded `data:` URI (or the buffer carries no
    /// URI at all, as in a GLB-style payload), so the staged import copy is
    /// complete. `.externalReferences` lists the referenced resource names —
    /// those bytes live beside the source file and are NOT staged.
    enum GLTFResourceDependency: Equatable {
        case selfContained
        case externalReferences([String])
        case invalidJSON
    }

    static func gltfResourceDependency(of data: Data) -> GLTFResourceDependency {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .invalidJSON }
        var external: [String] = []
        func collect(_ key: String) {
            guard let items = object[key] as? [[String: Any]] else { return }
            for item in items {
                guard let uri = item["uri"] as? String, !uri.isEmpty else { continue }
                if !uri.hasPrefix("data:") { external.append(uri) }
            }
        }
        collect("buffers")
        collect("images")
        return external.isEmpty ? .selfContained : .externalReferences(external)
    }

    private static func importedBodyNames(_ payload: Data) -> [String] {        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            return []
        }
        if let imported = object["imported"] as? [[String: Any]] {
            return imported.compactMap { $0["name"] as? String }
        }
        return object["names"] as? [String] ?? []
    }

    private static func importWarnings(_ payload: Data, format: String) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let note = object["note"] as? String else { return "" }
        return note
    }

    /// The frozen operation args persisted on an import proposal (and later
    /// decoded by `importSpec(from:)` to re-register it after a relaunch).
    static func importArgs(sourcePath: String, format: String, fileName: String?,
                            unitScale: Double?, sourceSHA256: String,
                            geometryClass: String) -> [String: Any] {
        var args: [String: Any] = [
            "sourcePath": sourcePath,
            "format": format,
            "sourceSHA256": sourceSHA256,
            "geometryClass": geometryClass,
        ]
        if let fileName { args["fileName"] = fileName }
        if let unitScale { args["unitScale"] = unitScale }
        return args
    }

    private func fileManagerTempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).floecad")
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

    func discard(proposalID: UUID) {
        service.discardProposal(proposalID)
        pending.removeAll { $0.id == proposalID }
        proposalDocument[proposalID] = nil
        importSpecs[proposalID] = nil
    }

    /// Whether a pending proposal was drafted as an import (vs a typed
    /// geometry/service proposal). The center routes the authorized apply
    /// accordingly.
    func isImportProposal(_ proposalID: UUID) -> Bool { importSpecs[proposalID] != nil }

    /// Re-registers a durably recorded pending proposal after an app restart
    /// (the in-process `pending` list is empty then). Geometry/service
    /// proposals are re-adopted by the proposal service — no evaluation
    /// re-runs — and the live document must still be at the recorded base
    /// revision/SHA, otherwise the restored proposal is refused as stale.
    /// Import proposals re-register their frozen source specification from
    /// the record's operation args (the host re-reads the source at apply).
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
        if let spec = Self.importSpec(from: proposal) {
            importSpecs[proposal.id] = spec
        } else {
            // The proposal service owns the geometry/service apply path;
            // re-register the frozen record there too (it validates
            // revision/SHA again at apply).
            service.adoptRestored(proposal)
        }
    }

    /// Reconstructs the frozen import specification from a persisted record's
    /// operation JSON; nil when the record is not an import proposal.
    static func importSpec(from proposal: CADProposalRecord) -> ImportSpec? {
        guard let data = proposal.operationJSON.data(using: .utf8),
              let operation = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              operation["op"] as? String == "document.import",
              let args = operation["args"] as? [String: Any],
              let format = args["format"] as? String,
              let sha = args["sourceSHA256"] as? String,
              let sourcePath = args["sourcePath"] as? String else { return nil }
        return ImportSpec(sourceRelativePath: sourcePath,
                          format: format,
                          fileName: args["fileName"] as? String,
                          unitScale: args["unitScale"] as? Double,
                          sourceSHA256: sha)
    }

    /// Pending proposals for one document as the interactive banner shows
    /// them (sorted newest first).
    func pendingProposals(for url: URL) -> [CADProposalRecord] {
        let key = key(url)
        return pending
            .filter { proposalDocument[$0.id].map { self.key($0) == key } ?? false }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Viewport capture / shared material library

    /// Actual offscreen viewport render of the live document, bound to its
    /// revision and live change count. The host owns artifact writing.
    func captureViewport(at url: URL, width: Int, height: Int,
                         expectedRevision: Int?) async throws -> CADViewportCaptureResult {
        let document = try await document(at: url)
        #if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
        // Present owns the pixels while it is actually showing this document.
        // Inactive -> nil -> explicit engineering fallback. Active failure or
        // a stale revision throws and MUST NOT be replaced by another renderer.
        if let presented = try await document.capturePresentedPNG(
            width: width, expectedRevision: expectedRevision) {
            return CADViewportCaptureResult(
                pngData: presented.pngData,
                width: presented.width,
                height: presented.height,
                revision: presented.revision,
                changeCount: presented.changeCount,
                // The PNG digest and the document package identity are
                // different identities; never alias one to the other.
                contentSHA256: document.contentSHA256,
                sha256: presented.sha256,
                renderer: "presentation",
                note: "Actual live RealityKit Present render of the open document.")
        }
        #endif
        return try document.captureViewportPNG(width: width, height: height,
                                               expectedRevision: expectedRevision)
    }

    /// App-owned shared material library file, used only by explicit
    /// libraryImport/libraryExport calls. Document packages stay self-contained.
    nonisolated static func materialLibraryFileURL(createDirectory: Bool = false) throws -> URL {
        let url = FloeCADDocument.sharedMaterialLibraryURL
        if createDirectory {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        }
        return url
    }

    /// An optional provided revision pin is authoritative: a mismatch is
    /// refused BEFORE any material/parameter mutation. `nil` keeps the
    /// ordinary action contract.
    static func requireRevisionPin(_ request: [String: Any],
                                   document: FloeCADDocument) throws {
        guard let raw = request["revision"] else { return }
        let value: Int64
        if let number = raw as? Int64 { value = number }
        else if let number = raw as? Int { value = Int64(number) }
        else if let number = raw as? NSNumber { value = number.int64Value }
        else if let text = raw as? String, let number = Int64(text) { value = number }
        else {
            throw CADDocumentError(code: "bad_revision", message: "revision must be an integer.")
        }
        guard value == Int64(document.revision) else {
            throw CADDocumentError(
                code: "revision_mismatch",
                message: "The document is at revision \(document.revision), not the requested "
                    + "\(value). Re-read it before this material/parameter action.")
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
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
