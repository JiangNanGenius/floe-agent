import Foundation
import SwiftUI
import FloeToolboxCore
import FloeToolboxRemoteFiles


public enum TerminalSidePanel: String, Hashable, Sendable { case assistant, files }
/// Wrap the existing terminal feature. System inspector adapts to sheets on compact screens.
public struct TerminalToolboxWorkspace<Terminal: View, Assistant: View, Files: View>: View {
    @Environment(\.locale) private var toolboxLocale
    private func fileText(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    @Binding private var panel: TerminalSidePanel?
    private let terminal: Terminal
    private let assistant: Assistant
    private let files: Files
    public init(panel: Binding<TerminalSidePanel?>, @ViewBuilder terminal: () -> Terminal,
                @ViewBuilder assistant: () -> Assistant, @ViewBuilder files: () -> Files) {
        _panel = panel; self.terminal = terminal(); self.assistant = assistant(); self.files = files()
    }
    public var body: some View {
        terminal.toolbar {
            ToolbarItemGroup(placement:.primaryAction) {
                Button(fileText("文件","Files"),systemImage:"folder") { panel = panel == .files ? nil : .files }
                Button(fileText("AI 助手","AI assistant"),systemImage:"sparkles") { panel = panel == .assistant ? nil : .assistant }
            }
        }.inspector(isPresented:Binding(get:{ panel != nil },set:{ if !$0 { panel = nil } })) {
            Group {
                switch panel {
                case .assistant: assistant
                case .files: files
                case nil: EmptyView()
                }
            }.inspectorColumnWidth(min:280,ideal:320,max:420)
        }
    }
}

public enum RemoteFilesViewAction: Sendable {
    case directory(RemoteFilePath), openFile(RemoteFilePath), download(Set<RemoteFilePath>), upload(RemoteFilePath)
    case newFolder(RemoteFilePath), rename(RemoteFilePath), delete(RemoteFilePath), information(RemoteFilePath), followLink(RemoteFilePath)
    case refresh, expand
}
/// Immutable host-owned directory state; every action carries the original lease back to the host.
public struct RemoteFilesPanel: View {
    @Environment(\.locale) private var toolboxLocale
    private func fileText(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    private let lease: SessionLease
    private let title: String
    private let root: RemoteFilePath
    private let directory: RemoteFilePath
    private let entries: [RemoteFileEntry]
    private let capabilities: Set<RemoteFileCapability>
    private let loading: Bool
    private let failureMessage: String?
    private let onAction: (SessionLease,RemoteFilesViewAction) -> Void
    @State private var selection: Set<RemoteFilePath> = []
    public init(lease: SessionLease, title: String, root: RemoteFilePath, directory: RemoteFilePath,
                entries: [RemoteFileEntry], capabilities: Set<RemoteFileCapability>, loading: Bool = false,
                failureMessage: String? = nil, onAction: @escaping (SessionLease,RemoteFilesViewAction) -> Void) {
        self.lease = lease; self.title = title; self.root = root; self.directory = directory
        self.entries = entries; self.capabilities = capabilities; self.loading = loading
        self.failureMessage = failureMessage; self.onAction = onAction
    }
    private func action(_ action: RemoteFilesViewAction) { onAction(lease,action) }
    public var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(fileText("刷新","Refresh"),systemImage:"arrow.clockwise") { action(.refresh) }.labelStyle(.iconOnly).disabled(loading)
                Button(fileText("展开文件管理","Expand file manager"),systemImage:"arrow.up.left.and.arrow.down.right") { action(.expand) }.labelStyle(.iconOnly)
            }
            HStack(alignment:.top) {
                Button(fileText("上一级","Parent folder"),systemImage:"arrow.up") { action(.directory(directory.parent)) }
                    .labelStyle(.iconOnly).disabled(directory == root || loading)
                Text(directory.value).font(.callout.monospaced()).textSelection(.enabled).lineLimit(3)
            }
            if let failureMessage { Text(failureMessage).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
            if loading { ProgressView(fileText("正在读取目录","Loading folder")) }
            List(selection:$selection) {
                ForEach(entries.sorted(by:ordered)) { entry in
                    Button {
                        if entry.kind == .directory { action(.directory(entry.path)) }
                        else if entry.kind == .symbolicLink { action(.information(entry.path)) }
                        else { action(.openFile(entry.path)) }
                    } label: {
                        HStack(spacing:10) {
                            Image(systemName:symbol(entry.kind)).foregroundStyle(.tint)
                            Text(entry.path.name).foregroundStyle(.primary)
                            Spacer()
                            if let count = entry.revision.byteCount, entry.kind != .directory {
                                Text(ByteCountFormatter.string(fromByteCount:Int64(clamping:count),countStyle:.file)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(minHeight:36)
                    }.tag(entry.path).contextMenu { menu(entry) }
                }
            }.listStyle(.plain).overlay {
                if entries.isEmpty, !loading, failureMessage == nil { ContentUnavailableView(fileText("文件夹为空","Empty folder"),systemImage:"folder") }
            }
            ViewThatFits(in:.horizontal) {
                HStack { transferButtons }
                VStack(alignment:.leading) { transferButtons }
            }
        }.padding().onChange(of:lease) { _,_ in selection.removeAll() }
            .onChange(of:directory) { _,_ in selection.removeAll() }
            .onChange(of:entries) { _,newValue in selection.formIntersection(Set(newValue.map(\.path))) }
    }
    private var transferButtons: some View {
        Group {
            Button(fileText("上传","Upload"),systemImage:"square.and.arrow.up") { action(.upload(directory)) }.disabled(!capabilities.contains(.write) || loading)
            Button(fileText("下载所选","Download selected"),systemImage:"square.and.arrow.down") { action(.download(selection)) }.disabled(selection.isEmpty || !capabilities.contains(.read) || loading)
            if capabilities.contains(.createDirectory) { Button(fileText("新建文件夹","New folder"),systemImage:"folder.badge.plus") { action(.newFolder(directory)) }.disabled(loading) }
        }.buttonStyle(.bordered)
    }
    @ViewBuilder private func menu(_ entry: RemoteFileEntry) -> some View {
        if capabilities.contains(.read), entry.kind == .file { Button(fileText("下载","Download")) { action(.download([entry.path])) } }
        if entry.kind == .symbolicLink, capabilities.contains(.resolveLink) { Button(fileText("打开链接目标","Open link target")) { action(.followLink(entry.path)) } }
        if capabilities.contains(.rename) { Button(fileText("重命名","Rename")) { action(.rename(entry.path)) } }
        Button(fileText("文件信息","File information")) { action(.information(entry.path)) }
        if capabilities.contains(.delete) { Button(fileText("删除","Delete"),role:.destructive) { action(.delete(entry.path)) } }
    }
    private func symbol(_ kind: RemoteFileKind) -> String {
        switch kind { case .directory: "folder"; case .symbolicLink: "link"; case .file,.unknown: "doc" }
    }
    private func ordered(_ a: RemoteFileEntry, _ b: RemoteFileEntry) -> Bool {
        if (a.kind == .directory) != (b.kind == .directory) { return a.kind == .directory }
        return a.path.name.localizedStandardCompare(b.path.name) == .orderedAscending
    }
}

public struct RemoteFilesWorkspace<LocalFiles: View, RemoteFiles: View, Transfers: View>: View {
    @Environment(\.locale) private var toolboxLocale
    private func fileText(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    private let local: LocalFiles
    private let remote: RemoteFiles
    private let transfers: Transfers
    @State private var remoteSelected = true
    public init(@ViewBuilder local: () -> LocalFiles, @ViewBuilder remote: () -> RemoteFiles, @ViewBuilder transfers: () -> Transfers) {
        self.local = local(); self.remote = remote(); self.transfers = transfers()
    }
    public var body: some View {
        GeometryReader { geometry in
            VStack(spacing:0) {
                if geometry.size.width >= 720 {
                    HStack(spacing:0) { local.frame(maxWidth:.infinity); Divider(); remote.frame(maxWidth:.infinity) }
                } else {
                    Picker(fileText("文件位置","File location"),selection:$remoteSelected) {
                        Text(fileText("我的文件","My files")).tag(false)
                        Text(fileText("远端文件","Remote files")).tag(true)
                    }.pickerStyle(.segmented).padding()
                    if remoteSelected { remote } else { local }
                }
                Divider(); transfers
            }
        }
    }
}

public struct RemoteTransferQueueItem: Identifiable, Sendable {
    public let title: String
    public let route: String
    public let snapshot: RemoteTransferSnapshot
    public let canRetry: Bool
    public var id: UUID { snapshot.id }
    public init(title: String, route: String, snapshot: RemoteTransferSnapshot, canRetry: Bool) {
        self.title = title; self.route = route; self.snapshot = snapshot; self.canRetry = canRetry
    }
}
public enum RemoteTransferQueueAction: Sendable { case cancel(UUID), retry(UUID), review(UUID) }
public struct RemoteTransferQueueView: View {
    @Environment(\.locale) private var toolboxLocale
    private func fileText(_ zh: String,_ en: String) -> String { toolboxLocale.language.languageCode?.identifier == "zh" ? zh : en }
    private let items: [RemoteTransferQueueItem]
    private let onAction: (RemoteTransferQueueAction) -> Void
    public init(items: [RemoteTransferQueueItem], onAction: @escaping (RemoteTransferQueueAction) -> Void) { self.items = items; self.onAction = onAction }
    public var body: some View {
        DisclosureGroup(fileText("传输队列","Transfers")) {
            ScrollView {
                LazyVStack(alignment:.leading,spacing:14) {
                    ForEach(items) { item in
                        VStack(alignment:.leading,spacing:6) {
                            HStack {
                                Text(item.title).lineLimit(2); Spacer()
                                switch item.snapshot.phase {
                                case .preparing,.verifyingPartial,.transferring:
                                    Button(fileText("取消","Cancel")) { onAction(.cancel(item.id)) }
                                case .failed,.cancelled:
                                    if item.canRetry { Button(fileText("重试","Retry")) { onAction(.retry(item.id)) } }
                                case .needsReview:
                                    Button(fileText("核对结果","Check result")) { onAction(.review(item.id)) }
                                default: EmptyView()
                                }
                            }
                            Text(item.route).font(.caption).foregroundStyle(.secondary)
                            if let total = item.snapshot.totalBytes, total > 0 {
                                ProgressView(value:Double(min(total,item.snapshot.completedBytes)),total:Double(total))
                            } else if [.preparing,.verifyingPartial,.transferring,.committing].contains(item.snapshot.phase) { ProgressView() }
                            Text(status(item.snapshot.phase)).font(.caption)
                            Text(ByteCountFormatter.string(fromByteCount:Int64(clamping:item.snapshot.completedBytes),countStyle:.file)).font(.caption.monospacedDigit())
                        }
                    }
                    if items.isEmpty { Text(fileText("暂无传输任务","No transfers")).foregroundStyle(.secondary) }
                }.padding(.top,8)
            }.frame(maxHeight:180)
        }.padding()
    }
    private func status(_ phase: RemoteTransferPhase) -> String {
        switch phase {
        case .preparing: fileText("正在准备","Preparing")
        case .verifyingPartial: fileText("正在校验半成品","Verifying partial file")
        case .transferring: fileText("正在传输","Transferring")
        case .committing: fileText("正在保存","Saving")
        case .completed: fileText("已完成","Completed")
        case .completedAfterInvalidation: fileText("已完成，会话已结束","Completed; session ended")
        case .cancelled: fileText("已取消，保留半成品","Cancelled; partial file kept")
        case .failed: fileText("传输未完成","Transfer did not finish")
        case .needsReview: fileText("请核对远端是否已保存","Check whether the remote file was saved")
        }
    }
}
