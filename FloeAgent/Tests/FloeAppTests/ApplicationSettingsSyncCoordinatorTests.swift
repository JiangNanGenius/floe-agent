#if canImport(UIKit) && canImport(CloudKit)
import Foundation
import XCTest
import CloudKit
import GRDB
import FloeCore
import FloeSecurity
import FloePersistence
@testable import FloeSync
@testable import FloeApp

@MainActor
final class ApplicationSettingsSyncCoordinatorTests: XCTestCase {
    private struct Fixture {
        let suite: String
        let defaults: UserDefaults
        let database: DatabaseManager
        let store: ModelConfigurationStore
        let metadata: ConfigSyncMetadataStore
        let settings: SQLiteSettingsStore
        let engine: ConfigSyncEngine
        let asr: CloudASRSettingsStore
        let keys: PortableSettingsFakeKeychain
        let coordinator: ApplicationSettingsSyncCoordinator
    }
    private func fixture() async throws -> Fixture {
        let suite = "portable-settings-app." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let store = ModelConfigurationStore(database: database), metadata = ConfigSyncMetadataStore(database: database)
        let settings = SQLiteSettingsStore(database: database)
        let engine = ConfigSyncEngine(configurationStore: store, metadataStore: metadata)
        let keys = PortableSettingsFakeKeychain()
        let asr = CloudASRSettingsStore(defaults: defaults, keychain: keys, legacyKeychain: keys)
        let coordinator = ApplicationSettingsSyncCoordinator(sync: engine, settings: settings,
            defaults: defaults, asr: asr, prepareLegacyTTS: { 0 })
        return Fixture(suite: suite, defaults: defaults, database: database, store: store, metadata: metadata,
            settings: settings, engine: engine, asr: asr, keys: keys, coordinator: coordinator)
    }
    private func deliver(_ value: ApplicationSettingRecord, to target: Fixture) async throws {
        let record = CKRecord(recordType: "ApplicationSetting", recordID: .init(recordName: value.recordID))
        record.encryptedValues["payload"] = try ApplicationSettingRecord.encodeValue(value) as CKRecordValue
        record.encryptedValues["fieldTimestamps"] = try ApplicationSettingRecord.encodeValue(
            ["key": value.updatedAt, "schemaVersion": value.updatedAt, "value": value.updatedAt, "updatedAt": value.updatedAt]) as CKRecordValue
        _ = try await target.engine.applyRemote(record)
    }

    func testSpeechProfileArrivalKeepsSelectionIndependentAndNeverReusesOldOriginKey() async throws {
        let f = try await fixture(); defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let original = try f.asr.addProfile(.openAICompatible(name: "Synthetic local",
            fileEndpoint: "https://one.example.test/v1", liveEndpoint: nil), credential: "synthetic-original-key")
        await f.coordinator.start()
        var remote = original; remote.fileEndpoint = "https://two.example.test/v1"; remote.credentialReference = nil
        try await deliver(.init(key: ApplicationSettingPolicy.asrKey(remote.id),
            value: ApplicationSettingRecord.encodeValue(remote), updatedAt: Date().addingTimeInterval(10)), to: f)
        await f.coordinator.flush()
        let imported = try XCTUnwrap(f.asr.profile(id: remote.id))
        XCTAssertEqual(imported.fileEndpoint, remote.fileEndpoint)
        XCTAssertFalse(f.asr.hasCredential(for: imported))
        XCTAssertEqual(try f.keys.read(account: SpeechCredentialBinding.asrAccount(original)), Data("synthetic-original-key".utf8))
        try f.keys.store(account: SpeechCredentialBinding.asrAccount(remote), secret: Data("synthetic-new-origin-key".utf8))
        await f.coordinator.flush() // same fan-out as a late-Keychain event
        XCTAssertTrue(f.asr.hasCredential(for: imported))

        let fresh = try await fixture(); defer { fresh.defaults.removePersistentDomain(forName: fresh.suite) }
        await fresh.coordinator.start()
        try await deliver(.init(key: ApplicationSettingPolicy.asrKey(remote.id),
            value: ApplicationSettingRecord.encodeValue(remote)), to: fresh)
        await fresh.coordinator.flush()
        let selectionBefore = try await fresh.metadata.metadata(recordType: "ApplicationSetting",
            recordID: ApplicationSettingRecord.recordPrefix + ApplicationSettingPolicy.asrSelection)
        XCTAssertNil(selectionBefore, "A profile delivery must not publish a synthesized nil selection")
        let selection = SyncedASRSelection(primaryProfileID: remote.id, legacyAliasProfileID: nil)
        try await deliver(.init(key: ApplicationSettingPolicy.asrSelection,
            value: ApplicationSettingRecord.encodeValue(selection)), to: fresh)
        await fresh.coordinator.flush()
        XCTAssertEqual(fresh.asr.primaryProfileID, remote.id)
        try await deliver(.init(key: ApplicationSettingPolicy.asrKey(remote.id), value: nil,
            updatedAt: Date().addingTimeInterval(20)), to: fresh)
        await fresh.coordinator.flush()
        XCTAssertNil(fresh.asr.profile(id: remote.id))
        XCTAssertEqual(fresh.asr.primaryProfileID, remote.id, "Deletion does not rewrite the independent selection record")
        let clear = ApplicationSettingRecord(key: ApplicationSettingPolicy.asrSelection, value: nil,
            updatedAt: Date().addingTimeInterval(30))
        try await deliver(clear, to: fresh)
        await fresh.coordinator.flush(); await fresh.coordinator.flush()
        XCTAssertNil(fresh.asr.primaryProfileID)
        let clearSaved = try await fresh.store.applicationSetting(key: clear.key)
        XCTAssertNil(clearSaved?.value, "An aggregate's empty projection cannot resurrect a wire tombstone")
        let clearMetadata = try await fresh.metadata.metadata(recordType: "ApplicationSetting", recordID: clear.recordID)
        XCTAssertNil(clearMetadata?.pendingAction)
    }

    func testTTSQuestionAndDatabasePreferencesRestoreWithoutDeviceStateOrOutboundEcho() async throws {
        let source = try await fixture(), target = try await fixture()
        defer { source.defaults.removePersistentDomain(forName: source.suite); target.defaults.removePersistentDomain(forName: target.suite) }
        let voice = TTSSettingsSnapshot(provider: .alibaba, billingRoute: .tokenPlan, modelID: "custom-model",
            voiceID: "custom-voice", speechRateRatio: 1.5, speechPitchSemitones: -2, language: "en-US")
        source.defaults.set(try ApplicationSettingRecord.encodeValue(voice), forKey: "voice.output.settings.v1")
        source.defaults.set(try ApplicationSettingRecord.encodeValue(["alibaba.tokenPlan": voice]), forKey: "voice.output.profiles.v1")
        source.defaults.set(Data("{\"optionalTimeoutSeconds\":35}".utf8), forKey: "floe.settings.userQuestionDefaults.v1")
        source.defaults.set(true, forKey: "voice.output.firstInstallSelection")
        source.defaults.set("/synthetic/device/path", forKey: "linux.runtime.root")
        try await source.settings.setValue("120", forKey: AppSettingsKey.executionTimeoutSeconds)
        await source.coordinator.start(); await target.coordinator.start()
        let records = try await source.store.applicationSettings()
        XCTAssertFalse(records.contains { $0.key.contains("firstInstall") || $0.key.contains("runtime.root") })
        for value in records { try await deliver(value, to: target) }
        await target.coordinator.flush()
        let savedVoice = try XCTUnwrap(target.defaults.data(forKey: "voice.output.settings.v1"))
        XCTAssertEqual(try JSONDecoder().decode(TTSSettingsSnapshot.self, from: savedVoice), voice)
        XCTAssertEqual(target.defaults.data(forKey: "floe.settings.userQuestionDefaults.v1"), Data("{\"optionalTimeoutSeconds\":35}".utf8))
        let timeout = try await target.settings.value(forKey: AppSettingsKey.executionTimeoutSeconds)
        XCTAssertEqual(timeout, "120")
        XCTAssertNil(target.defaults.object(forKey: "voice.output.firstInstallSelection"))
        XCTAssertNil(target.defaults.object(forKey: "linux.runtime.root"))
        let before = try await target.store.applicationSettings()
        await target.coordinator.flush()
        let after = try await target.store.applicationSettings()
        XCTAssertEqual(before, after, "Materializing cloud values is not a new local edit")
        let pending = try await target.metadata.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testUncapturedLocalEditWinsAndRestartRetainsTheSyncedBaseline() async throws {
        let f = try await fixture(); defer { f.defaults.removePersistentDomain(forName: f.suite) }
        f.defaults.set("en", forKey: "floe.settings.language")
        await f.coordinator.start()
        let remote = ApplicationSettingRecord(key: "defaults.floe.settings.language", value: Data("\"zhHans\"".utf8),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await deliver(remote, to: f)
        f.defaults.set("system", forKey: "floe.settings.language")
        await f.coordinator.flush()
        XCTAssertEqual(f.defaults.string(forKey: "floe.settings.language"), "system")
        let saved = try await f.store.applicationSetting(key: remote.key)
        XCTAssertEqual(saved?.value, Data("\"system\"".utf8))
        let restarted = ApplicationSettingsSyncCoordinator(sync: f.engine, settings: f.settings,
            defaults: f.defaults, asr: f.asr, prepareLegacyTTS: { 0 })
        await restarted.start(); await restarted.flush()
        let after = try await f.store.applicationSetting(key: remote.key)
        XCTAssertEqual(after, saved)
        XCTAssertEqual(f.defaults.string(forKey: "floe.settings.language"), "system")
    }
    func testExplicitSpeechDeletionCannotReviveLegacyInReloadedServices() async throws {
        let f = try await fixture(); defer { f.defaults.removePersistentDomain(forName: f.suite) }
        let voice = TTSSettingsSnapshot(provider: .openAI, modelID: "tts-1", voiceID: "alloy")
        f.defaults.set(try ApplicationSettingRecord.encodeValue(voice), forKey: "voice.output.settings.v1")
        f.defaults.set(try ApplicationSettingRecord.encodeValue(["openAI.payAsYouGo": voice]), forKey: "voice.output.profiles.v1")
        let legacyTTS = Data("synthetic-kept-old-TTS".utf8)
        try f.keys.store(account: "tts.openAI.payAsYouGo", secret: legacyTTS)
        let tts = TTSSettingsService(defaults: f.defaults, keychain: f.keys)
        _ = await SpeechCredentialStore.prepareTTSLegacyBindings(defaults: f.defaults, local: f.keys, destination: f.keys)
        XCTAssertTrue(tts.hasDedicatedCredential)
        try tts.saveCredential("synthetic-updated-TTS")
        try tts.deleteCredential()
        XCTAssertFalse(tts.hasDedicatedCredential)
        for enabled in [true, false] {
            SyncControlPreferences(overallEnabled: true, configurationEnabled: true, savedCredentialsEnabled: enabled).save(to: f.defaults)
            _ = await SpeechCredentialStore.prepareTTSLegacyBindings(defaults: f.defaults, local: f.keys, destination: f.keys)
        }
        let reloaded = TTSSettingsService(defaults: f.defaults, keychain: f.keys)
        XCTAssertFalse(reloaded.hasDedicatedCredential)
        do {
            _ = try await reloaded.credential(for: voice)
            XCTFail("Deleted speech key must not fall through to retained legacy bytes")
        } catch {}
        XCTAssertEqual(try f.keys.read(account: "tts.openAI.payAsYouGo"), legacyTTS)
        try reloaded.saveCredential("synthetic-explicit-new-TTS")
        _ = await SpeechCredentialStore.prepareTTSLegacyBindings(defaults: f.defaults, local: f.keys, destination: f.keys)
        let newTTS = try await reloaded.credential(for: voice)
        XCTAssertEqual(newTTS, "synthetic-explicit-new-TTS")

        var legacyASR = ASRProfile.openAICompatible(name: "Synthetic retained ASR")
        let rawASR = "profile." + legacyASR.id.uuidString.lowercased()
        legacyASR.credentialReference = .init(service: SpeechCredentialBinding.asrService, account: rawASR)
        let legacyASRBytes = Data("synthetic-kept-old-ASR".utf8)
        try f.keys.store(account: rawASR, secret: legacyASRBytes)
        f.defaults.set(try ApplicationSettingRecord.encodeValue(
            CloudASRSettingsStore.PersistedState(schemaVersion: 1, profiles: [legacyASR],
                primaryProfileID: legacyASR.id, legacyAliasProfileID: nil, migrationCompleted: true)),
            forKey: CloudASRSettingsStore.storageKey)
        f.asr.reloadSynchronizedPreferences()
        let preparationFailures = await f.asr.prepareLocalCredentialBindings()
        XCTAssertEqual(preparationFailures, 0)
        let frozen = try XCTUnwrap(f.asr.profile(id: legacyASR.id))
        XCTAssertTrue(f.asr.hasCredential(for: frozen))
        f.asr.removeProfile(id: legacyASR.id)
        XCTAssertThrowsError(try f.asr.credential(for: frozen))
        let policy = SpeechCredentialStore(service: SpeechCredentialBinding.asrService, defaults: f.defaults)
        XCTAssertThrowsError(try policy.copyRetainedLegacy(legacyASRBytes,
            account: SpeechCredentialBinding.asrAccount(legacyASR), destination: f.keys))
        XCTAssertEqual(try f.keys.read(account: rawASR), legacyASRBytes)
        let replacement = try f.asr.addProfile(legacyASR, credential: "synthetic-explicit-new-ASR")
        XCTAssertEqual(try f.asr.credential(for: replacement), "synthetic-explicit-new-ASR")
    }

    func testInterruptedInitialImportStaysEpochZeroUntilEveryKeyCommits() async throws {
        let f = try await fixture(); defer { f.defaults.removePersistentDomain(forName: f.suite) }
        f.defaults.set("dark", forKey: "floe.settings.appearance")
        f.defaults.set("en", forKey: "floe.settings.language")
        try await f.database.writer { db in
            try db.execute(sql: "CREATE TRIGGER fail_initial_second BEFORE INSERT ON config_sync_metadata WHEN NEW.record_id='app-setting.v1.defaults.floe.settings.language' BEGIN SELECT RAISE(ABORT,'synthetic second-key failure'); END")
        }
        var importer: ApplicationSettingsSyncCoordinator? = ApplicationSettingsSyncCoordinator(
            sync: f.engine, settings: f.settings, defaults: f.defaults, asr: f.asr, prepareLegacyTTS: { 0 })
        if let importer {
            await importer.start()
            let pass = await importer.flush()
            XCTAssertFalse(pass)
        }
        let first = try await f.store.applicationSetting(key: "defaults.floe.settings.appearance")
        let second = try await f.store.applicationSetting(key: "defaults.floe.settings.language")
        XCTAssertEqual(first?.updatedAt, Date(timeIntervalSince1970: 0))
        XCTAssertNil(second)
        XCTAssertNotNil(f.defaults.data(forKey: "sync.application-settings.materialized.v1"))
        XCTAssertFalse(f.defaults.bool(forKey: "sync.application-settings.bootstrap-complete.v1"))
        importer = nil // simulate service/process owner reconstruction, not a view dismissal
        try await f.database.writer { db in try db.execute(sql: "DROP TRIGGER fail_initial_second") }

        let cloud = ApplicationSettingRecord(key: "defaults.floe.settings.language",
            value: Data("\"zhHans\"".utf8), updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await deliver(cloud, to: f)
        let restarted = ApplicationSettingsSyncCoordinator(sync: f.engine, settings: f.settings,
            defaults: f.defaults, asr: f.asr, prepareLegacyTTS: { 0 })
        await restarted.start()
        let pass = await restarted.flush()
        XCTAssertTrue(pass)
        XCTAssertTrue(f.defaults.bool(forKey: "sync.application-settings.bootstrap-complete.v1"))
        XCTAssertEqual(f.defaults.string(forKey: "floe.settings.language"), "zhHans")
        let saved = try await f.store.applicationSetting(key: cloud.key)
        XCTAssertEqual(saved, cloud, "The remaining legacy value must never acquire Date() and overwrite cloud history")
        let pending = try await f.metadata.metadata(recordType: "ApplicationSetting", recordID: cloud.recordID)
        XCTAssertNil(pending?.pendingAction)
        let preservedFirst = try await f.store.applicationSetting(key: "defaults.floe.settings.appearance")
        XCTAssertEqual(preservedFirst?.updatedAt, Date(timeIntervalSince1970: 0))
    }

}

private final class PortableSettingsFakeKeychain: KeychainProbeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func store(account: String, secret: Data) throws { lock.lock(); items[account] = secret; lock.unlock() }
    func read(account: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = items[account] else { throw KeychainStoreError.itemNotFound }; return value
    }
    func delete(account: String) throws { lock.lock(); items.removeValue(forKey: account); lock.unlock() }
}
#endif
