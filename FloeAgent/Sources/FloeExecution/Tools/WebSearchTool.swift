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
        /// Explicit source selector: nil/`web` keeps the historical public-web
        /// semantics byte-for-byte; `professional` routes the exact query to a
        /// configured Volcengine DataPro dataset account. Unknown values are
        /// validation errors, never silent defaults.
        public var source: String?
    }

    public static let name = "web.search"

    /// Sane bounded request default when the model omits `maxResults`. It
    /// matches the existing in-app search-test default (`WebSearchService
    /// .searchTest` / `testSearch` use 5) and the catalog-backed provider
    /// editors. The complete normalized response is always retained in the
    /// tool capture; this default only limits the number of provider rows a
    /// single call requests (and therefore the immediate UI page). Explicit
    /// valid limits (1...50) keep their exact meaning.
    public static let defaultMaxResults = 5

    /// Minimum characters a kept row's snippet should retain to stay useful
    /// to the model. When even this floor cannot fit, trailing rows are
    /// dropped first (explicit `returned`/`omittedResults`/`truncated`
    /// markers) instead of shortening every snippet to noise.
    static let minimumUsefulSnippetCharacters = 64

    public static let toolDescription =
        "Search the public web without opening the visual browser. Returns normalized titles, URLs, snippets, index metadata (page_age = published OR last modified date, relative age, crawl date, source profile/favicon), provider provenance, citation IDs and an explicit contentState=searchMetadataOnly. Index metadata is NOT page verification: excerpts and dates come from the search index; use web.fetch (or browser tools when interaction is required) before relying on actual page contents, publication dates or quotes. Some providers also return a bounded provider-generated answer, marked separately from URL citations and still not fetched-page evidence. Providers may also return long summaries or provider-supplied page content; both are unverified provider text, kept separate from the short snippet and the local web.fetch result. Use fast for one search provider, balanced for ordinary research, or deep to query up to three configured providers concurrently. Set source=professional to search a configured Volcengine DataPro professional dataset account (academic literature, company registration/risk, securities/finance, vehicle specifications/sales, legislation and court cases) with the exact query; it accepts only query and provider, returns an untrusted professionalDatasetSummary envelope instead of page citations, and never falls back to or from public web providers. Professional dataset search is unavailable in temporary/public-web-only chats and fails clearly when no DataPro account is configured."
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
        "provider":{"type":"string","description":"Optional configured provider name, kind, or UUID; with source=professional selects one configured DataPro account"},
        "source":{"type":"string","enum":["web","professional"],"description":"Search source; defaults to web (public web providers). professional routes the exact query to a configured Volcengine DataPro dataset account with no cross-source fallback"}
      },
      "required":["query"],
      "additionalProperties":false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let service: WebSearchService
    /// Professional-source execution seam. `nil` (default) leaves the
    /// professional source unconfigured: it fails clearly instead of silently
    /// rerouting to public web providers.
    private let professional: (any WebSearchProfessionalExecuting)?

    public init(
        service: WebSearchService,
        professional: (any WebSearchProfessionalExecuting)? = nil
    ) {
        self.service = service
        self.professional = professional
    }

    /// Strict source parsing shared by validate/execute: an unknown selector
    /// is an error, never a silent web default.
    static func parsedSource(_ raw: String?) throws -> WebSearchSource {
        guard let raw else { return .web }
        guard let source = WebSearchSource(rawValue: raw) else {
            throw FloeError.validationFailed("source must be web or professional")
        }
        return source
    }

    public func validate(_ args: Arguments) throws {
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 2_000 else {
            throw FloeError.validationFailed("query must contain 1-2000 UTF-8 bytes")
        }
        let source = try Self.parsedSource(args.source)
        if source == .professional {
            // The reviewed DataPro adapter accepts one exact dataset question
            // only. Web-only refinements are rejected with an actionable
            // message rather than silently dropped or half-applied.
            var rejected: [String] = []
            if args.mode != nil { rejected.append("mode") }
            if args.domains != nil { rejected.append("domains") }
            if args.excludeDomains != nil { rejected.append("excludeDomains") }
            if args.recencyDays != nil { rejected.append("recencyDays") }
            if args.maxResults != nil { rejected.append("maxResults") }
            guard rejected.isEmpty else {
                throw FloeError.validationFailed(
                    "source=professional accepts only query and provider; remove \(rejected.joined(separator: ", "))"
                )
            }
            return
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
        let source = try Self.parsedSource(args.source)
        if source == .professional {
            return try await executeProfessionalSearch(args, context: context)
        }
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

    /// Professional branch of the ONE native web.search tool. The base
    /// descriptor stays readOnly/networkAccess and no approval-identity copy
    /// is made. Only the frozen account registry's exact DataPro query adapter
    /// runs; generic MCP methods keep their conservative mutating approval.
    private func executeProfessionalSearch(
        _ args: Arguments,
        context: ToolContext
    ) async throws -> ToolExecutionOutput {
        guard !context.publicWebOnly,
              !context.temporaryReadOnly,
              context.allowedToolNames?.contains(Self.name) != false,
              context.frozenEffectiveCatalogNames?.contains(Self.name) != false else {
            throw FloeError.validationFailed("Professional search is outside this task's tool ceiling")
        }
        guard let authority = context.professionalSearchAuthority else {
            throw WebSearchProfessionalError.authorityUnavailable
        }
        guard authority.allowsProfessionalSource else {
            throw FloeError.validationFailed("Professional search is outside this task's tool ceiling")
        }
        guard let professional else {
            throw WebSearchProfessionalError.notConfigured
        }
        let instance = try WebSearchProfessionalRouting.selectInstance(
            professional.instances(context: context),
            requestedProvider: args.provider
        )
        let output = try await professional.execute(
            instance: instance,
            query: args.query.trimmingCharacters(in: .whitespacesAndNewlines),
            context: context
        )
        try context.cancellation.throwIfCancelled()
        return output
    }

    /// Shared, backward-compatible serialization for both search tools. Two
    /// outputs are produced from the SAME normalized `WebSearchResponse`:
    ///
    /// 1. a complete, sanitized capture (`capturedOutput`) that preserves
    ///    every normalized row, snippet, long summary/content and provider
    ///    answer byte-for-byte after provider normalization; and
    /// 2. a bounded UI projection (`summary`, <= `maximumCharacters`) that
    ///    is always valid JSON and carries explicit truncation/omission
    ///    markers.
    ///
    /// The digest is over the complete capture, not over the UI projection:
    /// the previous implementation shrank rows/snippets into the 4_096-
    /// character page BEFORE constructing `ToolExecutionOutput`, so the
    /// runtime could not recover the provider's tail. The capture is
    /// normalized data only — never a raw provider body, headers or secret.
    /// The context planner decides whether to inline the capture or page it.
    ///
    /// The UI projection is bounded because the runtime prefixes ordinary
    /// tool summaries with a hard 4096-character cut. Bounding accounts for
    /// JSON escape inflation, not just source characters: top-level
    /// query/failure text and every result field are bounded, then
    /// long-summary/content, answers, snippets/extras and optionally trailing
    /// rows are reduced. A citation URL is NEVER shortened to fit: a row
    /// whose exact target cannot be preserved is omitted explicitly
    /// (`omittedOversizeURLRows`) instead of returning a changed citation. A
    /// citation/title is never invented from another field.
    static func output(
        _ response: WebSearchResponse,
        maximumCharacters: Int = 4_096
    ) throws -> ToolExecutionOutput {
        let fullCapture = Self.fullOutput(response)
        let captureDigest = FloeDigest.sha256Hex(Data(fullCapture.utf8))
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
        var additionalLimit = 0
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
        // honest. The ladder remains the safety net for JSON escape
        // inflation and pathological budgets.
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
            let longTextRows = eligible.prefix(max(0, included)).filter {
                !($0.summary?.isEmpty ?? true) || !($0.content?.isEmpty ?? true)
            }.count
            if longTextRows > 0 {
                // Long summary/content is useful but secondary to the exact
                // citation and short snippet. Split the remaining room per
                // row; the ladder below shrinks it further when JSON escaping
                // or generated answers need the space.
                additionalLimit = min(
                    1_200,
                    max(0, sizing.roomAfterSnippets / max(1, longTextRows))
                )
            }
        }

        while true {
            let (summary, _) = serialize(
                response,
                eligibleResults: eligible,
                included: included,
                snippetLimit: snippetLimit,
                extraLimit: extraLimit,
                additionalLimit: additionalLimit,
                answerLimit: answerLimit,
                titleCap: 300,
                queryCap: queryCap,
                failureCap: failureCap,
                omittedOversizeURLRows: omittedOversizeURLRows
            )
            if summary.count <= maximumCharacters {
                return ToolExecutionOutput(
                    summary: summary,
                    fullOutputSHA256: captureDigest,
                    exitStatus: 0,
                    maximumSummaryCharacters: maximumCharacters,
                    capturedOutput: fullCapture,
                    capturedOutputTruncated: false
                )
            }
            // 1. shrink a provider-generated answer first; it is auxiliary
            // text, while URL citations must stay whole and visible;
            // 2. shrink long summary/content (it is fully present in the
            //    capture), then additional excerpts;
            // 3. shrink snippets (rows and citations survive);
            // 4. shrink the top-level query/failure text (still visible);
            // 5. drop trailing rows; 6. shrink metadata further.
            if answerLimit > 0, !response.generatedAnswers.isEmpty {
                answerLimit = answerLimit > 200 ? answerLimit / 2 : 0
                continue
            }
            if additionalLimit > 0 {
                additionalLimit /= 2
                continue
            }
            if extraLimit > 0 {
                extraLimit /= 2
                continue
            }
            if snippetLimit > 0 {
                snippetLimit /= 2
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
            // bounded error page instead of truncated JSON. The complete
            // capture remains attached.
            return try budgetFallback(
                response,
                maximumCharacters: maximumCharacters,
                omittedOversizeURLRows: omittedOversizeURLRows,
                capturedOutput: fullCapture,
                capturedOutputDigest: captureDigest
            )
        }
    }

    /// Complete normalized capture. No result is dropped, no snippet,
    /// long-summary, content or generated answer is shortened, and every
    /// normalized metadata field is retained. This is not raw provider JSON:
    /// it is the same sanitized model the UI projection uses.
    static func fullOutput(_ response: WebSearchResponse) -> String {
        let entries = response.results.map { result -> [String: Any] in
            var row: [String: Any] = [
                "citation": result.citationID,
                "title": result.title,
                "url": result.url.absoluteString,
                "snippet": result.snippet,
                "extraSnippets": result.extraSnippets ?? [],
                "summary": result.summary ?? "",
                "content": result.content ?? "",
                "source": result.sourceName ?? "",
                "publishedAt": result.publishedAt ?? "",
                "provider": result.provider.rawValue,
                "pageAge": result.pageAge ?? "",
                "relativeAge": result.relativeAge ?? "",
                "pageFetched": result.pageFetched ?? "",
                "sourceProfile": result.sourceProfileName ?? "",
                "sourceProfileURL": result.sourceProfileURL ?? "",
                "favicon": result.faviconURL ?? "",
                "displayPath": result.displayPath ?? "",
                "contentState": result.effectiveContentState.rawValue
            ]
            if let score = result.score { row["score"] = score }
            if let authority = result.authority { row["authority"] = authority }
            return row
        }
        var payload: [String: Any] = [
            "captureSchemaVersion": 1,
            "captureState": "normalizedFullResponse",
            "query": response.query,
            "providers": response.providersUsed.map(\.rawValue),
            "failures": response.failures,
            "evidenceState": "searchMetadataOnly",
            "pageVerification": "notFetched",
            "pageFetchTool": "web.fetch",
            "metadataNote": metadataNote,
            "returned": entries.count,
            "available": response.results.count,
            "truncated": false,
            "omittedResults": 0,
            "results": entries
        ]
        if !response.generatedAnswers.isEmpty {
            payload["generatedAnswers"] = response.generatedAnswers.map { answer in
                [
                    "provider": answer.provider.rawValue,
                    "answer": answer.text,
                    "answerTruncated": answer.truncated,
                    "originalCharacters": answer.originalCharacters
                ] as [String: Any]
            }
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Hard cap for a citation target URL. A longer URL cannot be returned
    /// exactly inside the bounded payload, so its row is omitted explicitly
    /// rather than returned with a changed target.
    static let maximumCitationURLLength = 1_024

    /// Measures one serialization with zeroed snippet/excerpt/long-summary
    /// text and returns the largest equal snippet character cap whose ACTUAL
    /// emitted snippet total (sum of min(length, cap) over kept rows) still
    /// fits the remaining payload room, plus the room left for
    /// `extraSnippets` and long summary/content. Water-filling over real
    /// lengths means short excerpts are never shortened and their unused
    /// budget goes to longer excerpts. Pure function of the response and
    /// budgets: the result is deterministic.
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
            additionalLimit: 0,
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

    private static let metadataNote = "Snippets, dates and profiles come from the search index, not from a fetched page. Provider-returned summary/content text is provider-supplied and unverified. pageAge is the page's published OR last modified date; relativeAge is relative; never treat index metadata or provider text as verified page content. Snippets marked snippetTruncated were shortened only in this display projection; the complete normalized response remains in the runtime capture."

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

    /// Builds one bounded UI payload. Returns the serialized JSON and whether
    /// anything was shortened (query, failures, snippets, long summary/
    /// content, extras or fields) or omitted (trailing rows, or rows whose
    /// URL cannot be preserved).
    private static func serialize(
        _ response: WebSearchResponse,
        eligibleResults: [WebSearchResult],
        included: Int,
        snippetLimit: Int,
        extraLimit: Int,
        additionalLimit: Int,
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
            var summary: String?
            if let value = result.summary {
                summary = bound(value, additionalLimit, "summary", &fields)
            }
            let summaryTruncated = (result.summary?.count ?? 0) > (summary?.count ?? 0)
            var content: String?
            if let value = result.content {
                content = bound(value, additionalLimit, "content", &fields)
            }
            let contentTruncated = (result.content?.count ?? 0) > (content?.count ?? 0)
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
            if snippetTruncated || summaryTruncated || contentTruncated
                || extrasTruncated || !fields.isEmpty {
                truncated = true
            }
            var row: [String: Any] = [
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
            ]
            // Long summary/content stay separate from the short snippet so the
            // model never mistakes one for the other. They are optional in the
            // model and only appear here when the provider supplied them; the
            // complete original text is in `capturedOutput`.
            if let summary, let original = result.summary {
                row["summary"] = summary
                row["summaryTruncated"] = summaryTruncated
                row["originalSummaryChars"] = original.count
            }
            if let content, let original = result.content {
                row["content"] = content
                row["contentTruncated"] = contentTruncated
                row["originalContentChars"] = original.count
            }
            if let score = result.score { row["score"] = score }
            if let authority = result.authority { row["authority"] = authority }
            return row
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
        omittedOversizeURLRows: Int,
        capturedOutput: String,
        capturedOutputDigest: String
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
                    fullOutputSHA256: capturedOutputDigest,
                    exitStatus: 0,
                    maximumSummaryCharacters: maximumCharacters,
                    capturedOutput: capturedOutput,
                    capturedOutputTruncated: false
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
            fullOutputSHA256: capturedOutputDigest,
            exitStatus: 0,
            maximumSummaryCharacters: maximumCharacters,
            capturedOutput: capturedOutput,
            capturedOutputTruncated: false
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
