import Foundation
import FloeTools

/// Search backends supported by Floe's provider-neutral retrieval layer.
/// Raw provider responses never enter the agent context; adapters normalize
/// them into `WebSearchResult` first.
public enum WebSearchProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bochaWeb
    case bochaAI
    case tencentWSA
    case volcengine
    case deepseek
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

/// Explicit source selector of the unified `web.search` tool. `web` (the
/// default, and every legacy call without the argument) keeps the existing
/// public-web semantics byte-for-byte; `professional` routes the exact query
/// to a configured Volcengine DataPro dataset account through its reviewed
/// MCP capability. There is never a fallback between the two sources or
/// between paid channels.
public enum WebSearchSource: String, Codable, CaseIterable, Sendable {
    case web
    case professional
}

/// One frozen professional-dataset account selectable through the unified
/// web.search provider argument. Its generation is authority metadata, never a
/// model-callable tool name or a live fallback token.
public typealias WebSearchProfessionalInstance = ProfessionalSearchAuthority.Account

/// Typed, secret-free failures of the professional source. Each states the
/// actionable condition; none silently reroutes to public web providers, to
/// another account or to another paid channel.
public enum WebSearchProfessionalError: Error, LocalizedError, Sendable {
    case notConfigured
    case authorityUnavailable
    case providerNotFound(String)
    case ambiguousSelection([String])
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No professional dataset account was authorized when this run started. Configure Volcengine DataPro and start a new run, or search without source=professional."
        case .authorityUnavailable:
            return "Professional search requires the run's frozen account authority; start a new ordinary agent run."
        case .providerNotFound(let value):
            return "No configured professional dataset account matches: \(value)"
        case .ambiguousSelection(let names):
            return "Several professional dataset accounts are configured (\(names.joined(separator: ", "))); select one with the provider argument"
        case .notReady(let name):
            return "Professional dataset account is not ready: \(name)"
        }
    }
}

/// Volcengine exposes several distinct search products with mutually
/// exclusive credentials. This enum never contains a "legacy" case: a stored
/// configuration without an explicit interface keeps the original generic
/// endpoint/token contract byte-for-byte, so an old nil-interface record can
/// never silently become an Agent Plan or Ark product.
public enum VolcengineSearchInterface: String, Codable, CaseIterable, Identifiable, Sendable {
    case agentPlan
    case arkResponses
    case doubaoSearch

    public var id: String { rawValue }
}

/// Engine selection *within* the Ark Responses interface. `doubaoCustom`
/// sends `sources: ["doubao"]` exclusively; `onlineContent` sends the three
/// plugin sources together. They are never mixed.
public enum VolcengineArkSearchEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case doubaoCustom
    case onlineContent

    public var id: String { rawValue }
}

/// Typed access to the provider's string options dictionary. Unknown or
/// malformed security-relevant values throw instead of falling back to a
/// different product or credential; absent optional values keep their
/// documented defaults.
public struct VolcengineSearchOptions: Sendable, Hashable {
    public enum Key {
        public static let interface = "interface"
        public static let arkEngine = "arkEngine"
        public static let arkModel = "arkModel"
        public static let queryRewrite = "queryRewrite"
        public static let authoritativeOnly = "authoritativeOnly"
        public static let dataProEnabled = "dataProEnabled"
        public static let dataProServerID = "dataProServerID"
    }

    /// Official example model from the verified Ark web-search document. It is
    /// a configurable default, not an assertion about the current model
    /// catalog.
    public static let defaultArkModel = "doubao-seed-2-1-pro-260915"
    public static let maximumArkModelCharacters = 200
    /// Provider-generated auxiliary text is bounded before it enters the
    /// response. The tool output applies a second, smaller JSON budget.
    public static let maximumGeneratedAnswerCharacters = 4_000

    public var interface: VolcengineSearchInterface?
    public var arkEngine: VolcengineArkSearchEngine
    public var arkModel: String
    public var queryRewrite: Bool
    public var authoritativeOnly: Bool
    public var dataProEnabled: Bool
    public var dataProServerID: UUID?

    public init(
        interface: VolcengineSearchInterface? = nil,
        arkEngine: VolcengineArkSearchEngine = .doubaoCustom,
        arkModel: String = VolcengineSearchOptions.defaultArkModel,
        queryRewrite: Bool = false,
        authoritativeOnly: Bool = false,
        dataProEnabled: Bool = false,
        dataProServerID: UUID? = nil
    ) {
        self.interface = interface
        self.arkEngine = arkEngine
        self.arkModel = arkModel
        self.queryRewrite = queryRewrite
        self.authoritativeOnly = authoritativeOnly
        self.dataProEnabled = dataProEnabled
        self.dataProServerID = dataProServerID
    }

    public init(options: [String: String]) throws {
        let rawInterface = options[Key.interface]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawInterface.isEmpty {
            interface = nil
        } else if let value = VolcengineSearchInterface(rawValue: rawInterface) {
            interface = value
        } else {
            throw WebRetrievalError.invalidResponse(
                "Unknown Volcengine interface selection"
            )
        }

        let rawEngine = options[Key.arkEngine]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawEngine.isEmpty {
            arkEngine = .doubaoCustom
        } else if let value = VolcengineArkSearchEngine(rawValue: rawEngine) {
            arkEngine = value
        } else {
            throw WebRetrievalError.invalidResponse(
                "Unknown Volcengine Ark search engine selection"
            )
        }

        let candidateModel = options[Key.arkModel]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = candidateModel.isEmpty ? Self.defaultArkModel : candidateModel
        guard model.count <= Self.maximumArkModelCharacters,
              model.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics
                      .union(CharacterSet(charactersIn: "-._/:"))
                      .contains($0)
              }) else {
            throw WebRetrievalError.invalidResponse(
                "Invalid Volcengine Ark search model"
            )
        }
        arkModel = model

        queryRewrite = try Self.boolValue(options[Key.queryRewrite], name: "queryRewrite") ?? false
        authoritativeOnly = try Self.boolValue(
            options[Key.authoritativeOnly], name: "authoritativeOnly"
        ) ?? false
        dataProEnabled = try Self.boolValue(
            options[Key.dataProEnabled], name: "dataProEnabled"
        ) ?? false

        let rawServerID = options[Key.dataProServerID]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawServerID.isEmpty {
            dataProServerID = nil
        } else if let value = UUID(uuidString: rawServerID) {
            dataProServerID = value
        } else {
            throw WebRetrievalError.invalidResponse(
                "Invalid Volcengine DataPro server identifier"
            )
        }
    }

    /// Sparse dictionary for persistence. Optional values are only emitted
    /// when explicitly selected, so a legacy record keeps its missing
    /// interface key rather than acquiring a default one.
    public var dictionary: [String: String] {
        var values: [String: String] = [:]
        if let interface { values[Key.interface] = interface.rawValue }
        if interface == .arkResponses {
            values[Key.arkEngine] = arkEngine.rawValue
            values[Key.arkModel] = arkModel
        }
        if interface == .agentPlan || interface == .doubaoSearch {
            values[Key.queryRewrite] = queryRewrite ? "true" : "false"
            values[Key.authoritativeOnly] = authoritativeOnly ? "true" : "false"
        }
        if interface == .agentPlan {
            values[Key.dataProEnabled] = dataProEnabled ? "true" : "false"
            if let dataProServerID {
                values[Key.dataProServerID] = dataProServerID.uuidString
            }
        }
        return values
    }

    private static func boolValue(_ raw: String?, name: String) throws -> Bool? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "": return nil
        case "true", "1": return true
        case "false", "0": return false
        default:
            throw WebRetrievalError.invalidResponse(
                "Invalid Volcengine option \(name)"
            )
        }
    }
}

/// DeepSeek Search options exposed through the existing provider catalog
/// options dictionary. The only adjustable request field is `need_content`;
/// query, count and every filter are derived from the frozen tool arguments,
/// never from unrelated configuration. Absent values keep the documented
/// upstream default (`false`).
public struct DeepSeekSearchOptions: Sendable, Hashable {
    public enum Key {
        public static let needContent = "needContent"
        /// Historical/compatibility spelling accepted when a record was
        /// authored outside the catalog editor. The catalog itself only ever
        /// emits `needContent`.
        public static let needContentAlias = "need_content"
    }

    /// Official `query` bound: 1...128 Unicode characters after every
    /// translated site/date filter is appended.
    public static let maximumQueryScalars = 128

    public var needContent: Bool

    public init(needContent: Bool = false) {
        self.needContent = needContent
    }

    public init(options: [String: String]) throws {
        let raw = options[Key.needContent] ?? options[Key.needContentAlias]
        guard let raw else {
            needContent = false
            return
        }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "false", "0":
            needContent = false
        case "true", "1":
            needContent = true
        default:
            throw WebRetrievalError.invalidResponse(
                "Invalid DeepSeek search option needContent"
            )
        }
    }

    public var dictionary: [String: String] {
        [Key.needContent: needContent ? "true" : "false"]
    }
}

/// A bounded, explicitly provider-generated answer. It is auxiliary model
/// text, never a fetched page or a citation snippet; normalized URL results
/// stay separate.
public struct WebSearchProviderGeneratedAnswer: Codable, Hashable, Sendable {
    public var provider: WebSearchProviderKind
    public var text: String
    public var originalCharacters: Int
    public var truncated: Bool

    public init(
        provider: WebSearchProviderKind,
        text: String,
        originalCharacters: Int? = nil,
        truncated: Bool = false
    ) {
        self.provider = provider
        self.text = text
        self.originalCharacters = originalCharacters ?? text.count
        self.truncated = truncated
    }

    public static func bounded(
        provider: WebSearchProviderKind,
        text: String,
        maximumCharacters: Int = VolcengineSearchOptions.maximumGeneratedAnswerCharacters
    ) -> WebSearchProviderGeneratedAnswer? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maximumCharacters else {
            return WebSearchProviderGeneratedAnswer(
                provider: provider,
                text: trimmed,
                originalCharacters: trimmed.count,
                truncated: false
            )
        }
        return WebSearchProviderGeneratedAnswer(
            provider: provider,
            text: String(trimmed.prefix(maximumCharacters)),
            originalCharacters: trimmed.count,
            truncated: true
        )
    }
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

/// Storage identity constants for the searchable provider catalog flow.
/// v1 (`providers.v1`) is the historical auto-preset list; v2 is the
/// user-instance store. The v1 bytes are never rewritten by v2 code: they
/// stay readable by older builds and act as the natural migration source,
/// next to the explicit `migrationBackupKey` written by the v1→v2 move.
public enum WebSearchInstanceStore {
    public static let legacyProvidersKey = "floe.webSearch.providers.v1"
    public static let instancesKey = "floe.webSearch.instances.v2"
    public static let migrationBackupKey = "floe.webSearch.v1.migration-backup"
    public static let keychainService = "org.floeagent.ios.web-search"

    /// Instance-owned Keychain account. Every added instance gets its own
    /// account derived from its provider UUID, so two accounts of the same
    /// brand never share a secret and no global rewrite can move one.
    public static func instanceCredentialAccount(for providerID: UUID) -> String {
        "web-search.instance.\(providerID.uuidString.lowercased())"
    }
}

/// A user-added search provider instance: the runtime configuration plus
/// declarative catalog provenance. `appliedCatalogVersion` records which
/// signed catalog revision the managed defaults were last reviewed against;
/// `overrides` names the fields the user personally set, so a catalog update
/// merges only the values still controlled by the catalog. A nil
/// `catalogCredentialKeys` means the instance predates catalog awareness (no
/// recorded credential schema), which suppresses auth-change proposals until
/// the user adds or edits through a catalog entry.
public struct WebSearchProviderInstance: Codable, Identifiable, Hashable, Sendable {
    public var configuration: WebSearchProviderConfiguration
    public var presetID: String?
    public var appliedCatalogVersion: String?
    public var overrides: Set<String>
    public var catalogCredentialKeys: [String]?

    public var id: UUID { configuration.id }

    public init(
        configuration: WebSearchProviderConfiguration,
        presetID: String?,
        appliedCatalogVersion: String?,
        overrides: Set<String> = [],
        catalogCredentialKeys: [String]? = nil
    ) {
        self.configuration = configuration
        self.presetID = presetID
        self.appliedCatalogVersion = appliedCatalogVersion
        self.overrides = overrides
        self.catalogCredentialKeys = catalogCredentialKeys
    }

    /// The instance-owned credential account for this provider identity.
    public static func credentialAccount(for providerID: UUID) -> String {
        WebSearchInstanceStore.instanceCredentialAccount(for: providerID)
    }

    /// Managed field names the catalog can change for this instance, used by
    /// the editor to record what the user touched.
    public static let catalogManagedOverrideKeys: Set<String> = [
        "displayName", "endpoint", "options"
    ]
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

/// Whether a result's metadata came from the search index only or from a page
/// that was actually fetched and verified. Search metadata is NOT page
/// verification: it can prove a page was indexed with an excerpt, never that
/// its content or any date is accurate.
public enum WebSearchContentState: String, Codable, Sendable, CaseIterable {
    case searchMetadataOnly
    case fetchedAndVerified
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

    // MARK: Search-index metadata (optional; older payloads decode unchanged)

    /// Additional excerpts the provider returned (Brave `extra_snippets`,
    /// max 5). Still search excerpts, never fetched page text.
    public var extraSnippets: [String]?
    /// Provider-reported page date: published OR last modified, per the Brave
    /// documentation. Deliberately NOT mapped into `publishedAt`.
    public var pageAge: String?
    /// Provider-reported human-readable relative age (e.g. "2 days ago"), not
    /// an exact timestamp.
    public var relativeAge: String?
    /// Provider-reported crawl/fetch date of the indexed copy (`page_fetched`).
    public var pageFetched: String?
    /// Provider profile for the source (Brave `profile.long_name/name/url`).
    public var sourceProfileName: String?
    public var sourceProfileURL: String?
    /// Provider favicon URL (Brave `meta_url.favicon`).
    public var faviconURL: String?
    /// Provider display path (Brave `meta_url.path`).
    public var displayPath: String?
    /// Explicit evidence state. `nil` means `.searchMetadataOnly`, so records
    /// written before this field existed keep their exact meaning.
    public var contentState: WebSearchContentState?
    /// Provider-returned long summary intended for model reading. It is still
    /// search-index/provider text, not independently fetched or verified page
    /// content. Optional so every older payload decodes unchanged.
    public var summary: String?
    /// Provider-returned page body (DeepSeek `need_content=true`). It is
    /// supplied by the provider and is NOT fetched or verified by Floe;
    /// `contentState` stays `.searchMetadataOnly` so callers cannot confuse it
    /// with a local `web.fetch` result.
    public var content: String?
    /// Provider-reported authority score (DeepSeek: 0...4, `-1` unknown).
    public var authority: Int?

    public var effectiveContentState: WebSearchContentState {
        contentState ?? .searchMetadataOnly
    }

    public init(
        title: String,
        url: URL,
        snippet: String,
        sourceName: String? = nil,
        publishedAt: String? = nil,
        score: Double? = nil,
        provider: WebSearchProviderKind,
        citationID: String,
        extraSnippets: [String]? = nil,
        pageAge: String? = nil,
        relativeAge: String? = nil,
        pageFetched: String? = nil,
        sourceProfileName: String? = nil,
        sourceProfileURL: String? = nil,
        faviconURL: String? = nil,
        displayPath: String? = nil,
        contentState: WebSearchContentState? = nil,
        summary: String? = nil,
        content: String? = nil,
        authority: Int? = nil
    ) {
        self.title = title
        self.url = url
        self.snippet = snippet
        self.sourceName = sourceName
        self.publishedAt = publishedAt
        self.score = score
        self.provider = provider
        self.citationID = citationID
        self.extraSnippets = extraSnippets
        self.pageAge = pageAge
        self.relativeAge = relativeAge
        self.pageFetched = pageFetched
        self.sourceProfileName = sourceProfileName
        self.sourceProfileURL = sourceProfileURL
        self.faviconURL = faviconURL
        self.displayPath = displayPath
        self.contentState = contentState
        self.summary = summary
        self.content = content
        self.authority = authority
    }
}

public struct WebSearchResponse: Sendable {
    public var query: String
    public var results: [WebSearchResult]
    public var providersUsed: [WebSearchProviderKind]
    public var failures: [String]
    /// Optional provider-generated answer text. Empty for every provider that
    /// does not return one and for all older construction sites; callers must
    /// keep it separate from URL citation evidence.
    public var generatedAnswers: [WebSearchProviderGeneratedAnswer]

    public init(
        query: String,
        results: [WebSearchResult],
        providersUsed: [WebSearchProviderKind],
        failures: [String] = [],
        generatedAnswers: [WebSearchProviderGeneratedAnswer] = []
    ) {
        self.query = query
        self.results = results
        self.providersUsed = providersUsed
        self.failures = failures
        self.generatedAnswers = generatedAnswers
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

/// Outcome of the settings-page Test Search. Exactly one provider is ever
/// attempted, with an in-memory credential; the result is UI feedback, never
/// evidence that a run or a provider is production-ready.
public struct WebSearchTestOutcome: Sendable {
    public static let notConfiguredReason = "provider-not-configured"

    public var results: [WebSearchResult]
    /// Machine reason (stable label) or a provider error description. The UI
    /// maps `notConfiguredReason` to product copy and shows provider errors
    /// verbatim (they never contain credentials).
    public var error: String?

    public init(results: [WebSearchResult], error: String?) {
        self.results = results
        self.error = error
    }

    public var didSucceed: Bool { error == nil && !results.isEmpty }
}
