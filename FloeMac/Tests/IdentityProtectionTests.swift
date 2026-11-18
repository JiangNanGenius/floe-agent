// Standalone macOS identity/pairing regression tests. Compile alongside the
// production identity and control sources; this executable never opens the
// Keychain or starts Bridge. Every file it creates lives under a unique temp
// directory and is removed on exit.
import CryptoKit
import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw TestFailure(description: message) }
}

private func requireThrows(_ message: String, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch {
        return
    }
    throw TestFailure(description: message)
}

// Mirrors the persisted BridgeService.Pair shape, including the legacy
// optional fields. JSONEncoder uses the same default Data and Date encoding.
private struct StoredPair: Encodable {
    let key: Data
    let name: String
    let acceptedAt: Date
    let verification: String?
    let nonce: String?
}

@main
private enum IdentityProtectionTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeMacIdentityProtection-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        try pinCreationAndMatching(root.appendingPathComponent("pin-valid", isDirectory: true))
        try unknownPinSchemaDoesNotRecreate(root.appendingPathComponent("pin-schema", isDirectory: true))
        try challengeMustVerifyBeforePin(root.appendingPathComponent("challenge", isDirectory: true))
        try corruptPinDoesNotRecreate(root.appendingPathComponent("pin-corrupt", isDirectory: true))
        try unreadablePinDoesNotRecreate(root.appendingPathComponent("pin-unreadable", isDirectory: true))
        try pairingStorage(root.appendingPathComponent("pairings", isDirectory: true))
        print("IdentityProtectionTests passed")
    }

    private static func status() -> BridgeControlStatus {
        BridgeControlStatus(state: "ready", pid: 123, parentPID: 1,
            storageRoot: "fixture", workerHome: "fixture", controlSocket: "fixture",
            identitySource: "fixture", version: "1", build: "1", bundleIdentifier: "org.example.fixture")
    }

    private static func pinCreationAndMatching(_ root: URL) throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let alternate = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let initial = try BridgeIdentityPinStore.verifyOrPin(publicKey: key, status: status(), at: root)
        try require(initial.publicKeyBase64 == key.base64EncodedString(), "first pin contains wrong key")
        let loaded = try BridgeIdentityPinStore.load(at: root)
        try require(loaded == initial, "new pin was not persisted")
        let matching = try BridgeIdentityPinStore.verifyOrPin(publicKey: key, status: status(), at: root)
        try require(matching.publicKeyBase64 == initial.publicKeyBase64, "matching pin changed key")
        let url = root.appendingPathComponent("identity-pin.json")
        let before = try Data(contentsOf: url)
        try requireThrows("different key was accepted") {
            _ = try BridgeIdentityPinStore.verifyOrPin(publicKey: alternate, status: status(), at: root)
        }
        let after = try Data(contentsOf: url)
        try require(before == after, "different key replaced existing pin")
        var otherSource = status()
        otherSource.identitySource = "other-identity-source"
        try requireThrows("different identity source was accepted") {
            _ = try BridgeIdentityPinStore.verifyOrPin(publicKey: key, status: otherSource, at: root)
        }
        try require(try Data(contentsOf: url) == after, "different source replaced existing pin")
    }

    private static func challengeMustVerifyBeforePin(_ root: URL) throws {
        let key = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        let nonce = Data(repeating: 7, count: 32)
        var candidate = status()
        candidate.identityPublicKeyBase64 = publicKey.base64EncodedString()
        candidate.identityFingerprintSHA256 = BridgeControlCodec.fingerprint(publicKey)
        let valid = try key.signature(for: BridgeControlCodec.identityChallenge(nonce))
        let invalid = try other.signature(for: BridgeControlCodec.identityChallenge(nonce))
        try requireThrows("invalid signature created a pin") {
            _ = try BridgeIdentityPinStore.verifyChallenge(publicKey: publicKey, signature: invalid,
                                                             nonce: nonce, status: candidate, at: root)
        }
        try require(try BridgeIdentityPinStore.load(at: root) == nil, "invalid signature wrote a pin")
        var mismatched = candidate
        mismatched.identityFingerprintSHA256 = "incorrect"
        try requireThrows("mismatched status was accepted") {
            _ = try BridgeIdentityPinStore.verifyChallenge(publicKey: publicKey, signature: valid,
                                                             nonce: nonce, status: mismatched, at: root)
        }
        _ = try BridgeIdentityPinStore.verifyChallenge(publicKey: publicKey, signature: valid,
                                                        nonce: nonce, status: candidate, at: root)
        try require(try BridgeIdentityPinStore.load(at: root) != nil, "valid challenge did not persist a pin")
    }

    private static func corruptPinDoesNotRecreate(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("identity-pin.json")
        let corrupt = Data("{invalid-json".utf8)
        try corrupt.write(to: url)
        try requireThrows("corrupt pin was treated as absent") {
            _ = try BridgeIdentityPinStore.load(at: root)
        }
        try requireThrows("corrupt pin was silently recreated") {
            _ = try BridgeIdentityPinStore.verifyOrPin(
                publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                status: status(), at: root)
        }
        try require(try Data(contentsOf: url) == corrupt, "corrupt pin evidence was overwritten")
    }

    private static func unknownPinSchemaDoesNotRecreate(_ root: URL) throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        _ = try BridgeIdentityPinStore.verifyOrPin(publicKey: key, status: status(), at: root)
        let url = root.appendingPathComponent("identity-pin.json")
        let existing = try Data(contentsOf: url)
        var object = try JSONSerialization.jsonObject(with: existing) as! [String: Any]
        object["schema"] = "unknown-version"
        let invalid = try JSONSerialization.data(withJSONObject: object)
        try invalid.write(to: url)
        try requireThrows("unknown pin schema was accepted") {
            _ = try BridgeIdentityPinStore.verifyOrPin(publicKey: key, status: status(), at: root)
        }
        try require(try Data(contentsOf: url) == invalid, "unknown pin schema was overwritten")
    }

    private static func unreadablePinDoesNotRecreate(_ root: URL) throws {
        // A directory at the file path fails deterministically even when tests
        // run with a privileged UID; chmod(000) would not be reliable there.
        let url = root.appendingPathComponent("identity-pin.json", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try requireThrows("unreadable pin was treated as absent") {
            _ = try BridgeIdentityPinStore.load(at: root)
        }
        try requireThrows("unreadable pin was silently replaced") {
            _ = try BridgeIdentityPinStore.verifyOrPin(
                publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation,
                status: status(), at: root)
        }
        var isDirectory: ObjCBool = false
        try require(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue, "unreadable pin entry was replaced")
    }

    private static func pairingStorage(_ root: URL) throws {
        let file = root.appendingPathComponent("Library/Application Support/Floe Bridge/State/paired-clients.json")
        let missing = try BridgeIdentity.pairCount(storageRoot: root)
        try require(missing == 0, "missing pairing store should be empty")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let clientID = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        let pair = StoredPair(key: key, name: "fixture", acceptedAt: Date(timeIntervalSince1970: 1_600_000_000),
                              verification: nil, nonce: nil)
        let valid = try JSONEncoder().encode([clientID: pair])
        try valid.write(to: file)
        let count = try BridgeIdentity.pairCount(storageRoot: root)
        try require(count == 1, "valid legacy pairing did not decode")
        try require(try Data(contentsOf: file) == valid, "reading valid pairing modified it")

        for corrupt in [Data("{invalid-json".utf8), Data("[]".utf8),
                        Data("{\"client\":{\"name\":\"missing-key-and-date\"}}".utf8),
                        Data("{\"client\":{\"key\":42,\"name\":\"bad\",\"acceptedAt\":0}}".utf8)] {
            try corrupt.write(to: file)
            try requireThrows("damaged pairing store was accepted") {
                _ = try BridgeIdentity.pairCount(storageRoot: root)
            }
            try require(try Data(contentsOf: file) == corrupt, "damaged pairing store was modified")
        }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try requireThrows("unreadable pairing store was treated as empty") {
            _ = try BridgeIdentity.pairCount(storageRoot: root)
        }
    }
}
