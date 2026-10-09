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
import FloePersistence

/// Which canvas CAD node is open in the full-screen workbench.
struct CanvasNativeCADPresentation: Identifiable {
    let id: UUID          // node id
    let documentID: UUID
    let sourceKey: String // canvas-cad:<canvas>/<package>
}

struct CanvasNativeCADEditor: View {
    let presentation: CanvasNativeCADPresentation
    let assetStore: CreativeAssetStore
    var onClose: () -> Void

    @State private var document: FloeCADDocument?
    @State private var loadError: String?

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
                        canvasActions: CADCanvasActionBridge.actions(assetStore: assetStore))
                        .modifier(FloeCADHostChrome(
                            document: document,
                            canvasActions: CADCanvasActionBridge.actions(assetStore: assetStore)))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(document?.name ?? FloeCADStrings.text("cad.workbench.tools", "CAD Tools"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("engineering.done", "Done")) { onClose() }
                        .accessibilityIdentifier("canvas.nativeCAD.done")
                }
            }
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
