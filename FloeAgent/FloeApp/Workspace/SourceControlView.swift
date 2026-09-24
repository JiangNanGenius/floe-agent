#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeGit

/// One node of the source-control change tree. Folders group changes by
/// directory; files carry the underlying `GitFileChange`. Ids are the full
/// repository-relative path so rows stay stable across refreshes.
struct SourceControlChangeTreeNode: Identifiable, Equatable {
    let id: String
    let name: String
    let change: GitFileChange?
    let children: [SourceControlChangeTreeNode]

    var isFolder: Bool { change == nil }

    /// `OutlineGroup` requires an optional child collection key path and
    /// treats `nil` as a leaf. The tree model keeps its non-optional
    /// `children`; this projection only fails to `nil` where there is nothing
    /// to disclose.
    var outlineChildren: [SourceControlChangeTreeNode]? {
        children.isEmpty ? nil : children
    }
}

/// Builds the nested, directory-grouped change tree shown in the source
/// control surface. Kept UI-free so the grouping is unit-testable.
enum SourceControlChangeTree {
    private final class Box {
        var change: GitFileChange?
        var children: [String: Box] = [:]
        func insert(_ change: GitFileChange, _ components: ArraySlice<String>) {
            guard let first = components.first else { self.change = change; return }
            let child = children[first] ?? Box()
            child.insert(change, components.dropFirst())
            children[first] = child
        }
        func node(id: String, name: String) -> SourceControlChangeTreeNode {
            let childNodes = children
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { $0.value.node(id: id + "/" + $0.key, name: $0.key) }
            return SourceControlChangeTreeNode(id: id, name: name, change: change, children: childNodes)
        }
    }

    /// Groups repository-relative change paths into a sorted folder/file tree.
    static func build(_ changes: [GitFileChange]) -> [SourceControlChangeTreeNode] {
        let root = Box()
        for change in changes {
            let components = change.path.split(separator: "/").map(String.init)
            root.insert(change, ArraySlice(components))
        }
        return root.children
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { $0.value.node(id: $0.key, name: $0.key) }
    }
}

/// The ordinary source-control surface: staged/unstaged changes with
/// per-file stage, unstage and discard (recovery copy kept), working-tree and
/// staged diffs, commits, branch switch/create, fetch/pull (fast-forward and
/// merge variants), push, and merge-conflict resolution. It deliberately
/// exposes no force-push, reset --hard, clean or rebase. Changes render as a
/// collapsible directory tree (not a flat list) so a busy repository stays
/// scannable.
struct SourceControlView: View {
    @ObservedObject var center: SourceControlCenter
    /// Directly observed so a workspace switch that does not publish through
    /// the source-control center still redraws the pane and flips the lock.
    @ObservedObject private var workspaceCenter: WorkspaceCenter
    /// When non-nil, the whole surface is bound to this workspace root: every
    /// write action is disabled and no refresh is run while the app's current
    /// workspace points elsewhere, so a pinned IDE/inspector pane can never
    /// initialize, stage, commit or switch a different repository.
    var pinnedRootURL: URL? = nil
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

    /// True when this pane may operate on the repository the global center
    /// currently resolves to. nil pin keeps the pre-existing global behavior
    /// (FileInspectorView), and a center that has not discovered a root yet
    /// stays interactive while the first snapshot loads.
    private var identityMatches: Bool {
        SourceControlRootIdentity.matches(current: workspaceCenter.currentRootURL, pinned: pinnedRootURL)
    }

    init(center: SourceControlCenter, pinnedRootURL: URL? = nil) {
        self.center = center
        self.pinnedRootURL = pinnedRootURL
        _workspaceCenter = ObservedObject(wrappedValue: center.boundWorkspaceCenter)
    }

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
            if pinnedRootURL != nil && !identityMatches {
                identityMismatch
            } else if center.snapshot.isRepository {
                repositoryContent
            } else {
                // Intentional not-a-repository state: discovery already
                // checked the workspace and its parents, so this is a truthful
                // "no repository here" (not a hidden or failed tree).
                ContentUnavailableView {
                    Label(IDELanguageRunText.t("不是 Git 仓库", "Not a Git Repository"), systemImage: "arrow.triangle.branch")
                } description: {
                    Text(IDELanguageRunText.t("当前工作区及上层目录中都没有 Git 仓库。可以在工作区初始化一个本地仓库；文件仍保留在原位置。", "No Git repository exists in this workspace or its parent folders. You can initialize a local repository here; files stay where they are."))
                } actions: {
                    Button(IDELanguageRunText.t("初始化仓库", "Initialize Repository")) { run { try await center.initializeRepository() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(center.isBusy)
                }
            }
        }
        .disabled(pinnedRootURL != nil && !identityMatches)
        .overlay {
            if center.isBusy { ProgressView().controlSize(.large) }
        }
        .task {
            // A mismatched pane must not refresh the global center: that
            // snapshot belongs to whatever workspace the app switched to.
            if pinnedRootURL == nil || identityMatches { await center.refreshRepository() }
        }
        .refreshable {
            if pinnedRootURL == nil || identityMatches { await center.refreshRepository() }
        }
        .alert(IDELanguageRunText.t("源码管理错误", "Source Control Error"), isPresented: Binding(
            get: { center.errorMessage != nil },
            set: { if !$0 { center.errorMessage = nil } }
        )) {
            Button(IDELanguageRunText.t("好", "OK"), role: .cancel) { center.errorMessage = nil }
        } message: {
            Text(center.errorMessage ?? "")
        }
        .alert(IDELanguageRunText.t("合并", "Merge"), isPresented: Binding(
            get: { mergeNotice != nil },
            set: { if !$0 { mergeNotice = nil } }
        )) {
            Button(IDELanguageRunText.t("好", "OK"), role: .cancel) { mergeNotice = nil }
        } message: {
            Text(mergeNotice ?? "")
        }
        .alert(IDELanguageRunText.t("已保留恢复副本", "Recovery Copy Kept"), isPresented: Binding(
            get: { discardRecovery != nil },
            set: { if !$0 { discardRecovery = nil } }
        )) {
            Button(IDELanguageRunText.t("好", "OK"), role: .cancel) { discardRecovery = nil }
        } message: {
            Text(discardRecovery ?? "")
        }
        .confirmationDialog(
            IDELanguageRunText.t("放弃该文件的修改？未提交内容会先复制到 .git/floe-recovery。", "Discard changes to this file? Uncommitted content is copied to .git/floe-recovery first."),
            isPresented: Binding(
                get: { discardRequest != nil },
                set: { if !$0 { discardRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let change = discardRequest {
                Button(IDELanguageRunText.t("放弃修改", "Discard Changes"), role: .destructive) {
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
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { discardRequest = nil }
        }
        .sheet(isPresented: $showBranches) { branchSheet }
        .sheet(item: $diffRequest) { request in
            NavigationStack {
                Group {
                    if diffText.isEmpty { ContentUnavailableView(IDELanguageRunText.t("没有可显示的差异", "No Differences to Show"), systemImage: "doc.text.magnifyingglass") }
                    else { DiffView(diffText: diffText) }
                }
                .navigationTitle(request.path)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(IDELanguageRunText.t("完成", "Done")) { diffRequest = nil; diffText = "" }
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
                        Button(IDELanguageRunText.t("取消", "Cancel")) { conflictFile = nil; conflictNotice = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(IDELanguageRunText.t("标记已解决", "Mark Resolved")) {
                            let path = file.path
                            let content = conflictText
                            run {
                                let outcome = try await center.resolveConflict(path: path, content: content)
                                if outcome.isConflict {
                                    conflictNotice = String(format: IDELanguageRunText.t("仍有冲突：%@", "Still conflicting: %@"), outcome.conflictedPaths.joined(separator: ", "))
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
                // Surface the real repository root when it is an ancestor of
                // the workspace (a nested checkout or a linked worktree), so
                // the tree is truthful about which repository it inspects.
                if center.isNestedRepository, let root = center.repositoryRoot {
                    LabeledContent(IDELanguageRunText.t("仓库", "Repository")) {
                        Label(root.path, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Button { showBranches = true } label: {
                    LabeledContent(IDELanguageRunText.t("分支", "Branch")) {
                        Label(center.snapshot.branch ?? IDELanguageRunText.t("游离 HEAD", "detached HEAD"), systemImage: "arrow.triangle.branch")
                    }
                }
                .buttonStyle(.plain)
                if let remote = center.snapshot.remoteURL {
                    LabeledContent(IDELanguageRunText.t("远程", "Remote")) { Text(remote).lineLimit(1).truncationMode(.middle) }
                } else {
                    LabeledContent(IDELanguageRunText.t("远程", "Remote")) { Text(IDELanguageRunText.t("未绑定", "Not configured")).foregroundStyle(.secondary) }
                }
            }

            Section(IDELanguageRunText.t("同步", "Sync")) {
                HStack {
                    sourceButton(IDELanguageRunText.t("抓取", "Fetch"), icon: "arrow.down.circle") { try await center.fetch() }
                    sourceButton(IDELanguageRunText.t("拉取", "Pull"), icon: "arrow.down.to.line") { try await center.pull() }
                    sourceButton(IDELanguageRunText.t("推送", "Push"), icon: "arrow.up.to.line") { try await center.push() }
                }
                .buttonStyle(.bordered)
                Button {
                    run {
                        let outcome = try await center.pullMerge()
                        mergeNotice = outcome.isConflict
                            ? String(format: IDELanguageRunText.t("拉取产生冲突：%@", "Pull produced conflicts: %@"), outcome.conflictedPaths.joined(separator: ", "))
                            : outcome.message
                    }
                } label: {
                    Label(IDELanguageRunText.t("拉取并合并", "Pull and Merge"), systemImage: "arrow.triangle.merge")
                }
                .disabled(center.isBusy)
            }

            if !conflictedChanges.isEmpty {
                Section(String(format: IDELanguageRunText.t("冲突（%lld）", "Conflicts (%lld)"), Int64(conflictedChanges.count))) {
                    ForEach(conflictedChanges) { change in
                        Button {
                            openConflict(change.path)
                        } label: {
                            Label(change.path, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(FloeTheme.destructive)
                        }
                        .buttonStyle(.plain)
                    }
                    Button(IDELanguageRunText.t("中止合并", "Abort Merge"), role: .destructive) { run { try await center.abortMerge() } }
                        .disabled(center.isBusy)
                }
            }

            Section(IDELanguageRunText.t("提交", "Commit")) {
                TextField(IDELanguageRunText.t("说明这次修改", "Describe this change"), text: $commitMessage, axis: .vertical)
                    .lineLimit(2...5)
                HStack {
                    Button(IDELanguageRunText.t("暂存全部", "Stage All")) { run { try await center.stageAll() } }
                    Spacer()
                    Button(IDELanguageRunText.t("提交", "Commit")) {
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
                Section(String(format: IDELanguageRunText.t("已暂存（%lld）", "Staged (%lld)"), Int64(stagedChanges.count))) {
                    OutlineGroup(SourceControlChangeTree.build(stagedChanges), children: \.outlineChildren) { node in
                        changeNodeRow(node, staged: true)
                    }
                }
            }

            Section(String(format: IDELanguageRunText.t("更改（%lld）", "Changes (%lld)"), Int64(unstagedChanges.count))) {
                if unstagedChanges.isEmpty {
                    Text(IDELanguageRunText.t("工作区干净", "Working tree clean")).foregroundStyle(.secondary)
                } else {
                    OutlineGroup(SourceControlChangeTree.build(unstagedChanges), children: \.outlineChildren) { node in
                        changeNodeRow(node, staged: false)
                    }
                }
            }

            if !center.snapshot.recentCommits.isEmpty {
                Section(IDELanguageRunText.t("最近提交", "Recent Commits")) {
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

    /// A tree node row: folders render as collapsible branches, files render
    /// as the existing change row with stage/unstage/discard swipe actions.
    @ViewBuilder private func changeNodeRow(_ node: SourceControlChangeTreeNode, staged: Bool) -> some View {
        if let change = node.change {
            changeRow(change, staged: staged)
        } else {
            Label(node.name, systemImage: "folder")
                .foregroundStyle(.primary)
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
                    Text((change.path as NSString).lastPathComponent).lineLimit(1)
                    Text(change.path).lineLimit(1).truncationMode(.middle)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if staged {
                Button(IDELanguageRunText.t("取消暂存", "Unstage")) { run { try await center.unstage(paths: [change.path]) } }
                    .tint(.orange)
            } else {
                Button(IDELanguageRunText.t("暂存", "Stage")) { run { try await center.stage(paths: [change.path]) } }
                    .tint(.green)
            }
            Button(IDELanguageRunText.t("放弃修改", "Discard Changes"), role: .destructive) { discardRequest = change }
        }
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
                Section(IDELanguageRunText.t("切换分支", "Switch Branch")) {
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
                Section(IDELanguageRunText.t("合并到当前分支", "Merge into Current Branch")) {
                    ForEach(center.snapshot.branches.filter { $0 != center.snapshot.branch }, id: \.self) { branch in
                        Button {
                            showBranches = false
                            run {
                                let outcome = try await center.merge(branch: branch)
                                mergeNotice = outcome.isConflict
                                    ? String(format: IDELanguageRunText.t("合并产生冲突：%@", "Merge produced conflicts: %@"), outcome.conflictedPaths.joined(separator: ", "))
                                    : outcome.message
                            }
                        } label: {
                            Label(String(format: IDELanguageRunText.t("合并 %@", "Merge %@"), branch), systemImage: "arrow.triangle.merge")
                        }
                    }
                }
                Section(IDELanguageRunText.t("新分支", "New Branch")) {
                    TextField(IDELanguageRunText.t("分支名称", "Branch Name"), text: $branchName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(IDELanguageRunText.t("创建并切换", "Create and Switch")) {
                        let name = branchName
                        showBranches = false
                        run { try await center.createBranch(name: name); branchName = "" }
                    }
                    .disabled(branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(IDELanguageRunText.t("分支", "Branches"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(IDELanguageRunText.t("取消", "Cancel")) { showBranches = false } }
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
        Task { await center.perform(pinnedRoot: pinnedRootURL, operation) }
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

    /// Read-only lock shown when the pane's pinned workspace is no longer
    /// the app's current one: every write would otherwise target the global
    /// center's repository, which can belong to a different workspace.
    private var identityMismatch: some View {
        ContentUnavailableView {
            Label(
                IDELanguageRunText.t("工作区已切换", "Workspace Switched"),
                systemImage: "exclamationmark.lock"
            )
        } description: {
            Text(IDELanguageRunText.t(
                "此处的源码管理属于打开此面板时的工作区。当前已切换到其他工作区，为避免提交或暂存错误的仓库，本面板已锁定。请重新打开该工作区的 IDE。",
                "This source-control panel belongs to the workspace it was opened for. The app is now on a different workspace, so the panel is locked to avoid staging or committing the wrong repository. Reopen the IDE for that workspace."
            ))
        }
        .accessibilityIdentifier("workspace.ide.scm.identityLock")
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
