#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeCanvasCore

/// Explicit professional configuration surface. Its staged definition is
/// bound to the opening document revision, never to a later reload.
struct CanvasFlowDefinitionEditor: View {
    private struct Draft {
        let snapshot: CanvasSnapshot
        let pageID: UUID
        let graphID: UUID
        var text: String
    }
    @ObservedObject var store: CanvasEditorStore
    @State private var draft: Draft
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var selectAllToken = 0
    @Environment(\.dismiss) private var dismiss
    private var strings: CanvasStrings { store.strings }
    private static let byteLimit = 8 * 1024 * 1024

    init(store: CanvasEditorStore, graphID: UUID) {
        self.store = store
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let graph = store.page.flowGraphs.first { $0.id == graphID }
        let data = graph.flatMap { try? encoder.encode($0) }
        _draft = State(initialValue: Draft(snapshot: store.snapshot,
            pageID: store.selectedPageID, graphID: graphID,
            text: data.flatMap { String(data: $0, encoding: .utf8) } ?? ""))
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(strings[.flowDefinitionHelp]).font(.callout).foregroundStyle(.secondary)
                CanvasDefinitionTextView(text: $draft.text, selectAllToken: selectAllToken)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("floe.canvas.flow.definitionError")
                }
            }
            .padding()
            .navigationTitle(strings[.flowDefinitionTitle])
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(strings[.cancelButton]) { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(strings[.saveButton]) { Task { await save() } }
                        .disabled(isSaving || draft.text.isEmpty)
                        .accessibilityIdentifier("floe.canvas.flow.saveDefinition")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(strings[.flowDefinitionSelectAll]) { selectAllToken += 1 }
                        .accessibilityIdentifier("floe.canvas.flow.selectDefinition")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floe.canvas.flow.definitionEditor")
    }

    @MainActor private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let data = Data(draft.text.utf8)
            guard data.count <= Self.byteLimit else {
                throw CanvasKitError.invalidSnapshot("flow definition exceeds 8 MiB")
            }
            let graph = try JSONDecoder().decode(FlowGraph.self, from: data)
            guard graph.id == draft.graphID else {
                throw CanvasKitError.invalidSnapshot("flow identity must stay unchanged")
            }
            let batch = try CanvasFlowGraphEditing.replaceDefinitionBatch(
                snapshot: draft.snapshot, pageID: draft.pageID, definition: graph)
            await store.commit(batch, undoLabel: strings[.flowDefinitionTitle],
                               expectedRevision: draft.snapshot.revision)
            if store.alert == nil && store.revision > draft.snapshot.revision {
                dismiss()
            } else {
                errorMessage = store.alert?.message ?? strings[.flowDefinitionInvalid]
            }
        } catch {
            errorMessage = strings[.flowDefinitionInvalid] + "\n" + String(describing: error)
        }
    }
}

/// JSON/code input must not substitute smart quotes, dashes or case.
private struct CanvasDefinitionTextView: UIViewRepresentable {
    @Binding var text: String
    var selectAllToken: Int
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 12
        view.textContainerInset = .init(top: 12, left: 8, bottom: 12, right: 8)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.accessibilityIdentifier = "floe.canvas.flow.definitionText"
        view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        if context.coordinator.lastSelection != selectAllToken {
            context.coordinator.lastSelection = selectAllToken
            view.becomeFirstResponder()
            view.selectedRange = NSRange(location: 0, length: (view.text as NSString).length)
        }
    }
    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CanvasDefinitionTextView
        var lastSelection = 0
        init(parent: CanvasDefinitionTextView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
    }
}
#endif
