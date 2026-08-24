#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeGit

struct GitHubSettingsView: View {
    @ObservedObject var center: SourceControlCenter
    @State private var token = ""
    @State private var showCreateRepository = false
    @State private var repositoryName = ""
    @State private var repositoryDescription = ""
    @State private var repositoryIsPrivate = true
    @State private var cloneTarget: GitHubRepository?

    var body: some View {
        Form {
            Section("GitHub 连接") {
                if let account = center.account {
                    LabeledContent("账户") {
                        Label(account.login, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(FloeTheme.success)
                    }
                    Button("断开连接", role: .destructive) {
                        do { try center.disconnect() }
                        catch { center.errorMessage = error.localizedDescription }
                    }
                } else {
                    SecureField("GitHub 细粒度访问令牌", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                    Button("验证并连接") {
                        let value = token
                        Task {
                            do {
                                try await center.connect(token: value)
                                token = ""
                            } catch {
                                token = ""
                                center.errorMessage = error.localizedDescription
                            }
                        }
                    }
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || center.isBusy)
                }
                Text("凭据只保存在本机钥匙串。Floe 不会把令牌写入仓库、远程地址、日志或模型上下文。")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }

            if center.isGitHubConnected {
                Section {
                    Button { showCreateRepository = true } label: {
                        Label("新建 GitHub 仓库", systemImage: "plus.square.on.square")
                    }
                    Button {
                        Task { await center.loadConnection() }
                    } label: {
                        Label("刷新仓库列表", systemImage: "arrow.clockwise")
                    }
                }

                Section("云端仓库") {
                    if center.repositories.isEmpty {
                        Text("当前账户没有可访问的仓库").foregroundStyle(.secondary)
                    }
                    ForEach(center.repositories) { repository in
                        Button { cloneTarget = repository } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(repository.fullName).lineLimit(1)
                                    Spacer()
                                    Text(repository.isPrivate ? "私有" : "公开")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                HStack {
                                    Label(repository.defaultBranch, systemImage: "arrow.triangle.branch")
                                    Spacer()
                                    Text("克隆到当前工作区")
                                }
                                .font(.caption)
                                .foregroundStyle(FloeTheme.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("GitHub 与源码管理")
        .task { await center.loadConnection() }
        .overlay { if center.isBusy { ProgressView().controlSize(.large) } }
        .alert("GitHub 连接错误", isPresented: Binding(
            get: { center.errorMessage != nil },
            set: { if !$0 { center.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { center.errorMessage = nil }
        } message: {
            Text(center.errorMessage ?? "")
        }
        .confirmationDialog(
            "克隆仓库",
            isPresented: Binding(get: { cloneTarget != nil }, set: { if !$0 { cloneTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("克隆到当前工作区") {
                guard let repository = cloneTarget else { return }
                cloneTarget = nil
                Task { await center.perform { try await center.clone(repository) } }
            }
            Button("取消", role: .cancel) { cloneTarget = nil }
        } message: {
            Text(cloneTarget.map { "将创建子文件夹 \($0.name)" } ?? "")
        }
        .sheet(isPresented: $showCreateRepository) { createRepositorySheet }
    }

    private var createRepositorySheet: some View {
        NavigationStack {
            Form {
                TextField("仓库名称", text: $repositoryName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("说明（可选）", text: $repositoryDescription, axis: .vertical)
                Toggle("私有仓库", isOn: $repositoryIsPrivate)
            }
            .navigationTitle("新建 GitHub 仓库")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { showCreateRepository = false } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建") {
                        let name = repositoryName
                        let description = repositoryDescription
                        let isPrivate = repositoryIsPrivate
                        showCreateRepository = false
                        Task {
                            await center.perform {
                                try await center.createGitHubRepository(
                                    name: name, isPrivate: isPrivate, description: description
                                )
                                repositoryName = ""
                                repositoryDescription = ""
                                repositoryIsPrivate = true
                            }
                        }
                    }
                    .disabled(repositoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
#endif
