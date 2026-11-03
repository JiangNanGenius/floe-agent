// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCAD
import FloeModels

/// Reuses the original task composer and attachment pipeline. No automatic
/// send, parallel chat service, selection store or authorization is created.
@MainActor struct CADSelectionAssistantEntry: ViewModifier {
    let document: FloeCADDocument
    let selection: CADSelectionContext?
    let relativePath: String
    let root: URL?
    let workspaceID: UUID?
    let conversationID: UUID?
    var onContextAttached: (@MainActor (AttachmentRef) -> Void)? = nil
    @EnvironmentObject private var environment: AppEnvironment
    @State private var showing = false
    @State private var preparing = false
    @State private var error: String?
    @State private var preparationID: UUID?
    @State private var preparationTask: Task<Void, Never>?
    private var available: Bool {
        guard let selection, !selection.isEmpty, let root, let workspaceID, conversationID != nil,
              !document.isClosed, !document.isReadOnly,
              environment.workspaceCenter.currentWorkspace?.id == workspaceID,
              selection.documentRevision == Int64(document.revision),
              selection.changeCount == document.liveChangeCount else { return false }
        return root.appendingPathComponent(relativePath).standardizedFileURL == document.url.standardizedFileURL
    }
    func body(content: Content) -> some View {
        content.toolbar {
            if conversationID != nil {
                Button { beginPreparation() } label: {
                    Label(FloeCADStrings.text("cad.selection.askAssistant", "Ask About Selection"), systemImage: "sparkles")
                }
                .disabled(!available || preparing)
                .accessibilityIdentifier("cad.selection.askAssistant")
            }
        }
        .onDisappear {
            preparationID = nil; preparationTask?.cancel(); preparationTask = nil; preparing = false
        }
        .sheet(isPresented: $showing) {
            if let conversationID {
                NavigationStack {
                    ThreadDetailView(conversationID: conversationID, center: environment.conversationCenter, embedded: true)
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button(FloeCADStrings.text("cad.ui.common.done", "Done")) { showing = false }
                                .accessibilityIdentifier("cad.selection.assistant.done")
                        } }
                }
            }
        }
        .alert(FloeCADStrings.text("cad.ui.error.title", "Something Went Wrong"),
               isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(FloeCADStrings.text("cad.ui.common.ok", "OK"), role: .cancel) {}
        } message: { Text(error ?? "") }
    }
    private func beginPreparation() {
        guard available, !preparing else { return }
        preparing = true
        let id = UUID(); preparationID = id
        preparationTask = Task { await prepare(id: id) }
    }
    private func prepare(id: UUID) async {
        defer { if preparationID == id { preparing = false; preparationTask = nil } }
        guard !Task.isCancelled, preparationID == id, available,
              let workspaceID, let conversationID, let before = selection else { return }
        var unadopted: AttachmentRef?
        do {
            if document.hasUnsavedChanges {
                let outcome = await document.save()
                guard outcome.succeeded else { throw CADDocumentError(code: "selection_save", message: outcome.error ?? FloeCADStrings.text("cad.selection.attachFailed", "Couldn’t attach the selection. Try again.")) }
            }
            guard !document.isClosed, !document.isReadOnly else { return }
            guard !Task.isCancelled, preparationID == id else { return }
            let current = document.assistantSelectionContext()
            guard current.changeCount == before.changeCount,
                  current.features == before.features, current.datumPlane == before.datumPlane,
                  current.bodies.map(\.id) == before.bodies.map(\.id),
                  current.historySelectionGeneration == before.historySelectionGeneration,
                  let root, root.appendingPathComponent(relativePath).standardizedFileURL == document.url.standardizedFileURL,
                  environment.workspaceCenter.workspaceID(for: conversationID) == workspaceID,
                  let owner = try await environment.conversationStore.conversation(id: conversationID),
                  owner.purpose == .ordinary, owner.visibility == .normal else {
                throw CADDocumentError(code: "stale_selection", message: FloeCADStrings.text("cad.selection.changed", "The selection changed. Select it again."))
            }
            guard !Task.isCancelled, preparationID == id else { return }
            guard current.observationKey == document.assistantSelectionContext().observationKey,
                  !document.isClosed, !document.isReadOnly,
                  environment.workspaceCenter.currentWorkspace?.id == workspaceID else {
                throw CADDocumentError(code: "stale_selection", message: FloeCADStrings.text("cad.selection.changed", "The selection changed. Select it again."))
            }
            let store = ComposerDraftStore.shared, draft = store.entry(for: conversationID)
            let context: [String: Any] = ["schema": 1, "kind": "cad_selection", "path": relativePath,
                "revision": document.revision, "model_sha256": document.modelSHA256,
                "selection": current.jsonObject(), "authority": "context data only; re-query before editing"]
            let data = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
            let attachment = try environment.filesCenter.registerContextJSON(data,
                displayName: FloeCADStrings.text("cad.selection.attachment", "Selected 3D Part.json"), conversationID: conversationID)
            unadopted = attachment
            // No await between the final fence, draft read, staging and CAS.
            // User text and every existing attachment remain byte-for-byte.
            guard store.save(text: draft?.text ?? "", attachments: (draft?.attachments ?? []) + [attachment],
                conversationID: conversationID, selection: draft.flatMap { item -> NSRange? in
                    guard let location=item.selectionLocation else { return nil }; return NSRange(location:location,length:item.selectionLength ?? 0) },
                expectedRevision: draft?.revision) != nil else {
                throw CADDocumentError(code: "stale_draft", message: FloeCADStrings.text("cad.selection.changed", "The selection changed. Select it again."))
            }
            unadopted = nil
            onContextAttached?(attachment)
            showing = true
        } catch {
            if let unadopted {
                do { try environment.filesCenter.discardUnadoptedContextJSON(unadopted, conversationID: conversationID) }
                catch { self.error = FloeCADStrings.text("cad.selection.attachFailed", "Couldn’t attach the selection. Try again."); return }
            }
            self.error = error.localizedDescription
        }
    }
}
#endif
