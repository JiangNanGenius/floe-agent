import Foundation
import XCTest
@testable import FloeExecution

/// Integration-path coverage for the public web search repair.
///
/// These tests drive the real `WebSearchService` actor end to end — provider
/// resolution, request construction/signing, the SSRF `PublicNetworkTargetPolicy`
/// validation, response parsing and failover. Canonical provider hosts get
/// deterministic public DNS answers so CI outages cannot change the HTTP
/// contract under test; the policy still classifies every resolved address.
/// TCP transport is intercepted by a `URLProtocol` stub.
/// Intercepted transport is NOT device validation: see EVIDENCE for limits.
final class WebSearchServiceIntegrationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.state.reset()
    }

    private func makeService(
        _ providers: [(WebSearchProviderConfiguration, WebSearchCredential)]
    ) -> WebSearchService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return WebSearchService(
            configuration: configuration,
            configurations: { providers },
            validateDestination: { url, allowTransient in
                try PublicNetworkTargetPolicy.validate(
                    url,
                    allowTransientTunnelAddresses: allowTransient,
                    resolve: { host in
                        switch host {
                        case "api.bochaai.com", "api.tavily.com",
                             "wsa.tencentcloudapi.com", "redirected.example.org":
                            return ["93.184.216.34"]
                        default:
                            throw URLError(.cannotFindHost)
                        }
                    }
                )
            }
        )
    }

    private func provider(
        _ kind: WebSearchProviderKind,
        priority: Int = 0,
        endpoint: URL? = nil
    ) -> WebSearchProviderConfiguration {
        WebSearchProviderConfiguration(
            kind: kind,
            displayName: kind.rawValue,
            endpoint: endpoint,
            credentialAccount: "test-\(kind.rawValue)",
            enabled: true,
            priority: priority
        )
    }

    func testDeterministicResolverStillRejectsPrivateAddresses() {
        let url = URL(string: "https://api.bochaai.com/v1/web-search")!
        XCTAssertThrowsError(try PublicNetworkTargetPolicy.validate(
            url,
            allowTransientTunnelAddresses: false,
            resolve: { _ in ["127.0.0.1"] }
        )) { error in
            guard case HTTPRequestError.privateNetworkTarget("api.bochaai.com") = error else {
                return XCTFail("expected private-target rejection, got \(error)")
            }
        }
    }

    // MARK: - Public provider: real request construction through the actor

    func testBochaPublicProviderRequestDeliveryAndParse() async throws {
        MockURLProtocol.state.stub(host: "api.bochaai.com") { _ in
            .ok(Stubs.bochaBody(
                name: "Today headline",
                url: "https://example.com/article",
                snippet: "top story",
                site: "Example"
            ))
        }
        let service = makeService([
            (provider(.bochaWeb), WebSearchCredential(values: ["apiKey": "key-123"]))
        ])

        let response = try await service.search(WebSearchQuery(
            text: "todays news", mode: .balanced, maxResults: 10
        ))

        XCTAssertEqual(response.providersUsed, [.bochaWeb])
        XCTAssertTrue(response.failures.isEmpty)
        XCTAssertEqual(response.results.count, 1)
        let result = try XCTUnwrap(response.results.first)
        XCTAssertEqual(result.title, "Today headline")
        XCTAssertEqual(result.url.absoluteString, "https://example.com/article")
        XCTAssertEqual(result.snippet, "top story")
        XCTAssertEqual(result.sourceName, "Example")
        XCTAssertEqual(result.provider, .bochaWeb)
        XCTAssertEqual(result.citationID.count, 12)

        let sent = try XCTUnwrap(MockURLProtocol.state.captured.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://api.bochaai.com/v1/web-search")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer key-123")
        let body = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(Self.bodyData(of: sent))
        ) as? [String: Any]
        XCTAssertEqual(body?["query"] as? String, "todays news")
        XCTAssertEqual(body?["count"] as? Int, 10)
    }

    /// URLSession often hands a POST body to the protocol as an
    /// `httpBodyStream` rather than `httpBody`; drain whichever is present.
    fileprivate static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read < 0 { return nil }
            if read == 0 { break }
            data.append(contentsOf: buffer.prefix(read))
        }
        return data
    }

    func testTencentSignedRequestAndPageParsing() async throws {
        MockURLProtocol.state.stub(host: "wsa.tencentcloudapi.com") { _ in
            .ok(Stubs.tencentBody(items: [(
                title: "Tencent headline",
                url: "https://t.example.com/story",
                snippet: "tencent snippet"
            )]))
        }
        let service = makeService([
            (provider(.tencentWSA),
             WebSearchCredential(values: ["secretId": "sid", "secretKey": "skey"]))
        ])

        let response = try await service.search(WebSearchQuery(
            text: "todays news", mode: .balanced, maxResults: 10,
            requestedProvider: "tencentWSA"
        ))

        XCTAssertEqual(response.providersUsed, [.tencentWSA])
        XCTAssertEqual(response.results.first?.title, "Tencent headline")
        XCTAssertEqual(response.results.first?.provider, .tencentWSA)

        let sent = try XCTUnwrap(MockURLProtocol.state.captured.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://wsa.tencentcloudapi.com")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-TC-Action"), "SearchPro")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-TC-Version"), "2025-05-08")
        XCTAssertTrue(
            (sent.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("TC3-HMAC-SHA256"))
        XCTAssertNotNil(sent.value(forHTTPHeaderField: "X-TC-Timestamp"))
    }

    // MARK: - Failover and aggregate failure

    func testFailoverAdvancesAfterHTTPFailure() async throws {
        MockURLProtocol.state.stub(host: "api.bochaai.com") { _ in .status(500) }
        MockURLProtocol.state.stub(host: "api.tavily.com") { _ in
            .ok(Stubs.genericResults(items: [(
                title: "Tavily headline",
                url: "https://tavily.example.com/a",
                snippet: "fallback"
            )]))
        }
        let service = makeService([
            (provider(.bochaWeb, priority: 0),
             WebSearchCredential(values: ["apiKey": "k1"])),
            (provider(.tavily, priority: 1),
             WebSearchCredential(values: ["apiKey": "k2"]))
        ])

        let response = try await service.search(WebSearchQuery(
            text: "todays news", mode: .balanced, maxResults: 10
        ))

        XCTAssertEqual(response.providersUsed, [.tavily])
        XCTAssertEqual(response.results.first?.title, "Tavily headline")
        XCTAssertEqual(response.failures, ["bochaWeb: HTTP 500"])
    }

    func testEmptyResultAdvancesToNextProvider() async throws {
        MockURLProtocol.state.stub(host: "api.bochaai.com") { _ in .ok(Stubs.emptyBochaBody()) }
        MockURLProtocol.state.stub(host: "api.tavily.com") { _ in
            .ok(Stubs.genericResults(items: [(
                title: "Second provider result",
                url: "https://other.example.com/x",
                snippet: "s"
            )]))
        }
        let service = makeService([
            (provider(.bochaWeb, priority: 0), WebSearchCredential(values: ["apiKey": "k1"])),
            (provider(.tavily, priority: 1), WebSearchCredential(values: ["apiKey": "k2"]))
        ])

        let response = try await service.search(WebSearchQuery(
            text: "todays news", mode: .balanced, maxResults: 10
        ))

        XCTAssertEqual(response.providersUsed, [.tavily])
        XCTAssertEqual(response.failures, ["bochaWeb: empty result"])
    }

    func testAllProvidersFailingReportsProviderFailures() async {
        MockURLProtocol.state.stub(host: "api.bochaai.com") { _ in .status(429) }
        MockURLProtocol.state.stub(host: "api.tavily.com") { _ in .status(500) }
        let service = makeService([
            (provider(.bochaWeb, priority: 0), WebSearchCredential(values: ["apiKey": "k1"])),
            (provider(.tavily, priority: 1), WebSearchCredential(values: ["apiKey": "k2"]))
        ])

        do {
            _ = try await service.search(WebSearchQuery(
                text: "todays news", mode: .balanced, maxResults: 10
            ))
            XCTFail("expected allProvidersFailed")
        } catch let WebRetrievalError.allProvidersFailed(failures) {
            XCTAssertEqual(failures, ["bochaWeb: HTTP 429", "tavily: HTTP 500"])
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Redirect destination protection

    func testCrossOriginRedirectRejectedWithoutLeavingProviderOrigin() async throws {
        MockURLProtocol.state.stub(host: "api.bochaai.com") { request in
            if request.url?.path == "/v1/web-search" {
                return .redirect(to: "https://redirected.example.org/collect")
            }
            return .status(500)
        }
        MockURLProtocol.state.stub(host: "redirected.example.org") { _ in
            .ok(Stubs.genericResults(items: []))
        }
        let service = makeService([
            (provider(.bochaWeb), WebSearchCredential(values: ["apiKey": "secret-key"]))
        ])

        do {
            _ = try await service.search(WebSearchQuery(
                text: "todays news", mode: .balanced, maxResults: 10
            ))
            XCTFail("expected provider failure")
        } catch let WebRetrievalError.allProvidersFailed(failures) {
            XCTAssertEqual(failures.first, "bochaWeb: HTTP 302")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        // The redirect was refused: no request ever left the provider origin,
        // so the bearer key could not be forwarded cross-origin.
        let hosts = Set(MockURLProtocol.state.captured.compactMap { $0.url?.host })
        XCTAssertEqual(hosts, ["api.bochaai.com"])
        let redirected = MockURLProtocol.state.captured.filter {
            $0.url?.host == "redirected.example.org"
        }
        XCTAssertTrue(redirected.isEmpty)
    }

    func testSameOriginRedirectIsFollowedAndRevalidated() async throws {
        MockURLProtocol.state.stub(host: "api.bochaai.com") { request in
            if request.url?.path == "/v1/web-search" {
                return .redirect(to: "https://api.bochaai.com/v1/web-search-retry")
            }
            return .ok(Stubs.bochaBody(
                name: "Retried headline",
                url: "https://example.com/retry",
                snippet: "after same-origin redirect",
                site: "Example"
            ))
        }
        let service = makeService([
            (provider(.bochaWeb), WebSearchCredential(values: ["apiKey": "k"]))
        ])

        let response = try await service.search(WebSearchQuery(
            text: "todays news", mode: .balanced, maxResults: 10
        ))

        XCTAssertEqual(response.results.first?.title, "Retried headline")
        XCTAssertEqual(MockURLProtocol.state.captured.count, 2)
        XCTAssertTrue(MockURLProtocol.state.captured.allSatisfy {
            $0.url?.host == "api.bochaai.com"
        })
    }

    // MARK: - Fake-IP tunnel grant is bound to provider kind + canonical endpoint

    func testTransientTunnelGrantForCanonicalBuiltInKinds() {
        for kind in [WebSearchProviderKind.bochaWeb, .bochaAI, .tencentWSA,
                     .brave, .tavily, .exa, .googleProgrammable] {
            XCTAssertTrue(
                WebSearchService.allowsTransientTunnel(for: provider(kind)),
                kind.rawValue)
        }
    }

    func testTransientTunnelGrantRefusedForCustomAndSelfHostedKinds() {
        // Host name alone never grants the relaxation: custom/self-hosted
        // providers have no fixed endpoint contract.
        for kind in [WebSearchProviderKind.custom, .searxng, .volcengine] {
            XCTAssertFalse(
                WebSearchService.allowsTransientTunnel(for: provider(kind)),
                kind.rawValue)
        }
        // Even a custom provider pointed exactly at a canonical host is refused.
        let impersonator = provider(
            .custom,
            endpoint: URL(string: "https://api.bochaai.com/v1/web-search"))
        XCTAssertFalse(WebSearchService.allowsTransientTunnel(for: impersonator))
    }

    func testTransientTunnelGrantRefusedForEndpointOverrideOrNonStandardPort() {
        // An explicit override forfeits the grant even when it reproduces the
        // canonical URL exactly, and even when it merely adds a port.
        let sameURLOverride = provider(
            .bochaWeb,
            endpoint: URL(string: "https://api.bochaai.com/v1/web-search"))
        XCTAssertFalse(WebSearchService.allowsTransientTunnel(for: sameURLOverride))

        let portOverride = provider(
            .bochaWeb,
            endpoint: URL(string: "https://api.bochaai.com:8443/v1/web-search"))
        XCTAssertFalse(WebSearchService.allowsTransientTunnel(for: portOverride))

        let otherHostOverride = provider(
            .bochaWeb,
            endpoint: URL(string: "https://api.bochaai.com.evil.test/v1/web-search"))
        XCTAssertFalse(WebSearchService.allowsTransientTunnel(for: otherHostOverride))
    }

    // MARK: - Actual makeRequest URLs satisfy the canonical contract

    private func makeRequest(
        kind: WebSearchProviderKind,
        credential: [String: String]
    ) throws -> URLRequest {
        try WebSearchService.makeRequest(
            provider(kind),
            credential: WebSearchCredential(values: credential),
            query: WebSearchQuery(text: "todays news", maxResults: 10)
        )
    }

    func testActualMakeRequestURLsAreCanonicalForAllGrantedKinds() throws {
        let cases: [(WebSearchProviderKind, [String: String])] = [
            (.bochaWeb, ["apiKey": "k"]),
            (.bochaAI, ["apiKey": "k"]),
            (.tencentWSA, ["secretId": "sid", "secretKey": "skey"]),
            (.brave, ["apiKey": "k"]),
            (.tavily, ["apiKey": "k"]),
            (.exa, ["apiKey": "k"]),
            (.googleProgrammable, ["apiKey": "k", "engineId": "e"])
        ]
        for (kind, credential) in cases {
            let request = try makeRequest(kind: kind, credential: credential)
            // The real request URL may carry a generated query (Brave/Google);
            // scheme/host/port/path still equal the canonical contract, so the
            // runtime grant survives the query-bearing URL.
            XCTAssertTrue(
                WebSearchService.requestURLIsCanonical(request.url, kind: kind),
                kind.rawValue)
            // Full grant condition as used by `run`.
            XCTAssertTrue(
                WebSearchService.allowsTransientTunnel(for: provider(kind))
                    && WebSearchService.requestURLIsCanonical(request.url, kind: kind),
                kind.rawValue)
        }
    }

    func testCanonicalURLMatcherRejectsTamperedDestinations() {
        let canonical = URL(string: "https://api.bochaai.com/v1/web-search")!
        XCTAssertTrue(WebSearchService.requestURLIsCanonical(canonical, kind: .bochaWeb))
        // Different scheme, host, port or path: rejected. Query/fragment
        // changes alone do not defeat the match.
        for tampered in ["http://api.bochaai.com/v1/web-search",
                         "https://api.bochaai.com:8443/v1/web-search",
                         "https://api.bochaai.com.evil.test/v1/web-search",
                         "https://api.bochaai.com/v1/other"] {
            XCTAssertFalse(
                WebSearchService.requestURLIsCanonical(URL(string: tampered), kind: .bochaWeb),
                tampered)
        }
        XCTAssertTrue(WebSearchService.requestURLIsCanonical(
            URL(string: "https://api.bochaai.com/v1/web-search?x=1#f"), kind: .bochaWeb))
        // A canonical URL of one kind is not valid for a different kind.
        XCTAssertFalse(WebSearchService.requestURLIsCanonical(canonical, kind: .tavily))
    }
}

// MARK: - URLProtocol transport stub

enum StubOutcome {
    case ok(Data)
    case status(Int)
    case redirect(to: String)
    case failure(Error)
}

final class MockURLProtocol: URLProtocol {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var stubs: [String: (URLRequest) -> StubOutcome] = [:]
        private var capturedStorage: [URLRequest] = []

        func reset() {
            lock.lock()
            stubs = [:]
            capturedStorage = []
            lock.unlock()
        }

        func stub(host: String, _ outcome: @escaping (URLRequest) -> StubOutcome) {
            lock.lock()
            stubs[host] = outcome
            lock.unlock()
        }

        var captured: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return capturedStorage
        }

        func taskStarted(forHost host: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return capturedStorage.contains { $0.url?.host == host }
        }

        fileprivate func record(_ request: URLRequest) {
            lock.lock()
            capturedStorage.append(request)
            lock.unlock()
        }

        fileprivate func outcome(for request: URLRequest) -> StubOutcome {
            lock.lock()
            let stub = request.url.flatMap { stubs[$0.host ?? ""] }
            lock.unlock()
            return stub?(request) ?? .status(404)
        }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.record(request)
        switch Self.state.outcome(for: request) {
        case .ok(let data):
            respond(statusCode: 200, data: data)
        case .status(let code):
            respond(statusCode: code, data: Data())
        case .redirect(let location):
            // Notify the loading system of the redirect. It consults the task
            // delegate (willPerformHTTPRedirection): allowance starts a new
            // protocol task for the target. On refusal, CFNetwork delivers no
            // terminal response for a custom-protocol redirect (the task was
            // observed to hang until timeout), so if no follow-up task starts
            // shortly, deliver the 302 ourselves.
            let targetURL = URL(string: location)!
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": location])!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: targetURL),
                redirectResponse: response
            )
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) { [weak self] in
                guard let self else { return }
                guard !Self.state.taskStarted(forHost: targetURL.host ?? "") else { return }
                self.respond(statusCode: 302, data: Data(),
                             headers: ["Location": location])
            }
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func respond(
        statusCode: Int,
        data: Data,
        headers: [String: String] = [:]
    ) {
        var fields = headers
        fields["Content-Type"] = "application/json"
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1",
            headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

// MARK: - Provider fixtures

enum Stubs {
    static func bochaBody(name: String, url: String, snippet: String, site: String) -> Data {
        let json: [String: Any] = [
            "code": 200,
            "data": [
                "webPages": [
                    "value": [[
                        "name": name, "url": url, "summary": snippet, "siteName": site
                    ]]
                ]
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    static func emptyBochaBody() -> Data {
        let json: [String: Any] = [
            "code": 200,
            "data": ["webPages": ["value": []]]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    static func tencentBody(items: [(title: String, url: String, snippet: String)]) -> Data {
        let pages = items.map { item -> String in
            String(data: try! JSONSerialization.data(withJSONObject: [
                "title": item.title, "url": item.url, "snippet": item.snippet
            ]), encoding: .utf8)!
        }
        return try! JSONSerialization.data(withJSONObject: ["Response": ["Pages": pages]])
    }

    static func genericResults(items: [(title: String, url: String, snippet: String)]) -> Data {
        let values = items.map { ["title": $0.title, "url": $0.url, "snippet": $0.snippet] }
        return try! JSONSerialization.data(withJSONObject: ["results": values])
    }
}
