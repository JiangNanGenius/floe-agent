// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeGit

struct GitHubCollaborationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar
    @State private var center: GitHubCollaborationCenter
    @State private var panel: Panel?
    @State private var pendingDraftID: UUID?
    private let onWorkOnIssue: @MainActor (URL) async throws -> Void
    private let onReturnTask: @MainActor () -> Void
    private let onSignIn: @MainActor () -> Void
    private enum Panel: String, Identifiable { case drafts, history; var id: String { rawValue } }

    init(repository: GitHubLinkRepositoryID, workspaceID: UUID?, sourceTaskID: UUID?,
         service: GitHubCollaborationService, client: GitHubCollaborationClient,
         tokenProvider: @escaping @Sendable () throws -> String, initialLink: GitHubLink? = nil,
         onWorkOnIssue: @escaping @MainActor (URL) async throws -> Void, onReturnTask: @escaping @MainActor () -> Void,
         onSignIn: @escaping @MainActor () -> Void, authorize: @escaping @Sendable () throws -> Void) {
        _center = State(initialValue: GitHubCollaborationCenter(repository: repository, workspaceID: workspaceID,
            sourceTaskID: sourceTaskID, service: service, client: client, tokenProvider: tokenProvider,
            initialLink: initialLink, authorize: authorize))
        self.onWorkOnIssue = onWorkOnIssue; self.onReturnTask = onReturnTask; self.onSignIn = onSignIn
        let opensDetail = initialLink.map { link in
            link.number != nil && (link.kind == .issue || link.kind == .pullRequest) &&
                link.repository.fullName.caseInsensitiveCompare(repository.fullName) == .orderedSame
        } ?? false
        _preferredCompactColumn = State(initialValue: opensDetail ? .detail : .sidebar)
    }
    var body: some View {
        @Bindable var center = center
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(center.scope.repository.fullName, systemImage: "shippingbox")
                        .font(.headline).textSelection(.enabled).lineLimit(2)
                    Picker(ghCollabText("内容", "Content"), selection: $center.section) {
                        ForEach(GitHubCollaborationSection.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    Picker(ghCollabText("状态", "State"), selection: $center.stateFilter) {
                        Text(ghCollabText("打开", "Open")).tag("open")
                        Text(ghCollabText("关闭", "Closed")).tag("closed")
                        Text(ghCollabText("全部", "All")).tag("all")
                    }.pickerStyle(.segmented)
                }.padding(12)
                List(selection: $center.selection) {
                    if let error = center.listError {
                        GitHubCollaborationNotice(message: error, retry: { Task { await center.loadList() } })
                    }
                    if center.section == .issues {
                        ForEach(center.issues.filter { matches($0.title, number: $0.number) }) { item in
                            NavigationLink(value: GitHubCollaborationSelection.issue(item.number)) {
                                GitHubCollaborationThreadRow(title: item.title, number: item.number, state: item.state,
                                    author: item.user?.login, isPull: false, draft: false)
                            }
                        }
                    } else {
                        ForEach(center.pulls.filter { matches($0.title, number: $0.number) }) { item in
                            NavigationLink(value: GitHubCollaborationSelection.pull(item.number)) {
                                GitHubCollaborationThreadRow(title: item.title, number: item.number,
                                    state: item.merged == true ? "merged" : item.state, author: item.user?.login,
                                    isPull: true, draft: item.draft)
                            }
                        }
                    }
                    if center.listLoading { ProgressView(ghCollabText("正在载入", "Loading")) }
                    else if center.listNextPage != nil {
                        Button(ghCollabText("加载更多", "Load more")) { Task { await center.loadList(more: true) } }
                            .frame(minHeight: 44).accessibilityIdentifier("github.collaboration.list.more")
                    } else if center.listError == nil && (center.section == .issues ? center.issues.isEmpty : center.pulls.isEmpty) {
                        ContentUnavailableView(center.section == .issues ? ghCollabText("没有问题", "No issues") : ghCollabText("没有拉取请求", "No pull requests"),
                            systemImage: center.section == .issues ? "exclamationmark.circle" : "arrow.triangle.pull")
                    }
                }
                .listStyle(.sidebar).refreshable { await center.loadList() }
                .accessibilityIdentifier("github.collaboration.list")
            }
            .navigationTitle("GitHub")
            .toolbar {
                if horizontalSizeClass != .compact || preferredCompactColumn == .sidebar { collaborationToolbar }
            }
            .searchable(text: $center.search, prompt: ghCollabText("搜索当前列表", "Search this list"))
            .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 430)
        } detail: {
            GitHubCollaborationDetail(center: center, onWorkOnIssue: { url in try await onWorkOnIssue(url); dismiss() }, onSignIn: onSignIn)
                .toolbar {
                    if horizontalSizeClass == .compact && preferredCompactColumn == .detail { collaborationToolbar }
                }
        }
        .sheet(item: $panel, onDismiss: {
            if let id = pendingDraftID { pendingDraftID = nil; center.draftRoute = .init(id: id) }
        }) { item in
            NavigationStack {
                GitHubCollaborationActivity(center: center, showDrafts: item == .drafts, onSignIn: onSignIn,
                    onOpenDraft: { id in pendingDraftID = id; panel = nil })
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ghCollabText("完成", "Done")) { panel = nil } } }
            }
        }
        .sheet(item: $center.draftRoute) { route in
            GitHubCollaborationComposer(center: center, draftID: route.id, onSignIn: onSignIn)
        }
        .task { await center.bootstrap() }
        .task(id: center.section.rawValue + ":" + center.stateFilter) { await center.loadList() }
        .onChange(of: center.section) { _, next in
            if next == .issues, case .pull = center.selection { center.selection = nil }
            if next == .pulls, case .issue = center.selection { center.selection = nil }
        }
        .onChange(of: center.selection) { _, selection in
            preferredCompactColumn = selection == nil ? .sidebar : .detail
        }
        .onDisappear { center.fenceReads() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("github.collaboration")
    }
    @ToolbarContentBuilder private var collaborationToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(ghCollabText("完成", "Done")) { dismiss() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                if center.scope.sourceTaskID != nil {
                    Button(ghCollabText("返回任务", "Return to task"), systemImage: "arrow.uturn.backward") {
                        onReturnTask(); dismiss()
                    }.accessibilityIdentifier("github.collaboration.returnTask")
                    Divider()
                }
                Button(ghCollabText("新建问题", "New issue"), systemImage: "plus.bubble") { Task { await center.beginDraft(.createIssue) } }.disabled(!center.canWrite)
                Button(ghCollabText("新建拉取请求", "New pull request"), systemImage: "arrow.triangle.pull") { Task { await center.beginDraft(.createPull) } }.disabled(!center.canWrite)
                Divider()
                Button(ghCollabText("草稿", "Drafts"), systemImage: "doc.badge.ellipsis") { panel = .drafts }
                Button(ghCollabText("操作记录", "Activity"), systemImage: "clock.arrow.circlepath") { panel = .history }
                Button(ghCollabText("GitHub 连接", "GitHub connection"), systemImage: "person.crop.circle") { onSignIn() }
            } label: { Label(ghCollabText("协作操作", "Collaboration actions"), systemImage: "plus.circle") }
            .accessibilityIdentifier("github.collaboration.actions")
        }
    }
    private func matches(_ title: String, number: Int) -> Bool {
        center.search.isEmpty || title.localizedCaseInsensitiveContains(center.search) || String(number).contains(center.search.replacingOccurrences(of: "#", with: ""))
    }
}

struct GitHubCollaborationNotice: View {
    let message: String
    var retry: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.secondary)
            if let retry { Button(ghCollabText("重试", "Retry"), action: retry).frame(minHeight: 44) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
struct GitHubCollaborationThreadRow: View {
    let title: String
    let number: Int
    let state: String
    let author: String?
    let isPull: Bool
    let draft: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isPull ? "arrow.triangle.pull" : "exclamationmark.circle")
                .foregroundStyle(state == "open" ? Color.green : state == "merged" ? Color.purple : Color.secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(3)
                HStack(spacing: 8) {
                    Text("#\(number)")
                    if let author { Text(author).lineLimit(1) }
                    if draft { Text(ghCollabText("草稿", "Draft")) }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.frame(minHeight: 44, alignment: .leading).padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("github.collaboration.\(isPull ? "pull" : "issue").\(number)")
    }
}
#endif
