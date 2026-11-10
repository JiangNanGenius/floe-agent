// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeGit
import FloeSecurity
import FloePersistence
import FloeSync

/// Reuses the saved vault/profile handles. Password/key material never enters
/// the selection model, source-control snapshot or operation result.
struct SourceControlCredentialsView: View {
    @ObservedObject var center: SourceControlCenter
    let endpoint: GitRemoteEndpoint
    let scope: GitCredentialScope
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var tokenID: UUID?
    @State private var hostID: UUID?
    @State private var username = "git"
    @State private var options: [GitCredentialOption] = []
    @State private var hosts: [GitCredentialOption] = []
    @State private var saving = false
    @State private var notice: String?
    @State private var addToken = false
    @State private var tokenLabel = ""
    @State private var tokenSecret = ""
    @State private var showHosts = false

    var body: some View {
        Form {
            Section {
                LabeledContent(IDELanguageRunText.t("仓库主机", "Repository Host"), value: endpoint.origin)
                Picker(IDELanguageRunText.t("身份验证", "Authentication"), selection: $mode) {
                    Text(IDELanguageRunText.t("自动选择", "Automatic")).tag(0)
                    if endpoint.transport == .https {
                        Text(IDELanguageRunText.t("无需登录", "No Sign-In")).tag(1)
                        Text(IDELanguageRunText.t("已保存的凭据", "Saved Credential")).tag(2)
                    } else { Text(IDELanguageRunText.t("已保存的 SSH 连接", "Saved SSH Connection")).tag(3) }
                }
                if mode == 2 {
                    Picker(IDELanguageRunText.t("凭据", "Credential"), selection: $tokenID) {
                        Text(IDELanguageRunText.t("请选择", "Choose")).tag(UUID?.none)
                        ForEach(options) { Text($0.label).tag(Optional($0.id)) }
                    }
                    TextField(IDELanguageRunText.t("用户名", "Username"), text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if mode == 3 {
                    Picker(IDELanguageRunText.t("连接", "Connection"), selection: $hostID) {
                        Text(IDELanguageRunText.t("请选择", "Choose")).tag(UUID?.none)
                        ForEach(hosts) { Text($0.label).tag(Optional($0.id)) }
                    }
                }
            }
            if endpoint.transport == .https {
                Section {
                    DisclosureGroup(IDELanguageRunText.t("添加访问令牌", "Add Access Token"), isExpanded: $addToken) {
                        TextField(IDELanguageRunText.t("名称", "Name"), text: $tokenLabel)
                        SecureField(IDELanguageRunText.t("访问令牌或应用密码", "Access Token or App Password"), text: $tokenSecret)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        TextField(IDELanguageRunText.t("用户名", "Username"), text: $username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(IDELanguageRunText.t("保存到凭据库并使用", "Save to Vault and Use")) { saveNewToken() }
                            .disabled(tokenSecret.isEmpty || tokenLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                    }
                } footer: { Text(IDELanguageRunText.t("令牌保存在现有凭据库，仅用于此主机。", "The token is kept in the existing vault and used only for this host.")) }
            } else {
                Section {
                    Button { showHosts = true } label: {
                        Label(IDELanguageRunText.t("管理 SSH 连接", "Manage SSH Connections"), systemImage: "server.rack")
                    }
                } footer: { Text(IDELanguageRunText.t("使用已有连接中的密码或密钥。首次连接会要求确认主机指纹。", "Uses the existing connection's password or key. The first connection asks you to verify its fingerprint.")) }
            }
            if let notice { Section { Label(notice, systemImage: "exclamationmark.circle").foregroundStyle(.secondary) } }
        }
        .navigationTitle(IDELanguageRunText.t("仓库连接", "Repository Connection"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("取消", "Cancel")) { dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(IDELanguageRunText.t("保存", "Save")) { save() }
                    .disabled(saving || (mode == 2 && tokenID == nil) || (mode == 3 && hostID == nil))
            }
        }
        .task { await load() }
        .sheet(isPresented: $showHosts, onDismiss: { Task { await load() } }) {
            NavigationStack {
                HostListView(center: center.environment.remoteSessionCenter)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("完成", "Done")) { showHosts = false } } }
            }
        }
        .onDisappear { tokenSecret = "" }
    }
    private func validateOrigin() throws {
        guard SourceControlRootIdentity.matches(current: center.currentWorkspaceRoot, pinned: scope.workspaceRoot),
              center.boundWorkspaceCenter.currentWorkspace?.id == scope.workspaceID else { throw CancellationError() }
    }
    private func load() async {
        do {
            try validateOrigin()
            let selected = try await center.credentialResolver.choice(for: endpoint, scope: scope)
            let found = try await center.credentialResolver.credentialOptions(endpoint: endpoint, scope: scope)
            let ssh = endpoint.transport == .ssh ? try await center.credentialResolver.hostOptions(endpoint: endpoint) : []
            try validateOrigin(); options = found; hosts = ssh.map { .init(id: $0.id, label: $0.displayName) }
            switch selected {
            case .automatic: mode = 0
            case .anonymous: mode = 1
            case .savedToken(let id, let user): mode = 2; tokenID = id; username = user
            case .savedSSHHost(let id): mode = 3; hostID = id
            }
        } catch { notice = SecretRedactor.redact(error.localizedDescription) }
    }
    private func selection() throws -> GitRemoteCredentialChoice {
        switch mode {
        case 0: return .automatic
        case 1: return .anonymous
        case 2: guard let tokenID else { throw GitCredentialConfigurationError.selectCredential }; return .savedToken(id: tokenID, username: username)
        case 3: guard let hostID else { throw GitCredentialConfigurationError.configureSSH }; return .savedSSHHost(id: hostID)
        default: throw GitCredentialConfigurationError.selectCredential
        }
    }
    private func save() {
        guard !saving else { return }; saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try validateOrigin(); let choice = try selection()
                try await center.credentialResolver.save(choice, endpoint: endpoint, scope: scope)
                try validateOrigin(); dismiss()
            } catch { notice = SecretRedactor.redact(error.localizedDescription) }
        }
    }
    private func saveNewToken() {
        guard !saving else { return }; saving = true
        let secret = Data(tokenSecret.utf8), label = tokenLabel.trimmingCharacters(in: .whitespacesAndNewlines), user = username
        tokenSecret = ""
        Task { @MainActor in
            defer { saving = false }
            do {
                try validateOrigin()
                let owner: CredentialOwner = scope.workspaceID.map(CredentialOwner.workspace) ?? .vault
                let handle = try await center.environment.credentialVault.capture(secret, kind: .genericToken,
                    owner: owner, label: label, origin: endpoint.origin)
                try validateOrigin()
                try await center.credentialResolver.save(.savedToken(id: handle.id, username: user), endpoint: endpoint, scope: scope)
                try validateOrigin(); dismiss()
            } catch { notice = SecretRedactor.redact(error.localizedDescription) }
        }
    }
}

struct SourceControlCloneView: View {
    @ObservedObject var center: SourceControlCenter
    let pinnedRoot: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var folder = ""
    @State private var openProject = true
    @State private var credentials: SourceControlCredentialRoute?
    @State private var notice: String?
    var body: some View {
        Form {
            Section {
                TextField(IDELanguageRunText.t("HTTPS 或 SSH 仓库地址", "HTTPS or SSH Repository Address"), text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("sourceControl.clone.address")
                TextField(IDELanguageRunText.t("本地文件夹名称", "Local Folder Name"), text: $folder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("sourceControl.clone.folder")
                Toggle(IDELanguageRunText.t("完成后打开项目", "Open Project When Finished"), isOn: $openProject)
                Button { configure() } label: { Label(IDELanguageRunText.t("登录与连接", "Sign-In and Connection"), systemImage: "key") }
            } footer: { Text(IDELanguageRunText.t("仓库放在当前项目文件夹中，完成后加入项目列表。现有文件不会被覆盖。", "The repository is placed inside the current project folder and added to Projects when complete. Existing files are never replaced.")) }
            if let notice { Section { Text(notice).foregroundStyle(.secondary) } }
            if center.isBusy {
                Section { SourceControlTransferStatus(center: center) }
            }
        }
        .navigationTitle(IDELanguageRunText.t("克隆仓库", "Clone Repository"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("取消", "Cancel")) { if center.isBusy { center.cancelOperation() } else { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button(IDELanguageRunText.t("克隆", "Clone")) {
                    let address = address, folder = folder, open = openProject
                    Task { @MainActor in
                        await center.perform(pinnedRoot: pinnedRoot) {
                            _ = try await center.clone(address: address, folder: folder, openProject: open)
                            dismiss()
                        }
                    }
                }.disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || center.isBusy)
                .accessibilityIdentifier("sourceControl.clone.start")
            }
        }
        .sheet(item: $credentials) { route in NavigationStack { SourceControlCredentialsView(center: center, endpoint: route.endpoint, scope: route.scope) } }
        .interactiveDismissDisabled(center.isBusy)
        .sourceControlHostTrust(center: center, active: credentials == nil)
    }
    private func configure() {
        do {
            let endpoint = try GitRemoteEndpoint(address)
            credentials = .init(endpoint: endpoint, scope: try center.credentialScope())
        } catch { notice = SecretRedactor.redact(error.localizedDescription) }
    }
}
struct SourceControlCredentialRoute: Identifiable {
    let id = UUID()
    let endpoint: GitRemoteEndpoint
    let scope: GitCredentialScope
}

struct SourceControlTransferStatus: View {
    @ObservedObject var center: SourceControlCenter
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let value = center.transferProgress {
                    Text(title(value.phase)).font(.subheadline.weight(.medium))
                    if value.totalObjects > 0 {
                        ProgressView(value: Double(value.completedObjects), total: Double(max(value.totalObjects, value.completedObjects)))
                        Text("\(value.completedObjects) / \(value.totalObjects) · \(ByteCountFormatter.string(fromByteCount: value.bytes, countStyle: .file))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else { ProgressView().controlSize(.small) }
                } else { HStack { ProgressView(); Text(IDELanguageRunText.t("正在处理", "Working")) } }
            }
            Spacer(minLength: 8)
            Button(IDELanguageRunText.t("停止", "Stop"), role: .cancel) { center.cancelOperation() }
                .frame(minWidth: 44, minHeight: 44)
        }.accessibilityElement(children: .contain)
    }
    private func title(_ phase: GitRemoteProgress.Phase) -> String {
        switch phase {
        case .connecting: IDELanguageRunText.t("正在连接", "Connecting")
        case .receiving: IDELanguageRunText.t("正在接收", "Receiving")
        case .indexing: IDELanguageRunText.t("正在整理", "Indexing")
        case .sending: IDELanguageRunText.t("正在发送", "Sending")
        case .updatingReferences: IDELanguageRunText.t("正在更新分支", "Updating Branches")
        }
    }
}

struct SourceControlRemotesView: View {
    @ObservedObject var center: SourceControlCenter
    let pinnedRoot: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var name = "origin"
    @State private var fetch = ""
    @State private var push = ""
    @State private var upstream = ""
    @State private var remoteBranches: [String] = []
    @State private var credentials: SourceControlCredentialRoute?
    var body: some View {
        Form {
            Section(IDELanguageRunText.t("远端", "Remote")) {
                ForEach(center.remoteDescriptors) { remote in
                    Button {
                        name = remote.name; fetch = remote.fetch.transportURL; push = remote.push == remote.fetch ? "" : remote.push.transportURL
                        center.selectedRemoteName = remote.name
                    } label: {
                        HStack { VStack(alignment: .leading) { Text(remote.name); Text(remote.fetch.transportURL).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }; Spacer(); if remote.name == center.selectedRemoteName { Image(systemName: "checkmark") } }
                            .frame(minHeight: 44)
                    }
                }
                TextField(IDELanguageRunText.t("远端名称", "Remote Name"), text: $name)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField(IDELanguageRunText.t("获取地址", "Fetch Address"), text: $fetch)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField(IDELanguageRunText.t("推送地址（可选）", "Push Address (Optional)"), text: $push)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button(IDELanguageRunText.t("保存远端", "Save Remote")) { perform { try await center.configureRemote(name: name, fetch: fetch, push: push) } }
                    .disabled(name.isEmpty || fetch.isEmpty || center.isBusy)
            }
            Section {
                Button(IDELanguageRunText.t("获取连接凭据", "Fetch Connection Credentials")) { configure(fetch) }
                if !push.isEmpty && push != fetch { Button(IDELanguageRunText.t("推送连接凭据", "Push Connection Credentials")) { configure(push) } }
            }
            Section {
                Picker(IDELanguageRunText.t("远端分支", "Remote Branch"), selection: $upstream) {
                    Text(IDELanguageRunText.t("请选择", "Choose")).tag("")
                    ForEach(remoteBranches, id: \.self) { Text($0).tag($0) }
                }
                Button(IDELanguageRunText.t("设置跟踪分支", "Set Upstream")) { perform { try await center.setUpstream(remoteBranch: upstream) } }
                    .disabled(upstream.isEmpty || center.isBusy)
            } header: {
                Text(IDELanguageRunText.t("跟踪分支", "Upstream Branch"))
            } footer: { Text(IDELanguageRunText.t("先获取远端，再选择已有的远端分支。", "Fetch the remote before selecting an existing remote branch.")) }
        }
        .navigationTitle(IDELanguageRunText.t("远端与连接", "Remotes and Connections"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("完成", "Done")) { dismiss() } } }
        .task { if let value = center.remoteDescriptors.first(where: { $0.name == center.selectedRemoteName }) { name = value.name; fetch = value.fetch.transportURL; push = value.push == value.fetch ? "" : value.push.transportURL } }
        .task(id: center.selectedRemoteName) {
            do {
                let name = center.selectedRemoteName
                let values = try await center.remoteBranches()
                try Task.checkCancellation()
                guard name == center.selectedRemoteName, SourceControlRootIdentity.matches(current: center.currentWorkspaceRoot, pinned: pinnedRoot) else { return }
                remoteBranches = values
            } catch { center.errorMessage = SecretRedactor.redact(error.localizedDescription) }
        }
        .sheet(item: $credentials) { route in NavigationStack { SourceControlCredentialsView(center: center, endpoint: route.endpoint, scope: route.scope) } }
    }
    private func configure(_ address: String) {
        do { credentials = .init(endpoint: try GitRemoteEndpoint(address), scope: try center.credentialScope()) }
        catch { center.errorMessage = SecretRedactor.redact(error.localizedDescription) }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) { Task { await center.perform(pinnedRoot: pinnedRoot, operation) } }
}
private struct SourceControlHostTrust: ViewModifier {
    @ObservedObject var center: SourceControlCenter
    @ObservedObject var sessions: RemoteSessionCenter
    let active: Bool
    func body(content: Content) -> some View {
        content.sheet(item: Binding<RemoteSessionCenter.PendingHostKeyTrust?>(get: {
            guard active, let pending = sessions.pendingTrust, pending.id == center.activeTrustID else { return nil }
            return pending
        }, set: { value in
            if value == nil, let pending = sessions.pendingTrust, pending.id == center.activeTrustID {
                sessions.resolveTrust(false)
            }
        })) { pending in
            HostKeyTrustSheet(challenge: pending.challenge) { approved in
                guard sessions.pendingTrust?.id == pending.id else { return }
                sessions.resolveTrust(approved)
            }
        }
    }
}
extension View {
    func sourceControlHostTrust(center: SourceControlCenter, active: Bool) -> some View {
        modifier(SourceControlHostTrust(center: center, sessions: center.environment.remoteSessionCenter, active: active))
    }
}
#endif
