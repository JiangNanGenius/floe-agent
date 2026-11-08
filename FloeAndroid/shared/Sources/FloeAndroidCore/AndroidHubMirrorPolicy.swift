// SPDX-License-Identifier: MPL-2.0
//
// Android public SkillHub signed transport-mirror policy (CONTRACT_V1,
// Local/Private/next-round-eda-20261108/github-transport-mirrors). Ported
// VERBATIM in behaviour from the reviewed iOS main sources
//   FloeAgent/Sources/FloeSkills/GitHubTransportMirrorManifest.swift
//     (main @ 2ce48570a, read through the fixed git object, not the worktree)
// with Android-module naming only. The frozen contract shape stays exact:
// payload keys schemaVersion/purpose/generation/issuedAt/expiresAt/roles,
// schemaVersion=1, purpose=floe-github-transport-mirrors, strictly monotonic
// generation in 1...9007199254740991, UTC RFC3339-second times (<=300s future
// skew, <=30d validity), roles rawFiles/atom/releaseAssets each an ordered
// array of <=2 distinct IDs drawn ONLY from the compiled ghfast.top /
// gh-proxy.com identities. A signed list can order or disable already
// compiled transport IDs; it never supplies endpoints, keys, content
// identities or permissions. The signature domain is the exact ASCII prefix
// below; verification rides the SAME pinned detached-Ed25519 trust the
// curated hub already uses (CuratedSkillHub.trustedKeys(for:)), with the
// fixture mode available only to authored tests.
import Foundation
import FloeSkills

public enum AndroidHubMirrorID: String, Codable, Sendable, CaseIterable {
    case ghfast = "ghfast.top"
    case ghProxy = "gh-proxy.com"

    var prefix: String { "https://\(rawValue)/" }
}

public struct AndroidHubMirrorRoles: Codable, Sendable, Equatable {
    public let rawFiles: [AndroidHubMirrorID]
    public let atom: [AndroidHubMirrorID]
    public let releaseAssets: [AndroidHubMirrorID]

    public init(rawFiles: [AndroidHubMirrorID], atom: [AndroidHubMirrorID],
                releaseAssets: [AndroidHubMirrorID]) {
        self.rawFiles = rawFiles; self.atom = atom; self.releaseAssets = releaseAssets
    }

    /// Compiled approved defaults (contract "first reviewed values",
    /// generation1 at the Hub): rawFiles=[ghfast.top,gh-proxy.com],
    /// atom=[gh-proxy.com], releaseAssets=[].
    public static let bundled = Self(rawFiles: [.ghfast, .ghProxy], atom: [.ghProxy], releaseAssets: [])
}

public enum AndroidHubMirrorManifestFailure: Error, Equatable, Sendable {
    case bounds, signature, shape, canonical, time, expired, rollback, generationReused
    case storage, unavailable, cancelled
}

/// A signed list can only order or disable already compiled transport IDs.
/// It cannot supply endpoints, keys, content identities or permissions.
public struct AndroidHubTransportMirrorManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let purpose: String
    public let generation: Int64
    public let issuedAt: String
    public let expiresAt: String
    public let roles: AndroidHubMirrorRoles

    /// Fixed official Hub location (floe-skill-hub @ pinned publication).
    public static let payloadPath = "transport/mirrors.v1.json"
    public static let signaturePath = "transport/mirrors.v1.json.sig"
    /// 16 KiB payload / 8 KiB envelope (contract limits).
    public static let maximumPayloadBytes = 16_384
    public static let maximumSignatureBytes = 8_192
    public static let maximumGeneration: Int64 = 9_007_199_254_740_991
    /// Exact ASCII signature-domain prefix, contract-frozen.
    public static let domain = Data("FLOE-GITHUB-TRANSPORT-MIRRORS-V1\n".utf8)

    public struct Verified: Sendable {
        public let manifest: AndroidHubTransportMirrorManifest
        public let payload: Data
        public let signature: Data
        public let keyID: String
        public let expiry: Date
        public let issued: Date
    }

    /// Crypto runs on the exact domain-prefixed payload before interpreting
    /// configuration values. Cache history may be expired, never activated.
    public static func verify(
        payload: Data, signature: Data, now: Date,
        mode: CuratedSkillTrustMode = .production,
        allowExpiredHistory: Bool = false
    ) throws -> Verified {
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes,
              !signature.isEmpty, signature.count <= maximumSignatureBytes else {
            throw AndroidHubMirrorManifestFailure.bounds
        }
        let keyID: String
        do {
            let envelope = try CuratedSkillEnvelope.decode(signature)
            let keys = try CuratedSkillHub.trustedKeys(for: mode)
            _ = try SignedContentFeedVerifier.verifyEnvelope(
                bytes: domain + payload, signature: signature, trustedKeys: keys,
                maximumBytes: maximumPayloadBytes + domain.count)
            keyID = envelope.keyID
        } catch { throw AndroidHubMirrorManifestFailure.signature }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: payload) }
        catch { throw AndroidHubMirrorManifestFailure.shape }
        guard value.schemaVersion == 1, value.purpose == "floe-github-transport-mirrors",
              (1...maximumGeneration).contains(value.generation),
              [value.roles.rawFiles, value.roles.atom, value.roles.releaseAssets].allSatisfy({
                  $0.count <= 2 && Set($0).count == $0.count
              }) else { throw AndroidHubMirrorManifestFailure.shape }
        // Re-encoding the typed six-key model also rejects unknown/duplicate
        // keys, bool/float integers, BOM, whitespace and escaped aliases.
        guard payload.allSatisfy({ $0 < 128 }),
              let canonical = try? value.canonicalBytes(), canonical == payload else {
            throw AndroidHubMirrorManifestFailure.canonical
        }
        guard let issued = timestamp(value.issuedAt), let expiry = timestamp(value.expiresAt),
              expiry > issued, expiry.timeIntervalSince(issued) <= 30 * 86_400,
              issued.timeIntervalSince(now) <= 300 else {
            throw AndroidHubMirrorManifestFailure.time
        }
        guard allowExpiredHistory || expiry > now else { throw AndroidHubMirrorManifestFailure.expired }
        return Verified(manifest: value, payload: payload, signature: signature, keyID: keyID, expiry: expiry, issued: issued)
    }

    public func canonicalBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data([10])
    }

    /// Strict UTC RFC3339 seconds; the round-trip guard refuses offsets,
    /// fractional seconds and impossible calendar dates.
    private static func timestamp(_ text: String) -> Date? {
        guard text.utf8.count == 20 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
}
