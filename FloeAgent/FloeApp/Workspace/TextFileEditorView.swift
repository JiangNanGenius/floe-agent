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
        defer { isRunning = false }
        guard let toolName = language.runnableToolName else { return }
        guard let runner = ToolRunnerRegistry.shared.runner(named: toolName) else {
            runOutput = CodeRunOutput(title: "无法运行", text: "此构建未包含 \(language.displayName) 运行时。")
            return
        }
        do {
            let arguments = try JSONSerialization.data(withJSONObject: [
                "script": text,
                "timeout": 30,
                "maxOutputBytes": 262_144
            ])
            let context = ToolContext(
                runID: UUID(),
                approvalGrantID: UUID(),
                scope: .local,
                workspaceRootURL: center.currentRootURL,
                cancellation: CancellationToken()
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
            let content = try service.readFileForEditing(relativePath)
            let metadata = try service.metadata(relativePath)
            text = content.text
            originalText = content.text
            baseMtime = metadata.mtime
            baseSHA256 = metadata.sha256
            loadError = nil
            onDirtyChange(false)
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
            onDirtyChange(false)
            onSaved()
            if !embeddedInIDE {
                dismiss()
            }
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

private enum CodeLanguage: Equatable {
    case swift
    case python
    case javascript(displayName: String)
    case json
    case shell
    case cFamily(displayName: String)
    case markup(displayName: String)
    case stylesheet
    case configuration(displayName: String)
    case sql
    case generic(displayName: String)

    init?(relativePath: String) {
        let ext = WorkspaceFileType.pathExtension(for: relativePath)
        switch ext {
        case "swift": self = .swift
        case "py": self = .python
        case "js", "mjs", "cjs", "jsx": self = .javascript(displayName: "JavaScript")
        case "ts", "tsx": self = .javascript(displayName: "TypeScript")
        case "json", "jsonc": self = .json
        case "sh", "bash", "zsh", "fish": self = .shell
        case "c", "h", "m": self = .cFamily(displayName: "C / Objective-C")
        case "mm", "cc", "cpp", "cxx", "hpp": self = .cFamily(displayName: "C++")
        case "html", "htm", "xml", "vue", "svelte": self = .markup(displayName: ext.uppercased())
        case "css", "scss": self = .stylesheet
        case "yaml", "yml": self = .configuration(displayName: "YAML")
        case "toml": self = .configuration(displayName: "TOML")
        case "properties", "ini", "conf": self = .configuration(displayName: "Configuration")
        case "sql": self = .sql
        case "rs": self = .generic(displayName: "Rust")
        case "go": self = .generic(displayName: "Go")
        case "java": self = .generic(displayName: "Java")
        case "kt", "kts": self = .generic(displayName: "Kotlin")
        case "rb": self = .generic(displayName: "Ruby")
        case "php": self = .generic(displayName: "PHP")
        case "pl": self = .generic(displayName: "Perl")
        case "lua": self = .generic(displayName: "Lua")
        case "dart": self = .generic(displayName: "Dart")
        case "gradle": self = .generic(displayName: "Gradle")
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .swift: "Swift"
        case .python: "Python"
        case .javascript(let displayName), .cFamily(let displayName),
             .markup(let displayName), .configuration(let displayName),
             .generic(let displayName): displayName
        case .json: "JSON"
        case .shell: "Shell"
        case .stylesheet: "CSS"
        case .sql: "SQL"
        }
    }

    var icon: String {
        switch self {
        case .swift: "swift"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .json, .javascript: "curlybraces"
        case .shell: "terminal"
        default: "doc.text"
        }
    }

    var keywords: [String] {
        switch self {
        case .swift:
            return ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "isolated", "let", "nil", "nonisolated", "open", "private", "protocol", "public", "repeat", "return", "self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"]
        case .python:
            return ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case .javascript:
            return ["async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "let", "new", "null", "of", "private", "protected", "public", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with", "yield"]
        case .cFamily:
            return ["auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default", "delete", "do", "double", "else", "enum", "extern", "false", "float", "for", "if", "import", "include", "inline", "int", "long", "namespace", "new", "nullptr", "private", "protected", "public", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "true", "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while"]
        case .shell:
            return ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "readonly", "select", "then", "until", "while"]
        case .sql:
            return ["ALTER", "AND", "AS", "ASC", "BEGIN", "BY", "CASE", "CREATE", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "FROM", "GROUP", "HAVING", "IN", "INDEX", "INSERT", "INTO", "IS", "JOIN", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "SELECT", "TABLE", "THEN", "UNION", "UPDATE", "VALUES", "WHEN", "WHERE"]
        default:
            return []
        }
    }

    fileprivate var usesHashComments: Bool {
        switch self {
        case .python, .shell, .configuration: true
        default: false
        }
    }

    fileprivate var usesMarkupComments: Bool {
        if case .markup = self { return true }
        return false
    }

    fileprivate var runnableToolName: String? {
        switch self {
        case .python: "exec.localPython"
        case .javascript: "exec.javascript"
        default: nil
        }
    }

    func symbols(in source: String) -> [(offset: Int, label: String)] {
        let pattern: String
        let nameGroup: Int
        switch self {
        case .python:
            pattern = #"(?m)^\s*(?:async\s+)?(class|def)\s+([A-Za-z_][A-Za-z0-9_]*)"#
            nameGroup = 2
        case .javascript:
            pattern = #"(?m)^\s*(?:export\s+)?(?:async\s+)?(class|function|interface)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#
            nameGroup = 2
        case .swift:
            pattern = #"(?m)^\s*(?:(?:public|private|internal|fileprivate|open|final|static|nonisolated)\s+)*(actor|class|struct|enum|protocol|func)\s+([A-Za-z_][A-Za-z0-9_]*)"#
            nameGroup = 2
        default:
            return []
        }
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsSource = source as NSString
        return expression.matches(in: source, range: NSRange(location: 0, length: nsSource.length)).compactMap { match in
            guard match.numberOfRanges > nameGroup,
                  match.range(at: 1).location != NSNotFound,
                  match.range(at: nameGroup).location != NSNotFound else { return nil }
            let kind = nsSource.substring(with: match.range(at: 1))
            let name = nsSource.substring(with: match.range(at: nameGroup))
            return (match.range.location, "\(kind) \(name)")
        }
    }
}

private struct CodeRunOutput: Identifiable {
    let id = UUID()
    var title: String
    var text: String
}

private struct CodeEditorCommand: Equatable {
    enum Kind: Equatable {
        case none
        case undo
        case redo
        case select(NSRange)
    }
    var revision = 0
    var kind: Kind = .none

    mutating func send(_ kind: Kind) {
        revision += 1
        self.kind = kind
    }
}

/// UIKit-backed code editor with a TextKit line-number gutter and bounded
/// syntax highlighting. Editing remains native, so keyboard selection,
/// hardware-keyboard shortcuts and the undo manager keep standard behavior.
private struct StructuredCodeTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    let language: CodeLanguage
    @Binding var command: CodeEditorCommand

    func makeUIView(context: Context) -> LineNumberTextView {
        let view = LineNumberTextView()
        view.backgroundColor = .clear
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.isEditable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.alwaysBounceHorizontal = true
        view.showsHorizontalScrollIndicator = true
        view.delegate = context.coordinator
        view.text = text
        context.coordinator.highlight(view)
        return view
    }

    func updateUIView(_ view: LineNumberTextView, context: Context) {
        if view.text != text {
            let selection = view.selectedRange
            view.text = text
            context.coordinator.highlight(view)
            view.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
        }
        if context.coordinator.lastCommandRevision != command.revision {
            context.coordinator.lastCommandRevision = command.revision
            switch command.kind {
            case .none: break
            case .undo: view.undoManager?.undo()
            case .redo: view.undoManager?.redo()
            case .select(let range):
                view.selectedRange = range
                view.scrollRangeToVisible(range)
                view.becomeFirstResponder()
            }
        }
        view.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: StructuredCodeTextView
        var isHighlighting = false
        var lastCommandRevision = 0

        init(_ parent: StructuredCodeTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard !isHighlighting else { return }
            parent.text = textView.text
            parent.selectedRange = textView.selectedRange
            if let view = textView as? LineNumberTextView { highlight(view) }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selectedRange = textView.selectedRange
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? LineNumberTextView)?.setNeedsDisplay()
        }

        func highlight(_ view: LineNumberTextView) {
            guard !isHighlighting else { return }
            isHighlighting = true
            defer { isHighlighting = false }
            let source = view.text ?? ""
            let selection = view.selectedRange
            let full = NSRange(location: 0, length: (source as NSString).length)
            let baseAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .regular),
                .foregroundColor: UIColor.label
            ]
            let attributed = NSMutableAttributedString(
                string: source,
                attributes: baseAttributes
            )
            // Keep typing responsive for unusually large source files. They
            // retain the editor, line numbers and horizontal scrolling while
            // syntax color is intentionally bounded to 512 Ki UTF-16 units.
            guard full.length <= 512 * 1024 else {
                view.attributedText = attributed
                view.typingAttributes = baseAttributes
                view.selectedRange = selection
                view.setNeedsDisplay()
                return
            }
            func apply(_ pattern: String, color: UIColor, options: NSRegularExpression.Options = []) {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
                regex.enumerateMatches(in: source, range: full) { match, _, _ in
                    if let range = match?.range { attributed.addAttribute(.foregroundColor, value: color, range: range) }
                }
            }
            let words = parent.language.keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            if !words.isEmpty {
                apply("\\b(?:\(words))\\b", color: .systemPurple, options: parent.language == .sql ? [.caseInsensitive] : [])
            }
            apply(#"\b(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?)\b"#, color: .systemBlue)
            apply(#"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'"#, color: .systemRed)
            if parent.language.usesMarkupComments {
                apply(#"<!--[\s\S]*?-->"#, color: .systemGreen)
            } else if parent.language.usesHashComments {
                apply(#"(?m)#.*$"#, color: .systemGreen)
            } else {
                apply(#"(?m)//.*$|/\*[\s\S]*?\*/"#, color: .systemGreen)
            }
            view.attributedText = attributed
            view.typingAttributes = baseAttributes
            view.selectedRange = selection
            view.setNeedsDisplay()
        }
    }
}

private final class LineNumberTextView: UITextView {
    private let gutterWidth: CGFloat = 44

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        textContainerInset = UIEdgeInsets(top: 12, left: gutterWidth + 8, bottom: 12, right: 12)
        textContainer.widthTracksTextView = false
        textContainer.size = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        UIColor.secondarySystemBackground.setFill()
        context.fill(CGRect(x: contentOffset.x, y: rect.minY, width: gutterWidth, height: rect.height))

        let glyphRange = layoutManager.glyphRange(forBoundingRect: bounds, in: textContainer)
        guard glyphRange.length > 0 else {
            context.restoreGState()
            return
        }
        let firstCharacter = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        let firstPrefix = (text as NSString).substring(to: min(firstCharacter, (text as NSString).length))
        var line = firstPrefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            var lineGlyphRange = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange)
            let value = "\(line)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
            let size = value.size(withAttributes: attributes)
            value.draw(
                at: CGPoint(
                    x: contentOffset.x + gutterWidth - size.width - 7,
                    y: fragment.minY + textContainerInset.top
                ),
                withAttributes: attributes
            )
            line += 1
            glyphIndex = NSMaxRange(lineGlyphRange)
        }
        context.restoreGState()
    }
}
#endif
