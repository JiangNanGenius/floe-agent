// FloeApp — Workspace text file editor.
//
// SPDX-License-Identifier: MPL-2.0
//
// Plain-text editing with conflict-safe saving: the editor snapshots
// mtime+sha256 at load and passes them to WorkspaceCenter.saveFile, which
// refuses to overwrite externally modified files and surfaces a conflict
// alert (same UX contract as FilesCenter's FileConflict).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeWorkspace

/// Edits one workspace text file. Save goes through the guarded service
/// with optimistic-concurrency checks.
struct TextFileEditorView: View {
    let relativePath: String
    @ObservedObject var center: WorkspaceCenter
    /// Called after a successful save so the caller can refresh.
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var text = ""
    @State private var originalText = ""
    @State private var baseMtime: Double?
    @State private var baseSHA256: String?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var isSaving = false

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView {
                    Label("inspector.editor.error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                }
            } else {
                TextEditor(text: $text)
                    .font(FloeTheme.Typography.evidence)
                    .scrollContentBackground(.hidden)
                    .background(FloeTheme.readingSurface)
                    .padding(.horizontal, 8)
            }
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle((relativePath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("inspector.editor.cancel") { dismiss() }
                    .frame(minHeight: FloeTheme.minimumTarget)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("inspector.editor.save")
                    }
                }
                .disabled(!isDirty || isSaving)
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("inspector.editor.save")
            }
        }
        .task { await load() }
        .alert(item: $center.conflict) { conflict in
            Alert(
                title: Text("inspector.conflict.title"),
                message: Text(conflict.relativePath + "\n" + conflict.detail),
                dismissButton: .default(Text("action.done")) {
                    center.conflict = nil
                }
            )
        }
        .alert(
            Text("inspector.editor.save_failed"),
            isPresented: saveErrorBinding,
            presenting: saveError
        ) { _ in
            Button("action.done", role: .cancel) { saveError = nil }
        } message: { message in
            Text(message)
        }
    }

    private var isDirty: Bool { text != originalText }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private func load() async {
        guard let service = center.fileService else {
            loadError = String(localized: "inspector.no_workspace")
            return
        }
        do {
            let content = try service.readFile(relativePath, byteOffset: 0)
            let metadata = try service.metadata(relativePath)
            text = content.text
            originalText = content.text
            baseMtime = metadata.mtime
            baseSHA256 = metadata.sha256
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let outcome = try await center.saveFile(
                relativePath: relativePath,
                content: text,
                expectedMtime: baseMtime,
                expectedSHA256: baseSHA256
            )
            originalText = text
            baseMtime = outcome.mtime
            baseSHA256 = outcome.sha256
            saveError = nil
            onSaved()
            dismiss()
        } catch let error as WorkspaceToolError {
            if case .conflict = error {
                // The center already surfaced the conflict alert.
            } else {
                saveError = error.errorDescription ?? error.localizedDescription
            }
        } catch {
            saveError = error.localizedDescription
        }
    }
}
#endif
