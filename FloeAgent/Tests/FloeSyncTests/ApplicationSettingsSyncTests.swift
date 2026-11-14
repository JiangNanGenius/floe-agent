#if canImport(CloudKit)
import Foundation
import CloudKit
import GRDB
import Testing
import FloeCore
@testable import FloePersistence
@testable import FloeSync

@Suite("Application settings actual CloudKit record and SQLite paths")
struct ApplicationSettingsSyncTests {
    private struct Fixture {
        let database: DatabaseManager
        let configuration: ModelConfigurationStore
        let metadata: ConfigSyncMetadataStore
        let engine: ConfigSyncEngine
    }
    private func fixture() async throws -> Fixture {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let configuration = ModelConfigurationStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        return Fixture(database: database, configuration: configuration, metadata: metadata,
            engine: ConfigSyncEngine(configurationStore: configuration, metadataStore: metadata))
    }
    private func wire(_ fixture: Fixture, key: String) async throws -> CKRecord {
        try #require(await fixture.engine.recordToSave(.init(recordName: ApplicationSettingRecord.recordPrefix + key,
            zoneID: .init(zoneName: ConfigSyncEngine.zoneName))))
    }

    @Test func wireMergeDeletionAndRapidEditAcknowledgement() async throws {
        let a = try await fixture(), b = try await fixture()
        let key = ApplicationSettingPolicy.defaultsPrefix + "floe.settings.language"
        let early = ApplicationSettingRecord(key: key, value: try ApplicationSettingRecord.encodeValue("en"),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000.125))
        try await a.engine.saveApplicationSetting(early)
        let first = try await wire(a, key: key)
        #expect(first.recordType == "ApplicationSetting")
        #expect(first["payload"] == nil && first.encryptedValues["payload"] as? Data != nil)
        #expect(try await b.engine.applyRemote(first))
        #expect(try await b.configuration.applicationSetting(key: key)?.value == early.value)
        let later = ApplicationSettingRecord(key: key, value: try ApplicationSettingRecord.encodeValue("zhHans"),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000.875))
        try await a.engine.saveApplicationSetting(later)
        try await a.engine.acknowledgeApplicationSetting(first)
        let pending = try #require(try await a.metadata.metadata(recordType: "ApplicationSetting", recordID: later.recordID))
        #expect(pending.pendingAction == .save)
        #expect(pending.fieldTimestamps["value"] == later.updatedAt)
        #expect(try await b.engine.applyRemote(try await wire(a, key: key)))
        let other = ApplicationSettingRecord(key: "defaults.floe.settings.userQuestionDefaults.v1",
            value: Data("{\"optionalTimeoutSeconds\":30}".utf8), updatedAt: Date(timeIntervalSince1970: 1_700_000_001))
        try await b.engine.saveApplicationSetting(other)
        #expect(try await a.engine.applyRemote(try await wire(b, key: other.key)))
        #expect(try await a.configuration.applicationSetting(key: key)?.value == later.value)
        let tombstone = ApplicationSettingRecord(key: key, value: nil, updatedAt: Date(timeIntervalSince1970: 1_700_000_002))
        try await a.engine.saveApplicationSetting(tombstone)
        #expect(try await b.engine.applyRemote(try await wire(a, key: key)))
        #expect(try await b.configuration.applicationSetting(key: key)?.value == nil)
        #expect(!(try await b.engine.applyRemote(first)))
        #expect(try await b.configuration.applicationSetting(key: key)?.value == nil)
    }

    @Test func valueAndPendingMetadataRollbackAndCASStayAtomic() async throws {
        let f = try await fixture()
        let value = ApplicationSettingRecord(key: "database.exec.timeoutSeconds", value: Data("120".utf8))
        try await f.database.writer { db in
            try db.execute(sql: "CREATE TRIGGER fail_app_setting BEFORE INSERT ON config_sync_metadata WHEN NEW.record_type='ApplicationSetting' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END")
        }
        await #expect(throws: (any Error).self) { try await f.engine.saveApplicationSetting(value) }
        #expect(try await f.configuration.applicationSetting(key: value.key) == nil)
        #expect(try await f.metadata.metadata(recordType: "ApplicationSetting", recordID: value.recordID) == nil)
        try await f.database.writer { db in try db.execute(sql: "DROP TRIGGER fail_app_setting") }
        try await f.engine.saveApplicationSetting(value)
        let old = try await f.configuration.applicationSettingSnapshot(key: value.key)
        let next = ApplicationSettingRecord(key: value.key, value: Data("180".utf8))
        try await f.engine.saveApplicationSetting(next)
        let oldMetadata = try #require(old.metadata)
        await #expect(throws: (any Error).self) {
            try await f.configuration.commitApplicationSetting(value, metadata: oldMetadata, expecting: old)
        }
        #expect(try await f.configuration.applicationSetting(key: value.key)?.value == next.value)
        let ui = SQLiteSettingsStore(database: f.database)
        try await ui.setValue("180", forKey: AppSettingsKey.executionTimeoutSeconds)
        #expect(!(try await ui.compareAndSetValue("120", forKey: AppSettingsKey.executionTimeoutSeconds, expecting: nil)))
        #expect(try await ui.value(forKey: AppSettingsKey.executionTimeoutSeconds) == "180")
    }

    @Test func malformedAndCredentialBearingRemoteSettingsNeverCommit() async throws {
        let f = try await fixture()
        var profile = ASRProfile.openAICompatible(name: "Synthetic remote", fileEndpoint: "https://speech.example.test/v1")
        profile.credentialReference = .init(service: "foreign-service", account: "foreign-account")
        let unsafe = ApplicationSettingRecord(key: ApplicationSettingPolicy.asrKey(profile.id),
            value: try ApplicationSettingRecord.encodeValue(profile))
        for value in [unsafe, ApplicationSettingRecord(key: "defaults.sync.savedCredentialsEnabled", value: Data("true".utf8)),
                      ApplicationSettingRecord(key: "defaults.floe.settings.language", value: Data("\"en\"".utf8), schemaVersion: 2)] {
            let record = CKRecord(recordType: "ApplicationSetting", recordID: .init(recordName: value.recordID))
            record.encryptedValues["payload"] = try ApplicationSettingRecord.encodeValue(value) as CKRecordValue
            record.encryptedValues["fieldTimestamps"] = try ApplicationSettingRecord.encodeValue(["value": value.updatedAt]) as CKRecordValue
            #expect(!(try await f.engine.applyRemote(record)))
            #expect(try await f.metadata.metadata(recordType: "ApplicationSetting", recordID: value.recordID) == nil)
        }
        #expect(try await f.configuration.applicationSettings().isEmpty)
        #expect(await f.engine.remoteConfigurationAppliedCount == 0)
    }

    @Test func lateSpeechKeysUseExistingArrivalFanoutAndDeviceLocalSwitches() async throws {
        let f = try await fixture()
        let suite = "sync.speech-arrival." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SyncControlPreferences(overallEnabled: true, configurationEnabled: true, savedCredentialsEnabled: true).save(to: defaults)
        await f.engine.replacePreferencesDefaultsForTesting(suite: suite)
        let presence = ApplicationSettingSecretPresence()
        await f.engine.replaceSecretExistenceReaderForTesting { service, account, sync in
            sync && presence.contains(service + "/" + account)
        }
        let asr = ASRProfile.openAICompatible(name: "Synthetic ASR")
        try await f.engine.saveApplicationSetting(.init(key: ApplicationSettingPolicy.asrKey(asr.id),
            value: ApplicationSettingRecord.encodeValue(asr)))
        let tts = TTSSettingsSnapshot(provider: .openAI, modelID: "synthetic", voiceID: "voice")
        try await f.engine.saveApplicationSetting(.init(key: ApplicationSettingPolicy.ttsSelection,
            value: ApplicationSettingRecord.encodeValue(tts)))
        #expect(await f.engine.batchCompletionStatus() == .waitingForSecret)
        presence.insert(SpeechCredentialBinding.asrService + "/" + SpeechCredentialBinding.asrAccount(asr))
        #expect(await f.engine.batchCompletionStatus() == .waitingForSecret)
        await f.engine.markWaitingForSecret()
        presence.insert(SpeechCredentialBinding.ttsService + "/" + SpeechCredentialBinding.ttsAccount(tts))
        _ = await f.engine.refreshStatusIfWaiting()
        #expect(await f.engine.status == .synced)
        #expect(await f.engine.remoteConfigurationAppliedCount == 1)
        SyncControlPreferences(overallEnabled: true, configurationEnabled: true, savedCredentialsEnabled: false).save(to: defaults)
        presence.removeAll()
        #expect(await f.engine.batchCompletionStatus() == .synced)
        await f.engine.markPaused(reason: "synthetic fixture complete")
    }
    @Test func stateCatalogReplaysNewKindsAndDetectsRollbackWithoutLosingPending() async throws {
        let f = try await fixture(), sender = try await fixture()
        let catalog = ConfigSyncRecordType.allCases.map(\.rawValue)
        let pending = ApplicationSettingRecord(key: "defaults.floe.settings.language",
            value: Data("\"en\"".utf8), updatedAt: Date(timeIntervalSince1970: 100))
        try await f.engine.saveApplicationSetting(pending)
        let originalPending = try await f.metadata.metadata(recordType: "ApplicationSetting", recordID: pending.recordID)
        let oldConsumed = Data("synthetic-343-token-after-ignored-new-type".utf8)
        try await f.metadata.saveEngineState(oldConsumed)
        #expect(try await f.metadata.engineState(supportedRecordTypes: catalog) == nil)
        #expect(try await f.metadata.engineState() == oldConsumed, "Replay admission keeps the original raw state")

        // Same nil-state gate the production engine uses; actual inbound
        // CKRecord/SQLite apply proves the previously unknown unique UUID can
        // be materialized without a fake account or CloudKit request.
        let asr = ASRProfile.openAICompatible(name: "Unique remote ASR")
        let remote = ApplicationSettingRecord(key: ApplicationSettingPolicy.asrKey(asr.id),
            value: try ApplicationSettingRecord.encodeValue(asr), updatedAt: Date(timeIntervalSince1970: 200))
        try await sender.engine.saveApplicationSetting(remote)
        #expect(try await f.engine.applyRemote(try await wire(sender, key: remote.key)))
        #expect(try await f.configuration.applicationSetting(key: remote.key)?.value == remote.value)
        #expect(try await f.metadata.metadata(recordType: "ApplicationSetting", recordID: pending.recordID) == originalPending)

        let current = Data("synthetic-345-known-catalog-state".utf8)
        try await f.metadata.saveEngineState(current, supportedRecordTypes: catalog)
        #expect(try await f.metadata.engineState(supportedRecordTypes: catalog) == current)
        #expect(try await f.metadata.engineState(supportedRecordTypes: catalog) == current, "Unchanged restarts do not reset again")
        let rollback = Data("synthetic-343-advanced-again".utf8)
        try await f.metadata.saveEngineState(rollback) // old binary leaves the companion untouched
        #expect(try await f.metadata.engineState(supportedRecordTypes: catalog) == nil)
        #expect(try await f.metadata.engineState() == rollback)
        try await f.metadata.saveEngineState(current, supportedRecordTypes: catalog)
        try await f.database.writer { db in
            try db.execute(sql: "CREATE TRIGGER fail_state_binding BEFORE INSERT ON app_settings WHEN NEW.key='sync.engine-state.catalog.v1' BEGIN SELECT RAISE(ABORT,'synthetic binding failure'); END")
        }
        await #expect(throws: (any Error).self) {
            try await f.metadata.saveEngineState(Data("synthetic-never-committed-state".utf8), supportedRecordTypes: catalog)
        }
        #expect(try await f.metadata.engineState() == current)
        #expect(try await f.metadata.engineState(supportedRecordTypes: catalog) == current,
                "State and its exact catalog digest must roll back together")
        #expect(try await f.metadata.metadata(recordType: "ApplicationSetting", recordID: pending.recordID) == originalPending)
    }

}

private final class ApplicationSettingSecretPresence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: Set<String> = []
    func contains(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return values.contains(key) }
    func insert(_ key: String) { lock.lock(); values.insert(key); lock.unlock() }
    func removeAll() { lock.lock(); values.removeAll(); lock.unlock() }
}
#endif
