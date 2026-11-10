import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeGit

private final class CollaborationToolProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status = 200; var data = Data(); var fail = false }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Reply)?
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    static func start(_ action: @escaping @Sendable (URLRequest) -> Reply) { lock.withLock { handler = action; seen = [] } }
    static var requests: [URLRequest] { lock.withLock { seen } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var observed = request
        if observed.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count)); if bytes.count > 131_072 { break }
            }
            observed.httpBody = bytes
        }
        let action = Self.lock.withLock { Self.seen.append(observed); return Self.handler }
        guard let reply = action?(observed) else { return }
        if reply.fail { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: reply.data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func toolJSON(_ value: Any, status: Int = 200) -> CollaborationToolProtocol.Reply {
    .init(status: status, data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data())
}
private struct GitToolFixture: Sendable {
    let client: GitHubCollaborationClient
    let service: GitHubCollaborationService
    let environment: GitHubCollaborationToolEnvironment
    let journal: URL
    init() throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CollaborationToolProtocol.self]
        let client = GitHubCollaborationClient(client: .init(session: URLSession(configuration: config)))
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent("FloeCollaborationToolTests").appendingPathComponent(UUID().uuidString).appendingPathComponent("journal.json")
        let service = try GitHubCollaborationService(client: client, journalURL: journal)
        self.client = client; self.service = service; self.journal = journal
        self.environment = .init(service: service, client: client, tokenProvider: { "synthetic-tool-fixture-token" })
    }
}
private func createIssueArgs() throws -> GitHubIssueCreateTool.Arguments {
    try JSONDecoder().decode(GitHubIssueCreateTool.Arguments.self, from: Data(#"{"repositoryURL":"https://github.com/o/r","title":"Fix","body":"Details"}"#.utf8))
}
private func testIssue(_ body: String) -> [String: Any] { ["id": 71, "number": 7, "title": "Fix", "body": body, "state": "open", "updated_at": "2026-11-10T00:00:00Z", "user": ["login": "alice"], "html_url": "https://github.com/o/r/issues/7"] }
private final class ToolBodyCapture: @unchecked Sendable {
    private let lock = NSLock(); private var value = ""
    func set(_ text: String) { lock.withLock { value = text } }
    var body: String { lock.withLock { value } }
}
@Suite("Native GitHub model tools use the actual durable service", .serialized)
struct NextRoundGitCollaborationToolTests {
    @Test("Same runtime call identity returns its actual acknowledged issue without a second POST")
    func acknowledgedRetry() async throws {
        let f = try GitToolFixture(), body = ToolBodyCapture(), taskID = UUID()
        CollaborationToolProtocol.start { request in
            if request.url?.path == "/user" { return toolJSON(["login": "alice"]) }
            if request.httpMethod == "POST" {
                let object = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                body.set(object?["body"] as? String ?? "")
                return toolJSON(testIssue(body.body), status: 201)
            }
            return toolJSON(testIssue(body.body))
        }
        let context = ToolContext(runID: UUID(), toolCallID: "native-call-1", cancellation: CancellationToken(), conversationID: taskID)
        let tool = GitHubIssueCreateTool(environment: f.environment), args = try createIssueArgs()
        let first = try await tool.execute(args, context: context), second = try await tool.execute(args, context: context)
        #expect(!first.outcomeUnknown && !second.outcomeUnknown)
        #expect(first.summary == second.summary)
        #expect(try JSONSerialization.jsonObject(with: Data(first.summary.utf8)) as? [String: Any] != nil)
        #expect(CollaborationToolProtocol.requests.filter { $0.httpMethod == "POST" }.count == 1)
        #expect(await f.service.recent(ownerTaskID: taskID).first?.state == .acknowledged)
    }
    @Test("Lost POST outcome carries native unknown flag, retains one ID and refuses another owner")
    func unknownReplayAndOwner() async throws {
        let f = try GitToolFixture(), owner = UUID()
        CollaborationToolProtocol.start { request in request.httpMethod == "POST" ? .init(fail: true) : toolJSON(["login": "alice"]) }
        let context = ToolContext(runID: UUID(), toolCallID: "native-call-2", cancellation: CancellationToken(), conversationID: owner)
        let tool = GitHubIssueCreateTool(environment: f.environment), args = try createIssueArgs()
        let first = try await tool.execute(args, context: context)
        #expect(first.outcomeUnknown)
        let value = try #require(JSONSerialization.jsonObject(with: Data(first.summary.utf8)) as? [String: Any])
        let operation = try #require((value["operationID"] as? String).flatMap(UUID.init(uuidString:)))
        let repeatResult = try await tool.execute(args, context: context)
        #expect(repeatResult.outcomeUnknown)
        #expect(CollaborationToolProtocol.requests.filter { $0.httpMethod == "POST" }.count == 1)
        let wrong = ToolContext(runID: UUID(), toolCallID: "another-owner", cancellation: CancellationToken(), conversationID: UUID())
        let reconcile = GitHubOperationReconcileTool(environment: f.environment)
        let params = try JSONDecoder().decode(GitHubOperationReconcileTool.Arguments.self, from: JSONEncoder().encode(["operationID": operation.uuidString]))
        await #expect(throws: GitHubCollaborationError.operationMismatch) { try await reconcile.execute(params, context: wrong) }
        #expect(CollaborationToolProtocol.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }
    @Test("Temporary read-only contexts cannot prepare mutations or reconcile saved private operations")
    func temporaryDenied() async throws {
        let f = try GitToolFixture(), context = ToolContext(runID: UUID(), toolCallID: "temporary", cancellation: CancellationToken(), temporaryReadOnly: true)
        CollaborationToolProtocol.start { _ in Issue.record("Temporary mutation must not reach HTTP"); return toolJSON([:]) }
        await #expect(throws: FloeError.unauthorized) { try await GitHubIssueCreateTool(environment: f.environment).execute(createIssueArgs(), context: context) }
        let params = try JSONDecoder().decode(GitHubOperationReconcileTool.Arguments.self, from: JSONEncoder().encode(["operationID": UUID().uuidString]))
        await #expect(throws: FloeError.unauthorized) { try await GitHubOperationReconcileTool(environment: f.environment).execute(params, context: context) }
        #expect(!FileManager.default.fileExists(atPath: f.journal.path))
        #expect(CollaborationToolProtocol.requests.isEmpty)
    }
    @Test("Cancellation from real preflight prevents POST and retains a prepared draft")
    func cancellationBeforeSend() async throws {
        let f = try GitToolFixture(), cancellation = CancellationToken(), owner = UUID()
        CollaborationToolProtocol.start { _ in cancellation.cancel(); return toolJSON(["login": "alice"]) }
        let context = ToolContext(runID: UUID(), toolCallID: "cancel-preflight", cancellation: cancellation, conversationID: owner)
        await #expect(throws: (any Error).self) { try await GitHubIssueCreateTool(environment: f.environment).execute(createIssueArgs(), context: context) }
        #expect(!CollaborationToolProtocol.requests.contains { $0.httpMethod == "POST" })
        #expect(await f.service.recent(ownerTaskID: owner).first?.state == .prepared)
    }
    @Test("Runtime identities are stable within a call and isolated across run, owner and tool")
    func runtimeIdentity() throws {
        let run = UUID(), owner = UUID()
        let context = ToolContext(runID: run, toolCallID: "same", toolIdempotencyKey: "runtime-issued", cancellation: CancellationToken(), conversationID: owner)
        let first = try GitHubCollaborationToolEnvironment.operationID(context, tool: GitHubIssueCreateTool.name)
        #expect(try GitHubCollaborationToolEnvironment.operationID(context, tool: GitHubIssueCreateTool.name) == first)
        #expect(try GitHubCollaborationToolEnvironment.operationID(context, tool: GitHubPullCreateTool.name) != first)
        let other = ToolContext(runID: UUID(), toolCallID: "same", toolIdempotencyKey: "runtime-issued", cancellation: CancellationToken(), conversationID: owner)
        #expect(try GitHubCollaborationToolEnvironment.operationID(other, tool: GitHubIssueCreateTool.name) != first)
    }
}
