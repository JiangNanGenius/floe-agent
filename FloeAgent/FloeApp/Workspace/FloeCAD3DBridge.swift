// SPDX-License-Identifier: MPL-2.0
// FloeApp — native CAD (FloeCAD) bridge for the `cad.document` 3D actions.
//
// The bridge owns the open FloeCAD documents (keyed by canonical path) and the
// proposal service. It answers the generic request envelope the tool sends:
//
//   {"kind":"snapshot"}                          -> summary + state JSON
//   {"kind":"measure","payload":{...}}           -> deterministic measurement
//   {"kind":"propose","op":"feature.extrude",
//    "args":{...},"summary":"..."}               -> proposal record JSON
//   {"kind":"apply","proposal_id":"...",
//    "grant_id":"..."}                           -> apply receipt JSON
//
// Propose never writes: it evaluates on a throwaway copy. Apply requires a
// single-use grant; grants are issued here only from the interactive
// confirmation banner (`pending`), never from a model-supplied value.
//
// SPDX-License-Identifier: MPL-2.0

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

    private func key(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
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
        switch kind {
        case "snapshot":
            return try jsonString([
                "ok": true,
                "summary": summaryObject(document),
                "state": jsonObject(document.snapshotJSON()),
            ])
        case "measure":
            let payload = request["payload"] as? [String: Any] ?? [:]
            let outcome = document.measureJSON(payload)
            return try jsonString([
                "ok": outcome.isOK,
                "result": jsonObject(outcome.payload),
                "error": outcome.errorCode ?? "",
                "message": outcome.message ?? "",
            ])
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
        case "apply":
            // Authority lives in CadDocumentCenter's shared grant store; the
            // bridge must never consume a grant on its own. The host handles
            // apply before delegating and calls performAuthorizedApply.
            throw CADDocumentError(
                code: "grant_authority",
                message: "Native CAD apply must be authorized by CadDocumentCenter; "
                       + "the proposal service does not consume grants itself.")
        case "assembly", "drawing":
            // Explicit not-yet-wired answer: the persisted model exists, the
            // service surface does not. Never report success.
            return try jsonString([
                "ok": false,
                "error": "not_implemented",
                "message": "\\(kind) operations are not wired to a service in this build; "
                         + "the model type is persisted and round-trips, but no edit/export is offered yet.",
            ])
        default:
            throw CADDocumentError(code: "unknown_kind",
                                   message: "Unknown native CAD request kind '\(kind)'.")
        }
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

    func discard(proposalID: UUID) {
        service.discardProposal(proposalID)
        pending.removeAll { $0.id == proposalID }
        proposalDocument[proposalID] = nil
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
