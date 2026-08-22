import Crypto
import Foundation

public actor WebSearchService {
    private let session: URLSession
    private let configurations: WebSearchConfigurationResolver

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        configurations: @escaping WebSearchConfigurationResolver = { [] }
    ) {
        self.session = URLSession(configuration: configuration)
        self.configurations = configurations
    }

    public func search(_ query: WebSearchQuery) async throws -> WebSearchResponse {
        let available = await configurations()
            .filter { $0.0.enabled }
            .sorted { $0.0.priority < $1.0.priority }
        guard !available.isEmpty else { throw WebRetrievalError.noProviderConfigured }

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

        var combined: [WebSearchResult] = []
        var used: [WebSearchProviderKind] = []
        var failures: [String] = []

        if query.mode == .deep, selected.count > 1 {
            await withTaskGroup(of: ProviderOutcome.self) { group in
                for item in selected {
                    group.addTask { [self] in await run(item.0, credential: item.1, query: query) }
                }
                for await outcome in group {
                    switch outcome {
                    case .success(let kind, let results):
                        used.append(kind)
                        combined.append(contentsOf: results)
                    case .failure(let value): failures.append(value)
                    }
                }
            }
        } else {
            // Fast/balanced use ordered failover. A valid empty result is
            // treated as insufficient evidence and advances to the next
            // configured provider.
            let failoverCandidates = query.requestedProvider == nil ? available : selected
            for item in failoverCandidates {
                let outcome = await run(item.0, credential: item.1, query: query)
                switch outcome {
                case .success(let kind, let results) where !results.isEmpty:
                    used.append(kind)
                    combined = results
                    break
                case .success(let kind, _): failures.append("\(kind.rawValue): empty result")
                case .failure(let value): failures.append(value)
                }
                if !combined.isEmpty { break }
                if query.requestedProvider != nil { break }
            }
        }

        let normalized = Self.deduplicate(combined, limit: query.maxResults)
        guard !normalized.isEmpty else { throw WebRetrievalError.allProvidersFailed(failures) }
        return WebSearchResponse(
            query: query.text,
            results: normalized,
            providersUsed: used,
            failures: failures
        )
    }

    private enum ProviderOutcome: Sendable {
        case success(WebSearchProviderKind, [WebSearchResult])
        case failure(String)
    }

    private func run(
        _ configuration: WebSearchProviderConfiguration,
        credential: WebSearchCredential,
        query: WebSearchQuery
    ) async -> ProviderOutcome {
        do {
            let request = try Self.makeRequest(configuration, credential: credential, query: query)
            try PublicNetworkTargetPolicy.validate(request.url!)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return .failure("\(configuration.kind.rawValue): HTTP \(status)")
            }
            let results = try Self.parse(data, provider: configuration.kind, limit: query.maxResults)
            return .success(configuration.kind, results)
        } catch {
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
            let fallback = configuration.kind == .bochaAI
                ? "https://api.bochaai.com/v1/ai-search"
                : "https://api.bochaai.com/v1/web-search"
            request = try post(configuration.endpoint ?? URL(string: fallback)!, json: [
                "query": query.text,
                "summary": true,
                "answer": false,
                "stream": false,
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
            request = try get(endpoint, query: [
                URLQueryItem(name: "q", value: query.text),
                URLQueryItem(name: "count", value: String(min(count, 20))),
                URLQueryItem(name: "freshness", value: query.recencyDays.map { "pd\($0)d" })
            ])
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

        case .volcengine, .custom:
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
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, value: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: value, using: SymmetricKey(data: key)))
    }

    static func parse(_ data: Data, provider: WebSearchProviderKind, limit: Int) throws -> [WebSearchResult] {
        let root = try JSONSerialization.jsonObject(with: data)
        let dictionaries = resultDictionaries(root, provider: provider)
        return dictionaries.prefix(max(1, limit)).compactMap { item in
            let title = string(item, keys: ["title", "name"])
            let rawURL = string(item, keys: ["url", "link"])
            guard !title.isEmpty, let url = URL(string: rawURL), url.scheme == "https" || url.scheme == "http" else { return nil }
            let snippet = string(item, keys: ["snippet", "summary", "passage", "content", "text"])
            let seed = "\(provider.rawValue)|\(url.absoluteString)"
            return WebSearchResult(
                title: title,
                url: url,
                snippet: String(snippet.prefix(4_000)),
                sourceName: optionalString(item, keys: ["siteName", "site", "source"]),
                publishedAt: optionalString(item, keys: ["date", "published_date", "publishedAt"]),
                score: item["score"] as? Double,
                provider: provider,
                citationID: String(sha256Hex(Data(seed.utf8)).prefix(12))
            )
        }
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
        let paths: [[String]] = [
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
