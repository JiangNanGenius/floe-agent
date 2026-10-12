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
        case preflight = "preflight"
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

/// Which part of the Save lifecycle failed, so the UI can distinguish "nothing
/// was saved" (preflight rejection, zero side effects) from "local save
/// failed" (credential/sync state may already have changed) from "saved
/// locally, CloudKit delivery pending" (the existing sync status surface).
enum ProviderSaveFailurePhase: Equatable {
    /// Form validation rejected the input before ANY side effect. The
    /// keychain, sync preference, database and pending-sync queue are
    /// untouched; the user's input is preserved in the form.
    case preflight
    /// Credential write or sync-preference change ran; the local bundle
    /// commit then failed. Local configuration is unchanged, but the
    /// secret/sync setting may have changed.
    case credentialOrSync
    /// The SQLite bundle write/readback failed.
    case localCommit
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
    /// Field-level findings from the last Save preflight. Cleared on every
    /// Save entry. The form highlights the offending field(s) while the
    /// rejected text stays in the field (no silent truncation, no reset).
    @Published private(set) var fieldIssues: [ProviderConfigurationIssue] = []
    /// Phase of the last save failure, distinguishing a zero-side-effect
    /// preflight rejection from a failure after the credential/sync write.
    @Published private(set) var lastFailurePhase: ProviderSaveFailurePhase?
    /// True when the last save committed locally but CloudKit delivery did
    /// not complete. Local success, not a failure; the UI shows it as
    /// "saved, waiting for iCloud" rather than an error.
    @Published private(set) var lastSaveSyncPending = false
    /// Secret-free sync-pending detail for the last save, when available.
    @Published private(set) var lastSaveSyncError: String?
    /// True while a sync-only retry (no local rewrite) is in flight.
    @Published private(set) var isRetryingSync = false

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

    // MARK: - Build profile / frozen save request

    /// Captures the CURRENT field values synchronously. No suspension points:
    /// the draft is a consistent snapshot even if fields mutate immediately
    /// afterwards. Parsed non-secret headers are included.
    private func makeDraft() -> ProviderSaveDraft {
        ProviderSaveDraft(
            providerID: providerID,
            kind: selectedPreset.kind,
            wireProtocol: selectedProtocol,
            baseURLString: baseURLString,
            displayName: displayName,
            presetID: existing?.presetID ?? catalogPresetID,
            existingSecretRef: existing?.secretRef,
            nonSecretHeaders: Self.parseHeaders(nonSecretHeadersText),
            isEnabled: enabled,
            allowsPlainHTTP: allowsPlainHTTP,
            toolNameCompatibility: toolNameCompatibility,
            syncEnabled: syncEnabled,
            enteredAPIKey: apiKey,
            selectedModels: selectedModels,
            managedCapabilities: serviceRole.managedCapabilities,
            serviceRoleIsConversation: serviceRole == .conversation,
            defaultModelID: defaultModelID,
            existingCreatedAt: existing?.createdAt,
            existingSyncRevision: existing?.syncRevision ?? 0
        )
    }

    /// Freezes and validates the complete save content. The returned request
    /// is the single source of truth for every later side effect (Keychain,
    /// bundle commit, readback, routing). Field edits landing during the
    /// subsequent awaits cannot alter a save that already started.
    func makeSaveRequest() -> Result<ProviderSaveRequest, ProviderConfigurationValidationReport> {
        makeDraft().makeRequest()
    }

    /// Complete preflight: returns all field-level issues found; an empty
    /// array means a save may proceed to side effects. No credential, sync or
    /// database work.
    func preflight() -> [ProviderConfigurationIssue] {
        if case .failure(let report) = makeSaveRequest() { return report.issues }
        return []
    }

    /// Builds a ProviderProfile from the editable fields. Never embeds the
    /// API key — only a SecretReference to its Keychain account. Connection
    /// test and model discovery use this; Save uses `makeSaveRequest()` so its
    /// committed content cannot change during awaits.
    func buildProfile() throws -> ProviderProfile {
        switch makeSaveRequest() {
        case .success(let request):
            return request.profile
        case .failure(let report):
            let message = report.issues
                .map(Self.presentableMessage(for:))
                .joined(separator: "\n")
            throw FloeError.invalidConfiguration(message)
        }
    }

    /// User-facing message for a validation issue. The App catalog key
    /// (`providers.validation.*`) wins when present; otherwise the
    /// bilingual validation-boundary string is used. The rejected input is
    /// never interpolated into this message.
    static func presentableMessage(for issue: ProviderConfigurationIssue) -> String {
        let language = ProviderValidationLanguage.resolve(FloeL10n.currentLanguageCode)
        let resolved = FloeL10n.localized(key: issue.messageKey, arguments: issue.arguments)
        if resolved != issue.messageKey {
            return resolved
        }
        return ProviderConfigurationValidation.message(for: issue, language: language)
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

    /// Adapter that forwards the runner's fixed phases to the secret-free
    /// diagnostics logger.
    private struct SavePhaseReporter: ProviderSavePhaseReporting {
        func providerSaveReachedPhase(_ phase: ProviderSavePhaseEvent) {
            switch phase {
            case .setSync: ProviderSavePhaseLogger.log(.setSync)
            case .writeSecret: ProviderSavePhaseLogger.log(.writeSecret)
            case .bundleSave: ProviderSavePhaseLogger.log(.bundleSave)
            case .readback: ProviderSavePhaseLogger.log(.readback)
            }
        }
    }

    /// Persists the secret (Keychain), provider profile and models, and
    /// applies the iCloud Keychain sync preference.
    ///
    /// Ordering contract: the COMPLETE content is frozen and validated
    /// synchronously first (`makeSaveRequest`). On failure no side effect
    /// happens — no Keychain write, no sync-preference change, no SQLite
    /// write, no pending sync record — and the user's input stays on screen
    /// with field-level findings. The frozen request is the only content used
    /// by the credential write, local bundle commit, readback and routing
    /// update, so edits landing during awaits cannot change what gets saved.
    @discardableResult
    func save() async -> Bool {
        // Reentrancy guard: a second Save (double tap / repeated presses
        // during an in-flight write) must never run a second bundle save.
        guard !isSaving else { return false }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        saveErrorMessage = nil
        fieldIssues = []
        lastFailurePhase = nil
        lastSaveSyncPending = false
        lastSaveSyncError = nil
        ProviderSavePhaseLogger.log(.entered)

        // 1) Freeze + validate synchronously, BEFORE any suspension point or
        // side effect. Field edits after this point cannot affect this save.
        let request: ProviderSaveRequest
        switch makeSaveRequest() {
        case .success(let frozen):
            request = frozen
        case .failure(let report):
            fieldIssues = report.issues
            lastFailurePhase = .preflight
            let message = report.issues
                .map { Self.presentableMessage(for: $0) }
                .joined(separator: "\n")
            ProviderSavePhaseLogger.log(.failed)
            errorMessage = SecretRedactor.redact(message)
            saveErrorMessage = SecretRedactor.redact(message)
            return false
        }

        // 2) Run the frozen request through the ordering-guaranteed runner.
        let runner = ProviderSaveRunner(
            secretStore: KeychainSecretGateway(store: secretStore),
            committer: ConversationCenterProviderSaveGateway(center: center),
            phaseReporter: SavePhaseReporter()
        )
        let canonical: [ModelProfile]
        do {
            let result = try await runner.run(request)
            switch result {
            case .committed(let savedModels, let syncPending, let syncError):
                canonical = savedModels
                lastSaveSyncPending = syncPending
                lastSaveSyncError = syncError
            }
        } catch let error as ProviderSaveRunError {
            switch error {
            case .credentialOrSync:
                lastFailurePhase = .credentialOrSync
            case .localCommit, .readbackMismatch:
                lastFailurePhase = .localCommit
            case .invalidRequest(let problems):
                // Defense-in-depth gate: the frozen request was built and
                // validated by makeSaveRequest, so reaching this means the
                // canonical rule changed or a caller bypassed the draft.
                // Nothing was written; surface every field-level finding.
                lastFailurePhase = .preflight
                fieldIssues = problems.map {
                    ProviderConfigurationIssue(
                        field: .form, problem: $0,
                        messageKey: "providers.validation.invalid"
                    )
                }
            case .concurrentSaveRejected:
                // Another save for this provider is still in flight. Nothing
                // was written by THIS attempt; the user can retry once the
                // in-flight save finishes.
                lastFailurePhase = .preflight
            }
            ProviderSavePhaseLogger.log(.failed)
            let message: String
            switch error {
            case .invalidRequest(let problems):
                let language: ProviderValidationLanguage = FloeL10n.isChinese ? .chinese : .english
                let details = problems.map {
                    ProviderConfigurationValidation.message(
                        for: ProviderConfigurationIssue(
                            field: .form, problem: $0,
                            messageKey: "providers.validation.invalid"
                        ),
                        language: language
                    )
                }
                message = ([FloeL10n.l("providers.save.invalid_request")] + details)
                    .joined(separator: "\n")
            case .concurrentSaveRejected:
                message = FloeL10n.l("providers.save.concurrent_rejected")
            default:
                message = error.localizedDescription
            }
            errorMessage = SecretRedactor.redact(message)
            saveErrorMessage = SecretRedactor.redact(message)
            return false
        } catch {
            lastFailurePhase = .localCommit
            ProviderSavePhaseLogger.log(.failed)
            let message = SecretRedactor.redact(error.localizedDescription)
            errorMessage = message
            saveErrorMessage = message
            return false
        }

        // 3) Routing preference, computed from the FROZEN request and the
        // canonical stored models — never re-reading mutable editor fields.
        // Reflect the committed snapshot only if the user has not edited the field
        // during the save; never overwrite a newer draft.
        if ProviderConfigurationValidation.normalizedDisplayName(displayName) == request.profile.displayName {
            displayName = request.profile.displayName ?? ""
        }
        ProviderSavePhaseLogger.log(.completed)
        if request.serviceRoleIsConversation {
            var preferences = center.modelPreferences
            var appliedChosenDefault = false
            if case .chosen(let remoteModelID) = request.defaultModelIntent,
               request.providerEnabled,
               let canonicalModel = canonical.first(where: {
                   $0.remoteModelID == remoteModelID
                       && $0.isEnabled
                       && $0.isVisibleInPrimaryPicker
               }) {
                preferences.defaultAgentModelID = canonicalModel.id
                appliedChosenDefault = true
            }
            if !appliedChosenDefault {
                // Legacy fallback chain (unchanged): fill a missing default
                // with the first available agent model, or repair one whose
                // model disappeared.
                if preferences.defaultAgentModelID == nil,
                   let first = center.availableAgentModels.first {
                    preferences.defaultAgentModelID = first.id
                } else if let current = preferences.defaultAgentModelID,
                          !center.availableAgentModels.contains(where: { $0.id == current }) {
                    preferences.defaultAgentModelID = center.availableAgentModels.first?.id
                }
            }
            if preferences.defaultAgentModelID != nil {
                preferences.onboardingStatus = .completed
            }
            do {
                try await center.saveModelPreferences(preferences)
            } catch {
                // The provider bundle itself committed and read back. A
                // preference-save failure is surfaced honestly but must not
                // look like the provider failed to save.
                let message = SecretRedactor.redact(error.localizedDescription)
                errorMessage = message
            }
        }
        return true
    }

    /// Retries ONLY the CloudKit enqueue for the provider bundle that already
    /// committed locally. Uses the currently stored local truth (no frozen
    /// request, no secret write, no new sync store); on success the pending
    /// state clears, on failure the exact secret-free reason stays visible.
    @discardableResult
    func retrySync() async -> Bool {
        guard !isRetryingSync else { return false }
        isRetryingSync = true
        defer { isRetryingSync = false }
        if let failure = await center.retryProviderSync(providerID: providerID) {
            lastSaveSyncPending = true
            lastSaveSyncError = failure
            return false
        }
        lastSaveSyncPending = false
        lastSaveSyncError = nil
        return true
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
