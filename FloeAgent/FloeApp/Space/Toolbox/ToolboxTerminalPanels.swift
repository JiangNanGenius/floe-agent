// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeToolboxCore
import FloeToolboxUI
import FloeToolboxRemoteFiles
import FloeToolboxFileTransports

struct ToolboxTerminalAssistantView: View {
    @ObservedObject var session: ToolboxTerminalSession
    @EnvironmentObject private var environment: AppEnvironment
    @State private var conversationID: UUID?
    @State private var failure: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label(IDELanguageRunText.t("终端助手", "Terminal assistant"), systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("toolbox.terminal.assistant")
                Spacer(minLength: 8)
                Text(session.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Circle().fill(session.active ? FloeTheme.success : FloeTheme.destructive)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(session.active
                        ? IDELanguageRunText.t("已连接", "Connected")
                        : IDELanguageRunText.t("连接已结束", "Connection ended"))
            }.padding(.horizontal, 12).padding(.vertical, 8)
            if !session.active {
                assistantNotice(IDELanguageRunText.t("连接已结束。此助手不能再写入终端。", "The connection ended. This assistant can no longer write to the terminal."), symbol: "bolt.horizontal.circle")
            }
            if let captureFailure = session.captureFailure {
                assistantNotice(captureFailure, symbol: "exclamationmark.triangle")
            }
            Divider()
            if let conversationID {
                ThreadDetailView(conversationID: conversationID, center: environment.conversationCenter,
                    embedded: true, documentAssistant: true, ownsNavigationTitle: false)
            } else if let failure {
                ContentUnavailableView {
                    Label(IDELanguageRunText.t("助手未能打开", "Unable to open assistant"), systemImage: "exclamationmark.bubble")
                } description: { Text(failure) } actions: {
                    Button(IDELanguageRunText.t("重试", "Retry")) { Task { await openAssistant() } }
                }
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: session.id) { await openAssistant() }
    }
    private func openAssistant() async {
        failure = nil
        do {
            await session.flush()
            conversationID = try await environment.toolboxCenter.assistant(for: session)
        } catch {
            conversationID = nil
            failure = IDELanguageRunText.t("连接已结束或当前任务不可用。", "The connection ended or the task is unavailable.")
        }
    }
    private func assistantNotice(_ text: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol); Text(text)
        }.font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

struct ToolboxTerminalFilesView: View {
    @ObservedObject var session: ToolboxTerminalSession
    var expanded: Bool
    var onExpand: () -> Void = {}
    @State private var owner: ToolboxRemoteFilesOwner?
    @State private var failed = false
    var body: some View {
        Group {
            if let owner { ToolboxFilesContent(owner: owner, expanded: expanded, onExpand: onExpand) }
            else if failed { ContentUnavailableView(IDELanguageRunText.t("文件未能打开，请重新连接。", "Unable to open files. Reconnect and try again."), systemImage: "folder.badge.questionmark") }
            else { ProgressView() }
        }.task(id: session.id) { do { owner = try await session.fileOwner() } catch { failed = true } }
    }
}

private struct ToolboxFilesContent: View {
    @ObservedObject var owner: ToolboxRemoteFilesOwner
    @ObservedObject private var picker: ToolboxFileAccess
    let expanded: Bool
    let onExpand: () -> Void
    @State private var localSelection: Set<RemoteFilePath> = []
    @State private var editName = ""
    @State private var editingPath: RemoteFilePath?
    @State private var editingLocal = false
    @State private var showingName = false
    @State private var deleting: RemoteFilePath?
    @State private var deletingLocal = false
    @State private var conflict: TransferQueueEntry?
    @State private var showConflict = false
    init(owner: ToolboxRemoteFilesOwner, expanded: Bool, onExpand: @escaping () -> Void) {
        self.owner = owner; picker = owner.fileAccess; self.expanded = expanded; self.onExpand = onExpand
    }
    var body: some View {
        Group {
            if expanded { RemoteFilesWorkspace { localPane } remote: { remotePane } transfers: { transferQueue } }
            else { VStack(spacing: 0) { remotePane; Divider(); HStack { Label("\(owner.transfers.count)", systemImage: "arrow.up.arrow.down"); Spacer(); Button(IDELanguageRunText.t("展开文件管理", "Expand file manager")) { onExpand() }.frame(minHeight: 44) }.font(.caption).padding(.horizontal) } }
        }
        .fileImporter(isPresented: $picker.presenting, allowedContentTypes: picker.types, allowsMultipleSelection: false) { picker.finish($0.map { $0.first }) }
        .alert(IDELanguageRunText.t("名称", "Name"), isPresented: $showingName) {
            TextField(IDELanguageRunText.t("文件或文件夹名称", "File or folder name"), text: $editName)
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {}
            Button(IDELanguageRunText.t("保存", "Save")) {
                Task { if let editingPath { await owner.rename(editingPath, name: editName, local: editingLocal) } else { await owner.createFolder(editName, local: editingLocal) } }
            }
        }
        .confirmationDialog(IDELanguageRunText.t("删除所选项目？", "Delete the selected item?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(IDELanguageRunText.t("删除", "Delete"), role: .destructive) { if let deleting { let local = deletingLocal; self.deleting = nil; Task { await owner.delete(deleting, local: local) } } }
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { deleting = nil }
        }
        .confirmationDialog(IDELanguageRunText.t("目标已存在", "Destination already exists"), isPresented: $showConflict) {
            Button(IDELanguageRunText.t("保留现有文件", "Keep existing file"), role: .cancel) {}
            Button(IDELanguageRunText.t("替换", "Replace"), role: .destructive) { if let conflict { Task { await owner.resolveConflict(conflict, replace: true) } } }
            Button(IDELanguageRunText.t("保留两者", "Keep both")) { if let conflict { Task { await owner.resolveConflict(conflict, replace: false) } } }
        }
        .alert(IDELanguageRunText.t("文件信息", "File information"), isPresented: Binding(get: { owner.information != nil }, set: { _ in owner.dismissInformation() })) {
            Button(IDELanguageRunText.t("好", "OK")) { owner.dismissInformation() }
        } message: { Text(owner.information ?? "") }
    }
    private var localPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Label(IDELanguageRunText.t("我的文件", "My files"), systemImage: "folder").font(.headline); Spacer(); Button { Task { await owner.chooseLocalFolder() } } label: { Image(systemName: "folder.badge.gearshape").frame(width: 44, height: 44) }.accessibilityLabel(IDELanguageRunText.t("选择本地文件夹", "Choose local folder")); Button { Task { await owner.refresh(local: true) } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) } }
            HStack { Button { Task { await owner.navigate(owner.localDirectory.parent, local: true) } } label: { Image(systemName: "arrow.up").frame(width: 44, height: 44) }.disabled(owner.localDirectory.value == "/"); Text(owner.localDirectory.value).font(.caption.monospaced()).lineLimit(2) }
            if owner.loadingLocal { ProgressView() }
            List(selection: $localSelection) {
                ForEach(owner.localEntries.sorted { ($0.kind == .directory ? 0 : 1, $0.path.name) < ($1.kind == .directory ? 0 : 1, $1.path.name) }) { entry in
                    HStack {
                        Button { if entry.kind == .directory { Task { await owner.navigate(entry.path, local: true) } } else { if !localSelection.insert(entry.path).inserted { localSelection.remove(entry.path) } } } label: { Label(entry.path.name, systemImage: entry.kind == .directory ? "folder" : "doc").frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44) }.buttonStyle(.plain)
                        if localSelection.contains(entry.path) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                    }.tag(entry.path).contextMenu {
                        if entry.kind == .file {
                            Button(IDELanguageRunText.t("上传", "Upload")) { Task { await owner.enqueue([entry.path], uploading: true) } }
                            if let url = owner.localURL(entry.path) { ShareLink(item: url) { Label(IDELanguageRunText.t("共享", "Share"), systemImage: "square.and.arrow.up") } }
                        }
                        Button(IDELanguageRunText.t("重命名", "Rename")) { beginName(entry.path, local: true) }
                        Button(IDELanguageRunText.t("信息", "Information")) { Task { await owner.showInformation(entry.path, local: true) } }
                        Button(IDELanguageRunText.t("删除", "Delete"), role: .destructive) { deleting = entry.path; deletingLocal = true }
                    }
                }
            }.listStyle(.plain)
            ViewThatFits(in: .horizontal) { HStack { localActions }; VStack(alignment: .leading) { localActions } }
        }.padding().onChange(of: owner.localDirectory) { _, _ in localSelection.removeAll() }
    }
    private var localActions: some View {
        Group {
            Button(IDELanguageRunText.t("导入", "Import"), systemImage: "square.and.arrow.down") { Task { await owner.importLocalFile(uploadAfterImport: false) } }
            Button(IDELanguageRunText.t("上传所选", "Upload selected"), systemImage: "square.and.arrow.up") { let paths = localSelection; Task { await owner.enqueue(paths, uploading: true) } }.disabled(localSelection.isEmpty)
            Button(IDELanguageRunText.t("新建文件夹", "New folder"), systemImage: "folder.badge.plus") { beginName(nil, local: true) }
        }.buttonStyle(.bordered)
    }
    private var remotePane: some View {
        RemoteFilesPanel(lease: owner.lease, title: owner.title, root: try! .init("/"), directory: owner.remoteDirectory,
            entries: owner.remoteEntries, capabilities: owner.remoteCapabilities, loading: owner.loadingRemote, failureMessage: owner.failure) { lease, action in
            guard lease == owner.lease else { return }
            switch action {
            case .directory(let path): Task { await owner.navigate(path, local: false) }
            case .refresh: Task { await owner.refresh(local: false) }
            case .download(let paths): Task { await owner.enqueue(paths, uploading: false) }
            case .upload: Task { await owner.importLocalFile(uploadAfterImport: true) }
            case .newFolder: beginName(nil, local: false)
            case .rename(let path): beginName(path, local: false)
            case .delete(let path): deleting = path; deletingLocal = false
            case .information(let path), .openFile(let path): Task { await owner.showInformation(path, local: false) }
            case .followLink(let path): Task { await owner.followLink(path) }
            case .expand: if !expanded { onExpand() }
            }
        }
    }
    private var transferQueue: some View {
        DisclosureGroup(IDELanguageRunText.t("传输队列", "Transfers") + " · \(owner.transfers.count)") {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(owner.transfers) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.request.source.name).font(.subheadline).lineLimit(1); Spacer()
                                if [.queued, .running, .cancelling].contains(entry.phase) { Button(IDELanguageRunText.t("取消", "Cancel")) { Task { await owner.cancel(entry) } } }
                                if [.failed, .cancelled, .needsReview].contains(entry.phase) { Button(IDELanguageRunText.t("重试", "Retry")) { Task { await owner.retry(entry, resume: false) } }; if entry.transfer?.checkpoint != nil { Button(IDELanguageRunText.t("续传", "Resume")) { Task { await owner.retry(entry, resume: true) } } } }
                                if entry.phase == .conflict { Button(IDELanguageRunText.t("处理冲突", "Resolve conflict")) { conflict = entry; showConflict = true } }
                            }
                            Text(entry.request.source.value + " → " + entry.request.destination.value).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            if let transfer = entry.transfer, let total = transfer.totalBytes, total > 0 { ProgressView(value: Double(min(total, transfer.completedBytes)), total: Double(total)); Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: transfer.completedBytes), countStyle: .file)).font(.caption.monospacedDigit()) }
                            Text(phase(entry.phase)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if owner.transfers.isEmpty { Text(IDELanguageRunText.t("暂无传输任务", "No transfers")).foregroundStyle(.secondary) }
                }.padding(.top, 8)
            }.frame(maxHeight: 180)
        }.padding()
    }
    private func beginName(_ path: RemoteFilePath?, local: Bool) { editingPath = path; editingLocal = local; editName = path?.name ?? ""; showingName = true }
    private func phase(_ value: TransferQueuePhase) -> String {
        switch value {
        case .queued: IDELanguageRunText.t("等待传输", "Queued")
        case .running: IDELanguageRunText.t("正在传输", "Transferring")
        case .cancelling: IDELanguageRunText.t("正在取消", "Cancelling")
        case .completed: IDELanguageRunText.t("已完成", "Completed")
        case .cancelled: IDELanguageRunText.t("已取消，半成品保留", "Cancelled; partial file retained")
        case .failed: IDELanguageRunText.t("传输未完成，请检查连接、权限和文件", "Transfer did not finish; check the connection, permissions and files")
        case .conflict: IDELanguageRunText.t("目标已有同名文件", "A file already exists at the destination")
        case .needsReview: IDELanguageRunText.t("连接曾中断，请核对文件后重试", "The connection was interrupted; check the file before retrying")
        }
    }
}
#endif
