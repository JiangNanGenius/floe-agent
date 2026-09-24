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

/// The workspace directory tree (lazy) with an inline search field.
struct FileTreeView: View {
    @ObservedObject var viewModel: FileTreeViewModel
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
    @State private var showingRename = false
    @State private var renameTarget: FileTreeNode?
    @State private var renameName = ""
    @State private var pendingDelete: FileTreeNode?
    @State private var operationError: String?
    @State private var selecting = false
    @State private var selection: Set<String> = []
    @State private var deletingBatch = false
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

    var body: some View {
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
                    Button(selecting ? "完成选择" : "选择", systemImage: "checklist") {
                        selecting.toggle(); selection.removeAll()
                    }
                    if selecting {
                        Button("全选") { selection = Set(viewModel.visibleNodes.map { $0.node.relativePath }) }
                        Button("files.compress.action", systemImage: "doc.zipper") { beginCompress() }
                            .disabled(selection.isEmpty || compressing)
                        Button("删除 \(selection.count) 项", systemImage: "trash", role: .destructive) { deletingBatch = true }
                            .disabled(selection.isEmpty)
                    }
                    Button("刷新", systemImage: "arrow.clockwise") { Task { await viewModel.loadRoot() } }
                }
            }
        }
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
        .onChange(of: viewModel.query) { _, _ in selection.removeAll(); selecting = false }
        .onChange(of: compressFormatID) { oldValue, newValue in
            updateCompressNameExtension(from: oldValue, to: newValue)
        }
        .sheet(item: $exportedURL) { url in FileTreeShareSheet(url: url) }
        .sheet(isPresented: $showingCompress) { compressSheet }
        .confirmationDialog("删除所选文件？", isPresented: $deletingBatch, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task {
                    busy = true
                    let failures = await viewModel.deleteBatch(selection)
                    selection = Set(failures.keys)
                    operationError = failures.isEmpty ? nil : failures.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: "\n")
                    busy = false
                }
            }
        } message: { Text("文件夹包含其中全部内容，此操作不可撤销。") }
        .alert("移动文件", isPresented: Binding(get: { movingNode != nil }, set: { if !$0 { movingNode = nil } })) {
            TextField("目标路径（包含文件名）", text: $destinationPath)
            Button("移动") {
                guard let node = movingNode else { return }
                let destination = destinationPath
                movingNode = nil
                Task { do { try await viewModel.move(node, to: destination) } catch { operationError = error.localizedDescription } }
            }
            Button("action.cancel", role: .cancel) { movingNode = nil }
        } message: { Text("输入当前工作区内的目标路径。") }
        .alert("新建文件夹", isPresented: $showingNewFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("创建") { Task { await createFolder() } }
            Button("取消", role: .cancel) {}
        }
        .alert("重命名", isPresented: $showingRename) {
            TextField("新名称", text: $renameName)
            Button("确定") { Task { await rename() } }
            Button("取消", role: .cancel) {}
        }
        .alert(
            "确认删除？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { node in
            Button("删除", role: .destructive) {
                pendingDelete = nil
                Task { await deleteNode(node) }
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: { node in
            Text(node.isDirectory
                ? "将递归删除“\(node.name)”及其中的全部内容，此操作不可撤销。"
                : "将删除“\(node.name)”，此操作不可撤销。")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
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
                        } else if node.isDirectory {
                            Task { await viewModel.toggleDirectory(node) }
                        } else { onSelectFile(node.relativePath) }
                    }
                }
                .contextMenu { rowMenu(for: node) }
                .listRowInsets(dense
                    ? EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
                    : EdgeInsets())
                .listRowSeparator(dense ? .hidden : .visible, edges: .all)
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private func rowMenu(for node: FileTreeNode) -> some View {
        if node.isDirectory {
            Button {
                newFolderParent = node.relativePath
                newFolderName = ""
                showingNewFolder = true
            } label: {
                Label("新建文件夹", systemImage: "folder.badge.plus")
            }
        }
        Button {
            renameTarget = node
            renameName = node.name
            showingRename = true
        } label: {
            Label("重命名", systemImage: "pencil")
        }
        Button("移动", systemImage: "folder") { movingNode = node; destinationPath = node.relativePath }
        Button("files.compress.action", systemImage: "doc.zipper") {
            selection = [node.relativePath]
            selecting = true
            beginCompress()
        }
        if !node.isDirectory {
            Button("导出", systemImage: "square.and.arrow.up") {
                do { exportedURL = try viewModel.exportURL(node) } catch { operationError = error.localizedDescription }
            }
        }
        Button(role: .destructive) {
            pendingDelete = node
        } label: {
            Label("删除", systemImage: "trash")
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

    private func deleteNode(_ node: FileTreeNode) async {
        do {
            try await viewModel.delete(node, recursive: true)
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
                ProgressView("正在搜索文件名与文本内容…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView("无法完成搜索", systemImage: "magnifyingglass", description: Text(error))
            } else if viewModel.searchHits.isEmpty {
                ContentUnavailableView {
                    Label("inspector.search.empty", systemImage: "magnifyingglass")
                } description: {
                    Text(viewModel.query)
                }
            } else {
                List(Array(viewModel.searchHits.enumerated()), id: \.offset) { _, hit in
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
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12, height: 1)
                }
                Image(systemName: node.isDirectory
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
        .accessibilityAddTraits(node.isDirectory ? [] : .isButton)
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
