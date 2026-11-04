#if canImport(UIKit) && DEBUG
import Foundation
import Testing
@testable import FloeApp

private final class SkillHTTPFixture: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable, Equatable { case exact, declaredOversize, chunkOversize, suspended }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Mode = .exact
        func set(_ value: Mode) { lock.lock(); self.value = value; lock.unlock() }
        func get() -> Mode { lock.lock(); defer { lock.unlock() }; return value }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "skill-transport.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.state.get()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: mode == .declaredOversize ? ["Content-Length": "2048"] : [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if mode == .suspended { return }
        if mode == .exact {
            for _ in 0..<8 { client?.urlProtocol(self, didLoad: Data(repeating: 0x5a, count: 128)) }
        } else if mode == .chunkOversize {
            client?.urlProtocol(self, didLoad: Data(repeating: 0x5a, count: 768))
            client?.urlProtocol(self, didLoad: Data(repeating: 0x5a, count: 768))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("FloeApp.SkillGitHubDownload", .serialized)
struct SkillGitHubDownloadTests {
    private func request(_ mode: SkillHTTPFixture.Mode) async throws -> Data {
        SkillHTTPFixture.state.set(mode)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SkillHTTPFixture.self]
        return try await SkillGitHubDataRequest(maximumBytes: 1024, diagnostic: "Test source unavailable",
            configuration: configuration).load(URLRequest(url: URL(string: "https://skill-transport.invalid/test")!))
    }
    @Test func receivesExactLimitAcrossChunks() async throws {
        let received = try await request(.exact)
        #expect(received == Data(repeating: 0x5a, count: 1024))
    }
    @Test func refusesDeclaredAndUnknownLengthOverflow() async {
        for mode: SkillHTTPFixture.Mode in [.declaredOversize, .chunkOversize] {
            do { _ = try await request(mode); Issue.record("Oversize response was accepted") }
            catch { #expect(String(describing: error).contains("size limit")) }
        }
    }
    @Test func cancelsAnInFlightRequest() async throws {
        let task = Task { try await request(.suspended) }
        try await Task.sleep(for: .milliseconds(30)); task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled request completed") }
        catch { #expect(error is CancellationError) }
    }
    @Test func refusesRedirectInsteadOfForwardingCredentials() {
        let loader = SkillGitHubDataRequest(maximumBytes: 1024, diagnostic: "Test source unavailable")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://skill-transport.invalid/test")!
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let task = session.dataTask(with: original)
        loader.urlSession(session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://elsewhere.invalid/test")!)) { request in
                #expect(request == nil)
            }
        task.cancel()
    }
}
#endif
