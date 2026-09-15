// SPDX-License-Identifier: MPL-2.0
import Foundation

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
        case .insertPage, .movePage, .deletePage:
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
        let current = try document(base.id)
        if current.revision == base.revision { return try apply(batch) }
        var old = base, latest = current
        for edit in batch.edits {
            guard edit.canRebase(from: old, onto: latest) else { throw NoteError.conflict }
            try edit.apply(to: &old)
            try edit.apply(to: &latest)
        }
        var rebased = batch
        rebased.expectedRevision = current.revision
        return try apply(rebased)
    }
}
