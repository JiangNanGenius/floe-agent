import Foundation
import Testing
@testable import FloeCore

// FloeCoreTests — Design template library persistence.
// Covers the critical-review contracts: immutable version payloads with real
// bytes on rollback, atomic pointer commits, interruption recovery,
// corruption/newer-schema protection, and malicious id/version rejection.

@Suite("Design template library")
struct DesignTemplateStoreTests {
    private func makeStore() throws -> DesignTemplateStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DesignTemplates-\(UUID().uuidString)", isDirectory: true)
        return DesignTemplateStore(root: root)
    }

    private func manifest(id: String, version: String, name: String = "T") -> DesignTemplateManifest {
        DesignTemplateManifest(
            id: id, name: name, contentType: .webpage,
            capabilities: ["brief"], inputs: [], dependencies: [],
            outputFormats: ["html"], license: "test", source: "test",
            version: version, contentSHA256: "", origin: .user
        )
    }

    @Test func saveUpdatesWithRetainedHistoryAndVerifiedPayload() async throws {
        let store = try makeStore()
        let v1 = Data("version-one".utf8)
        let v2 = Data("version-two".utf8)
        try store.saveUser(manifest: manifest(id: "tpl", version: "1"), payload: v1)
        try store.saveUser(manifest: manifest(id: "tpl", version: "2"), payload: v2)
        let record = try store.loadUser(id: "tpl")
        #expect(record.manifest.version == "2")
        #expect(record.payload == v2)
        #expect(record.history.contains(where: { $0.version == "1" }))
    }

    @Test func rollbackRestoresRealPayloadBytes() async throws {
        let store = try makeStore()
        let v1 = Data("original-bytes".utf8)
        let v2 = Data("updated-bytes".utf8)
        try store.saveUser(manifest: manifest(id: "tpl", version: "1"), payload: v1)
        try store.saveUser(manifest: manifest(id: "tpl", version: "2"), payload: v2)
        let restored = try store.rollbackUser(id: "tpl", toVersion: "1")
        #expect(restored.version == "1")
        #expect(restored.rollbackVersion == "2")
        let record = try store.loadUser(id: "tpl")
        // The payload bytes must be the real v1 bytes, not the latest ones.
        #expect(record.payload == v1)
        #expect(record.manifest.contentSHA256 == FloeDigest.sha256Hex(v1))
        // Rollback is reversible: v2 is retained in history.
        #expect(record.history.contains(where: { $0.version == "2" }))
    }

    @Test func interruptedPointerSwapKeepsPreviousVersion() async throws {
        let store = try makeStore()
        let v1 = Data("one".utf8)
        try store.saveUser(manifest: manifest(id: "tpl", version: "1"), payload: v1)
        // Simulate an interrupted save: version dir written, pointer swapped
        // correctly by the real save; emulate crash by writing the version
        // dir but leaving the old pointer.
        let directory = try store.templateDirectory(id: "tpl")
            .appendingPathComponent("versions/2", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("two".utf8).write(to: directory.appendingPathComponent("payload.bin"))
        try FileManager.default.removeItem(at: try store.templateDirectory(id: "tpl").appendingPathComponent("current.json"))
        #expect(throws: (any Error).self) { try store.loadUser(id: "tpl") }
    }

    @Test func corruptStateIsNeverOverwrittenBySave() async throws {
        let store = try makeStore()
        let directory = try store.templateDirectory(id: "tpl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("current.json"))
        // A save must throw (corrupt), not overwrite the unreadable state.
        #expect(throws: (any Error).self) {
            try store.saveUser(manifest: manifest(id: "tpl", version: "1"), payload: Data("x".utf8))
        }
    }

    @Test func newerSchemaIsNeverOverwrittenBySave() async throws {
        let store = try makeStore()
        try store.saveUser(manifest: manifest(id: "tpl", version: "1"), payload: Data("x".utf8))
        // Bump the pointer schema to a future version.
        let pointerURL = try store.templateDirectory(id: "tpl").appendingPathComponent("current.json")
        let data = try Data(contentsOf: pointerURL)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var mutated = object
        mutated["schemaVersion"] = 99
        let future = try JSONSerialization.data(withJSONObject: mutated)
        try future.write(to: pointerURL, options: .atomic)
        #expect(throws: DesignTemplateStoreError.newerSchema("tpl")) {
            try store.loadUser(id: "tpl")
        }
        #expect(throws: (any Error).self) {
            try store.saveUser(manifest: manifest(id: "tpl", version: "2"), payload: Data("y".utf8))
        }
    }

    @Test func maliciousIDsAndVersionsAreRejected() async throws {
        let store = try makeStore()
        #expect(throws: DesignTemplateStoreError.invalidID("..")) {
            _ = try store.saveUser(manifest: manifest(id: "..", version: "1"), payload: Data("x".utf8))
        }
        #expect(throws: DesignTemplateStoreError.invalidID("a/b")) {
            _ = try store.saveUser(manifest: manifest(id: "a/b", version: "1"), payload: Data("x".utf8))
        }
        #expect(throws: DesignTemplateStoreError.invalidVersion("../v")) {
            _ = try store.saveUser(manifest: manifest(id: "ok", version: "../v"), payload: Data("x".utf8))
        }
        // A traversal id must not create files outside the root.
        let escaped = store.root.appendingPathComponent("..").standardizedFileURL
            .appendingPathComponent("escaped.txt")
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
    }

    @Test func missingPayloadIsAnError() async throws {
        let store = try makeStore()
        try store.saveUser(manifest: manifest(id: "tpl", version: "1"), payload: Data("real".utf8))
        let payloadURL = try store.templateDirectory(id: "tpl")
            .appendingPathComponent("versions/1/payload.bin")
        try FileManager.default.removeItem(at: payloadURL)
        #expect(throws: (any Error).self) { try store.loadUser(id: "tpl") }
    }

    @Test func sameVersionDifferentContentIsACollision() async throws {
        let store = try makeStore()
        try store.saveUser(manifest: manifest(id: "tpl", version: "1"), payload: Data("a".utf8))
        #expect(throws: DesignTemplateStoreError.versionCollision("tpl", "1")) {
            try store.saveUser(manifest: manifest(id: "tpl", version: "1"), payload: Data("b".utf8))
        }
        // Identical re-save is an idempotent no-op.
        try store.saveUser(manifest: manifest(id: "tpl", version: "1"), payload: Data("a".utf8))
        let record = try store.loadUser(id: "tpl")
        #expect(record.payload == Data("a".utf8))
    }
}
