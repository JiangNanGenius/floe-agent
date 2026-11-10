// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A focused domain client over the existing GitHub session. No token is
/// retained, no secondary account store is introduced, and reads stay bounded.
public struct GitHubCollaborationClient: Sendable {
    public let client: GitHubActionsClient
    public init(client: GitHubActionsClient = GitHubActionsClient()) { self.client = client }
    private static let maximumBytes = 4_194_304
    private func prefix(_ repository: GitHubLinkRepositoryID) throws -> [String] {
        let parsed = try GitHubLinkParser.parse("https://github.com/" + repository.fullName)
        guard parsed.kind == .repository, parsed.repository == repository else { throw GitHubCollaborationError.invalidInput("repository") }
        return ["repos", repository.owner, repository.name]
    }
    private func json<Value: Decodable & Sendable>(_ segments: [String], query: [URLQueryItem] = [], token: String) async throws -> Value {
        let response = try await client.readLinkResource(segments, query: query, token: token, maximumBytes: Self.maximumBytes)
        do { return try JSONDecoder().decode(Value.self, from: response.data) }
        catch { throw GitHubLinkError.invalidResponse("collaboration response") }
    }
    private func page<Item: Codable & Sendable>(_ segments: [String], query: [URLQueryItem] = [], page: Int, token: String) async throws -> GitHubCollaborationPage<Item> {
        guard (1...10_000).contains(page) else { throw GitHubCollaborationError.invalidInput("page") }
        let values: [Item] = try await json(segments, query: query + [.init(name: "page", value: String(page)), .init(name: "per_page", value: "100")], token: token)
        return .init(items: values, page: page, nextPage: values.count == 100 ? page + 1 : nil)
    }
    public func issues(_ repository: GitHubLinkRepositoryID, state: String = "open", page: Int = 1, token: String = "") async throws -> GitHubCollaborationPage<GitHubCollaborationThread> {
        guard ["open", "closed", "all"].contains(state) else { throw GitHubCollaborationError.invalidInput("state") }
        // The GitHub issues endpoint includes PRs. Keep the type flag intact;
        // callers may filter visually without losing pagination semantics.
        return try await self.page(prefix(repository) + ["issues"], query: [.init(name: "state", value: state)], page: page, token: token)
    }
    public func pulls(_ repository: GitHubLinkRepositoryID, state: String = "open", page: Int = 1, token: String = "") async throws -> GitHubCollaborationPage<GitHubCollaborationPull> {
        guard ["open", "closed", "all"].contains(state) else { throw GitHubCollaborationError.invalidInput("state") }
        return try await self.page(prefix(repository) + ["pulls"], query: [.init(name: "state", value: state)], page: page, token: token)
    }
    public func issue(_ repository: GitHubLinkRepositoryID, number: Int, token: String = "") async throws -> GitHubCollaborationThread {
        try positive(number); return try await json(prefix(repository) + ["issues", String(number)], token: token)
    }
    public func pull(_ repository: GitHubLinkRepositoryID, number: Int, token: String = "") async throws -> GitHubCollaborationPull {
        try positive(number); return try await json(prefix(repository) + ["pulls", String(number)], token: token)
    }
    public func comments(_ repository: GitHubLinkRepositoryID, number: Int, page: Int = 1, token: String = "") async throws -> GitHubCollaborationPage<GitHubCollaborationComment> {
        try positive(number); return try await self.page(prefix(repository) + ["issues", String(number), "comments"], page: page, token: token)
    }
    public func reviews(_ repository: GitHubLinkRepositoryID, number: Int, page: Int = 1, token: String = "") async throws -> GitHubCollaborationPage<GitHubCollaborationComment> {
        try positive(number); return try await self.page(prefix(repository) + ["pulls", String(number), "reviews"], page: page, token: token)
    }
    public func reviewComments(_ repository: GitHubLinkRepositoryID, number: Int, page: Int = 1, token: String = "") async throws -> GitHubCollaborationPage<GitHubCollaborationComment> {
        try positive(number); return try await self.page(prefix(repository) + ["pulls", String(number), "comments"], page: page, token: token)
    }
    public func files(_ repository: GitHubLinkRepositoryID, number: Int, page: Int = 1, token: String = "") async throws -> GitHubCollaborationPage<GitHubCollaborationFile> {
        try positive(number); return try await self.page(prefix(repository) + ["pulls", String(number), "files"], page: page, token: token)
    }
    public func checks(_ repository: GitHubLinkRepositoryID, sha: String, page: Int = 1, token: String = "") async throws -> GitHubCollaborationPage<GitHubCollaborationCheck> {
        try validSHA(sha); try positive(page)
        struct Envelope: Decodable, Sendable { let check_runs: [GitHubCollaborationCheck]; let total_count: Int }
        let value: Envelope = try await json(prefix(repository) + ["commits", sha, "check-runs"], query: [.init(name: "page", value: String(page)), .init(name: "per_page", value: "100")], token: token)
        guard value.check_runs.allSatisfy({ $0.headSHA == sha }) else { throw GitHubLinkError.invalidResponse("check head") }
        return .init(items: value.check_runs, page: page, nextPage: page * 100 < value.total_count ? page + 1 : nil)
    }
    public func commitStatus(_ repository: GitHubLinkRepositoryID, sha: String, token: String = "") async throws -> GitHubCollaborationCommitStatus {
        try validSHA(sha)
        let value: GitHubCollaborationCommitStatus = try await json(prefix(repository) + ["commits", sha, "status"], token: token)
        guard value.sha == sha else { throw GitHubLinkError.invalidResponse("status head") }; return value
    }
    public func requireHead(_ repository: GitHubLinkRepositoryID, number: Int, expected: String, token: String) async throws -> GitHubCollaborationPull {
        try validSHA(expected)
        let current = try await pull(repository, number: number, token: token)
        guard current.head.sha == expected else { throw GitHubCollaborationError.changedHead(expected: expected, actual: current.head.sha) }
        return current
    }
    private func positive(_ number: Int) throws { guard number > 0 else { throw GitHubCollaborationError.invalidInput("number") } }
    private func validSHA(_ sha: String) throws {
        guard [40, 64].contains(sha.utf8.count), sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw GitHubCollaborationError.invalidInput("commit") }
    }

    /// This method performs exactly one HTTP mutation. The service must persist
    /// .sending before calling and reconcile an uncertain response instead of
    /// repeating a POST. Redirects never forward the token or change identity.
    func send(_ prepared: GitHubPreparedMutation, token: String) async throws -> GitHubMutationResult {
        try prepared.validateContract()
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitHubCollaborationError.authenticationRequired }
        try Task.checkCancellation()
        let base = try prefix(prepared.repository)
        let url = try GitHubLinkTransport.apiURL(baseURL: client.baseURL, segments: base + prepared.endpoint, query: [])
        guard url.host == "api.github.com" else { throw GitHubCollaborationError.invalidInput("API origin") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = prepared.method; request.httpBody = prepared.payload
        request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("FloeAgent", forHTTPHeaderField: "User-Agent")
        let response: GitHubLinkHTTPResponse
        do { response = try await GitHubLinkTransport.read(request, session: client.session, maximumBytes: Self.maximumBytes) }
        catch let error as GitHubLinkError {
            switch error {
            case .authenticationRequired: throw GitHubCollaborationError.rejected(401)
            case .forbidden: throw GitHubCollaborationError.rejected(403)
            case .notFoundOrNotAccessible: throw GitHubCollaborationError.rejected(404)
            case .rateLimited: throw GitHubCollaborationError.rejected(429)
            case .http(let status) where (400..<500).contains(status): throw GitHubCollaborationError.rejected(status)
            default: throw GitHubCollaborationError.outcomeUnknown(prepared.id)
            }
        } catch { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
        do {
            if prepared.runID != nil {
                guard response.response.statusCode == (prepared.kind == .cancelActions ? 202 : 201) else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
                return .init(remoteID: prepared.runID, url: prepared.targetURL, commitSHA: prepared.expectedHeadSHA)
            }
            if prepared.kind == .mergePull {
                struct Merge: Decodable { let sha: String; let merged: Bool }
                let result = try JSONDecoder().decode(Merge.self, from: response.data)
                guard result.merged else { throw GitHubCollaborationError.rejected(response.response.statusCode) }
                return .init(remoteID: nil, url: prepared.targetURL, commitSHA: result.sha)
            }
            if prepared.kind == .createPull {
                let pull = try JSONDecoder().decode(GitHubCollaborationPull.self, from: response.data)
                guard try matchesPull(prepared, pull),
                      try GitHubLinkParser.parse(pull.htmlURL.absoluteString).repository == prepared.repository else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
                return .init(remoteID: pull.id, url: pull.htmlURL, commitSHA: pull.head.sha)
            }
            struct Resource: Decodable { let id: Int64; let html_url: URL }
            let result = try JSONDecoder().decode(Resource.self, from: response.data)
            guard result.id > 0, try GitHubLinkParser.parse(result.html_url.absoluteString).repository == prepared.repository else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
            return .init(remoteID: result.id, url: result.html_url, commitSHA: prepared.expectedHeadSHA)
        } catch let error as GitHubCollaborationError { throw error }
        catch { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
    }

    func validateBeforeSend(_ prepared: GitHubPreparedMutation, token: String) async throws {
        try prepared.validateContract()
        if prepared.kind == .updateIssue, let number = prepared.number {
            let current = try await issue(prepared.repository, number: number, token: token)
            guard current.pullRequest == nil else { throw GitHubCollaborationError.invalidInput("issue") }
        }
        if prepared.kind == .createPull {
            let payload = try JSONSerialization.jsonObject(with: prepared.payload) as? [String: Any]
            guard let head = payload?["head"] as? String, let expected = prepared.expectedHeadSHA else { throw GitHubCollaborationError.operationMismatch }
            let parts = head.split(separator: ":", maxSplits: 1).map(String.init)
            let headRepository = GitHubLinkRepositoryID(owner: parts.count == 2 ? parts[0] : prepared.repository.owner, name: payload?["head_repo"] as? String ?? prepared.repository.name)
            struct Commit: Decodable, Sendable { let sha: String }
            let actual: Commit = try await json(prefix(headRepository) + ["commits", parts.last ?? ""], token: token)
            guard actual.sha == expected else { throw GitHubCollaborationError.changedHead(expected: expected, actual: actual.sha) }
        }
        if let runID = prepared.runID {
            let run = try await actionAttempt(prepared.repository, runID: runID, token: token)
            guard run.id == runID, run.runAttempt == prepared.runAttempt, run.headSHA == prepared.expectedHeadSHA else { throw GitHubCollaborationError.operationMismatch }
            guard (prepared.kind == .cancelActions) != (run.status == "completed") else { throw GitHubCollaborationError.invalidInput("run state") }
        }
        if let sha = prepared.expectedHeadSHA, let number = prepared.number {
            let current = try await requireHead(prepared.repository, number: number, expected: sha, token: token)
            guard current.state == "open", current.merged != true else { throw GitHubCollaborationError.invalidInput("closed pull request") }
            if let line = prepared.reviewLine {
                // Load bounded pages until this exact file is found. The API
                // supplies no patch for binary/too-large files; those refuse a
                // fabricated line comment while ordinary timeline replies work.
                var page = 1, selected: GitHubCollaborationFile?
                while page <= 30 && selected == nil {
                    let value = try await files(prepared.repository, number: number, page: page, token: token)
                    selected = value.items.first(where: { $0.filename == line.path })
                    guard let next = value.nextPage, selected == nil else { break }; page = next
                }
                try line.validate(in: selected.map { [$0] } ?? [])
                _ = try await requireHead(prepared.repository, number: number, expected: sha, token: token)
            }
        }
    }

    public func actionAttempt(_ repository: GitHubLinkRepositoryID, runID: Int64, token: String) async throws -> GitHubActionAttempt {
        guard runID > 0 else { throw GitHubCollaborationError.invalidInput("run") }
        return try await json(prefix(repository) + ["actions", "runs", String(runID)], token: token)
    }
    func authenticatedActor(token: String) async throws -> String {
        guard !token.isEmpty else { throw GitHubCollaborationError.authenticationRequired }
        struct Actor: Decodable, Sendable { let login: String }
        let actor: Actor = try await json(["user"], token: token)
        guard !actor.login.isEmpty else { throw GitHubLinkError.invalidResponse("account") }; return actor.login
    }
    func reconcile(_ prepared: GitHubPreparedMutation, actor: String, token: String) async throws -> GitHubMutationResult? {
        try prepared.validateContract()
        if prepared.kind == .updateIssue, let number = prepared.number {
            let current = try await issue(prepared.repository, number: number, token: token)
            let payload = try JSONSerialization.jsonObject(with: prepared.payload) as? [String: Any]
            guard current.pullRequest == nil, current.state == payload?["state"] as? String else { return nil }
            return .init(remoteID: current.id, url: current.htmlURL, commitSHA: nil, confirmation: .observed)
        }
        if let runID = prepared.runID, let baseline = prepared.runAttempt {
            let run = try await actionAttempt(prepared.repository, runID: runID, token: token)
            guard run.id == runID, run.headSHA == prepared.expectedHeadSHA else { return nil }
            let observed = prepared.kind == .cancelActions
                ? run.runAttempt == baseline && run.status == "completed" && run.conclusion == "cancelled"
                : run.runAttempt > baseline
            guard observed else { return nil }
            return .init(remoteID: runID, url: prepared.targetURL, commitSHA: run.headSHA, confirmation: .observed)
        }
        if prepared.kind == .mergePull, let number = prepared.number {
            let current = try await pull(prepared.repository, number: number, token: token)
            guard current.merged == true, current.head.sha == prepared.expectedHeadSHA else { return nil }
            // Reconciliation confirms the requested repository state; it does
            // not assert that our interrupted HTTP request performed the merge.
            return .init(remoteID: current.id, url: current.htmlURL, commitSHA: current.head.sha, confirmation: .observed)
        }
        let payload = try JSONSerialization.jsonObject(with: prepared.payload) as? [String: Any]
        guard let expectedBody = payload?["body"] as? String else { return nil }
        if prepared.kind == .createIssue {
            for p in 1...5 {
                let page: GitHubCollaborationPage<GitHubCollaborationThread> = try await self.page(prefix(prepared.repository) + ["issues"], query: [.init(name: "state", value: "all"), .init(name: "creator", value: actor), .init(name: "sort", value: "created"), .init(name: "direction", value: "desc")], page: p, token: token)
                let matches = page.items.filter { $0.pullRequest == nil && $0.body == expectedBody && $0.title == payload?["title"] as? String && $0.user?.login.caseInsensitiveCompare(actor) == .orderedSame }
                guard matches.count <= 1 else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
                if let item = matches.first { return .init(remoteID: item.id, url: item.htmlURL, commitSHA: nil, confirmation: .observed) }
                if page.nextPage == nil { break }
            }
        } else if prepared.kind == .createPull {
            for p in 1...5 {
                let page: GitHubCollaborationPage<GitHubCollaborationPull> = try await self.page(prefix(prepared.repository) + ["pulls"], query: [.init(name: "state", value: "all"), .init(name: "head", value: payload?["head"] as? String), .init(name: "base", value: payload?["base"] as? String)], page: p, token: token)
                let matches = page.items.filter { $0.body == expectedBody && (try? matchesPull(prepared, $0)) == true && $0.title == payload?["title"] as? String && $0.user?.login.caseInsensitiveCompare(actor) == .orderedSame }
                guard matches.count <= 1 else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
                if let item = matches.first { return .init(remoteID: item.id, url: item.htmlURL, commitSHA: item.head.sha, confirmation: .observed) }
                if page.nextPage == nil { break }
            }
        } else if let number = prepared.number {
            for p in 1...5 {
                let page: GitHubCollaborationPage<GitHubCollaborationComment>
                switch prepared.kind {
                case .review: page = try await reviews(prepared.repository, number: number, page: p, token: token)
                case .lineComment: page = try await reviewComments(prepared.repository, number: number, page: p, token: token)
                default: page = try await comments(prepared.repository, number: number, page: p, token: token)
                }
                let matches = page.items.filter { value in
                    guard value.body == expectedBody, value.user?.login.caseInsensitiveCompare(actor) == .orderedSame else { return false }
                    if prepared.kind == .review { return value.commitID == prepared.expectedHeadSHA && value.state?.uppercased() == (payload?["event"] as? String).map { $0 == "COMMENT" ? "COMMENTED" : $0 == "APPROVE" ? "APPROVED" : "CHANGES_REQUESTED" } }
                    if let line = prepared.reviewLine { return value.commitID == prepared.expectedHeadSHA && value.path == line.path && value.line == line.line && value.side == line.side.rawValue && value.startLine == line.startLine }
                    return true
                }
                guard matches.count <= 1 else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
                if let item = matches.first { return .init(remoteID: item.id, url: item.htmlURL, commitSHA: item.commitID, confirmation: .observed) }
                if page.nextPage == nil { break }
            }
        }
        return nil
    }

    private func matchesPull(_ prepared: GitHubPreparedMutation, _ value: GitHubCollaborationPull) throws -> Bool {
        guard let body = try JSONSerialization.jsonObject(with: prepared.payload) as? [String: Any],
              let head = body["head"] as? String, let base = body["base"] as? String else { return false }
        let parts = head.split(separator: ":", maxSplits: 1).map(String.init)
        let owner = parts.count == 2 ? parts[0] : prepared.repository.owner
        let repository = body["head_repo"] as? String ?? prepared.repository.name
        return value.head.sha == prepared.expectedHeadSHA && value.head.ref == parts.last
            && value.base.ref == base && value.base.repo?.fullName.caseInsensitiveCompare(prepared.repository.fullName) == .orderedSame
            && value.head.repo?.fullName.caseInsensitiveCompare(owner + "/" + repository) == .orderedSame
    }

    /// Acknowledged API writes are followed by an independent read of the
    /// actual object. A failure here keeps the delivery uncertain and retains
    /// its result link for inspection; it never repeats the write.
    func confirm(_ prepared: GitHubPreparedMutation, result: GitHubMutationResult, actor: String, token: String) async throws {
        if prepared.runID != nil || prepared.kind == .mergePull || prepared.kind == .updateIssue {
            guard try await reconcile(prepared, actor: actor, token: token) != nil else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
            return
        }
        let payload = try JSONSerialization.jsonObject(with: prepared.payload) as? [String: Any]
        let link = try GitHubLinkParser.parse(result.url.absoluteString)
        guard link.repository == prepared.repository else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
        if prepared.kind == .createIssue, let number = link.number {
            let actual = try await issue(prepared.repository, number: number, token: token)
            guard actual.id == result.remoteID, actual.body == payload?["body"] as? String,
                  actual.title == payload?["title"] as? String,
                  actual.user?.login.caseInsensitiveCompare(actor) == .orderedSame else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
        } else if prepared.kind == .createPull, let number = link.number {
            let actual = try await pull(prepared.repository, number: number, token: token)
            guard actual.id == result.remoteID, actual.body == payload?["body"] as? String,
                  try matchesPull(prepared, actual),
                  actual.user?.login.caseInsensitiveCompare(actor) == .orderedSame else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
        } else if let id = result.remoteID {
            let path: [String]
            switch prepared.kind {
            case .review: path = ["pulls", String(prepared.number ?? 0), "reviews", String(id)]
            case .lineComment: path = ["pulls", "comments", String(id)]
            default: path = ["issues", "comments", String(id)]
            }
            let actual: GitHubCollaborationComment = try await json(prefix(prepared.repository) + path, token: token)
            guard actual.id == id, actual.body == payload?["body"] as? String,
                  actual.user?.login.caseInsensitiveCompare(actor) == .orderedSame,
                  prepared.expectedHeadSHA == nil || actual.commitID == prepared.expectedHeadSHA else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
            if prepared.kind == .review {
                let event = payload?["event"] as? String
                let expectedState = event == "APPROVE" ? "APPROVED" : event == "REQUEST_CHANGES" ? "CHANGES_REQUESTED" : "COMMENTED"
                guard actual.state?.uppercased() == expectedState else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
            }
            if let line = prepared.reviewLine {
                guard actual.path == line.path, actual.line == line.line, actual.side == line.side.rawValue,
                      actual.startLine == line.startLine else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
            }
        } else { throw GitHubCollaborationError.outcomeUnknown(prepared.id) }
    }
}
