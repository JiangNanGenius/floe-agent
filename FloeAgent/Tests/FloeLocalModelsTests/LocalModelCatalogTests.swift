import Foundation
import Testing
@testable import FloeLocalModelCatalog

@Suite("Local model catalog")
struct LocalModelCatalogTests {
    @Test("Curated entries are downloadable Apache models")
    func curatedEntries() {
        #expect(CuratedLocalModelCatalog.entries.count >= 3)
        for entry in CuratedLocalModelCatalog.entries {
            #expect(entry.modelURL.scheme == "https")
            #expect(entry.license == "Apache-2.0")
            #expect(entry.supportsToolCalling)
            #expect(entry.approximateDownloadBytes > 1_000_000_000)
        }
    }

    @Test("GGUF validation uses file signature")
    func ggufSignature() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let valid = directory.appendingPathComponent("model.gguf")
        try Data([0x47, 0x47, 0x55, 0x46, 0, 0, 0, 0]).write(to: valid)
        try LocalModelStore.validateGGUF(valid)

        let invalid = directory.appendingPathComponent("model.bin")
        try Data("not a model".utf8).write(to: invalid)
        #expect(throws: LocalModelStore.StoreError.self) {
            try LocalModelStore.validateGGUF(invalid)
        }
    }

    @Test("Resume records are discovered without treating unknown directories as models")
    func discoversResumeRecords() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let knownID = try #require(CuratedLocalModelCatalog.entries.first?.id)
        let known = root.appendingPathComponent(".downloads/\(knownID)", isDirectory: true)
        let unknown = root.appendingPathComponent(".downloads/not-in-catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: known, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: known.appendingPathComponent("weights.resume"))
        try Data([1, 2, 3]).write(to: unknown.appendingPathComponent("weights.resume"))

        let resumable = await LocalModelStore(root: root).resumableModelIDs()
        #expect(resumable == Set([knownID]))
    }

    @Test("Inference resource policy preserves headroom and adapts offload")
    func inferenceResourcePolicy() {
        let gib: UInt64 = 1_073_741_824
        #expect(LocalInferenceResourcePolicy.canLoad(
            mappedBytes: 4 * gib,
            physicalMemoryBytes: 8 * gib
        ))
        #expect(!LocalInferenceResourcePolicy.canLoad(
            mappedBytes: 6 * gib,
            physicalMemoryBytes: 8 * gib
        ))

        let constrained = LocalInferenceResourcePolicy.profile(
            mappedBytes: 4 * gib,
            physicalMemoryBytes: 8 * gib
        )
        #expect(constrained.contextSize == 3_072)
        #expect(constrained.batchSize == 96)
        #expect(constrained.gpuLayers == 16)

        let roomy = LocalInferenceResourcePolicy.profile(
            mappedBytes: 3 * gib,
            physicalMemoryBytes: 16 * gib
        )
        #expect(roomy.contextSize == 4_096)
        #expect(roomy.gpuLayers == 99)
        #expect(roomy.maximumOutputTokens == 1_024)
    }
}
