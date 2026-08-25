import Foundation

/// Search backends supported by Floe's provider-neutral retrieval layer.
/// Raw provider responses never enter the agent context; adapters normalize
/// them into `WebSearchResult` first.
public enum WebSearchProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bochaWeb
    case bochaAI
    case tencentWSA
    case volcengine
    case brave
    case tavily
    case exa
    case googleProgrammable
    case searxng
    case custom

    public var id: String { rawValue }

    /// Self-hosted SearXNG may be intentionally anonymous. Every managed
    /// commercial adapter currently requires credentials; custom endpoints
    /// default to bearer authentication.
    public var requiresCredential: Bool { self != .searxng }
}

public enum WebSearchMode: String, Codable, CaseIterable, Sendable {
    case fast
    case balanced
    case deep
}

/// Secret-free provider metadata. `credentialAccount` points at a Keychain
/// entry whose JSON body is resolved only at execution time.
public struct WebSearchProviderConfiguration: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: WebSearchProviderKind
    public var displayName: String
    public var endpoint: URL?
    public var credentialAccount: String
    public var enabled: Bool
    public var priority: Int
    public var region: String?
    public var options: [String: String]

    public init(
        id: UUID = UUID(),
        kind: WebSearchProviderKind,
        displayName: String,
        endpoint: URL? = nil,
        credentialAccount: String,
        enabled: Bool = true,
        priority: Int = 0,
        region: String? = nil,
        options: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.endpoint = endpoint
        self.credentialAccount = credentialAccount
        self.enabled = enabled
        self.priority = priority
        self.region = region
        self.options = options
    }
}

/// Decrypted only for the duration of a request. Provider-specific keys use
/// stable names: apiKey, secretId, secretKey, engineId, projectId.
public struct WebSearchCredential: Codable, Hashable, Sendable {
    public var values: [String: String]

    public init(values: [String: String]) { self.values = values }
    public subscript(_ key: String) -> String? { values[key] }
}

public struct WebSearchQuery: Hashable, Sendable {
    public var text: String
    public var mode: WebSearchMode
    public var domains: [String]
    public var excludedDomains: [String]
    public var recencyDays: Int?
    public var maxResults: Int
    public var requestedProvider: String?
    /// Per-tool Bocha summary behavior. `web.search` sets false for raw web
    /// evidence; `web.searchAI` sets true. Nil preserves compatibility for
    /// callers that intentionally defer to provider configuration.
    public var summaryEnabled: Bool?

    public init(
        text: String,
        mode: WebSearchMode = .fast,
        domains: [String] = [],
        excludedDomains: [String] = [],
        recencyDays: Int? = nil,
        maxResults: Int = 10,
        requestedProvider: String? = nil,
        summaryEnabled: Bool? = nil
    ) {
        self.text = text
        self.mode = mode
        self.domains = domains
        self.excludedDomains = excludedDomains
        self.recencyDays = recencyDays
        self.maxResults = maxResults
        self.requestedProvider = requestedProvider
        self.summaryEnabled = summaryEnabled
    }
}

public struct WebSearchResult: Codable, Hashable, Sendable {
    public var title: String
    public var url: URL
    public var snippet: String
    public var sourceName: String?
    public var publishedAt: String?
    public var score: Double?
    public var provider: WebSearchProviderKind
    public var citationID: String

    public init(
        title: String,
        url: URL,
        snippet: String,
        sourceName: String? = nil,
        publishedAt: String? = nil,
        score: Double? = nil,
        provider: WebSearchProviderKind,
        citationID: String
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.sourceName = sourceName
        self.publishedAt = publishedAt
        self.score = score
        self.provider = provider
        self.citationID = citationID
    }
}

public struct WebSearchResponse: Sendable {
    public var query: String
    public var results: [WebSearchResult]
    public var providersUsed: [WebSearchProviderKind]
    public var failures: [String]

    public init(
        query: String,
        results: [WebSearchResult],
        providersUsed: [WebSearchProviderKind],
        failures: [String] = []
    ) {
        self.query = query
        self.results = results
        self.providersUsed = providersUsed
        self.failures = failures
    }
}

public struct FetchedDocument: Sendable {
    public var url: URL
    public var title: String?
    public var contentType: String
    public var text: String
    public var statusCode: Int
    public var truncated: Bool
    public var fallbackReason: String?
}

public enum WebRetrievalError: Error, LocalizedError, Sendable {
    case noProviderConfigured
    case providerNotFound(String)
    case missingCredential(String)
    case invalidResponse(String)
    case allProvidersFailed([String])

    public var errorDescription: String? {
        switch self {
        case .noProviderConfigured: "No web search provider is configured."
        case .providerNotFound(let value): "No enabled web search provider matches: \(value)"
        case .missingCredential(let value): "Missing web search credential: \(value)"
        case .invalidResponse(let value): "Invalid web search response: \(value)"
        case .allProvidersFailed(let failures): "All web search providers failed: \(failures.joined(separator: "; "))"
        }
    }
}

public typealias WebSearchConfigurationResolver = @Sendable () async -> [(WebSearchProviderConfiguration, WebSearchCredential)]
