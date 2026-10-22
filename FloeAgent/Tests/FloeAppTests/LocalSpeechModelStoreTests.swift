#if canImport(UIKit)
import XCTest
import CryptoKit
@testable import FloeApp

@MainActor
final class LocalSpeechModelStoreTests: XCTestCase {
    func testRejectedDownloadPreservesInstalledModelAndRetryCanRecover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = Data("verified-model".utf8)
        let model = fixture(bytes)
        let downloader = DownloadFixture(root: root.appendingPathComponent("transfers"), bytes: bytes)
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [model]), root: root.appendingPathComponent("models"), defaults: UserDefaults(suiteName: suite)!, downloader: downloader)
        await store.beginInstallation(model)
        try await waitForCompletion(store)
        let installed = await store.isInstalled(model)
        XCTAssertTrue(installed)
        await downloader.setCorrupt(true)
        await store.beginInstallation(model)
        try await waitForCompletion(store)
        let failure = await store.state().failureKey
        XCTAssertNotNil(failure)
        let preserved = await store.isInstalled(model)
        XCTAssertTrue(preserved, "A failed replacement must not destroy the good model")
        await downloader.setCorrupt(false)
        await store.beginInstallation(model)
        try await waitForCompletion(store)
        let retryFailure = await store.state().failureKey
        XCTAssertNil(retryFailure)
        try await store.remove(model)
        let removed = await store.isInstalled(model)
        XCTAssertFalse(removed)
    }

    func testCancellationDoesNotInstallIncompleteFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = Data("model".utf8), model = fixture(Data("model".utf8))
        let downloader = DownloadFixture(root: root.appendingPathComponent("transfers"), bytes: bytes, delays: true)
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [model]), root: root.appendingPathComponent("models"), defaults: UserDefaults(suiteName: suite)!, downloader: downloader)
        await store.beginInstallation(model)
        await store.cancelInstallation()
        try await waitForCompletion(store)
        let installed = await store.isInstalled(model)
        XCTAssertFalse(installed)
    }

    func testVoiceMetadataUpdateKeepsVerifiedModelFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local-speech-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bytes = Data("verified-model".utf8)
        let model = fixture(bytes)
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [model]), root: root.appendingPathComponent("models"), defaults: UserDefaults(suiteName: suite)!, downloader: DownloadFixture(root: root.appendingPathComponent("transfers"), bytes: bytes))
        await store.beginInstallation(model)
        try await waitForCompletion(store)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        object["title"] = "Updated display name"
        object["languages"] = ["zh", "en", "ja"]
        let updated = try JSONDecoder().decode(LocalSpeechModel.self, from: JSONSerialization.data(withJSONObject: object))
        let stillInstalled = await store.isInstalled(updated)
        XCTAssertTrue(stillInstalled, "Voice metadata updates must not require downloading the same model again")
        var files = try XCTUnwrap(object["files"] as? [[String: Any]])
        files[0]["sha256"] = String(repeating: "0", count: 64)
        object["files"] = files
        let changed = try JSONDecoder().decode(LocalSpeechModel.self, from: JSONSerialization.data(withJSONObject: object))
        let differentAssets = await store.isInstalled(changed)
        XCTAssertFalse(differentAssets, "Asset changes still require complete verification and installation")
    }

    func testCatalogRejectsTraversalAndUnpinnedAssetURLs() async {
        var model = fixture(Data("model".utf8))
        model = LocalSpeechModel(id: model.id, title: model.title, engine: model.engine, repository: model.repository, revision: model.revision, license: model.license, languages: model.languages, voices: model.voices, files: [.init(path: "../escape", url: URL(string: "https://huggingface.co/test/model/resolve/main/weights.bin")!, sha256: String(repeating: "1", count: 64), byteCount: 5)], tokenizerRelativePath: nil, minimumMemoryBytes: nil)
        let store = LocalSpeechModelStore(catalog: LocalSpeechCatalog(schemaVersion: 1, models: [model]))
        do { _ = try await store.catalog(); XCTFail("Malformed catalog accepted") }
        catch { XCTAssertEqual(error as? LocalSpeechModelStore.Failure, .corrupt) }
    }

    private func fixture(_ bytes: Data) -> LocalSpeechModel {
        let revision = String(repeating: "1", count: 40)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return LocalSpeechModel(id: "test-tts", title: "Synthetic test", engine: "mossTTSNano", repository: "test/model", revision: revision, license: "Apache-2.0", languages: ["zh", "en"], voices: [.init(id: "default", name: "Test", languages: ["zh", "en"])], files: [.init(path: "weights.bin", url: URL(string: "https://huggingface.co/test/model/resolve/\(revision)/weights.bin")!, sha256: hash, byteCount: Int64(bytes.count))], tokenizerRelativePath: nil, minimumMemoryBytes: nil)
    }

    private func waitForCompletion(_ store: LocalSpeechModelStore) async throws {
        for _ in 0..<500 {
            if !(await store.state().running) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Synthetic installation did not settle")
    }
}

private actor DownloadFixture: LocalSpeechDownloading {
    let root: URL
    let bytes: Data
    let delays: Bool
    private var corrupt = false
    init(root: URL, bytes: Data, delays: Bool = false) { self.root = root; self.bytes = bytes; self.delays = delays }
    func setCorrupt(_ value: Bool) { corrupt = value }
    func download(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        if delays { try await Task.sleep(for: .seconds(30)) }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("cached-download")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        var result = bytes
        if corrupt { result[0] ^= 1 }
        try result.write(to: file)
        progress(Int64(result.count))
        return file
    }
}
#endif
