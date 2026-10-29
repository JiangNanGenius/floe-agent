// SPDX-License-Identifier: MPL-2.0
import Foundation

import FloeCore
/// Atomic on-disk recovery envelope. The baseline is the page actually shown
/// when drawing began, never a fresh read at save or recovery time.
public struct NoteInkDraft: Codable, Sendable {
    public var base: NoteDocument
    public let pageID: UUID
    public let drawing: Data
    /// In-memory lineage of the canvas that produced this draft. Envelopes
    /// written before this field existed decode with nil, and recovery
    /// replays deliberately keep it nil so a restarted session can never
    /// adopt a live-canvas acknowledgement (see NotesSession.recoverInk).
    public var canvasLineage: UUID? = nil
    /// Canvas generation that produced this draft; the editor advances it
    /// only when a verified page load is actually adopted by the canvas, so
    /// a reload/undo retires every generation that came before it.
    public var canvasGeneration: UInt64? = nil
    /// Per-canvas monotonically increasing report sequence, captured by the
    /// coordinator when the report originates (never read from mutable view
    /// state later).
    public var canvasSequence: UInt64? = nil
    public init(base: NoteDocument, pageID: UUID, drawing: Data, canvasLineage: UUID? = nil,
                canvasGeneration: UInt64? = nil, canvasSequence: UInt64? = nil) {
        self.base = base; self.pageID = pageID; self.drawing = drawing
        self.canvasLineage = canvasLineage; self.canvasGeneration = canvasGeneration; self.canvasSequence = canvasSequence
    }
}

public struct NoteEditConflict: Identifiable, Codable, Sendable {
    public let id: UUID
    public let current: NoteDocument
    public let copy: NoteDocument
    public let edits: [NoteEdit]
    public let title: String
    public init(id: UUID = UUID(), current: NoteDocument, copy: NoteDocument, edits: [NoteEdit], title: String) {
        self.id = id; self.current = current; self.copy = copy; self.edits = edits; self.title = title
    }
}

extension NoteEdit {
    /// Reapply only when the objects read by this operation have not changed.
    /// Unrelated pages/elements can progress independently. Broad structural
    /// replacements deliberately require a broader unchanged baseline.
    public func canRebase(from base: NoteDocument, onto current: NoteDocument) -> Bool {
        guard base.id == current.id, base.kind == current.kind, current.deletedAt == nil else { return false }
        func page(_ id: UUID, _ document: NoteDocument) -> NotePage? { document.pages.first { $0.id == id } }
        func sameSurface(_ id: UUID) -> Bool {
            guard let a = page(id, base), let b = page(id, current) else { return false }
            return a.width == b.width && a.height == b.height && a.paper == b.paper
                && a.backgroundResourceID == b.backgroundResourceID && a.pdfPageIndex == b.pdfPageIndex
        }
        switch self {
        case .textSource(let id, _):
            return base.textSources?[id.uuidString] == current.textSources?[id.uuidString]
        case .rename: return base.title == current.title
        case .moveToNotebook: return base.notebookID == current.notebookID
        case .favorite: return base.isFavorite == current.isFavorite
        case .tags: return base.tags == current.tags
        case .drawing(let id, _):
            return sameSurface(id) && page(id, base)?.drawingResourceID == page(id, current)?.drawingResourceID
        case .upsertElement(let id, let element):
            return sameSurface(id) && page(id, base)?.elements.first { $0.id == element.id }
                == page(id, current)?.elements.first { $0.id == element.id }
        case .deleteElements(let id, let ids):
            return sameSurface(id) && ids.allSatisfy { elementID in
                page(id, base)?.elements.first { $0.id == elementID } == page(id, current)?.elements.first { $0.id == elementID }
            }
        case .updatePage(let value): return page(value.id, base) == page(value.id, current)
        case .insertPage, .movePage, .deletePage, .duplicatePage:
            return base.pages == current.pages && base.linkedMindMaps == current.linkedMindMaps
        case .upsertNode(let value):
            return base.nodes.first { $0.id == value.id } == current.nodes.first { $0.id == value.id }
                && (value.parentID == nil || current.nodes.contains { $0.id == value.parentID })
        case .upsertConnection(let edge):
            return base.connections.first { $0.id == edge.id } == current.connections.first { $0.id == edge.id }
                && current.nodes.contains { $0.id == edge.from } && current.nodes.contains { $0.id == edge.to }
        case .deleteConnection(let id):
            return base.connections.first { $0.id == id } == current.connections.first { $0.id == id }
        case .deleteBranch, .replaceMindMap, .mindMapLayout:
            return base.nodes == current.nodes && base.connections == current.connections
                && base.summaries == current.summaries && base.mindMapDirection == current.mindMapDirection
        case .replaceOfficeResource: return base.officeResourceID == current.officeResourceID
        case .linkMindMap, .unlinkMindMap: return base.linkedMindMaps == current.linkedMindMaps && base.pages == current.pages
        }
    }
}

extension NotesStore {
    /// UI-only optimistic rebase with an explicit editor snapshot. Agent tools
    /// continue to require the exact revision returned by notes.read.
    public func applyRebased(_ batch: NoteEditBatch, base: NoteDocument) throws -> NoteDocument {
        guard base.id == batch.documentID, base.revision == batch.expectedRevision else { throw NoteError.conflict }
        // The satisfaction path below must not weaken the store's existing
        // batch contract: an empty or oversized batch rejects exactly as
        // `apply` would, even when every edit is already satisfied.
        guard !batch.edits.isEmpty, batch.edits.count <= 10_000 else {
            throw NoteError.invalidOperation(NoteLocalization.localized("notes.notes_store.the_edit_batch_is_empty_or"))
        }
        let current = try document(base.id)
        if current.revision == base.revision { return try apply(batch) }
        var old = base, latest = current
        var remaining: [NoteEdit] = []
        for edit in batch.edits {
            // A drawing replay whose content-addressed bytes the current page
            // already holds is satisfied, not a conflict. Satisfaction never
            // bypasses the other guards: the document identity and kind must
            // match, the document must not be deleted, the page surface must
            // be unchanged from the batch's own view, the resource must be
            // concrete and already installed, and receipt-bearing batches
            // never take this path, so requestID idempotency is untouched.
            // The edit is still mirrored onto the in-memory old/latest pair
            // so later edits in the same batch keep their sequential rebase
            // semantics, and the document only advances when at least one
            // edit still needs a real write.
            if batch.requestID == nil,
               case .drawing(let pageID, let resourceID) = edit,
               let resourceID,
               current.deletedAt == nil,
               base.kind == current.kind,
               let basePage = old.pages.first(where: { $0.id == pageID }),
               let currentPage = latest.pages.first(where: { $0.id == pageID }),
               currentPage.drawingResourceID == resourceID,
               basePage.width == currentPage.width, basePage.height == currentPage.height,
               basePage.paper == currentPage.paper,
               basePage.backgroundResourceID == currentPage.backgroundResourceID,
               basePage.pdfPageIndex == currentPage.pdfPageIndex {
                try edit.apply(to: &old)
                try edit.apply(to: &latest)
                continue
            }
            guard edit.canRebase(from: old, onto: latest) else { throw NoteError.conflict }
            try edit.apply(to: &old)
            try edit.apply(to: &latest)
            remaining.append(edit)
        }
        if remaining.isEmpty { return current }
        var rebased = batch
        rebased.edits = remaining
        rebased.expectedRevision = current.revision
        return try apply(rebased)
    }
}
