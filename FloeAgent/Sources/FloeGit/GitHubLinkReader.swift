// SPDX-License-Identifier: MPL-2.0
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Only GET requests through the existing GitHub API client. Tokens are used
/// for transport only and are never part of the returned source/context.
public struct GitHubLinkReader: Sendable {
    public let client: GitHubActionsClient
    public init(client: GitHubActionsClient = GitHubActionsClient()) { self.client = client }

    public func read(
        _ url: String, token: String, options: GitHubLinkReadOptions = GitHubLinkReadOptions(),
        association: GitHubLinkAssociation = GitHubLinkAssociation(),
        progress: (@Sendable (GitHubLinkReadProgress) async -> Void)? = nil
    ) async throws -> GitHubLinkSnapshot {
        let link = try GitHubLinkParser.parse(url)
        return try await GitHubLinkReadOperation(client: client, link: link, token: token,
                                                options: options, association: association, progress: progress).run()
    }
}

private actor GitHubLinkReadOperation {
    let client: GitHubActionsClient
    let link: GitHubLink
    let token: String
    let options: GitHubLinkReadOptions
    let association: GitHubLinkAssociation
    let progress: (@Sendable (GitHubLinkReadProgress) async -> Void)?
    var evidence: [GitHubLinkRequestEvidence] = []
    var prefix: [String] { ["repos", link.repository.owner, link.repository.name] }
    var pageSize: Int { min(max(options.perPage, 1), 100) }
    var pageCount: Int { min(max(options.maximumPages, 1), 5) }
    var startPage: Int { min(max(options.startingPage, 1), 10_000) }
    var jsonLimit: Int { min(max(options.maximumJSONBytes, 1), 4_194_304) }

    init(client: GitHubActionsClient, link: GitHubLink, token: String, options: GitHubLinkReadOptions,
         association: GitHubLinkAssociation, progress: (@Sendable (GitHubLinkReadProgress) async -> Void)?) {
        self.client = client; self.link = link; self.token = token; self.options = options
        self.association = association; self.progress = progress
    }

    func run() async throws -> GitHubLinkSnapshot {
        let wire: LinkRepositoryWire = try await json(prefix)
        guard wire.full_name.lowercased() == link.repository.fullName.lowercased() else {
            throw GitHubLinkError.invalidResponse("repository identity")
        }
        let repository = GitHubLinkRepository(id: wire.id, identity: link.repository, description: wire.description,
                                              defaultBranch: wire.default_branch, isPrivate: wire.private,
                                              url: try GitHubLinkParser.webURL([link.repository.owner, link.repository.name]))
        var revision: GitHubLinkRevision?
        var path: String?
        var readme: GitHubLinkFile?
        var directory: GitHubLinkPage<GitHubLinkTreeEntry>?
        var file: GitHubLinkFile?
        var commit: GitHubLinkCommit?
        var issue: GitHubLinkIssue?
        var pull: GitHubLinkPullRequest?
        var location: GitHubLinkLocation?
        var warnings: [GitHubLinkSnapshot.ReadWarning] = []
        switch link.kind {
        case .repository:
            if let branch = wire.default_branch {
                do { revision = try await namedRevision(kind: .branch, name: branch) }
                catch GitHubLinkError.notFoundOrNotAccessible { warnings.append(.defaultRevisionUnavailable) }
                catch GitHubLinkError.http(409) { warnings.append(.defaultRevisionUnavailable) }
                if let revision {
                    if options.includeReadme {
                        do {
                            let content: LinkContentWire = try await json(prefix + ["readme"], query: refQuery(revision.commitSHA), accept: "application/vnd.github.object+json")
                            readme = try await readContent(content, revision: revision)
                        } catch GitHubLinkError.notFoundOrNotAccessible { warnings.append(.readmeMissing) }
                    }
                    if options.includeDirectory { directory = try await readDirectory(path: "", revision: revision) }
                }
            } else { warnings.append(.defaultRevisionUnavailable) }
        case .tree, .file:
            let resolved = try await resolveRevision()
            revision = resolved.0; path = resolved.1
            if link.kind == .tree { directory = try await readDirectory(path: resolved.1, revision: resolved.0) }
            else {
                guard !resolved.1.isEmpty else { throw GitHubLinkError.invalidLink("file path") }
                let content: LinkContentWire = try await json(prefix + ["contents"] + resolved.1.split(separator: "/").map(String.init), query: refQuery(resolved.0.commitSHA), accept: "application/vnd.github.object+json")
                guard content.path == resolved.1 else { throw GitHubLinkError.invalidResponse("file path") }
                file = try await readContent(content, revision: resolved.0)
                location = lineLocation(file: file!, revision: resolved.0)
            }
        case .commit:
            guard let requested = link.revisionAndPath.first else { throw GitHubLinkError.invalidLink("commit") }
            revision = try await commitRevision(requested)
            commit = try await readCommit(revision!.commitSHA)
            location = diffLocation(files: commit?.files, commitSHA: revision!.commitSHA, baseSHA: commit?.parents.first)
        case .issue:
            let number = try number()
            let value: LinkIssueWire = try await json(prefix + ["issues", String(number)])
            guard value.number == number else { throw GitHubLinkError.invalidResponse("issue identity") }
            try validateWebIdentity(value.html_url, route: "issues", number: number, alternatives: ["pull"])
            var comments: GitHubLinkPage<GitHubLinkComment>?
            if options.includeComments { comments = try await issueComments(number) }
            issue = GitHubLinkIssue(number: number, title: value.title, state: value.state, body: value.body ?? "",
                                    labels: value.labels.map(\.name), author: value.user?.login, updatedAt: value.updated_at,
                                    isPullRequest: value.pull_request != nil, comments: comments)
            location = try await selectedComment(number: number, isPull: value.pull_request != nil)
        case .pullRequest:
            let number = try number()
            let value: LinkPullWire = try await json(prefix + ["pulls", String(number)])
            try validatePull(value, number: number)
            if let expected = options.expectedPullHeadSHA, expected != value.head.sha { throw GitHubLinkError.sourceChanged }
            var files: GitHubLinkPage<GitHubLinkChangedFile>?
            if let historical = link.pullRequestCommit {
                // A commit-scoped PR URL is not the current aggregate PR diff.
                let commits: GitHubLinkPage<LinkPullCommitWire> = try await pages(prefix + ["pulls", String(number), "commits"])
                let matches = commits.items.filter { $0.sha.lowercased().hasPrefix(historical.lowercased()) }
                guard matches.count == 1 else {
                    if !commits.isComplete || commits.items.count >= 250 { throw GitHubLinkError.invalidResponse("PR commit outside loaded range") }
                    throw GitHubLinkError.notFoundOrNotAccessible
                }
                revision = try await commitRevision(matches[0].sha)
                commit = try await readCommit(matches[0].sha)
                files = commit?.files
            } else if options.includeChanges || isDiffAnchor {
                let values: GitHubLinkPage<LinkChangedFileWire> = try await pages(prefix + ["pulls", String(number), "files"])
                files = try changePage(values, total: value.changed_files)
            }
            let comments = options.includeComments ? try await issueComments(number) : nil
            location = try await selectedComment(number: number, isPull: true)
            if location == nil { location = diffLocation(files: files, commitSHA: revision?.commitSHA ?? value.head.sha,
                                                          baseSHA: revision == nil ? value.base.sha : commit?.parents.first) }
            let after: LinkPullWire = try await json(prefix + ["pulls", String(number)])
            try validatePull(after, number: number)
            guard value.head.sha == after.head.sha, value.base.sha == after.base.sha, value.updated_at == after.updated_at else {
                throw GitHubLinkError.sourceChanged
            }
            pull = GitHubLinkPullRequest(number: number, title: value.title, state: value.state, body: value.body ?? "",
                                         isDraft: value.draft ?? false, isMerged: value.merged ?? false,
                                         base: try pullSide(value.base), head: try pullSide(value.head), changedFileCount: value.changed_files,
                                         updatedAt: value.updated_at, files: files, comments: comments)
        }
        var resolvedURL = link.url
        if let revision {
            if link.kind == .repository || link.kind == .tree || link.kind == .file {
                resolvedURL = try GitHubLinkParser.webURL([link.repository.owner, link.repository.name,
                                                          link.kind == .file ? "blob" : "tree", revision.commitSHA]
                                                         + (path ?? "").split(separator: "/").map(String.init), fragment: link.url.fragment)
            } else if link.kind == .commit {
                resolvedURL = try GitHubLinkParser.webURL([link.repository.owner, link.repository.name, "commit", revision.commitSHA], fragment: link.url.fragment)
            }
        }
        try Task.checkCancellation()
        return GitHubLinkSnapshot(link: link, association: association, repository: repository,
            source: GitHubLinkSource(originalURL: link.url, resolvedURL: resolvedURL, repository: link.repository,
                                     revision: revision, path: path, anchor: link.anchor, readAt: Date(), requests: evidence),
            readme: readme, directory: directory, file: file, commit: commit, issue: issue, pullRequest: pull, location: location, warnings: warnings)
    }

    private func response(_ segments: [String], query: [URLQueryItem] = [], accept: String = "application/vnd.github+json", limit: Int? = nil) async throws -> GitHubLinkHTTPResponse {
        try Task.checkCancellation()
        let result = try await client.readLinkResource(segments, query: query, token: token, accept: accept, maximumBytes: limit ?? jsonLimit)
        evidence.append(result.evidence)
        if let progress {
            await progress(GitHubLinkReadProgress(completedRequests: evidence.count,
                                                 receivedBytes: evidence.reduce(0) { $0 + $1.byteCount }, apiURL: result.evidence.apiURL))
        }
        try Task.checkCancellation()
        return result
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw GitHubLinkError.invalidResponse("JSON shape") }
    }

    private func json<T: Decodable>(_ segments: [String], query: [URLQueryItem] = [], accept: String = "application/vnd.github+json") async throws -> T {
        try decode(try await response(segments, query: query, accept: accept).data)
    }

    private func refQuery(_ sha: String) -> [URLQueryItem] { [URLQueryItem(name: "ref", value: sha)] }
    private func number() throws -> Int {
        guard let number = link.number else { throw GitHubLinkError.invalidLink("number") }; return number
    }

    private func pages<T: Codable & Sendable & Hashable>(_ segments: [String]) async throws -> GitHubLinkPage<T> {
        var items: [T] = []
        var page = startPage
        var read = 0
        var next: Int?
        repeat {
            let result = try await response(segments, query: [URLQueryItem(name: "per_page", value: String(pageSize)), URLQueryItem(name: "page", value: String(page))])
            let values: [T] = try decode(result.data)
            items += values; read += 1
            next = try nextPage(result, current: page)
            if let next { page = next } else { break }
        } while read < pageCount
        return GitHubLinkPage(items: items, nextPage: next, pagesRead: read, isComplete: next == nil && startPage == 1)
    }

    private func nextPage(_ result: GitHubLinkHTTPResponse, current: Int) throws -> Int? {
        guard let header = result.response.value(forHTTPHeaderField: "Link") else { return nil }
        guard let next = GitHubActionsPagination.nextURL(fromLinkHeader: header) else {
            if header.contains("rel=\"next\"") { throw GitHubLinkError.unsafePagination }; return nil
        }
        let original = result.evidence.apiURL
        guard next.scheme == "https", next.host == original.host, next.port == original.port,
              next.user == nil, next.password == nil, next.fragment == nil, next.path == original.path,
              let query = URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems,
              query.allSatisfy({ ["page", "per_page"].contains($0.name) }),
              query.filter({ $0.name == "page" }).count == 1,
              query.filter({ $0.name == "per_page" }).count == 1,
              let rawPage = query.first(where: { $0.name == "page" })?.value, let page = Int(rawPage), page == current + 1,
              query.first(where: { $0.name == "per_page" })?.value == String(pageSize) else { throw GitHubLinkError.unsafePagination }
        return page
    }

    private func resolveRevision() async throws -> (GitHubLinkRevision, String) {
        let tail = link.revisionAndPath.joined(separator: "/")
        guard let first = link.revisionAndPath.first else { throw GitHubLinkError.revisionNotFound }
        var candidates: [(GitHubLinkRevision.Kind, String, LinkObjectWire)] = []
        for kind in [GitHubLinkRevision.Kind.branch, .tag] {
            if let explicit = link.explicitRefKind, explicit != kind { continue }
            let namespace = kind == .branch ? "heads" : "tags"
            let refs: [LinkRefWire] = try await json(prefix + ["git", "matching-refs", namespace, first])
            for ref in refs {
                let leader = "refs/" + namespace + "/"
                guard ref.ref.hasPrefix(leader) else { throw GitHubLinkError.invalidResponse("ref namespace") }
                let name = String(ref.ref.dropFirst(leader.count))
                if tail == name || tail.hasPrefix(name + "/") { candidates.append((kind, name, ref.object)) }
            }
        }
        if let selection = options.revisionSelection {
            candidates = candidates.filter { $0.0 == selection.kind && $0.1 == selection.name }
        }
        if candidates.isEmpty, link.explicitRefKind == nil, options.revisionSelection == nil, GitHubLinkParser.isCommitName(first) {
            let revision = try await commitRevision(first)
            return (revision, link.revisionAndPath.dropFirst().joined(separator: "/"))
        }
        guard let length = candidates.map({ $0.1.count }).max() else { throw GitHubLinkError.revisionNotFound }
        candidates = candidates.filter { $0.1.count == length }
        guard candidates.count == 1 else { throw GitHubLinkError.ambiguousRevision(candidates.map { ($0.0 == .branch ? "refs/heads/" : "refs/tags/") + $0.1 }.sorted()) }
        let candidate = candidates[0]
        let sha = try await peel(candidate.2)
        let commit: LinkGitCommitWire = try await json(prefix + ["git", "commits", sha])
        try validateCommit(commit.sha, expected: sha)
        guard GitHubLinkParser.isSHA(commit.tree.sha) else { throw GitHubLinkError.invalidResponse("tree SHA") }
        let remaining = tail == candidate.1 ? "" : String(tail.dropFirst(candidate.1.count + 1))
        return (GitHubLinkRevision(kind: candidate.0, name: candidate.1, commitSHA: sha, treeSHA: commit.tree.sha), remaining)
    }

    private func namedRevision(kind: GitHubLinkRevision.Kind, name: String) async throws -> GitHubLinkRevision {
        let ref: LinkRefWire = try await json(prefix + ["git", "ref", kind == .branch ? "heads" : "tags", name])
        guard ref.ref == "refs/" + (kind == .branch ? "heads/" : "tags/") + name else { throw GitHubLinkError.invalidResponse("ref identity") }
        let sha = try await peel(ref.object)
        let commit: LinkGitCommitWire = try await json(prefix + ["git", "commits", sha])
        try validateCommit(commit.sha, expected: sha)
        guard GitHubLinkParser.isSHA(commit.tree.sha) else { throw GitHubLinkError.invalidResponse("tree SHA") }
        return GitHubLinkRevision(kind: kind, name: name, commitSHA: sha, treeSHA: commit.tree.sha)
    }

    private func peel(_ initial: LinkObjectWire) async throws -> String {
        var object = initial
        var seen: Set<String> = []
        for _ in 0..<8 {
            guard GitHubLinkParser.isSHA(object.sha), seen.insert(object.sha).inserted else { throw GitHubLinkError.invalidResponse("ref object") }
            if object.type == "commit" { return object.sha }
            guard object.type == "tag" else { throw GitHubLinkError.invalidResponse("ref is not a commit") }
            let tag: LinkTagWire = try await json(prefix + ["git", "tags", object.sha])
            guard tag.sha == object.sha else { throw GitHubLinkError.invalidResponse("tag identity") }
            object = tag.object
        }
        throw GitHubLinkError.invalidResponse("tag depth")
    }

    private func commitRevision(_ requested: String) async throws -> GitHubLinkRevision {
        let value: LinkCommitWire = try await json(prefix + ["commits", requested], query: [URLQueryItem(name: "per_page", value: "1")])
        guard GitHubLinkParser.isSHA(value.sha), value.sha.lowercased().hasPrefix(requested.lowercased()), GitHubLinkParser.isSHA(value.commit.tree.sha) else {
            throw GitHubLinkError.invalidResponse("commit identity")
        }
        return GitHubLinkRevision(kind: .commit, name: requested, commitSHA: value.sha, treeSHA: value.commit.tree.sha)
    }

    private func validateCommit(_ sha: String, expected: String) throws {
        guard GitHubLinkParser.isSHA(sha), sha == expected else { throw GitHubLinkError.invalidResponse("commit identity") }
    }

    private func readDirectory(path: String, revision: GitHubLinkRevision) async throws -> GitHubLinkPage<GitHubLinkTreeEntry> {
        var sha = revision.treeSHA
        var directoryPath = ""
        for component in path.split(separator: "/") {
            let parent: LinkTreeWire = try await json(prefix + ["git", "trees", sha])
            guard parent.sha == sha else { throw GitHubLinkError.invalidResponse("tree identity") }
            guard let item = parent.tree.first(where: { $0.path == component && $0.type == "tree" }) else {
                if parent.truncated { throw GitHubLinkError.invalidResponse("directory outside truncated tree") }
                throw GitHubLinkError.notFoundOrNotAccessible
            }
            guard GitHubLinkParser.isSHA(item.sha) else { throw GitHubLinkError.invalidResponse("tree child") }
            sha = item.sha; directoryPath += String(component) + "/"
        }
        let tree: LinkTreeWire = try await json(prefix + ["git", "trees", sha])
        guard tree.sha == sha else { throw GitHubLinkError.invalidResponse("tree identity") }
        let entries = try tree.tree.map { value in
            guard safePath(value.path), GitHubLinkParser.isSHA(value.sha) else { throw GitHubLinkError.invalidResponse("tree entry") }
            return GitHubLinkTreeEntry(path: directoryPath + value.path, mode: value.mode, type: value.type, sha: value.sha, size: value.size)
        }
        return GitHubLinkPage(items: entries, nextPage: nil, pagesRead: 1, isComplete: !tree.truncated)
    }

    private func readContent(_ value: LinkContentWire, revision: GitHubLinkRevision) async throws -> GitHubLinkFile {
        guard safePath(value.path), GitHubLinkParser.isSHA(value.sha), value.size >= 0 else { throw GitHubLinkError.invalidResponse("content identity") }
        var state = GitHubLinkFile.ContentState.notRequested
        var data: Data?
        let limit = min(max(options.maximumFileBytes, 1), 4_194_304)
        if value.type != "file" || value.submodule_git_url != nil { state = .unsupportedType }
        else if !options.includeFileContent { state = .notRequested }
        else if value.size > limit { state = .exceedsLimit }
        else if value.encoding == "base64", let encoded = value.content {
            let clean = encoded.filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: clean), decoded.count == value.size else { throw GitHubLinkError.invalidResponse("base64 content") }
            data = decoded; state = .loaded
        } else {
            let result = try await response(prefix + ["contents"] + value.path.split(separator: "/").map(String.init),
                                            query: refQuery(revision.commitSHA), accept: "application/vnd.github.raw+json", limit: limit)
            guard result.data.count == value.size else { throw GitHubLinkError.sourceChanged }
            data = result.data; state = .loaded
        }
        if let data {
            var gitObject = Data("blob \(data.count)\0".utf8); gitObject.append(data)
            let actual = Insecure.SHA1.hash(data: gitObject).map { String(format: "%02x", $0) }.joined()
            guard actual == value.sha else { throw GitHubLinkError.invalidResponse("blob content SHA") }
        }
        return GitHubLinkFile(path: value.path, blobSHA: value.sha, type: value.submodule_git_url != nil ? "submodule" : value.type,
                              size: value.size, content: data, contentState: state)
    }

    private func readCommit(_ sha: String) async throws -> GitHubLinkCommit {
        var first: LinkCommitWire?
        var items: [LinkChangedFileWire] = []
        var current = startPage
        var next: Int?
        var read = 0
        repeat {
            let result = try await response(prefix + ["commits", sha], query: [URLQueryItem(name: "per_page", value: String(pageSize)), URLQueryItem(name: "page", value: String(current))])
            let value: LinkCommitWire = try decode(result.data)
            try validateCommit(value.sha, expected: sha)
            if let first, first.commit != value.commit || first.parents != value.parents { throw GitHubLinkError.sourceChanged }
            else if first == nil { first = value }
            if options.includeChanges || isDiffAnchor { items += value.files ?? [] }
            read += 1; next = try nextPage(result, current: current)
            if !options.includeChanges && !isDiffAnchor { break }
            if let next { current = next } else { break }
        } while read < pageCount
        guard let value = first else { throw GitHubLinkError.invalidResponse("commit") }
        let files = options.includeChanges || isDiffAnchor ? GitHubLinkPage(items: try items.map(changedFile), nextPage: next, pagesRead: read,
                                                                             isComplete: next == nil && startPage == 1 && items.count < 3000) : nil
        return GitHubLinkCommit(sha: sha, message: value.commit.message, authorName: value.commit.author?.name, authorDate: value.commit.author?.date,
                                committerName: value.commit.committer?.name, parents: value.parents.map(\.sha), files: files)
    }

    private func changedFile(_ value: LinkChangedFileWire) throws -> GitHubLinkChangedFile {
        guard GitHubLinkParser.isSHA(value.sha), safePath(value.filename), value.previous_filename.map(safePath) ?? true,
              value.additions >= 0, value.deletions >= 0, value.changes >= 0 else { throw GitHubLinkError.invalidResponse("changed file identity") }
        return GitHubLinkChangedFile(sha: value.sha, filename: value.filename, previousFilename: value.previous_filename, status: value.status,
                               additions: value.additions, deletions: value.deletions, changes: value.changes,
                               patch: options.includePatch || isDiffAnchor ? value.patch : nil,
                               patchState: options.includePatch || isDiffAnchor ? (value.patch == nil ? "unavailable" : "providedByGitHub") : "notRequested")
    }

    private func changePage(_ value: GitHubLinkPage<LinkChangedFileWire>, total: Int) throws -> GitHubLinkPage<GitHubLinkChangedFile> {
        GitHubLinkPage(items: try value.items.map(changedFile), nextPage: value.nextPage, pagesRead: value.pagesRead,
                       isComplete: value.isComplete && total == value.items.count && total <= 3000)
    }

    private func lineLocation(file: GitHubLinkFile, revision: GitHubLinkRevision) -> GitHubLinkLocation? {
        guard let anchor = link.anchor else { return nil }
        guard case .lines(let start, let end) = anchor else { return location(.unresolvedAnchor, path: file.path, sha: revision.commitSHA) }
        guard let text = file.text else { return location(.outsideLoadedRange, path: file.path, sha: revision.commitSHA, start: start, end: end) }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        guard end <= lines.count else { return location(.outsideLoadedRange, path: file.path, sha: revision.commitSHA, start: start, end: end) }
        return location(.resolved, path: file.path, sha: revision.commitSHA, start: start, end: end,
                        text: lines[(start - 1)...(end - 1)].joined(separator: "\n"))
    }

    private var isDiffAnchor: Bool { if case .diff = link.anchor { return true }; return false }

    private func diffLocation(files: GitHubLinkPage<GitHubLinkChangedFile>?, commitSHA: String, baseSHA: String? = nil) -> GitHubLinkLocation? {
        guard let anchor = link.anchor else { return nil }
        guard case .diff(let digest, let side, let start, let end) = anchor else { return location(.unresolvedAnchor, sha: commitSHA) }
        // GitHub's HTML path digest is a presentation hint, not an API identity.
        // Match only against actually returned filenames; otherwise stay unresolved.
        guard let file = files?.items.first(where: { Self.pathDigest($0.filename) == digest }) else {
            return location(files?.isComplete == false ? .outsideLoadedRange : .unresolvedAnchor, sha: commitSHA, side: side, start: start, end: end)
        }
        let path = side == "L" ? (file.previousFilename ?? file.filename) : file.filename
        let sha = side == "L" ? baseSHA : commitSHA
        if let start, let end {
            guard let patch = file.patch, let selection = selectedDiffLines(patch, side: side, start: start, end: end) else {
                return location(.outsideLoadedRange, path: path, sha: sha, side: side, start: start, end: end)
            }
            return location(.resolved, path: path, sha: sha, side: side, start: start, end: end, text: selection)
        }
        return location(.resolved, path: path, sha: sha, side: side, text: file.patch)
    }

    private func selectedDiffLines(_ patch: String, side: String?, start: Int, end: Int) -> String? {
        guard side == "L" || side == "R", end - start < 10_000 else { return nil }
        let regex = try? NSRegularExpression(pattern: "^@@ -([0-9]+)(?:,[0-9]+)? \\+([0-9]+)(?:,[0-9]+)? @@")
        var left = 0, right = 0
        var selected: [Int: String] = [:]
        for line in patch.components(separatedBy: "\n") {
            if let match = regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let old = Range(match.range(at: 1), in: line), let new = Range(match.range(at: 2), in: line),
               let oldLine = Int(line[old]), let newLine = Int(line[new]) { left = oldLine; right = newLine; continue }
            guard left > 0 || right > 0 else { continue }
            if line.hasPrefix("\\") { continue }
            let belongs = side == "L" ? !line.hasPrefix("+") : !line.hasPrefix("-")
            let number = side == "L" ? left : right
            if belongs, number >= start, number <= end { selected[number] = String(line.dropFirst()) }
            if !line.hasPrefix("+") { left += 1 }
            if !line.hasPrefix("-") { right += 1 }
        }
        guard selected.count == end - start + 1 else { return nil }
        return (start...end).compactMap { selected[$0] }.joined(separator: "\n")
    }

    private static func pathDigest(_ path: String) -> String { SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func location(_ state: GitHubLinkLocation.State, path: String? = nil, sha: String? = nil, side: String? = nil,
                          start: Int? = nil, end: Int? = nil, text: String? = nil, comment: GitHubLinkComment? = nil) -> GitHubLinkLocation {
        GitHubLinkLocation(state: state, path: path, commitSHA: sha, side: side, startLine: start, endLine: end, selectedText: text, selectedComment: comment)
    }

    private func issueComments(_ number: Int) async throws -> GitHubLinkPage<GitHubLinkComment> {
        let page: GitHubLinkPage<LinkCommentWire> = try await pages(prefix + ["issues", String(number), "comments"])
        let comments = try page.items.map { value in
            try validateAPIIdentity(value.issue_url, route: "issues", number: number)
            return try comment(value, kind: "issueComment", route: "issues", number: number)
        }
        return GitHubLinkPage(items: comments, nextPage: page.nextPage, pagesRead: page.pagesRead, isComplete: page.isComplete)
    }

    private func selectedComment(number: Int, isPull: Bool) async throws -> GitHubLinkLocation? {
        guard let anchor = link.anchor else { return nil }
        let value: LinkCommentWire
        let selected: GitHubLinkComment
        switch anchor {
        case .issueComment(let id):
            value = try await json(prefix + ["issues", "comments", String(id)])
            guard value.id == id else { throw GitHubLinkError.invalidResponse("comment identity") }
            try validateAPIIdentity(value.issue_url, route: "issues", number: number)
            selected = try comment(value, kind: "issueComment", route: isPull ? "pull" : "issues", number: number)
        case .reviewComment(let id) where isPull:
            value = try await json(prefix + ["pulls", "comments", String(id)])
            guard value.id == id else { throw GitHubLinkError.invalidResponse("review comment identity") }
            try validateAPIIdentity(value.pull_request_url, route: "pulls", number: number)
            selected = try comment(value, kind: "reviewComment", route: "pull", number: number)
        case .review(let id) where isPull:
            value = try await json(prefix + ["pulls", String(number), "reviews", String(id)])
            guard value.id == id else { throw GitHubLinkError.invalidResponse("review identity") }
            selected = try comment(value, kind: "review", route: "pull", number: number)
        case .diff: return nil
        default: return location(.unresolvedAnchor)
        }
        let historical = selected.kind == "reviewComment" && selected.line == nil
        return location(historical ? .historicalReview : .resolved,
                        path: selected.path, sha: historical ? (selected.originalCommitSHA ?? selected.commitSHA) : selected.commitSHA, side: selected.side,
                        start: historical ? (selected.originalStartLine ?? selected.originalLine) : (selected.startLine ?? selected.line), end: selected.line ?? selected.originalLine,
                        text: selected.diffHunk, comment: selected)
    }

    private func comment(_ value: LinkCommentWire, kind: String, route: String, number: Int) throws -> GitHubLinkComment {
        try validateWebIdentity(value.html_url, route: route, number: number, alternatives: route == "issues" ? ["pull"] : [])
        if let path = value.path, !safePath(path) { throw GitHubLinkError.invalidResponse("review path") }
        for sha in [value.commit_id, value.original_commit_id].compactMap({ $0 }) where !GitHubLinkParser.isSHA(sha) {
            throw GitHubLinkError.invalidResponse("review commit")
        }
        return GitHubLinkComment(id: value.id, kind: kind, body: value.body ?? "", author: value.user?.login,
                                  createdAt: value.created_at, updatedAt: value.updated_at, url: value.html_url,
                                  path: value.path, commitSHA: value.commit_id, originalCommitSHA: value.original_commit_id,
                                  line: value.line, originalLine: value.original_line, startLine: value.start_line, originalStartLine: value.original_start_line,
                                  side: value.side ?? value.start_side, diffHunk: value.diff_hunk, state: value.state)
    }

    private func validatePull(_ value: LinkPullWire, number: Int) throws {
        guard value.number == number, GitHubLinkParser.isSHA(value.head.sha), GitHubLinkParser.isSHA(value.base.sha) else { throw GitHubLinkError.invalidResponse("PR identity") }
        try validateWebIdentity(value.html_url, route: "pull", number: number)
        guard let base = value.base.repo, base.full_name.lowercased() == link.repository.fullName.lowercased() else { throw GitHubLinkError.invalidResponse("PR base ownership") }
    }

    private func pullSide(_ value: LinkPullSideWire) throws -> GitHubLinkPullSide {
        var identity: GitHubLinkRepositoryID?
        if let repo = value.repo {
            let parsed = try GitHubLinkParser.parse("https://github.com/" + repo.full_name)
            identity = parsed.repository
        }
        return GitHubLinkPullSide(repository: identity, ref: value.ref, sha: value.sha, label: value.label)
    }

    private func validateWebIdentity(_ url: URL, route: String, number: Int, alternatives: [String] = []) throws {
        let parsed = try GitHubLinkParser.parse(url.absoluteString)
        guard parsed.repository.fullName.lowercased() == link.repository.fullName.lowercased(), parsed.number == number,
              ([route] + alternatives).contains(url.path.split(separator: "/").dropFirst(2).first.map(String.init) ?? ""),
              url.query == nil, url.user == nil, url.password == nil else { throw GitHubLinkError.invalidResponse("web source ownership") }
    }

    private func validateAPIIdentity(_ url: URL?, route: String, number: Int) throws {
        guard let url, url.scheme == "https", url.host == client.baseURL.host, url.user == nil, url.password == nil,
              url.port == client.baseURL.port, url.query == nil, url.fragment == nil,
              url.path.lowercased() == "/repos/\(link.repository.fullName)/\(route)/\(number)".lowercased() else {
            throw GitHubLinkError.invalidResponse("comment source ownership")
        }
    }

    private func safePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && value.utf8.count <= 16_384
            && !value.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
    }
}

// Explicit wire names avoid acronym conversions in JSONDecoder key strategies.
private struct LinkRepositoryWire: Decodable { let id: Int64; let full_name: String; let description: String?; let default_branch: String?; let `private`: Bool }
private struct LinkObjectWire: Codable, Sendable, Hashable { let type: String; let sha: String }
private struct LinkRefWire: Decodable { let ref: String; let object: LinkObjectWire }
private struct LinkTagWire: Decodable { let sha: String; let object: LinkObjectWire }
private struct LinkSHAWire: Codable, Sendable, Hashable { let sha: String }
private struct LinkAuthorWire: Codable, Sendable, Hashable { let name: String?; let date: String? }
private struct LinkGitCommitWire: Codable, Sendable, Hashable {
    let sha: String; let message: String; let tree: LinkSHAWire; let author: LinkAuthorWire?; let committer: LinkAuthorWire?; let parents: [LinkSHAWire]
}
private struct LinkCommitCoreWire: Codable, Sendable, Hashable {
    let message: String; let tree: LinkSHAWire; let author: LinkAuthorWire?; let committer: LinkAuthorWire?
}
private struct LinkCommitWire: Decodable { let sha: String; let commit: LinkCommitCoreWire; let parents: [LinkSHAWire]; let files: [LinkChangedFileWire]? }
private struct LinkPullCommitWire: Codable, Sendable, Hashable { let sha: String }
private struct LinkTreeWire: Decodable { let sha: String; let truncated: Bool; let tree: [LinkTreeEntryWire] }
private struct LinkTreeEntryWire: Decodable { let path: String; let mode: String; let type: String; let sha: String; let size: Int? }
private struct LinkContentWire: Decodable {
    let type: String; let path: String; let sha: String; let size: Int; let content: String?; let encoding: String?; let submodule_git_url: String?
}
private struct LinkChangedFileWire: Codable, Sendable, Hashable {
    let sha: String; let filename: String; let previous_filename: String?; let status: String
    let additions: Int; let deletions: Int; let changes: Int; let patch: String?
}
private struct LinkUserWire: Codable, Sendable, Hashable { let login: String }
private struct LinkLabelWire: Decodable { let name: String }
private struct LinkIssueWire: Decodable {
    let number: Int; let title: String; let state: String; let body: String?; let labels: [LinkLabelWire]; let user: LinkUserWire?
    let updated_at: String?; let html_url: URL; let pull_request: LinkIssuePullWire?
}
private struct LinkIssuePullWire: Decodable { let url: URL? }
private struct LinkPullRepositoryWire: Decodable { let full_name: String }
private struct LinkPullSideWire: Decodable { let ref: String; let sha: String; let label: String?; let repo: LinkPullRepositoryWire? }
private struct LinkPullWire: Decodable {
    let number: Int; let title: String; let state: String; let body: String?; let draft: Bool?; let merged: Bool?; let changed_files: Int
    let base: LinkPullSideWire; let head: LinkPullSideWire; let updated_at: String?; let html_url: URL
}
private struct LinkCommentWire: Codable, Sendable, Hashable {
    let id: Int64; let body: String?; let user: LinkUserWire?; let created_at: String?; let updated_at: String?; let html_url: URL
    let issue_url: URL?; let pull_request_url: URL?; let path: String?; let commit_id: String?; let original_commit_id: String?
    let line: Int?; let original_line: Int?; let start_line: Int?; let original_start_line: Int?; let side: String?; let start_side: String?
    let diff_hunk: String?; let state: String?
}
