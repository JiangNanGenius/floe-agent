// FloeApp — Lazy directory tree with search and file operations.
//
// SPDX-License-Identifier: MPL-2.0
//
// OutlineGroup-based tree over FileTreeViewModel. Typing in the search
// field switches to a flat hit list (path + line number + context).
// Selecting a file opens the preview through FileInspectorView. Each row
// exposes a context menu for creating a folder, renaming, and deleting.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeWorkspace
import FloeTools

import FloeCore
/// The workspace directory tree (lazy) with an inline search field.
struct FileTreeView: View {
    @ObservedObject var viewModel: FileTreeViewModel
    @ObservedObject private var workspaceContext: WorkspaceCenter
    /// The IDE sidebar owns its own header/refresh chrome; embedding keeps the
    /// tree's toolbar out of the host navigation bar.
    var showsToolbar = true
    /// IDE Explorer density: hides the default list separators/insets so the
    /// tree reads like an editor explorer instead of a document picker.
    /// Row hit targets stay at the 44pt accessibility minimum.
    var dense = false
    /// Called when the user taps a file (tree mode) or a hit (search mode).
    let onSelectFile: (String) -> Void

    @State private var showingNewFolder = false
    @State private var newFolderParent = ""
    @State private var newFolderName = ""
    @State private var showingNewCAD = false
    @State private var newCADParent = ""
    @State private var newCADName = ""
    @State private var showingRename = false
    @State private var renameTarget: FileTreeNode?
    @State private var renameName = ""
    @State private var pendingDelete: WorkspaceFileDeletionRequest?
    @State private var deletionPreparationTask: Task<Void, Never>?
    @State private var operationError: String?
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var pendingDeleteBatch: FileTreeDeletionBatch?
    @State private var deletionPreparationGeneration = UUID()
    @State private var busy = false
    @State private var movingNode: FileTreeNode?
    @State private var destinationPath = ""
    @State private var exportedURL: URL?
    // Multi-select Compress: the sheet collects a format + name, resolves the
    // destination conflict up front, then runs through the view model's
    // shared archive service with live progress and a real cancel.
    @State private var showingCompress = false
    @State private var compressFormatID = WorkspaceArchiveCompression.Format.default.id
    @State private var compressName = ""
    @State private var compressNotice: String?
    @State private var compressing = false
    @State private var compressCancellation: CancellationToken?
    @State private var compressBanner: String?

    init(viewModel: FileTreeViewModel, showsToolbar: Bool = true, dense: Bool = false,
         onSelectFile: @escaping (String) -> Void) {
        self.viewModel = viewModel; self.showsToolbar = showsToolbar; self.dense = dense
        self.onSelectFile = onSelectFile
        _workspaceContext = ObservedObject(wrappedValue: viewModel.deletionCenter)
    }

    var body: some View {
        fileTreeWithDestructiveAlerts
            .alert("chat.conversation_list_view.action_failed", isPresented: operationErrorBinding) {
                Button("workspace.office_document_editor_view.ok", role: .cancel) {}
            } message: {
                Text(operationError ?? "")
            }
    }

    // The modifier chain used to be one expression; Xcode 26.6's type checker
    // gave up on it ("unable to type-check this expression in reasonable
    // time"). Splitting it into small chained expressions changes no behavior.

    private var fileTreeBase: some View {
        VStack(spacing: 0) {
            if let compressBanner {
                compressBannerView(compressBanner)
            }
            searchField
            Divider()
            content
        }
        .toolbar {
            if showsToolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newCADParent = ""
                            newCADName = ""
                            showingNewCAD = true
                        } label: {
                            Label("workspace.file_tree_view.new_cad_document",
                                  systemImage: "cube.transparent")
                        }
                        .accessibilityIdentifier("fileTree.newCADDocument")
                        Button {
                            newFolderParent = ""
                            newFolderName = ""
                            showingNewFolder = true
                        } label: {
                            Label("workspace.file_tree_view.new_folder",
                                  systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("fileTree.createMenu")
                    Button(selecting ? "workspace.file_tree_view.done_selecting" : "workspace.file_tree_view.select", systemImage: "checklist") {
                        selecting.toggle(); selection.removeAll()
                    }
                    if selecting {
                        Button("composer.editor.select_all") { selection = Set(viewModel.visibleNodes.map { $0.node.relativePath }) }
                        Button("files.compress.action", systemImage: "doc.zipper") { beginCompress() }
                            .disabled(selection.isEmpty || compressing)
                        Button(FloeL10n.plural("workspace.file_tree_view.delete_items", count: selection.count), systemImage: "trash", role: .destructive) { prepareBatchDeletion() }
                            .disabled(selection.isEmpty)
                    }
                    Button("envmgr.refresh", systemImage: "arrow.clockwise") { Task { await viewModel.loadRoot() } }
                }
            }
        }
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
        .onChange(of: viewModel.query) { _, _ in cancelPendingDeletion(); selection.removeAll(); selecting = false }
        .onChange(of: workspaceContext.currentWorkspace?.id) { _, _ in cancelPendingDeletion() }
        .onChange(of: workspaceContext.currentRootURL) { _, _ in cancelPendingDeletion() }
        .onChange(of: workspaceContext.activeMountNames) { _, _ in cancelPendingDeletion() }
        .onChange(of: workspaceContext.cloudWorkspaceLinks) { _, _ in cancelPendingDeletion() }
        .onChange(of: workspaceContext.networkWorkspaceMounts) { _, _ in cancelPendingDeletion() }
        .onDisappear { cancelPendingDeletion() }
        .onChange(of: compressFormatID) { oldValue, newValue in
            updateCompressNameExtension(from: oldValue, to: newValue)
        }
    }

    private var fileTreeWithSheets: some View {
        fileTreeBase
            .sheet(item: $exportedURL) { url in FileTreeShareSheet(url: url) }
            .sheet(isPresented: $showingCompress) { compressSheet }
            .confirmationDialog("workspace.file_tree_view.delete_the_selected_files",
                isPresented: Binding(get: { pendingDeleteBatch != nil }, set: { if !$0 { pendingDeleteBatch = nil } }),
                titleVisibility: .visible, presenting: pendingDeleteBatch) { batch in
                    Button("workspace.workspace_canvas_view.delete", role: .destructive) {
                        pendingDeleteBatch = nil
                        Task {
                            busy = true
                            let failures = await viewModel.deleteBatch(batch)
                            if (try? WorkspaceFileActionScope(center: workspaceContext)) == batch.scope {
                                selection = Set(failures.keys)
                                operationError = failures.isEmpty ? nil : failures.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                            }
                            busy = false
                        }
                    }
                    Button("action.cancel", role: .cancel) { pendingDeleteBatch = nil }
                } message: { _ in Text("workspace.file_tree_view.the_folder_includes_all_of_its") }
    }

    private var fileTreeWithEntryAlerts: some View {
        fileTreeWithSheets
            .alert("workspace.file_tree_view.move_file", isPresented: movingNodeBinding) {
                TextField("workspace.file_tree_view.destination_path_including_file_name", text: $destinationPath)
                Button("workspace.file_tree_view.move") {
                    guard let node = movingNode else { return }
                    let destination = destinationPath
                    movingNode = nil
                    Task { do { try await viewModel.move(node, to: destination) } catch { operationError = error.localizedDescription } }
                }
                Button("action.cancel", role: .cancel) { movingNode = nil }
            } message: { Text("workspace.file_tree_view.enter_a_destination_path_inside_the") }
            .alert("workspace.file_tree_view.new_folder", isPresented: $showingNewFolder) {
                TextField("workspace.file_tree_view.folder_name", text: $newFolderName)
                Button("settings.git_hub_settings_view.create") { Task { await createFolder() } }
                Button("workspace.workspace_canvas_view.cancel", role: .cancel) {}
            }
            .alert("workspace.file_tree_view.new_cad_document", isPresented: $showingNewCAD) {
                TextField("workspace.file_tree_view.cad_document_name", text: $newCADName)
                Button("settings.git_hub_settings_view.create") { Task { await createCADDocument() } }
                Button("workspace.workspace_canvas_view.cancel", role: .cancel) {}
            } message: {
                Text("workspace.file_tree_view.new_cad_document_message")
            }
            .alert("workspace.file_tree_view.rename", isPresented: $showingRename) {
                TextField("workspace.file_tree_view.new_name", text: $renameName)
                Button("workspace.file_tree_view.ok") { Task { await rename() } }
                Button("workspace.workspace_canvas_view.cancel", role: .cancel) {}
            }
    }

    private var fileTreeWithDestructiveAlerts: some View {
        fileTreeWithEntryAlerts
            .alert("workspace.file_tree_view.confirm_deletion",
                isPresented: pendingDeleteBinding,
                presenting: pendingDelete
            ) { node in
                Button("workspace.workspace_canvas_view.delete", role: .destructive) {
                    pendingDelete = nil
                    Task { await deleteNode(node) }
                }
                Button("workspace.workspace_canvas_view.cancel", role: .cancel) { pendingDelete = nil }
            } message: { node in
                Text(node.isDirectory
                    ? FloeL10n.l("workspace.file_tree_view.and_all_of_its_contents_will", node.name)
                    : FloeL10n.l("workspace.file_tree_view.will_be_deleted_this_cannot_be", node.name))
            }
    }

    private var movingNodeBinding: Binding<Bool> {
        Binding(get: { movingNode != nil }, set: { if !$0 { movingNode = nil } })
    }

    private var pendingDeleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var operationErrorBinding: Binding<Bool> {
        Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(text: $viewModel.query) {
                Text("inspector.search.placeholder")
            }
            .textFieldStyle(.plain)
            .accessibilityLabel("inspector.search.placeholder")
            if viewModel.isSearching {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("inspector.search.clear")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isSearching {
            searchResults
        } else if viewModel.rootNodes.isEmpty {
            emptyState
        } else {
            treeList
        }
    }

    private var treeList: some View {
        List {
            ForEach(viewModel.visibleNodes) { visible in
                let node = visible.node
                let scope = viewModel.loadedScope
                HStack(spacing: 8) {
                    if selecting {
                        Image(systemName: selection.contains(node.relativePath) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(node.relativePath) ? Color.accentColor : .secondary)
                    }
                    FileTreeRow(
                        node: node,
                        depth: visible.depth,
                        isExpanded: viewModel.expandedDirectoryPaths.contains(node.relativePath)
                    ) {
                        if selecting {
                            if !selection.insert(node.relativePath).inserted { selection.remove(node.relativePath) }
                        } else if node.isBrowsableDirectory {
                            Task { await viewModel.toggleDirectory(node) }
                        } else { onSelectFile(node.relativePath) }
                    }
                    Menu { rowMenu(for: node, scope: scope) } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(.rect)
                    }.buttonStyle(.borderless).accessibilityLabel("workspace.workspace_canvas_view.more")
                        .accessibilityIdentifier("fileTree.row.menu." + node.relativePath)
                }
                .contextMenu { rowMenu(for: node, scope: scope) }
                .listRowInsets(dense
                    ? EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
                    : EdgeInsets())
                .listRowSeparator(dense ? .hidden : .visible, edges: .all)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func rowMenu(for node: FileTreeNode, scope: WorkspaceFileActionScope?, deletionOnly: Bool = false) -> some View {
        if !deletionOnly {
        if node.isBrowsableDirectory {
            Button {
                newFolderParent = node.relativePath
                newFolderName = ""
                showingNewFolder = true
            } label: {
                Label("workspace.file_tree_view.new_folder", systemImage: "folder.badge.plus")
            }
            Button {
                newCADParent = node.relativePath
                newCADName = ""
                showingNewCAD = true
            } label: {
                Label("workspace.file_tree_view.new_cad_document", systemImage: "cube.transparent")
            }
        }
        Button {
            renameTarget = node
            renameName = node.name
            showingRename = true
        } label: {
            Label("workspace.file_tree_view.rename", systemImage: "pencil")
        }
        Button("workspace.file_tree_view.move", systemImage: "folder") { movingNode = node; destinationPath = node.relativePath }
        Button("files.compress.action", systemImage: "doc.zipper") {
            selection = [node.relativePath]
            selecting = true
            beginCompress()
        }
        if !node.isDirectory {
            Button("files.export", systemImage: "square.and.arrow.up") {
                do { exportedURL = try viewModel.exportURL(node) } catch { operationError = error.localizedDescription }
            }
        }
        }
        Button(role: .destructive) {
            cancelPendingDeletion()
            let generation = deletionPreparationGeneration
            deletionPreparationTask = Task {
                do {
                    let request = try await viewModel.deletionRequest(node, scope: scope)
                    guard generation == deletionPreparationGeneration, !Task.isCancelled else { return }
                    pendingDelete = request
                } catch is CancellationError { }
                catch { if generation == deletionPreparationGeneration { operationError = error.localizedDescription } }
            }
        } label: {
            Label("workspace.workspace_canvas_view.delete", systemImage: "trash")
        }.disabled(scope == nil).accessibilityIdentifier("fileTree.row.delete")
    }

    private func cancelPendingDeletion() {
        deletionPreparationGeneration = UUID()
        deletionPreparationTask?.cancel(); deletionPreparationTask = nil
        pendingDelete = nil; pendingDeleteBatch = nil; busy = false
    }
    private func prepareBatchDeletion() {
        let paths = selection, scope = viewModel.loadedScope
        cancelPendingDeletion()
        let generation = deletionPreparationGeneration
        deletionPreparationTask = Task {
            busy = true
            defer { if generation == deletionPreparationGeneration { busy = false } }
            do {
                let batch = try await viewModel.prepareDeletionBatch(paths, scope: scope)
                guard generation == deletionPreparationGeneration, !Task.isCancelled else { return }
                pendingDeleteBatch = batch
            } catch is CancellationError { }
            catch { if generation == deletionPreparationGeneration { operationError = error.localizedDescription } }
        }
    }

    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await viewModel.createDirectory(parent: newFolderParent, name: name)
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// Production native CAD creation: builds the `.floecad` package through
    /// the versioned store and opens it immediately so the user lands in the
    /// workbench (sketch → solid → save all work from here).
    private func createCADDocument() async {
        let name = newCADName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let relative = try await viewModel.createNativeCADDocument(
                parent: newCADParent, name: name)
            onSelectFile(relative)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func rename() async {
        guard let target = renameTarget else { return }
        let name = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try await viewModel.rename(target, to: name)
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func deleteNode(_ node: WorkspaceFileDeletionRequest) async {
        do {
            try await viewModel.delete(node)
        } catch {
            operationError = error.localizedDescription
        }
    }

    // MARK: - multi-select compress

    private var selectedCompressFormat: WorkspaceArchiveCompression.Format {
        WorkspaceArchiveCompression.Format.format(id: compressFormatID)
    }

    private func compressBannerView(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(FloeTheme.success)
                .accessibilityHidden(true)
            Text(text)
                .font(FloeTheme.Typography.metadata)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                compressBanner = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("inspector.search.clear")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// The sheet: name + format, then live progress and a real cancel. The
    /// destination conflict is resolved before the engine runs, so an
    /// existing archive is never overwritten.
    private var compressSheet: some View {
        NavigationStack {
            Form {
                Section("files.compress.name") {
                    TextField("files.compress.name.placeholder", text: $compressName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(compressing)
                }
                Section("files.compress.format") {
                    Picker("files.compress.format", selection: $compressFormatID) {
                        ForEach(WorkspaceArchiveCompression.Format.all) { format in
                            Text(format.title).tag(format.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(compressing)
                    if compressFormatID == WorkspaceArchiveCompression.Format.tarballBzip2.id {
                        Text("files.compress.format.tbz2_note")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
                if compressing {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(compressProgressText)
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                        }
                        Button("files.compress.cancel", role: .destructive) { cancelCompress() }
                    }
                } else if let compressNotice {
                    Section {
                        Text(compressNotice)
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("files.compress.title")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(compressing)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { showingCompress = false }
                        .disabled(compressing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("files.compress.confirm") { startCompress() }
                        .disabled(compressing || compressName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var compressProgressText: String {
        guard let progress = viewModel.compressProgress else {
            return String(localized: "files.compress.preparing")
        }
        let phase: String
        switch progress.phase {
        case .scanning: phase = String(localized: "files.compress.phase.scanning")
        case .writing: phase = String(localized: "files.compress.phase.writing")
        case .reading: phase = String(localized: "files.compress.phase.reading")
        }
        if let total = progress.totalBytes, total > 0 {
            let percent = Int((Double(progress.completedBytes) / Double(total) * 100).rounded())
            return "\(phase) \(percent)%"
        }
        return "\(phase) · \(progress.completedEntries)"
    }

    private func beginCompress() {
        guard !selection.isEmpty else { return }
        compressName = defaultCompressName(format: selectedCompressFormat)
        compressNotice = nil
        showingCompress = true
    }

    /// Default name for the current selection: a single directory keeps its
    /// name, a single file drops its own extension, several items become
    /// `Archive`. The lookup only needs visible rows: every selection the UI
    /// can build comes from them.
    private func defaultCompressName(format: WorkspaceArchiveCompression.Format) -> String {
        let roots = FileTreeViewModel.selectionRoots(selection)
        if roots.count == 1,
           let node = viewModel.visibleNodes.first(where: { $0.node.relativePath == roots[0] })?.node {
            return WorkspaceArchiveCompression.defaultName(
                singleSourceName: node.name,
                singleSourceIsDirectory: node.isDirectory,
                format: format
            )
        }
        return WorkspaceArchiveCompression.defaultName(
            singleSourceName: nil,
            singleSourceIsDirectory: false,
            format: format
        )
    }

    /// Keeps the file extension in step with the chosen format without
    /// discarding a name the user already edited.
    private func updateCompressNameExtension(from oldID: String, to newID: String) {
        guard !compressing else { return }
        let oldFormat = WorkspaceArchiveCompression.Format.format(id: oldID)
        let newFormat = WorkspaceArchiveCompression.Format.format(id: newID)
        if compressName.isEmpty || compressName == defaultCompressName(format: oldFormat) {
            compressName = defaultCompressName(format: newFormat)
        } else if compressName.hasSuffix(".\(oldFormat.fileExtension)") {
            compressName = String(compressName.dropLast(oldFormat.fileExtension.count + 1))
                + ".\(newFormat.fileExtension)"
        }
    }

    private func startCompress() {
        let name = compressName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let format = selectedCompressFormat
        // Never overwrite: a taken name resolves to "name 2.ext" before the
        // engine runs, and the sheet says which name will be used.
        let resolved = WorkspaceArchiveCompression.uniqueName(name) { viewModel.pathExists($0) }
        compressNotice = resolved == name ? nil : String(localized: "files.compress.conflict_note") + resolved
        let cancellation = CancellationToken()
        compressCancellation = cancellation
        compressing = true
        let paths = selection
        Task { @MainActor in
            do {
                _ = try await viewModel.compress(
                    paths: paths,
                    destinationName: resolved,
                    format: format.id,
                    cancellation: cancellation
                )
                compressing = false
                compressCancellation = nil
                showingCompress = false
                selection.removeAll()
                selecting = false
                compressBanner = String(localized: "files.compress.done") + resolved
            } catch {
                compressing = false
                let wasCancelled = cancellation.isCancelled
                compressCancellation = nil
                showingCompress = false
                // A user cancel is not an error; anything else surfaces with
                // its real reason.
                operationError = wasCancelled ? nil : error.localizedDescription
            }
        }
    }

    private func cancelCompress() {
        compressCancellation?.cancel()
    }

    private var searchResults: some View {
        Group {
            if viewModel.searchInProgress {
                ProgressView("workspace.file_tree_view.searching_file_names_and_text_content").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView("workspace.file_tree_view.the_search_could_not_be_completed", systemImage: "magnifyingglass", description: Text(error))
            } else if viewModel.searchHits.isEmpty {
                ContentUnavailableView {
                    Label("inspector.search.empty", systemImage: "magnifyingglass")
                } description: {
                    Text(viewModel.query)
                }
            } else {
                List(Array(viewModel.searchHits.enumerated()), id: \.offset) { _, hit in
                    let scope = viewModel.searchScope
                    let node = FileTreeNode(relativePath: hit.relativePath, name: (hit.relativePath as NSString).lastPathComponent,
                        isDirectory: false, size: 0)
                    HStack {
                    Button {
                        onSelectFile(hit.relativePath)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.lineNumber > 0 ? "\(hit.relativePath):\(hit.lineNumber)" : hit.relativePath)
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(hit.context)
                                .font(FloeTheme.Typography.evidence)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Menu { rowMenu(for: node, scope: scope, deletionOnly: true) } label: {
                        Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(.rect)
                    }.buttonStyle(.borderless).accessibilityLabel("workspace.workspace_canvas_view.more")
                        .accessibilityIdentifier("fileTree.search.menu." + hit.relativePath)
                    }
                    .id(hit.relativePath + "\u{0}" + String(hit.lineNumber) + "\u{0}" + hit.context + "\u{0}" + (scope?.root.path ?? "") + (scope?.workspaceID.uuidString ?? ""))
                    .contextMenu { rowMenu(for: node, scope: scope, deletionOnly: true) }
                }
                .listStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("inspector.tree.empty", systemImage: "folder")
        } description: {
            if let message = viewModel.errorMessage {
                Text(message)
            } else {
                Text("inspector.tree.empty.hint")
            }
        }
    }
}

/// One tree row. Directories disclose via OutlineGroup; tapping a file
/// selects it.
private struct FileTreeRow: View {
    let node: FileTreeNode
    let depth: Int
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if node.isBrowsableDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                Image(systemName: node.isCADDocumentPackage ? "cube.transparent" : node.isDirectory
                    ? (isExpanded ? "folder.fill" : "folder")
                    : "doc.text")
                    .foregroundStyle(node.isDirectory ? FloeTheme.primary : Color.secondary)
                Text(node.name)
                    .font(FloeTheme.Typography.body)
                    .lineLimit(1)
            }
            .padding(.leading, CGFloat(depth) * 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Directories keep their disclosure hit area; the button still
        // satisfies the 44pt minimum target on compact layouts.
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityLabel(node.name)
        .accessibilityIdentifier("fileTree.row.\(node.name)")
        .accessibilityAddTraits(node.isBrowsableDirectory ? [] : .isButton)
    }
}
private struct FileTreeShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
