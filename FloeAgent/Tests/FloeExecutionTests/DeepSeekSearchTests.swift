// FloeExecutionTests — DeepSeek Search adapter and complete tool capture.
//
// All provider responses are synthetic, official-shaped fixtures served by a
// URLProtocol stub: no network, no credentials, no paid run. These tests pin
// the documented request/response contract, the final-query scalar bound,
// honest auth/quota/invalid/empty classification, explicit-provider isolation
// and the separation between the bounded UI projection and the complete
// normalized tool capture.

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

private final class DeepSeekStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var captured: [URLRequest] = []

    static func reset() {
        handler = nil
        captured = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captured.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("FloeExecution.DeepSeekSearch", .serialized)
struct DeepSeekSearchTests {
    private static let fixedNow = Date(timeIntervalSince1970: 1_793_361_600) // 2026-10-30T12:00:00Z

    private func provider(
        options: [String: String] = [:],
        endpoint: URL? = nil
    ) -> WebSearchProviderConfiguration {
        WebSearchProviderConfiguration(
            kind: .deepseek,
            displayName: "DeepSeek Search",
            endpoint: endpoint,
            credentialAccount: "test-deepseek",
            enabled: true,
            options: options
        )
    }

    private func bochaProvider() -> WebSearchProviderConfiguration {
        WebSearchProviderConfiguration(
            kind: .bochaWeb,
            displayName: "Bocha Search",
            credentialAccount: "test-bocha",
            enabled: true,
            priority: 1
        )
    }

    private func makeService(
        _ providers: [(WebSearchProviderConfiguration, WebSearchCredential)]
    ) -> WebSearchService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepSeekStubURLProtocol.self]
        return WebSearchService(
            configuration: configuration,
            configurations: { providers },
            validateDestination: { _, _ in }
        )
    }

    private func toolContext() -> ToolContext {
        ToolContext(runID: UUID(), cancellation: CancellationToken())
    }

    private func bodyObject(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            var collected = Data()
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(contentsOf: buffer.prefix(read))
            }
            data = collected
        } else {
            return [:]
        }
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func officialBody(
        rows: [(title: String, url: String, snippet: String, summary: String, content: String)]
    ) throws -> Data {
        let results: [[String: Any]] = rows.enumerated().map { index, row in
            [
                "rerank_score": 2.4,
                "title": row.title,
                "url": row.url,
                "snippet": row.snippet,
                "summary": row.summary,
                "content": row.content,
                "site_name": "Example \(index + 1)",
                "site_icon": "https://example.com/icon-\(index + 1).png",
                "date": "2026-10-30T00:00:00+00:00",
                "authority": 3
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["results": results])
    }

    // MARK: - Request contract

    @Test("Official request carries only query, count and need_content")
    func officialRequestContract() throws {
        let request = try WebSearchService.makeRequest(
            provider(options: [DeepSeekSearchOptions.Key.needContent: "true"]),
            credential: WebSearchCredential(values: ["apiKey": "fixture-key"]),
            query: WebSearchQuery(
                text: "DeepSeek V4",
                domains: ["github.com", "huggingface.co"],
                excludedDomains: ["example.com"],
                recencyDays: 7,
                maxResults: 7
            ),
            now: Self.fixedNow
        )
        #expect(request.url?.absoluteString == "https://api.deepseek.com/v1/tools/search")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        let body = try bodyObject(request)
        #expect(body["query"] as? String
            == "DeepSeek V4 site:github.com OR site:huggingface.co -site:example.com after:2026-10-24")
        #expect(body["count"] as? Int == 7)
        #expect(body["need_content"] as? Bool == true)
        // The entire chat, user IP and localization are never sent.
        #expect(body["ori_question"] == nil)
        #expect(body["localization"] == nil)
        #expect(Set(body.keys) == ["query", "count", "need_content"])
    }

    @Test("Omitted need_content stays false and the tool default count is five")
    func omittedDefaults() async throws {
        DeepSeekStubURLProtocol.reset()
        DeepSeekStubURLProtocol.handler = { _ in
            (200, try! JSONSerialization.data(withJSONObject: [
                "results": [[
                    "rerank_score": 1.0,
                    "title": "Result",
                    "url": "https://example.com/result",
                    "snippet": "short",
                    "summary": "long",
                    "content": "",
                    "site_name": NSNull(),
                    "site_icon": NSNull(),
                    "date": NSNull(),
                    "authority": -1
                ]]
            ]))
        }
        let tool = WebSearchTool(service: makeService([
            (provider(), WebSearchCredential(values: ["apiKey": "k"]))
        ]))
        _ = try await tool.execute(
            WebSearchTool.Arguments(query: "DeepSeek"),
            context: toolContext()
        )
        let sent = try #require(DeepSeekStubURLProtocol.captured.first)
        let body = try bodyObject(sent)
        #expect(body["count"] as? Int == WebSearchTool.defaultMaxResults)
        #expect(WebSearchTool.defaultMaxResults == 5)
        #expect(body["need_content"] as? Bool == false)
    }

    @Test("Final query is validated as 1...128 Unicode scalars, never truncated")
    func finalQueryScalarBound() throws {
        let exactly128 = String(repeating: "a", count: 128)
        let accepted = try WebSearchService.makeRequest(
            provider(),
            credential: WebSearchCredential(values: ["apiKey": "k"]),
            query: WebSearchQuery(text: exactly128, maxResults: 5)
        )
        #expect(try bodyObject(accepted)["query"] as? String == exactly128)

        let over = WebSearchQuery(text: String(repeating: "a", count: 129), maxResults: 5)
        Self.expectInvalidResponse {
            _ = try WebSearchService.makeRequest(
                provider(),
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: over
            )
        }

        // Filters count toward the same final-query bound: a 128-scalar query
        // plus site syntax is rejected instead of being shortened.
        Self.expectInvalidResponse {
            _ = try WebSearchService.makeRequest(
                provider(),
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(
                    text: exactly128,
                    domains: ["example.com"],
                    maxResults: 5
                )
            )
        }

        // The official limit is Unicode scalars, not grapheme clusters: 65
        // Australian flag sequences are 65 Characters but 130 scalars.
        Self.expectInvalidResponse {
            _ = try WebSearchService.makeRequest(
                provider(),
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(
                    text: String(repeating: "🇦🇺", count: 65),
                    maxResults: 5
                )
            )
        }
    }

    @Test("Domain values cannot inject extra search operators")
    func domainValidation() {
        Self.expectInvalidResponse {
            _ = try WebSearchService.makeRequest(
                self.provider(),
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(text: "q", domains: ["example.com -site:evil.com"])
            )
        }
        Self.expectInvalidResponse {
            _ = try WebSearchService.makeRequest(
                self.provider(),
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(text: "q", excludedDomains: ["bad/domain"])
            )
        }
    }

    @Test("Invalid need_content option rejects instead of silently defaulting")
    func invalidNeedContent() {
        Self.expectInvalidResponse {
            _ = try WebSearchService.makeRequest(
                self.provider(options: [DeepSeekSearchOptions.Key.needContent: "yes"]),
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(text: "q")
            )
        }
    }

    // MARK: - Response mapping

    @Test("Official fields map to typed normalized result values")
    func officialFieldMapping() throws {
        let longSummary = String(repeating: "长摘要", count: 1_000)
        let longContent = String(repeating: "正文", count: 2_000)
        let body = try officialBody(rows: [(
            title: "DeepSeek V4 发布",
            url: "https://example.com/deepseek-v4",
            snippet: "短摘要：支持工具调用与长上下文。",
            summary: longSummary,
            content: longContent
        )])
        let results = try WebSearchService.parse(body, provider: .deepseek, limit: 10)
        let result = try #require(results.first)
        #expect(result.title == "DeepSeek V4 发布")
        #expect(result.url.absoluteString == "https://example.com/deepseek-v4")
        #expect(result.snippet == "短摘要：支持工具调用与长上下文。")
        #expect(result.summary == longSummary)
        #expect(result.content == longContent)
        #expect(result.sourceName == "Example 1")
        #expect(result.faviconURL == "https://example.com/icon-1.png")
        #expect(result.publishedAt == "2026-10-30T00:00:00+00:00")
        #expect(result.score == 2.4)
        #expect(result.authority == 3)
        #expect(result.provider == .deepseek)
        #expect(result.citationID.count == 12)
        #expect(result.effectiveContentState == .searchMetadataOnly)
    }

    @Test("Missing or wrong-typed results are invalid; empty results are honest")
    func responseEnvelopeClassification() throws {
        Self.expectInvalidResponse {
            _ = try WebSearchService.parse(
                Data(#"{"unexpected":true}"#.utf8),
                provider: .deepseek,
                limit: 5
            )
        }
        Self.expectInvalidResponse {
            _ = try WebSearchService.parse(
                Data(#"{"results":{"title":"not-an-array"}}"#.utf8),
                provider: .deepseek,
                limit: 5
            )
        }
        Self.expectInvalidResponse {
            _ = try WebSearchService.parse(
                Data(#"{"error":{"message":"invalid query","type":"invalid_request_error","param":null,"code":"invalid_request_error"}}"#.utf8),
                provider: .deepseek,
                limit: 5
            )
        }
        let empty = try WebSearchService.parse(
            Data(#"{"results":[]}"#.utf8),
            provider: .deepseek,
            limit: 5
        )
        #expect(empty.isEmpty)
    }

    @Test("Auth, quota and invalid responses are classified honestly")
    func errorClassification() throws {
        #expect(
            WebSearchService.deepSeekFailure(status: 401, data: Data())
                == "deepseek: authentication failed (HTTP 401)"
        )
        #expect(
            WebSearchService.deepSeekFailure(status: 402, data: Data())
                == "deepseek: insufficient balance (HTTP 402)"
        )
        #expect(
            WebSearchService.deepSeekFailure(status: 413, data: Data())
                == "deepseek: request too large (HTTP 413)"
        )
        #expect(
            WebSearchService.deepSeekFailure(status: 429, data: Data())
                == "deepseek: rate limit exceeded (HTTP 429)"
        )
        #expect(
            WebSearchService.deepSeekFailure(status: 503, data: Data())
                == "deepseek: service unavailable (HTTP 503)"
        )
        let invalid = try JSONSerialization.data(withJSONObject: [
            "error": [
                "message": "'count' must be between 1 and 50",
                "type": "invalid_request_error",
                "param": NSNull(),
                "code": "invalid_request_error"
            ]
        ])
        let message = WebSearchService.deepSeekFailure(status: 400, data: invalid)
        #expect(message.hasPrefix("deepseek: invalid request (HTTP 400)"))
        #expect(message.contains("count"))
    }

    // MARK: - Service and tool path

    @Test("Explicit DeepSeek selection never falls back to another provider")
    func explicitProviderIsolation() async throws {
        DeepSeekStubURLProtocol.reset()
        DeepSeekStubURLProtocol.handler = { request in
            if request.url?.host == "api.deepseek.com" {
                return (401, Data(#"{"error":{"message":"Authentication Fails"}}"#.utf8))
            }
            return (200, try! JSONSerialization.data(withJSONObject: [
                "web": ["results": [[
                    "title": "must not be used",
                    "url": "https://example.com/fallback",
                    "description": "fallback"
                ]]]
            ]))
        }
        let service = makeService([
            (provider(), WebSearchCredential(values: ["apiKey": "bad-key"])),
            (bochaProvider(), WebSearchCredential(values: ["apiKey": "bocha-key"]))
        ])
        do {
            _ = try await service.search(WebSearchQuery(
                text: "DeepSeek",
                mode: .balanced,
                maxResults: 5,
                requestedProvider: "deepseek"
            ))
            Issue.record("expected the explicit provider to fail")
        } catch let WebRetrievalError.allProvidersFailed(failures) {
            #expect(failures.count == 1)
            #expect(failures.first?.contains("authentication failed") == true)
        }
        #expect(
            Set(DeepSeekStubURLProtocol.captured.compactMap { $0.url?.host })
                == Set(["api.deepseek.com"])
        )
    }

    @Test("Empty search result is reported as no results, not a failure")
    func emptyResultTestSearch() async throws {
        DeepSeekStubURLProtocol.reset()
        DeepSeekStubURLProtocol.handler = { _ in (200, Data(#"{"results":[]}"#.utf8)) }
        let configuration = provider()
        let service = makeService([
            (configuration, WebSearchCredential(values: ["apiKey": "k"]))
        ])
        let outcome = await service.testSearch(
            configuration: configuration,
            credential: WebSearchCredential(values: ["apiKey": "k"]),
            text: "no matches",
            maxResults: 5
        )
        #expect(outcome.error == nil)
        #expect(outcome.results.isEmpty)
    }

    @Test("Tool path preserves full long text in the capture and bounds only the UI page")
    func toolCaptureKeepsLongTail() async throws {
        let snippet = String(repeating: "短摘要", count: 300)
        let summary = String(repeating: "长摘要", count: 1_500)
        let content = String(repeating: "正文", count: 3_000)
        let rows = (1...6).map { index in
            (
                title: "DeepSeek result \(index)",
                url: "https://example.com/deepseek/\(index)",
                snippet: snippet,
                summary: summary,
                content: content
            )
        }
        let body = try officialBody(rows: rows)
        DeepSeekStubURLProtocol.reset()
        DeepSeekStubURLProtocol.handler = { _ in (200, body) }
        let tool = WebSearchTool(service: makeService([
            (provider(), WebSearchCredential(values: ["apiKey": "k"]))
        ]))
        let output = try await tool.execute(
            WebSearchTool.Arguments(query: "DeepSeek", maxResults: 6),
            context: toolContext()
        )
        #expect(output.summary.count <= 4_096)
        _ = try JSONSerialization.jsonObject(with: Data(output.summary.utf8))

        let capture = try #require(output.capturedOutput)
        #expect(capture.count > output.summary.count)
        let captured = try #require(
            try JSONSerialization.jsonObject(with: Data(capture.utf8)) as? [String: Any]
        )
        let capturedRows = try #require(captured["results"] as? [[String: Any]])
        #expect(capturedRows.count == 6)
        let last = try #require(capturedRows.last)
        #expect(last["url"] as? String == rows[5].url)
        #expect(last["snippet"] as? String == snippet)
        #expect(last["summary"] as? String == summary)
        #expect(last["content"] as? String == content)
        #expect(output.fullOutputSHA256 == FloeDigest.sha256Hex(Data(capture.utf8)))
    }

    @Test("Canonical endpoint validation and tunnel policy match the documented host")
    func canonicalEndpointValidation() {
        let configuration = provider()
        #expect(
            WebSearchService.canonicalEndpoint(for: configuration)?.absoluteString
                == "https://api.deepseek.com/v1/tools/search"
        )
        let request = try? WebSearchService.makeRequest(
            configuration,
            credential: WebSearchCredential(values: ["apiKey": "k"]),
            query: WebSearchQuery(text: "q")
        )
        #expect(
            WebSearchService.requestURLIsCanonical(
                request?.url,
                configuration: configuration
            )
        )
        #expect(WebSearchService.allowsTransientTunnel(for: configuration))
        var overridden = configuration
        overridden.endpoint = URL(string: "https://example.com/search")
        #expect(WebSearchService.canonicalEndpoint(for: overridden) == nil)
        #expect(!WebSearchService.allowsTransientTunnel(for: overridden))
    }

    // MARK: - Helpers

    private static func expectInvalidResponse(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            Issue.record("expected invalidResponse", sourceLocation: sourceLocation)
        } catch let WebRetrievalError.invalidResponse(message) {
            #expect(!message.isEmpty)
        } catch {
            Issue.record(
                "expected invalidResponse, got \(error)",
                sourceLocation: sourceLocation
            )
        }
    }
}
