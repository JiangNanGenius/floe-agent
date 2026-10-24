import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// SPDX-License-Identifier: MPL-2.0
//
// GitHubActionsModels — the pure, network-free half of the IDE's GitHub
// Actions execution target. It owns:
//
// * the wire models GitHub returns for workflows, runs, jobs and artifacts;
// * the *dispatch association* rule that ties one trigger to exactly one run
//   (so Floe never adopts somebody else's recent run);
// * `Link`-header pagination parsing and a hard page bound;
// * the git-data snapshot types used to publish an explicit file snapshot to
//   a run-owned branch.
//
// Nothing here performs I/O and nothing here holds a credential, so the whole
// decision layer is exercised by plain fixtures without a device or a network.

// MARK: - Errors

/// Typed failures of the GitHub Actions client. Messages never embed the
/// bearer token, request bodies or response bodies beyond GitHub's own error
/// text, which the app redacts before display.
public enum GitHubActionsError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case transport(String)
    case http(status: Int, message: String)
    case decoding(String)
    case responseTooLarge(limit: Int)
    /// The dispatch succeeded but no run could be uniquely associated with it.
    case associationUnresolved(String)
    case redirectWithoutLocation

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): return "GitHub Actions is not configured: \(detail)"
        case .transport(let detail): return "GitHub Actions network error: \(detail)"
        case .http(let status, let message): return "GitHub Actions request failed (\(status)): \(message)"
        case .decoding(let detail): return "GitHub Actions returned an unexpected response: \(detail)"
        case .responseTooLarge(let limit): return "GitHub Actions response exceeded the \(limit) byte limit"
        case .associationUnresolved(let detail): return detail
        case .redirectWithoutLocation: return "GitHub Actions download redirect had no destination"
        }
    }
}

// MARK: - Wire models

public struct GitHubActionsWorkflow: Identifiable, Codable, Sendable, Hashable {
    public let id: Int64
    public let name: String
    /// Repository-relative path such as `.github/workflows/ci.yml`.
    public let path: String
    public let state: String

    public init(id: Int64, name: String, path: String, state: String) {
        self.id = id; self.name = name; self.path = path; self.state = state
    }
}

public struct GitHubActionsRun: Identifiable, Codable, Sendable, Hashable {
    public let id: Int64
    public let workflowID: Int64
    public let runNumber: Int
    public let event: String
    public let status: String
    public let conclusion: String?
    public let headSHA: String
    public let headBranch: String?
    public let htmlURL: URL?
    public let createdAt: Date
    public let runStartedAt: Date?
    public let updatedAt: Date?

    /// GitHub returns snake_case; the client decoder does not globally convert
    /// because the dispatch response intentionally keeps its raw keys.
    private enum CodingKeys: String, CodingKey {
        case id
        case workflowID = "workflow_id"
        case runNumber = "run_number"
        case event
        case status
        case conclusion
        case headSHA = "head_sha"
        case headBranch = "head_branch"
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case runStartedAt = "run_started_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: Int64, workflowID: Int64, runNumber: Int, event: String,
        status: String, conclusion: String?, headSHA: String, headBranch: String?,
        htmlURL: URL?, createdAt: Date, runStartedAt: Date?, updatedAt: Date?
    ) {
        self.id = id; self.workflowID = workflowID; self.runNumber = runNumber
        self.event = event; self.status = status; self.conclusion = conclusion
        self.headSHA = headSHA; self.headBranch = headBranch; self.htmlURL = htmlURL
        self.createdAt = createdAt; self.runStartedAt = runStartedAt; self.updatedAt = updatedAt
    }

    /// GitHub reports `completed` (or `neutral`) for any finished run.
    public var isTerminal: Bool {
        status == "completed" || conclusion != nil
    }

    public var succeeded: Bool { conclusion == "success" }
}

public struct GitHubActionsJob: Identifiable, Codable, Sendable, Hashable {
    public let id: Int64
    public let name: String
    public let status: String
    public let conclusion: String?
    public let startedAt: Date?
    public let completedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    public init(id: Int64, name: String, status: String, conclusion: String?,
                startedAt: Date?, completedAt: Date?) {
        self.id = id; self.name = name; self.status = status
        self.conclusion = conclusion; self.startedAt = startedAt; self.completedAt = completedAt
    }
}

public struct GitHubActionsArtifact: Identifiable, Codable, Sendable, Hashable {
    public let id: Int64
    public let name: String
    public let sizeInBytes: Int64
    public let expired: Bool
    public let archiveDownloadURL: URL
    public let createdAt: Date
    public let expiresAt: Date?
    /// The API-provided content digest (typically `sha256:<hex>`) when GitHub
    /// returns one. `nil` means the server did not attest the bytes, so a local
    /// checksum is checksum-only and must never be presented as a verified
    /// download.
    public let digest: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, expired, digest
        case sizeInBytes = "size_in_bytes"
        case archiveDownloadURL = "archive_download_url"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }

    public init(id: Int64, name: String, sizeInBytes: Int64, expired: Bool,
                archiveDownloadURL: URL, createdAt: Date, expiresAt: Date?,
                digest: String? = nil) {
        self.id = id; self.name = name; self.sizeInBytes = sizeInBytes
        self.expired = expired; self.archiveDownloadURL = archiveDownloadURL
        self.createdAt = createdAt; self.expiresAt = expiresAt
        self.digest = digest
    }
}

// MARK: - Dispatch identity and association

/// The identity a run must match before Floe will adopt it. `baselineRunIDs`
/// are the run ids observed immediately *before* dispatch; a run that already
/// existed can never be the run this dispatch created. `headSHA` is the
/// snapshot commit the run was requested on, which distinguishes Floe's run
/// from any other `workflow_dispatch` on the same branch.
public struct GitHubActionsDispatchReceipt: Sendable, Equatable {
    public let owner: String
    public let repository: String
    public let workflowID: Int64
    public let ref: String
    public let headSHA: String
    public let dispatchedAt: Date
    public let baselineRunIDs: Set<Int64>
    /// Set only when GitHub's dispatch response returned an explicit run id.
    public let returnedRunID: Int64?

    public init(owner: String, repository: String, workflowID: Int64, ref: String,
                headSHA: String, dispatchedAt: Date, baselineRunIDs: Set<Int64>,
                returnedRunID: Int64?) {
        self.owner = owner; self.repository = repository; self.workflowID = workflowID
        self.ref = ref; self.headSHA = headSHA; self.dispatchedAt = dispatchedAt
        self.baselineRunIDs = baselineRunIDs; self.returnedRunID = returnedRunID
    }
}

public enum GitHubActionsAssociationFailure: Error, Equatable, Sendable {
    /// More than one candidate matched; Floe refuses to guess.
    case ambiguous(runIDs: [Int64])
    /// No candidate matched yet. The caller may keep polling within its bound.
    case notFound
}

public enum GitHubActionsRunAssociation {
    /// Clock skew allowance between the device and GitHub when filtering by
    /// `created_at`. The snapshot SHA match is the primary identity; time is
    /// only a fallback guard.
    public static let skewSeconds: TimeInterval = 180

    /// An explicit run id returned by GitHub is authoritative.
    public static func receiptRun(_ receipt: GitHubActionsDispatchReceipt) -> Int64? {
        receipt.returnedRunID
    }

    /// Selects the unique run created by this dispatch.
    ///
    /// A candidate must (1) not be in the baseline, (2) belong to the exact
    /// workflow, (3) carry the exact snapshot commit SHA, (4) run on the exact
    /// ref and (5) have been created at or after dispatch minus skew. If more
    /// than one candidate qualifies the association is `.ambiguous` — never a
    /// silent pick of the newest, which could be another actor's run.
    public static func select(
        candidates: [GitHubActionsRun],
        receipt: GitHubActionsDispatchReceipt
    ) -> Result<GitHubActionsRun, GitHubActionsAssociationFailure> {
        if let returned = receipt.returnedRunID {
            if let match = candidates.first(where: { $0.id == returned }) { return .success(match) }
            return .failure(.notFound)
        }
        let cutoff = receipt.dispatchedAt.addingTimeInterval(-skewSeconds)
        let matches = candidates.filter { run in
            !receipt.baselineRunIDs.contains(run.id)
                && run.workflowID == receipt.workflowID
                && run.headSHA == receipt.headSHA
                && run.headBranch == receipt.ref
                && run.createdAt >= cutoff
        }
        if matches.isEmpty { return .failure(.notFound) }
        if matches.count > 1 {
            return .failure(.ambiguous(runIDs: matches.map(\.id).sorted()))
        }
        return .success(matches[0])
    }
}

// MARK: - Pagination

public enum GitHubActionsPagination {
    /// Hard bound on how many pages one logical list may follow, so a hostile
    /// or broken `Link` header chain cannot loop forever.
    public static let maximumPages = 5
    public static let maximumPerPage = 100
    public static let defaultPerPage = 50

    public static func perPage(_ requested: Int?) -> Int {
        min(max(requested ?? defaultPerPage, 1), maximumPerPage)
    }

    /// Parses the `rel="next"` URL from a `Link` header. The header may hold
    /// several comma-separated links; only the `next` relation is returned.
    public static func nextURL(fromLinkHeader header: String?) -> URL? {
        guard let header, !header.isEmpty else { return nil }
        for entry in header.split(separator: ",") {
            let parts = entry.split(separator: ";")
            guard parts.count >= 2 else { continue }
            let urlPart = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard urlPart.hasPrefix("<"), urlPart.hasSuffix(">") else { continue }
            let relations = parts.dropFirst().joined(separator: ";")
            guard relations.contains("rel=\"next\"") else { continue }
            let raw = String(urlPart.dropFirst().dropLast())
            return URL(string: raw)
        }
        return nil
    }

    /// A next URL is only followed when it stays on the same API host and
    /// keeps the api.github.com scheme. Anything else stops the walk.
    public static func isFollowable(next: URL, origin: URL) -> Bool {
        next.scheme?.lowercased() == "https"
            && next.host?.lowercased() == origin.host?.lowercased()
    }
}

// MARK: - Bounded text slices

/// A bounded slice of job/run logs. `truncated` is true when the stream had
/// more bytes than the caller allowed, so the UI never presents a truncated
/// tail as the complete log.
public struct GitHubActionsLogSlice: Sendable, Equatable {
    public let text: String
    public let truncated: Bool
    public let byteCount: Int

    public init(text: String, truncated: Bool, byteCount: Int) {
        self.text = text; self.truncated = truncated; self.byteCount = byteCount
    }
}

// MARK: - Artifact download

public struct GitHubActionsArtifactDownload: Sendable, Equatable {
    public let data: Data
    /// The host the signed blob ultimately came from. Never carries the API
    /// bearer token (the redirect guard strips it).
    public let sourceHost: String
    public let suggestedFileName: String

    public init(data: Data, sourceHost: String, suggestedFileName: String) {
        self.data = data; self.sourceHost = sourceHost; self.suggestedFileName = suggestedFileName
    }
}

// MARK: - Git-data snapshot models

public struct GitHubActionsTreeEntry: Codable, Sendable, Equatable {
    public let path: String
    public let mode: String
    public let type: String
    public let sha: String

    public init(path: String, mode: String = "100644", type: String = "blob", sha: String) {
        self.path = path; self.mode = mode; self.type = type; self.sha = sha
    }
}

public struct GitHubActionsGitRef: Decodable, Sendable, Equatable {
    public let ref: String
    public let objectSHA: String

    enum CodingKeys: String, CodingKey { case ref, object }
    private struct Object: Codable { let sha: String }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(String.self, forKey: .ref)
        objectSHA = try container.decode(Object.self, forKey: .object).sha
    }
}

public struct GitHubActionsGitCommitObject: Decodable, Sendable, Equatable {
    public let sha: String
    public let treeSHA: String

    enum CodingKeys: String, CodingKey { case sha, tree }
    private struct Tree: Codable { let sha: String }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha = try container.decode(String.self, forKey: .sha)
        treeSHA = try container.decode(Tree.self, forKey: .tree).sha
    }
}

public struct GitHubActionsGitSHA: Codable, Sendable, Equatable {
    public let sha: String
}
