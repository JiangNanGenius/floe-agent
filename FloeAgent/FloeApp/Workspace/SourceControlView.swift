#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeGit

/// A deliberately lightweight source-control surface: repository state,
/// changed files, diffs, commits and safe branch/network operations. It does
/// not expose destructive reset, clean, force-push or history rewriting.
struct SourceControlView: View {
    @ObservedObject var center: SourceControlCenter
    @State private var commitMessage = ""
    @State private var selectedDiffPath: String?
    @State private var diffText = ""
    @State private var branchName = ""
    @State private var showBranches = false

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
        .sheet(isPresented: $showBranches) { branchSheet }
        .sheet(isPresented: Binding(
            get: { selectedDiffPath != nil },
            set: { if !$0 { selectedDiffPath = nil; diffText = "" } }
        )) {
            NavigationStack {
                Group {
                    if diffText.isEmpty { ContentUnavailableView("没有可显示的差异", systemImage: "doc.text.magnifyingglass") }
                    else { DiffView(diffText: diffText) }
                }
                .navigationTitle(selectedDiffPath ?? "工作区差异")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("完成") { selectedDiffPath = nil; diffText = "" }
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

            Section("更改（\(center.snapshot.changes.count)）") {
                if center.snapshot.changes.isEmpty {
                    Text("工作区干净").foregroundStyle(.secondary)
                } else {
                    ForEach(center.snapshot.changes) { change in
                        Button { loadDiff(change.path) } label: {
                            HStack(spacing: 10) {
                                Text(change.kind.badge)
                                    .font(.caption.monospaced().bold())
                                    .foregroundStyle(change.kind.color)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(change.path).lineLimit(1).truncationMode(.middle)
                                    if change.staged { Text("已暂存").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
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

    private func loadDiff(_ path: String) {
        selectedDiffPath = path
        diffText = ""
        Task {
            do { diffText = try await center.diff(path: path) }
            catch { center.errorMessage = error.localizedDescription; selectedDiffPath = nil }
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
