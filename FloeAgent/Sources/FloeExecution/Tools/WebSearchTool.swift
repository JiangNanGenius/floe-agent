import Crypto
import Foundation
import FloeCore
import FloeTools

public struct WebSearchTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var query: String
        public var mode: String?
        public var domains: [String]?
        public var excludeDomains: [String]?
        public var recencyDays: Int?
        public var maxResults: Int?
        public var provider: String?
    }

    public static let name = "web.search"

    /// Sane bounded request default when the model omits `maxResults`. It
    /// matches the existing in-app search-test default (`WebSearchService
    /// .searchTest` / `testSearch` use 5), and it is the practical ceiling
    /// for the tool's single 4_096-character JSON payload: each normalized
    /// row already carries an exact citation URL plus ~20 provenance/marker
    /// keys, so ten long provider rows (Volcengine `Snippet`/`Summary` are
    /// paragraphs) could never survive the budget intact and collapsed to
    /// empty snippets with heavy truncation noise. Explicit valid limits
    /// (1...50) keep their exact meaning; the serialization below still
    /// bounds total payload text.
    public static let defaultMaxResults = 5

    /// Minimum characters a kept row's snippet should retain to stay useful
    /// to the model. When even this floor cannot fit, trailing rows are
    /// dropped first (explicit `returned`/`omittedResults`/`truncated`
    /// markers) instead of shortening every snippet to noise.
    static let minimumUsefulSnippetCharacters = 64

    public static let toolDescription =
        "Search the public web without opening the visual browser. Returns normalized titles, URLs, snippets, index metadata (page_age = published OR last modified date, relative age, crawl date, source profile/favicon), provider provenance, citation IDs and an explicit contentState=searchMetadataOnly. Index metadata is NOT page verification: excerpts and dates come from the search index; use web.fetch (or browser tools when interaction is required) before relying on actual page contents, publication dates or quotes. Some providers also return a bounded provider-generated answer, marked separately from URL citations and still not fetched-page evidence. Use fast for one search provider, balanced for ordinary research, or deep to query up to three configured providers concurrently."
    public static let parametersJSON = #"""
    {
      "type":"object",
      "properties":{
        "query":{"type":"string","description":"Natural-language web search query"},
        "mode":{"type":"string","enum":["fast","balanced","deep"],"description":"Retrieval depth; default balanced"},
        "domains":{"type":"array","items":{"type":"string"},"description":"Optional preferred or required domains"},
        "excludeDomains":{"type":"array","items":{"type":"string"},"description":"Optional domains to exclude"},
        "recencyDays":{"type":"integer","minimum":1,"maximum":1825},
        "maxResults":{"type":"integer","minimum":1,"maximum":50,"description":"Maximum number of returned results; defaults to 5 when omitted"},
        "provider":{"type":"string","description":"Optional configured provider name, kind, or UUID"}
      },
      "required":["query"],
      "additionalProperties":false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let service: WebSearchService
    public init(service: WebSearchService) { self.service = service }

    public func validate(_ args: Arguments) throws {
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 2_000 else {
            throw FloeError.validationFailed("query must contain 1-2000 UTF-8 bytes")
        }
        if let mode = args.mode, WebSearchMode(rawValue: mode) == nil {
            throw FloeError.validationFailed("mode must be fast, balanced, or deep")
        }
        if let max = args.maxResults, !(1...50).contains(max) {
            throw FloeError.validationFailed("maxResults must be 1-50")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let response = try await service.search(WebSearchQuery(
            text: args.query.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: WebSearchMode(rawValue: args.mode ?? "balanced") ?? .balanced,
            domains: args.domains ?? [],
            excludedDomains: args.excludeDomains ?? [],
            recencyDays: args.recencyDays,
            maxResults: args.maxResults ?? WebSearchTool.defaultMaxResults,
            requestedProvider: args.provider,
            summaryEnabled: false
        ))
        return try Self.output(response)
    }

    /// Shared, backward-compatible serialization for both search tools. The
    /// original fields keep their names and emptiness semantics; the added
    /// metadata/provenance keys make field availability explicit and state
    /// that this evidence is search-index level, not fetched-page verified.
    ///
    /// The payload is bounded to `maximumCharacters` BEFORE it leaves the
    /// tool: the runtime prefixes tool summaries to 4096 characters without a
    /// JSON-aware marker, so an oversized payload would silently cut the JSON
    /// and lose citations. Bounding accounts for JSON escape inflation
    /// (quotes/backslashes/control characters), not just source characters:
    /// top-level query/failure text and every result field are bounded, then
    /// snippets/extras and optionally trailing rows are reduced, always
    /// emitting valid JSON with `returned`/`available`/`truncated` counts and
    /// per-result `snippetTruncated`/`fieldsTruncated` markers. A citation
    /// URL is NEVER shortened to fit: a row whose exact target cannot be
    /// preserved is omitted explicitly (`omittedOversizeURLRows`) instead of
    /// returning a changed citation. A citation/title is never invented from
    /// another field.
    static func output(
        _ response: WebSearchResponse,
        maximumCharacters: Int = 4_096
    ) throws -> ToolExecutionOutput {
        let available = response.results.count
        // Rows whose exact citation target cannot be preserved are excluded
        // up front: a changed/truncated URL would be a broken citation.
        let eligible = response.results.filter {
            $0.url.absoluteString.count <= maximumCitationURLLength
        }
        let omittedOversizeURLRows = available - eligible.count
        var included = eligible.count
        var snippetLimit = 4_000
        var extraLimit = 2_000
        var answerLimit = 1_500
        var queryCap = 2_000
        var failureCap = 1_500

        // Deterministic initial text sizing. The payload room is measured
        // from the REAL serialized skeleton (exact URLs, titles, provenance
        // fields, generated answers and the metadata note at their current
        // budgets) with zeroed snippet/excerpt text; the equal cap then
        // water-fills, so rows with shorter snippets keep them whole and
        // hand their slack to longer rows. Trailing rows are dropped first
        // only when even a kept row cannot carry the useful snippet floor —
        // explicit `returned`/`omittedResults`/`truncated` markers stay
        // honest. Previously every row started at the parser's 4_000-
        // character ceiling; 5-10 long Volcengine rows could never fit the
        // 4_096 boundary, and the halving ladder below collapsed them into
        // empty snippets plus truncation noise. The ladder remains the
        // safety net for JSON escape inflation and pathological budgets.
        if included > 0 {
            var sizing = Self.measureSnippetCap(
                response,
                eligibleResults: eligible,
                included: included,
                answerLimit: answerLimit,
                queryCap: queryCap,
                failureCap: failureCap,
                omittedOversizeURLRows: omittedOversizeURLRows,
                maximumCharacters: maximumCharacters
            )
            while included > 1, sizing.cap < Self.minimumUsefulSnippetCharacters {
                included -= 1
                sizing = Self.measureSnippetCap(
                    response,
                    eligibleResults: eligible,
                    included: included,
                    answerLimit: answerLimit,
                    queryCap: queryCap,
                    failureCap: failureCap,
                    omittedOversizeURLRows: omittedOversizeURLRows,
                    maximumCharacters: maximumCharacters
                )
            }
            snippetLimit = sizing.cap
            extraLimit = min(2_000, max(0, sizing.roomAfterSnippets / max(1, included)))
        }

        while true {
            let (summary, _) = serialize(
                response,
                eligibleResults: eligible,
                included: included,
                snippetLimit: snippetLimit,
                extraLimit: extraLimit,
                answerLimit: answerLimit,
                titleCap: 300,
                queryCap: queryCap,
                failureCap: failureCap,
                omittedOversizeURLRows: omittedOversizeURLRows
            )
            if summary.count <= maximumCharacters {
                let digest = FloeDigest.sha256Hex(Data(summary.utf8))
                return ToolExecutionOutput(
                    summary: summary,
                    fullOutputSHA256: digest,
                    exitStatus: 0,
                    maximumSummaryCharacters: maximumCharacters
                )
            }
            // 1. shrink a provider-generated answer first; it is auxiliary
            // text, while URL citations must stay whole and visible;
            // 2. shrink snippets/extras (rows and citations survive);
            // 3. shrink the top-level query/failure text (still visible);
            // 4. drop trailing rows; 5. shrink metadata further.
            if answerLimit > 0, !response.generatedAnswers.isEmpty {
                answerLimit = answerLimit > 200 ? answerLimit / 2 : 0
                continue
            }
            if snippetLimit > 0 {
                snippetLimit /= 2
                extraLimit /= 2
                continue
            }
            if queryCap > 256 || failureCap > 256 {
                queryCap = max(256, queryCap / 2)
                failureCap = max(256, failureCap / 2)
                continue
            }
            if included > 1 {
                included -= 1
                continue
            }
            if queryCap > 16 || failureCap > 16 {
                queryCap = max(16, queryCap / 2)
                failureCap = max(16, failureCap / 2)
                continue
            }
            // Even a single row with minimal metadata exceeds the budget (for
            // example an escape-heavy query): emit an explicit, valid,
            // bounded error page instead of truncated JSON.
            return try budgetFallback(
                response,
                maximumCharacters: maximumCharacters,
                omittedOversizeURLRows: omittedOversizeURLRows
            )
        }
    }

    /// Hard cap for a citation target URL. A longer URL cannot be returned
    /// exactly inside the bounded payload, so its row is omitted explicitly
    /// rather than returned with a changed target.
    static let maximumCitationURLLength = 1_024

    /// Measures one serialization with zeroed snippet/excerpt text and
    /// returns the largest equal snippet character cap whose ACTUAL emitted
    /// snippet total (sum of min(length, cap) over kept rows) still fits the
    /// remaining payload room, plus the room left for `extraSnippets`.
    /// Water-filling over real lengths means short excerpts are never
    /// shortened and their unused budget goes to longer excerpts. Pure
    /// function of the response and budgets: the result is deterministic.
    private static func measureSnippetCap(
        _ response: WebSearchResponse,
        eligibleResults: [WebSearchResult],
        included: Int,
        answerLimit: Int,
        queryCap: Int,
        failureCap: Int,
        omittedOversizeURLRows: Int,
        maximumCharacters: Int
    ) -> (cap: Int, roomAfterSnippets: Int) {
        let rows = Array(eligibleResults.prefix(max(0, included)))
        let (skeleton, _) = serialize(
            response,
            eligibleResults: rows,
            included: rows.count,
            snippetLimit: 0,
            extraLimit: 0,
            answerLimit: answerLimit,
            titleCap: 300,
            queryCap: queryCap,
            failureCap: failureCap,
            omittedOversizeURLRows: omittedOversizeURLRows
        )
        let room = max(0, maximumCharacters - skeleton.count)
        let lengths = rows.map { $0.snippet.count }
        let wholeTotal = lengths.reduce(0, +)
        if wholeTotal <= room {
            // Every snippet already fits whole: keep the parser's ceiling
            // and give the unused room to additional excerpts.
            return (4_000, room - wholeTotal)
        }
        var low = 0
        var high = 4_000
        while low < high {
            let mid = (low + high + 1) / 2
            let needed = lengths.reduce(0) { $0 + min($1, mid) }
            if needed <= room {
                low = mid
            } else {
                high = mid - 1
            }
        }
        let needed = lengths.reduce(0) { $0 + min($1, low) }
        return (low, max(0, room - needed))
    }

    private static let metadataNote = "Snippets, dates and profiles come from the search index, not from a fetched page. pageAge is the page's published OR last modified date; relativeAge is relative; never treat index metadata as verified page content. Snippets marked snippetTruncated were shortened to fit the response budget."

    /// Character-bounded copy: `truncated` is true only when characters were
    /// actually removed. `maximum <= 0` yields an empty string that is marked
    /// truncated whenever the source was non-empty.
    private static func bounded(_ value: String, _ maximum: Int) -> (text: String, truncated: Bool) {
        guard maximum > 0 else { return ("", !value.isEmpty) }
        guard value.count > maximum else { return (value, false) }
        return (String(value.prefix(maximum)), true)
    }

    /// Bounds a provider-failure list to a total character budget so error
    /// text can never inflate the payload past the tool boundary.
    private static func boundedFailures(
        _ failures: [String],
        totalCharacterBudget: Int,
        perItemCap: Int = 512
    ) -> (items: [String], truncated: Bool) {
        guard !failures.isEmpty else { return ([], false) }
        var items: [String] = []
        var used = 0
        var truncated = false
        for failure in failures {
            let room = totalCharacterBudget - used
            guard room > 0 else {
                truncated = true
                break
            }
            let piece = bounded(failure, min(perItemCap, room))
            used += piece.text.count
            if piece.truncated { truncated = true }
            items.append(piece.text)
        }
        if items.count < failures.count { truncated = true }
        return (items, truncated)
    }

    /// Builds one bounded payload. Returns the serialized JSON and whether
    /// anything was shortened (query, failures, snippets, extras or fields)
    /// or omitted (trailing rows, or rows whose URL cannot be preserved).
    private static func serialize(
        _ response: WebSearchResponse,
        eligibleResults: [WebSearchResult],
        included: Int,
        snippetLimit: Int,
        extraLimit: Int,
        answerLimit: Int,
        titleCap: Int,
        queryCap: Int,
        failureCap: Int,
        omittedOversizeURLRows: Int
    ) -> (summary: String, truncated: Bool) {
        var truncated = included < eligibleResults.count || omittedOversizeURLRows > 0
        let query = bounded(response.query, queryCap)
        if query.truncated { truncated = true }
        let failures = boundedFailures(response.failures, totalCharacterBudget: failureCap)
        if failures.truncated { truncated = true }
        let entries = eligibleResults.prefix(included).map { result -> [String: Any] in
            func bound(_ value: String?, _ maximum: Int, _ field: String, _ fields: inout [String]) -> String {
                guard let value else { return "" }
                if value.count <= maximum { return value }
                fields.append(field)
                return String(value.prefix(maximum))
            }
            var fields: [String] = []
            let title = bound(result.title, titleCap, "title", &fields)
            // The citation target is always the EXACT URL: rows whose URL
            // exceeds the cap were excluded before serialization.
            let url = result.url.absoluteString
            let snippet = String(result.snippet.prefix(snippetLimit))
            let snippetTruncated = snippet.count < result.snippet.count
            var extras: [String] = []
            var extrasTruncated = false
            if let values = result.extraSnippets, extraLimit > 0 {
                var used = 0
                for value in values {
                    if used >= extraLimit { extrasTruncated = true; break }
                    let piece = String(value.prefix(max(0, extraLimit - used)))
                    used += piece.count
                    if piece.count < value.count { extrasTruncated = true }
                    if !piece.isEmpty { extras.append(piece) }
                }
            } else if result.extraSnippets?.isEmpty == false {
                extrasTruncated = true
            }
            let source = bound(result.sourceName, 256, "source", &fields)
            let publishedAt = bound(result.publishedAt, 64, "publishedAt", &fields)
            let pageAge = bound(result.pageAge, 64, "pageAge", &fields)
            let relativeAge = bound(result.relativeAge, 64, "relativeAge", &fields)
            let pageFetched = bound(result.pageFetched, 64, "pageFetched", &fields)
            let sourceProfile = bound(result.sourceProfileName, 256, "sourceProfile", &fields)
            let sourceProfileURL = bound(result.sourceProfileURL, 256, "sourceProfileURL", &fields)
            let favicon = bound(result.faviconURL, 256, "favicon", &fields)
            let displayPath = bound(result.displayPath, 256, "displayPath", &fields)
            // The row's truncation state is computed AFTER every bounded
            // field, so source/date/profile shortening is reflected in the
            // top-level `truncated` flag too — not only fields visited before
            // the flag was last refreshed.
            if snippetTruncated || extrasTruncated || !fields.isEmpty { truncated = true }
            return [
                "citation": result.citationID,
                "title": title,
                "url": url,
                "snippet": snippet,
                "snippetTruncated": snippetTruncated,
                "originalSnippetChars": result.snippet.count,
                "extraSnippets": extras,
                "extraSnippetsTruncated": extrasTruncated,
                "source": source,
                "publishedAt": publishedAt,
                "provider": result.provider.rawValue,
                "pageAge": pageAge,
                "relativeAge": relativeAge,
                "pageFetched": pageFetched,
                "sourceProfile": sourceProfile,
                "sourceProfileURL": sourceProfileURL,
                "favicon": favicon,
                "displayPath": displayPath,
                "fieldsTruncated": fields,
                "contentState": result.effectiveContentState.rawValue
            ] as [String: Any]
        }
        var generatedAnswers: [[String: Any]] = []
        if answerLimit > 0 {
            for answer in response.generatedAnswers {
                let piece = bounded(answer.text, answerLimit)
                let wasTruncated = piece.truncated || answer.truncated
                if wasTruncated { truncated = true }
                guard !piece.text.isEmpty else { continue }
                generatedAnswers.append([
                    "provider": answer.provider.rawValue,
                    "answer": piece.text,
                    "answerTruncated": wasTruncated,
                    "originalCharacters": answer.originalCharacters
                ])
            }
        }
        var payload: [String: Any] = [
            "query": query.text,
            "providers": response.providersUsed.map(\.rawValue),
            "failures": failures.items,
            "evidenceState": "searchMetadataOnly",
            "pageVerification": "notFetched",
            "pageFetchTool": "web.fetch",
            "metadataNote": metadataNote,
            "returned": entries.count,
            "available": response.results.count,
            "truncated": truncated,
            "omittedResults": max(0, response.results.count - entries.count),
            "results": entries
        ]
        if !generatedAnswers.isEmpty {
            payload["generatedAnswers"] = generatedAnswers
            payload["providerGeneratedAnswerNote"] =
                "Provider-generated answer text. Not fetched-page evidence and not a citation snippet; use the normalized URL results and web.fetch for verification."
        } else if !response.generatedAnswers.isEmpty {
            payload["generatedAnswersOmitted"] = true
        }
        if query.truncated {
            payload["queryTruncated"] = true
            payload["originalQueryChars"] = response.query.count
        }
        if failures.truncated { payload["failuresTruncated"] = true }
        if omittedOversizeURLRows > 0 { payload["omittedOversizeURLRows"] = omittedOversizeURLRows }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return (String(decoding: data, as: UTF8.self), truncated)
    }

    /// Explicit bounded error page for the pathological single-row case.
    /// Deterministically reduces query/failure text, then the metadata note,
    /// and finally drops them entirely (with explicit `queryTruncated` /
    /// `failuresTruncated` / `error` markers) until the serialized payload
    /// fits, so the real ToolResult prefix never cuts JSON. The provider
    /// list and error state stay visible throughout.
    private static func budgetFallback(
        _ response: WebSearchResponse,
        maximumCharacters: Int,
        omittedOversizeURLRows: Int
    ) throws -> ToolExecutionOutput {
        var queryCap = 256
        var failureCap = 256
        var includeNote = true
        while true {
            let query = bounded(response.query, queryCap)
            let failures = boundedFailures(response.failures, totalCharacterBudget: failureCap)
            var payload: [String: Any] = [
                "query": query.text,
                "providers": response.providersUsed.map(\.rawValue),
                "failures": failures.items,
                "evidenceState": "searchMetadataOnly",
                "pageVerification": "notFetched",
                "pageFetchTool": "web.fetch",
                "returned": 0,
                "available": response.results.count,
                "truncated": true,
                "error": "resultExceedsBudget",
                "omittedResults": response.results.count,
                "results": []
            ]
            if query.truncated {
                payload["queryTruncated"] = true
                payload["originalQueryChars"] = response.query.count
            }
            if failures.truncated || (failures.items.isEmpty && !response.failures.isEmpty) {
                payload["failuresTruncated"] = true
            }
            if omittedOversizeURLRows > 0 { payload["omittedOversizeURLRows"] = omittedOversizeURLRows }
            if !response.generatedAnswers.isEmpty { payload["generatedAnswersOmitted"] = true }
            if includeNote { payload["metadataNote"] = metadataNote }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let summary = String(decoding: data, as: UTF8.self)
            if summary.count <= maximumCharacters {
                return ToolExecutionOutput(
                    summary: summary,
                    fullOutputSHA256: FloeDigest.sha256Hex(data),
                    exitStatus: 0,
                    maximumSummaryCharacters: maximumCharacters
                )
            }
            if includeNote {
                includeNote = false
                continue
            }
            if queryCap > 0 || failureCap > 0 {
                queryCap = 0
                failureCap = 0
                continue
            }
            break
        }
        // The minimal explicit page is tiny; a budget below it is a caller
        // error rather than a content problem.
        var minimal: [String: Any] = [
            "error": "resultExceedsBudget",
            "truncated": true,
            "returned": 0,
            "available": response.results.count,
            "results": []
        ]
        if !response.generatedAnswers.isEmpty { minimal["generatedAnswersOmitted"] = true }
        let data = try JSONSerialization.data(withJSONObject: minimal, options: [.sortedKeys])
        return ToolExecutionOutput(
            summary: String(decoding: data, as: UTF8.self),
            fullOutputSHA256: FloeDigest.sha256Hex(data),
            exitStatus: 0,
            maximumSummaryCharacters: maximumCharacters
        )
    }
}

/// Bocha's AI-enhanced result summary is a separate capability rather than a
/// provider-wide switch. Models can choose raw multi-provider web evidence or
/// the Bocha summary tool on the same turn.
public struct BochaAISearchTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var query: String
        public var recencyDays: Int?
        public var maxResults: Int?
    }

    public static let name = "web.searchAI"
    public static let toolDescription =
        "Search with the configured Bocha provider and request its AI-enhanced summary plus normalized source results. This is exposed alongside web.search; use web.search for ordinary raw or multi-provider retrieval and this tool when a synthesized Bocha answer is useful. Sources carry the same index-metadata semantics as web.search (searchMetadataOnly, not fetched-page verification); use web.fetch before relying on actual page facts. It never opens the visual browser."
    public static let parametersJSON = #"""
    {
      "type":"object",
      "properties":{
        "query":{"type":"string","description":"Natural-language research question"},
        "recencyDays":{"type":"integer","minimum":1,"maximum":1825},
        "maxResults":{"type":"integer","minimum":1,"maximum":50,"description":"Maximum number of returned results; defaults to 5 when omitted"}
      },
      "required":["query"],
      "additionalProperties":false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let service: WebSearchService
    public init(service: WebSearchService) { self.service = service }

    public func validate(_ args: Arguments) throws {
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 2_000 else {
            throw FloeError.validationFailed("query must contain 1-2000 UTF-8 bytes")
        }
        if let max = args.maxResults, !(1...50).contains(max) {
            throw FloeError.validationFailed("maxResults must be 1-50")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let response = try await service.search(WebSearchQuery(
            text: args.query.trimmingCharacters(in: .whitespacesAndNewlines),
            mode: .balanced,
            recencyDays: args.recencyDays,
            maxResults: args.maxResults ?? WebSearchTool.defaultMaxResults,
            requestedProvider: WebSearchProviderKind.bochaWeb.rawValue,
            summaryEnabled: true
        ))
        return try WebSearchTool.output(response)
    }
}
