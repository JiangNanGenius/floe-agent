// FloeApp — Workspace file inspector.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §4: the iPad collapsible third
// column / iPhone sheet container. Shows the workspace picker when no
// workspace is open; otherwise a lazy file tree + search, drilling into
// preview / editor / Quick Look. Selecting a file records it as recent and
// persists the inspector selection state.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels
import FloeExecution
import UniformTypeIdentifiers

/// The file inspector surface: workspace header + tree/search + preview
/// navigation. Presented in the iPad third column or the iPhone sheet via
/// AppRouter's inspectorContent.
struct FileInspectorView: View {
    @ObservedObject var center: WorkspaceCenter
    @EnvironmentObject private var router: AppRouter

    @StateObject private var treeModel: FileTreeViewModel
    @State private var previewPath: String?
    @State private var showWorkspacePicker = false
    @State private var showMountPicker = false
    @State private var showImportPicker = false
    @State private var showCloudWorkspaceLink = false
    @State private var canvasWorkspace: WorkspaceRecord?
    @State private var exportURL: URL?
    @State private var inspectorMode: InspectorMode = .files
    @State private var contextNotice: String?
    /// Prevents the tree's restoration task from reopening the file during
    /// the short async window in which the cleared selection is persisted.
    @State private var isClosingPreview = false

    init(center: WorkspaceCenter) {
        self.center = center
        _treeModel = StateObject(wrappedValue: FileTreeViewModel(center: center))
    }

    private enum InspectorMode: String, CaseIterable, Identifiable {
        case files, sourceControl
        var id: String { rawValue }
        var title: String { self == .files ? "文件" : "源码管理" }
        var icon: String { self == .files ? "folder" : "arrow.triangle.branch" }
    }

    var body: some View {
        Group {
            if let workspace = center.currentWorkspace {
                inspectorBody(workspace)
            } else {
                WorkspacePickerView(center: center)
            }
        }
        .background(FloeTheme.readingSurface)
        .sheet(isPresented: $showWorkspacePicker) {
            NavigationStack {
                WorkspacePickerView(center: center) {
                    showWorkspacePicker = false
                    Task { await treeModel.loadRoot() }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("inspector.close") { showWorkspacePicker = false }
                            .frame(minHeight: FloeTheme.minimumTarget)
                    }
                }
            }
        }
        .sheet(isPresented: $showMountPicker) {
            DocumentPickerView(contentTypes: [.folder]) { url in
                Task { await mountFolder(url) }
            }
        }
        .sheet(isPresented: $showImportPicker) {
            DocumentPickerView(contentTypes: [.folder]) { url in
                Task { await importFolder(url) }
            }
        }
        .sheet(isPresented: $showCloudWorkspaceLink) {
            CloudWorkspaceLinkSheet(center: center)
        }
        .fullScreenCover(item: $canvasWorkspace) { workspace in
            WorkspaceCanvasView(canvasID: workspace.id, name: workspace.name, workspace: workspace)
        }
        .sheet(isPresented: Binding(
            get: { exportURL != nil },
            set: { if !$0 { exportURL = nil } }
        )) {
            if let exportURL {
                WorkspaceExportShareSheet(items: [exportURL])
            }
        }
    }

    @ViewBuilder
    private func inspectorBody(_ workspace: WorkspaceRecord) -> some View {
        if let previewPath {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        closePreview()
                    } label: {
                        Label("inspector.back", systemImage: "chevron.left")
                    }
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityLabel("inspector.back")
                    Text((previewPath as NSString).lastPathComponent)
                        .font(FloeTheme.Typography.section)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        router.hideInspector()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityLabel("inspector.close")
                }
                .padding(.horizontal, 8)
                Divider()
                FilePreviewView(
                    relativePath: previewPath,
                    center: center,
                    onAddToContext: { addToContext(previewPath) }
                )
                .id(previewPath)
            }
            .overlay(alignment: .bottom) {
                if let contextNotice {
                    Label(contextNotice, systemImage: "checkmark.circle.fill")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.success)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        } else {
            VStack(spacing: 0) {
                workspaceHeader(workspace)
                Divider()
                Picker("工作区面板", selection: $inspectorMode) {
                    ForEach(InspectorMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                if inspectorMode == .files {
                    FileTreeView(viewModel: treeModel) { path in
                        isClosingPreview = false
                        self.previewPath = path
                        Task { await persistSelection(path) }
                    }
                } else {
                    SourceControlView(center: center.environment.sourceControlCenter)
                }
            }
            .navigationTitle("inspector.files")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        do {
                            try WorkspaceCanvasRegistry.createIfNeeded(workspace: workspace)
                            canvasWorkspace = workspace
                        } catch {
                            center.actionError = error.localizedDescription
                        }
                    } label: {
                        Label(
                            WorkspaceCanvasRegistry.exists(workspaceID: workspace.id)
                                ? "画布" : "新建画布",
                            systemImage: "rectangle.and.pencil.and.ellipsis"
                        )
                    }
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityHint("打开这个工作区唯一的画布入口")
                }
                if workspace.kind == .privateTask {
                    ToolbarItem(placement: .topBarTrailing) {
                        workspaceActions
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.hideInspector()
                    } label: {
                        Label("inspector.close", systemImage: "xmark")
                    }
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                    .accessibilityLabel("inspector.close")
                }
            }
            .task {
                await treeModel.loadRoot()
                if !isClosingPreview,
                   let selected = workspace.inspectorState.selectedRelativePath {
                    previewPath = selected
                }
            }
        }
    }

    private var workspaceActions: some View {
        Menu {
            Button {
                showMountPicker = true
            } label: {
                Label("链接外部文件夹", systemImage: "folder.badge.plus")
            }
            Button {
                showImportPicker = true
            } label: {
                Label("导入整个文件夹", systemImage: "square.and.arrow.down")
            }
            Button {
                showCloudWorkspaceLink = true
            } label: {
                Label("链接云工作区", systemImage: "cloud")
            }
            Button {
                do { exportURL = try center.prepareWorkspaceExport() }
                catch { center.actionError = error.localizedDescription }
            } label: {
                Label("导出工作区", systemImage: "square.and.arrow.up")
            }
        } label: {
            Label("工作区操作", systemImage: "ellipsis.circle")
        }
        .accessibilityLabel("工作区操作")
    }

    private func mountFolder(_ url: URL) async {
        do {
            try await center.mountExternalFolder(url)
            await treeModel.loadRoot()
        } catch {
            center.actionError = error.localizedDescription
        }
    }

    private func importFolder(_ url: URL) async {
        do {
            try await center.importFolder(url)
            await treeModel.loadRoot()
        } catch {
            center.actionError = error.localizedDescription
        }
    }

    private func workspaceHeader(_ workspace: WorkspaceRecord) -> some View {
        Group {
        if router.selectedConversationID == nil {
            Button { showWorkspacePicker = true } label: { workspaceHeaderLabel(workspace, showsSwitch: true) }
                .buttonStyle(.plain)
                .accessibilityLabel("workspace.switch")
        } else {
            workspaceHeaderLabel(workspace, showsSwitch: false)
        }
        }
        .frame(minHeight: FloeTheme.minimumTarget)
    }

    private func workspaceHeaderLabel(_ workspace: WorkspaceRecord, showsSwitch: Bool) -> some View {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(FloeTheme.primary)
                    .accessibilityHidden(true)
                Text(workspace.name)
                    .font(FloeTheme.Typography.section)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !center.activeMountNames.isEmpty {
                    Label("\(center.activeMountNames.count)", systemImage: "externaldrive.connected.to.line.below")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("已链接 \(center.activeMountNames.count) 个外部文件夹")
                }
                if !center.cloudWorkspaceLinks.isEmpty {
                    Label("\(center.cloudWorkspaceLinks.count)", systemImage: "cloud.fill")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.primary)
                        .accessibilityLabel("已链接 \(center.cloudWorkspaceLinks.count) 个云工作区")
                }
                Spacer()
                if showsSwitch {
                    Text("workspace.switch")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }

    private func persistSelection(_ path: String) async {
        var state = center.currentWorkspace?.inspectorState ?? InspectorState()
        state.selectedRelativePath = path
        state.isExpanded = true
        await center.updateInspectorState(state)
    }

    /// Returns to the file tree and clears the durable selection. Without
    /// clearing the persisted path, the tree's `.task` immediately restores
    /// the same preview and makes the Back button appear unresponsive.
    private func closePreview() {
        // Set the guard before changing branches. Without this synchronous
        // latch, the file-tree `.task` can read the old persisted path and
        // immediately reopen the same file, making Back look broken.
        isClosingPreview = true
        previewPath = nil
        Task {
            var state = center.currentWorkspace?.inspectorState ?? InspectorState()
            state.selectedRelativePath = nil
            state.isExpanded = true
            await center.updateInspectorState(state)
            await treeModel.loadRoot()
            isClosingPreview = false
        }
    }

    /// Adds the durable attachment without fabricating a user chat bubble.
    /// Feedback stays in the workspace pane where the action occurred.
    private func addToContext(_ relativePath: String) {
        Task {
            let added = await center.addFileToConversationContext(
                relativePath: relativePath,
                conversationID: router.selectedConversationID
            )
            guard added else { return }
            withAnimation(.snappy) {
                contextNotice = "已加入任务上下文"
            }
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.snappy) { contextNotice = nil }
        }
    }
}

private struct CloudWorkspaceLinkSheet: View {
    @ObservedObject var center: WorkspaceCenter
    @ObservedObject private var remoteCenter: RemoteSessionCenter
    @Environment(\.dismiss) private var dismiss
    @State private var selectedHostID: UUID?
    @State private var name = ""
    @State private var remotePath = ""
    @State private var port = String(RemoteAgentPayload.defaultPort)
    @State private var cleanupOnDelete = false
    @State private var errorMessage: String?

    init(center: WorkspaceCenter) {
        self.center = center
        self.remoteCenter = center.environment.remoteSessionCenter
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("云工作区") {
                    Picker("受信任主机", selection: $selectedHostID) {
                        Text("请选择主机").tag(UUID?.none)
                        ForEach(remoteCenter.hosts) { host in
                            Text("\(host.displayName) · \(host.user)@\(host.address)")
                                .tag(Optional(host.id))
                        }
                    }
                    TextField("显示名称", text: $name)
                    TextField("守护程序工作区 ID / 相对路径", text: $remotePath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("守护程序端口", text: $port)
                        .keyboardType(.numberPad)
                    Toggle("永久删除任务时清理云工作区", isOn: $cleanupOnDelete)
                }
                Section {
                    Text("这里只创建连接标记。守护程序仅在你于对话中明确要求安装后，才由模型通过已验证的 SSH 主机执行引导；默认服务只监听远端回环地址，并通过 SSH 隧道访问。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("链接云工作区")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("链接") { link() }
                        .disabled(selectedHostID == nil || remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                await remoteCenter.loadHosts()
                if selectedHostID == nil { selectedHostID = remoteCenter.hosts.first?.id }
            }
        }
    }

    private func link() {
        guard let selectedHostID else { return }
        do {
            _ = try center.linkCloudWorkspace(
                name: name,
                hostID: selectedHostID,
                remotePath: remotePath.trimmingCharacters(in: .whitespacesAndNewlines),
                daemonPort: Int(port) ?? RemoteAgentPayload.defaultPort,
                cleanupOnConversationDelete: cleanupOnDelete
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct WorkspaceExportShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
