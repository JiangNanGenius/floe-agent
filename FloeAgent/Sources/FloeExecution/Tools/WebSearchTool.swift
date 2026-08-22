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
    public static let toolDescription =
        "Search the public web without opening the visual browser. Returns normalized titles, URLs, snippets, dates, source names, provider provenance, and citation IDs. Use fast for one search provider, balanced for ordinary research, or deep to query up to three configured providers concurrently. Use browser tools only when search/fetch cannot provide enough structured information or interaction is required."
    public static let parametersJSON = #"""
    {
      "type":"object",
      "properties":{
        "query":{"type":"string","description":"Natural-language web search query"},
        "mode":{"type":"string","enum":["fast","balanced","deep"],"description":"Retrieval depth; default balanced"},
        "domains":{"type":"array","items":{"type":"string"},"description":"Optional preferred or required domains"},
        "excludeDomains":{"type":"array","items":{"type":"string"},"description":"Optional domains to exclude"},
        "recencyDays":{"type":"integer","minimum":1,"maximum":1825},
        "maxResults":{"type":"integer","minimum":1,"maximum":50},
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
            maxResults: args.maxResults ?? 10,
            requestedProvider: args.provider
        ))
        let payload: [String: Any] = [
            "query": response.query,
            "providers": response.providersUsed.map(\.rawValue),
            "failures": response.failures,
            "results": response.results.map { result in
                ["citation": result.citationID, "title": result.title,
                 "url": result.url.absoluteString, "snippet": result.snippet,
                 "source": result.sourceName ?? "", "publishedAt": result.publishedAt ?? "",
                 "provider": result.provider.rawValue] as [String: Any]
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let summary = String(decoding: data, as: UTF8.self)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: summary, fullOutputSHA256: digest, exitStatus: 0)
    }
}
