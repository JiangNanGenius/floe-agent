// FloeExecution — bounded web-search tool-output regressions.
// Synthetic responses only: no network, no credentials. These pin the
// omitted-max_results bounded default, the deterministic per-row snippet
// budget inside the 4_096-character tool boundary, honest truncation
// markers, and exact URL/citation identity preservation for the
// long-row Volcengine shape (paragraph Snippet text plus provenance
// fields on every row).

import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("Web search result budget")
struct WebSearchResultBudgetTests {
    /// A normalized row in the shape Volcengine's direct gateway produces:
    /// non-empty site/date/favicon-adjacent fields and a paragraph snippet.
    private static func row(_ index: Int, snippetLength: Int) -> WebSearchResult {
        WebSearchResult(
            title: "搜索结果 \(index)",
            url: URL(
                string: "https://example.com/volc/\(index)?trace=\(String(repeating: "t", count: 40))"
            )!,
            snippet: String(repeating: "研", count: snippetLength),
            sourceName: "站点 \(index)",
            publishedAt: "2026-10-2\(index % 9)T10:00:00+08:00",
            provider: .volcengine,
            citationID: String(format: "cit%09d", index),
            faviconURL: "https://example.com/logo-\(index).png"
        )
    }

    private static func response(_ rows: [WebSearchResult]) -> WebSearchResponse {
        WebSearchResponse(
            query: "量子计算 最新突破",
            results: rows,
            providersUsed: [.volcengine]
        )
    }

    private static func object(_ output: ToolExecutionOutput) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any]
        )
    }

    // MARK: - Omitted default wiring

    @Test("Omitted max_results uses the bounded shared default")
    func omittedUsesBoundedDefault() throws {
        // 5 matches WebSearchService.searchTest/testSearch and keeps every
        // kept row's snippet useful inside the fixed tool boundary.
        #expect(WebSearchTool.defaultMaxResults == 5)
        #expect(WebSearchTool.parametersJSON.contains("defaults to 5"))
        #expect(BochaAISearchTool.parametersJSON.contains("defaults to 5"))

        let decoder = JSONDecoder()
        let omitted = try decoder.decode(
            WebSearchTool.Arguments.self, from: Data(#"{"query":"x"}"#.utf8)
        )
        #expect(omitted.maxResults == nil)
        let null = try decoder.decode(
            WebSearchTool.Arguments.self, from: Data(#"{"query":"x","maxResults":null}"#.utf8)
        )
        #expect(null.maxResults == nil)
        let explicit = try decoder.decode(
            WebSearchTool.Arguments.self, from: Data(#"{"query":"x","maxResults":3}"#.utf8)
        )
        #expect(explicit.maxResults == 3)
    }

    @Test("Explicit valid limits validate; invalid values reject")
    func validateLimits() throws {
        let tool = WebSearchTool(service: WebSearchService())
        try tool.validate(WebSearchTool.Arguments(query: "x", maxResults: 5))
        try tool.validate(WebSearchTool.Arguments(query: "x", maxResults: 50))
        #expect(throws: (any Error).self) {
            try tool.validate(WebSearchTool.Arguments(query: "x", maxResults: 51))
        }
        #expect(throws: (any Error).self) {
            try tool.validate(WebSearchTool.Arguments(query: "x", maxResults: 0))
        }
    }

    // MARK: - Deterministic bounded serialization

    @Test("Five long rows stay inside the boundary with exact citations and useful snippets")
    func fiveLongRowsStayUsefulAndBounded() throws {
        let rows = (1...5).map { Self.row($0, snippetLength: 1_200) }
        let output = try WebSearchTool.output(Self.response(rows))
        #expect(output.summary.count <= 4_096)
        let object = try Self.object(output)
        #expect(object["available"] as? Int == 5)
        let entries = try #require(object["results"] as? [[String: Any]])
        #expect(object["returned"] as? Int == entries.count)
        // Budget measurement for five real Volcengine-shaped rows leaves
        // every kept row above the useful snippet floor; rows are never
        // reduced to empty-snippet noise at the default count.
        #expect(entries.count >= 4)
        #expect(object["truncated"] as? Bool == true)
        for (index, entry) in entries.enumerated() {
            // Exact citation identity for every kept row, in gateway order.
            #expect(entry["url"] as? String == rows[index].url.absoluteString)
            #expect(entry["citation"] as? String == rows[index].citationID)
            let snippet = entry["snippet"] as? String ?? ""
            #expect(snippet.count >= WebSearchTool.minimumUsefulSnippetCharacters)
            #expect(snippet.count < rows[index].snippet.count)
            #expect(entry["snippetTruncated"] as? Bool == true)
            #expect(entry["originalSnippetChars"] as? Int == 1_200)
        }
    }

    @Test("Overreturned rows are bounded with exact retained identities")
    func overreturnedRowsBounded() throws {
        let rows = (1...12).map { Self.row($0, snippetLength: 1_500) }
        let output = try WebSearchTool.output(Self.response(rows))
        #expect(output.summary.count <= 4_096)
        let object = try Self.object(output)
        let entries = try #require(object["results"] as? [[String: Any]])
        let returned = try #require(object["returned"] as? Int)
        #expect(returned == entries.count)
        #expect(object["available"] as? Int == 12)
        // The equal-usable-snippet rule drops trailing rows instead of
        // emptying every snippet: several rows survive, never all twelve.
        #expect(returned >= 3)
        #expect(returned < 12)
        #expect(object["omittedResults"] as? Int == 12 - returned)
        #expect(object["truncated"] as? Bool == true)
        for (index, entry) in entries.enumerated() {
            #expect(entry["url"] as? String == rows[index].url.absoluteString)
            #expect(entry["citation"] as? String == rows[index].citationID)
            let snippet = entry["snippet"] as? String ?? ""
            #expect(snippet.count >= WebSearchTool.minimumUsefulSnippetCharacters)
            #expect(entry["snippetTruncated"] as? Bool == true)
            #expect(entry["originalSnippetChars"] as? Int == 1_500)
        }
    }

    @Test("Huge single row stays bounded, exact and honestly marked")
    func hugeSingleItemBounded() throws {
        let rows = [Self.row(1, snippetLength: 50_000)]
        let output = try WebSearchTool.output(Self.response(rows))
        #expect(output.summary.count <= 4_096)
        let object = try Self.object(output)
        let entries = try #require(object["results"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(object["returned"] as? Int == 1)
        #expect(object["omittedResults"] as? Int == 0)
        let entry = try #require(entries.first)
        #expect(entry["url"] as? String == rows[0].url.absoluteString)
        #expect(entry["citation"] as? String == rows[0].citationID)
        // A single row gets the whole remaining budget: a large, useful
        // excerpt, never an empty snippet.
        let snippet = entry["snippet"] as? String ?? ""
        #expect(snippet.count >= 1_000)
        #expect(snippet.count < rows[0].snippet.count)
        #expect(entry["snippetTruncated"] as? Bool == true)
        #expect(entry["originalSnippetChars"] as? Int == 50_000)
        #expect(object["truncated"] as? Bool == true)
    }

    @Test("Two short rows are returned complete and untruncated")
    func twoShortRowsComplete() throws {
        let rows = (1...2).map { index in
            WebSearchResult(
                title: "Short \(index)",
                url: URL(string: "https://example.com/short/\(index)")!,
                snippet: "简洁摘要 \(index)",
                provider: .volcengine,
                citationID: String(format: "cit%09d", index)
            )
        }
        let output = try WebSearchTool.output(Self.response(rows))
        #expect(output.summary.count <= 4_096)
        let object = try Self.object(output)
        #expect(object["returned"] as? Int == 2)
        #expect(object["available"] as? Int == 2)
        #expect(object["omittedResults"] as? Int == 0)
        #expect(object["truncated"] as? Bool == false)
        let entries = try #require(object["results"] as? [[String: Any]])
        #expect(entries.count == 2)
        for (index, entry) in entries.enumerated() {
            #expect(entry["snippet"] as? String == rows[index].snippet)
            #expect(entry["snippetTruncated"] as? Bool == false)
            #expect(entry["url"] as? String == rows[index].url.absoluteString)
        }
    }

    @Test("Serialization is deterministic for the same response")
    func deterministicForSameResponse() throws {
        let rows = (1...5).map { Self.row($0, snippetLength: 1_200) }
        let response = Self.response(rows)
        let first = try WebSearchTool.output(response)
        let second = try WebSearchTool.output(response)
        #expect(first.summary == second.summary)
        #expect(first.fullOutputSHA256 == second.fullOutputSHA256)
    }

    @Test("Oversize citation URL rows are omitted while kept rows stay whole")
    func oversizeURLRowsOmittedNotShortened() throws {
        let longURL = "https://example.com/" + String(repeating: "segment/", count: 250) + "end"
        #expect(longURL.count > WebSearchTool.maximumCitationURLLength)
        var rows = [Self.row(1, snippetLength: 1_200)]
        rows.append(WebSearchResult(
            title: "Oversize",
            url: URL(string: longURL)!,
            snippet: String(repeating: "长", count: 1_200),
            provider: .volcengine,
            citationID: "cit-oversize"
        ))
        rows.append(Self.row(2, snippetLength: 1_200))
        let output = try WebSearchTool.output(Self.response(rows))
        #expect(output.summary.count <= 4_096)
        let object = try Self.object(output)
        let entries = try #require(object["results"] as? [[String: Any]])
        let urls = entries.compactMap { $0["url"] as? String }
        #expect(!urls.contains(longURL))
        #expect(object["omittedOversizeURLRows"] as? Int == 1)
        // The kept rows carry the EXACT original targets.
        #expect(urls.first == rows[0].url.absoluteString)
    }

    // MARK: - Complete normalized capture (not the UI budget)

    @Test("Complete capture preserves every row and long provider text beyond the UI budget")
    func completeCapturePreservesTailBeyondUIBudget() throws {
        let snippet = String(repeating: "短摘要", count: 500)
        let summary = String(repeating: "长摘要", count: 1_500)
        let content = String(repeating: "网页正文", count: 3_000)
        let rows = (1...6).map { index in
            WebSearchResult(
                title: "DeepSeek result \(index)",
                url: URL(string: "https://example.com/deepseek/\(index)")!,
                snippet: snippet,
                sourceName: "Example \(index)",
                publishedAt: "2026-10-30T00:00:00Z",
                score: 2.4,
                provider: .deepseek,
                citationID: String(format: "ds%09d", index),
                faviconURL: "https://example.com/icon-\(index).png",
                summary: summary,
                content: content,
                authority: 3
            )
        }
        let response = WebSearchResponse(
            query: "DeepSeek 最新发布",
            results: rows,
            providersUsed: [.deepseek]
        )
        let output = try WebSearchTool.output(response)

        // The display projection is still one bounded, valid JSON page.
        #expect(output.summary.count <= 4_096)
        _ = try Self.object(output)

        // The complete normalized capture is separate from that projection
        // and keeps the sixth row and every long field byte-for-byte.
        let capture = try #require(output.capturedOutput)
        #expect(capture.count > 4_096)
        #expect(output.capturedOutputTruncated == false)
        let captured = try #require(
            try JSONSerialization.jsonObject(with: Data(capture.utf8)) as? [String: Any]
        )
        #expect(captured["captureState"] as? String == "normalizedFullResponse")
        #expect(captured["returned"] as? Int == 6)
        #expect(captured["available"] as? Int == 6)
        #expect(captured["truncated"] as? Bool == false)
        let capturedRows = try #require(captured["results"] as? [[String: Any]])
        #expect(capturedRows.count == 6)
        let last = try #require(capturedRows.last)
        #expect(last["url"] as? String == rows[5].url.absoluteString)
        #expect(last["citation"] as? String == rows[5].citationID)
        #expect(last["snippet"] as? String == snippet)
        #expect(last["summary"] as? String == summary)
        #expect(last["content"] as? String == content)
        #expect(last["authority"] as? Int == 3)
        #expect(last["score"] as? Double == 2.4)
        #expect(output.fullOutputSHA256 == FloeDigest.sha256Hex(Data(capture.utf8)))
    }

    @Test("Complete capture retains provider failures instead of hiding them")
    func completeCaptureRetainsFailures() throws {
        let rows = [Self.row(1, snippetLength: 100)]
        let response = WebSearchResponse(
            query: "q",
            results: rows,
            providersUsed: [.volcengine],
            failures: [
                "deepseek: authentication failed (HTTP 401)",
                "bochaWeb: HTTP 429"
            ]
        )
        let output = try WebSearchTool.output(response)
        let capture = try #require(output.capturedOutput)
        let captured = try #require(
            try JSONSerialization.jsonObject(with: Data(capture.utf8)) as? [String: Any]
        )
        #expect(captured["failures"] as? [String] == response.failures)
        #expect(captured["returned"] as? Int == 1)
        #expect(captured["truncated"] as? Bool == false)
    }
}
