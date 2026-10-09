//
//  CADProposalService.swift
//  FloeCADKit
//
//  Explicit-effect proposals for the native CAD document, matching the app-wide
//  creative-tool contract: the model may describe, measure and draft, but only
//  an interactive grant can authorise a mutation.
//
//    propose(operation:)  evaluates the typed operation on a throwaway COPY of
//                         the package and returns a diff preview; nothing in
//                         the live document changes.
//    issueGrant(...)      callable only by the interactive UI. The model never
//                         sees or mints a grant.
//    apply(proposal:)     re-checks revision + content SHA, consumes the
//                         single-use grant, executes the operation, saves with
//                         compare-and-swap and returns the receipt.
//
//  Proposals bind the exact base revision/SHA they were drafted against; a
//  document that moved on invalidates them (the model must re-draft), and a
//  failed apply leaves the live document untouched.
//

import Foundation
import simd

public nonisolated struct CADProposalPreview: Codable, Sendable, Equatable {
    public var bodyCountBefore: Int
    public var bodyCountAfter: Int
    public var addedBodyNames: [String]
    public var removedBodyNames: [String]
    public var volumeBeforeMM3: Double
    public var volumeAfterMM3: Double
    public var evalErrors: [String]
    public var failed: Bool

    public var volumeDeltaMM3: Double { volumeAfterMM3 - volumeBeforeMM3 }
}

public nonisolated struct CADProposalRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var documentPath: String
    public var baseRevision: Int
    public var baseContentSHA256: String
    public var summary: String
    public var operationJSON: String
    public var createdAt: Date
    public var preview: CADProposalPreview

    public init(id: UUID = UUID(),
                documentPath: String,
                baseRevision: Int,
                baseContentSHA256: String,
                summary: String,
                operationJSON: String,
                createdAt: Date = Date(),
                preview: CADProposalPreview) {
        self.id = id
        self.documentPath = documentPath
        self.baseRevision = baseRevision
        self.baseContentSHA256 = baseContentSHA256
        self.summary = summary
        self.operationJSON = operationJSON
        self.createdAt = createdAt
        self.preview = preview
    }
}

public nonisolated struct CADApplyReceipt: Sendable, Equatable {
    public var proposalID: UUID
    public var revision: Int
    public var contentSHA256: String
    public var message: String
}

public nonisolated struct CADProposalError: Error, LocalizedError {
    public var code: String
    public var message: String
    public var errorDescription: String? { message }
}

/// One proposal awaiting or receiving a UI grant. Grants are single-use,
/// bound to proposal id + base revision + base SHA, and expire.
struct CADProposalGrant: Equatable {
    let proposalID: UUID
    let documentPath: String
    let baseRevision: Int
    let baseContentSHA256: String
    let expiresAt: Date
}

@MainActor
public final class CADProposalService {
    public static let grantTTL: TimeInterval = 10 * 60

    private var proposals: [UUID: CADProposalRecord] = [:]
    private var grants: [UUID: CADProposalGrant] = [:]
    private var applied: [UUID: CADApplyReceipt] = [:]
    private var appliedGrant: [UUID: UUID] = [:]
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: Propose

    /// Evaluate `operationJSON` (the shared `{op, args}` vocabulary) against a
    /// throwaway copy of `document` and return the diff preview. The live
    /// document, its revision and its package are untouched.
    ///
    /// The live in-memory revision is FLUSHED first, so the preview snapshot
    /// includes edits that had not reached disk yet; if the flush fails the
    /// proposal is refused rather than drafted against stale bytes. The
    /// proposal then binds the flushed revision/SHA, which is what the app's
    /// grant store validates at apply time.
    public func propose(document: FloeCADDocument,
                        operationJSON: String,
                        summary: String) async throws -> CADProposalRecord {
        if let flushed = await document.flushIfDirty(), !flushed.succeeded {
            throw CADProposalError(code: "dirty_document",
                                   message: "The document has unsaved changes that could not be flushed: "
                                          + (flushed.error ?? "unknown error"))
        }
        let operation = try Self.decodeOperation(operationJSON)
        let before = Self.documentStats(document)

        let cloneURL = fileManager.temporaryDirectory
            .appendingPathComponent("floecad-propose-\(UUID().uuidString).\(FileCADDocumentStore.packageExtension)")
        defer { try? fileManager.removeItem(at: cloneURL) }
        do {
            try fileManager.copyItem(at: document.url, to: cloneURL)
        } catch {
            throw CADProposalError(code: "clone_failed",
                                   message: "The proposal preview copy could not be made: \(error.localizedDescription)")
        }

        let clone: FloeCADDocument
        do {
            clone = try Self.openSynchronously(at: cloneURL,
                                               storeFactory: { FileCADDocumentStore(packageURL: $0) })
        } catch {
            throw CADProposalError(code: "clone_open_failed",
                                   message: "The proposal preview copy could not be opened: \(error.localizedDescription)")
        }

        let outcome = clone.execute(operation)
        var errors: [String] = []
        if let message = outcome.message { errors.append(message) }
        if let snapshotError = Self.evalErrors(clone) { errors.append(contentsOf: snapshotError) }
        let after = Self.documentStats(clone)
        clone.close()

        let preview = CADProposalPreview(
            bodyCountBefore: before.bodyCount,
            bodyCountAfter: after.bodyCount,
            addedBodyNames: Array(after.names.subtracting(before.names)).sorted(),
            removedBodyNames: Array(before.names.subtracting(after.names)).sorted(),
            volumeBeforeMM3: before.volume,
            volumeAfterMM3: after.volume,
            evalErrors: errors,
            failed: !outcome.isOK)
        let record = CADProposalRecord(
            documentPath: document.url.path,
            baseRevision: document.revision,
            baseContentSHA256: document.contentSHA256,
            summary: summary,
            operationJSON: operationJSON,
            preview: preview)
        proposals[record.id] = record
        return record
    }

    // MARK: Grant (package-internal test path)

    /// Called by the interactive UI only. The tool layer never calls this; a
    /// `grant_id` arriving from a model is not authority.
    ///
    /// NOTE: the Floe app does NOT use this path. App grants live in the
    /// existing `CadProposalGrantStore` owned by `CadDocumentCenter`; this
    /// in-package store exists so the geometry/transaction primitives can be
    /// exercised in isolation.
    @discardableResult
    func issueGrant(proposalID: UUID) throws -> String {
        guard let proposal = proposals[proposalID] else {
            throw CADProposalError(code: "unknown_proposal", message: "No such proposal.")
        }
        let grant = CADProposalGrant(proposalID: proposal.id,
                                     documentPath: proposal.documentPath,
                                     baseRevision: proposal.baseRevision,
                                     baseContentSHA256: proposal.baseContentSHA256,
                                     expiresAt: Date().addingTimeInterval(Self.grantTTL))
        let id = UUID()
        grants[id] = grant
        return id.uuidString
    }

    public func discardProposal(_ id: UUID) {
        proposals[id] = nil
        grants = grants.filter { $0.value.proposalID != id }
    }

    // MARK: Apply

    /// Execute an ALREADY-AUTHORIZED proposal against the live document. The
    /// caller (the app host) owns the permission decision: it has consumed a
    /// single-use grant from the existing CadProposalGrantStore and re-checked
    /// the base revision/SHA. Any failure leaves the live document as it was.
    public func applyAuthorized(document: FloeCADDocument,
                                proposalID: UUID) async throws -> CADApplyReceipt {
        guard let proposal = proposals[proposalID] else {
            throw CADProposalError(code: "unknown_proposal", message: "No such proposal.")
        }
        guard document.revision == proposal.baseRevision,
              document.contentSHA256 == proposal.baseContentSHA256 else {
            throw CADProposalError(code: "stale_proposal",
                                   message: "The document changed after this proposal was drafted; "
                                          + "re-read it and draft the change again.")
        }
        let operation = try Self.decodeOperation(proposal.operationJSON)
        let outcome = document.execute(operation)
        guard outcome.isOK else {
            throw CADProposalError(code: outcome.errorCode ?? "apply_failed",
                                   message: outcome.message ?? "The CAD operation failed; nothing was kept.")
        }
        let save = await document.save()
        guard save.succeeded else {
            throw CADProposalError(code: "save_failed",
                                   message: save.error ?? "The applied change could not be committed.")
        }
        let receipt = CADApplyReceipt(proposalID: proposalID,
                                      revision: save.revision,
                                      contentSHA256: save.contentSHA256,
                                      message: "Applied and committed \u{201C}\(proposal.summary)\u{201D}.")
        applied[proposalID] = receipt
        appliedGrant[proposalID] = nil
        proposals[proposalID] = proposal
        return receipt
    }

    /// Package-internal test path: consumes this service's own grant. The app
    /// wires auth through CadDocumentCenter instead.
    func apply(document: FloeCADDocument,
               proposalID: UUID,
               grantID: String) async throws -> CADApplyReceipt {
        if let existing = applied[proposalID] {
            // Idempotent replay: ONLY the same consumed grant replays the
            // original receipt. Any other grant value is a new confirmation
            // attempt on an already-applied proposal and is refused.
            if let used = appliedGrant[proposalID],
               UUID(uuidString: grantID) == used {
                return existing
            }
            throw CADProposalError(code: "already_applied",
                                   message: "This proposal was already applied; re-read the document before drafting another change.")
        }
        guard let proposal = proposals[proposalID] else {
            throw CADProposalError(code: "unknown_proposal", message: "No such proposal.")
        }
        guard let grantUUID = UUID(uuidString: grantID), let grant = grants[grantUUID],
              grant.proposalID == proposalID else {
            throw CADProposalError(code: "grant_required",
                                   message: "Applying a CAD proposal needs a single-use grant issued in the CAD UI.")
        }
        guard grant.expiresAt > Date() else {
            grants[grantUUID] = nil
            throw CADProposalError(code: "grant_expired",
                                   message: "The confirmation grant expired; review and confirm again.")
        }
        guard grant.documentPath == proposal.documentPath,
              document.url.path == proposal.documentPath else {
            throw CADProposalError(code: "wrong_document",
                                   message: "The proposal was drafted against a different document.")
        }
        guard document.revision == proposal.baseRevision,
              document.contentSHA256 == proposal.baseContentSHA256 else {
            grants[grantUUID] = nil
            throw CADProposalError(code: "stale_proposal",
                                   message: "The document changed after this proposal was drafted; "
                                          + "re-read it and draft the change again.")
        }

        // Single use: invalidate before the mutation so a crash cannot leave a
        // reusable grant behind.
        grants[grantUUID] = nil
        let operation = try Self.decodeOperation(proposal.operationJSON)
        let outcome = document.execute(operation)
        guard outcome.isOK else {
            proposals[proposalID] = proposal
            throw CADProposalError(code: outcome.errorCode ?? "apply_failed",
                                   message: outcome.message ?? "The CAD operation failed; nothing was kept.")
        }
        let save = await document.save()
        guard save.succeeded else {
            throw CADProposalError(code: "save_failed",
                                   message: save.error ?? "The applied change could not be committed.")
        }
        let receipt = CADApplyReceipt(proposalID: proposalID,
                                      revision: save.revision,
                                      contentSHA256: save.contentSHA256,
                                      message: "Applied and committed \u{201C}\(proposal.summary)\u{201D}.")
        applied[proposalID] = receipt
        appliedGrant[proposalID] = grantUUID
        proposals[proposalID] = proposal
        return receipt
    }

    public func receipt(for proposalID: UUID) -> CADApplyReceipt? {
        applied[proposalID]
    }

    // MARK: Helpers

    static func decodeOperation(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["op"] is String else {
            throw CADProposalError(code: "bad_operation",
                                   message: #"The operation must be a JSON object like {"op":"feature.extrude","args":{…}}."#)
        }
        return object
    }

    /// Synchronous open used by the proposal clone. `FloeCADDocument.open` is
    /// async by design; the clone is small and already local, so a private
    /// synchronous path avoids an actor hop that would only add latency.
    static func openSynchronously(at url: URL,
                                  storeFactory: (URL) -> FileCADDocumentStore) throws -> FloeCADDocument {
        let store = storeFactory(url)
        let project = try store.read()
        let context = CADModelContext(project: project, store: store)
        let session = DocumentSession(project: project, modelContext: context)
        return FloeCADDocument.make(url: url, project: project, store: store, session: session)
    }

    private static func documentStats(_ document: FloeCADDocument) -> (bodyCount: Int, names: Set<String>, volume: Double) {
        let bodies = document.session.document.bodies
        return (bodies.count,
                Set(bodies.map(\.name)),
                bodies.reduce(0) { $0 + MeasureKit.volume(of: $1) })
    }

    private static func evalErrors(_ document: FloeCADDocument) -> [String]? {
        let errors = document.session.lastEvalErrors
        guard !errors.isEmpty else { return nil }
        return errors.map { id, error in
            let name = document.session.document.features.node(id)?.name ?? id.raw.uuidString
            return "\(name): \(error)"
        }
    }
}
