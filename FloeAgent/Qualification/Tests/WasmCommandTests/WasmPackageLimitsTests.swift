import Foundation
import Testing
import WAT
import Crypto
import FloeCore
import FloeTools
import FloeExecution

/// Unit tests for the per-package limits that let a signed catalog entry carry
/// interpreter-class bounds without weakening the utility defaults.
///
/// Integrated 2026-09-19 into the qualification host; the app-side
/// FloeAgent/Tests/FloeExecutionTests target is out of this task's scope.
@Suite("Signed WASM package limits")
struct WasmPackageLimitsTests {
    private func module(_ wat: String, root: URL) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("test.wasm")
        try Data(wat2wasm(wat)).write(to: url)
        return url
    }

    private func signedCatalog(entry: SignedWasmCatalog.Entry, key: Curve25519.Signing.PrivateKey) throws -> (Data, Data) {
        let data = try JSONEncoder().encode(SignedWasmCatalog(packages: [entry]))
        return (data, try key.signature(for: Data("FLOE-CAPABILITY-CATALOG-V1\n".utf8) + data))
    }

    private func entry(limits: Bool, moduleBytes: Data) -> SignedWasmCatalog.Entry {
        var value = SignedWasmCatalog.Entry(
            id: "floe/test", version: "1.0.0", command: "floe-test",
            url: URL(string: "https://example.invalid/floe-test.wasm")!,
            sha256: FloeDigest.sha256Hex(moduleBytes),
            minimumAppVersion: "1.6.7")
        if limits {
            value.moduleMaxBytes = 8 * 1024 * 1024
            value.memoryMaxBytes = 256 * 1024 * 1024
            value.defaultTimeoutSeconds = 120
        }
        return value
    }

    @Test func defaultEntryKeepsTheHistoricalUtilityBounds() {
        let entry = entry(limits: false, moduleBytes: Data("x".utf8))
        #expect(entry.resolvedModuleMaxBytes == 4 * 1024 * 1024)
        #expect(entry.resolvedMemoryMaxBytes == 64 * 1024 * 1024)
        #expect(entry.resolvedDefaultTimeoutSeconds == 30)
    }

    @Test func signatureVerificationRejectsOutOfRangeLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let bytes = Data(try wat2wasm("(module (func (export \"_start\")))"))
        for mutate in [
            { (value: inout SignedWasmCatalog.Entry) in value.moduleMaxBytes = 1024 * 1024 * 1024 },
            { (value: inout SignedWasmCatalog.Entry) in value.moduleMaxBytes = 1024 },
            { (value: inout SignedWasmCatalog.Entry) in value.memoryMaxBytes = 8 * 1024 * 1024 * 1024 },
            { (value: inout SignedWasmCatalog.Entry) in value.defaultTimeoutSeconds = 3600 },
        ] {
            var value = entry(limits: true, moduleBytes: bytes)
            mutate(&value)
            let (data, signature) = try signedCatalog(entry: value, key: key)
            #expect(throws: Error.self) {
                try SignedWasmCatalog.verify(data: data, signature: signature,
                                             publicKey: key.publicKey.rawRepresentation, appVersion: "1.7.1")
            }
        }
    }

    @Test func runtimeRefusesAModuleAboveItsSignedLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("large.wasm")
        try (Data([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]) + Data(repeating: 0, count: 2 * 1024 * 1024)).write(to: url)
        let outcome = await WasmKitCommandRuntime().run(
            moduleURL: url, arguments: [], stdin: nil, environment: [:], rootURL: root,
            timeout: 5, maxOutputBytes: 1024, moduleMaxBytes: 1024 * 1024, memoryMaxBytes: 64 * 1024 * 1024)
        guard case .failed(let message) = outcome else {
            Issue.record("An oversized module must be refused, got: \(outcome)"); return
        }
        #expect(message.contains("size limit"))
    }

    @Test func installedReceiptSurvivesAddedLimitMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = Curve25519.Signing.PrivateKey()
        let source = try module("(module (func (export \"_start\")))", root: root)
        let bytes = try Data(contentsOf: source)
        let legacy = try signedCatalog(entry: entry(limits: false, moduleBytes: bytes), key: key)
        let store = try SignedWasmCapabilityStore(
            catalogData: legacy.0, signature: legacy.1,
            publicKey: key.publicKey.rawRepresentation, appVersion: "1.6.7",
            root: root.appendingPathComponent("installed")) { _, target, _ in try bytes.write(to: target) }
        try await store.install(id: "floe/test", cancellation: nil)
        #expect(await store.installedIDs() == ["floe/test"])

        // The same artifact re-signed with an interpreter-class limit block
        // must keep the existing receipt valid.
        let updated = try signedCatalog(entry: entry(limits: true, moduleBytes: bytes), key: key)
        let upgraded = try SignedWasmCapabilityStore(
            catalogData: updated.0, signature: updated.1,
            publicKey: key.publicKey.rawRepresentation, appVersion: "1.7.1",
            root: root.appendingPathComponent("installed")) { _, target, _ in try bytes.write(to: target) }
        #expect(await upgraded.installedIDs() == ["floe/test"])
    }
}
