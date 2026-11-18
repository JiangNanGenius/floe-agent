// Floe Mac M00 — trust-on-first-use pin for the helper identity.
//
// SPDX-License-Identifier: MPL-2.0
//
// The challenge response itself is not enough: a response that supplies its
// own public key would be self-verifying. The host verifies a challenge with
// the pinned key and requires the helper to report the same key. A changed
// key is a failure, not a silent re-pin.

import CryptoKit
import Darwin
import Foundation

struct BridgeIdentityPin: Codable, Equatable, Sendable {
    var schema: String
    var publicKeyBase64: String
    var fingerprintSHA256: String
    var identitySource: String
    var helperBundleIdentifier: String?
    var helperVersion: String?
    var helperBuild: String?
    var firstSeen: String
    var lastSeen: String
}

enum BridgeIdentityPinStore {
    /// Verify the candidate before publishing its control connection as ready.
    static func verifyChallenge(publicKey: Data, signature: Data, nonce: Data,
                                status: BridgeControlStatus, at root: URL) throws -> BridgeIdentityPin {
        guard publicKey.count == 32,
              status.identityPublicKeyBase64 == publicKey.base64EncodedString(),
              status.identityFingerprintSHA256 == BridgeControlCodec.fingerprint(publicKey),
              try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
                .isValidSignature(signature, for: BridgeControlCodec.identityChallenge(nonce)) else {
            throw BridgeControlFailure.remote("The helper identity challenge or status is invalid.")
        }
        return try verifyOrPin(publicKey: publicKey, status: status, at: root)
    }

    static func load(at root: URL) throws -> BridgeIdentityPin? {
        let url = root.appendingPathComponent("identity-pin.json", isDirectory: false)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw BridgeControlFailure.remote("The existing Bridge identity pin cannot be opened; it was not replaced.")
        }
        defer { close(descriptor) }
        var details = stat()
        guard fstat(descriptor, &details) == 0, (details.st_mode & S_IFMT) == S_IFREG else {
            throw BridgeControlFailure.remote("The Bridge identity pin is not a regular file; it was not replaced.")
        }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            guard let data = try handle.readToEnd() else { throw BridgeControlFailure.notConnected }
            let pin = try JSONDecoder().decode(BridgeIdentityPin.self, from: data)
            guard pin.schema == "floe-mac-bridge-identity-pin-v1",
                  let key = Data(base64Encoded: pin.publicKeyBase64), key.count == 32,
                  pin.fingerprintSHA256 == BridgeControlCodec.fingerprint(key),
                  !pin.identitySource.isEmpty else {
                throw BridgeControlFailure.remote("The Bridge identity pin has an invalid schema or identity.")
            }
            return pin
        } catch {
            throw BridgeControlFailure.remote("The existing Bridge identity pin is unreadable or invalid; it was not replaced.")
        }
    }

    static func verifyOrPin(
        publicKey: Data,
        status: BridgeControlStatus,
        at root: URL
    ) throws -> BridgeIdentityPin {
        let fingerprint = BridgeControlCodec.fingerprint(publicKey)
        let now = ISO8601DateFormatter().string(from: Date())
        if let existing = try load(at: root) {
            guard existing.publicKeyBase64 == publicKey.base64EncodedString(),
                  existing.fingerprintSHA256 == fingerprint else {
                throw BridgeControlFailure.remote(
                    "The embedded Bridge identity changed from the pinned key. Refusing to trust the new key or overwrite the pin."
                )
            }
            guard existing.identitySource == status.identitySource else {
                throw BridgeControlFailure.remote(
                    "The embedded Bridge identity source changed from \(existing.identitySource) to \(status.identitySource). Refusing to re-pin silently."
                )
            }
            var updated = existing
            updated.lastSeen = now
            updated.helperVersion = status.version
            updated.helperBuild = status.build
            return updated
        }
        let pin = BridgeIdentityPin(
            schema: "floe-mac-bridge-identity-pin-v1",
            publicKeyBase64: publicKey.base64EncodedString(),
            fingerprintSHA256: fingerprint,
            identitySource: status.identitySource,
            helperBundleIdentifier: status.bundleIdentifier,
            helperVersion: status.version,
            helperBuild: status.build,
            firstSeen: now,
            lastSeen: now
        )
        try saveNew(pin, at: root)
        return pin
    }

    private static func saveNew(_ pin: BridgeIdentityPin, at root: URL) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(pin)
        let url = root.appendingPathComponent("identity-pin.json", isDirectory: false)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw BridgeControlFailure.remote("Could not create the Bridge identity pin safely; an existing pin was not replaced.")
        }
        defer { close(descriptor) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(descriptor) == 0 else {
            throw BridgeControlFailure.remote("Could not persist the Bridge identity pin.")
        }
    }
}
