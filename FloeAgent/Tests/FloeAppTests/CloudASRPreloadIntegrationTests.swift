import XCTest
import Foundation
import FloeCore
import FloeProviders
import FloeSecurity
@testable import FloeApp

final class CloudASRPreloadIntegrationTests: XCTestCase {
    @MainActor
    func testExplicitFileServicePriorityDoesNotFollowOrChangeDictationSelection() async throws {
        let suite = "floe.asr.file-priority." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = CountingASRKeychain()
        let store = CloudASRSettingsStore(defaults: defaults, keychain: credentials,
                                           legacyKeychain: credentials)
        let primary = try store.addProfile(.openAICompatible(name: "Primary"),
                                           credential: "synthetic-primary-token")
        let file = try store.addProfile(.openAICompatible(name: "File preference"),
                                        credential: "synthetic-file-token")
        let fileID = store.serviceID(for: file)
        for method in [VoiceRecognitionPreferences.Method.system, .enhanced] {
            let assistant = AssistantAudioService(
                settings: TTSSettingsService(defaults: defaults, keychain: credentials),
                speech: TTSSpeechService(), defaults: defaults, keychain: credentials,
                cloudASRSettings: store, recognitionMethod: { method })
            await assistant.refreshAvailability()
            assistant.setPriority([fileID], for: .transcription)
            XCTAssertEqual(assistant.service(id: nil, for: .transcription)?.id, fileID)
            XCTAssertEqual(store.primaryProfileID, primary.id,
                           "A file-tool preference must not change the dictation profile")
        }
    }

    @MainActor
    func testOrdinarySettingsRefreshNeverReadsCredentialsOrResetsPreload() async throws {
        let suite = "floe.asr.metadata-refresh." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = CountingASRKeychain()
        let store = CloudASRSettingsStore(defaults: defaults, keychain: credentials,
                                           legacyKeychain: credentials)
        _ = try store.addProfile(.openAICompatible(name: "Synthetic profile"),
                                 credential: "synthetic-not-a-provider-token")
        let coordinator = CloudASRPreloadCoordinator(store: store, defaults: defaults,
            methodProvider: { CloudASRMethod.cloud }, runtime: .disabled)
        credentials.resetReads()
        let identity = coordinator.primaryRouteIdentity()
        XCTAssertFalse(coordinator.isEnabled)
        await coordinator.setEnabled(true)
        XCTAssertTrue(coordinator.isEnabled)
        // A locked credential may affect a real recognition request, but not
        // route metadata, an unrelated settings event, or the saved toggle.
        credentials.failReads = true
        for index in 0..<40 {
            defaults.set(index, forKey: "unrelated.fixture.preference")
            _ = await coordinator.syncPrimaryRoute()
            XCTAssertEqual(coordinator.primaryRouteIdentity(), identity)
        }
        XCTAssertEqual(credentials.readCount, 0,
                       "Root settings notifications must not synchronously query Keychain")
        XCTAssertTrue(coordinator.isEnabled)
        await coordinator.setEnabled(false)
    }
}

private final class CountingASRKeychain: KeychainProbeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var reads = 0
    private var locked = false
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var failReads: Bool {
        get { lock.lock(); defer { lock.unlock() }; return locked }
        set { lock.lock(); defer { lock.unlock() }; locked = newValue }
    }
    func resetReads() { lock.lock(); defer { lock.unlock() }; reads = 0 }
    func store(account: String, secret: Data) throws {
        lock.lock(); defer { lock.unlock() }; items[account] = secret
    }
    func read(account: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }; reads += 1
        guard !locked, let data = items[account] else { throw KeychainStoreError.itemNotFound }
        return data
    }
    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }; items.removeValue(forKey: account)
    }
}
