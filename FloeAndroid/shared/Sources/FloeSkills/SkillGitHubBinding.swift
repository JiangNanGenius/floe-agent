import Foundation

/// Update intent and installed evidence are separate: advancing a branch must
/// never turn an installed immutable commit into an invented tracking ref.
public struct SkillGitHubBinding: Codable, Equatable, Sendable {
    public let source: GitHubSkillSource
    public let installedCommit: String?
    public let installedContentDigest: String?

    public init(source: GitHubSkillSource, installedCommit: String?, installedContentDigest: String?) throws {
        if let installedCommit {
            guard installedCommit.count == 40, installedCommit.allSatisfy(\.isHexDigit) else {
                throw SkillUpgradeError.invalidCommit
            }
        }
        if let installedContentDigest {
            guard installedContentDigest.count == 64, installedContentDigest.allSatisfy(\.isHexDigit) else {
                throw SkillUpgradeError.invalidInventory
            }
        }
        self.source = source
        self.installedCommit = installedCommit?.lowercased()
        self.installedContentDigest = installedContentDigest?.lowercased()
    }

    private enum CodingKeys: String, CodingKey { case source, installedCommit, installedContentDigest }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(source: values.decode(GitHubSkillSource.self, forKey: .source),
            installedCommit: values.decodeIfPresent(String.self, forKey: .installedCommit),
            installedContentDigest: values.decodeIfPresent(String.self, forKey: .installedContentDigest))
    }
}
