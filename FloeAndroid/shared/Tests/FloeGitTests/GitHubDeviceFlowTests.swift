import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import FloeGit

private final class GitHubOAuthURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub { let status: Int; let body: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func prepare(_ values: [Stub]) {
        lock.lock()
        stubs = values
        requests = []
        lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        Self.lock.lock()
        Self.requests.append(captured)
        let stub = Self.stubs.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: stub.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("GitHub OAuth device flow", .serialized)
struct GitHubDeviceFlowTests {
    private func service() -> GitHubService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubOAuthURLProtocol.self]
        return GitHubService(session: URLSession(configuration: configuration))
    }

    @Test("Requests a device code using form encoding without a client secret")
    func beginsDeviceFlow() async throws {
        GitHubOAuthURLProtocol.prepare([.init(status: 200, body: Data(#"""
        {
          "device_code":"device-secret",
          "user_code":"ABCD-EFGH",
          "verification_uri":"https://github.com/login/device",
          "expires_in":900,
          "interval":5
        }
        """#.utf8))])

        let authorization = try await service().beginDeviceAuthorization(
            clientID: "public-client-id"
        )

        #expect(authorization.userCode == "ABCD-EFGH")
        #expect(authorization.verificationURL.absoluteString == "https://github.com/login/device")
        let request = try #require(GitHubOAuthURLProtocol.capturedRequests().first)
        #expect(request.url?.absoluteString == "https://github.com/login/device/code")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("client_id=public-client-id"))
        #expect(body.contains("scope=repo%20read:user") || body.contains("scope=repo+read:user"))
        #expect(!body.contains("client_secret"))
    }

    @Test("Polls pending authorization and returns the accepted token")
    func completesDeviceFlow() async throws {
        GitHubOAuthURLProtocol.prepare([
            .init(status: 200, body: Data(#"{"error":"authorization_pending"}"#.utf8)),
            .init(status: 200, body: Data(#"{"access_token":"accepted-token","token_type":"bearer","scope":"repo read:user"}"#.utf8))
        ])
        let authorization = GitHubDeviceAuthorization(
            deviceCode: "device-secret",
            userCode: "ABCD-EFGH",
            verificationURL: URL(string: "https://github.com/login/device")!,
            expiresAt: Date().addingTimeInterval(30),
            interval: 0
        )

        let token = try await service().completeDeviceAuthorization(
            authorization,
            clientID: "public-client-id"
        )

        #expect(token == "accepted-token")
        #expect(GitHubOAuthURLProtocol.capturedRequests().count == 2)
    }
}
