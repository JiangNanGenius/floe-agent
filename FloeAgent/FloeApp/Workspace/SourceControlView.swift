#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeGit

/// The ordinary source-control surface: staged/unstaged changes with
/// per-file stage, unstage and discard (recovery copy kept), working-tree and
/// staged diffs, commits, branch switch/create, fetch/pull (fast-forward and
/// merge variants), push, and merge-conflict resolution. It deliberately
/// exposes no force-push, reset --hard, clean or rebase.
struct SourceControlView: View {
    @ObservedObject var center: SourceControlCenter
    @State private var commitMessage = ""
    @State private var diffRequest: DiffRequest?
    @State private var diffText = ""
    @State private var branchName = ""
    @State private var showBranches = false
    @State private var conflictFile: GitConflictFile?
    @State private var conflictText = ""
    @State private var conflictNotice: String?
    @State private var mergeNotice: String?
    @State private var discardRequest: GitFileChange?
    @State private var discardRecovery: String?

    private struct DiffRequest: Identifiable {
        let path: String
        let staged: Bool
        var id: String { (staged ? "staged:" : "worktree:") + path }
    }

    private struct GitConflictFile: Identifiable {
        let path: String
        var id: String { path }
    }

    var body: some View {
        Group {
            if center.snapshot.isRepository {
                repositoryContent
            } else {
                ContentUnavailableView {
                    Label("尚未初始化 Git", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("在当前工作区建立本地仓库；文件仍保留在原位置。")
                } actions: {
                    Button("初始化仓库") { run { try await center.initializeRepository() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(center.isBusy)
                }
            }
        }
        .overlay {
            if center.isBusy { ProgressView().controlSize(.large) }
        }
        .task { await center.refreshRepository() }
        .refreshable { await center.refreshRepository() }
        .alert("源码管理错误", isPresented: Binding(
            get: { center.errorMessage != nil },
            set: { if !$0 { center.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { center.errorMessage = nil }
        } message: {
            Text(center.errorMessage ?? "")
        }
        .alert("合并", isPresented: Binding(
            get: { mergeNotice != nil },
            set: { if !$0 { mergeNotice = nil } }
        )) {
            Button("好", role: .cancel) { mergeNotice = nil }
        } message: {
            Text(mergeNotice ?? "")
        }
        .alert("已保留恢复副本", isPresented: Binding(
            get: { discardRecovery != nil },
            set: { if !$0 { discardRecovery = nil } }
        )) {
            Button("好", role: .cancel) { discardRecovery = nil }
        } message: {
            Text(discardRecovery ?? "")
        }
        .confirmationDialog(
            "放弃该文件的修改？未提交内容会先复制到 .git/floe-recovery。",
            isPresented: Binding(
                get: { discardRequest != nil },
                set: { if !$0 { discardRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let change = discardRequest {
                Button("放弃修改", role: .destructive) {
                    let path = change.path
                    // A staged row reverts the path to HEAD (index + working
                    // tree); an unstaged row only restores the working tree.
                    let includeStaged = change.staged
                    discardRequest = nil
                    run {
                        let outcome = try await center.discard(paths: [path], includeStaged: includeStaged)
                        if let recovery = outcome.recoveryPath { discardRecovery = recovery }
                    }
                }
            }
            Button("取消", role: .cancel) { discardRequest = nil }
        }
        .sheet(isPresented: $showBranches) { branchSheet }
        .sheet(item: $diffRequest) { request in
            NavigationStack {
                Group {
                    if diffText.isEmpty { ContentUnavailableView("没有可显示的差异", systemImage: "doc.text.magnifyingglass") }
                    else { DiffView(diffText: diffText) }
                }
                .navigationTitle(request.path)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("完成") { diffRequest = nil; diffText = "" }
                    }
                }
            }
        }
        .sheet(item: $conflictFile) { file in
            NavigationStack {
                VStack(spacing: 0) {
                    if let conflictNotice {
                        Label(conflictNotice, systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.bar)
                    }
                    TextEditor(text: $conflictText)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("sourceControl.conflict.editor")
                }
                .navigationTitle(file.path)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { conflictFile = nil; conflictNotice = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("标记已解决") {
                            let path = file.path
                            let content = conflictText
                            run {
                                let outcome = try await center.resolveConflict(path: path, content: content)
                                if outcome.isConflict {
                                    conflictNotice = "仍有冲突：" + outcome.conflictedPaths.joined(separator: ", ")
                                } else {
                                    conflictFile = nil
                                    conflictNotice = nil
                                    mergeNotice = outcome.message
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var repositoryContent: some View {
        List {
            Section {
                Button { showBranches = true } label: {
                    LabeledContent("分支") {
                        Label(center.snapshot.branch ?? "游离 HEAD", systemImage: "arrow.triangle.branch")
                    }
                }
                .buttonStyle(.plain)
                if let remote = center.snapshot.remoteURL {
                    LabeledContent("远程") { Text(remote).lineLimit(1).truncationMode(.middle) }
                } else {
                    LabeledContent("远程") { Text("未绑定").foregroundStyle(.secondary) }
                }
            }

            Section("同步") {
                HStack {
                    sourceButton("抓取", icon: "arrow.down.circle") { try await center.fetch() }
                    sourceButton("拉取", icon: "arrow.down.to.line") { try await center.pull() }
                    sourceButton("推送", icon: "arrow.up.to.line") { try await center.push() }
                }
                .buttonStyle(.bordered)
                Button {
                    run {
                        let outcome = try await center.pullMerge()
                        mergeNotice = outcome.isConflict
                            ? "拉取产生冲突：" + outcome.conflictedPaths.joined(separator: ", ")
                            : outcome.message
                    }
                } label: {
                    Label("拉取并合并", systemImage: "arrow.triangle.merge")
                }
                .disabled(center.isBusy)
            }

            if !conflictedChanges.isEmpty {
                Section("冲突（\(conflictedChanges.count)）") {
                    ForEach(conflictedChanges) { change in
                        Button {
                            openConflict(change.path)
                        } label: {
                            Label(change.path, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(FloeTheme.destructive)
                        }
                        .buttonStyle(.plain)
                    }
                    Button("中止合并", role: .destructive) { run { try await center.abortMerge() } }
                        .disabled(center.isBusy)
                }
            }

            Section("提交") {
                TextField("说明这次修改", text: $commitMessage, axis: .vertical)
                    .lineLimit(2...5)
                HStack {
                    Button("暂存全部") { run { try await center.stageAll() } }
                    Spacer()
                    Button("提交") {
                        let message = commitMessage
                        run {
                            try await center.commit(message: message)
                            commitMessage = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if !stagedChanges.isEmpty {
                Section("已暂存（\(stagedChanges.count)）") {
                    ForEach(stagedChanges) { change in
                        changeRow(change, staged: true)
                            .swipeActions(edge: .trailing) {
                                Button("取消暂存") { run { try await center.unstage(paths: [change.path]) } }
                                    .tint(.orange)
                                Button("放弃修改", role: .destructive) { discardRequest = change }
                            }
                    }
                }
            }

            Section("更改（\(unstagedChanges.count)）") {
                if unstagedChanges.isEmpty {
                    Text("工作区干净").foregroundStyle(.secondary)
                } else {
                    ForEach(unstagedChanges) { change in
                        changeRow(change, staged: false)
                            .swipeActions(edge: .trailing) {
                                Button("暂存") { run { try await center.stage(paths: [change.path]) } }
                                    .tint(.green)
                                Button("放弃修改", role: .destructive) { discardRequest = change }
                            }
                    }
                }
            }

            if !center.snapshot.recentCommits.isEmpty {
                Section("最近提交") {
                    ForEach(center.snapshot.recentCommits.prefix(20)) { commit in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(commit.message).lineLimit(2)
                            HStack {
                                Text(commit.shortOID).font(.caption.monospaced())
                                Text(commit.author)
                                Spacer()
                                Text(commit.date, style: .relative)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await center.refreshRepository() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(center.isBusy)
            }
        }
    }

    private func changeRow(_ change: GitFileChange, staged: Bool) -> some View {
        Button { loadDiff(change.path, staged: staged) } label: {
            HStack(spacing: 10) {
                Text(change.kind.badge)
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(change.kind.color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.path).lineLimit(1).truncationMode(.middle)
                    Text(staged ? "已暂存 · 查看暂存差异" : "未暂存 · 查看工作区差异")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private var stagedChanges: [GitFileChange] {
        center.snapshot.changes.filter { $0.staged && $0.kind != .conflicted }
    }

    private var unstagedChanges: [GitFileChange] {
        center.snapshot.changes.filter { !$0.staged && $0.kind != .conflicted }
    }

    private var conflictedChanges: [GitFileChange] {
        center.snapshot.changes.filter { $0.kind == .conflicted }
    }

    private var branchSheet: some View {
        NavigationStack {
            List {
                Section("切换分支") {
                    ForEach(center.snapshot.branches, id: \.self) { branch in
                        Button {
                            showBranches = false
                            run { try await center.switchBranch(name: branch) }
                        } label: {
                            HStack {
                                Text(branch)
                                Spacer()
                                if branch == center.snapshot.branch { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(branch == center.snapshot.branch)
                    }
                }
                Section("合并到当前分支") {
                    ForEach(center.snapshot.branches.filter { $0 != center.snapshot.branch }, id: \.self) { branch in
                        Button {
                            showBranches = false
                            run {
                                let outcome = try await center.merge(branch: branch)
                                mergeNotice = outcome.isConflict
                                    ? "合并产生冲突：" + outcome.conflictedPaths.joined(separator: ", ")
                                    : outcome.message
                            }
                        } label: {
                            Label("合并 \(branch)", systemImage: "arrow.triangle.merge")
                        }
                    }
                }
                Section("新分支") {
                    TextField("分支名称", text: $branchName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("创建并切换") {
                        let name = branchName
                        showBranches = false
                        run { try await center.createBranch(name: name); branchName = "" }
                    }
                    .disabled(branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("分支")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { showBranches = false } }
            }
        }
    }

    private func sourceButton(
        _ title: String,
        icon: String,
        operation: @escaping @MainActor () async throws -> Void
    ) -> some View {
        Button { run(operation) } label: { Label(title, systemImage: icon) }
            .disabled(center.isBusy)
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        Task { await center.perform(operation) }
    }

    private func loadDiff(_ path: String, staged: Bool) {
        diffRequest = DiffRequest(path: path, staged: staged)
        diffText = ""
        Task {
            do {
                diffText = staged
                    ? try await center.diffStaged(path: path)
                    : try await center.diff(path: path)
            } catch {
                center.errorMessage = error.localizedDescription
                diffRequest = nil
            }
        }
    }

    private func openConflict(_ path: String) {
        conflictNotice = nil
        Task {
            do {
                conflictText = try await center.conflictFileContents(path: path)
                conflictFile = GitConflictFile(path: path)
            } catch { center.errorMessage = error.localizedDescription }
        }
    }
}

private extension GitChangeKind {
    var badge: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .typeChanged: "T"
        case .conflicted: "!"
        case .untracked: "U"
        }
    }

    var color: Color {
        switch self {
        case .added, .untracked: FloeTheme.success
        case .deleted, .conflicted: FloeTheme.destructive
        default: FloeTheme.primary
        }
    }
}
#endif
