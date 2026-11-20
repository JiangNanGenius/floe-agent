// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCAD
import FloeCore

/// A separate presentation owner. The source drawing's WKWebView/Worker stays
/// alive in FilePreviewView, with its complete draft, selection and undo stack.
@MainActor struct CADFromDrawingDestination {
    let id: UUID
    let document: FloeCADDocument
    let path: String
    let transfer: CADSketchTransferEnvelope
    let sourcePath: String
    let sourceRoot: URL
    let workspaceID: UUID?
    let conversationID: UUID?
    let returnToDrawingFullScreen: Bool
}

@MainActor struct CADFromDrawingWorkspaceView: View {
    let destination: CADFromDrawingDestination
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var saving = false
    @State private var error: String?
    @State private var prepared = false
    @State private var building = false
    @State private var professional: CADBuildingProfessionalAction?
    @State private var saveTask: Task<Void, Never>?
    @State private var saveGeneration = UUID()
    @State private var projectCovered = false
    private var document: FloeCADDocument { destination.document }
    private var isBuilding: Bool { destination.transfer.purpose == .buildingFloorplan }
    private func t(_ zh: String, _ en: String) -> String { FloeL10n.isChinese ? zh : en }

    var body: some View {
        NavigationStack {
            Group {
                if isBuilding {
                    FloeBuildingWorkbenchView(document: document, incomingPlan: destination.transfer,
                                              hostOwnsProjectSave: true) { professional = $0 }
                } else {
                    FloeCADWorkbenchView(document: document)
                }
            }
            .environment(\.cadWorkbenchTransientlyCovered, true)
            .modifier(CADLibrarySketchImportEntry(document: document))
            .modifier(CADBuildingProjectEntry(document: document, root: destination.sourceRoot,
                                              blocked: saving,
                                              onCoverChange: { projectCovered = $0 }))
            .modifier(CADOfflineRenderEntry(document: document, root: destination.sourceRoot,
                workspaceID: destination.workspaceID, conversationID: destination.conversationID))
            .navigationTitle(document.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(FloeL10n.l("app.cadfrom_drawing_workspace_view.return_to_drawing")) { save(close: true) }
                        .disabled(saving).accessibilityIdentifier("cad.transfer.return")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !isBuilding {
                        Button { building = true } label: { Label(FloeL10n.l("cad.building.title"), systemImage: "building.2") }
                            .disabled(saving)
                    }
                    Button { save(close: false) } label: { Label(FloeL10n.l("voice.cloud.profile.save"), systemImage: "tray.and.arrow.down") }
                        .disabled(saving || document.isReadOnly).accessibilityIdentifier("cad.transfer.save")
                }
            }
            .disabled(saving)
        }
        .task {
            guard !prepared else { return }; prepared = true
            if !isBuilding {
                do { try document.queueDrawingTransfer(destination.transfer) }
                catch { self.error = error.localizedDescription }
            }
        }
        .fullScreenCover(isPresented: $building) {
            CADBuildingWorkspaceView(document: document, root: destination.sourceRoot,
                workspaceID: destination.workspaceID, conversationID: destination.conversationID)
        }
        .sheet(item: $professional) { action in
            CADBuildingProfessionalView(document: document, action: action, root: destination.sourceRoot,
                workspaceID: destination.workspaceID, conversationID: destination.conversationID)
        }
        .alert(FloeL10n.l("app.cadfrom_drawing_workspace_view.the_model_operation_could_not"),
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(FloeL10n.l("cad.ui.common.ok")) { error = nil }
        } message: { Text(error ?? "") }
        // Closing is an explicit save/release. A failed save keeps this owner
        // and its editable draft visible for retry.
        .interactiveDismissDisabled(true)
        .onChange(of: scenePhase) { _, phase in
            // The embedded building editor leaves the project save to this
            // owner, so keep the background flush it previously provided.
            guard isBuilding, phase != .active, !saving, !document.isClosed, document.hasUnsavedChanges else { return }
            Task { _ = await document.save() }
        }
        .onDisappear {
            if !building, !projectCovered, professional == nil {
                saveGeneration = UUID(); saveTask?.cancel(); saveTask = nil
            }
        }
        .accessibilityIdentifier("CADFromDrawingWorkspace")
    }
    private func save(close: Bool) {
        guard !saving else { return }; saving = true
        let generation = UUID(); saveGeneration = generation
        saveTask = Task { @MainActor in
            defer { if saveGeneration == generation { saving = false; saveTask = nil } }
            if close {
                if document.isClosed || FloeCAD3DBridge.shared.releaseReadOnlyDocument(document) { dismiss(); return }
                guard let outcome = await FloeCAD3DBridge.shared.releaseDocumentOutcome(at: document.url, expected: document) else {
                    error = FloeL10n.l("app.cadfrom_drawing_workspace_view.the_model_session_changed_open"); return
                }
                guard !Task.isCancelled, saveGeneration == generation else { return }
                if let failure = outcome.error { error = failure }
                else if document.isClosed { dismiss() }
                else { error = FloeL10n.l("app.cadfrom_drawing_workspace_view.the_model_has_newer_edits") }
            } else {
                let outcome = await document.save()
                guard !Task.isCancelled, saveGeneration == generation else { return }
                if let failure = outcome.error { error = failure }
            }
        }
    }
}
#endif
