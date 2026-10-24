import Foundation
import XCTest
import FloeTools
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
                             "wsa.tencentcloudapi.com", "redirected.example.org",
                             "open.feedcoopapi.com", "ark.cn-beijing.volces.com",
                             "api.search.brave.com", "search.example.com":
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

    private func volcengineProvider(
        _ interface: VolcengineSearchInterface,
        options: [String: String] = [:]
    ) -> WebSearchProviderConfiguration {
        var values = options
        values[VolcengineSearchOptions.Key.interface] = interface.rawValue
        return WebSearchProviderConfiguration(
            kind: .volcengine,
            displayName: "Volcengine",
            credentialAccount: "test-volcengine-\(interface.rawValue)",
            enabled: true,
            options: values
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

    // MARK: - Volcengine account/interface end-to-end

    func testVolcengineAgentPlanEndToEnd() async throws {
        MockURLProtocol.state.stub(host: "open.feedcoopapi.com") { _ in
            .ok(Stubs.volcengineDirectBody(
                title: "Agent Plan story",
                url: "https://example.com/agent-plan",
                snippet: "agent plan snippet",
                publishTime: "2026-10-20T10:00:00+08:00",
                siteName: "Example",
                logoURL: "https://example.com/logo.png"
            ))
        }
        let service = makeService([
            (volcengineProvider(.agentPlan),
             WebSearchCredential(values: ["apiKey": "agent-plan-key"]))
        ])

        let response = try await service.search(WebSearchQuery(
            text: "latest story",
            mode: .balanced,
            maxResults: 10,
            requestedProvider: "volcengine"
        ))

        XCTAssertEqual(response.providersUsed, [.volcengine])
        XCTAssertTrue(response.failures.isEmpty)
        XCTAssertTrue(response.generatedAnswers.isEmpty)
        XCTAssertEqual(response.results.first?.title, "Agent Plan story")
        XCTAssertEqual(response.results.first?.snippet, "agent plan snippet")
        XCTAssertEqual(response.results.first?.publishedAt, "2026-10-20T10:00:00+08:00")
        XCTAssertEqual(response.results.first?.sourceName, "Example")
        XCTAssertEqual(response.results.first?.faviconURL, "https://example.com/logo.png")

        let sent = try XCTUnwrap(MockURLProtocol.state.captured.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://open.feedcoopapi.com/search_api/web_search")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer agent-plan-key")
        let body = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(Self.bodyData(of: sent))
        ) as? [String: Any]
        XCTAssertEqual(body?["Query"] as? String, "latest story")
        XCTAssertEqual(body?["Count"] as? Int, 10)
        XCTAssertNil(sent.value(forHTTPHeaderField: "X-Traffic-Tag"))
    }

    func testVolcengineArkCitationsAndAnswerReachToolOutput() async throws {
        MockURLProtocol.state.stub(host: "ark.cn-beijing.volces.com") { _ in
            .ok(Stubs.volcengineArkBody(
                answer: "The generated weather summary.",
                citations: [(
                    title: "Weather source",
                    url: "https://example.com/weather",
                    summary: "Short citation summary",
                    siteName: "Example Weather",
                    publishTime: "2026-10-20T08:00:00+08:00"
                )]
            ))
        }
        let service = makeService([
            (volcengineProvider(.arkResponses),
             WebSearchCredential(values: ["apiKey": "ark-key"]))
        ])

        let response = try await service.search(WebSearchQuery(
            text: "weather",
            mode: .balanced,
            maxResults: 10,
            requestedProvider: "volcengine"
        ))

        XCTAssertEqual(response.providersUsed, [.volcengine])
        XCTAssertEqual(response.results.count, 1)
        XCTAssertEqual(response.results.first?.snippet, "Short citation summary")
        XCTAssertEqual(response.generatedAnswers.count, 1)
        XCTAssertEqual(response.generatedAnswers.first?.text, "The generated weather summary.")

        let output = try WebSearchTool.output(response)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any]
        )
        let answers = try XCTUnwrap(object["generatedAnswers"] as? [[String: Any]])
        XCTAssertEqual(answers.first?["answer"] as? String, "The generated weather summary.")
        XCTAssertNotNil(object["providerGeneratedAnswerNote"] as? String)
        let rows = try XCTUnwrap(object["results"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["snippet"] as? String, "Short citation summary")
        XCTAssertNotEqual(rows.first?["snippet"] as? String,
                          answers.first?["answer"] as? String)
    }

    func testVolcengineArkAnswerWithoutURLCitationsIsNotAnEmptyFailure() async throws {
        MockURLProtocol.state.stub(host: "ark.cn-beijing.volces.com") { _ in
            .ok(Stubs.volcengineArkAnswerOnlyBody("Useful weather text without citations."))
        }
        let service = makeService([
            (volcengineProvider(.arkResponses),
             WebSearchCredential(values: ["apiKey": "ark-key"]))
        ])

        let response = try await service.search(WebSearchQuery(
            text: "weather",
            mode: .balanced,
            maxResults: 10,
            requestedProvider: "volcengine"
        ))
        XCTAssertTrue(response.results.isEmpty)
        XCTAssertEqual(response.generatedAnswers.first?.text, "Useful weather text without citations.")

        let output = try WebSearchTool.output(response)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["returned"] as? Int, 0)
        let answers = try XCTUnwrap(object["generatedAnswers"] as? [[String: Any]])
        XCTAssertEqual(answers.first?["answer"] as? String, "Useful weather text without citations.")
        XCTAssertNotNil(object["providerGeneratedAnswerNote"] as? String)
    }

    func testVolcengineArkIncomplete200IsReportedAsProviderFailure() async {
        MockURLProtocol.state.stub(host: "ark.cn-beijing.volces.com") { _ in
            .ok(Stubs.volcengineArkStatusBody("incomplete", reason: "max_output_tokens"))
        }
        let service = makeService([
            (volcengineProvider(.arkResponses),
             WebSearchCredential(values: ["apiKey": "ark-key"]))
        ])

        do {
            _ = try await service.search(WebSearchQuery(
                text: "weather",
                mode: .balanced,
                maxResults: 10,
                requestedProvider: "volcengine"
            ))
            XCTFail("expected allProvidersFailed")
        } catch let WebRetrievalError.allProvidersFailed(failures) {
            XCTAssertEqual(failures.count, 1)
            XCTAssertTrue(failures.first?.hasPrefix("volcengine: ") == true)
            XCTAssertTrue(failures.first?.contains("incomplete") == true)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testVolcengineInterfaceOriginsAreCanonicalAndDistinct() throws {
        let cases: [(VolcengineSearchInterface, String)] = [
            (.agentPlan, "https://open.feedcoopapi.com/search_api/web_search"),
            (.doubaoSearch, "https://open.feedcoopapi.com/search_api/web_search"),
            (.arkResponses, "https://ark.cn-beijing.volces.com/api/v3/responses")
        ]
        for (interface, expected) in cases {
            let configuration = volcengineProvider(interface)
            let request = try WebSearchService.makeRequest(
                configuration,
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(text: "q")
            )
            XCTAssertEqual(request.url?.absoluteString, expected, interface.rawValue)
            XCTAssertTrue(
                WebSearchService.requestURLIsCanonical(request.url, configuration: configuration),
                interface.rawValue)
            XCTAssertTrue(
                WebSearchService.allowsTransientTunnel(for: configuration),
                interface.rawValue)
        }
        // The legacy record has no fixed origin and no tunnel relaxation.
        let legacy = WebSearchProviderConfiguration(
            kind: .volcengine,
            displayName: "legacy",
            endpoint: URL(string: "https://search.example.com/api"),
            credentialAccount: "legacy",
            enabled: true
        )
        XCTAssertNil(WebSearchService.canonicalEndpoint(for: legacy))
        XCTAssertFalse(WebSearchService.allowsTransientTunnel(for: legacy))
    }

    func testVolcengineCrossOriginRedirectIsRejected() async throws {
        MockURLProtocol.state.stub(host: "open.feedcoopapi.com") { request in
            if request.url?.path == "/search_api/web_search" {
                return .redirect(to: "https://ark.cn-beijing.volces.com/api/v3/responses")
            }
            return .status(500)
        }
        MockURLProtocol.state.stub(host: "ark.cn-beijing.volces.com") { _ in
            .ok(Stubs.volcengineArkAnswerOnlyBody("must not arrive"))
        }
        let service = makeService([
            (volcengineProvider(.agentPlan),
             WebSearchCredential(values: ["apiKey": "agent-plan-key"]))
        ])

        do {
            _ = try await service.search(WebSearchQuery(
                text: "redirect",
                mode: .balanced,
                maxResults: 10,
                requestedProvider: "volcengine"
            ))
            XCTFail("expected provider failure")
        } catch let WebRetrievalError.allProvidersFailed(failures) {
            XCTAssertEqual(failures.first, "volcengine: HTTP 302")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let hosts = Set(MockURLProtocol.state.captured.compactMap { $0.url?.host })
        XCTAssertEqual(hosts, ["open.feedcoopapi.com"])
    }

    func testVolcengineGeneratedAnswerToolOutputIsBoundedWithMetadata() throws {
        let answer = String(repeating: "多字节回答", count: 2_000)
        let response = WebSearchResponse(
            query: "q",
            results: [
                WebSearchResult(
                    title: "Result",
                    url: URL(string: "https://example.com/result")!,
                    snippet: "snippet",
                    provider: .volcengine,
                    citationID: "citation"
                )
            ],
            providersUsed: [.volcengine],
            generatedAnswers: [
                WebSearchProviderGeneratedAnswer(provider: .volcengine, text: answer)
            ]
        )
        let output = try WebSearchTool.output(response)
        XCTAssertLessThanOrEqual(output.summary.count, 4_096)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["truncated"] as? Bool, true)
        let answers = try XCTUnwrap(object["generatedAnswers"] as? [[String: Any]])
        let first = try XCTUnwrap(answers.first)
        XCTAssertEqual(first["answerTruncated"] as? Bool, true)
        XCTAssertEqual(first["originalCharacters"] as? Int, answer.count)
        let bounded = try XCTUnwrap(first["answer"] as? String)
        XCTAssertLessThan(bounded.count, answer.count)
        XCTAssertFalse(bounded.isEmpty)
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

// MARK: - Settings Test Search (frozen single provider, ephemeral credential)

extension WebSearchServiceIntegrationTests {

    /// The exact production entry point used by the settings Test Search:
    /// one frozen draft, one in-memory credential, normalized results, and no
    /// request to any other configured provider.
    func testTestSearchUsesOnlyTheFrozenProvider() async throws {
        MockURLProtocol.state.stub(host: "api.search.brave.com") { _ in
            .ok(Stubs.genericResults(items: [
                (title: "Brave result", url: "https://example.com/a", snippet: "a")
            ]))
        }
        MockURLProtocol.state.stub(host: "api.bochaai.com") { _ in
            .ok(Stubs.bochaBody(
                name: "Bocha result", url: "https://example.com/b", snippet: "b", site: "B"
            ))
        }
        var brave = provider(.brave)
        brave.displayName = "Frozen Brave"
        brave.priority = 5
        let service = makeService([
            (brave, WebSearchCredential(values: ["apiKey": "transient-key"])),
            (provider(.bochaWeb, priority: 0), WebSearchCredential(values: ["apiKey": "other-key"]))
        ])

        let outcome = await service.testSearch(
            configuration: brave,
            credential: WebSearchCredential(values: ["apiKey": "transient-key"]),
            text: "today"
        )

        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.results.map(\.title), ["Brave result"])
        XCTAssertEqual(outcome.results.map(\.provider), [.brave])
        // Priority did not matter: only the frozen draft was contacted.
        XCTAssertEqual(
            MockURLProtocol.state.captured.compactMap { $0.url?.host },
            ["api.search.brave.com"]
        )
        let sent = try XCTUnwrap(MockURLProtocol.state.captured.first)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "X-Subscription-Token"), "transient-key")
    }

    /// A failing draft surfaces an actionable error and never falls through
    /// to a second configured provider (settings feedback must describe the
    /// configuration the user is editing).
    func testTestSearchNeverFallsBackToAnotherProvider() async throws {
        MockURLProtocol.state.stub(host: "api.search.brave.com") { _ in .status(500) }
        MockURLProtocol.state.stub(host: "api.bochaai.com") { _ in
            .ok(Stubs.bochaBody(
                name: "Bocha result", url: "https://example.com/b", snippet: "b", site: "B"
            ))
        }
        let brave = provider(.brave, priority: 0)
        let service = makeService([
            (brave, WebSearchCredential(values: ["apiKey": "k"])),
            (provider(.bochaWeb, priority: 1), WebSearchCredential(values: ["apiKey": "k2"]))
        ])

        let outcome = await service.testSearch(
            configuration: brave,
            credential: WebSearchCredential(values: ["apiKey": "k"]),
            text: "x"
        )

        XCTAssertNotNil(outcome.error)
        XCTAssertTrue(outcome.results.isEmpty)
        XCTAssertEqual(
            Set(MockURLProtocol.state.captured.compactMap { $0.url?.host }),
            ["api.search.brave.com"]
        )
    }

    /// Whitelisted-like blank credentials never trigger a request; the UI
    /// maps this stable reason to product copy.
    func testTestSearchReportsNotConfiguredWithoutCredential() async {
        let brave = provider(.brave)
        let service = makeService([
            (brave, WebSearchCredential(values: ["apiKey": "   "]))
        ])
        let outcome = await service.testSearch(
            configuration: brave,
            credential: WebSearchCredential(values: ["apiKey": "   "]),
            text: "x"
        )
        XCTAssertEqual(outcome.error, WebSearchTestOutcome.notConfiguredReason)
        XCTAssertTrue(MockURLProtocol.state.captured.isEmpty)
    }

    /// The static helper creates its own single-pair service and keeps the
    /// documented custom contract (POST {query, count}, Bearer, generic JSON
    /// results) without extra adapter surfaces.
    func testTestSearchCustomInterfaceKeepsDocumentedContract() async throws {
        MockURLProtocol.state.stub(host: "search.example.com") { _ in
            .ok(Stubs.genericResults(items: [
                (title: "Custom result", url: "https://example.com/c", snippet: "c")
            ]))
        }
        let custom = provider(.custom, endpoint: URL(string: "https://search.example.com/api")!)
        let service = makeService([
            (custom, WebSearchCredential(values: ["apiKey": "custom-key"]))
        ])

        let outcome = await service.testSearch(
            configuration: custom,
            credential: WebSearchCredential(values: ["apiKey": "custom-key"]),
            text: "q",
            maxResults: 3
        )

        XCTAssertNil(outcome.error)
        XCTAssertEqual(outcome.results.map(\.title), ["Custom result"])
        let sent = try XCTUnwrap(MockURLProtocol.state.captured.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://search.example.com/api")
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer custom-key")
        let body = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(Self.bodyData(of: sent))
        ) as? [String: Any]
        XCTAssertEqual(body?["query"] as? String, "q")
        XCTAssertEqual(body?["count"] as? Int, 3)
    }

    /// The static helper stays offline when the draft cannot be configured.
    func testStaticTestSearchIsOfflineWhenNotConfigured() async {
        let outcome = await WebSearchService.searchTest(
            configuration: provider(.brave),
            credential: WebSearchCredential(values: [:]),
            text: "x"
        )
        XCTAssertEqual(outcome.error, WebSearchTestOutcome.notConfiguredReason)
        XCTAssertTrue(MockURLProtocol.state.captured.isEmpty)
    }
}

// MARK: - Omitted max_results bounded default and output budget (Volcengine)

extension WebSearchServiceIntegrationTests {

    private func makeWebSearchToolService(
        _ interface: VolcengineSearchInterface,
        options: [String: String] = [:]
    ) -> WebSearchService {
        makeService([
            (volcengineProvider(interface, options: options),
             WebSearchCredential(values: ["apiKey": "bounded-default-key"]))
        ])
    }

    private func decodeArguments(_ json: String) throws -> WebSearchTool.Arguments {
        try JSONDecoder().decode(
            WebSearchTool.Arguments.self, from: Data(json.utf8)
        )
    }

    private func requestBody(of sent: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(
            with: try XCTUnwrap(Self.bodyData(of: sent))
        ) as? [String: Any] ?? [:]
    }

    /// The real public-tool path with `maxResults` omitted (and with an
    /// explicit JSON null): the Doubao/Agent Plan request must carry the
    /// bounded default as Count, and the serialized tool result must stay
    /// valid bounded JSON with exact retained citations even when the
    /// gateway overreturns twelve long rows.
    func testWebSearchToolOmittedMaxResultsSendsBoundedDefaultAndBoundedOutput() async throws {
        for json in [
            #"{"query":"量子 计算"}"#,
            #"{"query":"量子 计算","maxResults":null}"#
        ] {
            MockURLProtocol.state.reset()
            MockURLProtocol.state.stub(host: "open.feedcoopapi.com") { _ in
                .ok(Stubs.volcengineSearchEnvelope(items: 12, snippetCharacters: 900))
            }
            let tool = WebSearchTool(service: makeWebSearchToolService(.agentPlan))
            let output = try await tool.execute(
                try decodeArguments(json),
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )

            // Request side: the omitted default is actually sent as Count.
            let sent = try XCTUnwrap(MockURLProtocol.state.captured.first)
            XCTAssertEqual(sent.url?.absoluteString, "https://open.feedcoopapi.com/search_api/web_search")
            let body = try requestBody(of: sent)
            XCTAssertEqual(body["Query"] as? String, "量子 计算")
            XCTAssertEqual(body["SearchType"] as? String, "web")
            XCTAssertEqual(body["Count"] as? Int, WebSearchTool.defaultMaxResults)

            // Decode side: the 12-item overreturn is trimmed to the request.
            // Output side: bounded valid JSON inside the runtime boundary.
            XCTAssertLessThanOrEqual(output.summary.count, 4_096)
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any]
            )
            XCTAssertEqual(object["available"] as? Int, WebSearchTool.defaultMaxResults)
            let entries = try XCTUnwrap(object["results"] as? [[String: Any]])
            XCTAssertEqual(object["returned"] as? Int, entries.count)
            XCTAssertLessThanOrEqual(entries.count, WebSearchTool.defaultMaxResults)
            XCTAssertGreaterThan(entries.count, 0)
            XCTAssertEqual(object["truncated"] as? Bool, true)
            for (index, entry) in entries.enumerated() {
                XCTAssertEqual(entry["url"] as? String, "https://example.com/volc/\(index)")
                XCTAssertEqual((entry["citation"] as? String)?.count, 12)
                let snippet = try XCTUnwrap(entry["snippet"] as? String)
                XCTAssertGreaterThanOrEqual(
                    snippet.count, WebSearchTool.minimumUsefulSnippetCharacters
                )
                XCTAssertEqual(entry["snippetTruncated"] as? Bool, true)
                XCTAssertEqual(entry["originalSnippetChars"] as? Int, 900)
            }
        }
    }

    /// An explicit valid limit is respected end to end: it reaches the
    /// gateway as Count and caps the overreturned rows; it is never
    /// silently replaced by the default.
    func testWebSearchToolExplicitMaxResultsRespectedAgainstServerOverReturn() async throws {
        MockURLProtocol.state.stub(host: "open.feedcoopapi.com") { _ in
            .ok(Stubs.volcengineSearchEnvelope(items: 20, snippetCharacters: 120))
        }
        let tool = WebSearchTool(service: makeWebSearchToolService(.doubaoSearch))
        let output = try await tool.execute(
            try decodeArguments(#"{"query":"explicit","maxResults":8}"#),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        let sent = try XCTUnwrap(MockURLProtocol.state.captured.first)
        let body = try requestBody(of: sent)
        XCTAssertEqual(body["Count"] as? Int, 8)

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any]
        )
        // 20 server rows, capped to the requested 8; the first kept rows
        // keep the exact gateway order and identities.
        XCTAssertEqual(object["available"] as? Int, 8)
        let entries = try XCTUnwrap(object["results"] as? [[String: Any]])
        XCTAssertLessThanOrEqual(entries.count, 8)
        XCTAssertEqual(entries.first?["url"] as? String, "https://example.com/volc/0")
        XCTAssertEqual(object["omittedOversizeURLRows"] as? Int ?? 0, 0)
        // Validation still rejects out-of-range explicit values.
        XCTAssertThrowsError(try tool.validate(
            try decodeArguments(#"{"query":"explicit","maxResults":51}"#)
        ))
        XCTAssertNoThrow(try tool.validate(
            try decodeArguments(#"{"query":"explicit","maxResults":50}"#)
        ))
    }

    /// The Agent Plan record that pairs the web options with the reserved
    /// professional-dataset (DataPro) configuration keeps its EXACT gateway
    /// envelope: same root keys, same Filter/QueryControl semantics, and no
    /// DataPro field ever enters the web_search body (the default count only
    /// lands in Count).
    func testVolcengineProfessionalDatasetAgentPlanRequestEnvelopeUnchanged() async throws {
        MockURLProtocol.state.stub(host: "open.feedcoopapi.com") { _ in
            .ok(Stubs.volcengineSearchEnvelope(items: 3, snippetCharacters: 80))
        }
        let service = makeWebSearchToolService(.agentPlan, options: [
            VolcengineSearchOptions.Key.queryRewrite: "true",
            VolcengineSearchOptions.Key.authoritativeOnly: "true",
            VolcengineSearchOptions.Key.dataProEnabled: "true",
            VolcengineSearchOptions.Key.dataProServerID: UUID().uuidString
        ])
        let tool = WebSearchTool(service: service)
        _ = try await tool.execute(
            try decodeArguments(#"{"query":"专业数据集 检索","domains":["example.org"],"recencyDays":7}"#),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )

        let sent = try XCTUnwrap(MockURLProtocol.state.captured.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://open.feedcoopapi.com/search_api/web_search")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer bounded-default-key")
        let body = try requestBody(of: sent)
        XCTAssertEqual(Set(body.keys), ["Query", "SearchType", "Count", "Filter", "QueryControl", "TimeRange"])
        XCTAssertEqual(body["Query"] as? String, "专业数据集 检索")
        XCTAssertEqual(body["Count"] as? Int, WebSearchTool.defaultMaxResults)
        XCTAssertEqual(body["TimeRange"] as? String, "OneWeek")
        let filter = try XCTUnwrap(body["Filter"] as? [String: Any])
        XCTAssertEqual(Set(filter.keys), ["AuthInfoLevel", "NeedContent", "NeedUrl", "Sites"])
        XCTAssertEqual(filter["AuthInfoLevel"] as? Int, 1)
        XCTAssertEqual(filter["NeedContent"] as? Bool, false)
        XCTAssertEqual(filter["NeedUrl"] as? Bool, true)
        XCTAssertEqual(filter["Sites"] as? String, "example.org")
        let control = try XCTUnwrap(body["QueryControl"] as? [String: Any])
        XCTAssertEqual(control["QueryRewrite"] as? Bool, true)
        // DataPro stays app-level MCP wiring: never serialized into the
        // web_search envelope.
        let serialized = String(decoding: try XCTUnwrap(Self.bodyData(of: sent)), as: UTF8.self)
        XCTAssertFalse(serialized.contains("ataPro"))
        XCTAssertFalse(serialized.contains("ServerID"))
    }

    /// One gateway row whose Snippet exceeds the parser ceiling still
    /// reaches the assistant as a valid bounded JSON page that keeps the
    /// exact citation and a large useful excerpt.
    func testVolcengineHugeSingleItemToolOutputStaysBoundedValidJSON() async throws {
        MockURLProtocol.state.stub(host: "open.feedcoopapi.com") { _ in
            .ok(Stubs.volcengineSearchEnvelope(items: 1, snippetCharacters: 12_000))
        }
        let tool = WebSearchTool(service: makeWebSearchToolService(.agentPlan))
        let output = try await tool.execute(
            try decodeArguments(#"{"query":"巨型单条"}"#),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        XCTAssertLessThanOrEqual(output.summary.count, 4_096)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any]
        )
        let entries = try XCTUnwrap(object["results"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(object["available"] as? Int, 1)
        XCTAssertEqual(object["returned"] as? Int, 1)
        XCTAssertEqual(object["omittedResults"] as? Int, 0)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["url"] as? String, "https://example.com/volc/0")
        // The parser caps the 12_000-character Snippet at its existing
        // 4_000 ceiling; the tool then sizes it to the payload room.
        XCTAssertEqual(entry["originalSnippetChars"] as? Int, 4_000)
        let snippet = try XCTUnwrap(entry["snippet"] as? String)
        XCTAssertGreaterThanOrEqual(snippet.count, 1_000)
        XCTAssertEqual(entry["snippetTruncated"] as? Bool, true)
        XCTAssertEqual(object["truncated"] as? Bool, true)
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

    static func volcengineDirectBody(
        title: String,
        url: String,
        snippet: String,
        publishTime: String? = nil,
        siteName: String? = nil,
        logoURL: String? = nil
    ) -> Data {
        var item: [String: Any] = [
            "Title": title, "Url": url, "Snippet": snippet, "Id": "1", "SortId": 1
        ]
        if let publishTime { item["PublishTime"] = publishTime }
        if let siteName { item["SiteName"] = siteName }
        if let logoURL { item["LogoUrl"] = logoURL }
        return try! JSONSerialization.data(withJSONObject: ["results": [item]])
    }

    static func volcengineArkBody(
        answer: String,
        citations: [(title: String, url: String, summary: String,
                     siteName: String, publishTime: String)]
    ) -> Data {
        let annotations = citations.map { citation -> [String: Any] in
            [
                "type": "url_citation",
                "title": citation.title,
                "url": citation.url,
                "summary": citation.summary,
                "site_name": citation.siteName,
                "publish_time": citation.publishTime
            ]
        }
        let payload: [String: Any] = [
            "object": "response",
            "status": "completed",
            "output": [[
                "type": "message",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": answer,
                    "annotations": annotations
                ]]
            ]]
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    static func volcengineArkAnswerOnlyBody(_ answer: String) -> Data {
        let payload: [String: Any] = [
            "object": "response",
            "status": "completed",
            "output": [[
                "type": "message",
                "content": [["type": "output_text", "text": answer, "annotations": []]]
            ]]
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    static func volcengineArkStatusBody(_ status: String, reason: String? = nil) -> Data {
        var payload: [String: Any] = ["object": "response", "status": status]
        if let reason {
            payload["incomplete_details"] = ["reason": reason]
        }
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    /// The exact documented Doubao/Agent Plan gateway envelope with an
    /// arbitrary number of PascalCase WebItems, so fixtures can reproduce a
    /// server that overreturns MORE rows than the request's Count asked for,
    /// or paragraph-length Snippets per row.
    static func volcengineSearchEnvelope(
        items: Int,
        snippetCharacters: Int,
        resultCount: Int? = nil,
        start: Int = 0
    ) -> Data {
        let webResults: [[String: Any]] = (start..<start + max(0, items)).map { index in
            [
                "Id": "over-\(index)",
                "SortId": index,
                "Title": "量子突破 第\(index)篇",
                "SiteName": "站点\(index)",
                "Url": "https://example.com/volc/\(index)",
                "Snippet": String(repeating: "研", count: snippetCharacters),
                "Summary": "",
                "PublishTime": "2026-10-2\(index % 9)T10:00:00+08:00",
                "LogoUrl": "",
                "RankScore": 0.5
            ]
        }
        return try! JSONSerialization.data(withJSONObject: [
            "ResponseMetadata": ["RequestId": "BOUNDED-TEST-\(items)"],
            "Result": [
                "ResultCount": resultCount ?? items,
                "WebResults": webResults
            ]
        ])
    }
}
