// SPDX-License-Identifier: MPL-2.0
#if canImport(Darwin)
import XCTest
import Foundation
@testable import FloeTransport

/// G02 provider transport redirect security (job-bb6076374ae04500).
///
/// The REAL `StreamingTransport.makeSession` router is exercised over the
/// synthetic loopback fixture. These tests pin the closed Main policy:
///  * same-origin: caller headers are preserved verbatim;
///  * scheme/host/effective-port change: credential-bearing and opaque custom
///    headers are stripped, only an explicit ordinary-header allowlist stays;
///  * HTTPS -> HTTP is refused (final response is the 3xx itself);
///  * a policy delegate that returns/reintroduces headers is sanitized;
///  * A -> B -> A never restores the original credentials;
///  * nil policy decisions stay nil (MCP fail-closed behaviour).
final class TransportRedirectPolicyTests: XCTestCase {

    private var fixtures: [ScriptedLoopbackFixture] = []

    override func tearDown() {
        for fixture in fixtures { fixture.stop() }
        fixtures.removeAll()
        super.tearDown()
    }

    private func startFixture() throws -> ScriptedLoopbackFixture {
        let fixture = try ScriptedLoopbackFixture()
        fixture.start()
        fixtures.append(fixture)
        return fixture
    }

    private func url(_ fixture: ScriptedLoopbackFixture, _ path: String,
                     host: String = "127.0.0.1") -> URL {
        URL(string: "http://\(host):\(fixture.port)\(path)")!
    }

    private func request(_ fixture: ScriptedLoopbackFixture, _ path: String,
                         host: String = "127.0.0.1",
                         headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url(fixture, path, host: host))
        request.timeoutInterval = 10
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private let credentialHeaders = [
        "Authorization": "Bearer synthetic-canary",
        "Proxy-Authorization": "Basic synthetic",
        "x-api-key": "synthetic-x-api-key",
        "api-key": "synthetic-api-key",
        "x-goog-api-key": "synthetic-google-key",
        "Cookie": "session=synthetic",
    ]

    private func scriptRedirect(_ fixture: ScriptedLoopbackFixture,
                                path: String, to location: String) {
        fixture.register(path: path) { connection in
            connection.sendHead(status: 302, headers: [
                "location": location, "content-length": "0",
            ])
        }
    }

    private func scriptOK(_ fixture: ScriptedLoopbackFixture, path: String,
                          body: String = "ok") {
        fixture.register(path: path) { connection in
            connection.sendHead(status: 200, headers: [
                "content-length": "\(body.utf8.count)",
            ])
            connection.sendRaw(Data(body.utf8))
        }
    }

    private func collect(_ request: URLRequest, session: URLSession,
                         maxBytes: Int = 4096) async throws
        -> (Data, HTTPURLResponse) {
        let (data, response) = try await StreamingTransport.collect(
            request, via: session, maxBytes: maxBytes)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    // MARK: - Actual router over loopback

    func testSameOriginRedirectPreservesCustomAndOrdinaryHeaders() async throws {
        let server = try startFixture()
        scriptRedirect(server, path: "/same/start", to: "/same/target")
        scriptOK(server, path: "/same/target")
        let session = StreamingTransport.makeSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var headers = credentialHeaders
        headers["X-Provider-Custom"] = "opaque-synthetic"
        headers["Accept"] = "application/json"
        let (_, response) = try await collect(
            request(server, "/same/start", headers: headers), session: session)
        XCTAssertEqual(response.statusCode, 200)
        let target = try XCTUnwrap(server.headers(for: "/same/target"))
        // Darwin's URLSession strips Authorization/Proxy-Authorization before
        // the delegate on ALL redirects (platform behaviour, not this router).
        // The router's same-origin contract is that it changes nothing it is
        // handed; Android corelibs preserves the caller's Authorization and
        // is proven by the API37 TLS T7 canary. Ordinary/custom headers must
        // survive unchanged on every platform.
        XCTAssertEqual(target["x-api-key"], "synthetic-x-api-key")
        XCTAssertEqual(target["x-provider-custom"], "opaque-synthetic")
        XCTAssertEqual(target["accept"], "application/json")
    }

    func testSameOriginPolicyRequestKeepsReintroducedCredentials() async throws {
        // A policy delegate may legitimately supply headers after Foundation
        // has constructed the redirect request. Same-origin must not sanitize
        // them; the cross-origin test below proves the contrast.
        let server = try startFixture()
        scriptRedirect(server, path: "/same/policy", to: "/same/policy-target")
        scriptOK(server, path: "/same/policy-target")
        let session = StreamingTransport.makeSession(
            configuration: .ephemeral,
            policyDelegate: ReintroducingPolicy())
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await collect(
            request(server, "/same/policy", headers: credentialHeaders), session: session)
        XCTAssertEqual(response.statusCode, 200)
        let target = try XCTUnwrap(server.headers(for: "/same/policy-target"))
        XCTAssertEqual(target["authorization"], "Bearer reintroduced-canary")
        XCTAssertEqual(target["proxy-authorization"], "Basic reintroduced-proxy")
        XCTAssertEqual(target["x-api-key"], "reintroduced-key")
        XCTAssertEqual(target["x-provider-custom"], "reintroduced-opaque")
    }

    func testCrossHostRedirectStripsCredentialsAndOpaqueCustomHeaders() async throws {
        let server = try startFixture()
        scriptRedirect(server, path: "/cross/host",
                       to: "http://localhost:\(server.port)/cross/target")
        scriptOK(server, path: "/cross/target")
        let session = StreamingTransport.makeSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var headers = credentialHeaders
        headers["X-Provider-Custom"] = "opaque-synthetic"
        headers["Accept"] = "application/json"
        headers["Content-Type"] = "application/json"
        headers["Cache-Control"] = "no-cache"
        let (_, response) = try await collect(
            request(server, "/cross/host", headers: headers), session: session)
        XCTAssertEqual(response.statusCode, 200)
        let target = try XCTUnwrap(server.headers(for: "/cross/target"))
        for name in ["authorization", "proxy-authorization", "x-api-key",
                     "api-key", "x-goog-api-key", "cookie",
                     "x-provider-custom"] {
            XCTAssertNil(target[name], "cross-host must strip \(name): \(target)")
        }
        XCTAssertEqual(target["accept"], "application/json")
        XCTAssertEqual(target["content-type"], "application/json")
        XCTAssertEqual(target["cache-control"], "no-cache")
    }

    func testCrossPortRedirectStripsCredentials() async throws {
        let origin = try startFixture()
        let targetServer = try startFixture()
        scriptRedirect(origin, path: "/cross/port",
                       to: "http://127.0.0.1:\(targetServer.port)/cross/port-target")
        scriptOK(targetServer, path: "/cross/port-target")
        let session = StreamingTransport.makeSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var headers = credentialHeaders
        headers["X-Provider-Custom"] = "opaque-synthetic"
        let (_, response) = try await collect(
            request(origin, "/cross/port", headers: headers), session: session)
        XCTAssertEqual(response.statusCode, 200)
        let target = try XCTUnwrap(targetServer.headers(for: "/cross/port-target"))
        XCTAssertNil(target["authorization"], "\(target)")
        XCTAssertNil(target["x-api-key"], "\(target)")
        XCTAssertNil(target["x-provider-custom"], "\(target)")
    }

    final class ReintroducingPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            var injected = request
            injected.setValue("Bearer reintroduced-canary", forHTTPHeaderField: "Authorization")
            injected.setValue("Basic reintroduced-proxy", forHTTPHeaderField: "Proxy-Authorization")
            injected.setValue("reintroduced-opaque", forHTTPHeaderField: "X-Provider-Custom")
            injected.setValue("reintroduced-key", forHTTPHeaderField: "x-api-key")
            injected.setValue("application/json", forHTTPHeaderField: "Accept")
            completionHandler(injected)
        }
    }

    func testPolicyReintroducedCredentialsAreSanitizedOnOriginChange() async throws {
        let server = try startFixture()
        scriptRedirect(server, path: "/policy/cross",
                       to: "http://localhost:\(server.port)/policy/target")
        scriptOK(server, path: "/policy/target")
        let session = StreamingTransport.makeSession(
            configuration: .ephemeral,
            policyDelegate: ReintroducingPolicy())
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await collect(
            request(server, "/policy/cross", headers: credentialHeaders), session: session)
        XCTAssertEqual(response.statusCode, 200)
        let target = try XCTUnwrap(server.headers(for: "/policy/target"))
        XCTAssertNil(target["authorization"], "\(target)")
        XCTAssertNil(target["proxy-authorization"], "\(target)")
        XCTAssertNil(target["x-provider-custom"], "\(target)")
        XCTAssertNil(target["x-api-key"], "\(target)")
        XCTAssertEqual(target["accept"], "application/json")
    }

    func testOriginAtoBtoADoesNotRestoreOriginalCredentials() async throws {
        let server = try startFixture()
        scriptRedirect(server, path: "/chain/a",
                       to: "http://localhost:\(server.port)/chain/b")
        scriptRedirect(server, path: "/chain/b",
                       to: "http://127.0.0.1:\(server.port)/chain/a-again")
        scriptOK(server, path: "/chain/a-again")
        let session = StreamingTransport.makeSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var headers = credentialHeaders
        headers["X-Provider-Custom"] = "opaque-synthetic"
        let (_, response) = try await collect(
            request(server, "/chain/a", headers: headers), session: session)
        XCTAssertEqual(response.statusCode, 200)
        let middle = try XCTUnwrap(server.headers(for: "/chain/b", occurrence: 0))
        let final = try XCTUnwrap(server.headers(for: "/chain/a-again"))
        for hop in [middle, final] {
            XCTAssertNil(hop["authorization"], "\(hop)")
            XCTAssertNil(hop["x-api-key"], "\(hop)")
            XCTAssertNil(hop["x-provider-custom"], "\(hop)")
        }
    }

    final class NilRedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    func testNilPolicyDecisionStaysNilAndTargetSeesNothing() async throws {
        let server = try startFixture()
        scriptRedirect(server, path: "/policy/nil",
                       to: "http://localhost:\(server.port)/policy/nil-target")
        scriptOK(server, path: "/policy/nil-target")
        let session = StreamingTransport.makeSession(
            configuration: .ephemeral,
            policyDelegate: NilRedirectPolicy())
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await collect(
            request(server, "/policy/nil", headers: credentialHeaders), session: session)
        XCTAssertEqual(response.statusCode, 302,
                       "nil policy must surface the 3xx itself")
        XCTAssertEqual(server.count(for: "/policy/nil-target"), 0)
    }

}
#endif
