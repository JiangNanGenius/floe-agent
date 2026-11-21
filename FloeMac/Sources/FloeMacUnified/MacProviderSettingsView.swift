// SPDX-License-Identifier: MPL-2.0

import FloeCore
import FloeProviders
import SwiftUI

/// One account owns its endpoint, credential and role-specific models.
struct MacProviderSettingsView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    private let openMediaSettings: ((ProviderCatalogServiceRole) -> Void)?
    #if FLOE_MAC_HOST_SMOKE
    static var smokeEditorRole: ProviderCatalogServiceRole?
    static var smokeSelectionFrames: [ProviderCatalogServiceRole: CGRect] = [:]
    static var smokeAccountFrames: [String: CGRect] = [:]
    static var smokeSupplierFrame: CGRect?
    static var smokeSupplierPickerMounted = false
    #endif
    @Binding private var pendingAddRole: ProviderCatalogServiceRole?
    @Binding private var editingID: UUID?
    @Binding private var showsEditor: Bool
    @Binding private var draft: MacProviderDraft
    @Binding private var manualModelID: String

    init(workspace: HostAgentWorkspace, editing: Binding<MacProviderEditorState>,
         openMediaSettings: ((ProviderCatalogServiceRole) -> Void)? = nil) {
        self.openMediaSettings = openMediaSettings
        self.workspace = workspace
        _pendingAddRole = editing.pendingAddRole
        _editingID = editing.editingID
        _showsEditor = editing.showsEditor
        _draft = editing.draft
        _manualModelID = editing.manualModelID
    }

    @State private var removalCandidate: UUID?
    @State private var modelRemovalCandidate: UUID?
    @State private var showingICloud = false
    @State private var optionsRecord: HostAgentProvider?
    @State private var connectionCheck: Task<Void, Never>?
    @State private var connectionCheckID = UUID()
    @State private var connectionStatus: String?
    @State private var testingMediaListing = false
    @State private var showsCatalog = false
    @State private var catalogError: String?
    /// Effective verified catalog (active signed install, else bundled),
    /// owned by the workspace and refreshed through the shared official
    /// catalogs service. Catalog data is public provider metadata only.
    private var catalog: ProviderCatalogIndex? { workspace.modelProviderCatalog }
    private var catalogEntry: ProviderCatalogEntry? {
        draft.savedPresetID.flatMap { catalog?.entry(presetID: $0) }
    }

    private var resolvedPreset: ProviderPreset {
        ProviderPreset.all.first { $0.id == draft.presetID }
            ?? ProviderPreset.preset(for: .custom, baseURL: URL(string: draft.endpoint))
    }

    private var planModelIDs: [String] {
        guard role == .conversation, [.volcengineAgentPlan, .alibabaTokenPlan].contains(resolvedPreset.id) else { return [] }
        return catalogEntry?.models ?? []
    }

    private var role: ProviderCatalogServiceRole { draft.role }
    private var formSpec: ProviderFormSpec {
        ProviderFormSpecResolver.resolve(role: role, preset: resolvedPreset, baseURL: URL(string: draft.endpoint),
            catalogEntry: catalogEntry)
    }
    private var presets: [ProviderPreset] { formSpec.eligiblePresets }

    private var groups: [HostProviderAccount] {
        workspace.accounts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var selectedRecord: HostAgentProvider? {
        workspace.providers.first { $0.profile.id == editingID && role.groups($0.model) }
    }

    private var connectionMatchesSavedAccount: Bool {
        guard let record = groups.first(where: { $0.id == editingID }) else { return false }
        let savedPreset = record.presetID ?? ProviderPreset.preset(for: record.profile.kind, baseURL: record.profile.baseURL).id.rawValue
        return record.profile.baseURL == URL(string: draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
            && savedPreset == draft.savedPresetID && record.profile.wireProtocol == draft.protocolKind
            && record.apiKey == draft.key && record.profile.allowsPlainHTTP == draft.allowsPlainHTTP
    }

    /// The saved record the advanced options sheet describes: the model
    /// currently loaded in the draft when there is one, otherwise the
    /// account's first model. Nil for an unsaved (new) provider.
    private var optionsTargetRecord: HostAgentProvider? {
        guard let providerID = editingID else { return nil }
        if let modelID = draft.editingModelID,
           let record = workspace.providers.first(where: { $0.profile.id == providerID && $0.model.id == modelID }) {
            return record
        }
        return selectedRecord
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsEditor {
                HStack {
                    Button(action: closeEditor) {
                        Label("mac.provider.backToProviders", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if selectedRecord != nil {
                        Button { showingICloud = true } label: {
                            Label("mac.icloud.models", systemImage: "icloud").labelStyle(.iconOnly)
                        }
                        .help("mac.icloud.models")
                        .disabled(!workspace.isReady || workspace.isSending || workspace.isTerminating)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                editor
                    #if FLOE_MAC_HOST_SMOKE
                    .onChange(of: role, initial: true) { _, role in Self.smokeEditorRole = role }
                    .onDisappear { Self.smokeEditorRole = nil }
                    #endif
                Divider()
                footer
            } else {
                providerList
            }
        }
        .onChange(of: pendingAddRole, initial: true) { _, requestedRole in
            if let requestedRole {
                pendingAddRole = nil
                beginAdding(requestedRole)
            }
        }
        .onChange(of: workspace.modelDiscoveryState) { _, state in
            guard testingMediaListing else { return }
            switch state {
            case .succeeded:
                connectionStatus = MacProviderText.t("已连接，供应商已返回模型列表。", "Connected. The provider returned its model list.")
            case .failed(let message):
                connectionStatus = message
            case .listingUnavailable:
                connectionStatus = String(localized: "mac.provider.discoveryUnavailable")
            case .idle, .discovering:
                return
            }
            testingMediaListing = false
        }
        .onChange(of: draft.key) { _, _ in scheduleDiscovery() }
        .onChange(of: draft.protocolKind) { _, _ in scheduleDiscovery() }
        .onChange(of: draft.allowsPlainHTTP) { _, _ in scheduleDiscovery() }
        .onChange(of: draft) { _, _ in cancelConnectionCheck() }
        .task { await workspace.loadActiveModelProviderCatalog() }
        .onDisappear {
            cancelConnectionCheck()
            workspace.cancelModelDiscovery()
        }
        .sheet(isPresented: $showingICloud) {
            MacICloudModelsView(workspace: workspace, providerID: editingID, modelID: draft.editingModelID) { id in
                if let record = workspace.providers.first(where: { $0.model.id == id }) { beginEditing(record) }
            }
        }
        .sheet(isPresented: Binding(
            get: { optionsRecord != nil },
            set: { if !$0 { optionsRecord = nil } }
        )) {
            if let record = optionsRecord {
                MacProviderOptionsView(workspace: workspace, record: record)
            }
        }
        .alert(MacProviderText.t("删除服务商", "Delete Provider"), isPresented: Binding(
            get: { removalCandidate != nil },
            set: { if !$0 { removalCandidate = nil } }
        )) {
            Button(MacProviderText.t("删除", "Delete"), role: .destructive) {
                if let id = removalCandidate {
                    let removedEditing = id == editingID
                    if workspace.removeProvider(id: id), removedEditing {
                        closeEditor()
                    }
                }
                removalCandidate = nil
            }
            Button(MacProviderText.t("取消", "Cancel"), role: .cancel) {
                removalCandidate = nil
            }
        } message: {
            Text(MacProviderText.t(
                "此服务商及其所有模型将从列表移除，聊天记录会保留。",
                "This provider and all of its models are removed from the list. Your chats are kept."))
        }
        .alert(MacProviderText.t("移除模型", "Remove Model"), isPresented: Binding(
            get: { modelRemovalCandidate != nil },
            set: { if !$0 { modelRemovalCandidate = nil } }
        )) {
            Button(MacProviderText.t("移除", "Remove"), role: .destructive) {
                if let modelID = modelRemovalCandidate {
                    _ = workspace.removeProviderModel(modelID: modelID)
                    if draft.editingModelID == modelID, let account = groups.first(where: { $0.id == editingID }) {
                        beginEditingAccount(account)
                    }
                }
                modelRemovalCandidate = nil
            }
            Button(MacProviderText.t("取消", "Cancel"), role: .cancel) {
                modelRemovalCandidate = nil
            }
        } message: {
            Text(MacProviderText.t(
                "仅此模型从该服务商移除，同账户下的其他模型不受影响。",
                "Only this model is removed from the provider. Other models under the same account are unaffected."))
        }
    }

    // MARK: - Provider list

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("mac.settings.providerModels").font(.headline)
                Spacer()
                Button { showingICloud = true } label: {
                    Label("mac.icloud.models", systemImage: "icloud")
                        .labelStyle(.iconOnly)
                }
                .help("mac.icloud.models")
                .accessibilityLabel("mac.icloud.models")
                .disabled(!workspace.isReady || workspace.isSending || workspace.isTerminating)
                Menu {
                    ForEach(ProviderCatalogServiceRole.allCases, id: \.self) { role in
                        Button(role.macProviderTitle, systemImage: role.macProviderIcon) { beginAdding(role) }
                            .accessibilityIdentifier("providers.add." + role.rawValue)
                    }
                } label: {
                    Label("mac.provider.add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("settings.providers.add")
                .disabled(!workspace.isReady || workspace.isSending || workspace.isTerminating)
            }
            .padding(20)
            Divider()
            if let openMediaSettings {
                HStack(spacing: 16) {
                    ForEach([ProviderCatalogServiceRole.image, .video], id: \.self) { role in
                        Button(role == .image ? MacProviderText.t("选择生图模型", "Choose Image Model")
                                              : MacProviderText.t("选择视频模型", "Choose Video Model")) {
                            openMediaSettings(role)
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("settings.providers.select." + role.rawValue)
                        #if FLOE_MAC_HOST_SMOKE
                        .background(MacWorkbenchButtonFrameReader { Self.smokeSelectionFrames[role] = $0 })
                        #endif
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
            if groups.isEmpty {
                ContentUnavailableView("mac.provider.noProviders", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(ProviderCatalogServiceRole.allCases, id: \.self) { role in
                        let accounts = groups.filter { account in
                            account.models.contains(where: role.groups)
                                || (account.models.isEmpty
                                    && role == (account.initialRole ?? .conversation))
                        }
                        if !accounts.isEmpty {
                            Section {
                                ForEach(accounts) { account in
                                    providerListHeader(account, role: role)
                                }
                            } header: { Label(role.macProviderTitle, systemImage: role.macProviderIcon) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func providerListHeader(_ group: HostProviderAccount, role: ProviderCatalogServiceRole) -> some View {
        let count = group.models.filter(role.groups).count
        return HStack(spacing: 8) {
            Button { beginEditingAccount(group, role: role) } label: {
                HStack {
                    Text(verbatim: group.name).lineLimit(1)
                    Spacer()
                    Text(MacProviderText.t("\(count) 个模型", "\(count) models"))
                        .font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings.providers.account." + role.rawValue + "." + group.id.uuidString)
            #if FLOE_MAC_HOST_SMOKE
            .background(MacWorkbenchButtonFrameReader {
                Self.smokeAccountFrames["\(role.rawValue).\(group.id.uuidString)"] = $0
            })
            #endif
            Toggle(isOn: Binding(get: { group.profile.isEnabled },
                                 set: { _ = workspace.setAccountEnabled(id: group.id, enabled: $0) })) {
                Text(MacProviderText.t("启用供应商", "Enable Provider"))
            }
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
            .disabled(workspace.isSending || workspace.isTerminating)
        }
        .contextMenu {
            Button(MacProviderText.t("编辑", "Edit")) { beginEditingAccount(group, role: role) }
            Button(MacProviderText.t("删除服务商", "Delete Provider"), role: .destructive) { removalCandidate = group.id }
        }
    }

    // MARK: - Editor

    private var editor: some View {
        Form {
            Section(editingID == nil
                    ? MacProviderText.t("添加服务商", "Add Provider")
                    : MacProviderText.t("编辑服务商", "Edit Provider")) {
                /// The binding setter is the ONLY preset application path:
                /// loading a record or starting another draft rewrites the
                /// id without touching endpoint, protocol or key.
                LabeledContent(MacProviderText.t("用途", "Use"), value: role.macModelTitle)
                /// One unified supplier entry point, matching iPad: tapping
                /// the provider field itself opens the searchable selector
                /// (built-in presets + verified official catalog together).
                LabeledContent("mac.provider.catalog.field") {
                    Button {
                        catalogError = nil
                        showsCatalog = true
                    } label: {
                        HStack(spacing: 6) {
                            Text(supplierFieldTitle).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 22, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.providers.preset")
                    .popover(isPresented: $showsCatalog, arrowEdge: .bottom) {
                        supplierPicker
                    }
                    #if FLOE_MAC_HOST_SMOKE
                    .background(MacWorkbenchButtonFrameReader { Self.smokeSupplierFrame = $0 })
                    #endif
                }
                TextField(MacProviderText.t("名称（可选）", "Name (optional)"), text: $draft.name)
                    .accessibilityIdentifier("settings.providers.name")
                /// User-only binding: typing compares the connection
                /// identity and may clear the key; programmatic reloads
                /// (record activation, preset application) never pass
                /// through here, so a loaded record's key is never erased.
                TextField(MacProviderText.t("API 基础地址", "API base URL"), text: endpointField)
                    .textContentType(.URL)
                if allowsLocalHTTP {
                    Toggle("mac.provider.allowLocalHTTP", isOn: $draft.allowsPlainHTTP)
                        .help("mac.provider.allowLocalHTTPHelp")
                }
                if formSpec.showsProtocolPicker {
                    Picker(MacProviderText.t("协议", "Protocol"), selection: Binding(get: { draft.protocolKind }, set: { wire in
                        if (draft.protocolKind == .anthropicMessages) != (wire == .anthropicMessages) { draft.key = "" }
                        draft.protocolKind = wire
                    })) {
                        Text("OpenAI Chat Completions").tag(ModelProtocol.openAIChatCompletions)
                        Text("OpenAI Responses").tag(ModelProtocol.openAIResponses)
                        Text("Anthropic Messages").tag(ModelProtocol.anthropicMessages)
                    }
                }
                SecureField(MacProviderText.t("API 密钥", "API key"), text: $draft.key)
                Text(MacProviderText.t(
                    "密钥只保存在本机钥匙串，不会同步到其他设备。",
                    "The key stays in this Mac's Keychain and never syncs to other devices."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let providerID = editingID, !groupRecords(providerID).isEmpty {
                Section("mac.provider.models") {
                    ForEach(groupRecords(providerID), id: \.model.id) { record in
                        editorModelRow(record)
                    }
                }
            }
            Section {
                HStack(spacing: 6) {
                    Text("mac.provider.models")
                    Spacer(minLength: 4)
                    if formSpec.showsModelListingRefresh { refreshButton }
                }
                discoveryStatus
                discoveredModelList
                additionalRolesMenu
                if let providerID = editingID {
                    /// Saved account: manual entry appends one model under
                    /// this provider without touching loaded siblings.
                    if !connectionMatchesSavedAccount {
                        Text(MacProviderText.t("先保存连接更改，再添加此供应商的模型。", "Save connection changes before adding models."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    let manualID = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
                    let existing = groupModel(matching: manualID)
                    HStack(spacing: 8) {
                        TextField(MacProviderText.t("手动添加模型 ID", "Manual model ID"), text: $manualModelID)
                        Button(existing != nil && role != .conversation ? assignRoleTitle : MacProviderText.t("添加", "Add")) {
                            if let existing { assignRole(to: existing) }
                            else { addManualModel(providerID: providerID) }
                        }
                        .disabled(!connectionMatchesSavedAccount || manualID.isEmpty || existing.map { role == .conversation || role.includes($0.model) } == true
                                  || workspace.isSending || workspace.isTerminating)
                    }
                } else {
                    TextField(MacProviderText.t("模型 ID", "Model ID"), text: $draft.modelID)
                        .accessibilityIdentifier("settings.providers.modelID")
                }
                if let modelID = draft.editingModelID {
                    Text(MacProviderText.t("正在编辑：\(modelDisplayName(modelID))",
                                           "Editing: \(modelDisplayName(modelID))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if role == .conversation {
                    Toggle(MacProviderText.t("支持图片输入", "Supports Image Input"),
                       isOn: capabilityBinding(\.supportsImages, bit: .vision))
                    Toggle("mac.agent.modelSupportsTools", isOn: capabilityBinding(\.supportsTools, bit: .tools))
                    Toggle("mac.permissions.modelEligible", isOn: capabilityBinding(\.supportsApproval, bit: .approval))
                }
            }
            if role == .conversation {
                Section {
                    TextField("mac.provider.contextTokens", value: $draft.limits.contextTokens, format: .number)
                    TextField("mac.provider.outputTokens", value: $draft.limits.maxOutputTokens, format: .number)
                    Text("mac.provider.tokenLimits.detail").font(.caption).foregroundStyle(.secondary)
                }
            }
            if role == .conversation, optionsTargetRecord != nil {
                Section {
                    Button { optionsRecord = optionsTargetRecord } label: {
                        HStack(spacing: 6) {
                            Label(MacProviderText.t("高级设置", "Advanced Settings"), systemImage: "gearshape")
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                if connectionCheck != nil || testingMediaListing {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("mac.provider.testingConnection")
                        Spacer()
                        Button("host.chat.cancel") {
                            if testingMediaListing { workspace.cancelModelDiscovery() }
                            cancelConnectionCheck()
                        }
                    }
                } else {
                    Button("mac.provider.testConnection", action: testConnection)
                        .disabled(draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          || !workspace.isReady || workspace.isTerminating)
                }
                if let connectionStatus { Text(connectionStatus).font(.caption).foregroundStyle(.secondary) }
            }
            if role == .conversation, let record = optionsTargetRecord {
                Section {
                    LabeledContent(MacProviderText.t("默认对话模型", "Default Chat Model")) {
                        if workspace.selectedModelID == record.model.id {
                            Label(MacProviderText.t("使用中", "In use"), systemImage: "checkmark.circle.fill")
                        } else {
                            Button(MacProviderText.t("设为默认", "Set as Default")) {
                                workspace.selectDefaultModel(record.model.id)
                            }
                            .disabled(!record.canSelectAsPrimary || workspace.isSending || workspace.isTerminating)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var supplierPicker: some View {
        ProviderCatalogPicker(
            role: role, presets: presets, selectedPresetID: draft.presetID, selectedCatalogID: draft.catalogID,
            catalog: catalog, configuredPresetIDs: Set(groups.compactMap(\.presetID)),
            onRefresh: { await refreshCatalog() }, refreshError: catalogError,
            onSelect: { entry in
                applyCatalogEntry(entry)
                showsCatalog = false
            },
            onSelectPreset: { preset in
                applyPreset(preset.id)
                showsCatalog = false
            }
        )
        #if FLOE_MAC_HOST_SMOKE
        .onAppear { Self.smokeSupplierPickerMounted = true }
        .onDisappear { Self.smokeSupplierPickerMounted = false }
        #endif
    }

    private func groupRecords(_ providerID: UUID) -> [HostAgentProvider] {
        workspace.providers.filter { $0.profile.id == providerID && role.groups($0.model) }
    }

    private func modelDisplayName(_ modelID: UUID) -> String {
        workspace.providers.first { $0.model.id == modelID }?.model.displayName ?? modelID.uuidString
    }

    /// One saved model row inside the editor: a direct enable toggle, a tap
    /// that loads the model into the draft for capability/limit edits, and
    /// a remove action scoped to exactly this model.
    private func editorModelRow(_ record: HostAgentProvider) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { record.model.isEnabled },
                set: { _ = workspace.setProviderModelEnabled(modelID: record.model.id, enabled: $0) }
            )) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(workspace.isSending || workspace.isTerminating)
            Button { loadModelIntoDraft(record, role: role) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(record.model.displayName).lineLimit(1)
                        if draft.editingModelID == record.model.id {
                            Text(MacProviderText.t("编辑中", "Editing"))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tint)
                        }
                    }
                    if record.model.displayName != record.model.remoteModelID {
                        Text(record.model.remoteModelID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer(minLength: 4)
            if record.model.capabilities.contains(.vision) {
                Label("mac.provider.images", systemImage: "photo")
                    .labelStyle(.iconOnly)
                    .help("mac.provider.images")
                    .foregroundStyle(.secondary)
            }
            if record.model.capabilities.contains(.tools) {
                Label("mac.provider.tools", systemImage: "wrench.and.screwdriver")
                    .labelStyle(.iconOnly)
                    .help("mac.provider.tools")
                    .foregroundStyle(.secondary)
            }
            Button { modelRemovalCandidate = record.model.id } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(MacProviderText.t("移除模型", "Remove Model"))
            .disabled(workspace.isSending || workspace.isTerminating)
        }
        .padding(.vertical, 2)
    }

    /// Re-runs the listing on demand; stays disabled where the endpoint
    /// publishes no listing at all.
    private var refreshButton: some View {
        Button {
            workspace.requestModelDiscovery(endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                                             apiKey: draft.key, debounce: false, allowsPlainHTTP: draft.allowsPlainHTTP, providerID: editingID, presetID: draft.presetID)
        } label: {
            Label("mac.provider.refreshModels", systemImage: "arrow.triangle.2.circlepath")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("mac.provider.refreshModelsHelp")
        .disabled(!formSpec.showsModelListingRefresh || workspace.modelDiscoveryState == .discovering
                  || workspace.modelDiscoveryState == .listingUnavailable
                  || workspace.isSending || workspace.isTerminating)
    }

    @ViewBuilder private var discoveryStatus: some View {
        switch workspace.modelDiscoveryState {
        case .idle:
            if formSpec.showsModelListingRefresh && needsKeyForDiscovery {
                Text("mac.provider.discoveryKeyHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .discovering:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("mac.provider.discovering")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .succeeded:
            let availableCount = discoveredForRole.count
            if availableCount == 0 {
                Text("mac.provider.discoveryEmpty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("mac.provider.discoveryCount \(availableCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .listingUnavailable:
            Text("mac.provider.discoveryUnavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text("mac.provider.discoveryFailed \(message)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Live listing rows. For a saved provider each row carries an add
    /// affordance so any number of listed models can be enabled under the
    /// same account; for a new provider selecting one copies the remote
    /// model ID into the draft as the account's first model.
    @ViewBuilder private var additionalRolesMenu: some View {
        if let account = groups.first(where: { $0.id == editingID }), connectionMatchesSavedAccount {
            let kind = ProviderPreset.all.first { $0.id.rawValue == account.presetID }?.kind ?? account.profile.kind
            let available = ProviderServiceOfferResolver.adapterSupportedMediaRoles(
                for: kind, presetID: account.presetID, baseURL: account.profile.baseURL)
            let roles = ProviderCatalogServiceRole.allCases.filter {
                $0 != role && (available.contains($0) || ($0 == .conversation && ProviderServiceOfferResolver.supportsConversation(for: kind)))
            }
            if !roles.isEmpty {
                Menu(MacProviderText.t("配置此账户的其他用途", "Configure Other Uses")) {
                    ForEach(roles, id: \.self) { role in
                        Button(role.macProviderTitle) { beginEditingAccount(account, role: role) }
                    }
                }.fixedSize()
            }
        }
    }

    private var discoveredForRole: [ModelProfile] {
        if role == .conversation {
            let kind = formSpec.kind
            let mediaIDs = Set(ProviderServiceOfferResolver.officialModelIDs(for: kind, role: .image)
                + ProviderServiceOfferResolver.officialModelIDs(for: kind, role: .video))
            let metadata = catalogEntry?.modelMetadata ?? [:]
            return workspace.discoveredModels.filter {
                $0.supportsChatAgentSurface && !mediaIDs.contains($0.remoteModelID)
                    && !ProviderCatalogCapabilityResolver.isGenerationModel(metadata[$0.remoteModelID])
            }
        }
        let spec = formSpec
        return workspace.discoveredModels.filter { spec.trustsDiscoveryForMedia || spec.isVerifiedMediaModel($0.remoteModelID) || role.includes($0) }
    }

    private var candidates: [ModelProfile] {
        var models = discoveredForRole
        let seeds = role == .conversation ? planModelIDs : formSpec.seedModelIDs
        let known = Set(models.map(\.remoteModelID))
        for remote in seeds where !known.contains(remote) {
            var model = ModelProfile(providerID: editingID ?? draft.candidateProviderID, remoteModelID: remote,
                displayName: remote, limits: draft.limits, capabilities: ModelCapabilities.defaultTextModel(for: draft.protocolKind))
            role.configureNewModel(&model)
            models.append(model)
        }
        return models
    }

    @ViewBuilder private var discoveredModelList: some View {
        let models = candidates
        if !models.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(models, id: \.remoteModelID) { model in
                        if editingID != nil {
                            discoveredModelAddRow(model)
                        } else {
                            discoveredModelPickRow(model)
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }

    private var assignRoleTitle: String {
        role == .image ? MacProviderText.t("改为生图模型", "Use as Image Model")
                       : MacProviderText.t("改为视频模型", "Use as Video Model")
    }

    private func groupModel(matching remoteID: String) -> HostAgentProvider? {
        workspace.providers.first { $0.profile.id == editingID && $0.model.remoteModelID == remoteID }
    }

    private func assignRole(to record: HostAgentProvider) {
        guard role != .conversation, !role.includes(record.model), connectionMatchesSavedAccount,
              workspace.assignMediaRole(role, to: record.model.id, providerID: record.profile.id),
              let saved = workspace.providers.first(where: { $0.model.id == record.model.id }) else { return }
        loadModelIntoDraft(saved)
    }

    private func discoveredModelAddRow(_ model: ModelProfile) -> some View {
        let existing = groupModel(matching: model.remoteModelID)
        let adoptExisting = existing.map { role != .conversation && !role.includes($0.model) } ?? false
        let exists = existing != nil && !adoptExisting
        return Button {
            if let existing { assignRole(to: existing) }
            else { addDiscoveredModel(model) }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName).lineLimit(1)
                    if model.displayName != model.remoteModelID {
                        Text(model.remoteModelID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if model.capabilities.contains(.vision) {
                    Label("mac.provider.images", systemImage: "photo")
                        .labelStyle(.iconOnly)
                        .help("mac.provider.images")
                        .foregroundStyle(.secondary)
                }
                if model.capabilities.contains(.tools) {
                    Label("mac.provider.tools", systemImage: "wrench.and.screwdriver")
                        .labelStyle(.iconOnly)
                        .help("mac.provider.tools")
                        .foregroundStyle(.secondary)
                }
                if adoptExisting { Text(assignRoleTitle).font(.caption).foregroundStyle(.tint) }
                Image(systemName: exists ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(exists ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .disabled(!connectionMatchesSavedAccount || exists || workspace.isSending || workspace.isTerminating)
    }

    private func discoveredModelPickRow(_ model: ModelProfile) -> some View {
        let selected = draft.modelID == model.remoteModelID
        return Button {
            let saved = workspace.providers.first {
                $0.profile.id == editingID && $0.profile.baseURL.absoluteString == draft.endpoint
                    && $0.profile.wireProtocol == draft.protocolKind && $0.model.remoteModelID == model.remoteModelID
            }?.model
            if !selected {
                draft.limits = saved?.limits ?? model.limits
                draft.editedCapabilities = []
            }
            draft.catalogSelection = .init(model: model, endpoint: draft.endpoint, wireProtocol: draft.protocolKind)
            draft.modelID = model.remoteModelID
            let owned = (saved?.explicitCapabilities ?? []).union(draft.editedCapabilities)
            if !owned.contains(.vision) {
                draft.supportsImages = model.capabilities.contains(.vision)
            } else if !selected {
                draft.supportsImages = saved?.capabilities.contains(.vision) == true
            }
            if !owned.contains(.approval) {
                draft.supportsApproval = model.supportsApprovalSurface
            } else if !selected {
                draft.supportsApproval = saved?.supportsApprovalSurface == true
            }
            if !owned.contains(.tools) {
                draft.supportsTools = model.capabilities.contains(.tools)
            } else if !selected {
                draft.supportsTools = saved?.capabilities.contains(.tools) == true
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.displayName).lineLimit(1)
                    if model.displayName != model.remoteModelID {
                        Text(model.remoteModelID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if model.capabilities.contains(.vision) {
                    Label("mac.provider.images", systemImage: "photo")
                        .labelStyle(.iconOnly)
                        .help("mac.provider.images")
                        .foregroundStyle(.secondary)
                }
                if model.capabilities.contains(.tools) {
                    Label("mac.provider.tools", systemImage: "wrench.and.screwdriver")
                        .labelStyle(.iconOnly)
                        .help("mac.provider.tools")
                        .foregroundStyle(.secondary)
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let notice = workspace.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if editingID != nil {
                /// Provider removal is deliberately separate from per-model
                /// removal: it always asks before deleting the account.
                Button(MacProviderText.t("删除服务商", "Delete Provider"), role: .destructive) {
                    removalCandidate = editingID
                }
            }
            Button(MacProviderText.t("保存", "Save")) { save() }
                .accessibilityIdentifier("settings.providers.save")
                .keyboardShortcut(.defaultAction)
                .disabled(draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (editingID == nil && draft.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                          || (role != .conversation && !formSpec.roleAdapterAvailable) || workspace.isSending || workspace.isTerminating)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Discovery wiring

    private func capabilityBinding(_ key: WritableKeyPath<MacProviderDraft, Bool>,
                                   bit: ModelCapabilities) -> Binding<Bool> {
        Binding(get: { draft[keyPath: key] }, set: { value in
            draft[keyPath: key] = value
            draft.editedCapabilities.insert(bit)
        })
    }

    private var allowsLocalHTTP: Bool {
        guard let url = URL(string: draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return url.scheme?.lowercased() == "http" && url.isLocalOrPrivateNetwork
    }

    /// True when the current endpoint supports listing but no key is entered:
    /// discovery stays idle and the editor shows the key hint instead.
    private var needsKeyForDiscovery: Bool {
        guard let url = URL(string: draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return false }
        let preset = ProviderPreset.all.first { $0.id == draft.presetID } ?? ProviderPreset.preset(for: .custom, baseURL: url)
        return preset.supportsModelDiscovery && preset.authStyle != .none && !draft.allowsPlainHTTP
            && draft.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Normalized connection identity (scheme/host/port plus provider route
    /// and auth family) via the shared validation rule; nil while the URL is
    /// not absolute yet. Keys are never carried across identity changes,
    /// including subscription-route changes at the same host.
    private func connectionIdentity(_ endpoint: String)
    -> ProviderConfigurationValidation.ProviderConnectionIdentity.Key? {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let kind = ProviderPreset.all.first { $0.id == draft.presetID }?.kind ?? .custom
        return ProviderConfigurationValidation.ProviderConnectionIdentity.key(kind: kind, baseURL: url)
    }

    /// User-only endpoint binding: each typed edit compares the connection
    /// identity and clears the draft key on any change — also for new
    /// drafts — so no request can carry a key to a host it was not typed
    /// for. A key typed afterwards always belongs to the exact endpoint in
    /// the field, and an edited custom endpoint otherwise waits for explicit
    /// Refresh. Programmatic reloads (record activation, preset application)
    /// never pass through here, so a loaded record's key is never erased.
    private var endpointField: Binding<String> {
        Binding(
            get: { draft.endpoint },
            set: { newValue in
                let previous = draft.endpoint
                draft.endpoint = newValue
                if connectionIdentity(previous) != connectionIdentity(newValue) {
                    draft.key = ""
                    draft.allowsPlainHTTP = false
                }
                scheduleDiscovery()
            }
        )
    }

    /// Title of the unified supplier field: the anchored catalog entry name
    /// wins, then the selected preset label; an explicit choose prompt when
    /// nothing is selected yet.
    private var supplierFieldTitle: String {
        if let catalogID = draft.catalogID,
           let entry = catalog?.entry(presetID: catalogID) {
            return entry.name
        }
        if let preset = presets.first(where: { $0.id == draft.presetID }) {
            return preset.displayName
        }
        return String(localized: "mac.provider.catalog.choose")
    }

    /// Signed catalog refresh through the workspace. The picker keeps serving
    /// the previous snapshot on failure; the real error stays visible next to
    /// a retry, and manual endpoint/model input remains fully usable.
    private func refreshCatalog() async {
        catalogError = nil
        do {
            try await workspace.refreshModelProviderCatalog()
        } catch {
            catalogError = error.localizedDescription
        }
    }

    private func applyCatalogEntry(_ entry: ProviderCatalogEntry) {
        guard let url = entry.baseURL else { return }
        applySupplier(template: ProviderPreset.preset(for: entry.kind, baseURL: url), catalogID: entry.presetID,
            name: entry.name, endpoint: url, wire: entry.defaultProtocol)
    }

    private func scheduleDiscovery() {
        guard showsEditor else { return }
        guard formSpec.showsModelListingRefresh else { workspace.cancelModelDiscovery(); return }
        workspace.requestModelDiscovery(endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                                        apiKey: draft.key, debounce: true, allowsPlainHTTP: draft.allowsPlainHTTP, providerID: editingID, presetID: draft.presetID)
    }

    private func applyPreset(_ id: ProviderTemplateID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        applySupplier(template: preset, catalogID: nil, name: preset.displayName,
            endpoint: preset.defaultBaseURL, wire: preset.defaultProtocol)
    }

    private func applySupplier(template: ProviderPreset, catalogID: String?, name: String, endpoint: URL, wire: ModelProtocol) {
        let previousIdentity = connectionIdentity(draft.endpoint)
        let previousWire = draft.protocolKind
        let replaceName = ProviderConfigurationValidation.ProviderSelectionFieldPolicy.shouldReplaceDisplayName(
            current: draft.name, previousDefault: catalogEntry?.name ?? resolvedPreset.displayName)
            || draft.name == resolvedPreset.displayName
        let wasSeed = draft.modelID.isEmpty || draft.catalogSelection != nil || candidates.contains { $0.remoteModelID == draft.modelID }
        draft.catalogID = catalogID == template.id.rawValue ? nil : catalogID
        draft.presetID = template.id
        draft.endpoint = endpoint.absoluteString
        draft.protocolKind = wire
        if replaceName { draft.name = name }
        if previousIdentity != connectionIdentity(draft.endpoint) || (previousWire == .anthropicMessages) != (wire == .anthropicMessages) {
            draft.key = ""
            draft.allowsPlainHTTP = false
        }
        if editingID == nil {
            draft.catalogSelection = nil
            if wasSeed {
                draft.modelID = (role == .conversation ? planModelIDs.first : formSpec.seedModelIDs.first) ?? ""
            }
        }
        scheduleDiscovery()
    }

    private func beginEditingAccount(_ account: HostProviderAccount, role requested: ProviderCatalogServiceRole? = nil) {
        let selected = requested ?? role
        if let model = account.models.first(where: selected.groups) {
            editingID = account.id
            showsEditor = true
            loadModelIntoDraft(account.record(model), role: selected)
            return
        }
        cancelConnectionCheck()
        workspace.cancelModelDiscovery()
        editingID = account.id
        showsEditor = true
        draft = MacProviderDraft(name: account.profile.displayName ?? "", endpoint: account.profile.baseURL.absoluteString,
            protocolKind: account.profile.wireProtocol, key: account.apiKey, presetID: account.presetID.flatMap(ProviderTemplateID.init(rawValue:))
                ?? ProviderPreset.preset(for: account.profile.kind, baseURL: account.profile.baseURL).id,
            allowsPlainHTTP: account.profile.allowsPlainHTTP)
        draft.catalogID = account.presetID.flatMap { ProviderTemplateID(rawValue: $0) == nil ? $0 : nil }
        draft.role = selected
        manualModelID = ""
        scheduleDiscovery()
    }

    private func beginEditing(_ record: HostAgentProvider) {
        editingID = record.profile.id
        showsEditor = true
        loadModelIntoDraft(record)
    }

    private func beginAdding(_ role: ProviderCatalogServiceRole) {
        cancelConnectionCheck()
        workspace.cancelModelDiscovery()
        editingID = nil
        showsEditor = true
        manualModelID = ""
        draft = MacProviderDraft(presetID: nil)
        draft.role = role
        if let preset = ProviderFormSpecResolver.eligiblePresets(for: role).first { applyPreset(preset.id) }
    }

    private func loadModelIntoDraft(_ record: HostAgentProvider, role: ProviderCatalogServiceRole? = nil) {
        cancelConnectionCheck()
        draft = MacProviderDraft(record: record)
        if let role { draft.role = role }
        manualModelID = ""
        scheduleDiscovery()
    }

    private func closeEditor() {
        cancelConnectionCheck()
        showsEditor = false
        editingID = nil
        draft = MacProviderDraft()
        manualModelID = ""
        workspace.cancelModelDiscovery()
    }

    /// Adopts one live-listed model under the open account. Siblings are
    /// untouched; duplicates are rejected by the row's disabled state.
    private func addDiscoveredModel(_ model: ModelProfile) {
        guard connectionMatchesSavedAccount, let providerID = editingID, !workspace.isSending, !workspace.isTerminating else { return }
        var candidate = model
        role.configureNewModel(&candidate)
        candidate.providerID = providerID
        if workspace.addProviderModel(providerID: providerID, model: candidate), draft.editingModelID == nil,
           let saved = workspace.providers.first(where: { $0.model.id == candidate.id }) { loadModelIntoDraft(saved) }
    }

    /// Adds a hand-typed model ID under the open account with the protocol's
    /// default chat capabilities; users can refine it afterwards through the
    /// per-model capability and limit controls.
    private func addManualModel(providerID: UUID) {
        let remote = manualModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connectionMatchesSavedAccount, !remote.isEmpty, !workspace.isSending, !workspace.isTerminating else { return }
        var model = ModelProfile(providerID: providerID, remoteModelID: remote, displayName: remote,
                                 limits: .init(contextTokens: 32_768, maxOutputTokens: 0),
                                 capabilities: ModelCapabilities.defaultTextModel(for: draft.protocolKind))
        role.configureNewModel(&model)
        if workspace.addProviderModel(providerID: providerID, model: model) {
            manualModelID = ""
            if draft.editingModelID == nil, let saved = workspace.providers.first(where: { $0.model.id == model.id }) {
                loadModelIntoDraft(saved)
            }
        }
    }

    private func testConnection() {
        let id = UUID()
        let candidate = draft
        if role != .conversation {
            guard (try? HostProviderAccount.configured(name: nil, endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                apiKey: draft.key, presetID: draft.savedPresetID, allowsPlainHTTP: draft.allowsPlainHTTP,
                catalog: catalog)) != nil else {
                connectionStatus = MacProviderText.t("请检查接口地址和密钥格式。", "Check the endpoint URL and API key format.")
                return
            }
            switch formSpec.mediaProbe {
            case .contractWithCredentialListing:
                guard !needsKeyForDiscovery else {
                    connectionStatus = String(localized: "mac.provider.discoveryKeyHint")
                    return
                }
                testingMediaListing = true
                connectionStatus = nil
                workspace.requestModelDiscovery(endpoint: candidate.endpoint, protocolKind: candidate.protocolKind,
                                                apiKey: candidate.key, debounce: false, allowsPlainHTTP: candidate.allowsPlainHTTP,
                                                providerID: editingID, presetID: candidate.presetID)
            case .contractOnly:
                connectionStatus = MacProviderText.t("已支持此接口；运行生成任务时验证凭据。", "This endpoint is supported. Credentials are checked when you generate media.")
            case .unavailable, .chatOnly:
                connectionStatus = MacProviderText.t("此接口不支持所选用途。", "This endpoint does not support the selected use.")
            }
            return
        }
        connectionCheckID = id
        connectionStatus = nil
        connectionCheck = Task {
            let status: String
            do {
                try await workspace.testProviderConnection(endpoint: candidate.endpoint, protocolKind: candidate.protocolKind,
                                                           modelID: candidate.modelID, key: candidate.key,
                                                           allowsPlainHTTP: candidate.allowsPlainHTTP, providerID: editingID, presetID: candidate.presetID)
                status = String(localized: "mac.provider.connectionSucceeded")
            } catch {
                status = SecretRedactor.redact(error.localizedDescription, secret: candidate.key.isEmpty ? nil : candidate.key)
            }
            guard !Task.isCancelled, connectionCheckID == id else { return }
            connectionStatus = status
            connectionCheck = nil
        }
    }

    private func cancelConnectionCheck() {
        testingMediaListing = false
        connectionCheckID = UUID()
        connectionCheck?.cancel()
        connectionCheck = nil
        connectionStatus = nil
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? nil : name
        let presetID = draft.savedPresetID
        let saved: Bool
        if let editingID {
            // Save the model that owns this draft, including when there are siblings.
            guard let editingModelID = draft.editingModelID else {
                if workspace.updateProviderAccount(id: editingID, name: displayName, endpoint: draft.endpoint,
                    protocolKind: draft.protocolKind, key: draft.key, presetID: presetID, allowsPlainHTTP: draft.allowsPlainHTTP) {
                    closeEditor()
                }
                return
            }
            saved = workspace.updateProvider(id: editingID, name: displayName,
                                             endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                                             modelID: draft.modelID, key: draft.key,
                                             supportsImages: draft.supportsImages, supportsTools: draft.supportsTools,
                                             presetID: presetID, limits: draft.limits, allowsPlainHTTP: draft.allowsPlainHTTP,
                                             catalogModel: draft.selectedCatalogModel, explicit: draft.editedCapabilities,
                                             supportsApproval: draft.editedCapabilities.contains(.approval) ? draft.supportsApproval : nil,
                                             editingModelID: editingModelID)
        } else {
            saved = workspace.addProvider(name: displayName,
                                          endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                                          modelID: draft.modelID, key: draft.key,
                                          supportsImages: draft.supportsImages, supportsTools: draft.supportsTools,
                                          presetID: presetID, limits: draft.limits, allowsPlainHTTP: draft.allowsPlainHTTP,
                                          catalogModel: draft.selectedCatalogModel, explicit: draft.editedCapabilities,
                                          supportsApproval: draft.editedCapabilities.contains(.approval) ? draft.supportsApproval : nil,
                                          role: role)
        }
        if saved { closeEditor() }
    }
}

// MARK: - Draft

struct MacProviderEditorState {
    var pendingAddRole: ProviderCatalogServiceRole?
    var editingID: UUID?
    var showsEditor = false
    var draft = MacProviderDraft()
    var manualModelID = ""
}

struct MacProviderDraft: Equatable {
    struct CatalogSelection: Equatable {
        let model: ModelProfile
        let endpoint: String
        let wireProtocol: ModelProtocol
    }
    /// The saved model this draft's model fields describe; nil for a model
    /// that does not exist yet (a fresh account).
    var editingModelID: UUID?
    var role: ProviderCatalogServiceRole = .conversation
    let candidateProviderID = UUID()
    var catalogSelection: CatalogSelection?
    var editedCapabilities: ModelCapabilities = []
    var selectedCatalogModel: ModelProfile? {
        guard let selection = catalogSelection, selection.endpoint == endpoint,
              selection.wireProtocol == protocolKind, selection.model.remoteModelID == modelID else { return nil }
        return selection.model
    }

    var name: String
    var presetID: ProviderTemplateID?
    var catalogID: String?
    var savedPresetID: String? { catalogID ?? presetID?.rawValue }
    var endpoint: String
    var protocolKind: ModelProtocol
    var modelID: String
    var key: String
    var allowsPlainHTTP: Bool
    var supportsImages: Bool
    var supportsTools: Bool
    var supportsApproval: Bool
    var limits: ModelLimits

    init(name: String = "", endpoint: String = "",
         protocolKind: ModelProtocol = .openAIChatCompletions,
         modelID: String = "", key: String = "", supportsImages: Bool = false, supportsTools: Bool? = nil, supportsApproval: Bool? = nil,
         presetID: ProviderTemplateID? = .custom,
         limits: ModelLimits = .init(contextTokens: 32_768, maxOutputTokens: 0), allowsPlainHTTP: Bool = false,
         editingModelID: UUID? = nil) {
        self.name = name
        self.endpoint = endpoint
        self.protocolKind = protocolKind
        self.modelID = modelID
        self.key = key
        self.allowsPlainHTTP = allowsPlainHTTP
        self.supportsImages = supportsImages
        self.supportsApproval = supportsApproval ?? ModelCapabilities.defaultTextModel(for: protocolKind).contains(.approval)
        self.supportsTools = supportsTools ?? ModelCapabilities.defaultTextModel(for: protocolKind).contains(.tools)
        self.presetID = presetID
        self.limits = limits
        self.editingModelID = editingModelID
    }

    init(record: HostAgentProvider) {
        // The saved preset identity wins; records saved before presets
        // existed resolve from the endpoint instead.
        let endpointPreset = ProviderPreset.preset(for: record.profile.kind, baseURL: record.profile.baseURL)
        let savedPreset = record.presetID.flatMap(ProviderTemplateID.init(rawValue:))
        let resolved = savedPreset.flatMap { id in ProviderPreset.all.first { $0.id == id } }
            ?? endpointPreset
        self.init(name: record.profile.displayName ?? "",
                  endpoint: record.profile.baseURL.absoluteString,
                  protocolKind: record.profile.wireProtocol,
                  modelID: record.model.remoteModelID,
                  key: record.apiKey, supportsImages: record.model.capabilities.contains(.vision),
                  supportsTools: record.model.capabilities.contains(.tools), supportsApproval: record.model.supportsApprovalSurface,
                  presetID: resolved.id, limits: record.model.limits, allowsPlainHTTP: record.profile.allowsPlainHTTP,
                  editingModelID: record.model.id)
        catalogID = record.presetID.flatMap { ProviderTemplateID(rawValue: $0) == nil ? $0 : nil }
        role = ProviderCatalogServiceRole.allCases.first { $0.includes(record.model) } ?? .conversation
    }
}

private extension ProviderCatalogServiceRole {
    func groups(_ model: ModelProfile) -> Bool {
        includes(model) || (self == .conversation && !Self.allCases.contains { $0.includes(model) })
    }

    var macModelTitle: String {
        switch self {
        case .conversation: MacProviderText.t("对话模型", "Chat Model")
        case .image: MacProviderText.t("生图模型", "Image Model")
        case .video: MacProviderText.t("视频模型", "Video Model")
        }
    }
    var macProviderTitle: String {
        switch self {
        case .conversation: MacProviderText.t("对话模型供应商", "Chat Model Providers")
        case .image: MacProviderText.t("生图与编辑供应商", "Image Generation & Editing Providers")
        case .video: MacProviderText.t("视频生成供应商", "Video Generation Providers")
        }
    }
    var macProviderIcon: String {
        switch self {
        case .conversation: "bubble.left.and.text.bubble.right"
        case .image: "photo.on.rectangle.angled"
        case .video: "video"
        }
    }
}

// MARK: - Bilingual text

/// EN / zh-CN inline strings for this view. The Mac host follows the system
/// language for its catalog, so this mirrors the same resolution without
/// adding new catalog keys.
private enum MacProviderText {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }

    static func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }
}
