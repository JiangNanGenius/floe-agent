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

/// Secret-free save-phase diagnostics for the provider editor. Records only
/// the fixed lifecycle stages of a Save tap (button activation → store
/// stages → completion/failure). Never logs the endpoint URL, API key, model
/// names, prompts or request/response bodies.
enum ProviderSavePhaseLogger {
    enum Phase: String {
        case entered
        case setSync = "set_sync"
        case writeSecret = "write_secret"
        case buildProfile = "build_profile"
        case bundleSave = "bundle_save"
        case readback
        case readbackFailed = "readback_failed"
        case completed
        case failed
    }

    static func log(_ phase: Phase) {
        FloeLogger(category: .providerSave).info("provider save phase \(phase.rawValue)")
    }
}

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
    /// Provider-level routing switch. Disabled providers stay editable in
    /// Settings but disappear from every runtime model picker.
    @Published var enabled = true
    /// Discovered, existing and manually added candidates. Only IDs in
    /// selectedModelIDs are persisted by this editing session.
    @Published var candidateModels: [ModelProfile] = []
    @Published var selectedModelIDs: Set<UUID> = []
    @Published var defaultModelID: UUID?
    /// Stable provider-catalog identity for profiles created from the
    /// catalog. Nil for manual/legacy providers, which persist no presetID.
    @Published private(set) var catalogPresetID: String?

    // MARK: - Status

    @Published private(set) var testState: ConnectionTestState = .idle
    @Published private(set) var secretStatus: SyncStatus = .synced
    @Published private(set) var isSaving = false
    @Published private(set) var nativeToolStatusByModelID: [UUID: NativeToolCapabilityStatus] = [:]
    @Published var errorMessage: String?
    /// Drives the save-failure alert ONLY. Connection-test and model-discovery
    /// failures keep their own inline context (`errorMessage` / `testState`)
    /// instead of being relabeled as a save failure.
    @Published var saveErrorMessage: String?

    let center: ConversationCenter
    /// The provider being edited, or nil when adding a new one.
    let existing: ProviderProfile?
    let serviceRole: ProviderServiceRole
    private let secretStore = KeychainSecretStore()
    private let adapterFactory = ProviderAdapterFactory()

    /// The provider ID (stable across edit; new when adding).
    let providerID: UUID

    init(
        center: ConversationCenter,
        existing: ProviderProfile?,
        initialRole: ProviderServiceRole? = nil,
        catalogEntry: ProviderCatalogEntry? = nil
    ) {
        self.center = center
        self.existing = existing
        let existingModels = existing.flatMap { center.configuredModelsByProvider[$0.id] } ?? []
        self.serviceRole = initialRole ?? ProviderServiceRole.infer(from: existingModels)
        if let existing {
            self.providerID = existing.id
            self.selectedPreset = ProviderPreset.preset(for: existing.kind)
            self.selectedProtocol = existing.wireProtocol
            self.displayName = existing.displayName ?? ProviderPreset.preset(for: existing.kind).displayName
            self.baseURLString = existing.baseURL.absoluteString
            self.allowsPlainHTTP = existing.allowsPlainHTTP
            self.toolNameCompatibility = existing.toolNameCompatibility
            self.enabled = existing.isEnabled
            self.syncEnabled = existing.secretRef?.synchronizable ?? true
            self.nonSecretHeadersText = Self.headersText(from: existing.nonSecretHeaders)
            self.catalogPresetID = existing.presetID
        } else {
            self.providerID = UUID()
            let preset = Self.presets(for: self.serviceRole)[0]
            self.selectedPreset = preset
            self.selectedProtocol = preset.defaultProtocol
            self.displayName = preset.displayName
            self.baseURLString = preset.defaultBaseURL.absoluteString
            self.catalogPresetID = nil
        }
        if existing == nil, let catalogEntry {
            applyCatalogEntry(catalogEntry)
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

    /// Pre-fills the editor from one official-catalog entry. The entry's
    /// kind selects the closest shipped adapter preset; the catalog identity
    /// is remembered so `buildProfile()` persists it as `presetID`.
    func applyCatalogEntry(_ entry: ProviderCatalogEntry) {
        switch entry.kind {
        case .local, .custom:
            selectedPreset = ProviderPreset.all.first { $0.id == .custom } ?? .custom
        default:
            selectedPreset = ProviderPreset.all.first { $0.kind == entry.kind } ?? .custom
        }
        selectedProtocol = entry.defaultProtocol
        displayName = entry.name
        if let baseURL = entry.baseURL {
            baseURLString = baseURL.absoluteString
        }
        // DeepSeek rejects dotted tool names; the catalog flag (or its known
        // preset identity) turns the compatibility rewrite on.
        toolNameCompatibility = entry.toolNameCompatibility || entry.presetID == "deepseek"
        catalogPresetID = entry.presetID
    }

    var availableProtocols: [ModelProtocol] { selectedPreset.supportedProtocols }

    var availablePresets: [ProviderPreset] {
        if existing?.kind == .googleGemini { return [.googleGemini] }
        return Self.presets(for: serviceRole)
    }

    var supportsDiscovery: Bool {
        selectedPreset.supportsModelDiscovery
    }

    var officialMediaPresets: [MediaModelDescriptor] {
        guard serviceRole != .conversation else { return [] }
        let family: MediaProviderFamily?
        switch selectedPreset.kind {
        case .openAI: family = .openAI
        case .googleGemini: family = .googleGemini
        case .volcengineArk: family = .volcengineArk
        case .alibabaStudio: family = .alibabaModelStudio
        case .anthropic, .local, .custom: family = nil
        }
        guard let family else { return [] }
        return OfficialMediaModelCatalog.models(
            provider: family,
            kind: serviceRole == .video ? .video : .image
        )
    }

    /// Loads the current secret-sync state for an existing provider.
    func load() async {
        guard existing != nil else {
            defaultModelID = center.modelPreferences.defaultAgentModelID
            return
        }
        secretStatus = await secretStore.status(for: providerID, hasConfiguration: true)
        let syncAvailable = await secretStore.isSyncEnabled(for: providerID)
        // A restored profile can arrive before device-local opt-out defaults.
        // Never turn its explicit local-only credential into a synced one just
        // because the user reopens and saves the provider editor.
        syncEnabled = (existing?.secretRef?.synchronizable ?? true) && syncAvailable
        let existingModels = center.configuredModelsByProvider[providerID] ?? []
        candidateModels = existingModels.filter { model in
            switch serviceRole {
            case .conversation:
                model.supportsChatAgentSurface
            case .image:
                model.supportsImageGenerationSurface
            case .video:
                model.supportsVideoGenerationSurface
            }
        }
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
            presetID: existing?.presetID ?? catalogPresetID,
            secretRef: secretRef,
            nonSecretHeaders: Self.parseHeaders(nonSecretHeadersText),
            isEnabled: enabled,
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
            return FloeL10n.l("providers.provider_editor_view_model.api_key_not_saved_yet")
        }
        var results: [String] = []
        for sync in [secretRef.synchronizable, !secretRef.synchronizable] {
            let store = KeychainStore(
                service: "org.floeagent.ios.secrets",
                synchronizable: sync
            )
            if let data = try? store.read(account: secretRef.keychainAccount) {
                let namespace = sync ? "iCloud" : FloeL10n.l("providers.provider_editor_view_model.local")
                results.append(FloeL10n.l("providers.provider_editor_view_model.keychain_key_found_bytes", namespace, data.count))
            } else {
                let namespace = sync ? "iCloud" : FloeL10n.l("providers.provider_editor_view_model.local")
                results.append(FloeL10n.l("providers.provider_editor_view_model.keychain_not_found", namespace))
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
                reason: FloeL10n.l("providers.provider_editor_view_model.show_the_model_service_api_key")
            ) else { return }
        } catch {
            errorMessage = FloeL10n.l("providers.provider_editor_view_model.device_owner_verification_failed")
            return
        }
        if !apiKey.isEmpty {
            showingAPIKey = true
            return
        }
        guard let existing, let secretRef = existing.secretRef else {
            errorMessage = FloeL10n.l("providers.provider_editor_view_model.api_key_not_configured")
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
        errorMessage = FloeL10n.l("providers.provider_editor_view_model.no_api_key_found_in_keychain")
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
        if serviceRole == .conversation {
            normalized.capabilities.insert(.text)
            normalized.useSurfaces = normalized.effectiveUseSurfaces.union(.chatAgent)
        } else {
            normalized.capabilities.remove(.text)
            normalized.capabilities.remove(.tools)
            normalized.capabilities.remove(.approval)
            normalized.isHiddenFromPrimaryPicker = true
            normalized.useSurfaces = serviceRole.defaultUseSurfaces
        }
        candidateModels[index] = normalized
        nativeToolStatusByModelID[normalized.id] = NativeToolCapabilityProbe.initialStatus(for: normalized)
    }

    func setModelEnabled(_ id: UUID, isEnabled: Bool) {
        guard let index = candidateModels.firstIndex(where: { $0.id == id }) else { return }
        candidateModels[index].isEnabled = isEnabled
    }

    func setModelHiddenFromPrimaryPicker(_ id: UUID, isHidden: Bool) {
        guard let index = candidateModels.firstIndex(where: { $0.id == id }) else { return }
        candidateModels[index].isHiddenFromPrimaryPicker = isHidden
        if isHidden, defaultModelID == id { defaultModelID = nil }
    }

    func setDefaultModel(_ id: UUID) {
        guard selectedModelIDs.contains(id) else { return }
        defaultModelID = id
    }

    private func mergeDiscovered(_ discovered: [ModelProfile]) {
        let normalized = discovered.map { discoveredModel in
            var model = discoveredModel
            if serviceRole != .conversation {
                model.capabilities = serviceRole.defaultCapabilities
                model.isHiddenFromPrimaryPicker = true
                model.useSurfaces = serviceRole.defaultUseSurfaces
            } else if model.useSurfaces == nil {
                model.useSurfaces = serviceRole.defaultUseSurfaces
            }
            return model
        }
        candidateModels = ModelCatalogMerger.merge(existing: candidateModels, discovered: normalized)
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
            capabilities: serviceRole == .conversation
                ? ModelCapabilities.defaultTextModel(for: selectedProtocol)
                : serviceRole.defaultCapabilities,
            useSurfaces: serviceRole.defaultUseSurfaces,
            isHiddenFromPrimaryPicker: serviceRole == .conversation ? false : true
        )
        candidateModels.append(model)
        nativeToolStatusByModelID[model.id] = NativeToolCapabilityProbe.initialStatus(for: model)
        selectedModelIDs.insert(model.id)
    }

    func addOfficialMediaPreset(_ descriptor: MediaModelDescriptor) {
        if let existing = candidateModels.first(where: { $0.remoteModelID == descriptor.remoteModelID }) {
            selectedModelIDs.insert(existing.id)
            return
        }
        addManualModel(remoteID: descriptor.remoteModelID, displayName: descriptor.displayName)
    }

    private static func presets(for role: ProviderServiceRole) -> [ProviderPreset] {
        switch role {
        case .conversation:
            ProviderPreset.chatPresets
        case .image:
            [.openAIResponses, .volcengineArk, .alibabaStudio, .googleGemini, .custom]
        case .video:
            [.volcengineArk, .alibabaStudio, .googleGemini, .custom]
        }
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
        // Reentrancy guard: a second Save (double tap / repeated presses
        // during an in-flight write) must never run a second bundle save.
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        saveErrorMessage = nil
        ProviderSavePhaseLogger.log(.entered)
        do {
            ProviderSavePhaseLogger.log(.setSync)
            try await secretStore.setSyncEnabled(syncEnabled, for: providerID)
            ProviderSavePhaseLogger.log(.writeSecret)
            try await persistSecretIfNeeded()
            ProviderSavePhaseLogger.log(.buildProfile)
            let profile = try buildProfile()
            ProviderSavePhaseLogger.log(.bundleSave)
            let saved = try await center.saveProviderBundle(
                provider: profile,
                models: selectedModels,
                managedCapabilities: serviceRole.managedCapabilities
            )
            ProviderSavePhaseLogger.log(.readback)
            // Persisted readback BEFORE reporting success: re-read the provider
            // and selected models from the store and fail visibly if the bytes
            // on disk do not match what the user just entered.
            if let reason = await center.verifyProviderPersisted(
                provider: profile, selectedModels: selectedModels) {
                ProviderSavePhaseLogger.log(.readbackFailed)
                throw FloeError.invalidConfiguration(reason)
            }
            ProviderSavePhaseLogger.log(.completed)
            // Auxiliary-model routing is owned by AuxiliaryModelsView. Saving
            // an image/video provider must not rewrite the conversation-model
            // preference and create a cross-device last-writer-wins conflict.
            if serviceRole == .conversation {
                var preferences = center.modelPreferences
                if let chosen = defaultModelID,
                   enabled,
                   let staged = selectedModels.first(where: {
                       $0.id == chosen && $0.isEnabled && $0.isVisibleInPrimaryPicker
                   }),
                   let canonical = saved.first(where: {
                       $0.remoteModelID == staged.remoteModelID
                           && $0.isEnabled
                           && $0.isVisibleInPrimaryPicker
                   }) {
                    preferences.defaultAgentModelID = canonical.id
                } else if preferences.defaultAgentModelID == nil,
                          let first = center.availableAgentModels.first {
                    preferences.defaultAgentModelID = first.id
                } else if let current = preferences.defaultAgentModelID,
                          !center.availableAgentModels.contains(where: { $0.id == current }) {
                    preferences.defaultAgentModelID = center.availableAgentModels.first?.id
                }
                if preferences.defaultAgentModelID != nil {
                    preferences.onboardingStatus = .completed
                }
                try await center.saveModelPreferences(preferences)
            }
            return true
        } catch {
            ProviderSavePhaseLogger.log(.failed)
            let message = SecretRedactor.redact(error.localizedDescription)
            errorMessage = message
            saveErrorMessage = message
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
