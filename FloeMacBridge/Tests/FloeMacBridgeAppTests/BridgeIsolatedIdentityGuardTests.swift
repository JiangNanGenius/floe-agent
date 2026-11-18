#if os(macOS)
import CryptoKit
import Foundation
import Testing
import FloeMacBridgeProtocol
@testable import FloeMacBridgeApp

@Suite("Separate Bridge identity guard")
struct BridgeIsolatedIdentityGuardTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-bridge-isolated-guard-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test("A missing legacy key never creates a replacement for existing pairings")
    func missingLegacyKeyKeepsPairings() {
        var created = false
        #expect(throws: BridgeFailure.self) {
            _ = try BridgeService.legacySigningKey(hasPairings: true, read: { _, _ in nil }, create: { _ in
                created = true
                return Curve25519.Signing.PrivateKey()
            })
        }
        #expect(!created)
    }

    @Test("The legacy server uses the same key for both first launch and paired launch")
    func existingLegacyKeyIsReused() throws {
        let original = Curve25519.Signing.PrivateKey()
        for hasPairings in [false, true] {
            let observed = try BridgeService.legacySigningKey(hasPairings: hasPairings, read: { service, account in
                #expect(service == "org.floeagent.bridge.server" && account == "identity-v1")
                return original.rawRepresentation
            }, create: { _ in
                Issue.record("An established server key was regenerated")
                return Curve25519.Signing.PrivateKey()
            })
            #expect(observed.publicKey.rawRepresentation == original.publicKey.rawRepresentation)
        }
    }

    @Test("isolated nil key is refused before malformed pairing data is read")
    func isolatedMissingKeyFailsBeforeStoreRead() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try BridgePaths(isolated: BridgeIsolatedProfile(home: root))
        let pairURL = paths.root.appendingPathComponent("State/paired-clients.json")
        let malformed = Data("not JSON".utf8)
        try malformed.write(to: pairURL)
        do {
            _ = try BridgeService(paths: paths)
            Issue.record("An isolated service without an explicit key was allowed")
        } catch BridgeFailure.remote(let message) {
            #expect(message == "The separate Bridge requires an explicitly resolved identity.")
        } catch {
            Issue.record("Wrong failure before pairing data: \(error)")
        }
        #expect(try Data(contentsOf: pairURL) == malformed)
    }

    @Test("isolated explicit key can initialize without real Keychain")
    func isolatedExplicitKeyStillWorks() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try BridgePaths(isolated: BridgeIsolatedProfile(home: root))
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        _ = try BridgeService(paths: paths, signingKey: key)
    }

    @Test("legacy nil key still reports malformed pairing data before any keychain access")
    func legacyDefaultOrderingIsUnchanged() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try BridgePaths(home: root)
        let pairURL = paths.root.appendingPathComponent("State/paired-clients.json")
        let malformed = Data("not JSON".utf8)
        try malformed.write(to: pairURL)
        do {
            _ = try BridgeService(paths: paths)
            Issue.record("Malformed legacy pairing data was accepted")
        } catch BridgeFailure.remote(let message) {
            #expect(message == "The existing Bridge pairing store is invalid; it was not modified.")
        } catch {
            Issue.record("Unexpected legacy failure: \(error)")
        }
        #expect(try Data(contentsOf: pairURL) == malformed)
    }
}
#endif
