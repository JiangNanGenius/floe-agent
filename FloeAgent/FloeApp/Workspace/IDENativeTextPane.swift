// FloeApp — Native text/code editing pane for the workspace IDE.
//
// SPDX-License-Identifier: MPL-2.0
//
// The IDE's text/code editor: multi-file tabs over `IDENativeTextWorkspace`
// buffers, line-numbered editing with bounded highlighting, find/replace,
// standard selection/IME/undo behavior and conflict review. It is the only
// text editor in the IDE (there is no Web/Monaco text kernel); every buffer
// stays alive for the IDE session, so switching tabs never loses unsaved text.
//
// The pane owns no file I/O of its own: load/save/conflict all go through the
// shared `WorkspaceFileService` the inspector and the run flow read.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import FloeWorkspace

/// Per-file editor UI state (command channel, selection, find bar). Kept out
/// of the model so the buffer stays Foundation-only and testable.
@MainActor
@Observable
final class IDENativeEditorUIState {
    var command = CodeEditorCommand()
    var selection = NSRange(location: 0, length: 0)
    var findText = ""
    var replacementText = ""
    var showsFind = false
    /// Markdown-only view state; the rendered preview reads the same unsaved
    /// buffer text, never a second document.
    var markdownPreview = false
    var showsMarkdownOutline = false
}

/// Owns the native workspace plus one editor UI state per open buffer.
@MainActor
@Observable
final class IDENativeTextPaneModel {
    let workspace: IDENativeTextWorkspace
    /// Not observed: the per-file `IDENativeEditorUIState` objects are
    /// observed directly by their editor views.
    @ObservationIgnored private var editorStates: [String: IDENativeEditorUIState] = [:]

    init(workspace: IDENativeTextWorkspace) {
        self.workspace = workspace
    }

    func editorState(for relativePath: String) -> IDENativeEditorUIState {
        if let existing = editorStates[relativePath] { return existing }
        let created = IDENativeEditorUIState()
        editorStates[relativePath] = created
        return created
    }

    /// Drops editor UI state for buffers that no longer exist (closed or
    /// evicted) so a closed tab cannot pin its undo stack forever.
    func pruneEditorStates(keeping paths: [String]) {
        let live = Set(paths)
        for key in editorStates.keys where !live.contains(key) {
            editorStates.removeValue(forKey: key)
        }
    }
}

struct IDENativeTextPane: View {
    let model: IDENativeTextPaneModel
    /// The IDE's code tab is showing this pane.
    var isActive: Bool
    var onRun: () -> Void
    var onSaved: () -> Void
    var onRequestClose: (String) -> Void

    private var workspace: IDENativeTextWorkspace { model.workspace }

    var body: some View {
        VStack(spacing: 0) {
            if workspace.buffers.isEmpty {
                emptyState
            } else {
                tabStrip
                Divider()
                ZStack {
                    ForEach(workspace.buffers, id: \.relativePath) { buffer in
                        IDENativeEditorTabView(
                            buffer: buffer,
                            state: model.editorState(for: buffer.relativePath),
                            isActiveTab: workspace.activePath == buffer.relativePath,
                            isPaneActive: isActive,
                            onRun: onRun,
                        )
                        .opacity(workspace.activePath == buffer.relativePath ? 1 : 0)
                        .allowsHitTesting(workspace.activePath == buffer.relativePath)
                        .accessibilityHidden(workspace.activePath != buffer.relativePath)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(FloeTheme.readingSurface)
        .onChange(of: workspace.openPaths) { _, paths in
            model.pruneEditorStates(keeping: paths)
        }
        .sheet(item: conflictBinding) { review in
            TextConflictReviewView(conflict: review, onResolve: { content in
                await model.workspace.resolveConflict(path: review.path, content: content)
                onSaved()
            }, onCancel: {
                model.workspace.buffer(review.path)?.conflict = nil
            }).id(review.id)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(IDELanguageRunText.t("未打开文件", "No file open"), systemImage: "doc.text")
        } description: {
            Text(IDELanguageRunText.t(
                "从文件侧边栏或文件树打开一个文本/代码文件。",
                "Open a text or code file from the file sidebar or the file tree."
            ))
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(workspace.buffers, id: \.relativePath) { buffer in
                    nativeTab(buffer)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .background(FloeTheme.chromeMaterial)
        .accessibilityIdentifier("workspace.ide.nativeTabs")
    }

    private func nativeTab(_ buffer: IDENativeTextBuffer) -> some View {
        let active = workspace.activePath == buffer.relativePath
        return HStack(spacing: 6) {
            Button {
                workspace.activate(buffer.relativePath)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: CodeLanguage(relativePath: buffer.relativePath)?.icon ?? "doc.text")
                        .font(.caption)
                    Text(buffer.title)
                        .lineLimit(1)
                    if buffer.isDirty {
                        Circle().fill(FloeTheme.primary).frame(width: 6, height: 6)
                            .accessibilityLabel(IDELanguageRunText.t("有未保存的修改", "Unsaved changes"))
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: FloeTheme.minimumTarget)
                .background(active ? FloeTheme.primary.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace.ide.nativeTab")

            Button {
                onRequestClose(buffer.relativePath)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(IDELanguageRunText.t("关闭标签", "Close tab"))
            .accessibilityIdentifier("workspace.ide.nativeTab.close")
        }
        .padding(.leading, 2)
        .padding(.trailing, 2)
        .overlay(alignment: .bottom) {
            if active {
                Rectangle().fill(FloeTheme.primary).frame(height: 2)
            }
        }
    }

    /// The first unresolved conflict, if any. The setter clears the review the
    /// sheet just dismissed so a cancelled review stays cancelled.
    private var conflictBinding: Binding<WorkspaceEditConflict?> {
        Binding(
            get: { workspace.pendingConflict()?.conflict },
            set: { newValue in
                guard newValue == nil, let path = workspace.pendingConflict()?.path else { return }
                workspace.buffer(path)?.conflict = nil
            }
        )
    }
}

/// One open buffer's editor: editor + find/replace + status + compact actions.
/// The view stays mounted while its tab is backgrounded so the undo stack and
/// selection survive tab switches.
private struct IDENativeEditorTabView: View {
    @Bindable var buffer: IDENativeTextBuffer
    @Bindable var state: IDENativeEditorUIState
    let isActiveTab: Bool
    let isPaneActive: Bool
    var onRun: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// Compact (iPhone) shows one concise status line: saved state and the
    /// cursor location only, so the IDE's own status bar can coexist below
    /// without wrapping. Verbose labels stay on regular widths and remain
    /// reachable from the toolbars on compact.
    private var compactStatus: Bool { sizeClass == .compact }

    private var language: CodeLanguage? { CodeLanguage(relativePath: buffer.relativePath) }

    /// Persisted editor zoom; 0 follows the Dynamic Type body baseline. The
    /// value is shared by every buffer and survives tab switches/reopen.
    @AppStorage("workspace.ide.editorFontSize") private var storedEditorFontSize = 0.0
    private var editorFontSize: CGFloat { IDEEditorFontSize.resolved(CGFloat(storedEditorFontSize)) }
    private var isMarkdown: Bool { WorkspaceFileType.isMarkdown(buffer.relativePath) }
    private var compactOutlineBinding: Binding<Bool> {
        Binding(
            get: { state.showsMarkdownOutline && compactStatus },
            set: { state.showsMarkdownOutline = $0 }
        )
    }

    private var markdownBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Picker("", selection: Binding(
                    get: { state.markdownPreview },
                    set: { state.markdownPreview = $0 }
                )) {
                    Text(IDELanguageRunText.t("源码", "Source")).tag(false)
                    Text(IDELanguageRunText.t("预览", "Preview")).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 168)
                .frame(minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("workspace.ide.markdown.mode")
                markdownButton("H1", identifier: "workspace.ide.markdown.h1") { applyPrefix("# ") }
                markdownButton("H2", identifier: "workspace.ide.markdown.h2") { applyPrefix("## ") }
                markdownButton("H3", identifier: "workspace.ide.markdown.h3") { applyPrefix("### ") }
                markdownButton(icon: "list.bullet", label: IDELanguageRunText.t("列表", "List"), identifier: "workspace.ide.markdown.list") { applyPrefix("- ") }
                markdownButton(icon: "list.number", label: IDELanguageRunText.t("有序列表", "Ordered list"), identifier: "workspace.ide.markdown.ordered") { applyPrefix("1. ") }
                markdownButton(icon: "text.quote", label: IDELanguageRunText.t("引用", "Quote"), identifier: "workspace.ide.markdown.quote") { applyPrefix("> ") }
                markdownButton(icon: "chevron.left.forwardslash.chevron.right", label: IDELanguageRunText.t("代码块", "Code block"), identifier: "workspace.ide.markdown.code") { applyCodeBlock() }
                markdownButton(icon: "link", label: IDELanguageRunText.t("链接", "Link"), identifier: "workspace.ide.markdown.link") { applyWrap(prefix: "[", suffix: "](url)") }
                markdownButton(icon: "tablecells", label: IDELanguageRunText.t("表格", "Table"), identifier: "workspace.ide.markdown.table") { applyTable() }
                markdownButton(
                    icon: "list.bullet.indent",
                    label: IDELanguageRunText.t("大纲", "Outline"),
                    identifier: "workspace.ide.markdown.outline",
                    active: state.showsMarkdownOutline
                ) { state.showsMarkdownOutline.toggle() }
            }
            .padding(.horizontal, 8)
        }
        .frame(minHeight: FloeTheme.minimumTarget)
        .background(FloeTheme.chromeMaterial)
        .accessibilityIdentifier("workspace.ide.markdown.bar")
    }

    @ViewBuilder
    private func markdownButton(
        _ title: String? = nil,
        icon: String? = nil,
        label: String = "",
        identifier: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let icon { Image(systemName: icon) } else if let title { Text(title).font(.caption.weight(.semibold)) }
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .background(active ? FloeTheme.primary.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title ?? label)
        .accessibilityIdentifier(identifier)
    }

    private var markdownPreview: some View {
        ScrollView {
            MarkdownRendererView(source: buffer.text)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(FloeTheme.readingSurface)
        .accessibilityIdentifier("workspace.ide.markdown.preview")
    }

    private var markdownOutline: some View {
        let headings = IDEMarkdownOutline.headings(in: buffer.text)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if headings.isEmpty {
                    Text(IDELanguageRunText.t("没有标题", "No headings"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                ForEach(headings) { heading in
                    Button {
                        jump(to: heading)
                    } label: {
                        Text(heading.displayTitle)
                            .font(.system(size: max(11, 15 - CGFloat(heading.level - 1))))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, CGFloat(heading.level - 1) * 12)
                            .padding(.horizontal, 8)
                            .frame(minHeight: FloeTheme.minimumTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace.ide.markdown.heading.\(heading.id)")
                }
            }
        }
        .background(FloeTheme.sidebarSurface)
        .accessibilityIdentifier("workspace.ide.markdown.outline")
    }

    /// Outline navigation targets the native source editor (the shared
    /// Markdown renderer exposes no per-block anchors); from preview it
    /// returns to source so the caret lands on the heading.
    private func jump(to heading: IDEMarkdownHeading) {
        state.markdownPreview = false
        let range = IDEMarkdownOutline.selectionRange(for: heading, in: buffer.text)
        state.selection = range
        state.command.send(.select(range))
    }

    private func applyWrap(prefix: String, suffix: String) {
        let result = IDEMarkdownEditing.wrap(text: buffer.text, selection: state.selection, prefix: prefix, suffix: suffix)
        buffer.text = result.text
        state.selection = result.selection
    }

    private func applyPrefix(_ marker: String) {
        let result = IDEMarkdownEditing.prefixLines(text: buffer.text, selection: state.selection, marker: marker)
        buffer.text = result.text
        state.selection = result.selection
    }

    private func applyTable() {
        let result = IDEMarkdownEditing.tableScaffold(text: buffer.text, selection: state.selection)
        buffer.text = result.text
        state.selection = result.selection
    }

    private func applyCodeBlock() {
        let result = IDEMarkdownEditing.codeBlock(text: buffer.text, selection: state.selection)
        buffer.text = result.text
        state.selection = result.selection
    }

    var body: some View {
        VStack(spacing: 0) {
            if let loadError = buffer.loadError, !buffer.isLoaded {
                loadFailureState(loadError)
            } else {
                if isMarkdown { markdownBar }
                HStack(spacing: 0) {
                    if isMarkdown, state.showsMarkdownOutline, !compactStatus {
                        markdownOutline
                            .frame(width: 200)
                        Divider()
                    }
                    Group {
                        if isMarkdown, state.markdownPreview {
                            markdownPreview
                        } else {
                            StructuredCodeTextView(
                                text: $buffer.text,
                                selectedRange: $state.selection,
                                language: language,
                                command: $state.command,
                                fontSize: editorFontSize,
                                accessibilityIdentifier: "workspace.ide.nativeEditor"
                            )
                            .background(FloeTheme.readingSurface)
                            .padding(.horizontal, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if state.showsFind { findReplaceBar }
                statusBar
            }
        }
        .sheet(isPresented: compactOutlineBinding) {
            NavigationStack {
                markdownOutline
                    .navigationTitle(IDELanguageRunText.t("大纲", "Outline"))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .alert(
            IDELanguageRunText.t("保存失败", "Save failed"),
            isPresented: Binding(
                get: { buffer.saveError != nil },
                set: { if !$0 { buffer.saveError = nil } }
            )
        ) {
            Button("action.done", role: .cancel) { buffer.saveError = nil }
        } message: {
            Text(buffer.saveError ?? "")
        }
    }

    private func loadFailureState(_ message: String) -> some View {
        ContentUnavailableView {
            Label(IDELanguageRunText.t("无法在此编辑", "Cannot edit here"), systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                Text(message)
                if let reason = buffer.fallbackReason {
                    Text(fallbackExplanation(reason))
                        .font(.footnote)
                }
            }
        }
    }

    private func fallbackExplanation(_ reason: IDENativeTextFallbackReason) -> String {
        switch reason {
        case .nonTextKind(let kind):
            return IDELanguageRunText.t(
                "该文件类型由\(kind.rawValue)原生界面处理。",
                "This file type is handled by its native \(kind.rawValue) surface."
            )
        case .binaryContent:
            return IDELanguageRunText.t("文件不是 UTF-8 文本。", "The file is not UTF-8 text.")
        case .exceedsNativeLimit(let limit):
            let mebibytes = Double(limit) / (1024 * 1024)
            return IDELanguageRunText.t(
                "文件超过 \(String(format: "%.0f", mebibytes)) MiB 文本策略上限。",
                "The file exceeds the \(String(format: "%.0f", mebibytes)) MiB text policy."
            )
        }
    }

    private var findReplaceBar: some View {
        VStack(spacing: 6) {
            HStack {
                TextField(IDELanguageRunText.t("查找", "Find"), text: $state.findText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("workspace.ide.nativeFind")
                Button(IDELanguageRunText.t("上一个", "Previous")) { find(backwards: true) }
                    .disabled(state.findText.isEmpty)
                Button(IDELanguageRunText.t("下一个", "Next")) { find(backwards: false) }
                    .disabled(state.findText.isEmpty)
            }
            HStack {
                TextField(IDELanguageRunText.t("替换为", "Replace"), text: $state.replacementText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("workspace.ide.nativeReplace")
                Button(IDELanguageRunText.t("替换", "Replace")) { replaceCurrent() }
                    .disabled(state.findText.isEmpty)
                Button(IDELanguageRunText.t("全部替换", "Replace all")) { replaceAll() }
                    .disabled(state.findText.isEmpty)
                    .accessibilityIdentifier("workspace.ide.nativeReplaceAll")
            }
            HStack(spacing: 8) {
                Button {
                    state.command.send(.undo)
                } label: {
                    Label(IDELanguageRunText.t("撤销", "Undo"), systemImage: "arrow.uturn.backward")
                }
                .accessibilityIdentifier("workspace.ide.nativeUndo")
                Button {
                    state.command.send(.redo)
                } label: {
                    Label(IDELanguageRunText.t("重做", "Redo"), systemImage: "arrow.uturn.forward")
                }
                .accessibilityIdentifier("workspace.ide.nativeRedo")
                Spacer(minLength: 0)
                Button {
                    state.showsFind = false
                } label: {
                    Label(IDELanguageRunText.t("关闭查找", "Close find"), systemImage: "xmark")
                }
            }
            .font(.footnote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FloeTheme.chromeMaterial)
        .accessibilityIdentifier("workspace.ide.nativeFindBar")
    }

    private var statusBar: some View {
        HStack(spacing: compactStatus ? 8 : 12) {
            if compactStatus {
                // One line on iPhone: saved state first, then location.
                if buffer.isDirty {
                    Label(IDELanguageRunText.t("未保存", "Unsaved"), systemImage: "circle.fill")
                        .foregroundStyle(FloeTheme.pending)
                        .labelStyle(.titleAndIcon)
                        .accessibilityIdentifier("workspace.ide.nativeSaveState")
                } else if buffer.isLoaded {
                    Label(IDELanguageRunText.t("已保存", "Saved"), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .accessibilityIdentifier("workspace.ide.nativeSaveState")
                }
                Text(cursorDescription)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("workspace.ide.nativeCursor")
                Spacer(minLength: 0)
                zoomControls
            } else {
                if let language {
                    Label(language.displayName, systemImage: language.icon)
                } else {
                    Label(IDELanguageRunText.t("纯文本", "Plain text"), systemImage: "doc.text")
                }
                Text(cursorDescription)
                    .accessibilityIdentifier("workspace.ide.nativeCursor")
                Spacer(minLength: 0)
                Button {
                    state.showsFind.toggle()
                } label: {
                    Label(IDELanguageRunText.t("查找替换", "Find & replace"), systemImage: "magnifyingglass")
                }
                .accessibilityIdentifier("workspace.ide.nativeFindToggle")
                .modifier(CommandFShortcut(enabled: isActiveTab && isPaneActive))

                if language?.runnableToolName != nil {
                    Button {
                        onRun()
                    } label: {
                        Label(IDELanguageRunText.t("运行", "Run"), systemImage: "play.fill")
                    }
                    .disabled(buffer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("workspace.ide.nativeRun")
                }
                if buffer.isDirty {
                    Label(IDELanguageRunText.t("未保存", "Unsaved"), systemImage: "circle.fill")
                        .foregroundStyle(FloeTheme.pending)
                        .accessibilityIdentifier("workspace.ide.nativeSaveState")
                } else if buffer.isLoaded {
                    Label(IDELanguageRunText.t("已保存", "Saved"), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("workspace.ide.nativeSaveState")
                }
                Spacer(minLength: 0)
                zoomControls
            }
        }
        .font(FloeTheme.Typography.metadata)
        .lineLimit(1)
        .minimumScaleFactor(compactStatus ? 0.75 : 1)
        .padding(.horizontal, compactStatus ? 10 : 12)
        .padding(.vertical, 6)
        .background(FloeTheme.chromeMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace.ide.nativeStatus")
    }

    /// Editor text zoom with 44pt targets. The persisted preference is read
    /// by every buffer and survives tab switches and reopen; the resolved
    /// size follows the Dynamic Type body baseline until the user zooms.
    @ViewBuilder
    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                setZoom(IDEEditorFontSize.decreased(CGFloat(storedEditorFontSize)))
            } label: {
                Image(systemName: "textformat.size.smaller")
                    .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!IDEEditorFontSize.canDecrease(CGFloat(storedEditorFontSize)))
            .accessibilityLabel(IDELanguageRunText.t("缩小编辑器字体", "Decrease editor font size"))
            .accessibilityIdentifier("workspace.ide.editorFont.decrease")
            .keyboardShortcut("-", modifiers: .command)

            Button {
                setZoom(IDEEditorFontSize.increased(CGFloat(storedEditorFontSize)))
            } label: {
                Image(systemName: "textformat.size.larger")
                    .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!IDEEditorFontSize.canIncrease(CGFloat(storedEditorFontSize)))
            .accessibilityLabel(IDELanguageRunText.t("放大编辑器字体", "Increase editor font size"))
            .accessibilityIdentifier("workspace.ide.editorFont.increase")
            .keyboardShortcut("=", modifiers: .command)
        }
    }

    private func setZoom(_ value: CGFloat) {
        storedEditorFontSize = Double(min(max(value, IDEEditorFontSize.bounds.lowerBound), IDEEditorFontSize.bounds.upperBound))
    }

    private var cursorDescription: String {
        let position = IDENativeTextEditing.lineAndColumn(in: buffer.text, at: state.selection.location)
        return IDELanguageRunText.t(
            "行 \(position.line)，列 \(position.column)",
            "Line \(position.line), Col \(position.column)"
        )
    }

    private func find(backwards: Bool) {
        guard let match = IDENativeTextEditing.find(
            in: buffer.text, query: state.findText, backwards: backwards, from: state.selection
        ) else { return }
        state.selection = match
        state.command.send(.select(match))
    }

    private func replaceCurrent() {
        let result = IDENativeTextEditing.replaceCurrent(
            in: buffer.text, query: state.findText, replacement: state.replacementText, selection: state.selection
        )
        if result.replaced { buffer.text = result.text }
        state.selection = result.selection
        state.command.send(.select(result.selection))
    }

    private func replaceAll() {
        let result = IDENativeTextEditing.replaceAll(
            in: buffer.text, query: state.findText, replacement: state.replacementText, selection: state.selection
        )
        guard result.replaced else { return }
        buffer.text = result.text
        state.selection = result.selection
        state.command.send(.select(result.selection))
    }
}

/// Registers Cmd-F only while this editor's tab is the visible one; a hidden
/// editor in the same ZStack must not also claim the shortcut.
private struct CommandFShortcut: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut("f", modifiers: .command)
        } else {
            content
        }
    }
}
#endif
