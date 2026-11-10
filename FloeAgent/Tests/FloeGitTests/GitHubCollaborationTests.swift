import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloeGit

private final class CollaborationProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status = 200; var data = Data(); var headers = [String: String](); var fail = false; var stall = false }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Reply)?
    nonisolated(unsafe) private static var seen = [URLRequest]()
    static func prepare(_ value: @escaping @Sendable (URLRequest) -> Reply) { lock.withLock { handler = value; seen = [] } }
    static var requests: [URLRequest] { lock.withLock { seen } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // URLSession may expose an outgoing body as a stream to URLProtocol.
        // Capture that actual wire body; an absent httpBody is not proof that
        // the production request sent an empty payload.
        var observed = request
        if observed.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(), chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&chunk, maxLength: chunk.count)
                guard count > 0 else { break }; bytes.append(contentsOf: chunk.prefix(count))
                if bytes.count > 131_072 { Issue.record("Fixture request exceeds production body limit"); break }
            }
            observed.httpBody = bytes
        }
        let respond = Self.lock.withLock { Self.seen.append(observed); return Self.handler }
        guard let reply = respond?(observed) else { return }
        if reply.stall { return }
        if reply.fail { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private let collaborationHead = String(repeating: "a", count: 40)
private let collaborationOther = String(repeating: "b", count: 40)
private let collaborationRepo = GitHubLinkRepositoryID(owner: "o", name: "r")
private let collaborationToken = "synthetic-fixture-token-never-persisted"
private func reply(_ object: Any, status: Int = 200) -> CollaborationProtocol.Reply {
    .init(status: status, data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
}
private func issueObject(body: String = "body", state: String = "open") -> [String: Any] {
    ["id": 101, "number": 7, "title": "Fix", "body": body, "state": state, "user": ["login": "alice"], "html_url": "https://github.com/o/r/issues/7", "updated_at": "2026-11-10T00:00:00Z"]
}
private func pullObject(body: String = "body", sha: String = collaborationHead, merged: Bool = false) -> [String: Any] {
    ["id": 109, "number": 9, "title": "Fix", "body": body, "state": merged ? "closed" : "open", "draft": false, "merged": merged, "user": ["login": "alice"], "html_url": "https://github.com/o/r/pull/9", "changed_files": 1,
     "head": ["ref": "feature", "sha": sha, "label": "fork:feature", "repo": ["full_name": "fork/r"]], "base": ["ref": "main", "sha": collaborationOther, "label": "o:main", "repo": ["full_name": "o/r"]]]
}
private func commentObject(body: String, review: Bool = false) -> [String: Any] {
    ["id": 22, "body": body, "user": ["login": "alice"], "html_url": review ? "https://github.com/o/r/pull/9#pullrequestreview-22" : "https://github.com/o/r/issues/7#issuecomment-22", "commit_id": collaborationHead, "state": "APPROVED"]
}
private func collaborationClient() -> GitHubCollaborationClient {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CollaborationProtocol.self]
    return .init(client: .init(session: URLSession(configuration: config)))
}
private func payloadBody(_ prepared: GitHubPreparedMutation) throws -> String {
    try #require((JSONSerialization.jsonObject(with: prepared.payload) as? [String: Any])?["body"] as? String)
}
private func journal() throws -> URL {
    let root = ProcessInfo.processInfo.environment["FLOE_GITHUB_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("FloeGitCollaborationTests", isDirectory: true)
    return root.appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json")
}
private func service(_ path: URL? = nil) throws -> GitHubCollaborationService { try .init(client: collaborationClient(), journalURL: path ?? journal()) }
private func waitForRequest(_ predicate: (URLRequest) -> Bool) async throws {
    for _ in 0..<500 {
        if CollaborationProtocol.requests.contains(where: predicate) { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Controlled request did not reach its expected boundary")
}
private final class CollaborationAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.withLock { stopped = true } }
    func authorize() throws { if lock.withLock({ stopped }) { throw CancellationError() } }
}

@Suite("GitHub collaboration actual contracts and durable delivery", .serialized)
struct GitHubCollaborationTests {
    @Test("Cancellation/authority is rechecked after preflight and before the first POST")
    func authorityBeforePost() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.reply(ownerTaskID: owner, repository: collaborationRepo, number: 7, body: "Reply"), authority = CollaborationAuthority()
        CollaborationProtocol.prepare { _ in authority.cancel(); return reply(["login": "alice"]) }
        try await store.prepare(prepared, ownerTaskID: owner)
        await #expect(throws: CancellationError.self) { try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken, authorize: { try authority.authorize() }) }
        #expect(!CollaborationProtocol.requests.contains { $0.httpMethod == "POST" })
        #expect(await store.recent(ownerTaskID: owner).first?.state == .prepared)
    }
    @Test("The existing GitHub service supplies its exact configured session")
    func existingSessionFactory() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CollaborationProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = GitHubService(session: session)
        #expect(service.collaborationClient().client.session === session)
    }
    @Test("Public reads keep pagination and omit credentials")
    func publicRead() async throws {
        CollaborationProtocol.prepare { _ in reply([issueObject()]) }
        let result = try await collaborationClient().issues(collaborationRepo)
        #expect(result.items.count == 1 && result.nextPage == nil)
        let request = try #require(CollaborationProtocol.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.url?.query?.contains("per_page=100") == true)
    }
    @Test("Oversized source responses are refused instead of decoded as empty")
    func boundedRead() async throws {
        CollaborationProtocol.prepare { _ in .init(headers: ["Content-Length": "4194305"]) }
        await #expect(throws: GitHubLinkError.responseTooLarge(4_194_304)) { try await collaborationClient().issues(collaborationRepo) }
    }
    @Test("Line ranges resolve only in one actual current diff hunk")
    func diffPositions() throws {
        let data = try JSONSerialization.data(withJSONObject: ["sha": collaborationHead, "filename": "a.swift", "status": "modified", "additions": 2, "deletions": 1, "patch": "@@ -1,2 +1,2 @@\n-old\n+new\n same\n@@ -10 +10 @@\n+last"])
        let file = try JSONDecoder().decode(GitHubCollaborationFile.self, from: data)
        try GitHubReviewLine(path: "a.swift", side: .right, line: 2, startLine: 1).validate(in: [file])
        try GitHubReviewLine(path: "a.swift", side: .left, line: 1).validate(in: [file])
        #expect(throws: GitHubCollaborationError.invalidLine) { try GitHubReviewLine(path: "a.swift", side: .right, line: 10, startLine: 1).validate(in: [file]) }
        #expect(throws: GitHubCollaborationError.invalidLine) { try GitHubReviewLine(path: "a.swift", side: .left, line: 2).validate(in: [file]) }
    }
    @Test("Changed PR head blocks a line review before any POST")
    func changedHead() async throws {
        CollaborationProtocol.prepare { request in request.url?.path == "/user" ? reply(["login": "alice"]) : reply(pullObject(sha: collaborationOther)) }
        let owner = UUID(), store = try service()
        let request = try GitHubPreparedMutation.lineComment(ownerTaskID: owner, repository: collaborationRepo, number: 9, headSHA: collaborationHead, line: .init(path: "a.swift", side: .right, line: 1), body: "Change this")
        try await store.prepare(request, ownerTaskID: owner)
        await #expect(throws: GitHubCollaborationError.changedHead(expected: collaborationHead, actual: collaborationOther)) { try await store.execute(id: request.id, ownerTaskID: owner, token: collaborationToken) }
        #expect(!CollaborationProtocol.requests.contains { $0.httpMethod == "POST" })
    }
    @Test("A successful issue is independently read back and cannot be sent twice or after reopen")
    func successfulIssue() async throws {
        let owner = UUID(), path = try journal(), store = try service(path)
        let prepared = try GitHubPreparedMutation.issue(ownerTaskID: owner, repository: collaborationRepo, title: "Fix", body: "Description")
        let body = try payloadBody(prepared)
        CollaborationProtocol.prepare { request in request.url?.path == "/user" ? reply(["login": "alice"]) : reply(issueObject(body: body), status: request.httpMethod == "POST" ? 201 : 200) }
        try await store.prepare(prepared, ownerTaskID: owner)
        let result = try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken)
        #expect(result.remoteID == 101 && result.url.absoluteString == "https://github.com/o/r/issues/7")
        _ = try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken)
        let reopened = try service(path); _ = try await reopened.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken)
        #expect(CollaborationProtocol.requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(CollaborationProtocol.requests.contains { $0.httpMethod == "GET" && $0.url?.path == "/repos/o/r/issues/7" })
        #expect(!String(decoding: try Data(contentsOf: path), as: UTF8.self).contains(collaborationToken))
    }
    @Test("Lost reply response reconciles the same actor/body/nonce without a second POST")
    func unknownReply() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.reply(ownerTaskID: owner, repository: collaborationRepo, number: 7, body: "Reply")
        let body = try payloadBody(prepared)
        CollaborationProtocol.prepare { request in
            if request.httpMethod == "POST" { return .init(fail: true) }
            return request.url?.path == "/user" ? reply(["login": "alice"]) : reply([commentObject(body: body)])
        }
        try await store.prepare(prepared, ownerTaskID: owner)
        await #expect(throws: GitHubCollaborationError.outcomeUnknown(prepared.id)) { try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken) }
        await #expect(throws: GitHubCollaborationError.outcomeUnknown(prepared.id)) { try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken) }
        let record = try await store.reconcile(id: prepared.id, ownerTaskID: owner, token: collaborationToken)
        #expect(record.state == .acknowledged && record.result?.confirmation == .observed)
        #expect(CollaborationProtocol.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }
    @Test("An absent or different author's reply remains uncertain, never an automatic retry")
    func noFalseReconciliation() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.reply(ownerTaskID: owner, repository: collaborationRepo, number: 7, body: "Reply")
        CollaborationProtocol.prepare { request in
            if request.httpMethod == "POST" { return .init(fail: true) }
            return request.url?.path == "/user" ? reply(["login": "alice"]) : reply([])
        }
        try await store.prepare(prepared, ownerTaskID: owner)
        await #expect(throws: GitHubCollaborationError.outcomeUnknown(prepared.id)) { try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken) }
        let record = try await store.reconcile(id: prepared.id, ownerTaskID: owner, token: collaborationToken)
        #expect(record.state == .unknown)
        #expect(CollaborationProtocol.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }
    @Test("Concurrent caller admission precedes the first network await")
    func concurrentAdmission() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.reply(ownerTaskID: owner, repository: collaborationRepo, number: 7, body: "Reply")
        CollaborationProtocol.prepare { _ in .init(stall: true) }; try await store.prepare(prepared, ownerTaskID: owner)
        let first = Task { try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken) }
        try await waitForRequest { $0.url?.path == "/user" }
        await #expect(throws: GitHubCollaborationError.outcomeUnknown(prepared.id)) { try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken) }
        first.cancel(); _ = await first.result
        #expect(!CollaborationProtocol.requests.contains { $0.httpMethod == "POST" })
        #expect(await store.recent(ownerTaskID: owner).first?.state == .prepared)
    }
    @Test("Cancellation after POST is durable uncertainty; reopening does not resend")
    func cancellationAfterSending() async throws {
        let owner = UUID(), path = try journal(), store = try service(path), prepared = try GitHubPreparedMutation.reply(ownerTaskID: owner, repository: collaborationRepo, number: 7, body: "Reply")
        CollaborationProtocol.prepare { $0.httpMethod == "POST" ? .init(stall: true) : reply(["login": "alice"]) }
        try await store.prepare(prepared, ownerTaskID: owner)
        let task = Task { try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken) }
        try await waitForRequest { $0.httpMethod == "POST" }; task.cancel()
        await #expect(throws: GitHubCollaborationError.outcomeUnknown(prepared.id)) { try await task.value }
        let reopened = try service(path)
        await #expect(throws: GitHubCollaborationError.outcomeUnknown(prepared.id)) { try await reopened.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken) }
        #expect(CollaborationProtocol.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }
    @Test("Task ownership and forged endpoint/method are refused locally")
    func ownerAndContract() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.reply(ownerTaskID: owner, repository: collaborationRepo, number: 7, body: "Reply")
        await #expect(throws: GitHubCollaborationError.operationMismatch) { try await store.prepare(prepared, ownerTaskID: UUID()) }
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared)) as? [String: Any]); json["endpoint"] = ["git", "refs"]
        let forged = try JSONDecoder().decode(GitHubPreparedMutation.self, from: JSONSerialization.data(withJSONObject: json))
        await #expect(throws: GitHubCollaborationError.operationMismatch) { try await store.prepare(forged, ownerTaskID: owner) }
    }
    @Test("Merge includes server CAS sha and independently reads actual merged state")
    func mergeReadback() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.merge(ownerTaskID: owner, repository: collaborationRepo, number: 9, headSHA: collaborationHead, method: .squash)
        CollaborationProtocol.prepare { request in
            if request.url?.path == "/user" { return reply(["login": "alice"]) }
            if request.httpMethod == "PUT" { return reply(["merged": true, "sha": collaborationOther]) }
            return reply(pullObject(merged: CollaborationProtocol.requests.contains { $0.httpMethod == "PUT" }))
        }
        try await store.prepare(prepared, ownerTaskID: owner)
        _ = try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken)
        let put = try #require(CollaborationProtocol.requests.first { $0.httpMethod == "PUT" })
        let payload = try #require(JSONSerialization.jsonObject(with: put.httpBody ?? Data()) as? [String: Any])
        #expect(payload["sha"] as? String == collaborationHead && payload["merge_method"] as? String == "squash")
    }
    @Test("Rerun uses the original run and verifies its increased real attempt; no dispatch")
    func originalRunRerun() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.rerun(ownerTaskID: owner, repository: collaborationRepo, runID: 88, attempt: 2, headSHA: collaborationHead, failedOnly: true)
        CollaborationProtocol.prepare { request in
            if request.url?.path == "/user" { return reply(["login": "alice"]) }
            if request.httpMethod == "POST" { return .init(status: 201) }
            let sent = CollaborationProtocol.requests.contains { $0.httpMethod == "POST" }
            return reply(["id": 88, "run_attempt": sent ? 3 : 2, "head_sha": collaborationHead, "status": sent ? "queued" : "completed"])
        }
        try await store.prepare(prepared, ownerTaskID: owner)
        let result = try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken)
        #expect(result.remoteID == 88)
        #expect(CollaborationProtocol.requests.filter { $0.httpMethod == "POST" }.map { $0.url?.path } == ["/repos/o/r/actions/runs/88/rerun-failed-jobs"])
        #expect(!CollaborationProtocol.requests.contains { $0.url?.path.contains("dispatch") == true })
    }
    @Test("Issue state change is separately read back")
    func closeIssue() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.issueState(ownerTaskID: owner, repository: collaborationRepo, number: 7, closed: true)
        CollaborationProtocol.prepare { request in
            if request.url?.path == "/user" { return reply(["login": "alice"]) }
            return reply(issueObject(state: CollaborationProtocol.requests.contains { $0.httpMethod == "PATCH" } ? "closed" : "open"))
        }
        try await store.prepare(prepared, ownerTaskID: owner)
        _ = try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken)
        #expect(CollaborationProtocol.requests.filter { $0.httpMethod == "PATCH" }.count == 1)
    }
    @Test("Fork PR binds the actual selected head before POST and after creation")
    func createForkPull() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.pull(ownerTaskID: owner, repository: collaborationRepo, title: "Fix", body: "From issue7", head: "fork:feature", base: "main", headSHA: collaborationHead)
        let body = try payloadBody(prepared)
        CollaborationProtocol.prepare { request in
            if request.url?.path == "/user" { return reply(["login": "alice"]) }
            if request.url?.path == "/repos/fork/r/commits/feature" { return reply(["sha": collaborationHead]) }
            return reply(pullObject(body: body), status: request.httpMethod == "POST" ? 201 : 200)
        }
        try await store.prepare(prepared, ownerTaskID: owner)
        let result = try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken)
        #expect(result.commitSHA == collaborationHead && result.url.absoluteString == "https://github.com/o/r/pull/9")
    }
    @Test("Line-comment wire carries its exact commit/path/side and independently verifies the anchor")
    func lineCommentReadback() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.lineComment(ownerTaskID: owner, repository: collaborationRepo, number: 9, headSHA: collaborationHead, line: .init(path: "a.swift", side: .right, line: 1), body: "Please adjust")
        let body = try payloadBody(prepared)
        CollaborationProtocol.prepare { request in
            if request.url?.path == "/user" { return reply(["login": "alice"]) }
            if request.url?.path == "/repos/o/r/pulls/9" { return reply(pullObject()) }
            if request.url?.path == "/repos/o/r/pulls/9/files" { return reply([["sha": collaborationHead, "filename": "a.swift", "status": "modified", "additions": 1, "deletions": 1, "patch": "@@ -1 +1 @@\n-old\n+new"]]) }
            var object = commentObject(body: body); object["html_url"] = "https://github.com/o/r/pull/9#discussion_r22"; object["path"] = "a.swift"; object["line"] = 1; object["side"] = "RIGHT"
            return reply(object, status: request.httpMethod == "POST" ? 201 : 200)
        }
        try await store.prepare(prepared, ownerTaskID: owner)
        _ = try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken)
        let post = try #require(CollaborationProtocol.requests.first { $0.httpMethod == "POST" })
        let object = try #require(JSONSerialization.jsonObject(with: post.httpBody ?? Data()) as? [String: Any])
        #expect(object["commit_id"] as? String == collaborationHead && object["path"] as? String == "a.swift")
        #expect(object["side"] as? String == "RIGHT" && object["line"] as? Int == 1)
    }
    @Test("Approve permits an empty user message and confirms the actual review conclusion")
    func reviewReadback() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.review(ownerTaskID: owner, repository: collaborationRepo, number: 9, headSHA: collaborationHead, event: .approve, body: "")
        let body = try payloadBody(prepared)
        CollaborationProtocol.prepare { request in
            if request.url?.path == "/user" { return reply(["login": "alice"]) }
            if request.url?.path == "/repos/o/r/pulls/9" { return reply(pullObject()) }
            return reply(commentObject(body: body, review: true), status: request.httpMethod == "POST" ? 200 : 200)
        }
        try await store.prepare(prepared, ownerTaskID: owner)
        let result = try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken)
        #expect(result.remoteID == 22)
    }
    @Test("An incorrect server review conclusion is uncertainty rather than an approval claim")
    func reviewStateMismatch() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.review(ownerTaskID: owner, repository: collaborationRepo, number: 9, headSHA: collaborationHead, event: .requestChanges, body: "Needs adjustment")
        let body = try payloadBody(prepared)
        CollaborationProtocol.prepare { request in
            if request.url?.path == "/user" { return reply(["login": "alice"]) }
            if request.url?.path == "/repos/o/r/pulls/9" { return reply(pullObject()) }
            return reply(commentObject(body: body, review: true))
        }
        try await store.prepare(prepared, ownerTaskID: owner)
        await #expect(throws: GitHubCollaborationError.outcomeUnknown(prepared.id)) { try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken) }
        #expect(await store.recent(ownerTaskID: owner).first?.state == .unknown)
    }
    @Test("Changed Actions attempt cannot accidentally cancel or rerun a successor")
    func changedRun() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.cancelRun(ownerTaskID: owner, repository: collaborationRepo, runID: 88, attempt: 2, headSHA: collaborationHead)
        CollaborationProtocol.prepare { request in request.url?.path == "/user" ? reply(["login": "alice"]) : reply(["id": 88, "run_attempt": 3, "head_sha": collaborationHead, "status": "in_progress"]) }
        try await store.prepare(prepared, ownerTaskID: owner)
        await #expect(throws: GitHubCollaborationError.operationMismatch) { try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken) }
        #expect(!CollaborationProtocol.requests.contains { $0.httpMethod == "POST" })
    }
    @Test("Cancel targets only the original run and reads its actual cancelled conclusion")
    func cancelOriginalRun() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.cancelRun(ownerTaskID: owner, repository: collaborationRepo, runID: 88, attempt: 2, headSHA: collaborationHead)
        CollaborationProtocol.prepare { request in
            if request.url?.path == "/user" { return reply(["login": "alice"]) }
            if request.httpMethod == "POST" { return .init(status: 202) }
            let sent = CollaborationProtocol.requests.contains { $0.httpMethod == "POST" }
            var value: [String: Any] = ["id": 88, "run_attempt": 2, "head_sha": collaborationHead, "status": sent ? "completed" : "in_progress"]
            if sent { value["conclusion"] = "cancelled" }; return reply(value)
        }
        try await store.prepare(prepared, ownerTaskID: owner)
        let result = try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken)
        #expect(result.remoteID == 88)
        #expect(CollaborationProtocol.requests.filter { $0.httpMethod == "POST" }.map { $0.url?.path } == ["/repos/o/r/actions/runs/88/cancel"])
    }
    @Test("Permission rejection retains its draft and cannot be confused with unknown delivery")
    func rejectedPermissions() async throws {
        let owner = UUID(), store = try service(), prepared = try GitHubPreparedMutation.reply(ownerTaskID: owner, repository: collaborationRepo, number: 7, body: "Keep this input")
        CollaborationProtocol.prepare { $0.httpMethod == "POST" ? reply(["message": "Forbidden"], status: 403) : reply(["login": "alice"]) }
        try await store.prepare(prepared, ownerTaskID: owner)
        for _ in 0..<2 {
            await #expect(throws: GitHubCollaborationError.rejected(403)) { try await store.execute(id: prepared.id, ownerTaskID: owner, token: collaborationToken) }
        }
        let record = try #require(await store.recent(ownerTaskID: owner).first)
        #expect(record.state == .rejected && record.request == prepared)
        #expect(CollaborationProtocol.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }
}
