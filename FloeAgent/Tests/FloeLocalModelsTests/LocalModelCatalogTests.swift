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
}
