import Foundation
import Testing
import WAT
import Crypto
import FloeCore
import FloeTools
@testable import FloeExecution

/// End-to-end signed WASM capability flow at the installer layer: the
/// verified SignedWasmCapabilityStore catalog is merged into
/// CapabilityInstaller discovery, and install/execute/remove/cancel go
/// through the same store the shell commands dispatch to.
@Suite("Signed WASM capability installer flow")
struct WasmCapabilityInstallerTests {
    private struct Fixture {
        var store: SignedWasmCapabilityStore
        var entry: SignedWasmCatalog.Entry
        var moduleBytes: Data
    }

    private func makeFixture(root: URL, id: String = "floe/lua", command: String = "floe-lua", version: String = "5.4.8") throws -> Fixture {
        let bytes = Data(try wat2wasm("(module (func (export \"_start\")))"))
        let entry = SignedWasmCatalog.Entry(
            id: id, version: version, command: command,
            url: URL(string: "https://example.invalid/\(command).wasm")!,
            sha256: FloeDigest.sha256Hex(bytes),
            minimumAppVersion: "1.6.7"
        )
        let data = try JSONEncoder().encode(SignedWasmCatalog(packages: [entry]))
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Data("FLOE-CAPABILITY-CATALOG-V1\n".utf8) + data)
        let store = try SignedWasmCapabilityStore(
            catalogData: data, signature: signature,
            publicKey: key.publicKey.rawRepresentation,
            appVersion: "1.6.7",
            root: root.appendingPathComponent("wasm", isDirectory: true)
        ) { _, target in
            try bytes.write(to: target)
        }
        return Fixture(store: store, entry: entry, moduleBytes: bytes)
    }

    private func makeInstaller(root: URL, store: SignedWasmCapabilityStore) -> CapabilityInstaller {
        CapabilityInstaller(
            catalog: CapabilityCatalog(entries: []),
            pythonInstaller: nil,
            http: HTTPRequestService(),
            packagesRoot: root.appendingPathComponent("packages", isDirectory: true),
            wasmStore: store
        )
    }

    @Test func installerDiscoversOnlyVerifiedCatalogEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)
        let installer = makeInstaller(root: root, store: fixture.store)
        let matches = await installer.search("lua")
        #expect(matches.contains { $0.id == "floe/lua" && $0.kind == .wasmCommand && $0.tier == .wasm })
        // The canonical command name resolves through the merged alias.
        #expect(await installer.show("floe-lua")?.id == "floe/lua")
        // Nothing is invented: an unrelated id stays unknown.
        #expect(await installer.show("lua") == nil)
        #expect(await installer.show("floe/python") == nil)
    }

    @Test func installExecuteRemoveRoundTripsThroughTheStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)
        let installer = makeInstaller(root: root, store: fixture.store)

        let receipt = try await installer.install(
            id: "floe/lua", purpose: "qualification install",
            capabilities: [], cancellation: nil
        )
        #expect(receipt.kind == .wasmCommand)
        #expect(await fixture.store.installedIDs() == ["floe/lua"])
        #expect(await installer.installedIDs().contains("floe/lua"))

        // The same store the shell `floe-lua`/`lua` commands dispatch to runs it.
        let outcome = await fixture.store.run(
            command: "floe-lua", arguments: ["--version"], stdin: nil,
            environment: [:], rootURL: root, timeout: 5, maxOutputBytes: 1024
        )
        guard case .exited(let code, _, _, _, _, _) = outcome else {
            Issue.record("WASM command did not run: \(outcome)"); return
        }
        #expect(code == 0)

        let removal = try await installer.remove(id: "floe/lua")
        #expect(removal.kind == .wasmCommand)
        #expect(await fixture.store.installedIDs().isEmpty)
        #expect(await installer.installedIDs().isEmpty)
        let missing = await fixture.store.run(
            command: "floe-lua", arguments: [], stdin: nil,
            environment: [:], rootURL: root
        )
        guard case .failed = missing else {
            Issue.record("Removed command still ran: \(missing)"); return
        }
    }

    @Test func installRequiresAPurposeForNetworkTiers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)
        let installer = makeInstaller(root: root, store: fixture.store)
        await #expect(throws: FloeError.self) {
            try await installer.install(id: "floe/lua", purpose: nil, capabilities: [], cancellation: nil)
        }
        await #expect(throws: FloeError.self) {
            try await installer.install(id: "floe/lua", purpose: "  ", capabilities: [], cancellation: nil)
        }
        #expect(await fixture.store.installedIDs().isEmpty)
    }

    @Test func cancelledInstallLeavesNoArtifactOrReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try makeFixture(root: root)
        let installer = makeInstaller(root: root, store: fixture.store)
        let token = CancellationToken()
        token.cancel()
        await #expect(throws: FloeError.self) {
            try await installer.install(
                id: "floe/lua", purpose: "qualification install",
                capabilities: [], cancellation: token
            )
        }
        #expect(await fixture.store.installedIDs().isEmpty)
        #expect(await installer.installedIDs().isEmpty)
        let wasmRoot = root.appendingPathComponent("wasm", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: wasmRoot.path)) ?? []
        #expect(entries.isEmpty)
    }

    @Test func installerWithoutAStoreRejectsWasmInstallsHonestly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = CapabilityInstaller(
            catalog: CapabilityCatalog(entries: []),
            pythonInstaller: nil,
            http: HTTPRequestService(),
            packagesRoot: root.appendingPathComponent("bare", isDirectory: true)
        )
        #expect(await bare.show("floe/lua") == nil)
        await #expect(throws: FloeError.self) {
            try await bare.install(id: "floe/lua", purpose: "qualification install", capabilities: [], cancellation: nil)
        }
    }
}
