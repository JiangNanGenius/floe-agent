#if canImport(UIKit)
import XCTest
import CryptoKit
import FloeCore
import FloeSecurity
import Synchronization
@testable import FloeApp

@MainActor
final class TTSSettingsServiceTests: XCTestCase {
    func testSavingOnlineAccountDoesNotSelectIt() throws {
        let name = "tts-settings-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = SpeechSettingsTestKeychain()
        let settings = TTSSettingsService(defaults: defaults, keychain: keychain)
        var account = TTSSettingsSnapshot.systemDefault
        account.provider = .openAI; account.modelID = "gpt-4o-mini-tts"; account.voiceID = "alloy"
        try settings.saveProfile(account, credential: "synthetic-test-key")
        defer { try? settings.removeProfile(account) }
        XCTAssertEqual(settings.snapshot.provider, .apple)
        XCTAssertEqual(settings.configuredProfiles.count, 1)
        XCTAssertTrue(settings.hasCredential(for: account))
        settings.choose(account)
        XCTAssertEqual(settings.snapshot.provider, .openAI)
    }

    func testBillingChannelsKeepIndependentCredentials() async throws {
        let name = "tts-channels-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = TTSSettingsService(defaults: defaults, keychain: SpeechSettingsTestKeychain())
        var plan = TTSSettingsSnapshot.systemDefault
        plan.provider = .alibaba
        plan.billingRoute = .tokenPlan
        plan.modelID = "synthetic-model"
        plan.voiceID = "synthetic-voice"
        var usage = plan
        usage.billingRoute = .payAsYouGo
        try settings.saveProfile(plan, credential: "synthetic-plan")
        try settings.saveProfile(usage, credential: "synthetic-usage")
        let planCredential = try await settings.credential(for: plan)
        let usageCredential = try await settings.credential(for: usage)
        XCTAssertEqual(planCredential, "synthetic-plan")
        XCTAssertEqual(usageCredential, "synthetic-usage")
        XCTAssertEqual(settings.configuredProfiles.count, 2)
        XCTAssertEqual(settings.snapshot.provider, .apple)
        try settings.removeProfile(plan)
        XCTAssertFalse(settings.hasCredential(for: plan))
        XCTAssertTrue(settings.hasCredential(for: usage))
    }

    func testFirstSuccessfulInstallSelectsCatalogDefaultNotHardcodedVivian() async throws {
        // The visible pack is MOSS-style with a "default" catalog voice. The
        // old hardcoded qwen/vivian path must not force "vivian".
        let fixture = try fixture()
        defer { fixture.cleanup() }
        await fixture.settings.install(fixture.model)
        try await settled(fixture)
        await fixture.settings.syncLocalSelection()
        XCTAssertEqual(fixture.settings.snapshot.provider, .onDevice)
        XCTAssertEqual(fixture.settings.snapshot.voiceID, "default")
        fixture.settings.update { $0.voiceID = "other" }
        await fixture.settings.install(fixture.model)
        try await settled(fixture)
        await fixture.settings.syncLocalSelection()
        XCTAssertEqual(fixture.settings.snapshot.voiceID, "other")
    }

    func testSelectionChangedDuringDownloadWins() async throws {
        let fixture = try fixture(delay: true)
        defer { fixture.cleanup() }
        await fixture.settings.install(fixture.model)
        fixture.settings.update { $0.voiceID = "explicit-system-voice" }
        try await settled(fixture)
        await fixture.settings.syncLocalSelection()
        XCTAssertEqual(fixture.settings.snapshot.provider, .apple)
        XCTAssertEqual(fixture.settings.snapshot.voiceID, "explicit-system-voice")
    }

    func testFirstInstallDoesNotSwitchBeforeLoadValidationPasses() async throws {
        // A pack that installed its bytes but has not passed the engine load
        // hook must NOT flip the active selection or mark first-install done.
        let fixture = try fixture(validation: .failed)
        defer { fixture.cleanup() }
        await fixture.settings.install(fixture.model)
        try await settled(fixture)
        await fixture.settings.syncLocalSelection()
        XCTAssertEqual(fixture.settings.snapshot.provider, .apple, "A failed load validation never hijacks the selection")
        XCTAssertFalse(fixture.defaults.bool(forKey: "voice.output.firstInstallSelection"))
        XCTAssertEqual(fixture.settings.localMigrationNote, "voice.local.error.verify")
        // A later retry with a healthy engine completes the transition.
        await fixture.gate.set(.passed)
        await fixture.settings.retryLocalValidation()
        XCTAssertEqual(fixture.settings.snapshot.provider, .onDevice)
        XCTAssertEqual(fixture.settings.snapshot.voiceID, "default")
        XCTAssertNil(fixture.settings.localMigrationNote)
    }

    private struct Fixture {
        let root: URL
        let name: String
        let defaults: UserDefaults
        let model: LocalSpeechModel
        let store: LocalSpeechModelStore
        let gate: ValidationGate
        let settings: TTSSettingsService
        func cleanup() { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
    }
    private func fixture(delay: Bool = false, validation: LocalPackValidation = .passed) throws -> Fixture {
        let name = "tts-install-test." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("synthetic-model".utf8)
        let revision = String(repeating: "1", count: 40)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        // Visible MOSS-style pack with a catalog default voice.
        let model = LocalSpeechModel(id: "synthetic-moss", title: "Synthetic", engine: "mossTTSNano", repository: "test/model", revision: revision, license: "Apache-2.0", languages: ["zh", "en"], voices: [.init(id: "default", name: "Default", languages: ["zh", "en"]), .init(id: "other", name: "Other", languages: ["zh", "en"])], files: [.init(path: "weights.bin", url: URL(string: "https://huggingface.co/test/model/resolve/\(revision)/weights.bin")!, sha256: hash, byteCount: Int64(bytes.count))], tokenizerRelativePath: nil, minimumMemoryBytes: nil, defaultVoiceID: "default", visibility: "visible")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [model]), root: root.appendingPathComponent("models"), defaults: UserDefaults(suiteName: name)!, downloader: InstallDownloadFixture(root: root, bytes: bytes, delay: delay))
        let gate = ValidationGate(validation)
        let settings = TTSSettingsService(defaults: defaults, keychain: KeychainStore(service: name, synchronizable: false), modelStore: store,
            loadValidator: { _, _ in await gate.current() })
        return Fixture(root: root, name: name, defaults: defaults, model: model, store: store, gate: gate, settings: settings)
    }
    private func settled(_ fixture: Fixture) async throws {
        for _ in 0..<300 {
            if !(await fixture.store.state().running) {
                // Allow the completion notification to cross MainActor.
                try await Task.sleep(for: .milliseconds(30))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synthetic install did not finish")
    }

    // MARK: - Legacy → enhanced selection migration (service level)

    private struct TwoPackFixture {
        let root: URL
        let name: String
        let defaults: UserDefaults
        let legacy: LocalSpeechModel
        let fresh: LocalSpeechModel
        let store: LocalSpeechModelStore
        let gate: ValidationGate
        let settings: TTSSettingsService
        func cleanup() { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
    }

    // Construct a distinct instance for the model actor, transferring ownership
    // while the settings fixture keeps its own instance of the same suite.
    private nonisolated static func transferredDefaults(suiteName: String) throws -> sending UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    private func twoPackFixture(preferredVoice: String, matchingVoiceAvailable: Bool = false) async throws -> TwoPackFixture {
        let name = "tts-migration-test." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacyRevision = String(repeating: "4", count: 40)
        let freshRevision = String(repeating: "5", count: 40)
        let legacyBytes = Data("legacy-pack".utf8)
        let freshBytes = Data("fresh-pack".utf8)
        let legacy = LocalSpeechModel(id: "legacy-qwen", title: "Legacy", engine: "qwen3TTS", repository: "test/legacy", revision: legacyRevision, license: "Apache-2.0", languages: ["zh"], voices: [.init(id: "vivian", name: "Vivian", languages: ["zh"]), .init(id: "serena", name: "Serena", languages: ["zh"])], files: [.init(path: "weights.bin", url: URL(string: "https://huggingface.co/test/legacy/resolve/\(legacyRevision)/weights.bin")!, sha256: SHA256.hash(data: legacyBytes).map { String(format: "%02x", $0) }.joined(), byteCount: Int64(legacyBytes.count))], tokenizerRelativePath: nil, minimumMemoryBytes: nil, defaultVoiceID: "vivian", visibility: "hidden")
        let fresh = LocalSpeechModel(id: "enhanced-moss", title: "Enhanced", engine: "mossTTSNano", repository: "test/fresh", revision: freshRevision, license: "Apache-2.0", languages: ["zh", "en"], voices: [.init(id: "default", name: "Default", languages: ["zh", "en"])] + (matchingVoiceAvailable ? [.init(id: "serena", name: "Serena", languages: ["zh", "en"])] : []), files: [.init(path: "weights.bin", url: URL(string: "https://huggingface.co/test/fresh/resolve/\(freshRevision)/weights.bin")!, sha256: SHA256.hash(data: freshBytes).map { String(format: "%02x", $0) }.joined(), byteCount: Int64(freshBytes.count))], tokenizerRelativePath: nil, minimumMemoryBytes: nil, defaultVoiceID: "default", visibility: "visible")
        // Seed the legacy pack exactly like a pre-migration install would.
        let legacyDir = root.appendingPathComponent("models/tts-\(legacy.id)-\(legacy.revision)")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try legacyBytes.write(to: legacyDir.appendingPathComponent("weights.bin"))
        try JSONEncoder().encode(legacy).write(to: legacyDir.appendingPathComponent("installed.json"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [legacy, fresh]),
                                          root: root.appendingPathComponent("models"),
                                          defaults: try Self.transferredDefaults(suiteName: name),
                                          downloader: MultiDownloadFixture(root: root.appendingPathComponent("transfers"), payloads: [legacy.files[0].url.absoluteString: legacyBytes, fresh.files[0].url.absoluteString: freshBytes]),
                                          transfersRoot: root.appendingPathComponent("transfers"))
        // Mark the store as a previous first install so legacy selection is
        // not re-claimed; the migration path is the one under test.
        defaults.set(true, forKey: "voice.output.firstInstallSelection")
        let gate = ValidationGate(.passed)
        let settings = TTSSettingsService(defaults: defaults, keychain: KeychainStore(service: name, synchronizable: false), modelStore: store,
            loadValidator: { _, _ in await gate.current() })
        settings.update { $0.provider = .onDevice; $0.modelID = legacy.id; $0.voiceID = preferredVoice; $0.billingRoute = .payAsYouGo }
        return TwoPackFixture(root: root, name: name, defaults: defaults, legacy: legacy, fresh: fresh, store: store, gate: gate, settings: settings)
    }

    func testUpgradeWithoutExplicitInstallNeverDownloadsOrDeletes() async throws {
        let fixture = try await twoPackFixture(preferredVoice: "vivian")
        defer { fixture.cleanup() }
        try await Task.sleep(for: .milliseconds(200))
        let state = await fixture.store.state()
        XCTAssertFalse(state.running, "Upgrading never starts a download on its own")
        let actualAt190 = await fixture.store.isInstalled(fixture.legacy)
        XCTAssertTrue(actualAt190, "The old pack is never deleted before an explicit install + validation")
        let record = await fixture.store.migrationRecord
        XCTAssertNil(record)
        XCTAssertEqual(fixture.settings.localVisibleModels.map(\.id), [fixture.fresh.id], "Only the enhanced pack is listed")
    }

    func testLegacyDefaultSelectionMigratesRevisionAwareAndReleasesOldPack() async throws {
        let fixture = try await twoPackFixture(preferredVoice: "vivian")
        defer { fixture.cleanup() }
        await fixture.settings.install(fixture.fresh)
        for _ in 0..<300 { if !(await fixture.store.state().running) { break }; try await Task.sleep(for: .milliseconds(10)) }
        await fixture.settings.syncLocalSelection()
        XCTAssertEqual(fixture.settings.snapshot.provider, .onDevice)
        XCTAssertEqual(fixture.settings.snapshot.modelID, fixture.fresh.id)
        XCTAssertEqual(fixture.settings.snapshot.voiceID, "default", "Migration lands on the catalog default voice")
        let actualAt205 = await fixture.store.isInstalled(fixture.legacy)
        XCTAssertFalse(actualAt205, "Validated migration removes the exact legacy pack")
        let record = await fixture.store.migrationRecord
        XCTAssertNil(record, "Completed migration clears the durable record")
    }

    func testLegacyCustomVoiceIsPreservedAndPackStaysUntilReleased() async throws {
        // A user who explicitly picked a non-default legacy voice is never
        // silently moved, and their pack is kept until they release it.
        let fixture = try await twoPackFixture(preferredVoice: "serena")
        defer { fixture.cleanup() }
        await fixture.settings.install(fixture.fresh)
        for _ in 0..<300 { if !(await fixture.store.state().running) { break }; try await Task.sleep(for: .milliseconds(10)) }
        await fixture.settings.syncLocalSelection()
        XCTAssertEqual(fixture.settings.snapshot.modelID, fixture.legacy.id)
        XCTAssertEqual(fixture.settings.snapshot.voiceID, "serena")
        let actualAt220 = await fixture.store.isInstalled(fixture.legacy)
        XCTAssertTrue(actualAt220)
        let record = await fixture.store.migrationRecord
        XCTAssertEqual(record?.stage, .awaitingLegacyRelease)
        // Once the user leaves the legacy pack, cleanup runs.
        fixture.settings.update { $0.provider = .apple; $0.voiceID = ""; $0.modelID = "" }
        await fixture.settings.syncLocalSelection()
        for _ in 0..<50 { if await fixture.store.migrationRecord == nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let actualAt227 = await fixture.store.isInstalled(fixture.legacy)
        XCTAssertFalse(actualAt227)
    }


    func testUnchangedLegacyStyleMigratesWhenReplacementOffersIt() async throws {
        let fixture = try await twoPackFixture(preferredVoice: "serena", matchingVoiceAvailable: true)
        defer { fixture.cleanup() }
        await fixture.settings.install(fixture.fresh)
        for _ in 0..<300 {
            if !(await fixture.store.state().running) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await fixture.settings.syncLocalSelection()
        XCTAssertEqual(fixture.settings.snapshot.modelID, fixture.fresh.id)
        XCTAssertEqual(fixture.settings.snapshot.voiceID, "serena")
        let legacyInstalled = await fixture.store.isInstalled(fixture.legacy)
        XCTAssertFalse(legacyInstalled, "A matching qualified replacement no longer needs the old pack")
    }

}

private actor InstallDownloadFixture: LocalSpeechDownloading {
    let root: URL
    let bytes: Data
    let delay: Bool
    init(root: URL, bytes: Data, delay: Bool) { self.root = root; self.bytes = bytes; self.delay = delay }
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        if delay { try await Task.sleep(for: .milliseconds(60)) }
        let target = root.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: target)
        progress(Int64(bytes.count))
        return target
    }
}

private final class SpeechSettingsTestKeychain: KeychainProbeStore {
    private let items = Mutex<[String: Data]>([:])
    func store(account: String, secret: Data) throws {
        items.withLock { $0[account] = secret }
    }
    func read(account: String) throws -> Data {
        try items.withLock {
            guard let value = $0[account] else { throw KeychainStoreError.itemNotFound }
            return value
        }
    }
    func delete(account: String) throws {
        items.withLock { _ = $0.removeValue(forKey: account) }
    }
}
private actor MultiDownloadFixture: LocalSpeechDownloading {
    let root: URL
    let payloads: [String: Data]
    init(root: URL, payloads: [String: Data]) { self.root = root; self.payloads = payloads }
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let bytes = payloads[url.absoluteString] else { throw CocoaError(.fileNoSuchFile) }
        let target = root.appendingPathComponent(url.absoluteString.data(using: .utf8)!.base64EncodedString().replacingOccurrences(of: "/", with: "_"))
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try bytes.write(to: target)
        progress(Int64(bytes.count))
        return target
    }
}

private actor ValidationGate {
    private var value: LocalPackValidation
    init(_ value: LocalPackValidation) { self.value = value }
    func set(_ value: LocalPackValidation) { self.value = value }
    func current() -> LocalPackValidation { value }
}
#endif
