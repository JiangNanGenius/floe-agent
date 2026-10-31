// SPDX-License-Identifier: MPL-2.0
// FloeApp — full-screen editor for a native CAD node owned by a Canvas.
//
// The Canvas toolbar's "CAD model (parametric workbench)" creates its editable
// `.floecad` package in the app-owned, per-canvas `CanvasCAD` container (not in
// a chat task or a user file workspace). Tapping the resulting node opens THIS
// full-screen workbench over the same package. It reuses:
//   * `FloeCAD3DBridge` for the single shared live document session,
//   * `FloeCADWorkbenchView` + `FloeCADHostChrome` (identical to FilePreview),
//   * `CADCanvasActionBridge` for "Apply to canvas / variant / add".
//
// On dismiss the live document is released through the bridge (which saves
// before dropping ownership). The canvas node's rendered thumbnail refreshes
// when the user explicitly applies inside; simply closing never mutates the
// node.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCAD
import FloeCore
import FloePersistence

/// Which canvas CAD node is open in the full-screen workbench. The canvas id
/// is part of the FROZEN owner captured into the action set at creation, so a
/// second workbench for the same package (another node) never steals or
/// unregisters this presentation's target.
struct CanvasNativeCADPresentation: Identifiable {
    let id: UUID          // node id
    let canvasID: UUID
    let documentID: UUID
    let sourceKey: String // canvas-cad:<canvas>/<package>
    /// True ONLY for the presentation opened by the creation route, before
    /// the user accepts the new model: the workbench then offers an explicit
    /// Cancel (an untouched draft leaves no node/package behind) next to an
    /// explicit Save & Keep. Opening an existing node is never cancellable
    /// this way.
    var newlyCreated: Bool = false
}

struct CanvasNativeCADEditor: View {
    let presentation: CanvasNativeCADPresentation
    let assetStore: CreativeAssetStore
    var onClose: () -> Void

    @State private var document: FloeCADDocument?
    @State private var loadError: String?
    @State private var cancelBusy = false
    @State private var discardMessage: String?
    /// E33: present only while the bound package cannot be verified and its
    /// verified `previous/` commit can be previewed. Restoring creates a NEW
    /// package; the damaged one stays bound to the canvas node.
    @State private var recoveryPreview: CADRecoveryPreview?
    @State private var recoverySheet: CADRecoverySheet?
    @State private var restoredCopyUnbound = false
    /// Fences inspection/restore completions to this presentation and to the
    /// node's bound package. The damaged package stays the canvas binding;
    /// only a copy this editor adopted may be saved/released on close.
    @State private var recoveryFence = CADRecoveryPresentationFence()
    @State private var recoveryTicket: CADRecoveryPresentationFence.Ticket?
    @State private var isClosing = false
    @State private var closeTask: Task<Void, Never>?
    @State private var releaseFailed = false

    /// The exact node this presentation owns, frozen for every action.
    private var frozenOwner: CADCanvasActionBridge.CADCanvasNodeOwner {
        CADCanvasActionBridge.CADCanvasNodeOwner(
            canvasID: presentation.canvasID,
            documentID: presentation.documentID,
            nodeID: presentation.id)
    }

    /// Cancel of a JUST-CREATED model: an untouched document is removed
    /// together with its node and package; an edited/unverifiable document is
    /// kept as the recoverable draft and the outcome says so.
    ///
    /// The LIVE session this workbench is showing is passed along: its own
    /// last-committed revision/hash is the ownership proof for the
    /// preview-only commits a fullscreen return/close flush produces, so
    /// merely viewing the model cannot read as an edit while a foreign write
    /// (even with identical content) still refuses.
    private func cancelNewCreation() {
        guard !cancelBusy else { return }
        cancelBusy = true
        let owner = presentation
        let liveDocument = document
        Task { @MainActor in
            let outcome = await CADCanvasActionBridge.discardNewCADDocument(
                canvasID: owner.canvasID, documentID: owner.documentID,
                nodeID: owner.id, liveDocument: liveDocument, assetStore: assetStore)
            cancelBusy = false
            if outcome.kind == .success {
                onClose()
            } else {
                discardMessage = outcome.message
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView {
                        Label("cad.canvas.editor.unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        if let preview = recoveryPreview {
                            Button("cad.recovery.action.review") {
                                recoverySheet = .decision(preview)
                            }
                            .accessibilityIdentifier("cad.recovery.reviewButton")
                        }
                        Button(role: .none) { closeEditor() } label: {
                            Text(FloeCADStrings.text("cad.ui.common.done", "Done"))
                        }
                    }
                } else if let document {
                    FloeCADWorkbenchView(
                        document: document,
                        canvasActions: workbenchCanvasActions)
                        .modifier(FloeCADHostChrome(
                            document: document,
                            canvasActions: workbenchCanvasActions))
                        .safeAreaInset(edge: .top) { restoredCopyNotice }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(document?.name ?? FloeCADStrings.text("cad.workbench.tools", "CAD Tools"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if presentation.newlyCreated {
                        // Cancel creation: never leaves an empty node/package
                        // for an untouched model; an edited draft is kept.
                        Button(role: .destructive) {
                            cancelNewCreation()
                        } label: {
                            Text(FloeL10n.l("action.cancel"))
                        }
                        .accessibilityIdentifier("canvas.nativeCAD.cancelCreation")
                        .disabled(document == nil || cancelBusy)
                    } else {
                        Button(FloeCADStrings.text("engineering.done", "Done")) { closeEditor() }
                            .accessibilityIdentifier("canvas.nativeCAD.done")
                    }
                }
                if presentation.newlyCreated {
                    ToolbarItem(placement: .confirmationAction) {
                        // Explicit save/keep (never labelled as cancel): the
                        // valid on-device document stays and the node keeps
                        // its binding.
                        Button(FloeL10n.l("canvas.nativeCAD.keep")) { onClose() }
                            .accessibilityIdentifier("canvas.nativeCAD.keep")
                    }
                }
            }
        }
        .sheet(item: $recoverySheet) { sheet in
            switch sheet {
            case .decision(let preview):
                CADRecoveryPreviewSheet(
                    preview: preview,
                    mode: .decide,
                    restore: { try await restoreRecoveryCopy(preview) },
                    onRestored: { result in
                        // Only the presentation that adopted THIS copy may
                        // clear the damaged-package error and show the copy.
                        guard restoredCopyUnbound,
                              document?.url.standardizedFileURL
                                == result.packageURL.standardizedFileURL else { return }
                        recoverySheet = nil
                        loadError = nil
                    },
                    onClose: { recoverySheet = nil },
                    onRefresh: {
                        recoverySheet = nil
                        recoveryPreview = nil
                        recoveryTicket = nil
                        restoredCopyUnbound = false
                        loadError = nil
                        recoveryFence.invalidate()
                        Task { await loadBoundPackage() }
                    })
            case .report(let preview):
                CADRecoveryPreviewSheet(
                    preview: preview,
                    mode: .report,
                    restore: nil,
                    onRestored: { _ in },
                    onClose: { recoverySheet = nil })
            }
        }
        .alert(
            FloeL10n.l("canvas.nativeCAD.keptDraftTitle"),
            isPresented: Binding(
                get: { discardMessage != nil },
                set: { presented in
                    if !presented {
                        discardMessage = nil
                        onClose()
                    }
                })
        ) {
            Button(FloeL10n.l("action.done")) {
                discardMessage = nil
                onClose()
            }
        } message: {
            Text(discardMessage ?? "")
        }
        .onDisappear {
            // The presentation is gone (Done, swipe, or an external retarget).
            // No in-flight inspection/restore may surface in another view, and
            // an adopted copy must not keep a bridge owner with no editor.
            isClosing = true
            recoveryFence.invalidate()
            guard restoredCopyUnbound, let live = document else { return }
            Task { @MainActor in
                if !FloeCAD3DBridge.shared.releaseReadOnlyDocument(live) {
                    _ = await FloeCAD3DBridge.shared
                        .releaseDocumentOutcome(at: live.url, expected: live)
                }
                document = nil
            }
        }
        .task { await loadBoundPackage() }
    }
    /// The bound node keeps using the existing action set. A restored COPY is
    /// not the node's bound package, so offering Apply/Variant there would be
    /// false; the copy opens as a standalone editable document and the banner
    /// says the node still points at the damaged package.
    private var workbenchCanvasActions: CADCanvasActions? {
        guard !restoredCopyUnbound else { return nil }
        return CADCanvasActionBridge.actions(assetStore: assetStore, owner: frozenOwner)
    }

    @ViewBuilder
    private var restoredCopyNotice: some View {
        if restoredCopyUnbound, let preview = recoveryPreview {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text("cad.recovery.canvas.unbound")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("cad.recovery.action.details") {
                        recoverySheet = .report(preview)
                    }
                    .font(.caption)
                    .accessibilityIdentifier("cad.recovery.restored.detailsButton")
                }
                // The copy's save failed on close. The editor stays open with
                // the only live owner so the user can retry; nothing is
                // silently dropped or dismissed.
                if releaseFailed {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("cad.recovery.canvas.saveFailedTitle")
                                .font(.caption.weight(.semibold))
                            Text("cad.recovery.canvas.saveFailedMessage")
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("cad.recovery.canvas.saveFailed")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityIdentifier("cad.recovery.canvas.unbound")
        }
    }

    @MainActor
    private func loadBoundPackage() async {
        guard document == nil, loadError == nil, recoveryPreview == nil,
              !isClosing else { return }
        guard let url = CADCanvasActionBridge.packageURL(forSourceKey: presentation.sourceKey) else {
            loadError = NSLocalizedString(
                "workspace.canvas_cad.bad_binding",
                value: "This CAD node does not carry a valid on-device document reference.",
                comment: "Canvas CAD node binding key could not be resolved")
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadError = NSLocalizedString(
                "workspace.canvas_cad.missing_package",
                value: "The CAD document for this node is not on this device.",
                comment: "Canvas CAD package missing on disk")
            return
        }
        // Every load owns a ticket. A late inspection/open from an older load
        // (or from a dismissed editor) can never present or adopt anything.
        let ticket = recoveryFence.begin(sourceURL: url)
        do {
            // A just-created model keeps its existing in-place creation and
            // cancel semantics; only opening an EXISTING corrupted node asks
            // before the store promotes its previous commit.
            if !presentation.newlyCreated {
                switch await FloeCADDocument.recoveryInspection(at: url) {
                case .intact:
                    break
                case .damaged(_, let preview):
                    guard recoveryFence.accepts(ticket), !Task.isCancelled,
                          !isClosing else { return }
                    if let preview {
                        recoveryPreview = preview
                        recoveryTicket = ticket
                        recoverySheet = .decision(preview)
                        loadError = FloeL10n.l("cad.recovery.unavailable")
                    } else {
                        loadError = FloeL10n.l("cad.recovery.error.noPrevious")
                    }
                    return
                }
            }
            guard recoveryFence.accepts(ticket), !Task.isCancelled, !isClosing else { return }
            let opened = try await FloeCAD3DBridge.shared.openDocument(at: url)
            guard recoveryFence.accepts(ticket), !Task.isCancelled, !isClosing else {
                // The node's bound package keeps the existing shared-session
                // lifetime; only a copy adopted by THIS editor is released.
                return
            }
            document = opened
        } catch {
            guard !isClosing else { return }
            loadError = error.localizedDescription
        }
    }

    /// Create the atomic sibling copy, then open it ONLY for the presentation
    /// that started this restore. The damaged package stays bound to the canvas
    /// node; the copy is never silently rebound and the original is never
    /// deleted. If the editor has already moved on, the copy still exists (the
    /// atomic step is allowed to finish) and is not attached to another view.
    @MainActor
    private func restoreRecoveryCopy(_ preview: CADRecoveryPreview) async throws
    -> CADRecoveryRestoreResult {
        guard let ticket = recoveryTicket,
              recoveryFence.accepts(ticket),
              ticket.sourceURL == preview.sourceURL.standardizedFileURL,
              !restoredCopyUnbound,
              !isClosing,
              !Task.isCancelled else {
            throw CancellationError()
        }
        let destination = CADRecoveryCopyDestination.suggestedURL(
            for: preview.sourceURL,
            suffix: FloeL10n.l("cad.recovery.copySuffix"))
        let result = try await FloeCADDocument.restorePreviousCopy(preview, to: destination)

        guard recoveryFence.accepts(ticket), !Task.isCancelled, !isClosing else {
            return result
        }
        do {
            let restored = try await FloeCAD3DBridge.shared.openDocument(at: result.packageURL)
            guard recoveryFence.accepts(ticket), !Task.isCancelled, !isClosing,
                  recoveryFence.adopt(ticket,
                                      copyURL: result.packageURL,
                                      resultSourceURL: result.sourceURL) != nil else {
                // Never leave a new bridge owner behind for a result this
                // editor cannot present. The node binding is untouched.
                await FloeCAD3DBridge.shared.releaseDocument(
                    at: result.packageURL, expected: restored)
                return result
            }
            document = restored
            restoredCopyUnbound = true
            return result
        } catch is CancellationError {
            return result
        } catch {
            throw CADRecoveryOpenError(message: FloeL10n.l(
                "cad.recovery.error.openFailed", result.packageURL.lastPathComponent))
        }
    }

    /// Close this editor. A restored COPY is a package this editor adopted, so
    /// it is saved and its bridge ownership is released HERE (the node keeps
    /// pointing at the damaged package). A failed save keeps the editor open
    /// and the only live owner alive for a retry.
    @MainActor
    private func closeEditor() {
        guard closeTask == nil else { return }
        isClosing = true
        let live = document
        let releaseCopy = restoredCopyUnbound
        closeTask = Task { @MainActor in
            if releaseCopy, let live {
                if FloeCAD3DBridge.shared.releaseReadOnlyDocument(live) {
                    // A read-only copy has nothing to commit and closes cleanly.
                    document = nil
                } else if let outcome = await FloeCAD3DBridge.shared
                    .releaseDocumentOutcome(at: live.url, expected: live) {
                    guard outcome.error == nil else {
                        // Keep this editor (and the only live copy owner) open
                        // so the user can retry the real save.
                        isClosing = false
                        closeTask = nil
                        releaseFailed = true
                        return
                    }
                    document = nil
                } else if live.isReadOnly {
                    // A read-only copy that the bridge no longer caches closes
                    // without a commit.
                    live.close()
                    document = nil
                } else {
                    // The bridge no longer owned the session: flush and close
                    // the exact copy this editor adopted.
                    let outcome = await live.save()
                    guard outcome.error == nil, !live.hasUnsavedChanges else {
                        isClosing = false
                        closeTask = nil
                        releaseFailed = true
                        return
                    }
                    live.close()
                    document = nil
                }
            }
            onClose()
        }
    }

}
#endif
