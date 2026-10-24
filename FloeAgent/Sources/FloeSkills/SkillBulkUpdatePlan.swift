import Foundation

/// Metadata only. Download trees and permission grants never enter this cache.
public struct SkillUpdateAvailability: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case checking, available, updating, reviewRequired, upToDate, failed
    }
    public var sourceIdentity: String?
    public var installedDigest: String
    public var version: String?
    public var phase: Phase
    public var error: String?

    public init(installedDigest: String, sourceIdentity: String? = nil, version: String? = nil, phase: Phase, error: String? = nil) {
        self.sourceIdentity = sourceIdentity
        self.installedDigest = installedDigest
        self.version = version
        self.phase = phase
        self.error = error
    }

    public func isCurrent(installedDigest: String, sourceIdentity: String) -> Bool {
        self.installedDigest == installedDigest && self.sourceIdentity == sourceIdentity
    }
}

/// Stable ordering and retry policy for a snapshot of all installed rows.
/// Callers resolve real sources and revalidate packages before every write.
public enum SkillBulkUpdatePlan {
    /// Updates preserve existing decisions; only a reviewed expansion grants
    /// new capabilities. A nil upgrade set denotes an ordinary installation.
    public static func installationGrants(declared: [String], upgradeAdded: Set<String>?) -> [String] {
        upgradeAdded?.sorted() ?? declared
    }

    public struct Item: Equatable, Sendable {
        public let id: String
        public let installedDigest: String
        public let hasKnownSource: Bool
        public let availableVersion: String?

        public init(id: String, installedDigest: String, hasKnownSource: Bool, availableVersion: String?) {
            self.id = id
            self.installedDigest = installedDigest
            self.hasKnownSource = hasKnownSource
            self.availableVersion = availableVersion
        }
    }

    public struct GitHubReference: Equatable, Sendable {
        public let owner: String
        public let repository: String
        public let ref: String
        public let path: String
    }

    /// A repository home, arbitrary URL, local row or encoded/ambiguous path
    /// is not an update source. A reviewed journal takes precedence upstream.
    public static func githubReference(_ text: String?) -> GitHubReference? {
        guard let text, let parts = URLComponents(string: text),
              parts.scheme == "https", parts.host?.lowercased() == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil, parts.fragment == nil,
              !parts.percentEncodedPath.contains("%") else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count >= 6, path[0].isEmpty, path[3] == "blob",
              path.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return .init(owner: String(path[1]), repository: String(path[2]), ref: String(path[4]),
                     path: path.dropFirst(5).joined(separator: "/"))
    }

    public static func checks(_ installed: [Item]) -> [String] {
        unique(installed.filter(\.hasKnownSource).map(\.id))
    }

    public static func updates(_ installed: [Item], states: [String: SkillUpdateAvailability]) -> [String] {
        unique(installed.filter { item in
            guard item.hasKnownSource, item.availableVersion != nil else { return false }
            guard let state = states[item.id], state.installedDigest == item.installedDigest else { return true }
            switch state.phase {
            case .checking, .updating, .reviewRequired: return false
            case .available, .failed, .upToDate: return true
            }
        }.map(\.id))
    }

    public static func isNewer(_ proposed: String, than installed: String) -> Bool {
        proposed.compare(installed, options: .numeric) == .orderedDescending
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
