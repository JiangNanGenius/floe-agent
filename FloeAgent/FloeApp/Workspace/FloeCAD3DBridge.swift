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
//   {"kind":"versions","payload":{"action":...}}   -> E34 named design versions
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
import FloeTools
import FloeWorkbench

/// The tool-task token is the same cooperative signal the kernel's import
/// budget polls; the conformance lets the bridge pass it straight through
/// without copying its state.
extension CancellationToken: @retroactive MeshImportCancellationChecking {}

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
        let resourcePaths: [String: String]
        let resourceSHA256: [String: String]
        init(sourceRelativePath: String, format: String, fileName: String?, unitScale: Double?, sourceSHA256: String,
             resourcePaths: [String: String] = [:], resourceSHA256: [String: String] = [:]) {
            self.sourceRelativePath=sourceRelativePath; self.format=format; self.fileName=fileName
            self.unitScale=unitScale; self.sourceSHA256=sourceSHA256
            self.resourcePaths=resourcePaths; self.resourceSHA256=resourceSHA256
        }
    }
    private var importSpecs: [UUID: ImportSpec] = [:]

    private var documents: [String: FloeCADDocument] = [:]
    /// Public editor presentations can re-adopt the SAME cached instance.
    /// Headless queries deliberately do not renew this presentation lease.
    private var documentAdoptions: [String: UUID] = [:]
    /// In-flight opens keyed by canonical path: concurrent callers share one
    /// open so two FloeCADDocument instances can never own the same file.
    private var opening: [String: Task<FloeCADDocument, Error>] = [:]
    private var proposalDocument: [UUID: URL] = [:]
    private let service = CADProposalService()
    /// In-flight import parses keyed by canonical document path. Closing or
    /// switching away from a document cancels them so a late parse cannot
    /// persist a proposal for a document the user left.
    private var inFlightImports: [String: [UUID: MeshImportCancellation]] = [:]

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

    /// Install the App-owned recovery sink for the DIRECT Present export on a
    /// document this bridge owns. The sink is bound to the document's exact
    /// canonical URL and is installed once; a second view/presentation of the
    /// same live session cannot replace its owner. The tool/headless export
    /// path never calls this sink, so it cannot create a duplicate record.
    private func installEditorExportRecovery(_ document: FloeCADDocument) {
        // Every host/tool open gets the same document-scoped codec adapters,
        // including exports invoked before a workbench view has appeared.
        CADDrawingModelBridge.configure(document)
        guard document.animationExportRecoverySink == nil else { return }
        document.installAnimationExportRecoverySink(
            NativeCADEditorAnimationExportRecovery(documentURL: document.url))
    }

    private func document(at url: URL) async throws -> FloeCADDocument {
        let key = key(url)
        if let existing = documents[key], !existing.isReadOnly, !existing.isClosed {
            installEditorExportRecovery(existing)
            return existing
        }
        // A closed session is ownerless. Never hand it to a new presentation:
        // a FilePreview reload may have flushed and closed its document before
        // releasing ownership, and a reopened path must start fresh.
        if documents[key]?.isClosed == true {
            documents[key] = nil
            services[key] = nil
            documentAdoptions[key] = nil
        }
        // Reentrancy guard: one in-flight open per canonical path, shared by
        // every concurrent caller.
        if let inFlight = opening[key] {
            let document = try await inFlight.value
            installEditorExportRecovery(document)
            return document
        }
        let task = Task { () throws -> FloeCADDocument in
            try await FloeCADDocument.open(at: url)
        }
        opening[key] = task
        do {
            let document = try await task.value
            opening[key] = nil
            documents[key] = document
            installEditorExportRecovery(document)
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
        let document = try await document(at: url)
        guard !document.isClosed else {
            throw CADDocumentError(code: "document_closed", message: "The document closed before the editor could open it.")
        }
        documentAdoptions[key(url)] = UUID()
        return document
    }

    /// Registers one in-flight import token under its canonical document.
    @discardableResult
    private func beginImport(_ url: URL,
                             observing outer: (any MeshImportCancellationChecking)? = nil)
        -> (id: UUID, token: MeshImportCancellation, key: String) {
        let key = key(url)
        let id = UUID()
        let token = MeshImportCancellation(observed: outer)
        inFlightImports[key, default: [:]][id] = token
        return (id, token, key)
    }

    private func endImport(_ id: UUID, key: String) {
        inFlightImports[key]?[id] = nil
        if inFlightImports[key]?.isEmpty == true { inFlightImports[key] = nil }
    }

    /// Cancels every import parse still running for `url`. Called when the
    /// editor closes, the preview is dismissed or another document replaces
    /// this one; the parse observes this token and refuses before any commit.
    func cancelInFlightImports(for url: URL) {
        let key = key(url)
        guard let tokens = inFlightImports[key] else { return }
        for token in tokens.values { token.cancel() }
        inFlightImports[key] = nil
    }

    /// Save and release one document, returning its real outcome. The cache
    /// entry is kept until the commit SUCCEEDS: a failed save must not drop the
    /// only live owner of the draft, so the caller can keep the editor open and
    /// retry. Nil means this bridge did not own that exact document (the caller
    /// still owns the instance it passed to `openDocument`).
    ///
    /// `expected` pins the release to the instance the caller adopted.
    /// Omitting it keeps the legacy URL-only behaviour, and the post-await
    /// ownership check below still prevents a stale completion from touching a
    /// session that was closed and reopened at the same path. That check is
    /// always applied: ownership may move while the commit awaits real I/O,
    /// and a command may run while it is blocked, leaving a newer edit that
    /// this save payload does not contain.
    @discardableResult
    func releaseDocumentOutcome(at url: URL,
                                expected: FloeCADDocument? = nil) async -> CADSaveOutcome? {
        // A close/switch cancels an in-flight import BEFORE the release save:
        // a parse that finishes later must not persist a proposal for a
        // document the user left (the proposal copy is separate from this
        // document, so only the token can stop it).
        cancelInFlightImports(for: url)
        let key = key(url)
        guard let document = documents[key] else { return nil }
        if let expected, document !== expected { return nil }
        guard !document.isClosed else {
            // An already-closed session has no owner and no draft to save.
            documents[key] = nil
            services[key] = nil
            documentAdoptions[key] = nil
            return nil
        }
        let adoption = documentAdoptions[key]
        // Explicit save may persist thumbnail/metadata even on a clean model.
        // Releasing a clean owner must not create an unrelated extra revision.
        let outcome: CADSaveOutcome
        if document.hasUnsavedChanges || document.isReadOnly {
            outcome = await document.save()
        } else {
            outcome = document.savedIdentity
        }
        guard documents[key] === document else {
            // A newer session owns the path now. Never let this stale
            // completion drop it or close it. If the caller's own instance was
            // already closed by that newer flow, its release is complete and
            // it still gets its real outcome; otherwise it remains the
            // caller's to save/release.
            return document.isClosed ? outcome : nil
        }
        guard documentAdoptions[key] == adoption else {
            // An editor opened this same instance while the save awaited IO.
            // The saved receipt still belongs to the document, but this old
            // release no longer owns its presentation or permission to close.
            return nil
        }
        guard !document.isClosed else {
            // The owner closed this instance while its commit was in flight.
            // There is no owner left for a draft; drop only the dead entry.
            documents[key] = nil
            services[key] = nil
            documentAdoptions[key] = nil
            return outcome
        }
        guard outcome.error == nil else {
            lastMessage = "CAD save failed (document kept open for retry): \(outcome.error ?? "")"
            return outcome
        }
        // A command that ran while the commit was suspended is not part of
        // this payload. Closing now would silently discard that draft: keep
        // the only live owner and its cache entry, and report a retryable
        // release failure instead of pretending the document is clean.
        guard !document.hasUnsavedChanges else {
            lastMessage = "CAD document changed while releasing; kept open for retry."
            var retry = outcome
            retry.error = String(localized: "cad.recovery.release.changed")
            return retry
        }
        documents[key] = nil
        services[key] = nil
        documentAdoptions[key] = nil
        document.close()
        return outcome
    }

    /// Drop ownership of a READ-ONLY document without attempting a commit.
    /// Such a document has no writable draft (newer schema / opaque package),
    /// so a failed "save" must not keep an editor open or claim data loss. A
    /// writable document is refused (false) so no draft is ever discarded here.
    @discardableResult
    func releaseReadOnlyDocument(_ document: FloeCADDocument) -> Bool {
        guard document.isReadOnly else { return false }
        cancelInFlightImports(for: document.url)
        let key = key(document.url)
        // Drop the cache entry only when it is THIS instance, so a concurrent
        // read-only open of the same path is never closed by this release.
        if documents[key] === document {
            documents[key] = nil
            services[key] = nil
            documentAdoptions[key] = nil
        }
        document.close()
        return true
    }

    /// Release a document that the workbench/FilePreviewView closed. The cache
    /// entry is kept until the commit SUCCEEDS: a failed save must not drop
    /// the only live owner of the draft. The retained document stays open for
    /// retry/recovery and the failure is surfaced. `expected` keeps a late
    /// release on the exact adopted instance; existing URL-only callers keep
    /// their current behaviour.
    func releaseDocument(at url: URL, expected: FloeCADDocument? = nil) async {
        _ = await releaseDocumentOutcome(at: url, expected: expected)
    }

    func handle(url: URL, requestJSON: String,
                cancellation: CancellationToken? = nil) async throws -> String {
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
                "selection": document.assistantSelectionContext().jsonObject(),
            ])

        case "query":
            let payload = request["payload"] as? [String: Any] ?? [:]
            let scope = payload["scope"] as? String ?? "snapshot"
            if scope == "selection" {
                return try jsonString([
                    "ok": true,
                    "result": document.assistantSelectionContext().jsonObject(),
                ])
            }
            if scope == "assembly" {
                let reply = await native.assembly.handleAsync(action: "report", args: [:])
                return try jsonString(["ok": reply["ok"] as? Bool ?? false, "result": reply])
            }
            if scope == "drawings" {
                let reply = native.drawing.handle(action: "pages", args: [:])
                return try jsonString(["ok": reply["ok"] as? Bool ?? false, "result": reply])
            }
            if scope == "animation" {
                return try jsonString(document.animationListJSON())
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
            var reply = await CADMaterialService(document: document).handleAsync(action: action, args: payload, cancellation:cancellation)
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
            var reply = await CADParameterService(document: document).handleAsync(action: action, args: payload)
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

        case "scene":
            // X22: the persisted view overlay is ordinary document state in
            // the existing additive sceneSettings column. The service uses the
            // document's own undo/read-only/closed rules; this bridge adds the
            // same revision pin and CAS commit as material/parameter edits.
            // No new tool, grant or approval path is involved.
            let payload = request["payload"] as? [String: Any] ?? [:]
            guard let action = payload["action"] as? String, !action.isEmpty else {
                throw CADDocumentError(
                    code: "missing_action",
                    message: "scene requires payload.action ("
                        + CADViewOverlayService.actions.joined(separator: "|") + ").")
            }
            try Self.requireRevisionPin(request, document: document)
            let changeBefore = document.liveChangeCount
            let checkpoint = document.captureEditCheckpoint()
            var reply = await CADViewOverlayService(document: document).handleAsync(
                action: action, args: payload, cancellation: cancellation)
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

        case "animation":
            let payload = request["payload"] as? [String: Any] ?? [:]
            guard let action = payload["action"] as? String,
                  CadNativeEditActions.animation.contains(action) else {
                throw CADDocumentError(
                    code: "missing_action",
                    message: "animation requires payload.action ("
                        + CadNativeEditActions.animation.sorted().joined(separator: "|") + ").")
            }
            guard action != "capture", action != "export" else {
                // Bytes/VM output belong to the host task path, never a JSON
                // string reply that would pretend a file was produced.
                throw CADDocumentError(
                    code: "host_task_required",
                    message: "animation \(action) must run through the host animation task path.")
            }
            try Self.requireRevisionPin(request, document: document)
            let changeBefore = document.liveChangeCount
            let checkpoint = document.captureEditCheckpoint()
            var reply = CADAnimationService(document: document).handle(
                action: action, args: payload)
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
            let reply = await native.drawing.handleAsync(action: action, args: args)
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
            // Heavy mesh work (boolean/simplify/combine/repair) snapshots the
            // inputs on the main actor and joins a service-owned detached
            // worker; the caller's Task cancellation fences the late commit.
            let reply = await native.mesh.handleAsync(action: action, args: args)
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
                "message": "Proposal prepared. Apply it with cad.document action=apply and this proposal_id; ordinary authorized document editing needs no separate confirmation.",
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

        case "versions":
            // E34: user-named design versions. This is the same live document
            // and the same save kernel; the service owns the checkpoint store,
            // exact compare and the revision/CAS restore transaction. The
            // request's task ownership has already been authorized by the
            // host before this bridge is reached.
            let payload = request["payload"] as? [String: Any] ?? [:]
            guard let action = payload["action"] as? String,
                  !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CADDocumentError(
                    code: "missing_action",
                    message: "versions requires payload.action "
                        + "(list|create|compare|restore|delete|recoveries|recover|discard_recovery|record).")
            }
            do {
                let operation = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if ["merge_compare", "merge_apply", "merge_cancel"].contains(operation) {
                    // This URL was resolved and overwritten by the App host's
                    // existing workspace guard, never trusted from a model.
                    let source = (payload["_resolved_merge_source_url"] as? String).flatMap(URL.init(string:))
                    return try await document.handleCopyMergeAction(operation, args: payload, sourceURL: source)
                }
                return try await document.handleNamedVersionAction(action, args: payload)
            } catch let error as CADNamedVersionError {
                throw CADDocumentError(code: "versions_failed",
                                       message: error.localizedDescription)
            }

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
            "package_schema_version": FloeCADDocument.supportedPackageSchemaVersion,
            "editing_authorization": [
                "separate_review_required": false,
                "apply": "Use cad.document action=apply with proposal_id; omit grant_id for ordinary authorized editing.",
                "document_ownership_and_revision_checks": true,
            ],
            "actions": CadDocumentAction.allCases.filter { $0 != .observe }.map(\.rawValue),
            // X22: the persisted view overlay is an action of this same tool,
            // not a separate tool or permission surface.
            "scene_actions": CADViewOverlayService.actions,
            "scene_note": "Section/measurement and material/animation edits are ordinary "
                + "undoable document commands committed with CAS; raster/video include "
                + "the cut and guide lines but not numeric text, and model exchange "
                + "formats carry geometry only.",
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
            // Guaranteed-refusal ops stay parseable for historical callers but
            // are NOT advertised as executable. Each row names the stable
            // executor refusal; the tool schema teaches the supported
            // alternatives. A capability consumer must not offer these as
            // callable operations.
            "unavailable_operations": FloeCADDocument.unavailableNativeOperations,
            "material_actions": CADMaterialService.actions,
            "parameter_actions": CADParameterService.actions,
            "scene_snapshot_schema": FloeCADDocument.sceneSnapshotSchemaVersion,
            "export": [
                "scopes": ["part", "assembly"],
                "coverage": true,
                "dry_run": true,
                "part_formats": ["step", "iges", "stl", "obj", "obj_bundle", "3mf",
                                 "glb", "usdz", "pdf", "svg", "dxf", "dwg", "csv"],
                "assembly_formats": ["step", "glb", "usdz"],
                "bundle_formats": ["obj_bundle"],
                "selection": ["body_ids", "instance_ids"],
                "partial": "requires accept_partial=true; the receipt is never reported complete",
                "obj_bundle": "one .zip with model.obj + model.mtl + relative texture resources; "
                    + "plain obj remains a single .obj with UVs and no materials",
            ],
            "viewport_capture": ["formats": ["png"], "min_size": 64, "max_size": 4096],
            "animation_actions": CADAnimationService.advertisedActions,
            // Keep service summary and detail names in one catalog. App-level
            // parity tests pin every catalog array to its native executor;
            // material/parameter/animation vocabularies use the native services.
            "assembly_actions": CadServiceOperationCatalog.actionNames(forKind: "assembly"),
            "drawing_actions": CadServiceOperationCatalog.actionNames(forKind: "drawing"),
            "script_actions": CadServiceOperationCatalog.actionNames(forKind: "script"),
            "mesh_actions": CADMeshService.advertisedActions,
            // Derived from the executable assembly service, not a retired
            // gate: there is no fixed pair limit (the old max_pairs=32 is
            // gone). Complete pair details are bounded by the explicit byte
            // envelope that the runtime can fully capture and page.
            "limits": ["interference_result_bytes": CADAssemblyService.interferenceResultBudgetBytes,
                       "interference_detail_digest": CADAssemblyService.interferenceDetailDigestAlgorithm,
                       "interference_pair_contract": "every requested unordered pair is processed exactly once; no fixed pair cap; complete details are bounded by interference_result_bytes",
                       "interference_volume_tolerance_mm3_default": 0,
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
    private static let commandImporterFormats: Set<String> = ["glb", "gltf", "zip", "blend", "usd", "usda", "usdc", "usdz"]

    /// Whether an import format yields render-only mesh bodies (no analytic
    /// B-rep, no parametric feature history).
    static func isMeshImportFormat(_ format: String) -> Bool {
        meshImportFormats.contains(format) || commandImporterFormats.contains(format)
    }

    /// The ACTUAL geometry classes an import preview produced, captured from
    /// the same throwaway apply that produced the body names. This is what
    /// lets the banner/tool reply state an open-surface limitation BEFORE the
    /// user applies, instead of calling every IGES file "B-rep" because the
    /// format name is `.igs`.
    struct ImportContent {
        let formatLabel: String
        /// "mesh" | "solid" | "surface" | "mixed".
        let geometryClass: String
        let solids: Int
        let surfaces: Int
        let openSurfaces: Int
        let bodyCount: Int

        func message(warnings: String) -> String {
            var text: String
            switch geometryClass {
            case "mesh":
                text = "Import \(formatLabel) preview: \(bodyCount) mesh body(ies) "
                    + "would be added; no parametric feature history is created."
            case "surface":
                text = "Import \(formatLabel) preview: \(bodyCount) exact open-surface "
                    + "body(ies) would be added; open surfaces support move/rotate/scale, "
                    + "material and IGES re-export but not solid boolean/fillet/shell; "
                    + "no parametric feature history is created."
            case "mixed":
                text = "Import \(formatLabel) preview: \(solids) exact solid body(ies) "
                    + "+ \(surfaces) exact open-surface body(ies) would be added; open "
                    + "surfaces support move/rotate/scale, material and IGES re-export but "
                    + "not solid boolean/fillet/shell; no parametric feature history is created."
            default:
                text = "Import \(formatLabel) preview: "
                    + "\(max(solids, bodyCount)) exact B-rep solid body(ies) would be added; "
                    + "no parametric feature history is created."
            }
            return warnings.isEmpty ? text : text + " " + warnings
        }
    }

    static func importContent(_ payload: Data, format: String,
                              bodyCount: Int) -> ImportContent {
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        var solids = object["solidsImported"] as? Int ?? 0
        var surfaces = object["surfacesImported"] as? Int ?? 0
        var openSurfaces = object["openSurfaceBodies"] as? Int ?? surfaces
        if isMeshImportFormat(format) {
            return ImportContent(formatLabel: format.uppercased(), geometryClass: "mesh",
                                 solids: 0, surfaces: 0, openSurfaces: 0,
                                 bodyCount: bodyCount)
        }
        // Older/other B-rep payloads may omit the split; an IGES note that
        // says surfaces are not solids is real evidence of surface bodies.
        if format == "iges", solids == 0, surfaces == 0,
           let note = object["note"] as? String,
           note.contains("IGES surfaces are not solids") {
            surfaces = bodyCount
            openSurfaces = bodyCount
        }
        // STEP (and any other B-rep import without a split payload) reports
        // only body names; those bodies are exact solids.
        if !isMeshImportFormat(format), solids == 0, surfaces == 0, bodyCount > 0 {
            solids = bodyCount
        }
        let geometryClass: String
        if surfaces > 0 && solids > 0 {
            geometryClass = "mixed"
        } else if surfaces > 0 {
            geometryClass = "surface"
        } else {
            geometryClass = "solid"
        }
        return ImportContent(formatLabel: format.uppercased(), geometryClass: geometryClass,
                             solids: solids, surfaces: surfaces,
                             openSurfaces: openSurfaces, bodyCount: bodyCount)
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
    /// STEP/IGES reuse `CADExactImportService`; all mesh formats reuse
    /// `CADMeshImportService` with the same explicitly supplied resources
    /// and units as the manual editor. No parser is implemented here, and no
    /// parametric feature history is synthesized for imported geometry.
    func proposeImport(at url: URL, sourceRelativePath: String, data: Data,
                       format rawFormat: String,
                       fileName: String?, unitScale: Double?,
                       sourceSHA256: String, summary: String,
                       siblings: [String: Data] = [:], resourcePaths: [String: String] = [:],
                       cancellation: CancellationToken? = nil) async throws -> CADProposalRecord {
        var format = rawFormat.lowercased()
        if format == "igs" { format = "iges" }
        try cancellation?.throwIfCancelled()
        // One token for the whole draft: it observes the tool-run token and is
        // also cancelled by a close/switch through `cancelInFlightImports`.
        let registration = beginImport(url, observing: cancellation)
        let importToken = registration.token
        defer { endImport(registration.id, key: registration.key) }
        let document = try await document(at: url)
        // Mirror CADProposalService: flush live edits first so the proposal
        // binds the bytes the grant will validate; a flush failure refuses.
        // `flushIfDirty` is package-internal. Only call the public save when
        // dirty: an explicit clean save can still persist metadata/preview.
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
        defer { if !clone.isClosed { clone.close() } }
        try Self.checkImportCancellation(importToken)
        let outcome = try await Self.applyImport(document: clone, data: data, format: format,
                                                 fileName: fileName, unitScale: unitScale, siblings: siblings,
                                                 cancellation: importToken)
        try Self.checkImportCancellation(importToken)
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

        let content = Self.importContent(outcome.payload, format: format,
                                         bodyCount: addedNames.count)
        let geometryClass = content.geometryClass
        let message = content.message(warnings: warnings)
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
            "importGeometryClass": geometryClass,
            "importSolidBodyCount": content.solids,
            "importSurfaceBodyCount": content.surfaces,
            "importOpenSurfaceBodyCount": content.openSurfaces,
        ]
        let previewData = try JSONSerialization.data(withJSONObject: previewJSON)
        let preview = try JSONDecoder().decode(CADProposalPreview.self, from: previewData)

        let operation: [String: Any] = [
            "op": Self.isMeshImportFormat(format) ? "document.importMeshGroup" : "document.import",
            "args": Self.importArgs(sourcePath: sourceRelativePath, format: format,
                                    fileName: fileName, unitScale: unitScale,
                                    sourceSHA256: sourceSHA256, geometryClass: geometryClass,
                                    resourcePaths: resourcePaths, resourceSHA256: try CADImportResources.hashes(siblings)),
        ]
        let operationJSON = try jsonString(operation)
        // A draft that finished after the owner cancelled must not become a
        // pending proposal; the throwaway copy is already closed above and the
        // caller persists nothing on a throw.
        try Self.checkImportCancellation(importToken)
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
                                           sourceSHA256: sourceSHA256, resourcePaths: resourcePaths,
                                           resourceSHA256: try CADImportResources.hashes(siblings))
        return record
    }

    /// Apply an ALREADY-AUTHORIZED import proposal to the live document with
    /// the guarded, re-verified source bytes. Re-checks the base revision/SHA
    /// and source SHA, mutates once and commits. A failed commit drops the
    /// cached live session so the next open reloads the last committed
    /// package rather than keeping an uncommitted import.
    @discardableResult
    func performAuthorizedImport(proposalID: UUID, data: Data,
                                 expectedSourceSHA256: String,
                                 siblings: [String: Data] = [:],
                                 cancellation: CancellationToken? = nil) async throws -> CADApplyReceipt {
        try cancellation?.throwIfCancelled()
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
        guard try CADImportResources.hashes(siblings) == spec.resourceSHA256 else {
            throw CADDocumentError(code: "source_changed", message: "An import resource changed after preview. Draft the complete group again; nothing was applied.")
        }
        // The apply re-parses off the MainActor under the same token. A
        // cancellation that arrives before the body command runs refuses with
        // zero mutation; once the atomic add has run the commit completes
        // normally (never a half model).
        let registration = beginImport(url, observing: cancellation)
        let importToken = registration.token
        defer { endImport(registration.id, key: registration.key) }
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
        try Self.checkImportCancellation(importToken)
        let outcome = try await Self.applyImport(document: document, data: data,
                                                 format: spec.format,
                                                 fileName: spec.fileName,
                                                 unitScale: spec.unitScale, siblings: siblings,
                                                 cancellation: importToken)
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
                documentAdoptions[key(url)] = nil
            }
            throw CADDocumentError(code: "save_failed",
                                   message: save.error
                                    ?? "The imported geometry could not be committed; the document was reloaded from the last saved package.")
        }
        let content = Self.importContent(outcome.payload, format: spec.format,
                                         bodyCount: Self.importedBodyNames(outcome.payload).count)
        let receipt = CADApplyReceipt(proposalID: proposalID,
                                      revision: save.revision,
                                      contentSHA256: save.contentSHA256,
                                      message: "Imported and committed \(spec.format.uppercased()) geometry "
                                        + "(\(content.bodyCount) body/bodies; \(content.geometryClass)). "
                                        + Self.importWarnings(outcome.payload, format: spec.format))
        pending.removeAll { $0.id == proposalID }
        proposalDocument[proposalID] = nil
        importSpecs[proposalID] = nil
        lastMessage = receipt.message
        return receipt
    }

    /// One import attempt against `document`. STEP/IGES read and tessellate
    /// OFF the MainActor through `CADExactImportService` (fresh import handles
    /// only), then restore their serialized exact shapes and commit on the
    /// document actor as ONE undo step. Mesh formats use the same scheduling
    /// split through `CADMeshImportService` under the same budget/token.
    private static func applyImport(document: FloeCADDocument, data: Data, format: String,
                                    fileName: String?, unitScale: Double?, siblings: [String: Data] = [:],
                                    cancellation: MeshImportCancellation) async throws -> CADCommandOutcome {
        do {
            if brepImportFormats.contains(format) {
                let plan = try await CADExactImportService.parseOffMain(
                    data: data, format: format,
                    fileName: fileName ?? "Imported.\(format)",
                    limits: .standard, cancellation: cancellation)
                try Self.checkImportCancellation(cancellation)
                if document.isClosed {
                    throw CADDocumentError(code: "read_only",
                                           message: "The CAD document is closed.")
                }
                let application = try CADExactImportService.apply(
                    plan, to: document, cancellation: cancellation,
                    undoMode: .singleStep)
                return application.outcome
            }
            guard Self.isMeshImportFormat(format) else {
                throw CADDocumentError(code: "unsupported_format", message: "Unsupported import format \(format).")
            }
            let displayName = (fileName ?? "Imported").components(separatedBy: "/").last ?? "Imported"
            let name = displayName.lowercased().hasSuffix(".\(format)") ? displayName : displayName + "." + format
            let plan = try await CADMeshImportService.parseOffMain(
                data: data, fileName: name, siblings: siblings, unitScale: unitScale,
                requireExplicitUnits: true, cancellation: cancellation)
            return try CADMeshImportService.apply(plan, to: document, cancellation: cancellation)
        } catch let error as CADDocumentError {
            throw error
        } catch is CancellationError {
            throw CADDocumentError(
                code: "cancelled",
                message: "The import was cancelled; nothing was imported and the source was not changed.")
        } catch {
            throw CADDocumentError(code: "import_failed",
                                   message: "The import failed: \(error.localizedDescription) "
                                    + "Nothing was imported; the source and document are unchanged.")
        }
    }

    /// Refuses a cancelled draft/apply before any document mutation. Used by
    /// both the proposal copy and the live authorized import so the two paths
    /// cannot disagree about the cancel fence.
    private static func checkImportCancellation(_ token: MeshImportCancellation) throws {
        if token.isCancelled {
            throw CADDocumentError(
                code: "cancelled",
                message: "The import was cancelled; nothing was imported and the source was not changed.")
        }
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
                            geometryClass: String, resourcePaths: [String: String] = [:],
                            resourceSHA256: [String: String] = [:]) -> [String: Any] {
        var args: [String: Any] = [
            "sourcePath": sourcePath,
            "format": format,
            "sourceSHA256": sourceSHA256,
            "geometryClass": geometryClass,
        ]
        if let fileName { args["fileName"] = fileName }
        if let unitScale { args["unitScale"] = unitScale }
        if Self.isMeshImportFormat(format) {
            args["groupVersion"] = 1
            args["resourcePaths"] = resourcePaths
            args["resourceSHA256"] = resourceSHA256
        }
        return args
    }

    private func fileManagerTempURL(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString).floecad")
    }

    // MARK: Native export / import (host-guarded callers)

    struct NativeExportResult: Sendable {
        /// Nil for a dry-run coverage receipt or a receipt that needs an
        /// explicit partial-export choice. Never a half-written file.
        let data: Data?
        let note: String
        let revision: Int
        let changeCount: Int
        let contentSHA256: String
        /// JSON-encoded `CADExchangeCoverage`. The legacy part export now
        /// carries the SAME receipt as the explicit-scope route; only drawing
        /// formats (whose service refuses an incomplete set itself) leave it
        /// empty.
        let coverageJSON: String
        let complete: Bool
        let requiresConfirmation: Bool
    }

    /// Exact/format export bytes for the open document. Runs on the main
    /// actor with the shared live session; the host owns path resolution,
    /// writing and verification.
    ///
    /// The legacy (unscoped) part export is NOT a raw pass-through any more:
    /// it returns the same truthful per-body receipt as the exchange route and
    /// yields no bytes while that receipt is incomplete. An explicit partial
    /// export stays on the existing `scope=part|assembly` + `accept_partial`
    /// route, so no partial choice is inferred here.
    func exportNativeData(at url: URL, format: String, pageID: UUID?) async throws -> NativeExportResult {
        let document = try await document(at: url)
        var normalized = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "igs" { normalized = "iges" }
        let receiptFormats: Set<String> = ["step", "iges", "stl", "obj", "obj_bundle",
                                           "3mf", "glb", "usdz"]
        if receiptFormats.contains(normalized) {
            switch document.nativePartExport(format: normalized, pageID: pageID) {
            case let .success(data, note, coverage):
                return NativeExportResult(data: data, note: note,
                                          revision: coverage.documentRevision,
                                          changeCount: coverage.changeCount,
                                          contentSHA256: coverage.contentSHA256,
                                          coverageJSON: coverage.jsonString(),
                                          complete: coverage.complete,
                                          requiresConfirmation: coverage.requiresConfirmation)
            case let .coverageRequired(coverage):
                return NativeExportResult(data: nil,
                                          note: "coverage incomplete; explicit choice required",
                                          revision: coverage.documentRevision,
                                          changeCount: coverage.changeCount,
                                          contentSHA256: coverage.contentSHA256,
                                          coverageJSON: coverage.jsonString(),
                                          complete: false,
                                          requiresConfirmation: true)
            case let .coverage(coverage):
                return NativeExportResult(data: nil, note: "coverage preview",
                                          revision: coverage.documentRevision,
                                          changeCount: coverage.changeCount,
                                          contentSHA256: coverage.contentSHA256,
                                          coverageJSON: coverage.jsonString(),
                                          complete: coverage.complete,
                                          requiresConfirmation: coverage.requiresConfirmation)
            case let .failure(error):
                // Keep the legacy USDZ platform contract for callers of the
                // unscoped route; the exchange route uses `unsupportedPlatform`.
                if normalized == "usdz", error.code == "unsupportedPlatform" {
                    throw CADDocumentError(
                        code: "usdz_unavailable",
                        message: "USDZ export is not available on this platform/build.")
                }
                throw error
            }
        }
        switch await document.nativeExportDataAsync(format: format, pageID: pageID) {
        case .success(let (data, note)):
            return NativeExportResult(data: data, note: note,
                                      revision: document.revision,
                                      changeCount: document.exchangeChangeCount,
                                      contentSHA256: document.contentSHA256,
                                      coverageJSON: "",
                                      complete: true,
                                      requiresConfirmation: false)
        case .failure(let error):
            throw error
        }
    }

    /// Placed-assembly exchange export (E24/E25). The same core plan/call the
    /// UI uses; bytes are returned only when the coverage is complete or the
    /// caller explicitly accepted a partial receipt. The host still owns
    /// staging, digest verification and atomic promotion.
    func exportNativeData(at url: URL, format: String, pageID: UUID?,
                          selection: CADExchangeSelection,
                          dryRun: Bool) async throws -> NativeExportResult {
        let document = try await document(at: url)
        switch document.nativeExchangeExport(format: format, pageID: pageID,
                                             selection: selection, dryRun: dryRun) {
        case let .success(data, note, coverage):
            return NativeExportResult(data: data, note: note,
                                      revision: coverage.documentRevision,
                                      changeCount: coverage.changeCount,
                                      contentSHA256: coverage.contentSHA256,
                                      coverageJSON: coverage.jsonString(),
                                      complete: coverage.complete,
                                      requiresConfirmation: coverage.requiresConfirmation)
        case let .coverageRequired(coverage):
            return NativeExportResult(data: nil, note: "coverage incomplete; explicit choice required",
                                      revision: coverage.documentRevision,
                                      changeCount: coverage.changeCount,
                                      contentSHA256: coverage.contentSHA256,
                                      coverageJSON: coverage.jsonString(),
                                      complete: coverage.complete,
                                      requiresConfirmation: true)
        case let .coverage(coverage):
            return NativeExportResult(data: nil, note: "coverage preview",
                                      revision: coverage.documentRevision,
                                      changeCount: coverage.changeCount,
                                      contentSHA256: coverage.contentSHA256,
                                      coverageJSON: coverage.jsonString(),
                                      complete: coverage.complete,
                                      requiresConfirmation: coverage.requiresConfirmation)
        case let .failure(error):
            throw error
        }
    }

    /// Re-check the exact live identity immediately before file promotion.
    /// An edit (saved or unsaved), a close/reopen with committed changes, or a
    /// different selection/fence makes the staged export stale; nothing is
    /// written and the previous target is preserved.
    func exportFenceMatches(at url: URL, revision: Int, changeCount: Int,
                            contentSHA256: String) async -> Bool {
        guard let live = try? await document(at: url) else { return false }
        return live.revision == revision
            && live.exchangeChangeCount == changeCount
            && live.contentSHA256 == contentSHA256
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
              let op = operation["op"] as? String,
              ["document.import", "document.importMeshGroup"].contains(op),
              let args = operation["args"] as? [String: Any],
              let format = args["format"] as? String,
              let sha = args["sourceSHA256"] as? String,
              let sourcePath = args["sourcePath"] as? String else { return nil }
        let paths = args["resourcePaths"] as? [String: String] ?? [:]
        let hashes = args["resourceSHA256"] as? [String: String] ?? [:]
        if op == "document.importMeshGroup" {
            guard args["groupVersion"] as? Int == 1, args["resourcePaths"] is [String: String],
                  args["resourceSHA256"] is [String: String], Set(paths.keys) == Set(hashes.keys) else { return nil }
        }
        return ImportSpec(sourceRelativePath: sourcePath,
                          format: format,
                          fileName: args["fileName"] as? String,
                          unitScale: args["unitScale"] as? Double,
                          sourceSHA256: sha, resourcePaths: paths, resourceSHA256: hashes)
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
                // The registry describes the ACTUAL live camera: projection,
                // the selected saved view (when any) and whether the live
                // view still matches it. A temporary orbit never rewrites the
                // saved view.
                note: presented.note,
                projection: presented.projection,
                cameraName: presented.cameraName,
                matchesSavedCamera: presented.matchesSavedCamera,
                sectionCutIncluded: presented.sectionCutIncluded,
                measurementGuideCount: presented.measurementGuideCount,
                measurementLengthsMM: presented.measurementLengthsMM)
        }
        #endif
        // Present is not showing this document. A selected saved view still
        // owns the projection and framing the AI capture must keep; with no
        // selection this is the historical fitted perspective capture.
        return try document.captureViewportPNG(
            width: width, height: height,
            expectedRevision: expectedRevision,
            camera: document.activeSavedCamera)
    }

    func renderStill(at url: URL, requestJSON: String, expectedRevision: Int?) async throws -> CadViewportCapture {
        let document = try await document(at: url)
        if let expectedRevision, document.revision != expectedRevision {
            throw CADDocumentError(code: "revision_mismatch", message: "Re-read the document before rendering.")
        }
        let options = try JSONDecoder().decode(CADStillRenderSettings.self, from: Data(requestJSON.utf8))
        let output = try await CADStillRenderService.shared.render(document: document, settings: options)
        return CadViewportCapture(pngData: output.png, width: output.width, height: output.height,
            revision: Int64(output.revision), changeCount: document.liveChangeCount,
            contentSHA256: output.sourceSHA256, sha256: output.imageSHA256,
            renderer: "presentation-offline",
            note: "Actual offline RealityKit raster, \(output.quality.rawValue), source \(output.sourceWidth)x\(output.sourceHeight); linear-light exposure and saturation; display-sRGB lossless PNG. Not HDR or path tracing. Numeric overlay labels are not drawn.")
    }

    /// Actual animation frame from the live Present or the service render
    /// host. No engineering-viewport fallback: an animation frame must reflect
    /// the native animated scene or the call fails.
    func captureAnimationFrame(at url: URL,
                               request: CadAnimationCaptureRequest) async throws
    -> CadAnimationCapture {
        let document = try await document(at: url)
        if let expected = request.expectedRevision,
           Int64(document.revision) != expected {
            throw CADDocumentError(
                code: "revision_mismatch",
                message: "The document is at revision \(document.revision), not \(expected).")
        }
        let format = request.format.lowercased()
        let capture: CADAnimationFrameCapture
        if let frame = request.frame {
            switch format {
            case "png":
                capture = try await document.captureAnimationFramePNG(
                    clipID: request.clipID, frame: frame, fps: request.fps,
                    width: request.width, height: request.height)
            case "jpeg", "jpg":
                // The time-based overload cannot take a frame index; resolve
                // the exact frame time first so the captured pose is correct.
                let state = document.animationLoadState()
                let clip = request.clipID.flatMap { state.animation.clip(withID: $0) }
                    ?? state.animation.activeClip
                let time = clip.map {
                    FloeCADDocument.animationFrameTime(
                        frame: frame, fps: request.fps, duration: $0.duration)
                } ?? 0
                capture = try await document.captureAnimationFrame(
                    clipID: request.clipID, time: time, width: request.width,
                    height: request.height, frameRate: request.fps,
                    format: .jpeg, jpegQuality: request.jpegQuality)
            default:
                throw CADDocumentError(
                    code: "bad_animation_format",
                    message: "Animation capture format must be png or jpeg.")
            }
        } else {
            let time = request.timeSeconds ?? 0
            switch format {
            case "png":
                capture = try await document.captureAnimationFramePNG(
                    clipID: request.clipID, time: time, width: request.width,
                    height: request.height, frameRate: request.fps)
            case "jpeg", "jpg":
                capture = try await document.captureAnimationFrame(
                    clipID: request.clipID, time: time, width: request.width,
                    height: request.height, frameRate: request.fps,
                    format: .jpeg, jpegQuality: request.jpegQuality)
            default:
                throw CADDocumentError(
                    code: "bad_animation_format",
                    message: "Animation capture format must be png or jpeg.")
            }
        }
        return CadAnimationCapture(
            imageData: capture.imageData,
            mimeType: capture.mimeType,
            width: capture.width, height: capture.height,
            revision: Int64(capture.revision), changeCount: capture.changeCount,
            contentSHA256: capture.contentSHA256, sha256: capture.sha256,
            clipID: capture.clipID, timeSeconds: capture.timeSeconds,
            frameIndex: capture.frameIndex, frameRate: capture.frameRate,
            renderer: capture.renderer, note: capture.note)
    }

    /// Verified animation export. The service renders the real native frames,
    /// writes a staged output and promotes only after read-back verification;
    /// the host owns the workspace-guarded destination and durable task record
    /// around this call.
    func exportAnimation(at url: URL, to output: URL,
                         options: CadAnimationExportOptions) async throws
    -> CADAnimationExportResult {
        let document = try await document(at: url)
        guard let format = CADAnimationExportOutputFormat(
                rawValue: options.format.lowercased()) else {
            throw CADDocumentError(
                code: "bad_animation_format",
                message: "Animation output format must be mp4 or png_zip.")
        }
        guard let alpha = CADAnimationExportAlpha(
                rawValue: options.alpha.lowercased()) else {
            throw CADDocumentError(
                code: "bad_animation_alpha",
                message: "Animation alpha must be opaque or transparent.")
        }
        let codec: CADAnimationVideoCodec
        if format == .mp4 {
            guard let parsed = CADAnimationVideoCodec(
                    rawValue: options.codec.lowercased()) else {
                throw CADDocumentError(
                    code: "bad_animation_codec",
                    message: "Video codec must be h264 or hevc.")
            }
            codec = parsed
        } else {
            guard options.codec.lowercased() == "png" else {
                throw CADDocumentError(
                    code: "bad_animation_codec",
                    message: "PNG frame sequences use codec png.")
            }
            codec = .h264
        }
        let settings = CADAnimationExportSettings(
            width: options.width, height: options.height,
            frameRate: options.frameRate, codec: codec,
            bitrate: options.bitrate, overwrite: options.overwrite,
            posterEnabled: options.posterEnabled,
            format: format, alpha: alpha)
        return try await document.exportAnimation(
            to: output, settings: settings)
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
                    + "\(value). Re-read it before this document edit.")
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
