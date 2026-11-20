// SPDX-License-Identifier: MPL-2.0

import FloeCore
import FloeProviders
import SwiftUI

/// Provider management for the unified Mac workspace, grouped the iPad way:
/// one account (name / base URL / protocol / key) owns any number of chat
/// models. The list groups `workspace.providers` by `profile.id`; the editor
/// edits the shared account fields plus exactly one model at a time, so
/// saving a model never disturbs its siblings. Models are adopted from the
/// endpoint's live listing or added by hand; per-model enable, capability
/// and limit overrides persist through the workspace store worker. Removing
/// the whole provider stays a separate, explicit destructive action. The
/// existing iCloud controls are unchanged and stay out of scope here; the
/// auxiliary-models surface and the per-record advanced options sheet are
/// owned by the root lane.
struct MacProviderSettingsView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    let openImageModelSettings: () -> Void
    let openVideoModelSettings: () -> Void

    @State private var editingID: UUID?
    @State private var showsEditor = false
    @State private var draft = MacProviderDraft()
    @State private var manualModelID = ""
    @State private var removalCandidate: UUID?
    @State private var modelRemovalCandidate: UUID?
    @State private var showingICloud = false
    @State private var showsAuxiliary = false
    @State private var optionsRecord: HostAgentProvider?
    @State private var connectionCheck: Task<Void, Never>?
    @State private var connectionCheckID = UUID()
    @State private var connectionStatus: String?

    /// Shared chat-capable presets. Auxiliary (image-only) and on-device
    /// presets stay in their own surfaces, exactly like the App.
    private let presets = ProviderPreset.chatPresets

    private var groups: [HostProviderAccount] {
        workspace.accounts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var selectedRecord: HostAgentProvider? {
        workspace.providers.first { $0.profile.id == editingID }
    }

    private var connectionMatchesSavedAccount: Bool {
        guard let record = groups.first(where: { $0.id == editingID }) else { return false }
        return record.profile.baseURL == URL(string: draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
            && record.profile.wireProtocol == draft.protocolKind && record.apiKey == draft.key
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
                Divider()
                footer
            } else {
                providerList
            }
        }
        .onChange(of: draft.key) { _, _ in scheduleDiscovery() }
        .onChange(of: draft.protocolKind) { _, _ in scheduleDiscovery() }
        .onChange(of: draft.allowsPlainHTTP) { _, _ in scheduleDiscovery() }
        .onChange(of: draft) { _, _ in cancelConnectionCheck() }
        .onDisappear {
            cancelConnectionCheck()
            workspace.cancelModelDiscovery()
        }
        .sheet(isPresented: $showingICloud) {
            MacICloudModelsView(workspace: workspace, providerID: editingID, modelID: draft.editingModelID) { id in
                if let record = workspace.providers.first(where: { $0.model.id == id }) { beginEditing(record) }
            }
        }
        .sheet(isPresented: $showsAuxiliary) {
            MacAuxiliaryModelsView(workspace: workspace, openImageModelSettings: openImageModelSettings,
                                   openVideoModelSettings: openVideoModelSettings)
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
                Text("mac.settings.models").font(.title2.weight(.semibold))
                Spacer()
                Button { showingICloud = true } label: {
                    Label("mac.icloud.models", systemImage: "icloud")
                        .labelStyle(.iconOnly)
                }
                .help("mac.icloud.models")
                .accessibilityLabel("mac.icloud.models")
                .disabled(!workspace.isReady || workspace.isSending || workspace.isTerminating)
                Button(action: beginAdding) {
                    Label("mac.provider.add", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!workspace.isReady || workspace.isSending || workspace.isTerminating)
            }
            .padding(20)
            Divider()
            Button(action: openImageModelSettings) {
                Label("mac.provider.imageModel", systemImage: "photo")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            Button(action: openVideoModelSettings) {
                Label("mac.creative.videoModel", systemImage: "film")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            Button { showsAuxiliary = true } label: {
                Label(MacProviderText.t("辅助模型", "Auxiliary Models"), systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("settings.openAuxiliaryModels")
            #if FLOE_MAC_HOST_SMOKE
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { workspace.smokeAuxiliaryButtonFrame = $0 }
            #endif
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            if groups.isEmpty {
                ContentUnavailableView("mac.provider.noProviders", systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.id) { group in
                        Section {
                            ForEach(group.models, id: \.id) { model in modelListRow(group.record(model)) }
                            if group.models.isEmpty {
                                Button(MacProviderText.t("添加模型…", "Add Models…")) { beginEditingAccount(group) }
                            }
                        } header: {
                            providerListHeader(group)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func providerListHeader(_ group: HostProviderAccount) -> some View {
        HStack(spacing: 6) {
            Button { beginEditingAccount(group) } label: {
                HStack(spacing: 5) {
                    Text(verbatim: group.name).font(.headline).lineLimit(1)
                    Image(systemName: "slider.horizontal.3").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(MacProviderText.t("供应商配置", "Provider settings"))
            Spacer(minLength: 4)
            Text(MacProviderText.t("\(group.models.count) 个模型", "\(group.models.count) models"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(MacProviderText.t("编辑", "Edit")) {
                beginEditingAccount(group)
            }
            Button(MacProviderText.t("删除服务商", "Delete Provider"), role: .destructive) {
                removalCandidate = group.id
            }
        }
    }

    private func modelListRow(_ record: HostAgentProvider) -> some View {
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
            Button { beginEditing(record) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.model.displayName).lineLimit(1)
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
            if workspace.composerProvider?.model.id == record.model.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .help(MacProviderText.t("当前用于对话", "Used for chat"))
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button(MacProviderText.t("用于对话", "Use for Chat")) {
                _ = workspace.selectComposerModel(record.model.id)
            }
            .disabled(!record.canSelectAsPrimary || workspace.composerProvider?.model.id == record.model.id
                      || workspace.isSending || workspace.isTerminating)
            Button(MacProviderText.t("编辑", "Edit")) { beginEditing(record) }
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
                Picker("mac.provider.preset", selection: presetSelection) {
                    ForEach(presets) { preset in
                        Text(preset.displayName).tag(Optional(preset.id))
                    }
                }
                TextField(MacProviderText.t("名称（可选）", "Name (optional)"), text: $draft.name)
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
                Picker(MacProviderText.t("协议", "Protocol"), selection: $draft.protocolKind) {
                    Text("OpenAI Chat Completions").tag(ModelProtocol.openAIChatCompletions)
                    Text("OpenAI Responses").tag(ModelProtocol.openAIResponses)
                    Text("Anthropic Messages").tag(ModelProtocol.anthropicMessages)
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
                    refreshButton
                }
                discoveryStatus
                discoveredModelList
                if let providerID = editingID {
                    /// Saved account: manual entry appends one model under
                    /// this provider without touching loaded siblings.
                    if !connectionMatchesSavedAccount {
                        Text(MacProviderText.t("先保存连接更改，再添加此供应商的模型。", "Save connection changes before adding models."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        TextField(MacProviderText.t("手动添加模型 ID", "Manual model ID"), text: $manualModelID)
                        Button(MacProviderText.t("添加", "Add")) {
                            addManualModel(providerID: providerID)
                        }
                        .disabled(!connectionMatchesSavedAccount || manualModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || workspace.isSending || workspace.isTerminating)
                    }
                } else {
                    TextField(MacProviderText.t("首个模型 ID（可稍后添加）", "First model ID (optional)"), text: $draft.modelID)
                }
                if let modelID = draft.editingModelID {
                    Text(MacProviderText.t("正在编辑：\(modelDisplayName(modelID))",
                                           "Editing: \(modelDisplayName(modelID))"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(MacProviderText.t("支持图片输入", "Supports Image Input"),
                       isOn: capabilityBinding(\.supportsImages, bit: .vision))
                Toggle("mac.agent.modelSupportsTools", isOn: capabilityBinding(\.supportsTools, bit: .tools))
                Toggle("mac.permissions.modelEligible", isOn: capabilityBinding(\.supportsApproval, bit: .approval))
            }
            Section {
                TextField("mac.provider.contextTokens", value: $draft.limits.contextTokens, format: .number)
                TextField("mac.provider.outputTokens", value: $draft.limits.maxOutputTokens, format: .number)
                Text("mac.provider.tokenLimits.detail").font(.caption).foregroundStyle(.secondary)
            }
            if optionsTargetRecord != nil {
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
                if connectionCheck != nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("mac.provider.testingConnection")
                        Spacer()
                        Button("host.chat.cancel", action: cancelConnectionCheck)
                    }
                } else {
                    Button("mac.provider.testConnection", action: testConnection)
                        .disabled(draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          || !workspace.isReady || workspace.isTerminating)
                }
                if let connectionStatus { Text(connectionStatus).font(.caption).foregroundStyle(.secondary) }
            }
            if let record = optionsTargetRecord {
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

    private func groupRecords(_ providerID: UUID) -> [HostAgentProvider] {
        workspace.providers.filter { $0.profile.id == providerID }
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
            Button { loadModelIntoDraft(record) } label: {
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
                                             apiKey: draft.key, debounce: false, allowsPlainHTTP: draft.allowsPlainHTTP, providerID: editingID)
        } label: {
            Label("mac.provider.refreshModels", systemImage: "arrow.triangle.2.circlepath")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("mac.provider.refreshModelsHelp")
        .disabled(workspace.modelDiscoveryState == .discovering
                  || workspace.modelDiscoveryState == .listingUnavailable
                  || workspace.isSending || workspace.isTerminating)
    }

    @ViewBuilder private var discoveryStatus: some View {
        switch workspace.modelDiscoveryState {
        case .idle:
            if needsKeyForDiscovery {
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
        case .succeeded(let count):
            if count == 0 {
                Text("mac.provider.discoveryEmpty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("mac.provider.discoveryCount \(count)")
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
    @ViewBuilder private var discoveredModelList: some View {
        if !workspace.discoveredModels.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(workspace.discoveredModels, id: \.remoteModelID) { model in
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

    private func discoveredModelAddRow(_ model: ModelProfile) -> some View {
        let exists = workspace.providers.contains {
            $0.profile.id == editingID && $0.model.remoteModelID == model.remoteModelID
        }
        return Button {
            addDiscoveredModel(model)
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
                .keyboardShortcut(.defaultAction)
                .disabled(draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || workspace.isSending || workspace.isTerminating)
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
        let preset = ProviderPreset.preset(for: .custom, baseURL: url)
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
        return ProviderConfigurationValidation.ProviderConnectionIdentity.key(kind: .custom, baseURL: url)
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

    /// Explicit picker binding: user-driven preset picks apply the preset;
    /// programmatic id reloads (record load, new draft) change nothing.
    private var presetSelection: Binding<ProviderTemplateID?> {
        Binding(
            get: { draft.presetID },
            set: { newID in
                guard let newID, newID != draft.presetID else {
                    draft.presetID = newID
                    return
                }
                applyPreset(newID)
            }
        )
    }

    private func scheduleDiscovery() {
        guard showsEditor else { return }
        workspace.requestModelDiscovery(endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                                        apiKey: draft.key, debounce: true, allowsPlainHTTP: draft.allowsPlainHTTP, providerID: editingID)
    }

    /// Applies a user-picked preset: endpoint/protocol pre-fill and, only
    /// when the connection identity is unchanged, the key is kept. Runs the
    /// listing immediately — a preset endpoint is a confirmed endpoint.
    private func applyPreset(_ id: ProviderTemplateID) {
        guard let preset = presets.first(where: { $0.id == id }) else { return }
        draft.presetID = id
        let previousIdentity = connectionIdentity(draft.endpoint)
        draft.endpoint = preset.defaultBaseURL.absoluteString
        draft.protocolKind = preset.defaultProtocol
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || presets.contains(where: { $0.displayName == trimmedName }) {
            draft.name = preset.displayName
        }
        if previousIdentity != connectionIdentity(draft.endpoint) {
            draft.key = ""
            draft.allowsPlainHTTP = false
        }
        workspace.requestModelDiscovery(endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                                        apiKey: draft.key, debounce: false, allowsPlainHTTP: draft.allowsPlainHTTP, providerID: editingID)
    }

    /// Single record-activation path for every selection change (list
    /// selection, Add, initial appear): cancels the old listing generation,
    /// loads the record or a fresh draft and schedules one debounced
    /// listing. It never touches the key.
    private func activateCurrentSelection() {
        cancelConnectionCheck()
        workspace.cancelModelDiscovery()
        draft = selectedRecord.map(MacProviderDraft.init) ?? MacProviderDraft()
        scheduleDiscovery()
    }

    // MARK: - Actions

    private func beginEditingAccount(_ account: HostProviderAccount) {
        if let model = account.models.first { beginEditing(account.record(model)); return }
        cancelConnectionCheck()
        workspace.cancelModelDiscovery()
        editingID = account.id
        showsEditor = true
        draft = MacProviderDraft(name: account.profile.displayName ?? "", endpoint: account.profile.baseURL.absoluteString,
            protocolKind: account.profile.wireProtocol, key: account.apiKey, presetID: account.presetID.flatMap(ProviderTemplateID.init(rawValue:)),
            allowsPlainHTTP: account.profile.allowsPlainHTTP)
        manualModelID = ""
        scheduleDiscovery()
    }

    private func beginEditing(_ record: HostAgentProvider) {
        editingID = record.profile.id
        showsEditor = true
        loadModelIntoDraft(record)
    }

    private func beginAdding() {
        editingID = nil
        showsEditor = true
        activateCurrentSelection()
    }

    /// Loads one saved model of the open account into the draft so its
    /// capability/limit edits save back to exactly that model.
    private func loadModelIntoDraft(_ record: HostAgentProvider) {
        cancelConnectionCheck()
        draft = MacProviderDraft(record: record)
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
        let model = ModelProfile(providerID: providerID, remoteModelID: remote, displayName: remote,
                                 limits: .init(contextTokens: 32_768, maxOutputTokens: 0),
                                 capabilities: ModelCapabilities.defaultTextModel(for: draft.protocolKind))
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
        connectionCheckID = id
        connectionStatus = nil
        connectionCheck = Task {
            let status: String
            do {
                try await workspace.testProviderConnection(endpoint: candidate.endpoint, protocolKind: candidate.protocolKind,
                                                           modelID: candidate.modelID, key: candidate.key,
                                                           allowsPlainHTTP: candidate.allowsPlainHTTP, providerID: editingID)
                status = String(localized: "mac.provider.connectionSucceeded")
            } catch {
                status = String(localized: "mac.provider.connectionFailed")
            }
            guard !Task.isCancelled, connectionCheckID == id else { return }
            connectionStatus = status
            connectionCheck = nil
        }
    }

    private func cancelConnectionCheck() {
        connectionCheckID = UUID()
        connectionCheck?.cancel()
        connectionCheck = nil
        connectionStatus = nil
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? nil : name
        let presetID = draft.presetID?.rawValue
        let saved: Bool
        if let editingID {
            // Save the model that owns this draft, including when there are siblings.
            let editingModelID = draft.editingModelID
                ?? workspace.providers.first { $0.profile.id == editingID }?.model.id
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
                                          supportsApproval: draft.editedCapabilities.contains(.approval) ? draft.supportsApproval : nil)
        }
        if saved { closeEditor() }
    }
}

// MARK: - Draft

private struct MacProviderDraft: Equatable {
    struct CatalogSelection: Equatable {
        let model: ModelProfile
        let endpoint: String
        let wireProtocol: ModelProtocol
    }
    /// The saved model this draft's model fields describe; nil for a model
    /// that does not exist yet (a fresh account).
    var editingModelID: UUID?
    var catalogSelection: CatalogSelection?
    var editedCapabilities: ModelCapabilities = []
    var selectedCatalogModel: ModelProfile? {
        guard let selection = catalogSelection, selection.endpoint == endpoint,
              selection.wireProtocol == protocolKind, selection.model.remoteModelID == modelID else { return nil }
        return selection.model
    }

    var name: String
    var presetID: ProviderTemplateID?
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
        let endpointPreset = ProviderPreset.preset(for: .custom, baseURL: record.profile.baseURL)
        let savedPreset = record.presetID.flatMap(ProviderTemplateID.init(rawValue:))
        let resolved = savedPreset.flatMap { id in ProviderPreset.chatPresets.first { $0.id == id } }
            ?? endpointPreset
        self.init(name: record.profile.displayName ?? "",
                  endpoint: record.profile.baseURL.absoluteString,
                  protocolKind: record.profile.wireProtocol,
                  modelID: record.model.remoteModelID,
                  key: record.apiKey, supportsImages: record.model.capabilities.contains(.vision),
                  supportsTools: record.model.capabilities.contains(.tools), supportsApproval: record.model.supportsApprovalSurface,
                  presetID: resolved.id, limits: record.model.limits, allowsPlainHTTP: record.profile.allowsPlainHTTP,
                  editingModelID: record.model.id)
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
