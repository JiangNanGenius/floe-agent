#if canImport(UIKit)
import XCTest
import CryptoKit
import FloeCore
import FloeSecurity
@testable import FloeApp

@MainActor
final class TTSSettingsServiceTests: XCTestCase {
    func testSavingOnlineAccountDoesNotSelectIt() throws {
        let name = "tts-settings-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let keychain = KeychainStore(service: name, synchronizable: false)
        let settings = TTSSettingsService(defaults: defaults, keychain: keychain)
        var account = TTSSettingsSnapshot.systemDefault
        account.provider = .openAI; account.modelID = "gpt-4o-mini-tts"; account.voiceID = "alloy"
        try settings.saveProfile(account, credential: "synthetic-test-key")
        defer { try? settings.removeProfile(account) }
        XCTAssertEqual(settings.snapshot.provider, .apple)
        XCTAssertEqual(settings.configuredProfiles.count, 1)
        settings.choose(account)
        XCTAssertEqual(settings.snapshot.provider, .openAI)
    }

    func testFirstSuccessfulInstallSelectsVivianAndReinstallKeepsChoice() async throws {
        let fixture = try fixture()
        defer { fixture.cleanup() }
        await fixture.settings.install(fixture.model)
        try await settled(fixture)
        XCTAssertEqual(fixture.settings.snapshot.provider, .onDevice)
        XCTAssertEqual(fixture.settings.snapshot.voiceID, "vivian")
        fixture.settings.update { $0.voiceID = "serena" }
        await fixture.settings.install(fixture.model)
        try await settled(fixture)
        XCTAssertEqual(fixture.settings.snapshot.voiceID, "serena")
    }

    func testSelectionChangedDuringDownloadWins() async throws {
        let fixture = try fixture(delay: true)
        defer { fixture.cleanup() }
        await fixture.settings.install(fixture.model)
        fixture.settings.update { $0.voiceID = "explicit-system-voice" }
        try await settled(fixture)
        XCTAssertEqual(fixture.settings.snapshot.provider, .apple)
        XCTAssertEqual(fixture.settings.snapshot.voiceID, "explicit-system-voice")
    }

    private struct Fixture {
        let root: URL
        let name: String
        let defaults: UserDefaults
        let model: LocalSpeechModel
        let store: LocalSpeechModelStore
        let settings: TTSSettingsService
        func cleanup() { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
    }
    private func fixture(delay: Bool = false) throws -> Fixture {
        let name = "tts-install-test." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bytes = Data("synthetic-model".utf8)
        let revision = String(repeating: "1", count: 40)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let model = LocalSpeechModel(id: "synthetic-qwen", title: "Synthetic", engine: "qwen3TTS", repository: "test/model", revision: revision, license: "Apache-2.0", languages: ["zh"], voices: [.init(id: "vivian", name: "Vivian", languages: ["zh"])], files: [.init(path: "weights.bin", url: URL(string: "https://huggingface.co/test/model/resolve/\(revision)/weights.bin")!, sha256: hash, byteCount: Int64(bytes.count))], tokenizerRelativePath: "tokenizer", minimumMemoryBytes: nil)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [model]), root: root.appendingPathComponent("models"), defaults: defaults, downloader: InstallDownloadFixture(root: root, bytes: bytes, delay: delay))
        let settings = TTSSettingsService(defaults: defaults, keychain: KeychainStore(service: name, synchronizable: false), modelStore: store)
        return Fixture(root: root, name: name, defaults: defaults, model: model, store: store, settings: settings)
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
#endif
