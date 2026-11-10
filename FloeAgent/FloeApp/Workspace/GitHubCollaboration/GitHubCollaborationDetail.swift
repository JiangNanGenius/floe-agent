// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeGit

struct GitHubCollaborationDetail: View {
    @Bindable var center: GitHubCollaborationCenter
    let onWorkOnIssue: @MainActor (URL) async throws -> Void
    let onSignIn: @MainActor () -> Void
    @State private var pane = Pane.discussion
    @State private var startingTask = false
    @State private var taskError: String?
    @State private var openingRun = false
    @State private var runLink = ""
    enum Pane: String, CaseIterable, Identifiable {
        case discussion, files, checks
        var id: String { rawValue }
        var title: String {
            switch self {
            case .discussion: ghCollabText("讨论", "Conversation")
            case .files: ghCollabText("文件", "Files")
            case .checks: ghCollabText("检查", "Checks")
            }
        }
    }
    var body: some View {
        Group {
            if center.selection == nil {
                ContentUnavailableView(ghCollabText("选择一个问题或拉取请求", "Select an issue or pull request"),
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(ghCollabText("讨论、评审与检查结果会显示在这里。", "Read discussions, review changes and inspect checks here.")))
            } else if let item = center.issue {
                discussionList(title: item.title, number: item.number, body: item.body, state: item.state, author: item.user?.login)
            } else if let item = center.pull {
                VStack(spacing: 0) {
                    Picker(ghCollabText("拉取请求内容", "Pull request content"), selection: $pane) {
                        ForEach(Pane.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).padding(12)
                    switch pane {
                    case .discussion: discussionList(title: item.title, number: item.number, body: item.body,
                        state: item.merged == true ? "merged" : item.state, author: item.user?.login)
                    case .files: fileList
                    case .checks: checkList
                    }
                }
            } else if let error = center.detailError {
                ContentUnavailableView {
                    Label(ghCollabText("无法载入内容", "Unable to load content"), systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button(ghCollabText("重试", "Retry")) { Task { await center.loadDetail() } }
                    if center.needsSignIn { Button(ghCollabText("连接 GitHub", "Connect GitHub"), action: onSignIn) }
                }
            } else { ProgressView(ghCollabText("正在载入", "Loading")) }
        }
        .navigationTitle(center.selection.map { "#\($0.number)" } ?? ghCollabText("协作", "Collaboration"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: center.selection) { await center.loadDetail() }
        .toolbar { ToolbarItemGroup(placement: .primaryAction) {
            if let url = canonicalURL { Link(destination: url) { Label(ghCollabText("在 GitHub 打开", "Open on GitHub"), systemImage: "arrow.up.right.square") } }
            if center.selection != nil {
                Button { Task { await center.loadDetail() } } label: { Label(ghCollabText("刷新", "Refresh"), systemImage: "arrow.clockwise") }
                    .disabled(center.detailLoading).accessibilityIdentifier("github.collaboration.detail.refresh")
            }
        } }
        .alert(ghCollabText("查看 GitHub 运行", "Open GitHub run"), isPresented: $openingRun) {
            TextField(ghCollabText("运行链接", "Run URL"), text: $runLink)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            Button(ghCollabText("打开", "Open")) {
                if let url = URL(string: runLink) { Task { await center.inspectAction(url) } }
                else { center.detailError = ghCollabText("请输入此仓库的 GitHub Actions 运行链接。", "Enter a GitHub Actions run URL for this repository.") }
            }
            Button(ghCollabText("取消", "Cancel"), role: .cancel) {}
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("github.collaboration.detail")
    }
    private var canonicalURL: URL? {
        guard let selected = center.selection else { return nil }
        let path = selected.id.hasPrefix("pull-") ? "pull" : "issues"
        return ghCollabWebURL(center.scope.repository, [path, String(selected.number)])
    }
    private func discussionList(title: String, number: Int, body: String?, state: String, author: String?) -> some View {
        List {
            Section {
                Text(title).font(.title2.weight(.semibold)).textSelection(.enabled)
                Label(state == "open" ? ghCollabText("打开", "Open") : state == "merged" ? ghCollabText("已合并", "Merged") : ghCollabText("已关闭", "Closed"),
                    systemImage: state == "open" ? "circle" : "checkmark.circle")
                    .font(.subheadline).foregroundStyle(state == "open" ? Color.green : .secondary)
                if let author { Text(author).font(.subheadline).foregroundStyle(.secondary) }
                if let pull = center.pull {
                    Label(pull.base.label + " ← " + pull.head.label, systemImage: "arrow.triangle.branch")
                        .font(.subheadline.monospaced()).textSelection(.enabled)
                    if pull.draft { Label(ghCollabText("草稿拉取请求", "Draft pull request"), systemImage: "doc.badge.ellipsis").foregroundStyle(.secondary) }
                }
                if let body, !body.isEmpty { GitHubCollaborationMarkdown(text: body) }
                else { Text(ghCollabText("暂无说明", "No description provided")).foregroundStyle(.secondary) }
            }
            notices
            Section {
                HStack {
                    Button(ghCollabText("回复", "Reply"), systemImage: "arrowshape.turn.up.left") { Task { await center.beginDraft(.reply) } }
                    Spacer()
                    if let pull = center.pull {
                        Menu(ghCollabText("评审", "Review"), systemImage: "text.bubble") {
                            Button(ghCollabText("提交评审", "Submit review")) { Task { await center.beginDraft(.review) } }
                            Button(ghCollabText("合并拉取请求", "Merge pull request")) { Task { await center.beginDraft(.mergePull) } }
                                .disabled(pull.state != "open" || pull.draft || pull.merged == true)
                        }
                    } else {
                        Button(state == "open" ? ghCollabText("关闭问题", "Close issue") : ghCollabText("重新打开", "Reopen")) {
                            Task { await center.beginDraft(.updateIssue, closeIssue: state == "open") }
                        }
                    }
                }.buttonStyle(.bordered).frame(minHeight: 44).disabled(!center.canWrite)
                if let url = canonicalURL {
                    Button {
                        guard !startingTask else { return }
                        startingTask = true; taskError = nil
                        Task {
                            defer { startingTask = false }
                            do { try await onWorkOnIssue(url) }
                            catch { taskError = ghCollabText("暂时无法打开任务，请重试。", "Unable to open the task. Try again.") }
                        }
                    } label: {
                        Label(ghCollabText("在任务中处理", "Work on this issue"), systemImage: "sparkles")
                    }.disabled(startingTask).frame(minHeight: 44)
                    .accessibilityIdentifier("github.collaboration.workOnIssue")
                    if startingTask { ProgressView(ghCollabText("正在准备任务", "Preparing task")) }
                    if let taskError { Text(taskError).foregroundStyle(.secondary) }
                }
            }
            commentSection(ghCollabText("讨论", "Conversation"), values: center.comments, collection: .comments)
            if center.pull != nil {
                commentSection(ghCollabText("评审", "Reviews"), values: center.reviews, collection: .reviews)
                commentSection(ghCollabText("行内评论", "Line comments"), values: center.lineComments, collection: .lineComments)
            }
        }.listStyle(.insetGrouped)
    }
    @ViewBuilder private var notices: some View {
        if let error = center.storageError {
            GitHubCollaborationNotice(message: error, retry: { Task { await center.bootstrap() } })
        }
        if let error = center.operationError { GitHubCollaborationNotice(message: error) }
        if center.needsSignIn { Button(ghCollabText("连接 GitHub", "Connect GitHub"), action: onSignIn).frame(minHeight: 44) }
        if center.scope.ownerID == nil {
            Text(ghCollabText("从项目或任务打开后可回复与提交更改。", "Open this from a project or task to reply and submit changes.")).foregroundStyle(.secondary)
        }
        if center.initialLink?.pullRequestCommit != nil {
            Text(ghCollabText("此链接包含历史提交；协作页显示当前拉取请求。", "This link includes a historical commit; collaboration shows the current pull request."))
                .font(.caption).foregroundStyle(.secondary)
        }
        if center.activeOperationID != nil { ProgressView(ghCollabText("正在确认并发送", "Checking and sending")) }
    }
    private func commentSection(_ title: String, values: [GitHubCollaborationComment], collection: GitHubCollaborationCollection) -> some View {
        Section(title) {
            ForEach(values) { comment in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(comment.user?.login ?? "GitHub", systemImage: "person.crop.circle").font(.subheadline.weight(.semibold))
                        Spacer()
                        if let state = comment.state { Text(reviewState(state)).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let path = comment.path {
                        Text(path + (comment.line.map { ":\($0)" } ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    GitHubCollaborationMarkdown(text: comment.body)
                }.padding(.vertical, 6).id("comment-\(comment.id)")
            }
            collectionFooter(collection, empty: values.isEmpty)
        }
    }
    @ViewBuilder private func collectionFooter(_ collection: GitHubCollaborationCollection, empty: Bool) -> some View {
        if let error = center.collectionErrors[collection] {
            GitHubCollaborationNotice(message: error, retry: { Task { await center.retryCollection(collection) } })
        } else if center.collectionsLoading.contains(collection) { ProgressView() }
        else if center.detailNextPages[collection] != nil {
            Button(ghCollabText("加载更多", "Load more")) { Task { await center.loadMore(collection) } }.frame(minHeight: 44)
        } else if empty { Text(ghCollabText("暂无内容", "No entries yet")).foregroundStyle(.secondary) }
    }
    private var fileList: some View {
        List {
            ForEach(center.files) { file in
                NavigationLink {
                    GitHubCollaborationFileView(center: center, file: file)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(file.filename, systemImage: "doc.text").font(.subheadline.monospaced()).lineLimit(3)
                        HStack { Text("+\(file.additions)").foregroundStyle(.green); Text("−\(file.deletions)").foregroundStyle(.red) }.font(.caption.monospacedDigit())
                    }.frame(minHeight: 44)
                }
            }
            collectionFooter(.files, empty: center.files.isEmpty)
        }.listStyle(.insetGrouped).accessibilityIdentifier("github.collaboration.files")
    }
    private var checkList: some View {
        List {
            Section {
                Button(ghCollabText("按链接查看运行", "Open a run link"), systemImage: "link") { runLink = ""; openingRun = true }
            }
            if let status = center.commitStatus {
                Section(ghCollabText("提交状态", "Commit status")) {
                    Label(checkState(status.state), systemImage: checkSymbol(status.state))
                    ForEach(status.statuses) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(row.context, systemImage: checkSymbol(row.state))
                            if let detail = row.description { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            if let url = row.targetURL { Link(ghCollabText("查看详情", "View details"), destination: url) }
                        }
                    }
                }
            }
            if let error = center.statusError { GitHubCollaborationNotice(message: error, retry: { Task { await center.loadDetail() } }) }
            Section(ghCollabText("检查", "Checks")) {
                ForEach(center.checks) { check in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(check.name, systemImage: checkSymbol(check.conclusion ?? check.status))
                        Text(checkState(check.conclusion ?? check.status)).font(.caption).foregroundStyle(.secondary)
                        if let url = check.htmlURL {
                            HStack {
                                Link(ghCollabText("在 GitHub 查看", "View on GitHub"), destination: url)
                                if url.path.contains("/actions/runs/") {
                                    Button(ghCollabText("运行操作", "Run actions")) { Task { await center.inspectAction(url) } }
                                }
                            }.font(.subheadline).frame(minHeight: 44)
                        }
                    }.padding(.vertical, 4)
                }
                collectionFooter(.checks, empty: center.checks.isEmpty)
            }
            if let run = center.actionRun {
                Section(ghCollabText("本次运行", "Selected run")) {
                    Text("#\(run.id) · " + checkState(run.conclusion ?? run.status)).font(.subheadline)
                    Text(ghCollabText("第 \(run.runAttempt) 次尝试", "Attempt \(run.runAttempt)")).font(.caption).foregroundStyle(.secondary)
                    NavigationLink {
                        GitHubCollaborationRunView(center: center, run: run)
                    } label: {
                        Label(ghCollabText("任务与失败日志", "Jobs and failure logs"), systemImage: "list.bullet.rectangle")
                    }.accessibilityIdentifier("github.collaboration.run.jobs")
                    Button(ghCollabText("重新运行全部作业", "Re-run all jobs")) { Task { await center.beginDraft(.rerunActions, run: run) } }.disabled(run.status != "completed" || !center.canWrite)
                    Button(ghCollabText("重跑失败作业", "Re-run failed jobs")) { Task { await center.beginDraft(.rerunFailedActions, run: run) } }.disabled(run.status != "completed" || !center.canWrite)
                    Button(ghCollabText("取消运行", "Cancel run"), role: .destructive) { Task { await center.beginDraft(.cancelActions, run: run) } }.disabled(run.status == "completed" || !center.canWrite)
                }
            }
            if let error = center.detailError { GitHubCollaborationNotice(message: error) }
        }.listStyle(.insetGrouped).accessibilityIdentifier("github.collaboration.checks")
    }
    private func reviewState(_ state: String) -> String {
        switch state {
        case "APPROVED": ghCollabText("已批准", "Approved")
        case "CHANGES_REQUESTED": ghCollabText("要求修改", "Changes requested")
        case "COMMENTED": ghCollabText("已评论", "Commented")
        default: state
        }
    }
    private func checkState(_ state: String) -> String {
        switch state {
        case "success": ghCollabText("通过", "Passed")
        case "failure", "error": ghCollabText("失败", "Failed")
        case "queued", "pending", "requested", "waiting": ghCollabText("等待中", "Waiting")
        case "in_progress": ghCollabText("运行中", "Running")
        case "cancelled": ghCollabText("已取消", "Cancelled")
        case "skipped": ghCollabText("已跳过", "Skipped")
        case "completed": ghCollabText("已完成", "Completed")
        default: state
        }
    }
    private func checkSymbol(_ state: String) -> String {
        switch state {
        case "success": "checkmark.circle.fill"
        case "failure", "error": "xmark.circle.fill"
        case "in_progress": "arrow.trianglehead.2.clockwise.rotate.90"
        default: "clock"
        }
    }
}

struct GitHubCollaborationMarkdown: View {
    let text: String
    var body: some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .full))) ?? AttributedString(text))
            .font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
