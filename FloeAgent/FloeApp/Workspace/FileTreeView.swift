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

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            content
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(selecting ? "完成选择" : "选择", systemImage: "checklist") {
                    selecting.toggle(); selection.removeAll()
                }
                if selecting {
                    Button("全选") { selection = Set(viewModel.visibleNodes.map { $0.node.relativePath }) }
                    Button("删除 \(selection.count) 项", systemImage: "trash", role: .destructive) { deletingBatch = true }
                        .disabled(selection.isEmpty)
                }
                Button("刷新", systemImage: "arrow.clockwise") { Task { await viewModel.loadRoot() } }
            }
        }
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
        .onChange(of: viewModel.query) { _, _ in selection.removeAll(); selecting = false }
        .sheet(item: $exportedURL) { url in FileTreeShareSheet(url: url) }
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

    private var searchResults: some View {
        Group {
            if viewModel.searchHits.isEmpty {
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
                            Text("\(hit.relativePath):\(hit.lineNumber)")
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
