import Foundation
import Testing
import FloeCore
import FloeMedia

@Suite("Model artifact readiness and ownership")
struct ModelArtifactTests {
    private func model(path: String = "weights.bin", status: String = "ready", size: Int64 = 7) -> ModelArtifact {
        .init(id: "floe/test", version: "1.0.0", kind: "coreml", capability: "video.restore",
              files: [.init(path: path, url: "https://example.invalid/weights", sha256: FloeDigest.sha256Hex(Data("weights".utf8)), sizeBytes: size)],
              license: "MIT", status: status)
    }
    @Test func rejectsPendingAndTraversalBeforeDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelArtifactStore(rootURL: root) { _, _ in
            Issue.record("Invalid artifacts must not initiate downloads")
            return Data()
        }
        for artifact in [model(status: "pending-assets"), model(path: "../outside"), model(path: "/outside")] {
            await #expect(throws: (any Error).self) { try await store.install(artifact, scope: .shared, cancellation: nil) }
        }
        #expect(await store.installed().isEmpty)
    }
    @Test func validatesSizeAndRestoresInstalledStateAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelArtifactStore(rootURL: root) { _, _ in Data("weights".utf8) }
        await #expect(throws: (any Error).self) { try await store.install(model(size: 8), scope: .shared, cancellation: nil) }
        let record = try await store.install(model(), scope: .shared, cancellation: nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: record.rootPath).appendingPathComponent("weights.bin")) == Data("weights".utf8))
        let reopened = ModelArtifactStore(rootURL: root) { _, _ in Data() }
        #expect(await reopened.installed().count == 1)
        try await reopened.remove(id: record.id)
        #expect(await reopened.installed().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: record.rootPath))
    }
    @Test func corruptRegistryIsNotOverwrittenByInstall() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("installed-models.json")
        try Data("broken".utf8).write(to: manifest)
        let store = ModelArtifactStore(rootURL: root) { _, _ in Data("weights".utf8) }
        await #expect(throws: (any Error).self) { try await store.install(model(), scope: .shared, cancellation: nil) }
        #expect(try String(contentsOf: manifest, encoding: .utf8) == "broken")
    }
}
