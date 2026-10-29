// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes-purpose assistant runtime — the ONE native authority accessor.
//
// Every document read, proposal create and decision ack is performed through
// the EXISTING `floe.notes/4` C5 action surface on `NotesDomainService.shared`
// (the one process-wide Notes engine/store). This file contains no store, no
// proposal file format, no OCR cache and no second permission model: it is a
// typed projection over the actions the authority lane already owns.
import Foundation
import FloeCore
import FloeNotes

/// Raw-JSON projection of the typed Notes wire union, used ONLY to build
/// `floe.notes/4` payload objects inside this module.
extension NotesJSONValue {
    var notesRawJSON: Any {
        switch self {
        case .object(let value): return value.mapValues(\.notesRawJSON)
        case .array(let value): return value.map(\.notesRawJSON)
        case .string(let value): return value
        case .integer(let value): return value
        case .fractional(let value): return value
        case .boolean(let value): return value
        case .null: return NSNull()
        }
    }
}

/// One granted document as the assistant sees it (identifier + revision +
/// title only; no content).
struct NotesRosterEntry: Sendable, Equatable {
    let documentID: UUID
    let title: String
    let kind: String
    let revision: Int
}

/// Bounded `floe.notes/4` accessor bound to ONE accepted epoch.
struct NotesAuthority: Sendable {
    let epoch: UInt64

    /// Raw C5 action reply bytes. Typed native refusals keep their own
    /// code/reason (never flattened into a generic failure).
    func callData(_ action: String, _ payload: [String: Any]) async throws -> Data {
        let requestData: Data
        do {
            requestData = try JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys])
        } catch {
            throw NotesAssistantRefusal(.invalidPayload, "payloadEncode")
        }
        guard requestData.count <= NotesWire.maximumRequestBytes else {
            throw NotesAssistantRefusal(.invalidPayload, "payloadTooLarge")
        }
        let value = (try? JSONDecoder().decode(NotesJSONValue.self, from: requestData))
            ?? .object([:])
        let response: Data
        do {
            response = try await NotesDomainService.shared.handle(
                epoch: epoch,
                requestID: "notes-assistant-" + UUID().uuidString,
                action: action,
                payload: value)
        } catch {
            let mapped = NotesWire.mappedError(error)
            throw NotesAssistantRefusal(.authority,
                                        "\(mapped.code):\(mapped.reason ?? "-")",
                                        retryable: mapped.retryable)
        }
        guard response.count <= NotesWire.maximumResponseBytes else {
            throw NotesAssistantRefusal(.authority, "responseTooLarge")
        }
        return response
    }

    /// Decoded reply object with `ok` enforced.
    func call(_ action: String, _ payload: [String: Any]) async throws -> [String: Any] {
        let response = try await callData(action, payload)
        guard let object = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any]
        else {
            throw NotesAssistantRefusal(.authority, "invalidBinderOutput")
        }
        if (object["ok"] as? Bool) == true { return object }
        let code = object["error"] as? String ?? "unknown"
        let reason = object["reason"] as? String
        throw NotesAssistantRefusal(.authority,
                                    reason.map { "\(code):\($0)" } ?? code,
                                    retryable: (object["retryable"] as? Bool) ?? false)
    }

    // MARK: Documents

    private struct DocumentReply: Decodable { let document: NoteDocument }

    /// Live granted document roster for one conversation (the native
    /// `assistant_scopes` rows joined to live documents).
    func roster(conversationID: UUID) async throws -> [NotesRosterEntry] {
        let reply = try await call("assistant.scopedDocuments",
                                   ["conversationID": conversationID.uuidString])
        guard let rows = reply["documents"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let rawID = row["id"] as? String, let documentID = UUID(uuidString: rawID)
            else { return nil }
            return NotesRosterEntry(
                documentID: documentID,
                title: row["title"] as? String ?? "",
                kind: row["kind"] as? String ?? "",
                revision: (row["revision"] as? NSNumber)?.intValue ?? 0)
        }
        .sorted { $0.documentID.uuidString < $1.documentID.uuidString }
    }

    /// Live `assistant_scopes` grants: document id → canEdit. This is the
    /// native authority every Notes tool re-reads; nothing in a tool argument
    /// can add an entry.
    func grants(conversationID: UUID) async throws -> [UUID: Bool] {
        let reply = try await call("assistant.grants",
                                   ["conversationID": conversationID.uuidString])
        guard let rows = reply["grants"] as? [String: Any] else { return [:] }
        var result: [UUID: Bool] = [:]
        for (key, value) in rows {
            guard let documentID = UUID(uuidString: key),
                  let canEdit = value as? Bool else { continue }
            result[documentID] = canEdit
        }
        return result
    }

    /// App-generated navigation context for this conversation. Data + workflow
    /// guidance only; it never grants a document.
    func runtimeContext(conversationID: UUID) async throws -> String? {
        let reply = try await call("assistant.runtimeContext",
                                   ["conversationID": conversationID.uuidString])
        guard let context = reply["context"] as? String else { return nil }
        return context.isEmpty ? nil : context
    }

    /// Full validated document, ONLY after the conversation's live grant for
    /// that exact note was re-read. A revoked grant therefore refuses here,
    /// before any bytes are returned to the model.
    func document(documentID: UUID, conversationID: UUID) async throws -> NoteDocument {
        let granted = try await roster(conversationID: conversationID)
        guard granted.contains(where: { $0.documentID == documentID }) else {
            throw NotesAssistantRefusal(.notAuthorized, "documentNotGranted")
        }
        let data = try await callData("document.get",
                                      ["documentID": documentID.uuidString])
        do {
            return try NotesWire.decode(DocumentReply.self, from: data).document
        } catch {
            throw NotesAssistantRefusal(.authority, "documentDecode")
        }
    }

    /// The document's canonical searchable text (the same projection the
    /// library index uses) plus its per-page text for page-targeted reads.
    struct DocumentText: Sendable {
        let document: NoteDocument
        let fullText: String
        let pageTexts: [UUID: String]
    }

    func documentText(documentID: UUID, conversationID: UUID) async throws -> DocumentText {
        let document = try await document(documentID: documentID,
                                          conversationID: conversationID)
        var pageTexts: [UUID: String] = [:]
        for page in document.pages {
            pageTexts[page.id] = Self.pageText(page)
        }
        return DocumentText(document: document,
                            fullText: document.searchableText,
                            pageTexts: pageTexts)
    }

    static func pageText(_ page: NotePage) -> String {
        var parts: [String] = []
        if let extracted = page.extractedText, !extracted.isEmpty {
            parts.append(extracted)
        }
        for element in page.elements where element.kind == .text && !element.text.isEmpty {
            parts.append(element.text)
        }
        if let ocr = page.indexedVisualText, !ocr.isEmpty {
            parts.append(ocr)
        }
        return parts.joined(separator: "\n")
    }

    // MARK: Proposals

    /// Creates one durable structured proposal from an already-flattened edit
    /// batch. The native service validates every edit, recomputes the human
    /// summary/fingerprint and stores the exact origin — model-authored prose
    /// is never treated as an edit. `sourceRequestID` binds the proposal to the
    /// EXACT tool call that created it (provenance only; never the apply
    /// receipt).
    func createProposal(documentID: UUID,
                        expectedRevision: Int,
                        title: String?,
                        edits: [Any],
                        conversationID: UUID,
                        environmentID: String?,
                        sourceRequestID: String?) async throws -> [String: Any] {
        var payload: [String: Any] = [
            "documentID": documentID.uuidString,
            "expectedRevision": expectedRevision,
            "edits": edits,
            "conversationID": conversationID.uuidString,
        ]
        if let title, !title.isEmpty { payload["title"] = title }
        if let environmentID, !environmentID.isEmpty {
            payload["environmentID"] = environmentID
        }
        if let sourceRequestID, !sourceRequestID.isEmpty {
            payload["sourceRequestID"] = sourceRequestID
        }
        let reply = try await call("proposal.create", payload)
        guard let proposal = reply["proposal"] as? [String: Any] else {
            throw NotesAssistantRefusal(.authority, "proposalMissing")
        }
        return proposal
    }

    /// One stored proposal projection, origin-scoped to this conversation and
    /// environment. A foreign task sees `notFound`.
    func proposal(proposalID: UUID, documentID: UUID,
                  conversationID: UUID,
                  environmentID: String?) async throws -> [String: Any] {
        var payload: [String: Any] = [
            "proposalID": proposalID.uuidString,
            "documentID": documentID.uuidString,
            "conversationID": conversationID.uuidString,
        ]
        if let environmentID, !environmentID.isEmpty {
            payload["environmentID"] = environmentID
        }
        let reply = try await call("proposal.get", payload)
        guard let proposal = reply["proposal"] as? [String: Any] else {
            throw NotesAssistantRefusal(.authority, "proposalMissing")
        }
        return proposal
    }

    /// Interactive-editor grant. Called ONLY by the trusted task domain for a
    /// policy-authorized routine apply; it is never exposed as a tool action
    /// and never accepts a model-supplied id.
    func issueGrant(proposalID: UUID, documentID: UUID) async throws -> [String: Any] {
        let reply = try await call("proposal.issueGrant", [
            "proposalID": proposalID.uuidString,
            "documentID": documentID.uuidString,
        ])
        guard let grant = reply["grant"] as? [String: Any] else {
            throw NotesAssistantRefusal(.authority, "grantMissing")
        }
        return grant
    }

    func applyProposal(proposalID: UUID, documentID: UUID, grantID: String,
                       conversationID: UUID,
                       environmentID: String?) async throws -> [String: Any] {
        var payload: [String: Any] = [
            "proposalID": proposalID.uuidString,
            "documentID": documentID.uuidString,
            "grantID": grantID,
            "conversationID": conversationID.uuidString,
        ]
        if let environmentID, !environmentID.isEmpty {
            payload["environmentID"] = environmentID
        }
        return try await call("proposal.apply", payload)
    }

    // MARK: Decisions

    func outbox(conversationID: UUID, limit: Int) async throws -> [[String: Any]] {
        let reply = try await call("proposal.outbox", [
            "conversationID": conversationID.uuidString,
            "limit": min(200, max(1, limit)),
        ])
        return (reply["decisions"] as? [[String: Any]]) ?? []
    }

    func acknowledge(intentID: UUID, eventID: UUID) async throws -> [String: Any] {
        let reply = try await call("proposal.outboxAck", [
            "intentID": intentID.uuidString,
            "eventID": eventID.uuidString,
        ])
        return (reply["ack"] as? [String: Any]) ?? [:]
    }
}
