import Foundation
import Testing
import FloeCore
import FloeSecurity
@testable import FloeSync

@Suite("Origin-bound speech Keychain synchronization")
struct SpeechCredentialStoreTests {
    @Test func switchCopiesVerifyAndFailuresKeepOriginalKeys() throws {
        let suite = "speech-key-copy." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        SyncControlPreferences(overallEnabled: true, configurationEnabled: true, savedCredentialsEnabled: false).save(to: defaults)
        let local = SpeechSyncFakeKeychain(), cloud = SpeechSyncFakeKeychain()
        let store = SpeechCredentialStore(service: SpeechCredentialBinding.asrService,
            local: local, synchronized: cloud, defaults: defaults)
        let account = SpeechCredentialBinding.asrAccount(.openAICompatible(name: "Synthetic"))
        let bytes = Data("synthetic-local-speech-key".utf8)
        try store.store(account: account, secret: bytes)
        cloud.failWrites = true
        let failed = store.prepareSynchronization(enabled: true)
        #expect(failed.failed == 1 && failed.migrated == 0)
        #expect(try local.read(account: account) == bytes)
        #expect(throws: KeychainStoreError.itemNotFound) { try cloud.read(account: account) }
        cloud.failWrites = false
        #expect(store.prepareSynchronization(enabled: true).migrated == 1)
        SyncControlPreferences(overallEnabled: true, configurationEnabled: true, savedCredentialsEnabled: true).save(to: defaults)
        #expect(try store.read(account: account) == bytes)
        let newer = Data("synthetic-new-key".utf8)
        try store.store(account: account, secret: newer)
        #expect(store.prepareSynchronization(enabled: false).migrated == 1)
        SyncControlPreferences(overallEnabled: true, configurationEnabled: true, savedCredentialsEnabled: false).save(to: defaults)
        #expect(try store.read(account: account) == newer)
        #expect(try cloud.read(account: account) == newer, "Turning off keeps the recoverable source copy")
        let offlineEdit = Data("synthetic-local-after-off".utf8)
        try store.store(account: account, secret: offlineEdit)
        _ = store.prepareSynchronization(enabled: false)
        #expect(try store.read(account: account) == offlineEdit, "Retry OFF cannot restore an inactive stale cloud copy")
        #expect(try cloud.read(account: account) == newer)
        #expect(!defaults.dictionaryRepresentation().values.contains { ($0 as? Data) == bytes })
    }

    @MainActor @Test func legacyOriginMustBeKnownBeforeRemoteMetadataArrives() async throws {
        let suite = "speech-known-origin." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = TTSSettingsSnapshot(provider: .openAI, modelID: "tts-1", voiceID: "alloy")
        defaults.set(try ApplicationSettingRecord.encodeValue(original), forKey: "voice.output.settings.v1")
        SpeechCredentialStore.captureLocalTTSOrigins(defaults: defaults)
        var remote = original; remote.openAIBaseURL = "https://new.example.test/v1"
        defaults.set(try ApplicationSettingRecord.encodeValue(remote), forKey: "voice.output.settings.v1")
        let old = SpeechSyncFakeKeychain(), local = SpeechSyncFakeKeychain(), cloud = SpeechSyncFakeKeychain()
        try old.store(account: "tts.openAI.payAsYouGo", secret: Data("synthetic-old-origin-key".utf8))
        let target = SpeechCredentialStore(service: SpeechCredentialBinding.ttsService,
            local: local, synchronized: cloud, defaults: defaults)
        #expect(await SpeechCredentialStore.prepareTTSLegacyBindings(defaults: defaults, local: old, destination: target) == 0)
        #expect(throws: KeychainStoreError.itemNotFound) { try target.read(account: SpeechCredentialBinding.ttsAccount(remote)) }
        defaults.set(try ApplicationSettingRecord.encodeValue(original), forKey: "voice.output.settings.v1")
        #expect(await SpeechCredentialStore.prepareTTSLegacyBindings(defaults: defaults, local: old, destination: target) == 0)
        #expect(try target.read(account: SpeechCredentialBinding.ttsAccount(original)) == Data("synthetic-old-origin-key".utf8))
        #expect(try old.read(account: "tts.openAI.payAsYouGo") == Data("synthetic-old-origin-key".utf8))
    }

    @Test func lateLegacyCopyCannotOverwriteExplicitOriginKey() throws {
        let suite = "speech-copy-cas." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SpeechCredentialStore(service: SpeechCredentialBinding.asrService,
            local: SpeechSyncFakeKeychain(), synchronized: SpeechSyncFakeKeychain(), defaults: defaults)
        let account = SpeechCredentialBinding.asrAccount(.openAICompatible(name: "Synthetic"))
        try store.store(account: account, secret: Data("synthetic-explicit-new-key".utf8))
        try store.copyKnownLegacy(Data("synthetic-legacy-key".utf8), to: account)
        #expect(try store.read(account: account) == Data("synthetic-explicit-new-key".utf8))
        #expect(throws: (any Error).self) { try store.store(account: "profile.arbitrary", secret: Data()) }
    }
    @Test func explicitDeletionFencesRetainedCopiesAcrossRestartAndSwitches() throws {
        let suite = "speech-delete-proof." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for service in [SpeechCredentialBinding.asrService, SpeechCredentialBinding.ttsService] {
            SyncControlPreferences(overallEnabled: true, configurationEnabled: true, savedCredentialsEnabled: false).save(to: defaults)
            let local = SpeechSyncFakeKeychain(), cloud = SpeechSyncFakeKeychain(), legacy = SpeechSyncFakeKeychain()
            let account = service == SpeechCredentialBinding.asrService
                ? SpeechCredentialBinding.asrAccount(.openAICompatible(name: "Synthetic"))
                : SpeechCredentialBinding.ttsAccount(.init(provider: .openAI, modelID: "tts-1", voiceID: "alloy"))
            let original = Data("synthetic-retained-legacy".utf8)
            try legacy.store(account: "retained-raw-account", secret: original)
            // Captured before deletion: represents a worker already past its
            // original legacy read, but not yet at the actual copy boundary.
            let captured = try legacy.read(account: "retained-raw-account")
            let store = SpeechCredentialStore(service: service, local: local, synchronized: cloud, defaults: defaults)
            try store.copyKnownLegacy(captured, to: account)
            try store.store(account: account, secret: Data("synthetic-updated-origin".utf8))
            try store.delete(account: account)
            #expect(throws: KeychainStoreError.itemNotFound) { try store.read(account: account) }
            let reopened = SpeechCredentialStore(service: service, local: local, synchronized: cloud, defaults: defaults)
            for enabled in [true, false] {
                SyncControlPreferences(overallEnabled: true, configurationEnabled: true, savedCredentialsEnabled: enabled).save(to: defaults)
                _ = reopened.prepareSynchronization(enabled: enabled)
                #expect(throws: KeychainStoreError.itemNotFound) {
                    try reopened.copyRetainedLegacy(captured, account: account, destination: reopened)
                }
                #expect(throws: KeychainStoreError.itemNotFound) { try reopened.read(account: account) }
                #expect(throws: KeychainStoreError.itemNotFound) {
                    try SpeechCredentialStore.readUnlessDeleted(account: account, service: service, defaults: defaults) {
                        try legacy.read(account: "retained-raw-account")
                    }
                }
            }
            #expect(try legacy.read(account: "retained-raw-account") == original)
            let fresh = Data("synthetic-explicit-replacement".utf8)
            try reopened.store(account: account, secret: fresh)
            try reopened.copyKnownLegacy(captured, to: account)
            #expect(try reopened.read(account: account) == fresh)
        }
    }

    @Test func failedOffRetryUsesOriginalTransferAndPreservesLaterExplicitSave() throws {
        for scenario in ["retry", "explicit-local", "late-cloud"] {
            let suite = "speech-off-retry." + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let local = SpeechSyncFakeKeychain(), cloud = SpeechSyncFakeKeychain()
            let account = SpeechCredentialBinding.asrAccount(.openAICompatible(name: "Synthetic"))
            let k1 = Data("synthetic-K1".utf8), k2 = Data("synthetic-K2".utf8)
            let k3 = Data("synthetic-K3".utf8), k4 = Data("synthetic-late-K4".utf8)
            SyncControlPreferences(overallEnabled: true, configurationEnabled: true, savedCredentialsEnabled: false).save(to: defaults)
            let store = SpeechCredentialStore(service: SpeechCredentialBinding.asrService,
                local: local, synchronized: cloud, defaults: defaults)
            try store.store(account: account, secret: k1)
            #expect(store.prepareSynchronization(enabled: true).failed == 0)
            SyncControlPreferences(overallEnabled: true, configurationEnabled: true, savedCredentialsEnabled: true).save(to: defaults)
            try store.store(account: account, secret: k2)
            #expect(try local.read(account: account) == k1)
            local.failWrites = true
            #expect(store.prepareSynchronization(enabled: false).failed == 1)
            // An explicit stop still commits OFF despite failed migration.
            SyncControlPreferences(overallEnabled: true, configurationEnabled: true, savedCredentialsEnabled: false).save(to: defaults)
            local.failWrites = false
            let reopened = SpeechCredentialStore(service: SpeechCredentialBinding.asrService,
                local: local, synchronized: cloud, defaults: defaults)
            if scenario == "explicit-local" { try reopened.store(account: account, secret: k3) }
            if scenario == "late-cloud" { try cloud.store(account: account, secret: k4) }
            let retry = reopened.prepareSynchronization(enabled: false)
            if scenario == "late-cloud" {
                #expect(retry.failed == 1)
                #expect(try local.read(account: account) == k1)
                #expect(try cloud.read(account: account) == k4)
            } else {
                #expect(retry.failed == 0 && retry.missing == 0 && retry.migrated == 1)
                #expect(try reopened.read(account: account) == (scenario == "explicit-local" ? k3 : k2))
                #expect(try cloud.read(account: account) == k2)
            }
        }
    }

}

private final class SpeechSyncFakeKeychain: KeychainProbeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var rejectsWrites = false
    var failWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return rejectsWrites }
        set { lock.lock(); rejectsWrites = newValue; lock.unlock() }
    }
    func store(account: String, secret: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if rejectsWrites { throw KeychainStoreError.interactionNotAllowed }
        items[account] = secret
    }
    func read(account: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = items[account] else { throw KeychainStoreError.itemNotFound }
        return value
    }
    func delete(account: String) throws { lock.lock(); items.removeValue(forKey: account); lock.unlock() }
}
