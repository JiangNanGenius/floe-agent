import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloeGit

private final class AttemptProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Data)?
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    static func start(_ value: @escaping @Sendable (URLRequest) -> Data) { lock.withLock { handler = value; seen = [] } }
    static var requests: [URLRequest] { lock.withLock { seen } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let action = Self.lock.withLock { Self.seen.append(request); return Self.handler }
        guard let data = action?(request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func attemptData(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data() }
private let attemptSHA = String(repeating: "a", count: 40)
private let attemptRepo = GitHubLinkRepositoryID(owner: "o", name: "r")
private func attemptFixtureClient() -> GitHubCollaborationClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AttemptProtocol.self]
    return .init(client: .init(session: URLSession(configuration: configuration)))
}
private func attemptMetadata(_ number: Int = 2) -> [String: Any] { ["id": 8, "run_attempt": number, "head_sha": attemptSHA, "status": "completed", "conclusion": "failure"] }
private func attemptJobs(_ job: Int64 = 11, runID: Int64 = 8) -> [String: Any] { ["total_count": 201, "jobs": [["id": job, "run_id": runID, "head_sha": attemptSHA, "name": "Build", "status": "completed", "conclusion": "failure"]]] }
@Suite("Original GitHub Actions attempt identity and bounded logs", .serialized)
struct GitHubActionsAttemptTests {
    @Test("Anonymous original attempt and actual jobs page precede bounded log read")
    func exactAttemptLog() async throws {
        AttemptProtocol.start { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let path = request.url?.path ?? ""
            if path.hasSuffix("/logs") { return Data(String(repeating: "actual log\n", count: 100).utf8) }
            if path.hasSuffix("/jobs") {
                #expect(path == "/repos/o/r/actions/runs/8/attempts/2/jobs")
                #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "page", value: "3")) == true)
                return attemptData(attemptJobs())
            }
            #expect(path == "/repos/o/r/actions/runs/8/attempts/2")
            return attemptData(attemptMetadata())
        }
        let log = try await attemptFixtureClient().attemptJobLog(attemptRepo, runID: 8, attempt: 2, headSHA: attemptSHA, jobID: 11, jobsPage: 3, maximumBytes: 24, token: "")
        #expect(log.truncated && log.byteCount == 24 && log.text.hasPrefix("actual log\n"))
        #expect(AttemptProtocol.requests.count == 3)
    }
    @Test("A job from a different run or a different page cannot reach the log endpoint")
    func wrongJobRefused() async throws {
        AttemptProtocol.start { request in request.url?.path.hasSuffix("/jobs") == true ? attemptData(attemptJobs(11, runID: 9)) : attemptData(attemptMetadata()) }
        await #expect(throws: (any Error).self) { try await attemptFixtureClient().attemptJobLog(attemptRepo, runID: 8, attempt: 2, headSHA: attemptSHA, jobID: 11, jobsPage: 1, token: "") }
        #expect(!AttemptProtocol.requests.contains { $0.url?.path.hasSuffix("/logs") == true })
        AttemptProtocol.start { request in request.url?.path.hasSuffix("/jobs") == true ? attemptData(attemptJobs(999)) : attemptData(attemptMetadata()) }
        await #expect(throws: (any Error).self) { try await attemptFixtureClient().attemptJobLog(attemptRepo, runID: 8, attempt: 2, headSHA: attemptSHA, jobID: 11, jobsPage: 1, token: "") }
        #expect(!AttemptProtocol.requests.contains { $0.url?.path.hasSuffix("/logs") == true })
    }
    @Test("A wrong returned attempt refuses without silently following the latest run")
    func attemptMismatch() async throws {
        AttemptProtocol.start { _ in attemptData(attemptMetadata(3)) }
        await #expect(throws: (any Error).self) { try await attemptFixtureClient().attemptJobLog(attemptRepo, runID: 8, attempt: 2, headSHA: attemptSHA, jobID: 11, jobsPage: 1, token: "") }
        #expect(AttemptProtocol.requests.count == 1)
    }
}
