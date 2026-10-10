#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloePersistence
import FloeSecurity
import FloeTools
import FloeSkills

import FloeCore
import UniformTypeIdentifiers

struct SkillsView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var center: SkillsCenter
    @ObservedObject private var mcpCenter: MCPSettingsCenter
    @State private var showingInstalled = false
    @State private var searchText = ""
    @State private var showingCreator = false
    @State private var showingFinder = false
    @State private var pendingRemoval: PersistedSkill?
    @State private var updatingSkill: PersistedSkill?
    @State private var showingFolderImporter = false
    /// Shared scripted auto-update policy; the same defaults value is managed
    /// by Settings → Content updates. Never a second copy.
    @AppStorage(ContentUpdateCenter.scriptedAutoInstallDefaultsKey)
    private var autoScriptedUpdates = false

    init(center: SkillsCenter, mcpCenter: MCPSettingsCenter = .shared) {
        self.center = center
        self.mcpCenter = mcpCenter
    }

    /// The hub shows user skills plus the explicitly exposed built-ins
    /// (office/pdf/network); hidden built-ins stay readable via skill.read
    /// but never occupy hub space.
    private var visibleInstalled: [PersistedSkill] {
        let exposed = Set(DomainSkillLibrary.all.filter(\.exposed).map(\.id))
        return center.installed.filter { skill in
            guard searchText.isEmpty || skill.name.localizedStandardContains(searchText) else { return false }
            guard DomainSkillLibrary.all.contains(where: { $0.id == skill.id }) else { return true }
            return exposed.contains(skill.id)
        }
    }

    private func pluginSummary(_ definition: DomainSkillLibrary.Definition) -> String {
        switch definition.id {
        case "floe-office": String(localized: "plugins.office.summary")
        case "floe-pdf": String(localized: "plugins.pdf.summary")
        case "floe-network": String(localized: "plugins.network.summary")
        default: definition.description
        }
    }

    var body: some View {
        List {
            Picker("plugins.title", selection: $showingInstalled) {
                Text("plugins.discover").tag(false)
                Text("plugins.installed").tag(true)
            }.pickerStyle(.segmented)
            if !showingInstalled {
                Section("plugins.official") {
                    ForEach(DomainSkillLibrary.all.filter { $0.exposed && (searchText.isEmpty || $0.name.localizedStandardContains(searchText) || $0.description.localizedStandardContains(searchText)) }, id: \.id) { definition in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(definition.name).font(.headline).accessibilityIdentifier("plugins.card.\(definition.id)")
                                Spacer()
                                Text("v\(center.installed.contains(where: { $0.id == definition.id }) ? (center.catalogPackages[definition.id]?.version ?? definition.version) : definition.version)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(pluginSummary(definition)).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                            if let installed = center.installed.first(where: { $0.id == definition.id }) {
                                if let version = center.availableVersion(for: installed) {
                                    Button(FloeL10n.l("skills.skills_view.update_to_v", version)) { updatingSkill = installed }
                                } else if installed.status == "enabled" {
                                    Label("plugins.ready", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Button("plugins.enable") { Task { await center.setEnabled(true, skill: installed) } }
                                }
                            } else {
                                Button("action.install") { Task { await center.installOfficialSkill(id: definition.id) } }
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Section {
                    Button("plugins.import", systemImage: "square.and.arrow.down") { showingFinder = true }
                    Button("skills.import_folder", systemImage: "folder") { showingFolderImporter = true }
                    Button("skills.creator", systemImage: "plus") { showingCreator = true }
                }
                Section {
                    Toggle("skills.auto_scripted_updates.label", isOn: $autoScriptedUpdates)
                        .accessibilityIdentifier("skills.auto_scripted_updates")
                } header: {
                    Text("skills.auto_scripted_updates.title")
                } footer: {
                    Text("skills.auto_scripted_updates.footer")
                }
            }
            Section("connectors.title") {
                NavigationLink {
                    ConnectorsView(sourceControl: environment.sourceControlCenter, mcpCenter: mcpCenter)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("connectors.manage")
                            Text("connectors.summary")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "network")
                    }
                }
                .accessibilityIdentifier("skills.connectors")
            }
            if showingInstalled {
                if visibleInstalled.isEmpty {
                    ContentUnavailableView("skills.empty", systemImage: "puzzlepiece.extension")
                } else {
                    ForEach(visibleInstalled) { skill in
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
                            if let definition = DomainSkillLibrary.all.first(where: { $0.id == skill.id }) {
                                Text(pluginSummary(definition)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Button {
                                updatingSkill = skill
                            } label: {
                                if let version = center.availableVersion(for: skill) {
                                    Label(FloeL10n.l("skills.skills_view.update_to_v", version), systemImage: "arrow.down.circle")
                                } else { Label("skills.update", systemImage: "arrow.down.circle") }
                            }.buttonStyle(.borderless)
                        }
                        .swipeActions {
                            if DomainSkillLibrary.all.first(where: { $0.id == skill.id })?.exposed != false {
                                Button("action.delete", role: .destructive) { pendingRemoval = skill }
                            }
                        }
                    }
                }
            }
            if let error = center.catalogError {
                Text(error).foregroundStyle(.secondary).font(.footnote)
            }
            if let error = center.errorMessage {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        }
        .overlay { if center.isWorking { ProgressView().controlSize(.large) } }
        .navigationTitle("plugins.title")
        .searchable(text: $searchText, prompt: "plugins.search")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("skills.finder", systemImage: "magnifyingglass") { showingFinder = true }
                Button("skills.creator", systemImage: "plus") { showingCreator = true }
            }
        }
        .fileImporter(
            isPresented: $showingFolderImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await importTraditionalFolder(url) }
            }
        }
        .task { await center.load(); await center.refreshOfficialCatalog() }
        .refreshable { await center.load(); await center.refreshOfficialCatalog(force: true) }
        .sheet(isPresented: $showingCreator) { SkillCreatorSheet(center: center) }
        .sheet(isPresented: $showingFinder) { SkillFinderSheet(center: center) }
        .sheet(item: $updatingSkill) { skill in SkillGitHubUpgradeSheet(center: center, skill: skill) }
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
    /// Imports a traditional skill folder (SKILL.md, optional floe.json,
    /// scripts/references/assets/agents). The source directory is copied to a
    /// temporary location; installation never executes scripts and never
    /// writes Floe metadata back into the user's folder.
    private func importTraditionalFolder(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-skill-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try FileManager.default.copyItem(at: url, to: temporary)
            guard let source = URL(string: "floe-folder://local/\(url.lastPathComponent)") else { return }
            await center.installTraditionalPackage(at: temporary, sourceURL: source)
        } catch {
            center.errorMessage = error.localizedDescription
        }
    }
}

private struct SkillGitHubUpgradeSheet: View {
    @ObservedObject var center: SkillsCenter
    let skill: PersistedSkill
    @Environment(\.dismiss) private var dismiss
    @State private var owner = ""
    @State private var repository = ""
    @State private var ref = "main"
    @State private var path = "SKILL.md"
    @State private var validationError: String?
    @State private var confirmingRollback = false
    private var isOfficial: Bool { OfficialSkillHub.skillIDs.contains(skill.id) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("skills.update.installed", value: "v\(skill.version)")
                    if let candidate = center.pendingUpgrade {
                        LabeledContent("skills.update.available", value: "v\(candidate.snapshot.package.manifest.version)")
                        if !candidate.addedCapabilities.isEmpty || !candidate.addedTools.isEmpty {
                            Label("skills.skills_view.this_update_requires_new_access_permissions", systemImage: "hand.raised")
                                .font(.callout)
                        }
                        if candidate.changedFiles.isEmpty {
                            Label("skills.skills_view.already_the_latest_version", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        }
                        Button("skills.update.now") {
                            Task {
                                await center.applyReviewedUpgrade()
                                if center.errorMessage == nil { dismiss() }
                            }
                        }.disabled(candidate.changedFiles.isEmpty)
                    } else {
                        Button("skills.update.check") { checkForUpdate() }
                    }
                }
                DisclosureGroup("skills.update.details") {
                    if !isOfficial {
                        TextField("Owner", text: $owner)
                        TextField("Repository", text: $repository)
                        TextField("Branch / tag / commit", text: $ref)
                        TextField("SKILL.md or package inventory JSON", text: $path)
                        Button("skills.update.check") { checkForUpdate() }
                    }
                    Text(skill.sourceURL ?? "App / local").font(.caption).textSelection(.enabled)
                    if let candidate = center.pendingUpgrade {
                        LabeledContent("Commit", value: candidate.commit)
                        if let notes = candidate.releaseNotes[Locale.current.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en"] {
                            Text(notes).font(.callout)
                        }
                        LabeledContent("skills.skills_view.new_capabilities", value: candidate.addedCapabilities.sorted().joined(separator: ", "))
                        LabeledContent("skills.skills_view.new_tools", value: candidate.addedTools.sorted().joined(separator: ", "))
                        ForEach(candidate.changedFiles, id: \.self) { file in
                            DisclosureGroup(file) {
                                Text("Before").font(.caption.bold())
                                Text(preview(candidate.installedSnapshot.files[file])).font(.caption.monospaced())
                                Text("After").font(.caption.bold())
                                Text(preview(candidate.snapshot.files[file])).font(.caption.monospaced())
                            }
                        }
                    }
                    Button("skills.update.rollback", role: .destructive) { confirmingRollback = true }
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                if let error = validationError ?? center.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .disabled(center.isWorking)
            .overlay { if center.isWorking { ProgressView() } }
            .navigationTitle(skill.name)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { center.cancelUpgrade(); dismiss() }.disabled(center.isWorking) } }
            .confirmationDialog("skills.skills_view.restore_previous_content_and_grants", isPresented: $confirmingRollback) {
                Button("skills.skills_view.roll_back", role: .destructive) { Task { await center.rollbackLatestUpgrade(skill: skill); if center.errorMessage == nil { dismiss() } } }
            }
            .interactiveDismissDisabled(center.isWorking)
            .onAppear {
                if let source = center.lastGitHubSource(skillID: skill.id) {
                    owner = source.owner; repository = source.repository; ref = source.ref; path = source.path
                }
                if isOfficial || !owner.isEmpty { checkForUpdate() }
            }
            .onDisappear { if !center.isWorking { center.cancelUpgrade() } }
        }
    }

    private func checkForUpdate() {
        do {
            let source = try isOfficial ? OfficialSkillHub.source() : GitHubSkillSource(owner: owner, repository: repository, ref: ref, path: path)
            validationError = nil
            Task { await center.checkGitHubUpgrade(skill: skill, source: source) }
        } catch { validationError = error.localizedDescription }
    }

    private func preview(_ data: Data?) -> String {
        guard let data else { return "(absent)" }
        guard let text = String(data: data, encoding: .utf8) else { return "Binary resource: \(data.count) bytes" }
        return text
    }
}

/// Account integrations are not installable skill Markdown. Keep existing
/// account stores and Keychain identities intact when changing navigation.
struct ConnectorsView: View {
    @ObservedObject var sourceControl: SourceControlCenter
    @ObservedObject var mcpCenter: MCPSettingsCenter

    var body: some View {
        List {
            Section("connectors.services") {
                NavigationLink { MailSettingsView() } label: {
                    Label("mail.settings.title", systemImage: "envelope")
                }
                .accessibilityIdentifier("connectors.mail")
                NavigationLink {
                    GitHubSettingsView(center: sourceControl)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("GitHub")
                            Text(sourceControl.account.map { String(localized: "connectors.connected") + " · \($0.login)" }
                                 ?? String(localized: "connectors.github.disconnected"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "arrow.triangle.branch") }
                }
                .accessibilityIdentifier("connectors.github")
            }
            Section {
                NavigationLink {
                    MCPServersView(center: mcpCenter)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("connectors.mcp.title")
                            Text(String.localizedStringWithFormat(String(localized: "connectors.mcp.enabled_count"), mcpCenter.servers.filter(\.enabled).count))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "network") }
                }
                .accessibilityIdentifier("connectors.mcp")
            } header: { Text("connectors.tool_sources") }
            footer: {
                Text("connectors.footer")
            }
        }
        .navigationTitle("connectors.title")
        .task { await sourceControl.loadConnection() }
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
            if let client = clients.removeValue(forKey: server.id) {
                Task { await client.disconnect() }
            }
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
            if let client = clients.removeValue(forKey: serverID) {
                Task { await client.disconnect() }
            }
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
        if let client = clients.removeValue(forKey: serverID) {
            Task { await client.disconnect() }
        }
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
        let previousClient = clients[serverID]
        do {
            let credentialData = try? keychain.read(account: credentialAccount(server))
            let credential = credentialData.map { String(decoding: $0, as: UTF8.self) }
            let client = try MCPRemoteClient(configuration: server, credential: credential)
            let tools = try await client.discoverTools()
            guard refreshGenerationByServerID[serverID] == generation,
                  servers.first(where: { $0.id == serverID }) == server else {
                // Superseded by a newer refresh: tear the new client down and do
                // not touch the current registration.
                await client.disconnect()
                return
            }
            clients[serverID] = client
            toolsByServerID[serverID] = tools
            MCPRemoteToolSource.register(configuration: server, client: client, tools: tools)
            stateByServerID[serverID] = .ready(tools.count)
            if let previousClient, previousClient !== client {
                await previousClient.disconnect()
            }
        } catch {
            guard refreshGenerationByServerID[serverID] == generation else { return }
            MCPRemoteToolSource.unregister(configuration: server)
            clients.removeValue(forKey: serverID)
            // A failed refresh must not leave its half-open client or a prior
            // client's session alive.
            if let previousClient {
                await previousClient.disconnect()
            }
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
                    ContentUnavailableView("skills.skills_view.no_mcp_server_added_yet",
                        systemImage: "network",
                        description: Text("skills.skills_view.add_a_standard_remote_mcp_so")
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
                        Button("workspace.workspace_canvas_view.delete", role: .destructive) { center.remove(serverID: server.id) }
                    }
                }
            } footer: {
                Text("skills.skills_view.supports_standard_streamable_http_remote_tools")
            }
            if let error = center.errorMessage {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        }
        .navigationTitle("connectors.mcp.title")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("portforward.add", systemImage: "plus") { showingNewServer = true }
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
        case .inactive, nil: FloeL10n.l("skills.skills_view.not_connected")
        case .connecting: FloeL10n.l("skills.skills_view.reading_tools")
        case .ready(let count): FloeL10n.plural("skills.skills_view.tools_available", count: count)
        case .failed(let message): FloeL10n.l("skills.skills_view.connection_failed", message)
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
                    TextField("notes.notes_root_view.name", text: $server.displayName)
                    TextField("https://…/mcp", text: $endpointText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Toggle("skills.skills_view.enabled", isOn: $server.enabled)
                    Toggle("skills.skills_view.allow_canvas_to_use", isOn: $server.allowInCanvas)
                } header: {
                    Text("skills.skills_view.server")
                } footer: {
                    Text("skills.skills_view.mcp_is_off_by_default_for")
                }
                Section("workspace.file_inspector_view.authentication") {
                    Picker("hosts.auth", selection: $server.authentication) {
                        Text("workspace.workspace_canvas_view.none").tag(MCPServerConfiguration.Authentication.none)
                        Text("Bearer Token").tag(MCPServerConfiguration.Authentication.bearerToken)
                        Text("skills.skills_view.custom_request_headers").tag(MCPServerConfiguration.Authentication.customHeader)
                    }
                    if server.authentication == .customHeader {
                        TextField("skills.skills_view.request_header_name", text: $server.credentialHeaderName)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    if server.authentication != .none {
                        SecureField(
                            center.hasStoredCredential(serverID: server.id) ? "skills.skills_view.enter_new_credentials_to_replace_the" : "providers.credentials",
                            text: $credential
                        )
                        if center.hasStoredCredential(serverID: server.id) {
                            Label("skills.skills_view.credentials_saved_securely_in_keychain", systemImage: "checkmark.shield")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("skills.skills_view.network_security") {
                    Toggle("skills.skills_view.allow_insecure_http_trusted_lan_only", isOn: $server.allowInsecureHTTP)
                }
                if let tools = center.toolsByServerID[server.id], !tools.isEmpty {
                    Section("skills.skills_view.tools") {
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
            .navigationTitle(server.displayName.isEmpty ? "skills.skills_view.add_mcp" : server.displayName)
            .disabled(isSaving)
            .overlay { if isSaving { ProgressView() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("workspace.workspace_canvas_view.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("skills.skills_view.save_and_connect") { save() }
                        .disabled(server.displayName.trimmingCharacters(in: .whitespaces).isEmpty || endpointText.isEmpty)
                }
            }
        }
    }

    private func save() {
        validationMessage = nil
        guard let endpoint = URL(string: endpointText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            validationMessage = FloeL10n.l("skills.skills_view.enter_a_valid_mcp_url")
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
                    Section("skills.skills_view.python_scripts_audited_at_install") {
                        ForEach(pending.files.keys.filter { $0.hasPrefix("scripts/") }.sorted(), id: \.self) {
                            Label($0, systemImage: "doc.text")
                                .font(FloeTheme.Typography.evidence)
                        }
                    }
                }
                if !pending.manifest.pythonPackages.isEmpty {
                    Section("skills.skills_view.pure_python_dependencies_audited_at_install") {
                        ForEach(pending.manifest.pythonPackages, id: \.spec) { package in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(package.spec).font(FloeTheme.Typography.evidence)
                                Text(package.purpose)
                                    .font(FloeTheme.Typography.metadata)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("skills.skills_view.only_pinned_version_pypi_none_any")
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
