// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes assistant — trusted proposal review/commit policy.
//
// The MODEL never reaches this file: it has no `proposal.issueGrant` tool and no
// raw apply. The trusted Notes domain calls it after `notes.edit` created a
// durable proposal, and only then may it mint the single-use grant and commit
// the native edits.
//
// Everything here is a CLOSED deterministic rule over already-verified native
// facts. Prose (proposal summary, document text, tool output) never decides
// eligibility.
import Foundation
import FloeNotes

/// The resolved edit family of one proposal, as supplied by the trusted tool
/// call that created it. Only action names cross this boundary — never edits,
/// never model text.
struct NotesProposalEditFamily: Sendable, Equatable {
    let actions: [String]
    let count: Int

    /// Closed non-destructive, locally undoable C5 edit vocabulary. Anything
    /// that deletes content, replaces bytes, re-parents a page, re-links
    /// another document or moves the note across notebooks needs the editor's
    /// explicit accept control.
    static let routineActions: Set<String> = [
        "rename", "favorite", "tags", "textSource", "updatePage",
        "upsertElement", "insertPage", "mindMapLayout", "upsertNode",
        "upsertConnection",
    ]

    /// True only when every action is in the routine family. A mixed batch is
    /// decided by its least routine member.
    var isRoutine: Bool {
        !actions.isEmpty && actions.allSatisfy { Self.routineActions.contains($0) }
    }
}

/// One decision of the trusted review step.
enum NotesReviewOutcome: Sendable, Equatable {
    /// The proposal was committed exactly once (or replayed under the same
    /// deterministic receipt).
    case applied(revision: Int?, replayed: Bool)
    /// The proposal remains pending for the real editor accept/reject path.
    /// `reason` is a stable code, never prose.
    case pending(reason: String)
    /// The baseline changed: no write occurred and the native invalidation
    /// path owns the durable decision.
    case conflict(reason: String)
}

/// The exact facts re-read immediately before a commit. The actor fills this
/// from the live native store + run domain; the pure checks below never fetch.
struct NotesProposalReviewFacts: Sendable, Equatable {
    var proposalID: UUID
    var documentID: UUID
    var proposalStatus: String
    var proposalSourceRequestID: String?
    var proposalBaseRevision: Int
    var proposalBaseSHA256: String
    var proposalEditCount: Int
    /// Exact `assistant_threads` owner of the document.
    var threadConversationID: UUID?
    var liveCanEdit: Bool
    /// Live Notes run owner: exact conversation + non-retired phase.
    var runConversationID: UUID?
    var runIsLive: Bool
}

enum NotesProposalReviewPolicy {
    /// Pure eligibility check. Returns nil when the proposal may be committed,
    /// or the stable pending/conflict reason otherwise.
    static func refusal(_ facts: NotesProposalReviewFacts,
                        conversationID: UUID,
                        documentID: UUID,
                        runID: UUID,
                        toolCallID: String?,
                        family: NotesProposalEditFamily,
                        currentRevision: Int,
                        currentFingerprint: String) -> NotesReviewOutcome? {
        guard facts.documentID == documentID else {
            return .pending(reason: "proposalDocumentMismatch")
        }
        guard facts.proposalStatus == "pending" else {
            // Applied (replay is handled by the native apply receipt) or
            // resolved: nothing to commit here.
            return .pending(reason: "proposalNotPending")
        }
        // Exact origin: the proposal was authored for THIS conversation.
        guard facts.threadConversationID == conversationID else {
            return .pending(reason: "threadOwnerMismatch")
        }
        guard facts.liveCanEdit else {
            return .pending(reason: "editingNotAuthorized")
        }
        // Live Notes run ownership for the exact run that received the tool
        // call. A completed/retired run cannot mint authority later.
        guard facts.runIsLive, facts.runConversationID == conversationID else {
            return .pending(reason: "runNotLive")
        }
        // Provenance: the proposing tool call must be THIS call. A proposal
        // created by another turn/call is not silently adopted.
        guard let toolCallID, !toolCallID.isEmpty,
              facts.proposalSourceRequestID == toolCallID else {
            return .pending(reason: "sourceRequestMismatch")
        }
        guard family.count == facts.proposalEditCount else {
            return .pending(reason: "editCountMismatch")
        }
        guard family.isRoutine else {
            return .pending(reason: "reviewPolicyRequiresUser")
        }
        // Baseline still exact: revision AND canonical fingerprint. A mismatch
        // is a conflict, never a write.
        guard facts.proposalBaseRevision == currentRevision,
              facts.proposalBaseSHA256 == currentFingerprint else {
            return .conflict(reason: "revisionOrSourceChanged")
        }
        return nil
    }
}
