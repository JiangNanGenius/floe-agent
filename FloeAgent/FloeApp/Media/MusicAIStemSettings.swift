// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeMedia
import FloeSecurity

/// User configuration for the Music.AI stem route. Credentials live ONLY in
/// the existing approved Keychain store (the same `KeychainStore` pattern as
/// the cloud-ASR profiles); nothing here reads or writes language-model
/// credentials, and no developer subscription/smoke test gates the user.
/// The API key value never enters UserDefaults, logs, prompts or Git.
@MainActor final class MusicAIStemSettingsStore: ObservableObject {
    static let shared = MusicAIStemSettingsStore()
    static let defaultsKey = "music-ai.stem-separation.v1"
    static let keychainService = "org.floeagent.ios.music-ai-stem"
    static let credentialAccount = "api.key"
    struct PersistedState: Codable, Equatable {
        var schemaVersion = 1
        var enabled = false
        var customBaseURL: String?
        var workflow: String?
    }
    @Published private(set) var enabled: Bool
    @Published private(set) var customBaseURL: String?
    @Published private(set) var workflow: String?
    @Published private(set) var hasCredential = false
    private let defaults: UserDefaults
    private let keychain: any KeychainProbeStore
    private var persisted: PersistedState
    /// Sendable handle so the API credential closure can read the approved
    /// Keychain without capturing this MainActor model object.
    var credentialStore: any KeychainProbeStore { keychain }
    static var credentialAccountName: String { credentialAccount }

    init(defaults: UserDefaults = .standard, keychain: any KeychainProbeStore = KeychainStore(
        service: MusicAIStemSettingsStore.keychainService, synchronizable: false)) {
        self.defaults = defaults; self.keychain = keychain
        let loaded = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(PersistedState.self, from: $0) } ?? PersistedState()
        persisted = loaded
        enabled = loaded.enabled
        customBaseURL = loaded.customBaseURL
        workflow = loaded.workflow
        hasCredential = (try? keychain.read(account: Self.credentialAccount)) != nil
    }
    var configuration: MusicAIStemConfiguration {
        var value = MusicAIStemConfiguration()
        if let customBaseURL, let url = URL(string: customBaseURL), url.scheme?.lowercased() == "https", url.host != nil { value = MusicAIStemConfiguration(baseURL: url) }
        if let workflow, !workflow.isEmpty { value = MusicAIStemConfiguration(baseURL: value.baseURL, workflow: workflow) }
        return value
    }
    /// Ready = explicitly enabled AND a stored key AND a valid bounded
    /// configuration. Never probes the provider to answer.
    var isReady: Bool {
        enabled && hasCredential && (try? configuration.validate()) != nil
    }
    func setEnabled(_ value: Bool) {
        enabled = value; persisted.enabled = value; persist()
    }
    func setBaseURL(_ raw: String?) throws {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, trimmed.utf8.count <= 2_048 else {
                throw FloeError.validationFailed("Use a bounded https Music.AI endpoint without credentials in the URL")
            }
            customBaseURL = trimmed; persisted.customBaseURL = trimmed
        } else { customBaseURL = nil; persisted.customBaseURL = nil }
        persist()
    }
    func setWorkflow(_ raw: String?) throws {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            guard trimmed.utf8.count <= 256, !trimmed.unicodeScalars.contains(where: { $0.value < 32 }) else {
                throw FloeError.validationFailed("The workflow name is not a bounded single line")
            }
            workflow = trimmed; persisted.workflow = trimmed
        } else { workflow = nil; persisted.workflow = nil }
        persist()
    }
    func setCredential(_ value: String?) throws {
        guard let value else {
            try keychain.delete(account: Self.credentialAccount); hasCredential = false; return
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 16_384,
              !trimmed.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw FloeError.validationFailed("The API key is empty or contains control characters")
        }
        try keychain.store(account: Self.credentialAccount, secret: Data(trimmed.utf8))
        hasCredential = true
    }
    /// The bounded API-key value for one call path. Callers must never log,
    /// persist or display the returned string.
    func currentCredential() -> String? {
        guard let data = try? keychain.read(account: Self.credentialAccount),
              let value = String(data: data, encoding: .utf8), !value.isEmpty, value.utf8.count <= 16_384 else { return nil }
        return value
    }
    private func persist() {
        persisted.schemaVersion = 1
        guard let data = try? JSONEncoder().encode(persisted) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Compact native configuration sheet opened from the voice-separation
/// inspector and the media AI services settings list.
struct MusicAIStemSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings: MusicAIStemSettingsStore
    init(settings: MusicAIStemSettingsStore = MusicAIStemSettingsStore.shared) { self.settings = settings }
    @State private var keyDraft = ""
    @State private var baseURLDraft = ""
    @State private var workflowDraft = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Toggle(WorkbenchText.t("使用 Music.AI 人声分离", "Use Music.AI voice separation"), isOn: Binding(
                    get: { settings.enabled }, set: { settings.setEnabled($0) }))
                    .frame(minHeight: 44)
                Section {
                    SecureField(WorkbenchText.t("API 密钥", "API key"), text: $keyDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(settings.hasCredential ? WorkbenchText.t("更新密钥", "Update key") : WorkbenchText.t("保存密钥", "Save key")) {
                        do { try settings.setCredential(keyDraft); keyDraft = ""; error = nil }
                        catch { self.error = error.localizedDescription }
                    }.frame(minHeight: 44).disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if settings.hasCredential {
                        Button(WorkbenchText.t("删除已保存的密钥", "Delete the saved key"), role: .destructive) {
                            do { try settings.setCredential(nil); error = nil } catch { self.error = error.localizedDescription }
                        }.frame(minHeight: 44)
                    }
                } header: {
                    Text(WorkbenchText.t(settings.hasCredential ? "已配置密钥" : "尚未配置密钥",
                        settings.hasCredential ? "A key is stored" : "No key stored yet"))
                }
                Section {
                    TextField(WorkbenchText.t("接口地址（可留空使用默认）", "Endpoint (empty for the default)"), text: $baseURLDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField(WorkbenchText.t("工作流（可留空使用默认）", "Workflow (empty for the default)"), text: $workflowDraft)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(WorkbenchText.t("保存高级设置", "Save advanced settings")) {
                        do {
                            try settings.setBaseURL(baseURLDraft.isEmpty ? nil : baseURLDraft)
                            try settings.setWorkflow(workflowDraft.isEmpty ? nil : workflowDraft)
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }.frame(minHeight: 44)
                } header: { Text(WorkbenchText.t("高级", "Advanced")) } footer: {
                    Text(WorkbenchText.t("密钥只保存在本机钥匙串。费用与额度由你的 Music.AI 账户决定。",
                        "The key stays in this device's Keychain. Costs follow your own Music.AI account."))
                        .font(.caption)
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }
            .navigationTitle(WorkbenchText.t("Music.AI 人声分离", "Music.AI voice separation"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { dismiss() } } }
            .onAppear {
                baseURLDraft = settings.customBaseURL ?? ""
                workflowDraft = settings.workflow ?? ""
            }
        }
    }
}
#endif
