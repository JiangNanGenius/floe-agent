// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Truthful, per-capability description of the Notes assistant surface. It is
/// compiled data, not a claim: every `implemented` entry names the exact tool
/// and action that exists in this build, `delegated` entries name the workspace
/// tool that must be staged to first, and `unavailable` entries have no tool at
/// all and say why.
public enum NoteCapabilityMatrix {
    public enum Tier: String, Codable, Sendable, CaseIterable {
        /// Implemented in this build and covered by focused tests.
        case implemented
        /// Implemented by the workspace tools after the resource is staged.
        case delegated
        /// No faithful implementation exists; never faked.
        case unavailable
    }

    public enum Grant: String, Codable, Sendable {
        /// The document must be explicitly selected/granted for the conversation.
        case notesRead = "notes-read"
        /// The document's own assistant session (created by opening the editor
        /// assistant) and an editing grant.
        case assistantEditOwnership = "assistant-edit-ownership"
        /// Single-use, expiring grant minted by the editor's accept control.
        case uiAcceptGrant = "ui-accept-grant"
        /// A workspace-relative path inside the task's confined root.
        case workspacePath = "workspace-path"
        /// A human tap in the editor UI; no tool call.
        case editorUI = "editor-ui"
        case none
    }

    public struct Capability: Codable, Sendable, Equatable {
        public var id: String
        public var tier: Tier
        public var path: String
        public var tool: String?
        public var actions: [String]?
        public var grant: Grant
        public var uiConfirmationRequired: Bool
        public var detail: String
    }

    public struct Snapshot: Codable, Sendable, Equatable {
        public var kind = "notes"
        public var tiers: [String: String]
        public var readSections: [String]
        public var editActions: [String]
        public var capabilities: [Capability]
        public var qualification: String
    }

    /// `notes.read section=` values this build accepts.
    public static let readSections = ["pages", "nodes", "connections", "summaries", "officeText", "officeFields", "capabilities"]
    /// `notes.edit operations[].action` values this build accepts.
    public static let editActions = [
        "rename", "addPage", "addText", "updateText", "moveText", "deleteText",
        "addNode", "updateNode", "moveNode", "deleteBranch", "replaceMap",
        "linkMap", "unlinkMap", "updateOfficeText"
    ]
    /// Top-level `notes.edit action=` values.
    public static let editToolActions = ["apply", "propose", "preview", "applyProposal"]

    public static func snapshot() -> Snapshot {
        Snapshot(
            tiers: [
                Tier.implemented.rawValue: "implemented in this build and covered by focused unit tests",
                Tier.delegated.rawValue: "available through workspace document tools on a staged copy; the Notes original is never modified",
                Tier.unavailable.rawValue: "no faithful implementation exists; this is never faked"
            ],
            readSections: readSections,
            editActions: editActions,
            capabilities: capabilities,
            qualification: "agent-tool unit tests run in the FloeNotes package and the NativeNotes qualification host; UI ink/lasso/shape and pending-proposal accept controls are editor surfaces, not agent tools. Physical-device acceptance remains separate.")
    }

    public static let capabilities: [Capability] = [
        Capability(id: "search", tier: .implemented, path: "native", tool: "notes.search", actions: nil,
                   grant: .notesRead, uiConfirmationRequired: false,
                   detail: "Searches only the conversation's granted documents. Each hit carries documentID, pageID/nodeID, elementID and UTF-16 matchOffset/matchLength with the match source, computed by the same pure helper the library tap uses."),
        Capability(id: "read", tier: .implemented, path: "native", tool: "notes.read",
                   actions: readSections, grant: .notesRead, uiConfirmationRequired: false,
                   detail: "Bounded reads for notebook pages/elements/text, map nodes/connections/summaries, Office extracted text and Office editable fields, plus section=capabilities for this matrix."),
        Capability(id: "edit", tier: .implemented, path: "native", tool: "notes.edit", actions: editActions,
                   grant: .assistantEditOwnership, uiConfirmationRequired: false,
                   detail: "One undoable, revision-checked batch with a per-call idempotency receipt. The editing grant is minted by opening the document's own assistant from the editor; a picker-only read grant cannot edit. updateOfficeText rewrites only named fields on a temporary copy, verifies the reopened package and commits a new CAS resource."),
        Capability(id: "propose", tier: .implemented, path: "native", tool: "notes.edit", actions: ["propose"],
                   grant: .notesRead, uiConfirmationRequired: false,
                   detail: "Applies NoteEdit values to an in-memory decoded copy to validate them, computes a human-readable diff summary and binds proposalID + documentID + baseRevision + document JSON SHA-256 (referenced resource bytes are CAS-pinned separately by their content-addressed IDs, not by this hash). Requires expectedRevision equals the current revision. Origin (conversation + environment) is persisted and preview/apply are limited to that exact task. updateOfficeText is rejected here (it needs the byte rewrite) and must use direct apply."),
        Capability(id: "preview", tier: .implemented, path: "native", tool: "notes.edit", actions: ["preview"],
                   grant: .notesRead, uiConfirmationRequired: false,
                   detail: "Returns the stored pending proposal (summary, baseRevision, baseSHA256, edited fields) without applying anything."),
        Capability(id: "applyProposal", tier: .implemented, path: "native", tool: "notes.edit", actions: ["applyProposal"],
                   grant: .uiAcceptGrant, uiConfirmationRequired: true,
                   detail: "Applies a stored proposal only with a single-use, expiring grant minted by the editor's accept tap. A durable write-ahead decision intent (storing the exact commit operation id) is persisted BEFORE the document commit; agent calls must match the proposal's origin (conversation + environment), and a proposal already rejected/invalidated is refused before the grant is touched (a genuine committed receipt replay still returns its receipt). Revision + document JSON fingerprint are re-verified. Recovery on editor open or the next Notes tool call finishes a crashed acceptance from the receipt under that exact operation id, revalidates the originating conversation's editing grant before any recovered mutation, converts a stale/revoked acceptance into a durable invalidation, and delivers accepted/rejected/invalidated events exactly once to the originating conversation (stable event ids, runtime-input enqueue + transcript append, never marked delivered on a partial write). A UI-authored proposal with no origin notifies nobody; resolved proposal files are pruned only after delivery."),
        Capability(id: "exportPDF", tier: .implemented, path: "native", tool: "notes.export", actions: ["format=pdf"],
                   grant: .notesRead, uiConfirmationRequired: false,
                   detail: "Exports the selected page subset (default: whole document) into the task workspace through atomic staging and a reopen-verified page count. The library page list exports one page through the same NotesExport.pdf path."),
        Capability(id: "exportArchive", tier: .implemented, path: "native", tool: "notes.export", actions: ["format=floenote"],
                   grant: .notesRead, uiConfirmationRequired: false,
                   detail: "Exports any granted document kind (notebook, mind map, Office, engineering) as a portable .floenote archive (document + linked maps + resources) via NotesArchive.export; small archives are re-imported into a scratch store to verify manifest and resource digests before the staged file is committed."),
        Capability(id: "attachFile", tier: .implemented, path: "native", tool: "notes.attachFile", actions: nil,
                   grant: .assistantEditOwnership, uiConfirmationRequired: false,
                   detail: "Copies an authorized workspace file into a mind-map topic as a durable attachment; never modifies the workspace input."),
        Capability(id: "stageAttachment", tier: .implemented, path: "native", tool: "notes.stageAttachment", actions: nil,
                   grant: .notesRead, uiConfirmationRequired: false,
                   detail: "Copies one resource of a granted document into the confined task workspace so exec/PDF tools can process real bytes; the document is never modified."),
        Capability(id: "inkPenLassoShapes", tier: .implemented, path: "editor-ui", tool: nil, actions: nil,
                   grant: .editorUI, uiConfirmationRequired: false,
                   detail: "PencilKit pen/marker/eraser/lasso/region selection and rectangle/ellipse/line/arrow shapes, saved as undoable NoteEdit.drawing/upsertElement batches. Ink is a PencilKit resource, never a PDF annotation."),
        Capability(id: "pageOrganization", tier: .implemented, path: "editor-ui", tool: nil, actions: ["addPage", "movePage", "duplicatePage", "deletePage"],
                   grant: .editorUI, uiConfirmationRequired: false,
                   detail: "Page list reorder, duplicate and delete plus reader page export. The assistant can add/rename pages through notes.edit but has no reorder/duplicate operation."),
        Capability(id: "ocrSearchIndex", tier: .implemented, path: "native-index", tool: nil, actions: nil,
                   grant: .editorUI, uiConfirmationRequired: false,
                   detail: "Vision OCR is cached per page revision for search and never claims to make handwriting or scanned text editable."),
        Capability(id: "pdfInspect", tier: .delegated, path: "workspace-tools", tool: "document.pdf.inspect", actions: nil,
                   grant: .workspacePath, uiConfirmationRequired: false,
                   detail: "Stage the PDF resource with notes.stageAttachment first; inspect works on the workspace copy with SHA-256 binding."),
        Capability(id: "pdfRender", tier: .delegated, path: "workspace-tools", tool: "document.pdf.render", actions: nil,
                   grant: .workspacePath, uiConfirmationRequired: false,
                   detail: "Renders staged PDF pages to images inside the task workspace."),
        Capability(id: "pdfEdit", tier: .delegated, path: "workspace-tools", tool: "document.pdf.edit", actions: nil,
                   grant: .workspacePath, uiConfirmationRequired: false,
                   detail: "Native PDF annotations, form fields, page operations and text-layer replacement on the staged copy; real PDF annotations are produced by this delegated tool, not by Notes ink."),
        Capability(id: "pdfExportText", tier: .delegated, path: "workspace-tools", tool: "document.pdf.export", actions: nil,
                   grant: .workspacePath, uiConfirmationRequired: false,
                   detail: "Exports real PDF text to UTF-8 text/JSON; never invents text for scanned pages."),
        Capability(id: "pdfFillForm", tier: .delegated, path: "workspace-tools", tool: "document.pdf.fillForm", actions: nil,
                   grant: .workspacePath, uiConfirmationRequired: false,
                   detail: "Fills AcroForm fields on the staged copy with reopen verification."),
        Capability(id: "pdfOriginalTextEdit", tier: .unavailable, path: "none", tool: nil, actions: nil,
                   grant: .none, uiConfirmationRequired: false,
                   detail: "There is no faithful in-place PDF original-text edit in Notes: the PDF resource is immutable and unedited, ink is drawn above it and flattened on export, and the delegated document.pdf.edit path edits a copy. Use PDF text replacement through document.pdf.edit on a staged copy when that is what the user asked for."),
        Capability(id: "handwritingTextEdit", tier: .unavailable, path: "none", tool: nil, actions: nil,
                   grant: .none, uiConfirmationRequired: false,
                   detail: "Recognized handwriting/OCR text is a search cache only; there is no tool that edits recognized text or the underlying strokes as text.")
    ]
}
