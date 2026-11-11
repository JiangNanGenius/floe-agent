// SPDX-License-Identifier: MPL-2.0
// FloeApp — shared Floe-level chrome for the native `.floecad` workbench.
//
// The FilePreview host and the qualification fixture must present the SAME
// Floe-level surface around the imported editor (CUA 2026-10-10: the fixture
// previously showed only imported-editor controls, so acceptance could not
// see the production chrome). This modifier is that shared surface:
//
//   * Save status — an explicit save control with an honest outcome line
//     (the package also autosaves on background/release; this button is the
//     user-visible commit + status).
//   * Fullscreen — the same expansion the 2D engineering preview has, with
//     a Done return that keeps the live session (sizing transition, no
//     discard).
//
// The proposal banner, Canvas actions and assistant entry stay host-owned:
// the banner and Canvas actions appear in the real preview; the fixture has
// no assistant/Canvas by design.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCAD

@MainActor
struct FloeCADHostChrome: ViewModifier {
    let document: FloeCADDocument
    var canvasActions: CADCanvasActions? = nil
    /// Optional host observer for the live CAD selection (bodies/faces/edges/
    /// sketch/assembly instances + trusted document revision). Nil keeps the
    /// existing fullscreen/FilePreview hosts unchanged.
    var onSelectionContextChange: (@MainActor (CADSelectionContext) -> Void)? = nil

    /// Optional observation of the real host save; no replacement save path.
    var onSaveCompleted: (@MainActor (CADSaveOutcome) -> Void)? = nil
    var workspaceRoot: URL? = nil
    var workspaceID: UUID? = nil
    var conversationID: UUID? = nil
    var externalCoverPresented = false
    var manufacturingAvailable = true
    var onPreparePrint: (() -> Void)? = nil

    @State private var filePresentation = CADFilePresentationLease()
    @State private var saving = false
    @State private var saveOutcome: String?
    @State private var fullScreen = false
    @State private var building = false
    @State private var simulationCovered = false
    @State private var libraryCovered = false
    @State private var buildingProfessionalCovered = false
    @State private var printAfterFullscreen = false

    func body(content: Content) -> some View {
        content
            .modifier(CADLibrarySketchImportEntry(document: document, onCoverChange: { libraryCovered = $0 }))
            .onAppear { filePresentation.attach(document) }
            .onDisappear {
                if !fullScreen && !building && !externalCoverPresented && !simulationCovered && !buildingProfessionalCovered && !libraryCovered { filePresentation.release() }
            }
            .task(id:ObjectIdentifier(document)) {
                filePresentation.attach(document)
                CADDrawingModelBridge.configure(document)
            }
            // While the fullscreen cover is presented, the editor underneath
            // is TRANSIENTLY covered — its disappearance is not a close, so
            // the close-time preview flush is suppressed (T7T). A real close
            // (cover dismissed) leaves this false and flushes normally.
            .environment(\.cadWorkbenchTransientlyCovered, fullScreen || building || externalCoverPresented || simulationCovered || buildingProfessionalCovered || libraryCovered)
            .modifier(CADOfflineRenderEntry(document:document,root:workspaceRoot,workspaceID:workspaceID,conversationID:conversationID))
            .modifier(CADSimulationEntry(document:document,onCoverChange:{ simulationCovered = $0 }))
            .modifier(CADBuildingProfessionalEntry(document: document, root: workspaceRoot,
                workspaceID: workspaceID, conversationID: conversationID,
                onCoverChange: { buildingProfessionalCovered = $0 }))
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { building=true } label:{
                        Label(FloeCADStrings.text("cad.building.title","Building Design"),systemImage:"building.2")
                    }.accessibilityIdentifier("cad.host.building")
                    Button {
                        Task { await save() }
                    } label: {
                        Label(saving
                              ? FloeCADStrings.text("cad.host.saving", "Saving…")
                              : FloeCADStrings.text("cad.host.save", "Save"),
                              systemImage: saving ? "arrow.triangle.2.circlepath" : "tray.and.arrow.down")
                    }
                    .disabled(saving)
                    .accessibilityIdentifier("cad.host.save")
                    Button {
                        fullScreen = true
                    } label: {
                        Label(FloeCADStrings.text("engineering.fullscreen", "Full Screen"),
                              systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityIdentifier("cad.host.fullscreen")
                }
            }
            .fullScreenCover(isPresented:$building) {
                CADBuildingWorkspaceView(document:document,root:workspaceRoot,workspaceID:workspaceID,conversationID:conversationID)
            }
            .fullScreenCover(isPresented: $fullScreen, onDismiss: {
                if printAfterFullscreen { printAfterFullscreen = false; onPreparePrint?() }
            }) {
                NavigationStack {
                    // The cover's editor is a re-presentation of the SAME live
                    // session: its dismissal returns to the host editor, so it
                    // never performs a close-time flush either.
                    FloeCADWorkbenchView(
                        document: document,
                        canvasActions: canvasActions,
                        onSelectionContextChange: onSelectionContextChange)
                        .modifier(CADLibrarySketchImportEntry(document: document, onCoverChange: { libraryCovered = $0 }))
                        .modifier(CADManufacturingEntry(document: document,
                            available: manufacturingAvailable, offered: onPreparePrint != nil,
                            onPreparePrint: { printAfterFullscreen = true; fullScreen = false }))
                        .navigationTitle(document.name)
                        .navigationBarTitleDisplayMode(.inline)
                        .modifier(CADOfflineRenderEntry(document:document,root:workspaceRoot,workspaceID:workspaceID,conversationID:conversationID))
                        .modifier(CADSimulationEntry(document:document))
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button(FloeCADStrings.text("engineering.done", "Done")) {
                                    fullScreen = false
                                }
                                .accessibilityIdentifier("cad.host.done")
                            }
                        }
                }
                .modifier(CADBuildingProfessionalEntry(document: document, root: workspaceRoot,
                    workspaceID: workspaceID, conversationID: conversationID))
                .environment(\.cadWorkbenchTransientlyCovered, true)
                // Same sizing-transition rule as the 2D fullscreen: the live
                // session (including unsaved edits) is re-adopted on return.
            }
            .overlay(alignment: .top) {
                if let saveOutcome {
                    Text(saveOutcome)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.bar, in: Capsule())
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("cad.host.saveOutcome")
                }
            }
            .task(id: saveOutcome) {
                guard saveOutcome != nil else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled {
                    withAnimation { saveOutcome = nil }
                }
            }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let outcome = await document.save()
        onSaveCompleted?(outcome)
        saveOutcome = outcome.error
            ?? FloeCADStrings.text("cad.host.saved", "Saved")
    }
}
#endif
