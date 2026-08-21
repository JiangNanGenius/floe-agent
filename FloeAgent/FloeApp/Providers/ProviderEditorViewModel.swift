// FloeApp — Provider editor view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Drives the provider editor: preset pre-fill, wire protocol/base URL/API
// key, non-secret headers, capability flags, Test connection (committed
// testConnection + ModelDiscovery), manual-model fallback and the iCloud
// Keychain sync toggle. The API key stays in memory while testing and is
// written to Keychain only when the user saves; only a SecretReference is
// persisted in SQLite/CloudKit.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import LocalAuthentication
import FloeCore
import FloeProviders
import FloeSync
import FloeSyncCore
import FloeSecurity

/// View model for adding or editing one provider.
@MainActor
final class ProviderEditorViewModel: ObservableObject {

    enum ConnectionTestState: Equatable {
        case idle
        case testing
        case succeeded(modelCount: Int)
        case failed(String)
    }

    // MARK: - Editable fields

    @Published var selectedPreset: ProviderPreset
    @Published var selectedProtocol: ModelProtocol
    /// User-facing provider name (editable; falls back to the preset label).
    @Published var displayName: String
    @Published var baseURLString: String
    @Published var apiKey: String = ""
    /// Whether the API key field is currently revealed (plain text). Toggled
    /// by the eye button; revealing reads from Keychain and shows the stored
    /// key so the user can verify what's actually saved.
    @Published var showingAPIKey = false
    @Published var nonSecretHeadersText: String = ""
    @Published var allowsPlainHTTP = false
    @Published var syncEnabled = true
    /// When true, tool names sent to this provider have dots replaced with
    /// underscores (e.g. `workspace.createFile` → `workspace_createFile`).
    /// Needed for providers like DeepSeek that enforce `^[a-zA-Z0-9_-]+$`.
    @Published var toolNameCompatibility = false
    /// Discovered, existing and manually added candidates. Only IDs in
    /// selectedModelIDs are persisted by this editing session.
    @Published var candidateModels: [ModelProfile] = []
    @Published var selectedModelIDs: Set<UUID> = []
    @Published var defaultModelID: UUID?

    // MARK: - Status

    @Published private(set) var testState: ConnectionTestState = .idle
    @Published private(set) var secretStatus: SyncStatus = .synced
    @Published private(set) var isSaving = false
    @Published private(set) var nativeToolStatusByModelID: [UUID: NativeToolCapabilityStatus] = [:]
    @Published var errorMessage: String?

    let center: ConversationCenter
    /// The provider being edited, or nil when adding a new one.
    let existing: ProviderProfile?
    private let secretStore = KeychainSecretStore()
    private let adapterFactory = ProviderAdapterFactory()

    /// The provider ID (stable across edit; new when adding).
    let providerID: UUID

    init(center: ConversationCenter, existing: ProviderProfile?) {
        self.center = center
        self.existing = existing
        if let existing {
            self.providerID = existing.id
            self.selectedPreset = ProviderPreset.preset(for: existing.kind)
            self.selectedProtocol = existing.wireProtocol
            self.displayName = existing.displayName ?? ProviderPreset.preset(for: existing.kind).displayName
            self.baseURLString = existing.baseURL.absoluteString
            self.allowsPlainHTTP = existing.allowsPlainHTTP
            self.toolNameCompatibility = existing.toolNameCompatibility
            self.nonSecretHeadersText = Self.headersText(from: existing.nonSecretHeaders)
        } else {
            self.providerID = UUID()
            self.selectedPreset = ProviderPreset.all[0]
            self.selectedProtocol = ProviderPreset.all[0].defaultProtocol
            self.displayName = ProviderPreset.all[0].displayName
            self.baseURLString = ProviderPreset.all[0].defaultBaseURL.absoluteString
        }
    }

    /// Applies a preset's defaults to the editable fields.
    func applyPreset(_ preset: ProviderPreset) {
        let previousPresetName = selectedPreset.displayName
        let shouldReplaceDisplayName = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || displayName == previousPresetName
        selectedPreset = preset
        // Only auto-fill the name when the user hasn't customized it, so a
        // typed "DeepSeek" survives switching protocols/presets.
        if shouldReplaceDisplayName {
            displayName = preset.displayName
        }
        baseURLString = preset.defaultBaseURL.absoluteString
        selectedProtocol = preset.defaultProtocol
    }

    var availableProtocols: [ModelProtocol] { selectedPreset.supportedProtocols }

    var supportsDiscovery: Bool {
        selectedPreset.supportsModelDiscovery
    }

    /// Loads the current secret-sync state for an existing provider.
    func load() async {
        guard existing != nil else {
            defaultModelID = center.modelPreferences.defaultAgentModelID
            return
        }
        secretStatus = await secretStore.status(for: providerID, hasConfiguration: true)
        syncEnabled = await secretStore.isSyncEnabled(for: providerID)
        let existingModels = center.modelsByProvider[providerID] ?? []
        candidateModels = existingModels.filter { $0.capabilities.contains(.text) }
        nativeToolStatusByModelID = Dictionary(uniqueKeysWithValues: candidateModels.map {
            ($0.id, NativeToolCapabilityProbe.initialStatus(for: $0))
        })
        selectedModelIDs = Set(candidateModels.map(\.id))
        defaultModelID = center.modelPreferences.defaultAgentModelID
    }

    // MARK: - Build profile

    /// Builds a ProviderProfile from the editable fields. Never embeds the
    /// API key — only a SecretReference to its Keychain account.
    func buildProfile() throws -> ProviderProfile {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw FloeError.invalidConfiguration("Invalid base URL")
        }
        let hasKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || existing?.secretRef != nil
        let secretRef = hasKey ? SecretReference(
            keychainAccount: existing?.secretRef?.keychainAccount
                ?? "provider.\(providerID.uuidString)",
            synchronizable: syncEnabled
        ) : nil
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ProviderProfile(
            id: providerID,
            kind: selectedPreset.kind,
            wireProtocol: selectedProtocol,
            baseURL: url,
            displayName: trimmedName.isEmpty ? nil : trimmedName,
            secretRef: secretRef,
            nonSecretHeaders: Self.parseHeaders(nonSecretHeadersText),
            isEnabled: true,
            allowsPlainHTTP: allowsPlainHTTP,
            toolNameCompatibility: toolNameCompatibility,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date(),
            syncRevision: (existing?.syncRevision ?? 0)
        )
        try profile.validate()
        return profile
    }

    // MARK: - Test connection

    /// Runs the committed connection test: adapter.testConnection plus
    /// model discovery when supported. On failure the manual-model
    /// fallback remains available.
    func testConnection() async {
        await discoverModels(testConnectivity: true)
    }

    /// Re-fetches the provider's model catalog from the normal settings flow.
    /// Existing credentials are resolved from Keychain when the key field is
    /// intentionally left blank while editing.
    func refreshModels() async {
        await discoverModels(testConnectivity: true)
    }

    private func discoverModels(testConnectivity: Bool) async {
        testState = .testing
        errorMessage = nil
        do {
            let profile = try buildProfile()
            let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let credentials: ProviderCredentials
            if !enteredKey.isEmpty {
                credentials = ProviderCredentials(apiKey: enteredKey)
            } else {
                // Use the same Keychain resolution as ConversationCenter so
                // the editor and runtime agree on which namespace to read.
                credentials = center.resolveCredentials(for: profile)
            }
            let adapter = adapterFactory.adapter(for: profile)
            if testConnectivity {
                try await adapter.testConnection(provider: profile, credentials: credentials)
            }
            if supportsDiscovery {
                let models = try await adapter.listModels(
                    provider: profile,
                    credentials: credentials
                )
                mergeDiscovered(models)
                testState = .succeeded(modelCount: models.count)
            } else {
                testState = .succeeded(modelCount: 0)
            }
        } catch {
            let message = SecretRedactor.redact(error.localizedDescription)
            testState = .failed(message)
            errorMessage = message
        }
    }

    /// Diagnostic: reads the provider's Keychain entry directly and reports
    /// whether a key was found (and in which namespace). This helps debug
    /// "provider unavailable" issues without exposing the key itself.
    func diagnoseKeychain() -> String {
        guard let existing, let secretRef = existing.secretRef else {
            return "未配置 API key（secretRef 为空）"
        }
        var results: [String] = []
        for sync in [secretRef.synchronizable, !secretRef.synchronizable] {
            let store = KeychainStore(
                service: "org.floeagent.ios.secrets",
                synchronizable: sync
            )
            if let data = try? store.read(account: secretRef.keychainAccount) {
                let namespace = sync ? "iCloud" : "本地"
                results.append("\(namespace) Keychain: 找到 key（\(data.count) 字节）")
            } else {
                let namespace = sync ? "iCloud" : "本地"
                results.append("\(namespace) Keychain: 未找到")
            }
        }
        return results.joined(separator: "\n")
    }

    /// Reveals either the newly typed or stored API key only after explicit
    /// device-owner authentication. Keychain storage alone does not imply an
    /// authentication prompt, so the editor enforces it at the reveal action.
    func authenticateAndRevealAPIKey() async {
        do {
            guard try await DeviceOwnerAuthenticator.authenticate(
                reason: "验证身份后显示模型服务 API key"
            ) else { return }
        } catch {
            errorMessage = "未通过设备所有者验证"
            return
        }
        if !apiKey.isEmpty {
            showingAPIKey = true
            return
        }
        guard let existing, let secretRef = existing.secretRef else {
            errorMessage = "未配置 API key"
            return
        }
        // Try both namespaces; the first hit wins.
        for sync in [secretRef.synchronizable, !secretRef.synchronizable] {
            let store = KeychainStore(
                service: "org.floeagent.ios.secrets",
                synchronizable: sync
            )
            if let data = try? store.read(account: secretRef.keychainAccount),
               let key = String(data: data, encoding: .utf8) {
                apiKey = key
                showingAPIKey = true
                errorMessage = nil
                return
            }
        }
        errorMessage = "Keychain 中没有找到 API key"
    }

    // MARK: - Models

    var selectedModels: [ModelProfile] {
        candidateModels.filter { selectedModelIDs.contains($0.id) }
    }

    func toggleSelection(_ id: UUID) {
        if selectedModelIDs.contains(id) {
            selectedModelIDs.remove(id)
            if defaultModelID == id { defaultModelID = nil }
        } else {
            selectedModelIDs.insert(id)
        }
    }

    /// Sets selection idempotently. This is used by the model picker's
    /// native Toggle rows so touch, keyboard and VoiceOver activation all
    /// update the same source of truth without relying on a nested List
    /// button gesture.
    func setSelection(_ id: UUID, isSelected: Bool) {
        if isSelected {
            selectedModelIDs.insert(id)
        } else {
            selectedModelIDs.remove(id)
            if defaultModelID == id { defaultModelID = nil }
        }
    }

    func updateModel(_ model: ModelProfile) {
        guard let index = candidateModels.firstIndex(where: { $0.id == model.id }) else { return }
        var normalized = model
        normalized.capabilities.insert(.text)
        candidateModels[index] = normalized
        nativeToolStatusByModelID[normalized.id] = NativeToolCapabilityProbe.initialStatus(for: normalized)
    }

    func setDefaultModel(_ id: UUID) {
        guard selectedModelIDs.contains(id) else { return }
        defaultModelID = id
    }

    private func mergeDiscovered(_ discovered: [ModelProfile]) {
        candidateModels = ModelCatalogMerger.merge(existing: candidateModels, discovered: discovered)
        for model in candidateModels where nativeToolStatusByModelID[model.id] != .verified {
            nativeToolStatusByModelID[model.id] = NativeToolCapabilityProbe.initialStatus(for: model)
        }
    }

    /// Adds a manual model entry (fallback when discovery is unsupported).
    func addManualModel(remoteID: String, displayName: String) {
        let trimmed = remoteID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let model = ModelProfile(
            providerID: providerID,
            remoteModelID: trimmed,
            displayName: displayName.isEmpty ? trimmed : displayName,
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: ModelCapabilities.defaultTextModel(for: selectedProtocol)
        )
        candidateModels.append(model)
        nativeToolStatusByModelID[model.id] = NativeToolCapabilityProbe.initialStatus(for: model)
        selectedModelIDs.insert(model.id)
    }

    /// Runs an explicit, inert native-tool round trip for one candidate model.
    /// This is intentionally opt-in because it consumes a small model request.
    func probeNativeTools(for modelID: UUID) async {
        guard let model = candidateModels.first(where: { $0.id == modelID }) else { return }
        nativeToolStatusByModelID[modelID] = .probing
        do {
            let profile = try buildProfile()
            let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let credentials: ProviderCredentials
            if !enteredKey.isEmpty {
                credentials = ProviderCredentials(apiKey: enteredKey)
            } else if profile.secretRef != nil {
                let secret = try await secretStore.readSecret(scope: .provider(providerID))
                credentials = ProviderCredentials(apiKey: String(data: secret, encoding: .utf8))
            } else {
                credentials = ProviderCredentials()
            }
            nativeToolStatusByModelID[modelID] = await NativeToolCapabilityProbe.run(
                adapter: adapterFactory.adapter(for: profile),
                provider: profile,
                model: model,
                credentials: credentials
            )
        } catch {
            nativeToolStatusByModelID[modelID] = .failed(SecretRedactor.redact(error.localizedDescription))
        }
    }

    func removeManualModel(id: UUID) {
        candidateModels.removeAll { $0.id == id }
        nativeToolStatusByModelID.removeValue(forKey: id)
        selectedModelIDs.remove(id)
        if defaultModelID == id { defaultModelID = nil }
    }

    // MARK: - Save

    /// Persists the secret (Keychain), provider profile and models, and
    /// applies the iCloud Keychain sync preference.
    @discardableResult
    func save() async -> Bool {
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            try await secretStore.setSyncEnabled(syncEnabled, for: providerID)
            try await persistSecretIfNeeded()
            let profile = try buildProfile()
            let saved = try await center.saveProviderBundle(
                provider: profile,
                models: selectedModels
            )
            var preferences = center.modelPreferences
            if let chosen = defaultModelID,
               let staged = selectedModels.first(where: { $0.id == chosen }),
               let canonical = saved.first(where: { $0.remoteModelID == staged.remoteModelID }) {
                preferences.defaultAgentModelID = canonical.id
            } else if preferences.defaultAgentModelID == nil,
                      let first = saved.first(where: { $0.capabilities.contains(.text) }) {
                preferences.defaultAgentModelID = first.id
            }
            if preferences.defaultAgentModelID != nil {
                preferences.onboardingStatus = .completed
            }
            try await center.saveModelPreferences(preferences)
            return true
        } catch {
            errorMessage = SecretRedactor.redact(error.localizedDescription)
            return false
        }
    }

    // MARK: - Secret handling

    /// Writes the API key to Keychain when the user entered one. The key
    /// never touches the database or any persisted UI state.
    private func persistSecretIfNeeded() async throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let data = key.data(using: .utf8) else { return }
        try await secretStore.storeSecret(data, scope: .provider(providerID))
    }

    // MARK: - Header parsing

    private static func parseHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { headers[key] = value }
        }
        return headers
    }

    private static func headersText(from headers: [String: String]) -> String {
        headers.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }
}
#endif
