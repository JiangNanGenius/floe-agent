import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloeGit

private final class BranchContractProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    static func start(_ value: @escaping @Sendable (URLRequest) -> (Int, Data)) { lock.withLock { responder = value; seen = [] } }
    static var requests: [URLRequest] { lock.withLock { seen } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var observed = request
        if observed.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count)); if data.count > 131_072 { break }
            }
            observed.httpBody = data
        }
        let responder = Self.lock.withLock { Self.seen.append(observed); return Self.responder }
        guard let (status, data) = responder?(observed), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func branchReply(_ value: Any, status: Int = 200) -> (Int, Data) { (status, (try? JSONSerialization.data(withJSONObject: value)) ?? Data()) }
private func branchClient() -> GitHubCollaborationClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [BranchContractProtocol.self]
    return .init(client: .init(session: URLSession(configuration: configuration)))
}
private let branchHead = String(repeating: "d", count: 40)
private let branchRepo = GitHubLinkRepositoryID(owner: "o", name: "r")
private let branchToken = "synthetic-branch-contract-token"
private func forkPull(_ body: String, repository: String = "o/renamed-fork") -> [String: Any] {
    ["id": 17, "number": 9, "title": "Fix", "body": body, "state": "open", "draft": false, "merged": false,
     "user": ["login": "alice"], "html_url": "https://github.com/o/r/pull/9", "changed_files": 1,
     "head": ["ref": "feature/docs", "sha": branchHead, "label": "o:feature/docs", "repo": ["full_name": repository]],
     "base": ["ref": "trunk", "sha": String(repeating: "e", count: 40), "label": "o:trunk", "repo": ["full_name": "o/r"]]]
}
private func branchJournal() -> URL {
    let base = ProcessInfo.processInfo.environment["FLOE_GITHUB_BRANCH_TEST_ROOT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("FloeGitBranchTests")
    return base.appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json")
}
@Suite("GitHub real branch and renamed fork contracts", .serialized)
struct GitHubCollaborationBranchTests {
    @Test("Anonymous branch pages and exact slash refs use the real default branch")
    func actualBranches() async throws {
        BranchContractProtocol.start { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            if request.url?.path == "/repos/o/r" { return branchReply(["full_name": "o/r", "default_branch": "trunk"]) }
            if request.url?.absoluteString.contains("feature%2Fdocs") == true { return branchReply(["name": "feature/docs", "commit": ["sha": branchHead]]) }
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "page", value: "2")) == true)
            return branchReply((0..<100).map { ["name": "branch-\($0)", "commit": ["sha": branchHead]] })
        }
        let client = branchClient()
        #expect(try await client.defaultBranch(branchRepo) == "trunk")
        let page = try await client.branches(branchRepo, page: 2)
        #expect(page.items.count == 100 && page.nextPage == 3)
        let actual = try await client.branch(branchRepo, name: "feature/docs")
        #expect(actual.name == "feature/docs" && actual.commit.sha == branchHead)
    }
    @Test("Malformed or moved branch metadata is an error, not guessed main or another SHA")
    func invalidMetadata() async throws {
        BranchContractProtocol.start { request in
            if request.url?.path == "/repos/o/r" { return branchReply(["full_name": "o/another", "default_branch": "main"]) }
            return branchReply(["name": "another", "commit": ["sha": "not-a-commit"]])
        }
        let client = branchClient()
        await #expect(throws: (any Error).self) { try await client.defaultBranch(branchRepo) }
        await #expect(throws: (any Error).self) { try await client.branch(branchRepo, name: "feature/docs") }
    }
    @Test("Renamed same-organization fork is bound through real preflight, wire head_repo and independent readback")
    func renamedFork() async throws {
        let owner = UUID(), prepared = try GitHubPreparedMutation.pull(ownerTaskID: owner, repository: branchRepo,
            title: "Fix", body: "Body", head: "o:feature/docs", base: "trunk", headSHA: branchHead, headRepository: "renamed-fork")
        let body = try #require((JSONSerialization.jsonObject(with: prepared.payload) as? [String: Any])?["body"] as? String)
        BranchContractProtocol.start { request in
            if request.url?.path == "/user" { return branchReply(["login": "alice"]) }
            if request.url?.absoluteString.contains("/repos/o/renamed-fork/commits/feature%2Fdocs") == true { return branchReply(["sha": branchHead]) }
            if request.httpMethod == "POST" {
                let json = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                #expect(json?["head_repo"] as? String == "renamed-fork")
                #expect(json?["head"] as? String == "o:feature/docs")
                return branchReply(forkPull(body), status: 201)
            }
            return branchReply(forkPull(body))
        }
        let service = try GitHubCollaborationService(client: branchClient(), journalURL: branchJournal())
        try await service.prepare(prepared, ownerTaskID: owner)
        let result = try await service.execute(id: prepared.id, ownerTaskID: owner, token: branchToken)
        #expect(result.url.absoluteString == "https://github.com/o/r/pull/9")
        #expect(await service.recent(ownerTaskID: owner).first?.state == .acknowledged)
        #expect(BranchContractProtocol.requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(BranchContractProtocol.requests.contains { $0.url?.path == "/repos/o/r/pulls/9" && $0.httpMethod == "GET" })
    }
    @Test("A wrong returned fork stays unknown and the same native operation cannot repeat POST")
    func wrongForkUnknown() async throws {
        let owner = UUID(), prepared = try GitHubPreparedMutation.pull(ownerTaskID: owner, repository: branchRepo,
            title: "Fix", body: "Body", head: "o:feature/docs", base: "trunk", headSHA: branchHead, headRepository: "renamed-fork")
        let body = try #require((JSONSerialization.jsonObject(with: prepared.payload) as? [String: Any])?["body"] as? String)
        BranchContractProtocol.start { request in
            if request.url?.path == "/user" { return branchReply(["login": "alice"]) }
            if request.httpMethod == "POST" { return branchReply(forkPull(body, repository: "o/wrong"), status: 201) }
            return branchReply(["sha": branchHead])
        }
        let service = try GitHubCollaborationService(client: branchClient(), journalURL: branchJournal())
        try await service.prepare(prepared, ownerTaskID: owner)
        await #expect(throws: GitHubCollaborationError.outcomeUnknown(prepared.id)) { try await service.execute(id: prepared.id, ownerTaskID: owner, token: branchToken) }
        await #expect(throws: GitHubCollaborationError.outcomeUnknown(prepared.id)) { try await service.execute(id: prepared.id, ownerTaskID: owner, token: branchToken) }
        #expect(await service.recent(ownerTaskID: owner).first?.state == .unknown)
        #expect(BranchContractProtocol.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }
}
