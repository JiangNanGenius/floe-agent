// FloeSkills — shared signed content-update foundation.
//
// One verifier and one version policy for every remotely updateable content
// domain (skills today; prompts/help/templates/providers/models next). The
// trust root is compiled into the app and can never be replaced by the
// network; a feed is data, never authority.
//
// Contract (mirrors the content-hub builder and the existing skill-hub):
//   * Ed25519 signature over the exact feed bytes, keyed by a fixed keyID.
//   * Strict three-part dotted versions, no leading zeros.
//   * Immutable published versions: same version with a different digest is
//     rejected, and a lower remote version never downgrades an install.
//   * Unknown/incompatible/newer-than-app content is retained, never
//     activated implicitly.
//   * Dependencies activate together; a missing dependency blocks only that
//     entry and never half-installs a dependent.

import Foundation
import Crypto
import FloeCore

// MARK: - Versions

/// Strict `major.minor.patch` version, matching the publisher contract.
public struct SignedContentVersion: Comparable, Sendable, Hashable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ value: String) throws {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              pieces.allSatisfy({ piece in
                  !piece.isEmpty && piece.allSatisfy(\.isNumber)
                      && (piece == "0" || !piece.hasPrefix("0"))
              }),
              let major = Int(pieces[0]), let minor = Int(pieces[1]), let patch = Int(pieces[2])
        else {
            throw SignedContentFailure.feed
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SignedContentVersion, rhs: SignedContentVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

// MARK: - Feed models

public enum SignedContentKind: String, Codable, Sendable, CaseIterable, Hashable {
    case prompts
    case providers
    case models
    case help
    case templates
}

public struct SignedContentEnvelope: Codable, Sendable, Equatable {
    public let keyID: String
    public let signature: String
}

public struct SignedContentEntry: Codable, Sendable, Equatable {
    public let id: String
    public let kind: SignedContentKind
    public let version: String
    public let schemaVersion: Int
    public let minimumAppVersion: String
    /// Optional upper app-compatibility bound. Absent means no upper bound.
    /// Entries outside `minimum...maximum` are retained but never activated.
    public let maximumAppVersion: String?
    public let requiredCapabilities: [String]
    public let dependencies: [String]
    public let path: String
    public let size: Int
    public let sha256: String
    public let contentDigest: String
    public let releaseNotes: [String: String]
    public let sourceRevision: String
    public let containsScripts: Bool

    public init(
        id: String,
        kind: SignedContentKind,
        version: String,
        schemaVersion: Int,
        minimumAppVersion: String,
        maximumAppVersion: String? = nil,
        requiredCapabilities: [String],
        dependencies: [String],
        path: String,
        size: Int,
        sha256: String,
        contentDigest: String,
        releaseNotes: [String: String],
        sourceRevision: String,
        containsScripts: Bool
    ) {
        self.id = id
        self.kind = kind
        self.version = version
        self.schemaVersion = schemaVersion
        self.minimumAppVersion = minimumAppVersion
        self.maximumAppVersion = maximumAppVersion
        self.requiredCapabilities = requiredCapabilities
        self.dependencies = dependencies
        self.path = path
        self.size = size
        self.sha256 = sha256
        self.contentDigest = contentDigest
        self.releaseNotes = releaseNotes
        self.sourceRevision = sourceRevision
        self.containsScripts = containsScripts
    }

    public func isCompatible(appVersion: String) -> Bool {
        guard let app = try? SignedContentVersion(appVersion) else { return false }
        if let minimum = try? SignedContentVersion(minimumAppVersion), app < minimum { return false }
        if let maximumAppVersion,
           let maximum = try? SignedContentVersion(maximumAppVersion), app > maximum { return false }
        return true
    }
}

public struct SignedContentFeed: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let publisher: String
    public let generatedAt: String?
    public let entries: [SignedContentEntry]
}

// MARK: - Failures

public enum SignedContentFailure: Error, Equatable, LocalizedError {
    /// Signature envelope missing, untrusted key, or invalid proof.
    case signature
    /// Structurally invalid feed/entry, or a limit violation.
    case feed
    /// Signed archive unsafe, oversized, or corrupt.
    case archive
    /// Published content cannot change under the same identity (immutability).
    case immutableVersion
    /// The entry requires an app newer than the running one.
    case incompatible
    /// A declared dependency is not available.
    case missingDependency

    public var errorDescription: String? {
        switch self {
        case .signature: "Signed content signature verification failed"
        case .feed: "Invalid signed content index or entry identity"
        case .archive: "Unsafe, oversized or corrupt content archive"
        case .immutableVersion: "Published content versions cannot change; publish a new version"
        case .incompatible: "Update Floe before activating this content version"
        case .missingDependency: "A required content dependency is not available"
        }
    }
}

// MARK: - Official content hub identity

/// Static identity of the public content hub. The same repository and key
/// identity as the skill hub; the app never learns a new trust root from the
/// network.
public enum OfficialContentHub {
    public static let owner = "JiangNanGenius"
    public static let repository = "floe-agent"
    public static let indexPath = "content-hub/index.json"
    public static let signaturePath = "content-hub/index.sig"
    public static let publisher = "JiangNanGenius"

    public static func source() throws -> GitHubSkillSource {
        try GitHubSkillSource(owner: owner, repository: repository, ref: "main", path: indexPath)
    }

    public static func validateSource(_ source: GitHubSkillSource) throws {
        guard source.owner == owner, source.repository == repository,
              source.path == indexPath else { throw SignedContentFailure.signature }
    }
}

// MARK: - Feed verification

public enum SignedContentFeedVerifier {
    public static let maximumFeedBytes = 262_144
    public static let maximumSignatureBytes = 4_096
    public static let maximumEntries = 256
    private static let identifierCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")

    /// Verifies the Ed25519 envelope over the exact feed bytes and returns the
    /// decoded envelope. Never touches the network and never accepts an
    /// unknown key.
    public static func verifyEnvelope(
        bytes: Data,
        signature: Data,
        trustedKeys: [String: Data],
        maximumBytes: Int = SignedContentFeedVerifier.maximumFeedBytes
    ) throws -> SignedContentEnvelope {
        guard bytes.count <= maximumBytes, signature.count <= maximumSignatureBytes else {
            throw SignedContentFailure.feed
        }
        let envelope: SignedContentEnvelope
        do {
            envelope = try JSONDecoder().decode(SignedContentEnvelope.self, from: signature)
        } catch {
            throw SignedContentFailure.signature
        }
        guard let keyBytes = trustedKeys[envelope.keyID],
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes),
              let proof = Data(base64Encoded: envelope.signature),
              key.isValidSignature(proof, for: bytes) else {
            throw SignedContentFailure.signature
        }
        return envelope
    }

    /// Full structural verification of a content feed. Allowed kinds and the
    /// expected publisher are explicit so each domain validates only what it
    /// understands; unknown kinds fail closed.
    public static func verify(
        feed bytes: Data,
        signature: Data,
        trustedKeys: [String: Data],
        publisher: String = OfficialContentHub.publisher,
        allowedKinds: Set<SignedContentKind> = Set(SignedContentKind.allCases),
        validateContentPaths: Bool = true
    ) throws -> SignedContentFeed {
        _ = try verifyEnvelope(bytes: bytes, signature: signature, trustedKeys: trustedKeys)
        let feed: SignedContentFeed
        do {
            feed = try JSONDecoder().decode(SignedContentFeed.self, from: bytes)
        } catch {
            throw SignedContentFailure.feed
        }
        guard feed.schemaVersion == 1, feed.publisher == publisher,
              (1...maximumEntries).contains(feed.entries.count) else {
            throw SignedContentFailure.feed
        }
        var ids: Set<String> = []
        for entry in feed.entries {
            try validate(entry: entry, allowedKinds: allowedKinds, validateContentPath: validateContentPaths)
            guard ids.insert(entry.id).inserted else { throw SignedContentFailure.feed }
        }
        for entry in feed.entries {
            for dependency in entry.dependencies where dependency == entry.id {
                throw SignedContentFailure.feed
            }
        }
        return feed
    }

    static func validate(
        entry: SignedContentEntry,
        allowedKinds: Set<SignedContentKind>,
        validateContentPath: Bool
    ) throws {
        guard allowedKinds.contains(entry.kind) else { throw SignedContentFailure.feed }
        guard isValidContentID(entry.id), entry.id.utf8.count <= 128 else { throw SignedContentFailure.feed }
        _ = try SignedContentVersion(entry.version)
        let minimum = try SignedContentVersion(entry.minimumAppVersion)
        if let maximumAppVersion = entry.maximumAppVersion {
            let maximum = try SignedContentVersion(maximumAppVersion)
            guard maximum >= minimum else { throw SignedContentFailure.feed }
        }
        guard entry.schemaVersion >= 1, entry.schemaVersion <= 1_024 else { throw SignedContentFailure.feed }
        guard (1...8_388_608).contains(entry.size) else { throw SignedContentFailure.feed }
        guard isHex(entry.sha256), isHex(entry.contentDigest) else { throw SignedContentFailure.feed }
        guard entry.releaseNotes["zh-Hans"]?.isEmpty == false,
              entry.releaseNotes["en"]?.isEmpty == false,
              entry.releaseNotes.count <= 8 else { throw SignedContentFailure.feed }
        for (locale, note) in entry.releaseNotes {
            guard locale.utf8.count <= 32, note.utf8.count <= 4_096 else { throw SignedContentFailure.feed }
        }
        guard entry.sourceRevision.isEmpty || (entry.sourceRevision.count == 40 && entry.sourceRevision.allSatisfy(\.isHexDigit)) else {
            throw SignedContentFailure.feed
        }
        guard entry.requiredCapabilities.count <= 32,
              entry.dependencies.count <= 32,
              entry.requiredCapabilities.allSatisfy({ $0.utf8.count <= 64 }),
              entry.dependencies.allSatisfy({ isValidContentID($0) && $0.utf8.count <= 128 }) else {
            throw SignedContentFailure.feed
        }
        if validateContentPath {
            let expected = "content-hub/packages/\(entry.id)/\(entry.version)/\(entry.id).zip"
            guard entry.path == expected else { throw SignedContentFailure.feed }
        } else {
            guard !entry.path.isEmpty, !entry.path.hasPrefix("/"), !entry.path.contains("\\"),
                  entry.path.utf8.count <= 512,
                  !entry.path.split(separator: "/").contains("..") else { throw SignedContentFailure.feed }
        }
    }

    public static func isValidContentID(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter || first.isNumber,
              value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { identifierCharacters.contains($0) }
    }

    private static func isHex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

// MARK: - Version policy

public enum ContentUpdateDecision: Equatable, Sendable {
    case upToDate(version: String)
    case update(SignedContentEntry)
    case blocked(reason: ContentUpdateBlockReason, version: String)

    public var isUpdate: Bool {
        if case .update = self { return true }
        return false
    }
}

/// Machine-readable reasons so the UI can localize them and no call site
/// invents its own classification.
public enum ContentUpdateBlockReason: String, Sendable, Equatable {
    /// The remote feed is older than the installed version.
    case downgrade
    /// The same version exists with different content; published versions are
    /// immutable, so the copy is retained and the feed entry is rejected.
    case sameVersionDifferentContent
    /// The entry needs a newer app build.
    case incompatibleApp
    /// A declared dependency is not installed/available.
    case missingDependency
    /// The user pinned/rolled back this content; no automatic overwrite.
    case pinned
    /// The entry itself is structurally invalid for activation.
    case feedFailure
}

/// Default-highest-compatible selection with explicit immutability, downgrade
/// and dependency rules. Pure and synchronous so every branch is testable.
public enum ContentVersionPolicy {
    public static func decide(
        entry: SignedContentEntry,
        installedVersion: String?,
        installedDigest: String?,
        appVersion: String,
        pinnedVersion: String? = nil,
        availableDependencyIDs: Set<String> = []
    ) throws -> ContentUpdateDecision {
        let remote = try SignedContentVersion(entry.version)
        if let installedVersion, let installed = try? SignedContentVersion(installedVersion) {
            if remote < installed {
                return .blocked(reason: .downgrade, version: entry.version)
            }
            if remote == installed {
                if let installedDigest, installedDigest.lowercased() != entry.contentDigest.lowercased() {
                    return .blocked(reason: .sameVersionDifferentContent, version: entry.version)
                }
                return .upToDate(version: entry.version)
            }
            if let pinnedVersion, installedVersion == pinnedVersion {
                return .blocked(reason: .pinned, version: entry.version)
            }
        }
        guard let app = try? SignedContentVersion(appVersion),
              let minimum = try? SignedContentVersion(entry.minimumAppVersion),
              minimum <= app else {
            return .blocked(reason: .incompatibleApp, version: entry.version)
        }
        if let maximumAppVersion = entry.maximumAppVersion,
           let maximum = try? SignedContentVersion(maximumAppVersion), app > maximum {
            return .blocked(reason: .incompatibleApp, version: entry.version)
        }
        for dependency in entry.dependencies where !availableDependencyIDs.contains(dependency) {
            return .blocked(reason: .missingDependency, version: entry.version)
        }
        return .update(entry)
    }

    /// True when the app-bundled copy should take over from an installed copy:
    /// only when it is strictly newer, or equal with identical content.
    /// Same-version-different content never silently replaces a user install.
    public static func bundledTakesOver(
        installedVersion: String,
        installedDigest: String,
        bundledVersion: String,
        bundledDigest: String
    ) -> Bool {
        guard let installed = try? SignedContentVersion(installedVersion),
              let bundled = try? SignedContentVersion(bundledVersion) else { return false }
        if bundled > installed { return true }
        if bundled == installed { return installedDigest == bundledDigest }
        return false
    }
}
