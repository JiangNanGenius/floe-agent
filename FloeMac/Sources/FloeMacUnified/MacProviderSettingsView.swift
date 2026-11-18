// SPDX-License-Identifier: MPL-2.0

import FloeCore
import SwiftUI

/// Provider management for the unified Mac workspace: lists the saved
/// providers, edits or removes them, and chooses which one chat uses.
/// All records live in the existing device-bound chat Keychain namespace;
/// failures surface as the workspace's existing local notices.
struct MacProviderSettingsView: View {
    @ObservedObject var workspace: HostAgentWorkspace
    @Binding var isPresented: Bool

    @State private var editingID: UUID?
    @State private var draft = MacProviderDraft()
    @State private var removalCandidate: UUID?

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
        .frame(width: 720, height: 430)
        .onAppear(perform: beginInitialEditing)
        .onChange(of: editingID) { _, newID in
            guard newID != nil, let record = selectedRecord else { return }
            draft = MacProviderDraft(record: record)
        }
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
                TextField(MacProviderText.t("名称（可选）", "Name (optional)"), text: $draft.name)
                TextField(MacProviderText.t("API 基础地址", "API base URL"), text: $draft.endpoint)
                    .textContentType(.URL)
                Picker(MacProviderText.t("协议", "Protocol"), selection: $draft.protocolKind) {
                    Text("OpenAI Chat Completions").tag(ModelProtocol.openAIChatCompletions)
                    Text("OpenAI Responses").tag(ModelProtocol.openAIResponses)
                    Text("Anthropic Messages").tag(ModelProtocol.anthropicMessages)
                }
                TextField(MacProviderText.t("模型 ID", "Model ID"), text: $draft.modelID)
                SecureField(MacProviderText.t("API 密钥", "API key"), text: $draft.key)
                Text(MacProviderText.t(
                    "密钥只保存在本机钥匙串，不会同步到其他设备。",
                    "The key stays in this Mac's Keychain and never syncs to other devices."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    // MARK: - Actions

    private func beginInitialEditing() {
        if let first = workspace.providers.first {
            beginEditing(first)
        } else {
            beginAdding()
        }
    }

    private func beginEditing(_ record: HostAgentProvider) {
        editingID = record.profile.id
        draft = MacProviderDraft(record: record)
    }

    private func beginAdding() {
        editingID = nil
        draft = MacProviderDraft()
    }

    private func save() {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.isEmpty ? nil : name
        let saved: Bool
        if let editingID {
            saved = workspace.updateProvider(id: editingID, name: displayName,
                                             endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                                             modelID: draft.modelID, key: draft.key)
        } else {
            saved = workspace.addProvider(name: displayName,
                                          endpoint: draft.endpoint, protocolKind: draft.protocolKind,
                                          modelID: draft.modelID, key: draft.key)
        }
        if saved { isPresented = false }
    }
}

// MARK: - Draft

private struct MacProviderDraft {
    var name: String
    var endpoint: String
    var protocolKind: ModelProtocol
    var modelID: String
    var key: String

    init(name: String = "", endpoint: String = "",
         protocolKind: ModelProtocol = .openAIChatCompletions,
         modelID: String = "", key: String = "") {
        self.name = name
        self.endpoint = endpoint
        self.protocolKind = protocolKind
        self.modelID = modelID
        self.key = key
    }

    init(record: HostAgentProvider) {
        self.init(name: record.profile.displayName ?? "",
                  endpoint: record.profile.baseURL.absoluteString,
                  protocolKind: record.profile.wireProtocol,
                  modelID: record.model.remoteModelID,
                  key: record.apiKey)
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
