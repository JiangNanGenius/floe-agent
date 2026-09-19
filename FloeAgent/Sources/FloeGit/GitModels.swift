import Foundation

public enum GitChangeKind: String, Codable, Sendable, CaseIterable {
    case added, modified, deleted, renamed, typeChanged, conflicted, untracked
}

public struct GitFileChange: Identifiable, Codable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let oldPath: String?
    public let kind: GitChangeKind
    public let staged: Bool

    public init(path: String, oldPath: String? = nil, kind: GitChangeKind, staged: Bool) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.staged = staged
    }
}

public struct GitCommitSummary: Identifiable, Codable, Sendable, Hashable {
    public var id: String { oid }
    public let oid: String
    public let shortOID: String
    public let message: String
    public let author: String
    public let date: Date

    public init(oid: String, shortOID: String, message: String, author: String, date: Date) {
        self.oid = oid
        self.shortOID = shortOID
        self.message = message
        self.author = author
        self.date = date
    }
}

public struct GitRepositorySnapshot: Codable, Sendable, Hashable {
    public let isRepository: Bool
    public let branch: String?
    public let detachedHEAD: Bool
    public let branches: [String]
    public let remoteURL: String?
    public let changes: [GitFileChange]
    public let recentCommits: [GitCommitSummary]
    /// The discovered repository root. Differs from the inspected workspace
    /// root when the workspace lives inside a repository (or a worktree); nil
    /// for a non-repository. Change paths are always relative to this root.
    public let repositoryRoot: URL?

    public init(
        isRepository: Bool,
        branch: String? = nil,
        detachedHEAD: Bool = false,
        branches: [String] = [],
        remoteURL: String? = nil,
        changes: [GitFileChange] = [],
        recentCommits: [GitCommitSummary] = [],
        repositoryRoot: URL? = nil
    ) {
        self.isRepository = isRepository
        self.branch = branch
        self.detachedHEAD = detachedHEAD
        self.branches = branches
        self.remoteURL = remoteURL
        self.changes = changes
        self.recentCommits = recentCommits
        self.repositoryRoot = repositoryRoot
    }
}

/// Result of a merge (or merge-conflict resolution) operation.
public struct GitMergeOutcome: Codable, Sendable, Hashable {
    public enum Result: String, Codable, Sendable {
        case upToDate
        case fastForward
        case merged
        case conflicts
    }

    public let result: Result
    public let message: String
    public let conflictedPaths: [String]

    public init(result: Result, message: String, conflictedPaths: [String] = []) {
        self.result = result
        self.message = message
        self.conflictedPaths = conflictedPaths
    }

    public var isConflict: Bool { result == .conflicts }
}

/// Result of discarding working-tree changes. `recoveryPath` points at a
/// private copy of everything that was about to be lost, when one was made.
public struct GitDiscardOutcome: Codable, Sendable, Hashable {
    public let discardedPaths: [String]
    public let recoveryPath: String?

    public init(discardedPaths: [String], recoveryPath: String?) {
        self.discardedPaths = discardedPaths
        self.recoveryPath = recoveryPath
    }
}

public struct GitHubAccount: Codable, Sendable, Hashable {
    public let login: String
    public let name: String?
    public let avatarURL: URL?

    public init(login: String, name: String?, avatarURL: URL?) {
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
    }
}

public struct GitHubRepository: Identifiable, Codable, Sendable, Hashable {
    public let id: Int64
    public let fullName: String
    public let name: String
    public let isPrivate: Bool
    public let defaultBranch: String
    public let cloneURL: URL
    public let webURL: URL
    public let pushedAt: Date?

    public init(
        id: Int64,
        fullName: String,
        name: String,
        isPrivate: Bool,
        defaultBranch: String,
        cloneURL: URL,
        webURL: URL,
        pushedAt: Date?
    ) {
        self.id = id
        self.fullName = fullName
        self.name = name
        self.isPrivate = isPrivate
        self.defaultBranch = defaultBranch
        self.cloneURL = cloneURL
        self.webURL = webURL
        self.pushedAt = pushedAt
    }
}
