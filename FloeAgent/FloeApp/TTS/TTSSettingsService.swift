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
        // Persisted rate/pitch are normalized here (finite + in range) so an
        // arbitrary caller can never store a value a player would have to
        // repair again. The snapshot's own initializer applies the same rule.
        let controls = TTSPlaybackControls(
            speechRateRatio: value.speechRateRatio,
            speechPitchSemitones: value.speechPitchSemitones)
        value.speechRateRatio = controls.speechRateRatio
        value.speechPitchSemitones = controls.speechPitchSemitones
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
        // The compatible-endpoint override belongs to the OpenAI route only.
        // Canonicalize (or reject) it here, before the credential or the
        // profile is written; other providers always store nil so their
        // persisted shape and dispatch stay unchanged.
        if saved.provider == .openAI {
            saved.openAIBaseURL = try TTSOpenAISpeechEndpoint.normalized(saved.openAIBaseURL)
        } else {
            saved.openAIBaseURL = nil
        }
        let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        // A key issued by one service is never silently reused for another:
        // a host/port change requires entering the new service's key even
        // when a dedicated key or a reused connection is already stored.
        // Path-only changes on the same origin keep the stored key.
        if saved.provider == .openAI, key.isEmpty,
           TTSOpenAISpeechEndpoint.originChanged(
               from: profiles[profileID(saved)]?.openAIBaseURL, to: saved.openAIBaseURL) {
            throw TTSSettingsFailure.credentialChangedRequiresNewKey
        }
        if !key.isEmpty { try keychain.store(account: account(saved), secret: Data(key.utf8)); saved.connectionProviderID = nil }
        guard hasCredential(for: saved) || saved.connectionProviderID != nil else { throw TTSSettingsFailure.missingCredential }
        objectWillChange.send()
        profiles[profileID(saved)] = saved
        defaults.set(try JSONEncoder().encode(profiles), forKey: Self.profilesKey)
        if snapshot.provider == saved.provider && snapshot.billingRoute == saved.billingRoute {
            // Saving the ACTIVE service updates its voice/model but keeps the
            // user's live global controls: the editor's profile copy may carry
            // older rate/pitch values than the ones the user just set.
            applyGlobalControls(to: &saved)
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
        applyGlobalControls(to: &chosen)
        update { $0 = chosen }
    }

    /// The four user-facing output controls live above any single provider
    /// profile. Selecting a voice, switching provider/route, or saving the
    /// active service must never silently reset them (which building a value
    /// from `.systemDefault` or an older saved profile would do).
    private func applyGlobalControls(to value: inout TTSSettingsSnapshot) {
        value.autoReadEnabled = snapshot.autoReadEnabled
        value.allowBargeIn = snapshot.allowBargeIn
        value.speechRateRatio = snapshot.speechRateRatio
        value.speechPitchSemitones = snapshot.speechPitchSemitones
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
        case .complete:
            pendingLocalMigration = false
            localMigrationNote = nil
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
        applyGlobalControls(to: &next)
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
        // Draft previews and in-flight snapshots must not carry a stored key
        // across origins, even before an edited profile is saved.
        if settings.provider == .openAI,
           TTSOpenAISpeechEndpoint.originChanged(
               from: profiles[profileID(settings)]?.openAIBaseURL,
               to: settings.openAIBaseURL) {
            throw TTSSettingsFailure.credentialChangedRequiresNewKey
        }
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

enum TTSSettingsFailure: Error { case missingCredential; case credentialChangedRequiresNewKey }

/// One utterance segment's forwarding channel plus its explicit close handle.
///
/// Consumers close it on every exit (EOF, failure, stall, cancellation). The
/// close is idempotent and is what wakes a producer that is parked on a full
/// channel after the consumer stopped taking chunks; without it the forwarder
/// outlives the utterance and the next local session join never returns.
@MainActor
struct TTSConfiguredStream {
    let stream: TTSAudioChunkStream
    /// Frozen user playback controls for this segment. Immutable on purpose: a
    /// later settings edit can never change audio already in flight, and both
    /// output paths (ordinary answer player, continuous voice) read the SAME
    /// value. Callers that build a stream directly keep the default neutral so
    /// their output is unchanged (see the frozen cross-stage contract).
    let playbackControls: TTSPlaybackControls
    private let close: @Sendable () -> Void

    init(stream: TTSAudioChunkStream,
         playbackControls: TTSPlaybackControls = .neutral,
         close: @escaping @Sendable () -> Void) {
        self.stream = stream
        self.playbackControls = playbackControls
        self.close = close
    }

    func closeStream() { close() }

    /// Wraps a routed provider stream into an explicitly closable segment.
    static func make(request: TTSSynthesisRequest,
                     playbackControls: TTSPlaybackControls = .neutral,
                     credential: @escaping @MainActor @Sendable () async throws -> String,
                     service: TTSSpeechService) -> TTSConfiguredStream {
        let (stream, sender) = TTSAudioChunkStream.make()
        let producer = Task { @MainActor in
            do {
                // Configuration (including the frozen OpenAI-compatible
                // endpoint) is validated before the credential is resolved:
                // an unusable request must report its configuration problem
                // and never read or hand off a key.
                if let problem = request.validationProblem() {
                    throw TTSSynthesisError.invalidConfiguration(problem)
                }
                let value = try await credential()
                try Task.checkCancellation()
                for try await chunk in service.synthesize(request, credential: value) {
                    try Task.checkCancellation()
                    // Cooperative: a cancelled forwarder closes its own
                    // channel so a parked send can never outlive the segment.
                    try await CancellableSpeechSend.send(chunk, sender: sender)
                }
                sender.finish()
            } catch { sender.finish(throwing: error) }
        }
        sender.attach(producer)
        return TTSConfiguredStream(
            stream: stream,
            playbackControls: playbackControls,
            close: { sender.finish(throwing: TTSSynthesisError.cancelled) })
    }
}

/// Freeze configuration for a spoken answer. Settings changes apply to the next
/// answer; an in-flight segment cannot silently move provider or billing route,
/// and an in-flight segment's rate/pitch is carried frozen on the stream.
@MainActor
struct ConfiguredTTSSpeechSource {
    let snapshot: TTSSettingsSnapshot
    let settings: TTSSettingsService
    let service: TTSSpeechService
    var overrideCredential: String? = nil

    func synthesize(text: String, sessionID: UUID, segmentIndex: Int) -> TTSConfiguredStream {
        let request = Self.makeRequest(
            snapshot: snapshot, text: text, sessionID: sessionID,
            segmentIndex: segmentIndex)
        let settings = self.settings
        let snapshot = self.snapshot
        let overrideCredential = self.overrideCredential
        let credential: @MainActor @Sendable () async throws -> String = {
            if let overrideCredential { return overrideCredential }
            return try await settings.credential(for: snapshot)
        }
        return TTSConfiguredStream.make(
            request: request,
            playbackControls: snapshot.playbackControls,
            credential: credential,
            service: service)
    }

    /// Neutral-generation seam (frozen cross-stage contract): the provider
    /// request always carries rate 1.0 and requests never gain a pitch
    /// parameter. The user's rate/pitch travel on the returned stream and are
    /// applied exactly once by the shared output DSP, so a provider knob and
    /// the DSP can never scale the same utterance twice. Direct provider
    /// callers that build `TTSSynthesisRequest` themselves keep the explicit
    /// rate semantics documented on that type.
    static func makeRequest(
        snapshot: TTSSettingsSnapshot,
        text: String,
        sessionID: UUID,
        segmentIndex: Int
    ) -> TTSSynthesisRequest {
        TTSSynthesisRequest(
            sessionID: sessionID, segmentIndex: segmentIndex,
            provider: snapshot.provider, billingRoute: snapshot.billingRoute,
            region: snapshot.alibabaRegion, openAIBaseURL: snapshot.openAIBaseURL,
            modelID: snapshot.modelID,
            voiceID: snapshot.voiceID, text: text,
            speechRateRatio: TTSPlaybackControls.neutralRate,
            language: snapshot.language
        )
    }
}
#endif
