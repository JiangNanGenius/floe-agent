import Foundation
import FloeTools

/// Original-file receipts intentionally omit Linux archive/review and guest
/// qualification fields. Exact signed catalog/source/file identities remain.
public struct MacOriginalSkillInstallReceipt: Codable, Sendable {
    public let target: String
    public let skillID: String
    public let version: String
    public let contentDigest: String
    public let catalogDigest: String
    public let publicationCommit: String
    public let sourceCommit: String
    public let sourceRepository: String
    public let fileCount: Int
    public let totalBytes: Int64
    public let installedPath: String
    public init(skillID: String, version: String, contentDigest: String, catalogDigest: String,
                publicationCommit: String, sourceCommit: String, sourceRepository: String,
                fileCount: Int, totalBytes: Int64, installedPath: String) {
        target = "macos-original"; self.skillID = skillID; self.version = version
        self.contentDigest = contentDigest; self.catalogDigest = catalogDigest
        self.publicationCommit = publicationCommit; self.sourceCommit = sourceCommit
        self.sourceRepository = sourceRepository; self.fileCount = fileCount
        self.totalBytes = totalBytes; self.installedPath = installedPath
    }
    public func verify(against request: SkillHubInstallRequest) throws {
        try SkillIdentifier.validate(skillID)
        _ = try SignedContentVersion(version)
        func hex(_ text: String, count: Int) -> Bool { text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard target == "macos-original", request.id == skillID,
              request.publicationCommit == nil || request.publicationCommit == publicationCommit,
              hex(contentDigest, count: 64), hex(catalogDigest, count: 64),
              hex(publicationCommit, count: 40), hex(sourceCommit, count: 40),
              fileCount > 0, totalBytes >= 0, totalBytes <= MacOriginalSkillCatalog.maximumPackageBytes,
              sourceRepository.split(separator: "/").count == 2, installedPath.hasPrefix("/"), !installedPath.contains("\0") else {
            throw SkillHubValidationError.receiptIdentityMismatch
        }
    }
}

public protocol SkillMacOriginalInstalling: Sendable {
    func installMacOriginal(_ request: SkillHubInstallRequest, context: ToolContext) async throws -> MacOriginalSkillInstallReceipt
}
