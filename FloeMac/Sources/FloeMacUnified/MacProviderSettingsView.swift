// SPDX-License-Identifier: MPL-2.0

import FloeCore
import FloeProviders
import SwiftUI

/// Provider management for the unified Mac workspace: lists the saved
/// providers, edits or removes them, and chooses which one chat uses.
/// All records live in the existing device-bound chat Keychain namespace;
/// failures surface as the workspace's existing local notices.
///
/// The editor reuses the shared provider presets and the factory adapters:
/// picking a preset pre-fills endpoint/protocol/name, a valid endpoint and
/// key discover the live model listing automatically (debounced, cancelled
/// on every edit so a stale listing never crosses a provider change), an
/// explicit Refresh re-runs the listing, discovered rows carry the endpoint's
/// capability metadata into the draft, and manual model entry always stays
/// available as the fallback.
struct MacProviderSettingsView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    @Binding var isPresented: Bool

    @State private var editingID: UUID?
    @State private var draft = MacProviderDraft()
    @State private var removalCandidate: UUID?

    /// Shared chat-capable presets. Auxiliary (image-only) and on-device
    /// presets stay in their own surfaces, exactly like the App.
    private let presets = ProviderPreset.chatPresets

    private var selectedRecord: HostAgentProvider? {
        workspace.providers.first { $0.profile.id == editingID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                providerList
                    .frame(width: 236)
                Divider()
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 540)
        .onAppear(perform: beginInitialEditing)
        .onChange(of: editingID) { _, _ in activateCurrentSelection() }
        .onChange(of: draft.key) { _, _ in scheduleDiscovery() }
        .onChange(of: draft.protocolKind) { _, _ in scheduleDiscovery() }
        .onDisappear { workspace.cancelModelDiscovery() }
        .alert(MacProviderText.t("删除服务商", "Delete Provider"), isPresented: Binding(
            get: { removalCandidate != nil },
            set: { if !$0 { removalCandidate = nil } }
        )) {
            Button(MacProviderText.t("删除", "Delete"), role: .destructive) {
                if let id = removalCandidate {
                    let removedEditing = id == editingID
                    if workspace.removeProvider(id: id), removedEditing {
                        beginAdding()
                    }
                }
                removalCandidate = nil
            }
            Button(MacProviderText.t("取消", "Cancel"), role: .cancel) {
                removalCandidate = nil
            }
        } message: {
            Text(MacProviderText.t(
                "此服务商将从列表中移除，聊天记录会保留。",
                "This provider is removed from the list. Your chats are kept."))
        }
    }

    // MARK: - Provider list

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $editingID) {
                if workspace.providers.isEmpty {
                    Text(MacProviderText.t("还没有服务商。点“添加”开始配置。", "No providers yet. Choose Add to set one up."))
                        .foregroundStyle(.secondary)
                }
                ForEach(workspace.providers, id: \.profile.id) { record in
                    providerRow(record)
                        .tag(Optional(record.profile.id))
                }
            }
            HStack {
                Button(action: beginAdding) {
                    Label(MacProviderText.t("添加", "Add"), systemImage: "plus")
                }
                Spacer()
            }
            .padding(8)
        }
    }

    private func providerRow(_ record: HostAgentProvider) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayTitle).lineLimit(1)
                Text(record.model.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if workspace.selectedProviderID == record.profile.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .help(MacProviderText.t("当前用于对话", "Used for chat"))
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(MacProviderText.t("用于对话", "Use for Chat")) {
                workspace.selectChatProvider(id: record.profile.id)
            }
            .disabled(workspace.selectedProviderID == record.profile.id
                      || workspace.isSending || workspace.isTerminating)
            Button(MacProviderText.t("编辑", "Edit")) { beginEditing(record) }
            Button(MacProviderText.t("删除", "Delete"), role: .destructive) {
                removalCandidate = record.profile.id
            }
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
            Section {
                HStack(spacing: 6) {
                    Text("mac.provider.models")
                    Spacer(minLength: 4)
                    refreshButton
                }
                discoveryStatus
                discoveredModelList
                TextField("host.chat.modelID", text: $draft.modelID)
                Toggle(MacProviderText.t("支持图片输入", "Supports Image Input"), isOn: $draft.supportsImages)
                Toggle("mac.agent.modelSupportsTools", isOn: $draft.supportsTools)
            }
            if let record = selectedRecord {
                Section {
                    LabeledContent(MacProviderText.t("对话", "Chat")) {
                        if workspace.selectedProviderID == record.profile.id {
                            Label(MacProviderText.t("使用中", "In use"), systemImage: "checkmark.circle.fill")
                        } else {
                            Button(MacProviderText.t("用于对话", "Use for Chat")) {
                                workspace.selectChatProvider(id: record.profile.id)
                            }
                            .disabled(workspace.isSending || workspace.isTerminating)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Re-runs the listing on demand; stays disabled where the endpoint
    /// publishes no listing at all.
    private var refreshButton: some View {
        Button {
            workspace.requestModelDiscovery(endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                                            apiKey: draft.key, debounce: false)
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

    /// Live listing rows. Selecting one copies the remote model ID into the
    /// draft and adopts the capability metadata the endpoint reported; the
    /// manual model field below always stays editable.
    @ViewBuilder private var discoveredModelList: some View {
        if !workspace.discoveredModels.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(workspace.discoveredModels, id: \.remoteModelID) { model in
                        discoveredModelRow(model)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
    }

    private func discoveredModelRow(_ model: ModelProfile) -> some View {
        let selected = draft.modelID == model.remoteModelID
        return Button {
            draft.modelID = model.remoteModelID
            draft.supportsImages = model.capabilities.contains(.vision)
            draft.supportsTools = model.capabilities.contains(.tools)
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
                Button(MacProviderText.t("删除", "Delete"), role: .destructive) {
                    removalCandidate = editingID
                }
            }
            Button(MacProviderText.t("取消", "Cancel"), role: .cancel) {
                isPresented = false
            }
            .keyboardShortcut(.cancelAction)
            Button(MacProviderText.t("保存", "Save")) { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || draft.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || workspace.isSending || workspace.isTerminating)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Discovery wiring

    /// True when the current endpoint supports listing but no key is entered:
    /// discovery stays idle and the editor shows the key hint instead.
    private var needsKeyForDiscovery: Bool {
        guard let url = URL(string: draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host?.isEmpty == false else { return false }
        let preset = ProviderPreset.preset(for: .custom, baseURL: url)
        return preset.supportsModelDiscovery && preset.authStyle != .none
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
        workspace.requestModelDiscovery(endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                                        apiKey: draft.key, debounce: true)
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
        }
        workspace.requestModelDiscovery(endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                                        apiKey: draft.key, debounce: false)
    }

    /// Single record-activation path for every selection change (list
    /// selection, Add, initial appear): cancels the old listing generation,
    /// loads the record or a fresh draft and schedules one debounced
    /// listing. It never touches the key.
    private func activateCurrentSelection() {
        workspace.cancelModelDiscovery()
        draft = selectedRecord.map(MacProviderDraft.init) ?? MacProviderDraft()
        scheduleDiscovery()
    }

    // MARK: - Actions

    private func beginInitialEditing() {
        editingID = workspace.providers.first?.profile.id
    }

    private func beginEditing(_ record: HostAgentProvider) {
        editingID = record.profile.id
    }

    private func beginAdding() {
        editingID = nil
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? nil : name
        let presetID = draft.presetID?.rawValue
        let saved: Bool
        if let editingID {
            saved = workspace.updateProvider(id: editingID, name: displayName,
                                             endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                                             modelID: draft.modelID, key: draft.key,
                                             supportsImages: draft.supportsImages, supportsTools: draft.supportsTools,
                                             presetID: presetID)
        } else {
            saved = workspace.addProvider(name: displayName,
                                          endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                                          modelID: draft.modelID, key: draft.key,
                                          supportsImages: draft.supportsImages, supportsTools: draft.supportsTools,
                                          presetID: presetID)
        }
        if saved { isPresented = false }
    }
}

// MARK: - Draft

private struct MacProviderDraft {
    var name: String
    var presetID: ProviderTemplateID?
    var endpoint: String
    var protocolKind: ModelProtocol
    var modelID: String
    var key: String
    var supportsImages: Bool
    var supportsTools: Bool

    init(name: String = "", endpoint: String = "",
         protocolKind: ModelProtocol = .openAIChatCompletions,
         modelID: String = "", key: String = "", supportsImages: Bool = false, supportsTools: Bool = false,
         presetID: ProviderTemplateID? = .custom) {
        self.name = name
        self.endpoint = endpoint
        self.protocolKind = protocolKind
        self.modelID = modelID
        self.key = key
        self.supportsImages = supportsImages
        self.supportsTools = supportsTools
        self.presetID = presetID
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
                  supportsTools: record.model.capabilities.contains(.tools),
                  presetID: resolved.id)
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
