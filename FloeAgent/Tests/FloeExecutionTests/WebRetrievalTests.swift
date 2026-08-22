import Foundation
import Testing
@testable import FloeExecution

@Suite("Web retrieval adapters")
struct WebRetrievalTests {
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
