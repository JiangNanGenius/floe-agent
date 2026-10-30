//
//  CADExplodedViewPreview.swift
//  FloeCADKit
//
//  ONE transient exploded-view preview per open document. A saved
//  `CADExplodedView` is display/drawing state; activating it here makes the
//  engineering viewport and the presentation scene draw its offsets, and
//  resetting stops using them. Nothing in this file touches the document:
//  the persisted instance transforms, the assembly JSON, the undo stack and
//  the dirty flag are unchanged, so a preview can never become saved geometry.
//
//  Ownership: `DocumentSession` is the live document identity shared by the
//  editor view model, the assembly service and the presentation snapshot, so
//  the state is kept per session (a weak-key table releases it with the
//  document) instead of on the view or the snapshot. Reopening a document
//  therefore starts with no preview, and two open documents never share one.
//

import Foundation
import Observation

/// Transient exploded-view display state for one open document.
///
/// `revision` is the redraw token: observers (the editor's SwiftUI change key
/// and the panel) read it so activating or resetting a preview repaints the
/// viewport. The state deliberately stores only the viewed id/name — the
/// placements are resolved against the LIVE assembly on every read, so a view
/// removed by an edit or undo can never keep a stale offset alive.
@MainActor
@Observable
final class CADExplodedViewPreview {
    /// Bumped on every activation/reset/rename. Views that read the state
    /// re-evaluate and the viewport repaints.
    private(set) var revision = 0
    /// Saved view currently previewed; nil when the assembly is shown at its
    /// base (saved) placements.
    private(set) var viewID: UUID?
    /// Display name captured at activation; `reconcile(with:)` refreshes it.
    private(set) var viewName: String?

    /// True when the viewport is showing a saved exploded view.
    var isActive: Bool { viewID != nil }

    fileprivate init() {}

    // MARK: - Resolution

    /// The view id to apply against `assembly`, or nil when the preview is off
    /// or its saved view no longer exists. Reads only live document JSON, so a
    /// removed/undone view safely falls back to the base placements.
    func resolvedViewID(in assembly: CADAssembly) -> UUID? {
        guard let viewID, assembly.explodedView(viewID) != nil else { return nil }
        return viewID
    }

    /// This instance's preview placement (`base + view offset`), or nil when
    /// no preview applies — callers then use the stored instance transform.
    /// The stored transform itself is never modified.
    func transform(for instanceID: UUID, in assembly: CADAssembly) -> CADTransform? {
        guard let viewID = resolvedViewID(in: assembly) else { return nil }
        return assembly.explodedTransform(for: instanceID, viewID: viewID)
    }

    // MARK: - Activation

    /// Show the named saved view in the viewport. Re-activating the same view
    /// keeps the current revision (no repaint is owed); a different view bumps
    /// it. The caller has already validated that the view exists.
    @discardableResult
    func activate(viewID: UUID, name: String) -> Bool {
        if self.viewID == viewID {
            if viewName != name {
                viewName = name
                revision += 1
            }
            return false
        }
        self.viewID = viewID
        viewName = name
        revision += 1
        return true
    }

    /// Return to the base placements. Returns true when something changed so
    /// the caller can report an honest "was there a preview" answer.
    @discardableResult
    func reset() -> Bool {
        guard viewID != nil || viewName != nil else { return false }
        viewID = nil
        viewName = nil
        revision += 1
        return true
    }

    /// Drop the preview when its saved view is gone (removed, cleared or
    /// undone) and refresh a renamed view's display name. Returns true when the
    /// preview was cleared.
    @discardableResult
    func reconcile(with assembly: CADAssembly) -> Bool {
        guard let viewID else { return false }
        guard let view = assembly.explodedView(viewID) else { return reset() }
        if view.name != viewName {
            viewName = view.name
            revision += 1
        }
        return false
    }
}

// MARK: - Per-session registry

extension CADExplodedViewPreview {
    /// Weak document keys: the entry disappears with the open document, so a
    /// closed/reopened document never inherits a preview and the table cannot
    /// grow without bound.
    private static let states = NSMapTable<DocumentSession, CADExplodedViewPreview>(
        keyOptions: .weakMemory, valueOptions: .strongMemory)

    /// The live preview for this document, or nil when the assembly is drawn
    /// at its base placements. Never creates state (safe from read-only
    /// snapshot/query paths).
    static func current(for session: DocumentSession) -> CADExplodedViewPreview? {
        states.object(forKey: session)
    }

    /// The stable state object for this document, created on first use.
    static func state(for session: DocumentSession) -> CADExplodedViewPreview {
        if let existing = states.object(forKey: session) { return existing }
        let created = CADExplodedViewPreview()
        states.setObject(created, forKey: session)
        return created
    }
}
