// FloeApp — Explicit speech settings and Keychain-bound credentials.
#if canImport(UIKit)
import Foundation
import Combine
import FloeCore
import FloeSecurity
import FloeProviders

/// Three-state outcome of the local-pack load-validation hook. `deferred`
/// leaves the retry gate closed (transient lease/memory/thermal); a real
/// failure waits for an explicit retry so a broken pack is never marked good.
enum LocalPackValidation: Sendable, Equatable { case passed, deferred, failed }

@MainActor
final class TTSSettingsService: ObservableObject {
    @Published private(set) var snapshot: TTSSettingsSnapshot
    @Published private(set) var localInstallation = LocalSpeechModelStore.Installation()
    @Published private(set) var localVisibleModels: [LocalSpeechModel] = []
    /// Packs a user may manage: all downloadable packs plus any installed
    /// hidden legacy descriptor, so old storage stays visible and removable.
    @Published private(set) var localManagedModels: [LocalSpeechModel] = []
    @Published private(set) var localInstalledModelIDs: Set<String> = []
    /// Fixed localization key shown while a pack installed but has not yet
    /// passed the load-validation hook (nil when healthy).
    @Published private(set) var localMigrationNote: String?
    /// Set when the bundled pack catalog itself cannot be validated/decoded.
    @Published private(set) var localCatalogErrorKey: String?
    /// One concise product progress step for the pack it applies to while a
    /// migration is between "bytes installed" and "transition finished":
    /// checking (load validation) or removing (legacy cleanup). Surfaces show
    /// this instead of an immediately-ready "Installed" state.
    struct LocalProgressOperation: Equatable, Sendable { let modelID: String; let key: String }
    @Published private(set) var localProgressOperation: LocalProgressOperation?
    private let defaults: UserDefaults
    private let keychain: any KeychainProbeStore
    private let modelStore: LocalSpeechModelStore
    private let resolveConnection: @MainActor (UUID) async throws -> String
    private let localPackValidator: @Sendable (LocalSpeechModel, String?) async -> LocalPackValidation
    private static let storageKey = "voice.output.settings.v1"
    private static let profilesKey = "voice.output.profiles.v1"
    private static let selectionRevisionKey = "voice.output.selectionRevision"
    private static let firstInstallKey = "voice.output.firstInstallSelection"
    private static let pendingSelectionKey = "voice.output.pendingSelection"
    private var installationObserver: AnyCancellable?
    private struct PendingSelection: Codable { let modelID: String; let revision: Int }
    private var profiles: [String: TTSSettingsSnapshot] = [:]
    // Service-owned transfer snapshot pump: list, voice picker and detail all
    // read this one state; downloads and cleanup are never view-lifetime owned.
    private var localStatePump: Task<Void, Never>?
    private var migrationValidationStarted = false
    private var firstInstallValidationStarted = false
    private var pendingLocalMigration: Bool?

    init(defaults: UserDefaults = .standard,
         keychain: any KeychainProbeStore = KeychainStore(service: "org.floeagent.ios.tts", synchronizable: false),
         resolveConnection: @escaping @MainActor (UUID) async throws -> String = { _ in throw TTSSettingsFailure.missingCredential },
         modelStore: LocalSpeechModelStore = .shared,
         loadValidator: (@Sendable (LocalSpeechModel, String?) async -> LocalPackValidation)? = nil) {
        self.defaults = defaults
        self.modelStore = modelStore
        self.keychain = keychain
        self.resolveConnection = resolveConnection
        self.localPackValidator = loadValidator ?? { model, voiceID in
            await LocalSpeechRuntime.validateLocalPack(modelID: model.id, voiceID: voiceID)
        }
        profiles = defaults.data(forKey: Self.profilesKey).flatMap { try? JSONDecoder().decode([String: TTSSettingsSnapshot].self, from: $0) } ?? [:]
        snapshot = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(TTSSettingsSnapshot.self, from: $0) } ?? .systemDefault
        installationObserver = NotificationCenter.default.publisher(for: .localSpeechInstallationCompleted)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.syncLocalSelection() }
            }
        Task { [weak self] in await self?.syncLocalSelection() }
        localStatePump = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshLocalSpeechState()
                await self.syncLocalSelection()
                // Fast only while bytes are actually moving; otherwise a slow
                // idle sweep just catches out-of-band removals. Migration and
                // selection transitions are event-driven (notification, install,
                // user update), so idle cadence stays low and cheap.
                let active = self.localInstallation.running
                    || (self.pendingLocalMigration == true)
                let cadence: Double = active ? 0.5 : 15
                do { try await Task.sleep(for: .seconds(cadence)) } catch { return }
            }
        }
    }
    deinit { localStatePump?.cancel() }

    func update(_ change: (inout TTSSettingsSnapshot) -> Void) {
        var value = snapshot
        change(&value)
        value.speechRateRatio = min(2, max(0.5, value.speechRateRatio.isFinite ? value.speechRateRatio : 1))
        guard let encoded = try? JSONEncoder().encode(value) else { return }
        defaults.set(encoded, forKey: Self.storageKey)
        profiles[binding(value.provider, value.billingRoute)] = value
        if let encodedProfiles = try? JSONEncoder().encode(profiles) { defaults.set(encodedProfiles, forKey: Self.profilesKey) }
        if snapshot.provider != value.provider || snapshot.modelID != value.modelID || snapshot.voiceID != value.voiceID || snapshot.language != value.language {
            defaults.set(defaults.integer(forKey: Self.selectionRevisionKey) + 1, forKey: Self.selectionRevisionKey)
        }
        snapshot = value
        // A selection change may release a legacy pack held by awaitingLegacyRelease
        // or land exactly when a revision-aware migration was waiting on it.
        Task { [weak self] in await self?.reconcileLocalMigration() }
    }

    func voiceDisplayName(for value: TTSSettingsSnapshot) -> String? {
        defaults.dictionary(forKey: "voice.output.voiceNames.v1")?[profileID(value) + "/" + value.voiceID] as? String
    }
    func rememberVoiceName(_ name: String, for value: TTSSettingsSnapshot) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { return }
        var names = defaults.dictionary(forKey: "voice.output.voiceNames.v1") as? [String: String] ?? [:]
        names[profileID(value) + "/" + value.voiceID] = name
        objectWillChange.send()
        defaults.set(names, forKey: "voice.output.voiceNames.v1")
    }

    var configuredProfiles: [TTSSettingsSnapshot] {
        profiles.values.filter { $0.provider.requiresCloudCredential && (hasCredential(for: $0) || $0.connectionProviderID != nil) }
            .sorted { profileID($0) < profileID($1) }
    }
    func profileID(_ value: TTSSettingsSnapshot) -> String { binding(value.provider, value.billingRoute) }
    func profile(provider: TTSSpeakerProvider, route: TTSBillingRoute) -> TTSSettingsSnapshot {
        profiles[binding(provider, route)] ?? TTSSettingsSnapshot(provider: provider, billingRoute: route)
    }
    func hasCredential(for value: TTSSettingsSnapshot) -> Bool {
        (try? keychain.read(account: account(value)))?.isEmpty == false
    }
    func saveProfile(_ value: TTSSettingsSnapshot, credential: String) throws {
        var saved = value
        let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { try keychain.store(account: account(saved), secret: Data(key.utf8)); saved.connectionProviderID = nil }
        guard hasCredential(for: saved) || saved.connectionProviderID != nil else { throw TTSSettingsFailure.missingCredential }
        objectWillChange.send()
        profiles[profileID(saved)] = saved
        defaults.set(try JSONEncoder().encode(profiles), forKey: Self.profilesKey)
        if snapshot.provider == saved.provider && snapshot.billingRoute == saved.billingRoute {
            saved.autoReadEnabled = snapshot.autoReadEnabled; saved.allowBargeIn = snapshot.allowBargeIn
            update { $0 = saved }
        }
    }
    func removeProfile(_ value: TTSSettingsSnapshot) throws {
        try keychain.delete(account: account(value))
        objectWillChange.send()
        profiles.removeValue(forKey: profileID(value))
        defaults.set(try JSONEncoder().encode(profiles), forKey: Self.profilesKey)
        if snapshot.provider == value.provider && snapshot.billingRoute == value.billingRoute {
            update { $0.provider = .apple; $0.voiceID = ""; $0.modelID = ""; $0.connectionProviderID = nil }
        }
    }
    func choose(_ value: TTSSettingsSnapshot) {
        var chosen = value
        chosen.autoReadEnabled = snapshot.autoReadEnabled; chosen.allowBargeIn = snapshot.allowBargeIn
        update { $0 = chosen }
    }

    // MARK: - Local packs

    func install(_ model: LocalSpeechModel) async {
        if !model.isHidden, !defaults.bool(forKey: Self.firstInstallKey) {
            let pending = PendingSelection(modelID: model.id, revision: defaults.integer(forKey: Self.selectionRevisionKey))
            defaults.set(try? JSONEncoder().encode(pending), forKey: Self.pendingSelectionKey)
        }
        await modelStore.beginInstallation(model, selectionRevision: defaults.integer(forKey: Self.selectionRevisionKey))
        await refreshLocalSpeechState()
    }
    func cancelInstallation() async {
        defaults.removeObject(forKey: Self.pendingSelectionKey)
        firstInstallValidationStarted = false
        await modelStore.cancelInstallation()
        await refreshLocalSpeechState()
    }
    /// Explicit retry after a failed load validation (UI action).
    func retryLocalValidation() async {
        migrationValidationStarted = false
        firstInstallValidationStarted = false
        await reconcileLocalMigration()
        await finishFirstInstallationSelection()
    }

    /// First successful pack installation switches to the pack ONLY after the
    /// bytes verify and the load-validation hook passes; the voice is the
    /// catalog default, never a hardcoded provider voice id.
    private func finishFirstInstallationSelection() async {
        guard !defaults.bool(forKey: Self.firstInstallKey),
              let bytes = defaults.data(forKey: Self.pendingSelectionKey),
              let pending = try? JSONDecoder().decode(PendingSelection.self, from: bytes),
              let model = try? await modelStore.catalog().first(where: { $0.id == pending.modelID }),
              !model.isHidden,
              await modelStore.isInstalled(model),
              let defaultVoice = model.defaultVoiceID ?? model.voices.first?.id else { return }
        guard !firstInstallValidationStarted else { return }
        firstInstallValidationStarted = true
        switch await localPackValidator(model, defaultVoice) {
        case .deferred:
            firstInstallValidationStarted = false
            return
        case .failed:
            localMigrationNote = "voice.local.error.verify"
            return
        case .passed:
            localMigrationNote = nil
        }
        defaults.set(true, forKey: Self.firstInstallKey)
        defaults.removeObject(forKey: Self.pendingSelectionKey)
        firstInstallValidationStarted = false
        guard pending.revision == defaults.integer(forKey: Self.selectionRevisionKey) else { return }
        update {
            $0.provider = .onDevice; $0.modelID = model.id; $0.voiceID = defaultVoice
            $0.language = nil; $0.connectionProviderID = nil; $0.billingRoute = .payAsYouGo
        }
    }

    /// Revision-aware legacy→new selection transition. Only a selection that is
    /// still uses the legacy pack moves to the equivalent qualified voice (or
    /// the new default). A selection changed during download stays authoritative.
    private func migrateLegacySelectionIfNeeded(record: LocalSpeechModelStore.MigrationRecord, to model: LocalSpeechModel) async {
        let catalog = (try? await modelStore.catalog()) ?? []
        // Check the live selection AFTER the actor hop, so a late catalog
        // result cannot replace a voice chosen while that read was suspended.
        guard snapshot.provider == .onDevice,
              let legacy = record.legacy.first(where: { $0.id == snapshot.modelID }),
              record.selectionRevision == defaults.integer(forKey: Self.selectionRevisionKey),
              let legacyModel = catalog.first(where: { $0.id == legacy.id }) else { return }
        let voice: String?
        if snapshot.voiceID == (legacyModel.defaultVoiceID ?? legacyModel.voices.first?.id) {
            voice = model.defaultVoiceID ?? model.voices.first?.id
        } else {
            voice = model.voices.first(where: { $0.id == snapshot.voiceID })?.id
        }
        guard let voice else { return }
        update { $0.modelID = model.id; $0.voiceID = voice; $0.language = nil }
    }

    /// Durable migration state machine. Safe to call on every trigger; stages
    /// are persisted in the store and survive process death.
    /// Idempotent service-side selection + migration sync. Driven by the
    /// install-complete notification, user selection updates, launch and the
    /// idle pump — views never own this flow.
    func syncLocalSelection() async {
        await finishFirstInstallationSelection()
        await reconcileLocalMigration()
    }

    func reconcileLocalMigration() async {
        guard let record = await modelStore.migrationRecord else {
            pendingLocalMigration = false
            // A completed migration resolves the retryable-cleanup note.
            if localMigrationNote == "voice.local.error.remove" { localMigrationNote = nil }
            return
        }
        pendingLocalMigration = true
        switch record.stage {
        case .pendingInstall:
            break
        case .awaitingLoadValidation:
            guard !migrationValidationStarted else { return }
            guard let model = (try? await modelStore.catalog())?.first(where: { $0.id == record.newModelID && $0.revision == record.newRevision }),
                  await modelStore.isInstalled(model) else { return }
            migrationValidationStarted = true
            let voiceID = model.defaultVoiceID ?? model.voices.first?.id
            switch await localPackValidator(model, voiceID) {
            case .deferred:
                migrationValidationStarted = false
                return
            case .failed:
                localMigrationNote = "voice.local.error.verify"
                return
            case .passed:
                localMigrationNote = nil
            }
            // The gate stays held through the selection transition so the
            // update()-triggered reconcile cannot start a second load probe.
            await migrateLegacySelectionIfNeeded(record: record, to: model)
            let legacyStillSelected = snapshot.provider == .onDevice && record.legacy.contains { $0.id == snapshot.modelID }
            await modelStore.migrationLoadValidated(legacyStillSelected: legacyStillSelected)
            migrationValidationStarted = false
        case .awaitingLegacyRelease:
            let stillUsed = snapshot.provider == .onDevice && record.legacy.contains { $0.id == snapshot.modelID }
            if !stillUsed { await modelStore.migrationLegacyReleased() }
        case .cleanupPending:
            await modelStore.retryLegacyCleanup()
            let status = await modelStore.migrationStatus()
            if let key = status.cleanupFailureKey {
                // Cleanup failed: the stage stays retryable and the user is
                // told the old pack could not be removed yet.
                localMigrationNote = key
            } else if status.record == nil {
                localMigrationNote = nil
            }
        }
        await refreshLocalSpeechState()
    }

    /// Re-sync published state after a direct store mutation (e.g. pack
    /// removal from the detail view) without waiting for the next pump tick.
    func refreshAfterExternalChange() async { await refreshLocalSpeechState() }

    private func refreshLocalSpeechState() async {
        let installation = await modelStore.state()
        if installation != localInstallation { localInstallation = installation }
        if localVisibleModels.isEmpty {
            do { localVisibleModels = try await modelStore.visibleCatalog() }
            catch { localCatalogErrorKey = "voice.local.error.catalog" }
            if !localVisibleModels.isEmpty { localCatalogErrorKey = nil }
        }
        if !localVisibleModels.isEmpty {
            var installed = Set<String>()
            for model in localVisibleModels {
                if await modelStore.isInstalled(model) { installed.insert(model.id) }
            }
            if installed != localInstalledModelIDs { localInstalledModelIDs = installed }
            let all = (try? await modelStore.catalog()) ?? []
            let managed = all.filter { !$0.isHidden || installed.contains($0.id) }
            if managed != localManagedModels { localManagedModels = managed }
        }
        await updateLocalProgressOperation()
    }

    /// Derives the single visible migration progress step (if any) from the
    /// durable stage. A blocked validation (failed note + explicit retry)
    /// resolves to the honest installed state with the error shown beneath,
    /// rather than an endless spinner; cleanup stays shown even when retrying.
    private func updateLocalProgressOperation() async {
        let status = await modelStore.migrationStatus()
        var next: LocalProgressOperation?
        if let record = status.record {
            switch record.stage {
            case .awaitingLoadValidation:
                if localMigrationNote != "voice.local.error.verify" {
                    next = LocalProgressOperation(modelID: record.newModelID, key: "voice.local.progress.checking")
                }
            case .cleanupPending:
                if let legacy = record.legacy.first {
                    next = LocalProgressOperation(modelID: legacy.id, key: "voice.local.progress.removing")
                }
            default:
                break
            }
        }
        if next != localProgressOperation { localProgressOperation = next }
    }

    func select(_ provider: TTSSpeakerProvider) {
        guard provider != snapshot.provider else { return }
        let route = provider.supportedBillingRoutes.first ?? .payAsYouGo
        restore(provider, route: route)
    }

    func select(_ route: TTSBillingRoute) {
        guard snapshot.provider.supportedBillingRoutes.contains(route), route != snapshot.billingRoute else { return }
        restore(snapshot.provider, route: route)
    }

    private func restore(_ provider: TTSSpeakerProvider, route: TTSBillingRoute) {
        var next = profiles[binding(provider, route)] ?? TTSSettingsSnapshot(provider: provider, billingRoute: route)
        next.autoReadEnabled = snapshot.autoReadEnabled
        next.allowBargeIn = snapshot.allowBargeIn
        update { $0 = next }
    }

    private func binding(_ provider: TTSSpeakerProvider, _ route: TTSBillingRoute) -> String {
        "\(provider.rawValue).\(route.rawValue)"
    }

    func saveCredential(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TTSSettingsFailure.missingCredential }
        try keychain.store(account: account(snapshot), secret: Data(value.utf8))
        update { $0.connectionProviderID = nil }
    }

    func deleteCredential() throws { try keychain.delete(account: account(snapshot)) }

    var hasDedicatedCredential: Bool { (try? keychain.read(account: account(snapshot)))?.isEmpty == false }

    func credential(for settings: TTSSettingsSnapshot) async throws -> String {
        guard settings.provider.requiresCloudCredential else { return "" }
        if let id = settings.connectionProviderID { return try await resolveConnection(id) }
        guard let data = try? keychain.read(account: account(settings)),
              let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw TTSSynthesisError.credentialMissing(provider: settings.provider, route: settings.billingRoute)
        }
        return value
    }

    private func account(_ settings: TTSSettingsSnapshot) -> String {
        "tts.\(settings.provider.rawValue).\(settings.billingRoute.rawValue)"
    }
}

enum TTSSettingsFailure: Error { case missingCredential }

/// Freeze configuration for a spoken answer. Settings changes apply to the next
/// answer; an in-flight segment cannot silently move provider or billing route.
@MainActor
struct ConfiguredTTSSpeechSource {
    let snapshot: TTSSettingsSnapshot
    let settings: TTSSettingsService
    let service: TTSSpeechService
    var overrideCredential: String? = nil

    func synthesize(text: String, sessionID: UUID, segmentIndex: Int) -> TTSAudioChunkStream {
        let (stream, sender) = TTSAudioChunkStream.make()
        let request = TTSSynthesisRequest(
            sessionID: sessionID, segmentIndex: segmentIndex,
            provider: snapshot.provider, billingRoute: snapshot.billingRoute,
            region: snapshot.alibabaRegion, modelID: snapshot.modelID,
            voiceID: snapshot.voiceID, text: text, speechRateRatio: snapshot.speechRateRatio, language: snapshot.language
        )
        let producer = Task { @MainActor in
            do {
                let credential: String
                if let overrideCredential { credential = overrideCredential }
                else { credential = try await settings.credential(for: snapshot) }
                try Task.checkCancellation()
                for try await chunk in service.synthesize(request, credential: credential) {
                    try Task.checkCancellation()
                    try await sender.send(chunk)
                }
                sender.finish()
            } catch { sender.finish(throwing: error) }
        }
        sender.attach(producer)
        return stream
    }
}
#endif
