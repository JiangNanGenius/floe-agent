import Foundation

public struct SkillInstallProvenance: Codable, Equatable, Sendable {
    public var sourceURL: URL
    public var originalSHA256: String
    public var expectedRewrittenSHA256: String
    public var rewriteModelID: String
    public var compatibilitySummary: String

    public init(
        sourceURL: URL,
        originalSHA256: String,
        expectedRewrittenSHA256: String,
        rewriteModelID: String,
        compatibilitySummary: String
    ) {
        var sanitized = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
        sanitized?.user = nil
        sanitized?.password = nil
        sanitized?.query = nil
        sanitized?.fragment = nil
        self.sourceURL = sanitized?.url ?? sourceURL
        self.originalSHA256 = originalSHA256
        self.expectedRewrittenSHA256 = expectedRewrittenSHA256
        self.rewriteModelID = rewriteModelID
        self.compatibilitySummary = compatibilitySummary
    }
}

public struct SkillInstallationRecord: Codable, Equatable, Sendable {
    public var skillID: String
    public var version: String
    public var canonicalPackageURL: URL
    public var canonicalSHA256: String
    public var provenance: SkillInstallProvenance
    public var installedAt: Date

    /// This invariant is part of the persistence contract: source packages
    /// are reviewed in a temporary location and are never copied into the
    /// Skills store or database.
    public var originalPayloadStored: Bool { false }

    public init(
        skillID: String,
        version: String,
        canonicalPackageURL: URL,
        canonicalSHA256: String,
        provenance: SkillInstallProvenance,
        installedAt: Date
    ) {
        self.skillID = skillID
        self.version = version
        self.canonicalPackageURL = canonicalPackageURL
        self.canonicalSHA256 = canonicalSHA256
        self.provenance = provenance
        self.installedAt = installedAt
    }
}

public protocol SkillInstallationMetadataStore: Sendable {
    func persist(_ record: SkillInstallationRecord) async throws
}

public actor SkillInstallStagingService {
    private let installationRoot: URL
    private let validator: SkillPackageValidator
    private let metadataStore: (any SkillInstallationMetadataStore)?
    private let fileManager: FileManager

    public init(
        installationRoot: URL,
        validator: SkillPackageValidator = SkillPackageValidator(),
        metadataStore: (any SkillInstallationMetadataStore)? = nil,
        fileManager: FileManager = .default
    ) {
        self.installationRoot = installationRoot.standardizedFileURL
        self.validator = validator
        self.metadataStore = metadataStore
        self.fileManager = fileManager
    }

    /// Installs only the already-rewritten canonical package. The original
    /// download URL is metadata; its bytes are never accepted by this API.
    public func installRewrittenPackage(
        at rewrittenPackageURL: URL,
        provenance: SkillInstallProvenance,
        replaceExisting: Bool = false,
        now: Date = Date()
    ) async throws -> SkillInstallationRecord {
        guard !rewrittenPackageURL.standardizedFileURL.path.hasPrefix(installationRoot.path + "/") else {
            throw SkillInstallError.sourceMustBeTemporary
        }
        guard Self.isSHA256(provenance.originalSHA256),
              Self.isSHA256(provenance.expectedRewrittenSHA256),
              !provenance.rewriteModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              provenance.compatibilitySummary.utf8.count <= 8_192
        else {
            throw SkillInstallError.invalidProvenance
        }
        let package = try validator.validate(packageAt: rewrittenPackageURL)
        guard package.canonicalSHA256 == provenance.expectedRewrittenSHA256 else {
            throw SkillValidationError.digestMismatch
        }
        try fileManager.createDirectory(at: installationRoot, withIntermediateDirectories: true)

        let destination = installationRoot.appendingPathComponent(package.manifest.id, isDirectory: true)
        let staging = installationRoot.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let backup = installationRoot.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        var didBackup = false
        var didInstallDestination = false
        do {
            try fileManager.copyItem(at: package.rootURL, to: staging)
            let stagedPackage = try validator.validate(packageAt: staging)
            guard stagedPackage.canonicalSHA256 == package.canonicalSHA256 else {
                throw SkillValidationError.digestMismatch
            }
            if fileManager.fileExists(atPath: destination.path) {
                guard replaceExisting else {
                    throw SkillInstallError.alreadyInstalled(package.manifest.id)
                }
                try fileManager.moveItem(at: destination, to: backup)
                didBackup = true
            }
            try fileManager.moveItem(at: staging, to: destination)
            didInstallDestination = true
            let record = SkillInstallationRecord(
                skillID: package.manifest.id,
                version: package.manifest.version,
                canonicalPackageURL: destination,
                canonicalSHA256: package.canonicalSHA256,
                provenance: provenance,
                installedAt: now
            )
            try await metadataStore?.persist(record)
            if didBackup { try? fileManager.removeItem(at: backup) }
            return record
        } catch {
            try? fileManager.removeItem(at: staging)
            if didInstallDestination, fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if didBackup, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }
}

public enum SkillInstallError: Error, Equatable, Sendable, LocalizedError {
    case alreadyInstalled(String)
    case sourceMustBeTemporary
    case invalidProvenance

    public var errorDescription: String? {
        switch self {
        case .alreadyInstalled(let id): "Skill '\(id)' is already installed"
        case .sourceMustBeTemporary: "The rewritten source must be outside the canonical Skills store"
        case .invalidProvenance: "Skill provenance is missing or invalid"
        }
    }
}
