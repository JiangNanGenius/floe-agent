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
import UIKit
import FloeWorkspace
import FloeMarkdown

/// Edits one workspace text file. Save goes through the guarded service
/// with optimistic-concurrency checks. Markdown files gain a live preview
/// toggle and a formatting toolbar.
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
    @State private var isPreviewing = false
    @State private var selectedRange = NSRange(location: 0, length: 0)

    /// Whether this file is Markdown and should offer preview + formatting.
    private var isMarkdown: Bool {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let loadError {
                    ContentUnavailableView {
                        Label("inspector.editor.error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    }
                } else if isMarkdown && isPreviewing {
                    ScrollView {
                        MarkdownRendererView(source: text)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(FloeTheme.readingSurface)
                } else {
                    MarkdownAwareTextView(
                        text: $text,
                        selectedRange: $selectedRange
                    )
                    .background(FloeTheme.readingSurface)
                    .padding(.horizontal, 8)
                }
            }
            if isMarkdown, !isPreviewing {
                formatToolbar
            }
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle((relativePath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isMarkdown {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isPreviewing ? "inspector.editor.edit" : "inspector.editor.preview") {
                        isPreviewing.toggle()
                    }
                    .frame(minHeight: FloeTheme.minimumTarget)
                }
            }
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

    // MARK: - Formatting toolbar

    private var formatToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                formatButton("B", systemImage: "bold") { wrap("**") }
                formatButton("I", systemImage: "italic") { wrap("*") }
                formatButton("H", systemImage: "textformat.size") { prefixLines("# ") }
                formatButton("List", systemImage: "list.bullet") { prefixLines("- ") }
                formatButton("Code", systemImage: "chevron.left.forwardslash.chevron.right") {
                    wrap("```\n", suffix: "\n```")
                }
                formatButton("Quote", systemImage: "text.quote") { prefixLines("> ") }
                formatButton("Link", systemImage: "link") {
                    insert("[text](https://)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(FloeTheme.chromeMaterial)
    }

    private func formatButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.body)
        }
        .buttonStyle(.bordered)
        .frame(minWidth: 40, minHeight: 40)
        .accessibilityLabel(title)
    }

    /// Wraps the current selection (or inserts an empty template at the
    /// cursor) with `prefix`/`suffix`.
    private func wrap(_ prefix: String, suffix: String? = nil) {
        let suffix = suffix ?? prefix
        applyFormatting(prefix: prefix, suffix: suffix)
    }

    /// Prefixes each line of the selection (or the current line) with
    /// `marker`.
    private func prefixLines(_ marker: String) {
        let range = effectiveRange
        let nsText = text as NSString
        let selected = nsText.substring(with: range)
        let transformed = selected.isEmpty
            ? marker
            : selected.components(separatedBy: .newlines).map { marker + $0 }.joined(separator: "\n")
        replaceRange(range, with: transformed)
    }

    private func insert(_ template: String) {
        replaceRange(effectiveRange, with: template)
    }

    private func applyFormatting(prefix: String, suffix: String) {
        let range = effectiveRange
        let nsText = text as NSString
        let selected = nsText.substring(with: range)
        let replacement = prefix + (selected.isEmpty ? "text" : selected) + suffix
        replaceRange(range, with: replacement)
    }

    private var effectiveRange: NSRange {
        if selectedRange.length > 0 { return selectedRange }
        return NSRange(location: selectedRange.location, length: 0)
    }

    private func replaceRange(_ range: NSRange, with replacement: String) {
        guard let swiftRange = Range(range, in: text) else { return }
        text.replaceSubrange(swiftRange, with: replacement)
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

/// UITextView bridge that exposes the current selection range so the
/// Markdown formatting toolbar can wrap/prefix the selection. A plain
/// `TextEditor` cannot report its cursor, so Markdown files use this.
private struct MarkdownAwareTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.isEditable = true
        view.isScrollEnabled = true
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            view.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let parent: MarkdownAwareTextView

        init(_ parent: MarkdownAwareTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.selectedRange = textView.selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selectedRange = textView.selectedRange
        }
    }
}
#endif
