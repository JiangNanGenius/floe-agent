// SPDX-License-Identifier: MPL-2.0
// FloeApp — DEBUG-only fixture for the canvas native-CAD node entry surface.
//
// Launch with `-ui-testing --ui-test-canvas-cad-fixture`. It builds an
// ordinary canvas (no file workspace, no chat task) with ONE canvas-owned
// native CAD node through the production bridge
// (`CADCanvasActionBridge.newCADDocumentInCanvas`), presents the REAL
// `WorkspaceCanvasView` and selects the node so the bottom contextual
// toolbar shows its explicit "Open CAD workbench" action. The UI test then
// drives that action and asserts the full-screen native CAD editor opens via
// the SAME binding route double tap uses (`openNativeCADEditor` →
// `CanvasNativeCADEditor`).
//
// The UI test proves the previously reported defects are fixed: the node
// shows its real viewport thumbnail with an explicit editable `.floecad`
// identity (not a generic document icon labelled image/png), and the
// selected-node contextual action opens the native CAD workbench rather
// than inline-renaming the node. Debug only: no release code path creates
// this fixture.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeCAD

/// Fixture node identity carried into `WorkspaceCanvasView`. The environment
/// key is always compiled (always nil in product paths); only the harness
/// view below is DEBUG-gated.
struct CanvasCADFixtureAutoOpen: Equatable {
    let nodeID: UUID
    let documentID: UUID
}

struct CanvasCADFixtureAutoOpenKey: EnvironmentKey {
    static let defaultValue: CanvasCADFixtureAutoOpen? = nil
}

extension EnvironmentValues {
    var canvasCADFixtureAutoOpen: CanvasCADFixtureAutoOpen? {
        get { self[CanvasCADFixtureAutoOpenKey.self] }
        set { self[CanvasCADFixtureAutoOpenKey.self] = newValue }
    }
}

#if DEBUG
import FloePersistence

struct CanvasCADEntryFixtureHarness: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var canvasID = UUID()
    @State private var nodeID: UUID?
    @State private var documentID: UUID?
    @State private var failed: String?

    var body: some View {
        Group {
            if let failed {
                VStack(spacing: 12) {
                    Text("Canvas CAD fixture failed").font(.headline)
                    Text(failed).font(.footnote).multilineTextAlignment(.center).padding()
                }
            } else if let nodeID, let documentID {
                WorkspaceCanvasView(canvasID: canvasID,
                                    name: "CAD Canvas Fixture",
                                    workspace: nil)
                    .environment(\.canvasCADFixtureAutoOpen,
                                  CanvasCADFixtureAutoOpen(nodeID: nodeID,
                                                           documentID: documentID))
            } else {
                ProgressView("Preparing canvas CAD fixture…")
            }
        }
        .accessibilityIdentifier("CanvasCADFixtureHarness")
        .task {
            guard nodeID == nil, failed == nil else { return }
            do {
                try WorkspaceCanvasRegistry.createIfNeeded(canvasID: canvasID,
                                                            name: "CAD Canvas Fixture",
                                                            workspaceID: nil)
                let project = try WorkspaceCanvasRegistry.project(canvasID: canvasID)
                guard let docID = project.documents.first?.id else {
                    throw CADDocumentError(code: "fixture_failed",
                                           message: "The fixture canvas has no document.")
                }
                let result = await CADCanvasActionBridge.newCADDocumentInCanvas(
                    canvasID: canvasID,
                    documentID: docID,
                    // Inside the initial detail viewport (clear of the
                    // sidebar at regular width; the node is 420×300 centred
                    // here) so it is visible without an initial pan.
                    position: CanvasPoint(x: 420, y: 320),
                    assetStore: environment.creativeAssetStore)
                guard let created = result.nodeID else {
                    throw CADDocumentError(code: "fixture_failed", message: result.message)
                }
                documentID = docID
                nodeID = created
            } catch {
                failed = error.localizedDescription
            }
        }
    }
}
#endif
#endif
