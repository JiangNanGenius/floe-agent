// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A read source, never authority to execute repository content or change a project.
public struct GitHubLink: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case repository, tree, commit, file, issue, pullRequest }
    public let url: URL
    public let repository: GitHubLinkRepositoryID
    public let kind: Kind
    /// Still ambiguous until the API has matched an actual branch/tag/commit.
    public let revisionAndPath: [String]
    public let explicitRefKind: GitHubLinkRevision.Kind?
    public let number: Int?
    public let anchor: GitHubLinkAnchor?
    /// A PR /files/<sha> or /commits/<sha> link selects a historical comparison.
    public let pullRequestCommit: String?
}

public struct GitHubLinkRepositoryID: Codable, Sendable, Hashable {
    public let owner: String
    public let name: String
    public var fullName: String { owner + "/" + name }
    public init(owner: String, name: String) { self.owner = owner; self.name = name }
}

public enum GitHubLinkAnchor: Codable, Sendable, Hashable {
    case lines(start: Int, end: Int)
    case issueComment(Int64)
    case reviewComment(Int64)
    case review(Int64)
    case diff(digest: String, side: String?, start: Int?, end: Int?)
    case other(String)
}

public enum GitHubLinkError: Error, Equatable, Sendable, LocalizedError {
    case invalidLink(String)
    case unsupportedLink
    case authenticationRequired
    case forbidden
    /// GitHub deliberately does not distinguish private/no-access from absent.
    case notFoundOrNotAccessible
    case moved(URL?)
    case rateLimited(retryAfter: String?)
    case http(Int)
    case transport
    case invalidResponse(String)
    case responseTooLarge(Int)
    case revisionNotFound
    case ambiguousRevision([String])
    case unsafePagination
    case sourceChanged
    public var errorDescription: String? {
        switch self {
        case .invalidLink: return "Invalid GitHub link"
        case .unsupportedLink: return "This GitHub link is not supported"
        case .authenticationRequired: return "Sign in to GitHub and try again"
        case .forbidden: return "GitHub did not allow this read"
        case .notFoundOrNotAccessible: return "The GitHub source is missing or is not accessible to this account"
        case .moved: return "The GitHub source has moved; confirm its new location"
        case .rateLimited: return "GitHub is limiting requests; try again later"
        case .http(let status): return "GitHub request failed (\(status))"
        case .transport: return "Could not connect to GitHub"
        case .invalidResponse: return "GitHub returned an unexpected response"
        case .responseTooLarge: return "This source exceeds the selected read limit"
        case .revisionNotFound: return "The requested GitHub revision could not be found"
        case .ambiguousRevision: return "Choose the intended branch or tag"
        case .unsafePagination: return "GitHub returned an invalid continuation"
        case .sourceChanged: return "The source changed while it was being read; refresh to read a new snapshot"
        }
    }
}

public struct GitHubLinkRevision: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case branch, tag, commit }
    public let kind: Kind
    public let name: String
    public let commitSHA: String
    public let treeSHA: String
}

/// Opaque caller-owned identities. Supplying them does not authorize any write.
public struct GitHubLinkAssociation: Codable, Sendable, Hashable {
    public let taskID: String?
    public let projectID: String?
    public let noteID: String?
    public init(taskID: String? = nil, projectID: String? = nil, noteID: String? = nil) {
        self.taskID = taskID; self.projectID = projectID; self.noteID = noteID
    }
}

public struct GitHubLinkReadOptions: Sendable {
    public var includeReadme = true
    public var includeDirectory = false
    public var includeFileContent = true
    public var includeChanges = true
    public var includePatch = false
    public var includeComments = false
    public var maximumFileBytes = 1_048_576
    public var maximumJSONBytes = 4_194_304
    public var maximumPages = 3
    public var perPage = 50
    public var startingPage = 1
    /// Required when appending a continuation to a previously read PR snapshot.
    public var expectedPullHeadSHA: String?
    /// Exact branch/tag choice for a genuinely ambiguous URL, not a fallback.
    public var revisionSelection: GitHubLinkRevisionSelection?
    public init() {}
}

public struct GitHubLinkRevisionSelection: Sendable {
    public let kind: GitHubLinkRevision.Kind
    public let name: String
    public init(kind: GitHubLinkRevision.Kind, name: String) { self.kind = kind; self.name = name }
}

public struct GitHubLinkRepository: Codable, Sendable, Hashable {
    public let id: Int64
    public let identity: GitHubLinkRepositoryID
    public let description: String?
    public let defaultBranch: String?
    public let isPrivate: Bool
    public let url: URL
}

public struct GitHubLinkRequestEvidence: Codable, Sendable, Hashable {
    public let apiURL: URL
    public let readAt: Date
    public let etag: String?
    public let lastModified: String?
    public let byteCount: Int
}

public struct GitHubLinkSource: Codable, Sendable, Hashable {
    public let originalURL: URL
    public let resolvedURL: URL
    public let repository: GitHubLinkRepositoryID
    public let revision: GitHubLinkRevision?
    public let path: String?
    public let anchor: GitHubLinkAnchor?
    public let readAt: Date
    public let requests: [GitHubLinkRequestEvidence]
    /// Repository bodies, code, comments and patches remain untrusted input.
    public var isUntrusted: Bool { true }
}

public struct GitHubLinkReadProgress: Sendable {
    public let completedRequests: Int
    public let receivedBytes: Int
    public let apiURL: URL
}

public struct GitHubLinkPage<Element: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public let items: [Element]
    public let nextPage: Int?
    public let pagesRead: Int
    /// Includes server truncation/API ceilings, not just the caller page budget.
    public let isComplete: Bool
}

public struct GitHubLinkTreeEntry: Codable, Sendable, Hashable {
    public let path: String
    public let mode: String
    public let type: String
    public let sha: String
    public let size: Int?
}

public struct GitHubLinkFile: Codable, Sendable, Hashable {
    public enum ContentState: String, Codable, Sendable { case loaded, notRequested, exceedsLimit, unsupportedType }
    public let path: String
    public let blobSHA: String
    public let type: String
    public let size: Int
    public let content: Data?
    public let contentState: ContentState
    public var text: String? {
        guard let content, !content.contains(0) else { return nil }
        return String(data: content, encoding: .utf8)
    }
}

public struct GitHubLinkChangedFile: Codable, Sendable, Hashable {
    public let sha: String
    public let filename: String
    public let previousFilename: String?
    public let status: String
    public let additions: Int
    public let deletions: Int
    public let changes: Int
    /// Absent for binary/large files or when not requested. Never means no changes.
    public let patch: String?
    public let patchState: String
}

public struct GitHubLinkCommit: Codable, Sendable, Hashable {
    public let sha: String
    public let message: String
    public let authorName: String?
    public let authorDate: String?
    public let committerName: String?
    public let parents: [String]
    public let files: GitHubLinkPage<GitHubLinkChangedFile>?
}

public struct GitHubLinkComment: Codable, Sendable, Hashable {
    public let id: Int64
    public let kind: String
    public let body: String
    public let author: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let url: URL
    public let path: String?
    public let commitSHA: String?
    public let originalCommitSHA: String?
    public let line: Int?
    public let originalLine: Int?
    public let startLine: Int?
    public let originalStartLine: Int?
    public let side: String?
    public let diffHunk: String?
    public let state: String?
}

public struct GitHubLinkIssue: Codable, Sendable, Hashable {
    public let number: Int
    public let title: String
    public let state: String
    public let body: String
    public let labels: [String]
    public let author: String?
    public let updatedAt: String?
    public let isPullRequest: Bool
    public let comments: GitHubLinkPage<GitHubLinkComment>?
}

public struct GitHubLinkPullSide: Codable, Sendable, Hashable {
    /// A deleted fork has no repository, and must not become the base repository.
    public let repository: GitHubLinkRepositoryID?
    public let ref: String
    public let sha: String
    public let label: String?
}

public struct GitHubLinkPullRequest: Codable, Sendable, Hashable {
    public let number: Int
    public let title: String
    public let state: String
    public let body: String
    public let isDraft: Bool
    public let isMerged: Bool
    public let base: GitHubLinkPullSide
    public let head: GitHubLinkPullSide
    public let changedFileCount: Int
    public let updatedAt: String?
    public let files: GitHubLinkPage<GitHubLinkChangedFile>?
    public let comments: GitHubLinkPage<GitHubLinkComment>?
}

public struct GitHubLinkLocation: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable { case resolved, unresolvedAnchor, outsideLoadedRange, historicalReview }
    public let state: State
    public let path: String?
    public let commitSHA: String?
    public let side: String?
    public let startLine: Int?
    public let endLine: Int?
    public let selectedText: String?
    public let selectedComment: GitHubLinkComment?
}

/// Codable so task/Notes/project owners can persist the same immutable read.
/// Refresh creates a new snapshot. This service never imports or switches projects.
public struct GitHubLinkSnapshot: Codable, Sendable, Hashable {
    public enum ReadWarning: String, Codable, Sendable { case defaultRevisionUnavailable, readmeMissing }
    public let link: GitHubLink
    public let association: GitHubLinkAssociation
    public let repository: GitHubLinkRepository
    public let source: GitHubLinkSource
    public let readme: GitHubLinkFile?
    public let directory: GitHubLinkPage<GitHubLinkTreeEntry>?
    public let file: GitHubLinkFile?
    public let commit: GitHubLinkCommit?
    public let issue: GitHubLinkIssue?
    public let pullRequest: GitHubLinkPullRequest?
    public let location: GitHubLinkLocation?
    public let warnings: [ReadWarning]
}
