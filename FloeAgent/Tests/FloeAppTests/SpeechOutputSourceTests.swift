// FloeAppTests — playback-source identity, selection, per-source voice
// filtering and persistence.
//
// Covers the source/voice separation contract: the source list carries only
// system, installed visible packs and configured online profiles; selecting a
// source restores that source's saved voice while keeping the global controls;
// an incomplete or unconfigured profile is never selected and never falls back
// to a paid channel; saving a new service never changes the current source;
// installed packs remember independent voices; a saved custom voice ID with
// its display name survives even when it is absent from the catalogue; and
// every voice list is filtered to exactly the selected source.

#if canImport(UIKit)
import XCTest
import CryptoKit
import FloeCore
import FloeProviders
import FloeSecurity
@testable import FloeApp

@MainActor
final class SpeechOutputSourceTests: XCTestCase {
    private struct Fixture {
        let name: String
        let defaults: UserDefaults
        let keychain: SourceTestKeychain
        let settings: TTSSettingsService
        func cleanup() { defaults.removePersistentDomain(forName: name) }
    }

    private func makeFixture() throws -> Fixture {
        let name = "speech-source-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let keychain = SourceTestKeychain()
        return Fixture(
            name: name, defaults: defaults, keychain: keychain,
            settings: TTSSettingsService(defaults: defaults, keychain: keychain))
    }

    private func volcProfile(
        route: TTSBillingRoute = .payAsYouGo,
        model: String = "doubao-seed-tts-2.0",
        voice: String = "zh_female_vv_uranus_bigtts"
    ) -> TTSSettingsSnapshot {
        TTSSettingsSnapshot(provider: .volcengine, billingRoute: route, modelID: model, voiceID: voice)
    }

    private func makeLocalModel(id: String, revision: String, voices: [String]) -> LocalSpeechModel {
        let bytes = Data(id.utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return LocalSpeechModel(
            id: id, title: "Synthetic \(id)", engine: "mossTTSNano", repository: "test/\(id)",
            revision: revision, license: "Apache-2.0", languages: ["zh", "en"],
            voices: voices.map { .init(id: $0, name: $0.capitalized, languages: ["zh", "en"]) },
            files: [.init(path: "weights.bin",
                          url: URL(string: "https://huggingface.co/test/\(id)/resolve/\(revision)/weights.bin")!,
                          sha256: hash, byteCount: Int64(bytes.count))],
            tokenizerRelativePath: nil, minimumMemoryBytes: nil,
            defaultVoiceID: voices.first, visibility: "visible")
    }

    // MARK: - Identity

    func testSourceIdentityIsTheExactBinding() {
        XCTAssertEqual(SpeechOutputSource(snapshot: .systemDefault), .system)
        XCTAssertEqual(SpeechOutputSource(snapshot: TTSSettingsSnapshot(provider: .onDevice, modelID: "m1", voiceID: "v1")).id,
                       "local.m1")
        let agent = SpeechOutputSource(snapshot: TTSSettingsSnapshot(provider: .volcengine, billingRoute: .agentPlan, modelID: "m", voiceID: "v"))
        let paygo = SpeechOutputSource(snapshot: TTSSettingsSnapshot(provider: .volcengine, billingRoute: .payAsYouGo, modelID: "m", voiceID: "v"))
        XCTAssertEqual(agent.id, "online.volcengine.agentPlan")
        XCTAssertNotEqual(agent, paygo, "The billing channel is part of the source identity")
    }

    func testAvailableSourcesListOnlyInstalledAndConfigured() {
        let installed = makeLocalModel(id: "moss-a", revision: String(repeating: "1", count: 40), voices: ["a-default"])
        let sources = SpeechOutputSource.available(
            installedVisibleModels: [installed],
            configuredProfiles: [volcProfile()])
        XCTAssertEqual(sources.map(\.id), ["system", "local.moss-a", "online.volcengine.payAsYouGo"])
        // Placeholder guard: non-cloud snapshots can never appear as online
        // sources even if a caller passes them by mistake.
        let guarded = SpeechOutputSource.available(
            installedVisibleModels: [],
            configuredProfiles: [.systemDefault, TTSSettingsSnapshot(provider: .onDevice, modelID: "x", voiceID: "v")])
        XCTAssertEqual(guarded, [.system])
    }

    // MARK: - Source selection keeps controls and saved choices

    func testSelectingOnlineSourceRestoresSavedVoiceAndKeepsControls() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        settings.update {
            $0.speechRateRatio = 1.6; $0.speechPitchSemitones = 2
            $0.autoReadEnabled = true; $0.allowBargeIn = false
        }
        var account = volcProfile()
        account.speechRateRatio = 0.6 // an older stored profile value
        try settings.saveProfile(account, credential: "synthetic-key")
        defer { try? settings.removeProfile(account) }

        XCTAssertTrue(settings.selectSource(.online(provider: .volcengine, route: .payAsYouGo)))
        XCTAssertEqual(settings.currentOutputSource, .online(provider: .volcengine, route: .payAsYouGo))
        XCTAssertEqual(settings.snapshot.voiceID, "zh_female_vv_uranus_bigtts")
        XCTAssertEqual(settings.snapshot.speechRateRatio, 1.6)
        XCTAssertEqual(settings.snapshot.speechPitchSemitones, 2)
        XCTAssertTrue(settings.snapshot.autoReadEnabled)
        XCTAssertFalse(settings.snapshot.allowBargeIn)

        XCTAssertTrue(settings.selectSource(.system))
        XCTAssertEqual(settings.currentOutputSource, .system)
        XCTAssertEqual(settings.snapshot.speechRateRatio, 1.6, "A source switch never resets the controls")

        XCTAssertTrue(settings.selectSource(.online(provider: .volcengine, route: .payAsYouGo)))
        XCTAssertEqual(settings.snapshot.voiceID, "zh_female_vv_uranus_bigtts",
                       "The source's saved voice is remembered")
    }

    func testSystemSourceRemembersItsChosenVoice() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        var chosen = TTSSettingsSnapshot.systemDefault
        chosen.voiceID = "com.apple.voice.synthetic-sara"
        settings.choose(chosen)
        let account = volcProfile()
        try settings.saveProfile(account, credential: "synthetic-key")
        defer { try? settings.removeProfile(account) }
        XCTAssertTrue(settings.selectSource(.online(provider: .volcengine, route: .payAsYouGo)))
        XCTAssertTrue(settings.selectSource(.system))
        XCTAssertEqual(settings.snapshot.voiceID, "com.apple.voice.synthetic-sara",
                       "Returning to the system source restores its own last voice")
    }

    func testSelectSourceNeverEntersAnUnconfiguredChannel() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        // Never configured at all.
        XCTAssertFalse(settings.selectSource(.online(provider: .volcengine, route: .agentPlan)))
        XCTAssertEqual(settings.currentOutputSource, .system)
        XCTAssertEqual(settings.snapshot.voiceID, "", "A rejected selection changes nothing")
        // Configuring one channel must not make the other one selectable.
        let account = volcProfile()
        try settings.saveProfile(account, credential: "synthetic-key")
        defer { try? settings.removeProfile(account) }
        XCTAssertFalse(settings.selectSource(.online(provider: .volcengine, route: .agentPlan)),
                       "A paid plan without its own key is never auto-entered")
        XCTAssertTrue(settings.selectSource(.online(provider: .volcengine, route: .payAsYouGo)))
    }

    func testSavingANewServiceNeverChangesTheCurrentSource() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        let account = TTSSettingsSnapshot(provider: .alibaba, billingRoute: .tokenPlan,
                                          modelID: "qwen-audio-3.0-tts-plus", voiceID: "synthetic-voice")
        try settings.saveProfile(account, credential: "synthetic-token-plan-key")
        defer { try? settings.removeProfile(account) }
        XCTAssertEqual(settings.currentOutputSource, .system,
                       "Adding and saving an inactive service never activates it")
        XCTAssertTrue(settings.outputSources.contains(.online(provider: .alibaba, route: .tokenPlan)),
                      "It appears as a selectable configured source")
        XCTAssertTrue(settings.selectSource(.online(provider: .alibaba, route: .tokenPlan)))
        XCTAssertEqual(settings.currentOutputSource, .online(provider: .alibaba, route: .tokenPlan))
    }

    func testRemovingTheActiveSourceReturnsToSystemIdentity() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        let account = volcProfile()
        try settings.saveProfile(account, credential: "synthetic-key")
        XCTAssertTrue(settings.selectSource(.online(provider: .volcengine, route: .payAsYouGo)))
        try settings.removeProfile(account)
        XCTAssertEqual(settings.currentOutputSource, .system)
        XCTAssertFalse(settings.selectSource(.online(provider: .volcengine, route: .payAsYouGo)),
                       "A deleted profile cannot be re-selected from its stale bucket")
    }

    func testSelectedSourcePersistsAcrossRelaunch() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        var account = volcProfile()
        try fixture.settings.saveProfile(account, credential: "synthetic-key")
        account.voiceID = "zh_female_xiaohe_uranus_bigtts"
        fixture.settings.choose(account)
        fixture.settings.update { $0.speechRateRatio = 1.25 }

        let reloaded = TTSSettingsService(defaults: fixture.defaults, keychain: fixture.keychain)
        XCTAssertEqual(reloaded.currentOutputSource, .online(provider: .volcengine, route: .payAsYouGo))
        XCTAssertEqual(reloaded.snapshot.voiceID, "zh_female_xiaohe_uranus_bigtts")
        XCTAssertEqual(reloaded.snapshot.speechRateRatio, 1.25)
        try reloaded.removeProfile(account)
    }

    // MARK: - Installed packs remember independent voices

    private struct PackFixture {
        let root: URL
        let name: String
        let defaults: UserDefaults
        let modelA: LocalSpeechModel
        let modelB: LocalSpeechModel
        let store: LocalSpeechModelStore
        let settings: TTSSettingsService
        func cleanup() { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
    }

    private nonisolated static func transferredDefaults(suiteName: String) throws -> sending UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    private func packFixture() throws -> PackFixture {
        let name = "speech-source-packs." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let revisionA = String(repeating: "7", count: 40)
        let revisionB = String(repeating: "8", count: 40)
        let modelA = makeLocalModel(id: "moss-a", revision: revisionA, voices: ["a-default", "a-other"])
        let modelB = makeLocalModel(id: "moss-b", revision: revisionB, voices: ["b-default"])
        let payloads: [String: Data] = [
            modelA.files[0].url.absoluteString: Data("pack-a".utf8),
            modelB.files[0].url.absoluteString: Data("pack-b".utf8),
        ]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = LocalSpeechModelStore(
            catalog: LocalSpeechCatalog(schemaVersion: 1, models: [modelA, modelB]),
            root: root.appendingPathComponent("models"),
            defaults: try Self.transferredDefaults(suiteName: name),
            downloader: PackDownloadFixture(root: root.appendingPathComponent("transfers"), payloads: payloads),
            transfersRoot: root.appendingPathComponent("transfers"))
        let settings = TTSSettingsService(
            defaults: defaults, keychain: KeychainStore(service: name, synchronizable: false),
            modelStore: store, loadValidator: { _, _ in .passed })
        return PackFixture(root: root, name: name, defaults: defaults,
                           modelA: modelA, modelB: modelB, store: store, settings: settings)
    }

    private func settled(_ store: LocalSpeechModelStore) async throws {
        for _ in 0..<300 {
            if !(await store.state().running) {
                try await Task.sleep(for: .milliseconds(30))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synthetic install did not finish")
    }

    func testLocalPacksRememberIndependentVoicesAndListAsSources() async throws {
        let fixture = try packFixture()
        defer { fixture.cleanup() }
        let settings = fixture.settings
        settings.update { $0.speechRateRatio = 1.4; $0.autoReadEnabled = true }
        await settings.install(fixture.modelA)
        try await settled(fixture.store)
        await settings.syncLocalSelection()
        await settings.install(fixture.modelB)
        try await settled(fixture.store)
        await settings.syncLocalSelection()

        XCTAssertEqual(settings.currentOutputSource, .local(modelID: "moss-a"),
                       "The first validated install lands on the pack's catalog default")
        XCTAssertEqual(settings.snapshot.voiceID, "a-default")
        XCTAssertTrue(Set(settings.outputSources.map(\.id)).isSuperset(of: ["system", "local.moss-a", "local.moss-b"]))

        settings.choose(TTSSettingsSnapshot(provider: .onDevice, billingRoute: .payAsYouGo,
                                            modelID: "moss-a", voiceID: "a-other"))
        XCTAssertTrue(settings.selectSource(.local(modelID: "moss-b")))
        XCTAssertEqual(settings.snapshot.modelID, "moss-b")
        XCTAssertEqual(settings.snapshot.voiceID, "b-default", "Pack B never inherits pack A's voice")

        XCTAssertTrue(settings.selectSource(.local(modelID: "moss-a")))
        XCTAssertEqual(settings.snapshot.voiceID, "a-other", "Pack A remembers its own choice")
        XCTAssertEqual(settings.snapshot.speechRateRatio, 1.4)
        XCTAssertTrue(settings.snapshot.autoReadEnabled)

        // An uninstalled pack is not offered and cannot be selected.
        XCTAssertFalse(settings.selectSource(.local(modelID: "moss-missing")))
        XCTAssertEqual(settings.currentOutputSource, .local(modelID: "moss-a"))
    }

    // MARK: - Voice filtering per source

    func testSystemOptionsContainOnlySystemVoices() {
        let catalog = [TTSSpeechVoice(voiceID: "en-US-Sara", displayName: "Sara", kind: .builtin)]
        let options = SpeechOutputVoices.options(
            for: .system, current: .systemDefault, localModel: nil,
            onlineProfile: volcProfile(), catalogVoices: catalog, savedVoiceDisplayName: nil)
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options[0].id, "apple/auto")
        XCTAssertEqual(options[0].snapshot, .systemDefault)
        XCTAssertTrue(options.allSatisfy { $0.snapshot.provider == .apple },
                      "The system source never shows cloud or local voices")
        XCTAssertEqual(options[1].snapshot.voiceID, "en-US-Sara")
    }

    func testLocalOptionsContainOnlyThatPacksVoices() {
        let model = makeLocalModel(id: "moss-a", revision: String(repeating: "1", count: 40),
                                   voices: ["a-default", "a-other"])
        let current = TTSSettingsSnapshot(provider: .onDevice, modelID: "moss-a", voiceID: "a-other")
        let options = SpeechOutputVoices.options(
            for: .local(modelID: "moss-a"), current: current, localModel: model,
            onlineProfile: nil, catalogVoices: [], savedVoiceDisplayName: nil)
        XCTAssertEqual(options.map(\.id), ["moss-a/a-default", "moss-a/a-other"])
        XCTAssertTrue(options.allSatisfy {
            $0.snapshot.provider == .onDevice && $0.snapshot.modelID == "moss-a"
        })
        // Another pack's voices never leak in.
        let other = SpeechOutputVoices.options(
            for: .local(modelID: "moss-b"), current: current, localModel: model,
            onlineProfile: nil, catalogVoices: [], savedVoiceDisplayName: nil)
        XCTAssertTrue(other.isEmpty)
    }

    func testOnlineOptionsKeepCustomSavedVoiceWithDisplayName() {
        let profile = volcProfile(model: "doubao-seed-tts-1.0", voice: "my_cloned_voice_v9")
        let options = SpeechOutputVoices.options(
            for: .online(provider: .volcengine, route: .payAsYouGo), current: profile,
            localModel: nil, onlineProfile: profile,
            catalogVoices: [], savedVoiceDisplayName: "我的克隆音色")
        XCTAssertEqual(options.count, 1, "A manual-ID voice stays selectable with an empty catalogue")
        XCTAssertEqual(options[0].title, "我的克隆音色")
        let value = options[0].snapshot
        XCTAssertEqual(value.provider, .volcengine)
        XCTAssertEqual(value.billingRoute, .payAsYouGo)
        XCTAssertEqual(value.modelID, "doubao-seed-tts-1.0")
        XCTAssertEqual(value.voiceID, "my_cloned_voice_v9")
    }

    func testOnlineOptionsShowCataloguePlusCustomWithoutOtherChannels() {
        let service = TTSSpeechService()
        let profile = volcProfile(voice: "my_cloned_voice_v9")
        let catalogue = service.builtinVoices(for: .volcengine, modelID: profile.modelID)
        let options = SpeechOutputVoices.options(
            for: .online(provider: .volcengine, route: .payAsYouGo), current: profile,
            localModel: nil, onlineProfile: profile,
            catalogVoices: catalogue, savedVoiceDisplayName: "Cloned")
        XCTAssertEqual(options.count, catalogue.count + 1)
        XCTAssertEqual(options.first?.id, "volcengine.payAsYouGo/my_cloned_voice_v9",
                       "The custom saved ID is preserved even when the catalogue lists voices")
        XCTAssertTrue(options.allSatisfy { $0.id.hasPrefix("volcengine.payAsYouGo/") },
                      "One channel's list never mixes another channel or provider")
        XCTAssertTrue(options.allSatisfy { $0.snapshot.provider == .volcengine && $0.snapshot.billingRoute == .payAsYouGo })
    }

    func testSourceTitleCarriesProviderAndChannel() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let account = volcProfile(route: .agentPlan, voice: "v")
        try fixture.settings.saveProfile(account, credential: "synthetic-agent")
        defer { try? fixture.settings.removeProfile(account) }
        let title = fixture.settings.outputSourceTitle(
            for: .online(provider: .volcengine, route: .agentPlan))
        XCTAssertTrue(title.contains(" · "), "The picker names the exact service and channel")
        XCTAssertEqual(fixture.settings.outputSourceTitle(for: .system),
                       FloeL10n.l("voice.settings.service.system"))
    }
}

/// Dictionary keychain used only by these tests; no Keychain, no network.
private final class SourceTestKeychain: KeychainProbeStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func store(account: String, secret: Data) throws {
        lock.lock(); defer { lock.unlock() }
        items[account] = secret
    }
    func read(account: String) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let value = items[account] else { throw KeychainStoreError.itemNotFound }
        return value
    }
    func delete(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        items.removeValue(forKey: account)
    }
}

private actor PackDownloadFixture: LocalSpeechDownloading {
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
#endif
