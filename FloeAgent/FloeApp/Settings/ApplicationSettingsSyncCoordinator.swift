// Secret-free settings projection over the existing configuration engine.
// This service owns observation; views do not own synchronization work.
#if canImport(UIKit) && canImport(CloudKit)
import Foundation
import Combine
import FloeCore
import FloePersistence
import FloeSync

@MainActor
final class ApplicationSettingsSyncCoordinator {
    private static let baselineKey = "sync.application-settings.materialized.v1"
    private static let bootstrapCompleteKey = "sync.application-settings.bootstrap-complete.v1"
    private static let ttsSettingsKey = "voice.output.settings.v1"
    private static let ttsProfilesKey = "voice.output.profiles.v1"
    private static let ttsNamesKey = "voice.output.voiceNames.v1"
    private static let assistantKey = "voice.assistantAudio.v1"
    private let sync: ConfigSyncEngine
    private let settings: SQLiteSettingsStore
    private let defaults: UserDefaults
    private let asr: CloudASRSettingsStore
    private let prepareLegacyTTS: @MainActor () async -> Int
    private var observers: [AnyCancellable] = []
    private var baseline: [String: Data]
    private var started = false
    private var starting = false
    private var lastPassSucceeded = true
    private var requested = false
    private var worker: Task<Void, Never>?

    init(sync: ConfigSyncEngine, settings: SQLiteSettingsStore,
         defaults: UserDefaults = .standard, asr: CloudASRSettingsStore = .shared,
         prepareLegacyTTS: (@MainActor () async -> Int)? = nil) {
        self.sync = sync; self.settings = settings; self.defaults = defaults; self.asr = asr
        self.prepareLegacyTTS = prepareLegacyTTS ?? {
            await SpeechCredentialStore.prepareTTSLegacyBindings(defaults: defaults)
        }
        baseline = defaults.data(forKey: Self.baselineKey)
            .flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) } ?? [:]
    }
    deinit { worker?.cancel() }

    /// Called before the first CloudKit fetch. Freeze LOCAL legacy origins
    /// before remote metadata can arrive, then stage the old values at epoch
    /// zero so a new device's defaults never beat actual cloud edits.
    func start() async {
        guard !started, !starting else { return }
        starting = true
        defer { starting = false }
        for name in [UserDefaults.didChangeNotification, SpeechCredentialBinding.localSettingsChanged] {
            observers.append(NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main).sink { [weak self] _ in
                    Task { @MainActor [weak self] in self?.requestWork() }
                })
        }
        SpeechCredentialStore.captureLocalTTSOrigins(defaults: defaults)
        let asrFailures = await asr.prepareLocalCredentialBindings()
        let ttsFailures = await prepareLegacyTTS()
        let failures = asrFailures + ttsFailures
        do {
            let initial = !defaults.bool(forKey: Self.bootstrapCompleteKey)
            try await captureLocalChanges(initial: initial)
            try await materializePersistedSettings()
            lastPassSucceeded = failures == 0
            if failures > 0 { await sync.reportApplicationSettingsFailure() }
        } catch { lastPassSucceeded = false; await sync.reportApplicationSettingsFailure() }
        started = true
        if requested { requestWork() }
    }

    @discardableResult
    func prepareLegacyCredentials() async -> Int {
        let asrFailures = await asr.prepareLocalCredentialBindings()
        let ttsFailures = await prepareLegacyTTS()
        let failures = asrFailures + ttsFailures
        if failures > 0 { await sync.reportApplicationSettingsFailure() }
        return failures
    }

    /// Explicit sync and inbound fan-out share the same serialized projection.
    /// Every pass captures new local edits before applying a remote snapshot.
    @discardableResult
    func flush() async -> Bool {
        guard started else { return false }
        requestWork()
        await worker?.value
        return lastPassSucceeded
    }
    private func requestWork() {
        requested = true
        guard started, worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.requested, !Task.isCancelled {
                self.requested = false
                do {
                    try await self.captureLocalChanges(initial: !self.defaults.bool(forKey: Self.bootstrapCompleteKey))
                    try await self.materializePersistedSettings()
                    self.lastPassSucceeded = true
                } catch { self.lastPassSucceeded = false; await self.sync.reportApplicationSettingsFailure() }
            }
            self.worker = nil
        }
    }

    private func saveBaseline() throws {
        defaults.set(try ApplicationSettingRecord.encodeValue(baseline), forKey: Self.baselineKey)
    }
    private func captureLocalChanges(initial: Bool) async throws {
        let current = try await snapshot()
        let keys = initial ? Set(current.values.keys) : Set(current.values.keys).union(baseline.keys)
        for key in keys.sorted() where current.values[key] != baseline[key] || (initial && current.values[key] != nil) {
            let value = ApplicationSettingRecord(key: key, value: current.values[key],
                updatedAt: initial ? Date(timeIntervalSince1970: 0) : Date())
            try await sync.saveApplicationSetting(value)
            if baseline[key] != current.values[key] {
                baseline[key] = current.values[key]
                try saveBaseline()
            }
        }
        // A partially persisted per-key baseline is NOT a completed import.
        // Only the entire epoch-zero batch (including an empty install) may
        // complete bootstrap. All retries before this point keep epoch zero.
        if defaults.object(forKey: Self.baselineKey) == nil { try saveBaseline() }
        if initial { defaults.set(true, forKey: Self.bootstrapCompleteKey) }
    }

    private struct Snapshot {
        var values: [String: Data]
        var database: [String: String]
    }
    private func snapshot() async throws -> Snapshot {
        let database = try await settings.allValues()
        var values: [String: Data] = [:]
        func put(_ key: String, _ data: Data) throws {
            let canonical = try ApplicationSettingPolicy.canonicalValue(data, for: key)
            if let old = values[key], old != canonical {
                throw FloeError.invalidConfiguration("Ambiguous portable settings")
            }
            values[key] = canonical
        }
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: CloudASRSettingsStore.storageKey) {
            let state = try decoder.decode(CloudASRSettingsStore.PersistedState.self, from: data)
            guard state.schemaVersion == 1, state.profiles.count <= 256,
                  Set(state.profiles.map(\.id)).count == state.profiles.count else {
                throw FloeError.invalidConfiguration("Invalid recognition settings")
            }
            for var profile in state.profiles {
                profile.credentialReference = nil
                try put(ApplicationSettingPolicy.asrKey(profile.id), ApplicationSettingRecord.encodeValue(profile))
            }
            try put(ApplicationSettingPolicy.asrSelection, ApplicationSettingRecord.encodeValue(
                SyncedASRSelection(primaryProfileID: state.primaryProfileID, legacyAliasProfileID: state.legacyAliasProfileID)))
        }
        if let data = defaults.data(forKey: Self.ttsProfilesKey) {
            let profiles = try decoder.decode([String: TTSSettingsSnapshot].self, from: data)
            guard profiles.count <= 256 else { throw FloeError.invalidConfiguration("Too many speech profiles") }
            for value in profiles.values {
                try put(ApplicationSettingPolicy.ttsProfilePrefix + ApplicationSettingPolicy.ttsBucket(value),
                    ApplicationSettingRecord.encodeValue(value))
            }
        }
        if let data = defaults.data(forKey: Self.ttsSettingsKey) { try put(ApplicationSettingPolicy.ttsSelection, data) }
        if let names = defaults.dictionary(forKey: Self.ttsNamesKey) as? [String: String] {
            try put(ApplicationSettingPolicy.ttsVoiceNames, ApplicationSettingRecord.encodeValue(names))
        }
        if let data = defaults.data(forKey: Self.assistantKey) {
            let value = try decoder.decode(AssistantAudioPreferences.self, from: data)
            try put(ApplicationSettingPolicy.audioPriorities, ApplicationSettingRecord.encodeValue(
                SyncedAssistantAudioPriorities(transcriptionPriority: value.transcriptionPriority,
                    synthesisPriority: value.synthesisPriority)))
        }
        for raw in ApplicationSettingPolicy.defaultsKeys {
            guard let object = defaults.object(forKey: raw) else { continue }
            let data = ApplicationSettingPolicy.dataDefaultsKeys.contains(raw)
                ? (object as? Data) : try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .sortedKeys])
            guard let data else { throw FloeError.invalidConfiguration("Invalid settings value") }
            try put(ApplicationSettingPolicy.defaultsPrefix + raw, data)
        }
        for raw in ApplicationSettingPolicy.databaseKeys {
            if let json = database[raw] { try put(ApplicationSettingPolicy.databasePrefix + raw, Data(json.utf8)) }
        }
        return Snapshot(values: values, database: database)
    }

    private func materializePersistedSettings() async throws {
        // Profiles precede selections, but their independent records do not
        // silently edit a selection while CloudKit is delivering that row.
        let records = try await sync.applicationSettings().sorted {
            let a = Self.selectionKeys.contains($0.key), b = Self.selectionKeys.contains($1.key)
            return a == b ? $0.key < $1.key : !a
        }
        for record in records {
            let value = try record.validated()
            let current = try await snapshot()
            guard current.values[value.key] == baseline[value.key] else {
                requested = true; continue // a newer UI edit owns this value
            }
            let projected = try projectedValue(value)
            guard current.values[value.key] != projected else { continue }
            if value.key.hasPrefix(ApplicationSettingPolicy.databasePrefix) {
                let raw = String(value.key.dropFirst(ApplicationSettingPolicy.databasePrefix.count))
                let json = value.value.flatMap { String(data: $0, encoding: .utf8) }
                guard try await settings.compareAndSetValue(json, forKey: raw, expecting: current.database[raw]) else {
                    requested = true; continue
                }
            } else {
                try applyDefaults(value)
                if ApplicationSettingPolicy.profileID(value.key) != nil,
                   current.values[ApplicationSettingPolicy.asrSelection] == nil {
                    // A received profile creates the aggregate locally. Its
                    // nil pointer is not a new user selection or a remote
                    // selection deletion while that separate record arrives.
                    baseline[ApplicationSettingPolicy.asrSelection] = try ApplicationSettingRecord.encodeValue(
                        SyncedASRSelection(primaryProfileID: nil, legacyAliasProfileID: nil))
                }
            }
            baseline[value.key] = projected
            try saveBaseline()
        }
        asr.reloadSynchronizedPreferences()
        NotificationCenter.default.post(name: SpeechCredentialBinding.settingsApplied, object: nil)
    }
    private func projectedValue(_ value: ApplicationSettingRecord) throws -> Data? {
        if let data = value.value { return data }
        // Aggregates represent "unset" as empty fields. Keep the wire
        // tombstone, but baseline that actual projection so it cannot echo
        // back as a fresh user edit or repeatedly reapply itself.
        if value.key == ApplicationSettingPolicy.asrSelection {
            return try ApplicationSettingRecord.encodeValue(SyncedASRSelection(primaryProfileID: nil, legacyAliasProfileID: nil))
        }
        if value.key == ApplicationSettingPolicy.audioPriorities {
            return try ApplicationSettingRecord.encodeValue(SyncedAssistantAudioPriorities(transcriptionPriority: [], synthesisPriority: []))
        }
        return nil
    }
    private static let selectionKeys: Set<String> = [ApplicationSettingPolicy.asrSelection, ApplicationSettingPolicy.ttsSelection]

    private func applyDefaults(_ record: ApplicationSettingRecord) throws {
        let key = record.key, data = record.value, decoder = JSONDecoder()
        if let id = ApplicationSettingPolicy.profileID(key) {
            var state = try asrState()
            if let data {
                var profile = try decoder.decode(ASRProfile.self, from: data)
                let account = SpeechCredentialBinding.asrAccount(profile)
                try SpeechCredentialStore(service: SpeechCredentialBinding.asrService, defaults: defaults).register(account: account)
                let old = state.profiles.first { $0.id == id }
                profile.credentialReference = old.flatMap {
                    SpeechCredentialBinding.asrAccount($0) == account ? $0.credentialReference : nil
                } ?? ASRCredentialReference(service: SpeechCredentialBinding.asrService, account: account)
                state.profiles.removeAll { $0.id == id }; state.profiles.append(profile)
            } else { state.profiles.removeAll { $0.id == id } }
            // In particular, do not clear or invent the primary selection.
            try saveASR(state); return
        }
        if key == ApplicationSettingPolicy.asrSelection {
            var state = try asrState()
            let value = try data.map { try decoder.decode(SyncedASRSelection.self, from: $0) }
            state.primaryProfileID = value?.primaryProfileID; state.legacyAliasProfileID = value?.legacyAliasProfileID
            try saveASR(state); return
        }
        if key.hasPrefix(ApplicationSettingPolicy.ttsProfilePrefix) {
            var profiles = try defaults.data(forKey: Self.ttsProfilesKey)
                .map { try decoder.decode([String: TTSSettingsSnapshot].self, from: $0) } ?? [:]
            let oldKeys = profiles.filter {
                ApplicationSettingPolicy.ttsProfilePrefix + ApplicationSettingPolicy.ttsBucket($0.value) == key
            }.map(\.key)
            for old in oldKeys { profiles.removeValue(forKey: old) }
            if let data {
                let value = try decoder.decode(TTSSettingsSnapshot.self, from: data)
                try registerTTSAccount(value)
                let bucket = value.provider == .onDevice && !value.modelID.isEmpty
                    ? "onDevice." + value.modelID : value.provider.rawValue + "." + value.billingRoute.rawValue
                profiles[bucket] = value
            }
            defaults.set(try ApplicationSettingRecord.encodeValue(profiles), forKey: Self.ttsProfilesKey); return
        }
        if key == ApplicationSettingPolicy.ttsSelection {
            if let data { try registerTTSAccount(decoder.decode(TTSSettingsSnapshot.self, from: data)) }
            defaults.set(data, forKey: Self.ttsSettingsKey); return
        }
        if key == ApplicationSettingPolicy.ttsVoiceNames {
            if let data { defaults.set(try decoder.decode([String: String].self, from: data), forKey: Self.ttsNamesKey) }
            else { defaults.removeObject(forKey: Self.ttsNamesKey) }
            return
        }
        if key == ApplicationSettingPolicy.audioPriorities {
            var preferences = try defaults.data(forKey: Self.assistantKey)
                .map { try decoder.decode(AssistantAudioPreferences.self, from: $0) } ?? AssistantAudioPreferences()
            let value = try data.map { try decoder.decode(SyncedAssistantAudioPriorities.self, from: $0) }
            preferences.transcriptionPriority = value?.transcriptionPriority ?? []
            preferences.synthesisPriority = value?.synthesisPriority ?? []
            defaults.set(try ApplicationSettingRecord.encodeValue(preferences), forKey: Self.assistantKey); return
        }
        let raw = String(key.dropFirst(ApplicationSettingPolicy.defaultsPrefix.count))
        if let data {
            if ApplicationSettingPolicy.dataDefaultsKeys.contains(raw) { defaults.set(data, forKey: raw) }
            else { defaults.set(try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed), forKey: raw) }
        } else { defaults.removeObject(forKey: raw) }
    }
    private func registerTTSAccount(_ value: TTSSettingsSnapshot) throws {
        if value.provider.requiresCloudCredential, value.connectionProviderID == nil {
            try SpeechCredentialStore(service: SpeechCredentialBinding.ttsService, defaults: defaults)
                .register(account: SpeechCredentialBinding.ttsAccount(value))
        }
    }
    private func asrState() throws -> CloudASRSettingsStore.PersistedState {
        try defaults.data(forKey: CloudASRSettingsStore.storageKey)
            .map { try JSONDecoder().decode(CloudASRSettingsStore.PersistedState.self, from: $0) } ?? .empty
    }
    private func saveASR(_ input: CloudASRSettingsStore.PersistedState) throws {
        var state = input; state.schemaVersion = 1; state.migrationCompleted = true
        defaults.set(try ApplicationSettingRecord.encodeValue(state), forKey: CloudASRSettingsStore.storageKey)
    }
}
#endif
