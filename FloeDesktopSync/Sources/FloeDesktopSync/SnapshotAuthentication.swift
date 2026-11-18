import Foundation

/// A sender's HMAC over a complete snapshot manifest and its intended receiver.
/// This proves possession of the configured pairing key, not that the sender's
/// source database is honest or that a historical snapshot is freshly captured.
public struct AuthenticatedSnapshotManifest: Sendable, Equatable {
    public let manifest: SnapshotManifest
    public let receiverDeviceID: DeviceID
    public let keyID: String
    public let tag: IncrementalAuthenticationTag

    public init(manifest: SnapshotManifest, receiverDeviceID: DeviceID, keyID: String,
                tag: IncrementalAuthenticationTag) throws {
        try IncrementalProofKeyIdentifier.validate(keyID)
        self.manifest = manifest
        self.receiverDeviceID = receiverDeviceID
        self.keyID = keyID
        self.tag = tag
    }

    fileprivate func authenticationMessage() -> [UInt8] {
        JSONValue.object([
            "domain": .string("floe.snapshot.manifest.auth.v1"),
            "receiverDeviceID": .string(receiverDeviceID.canonical),
            "manifestDigest": .string(manifest.digest.description),
            "keyID": .string(keyID)
        ]).canonicalUTF8
    }
}

public extension SnapshotManifest {
    func signedForSnapshot(receiverDeviceID: DeviceID, keyID: String,
                           key: SyncProofKey) throws -> AuthenticatedSnapshotManifest {
        try validate()
        try IncrementalProofKeyIdentifier.validate(keyID)
        let provisional = try AuthenticatedSnapshotManifest(manifest: self, receiverDeviceID: receiverDeviceID,
            keyID: keyID, tag: IncrementalAuthenticationTag.compute(key: key, message: []))
        return try AuthenticatedSnapshotManifest(manifest: self, receiverDeviceID: receiverDeviceID,
            keyID: keyID, tag: IncrementalAuthenticationTag.compute(key: key, message: provisional.authenticationMessage()))
    }
}

/// Host-configured key registry. The host must load pairwise credentials from
/// authenticated pairing state and must not allow remote callers to install it.
public struct HMACSnapshotAuthenticator: Sendable {
    public struct PeerKey: Sendable {
        public let peerDeviceID: DeviceID
        public let keyID: String
        public let key: SyncProofKey

        public init(peerDeviceID: DeviceID, keyID: String, key: SyncProofKey) throws {
            try IncrementalProofKeyIdentifier.validate(keyID)
            self.peerDeviceID = peerDeviceID
            self.keyID = keyID
            self.key = key
        }
    }

    private let entries: [String: PeerKey]

    func validatePeerKeyIsolation(from incremental: HMACIncrementalAuthenticator) throws {
        let incrementalKeys = incremental.effectivePeerKeys
        for entry in entries.values {
            let normalized = HMACSHA256.normalizeKey(entry.key.bytes)
            guard !incrementalKeys.contains(where: { $0.0 != entry.peerDeviceID && $0.1 == normalized }) else {
                throw SyncStoreError.invalidAuthenticationProof("equivalent snapshot and incremental keys cannot belong to different peers")
            }
        }
    }

    public init(peerKeys: [PeerKey]) throws {
        var entries: [String: PeerKey] = [:]
        for entry in peerKeys {
            guard entries[entry.keyID] == nil else {
                throw SyncStoreError.invalidAuthenticationProof("duplicate snapshot proof key ID")
            }
            let normalized = HMACSHA256.normalizeKey(entry.key.bytes)
            guard !entries.values.contains(where: {
                $0.peerDeviceID != entry.peerDeviceID && HMACSHA256.normalizeKey($0.key.bytes) == normalized
            }) else {
                throw SyncStoreError.invalidAuthenticationProof("equivalent snapshot proof keys cannot be shared across peers")
            }
            entries[entry.keyID] = entry
        }
        guard !entries.isEmpty else {
            throw SyncStoreError.invalidAuthenticationProof("at least one trusted snapshot peer key is required")
        }
        self.entries = entries
    }

    func authenticate(_ signed: AuthenticatedSnapshotManifest, receiverDeviceID: DeviceID) throws {
        try signed.manifest.validate()
        guard signed.receiverDeviceID == receiverDeviceID,
              signed.manifest.originDeviceID != receiverDeviceID,
              let entry = entries[signed.keyID],
              entry.peerDeviceID == signed.manifest.originDeviceID,
              signed.tag.verify(key: entry.key, message: signed.authenticationMessage()) else {
            throw SyncStoreError.snapshotImportUnverified
        }
    }
}
