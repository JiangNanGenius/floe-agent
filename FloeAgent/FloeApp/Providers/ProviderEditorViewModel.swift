// FloeApp — Provider editor view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Drives the provider editor: preset pre-fill, wire protocol/base URL/API
// key, non-secret headers, capability flags, Test connection (committed
// testConnection + ModelDiscovery), manual-model fallback and the iCloud
// Keychain sync toggle. The API key goes straight to Keychain via
// KeychainSecretStore; only a SecretReference is persisted.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeProviders
import FloeSync
import FloeSyncCore

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
    @Published var baseURLString: String
    @Published var apiKey: String = ""
    @Published var nonSecretHeadersText: String = ""
    @Published var allowsPlainHTTP = false
    @Published var syncEnabled = true
    /// Manually-added models (fallback when discovery is unsupported).
    @Published var manualModels: [ModelProfile] = []
    /// Models discovered via Test connection (not yet saved).
    @Published var discoveredModels: [ModelProfile] = []

    // MARK: - Status

    @Published private(set) var testState: ConnectionTestState = .idle
    @Published private(set) var secretStatus: SyncStatus = .synced
    @Published private(set) var isSaving = false
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
            self.baseURLString = existing.baseURL.absoluteString
            self.allowsPlainHTTP = existing.allowsPlainHTTP
            self.nonSecretHeadersText = Self.headersText(from: existing.nonSecretHeaders)
        } else {
            self.providerID = UUID()
            self.selectedPreset = ProviderPreset.all[0]
            self.baseURLString = ProviderPreset.all[0].defaultBaseURL.absoluteString
        }
    }

    /// Applies a preset's defaults to the editable fields.
    func applyPreset(_ preset: ProviderPreset) {
        selectedPreset = preset
        baseURLString = preset.defaultBaseURL.absoluteString
    }

    var supportsDiscovery: Bool {
        selectedPreset.supportsModelDiscovery
    }

    /// Loads the current secret-sync state for an existing provider.
    func load() async {
        guard existing != nil else { return }
        secretStatus = await secretStore.status(for: providerID, hasConfiguration: true)
        syncEnabled = await secretStore.isSyncEnabled(for: providerID)
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
        let profile = ProviderProfile(
            id: providerID,
            kind: selectedPreset.kind,
            wireProtocol: selectedPreset.wireProtocol,
            baseURL: url,
            secretRef: secretRef,
            nonSecretHeaders: Self.parseHeaders(nonSecretHeadersText),
            isEnabled: true,
            allowsPlainHTTP: allowsPlainHTTP,
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
        testState = .testing
        errorMessage = nil
        do {
            let profile = try buildProfile()
            let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let credentials = enteredKey.isEmpty
                ? resolveCredentials(profile)
                : ProviderCredentials(apiKey: enteredKey)
            let adapter = adapterFactory.adapter(for: profile)
            try await adapter.testConnection(provider: profile, credentials: credentials)
            if supportsDiscovery {
                let models = try await adapter.listModels(
                    provider: profile,
                    credentials: credentials
                )
                discoveredModels = models
                testState = .succeeded(modelCount: models.count)
            } else {
                testState = .succeeded(modelCount: 0)
            }
        } catch {
            testState = .failed(SecretRedactor.redact(error.localizedDescription))
        }
    }

    // MARK: - Models

    /// Adds a manual model entry (fallback when discovery is unsupported).
    func addManualModel(remoteID: String, displayName: String) {
        let trimmed = remoteID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let model = ModelProfile(
            providerID: providerID,
            remoteModelID: trimmed,
            displayName: displayName.isEmpty ? trimmed : displayName,
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: [.text, .tools]
        )
        manualModels.append(model)
    }

    func removeManualModel(id: UUID) {
        manualModels.removeAll { $0.id == id }
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
            try await center.saveProvider(profile)
            for model in discoveredModels + manualModels {
                try await center.saveModel(model)
            }
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

    private func resolveCredentials(_ profile: ProviderProfile) -> ProviderCredentials {
        center.resolveCredentials(for: profile)
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
