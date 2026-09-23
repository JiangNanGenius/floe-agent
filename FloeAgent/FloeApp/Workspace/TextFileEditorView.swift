// FloeApp — Workspace text file editor.
//
// SPDX-License-Identifier: MPL-2.0
//
// Plain-text editing with conflict-safe saving: the editor snapshots
// mtime+sha256 and the original text at load. Saves use the captured workspace
// service and present a three-way review if the disk version changed.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import FloeWorkspace
import FloeMarkdown
import FloeTools

/// Edits one workspace text file. Save goes through the guarded service
/// with optimistic-concurrency checks. Markdown files gain a live preview
/// toggle and a formatting toolbar.
struct TextFileEditorView: View {
    let relativePath: String
    @ObservedObject var center: WorkspaceCenter
    /// Called after a successful save so the caller can refresh.
    var onSaved: () -> Void = {}
    /// The full workspace IDE owns dismissal and file navigation itself.
    var embeddedInIDE = false
    /// Lets the IDE guard file switches and dismissal while edits are dirty.
    var onDirtyChange: (Bool) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var text = ""
    @State private var originalText = ""
    @State private var editService: WorkspaceFileService?
    @State private var editConflict: WorkspaceEditConflict?
    @State private var baseMtime: Double?
    @State private var baseSHA256: String?
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var isPreviewing = false
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var showsFind = false
    @State private var findText = ""
    @State private var replacementText = ""
    @State private var editorCommand = CodeEditorCommand()
    @State private var runOutput: CodeRunOutput?
    @State private var isRunning = false
    @State private var runCancellation: CancellationToken?

    /// Whether this file is Markdown and should offer preview + formatting.
    private var isMarkdown: Bool {
        WorkspaceFileType.isMarkdown(relativePath)
    }

    private var codeLanguage: CodeLanguage? {
        CodeLanguage(relativePath: relativePath)
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
                    Group {
                        if let codeLanguage {
                            StructuredCodeTextView(
                                text: $text,
                                selectedRange: $selectedRange,
                                language: codeLanguage,
                                command: $editorCommand
                            )
                        } else {
                            MarkdownAwareTextView(
                                text: $text,
                                selectedRange: $selectedRange
                            )
                        }
                    }
                    .background(FloeTheme.readingSurface)
                    .padding(.horizontal, 8)
                }
            }
            if codeLanguage != nil, showsFind {
                findReplaceBar
            }
            if isMarkdown, !isPreviewing {
                formatToolbar
            }
            if let language = codeLanguage {
                codeStatusBar(language)
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
            if !embeddedInIDE {
                ToolbarItem(placement: .cancellationAction) {
                    Button("inspector.editor.cancel") { dismiss() }
                        .frame(minHeight: FloeTheme.minimumTarget)
                }
            }
            if let language = codeLanguage {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        showsFind.toggle()
                    } label: {
                        Label("查找替换", systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    Menu {
                        ForEach(codeSymbols(language), id: \.offset) { symbol in
                            Button(symbol.label) { select(offset: symbol.offset) }
                        }
                    } label: {
                        Label("符号", systemImage: "list.bullet.indent")
                    }
                    .disabled(codeSymbols(language).isEmpty)
                    Button {
                        editorCommand.send(.undo)
                    } label: {
                        Label("撤销", systemImage: "arrow.uturn.backward")
                    }
                    Button {
                        editorCommand.send(.redo)
                    } label: {
                        Label("重做", systemImage: "arrow.uturn.forward")
                    }
                    if language.runnableToolName != nil {
                        if isRunning {
                            Button("停止") { runCancellation?.cancel() }
                        }
                        Button {
                            Task { await run(language) }
                        } label: {
                            if isRunning { ProgressView() } else { Label("运行", systemImage: "play.fill") }
                        }
                        .disabled(isRunning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
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
                .keyboardShortcut("s", modifiers: .command)
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("inspector.editor.save")
            }
        }
        .sheet(item: $runOutput) { output in
            NavigationStack {
                ScrollView {
                    Text(output.text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(output.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { runOutput = nil }
                    }
                }
            }
        }
        .task { await load() }
        .onChange(of: isDirty) { _, dirty in
            onDirtyChange(dirty)
        }
        .sheet(item: $editConflict) { review in
            TextConflictReviewView(conflict: review, onResolve: { merged in
                await resolve(review, content: merged)
            }, onCancel: { editConflict = nil }).id(review.id)
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

    private var findReplaceBar: some View {
        VStack(spacing: 6) {
            HStack {
                TextField("查找", text: $findText)
                    .textFieldStyle(.roundedBorder)
                Button("上一个") { find(backwards: true) }.disabled(findText.isEmpty)
                Button("下一个") { find(backwards: false) }.disabled(findText.isEmpty)
            }
            HStack {
                TextField("替换为", text: $replacementText)
                    .textFieldStyle(.roundedBorder)
                Button("替换") { replaceCurrent() }.disabled(findText.isEmpty)
                Button("全部替换") { replaceAll() }.disabled(findText.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FloeTheme.chromeMaterial)
    }

    private func codeStatusBar(_ language: CodeLanguage) -> some View {
        HStack(spacing: 12) {
            Label(language.displayName, systemImage: language.icon)
            Text(cursorDescription)
            Spacer()
            if isDirty {
                Label("未保存", systemImage: "circle.fill")
                    .foregroundStyle(FloeTheme.pending)
            } else {
                Label("已保存", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(FloeTheme.Typography.metadata)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(FloeTheme.chromeMaterial)
    }

    private var cursorDescription: String {
        let prefix = (text as NSString).substring(to: min(selectedRange.location, (text as NSString).length))
        let lines = prefix.components(separatedBy: "\n")
        return "行 \(lines.count)，列 \((lines.last?.utf16.count ?? 0) + 1)"
    }

    private func select(offset: Int) {
        selectedRange = NSRange(location: min(offset, (text as NSString).length), length: 0)
        editorCommand.send(.select(selectedRange))
    }

    private func find(backwards: Bool) {
        guard !findText.isEmpty else { return }
        let nsText = text as NSString
        let start = backwards ? 0 : min(NSMaxRange(selectedRange), nsText.length)
        let length = backwards ? min(selectedRange.location, nsText.length) : nsText.length - start
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        var range = nsText.range(of: findText, options: options, range: NSRange(location: start, length: length))
        if range.location == NSNotFound {
            range = nsText.range(of: findText, options: options, range: NSRange(location: 0, length: nsText.length))
        }
        guard range.location != NSNotFound else { return }
        selectedRange = range
        editorCommand.send(.select(range))
    }

    private func replaceCurrent() {
        let nsText = text as NSString
        if selectedRange.length > 0,
           nsText.substring(with: selectedRange).localizedCaseInsensitiveCompare(findText) == .orderedSame {
            replaceRange(selectedRange, with: replacementText)
            selectedRange = NSRange(location: selectedRange.location + (replacementText as NSString).length, length: 0)
        } else {
            find(backwards: false)
        }
    }

    private func replaceAll() {
        guard !findText.isEmpty else { return }
        text = text.replacingOccurrences(of: findText, with: replacementText, options: .caseInsensitive)
    }

    private func codeSymbols(_ language: CodeLanguage) -> [(offset: Int, label: String)] {
        language.symbols(in: text)
    }

    private func run(_ language: CodeLanguage) async {
        isRunning = true
        defer { isRunning = false; runCancellation = nil }
        guard let toolName = language.runnableToolName else { return }
        guard let runner = ToolRunnerRegistry.shared.runner(named: toolName) else {
            runOutput = CodeRunOutput(title: "无法运行", text: "此构建未包含 \(language.displayName) 运行时。")
            return
        }
        do {
            if toolName == "exec.shell", (relativePath as NSString).pathExtension.lowercased() != "sh" {
                runOutput = CodeRunOutput(title: "不支持的 Shell 方言", text: "本地运行使用 POSIX sh；bash、zsh、fish 脚本请先转换，或在远程主机运行。")
                return
            }
            var values: [String: Any] = ["script": text, "timeout": 30, "maxOutputBytes": 262_144]
            if toolName == "exec.shell" {
                let directory = (relativePath as NSString).deletingLastPathComponent
                values["cwd"] = directory.isEmpty ? "." : directory
            }
            let arguments = try JSONSerialization.data(withJSONObject: values)
            let cancellation = CancellationToken()
            runCancellation = cancellation
            let context = ToolContext(
                runID: UUID(),
                toolCallID: "user.editor.run." + UUID().uuidString,
                scope: .local,
                workspaceRootURL: center.currentRootURL,
                cancellation: cancellation
            )
            let output = try await runner.execute(argumentsJSON: arguments, context: context)
            runOutput = CodeRunOutput(
                title: output.exitStatus == 0 ? "运行完成" : "运行失败",
                text: output.summary
            )
        } catch {
            runOutput = CodeRunOutput(title: "运行失败", text: error.localizedDescription)
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
            let snapshot = try service.editConflict(path: relativePath, base: nil, draft: "")
            editService = service
            text = snapshot.current
            originalText = snapshot.current
            baseMtime = snapshot.currentMtime
            baseSHA256 = snapshot.currentSHA256
            loadError = nil
            onDirtyChange(false)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func resolve(_ review: WorkspaceEditConflict, content: String) async {
        guard let editService else { return }
        text = content // Retain the selected resolution even if a later save fails.
        isSaving = true
        defer { isSaving = false }
        do {
            let outcome = try editService.resolveConflict(review, content: content)
            originalText = content; baseMtime = outcome.mtime; baseSHA256 = outcome.sha256
            editConflict = nil; saveError = nil
            onDirtyChange(false); onSaved()
        } catch let error as WorkspaceToolError {
            if case .conflict = error {
                do { editConflict = try editService.editConflict(path: relativePath, base: review.current, draft: content, preserveDraft: true) }
                catch { saveError = error.localizedDescription }
            } else { saveError = error.localizedDescription }
        } catch { saveError = error.localizedDescription }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            guard let editService else { throw CocoaError(.fileWriteNoPermission) }
            let outcome = try editService.writeFile(
                relativePath, content: text,
                expectedMtime: baseMtime,
                expectedSHA256: baseSHA256
            )
            originalText = text
            baseMtime = outcome.mtime
            baseSHA256 = outcome.sha256
            saveError = nil
            onDirtyChange(false)
            onSaved()
            if !embeddedInIDE {
                dismiss()
            }
        } catch let error as WorkspaceToolError {
            if case .conflict = error {
                do { editConflict = try editService?.editConflict(path: relativePath, base: originalText, draft: text, preserveDraft: true) }
                catch { saveError = error.localizedDescription }
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


private struct CodeRunOutput: Identifiable {
    let id = UUID()
    var title: String
    var text: String
}
#endif
