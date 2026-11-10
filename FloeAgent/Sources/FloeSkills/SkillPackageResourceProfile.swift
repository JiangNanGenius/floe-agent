import Foundation

/// A signed package's resource envelope, never a capability or execution grant.
public enum SkillPackageResourceProfile: String, Codable, Sendable, Equatable, Hashable {
    case standard
    case largeSourceV1 = "large-source-v1"

    public var maximumFiles: Int { self == .standard ? 128 : 2048 }
    public var maximumBytes: Int { self == .standard ? 8_388_608 : 67_108_864 }
    public var maximumFileBytes: Int { 2_097_152 }
    public var validationLimits: SkillValidationLimits {
        SkillValidationLimits(maximumFileCount: maximumFiles, maximumFileBytes: maximumFileBytes,
            maximumPackageBytes: maximumBytes)
    }
    var archiveLimits: SignedContentArchiveLimits {
        SignedContentArchiveLimits(maximumEntries: maximumFiles,
            maximumFileBytes: maximumFileBytes, maximumTotalBytes: maximumBytes)
    }
}

/// Local revalidation authority for one exact reviewed package. This cannot
/// authorize a download. The App restores it only from its committed curated
/// receipt/history, never from a package manifest, tool argument or URL.
public struct SkillPackageResourceAuthorization: Sendable, Equatable {
    public let profile: SkillPackageResourceProfile
    public let skillID: String
    public let version: String
    public let contentDigest: String

    init(profile: SkillPackageResourceProfile, skillID: String, version: String, contentDigest: String) {
        self.profile = profile; self.skillID = skillID
        self.version = version; self.contentDigest = contentDigest
    }

    public var validator: SkillPackageValidator { SkillPackageValidator(limits: profile.validationLimits) }
    public func requireIdentity(_ package: ValidatedSkillPackage) throws {
        guard package.manifest.id == skillID, package.manifest.version == version,
              package.canonicalSHA256 == contentDigest else { throw SkillValidationError.digestMismatch }
    }
}

public extension CuratedSkillHub {
    /// Only `stage` mints this non-Codable value after verifying a Publication.
    /// The transport must match all retrieval facts before using its byte cap.
    struct PackageDownloadAuthorization: Sendable {
        public let profile: SkillPackageResourceProfile
        public let publicationCommit: String
        public let packagePath: String
        public let packageSize: Int
        public let packageSHA256: String
        public let contentDigest: String

        init(binding: CuratedSkillPackageBinding, publicationCommit: String) {
            profile = binding.profile; self.publicationCommit = publicationCommit
            packagePath = binding.path; packageSize = binding.size
            packageSHA256 = binding.sha256; contentDigest = binding.contentDigest
        }

        public func maximumBytes(owner: String, repository: String, ref: String, path: String?) throws -> Int {
            guard owner == CuratedSkillHub.owner, repository == CuratedSkillHub.repository,
                  ref == publicationCommit, CuratedSkillStrictJSON.isCommit(ref),
                  path == packagePath, (1...profile.maximumBytes).contains(packageSize) else {
                throw CuratedSkillHubFailure.source("verified package retrieval identity changed")
            }
            return packageSize
        }
    }

    typealias FetchAuthorizedPackage = @Sendable
        (GitHubSkillSource, String, String, PackageDownloadAuthorization) async throws -> Data
}

public extension CuratedSkillHub.Receipt {
    /// This is for App-owned committed metadata and retained history only.
    /// It is intentionally a DIFFERENT type from transport authorization.
    func resourceAuthorization(mode: CuratedSkillTrustMode = .production) throws -> SkillPackageResourceAuthorization? {
        guard let profile = packageProfile, profile != .standard else { return nil }
        let trusted: Bool
        switch mode {
        case .production:
            trusted = feedStatus == .production && feedSignatureKeyID == CuratedSkillHub.productionKeyID
                && reviewKeyID == CuratedSkillHub.productionKeyID
        case .fixtureTestOnly(let key):
            trusted = key.count == 32 && feedStatus == .fixture
                && feedSignatureKeyID == CuratedSkillHub.fixtureKeyID && reviewKeyID == CuratedSkillHub.fixtureKeyID
        }
        let prefix = channel == .ios ? "" : "android/"
        guard receiptSchemaVersion == 1, trusted,
              hubRepository == CuratedSkillHub.hubRepository, publisher == CuratedSkillHub.publisher,
              reviewDecision == .approve,
              CuratedSkillStrictJSON.isCommit(publicationCommit),
              CuratedSkillStrictJSON.isSHA256(catalogSHA256),
              CuratedSkillStrictJSON.isSHA256(packageSHA256),
              CuratedSkillStrictJSON.isSHA256(contentDigest),
              packagePath == "\(prefix)packages/\(entryID)/\(entryVersion)/\(entryID).zip",
              (1...profile.maximumBytes).contains(packageSize),
              catalogLayout == .largeSourceV1 else {
            throw CuratedSkillHubFailure.trust("invalid committed package profile receipt")
        }
        return SkillPackageResourceAuthorization(profile: profile, skillID: entryID,
            version: entryVersion, contentDigest: contentDigest)
    }
}
