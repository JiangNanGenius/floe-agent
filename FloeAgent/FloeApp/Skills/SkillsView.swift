#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloePersistence
import FloeSecurity
import FloeTools

struct SkillsView: View {
    @ObservedObject var center: SkillsCenter
    @ObservedObject private var mcpCenter: MCPSettingsCenter
    @State private var showingCreator = false
    @State private var showingFinder = false
    @State private var pendingRemoval: PersistedSkill?

    init(center: SkillsCenter, mcpCenter: MCPSettingsCenter = .shared) {
        self.center = center
        self.mcpCenter = mcpCenter
    }

    var body: some View {
        List {
            Section("工具来源") {
                NavigationLink {
                    MCPServersView(center: mcpCenter)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("标准 MCP")
                            Text("已启用 \(mcpCenter.servers.filter(\.enabled).count) 个远程工具服务器")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "network")
                    }
                }
            }
            if center.installed.isEmpty {
                ContentUnavailableView("skills.empty", systemImage: "puzzlepiece.extension")
            } else {
                ForEach(center.installed) { skill in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(skill.name).font(.headline)
                                Text("v\(skill.version)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("skills.enabled", isOn: Binding(
                                get: { skill.status == "enabled" },
                                set: { value in Task { await center.setEnabled(value, skill: skill) } }
                            )).labelsHidden()
                        }
                        Text(skill.skillMarkdown.split(separator: "\n").dropFirst(4).joined(separator: "\n"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    .swipeActions {
                        Button("action.delete", role: .destructive) { pendingRemoval = skill }
                    }
                }
            }
            if let error = center.errorMessage {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        }
        .overlay { if center.isWorking { ProgressView().controlSize(.large) } }
        .navigationTitle("skills.title")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("skills.finder", systemImage: "magnifyingglass") { showingFinder = true }
                Button("skills.creator", systemImage: "plus") { showingCreator = true }
            }
        }
        .task { await center.load() }
        .sheet(isPresented: $showingCreator) { SkillCreatorSheet(center: center) }
        .sheet(isPresented: $showingFinder) { SkillFinderSheet(center: center) }
        .sheet(item: $center.pendingInstallation) { pending in
            SkillInstallReviewSheet(center: center, pending: pending)
        }
        .alert("skills.remove.title", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("action.cancel", role: .cancel) { pendingRemoval = nil }
            Button("action.delete", role: .destructive) {
                if let skill = pendingRemoval { Task { await center.remove(skill) } }
                pendingRemoval = nil
            }
        }
    }
}

@MainActor
final class MCPSettingsCenter: ObservableObject {
    enum ConnectionState: Equatable {
        case inactive
        case connecting
        case ready(Int)
        case failed(String)
    }

    static let shared = MCPSettingsCenter()
    private static let defaultsKey = "floe.mcp.remoteServers.v1"
    private static let keychainService = "org.floeagent.ios.mcp"

    @Published private(set) var servers: [MCPServerConfiguration] = []
    @Published private(set) var stateByServerID: [UUID: ConnectionState] = [:]
    @Published private(set) var toolsByServerID: [UUID: [MCPDiscoveredTool]] = [:]
    @Published var errorMessage: String?

    private let defaults: UserDefaults
    private let cloud: NSUbiquitousKeyValueStore
    private let keychain: KeychainStore
    private var clients: [UUID: MCPRemoteClient] = [:]
    private var refreshGenerationByServerID: [UUID: UInt64] = [:]
    private var activated = false

    init(
        defaults: UserDefaults = .standard,
        cloud: NSUbiquitousKeyValueStore = .default
    ) {
        self.defaults = defaults
        self.cloud = cloud
        self.keychain = KeychainStore(service: Self.keychainService, synchronizable: true)
        reload()
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = self.servers
                self.reload()
                self.reconcileRuntime(previous: previous)
                self.activate(force: true)
            }
        }
        cloud.synchronize()
    }

    func activate(force: Bool = false) {
        guard force || !activated else { return }
        activated = true
        Task { [weak self] in
            guard let self else { return }
            for server in self.servers where server.enabled {
                await self.refresh(serverID: server.id)
            }
        }
    }

    func upsert(_ server: MCPServerConfiguration, credential: String?) async throws {
        try server.validate()
        let previous = servers.first(where: { $0.id == server.id })
        let account = credentialAccount(server)
        if let credential, !credential.isEmpty {
            try keychain.store(account: account, secret: Data(credential.utf8))
        } else if server.authentication != .none,
                  (try? keychain.read(account: account)) == nil {
            throw MCPClientError.authenticationRequired
        }
        if server.authentication == .none {
            try? keychain.delete(account: account)
        }
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        servers.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if let previous, credentialAccount(previous) != account {
            try? keychain.delete(account: credentialAccount(previous))
        }
        try? keychain.delete(account: legacyCredentialAccount(server.id))
        persist()
        if server.enabled {
            await refresh(serverID: server.id)
        } else {
            MCPRemoteToolSource.unregister(configuration: server)
            stateByServerID[server.id] = .inactive
            toolsByServerID[server.id] = []
        }
    }

    func setEnabled(_ enabled: Bool, serverID: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[index].enabled = enabled
        let server = servers[index]
        persist()
        if enabled {
            Task { await refresh(serverID: serverID) }
        } else {
            invalidateRefresh(serverID: serverID)
            MCPRemoteToolSource.unregister(configuration: server)
            clients.removeValue(forKey: serverID)
            stateByServerID[serverID] = .inactive
        }
    }

    func setToolEnabled(_ enabled: Bool, remoteName: String, serverID: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        if enabled {
            servers[index].disabledRemoteToolNames.remove(remoteName)
        } else {
            servers[index].disabledRemoteToolNames.insert(remoteName)
        }
        persist()
        let server = servers[index]
        if let client = clients[serverID], let tools = toolsByServerID[serverID] {
            MCPRemoteToolSource.register(configuration: server, client: client, tools: tools)
        }
    }

    func remove(serverID: UUID) {
        guard let server = servers.first(where: { $0.id == serverID }) else { return }
        MCPRemoteToolSource.unregister(configuration: server)
        servers.removeAll { $0.id == serverID }
        clients.removeValue(forKey: serverID)
        toolsByServerID.removeValue(forKey: serverID)
        stateByServerID.removeValue(forKey: serverID)
        invalidateRefresh(serverID: serverID)
        try? keychain.delete(account: credentialAccount(server))
        try? keychain.delete(account: legacyCredentialAccount(serverID))
        persist()
    }

    func refresh(serverID: UUID) async {
        guard let server = servers.first(where: { $0.id == serverID }), server.enabled else { return }
        let generation = beginRefresh(serverID: serverID)
        stateByServerID[serverID] = .connecting
        errorMessage = nil
        do {
            let credentialData = try? keychain.read(account: credentialAccount(server))
            let credential = credentialData.map { String(decoding: $0, as: UTF8.self) }
            let client = try MCPRemoteClient(configuration: server, credential: credential)
            let tools = try await client.discoverTools()
            guard refreshGenerationByServerID[serverID] == generation,
                  servers.first(where: { $0.id == serverID }) == server else { return }
            clients[serverID] = client
            toolsByServerID[serverID] = tools
            MCPRemoteToolSource.register(configuration: server, client: client, tools: tools)
            stateByServerID[serverID] = .ready(tools.count)
        } catch {
            guard refreshGenerationByServerID[serverID] == generation else { return }
            MCPRemoteToolSource.unregister(configuration: server)
            clients.removeValue(forKey: serverID)
            stateByServerID[serverID] = .failed(error.localizedDescription)
            errorMessage = "\(server.displayName)：\(error.localizedDescription)"
        }
    }

    func hasStoredCredential(serverID: UUID) -> Bool {
        guard let server = servers.first(where: { $0.id == serverID }) else { return false }
        return (try? keychain.read(account: credentialAccount(server))) != nil
    }

    /// Snapshot the exact remote-tool names that may enter a Canvas Agent
    /// run. Keeping this decision in one policy builder prevents the canvas
    /// UI from accidentally treating every ordinary-Agent MCP registration
    /// as canvas-authorized.
    func canvasAllowedToolNames() -> Set<String> {
        CanvasAgentToolPolicy.allowedToolNames(
            servers: servers,
            discoveredTools: toolsByServerID
        )
    }

    private func reload() {
        let data = cloud.data(forKey: Self.defaultsKey) ?? defaults.data(forKey: Self.defaultsKey)
        servers = data.flatMap { try? JSONDecoder().decode([MCPServerConfiguration].self, from: $0) } ?? []
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
        cloud.set(data, forKey: Self.defaultsKey)
        cloud.synchronize()
    }

    private func reconcileRuntime(previous: [MCPServerConfiguration]) {
        let currentByID = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, $0) })
        for old in previous {
            guard let current = currentByID[old.id], current.enabled, current == old else {
                invalidateRefresh(serverID: old.id)
                MCPRemoteToolSource.unregister(configuration: old)
                clients.removeValue(forKey: old.id)
                toolsByServerID.removeValue(forKey: old.id)
                stateByServerID[old.id] = currentByID[old.id] == nil ? nil : .inactive
                continue
            }
        }
    }

    private func beginRefresh(serverID: UUID) -> UInt64 {
        let next = (refreshGenerationByServerID[serverID] ?? 0) &+ 1
        refreshGenerationByServerID[serverID] = next
        return next
    }

    private func invalidateRefresh(serverID: UUID) {
        refreshGenerationByServerID[serverID] = (refreshGenerationByServerID[serverID] ?? 0) &+ 1
    }

    /// Bind secret lookup to both the stable server identity and its network
    /// origin. Editing or cloud-syncing an endpoint therefore requires a
    /// credential stored for the new destination instead of silently sending
    /// the old secret to it.
    private func credentialAccount(_ server: MCPServerConfiguration) -> String {
        let scheme = server.endpoint.scheme?.lowercased() ?? "https"
        let host = server.endpoint.host?.lowercased() ?? "invalid"
        let port = server.endpoint.port ?? (scheme == "https" ? 443 : 80)
        return "mcp.\(server.id.uuidString).\(scheme).\(host).\(port)"
    }

    private func legacyCredentialAccount(_ serverID: UUID) -> String {
        "mcp.\(serverID.uuidString)"
    }
}

private struct MCPServersView: View {
    @ObservedObject var center: MCPSettingsCenter
    @State private var editingServer: MCPServerConfiguration?
    @State private var showingNewServer = false

    var body: some View {
        List {
            Section {
                if center.servers.isEmpty {
                    ContentUnavailableView(
                        "尚未添加 MCP 服务器",
                        systemImage: "network",
                        description: Text("添加标准远程 MCP，让普通 Agent 使用服务器提供的工具。")
                    )
                }
                ForEach(center.servers) { server in
                    Button { editingServer = server } label: {
                        HStack(spacing: 12) {
                            Image(systemName: stateIcon(center.stateByServerID[server.id]))
                                .foregroundStyle(stateColor(center.stateByServerID[server.id]))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.displayName).foregroundStyle(.primary)
                                Text(server.endpoint.absoluteString)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(stateText(center.stateByServerID[server.id]))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { server.enabled },
                                set: { center.setEnabled($0, serverID: server.id) }
                            )).labelsHidden()
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { center.remove(serverID: server.id) }
                    }
                }
            } footer: {
                Text("支持标准 Streamable HTTP。远程工具仍经过 Floe 的本地权限与审批；画布默认不能使用 MCP。")
            }
            if let error = center.errorMessage {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        }
        .navigationTitle("标准 MCP")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("添加", systemImage: "plus") { showingNewServer = true }
            }
        }
        .sheet(isPresented: $showingNewServer) {
            MCPServerEditor(center: center, server: nil)
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditor(center: center, server: server)
        }
        .onAppear { center.activate() }
    }

    private func stateText(_ state: MCPSettingsCenter.ConnectionState?) -> String {
        switch state {
        case .inactive, nil: "未连接"
        case .connecting: "正在读取工具…"
        case .ready(let count): "可用工具 \(count) 个"
        case .failed(let message): "连接失败：\(message)"
        }
    }

    private func stateIcon(_ state: MCPSettingsCenter.ConnectionState?) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .inactive, nil: "circle"
        }
    }

    private func stateColor(_ state: MCPSettingsCenter.ConnectionState?) -> Color {
        switch state {
        case .ready: .green
        case .failed: .orange
        default: .secondary
        }
    }
}

private struct MCPServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var center: MCPSettingsCenter
    @State private var server: MCPServerConfiguration
    @State private var endpointText: String
    @State private var credential = ""
    @State private var validationMessage: String?
    @State private var isSaving = false

    init(center: MCPSettingsCenter, server: MCPServerConfiguration?) {
        self.center = center
        let value = server ?? MCPServerConfiguration(
            displayName: "",
            endpoint: URL(string: "https://example.com/mcp")!,
            enabled: true
        )
        _server = State(initialValue: value)
        _endpointText = State(initialValue: server?.endpoint.absoluteString ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $server.displayName)
                    TextField("https://…/mcp", text: $endpointText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Toggle("启用", isOn: $server.enabled)
                    Toggle("允许画布使用", isOn: $server.allowInCanvas)
                } header: {
                    Text("服务器")
                } footer: {
                    Text("画布默认关闭 MCP。只有你明确打开此服务器后，画布 Agent 才能看到它的工具。")
                }
                Section("认证") {
                    Picker("方式", selection: $server.authentication) {
                        Text("无").tag(MCPServerConfiguration.Authentication.none)
                        Text("Bearer Token").tag(MCPServerConfiguration.Authentication.bearerToken)
                        Text("自定义请求头").tag(MCPServerConfiguration.Authentication.customHeader)
                    }
                    if server.authentication == .customHeader {
                        TextField("请求头名称", text: $server.credentialHeaderName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if server.authentication != .none {
                        SecureField(
                            center.hasStoredCredential(serverID: server.id) ? "输入新凭据以替换已保存凭据" : "凭据",
                            text: $credential
                        )
                        if center.hasStoredCredential(serverID: server.id) {
                            Label("凭据已安全保存在钥匙串", systemImage: "checkmark.shield")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("网络安全") {
                    Toggle("允许不安全的 HTTP（仅可信局域网）", isOn: $server.allowInsecureHTTP)
                }
                if let tools = center.toolsByServerID[server.id], !tools.isEmpty {
                    Section("工具") {
                        ForEach(tools, id: \.remoteName) { tool in
                            Toggle(isOn: Binding(
                                get: { !server.disabledRemoteToolNames.contains(tool.remoteName) },
                                set: {
                                    if $0 { server.disabledRemoteToolNames.remove(tool.remoteName) }
                                    else { server.disabledRemoteToolNames.insert(tool.remoteName) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tool.displayName ?? tool.remoteName)
                                    Text(tool.toolDescription).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }
                if let validationMessage {
                    Text(validationMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle(server.displayName.isEmpty ? "添加 MCP" : server.displayName)
            .disabled(isSaving)
            .overlay { if isSaving { ProgressView() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并连接") { save() }
                        .disabled(server.displayName.trimmingCharacters(in: .whitespaces).isEmpty || endpointText.isEmpty)
                }
            }
        }
    }

    private func save() {
        validationMessage = nil
        guard let endpoint = URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            validationMessage = "请输入有效的 MCP 地址。"
            return
        }
        server.endpoint = endpoint
        isSaving = true
        Task {
            do {
                try await center.upsert(server, credential: credential.isEmpty ? nil : credential)
                dismiss()
            } catch {
                validationMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private struct SkillInstallReviewSheet: View {
    @ObservedObject var center: SkillsCenter
    let pending: SkillsCenter.PendingInstallation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("skills.review.source") { Text(pending.sourceURL.absoluteString).font(.footnote) }
                Section("skills.review.permissions") {
                    if pending.capabilityNames.isEmpty { Text("skills.review.none") }
                    ForEach(pending.capabilityNames, id: \.self) { Text($0) }
                }
                if !pending.toolNames.isEmpty {
                    Section("skills.review.tools") { ForEach(pending.toolNames, id: \.self) { Text($0) } }
                }
                if pending.containsScripts {
                    Section("Python 脚本（安装时审计）") {
                        ForEach(pending.files.keys.filter { $0.hasPrefix("scripts/") }.sorted(), id: \.self) {
                            Label($0, systemImage: "doc.text")
                                .font(FloeTheme.Typography.evidence)
                        }
                    }
                }
                if !pending.manifest.pythonPackages.isEmpty {
                    Section("纯 Python 依赖（安装时审计）") {
                        ForEach(pending.manifest.pythonPackages, id: \.spec) { package in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(package.spec).font(FloeTheme.Typography.evidence)
                                Text(package.purpose)
                                    .font(FloeTheme.Typography.metadata)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("只接受固定版本的 PyPI none-any wheel；安装后仅相同脚本与依赖可免重复审核。")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("skills.review.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("action.cancel") { center.cancelPendingInstallation(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.install") { Task { await center.confirmPendingInstallation(); dismiss() } }
                }
            }
        }
    }
}

private struct SkillCreatorSheet: View {
    @ObservedObject var center: SkillsCenter
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("skills.name", text: $name)
                TextField("skills.description", text: $description, axis: .vertical)
                TextField("skills.instructions", text: $instructions, axis: .vertical).lineLimit(6...14)
            }
            .navigationTitle("skills.creator")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.install") {
                        Task { await center.create(name: name, description: description, instructions: instructions); if center.errorMessage == nil { dismiss() } }
                    }.disabled(name.isEmpty || description.isEmpty || instructions.isEmpty || center.isWorking)
                }
            }
        }
    }
}

private struct SkillFinderSheet: View {
    @ObservedObject var center: SkillsCenter
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var rewriteModelID: UUID?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: {
                    Text("skills.finder.source")
                } footer: {
                    Text("skills.finder.footer")
                }
                Picker("skills.finder.model", selection: $rewriteModelID) {
                    ForEach(center.rewriteModels) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
            }
            .navigationTitle("skills.finder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.install") {
                        Task { await center.installFromFinder(urlText: url, rewriteModelID: rewriteModelID); if center.errorMessage == nil { dismiss() } }
                    }.disabled(url.isEmpty || rewriteModelID == nil || center.isWorking)
                }
            }
            .onAppear { if rewriteModelID == nil { rewriteModelID = center.defaultRewriteModelID ?? center.rewriteModels.first?.id } }
        }
    }
}
#endif
