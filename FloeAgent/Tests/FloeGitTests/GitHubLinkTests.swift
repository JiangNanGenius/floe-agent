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
import Testing
@testable import FloeGit

private final class GitHubLinkProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var data = Data()
        var stall = false
        var failure = false
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Reply)?
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    nonisolated(unsafe) private static var stops = 0
    static func prepare(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }; Self.handler = handler; seen = []; stops = 0
    }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    static var stopped: Int { lock.lock(); defer { lock.unlock() }; return stops }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.seen.append(request); let handler = Self.handler; Self.lock.unlock()
        guard let reply = handler?(request) else { return }
        if reply.stall { return }
        if reply.failure { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.lock(); Self.stops += 1; Self.lock.unlock() }
}

private let linkHead = String(repeating: "a", count: 40)
private let linkBase = String(repeating: "b", count: 40)
private let linkTree = String(repeating: "c", count: 40)
private let linkTag = String(repeating: "d", count: 40)
private let linkText = "first\n第二行\nthird\n"
private func linkJSON(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> GitHubLinkProtocol.Reply {
    GitHubLinkProtocol.Reply(status: status, headers: headers, data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
}
private func linkReader() -> GitHubLinkReader {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [GitHubLinkProtocol.self]
    return GitHubLinkReader(client: GitHubActionsClient(session: URLSession(configuration: config)))
}
private func gitBlobSHA(_ data: Data) -> String {
    var object = Data("blob \(data.count)\0".utf8); object.append(data)
    return Insecure.SHA1.hash(data: object).map { String(format: "%02x", $0) }.joined()
}
private func linkRepo() -> GitHubLinkProtocol.Reply {
    linkJSON(["id": 17, "full_name": "o/r", "description": "Fixture", "default_branch": "main", "private": true])
}
private func linkRef(_ name: String, sha: String = linkHead, type: String = "commit") -> [String: Any] {
    ["ref": name, "object": ["type": type, "sha": sha]]
}
private func gitCommit(_ sha: String = linkHead) -> GitHubLinkProtocol.Reply {
    linkJSON(["sha": sha, "message": "test", "tree": ["sha": linkTree], "parents": [["sha": linkBase]], "author": ["name": "A", "date": "2026-11-09T00:00:00Z"]])
}
private func linkFile(_ path: String = "目录/hello world.txt", text: String = linkText) -> GitHubLinkProtocol.Reply {
    let bytes = Data(text.utf8)
    return linkJSON(["type": "file", "path": path, "sha": gitBlobSHA(bytes), "size": bytes.count, "encoding": "base64", "content": bytes.base64EncodedString()])
}
private func changedFile() -> [String: Any] {
    ["sha": linkHead, "filename": "src/new.swift", "previous_filename": "src/old.swift", "status": "renamed", "additions": 1, "deletions": 1, "changes": 2,
     "patch": "@@ -1,2 +1,2 @@\n-old\n+new\n same"]
}
private func linkCommit(files: [[String: Any]] = [changedFile()], headers: [String: String] = [:], message: String = "change") -> GitHubLinkProtocol.Reply {
    linkJSON(["sha": linkHead, "commit": ["message": message, "tree": ["sha": linkTree], "author": ["name": "Alice", "date": "2026-11-09T00:00:00Z"]],
              "parents": [["sha": linkBase]], "files": files], headers: headers)
}
private func issueWire() -> GitHubLinkProtocol.Reply {
    linkJSON(["number": 7, "title": "Question", "body": "untrusted body", "state": "open", "labels": [["name": "bug"]], "user": ["login": "alice"],
              "html_url": "https://github.com/o/r/issues/7", "updated_at": "2026-11-09T00:00:00Z"])
}
private func pullWire(sha: String = linkHead) -> GitHubLinkProtocol.Reply {
    linkJSON(["number": 9, "title": "PR", "body": "review", "state": "open", "draft": true, "merged": false, "changed_files": 1,
              "base": ["repo": ["full_name": "o/r"], "ref": "main", "sha": linkBase],
              "head": ["repo": ["full_name": "fork/r"], "ref": "feature/x", "sha": sha, "label": "fork:feature/x"],
              "html_url": "https://github.com/o/r/pull/9", "updated_at": "2026-11-09T00:00:00Z"])
}
private func issueComment(_ id: Int = 22, number: Int = 7) -> [String: Any] {
    ["id": id, "body": "comment", "user": ["login": "bob"], "html_url": "https://github.com/o/r/issues/\(number)#issuecomment-\(id)",
     "issue_url": "https://api.github.com/repos/o/r/issues/\(number)"]
}
private func fixture(_ extra: @escaping @Sendable (URLRequest) -> GitHubLinkProtocol.Reply?) {
    GitHubLinkProtocol.prepare { request in
        if let reply = extra(request) { return reply }
        switch request.url?.path {
        case "/repos/o/r": return linkRepo()
        case "/repos/o/r/git/ref/heads/main": return linkJSON(linkRef("refs/heads/main"))
        case "/repos/o/r/git/commits/" + linkHead: return gitCommit()
        case "/repos/o/r/git/matching-refs/heads/feature": return linkJSON([linkRef("refs/heads/feature/x")])
        case "/repos/o/r/git/matching-refs/tags/feature": return linkJSON([])
        case "/repos/o/r/issues/7": return issueWire()
        case "/repos/o/r/pulls/9": return pullWire()
        case "/repos/o/r/pulls/9/files": return linkJSON([changedFile()])
        default:
            print("Unmatched controlled GitHub route: \(request.url?.absoluteString ?? "nil")")
            return linkJSON(["message": "not found"], status: 404)
        }
    }
}

@Suite("GitHub link source contracts", .serialized)
struct GitHubLinkTests {
    @Test func parsesAllSixKindsAndSanitizesQueries() throws {
        let links: [(String, GitHubLink.Kind)] = [
            ("https://github.com/o/r.git?access_token=never-store", .repository),
            ("git@github.com:o/r.git", .repository), ("ssh://git@github.com/o/r.git", .repository),
            ("https://github.com/o/r/tree/feature/x/目录", .tree),
            ("https://github.com/o/r/commit/abcdef0", .commit),
            ("https://raw.githubusercontent.com/o/r/refs/heads/feature/x/目录/hello%20world.txt#L2-L3", .file),
            ("https://github.com/o/r/issues/7#issuecomment-22", .issue),
            ("https://github.com/o/r/pull/9/files#discussion_r33", .pullRequest)
        ]
        for (url, kind) in links {
            let parsed = try GitHubLinkParser.parse(url)
            #expect(parsed.kind == kind); #expect(parsed.repository.fullName == "o/r")
            #expect(parsed.url.query == nil); #expect(parsed.url.user == nil)
        }
        let raw = try GitHubLinkParser.parse(links[5].0)
        #expect(raw.explicitRefKind == .branch)
        #expect(raw.anchor == .lines(start: 2, end: 3))
        #expect(raw.url.host == "github.com")
        #expect(raw.revisionAndPath.last == "hello world.txt")
        #expect(!raw.url.absoluteString.contains("%2520"))
        let literalPercent = try GitHubLinkParser.parse("https://github.com/o/r/blob/main/目录/literal%2520.txt")
        #expect(literalPercent.revisionAndPath.last == "literal%20.txt")
    }

    @Test func rejectsSpoofingTraversalMalformedEncodingAndAnchors() {
        for link in ["http://github.com/o/r", "https://github.com.evil.test/o/r", "https://user:secret@github.com/o/r",
                     "https://github.com:444/o/r", "https://github.com/o/r/blob/main/%2e%2e/secret", "https://github.com/o/r/blob/main/%GG",
                     "https://github.com/o/r/blob/main/a%00", "https://github.com/o/r//blob/main/a", "https://github.com/o/r/blob/main/a#L3-L2",
                     "https://github.com/o/r/issues/7#issuecomment-0", "https://github.com/o/r/actions", "https://evil.test/o/r"] {
            #expect(throws: GitHubLinkError.self) { try GitHubLinkParser.parse(link) }
        }
    }

    @Test func readsRepositoryReadmeAtResolvedCommitAndRoundTripsContext() async throws {
        fixture { request in request.url?.path == "/repos/o/r/readme" ? linkFile("README.md") : nil }
        let result = try await linkReader().read("https://github.com/o/r?token=never-store", token: "transport-secret",
                                                association: GitHubLinkAssociation(taskID: "task-A", projectID: "project-A", noteID: "note-A"))
        #expect(result.repository.defaultBranch == "main")
        #expect(result.readme?.text == linkText)
        #expect(result.source.revision?.commitSHA == linkHead)
        #expect(result.source.resolvedURL.path.hasSuffix(linkHead))
        let readmeRequest = try #require(GitHubLinkProtocol.requests.last)
        #expect(readmeRequest.url?.query == "ref=" + linkHead)
        #expect(readmeRequest.value(forHTTPHeaderField: "Authorization") == "Bearer transport-secret")
        #expect(readmeRequest.value(forHTTPHeaderField: "X-GitHub-Api-Version") == GitHubActionsClient.stableAPIVersion)
        #expect(GitHubLinkProtocol.requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.host == "api.github.com" })
        let data = try JSONEncoder().encode(result)
        #expect(!String(decoding: data, as: UTF8.self).contains("transport-secret"))
        #expect(!String(decoding: data, as: UTF8.self).contains("never-store"))
        #expect(try JSONDecoder().decode(GitHubLinkSnapshot.self, from: data) == result)
        #expect(result.source.requests.count == 4)
        #expect(result.association.taskID == "task-A")
    }

    @Test func slashBranchAndUnicodeFileLinesAreBoundToCommit() async throws {
        fixture { request in request.url?.path == "/repos/o/r/contents/目录/hello world.txt" ? linkFile() : nil }
        let result = try await linkReader().read("https://github.com/o/r/blob/feature/x/目录/hello%20world.txt#L2-L3", token: "t")
        #expect(result.source.revision?.name == "feature/x")
        #expect(result.source.path == "目录/hello world.txt")
        #expect(result.location?.selectedText == "第二行\nthird")
        #expect(result.location?.commitSHA == linkHead)
        #expect(result.source.resolvedURL.path.contains("/blob/" + linkHead + "/"))
        #expect(GitHubLinkProtocol.requests.last?.url?.query == "ref=" + linkHead)
    }

    @Test func encodedSlashAndAnnotatedTagsResolveRealObjects() async throws {
        fixture { request in
            switch request.url?.path {
            case "/repos/o/r/git/matching-refs/tags/release/v1": return linkJSON([linkRef("refs/tags/release/v1", sha: linkTag, type: "tag")])
            case "/repos/o/r/git/tags/" + linkTag: return linkJSON(["sha": linkTag, "object": ["type": "commit", "sha": linkHead]])
            case "/repos/o/r/git/trees/" + linkTree: return linkJSON(["sha": linkTree, "truncated": false, "tree": [["path": "src", "mode": "040000", "type": "tree", "sha": linkBase]]])
            case "/repos/o/r/git/trees/" + linkBase: return linkJSON(["sha": linkBase, "truncated": true, "tree": [["path": "file.txt", "mode": "100644", "type": "blob", "sha": linkHead, "size": 10]]])
            default: return nil
            }
        }
        let result = try await linkReader().read("https://github.com/o/r/tree/refs/tags/release%2Fv1/src", token: "t")
        #expect(result.source.revision?.kind == .tag)
        #expect(result.source.revision?.name == "release/v1")
        #expect(result.directory?.items.first?.path == "src/file.txt")
        #expect(result.directory?.isComplete == false)
        #expect(GitHubLinkProtocol.requests.contains { $0.url?.absoluteString.contains("release%2Fv1") == true })
    }

    @Test func ambiguousBranchTagRequiresExactChoice() async throws {
        fixture { request in
            if request.url?.path == "/repos/o/r/git/matching-refs/tags/feature" { return linkJSON([linkRef("refs/tags/feature/x")]) }
            if request.url?.path == "/repos/o/r/contents/目录/hello world.txt" { return linkFile() }; return nil
        }
        do { _ = try await linkReader().read("https://github.com/o/r/blob/feature/x/目录/hello%20world.txt", token: "t"); Issue.record("ambiguous ref was accepted") }
        catch let error as GitHubLinkError { #expect(error == .ambiguousRevision(["refs/heads/feature/x", "refs/tags/feature/x"])) }
        var options = GitHubLinkReadOptions(); options.revisionSelection = GitHubLinkRevisionSelection(kind: .tag, name: "feature/x")
        let selected = try await linkReader().read("https://github.com/o/r/blob/feature/x/目录/hello%20world.txt", token: "t", options: options)
        #expect(selected.source.revision?.kind == .tag)
    }

    @Test func commitReadsIdentityParentsAndPaginatedChanges() async throws {
        fixture { request in
            if request.url?.path.hasPrefix("/repos/o/r/commits/") == true {
                let query = request.url?.query ?? ""
                if query.contains("page=2") { return linkCommit(files: []) }
                return linkCommit(headers: query.contains("page=1") ? ["Link": "<https://api.github.com/repos/o/r/commits/\(linkHead)?per_page=50&page=2>; rel=\"next\""] : [:])
            }; return nil
        }
        var options = GitHubLinkReadOptions(); options.includePatch = true
        let result = try await linkReader().read("https://github.com/o/r/commit/" + String(linkHead.prefix(7)), token: "t", options: options)
        #expect(result.commit?.sha == linkHead)
        #expect(result.commit?.parents == [linkBase])
        #expect(result.commit?.authorName == "Alice")
        #expect(result.commit?.files?.pagesRead == 2)
        #expect(result.commit?.files?.items.first?.patch?.contains("+new") == true)
        #expect(result.commit?.files?.isComplete == true)
    }

    @Test func issueCommentAnchorValidatesMembership() async throws {
        fixture { request in request.url?.path == "/repos/o/r/issues/comments/22" ? linkJSON(issueComment()) : nil }
        let result = try await linkReader().read("https://github.com/o/r/issues/7#issuecomment-22", token: "t")
        #expect(result.issue?.labels == ["bug"])
        #expect(result.location?.selectedComment?.body == "comment")
        fixture { request in request.url?.path == "/repos/o/r/issues/comments/22" ? linkJSON(issueComment(number: 8)) : nil }
        await #expect(throws: GitHubLinkError.invalidResponse("comment source ownership")) {
            try await linkReader().read("https://github.com/o/r/issues/7#issuecomment-22", token: "t")
        }
    }

    @Test func pullDiffKeepsForkBaseAndLeftRenameCoordinates() async throws {
        fixture { _ in nil }
        let digest = SHA256.hash(data: Data("src/new.swift".utf8)).map { String(format: "%02x", $0) }.joined()
        let result = try await linkReader().read("https://github.com/o/r/pull/9/files#diff-\(digest)L1", token: "t")
        #expect(result.pullRequest?.head.repository?.fullName == "fork/r")
        #expect(result.pullRequest?.base.repository?.fullName == "o/r")
        #expect(result.location?.path == "src/old.swift")
        #expect(result.location?.commitSHA == linkBase)
        #expect(result.location?.selectedText == "old")
        #expect(result.pullRequest?.files?.isComplete == true)
    }

    @Test func outdatedReviewPreservesOriginalRevisionAndLine() async throws {
        fixture { request in
            if request.url?.path == "/repos/o/r/pulls/comments/33" {
                return linkJSON(["id": 33, "body": "old review", "html_url": "https://github.com/o/r/pull/9#discussion_r33", "pull_request_url": "https://api.github.com/repos/o/r/pulls/9",
                                 "path": "src/file.swift", "commit_id": linkBase, "original_commit_id": linkTag, "original_line": 12, "side": "RIGHT", "diff_hunk": "@@ -1 +1 @@\n+code"])
            }; return nil
        }
        let result = try await linkReader().read("https://github.com/o/r/pull/9#discussion_r33", token: "t")
        #expect(result.location?.state == .historicalReview)
        #expect(result.location?.selectedComment?.originalCommitSHA == linkTag)
        #expect(result.location?.selectedComment?.originalLine == 12)
        #expect(result.location?.commitSHA == linkTag)
    }

    @Test func pullRefreshDuringReadFailsRatherThanMixingSnapshots() async {
        fixture { request in
            if request.url?.path == "/repos/o/r/pulls/9" {
                let count = GitHubLinkProtocol.requests.filter { $0.url?.path == "/repos/o/r/pulls/9" }.count
                return pullWire(sha: count == 1 ? linkHead : linkTag)
            }; return nil
        }
        await #expect(throws: GitHubLinkError.sourceChanged) { try await linkReader().read("https://github.com/o/r/pull/9", token: "t") }
    }

    @Test func pageBudgetReturnsContinuationAndExpectedHeadGuardsAppend() async throws {
        fixture { request in
            if request.url?.path == "/repos/o/r/issues/7/comments" {
                return linkJSON([issueComment()], headers: ["Link": "<https://api.github.com/repos/o/r/issues/7/comments?per_page=50&page=2>; rel=\"next\""])
            }; return nil
        }
        var options = GitHubLinkReadOptions(); options.includeComments = true; options.maximumPages = 1
        let result = try await linkReader().read("https://github.com/o/r/issues/7", token: "t", options: options)
        #expect(result.issue?.comments?.nextPage == 2)
        #expect(result.issue?.comments?.isComplete == false)
        options.expectedPullHeadSHA = linkTag
        await #expect(throws: GitHubLinkError.sourceChanged) { try await linkReader().read("https://github.com/o/r/pull/9", token: "t", options: options) }
    }

    @Test func hostileOrCyclicPaginationNeverLeavesSource() async {
        for next in ["https://evil.test/x?per_page=50&page=2", "https://api.github.com/repos/other/r/issues/7/comments?per_page=50&page=2",
                     "https://api.github.com/repos/o/r/issues/7/comments?per_page=50&page=1", "https://api.github.com/repos/o/r/issues/7/comments?per_page=50&page=2&ref=bad"] {
            fixture { request in request.url?.path == "/repos/o/r/issues/7/comments" ? linkJSON([], headers: ["Link": "<\(next)>; rel=\"next\""]) : nil }
            var options = GitHubLinkReadOptions(); options.includeComments = true
            await #expect(throws: GitHubLinkError.unsafePagination) { try await linkReader().read("https://github.com/o/r/issues/7", token: "t", options: options) }
            #expect(GitHubLinkProtocol.requests.allSatisfy { $0.url?.host == "api.github.com" })
            #expect(GitHubLinkProtocol.requests.count == 3)
        }
    }

    @Test func largeFileIsMetadataOnlyAndTransportStopsOversizeBody() async throws {
        fixture { request in
            if request.url?.path == "/repos/o/r/contents/huge.bin" { return linkJSON(["type": "file", "path": "huge.bin", "sha": linkHead, "size": 10_000_000, "encoding": "none"]) }
            return nil
        }
        let result = try await linkReader().read("https://github.com/o/r/blob/feature/x/huge.bin", token: "t")
        #expect(result.file?.contentState == .exceedsLimit)
        #expect(result.file?.content == nil)
        #expect(!GitHubLinkProtocol.requests.contains { $0.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json" })
        GitHubLinkProtocol.prepare { _ in GitHubLinkProtocol.Reply(data: Data(repeating: 65, count: 1024)) }
        var options = GitHubLinkReadOptions(); options.maximumJSONBytes = 128
        await #expect(throws: GitHubLinkError.responseTooLarge(128)) { try await linkReader().read("https://github.com/o/r", token: "t", options: options) }
    }

    @Test func rawUsesAuthenticatedAPIAndChecksGitBlobHash() async throws {
        fixture { request in
            if request.url?.path == "/repos/o/r/contents/raw.txt" {
                if request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json" { return GitHubLinkProtocol.Reply(data: Data(linkText.utf8)) }
                return linkJSON(["type": "file", "path": "raw.txt", "sha": gitBlobSHA(Data(linkText.utf8)), "size": Data(linkText.utf8).count, "encoding": "none"])
            }; return nil
        }
        let result = try await linkReader().read("https://raw.githubusercontent.com/o/r/feature/x/raw.txt", token: "t")
        #expect(result.file?.text == linkText)
        #expect(GitHubLinkProtocol.requests.allSatisfy { $0.url?.host == "api.github.com" })
        fixture { request in
            if request.url?.path == "/repos/o/r/contents/raw.txt" { return linkJSON(["type": "file", "path": "raw.txt", "sha": linkHead, "size": 1, "encoding": "base64", "content": "YQ=="]) }; return nil
        }
        await #expect(throws: GitHubLinkError.invalidResponse("blob content SHA")) { try await linkReader().read("https://github.com/o/r/blob/feature/x/raw.txt", token: "t") }
    }

    @Test func permissionsRateLimitMovedAndNetworkHaveTypedFailures() async {
        let cases: [(Int, [String: String], GitHubLinkError)] = [
            (401, [:], .authenticationRequired), (403, [:], .forbidden), (404, [:], .notFoundOrNotAccessible),
            (429, ["Retry-After": "30"], .rateLimited(retryAfter: "30")),
            (403, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "123"], .rateLimited(retryAfter: "123")),
            (301, ["Location": "https://api.github.com/repos/new/r?token=secret"], .moved(URL(string: "https://api.github.com/repos/new/r"))),
            (302, ["Location": "https://evil.test/path?token=secret"], .moved(nil))
        ]
        for (status, headers, expected) in cases {
            GitHubLinkProtocol.prepare { _ in GitHubLinkProtocol.Reply(status: status, headers: headers, data: Data("private-token".utf8)) }
            await #expect(throws: expected) { try await linkReader().read("https://github.com/o/r", token: "private-token") }
            #expect(GitHubLinkProtocol.requests.count == 1)
        }
        GitHubLinkProtocol.prepare { _ in GitHubLinkProtocol.Reply(failure: true) }
        await #expect(throws: GitHubLinkError.transport) { try await linkReader().read("https://github.com/o/r", token: "t") }
    }

    @Test func cancellationStopsAnInFlightReadAndPreservesCancellation() async throws {
        GitHubLinkProtocol.prepare { _ in GitHubLinkProtocol.Reply(stall: true) }
        let task = Task { try await linkReader().read("https://github.com/o/r", token: "t") }
        for _ in 0..<100 where GitHubLinkProtocol.requests.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(GitHubLinkProtocol.requests.count == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(GitHubLinkProtocol.stopped > 0)
    }

    @Test func unavailableLineRangeDoesNotClaimSuccessfulLocation() async throws {
        fixture { request in request.url?.path == "/repos/o/r/contents/目录/hello world.txt" ? linkFile() : nil }
        let result = try await linkReader().read("https://github.com/o/r/blob/feature/x/目录/hello%20world.txt#L99", token: "t")
        #expect(result.location?.state == .outsideLoadedRange)
        #expect(result.location?.selectedText == nil)
        #expect(result.location?.startLine == 99)
    }

    @Test func emptyRepositoryRetainsMetadataWithoutInventingRevision() async throws {
        fixture { request in request.url?.path == "/repos/o/r/git/ref/heads/main" ? linkJSON(["message": "empty"], status: 409) : nil }
        let result = try await linkReader().read("https://github.com/o/r", token: "t")
        #expect(result.repository.id == 17)
        #expect(result.source.revision == nil)
        #expect(result.readme == nil)
        #expect(result.warnings == [.defaultRevisionUnavailable])
    }

    @Test func reviewSummaryAnchorReadsTheExactReview() async throws {
        fixture { request in
            if request.url?.path == "/repos/o/r/pulls/9/reviews/44" {
                return linkJSON(["id": 44, "body": "please change", "state": "CHANGES_REQUESTED", "html_url": "https://github.com/o/r/pull/9#pullrequestreview-44", "commit_id": linkBase])
            }; return nil
        }
        let result = try await linkReader().read("https://github.com/o/r/pull/9#pullrequestreview-44", token: "t")
        #expect(result.location?.selectedComment?.kind == "review")
        #expect(result.location?.selectedComment?.state == "CHANGES_REQUESTED")
        #expect(result.location?.commitSHA == linkBase)
    }

    @Test func historicalPullCommitChecksMembershipBeforeReadingItsDiff() async throws {
        fixture { request in
            if request.url?.path == "/repos/o/r/pulls/9/commits" { return linkJSON([["sha": linkHead]]) }
            if request.url?.path == "/repos/o/r/commits/" + linkHead { return linkCommit() }
            return nil
        }
        let result = try await linkReader().read("https://github.com/o/r/pull/9/files/" + linkHead, token: "t")
        #expect(result.source.revision?.commitSHA == linkHead)
        #expect(result.commit?.parents == [linkBase])
        #expect(!GitHubLinkProtocol.requests.contains { $0.url?.path == "/repos/o/r/pulls/9/files" })
        let foreign = String(repeating: "e", count: 40)
        await #expect(throws: GitHubLinkError.notFoundOrNotAccessible) { try await linkReader().read("https://github.com/o/r/pull/9/files/" + foreign, token: "t") }
    }

    @Test func unsafeChangedPathIsRejectedAndUnloadedDiffLineStaysExplicit() async throws {
        fixture { request in
            if request.url?.path == "/repos/o/r/pulls/9/files" {
                var value = changedFile(); value["filename"] = "../escape.swift"; return linkJSON([value])
            }; return nil
        }
        await #expect(throws: GitHubLinkError.invalidResponse("changed file identity")) { try await linkReader().read("https://github.com/o/r/pull/9", token: "t") }
        fixture { _ in nil }
        let digest = SHA256.hash(data: Data("src/new.swift".utf8)).map { String(format: "%02x", $0) }.joined()
        let result = try await linkReader().read("https://github.com/o/r/pull/9/files#diff-\(digest)R99", token: "t")
        #expect(result.location?.state == .outsideLoadedRange)
        #expect(result.location?.selectedText == nil)
    }
}
