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
                        Button(role: .none) { onClose() } label: {
                            Text(FloeCADStrings.text("cad.ui.common.done", "Done"))
                        }
                    }
                } else if let document {
                    FloeCADWorkbenchView(
                        document: document,
                        canvasActions: CADCanvasActionBridge.actions(
                            assetStore: assetStore, owner: frozenOwner))
                        .modifier(FloeCADHostChrome(
                            document: document,
                            canvasActions: CADCanvasActionBridge.actions(
                                assetStore: assetStore, owner: frozenOwner)))
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
                        Button(FloeCADStrings.text("engineering.done", "Done")) { onClose() }
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
        .task {
            guard document == nil, loadError == nil else { return }
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
            do {
                document = try await FloeCAD3DBridge.shared.openDocument(at: url)
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
#endif
