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

/// One optional additional service role offered for the provider being
/// edited. The role can only be enabled when a shipped adapter exists, the
/// connection is shareable (same origin/auth) and verified model identifiers
/// are available.
struct ProviderServiceOfferState: Identifiable, Equatable {
    var role: ProviderServiceRole
    var isEnabled: Bool
    var models: [String]
    var connection: ProviderServiceOfferResolution.ConnectionMode
    var isUsable: Bool
    var endpoint: URL?
    /// True when the role needs a real discovery round trip before it can be
    /// configured (no invented model identifiers).
    var requiresDiscovery: Bool = false
    var reason: String?
    var note: String?

    var id: String { role.rawValue }
}

/// One transitory confirmation request shown after a multi-role vendor is
/// selected: the initiating role stays fixed and every extra role is opt-in.
struct ProviderServiceOfferPrompt: Identifiable, Equatable {
    var primaryRole: ProviderServiceRole
    var offers: [ProviderServiceOfferState]

    var id: String { offers.map(\.role.rawValue).sorted().joined(separator: "-") }
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
    /// Stable provider-catalog identity. Native/manual/legacy providers may
    /// carry no presetID; their actual endpoint still selects a template.
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
    /// Optional additional roles (image/video) that a shipped adapter can
    /// really serve for this provider kind. Only `.shared` offers can be
    /// opted in; `.distinct` offers are shown as separate settings with a
    /// non-secret reason.
    @Published private(set) var serviceOffers: [ProviderServiceOfferState] = []
    /// True when at least one usable offer is still undecided. Drives the
    /// one-time prompt section.
    var hasPendingServiceOfferPrompt: Bool {
        serviceOffers.contains { offer in
            guard offer.isUsable, offer.connection == .shared, !offer.isEnabled,
                  !declinedServiceRoles.contains(offer.role) else { return false }
            if case .testing = serviceOfferDiscoveryState[offer.role] { return false }
            return true
        }
    }
    /// Transient one-time confirmation shown after selecting a multi-role
    /// vendor. Nil while no decision is pending.
    @Published var pendingServiceOfferPrompt: ProviderServiceOfferPrompt?
    /// Per-role state of the real discovery round trip a role needs before it
    /// can be configured (roles with verified catalog identifiers never use
    /// this path).
    @Published private(set) var serviceOfferDiscoveryState: [ProviderServiceRole: ConnectionTestState] = [:]
    /// Secret-free discovery failure for one role; the role stays OFF.
    @Published private(set) var serviceOfferDiscoveryError: [ProviderServiceRole: String] = [:]
    /// True when the endpoint host changed while a stored credential exists:
    /// the form then requires a fresh key instead of silently reusing the old
    /// secret on the new host.
    @Published private(set) var requiresNewCredentialForConnection = false

    let center: ConversationCenter
    /// The provider being edited, or nil when adding a new one.
    let existing: ProviderProfile?
    let serviceRole: ProviderServiceRole
    /// Optional validated catalog. Enables embedded catalog search and the
    /// optional multi-service offers; nil keeps the manual-only editor.
    let catalog: ProviderCatalogIndex?
    private let secretStore = KeychainSecretStore()
    private let adapterFactory = ProviderAdapterFactory()
    private let promptStore: ProviderServiceOfferPromptStore
    /// Models staged for opted-in additional roles (media or chat) that are
    /// saved in the same bundle transaction as the primary role.
    private var additionalRoleModels: [ProviderServiceRole: [ModelProfile]] = [:]
    private var declinedServiceRoles: Set<ProviderServiceRole> = []
    /// Verified catalog identifiers staged for a distinct-connection offer
    /// opened as its own editor (for example the Google Gemini
    /// OpenAI-compatible conversation route). Catalog-declared only: nothing
    /// is invented locally.
    private let serviceOfferSeedModels: [String]

    /// The provider ID (stable across edit; new when adding).
    let providerID: UUID

    init(
        center: ConversationCenter,
        existing: ProviderProfile?,
        initialRole: ProviderServiceRole? = nil,
        catalogEntry: ProviderCatalogEntry? = nil,
        catalog: ProviderCatalogIndex? = nil,
        promptStore: ProviderServiceOfferPromptStore = .shared,
        serviceOfferEndpointOverride: URL? = nil,
        serviceOfferSeedModels: [String] = []
    ) {
        self.center = center
        self.existing = existing
        self.catalog = catalog
        self.promptStore = promptStore
        self.serviceOfferSeedModels = serviceOfferSeedModels
        let existingModels = existing.flatMap { center.configuredModelsByProvider[$0.id] } ?? []
        self.serviceRole = initialRole ?? ProviderServiceRole.infer(from: existingModels)
        if let existing {
            self.providerID = existing.id
            let preset = ProviderPreset.preset(for: existing.kind, baseURL: existing.baseURL)
            self.selectedPreset = preset
            self.selectedProtocol = existing.wireProtocol
            self.displayName = existing.displayName ?? preset.displayName
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
        if let serviceOfferEndpointOverride {
            // A distinct-endpoint offer opens its own editor; the credential
            // for this new connection is entered by the user.
            apiKey = ""
            baseURLString = serviceOfferEndpointOverride.absoluteString
        }
        declinedServiceRoles = promptStore.declinedRoles(for: providerID)
        refreshConnectionCredentialState()
        refreshServiceOffers()
    }

    /// Applies a preset's defaults to the editable fields.
    func applyPreset(_ preset: ProviderPreset) {
        let previousPresetName = selectedPreset.displayName
        let shouldReplaceDisplayName = ProviderConfigurationValidation
            .ProviderSelectionFieldPolicy.shouldReplaceDisplayName(
                current: displayName,
                previousDefault: previousPresetName
            )
        let previousIdentity = currentConnectionIdentity()
        selectedPreset = preset
        // Native suppliers do not inherit a catalog row's metadata or older
        // availability policy. Saved Kimi Code profiles resolve by endpoint.
        catalogPresetID = nil
        // Only auto-fill the name when the user hasn't customized it, so a
        // typed "DeepSeek" survives switching protocols/presets.
        if shouldReplaceDisplayName {
            displayName = preset.displayName
        }
        baseURLString = preset.defaultBaseURL.absoluteString
        selectedProtocol = preset.defaultProtocol
        if previousIdentity != currentConnectionIdentity() {
            // Never carry a typed key across an incompatible connection (a
            // different origin, port, scheme or provider/auth family); the
            // stored-key case is enforced by the save preflight.
            apiKey = ""
        }
        refreshConnectionCredentialState()
        refreshServiceOffers()
    }

    /// Pre-fills the editor from one official-catalog entry. The entry's
    /// kind selects the closest shipped adapter preset; the catalog identity
    /// is remembered so `buildProfile()` persists it as `presetID`.
    func applyCatalogEntry(_ entry: ProviderCatalogEntry) {
        let previousPresetName = selectedPreset.displayName
        let shouldReplaceDisplayName = ProviderConfigurationValidation
            .ProviderSelectionFieldPolicy.shouldReplaceDisplayName(
                current: displayName,
                previousDefault: previousPresetName
            )
        let previousIdentity = currentConnectionIdentity()
        selectedPreset = entry.kind == .local ? .custom
            : ProviderPreset.preset(for: entry.kind, baseURL: entry.baseURL)
        selectedProtocol = entry.defaultProtocol
        // Selection happens mid-form: only an untouched/uncustomized name is
        // replaced by the catalog name.
        if shouldReplaceDisplayName {
            displayName = entry.name
        }
        if let baseURL = entry.baseURL {
            baseURLString = baseURL.absoluteString
        }
        // Selecting a catalog entry that changes the connection identity must
        // never carry the typed key with it (the stored-key case is enforced
        // at preflight). Same-provider alias/path changes keep the key.
        if previousIdentity != currentConnectionIdentity() {
            apiKey = ""
        }
        // DeepSeek rejects dotted tool names; the catalog flag (or its known
        // preset identity) turns the compatibility rewrite on.
        toolNameCompatibility = entry.toolNameCompatibility || entry.presetID == "deepseek"
        catalogPresetID = entry.presetID
        refreshConnectionCredentialState()
        refreshServiceOffers()
        // Selecting a multi-role vendor raises the ONE-TIME native prompt;
        // extras are opted in there, never as a permanent inline invitation.
        presentServiceOfferPromptIfNeeded()
    }

    /// Connection identity of the CURRENT form fields (scheme/host/port plus
    /// provider routing and auth family). Nil while the URL does not parse.
    private func currentConnectionIdentity() -> ProviderConfigurationValidation.ProviderConnectionIdentity.Key? {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return ProviderConfigurationValidation.ProviderConnectionIdentity.key(
            kind: selectedPreset.kind,
            baseURL: url
        )
    }

    // MARK: - Optional service roles

    /// Supplier-field selection finished: recompute the optional role offers
    /// and raise the one-time prompt when genuine multi-role support exists.
    /// Used by the unified supplier selector for BOTH built-in presets and
    /// catalog entries.
    func supplierSelectionDidComplete() {
        refreshServiceOffers()
        presentServiceOfferPromptIfNeeded()
    }

    /// Recomputes the offered additional roles from the selected provider
    /// kind, shipped adapters, official model identifiers, the optional
    /// catalog metadata and the connection's compatibility. Configured roles
    /// and prior declines are never re-offered.
    func refreshServiceOffers() {
        declinedServiceRoles = promptStore.declinedRoles(for: providerID)
        let entry = resolvedCatalogEntry()
        let kind = selectedPreset.kind
        let resolutions = ProviderServiceOfferResolver.resolvedOffers(
            for: kind,
            presetID: catalogPresetID,
            baseURL: URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
            authStyle: Self.catalogAuthStyle(for: selectedPreset),
            availability: entry?.availability ?? .available,
            declared: entry?.serviceOffers
        )
        let existingModels = existing.flatMap { center.configuredModelsByProvider[$0.id] } ?? []
        var states: [ProviderServiceOfferState] = []
        for resolution in resolutions {
            guard let role = ProviderServiceRole(rawValue: resolution.role.rawValue),
                  role != serviceRole else { continue }
            let alreadyConfigured = existingModels.contains { model in
                switch role {
                case .conversation: model.supportsChatAgentSurface
                case .image: model.supportsImageGenerationSurface
                case .video: model.supportsVideoGenerationSurface
                }
            }
            if alreadyConfigured { continue }
            if declinedServiceRoles.contains(role) { continue }
            guard resolution.isUsable else {
                // Declared but unsupported: keep it visible with the reason so
                // a dead control is never silently offered.
                if resolution.reason != nil {
                    states.append(ProviderServiceOfferState(
                        role: role,
                        isEnabled: false,
                        models: resolution.models,
                        connection: resolution.connection,
                        isUsable: false,
                        endpoint: resolution.endpoint,
                        reason: resolution.reason,
                        note: resolution.note
                    ))
                }
                continue
            }
            states.append(ProviderServiceOfferState(
                role: role,
                isEnabled: additionalRoleModels[role] != nil,
                models: resolution.models,
                connection: resolution.connection,
                isUsable: true,
                endpoint: resolution.endpoint,
                requiresDiscovery: resolution.requiresDiscovery,
                reason: resolution.reason,
                note: resolution.note
            ))
        }
        serviceOffers = states
    }

    /// Opts in or out of one additional role. Only shareable connections can
    /// be enabled; distinct connections keep their own settings and are never
    /// silently merged into this provider. A role without verified catalog
    /// identifiers runs the existing real discovery round trip first; failure
    /// leaves the role OFF with the exact reason (no invented models).
    func setServiceOfferEnabled(_ role: ProviderServiceRole, isEnabled: Bool) {
        guard let index = serviceOffers.firstIndex(where: { $0.role == role }),
              serviceOffers[index].isUsable,
              serviceOffers[index].connection == .shared else { return }
        if !isEnabled {
            additionalRoleModels[role] = nil
            serviceOffers[index].isEnabled = false
            serviceOfferDiscoveryState[role] = .idle
            serviceOfferDiscoveryError[role] = nil
            return
        }
        if additionalRoleModels[role] != nil {
            serviceOffers[index].isEnabled = true
            return
        }
        if serviceOffers[index].requiresDiscovery {
            if case .testing = serviceOfferDiscoveryState[role] { return }
            serviceOfferDiscoveryState[role] = .testing
            serviceOfferDiscoveryError[role] = nil
            Task { await enableServiceOfferWithDiscovery(role) }
            return
        }
        additionalRoleModels[role] = makeRoleModels(
            for: role,
            discovered: serviceOffers[index].models.map {
                Self.syntheticRoleModel($0, role: role)
            }
        )
        serviceOffers[index].isEnabled = true
    }

    /// Runs the real adapter model discovery for one additional role. The
    /// discovered identifiers come from the endpoint itself; nothing is
    /// invented locally. On failure the role stays off with the exact
    /// reason and no partial models are staged.
    private func enableServiceOfferWithDiscovery(_ role: ProviderServiceRole) async {
        do {
            let profile = try buildProfile()
            let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let credentials: ProviderCredentials
            if !enteredKey.isEmpty {
                credentials = ProviderCredentials(apiKey: enteredKey)
            } else {
                credentials = center.resolveCredentials(for: profile)
            }
            let adapter = adapterFactory.adapter(for: profile)
            let discovered = try await adapter.listModels(
                provider: profile,
                credentials: credentials
            )
            guard !discovered.isEmpty else {
                throw FloeError.validationFailed("Model discovery returned no models")
            }
            additionalRoleModels[role] = makeRoleModels(
                for: role,
                discovered: discovered.map { Self.normalizedRoleModel($0, role: role, providerID: providerID) }
            )
            if let index = serviceOffers.firstIndex(where: { $0.role == role }) {
                serviceOffers[index].isEnabled = true
            }
            serviceOfferDiscoveryState[role] = .succeeded(modelCount: discovered.count)
        } catch {
            let message = SecretRedactor.redact(error.localizedDescription)
            serviceOfferDiscoveryState[role] = .failed(message)
            serviceOfferDiscoveryError[role] = message
            additionalRoleModels[role] = nil
            if let index = serviceOffers.firstIndex(where: { $0.role == role }) {
                serviceOffers[index].isEnabled = false
            }
        }
    }

    /// Catalog identifiers staged as role models without any local guessing:
    /// capabilities and surfaces come from the role's fixed contract, the
    /// display name from the product-owned media manifest when it is a media
    /// identifier, otherwise the identifier itself.
    private static func syntheticRoleModel(
        _ remoteID: String,
        role: ProviderServiceRole
    ) -> ModelProfile {
        ModelProfile(
            providerID: UUID(),
            remoteModelID: remoteID,
            displayName: OfficialMediaModelCatalog.models
                .first { $0.remoteModelID == remoteID }?.displayName ?? remoteID,
            limits: ModelLimits(
                contextTokens: role == .conversation ? 128_000 : 32_768,
                maxOutputTokens: 0
            ),
            capabilities: role.defaultCapabilities,
            useSurfaces: role.defaultUseSurfaces,
            isEnabled: true,
            isHiddenFromPrimaryPicker: role != .conversation
        )
    }

    /// Normalizes one discovered model for a role: preserves the endpoint's
    /// identifiers and any capability flags it reported, and applies the
    /// role's surfaces/picker-visibility contract.
    private static func normalizedRoleModel(
        _ model: ModelProfile,
        role: ProviderServiceRole,
        providerID: UUID
    ) -> ModelProfile {
        var normalized = model
        normalized.providerID = providerID
        normalized.isHiddenFromPrimaryPicker = role != .conversation
        normalized.useSurfaces = (normalized.useSurfaces ?? []).union(role.defaultUseSurfaces)
        if role != .conversation {
            normalized.capabilities.formUnion(role.defaultCapabilities)
        }
        return normalized
    }

    /// Raises the transient confirmation when undecided usable roles exist.
    private func presentServiceOfferPromptIfNeeded() {
        let pending = serviceOffers.filter {
            $0.isUsable && $0.connection == .shared && !$0.isEnabled
                && !declinedServiceRoles.contains($0.role)
        }
        guard !pending.isEmpty else {
            pendingServiceOfferPrompt = nil
            return
        }
        pendingServiceOfferPrompt = ProviderServiceOfferPrompt(
            primaryRole: serviceRole,
            offers: pending
        )
    }

    /// Confirms the one-time prompt: selected extra roles are staged (and
    /// discovered where required), unselected extras are recorded as declined
    /// so the prompt is not shown again for this provider.
    func confirmServiceOfferSelection(_ roles: Set<ProviderServiceRole>) {
        guard let prompt = pendingServiceOfferPrompt else { return }
        pendingServiceOfferPrompt = nil
        let pendingRoles = Set(prompt.offers.map(\.role))
        let declined = pendingRoles.subtracting(roles)
        if !declined.isEmpty {
            promptStore.recordDecline(roles: declined, for: providerID)
            declinedServiceRoles.formUnion(declined)
            serviceOffers.removeAll { declined.contains($0.role) }
        }
        for role in roles.sorted(by: { $0.rawValue < $1.rawValue }) {
            setServiceOfferEnabled(role, isEnabled: true)
        }
    }

    /// Declines the whole one-time prompt (the explicit button and the sheet
    /// dismissal both land here): every pending role is recorded once.
    func declineServiceOfferPrompt() {
        guard let prompt = pendingServiceOfferPrompt else { return }
        pendingServiceOfferPrompt = nil
        let roles = Set(prompt.offers.map(\.role))
        guard !roles.isEmpty else { return }
        promptStore.recordDecline(roles: roles, for: providerID)
        declinedServiceRoles.formUnion(roles)
        serviceOffers.removeAll { roles.contains($0.role) }
    }

    /// Sheet `onDismiss` hook: a dismissal that is not a confirmation is a
    /// decline.
    func dismissServiceOfferPrompt() {
        declineServiceOfferPrompt()
    }

    /// Records a one-time decline for every still-undecided usable role and
    /// removes those rows; the prompt is not shown again for this provider.
    func declineServiceOffers() {
        let roles = Set(
            serviceOffers
                .filter { $0.isUsable && $0.connection == .shared && !$0.isEnabled }
                .map(\.role)
        )
        guard !roles.isEmpty else { return }
        promptStore.recordDecline(roles: roles, for: providerID)
        declinedServiceRoles.formUnion(roles)
        serviceOffers.removeAll { roles.contains($0.role) }
    }

    /// Canonical models for an opted-in role: every existing model that
    /// already serves the role (with its stored capability overrides intact)
    /// plus the verified/discovered models that are not configured yet.
    private func makeRoleModels(
        for role: ProviderServiceRole,
        discovered: [ModelProfile]
    ) -> [ModelProfile] {
        var models = (existing.flatMap { center.configuredModelsByProvider[$0.id] } ?? [])
            .filter { model in
                switch role {
                case .conversation: model.supportsChatAgentSurface
                case .image: model.supportsImageGenerationSurface
                case .video: model.supportsVideoGenerationSurface
                }
            }
        var known = Set(models.map(\.remoteModelID))
        for model in discovered where known.insert(model.remoteModelID).inserted {
            var normalized = Self.normalizedRoleModel(model, role: role, providerID: providerID)
            if role == .conversation {
                // Catalog-declared conversation models use the same
                // metadata-driven defaults as discovery and manual entry.
                normalized.capabilities = defaultCapabilities(
                    forRemoteID: normalized.remoteModelID,
                    role: .conversation
                )
            }
            models.append(normalized)
        }
        return models
    }

    /// The catalog entry this editor is anchored to: the stored presetID for
    /// an existing provider, or the identity applied from the picker. Hidden
    /// presets stay resolvable so a saved provider can still be edited.
    private func resolvedCatalogEntry() -> ProviderCatalogEntry? {
        // catalogPresetID is seeded from the stored presetID and updated by
        // catalog selection, so it is the current catalog identity.
        guard let presetID = catalogPresetID, let catalog else { return nil }
        return catalog.entry(presetID: presetID)
    }

    /// Verified catalog metadata for one remote model identifier, when the
    /// entry anchored to this editor declares it.
    func catalogModelMetadata(for remoteID: String) -> ProviderCatalogModelMetadata? {
        if let metadata = resolvedCatalogEntry()?.modelMetadata?[remoteID] { return metadata }
        // Built-in presets deliberately have no catalogPresetID (it also
        // controls availability/service offers). Resolve capability evidence
        // separately, without changing that policy or the saved provider.
        guard let catalog,
              let endpoint = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return ProviderCatalogCapabilityResolver.metadata(
            forRemoteID: remoteID, kind: selectedPreset.kind,
            baseURL: endpoint, modelProtocol: selectedProtocol, catalog: catalog
        )
    }

    /// True when the catalog verifies image input for this model AND the
    /// staged/saved row actually carries the `.vision` bit: the badge states
    /// what the run will really send, never a provider-wide guess.
    func catalogVerifiedImageInput(for model: ModelProfile) -> Bool {
        model.capabilities.contains(.vision)
            && ProviderCatalogCapabilityResolver.supportsImageInput(
                catalogModelMetadata(for: model.remoteModelID)
            )
    }

    /// Capability defaults for a NEWLY created model row. Discovery and the
    /// manual fallback use this same pure resolver: verified catalog metadata
    /// when present, the legacy protocol default otherwise. Existing rows are
    /// never rewritten here — only the user-reviewed migration can do that.
    private func defaultCapabilities(
        forRemoteID remoteID: String,
        role: ProviderServiceRole
    ) -> ModelCapabilities {
        switch role {
        case .conversation:
            return ProviderCatalogCapabilityResolver.capabilities(
                for: catalogModelMetadata(for: remoteID),
                base: ModelCapabilities.defaultTextModel(for: selectedProtocol)
            )
        case .image, .video:
            return role.defaultCapabilities
        }
    }

    /// Catalog entry exposed to the view for the "configure separately" flow
    /// of a distinct-connection offer.
    var catalogEntryForSeparateOffer: ProviderCatalogEntry? { resolvedCatalogEntry() }

    private static func catalogAuthStyle(for preset: ProviderPreset) -> String {
        switch preset.authStyle {
        case .bearer: "bearer"
        case .apiKeyHeader: "apiKeyHeader"
        case .none: "none"
        }
    }

    /// True when a stored credential exists but the current form's connection
    /// identity (origin, port, scheme, provider routing/auth family) differs
    /// from the stored profile's. Saving then requires a new key.
    private func refreshConnectionCredentialState() {
        guard let existing, existing.secretRef != nil,
              let newURL = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            requiresNewCredentialForConnection = false
            return
        }
        requiresNewCredentialForConnection = !ProviderConfigurationValidation
            .ProviderConnectionIdentity.isCompatible(
                from: existing.kind,
                oldBaseURL: existing.baseURL,
                to: selectedPreset.kind,
                newBaseURL: newURL
            )
    }

    /// User-facing hint shown when the connection identity changed while a
    /// stored credential exists. Uses the App catalog key when present,
    /// otherwise the bilingual validation-boundary message.
    var connectionCredentialRequirementMessage: String? {
        guard requiresNewCredentialForConnection else { return nil }
        return Self.presentableMessage(for: ProviderConfigurationIssue(
            field: .baseURL,
            problem: .connectionChangedRequiresNewCredential,
            messageKey: "providers.validation.connection_changed_requires_key"
        ))
    }

    var availableProtocols: [ModelProtocol] { selectedPreset.supportedProtocols }

    var availablePresets: [ProviderPreset] {
        if existing?.kind == .googleGemini { return [.googleGemini] }
        return Self.presets(for: serviceRole)
    }

    var supportsDiscovery: Bool {
        selectedPreset.supportsModelDiscovery
    }

    var needsKimiImageModelSelection: Bool {
        guard serviceRole == .image,
              let baseURL = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return ProviderPreset.preset(for: selectedPreset.kind, baseURL: baseURL).id == .kimiCode
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

    /// Loads the current secret-sync state for an existing provider, or
    /// stages a distinct-connection offer's verified catalog identifiers for
    /// a new one.
    func load() async {
        guard existing != nil else {
            // A distinct-connection offer (separate endpoint/auth) carries its
            // verified catalog identifiers into this editor so the new
            // settings row is immediately usable without local guessing.
            if serviceRole == .conversation {
                for remoteID in serviceOfferSeedModels {
                    addManualModel(remoteID: remoteID, displayName: remoteID)
                }
            }
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
        refreshServiceOffers()
    }

    // MARK: - Build profile / frozen save request

    /// The complete model set this save will commit: the primary role's
    /// selection plus every opted-in additional role, in a stable order.
    var modelsForSave: [ModelProfile] {
        var models = selectedModels
        for role in serviceOffers.map(\.role).sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let extras = additionalRoleModels[role] else { continue }
            models.append(contentsOf: extras)
        }
        return models
    }

    /// Capability union for stale-row cleanup: only roles this save manages
    /// may remove rows, so a conversation save that never opted into media
    /// leaves existing media models untouched.
    var managedCapabilitiesForSave: ModelCapabilities {
        var capabilities = serviceRole.managedCapabilities
        for role in additionalRoleModels.keys {
            capabilities.formUnion(role.managedCapabilities)
        }
        return capabilities
    }

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
            presetID: catalogPresetID,
            existingSecretRef: existing?.secretRef,
            nonSecretHeaders: Self.parseHeaders(nonSecretHeadersText),
            isEnabled: enabled,
            allowsPlainHTTP: allowsPlainHTTP,
            toolNameCompatibility: toolNameCompatibility,
            syncEnabled: syncEnabled,
            enteredAPIKey: apiKey,
            selectedModels: modelsForSave,
            managedCapabilities: managedCapabilitiesForSave,
            serviceRoleIsConversation: serviceRole == .conversation,
            defaultModelID: defaultModelID,
            existingCreatedAt: existing?.createdAt,
            existingSyncRevision: existing?.syncRevision ?? 0,
            existingBaseURL: existing?.baseURL,
            existingKind: existing?.kind
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
        let previous = candidateModels[index]
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
        // Record exactly the user-editable bits this save changed, so refresh,
        // discovery and sync can never silently re-enable a disabled bit (or
        // silently disable an enabled one). Forced role bits (.text/.approval)
        // are not user decisions and stay out of the mask.
        let userEditable: ModelCapabilities = [
            .vision, .tools, .imageGeneration, .imageEditing, .videoGeneration
        ]
        let changed = normalized.capabilities
            .symmetricDifference(previous.capabilities)
            .intersection(userEditable)
        if !changed.isEmpty {
            normalized.explicitCapabilities = (previous.explicitCapabilities ?? []).union(changed)
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
        let knownRemoteIDs = Set(candidateModels.map(\.remoteModelID))
        let normalized = discovered.map { discoveredModel in
            var model = discoveredModel
            if serviceRole != .conversation {
                model.capabilities = serviceRole.defaultCapabilities
                model.isHiddenFromPrimaryPicker = true
                model.useSurfaces = serviceRole.defaultUseSurfaces
            } else {
                // New rows get metadata-driven defaults. Existing rows keep
                // their stored capabilities exactly: the merger can only add
                // bits the user has not explicitly decided.
                if !knownRemoteIDs.contains(model.remoteModelID) {
                    model.capabilities = defaultCapabilities(
                        forRemoteID: model.remoteModelID,
                        role: .conversation
                    )
                }
                if model.useSurfaces == nil {
                    model.useSurfaces = serviceRole.defaultUseSurfaces
                }
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
            capabilities: defaultCapabilities(forRemoteID: trimmed, role: serviceRole),
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
            ProviderPreset.imagePresets
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
        // The optional-role prompt is shown once per provider: a successful
        // save with the section left undecided records those declines so the
        // user is not asked again.
        declineUndecidedOffersAfterSave()
        return true
    }

    /// Records the implicit decline after a successful save that left enabled
    /// offers untouched.
    private func declineUndecidedOffersAfterSave() {
        let roles = Set(
            serviceOffers
                .filter { $0.isUsable && $0.connection == .shared && !$0.isEnabled }
                .map(\.role)
        )
        guard !roles.isEmpty else { return }
        promptStore.recordDecline(roles: roles, for: providerID)
        declinedServiceRoles.formUnion(roles)
        serviceOffers.removeAll { roles.contains($0.role) }
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
