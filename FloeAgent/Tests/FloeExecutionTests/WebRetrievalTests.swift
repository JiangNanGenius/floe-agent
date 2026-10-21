import Foundation
import Testing
@testable import FloeExecution

@Suite("Web retrieval adapters")
struct WebRetrievalTests {
    @Test("Search readiness excludes disabled, empty-key and incomplete providers")
    func configuredSearchProviders() {
        var bocha = WebSearchProviderConfiguration(kind: .bochaWeb, displayName: "Bocha", credentialAccount: "test")
        #expect(!WebSearchService.isConfigured(bocha, credential: .init(values: [:])))
        #expect(!WebSearchService.isConfigured(bocha, credential: .init(values: ["apiKey": "  "])))
        #expect(WebSearchService.isConfigured(bocha, credential: .init(values: ["apiKey": "fixture"])))
        bocha.enabled = false
        #expect(!WebSearchService.isConfigured(bocha, credential: .init(values: ["apiKey": "fixture"])))
        let google = WebSearchProviderConfiguration(kind: .googleProgrammable, displayName: "Google", credentialAccount: "test")
        #expect(!WebSearchService.isConfigured(google, credential: .init(values: ["apiKey": "fixture"])))
        var searx = WebSearchProviderConfiguration(kind: .searxng, displayName: "SearXNG", credentialAccount: "test")
        #expect(!WebSearchService.isConfigured(searx, credential: .init(values: [:])))
        searx.endpoint = URL(string: "https://search.example.com/search")
        #expect(WebSearchService.isConfigured(searx, credential: .init(values: [:])))
    }

    @Test("Bocha request uses official endpoint and normalized freshness")
    func bochaRequest() throws {
        let configuration = WebSearchProviderConfiguration(
            kind: .bochaWeb, displayName: "Bocha", credentialAccount: "test"
        )
        let request = try WebSearchService.makeRequest(
            configuration,
            credential: WebSearchCredential(values: ["apiKey": "secret"]),
            query: WebSearchQuery(text: "Floe", recencyDays: 7, maxResults: 8)
        )
        #expect(request.url?.absoluteString == "https://api.bochaai.com/v1/web-search")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["freshness"] as? String == "oneWeek")
        #expect(object["count"] as? Int == 8)
        #expect(object["summary"] as? Bool == true)
        #expect(object["answer"] == nil)
        #expect(object["stream"] == nil)
    }

    @Test("Bocha summary can be disabled without changing endpoint or credential")
    func bochaSummaryToggle() throws {
        let configuration = WebSearchProviderConfiguration(
            kind: .bochaWeb,
            displayName: "Bocha Search",
            credentialAccount: "web-search.bochaWeb",
            options: ["summaryEnabled": "false"]
        )
        let request = try WebSearchService.makeRequest(
            configuration,
            credential: WebSearchCredential(values: ["apiKey": "shared-key"]),
            query: WebSearchQuery(text: "Floe")
        )
        #expect(request.url?.path == "/v1/web-search")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer shared-key")
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["summary"] as? Bool == false)
    }

    @Test("Bocha AI tool overrides provider setting while raw search stays separate")
    func bochaPerToolSummaryMode() throws {
        let configuration = WebSearchProviderConfiguration(
            kind: .bochaWeb,
            displayName: "Bocha Search",
            credentialAccount: "web-search.bochaWeb",
            options: ["summaryEnabled": "false"]
        )
        let request = try WebSearchService.makeRequest(
            configuration,
            credential: WebSearchCredential(values: ["apiKey": "shared-key"]),
            query: WebSearchQuery(text: "Floe", summaryEnabled: true)
        )
        let body = try #require(request.httpBody)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["summary"] as? Bool == true)
        #expect(BochaAISearchTool.name == "web.searchAI")
        #expect(BochaAISearchTool.toolEffect == .readOnly)
        #expect(!BochaAISearchTool.isSideEffecting)
    }

    @Test("Tencent WSA request is signed with current SearchPro contract")
    func tencentRequest() throws {
        let configuration = WebSearchProviderConfiguration(
            kind: .tencentWSA, displayName: "Tencent", credentialAccount: "test"
        )
        let request = try WebSearchService.makeRequest(
            configuration,
            credential: WebSearchCredential(values: ["secretId": "id", "secretKey": "key"]),
            query: WebSearchQuery(text: "test", maxResults: 12),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(request.value(forHTTPHeaderField: "X-TC-Action") == "SearchPro")
        #expect(request.value(forHTTPHeaderField: "X-TC-Version") == "2025-05-08")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("TC3-HMAC-SHA256") == true)
    }

    @Test("Bocha and Tencent response envelopes normalize to citations")
    func responseParsing() throws {
        let bocha = Data(#"{"data":{"webPages":{"value":[{"name":"Official","url":"https://example.com/a","summary":"Answer"}]}}}"#.utf8)
        let parsed = try WebSearchService.parse(bocha, provider: .bochaWeb, limit: 10)
        #expect(parsed.first?.title == "Official")
        #expect(parsed.first?.snippet == "Answer")

        let page = #"{"title":"Tencent","url":"https://example.com/b","snippet":"Result"}"#
        let tencent = try JSONSerialization.data(withJSONObject: ["Response": ["Pages": [page]]])
        let tencentParsed = try WebSearchService.parse(tencent, provider: .tencentWSA, limit: 10)
        #expect(tencentParsed.first?.title == "Tencent")
        #expect(tencentParsed.first?.citationID.isEmpty == false)
    }

    @Test("Search and fetch remain read-only tools")
    func readOnlyDescriptors() {
        #expect(WebSearchTool.toolEffect == .readOnly)
        #expect(BochaAISearchTool.toolEffect == .readOnly)
        #expect(WebFetchTool.toolEffect == .readOnly)
        #expect(!WebSearchTool.isSideEffecting)
        #expect(!WebFetchTool.isSideEffecting)
    }

    @Test("Self-hosted SearXNG can be configured without a credential")
    func credentialRequirements() {
        #expect(!WebSearchProviderKind.searxng.requiresCredential)
        #expect(WebSearchProviderKind.bochaWeb.requiresCredential)
        #expect(WebSearchProviderKind.tencentWSA.requiresCredential)
        #expect(WebSearchProviderKind.custom.requiresCredential)
    }
}

// MARK: - Volcengine account/interface contracts

private func volcengineConfiguration(
    _ interface: VolcengineSearchInterface?,
    options: [String: String] = [:],
    endpoint: URL? = nil
) -> WebSearchProviderConfiguration {
    var values = options
    if let interface {
        values[VolcengineSearchOptions.Key.interface] = interface.rawValue
    }
    return WebSearchProviderConfiguration(
        kind: .volcengine,
        displayName: "Volcengine",
        endpoint: endpoint,
        credentialAccount: "web-search.volcengine.test",
        enabled: true,
        options: values
    )
}

private func requestJSONBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Suite("Volcengine search contracts")
struct VolcengineSearchContractTests {
    @Test("Agent Plan request uses PascalCase contract and count ceiling")
    func agentPlanRequest() throws {
        let configuration = volcengineConfiguration(
            .agentPlan,
            options: [
                VolcengineSearchOptions.Key.queryRewrite: "true",
                VolcengineSearchOptions.Key.authoritativeOnly: "true"
            ]
        )
        let request = try WebSearchService.makeRequest(
            configuration,
            credential: WebSearchCredential(values: ["apiKey": "agent-plan-key"]),
            query: WebSearchQuery(
                text: "latest weather",
                domains: ["example.com", "news.example.org"],
                excludedDomains: ["spam.example"],
                recencyDays: 7,
                maxResults: 60
            ),
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(request.url?.absoluteString == "https://open.feedcoopapi.com/search_api/web_search")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer agent-plan-key")
        #expect(request.value(forHTTPHeaderField: "X-Traffic-Tag") == nil)
        let body = try requestJSONBody(request)
        #expect(body["Query"] as? String == "latest weather")
        #expect(body["SearchType"] as? String == "web")
        #expect(body["Count"] as? Int == 50)
        #expect(body["TimeRange"] as? String == "OneWeek")
        let filter = try #require(body["Filter"] as? [String: Any])
        #expect(filter["AuthInfoLevel"] as? Int == 1)
        #expect(filter["NeedContent"] as? Bool == false)
        #expect(filter["NeedUrl"] as? Bool == true)
        #expect(filter["Sites"] as? String == "example.com|news.example.org")
        #expect(filter["BlockHosts"] as? String == "spam.example")
        let control = try #require(body["QueryControl"] as? [String: Any])
        #expect(control["QueryRewrite"] as? Bool == true)
        #expect(WebSearchService.requestURLIsCanonical(request.url, configuration: configuration))
        #expect(WebSearchService.allowsTransientTunnel(for: configuration))
        #expect(WebSearchService.isConfigured(
            configuration,
            credential: WebSearchCredential(values: ["apiKey": "k"])
        ))
    }

    @Test("Doubao Search interface shares the HTTP contract with separate credentials")
    func doubaoSearchRequest() throws {
        let configuration = volcengineConfiguration(.doubaoSearch)
        let request = try WebSearchService.makeRequest(
            configuration,
            credential: WebSearchCredential(values: ["apiKey": "doubao-product-key"]),
            query: WebSearchQuery(text: "headline", maxResults: 11)
        )
        #expect(request.url?.absoluteString == "https://open.feedcoopapi.com/search_api/web_search")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer doubao-product-key")
        let body = try requestJSONBody(request)
        #expect(body["Count"] as? Int == 11)
        let filter = try #require(body["Filter"] as? [String: Any])
        #expect(filter["AuthInfoLevel"] as? Int == 0)
        let control = try #require(body["QueryControl"] as? [String: Any])
        #expect(control["QueryRewrite"] as? Bool == false)
    }

    @Test("Direct API rejects unbounded or unsupported request values")
    func directLimits() {
        let configuration = volcengineConfiguration(.agentPlan)
        #expect(throws: (any Error).self) {
            _ = try WebSearchService.makeRequest(
                configuration,
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(
                    text: "q",
                    domains: (0..<21).map { "d\($0).example" }
                )
            )
        }
        #expect(throws: (any Error).self) {
            _ = try WebSearchService.makeRequest(
                configuration,
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(
                    text: "q",
                    excludedDomains: (0..<6).map { "d\($0).example" }
                )
            )
        }
        #expect(throws: (any Error).self) {
            _ = try WebSearchService.makeRequest(
                configuration,
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(text: String(repeating: "q", count: 101))
            )
        }
        #expect(throws: (any Error).self) {
            _ = try WebSearchService.makeRequest(
                configuration,
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(text: "q", domains: ["bad|domain"])
            )
        }
    }

    @Test("Ark Responses request is standalone and uses only web_search")
    func arkCustomRequest() throws {
        let configuration = volcengineConfiguration(
            .arkResponses,
            options: [
                VolcengineSearchOptions.Key.arkEngine: VolcengineArkSearchEngine.doubaoCustom.rawValue,
                VolcengineSearchOptions.Key.arkModel: "doubao-test-1"
            ]
        )
        let request = try WebSearchService.makeRequest(
            configuration,
            credential: WebSearchCredential(values: ["apiKey": "ark-key"]),
            query: WebSearchQuery(text: "today AI news", maxResults: 30)
        )
        #expect(request.url?.absoluteString == "https://ark.cn-beijing.volces.com/api/v3/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ark-key")
        let body = try requestJSONBody(request)
        #expect(body["model"] as? String == "doubao-test-1")
        #expect(body["stream"] as? Bool == false)
        #expect(body["input"] as? String == "today AI news")
        #expect(body["max_tool_calls"] as? Int == 1)
        #expect(body["functions"] == nil)
        #expect(body["previous_response_id"] == nil)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "web_search")
        let sources = try #require(tools[0]["sources"] as? [String])
        #expect(sources == ["doubao"])
        #expect(tools[0]["limit"] == nil)
        #expect(WebSearchService.requestURLIsCanonical(request.url, configuration: configuration))
        #expect(WebSearchService.allowsTransientTunnel(for: configuration))
    }

    @Test("Ark online content sends all three sources together, never doubao")
    func arkOnlineContentRequest() throws {
        let configuration = volcengineConfiguration(
            .arkResponses,
            options: [
                VolcengineSearchOptions.Key.arkEngine: VolcengineArkSearchEngine.onlineContent.rawValue
            ]
        )
        let request = try WebSearchService.makeRequest(
            configuration,
            credential: WebSearchCredential(values: ["apiKey": "ark-key"]),
            query: WebSearchQuery(text: "weather", maxResults: 40)
        )
        let body = try requestJSONBody(request)
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "web_search")
        #expect(tools[0]["sources"] as? [String] == ["toutiao", "douyin", "moji"])
        #expect(tools[0]["limit"] as? Int == 20)
        #expect((tools[0]["sources"] as? [String])?.contains("doubao") == false)
    }

    @Test("Ark rejects filters it cannot apply")
    func arkUnsupportedFilters() {
        let configuration = volcengineConfiguration(.arkResponses)
        #expect(throws: (any Error).self) {
            _ = try WebSearchService.makeRequest(
                configuration,
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(text: "q", domains: ["example.com"])
            )
        }
        #expect(throws: (any Error).self) {
            _ = try WebSearchService.makeRequest(
                configuration,
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(text: "q", recencyDays: 3)
            )
        }
    }

    @Test("Stored record without an interface keeps the exact legacy request")
    func legacyCustomEndpoint() throws {
        let endpoint = URL(string: "https://search.example.com/api")!
        let configuration = volcengineConfiguration(nil, endpoint: endpoint)
        let request = try WebSearchService.makeRequest(
            configuration,
            credential: WebSearchCredential(values: ["apiKey": "legacy-key"]),
            query: WebSearchQuery(text: "legacy query", maxResults: 7)
        )
        #expect(request.url == endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer legacy-key")
        let body = try requestJSONBody(request)
        #expect(body.count == 2)
        #expect(body["query"] as? String == "legacy query")
        #expect(body["count"] as? Int == 7)
        #expect(body["Query"] == nil)
        #expect(WebSearchService.canonicalEndpoint(for: configuration) == nil)
        #expect(!WebSearchService.allowsTransientTunnel(for: configuration))
    }

    @Test("Old nil-interface record never silently becomes Agent Plan")
    func legacyWithoutEndpoint() {
        let configuration = volcengineConfiguration(nil)
        #expect(!WebSearchService.isConfigured(
            configuration,
            credential: WebSearchCredential(values: ["apiKey": "k"])
        ))
        #expect(WebSearchService.canonicalEndpoint(for: configuration) == nil)
        #expect(throws: (any Error).self) {
            _ = try WebSearchService.makeRequest(
                configuration,
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(text: "q")
            )
        }
        // An interface plus a leftover custom endpoint is rejected instead of
        // sending the selected credential to the legacy destination.
        let mixed = volcengineConfiguration(
            .agentPlan,
            endpoint: URL(string: "https://search.example.com/api")
        )
        #expect(throws: (any Error).self) {
            _ = try WebSearchService.makeRequest(
                mixed,
                credential: WebSearchCredential(values: ["apiKey": "k"]),
                query: WebSearchQuery(text: "q")
            )
        }
    }

    @Test("Direct PascalCase results normalize without changing camelCase providers")
    func directParsing() throws {
        let data = Data(#"""
        {"results":[{"Id":"1","Title":"Official story","Url":"https://example.com/a","Snippet":"direct snippet","Summary":"summary fallback","PublishTime":"2026-10-20T10:00:00+08:00","SiteName":"Example","LogoUrl":"https://example.com/logo.png","RankScore":1.5}]}
        """#.utf8)
        let output = try WebSearchService.parseOutput(data, provider: .volcengine, limit: 10)
        let result = try #require(output.results.first)
        #expect(output.generatedAnswer == nil)
        #expect(result.title == "Official story")
        #expect(result.url.absoluteString == "https://example.com/a")
        #expect(result.snippet == "direct snippet")
        #expect(result.publishedAt == "2026-10-20T10:00:00+08:00")
        #expect(result.sourceName == "Example")
        #expect(result.faviconURL == "https://example.com/logo.png")
        #expect(result.provider == .volcengine)
        #expect(result.effectiveContentState == .searchMetadataOnly)
        // Legacy custom endpoints keep their lowercase envelope.
        let legacy = Data(#"{"results":[{"title":"Legacy","url":"https://example.com/b","snippet":"old"}]}"#.utf8)
        let legacyOutput = try WebSearchService.parseOutput(legacy, provider: .volcengine, limit: 10)
        #expect(legacyOutput.results.first?.title == "Legacy")
        #expect(legacyOutput.generatedAnswer == nil)
    }

    @Test("Ark citations and generated answer stay separate")
    func arkParsing() throws {
        let data = Data(#"""
        {"object":"response","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"The answer is sunny.","annotations":[{"type":"url_citation","title":"Weather story","url":"https://example.com/weather","summary":"citation summary","site_name":"Example Weather","publish_time":"2026-10-20T08:00:00+08:00"}]}]}]}
        """#.utf8)
        let output = try WebSearchService.parseOutput(data, provider: .volcengine, limit: 10)
        let result = try #require(output.results.first)
        let answer = try #require(output.generatedAnswer)
        #expect(result.title == "Weather story")
        #expect(result.snippet == "citation summary")
        #expect(result.sourceName == "Example Weather")
        #expect(result.publishedAt == "2026-10-20T08:00:00+08:00")
        #expect(answer.text == "The answer is sunny.")
        #expect(answer.text != result.snippet)
        #expect(answer.provider == .volcengine)
    }

    @Test("Ark answer without citations is real output; failures are not empty success")
    func arkAnswerOnlyAndFailures() throws {
        let answerOnly = Data(#"""
        {"object":"response","status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"No citation, but useful weather text.","annotations":[]}]}]}
        """#.utf8)
        let output = try WebSearchService.parseOutput(answerOnly, provider: .volcengine, limit: 10)
        #expect(output.results.isEmpty)
        #expect(output.generatedAnswer?.text == "No citation, but useful weather text.")

        for body in [#"{"object":"response","status":"failed","error":{"message":"upstream failed"}}"#,
                     #"{"object":"response","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}"#,
                     #"{"object":"response","status":"completed","error":{"message":"bad request"}}"#] {
            #expect(throws: (any Error).self) {
                _ = try WebSearchService.parseOutput(Data(body.utf8), provider: .volcengine, limit: 10)
            }
        }
    }

    @Test("Generated answer is bounded with truncation metadata")
    func generatedAnswerBound() throws {
        let longText = String(repeating: "多字节回答", count: 1_000)
        let payload: [String: Any] = [
            "object": "response",
            "status": "completed",
            "output": [["type": "message", "content": [["type": "output_text", "text": longText]]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let output = try WebSearchService.parseOutput(data, provider: .volcengine, limit: 10)
        let answer = try #require(output.generatedAnswer)
        #expect(answer.text.count == VolcengineSearchOptions.maximumGeneratedAnswerCharacters)
        #expect(answer.originalCharacters == longText.count)
        #expect(answer.truncated)
    }

    @Test("Canonical origin is selected per interface, never shared")
    func canonicalOrigins() throws {
        let agent = volcengineConfiguration(.agentPlan)
        let ark = volcengineConfiguration(.arkResponses)
        #expect(WebSearchService.canonicalEndpoint(for: agent)
            == URL(string: "https://open.feedcoopapi.com/search_api/web_search"))
        #expect(WebSearchService.canonicalEndpoint(for: ark)
            == URL(string: "https://ark.cn-beijing.volces.com/api/v3/responses"))
        #expect(WebSearchService.canonicalEndpoint(for: volcengineConfiguration(nil)) == nil)
        let agentRequest = try WebSearchService.makeRequest(
            agent,
            credential: WebSearchCredential(values: ["apiKey": "k"]),
            query: WebSearchQuery(text: "q")
        )
        #expect(!WebSearchService.requestURLIsCanonical(agentRequest.url, configuration: ark))
    }

    @Test("Malformed options and time ranges are explicit")
    func malformedOptionsAndTimeRange() {
        for options in [
            [VolcengineSearchOptions.Key.interface: "unknown"],
            [VolcengineSearchOptions.Key.interface: "agentPlan",
             VolcengineSearchOptions.Key.arkEngine: "unknown"],
            [VolcengineSearchOptions.Key.interface: "arkResponses",
             VolcengineSearchOptions.Key.arkModel: "bad model"],
            [VolcengineSearchOptions.Key.interface: "agentPlan",
             VolcengineSearchOptions.Key.queryRewrite: "maybe"],
            [VolcengineSearchOptions.Key.interface: "agentPlan",
             VolcengineSearchOptions.Key.dataProServerID: "not-a-uuid"]
        ] {
            #expect(throws: (any Error).self) {
                _ = try VolcengineSearchOptions(options: options)
            }
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(WebSearchService.volcengineTimeRange(days: 1, now: now) == "OneDay")
        #expect(WebSearchService.volcengineTimeRange(days: 7, now: now) == "OneWeek")
        #expect(WebSearchService.volcengineTimeRange(days: 31, now: now) == "OneMonth")
        #expect(WebSearchService.volcengineTimeRange(days: 365, now: now) == "OneYear")
        #expect(WebSearchService.volcengineTimeRange(days: 400, now: now)
            == "2022-10-11..2023-11-14")
    }
}
