import Crypto
import Foundation
import FloeCore
import FloeTools

/// Parsed provider output. URL citations and a provider-generated answer stay
/// separate so model text is never relabeled as per-URL evidence.
struct WebSearchProviderOutput: Sendable {
    var results: [WebSearchResult]
    var generatedAnswer: WebSearchProviderGeneratedAnswer?
}

public actor WebSearchService {
    /// Internal for privacy-audit tests: the transport configuration must
    /// stay ephemeral (no shared on-disk cache/cookie/credential state).
    let session: URLSession
    private let configurations: WebSearchConfigurationResolver
    private let validateDestination: @Sendable (URL, Bool) throws -> Void

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        configurations: @escaping WebSearchConfigurationResolver = { [] }
    ) {
        let validator: @Sendable (URL, Bool) throws -> Void = { url, allowTransient in
            try PublicNetworkTargetPolicy.validate(
                url,
                allowTransientTunnelAddresses: allowTransient
            )
        }
        // Redirects from provider endpoints are revalidated against the strict
        // public policy and cross-origin credentials are stripped.
        self.session = URLSession(
            configuration: configuration,
            delegate: SearchProviderRedirectDelegate(validateDestination: { url in
                try validator(url, false)
            }),
            delegateQueue: nil
        )
        self.configurations = configurations
        self.validateDestination = validator
    }

    /// Internal seam for integration tests to supply repeatable DNS answers.
    /// The public initializer above always uses system DNS and the same policy.
    init(
        configuration: URLSessionConfiguration,
        configurations: @escaping WebSearchConfigurationResolver,
        validateDestination: @escaping @Sendable (URL, Bool) throws -> Void
    ) {
        self.session = URLSession(
            configuration: configuration,
            delegate: SearchProviderRedirectDelegate(validateDestination: { url in
                try validateDestination(url, false)
            }),
            delegateQueue: nil
        )
        self.configurations = configurations
        self.validateDestination = validateDestination
    }

    /// Local readiness only: no network probe, no credential value in diagnostics.
    public nonisolated static func isConfigured(_ configuration: WebSearchProviderConfiguration, credential: WebSearchCredential) -> Bool {
        guard configuration.enabled else { return false }
        let cleaned = WebSearchCredential(values: credential.values.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard let request = try? makeRequest(configuration, credential: cleaned, query: .init(text: "configuration-check")),
              let url = request.url, ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil else { return false }
        return true
    }

    public func search(_ query: WebSearchQuery) async throws -> WebSearchResponse {
        let traceID = UUID().uuidString
        let startedAt = Date()
        // Single bounded effective limit for the whole call. Request
        // construction already clamps to 1...50; decode, aggregation and
        // dedup honor the SAME bound so a server-overreturning gateway or a
        // pathological caller can never widen the returned set beyond what
        // the request asked for.
        let resultLimit = max(1, min(query.maxResults, 50))
        let available = await configurations()
            .filter { Self.isConfigured($0.0, credential: $0.1) }
            .sorted { $0.0.priority < $1.0.priority }
        guard !available.isEmpty else {
            FloeLogger(category: .tools).warning("webSearchUnavailable trace=\(traceID) reason=noProviderConfigured")
            throw WebRetrievalError.noProviderConfigured
        }

        let selected: [(WebSearchProviderConfiguration, WebSearchCredential)]
        if let requested = query.requestedProvider?.lowercased() {
            selected = available.filter {
                $0.0.id.uuidString.lowercased() == requested
                    || $0.0.kind.rawValue.lowercased() == requested
                    || $0.0.displayName.lowercased() == requested
            }
            guard !selected.isEmpty else { throw WebRetrievalError.providerNotFound(requested) }
        } else {
            let count = query.mode == .deep ? min(3, available.count) : 1
            selected = Array(available.prefix(count))
        }
        FloeLogger(category: .tools).info(
            "webSearchStarted trace=\(traceID) mode=\(query.mode.rawValue) configured=\(available.count) selected=\(selected.map { $0.0.kind.rawValue }.joined(separator: ",")) maxResults=\(resultLimit) recencyDays=\(query.recencyDays ?? 0) domainFilters=\(query.domains.count) excludedDomains=\(query.excludedDomains.count)"
        )

        var combined: [WebSearchResult] = []
        var used: [WebSearchProviderKind] = []
        var failures: [String] = []
        var generatedAnswers: [WebSearchProviderGeneratedAnswer] = []

        if query.mode == .deep, selected.count > 1 {
            await withTaskGroup(of: ProviderOutcome.self) { group in
            for item in selected {
                group.addTask { [self] in
                    await run(item.0, credential: item.1, query: query, traceID: traceID, limit: resultLimit)
                }
            }
                for await outcome in group {
                    switch outcome {
                    case .success(let kind, let results, let answer):
                        used.append(kind)
                        combined.append(contentsOf: results)
                        if let answer { generatedAnswers.append(answer) }
                    case .failure(let value): failures.append(value)
                    }
                }
            }
        } else {
            // Fast/balanced use ordered failover. An empty result is
            // insufficient evidence and advances to the next provider. A
            // provider-generated answer without URL citations is real output,
            // not an empty result, so it stops the failover and travels to
            // the tool unchanged.
            let failoverCandidates = query.requestedProvider == nil ? available : selected
            for item in failoverCandidates {
                let outcome = await run(item.0, credential: item.1, query: query, traceID: traceID, limit: resultLimit)
                var succeeded = false
                switch outcome {
                case .success(let kind, let results, let answer)
                    where !results.isEmpty || answer != nil:
                    used.append(kind)
                    combined = results
                    if let answer { generatedAnswers.append(answer) }
                    succeeded = true
                case .success(let kind, _, _):
                    failures.append("\(kind.rawValue): empty result")
                case .failure(let value):
                    failures.append(value)
                }
                if succeeded { break }
                if query.requestedProvider != nil { break }
            }
        }

        let normalized = Self.deduplicate(combined, limit: resultLimit)
        guard !normalized.isEmpty || !generatedAnswers.isEmpty else {
            FloeLogger(category: .tools).warning(
                "webSearchFailed trace=\(traceID) attempts=\(selected.count) failures=\(failures.count) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            throw WebRetrievalError.allProvidersFailed(failures)
        }
        FloeLogger(category: .tools).info(
            "webSearchFinished trace=\(traceID) providers=\(used.map(\.rawValue).joined(separator: ",")) rawResults=\(combined.count) results=\(normalized.count) answers=\(generatedAnswers.count) failures=\(failures.count) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
        )
        return WebSearchResponse(
            query: query.text,
            results: normalized,
            providersUsed: used,
            failures: failures,
            generatedAnswers: generatedAnswers
        )
    }

    private enum ProviderOutcome: Sendable {
        case success(
            WebSearchProviderKind,
            [WebSearchResult],
            WebSearchProviderGeneratedAnswer?
        )
        case failure(String)
    }

    /// Canonical public endpoints of the fixed commercial providers. The
    /// fake-IP tunnel relaxation is bound to the (provider kind, endpoint)
    /// pair, not to a host name alone: a `.custom` provider pointing at one
    /// of these hosts gets no relaxation, and neither does a provider whose
    /// endpoint was overridden (even to another canonical-looking host).
    static let canonicalEndpoints: [WebSearchProviderKind: URL] = [
        .bochaWeb: URL(string: "https://api.bochaai.com/v1/web-search")!,
        .bochaAI: URL(string: "https://api.bochaai.com/v1/web-search")!,
        .tencentWSA: URL(string: "https://wsa.tencentcloudapi.com")!,
        .brave: URL(string: "https://api.search.brave.com/res/v1/web/search")!,
        .tavily: URL(string: "https://api.tavily.com/search")!,
        .exa: URL(string: "https://api.exa.ai/search")!,
        .googleProgrammable: URL(string: "https://customsearch.googleapis.com/customsearch/v1")!
    ]

    static let volcengineFeedcoopEndpoint = URL(
        string: "https://open.feedcoopapi.com/search_api/web_search"
    )!
    static let volcengineArkResponsesEndpoint = URL(
        string: "https://ark.cn-beijing.volces.com/api/v3/responses"
    )!

    /// The exact canonical endpoint for a configuration. Volcengine has two
    /// separate origins selected by its stored interface; a legacy custom
    /// endpoint or an absent interface has no canonical origin and therefore
    /// no fake-IP tunnel relaxation. Other kinds keep their single entry.
    static func canonicalEndpoint(for configuration: WebSearchProviderConfiguration) -> URL? {
        guard configuration.endpoint == nil else { return nil }
        guard configuration.kind == .volcengine else {
            return canonicalEndpoints[configuration.kind]
        }
        guard let options = try? VolcengineSearchOptions(options: configuration.options),
              let interface = options.interface else { return nil }
        switch interface {
        case .agentPlan, .doubaoSearch:
            return volcengineFeedcoopEndpoint
        case .arkResponses:
            return volcengineArkResponsesEndpoint
        }
    }

    /// Whether the effective request URL produced by `makeRequest` matches the
    /// canonical contract for its kind on scheme, host, port and path. Query
    /// and fragment are deliberately ignored: some canonical requests (Brave,
    /// Google) carry generated query parameters, and fragments are not sent.
    static func requestURLIsCanonical(_ url: URL?, kind: WebSearchProviderKind) -> Bool {
        guard let url, let canonical = canonicalEndpoints[kind] else { return false }
        guard let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else {
            return false
        }
        return actual.scheme?.lowercased() == expected.scheme?.lowercased()
            && actual.host?.lowercased() == expected.host?.lowercased()
            && (actual.port ?? 443) == (expected.port ?? 443)
            && actual.path == expected.path
    }

    static func requestURLIsCanonical(
        _ url: URL?,
        configuration: WebSearchProviderConfiguration
    ) -> Bool {
        guard let url, let canonical = canonicalEndpoint(for: configuration) else {
            return false
        }
        guard let actual = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else {
            return false
        }
        return actual.scheme?.lowercased() == expected.scheme?.lowercased()
            && actual.host?.lowercased() == expected.host?.lowercased()
            && (actual.port ?? 443) == (expected.port ?? 443)
            && actual.path == expected.path
    }

    /// Decide whether this provider configuration may accept addresses in
    /// the 198.18.0.0/15 fake-IP tunnel range. Requirements:
    /// 1. the provider kind is one of the fixed built-in commercial kinds;
    /// 2. the effective endpoint is the configuration's canonical endpoint —
    ///    an explicit endpoint override forfeits the relaxation;
    /// 3. the scheme is HTTPS and the port is absent or 443.
    static func allowsTransientTunnel(for configuration: WebSearchProviderConfiguration) -> Bool {
        guard let canonical = canonicalEndpoint(for: configuration) else { return false }
        // An override always forfeits; makeRequest would use it verbatim.
        guard configuration.endpoint == nil else { return false }
        guard let components = URLComponents(url: canonical, resolvingAgainstBaseURL: false) else {
            return false
        }
        guard components.scheme?.lowercased() == "https" else { return false }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return false }
        if let port = components.port { return port == 443 }
        return true
    }

    private func run(
        _ configuration: WebSearchProviderConfiguration,
        credential: WebSearchCredential,
        query: WebSearchQuery,
        traceID: String,
        limit: Int
    ) async -> ProviderOutcome {
        let startedAt = Date()
        do {
            let request = try Self.makeRequest(configuration, credential: credential, query: query)
            FloeLogger(category: .tools).debug(
                "webSearchProviderStarted trace=\(traceID) provider=\(configuration.kind.rawValue) host=\(request.url?.host ?? "none") method=\(request.httpMethod ?? "GET")"
            )
            // Only a fixed built-in provider endpoint (provider kind + canonical
            // HTTPS host/path + default port) tolerates fake-IP tunnel answers
            // in 198.18.0.0/15; custom endpoints and endpoint overrides stay
            // strict. The request URL's generated query is ignored in the match
            // (Brave/Google encode parameters in the query), but scheme, host,
            // port and path must equal the canonical contract.
            let allowsTransient = Self.allowsTransientTunnel(for: configuration)
                && Self.requestURLIsCanonical(request.url, configuration: configuration)
            try validateDestination(request.url!, allowsTransient)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                FloeLogger(category: .tools).warning(
                    "webSearchProviderFailed trace=\(traceID) provider=\(configuration.kind.rawValue) status=\(status) responseBytes=\(data.count) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
                )
                return .failure("\(configuration.kind.rawValue): HTTP \(status)")
            }
            let output = try Self.parseOutput(
                data,
                provider: configuration.kind,
                limit: limit
            )
            FloeLogger(category: .tools).info(
                "webSearchProviderFinished trace=\(traceID) provider=\(configuration.kind.rawValue) status=\(http.statusCode) responseBytes=\(data.count) results=\(output.results.count) answerChars=\(output.generatedAnswer?.text.count ?? 0) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            return .success(configuration.kind, output.results, output.generatedAnswer)
        } catch {
            let nsError = error as NSError
            FloeLogger(category: .tools).warning(
                "webSearchProviderError trace=\(traceID) provider=\(configuration.kind.rawValue) domain=\(nsError.domain) code=\(nsError.code) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            return .failure("\(configuration.kind.rawValue): \(error.localizedDescription)")
        }
    }

    static func makeRequest(
        _ configuration: WebSearchProviderConfiguration,
        credential: WebSearchCredential,
        query: WebSearchQuery,
        now: Date = Date()
    ) throws -> URLRequest {
        let count = max(1, min(query.maxResults, 50))
        let apiKey = credential["apiKey"] ?? ""
        var request: URLRequest
        switch configuration.kind {
        case .bochaWeb, .bochaAI:
            guard !apiKey.isEmpty else { throw WebRetrievalError.missingCredential("apiKey") }
            // Bocha's currently documented public API is Web Search. The old
            // separate /ai-search preset returned HTTP 406 for valid keys.
            // Summary enrichment is an option on the same provider/key.
            request = try post(configuration.endpoint ?? URL(string: "https://api.bochaai.com/v1/web-search")!, json: [
                "query": query.text,
                "summary": query.summaryEnabled
                    ?? (configuration.options["summaryEnabled"] != "false"),
                "freshness": Self.bochaFreshness(days: query.recencyDays),
                "count": count
            ])
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        case .tencentWSA:
            guard let secretID = credential["secretId"], !secretID.isEmpty else {
                throw WebRetrievalError.missingCredential("secretId")
            }
            guard let secretKey = credential["secretKey"], !secretKey.isEmpty else {
                throw WebRetrievalError.missingCredential("secretKey")
            }
            let endpoint = configuration.endpoint ?? URL(string: "https://wsa.tencentcloudapi.com")!
            var body: [String: Any] = ["Query": query.text, "Cnt": Self.tencentCount(count)]
            if let days = query.recencyDays { body["Freshness"] = "d\(max(1, min(days, 30)))" }
            if let domain = query.domains.first { body["Site"] = domain }
            request = try post(endpoint, json: body)
            Self.signTencent(
                request: &request,
                body: request.httpBody ?? Data(),
                secretID: secretID,
                secretKey: secretKey,
                now: now
            )

        case .brave:
            guard !apiKey.isEmpty else { throw WebRetrievalError.missingCredential("apiKey") }
            let endpoint = configuration.endpoint ?? URL(string: "https://api.search.brave.com/res/v1/web/search")!
            var items: [URLQueryItem] = [
                URLQueryItem(name: "q", value: query.text),
                URLQueryItem(name: "count", value: String(min(count, 20))),
                // Documented optional parameters on the SAME endpoint:
                // additional excerpts plus fetch metadata (page_fetched).
                URLQueryItem(name: "extra_snippets", value: "true"),
                URLQueryItem(name: "include_fetch_metadata", value: "true")
            ]
            if let freshness = Self.braveFreshness(days: query.recencyDays, now: now) {
                items.append(URLQueryItem(name: "freshness", value: freshness))
            }
            request = try get(endpoint, query: items)
            request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")

        case .tavily:
            guard !apiKey.isEmpty else { throw WebRetrievalError.missingCredential("apiKey") }
            request = try post(configuration.endpoint ?? URL(string: "https://api.tavily.com/search")!, json: [
                "api_key": apiKey, "query": query.text, "max_results": count,
                "search_depth": query.mode == .fast ? "basic" : "advanced",
                "include_domains": query.domains, "exclude_domains": query.excludedDomains
            ])

        case .exa:
            guard !apiKey.isEmpty else { throw WebRetrievalError.missingCredential("apiKey") }
            request = try post(configuration.endpoint ?? URL(string: "https://api.exa.ai/search")!, json: [
                "query": query.text, "numResults": count, "useAutoprompt": true
            ])
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        case .googleProgrammable:
            guard !apiKey.isEmpty else { throw WebRetrievalError.missingCredential("apiKey") }
            guard let engineID = credential["engineId"], !engineID.isEmpty else {
                throw WebRetrievalError.missingCredential("engineId")
            }
            request = try get(
                configuration.endpoint ?? URL(string: "https://customsearch.googleapis.com/customsearch/v1")!,
                query: [URLQueryItem(name: "key", value: apiKey), URLQueryItem(name: "cx", value: engineID),
                        URLQueryItem(name: "q", value: query.text), URLQueryItem(name: "num", value: String(min(count, 10)))]
            )

        case .searxng:
            guard let endpoint = configuration.endpoint else {
                throw WebRetrievalError.invalidResponse("SearXNG endpoint is required")
            }
            request = try get(endpoint, query: [URLQueryItem(name: "q", value: query.text),
                                                URLQueryItem(name: "format", value: "json")])

        case .volcengine:
            request = try volcengineRequest(
                configuration,
                credential: credential,
                query: query,
                count: count,
                now: now
            )

        case .custom:
            guard let endpoint = configuration.endpoint else {
                throw WebRetrievalError.invalidResponse("A provider endpoint is required")
            }
            guard !apiKey.isEmpty else { throw WebRetrievalError.missingCredential("apiKey") }
            request = try post(endpoint, json: ["query": query.text, "count": count])
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Volcengine has three real account/interface products plus the original
    /// generic custom-endpoint configuration. The latter is selected only by
    /// the ABSENCE of an interface (or by an explicit endpoint override), so
    /// old stored records keep their exact request, endpoint and credential.
    private static func volcengineRequest(
        _ configuration: WebSearchProviderConfiguration,
        credential: WebSearchCredential,
        query: WebSearchQuery,
        count: Int,
        now: Date
    ) throws -> URLRequest {
        let apiKey = credential["apiKey"] ?? ""
        let rawInterface = configuration.options[VolcengineSearchOptions.Key.interface]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawInterface.isEmpty {
            return try legacyVolcengineRequest(
                configuration,
                apiKey: apiKey,
                query: query,
                count: count
            )
        }
        guard let interface = VolcengineSearchInterface(rawValue: rawInterface) else {
            throw WebRetrievalError.invalidResponse(
                "Unknown Volcengine interface selection"
            )
        }
        if configuration.endpoint != nil {
            // A custom endpoint belongs to the legacy contract. Keeping it
            // alongside a new interface would silently send the selected
            // credential to a different destination.
            throw WebRetrievalError.invalidResponse(
                "Volcengine interface settings cannot be combined with a custom endpoint"
            )
        }
        guard !apiKey.isEmpty else { throw WebRetrievalError.missingCredential("apiKey") }
        let options = try VolcengineSearchOptions(options: configuration.options)

        switch interface {
        case .arkResponses:
            return try arkResponsesRequest(
                options: options,
                apiKey: apiKey,
                query: query,
                count: count
            )
        case .agentPlan, .doubaoSearch:
            return try doubaoSearchRequest(
                options: options,
                apiKey: apiKey,
                query: query,
                count: count,
                now: now
            )
        }
    }

    /// The original pre-integration contract: POST {query,count} to the
    /// user-supplied endpoint with the same Bearer credential account.
    private static func legacyVolcengineRequest(
        _ configuration: WebSearchProviderConfiguration,
        apiKey: String,
        query: WebSearchQuery,
        count: Int
    ) throws -> URLRequest {
        guard let endpoint = configuration.endpoint else {
            // Pre-integration behavior required an endpoint; a stored legacy
            // record must not be silently promoted to a different product.
            throw WebRetrievalError.invalidResponse(
                "Select a Volcengine account/interface or configure a custom endpoint"
            )
        }
        guard !apiKey.isEmpty else { throw WebRetrievalError.missingCredential("apiKey") }
        var request = try post(endpoint, json: ["query": query.text, "count": count])
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Standalone Ark Responses request. It is intentionally independent of
    /// the parent Agent request: the visible model adapter and function/MCP
    /// tool list are never changed, and the same Office tools stay available.
    private static func arkResponsesRequest(
        options: VolcengineSearchOptions,
        apiKey: String,
        query: WebSearchQuery,
        count: Int
    ) throws -> URLRequest {
        // Ark web_search citations do not support provider-side domain or
        // recency filters. Reject them with an actionable error instead of
        // pretending they were applied.
        guard query.domains.isEmpty, query.excludedDomains.isEmpty, query.recencyDays == nil else {
            throw WebRetrievalError.invalidResponse(
                "Ark Responses search does not support domain or recency filters; use the Agent Plan interface"
            )
        }
        var tool: [String: Any] = ["type": "web_search"]
        switch options.arkEngine {
        case .doubaoCustom:
            // Doubao Search Custom is an exclusive engine: it must never be
            // mixed with the online-content sources.
            tool["sources"] = ["doubao"]
        case .onlineContent:
            // Latest explicit product decision: one switch for the plugin
            // interface, with all three content sources enabled together.
            tool["sources"] = ["toutiao", "douyin", "moji"]
            // `limit` is supported by the online-content plugin only; its
            // effective per-search ceiling is 20.
            tool["limit"] = min(max(1, count), 20)
        }
        let body: [String: Any] = [
            "model": options.arkModel,
            "stream": false,
            "input": query.text,
            "tools": [tool],
            // Verified official range is 1...10. A web.search call answers
            // one request, so one tool round bounds cost and latency.
            "max_tool_calls": 1
        ]
        var request = try post(volcengineArkResponsesEndpoint, json: body)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Direct Doubao Search Custom HTTP API, shared by the Agent Plan and
    /// separate Doubao Search product credentials. Only the Keychain account
    /// differs; the request contract is identical.
    private static func doubaoSearchRequest(
        options: VolcengineSearchOptions,
        apiKey: String,
        query: WebSearchQuery,
        count: Int,
        now: Date
    ) throws -> URLRequest {
        let trimmedQuery = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw WebRetrievalError.invalidResponse("Volcengine search query is empty")
        }
        // The vendor's documented limit is 1...100 characters. A longer query
        // is rejected rather than silently truncated (which would change the
        // user's search).
        guard trimmedQuery.count <= 100 else {
            throw WebRetrievalError.invalidResponse(
                "Volcengine Doubao Search accepts queries up to 100 characters; shorten the query"
            )
        }

        var filter: [String: Any] = [
            "AuthInfoLevel": options.authoritativeOnly ? 1 : 0,
            "NeedContent": false,
            "NeedUrl": true
        ]
        if !query.domains.isEmpty {
            filter["Sites"] = try volcengineDomainList(
                query.domains,
                maximum: 20,
                field: "sites"
            )
        }
        if !query.excludedDomains.isEmpty {
            filter["BlockHosts"] = try volcengineDomainList(
                query.excludedDomains,
                maximum: 5,
                field: "blocked hosts"
            )
        }

        var body: [String: Any] = [
            "Query": trimmedQuery,
            "SearchType": "web",
            "Count": min(max(1, count), 50),
            "Filter": filter,
            "QueryControl": ["QueryRewrite": options.queryRewrite]
        ]
        if let timeRange = volcengineTimeRange(days: query.recencyDays, now: now) {
            body["TimeRange"] = timeRange
        }
        var request = try post(volcengineFeedcoopEndpoint, json: body)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Vendor filter values are pipe-separated and the source API caps the
    /// lists. Exceeding a cap is an explicit error, never a silent prefix.
    private static func volcengineDomainList(
        _ values: [String],
        maximum: Int,
        field: String
    ) throws -> String {
        guard values.count <= maximum else {
            throw WebRetrievalError.invalidResponse(
                "Volcengine \(field) accepts at most \(maximum) entries"
            )
        }
        let cleaned = try values.map { value -> String in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains("|"),
                  trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                throw WebRetrievalError.invalidResponse(
                    "Volcengine \(field) contains an invalid domain"
                )
            }
            return trimmed
        }
        return cleaned.joined(separator: "|")
    }

    /// Official enum values, or an explicit UTC date range beyond one year.
    static func volcengineTimeRange(days: Int?, now: Date) -> String? {
        guard let days, days > 0 else { return nil }
        switch days {
        case ...1: return "OneDay"
        case ...7: return "OneWeek"
        case ...31: return "OneMonth"
        case ...365: return "OneYear"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            let start = now.addingTimeInterval(-Double(days - 1) * 86_400)
            return "\(formatter.string(from: start))..\(formatter.string(from: now))"
        }
    }

    private static func post(_ url: URL, json: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return request
    }

    private static func get(_ url: URL, query: [URLQueryItem]) throws -> URLRequest {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw WebRetrievalError.invalidResponse("invalid endpoint")
        }
        components.queryItems = (components.queryItems ?? []) + query.filter { $0.value != nil }
        guard let result = components.url else { throw WebRetrievalError.invalidResponse("invalid query") }
        return URLRequest(url: result)
    }

    private static func tencentCount(_ count: Int) -> Int {
        [10, 20, 30, 40, 50].first(where: { $0 >= count }) ?? 50
    }

    private static func bochaFreshness(days: Int?) -> String {
        guard let days else { return "noLimit" }
        switch days {
        case ...1: return "oneDay"
        case ...7: return "oneWeek"
        case ...31: return "oneMonth"
        default: return "oneYear"
        }
    }

    /// Brave's documented freshness values: `pd` (<=24h), `pw` (<=7d), `pm`
    /// (<=31d), `py` (<=365d) or a custom `YYYY-MM-DDtoYYYY-MM-DD` range.
    /// The previous `pd<days>d` form is not part of the API and was ignored.
    /// The custom range is deterministic for a given `now`.
    static func braveFreshness(days: Int?, now: Date) -> String? {
        guard let days, days > 0 else { return nil }
        switch days {
        case ...1: return "pd"
        case ...7: return "pw"
        case ...31: return "pm"
        case ...365: return "py"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            let start = now.addingTimeInterval(-Double(days - 1) * 86_400)
            return "\(formatter.string(from: start))to\(formatter.string(from: now))"
        }
    }

    private static func signTencent(
        request: inout URLRequest,
        body: Data,
        secretID: String,
        secretKey: String,
        now: Date
    ) {
        let timestamp = Int(now.timeIntervalSince1970)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: now)
        let host = request.url!.host!
        let contentType = "application/json; charset=utf-8"
        let canonicalHeaders = "content-type:\(contentType)\nhost:\(host)\n"
        let signedHeaders = "content-type;host"
        let payloadHash = sha256Hex(body)
        let canonicalRequest = "POST\n/\n\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"
        let scope = "\(date)/wsa/tc3_request"
        let stringToSign = "TC3-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(sha256Hex(Data(canonicalRequest.utf8)))"
        let secretDate = hmac(key: Data("TC3\(secretKey)".utf8), value: Data(date.utf8))
        let secretService = hmac(key: secretDate, value: Data("wsa".utf8))
        let secretSigning = hmac(key: secretService, value: Data("tc3_request".utf8))
        let signature = hmac(key: secretSigning, value: Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()
        let authorization = "TC3-HMAC-SHA256 Credential=\(secretID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("SearchPro", forHTTPHeaderField: "X-TC-Action")
        request.setValue("2025-05-08", forHTTPHeaderField: "X-TC-Version")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-TC-Timestamp")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    }

    private static func sha256Hex(_ data: Data) -> String {
        FloeDigest.sha256Hex(data)
    }

    private static func hmac(key: Data, value: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: value, using: SymmetricKey(data: key)))
    }

    static func parse(_ data: Data, provider: WebSearchProviderKind, limit: Int) throws -> [WebSearchResult] {
        try parseOutput(data, provider: provider, limit: limit).results
    }

    /// Full provider output. Only Ark carries a separate generated answer;
    /// every other provider returns an empty answer field.
    static func parseOutput(
        _ data: Data,
        provider: WebSearchProviderKind,
        limit: Int
    ) throws -> WebSearchProviderOutput {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw WebRetrievalError.invalidResponse("response is not valid JSON")
        }
        guard let object = root as? [String: Any] else {
            if provider == .volcengine {
                throw WebRetrievalError.invalidResponse("response root is not a JSON object")
            }
            // Preserve the existing tolerant behavior for providers whose
            // parser historically treated a non-object root as no results.
            return WebSearchProviderOutput(results: [], generatedAnswer: nil)
        }
        if provider == .volcengine, isArkResponse(object) {
            return try parseArkResponse(object, limit: limit)
        }
        // The direct Doubao/Agent Plan gateway answers HTTP 2xx with a
        // PascalCase Error object — at the root or nested inside
        // ResponseMetadata — and a null Result when the request is rejected
        // (documented gateway contract). Surfacing it is required: falling
        // through to generic extraction would relabel a rejected request as
        // a successful empty search ("empty result"), the exact error
        // masking seen on-device for valid saved Agent Plan keys.
        if provider == .volcengine {
            let metadata = object["ResponseMetadata"] as? [String: Any]
            for error in [object["error"], object["Error"], metadata?["Error"]] {
                if let error, !(error is NSNull) {
                    throw WebRetrievalError.invalidResponse(providerErrorMessage(error))
                }
            }
        }
        return WebSearchProviderOutput(
            results: parseGenericResults(object, provider: provider, limit: limit),
            generatedAnswer: nil
        )
    }

    /// Ark Responses objects are distinguishable from the direct search API
    /// and the original custom-endpoint envelopes by their response shape.
    private static func isArkResponse(_ object: [String: Any]) -> Bool {
        if object["object"] as? String == "response" { return true }
        if let output = object["output"] as? [[String: Any]], !output.isEmpty { return true }
        if let identifier = object["id"] as? String, identifier.hasPrefix("resp_") { return true }
        return false
    }

    private static func parseGenericResults(
        _ root: Any,
        provider: WebSearchProviderKind,
        limit: Int
    ) -> [WebSearchResult] {
        let dictionaries = resultDictionaries(root, provider: provider)
        return dictionaries.prefix(max(1, limit)).compactMap { item in
            let title = string(item, keys: ["title", "name", "Title"])
            let rawURL = string(item, keys: ["url", "link", "Url"])
            guard !title.isEmpty, let url = URL(string: rawURL), url.scheme == "https" || url.scheme == "http" else { return nil }
            // Excerpt priority preserves existing providers and adds Brave's
            // documented `description`. `extra_snippets` stays a SEPARATE,
            // bounded list and is never concatenated into the main excerpt.
            // Volcengine's direct API uses PascalCase Snippet/Summary; the
            // legacy custom endpoint keeps lower-case keys.
            let snippet = string(item, keys: [
                "snippet", "summary", "passage", "content", "text", "description",
                "Snippet", "Summary"
            ])
            let seed = "\(provider.rawValue)|\(url.absoluteString)"
            return WebSearchResult(
                title: title,
                url: url,
                snippet: String(snippet.prefix(4_000)),
                sourceName: sourceName(item),
                // Only explicit provider publication fields feed publishedAt.
                // Brave's `page_age` (published OR modified) and `age`
                // (relative) are surfaced separately and never relabeled.
                publishedAt: optionalString(item, keys: [
                    "date", "published_date", "publishedAt", "PublishTime"
                ]),
                score: (item["score"] as? Double) ?? (item["RankScore"] as? Double),
                provider: provider,
                citationID: String(sha256Hex(Data(seed.utf8)).prefix(12)),
                extraSnippets: boundedStrings(item["extra_snippets"], maxCount: 5, maxCharacters: 1_000),
                pageAge: optionalString(item, keys: ["page_age"]),
                relativeAge: optionalString(item, keys: ["age"]),
                pageFetched: optionalString(item, keys: ["page_fetched"]),
                sourceProfileName: nestedString(item, parent: "profile", keys: ["long_name", "name"]),
                sourceProfileURL: nestedString(item, parent: "profile", keys: ["url"]),
                faviconURL: optionalString(item, keys: ["LogoUrl"])
                    ?? nestedString(item, parent: "meta_url", keys: ["favicon"]),
                displayPath: nestedString(item, parent: "meta_url", keys: ["path"]),
                contentState: .searchMetadataOnly
            )
        }
    }

    /// Ark Responses: citations live in `output[].content[].annotations[]`;
    /// the visible assistant text is a separate provider-generated answer and
    /// is never copied into citation snippets.
    private static func parseArkResponse(
        _ object: [String: Any],
        limit: Int
    ) throws -> WebSearchProviderOutput {
        if let error = object["error"], !(error is NSNull) {
            throw WebRetrievalError.invalidResponse(providerErrorMessage(error))
        }
        let status = (object["status"] as? String)?.lowercased()
        switch status {
        case nil, .some("completed"):
            break
        case .some("failed"):
            throw WebRetrievalError.invalidResponse("Ark Responses search failed")
        case .some("incomplete"):
            let reason = ((object["incomplete_details"] as? [String: Any])?["reason"] as? String)
                .map { " (\($0))" } ?? ""
            throw WebRetrievalError.invalidResponse(
                "Ark Responses search was incomplete\(reason)"
            )
        case .some(let value):
            throw WebRetrievalError.invalidResponse(
                "Ark Responses search returned status \(value)"
            )
        }

        var citations: [WebSearchResult] = []
        var answerParts: [String] = []
        var seenURLs = Set<String>()
        if let output = object["output"] as? [[String: Any]] {
            for item in output {
                guard item["type"] as? String == "message" else { continue }
                guard let content = item["content"] as? [[String: Any]] else { continue }
                for part in content {
                    guard part["type"] as? String == "output_text" else { continue }
                    if let text = part["text"] as? String, !text.isEmpty {
                        answerParts.append(text)
                    }
                    guard let annotations = part["annotations"] as? [[String: Any]] else {
                        continue
                    }
                    for annotation in annotations {
                        guard annotation["type"] as? String == "url_citation" else { continue }
                        guard let rawURL = annotation["url"] as? String,
                              let url = URL(string: rawURL),
                              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                            continue
                        }
                        guard let title = (annotation["title"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                            !title.isEmpty else {
                            // A citation without a title is not fabricated from
                            // its URL or from the answer text.
                            continue
                        }
                        let key = url.absoluteString.lowercased()
                        guard seenURLs.insert(key).inserted else { continue }
                        let snippet = (annotation["summary"] as? String) ?? ""
                        let seed = "volcengine|\(url.absoluteString)"
                        citations.append(WebSearchResult(
                            title: title,
                            url: url,
                            snippet: String(snippet.prefix(4_000)),
                            sourceName: annotation["site_name"] as? String,
                            publishedAt: annotation["publish_time"] as? String,
                            provider: .volcengine,
                            citationID: String(sha256Hex(Data(seed.utf8)).prefix(12)),
                            contentState: .searchMetadataOnly
                        ))
                    }
                }
            }
        }
        if answerParts.isEmpty, let text = object["output_text"] as? String {
            answerParts.append(text)
        }
        let answer = WebSearchProviderGeneratedAnswer.bounded(
            provider: .volcengine,
            text: answerParts.joined(separator: "\n\n")
        )
        return WebSearchProviderOutput(
            results: Array(citations.prefix(max(1, limit))),
            generatedAnswer: answer
        )
    }

    private static func providerErrorMessage(_ error: Any) -> String {
        if let dictionary = error as? [String: Any] {
            // Volcengine's gateway errors are PascalCase (Code/Message/CodeN);
            // existing providers keep their lowercase message first.
            let message = (dictionary["message"] as? String)
                ?? (dictionary["Message"] as? String)
            let code = (dictionary["code"] as? String)
                ?? (dictionary["Code"] as? String)
                ?? (dictionary["CodeN"] as? Int).map(String.init)
                ?? (dictionary["code"] as? Int).map(String.init)
                ?? (dictionary["CodeN"] as? Int64).map(String.init)
            if let message, !message.isEmpty {
                if let code, !code.isEmpty {
                    return "Provider error: \(code): \(String(message.prefix(512)))"
                }
                return "Provider error: \(String(message.prefix(512)))"
            }
            if let code, !code.isEmpty {
                return "Provider error: \(String(code.prefix(512)))"
            }
        }
        if let message = error as? String, !message.isEmpty {
            return "Provider error: \(String(message.prefix(512)))"
        }
        return "Provider returned an error response"
    }

    /// Source display name: existing flat keys keep priority; Brave's
    /// `profile`/`meta_url` objects are the documented fallback. Volcengine's
    /// direct API uses PascalCase SiteName.
    private static func sourceName(_ item: [String: Any]) -> String? {
        if let flat = optionalString(item, keys: ["siteName", "site", "source", "SiteName"]) {
            return flat
        }
        return nestedString(item, parent: "profile", keys: ["long_name", "name"])
            ?? nestedString(item, parent: "meta_url", keys: ["hostname"])
    }

    private static func nestedString(_ item: [String: Any], parent: String, keys: [String]) -> String? {
        guard let dictionary = item[parent] as? [String: Any] else { return nil }
        return optionalString(dictionary, keys: keys)
    }

    /// Bounded string list: count and per-entry characters are capped and
    /// empty entries dropped; an empty/invalid value yields nil (absent), not
    /// a fabricated placeholder.
    private static func boundedStrings(_ value: Any?, maxCount: Int, maxCharacters: Int) -> [String]? {
        guard let values = value as? [String] else { return nil }
        let bounded = values.prefix(maxCount).map { String($0.prefix(maxCharacters)) }.filter { !$0.isEmpty }
        return bounded.isEmpty ? nil : bounded
    }

    private static func resultDictionaries(_ root: Any, provider: WebSearchProviderKind) -> [[String: Any]] {
        guard let object = root as? [String: Any] else { return [] }
        if provider == .tencentWSA,
           let response = object["Response"] as? [String: Any],
           let pages = response["Pages"] as? [String] {
            return pages.compactMap { value in
                guard let data = value.data(using: .utf8) else { return nil }
                return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            }
        }
        // Volcengine's direct search gateway (Agent Plan / Doubao Search and
        // any legacy custom endpoint mirroring it) returns the documented
        // PascalCase envelope `{ "ResponseMetadata": …, "Result": {
        // "ResultCount": …, "WebResults": [ WebItem ] } }`. None of the
        // generic paths below matches it, so real 200 responses decoded to
        // zero results and surfaced as "volcengine: empty result". Item
        // fields (Title/Url/Snippet/Summary/SiteName/PublishTime/LogoUrl)
        // already normalize through the shared PascalCase keys.
        let volcenginePaths: [[String]] = provider == .volcengine ? [["Result", "WebResults"]] : []
        let paths: [[String]] = volcenginePaths + [
            ["data", "webPages", "value"], ["webPages", "value"], ["web", "results"],
            ["data", "results"], ["results"], ["items"]
        ]
        for path in paths {
            var cursor: Any = object
            var valid = true
            for component in path {
                guard let dictionary = cursor as? [String: Any], let next = dictionary[component] else {
                    valid = false; break
                }
                cursor = next
            }
            if valid, let values = cursor as? [[String: Any]] { return values }
        }
        return []
    }

    private static func string(_ dictionary: [String: Any], keys: [String]) -> String {
        optionalString(dictionary, keys: keys) ?? ""
    }

    private static func optionalString(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Ephemeral single-instance test transport. The frozen draft
    /// configuration and the in-memory supplied credential are captured only
    /// for this call: nothing is persisted, the credential never enters the
    /// Keychain or a log, and because exactly one resolver pair exists the
    /// service's ordered-failover loop can never reach another provider.
    /// Request construction, signing, SSRF policy and parsing are the real
    /// production paths, including the provider-specific Volcengine
    /// interface guards.
    public static func searchTest(
        configuration: WebSearchProviderConfiguration,
        credential: WebSearchCredential,
        text: String,
        maxResults: Int = 5
    ) async -> WebSearchTestOutcome {
        let service = WebSearchService(configurations: { [(configuration, credential)] })
        return await service.testSearch(
            configuration: configuration,
            credential: credential,
            text: text,
            maxResults: maxResults
        )
    }

    /// Test Search on this service for exactly one frozen draft. The query
    /// names the draft's provider id, so even a service that resolves other
    /// providers can never fall back to a different one: `search` filters to
    /// the requested provider and stops after the first attempt. Nothing is
    /// persisted; the supplied credential lives only for this call.
    func testSearch(
        configuration: WebSearchProviderConfiguration,
        credential: WebSearchCredential,
        text: String,
        maxResults: Int = 5
    ) async -> WebSearchTestOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return WebSearchTestOutcome(results: [], error: "empty query")
        }
        guard WebSearchService.isConfigured(configuration, credential: credential) else {
            return WebSearchTestOutcome(
                results: [],
                error: WebSearchTestOutcome.notConfiguredReason
            )
        }
        let query = WebSearchQuery(
            text: trimmed,
            maxResults: max(1, min(maxResults, 10)),
            requestedProvider: configuration.id.uuidString.lowercased()
        )
        do {
            let response = try await search(query)
            return WebSearchTestOutcome(results: Array(response.results.prefix(maxResults)), error: nil)
        } catch let WebRetrievalError.allProvidersFailed(failures) {
            if Self.isEmptyResultOnly(failures) {
                // The single attempted provider answered HTTP 2xx with zero
                // matches. That is "no results", not a provider failure: the
                // UI's no_results copy is accurate, and "All web search
                // providers failed" would hide a working credential behind
                // failure wording.
                return WebSearchTestOutcome(results: [], error: nil)
            }
            return WebSearchTestOutcome(results: [], error: WebRetrievalError
                .allProvidersFailed(failures).localizedDescription)
        } catch {
            return WebSearchTestOutcome(results: [], error: error.localizedDescription)
        }
    }

    /// True when the only recorded failure is the service's own
    /// "<kind>: empty result" tag: an HTTP-success envelope with zero
    /// results and no generated answer. Hard transport/HTTP errors are
    /// formatted differently ("<kind>: HTTP <status>" / localized error)
    /// and never match.
    static func isEmptyResultOnly(_ failures: [String]) -> Bool {
        failures.count == 1 && failures[0].hasSuffix(": empty result")
    }

    private static func deduplicate(_ results: [WebSearchResult], limit: Int) -> [WebSearchResult] {
        var seen = Set<String>()
        var output: [WebSearchResult] = []
        for result in results {
            var components = URLComponents(url: result.url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            let filteredQueryItems = components?.queryItems?.filter {
                !$0.name.lowercased().hasPrefix("utm_")
            }
            components?.queryItems = filteredQueryItems
            let key = (components?.url?.absoluteString ?? result.url.absoluteString).lowercased()
            guard seen.insert(key).inserted else { continue }
            output.append(result)
            if output.count >= max(1, limit) { break }
        }
        return output
    }
}

/// Provider requests start at fixed pinned hosts. There is no demonstrated
/// need for a search provider API to redirect anywhere, so every redirect is
/// revalidated with the strict public policy (fake-IP answers not honored)
/// and any cross-origin redirect — including same-host-different-port — is
/// rejected outright instead of being followed with API keys stripped.
/// Provider credentials (Authorization bearer, X-Subscription-Token,
/// X-api-key, X-TC-* signing headers) therefore never leave the origin.
private final class SearchProviderRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let validateDestination: @Sendable (URL) throws -> Void

    init(validateDestination: @escaping @Sendable (URL) throws -> Void) {
        self.validateDestination = validateDestination
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              (try? validateDestination(url)) != nil,
              Self.origin(task.currentRequest?.url) == Self.origin(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func origin(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else {
            return nil
        }
        return "\(scheme)://\(host):\(url.port ?? 443)"
    }
}

// MARK: - Professional dataset source (unified web.search selector)

/// Execution seam for web.search with source=professional. Production uses
/// the exact owned MCP client registered for the selected account; tests may
/// inject deterministic fakes. No generic HTTP API, remote-method argument or
/// cross-source fallback exists at this boundary.
public protocol WebSearchProfessionalExecuting: Sendable {
    /// Accounts frozen for THIS run, not a live lookup that could widen it.
    func instances(context: ToolContext) -> [WebSearchProfessionalInstance]

    /// Executes only the validated query string against the selected frozen
    /// account+generation. Arbitrary model JSON never crosses this seam.
    func execute(
        instance: WebSearchProfessionalInstance,
        query: String,
        context: ToolContext
    ) async throws -> ToolExecutionOutput
}

/// Default executor over the SAME injected registry as MCP registration. The
/// private authority store owns the client closure, exact generation checks
/// and late-result suppression; no credential is copied or migrated.
public struct MCPRegistryProfessionalSearchExecutor: WebSearchProfessionalExecuting {
    private let registry: ToolRunnerRegistry

    public init(registry: ToolRunnerRegistry = .shared) {
        self.registry = registry
    }

    public func instances(context: ToolContext) -> [WebSearchProfessionalInstance] {
        guard let authority = context.professionalSearchAuthority,
              authority.isBound(to: registry),
              authority.allowsProfessionalSource else { return [] }
        return authority.accounts
    }

    public func execute(
        instance: WebSearchProfessionalInstance,
        query: String,
        context: ToolContext
    ) async throws -> ToolExecutionOutput {
        guard let authority = context.professionalSearchAuthority else {
            throw WebSearchProfessionalError.authorityUnavailable
        }
        return try await ProfessionalSearchAuthority.execute(
            registry: registry,
            authority: authority,
            account: instance,
            query: query,
            context: context
        )
    }
}

/// Deterministic account selection for the professional source. An explicit
/// selector must match exactly one registered account; several accounts
/// without a selector are an explicit choice the model has to make. There is
/// never an implicit first-match, cross-account or cross-channel fallback.
public enum WebSearchProfessionalRouting {
    public static func selectInstance(
        _ instances: [WebSearchProfessionalInstance],
        requestedProvider: String?
    ) throws -> WebSearchProfessionalInstance {
        guard !instances.isEmpty else {
            throw WebSearchProfessionalError.notConfigured
        }
        guard let requested = requestedProvider?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty else {
            guard instances.count == 1 else {
                throw WebSearchProfessionalError.ambiguousSelection(
                    instances.map(\.displayName)
                )
            }
            return instances[0]
        }
        let needle = requested.lowercased()
        // Only public account identity is selectable. A retired internal alias
        // is neither a provider selector nor an authorization route.
        let matches = instances.filter {
            $0.serverID.uuidString.lowercased() == needle
                || $0.displayName.lowercased() == needle
        }
        guard !matches.isEmpty else {
            throw WebSearchProfessionalError.providerNotFound(requested)
        }
        guard matches.count == 1 else {
            throw WebSearchProfessionalError.ambiguousSelection(
                matches.map(\.displayName)
            )
        }
        return matches[0]
    }
}
