// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameCore
import FloeGameEditingCore

/// Root shell for a project-bound editing session: file sidebar, editor
/// detail, save/undo/redo bar, conflict banner and draft recovery.
/// Standalone qualification shell. The actual App reuses its existing IDE
/// files/Git and embeds GameVisualEditorPanel for selected visual content.
public struct GameEditingSessionView: View {
    @ObservedObject public var session: GameEditingSession
    public let onClose: (@MainActor () -> Void)?
    /// Optional engine-specific visual map editor (for example the RPG
    /// tileset editor). The App host supplies this to avoid a package cycle;
    /// without it the generic color-GID editor remains the fallback.
    public var tileMapEditorFactory: (@MainActor (GameEditingSession, GameRelativePath) -> AnyView)?
    @Environment(\.gameEditLocale) private var locale
    @State private var selection: GameRelativePath?
    @State private var sidebarTab: SidebarTab = .files
    @State private var errorPresentation: GameEditIssue?
    @State private var addAssetRequest = false
    @State private var importProjectRequest = false

    public init(session: GameEditingSession, onClose: (@MainActor () -> Void)? = nil,
                tileMapEditorFactory: (@MainActor (GameEditingSession, GameRelativePath) -> AnyView)? = nil) {
        self.session = session; self.onClose = onClose
        self.tileMapEditorFactory = tileMapEditorFactory
    }

    enum SidebarTab: String, CaseIterable, Sendable {
        case files, history
        var title: GameEditCopy {
            switch self {
            case .files: return GameEditCopy("Files", "文件")
            case .history: return GameEditCopy("History", "历史")
            }
        }
    }

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("", selection: $sidebarTab) {
                    ForEach(SidebarTab.allCases, id: \.self) { tab in
                        EditText(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                switch sidebarTab {
                case .files:
                    List(selection: $selection) {
                        if session.existingPaths().isEmpty {
                            ContentUnavailableView {
                                EditText(GameEditCopy("Empty project", "空项目"))
                            } description: {
                                EditText(GameEditCopy(
                                    "Import the original project or game files first; recognition and organization come later.",
                                    "请先导入原始项目或游戏文件；识别与整理稍后进行。"))
                            } actions: {
                                VStack(spacing: 8) {
                                    if session.projectImportHost != nil {
                                        EditButton { importProjectRequest = true } label: {
                                            Label { EditText(.importProject) } icon: { Image(systemName: "shippingbox") }
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                    EditButton { addAssetRequest = true } label: {
                                        Label { EditText(.addAsset) } icon: { Image(systemName: "doc.badge.plus") }
                                    }
                                }
                            }
                        }
                        ForEach(session.existingPaths(), id: \.self) { path in
                            Label {
                                HStack {
                                    Text(path.value)
                                    if session.isDocumentDirty(at: path) {
                                        Image(systemName: "circle.fill")
                                            .font(.system(size: 7))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            } icon: {
                                Image(systemName: iconName(for: path))
                            }
                            .tag(Optional(path))
                        }
                        .onDelete { indexSet in
                            Task { await deleteFiles(at: indexSet) }
                        }
                    }
                case .history:
                    List(session.history.reversed()) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            EditText(record.summary)
                                .font(.callout)
                            HStack(spacing: 6) {
                                Text(record.path?.value ?? "—")
                                    .lineLimit(1)
                                Text(record.atUTC, style: .time)
                                Text(operationName(record.operation))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            NavigationStack {
                Group {
                    if let path = selection, session.documentExists(at: path) {
                        detailView(for: path).id(path)
                    } else {
                        ContentUnavailableView {
                            EditText(GameEditCopy("No file selected", "未选择文件"))
                        } description: {
                            EditText(GameEditCopy("Pick a file on the left, or import a new asset.",
                                                  "在左侧选择文件，或导入新素材。"))
                        }
                    }
                }
                .navigationTitle(session.baseProject.title)
                .toolbar { toolbarContent }
            }
        }
        .navigationTitle(session.baseProject.title)
        .safeAreaInset(edge: .bottom) {
            if !session.diagnostics.isEmpty || session.conflict != nil || !session.fileConflicts.isEmpty {
                statusBanner
            }
        }
        .alert(Text(GameEditCopy.unsavedDraftTitle.text(locale)), isPresented: draftAlertBinding) {
            Button {
                Task { try? await session.recoverDraft() }
            } label: { EditText(.recover) }
            Button(role: .destructive) {
                Task { try? await session.discardDraft() }
            } label: { EditText(.discard) }
        } message: {
            if let draft = session.pendingDraft {
                EditText(GameEditCopy(
                    "Recovered \(draft.documentCount) unsaved file(s) from \(draft.savedAtUTC.formatted()).",
                    "从 \(draft.savedAtUTC.formatted()) 恢复 \(draft.documentCount) 个未保存文件。"))
            }
        }
        .alert(Text(GameEditCopy.editingIssueTitle.text(locale)), isPresented: issueAlertBinding) {
            Button(role: .cancel) { errorPresentation = nil } label: { EditText(.close) }
        } message: {
            if let issue = errorPresentation {
                Text(issue.diagnostics.map { $0.message.text(locale) }.joined(separator: "\n"))
            }
        }
        .fileImporter(isPresented: $addAssetRequest, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            Task { await addAssets(result) }
        }
        .fileImporter(isPresented: $importProjectRequest, allowedContentTypes: [.item, .folder], allowsMultipleSelection: true) { result in
            Task { await importProjectContents(result) }
        }
    }

    /// Single-asset import into the working set (bytes, no unpacking).
    private func addAssets(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result else { return }
        var items: [(name: String, bytes: Data)] = []
        var failures: [GameEditDiagnostic] = []
        for url in urls {
            do {
                let bytes = try await GameAssetByteLoader.load(url)
                items.append((url.lastPathComponent, bytes))
            } catch {
                failures.append(GameEditDiagnostic(severity: .error,
                    message: GameEditCopy("Could not read \(url.lastPathComponent): \(error.localizedDescription)",
                                          "无法读取 \(url.lastPathComponent)：\(error.localizedDescription)")))
            }
        }
        if !failures.isEmpty {
            errorPresentation = GameEditIssue(failures)
            guard !items.isEmpty else { return }
        }
        do {
            let paths = try await session.importAssets(items)
            selection = paths.first
        } catch let issue as GameEditIssue {
            errorPresentation = issue
        } catch {
            errorPresentation = GameEditIssue([GameEditDiagnostic(severity: .error,
                message: GameEditCopy(String(describing: error), String(describing: error)))])
        }
    }

    /// Full project/archive import through the injected host pipeline.
    private func importProjectContents(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        guard let host = session.projectImportHost else {
            errorPresentation = GameEditIssue([GameEditDiagnostic(severity: .error,
                message: GameEditCopy("Project import is provided by the host in the full App.",
                                      "项目导入由完整 App 的主机提供。"))])
            return
        }
        do {
            guard !session.isDirty, session.pendingDraft == nil else {
                throw GameEditIssue([GameEditDiagnostic(severity: .error,
                    message: GameEditCopy("Save or undo your current changes before importing a project.",
                                          "请先保存或撤销当前修改，再导入项目。"))])
            }
            let diagnostics = try await host.importProjectContents(.init(
                projectID: session.projectID, owner: session.owner,
                baseRevision: session.expectedRevision, sources: urls))
            try await session.refreshAfterProjectImport()
            if !diagnostics.isEmpty {
                errorPresentation = GameEditIssue(diagnostics)
            }
            selection = session.existingPaths().first
        } catch let issue as GameEditIssue {
            errorPresentation = issue
        } catch {
            errorPresentation = GameEditIssue([GameEditDiagnostic(severity: .error,
                message: GameEditCopy(String(describing: error), String(describing: error)))])
        }
    }

    @ViewBuilder
    private func detailView(for path: GameRelativePath) -> some View {
        if session.adapter.tileMapBinding(for: path, in: session.baseProject) != nil,
           session.adapter.narrativeBinding(for: path, in: session.baseProject) != nil {
            MapAndEventEditor(session: session, path: path,
                              tileMapEditorFactory: tileMapEditorFactory)
        } else if session.adapter.tileMapBinding(for: path, in: session.baseProject) != nil {
            if let tileMapEditorFactory {
                tileMapEditorFactory(session, path)
            } else {
                TileMapEditorView(session: session, path: path)
            }
        } else if session.adapter.narrativeBinding(for: path, in: session.baseProject) != nil {
            NarrativeEditorView(session: session, path: path)
        } else if session.adapter.parameterBinding(for: path, in: session.baseProject) != nil
                    || (path.value.hasSuffix(".json")
                        && !session.adapter.parameterSchemas(for: path, in: session.baseProject).isEmpty) {
            ParameterFormView(session: session, path: path)
        } else {
            AssetPreviewView(session: session, path: path)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let onClose {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: onClose) { EditText(GameEditCopy("Done", "完成")) }
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                if session.projectImportHost != nil {
                    Button { importProjectRequest = true } label: {
                        Label { EditText(.importProject) } icon: { Image(systemName: "shippingbox") }
                    }
                }
                Button { addAssetRequest = true } label: {
                    Label { EditText(.addAsset) } icon: { Image(systemName: "doc.badge.plus") }
                }
            } label: {
                Label { EditText(.importAction) } icon: { Image(systemName: "square.and.arrow.down") }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            EditButton {
                Task { try? await session.undo() }
            } label: {
                Label { EditText(.undo) } icon: { Image(systemName: "arrow.uturn.backward") }
            }
            .disabled(!session.canUndo)
            .help(session.undoSummary?.text(locale) ?? "")

            EditButton {
                Task { try? await session.redo() }
            } label: {
                Label { EditText(.redo) } icon: { Image(systemName: "arrow.uturn.forward") }
            }
            .disabled(!session.canRedo)
            .help(session.redoSummary?.text(locale) ?? "")

            EditButton {
                Task {
                    do { _ = try await session.save() }
                    catch let issue as GameEditIssue { errorPresentation = issue }
                    catch {
                        errorPresentation = GameEditIssue([GameEditDiagnostic(
                            severity: .error, message: GameEditCopy(String(describing: error), String(describing: error)))])
                    }
                }
            } label: {
                Label { EditText(.save) } icon: {
                    Image(systemName: session.isDirty ? "arrow.up.doc.fill" : "checkmark.seal")
                }
            }
            .disabled(!session.isDirty || session.conflict != nil)
            .accessibilityIdentifier("game.edit.save")
        }
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.conflict != nil {
                conflictRow
            }
            if !session.fileConflicts.isEmpty {
                ForEach(Array(session.fileConflicts.values), id: \.path) { file in
                    HStack {
                        EditText(file.blockingCopy)
                            .font(.callout)
                        Spacer()
                        EditButton { try? session.resolveConflict(at: file.path, .keepMine) } label: {
                            EditText(GameEditCopy("Keep mine", "保留我的")).font(.callout)
                        }
                        EditButton { try? session.resolveConflict(at: file.path, .keepTheirs) } label: {
                            EditText(GameEditCopy("Keep theirs", "保留对方")).font(.callout)
                        }
                    }
                }
            }
            ForEach(session.diagnostics) { diagnostic in
                EditText(diagnostic.message)
                    .font(.callout)
                    .foregroundStyle(diagnostic.severity == .error ? Color.red : Color.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }

    private var conflictRow: some View {
        HStack {
            EditText(GameEditCopy("The project changed elsewhere.", "项目在其他地方有改动。"))
                .font(.callout.bold())
            Spacer()
            EditButton {
                Task { try? await session.reloadForRebase() }
            } label: {
                EditText(GameEditCopy("Review changes", "查看改动")).font(.callout)
            }
        }
    }

    private var draftAlertBinding: Binding<Bool> {
        Binding(get: { session.pendingDraft != nil }, set: { _ in })
    }

    private var issueAlertBinding: Binding<Bool> {
        Binding(get: { errorPresentation != nil }, set: { shown in if !shown { errorPresentation = nil } })
    }

    private func deleteFiles(at indexSet: IndexSet) async {
        let paths = session.existingPaths()
        for index in indexSet where paths.indices.contains(index) {
            do {
                _ = try await session.deleteAsset(at: paths[index])
            } catch let issue as GameEditIssue {
                errorPresentation = issue
            } catch { /* file vanished concurrently */ }
        }
    }

    private func operationName(_ operation: GameEditRecord.Operation) -> String {
        switch operation {
        case .apply: return GameEditCopy("edit", "编辑").text(locale)
        case .undo: return GameEditCopy("undo", "撤销").text(locale)
        case .redo: return GameEditCopy("redo", "重做").text(locale)
        }
    }

    private func iconName(for path: GameRelativePath) -> String {
        switch session.adapter.assetKind(for: path, in: session.baseProject) ?? .unknown {
        case .image, .tileset: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .map: return "map"
        case .script: return "chevron.left.forwardslash.chevron.right"
        case .data, .manifest: return "tablecells"
        case .save: return "internaldrive"
        case .unknown: return "doc"
        }
    }
}

private struct MapAndEventEditor: View {
    @ObservedObject var session: GameEditingSession
    let path: GameRelativePath
    var tileMapEditorFactory: (@MainActor (GameEditingSession, GameRelativePath) -> AnyView)?
    @State private var events = false
    var body: some View {
        VStack(spacing: 0) {
            Picker(selection: $events) {
                EditText(GameEditCopy("Map", "地图")).tag(false)
                EditText(GameEditCopy("Events", "事件")).tag(true)
            } label: { EditText(GameEditCopy("Edit", "编辑")) }
            .pickerStyle(.segmented).padding(8)
            .accessibilityIdentifier("game.edit.map.mode")
            if events {
                NarrativeEditorView(session: session, path: path)
            } else if let tileMapEditorFactory {
                tileMapEditorFactory(session, path)
            } else {
                TileMapEditorView(session: session, path: path)
            }
        }
    }
}

extension GameEditingSession {
    /// Adds an "asset browser" entry point used by the session view's preview.
    var assetBrowserPaths: [GameRelativePath] { existingPaths() }
}
