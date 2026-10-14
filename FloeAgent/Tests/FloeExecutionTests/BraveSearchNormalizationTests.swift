// FloeExecutionTests — Brave search normalization and the real tool-summary
// boundary.
//
// All provider responses are synthetic, official-shaped fixtures served by a
// URLProtocol stub: no network, no credentials, no paid run. The final tests
// drive the actual WebSearchService -> WebSearchTool -> ToolResult path and
// prove the emitted JSON survives the runtime's 4096-character prefix intact.

import Foundation
import Testing
import FloeModels
import FloeTools
@testable import FloeExecution

private final class BraveStubURLProtocol: URLProtocol {
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

private let fixtureAPIKey = "fixture-brave-key"

private func braveProvider() -> WebSearchProviderConfiguration {
    WebSearchProviderConfiguration(
        kind: .brave,
        displayName: "Brave",
        credentialAccount: "test-brave",
        enabled: true,
        priority: 0
    )
}

private func makeBraveService() -> WebSearchService {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BraveStubURLProtocol.self]
    return WebSearchService(
        configuration: configuration,
        configurations: { [(braveProvider(), WebSearchCredential(values: ["apiKey": fixtureAPIKey]))] },
        validateDestination: { _, _ in }
    )
}

private func context() -> ToolContext {
    ToolContext(runID: UUID(), cancellation: CancellationToken())
}

private func queryText(_ request: URLRequest) -> [URLQueryItem] {
    guard let url = request.url,
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
    return components.queryItems ?? []
}

/// One official-shaped Brave web result with every documented field.
private func braveResultJSON(
    title: String,
    url: String,
    description: String,
    extraSnippets: [String] = [],
    includeDates: Bool = true
) -> [String: Any] {
    var result: [String: Any] = [
        "title": title,
        "url": url,
        "description": description,
        "language": "en",
        "family_friendly": true,
        "profile": [
            "name": "example.com",
            "long_name": "Example Blog",
            "url": "https://example.com",
            "img": "https://example.com/icon.png"
        ],
        "meta_url": [
            "scheme": "https",
            "netloc": "example.com",
            "hostname": "example.com",
            "favicon": "https://example.com/favicon.ico",
            "path": "posts/1"
        ]
    ]
    if !extraSnippets.isEmpty { result["extra_snippets"] = extraSnippets }
    if includeDates {
        result["age"] = "2 days ago"
        result["page_age"] = "2026-10-01T00:00:00"
        result["page_fetched"] = "2026-10-05T00:00:00"
    }
    return result
}

private func braveBody(_ results: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["web": ["results": results]])
}

@Suite("FloeExecution.BraveSearchNormalization", .serialized)
struct BraveSearchNormalizationTests {

    // MARK: - Request mapping

    @Test func braveFreshnessMappingIsDocumentedAndDeterministic() {
        let now = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!
        #expect(FloeExecution.WebSearchService.braveFreshness(days: nil, now: now) == nil)
        #expect(FloeExecution.WebSearchService.braveFreshness(days: 1, now: now) == "pd")
        #expect(FloeExecution.WebSearchService.braveFreshness(days: 2, now: now) == "pw")
        #expect(FloeExecution.WebSearchService.braveFreshness(days: 7, now: now) == "pw")
        #expect(FloeExecution.WebSearchService.braveFreshness(days: 8, now: now) == "pm")
        #expect(FloeExecution.WebSearchService.braveFreshness(days: 31, now: now) == "pm")
        #expect(FloeExecution.WebSearchService.braveFreshness(days: 32, now: now) == "py")
        #expect(FloeExecution.WebSearchService.braveFreshness(days: 365, now: now) == "py")
        #expect(
            FloeExecution.WebSearchService.braveFreshness(days: 366, now: now)
                == "2025-10-14to2026-10-14"
        )
        #expect(
            FloeExecution.WebSearchService.braveFreshness(days: 400, now: now)
                == "2025-09-10to2026-10-14"
        )
    }

    @Test func braveRequestCarriesOnlyDocumentedParameters() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-14T12:00:00Z")!
        let request = try FloeExecution.WebSearchService.makeRequest(
            braveProvider(),
            credential: WebSearchCredential(values: ["apiKey": fixtureAPIKey]),
            query: WebSearchQuery(text: "latest model news", recencyDays: 7, maxResults: 40),
            now: now
        )
        let items = queryText(request)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        #expect(request.url?.host == "api.search.brave.com")
        #expect(request.url?.path == "/res/v1/web/search")
        #expect(value("q") == "latest model news")
        #expect(value("count") == "20")
        #expect(value("freshness") == "pw")
        #expect(value("extra_snippets") == "true")
        #expect(value("include_fetch_metadata") == "true")
        #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == fixtureAPIKey)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!(request.url?.absoluteString.contains("pd7d") ?? false))

        // No recency: no freshness parameter at all (rather than an invalid one).
        let noRecency = try FloeExecution.WebSearchService.makeRequest(
            braveProvider(),
            credential: WebSearchCredential(values: ["apiKey": fixtureAPIKey]),
            query: WebSearchQuery(text: "plain"),
            now: now
        )
        #expect(!queryText(noRecency).contains { $0.name == "freshness" })
    }

    // MARK: - Parse

    @Test func officialShapedFixtureNormalizesFieldsWithoutMislabelingDates() throws {
        let body = braveBody([
            braveResultJSON(
                title: "Example release",
                url: "https://example.com/posts/1",
                description: "Main snippet text",
                extraSnippets: ["First additional excerpt", "Second additional excerpt"]
            )
        ])
        let results = try FloeExecution.WebSearchService.parse(body, provider: .brave, limit: 10)
        let result = try #require(results.first)
        #expect(results.count == 1)
        #expect(result.provider == .brave)
        #expect(result.snippet == "Main snippet text")
        #expect(result.extraSnippets == ["First additional excerpt", "Second additional excerpt"])
        #expect(result.pageAge == "2026-10-01T00:00:00")
        #expect(result.relativeAge == "2 days ago")
        #expect(result.pageFetched == "2026-10-05T00:00:00")
        #expect(result.sourceName == "Example Blog")
        #expect(result.sourceProfileName == "Example Blog")
        #expect(result.sourceProfileURL == "https://example.com")
        #expect(result.faviconURL == "https://example.com/favicon.ico")
        #expect(result.displayPath == "posts/1")
        // page_age means published OR modified: it must never be relabeled.
        #expect(result.publishedAt == nil)
        #expect(result.effectiveContentState == .searchMetadataOnly)
        #expect(result.citationID.count == 12)

        // The citation is deterministic for the provider+URL pair.
        let again = try FloeExecution.WebSearchService.parse(body, provider: .brave, limit: 10)
        #expect(again.first?.citationID == result.citationID)
    }

    @Test func titleOnlyResultFabricatesNothing() throws {
        let body = braveBody([
            ["title": "Bare title", "url": "https://example.com/bare"]
        ])
        let results = try FloeExecution.WebSearchService.parse(body, provider: .brave, limit: 10)
        let result = try #require(results.first)
        #expect(result.snippet.isEmpty)
        #expect(result.extraSnippets == nil)
        #expect(result.pageAge == nil)
        #expect(result.relativeAge == nil)
        #expect(result.pageFetched == nil)
        #expect(result.sourceName == nil)
        #expect(result.publishedAt == nil)
    }

    @Test func emptyAndMissingResultSetsAreDistinctFromTransportFailure() throws {
        #expect(
            try FloeExecution.WebSearchService.parse(
                braveBody([]), provider: .brave, limit: 10
            ).isEmpty
        )
        #expect(
            try FloeExecution.WebSearchService.parse(
                Data(#"{"query":{"original":"x"}}"#.utf8), provider: .brave, limit: 10
            ).isEmpty
        )
        #expect(throws: (any Error).self) {
            _ = try FloeExecution.WebSearchService.parse(Data("not json".utf8), provider: .brave, limit: 10)
        }
    }

    // MARK: - Service -> tool -> ToolResult boundary

    private func toolOutput(_ body: Data) async throws -> ToolExecutionOutput {
        BraveStubURLProtocol.reset()
        BraveStubURLProtocol.handler = { _ in (200, body) }
        let service = makeBraveService()
        let tool = WebSearchTool(service: service)
        return try await tool.execute(
            WebSearchTool.Arguments(query: "latest model news", mode: "fast"),
            context: context()
        )
    }

    /// Mirrors the runtime's else-branch for non-enumerated tools: no
    /// JSON-aware marker, a hard 4096-character prefix.
    private func runtimeToolResult(_ output: ToolExecutionOutput) -> ToolResult {
        ToolResult(
            callID: "call-1",
            status: .ok,
            outputSummary: output.summary,
            outputDigest: output.fullOutputSHA256,
            exitStatus: output.exitStatus
        )
    }

    @Test func longUnicodeSnippetsSurviveTheToolResultBoundaryWithHonestTruncation() async throws {
        let cjk = String(repeating: "长", count: 4_000)
        let extra = String(repeating: "补", count: 500)
        let results = (0..<5).map { index in
            braveResultJSON(
                title: "Release \(index)",
                url: "https://example.com/posts/\(index)",
                description: cjk,
                extraSnippets: Array(repeating: extra, count: 5)
            )
        }
        let output = try await toolOutput(braveBody(results))
        let result = runtimeToolResult(output)

        // The runtime prefix must not cut anything: our payload already fits.
        #expect(result.outputSummary == output.summary)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.outputSummary.utf8)) as? [String: Any]
        )
        #expect(object["truncated"] as? Bool == true)
        #expect(object["returned"] as? Int == 5)
        #expect(object["available"] as? Int == 5)
        #expect(object["evidenceState"] as? String == "searchMetadataOnly")
        let entries = try #require(object["results"] as? [[String: Any]])
        #expect(entries.count == 5)
        // Citations and URLs survive even when snippets are shortened.
        for (index, entry) in entries.enumerated() {
            #expect(entry["url"] as? String == "https://example.com/posts/\(index)")
            let citation = entry["citation"] as? String ?? ""
            #expect(citation.count == 12)
            #expect(entry["snippetTruncated"] as? Bool == true)
            #expect((entry["originalSnippetChars"] as? Int) == 4_000)
            #expect(entry["contentState"] as? String == "searchMetadataOnly")
        }
    }

    @Test func normalFiveResultsAreCompleteAndCitationsPreserved() async throws {
        let expected = (0..<5).map { index in
            braveResultJSON(
                title: "Release \(index)",
                url: "https://example.com/posts/\(index)",
                description: "Short snippet \(index)",
                extraSnippets: ["extra a \(index)", "extra b \(index)"]
            )
        }
        let body = braveBody(expected)
        BraveStubURLProtocol.reset()
        BraveStubURLProtocol.handler = { _ in (200, body) }
        let service = makeBraveService()
        let response = try await service.search(WebSearchQuery(text: "latest model news", mode: .fast))
        let output = try WebSearchTool.output(response)
        let result = runtimeToolResult(output)
        #expect(result.outputSummary == output.summary)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.outputSummary.utf8)) as? [String: Any]
        )
        #expect(object["returned"] as? Int == 5)
        #expect(object["truncated"] as? Bool == false)
        #expect(object["omittedResults"] as? Int == 0)
        let entries = try #require(object["results"] as? [[String: Any]])
        let citations: [String?] = entries.map { $0["citation"] as? String }
        #expect(citations == response.results.map(\.citationID))
        #expect((entries.first?["pageAge"] as? String) == "2026-10-01T00:00:00")
        #expect((entries.first?["publishedAt"] as? String) == "")
        #expect((entries.first?["source"] as? String) == "Example Blog")
        #expect((entries.first?["pageFetched"] as? String) == "2026-10-05T00:00:00")
        #expect((entries.first?["displayPath"] as? String) == "posts/1")
    }

    @Test func emptyProviderResultIsAnHonestFailureNotFabricatedData() async {
        BraveStubURLProtocol.reset()
        BraveStubURLProtocol.handler = { _ in (200, braveBody([])) }
        let service = makeBraveService()
        await #expect(throws: WebRetrievalError.self) {
            _ = try await service.search(WebSearchQuery(text: "nothing", mode: .fast))
        }
    }

    // MARK: - Bounded producer regressions (long URL / escape-heavy query / huge failures)

    /// A citation target that cannot be returned exactly (over the 1024
    /// character cap) must be OMITTED explicitly: returning a shortened URL
    /// would silently retarget the citation. The other rows keep exact URLs.
    @Test func oversizeCitationURLIsOmittedInsteadOfReturnedChanged() async throws {
        let longURL = "https://example.com/" + String(repeating: "segment/", count: 250) + "end"
        #expect(longURL.count > WebSearchTool.maximumCitationURLLength)
        let output = try await toolOutput(braveBody([
            braveResultJSON(title: "Oversize", url: longURL, description: "omitted row"),
            braveResultJSON(title: "Kept A", url: "https://example.com/keep-a", description: "short a"),
            braveResultJSON(title: "Kept B", url: "https://example.com/keep-b", description: "short b")
        ]))
        let result = runtimeToolResult(output)
        // The runtime's hard 4096-character prefix must not cut anything.
        #expect(result.outputSummary == output.summary)
        #expect(result.outputSummary.count <= 4_096)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.outputSummary.utf8)) as? [String: Any]
        )
        #expect(object["truncated"] as? Bool == true)
        #expect(object["available"] as? Int == 3)
        #expect(object["returned"] as? Int == 2)
        #expect(object["omittedResults"] as? Int == 1)
        #expect(object["omittedOversizeURLRows"] as? Int == 1)
        let entries = try #require(object["results"] as? [[String: Any]])
        let urls = entries.compactMap { $0["url"] as? String }
        #expect(urls == ["https://example.com/keep-a", "https://example.com/keep-b"])
        #expect(!urls.contains(longURL), "an oversize URL row must be omitted, never shortened")
    }

    /// A valid 1-2000-byte query full of quotes, backslashes and control
    /// characters inflates ~4x when JSON-escaped. The payload (query text,
    /// snippets, metadata note) must be bounded by the SERIALIZED length so
    /// the runtime prefix still receives complete valid JSON.
    @Test func escapeHeavyQueryStaysValidJSONUnderTheRuntimePrefix() async throws {
        let query = "a" + String(repeating: "\u{01}\\\"\n", count: 495) + "z"
        #expect(query.utf8.count <= 2_000)
        BraveStubURLProtocol.reset()
        BraveStubURLProtocol.handler = { _ in (200, braveBody([
            braveResultJSON(title: "Kept", url: "https://example.com/kept", description: "short")
        ])) }
        let service = makeBraveService()
        let output = try await WebSearchTool(service: service).execute(
            WebSearchTool.Arguments(query: query, mode: "fast"),
            context: context()
        )
        let result = runtimeToolResult(output)
        #expect(result.outputSummary == output.summary)
        #expect(result.outputSummary.count <= 4_096)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.outputSummary.utf8)) as? [String: Any]
        )
        #expect(object["queryTruncated"] as? Bool == true)
        #expect((object["originalQueryChars"] as? Int) == query.count)
        // The row and its exact citation target survive the query bounding.
        let entries = try #require(object["results"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries.first?["url"] as? String == "https://example.com/kept")
        #expect(object["truncated"] as? Bool == true)
    }

    /// Provider failures can be arbitrarily large. With zero results AND an
    /// escape-heavy query there is no row to drop, so the top-level metadata
    /// itself must be bounded with explicit markers — never cut JSON.
    @Test func escapeHeavyQueryPlusHugeProviderFailuresStayValidJSON() async throws {
        let query = "a" + String(repeating: "\u{01}\\\"\n", count: 495) + "z"
        let huge = String(repeating: "provider exploded: ", count: 1_200)
        let response = WebSearchResponse(
            query: query,
            results: [],
            providersUsed: [],
            failures: (0..<12).map { "brave: \($0) \(huge)" }
        )
        let output = try WebSearchTool.output(response)
        let result = runtimeToolResult(output)
        #expect(result.outputSummary == output.summary)
        #expect(result.outputSummary.count <= 4_096)

        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(result.outputSummary.utf8)) as? [String: Any]
        )
        #expect(object["returned"] as? Int == 0)
        #expect(object["truncated"] as? Bool == true)
        #expect(object["queryTruncated"] as? Bool == true)
        #expect(object["failuresTruncated"] as? Bool == true)
        // The bounded error state stays visible, not an empty success.
        let failures = object["failures"] as? [String] ?? []
        #expect(!failures.isEmpty)
        #expect(failures.allSatisfy { $0.count <= 512 })

        // The fallback is also bounded: a pathological budget that cannot fit
        // even one row must produce a valid explicit error page, not cut JSON.
        let forced = try WebSearchTool.output(response, maximumCharacters: 600)
        #expect(forced.summary.count <= 600)
        let fallback = try #require(
            try JSONSerialization.jsonObject(with: Data(forced.summary.utf8)) as? [String: Any]
        )
        #expect(fallback["error"] as? String == "resultExceedsBudget")
        #expect(fallback["truncated"] as? Bool == true)
        #expect(fallback["available"] as? Int == 0)
    }

    /// Source/date/profile field shortening must be reflected in the
    /// top-level `truncated` flag as well as the per-row `fieldsTruncated`
    /// list — the flag used to be refreshed before the later fields ran.
    @Test func profileAndDateTruncationIsReflectedInTheTopLevelFlag() async throws {
        let response = WebSearchResponse(
            query: "profile flags",
            results: [
                WebSearchResult(
                    title: "Kept",
                    url: URL(string: "https://example.com/kept")!,
                    snippet: "short",
                    provider: .brave,
                    citationID: "cit-profile-1",
                    pageAge: String(repeating: "p", count: 100),
                    sourceProfileName: String(repeating: "s", count: 400),
                    sourceProfileURL: "https://example.com/" + String(repeating: "p", count: 300)
                )
            ],
            providersUsed: [.brave]
        )
        let output = try WebSearchTool.output(response)
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any]
        )
        #expect(object["truncated"] as? Bool == true)
        let entries = try #require(object["results"] as? [[String: Any]])
        let fields = entries.first?["fieldsTruncated"] as? [String] ?? []
        #expect(fields.contains("sourceProfile"))
        #expect(fields.contains("sourceProfileURL"))
        #expect(fields.contains("pageAge"))
        // The citation target itself is still exact.
        #expect(entries.first?["url"] as? String == "https://example.com/kept")
    }
}
