// FloeExecution — focused Volcengine direct-gateway envelope regression.
// Synthetic fixtures reproduce the documented response
// shape of open.feedcoopapi.com/search_api/web_search:
//   { "ResponseMetadata": { … }, "Result": { "ResultCount": n,
//     "WebResults": [ WebItem ] } }
// and the HTTP-200 gateway error shape with a null Result plus an Error
// object inside ResponseMetadata. No network, no credentials.

import Foundation
import Testing
@testable import FloeExecution

@Suite("Volcengine direct gateway envelope")
struct VolcengineDirectGatewayEnvelopeTests {
    private static let liveShapedBody = Data("""
    {"ResponseMetadata":{"RequestId":"20261024TESTREQUESTID","Action":"","Version":"","Service":"","Region":""},\
    "Result":{"ResultCount":2,"WebResults":[\
    {"Id":"5f4408b2b5dd9d81-9b8fc02da10ab180","SortId":1,"Title":"豆包大模型 1.6 正式发布",\
    "SiteName":"火山引擎","Url":"https://example.com/doubao-1-6",\
    "Snippet":"简短片段约200字","Summary":"相关摘要500到1000字","Content":"正文",\
    "PublishTime":"2026-05-06T10:00:00+08:00","LogoUrl":"https://example.com/logo.png",\
    "RankScore":0.91,"AuthInfoDes":"正常权威","AuthInfoLevel":2},\
    {"Id":"05abd7ac72386587-69d19099247a2754","SortId":2,"Title":"iPad 产品页",\
    "SiteName":"Apple","Url":"https://example.com/ipad",\
    "Snippet":"第二条片段","Summary":"","PublishTime":"2026-09-21T10:53:59+08:00",\
    "LogoUrl":"","RankScore":0,"AuthInfoDes":"正常权威","AuthInfoLevel":2}]}}
    """.utf8)

    @Test("Result.WebResults envelope decodes to normalized results")
    func liveEnvelopeDecodes() throws {
        let output = try WebSearchService.parseOutput(
            Self.liveShapedBody, provider: .volcengine, limit: 5
        )
        #expect(output.generatedAnswer == nil)
        #expect(output.results.count == 2)
        let first = try #require(output.results.first)
        #expect(first.title == "豆包大模型 1.6 正式发布")
        #expect(first.url.absoluteString == "https://example.com/doubao-1-6")
        #expect(first.snippet == "简短片段约200字")
        #expect(first.sourceName == "火山引擎")
        #expect(first.publishedAt == "2026-05-06T10:00:00+08:00")
        #expect(first.faviconURL == "https://example.com/logo.png")
        #expect(first.score == 0.91)
        let second = output.results[1]
        #expect(second.title == "iPad 产品页")
        // Empty LogoUrl must not fabricate a favicon.
        #expect(second.faviconURL == nil)
    }

    @Test("Gateway error with null Result surfaces as a provider error")
    func gatewayErrorSurfaces() {
        for body in [
            // Error nested in ResponseMetadata (documented gateway shape).
            """
            {"ResponseMetadata":{"RequestId":"R1","Error":{"Code":"InvalidParameter","Message":"query too long","CodeN":400}},\
            "Result":null}
            """,
            // Error at the root.
            """
            {"ResponseMetadata":{"RequestId":"R2"},"Error":{"Code":"AuthFail","Message":"invalid api key"}}
            """
        ] {
            #expect(throws: (any Error).self) {
                _ = try WebSearchService.parseOutput(
                    Data(body.utf8), provider: .volcengine, limit: 5
                )
            }
        }
        // The surfaced message carries the vendor code and text.
        do {
            _ = try WebSearchService.parseOutput(
                Data("""
                {"ResponseMetadata":{"RequestId":"R1","Error":{"Code":"InvalidParameter","Message":"query too long"}}}
                """.utf8), provider: .volcengine, limit: 5
            )
            Issue.record("expected a thrown provider error")
        } catch {
            let text = error.localizedDescription
            #expect(text.contains("InvalidParameter"))
            #expect(text.contains("query too long"))
        }
    }

    @Test("Legitimate zero-match answer is a successful empty result")
    func emptyMatchListIsSuccess() throws {
        let body = Data("""
        {"ResponseMetadata":{"RequestId":"R3"},"Result":{"ResultCount":0,"WebResults":[]}}
        """.utf8)
        let output = try WebSearchService.parseOutput(body, provider: .volcengine, limit: 5)
        #expect(output.results.isEmpty)
        #expect(output.generatedAnswer == nil)
    }

    @Test("isEmptyResultOnly distinguishes empty success from hard failures")
    func emptyResultTagging() {
        #expect(WebSearchService.isEmptyResultOnly(["volcengine: empty result"]))
        #expect(!WebSearchService.isEmptyResultOnly(["volcengine: HTTP 401"]))
        #expect(!WebSearchService.isEmptyResultOnly([
            "volcengine: empty result", "bochaWeb: HTTP 429"
        ]))
        #expect(!WebSearchService.isEmptyResultOnly([]))
    }

    @Test("Legacy lowercase envelope and other providers keep prior behavior")
    func unchangedEnvelopePaths() throws {
        let legacy = Data(
            #"{"results":[{"title":"Legacy","url":"https://example.com/b","snippet":"old"}]}"#.utf8
        )
        let legacyOutput = try WebSearchService.parseOutput(
            legacy, provider: .volcengine, limit: 5
        )
        #expect(legacyOutput.results.first?.title == "Legacy")
        let bocha = Data(
            #"{"data":{"webPages":{"value":[{"name":"Bocha","url":"https://example.com/c","snippet":"s"}]}}}"#.utf8
        )
        let bochaOutput = try WebSearchService.parseOutput(
            bocha, provider: .bochaWeb, limit: 5
        )
        #expect(bochaOutput.results.first?.title == "Bocha")
    }

    // MARK: - Defensive over-return / oversized-item bounding

    /// Exact documented gateway envelope with an arbitrary number of items,
    /// so fixtures can reproduce a server that returns MORE results than
    /// the request asked for.
    private static func envelope(
        items: [[String: Any]],
        resultCount: Int? = nil
    ) -> Data {
        let json: [String: Any] = [
            "ResponseMetadata": ["RequestId": "OVERRETURN-TEST"],
            "Result": [
                "ResultCount": resultCount ?? items.count,
                "WebResults": items
            ]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    @Test("Server over-return is capped at the requested limit with order and identity preserved")
    func serverOverReturnCappedAtLimit() throws {
        let items: [[String: Any]] = (0..<12).map { index in
            [
                "Id": "over-\(index)",
                "SortId": index,
                "Title": "Overreturn \(index)",
                "SiteName": "Site \(index)",
                "Url": "https://example.com/overreturn/\(index)",
                "Snippet": "snippet \(index)",
                "Summary": ""
            ]
        }
        let output = try WebSearchService.parseOutput(
            Self.envelope(items: items, resultCount: 12), provider: .volcengine, limit: 5
        )
        // Exactly the requested count, in gateway order — never the 12 the
        // server overreturned, and identities survive the trim.
        #expect(output.results.count == 5)
        #expect(output.results.map(\.url.absoluteString)
                == (0..<5).map { "https://example.com/overreturn/\($0)" })
        #expect(output.results.map(\.title) == (0..<5).map { "Overreturn \($0)" })
        #expect(output.results.allSatisfy { $0.citationID.count == 12 })
    }

    @Test("Huge single item text is capped at parse without losing identity")
    func hugeSingleItemCappedAtParse() throws {
        let item: [[String: Any]] = [[
            "Id": "huge-1",
            "SortId": 1,
            "Title": "Huge result",
            "SiteName": "Site",
            "Url": "https://example.com/huge",
            "Snippet": String(repeating: "长", count: 30_000),
            "Summary": ""
        ]]
        let output = try WebSearchService.parseOutput(
            Self.envelope(items: item), provider: .volcengine, limit: 5
        )
        #expect(output.results.count == 1)
        // Existing parser ceiling: 4_000 characters, title/URL untouched.
        #expect(output.results[0].snippet.count == 4_000)
        #expect(output.results[0].title == "Huge result")
        #expect(output.results[0].url.absoluteString == "https://example.com/huge")
    }

    @Test("Gateway Content field never leaks into the snippet")
    func contentFieldNotUsedAsSnippet() throws {
        let item: [[String: Any]] = [[
            "Id": "content-1",
            "SortId": 1,
            "Title": "Content only",
            "SiteName": "Site",
            "Url": "https://example.com/content-only",
            "Snippet": "",
            "Summary": "",
            "Content": String(repeating: "正文", count: 400)
        ]]
        let output = try WebSearchService.parseOutput(
            Self.envelope(items: item), provider: .volcengine, limit: 5
        )
        // NeedContent=false contract: the PascalCase full-body field is not
        // one of the snippet keys, so an empty Snippet/Summary stays empty.
        #expect(output.results.count == 1)
        #expect(output.results[0].snippet.isEmpty)
        #expect(output.results[0].title == "Content only")
        #expect(output.results[0].url.absoluteString == "https://example.com/content-only")
    }
}
