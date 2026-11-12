// FloeProviders — `/models` discovery for OpenAI-compatible endpoints and
// Anthropic. See docs/ALPHA_DAILY_PLAN.md: use `/models` discovery where
// supported and a safe manual-model fallback where it is not. Discovery
// failures surface as thrown errors so the editor can fall back to manual
// model entry. No credentials are logged.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore

/// Wire shape of an OpenAI-compatible `GET /models` response. Optional
/// limit metadata is parsed when the endpoint actually reports it; absence
/// must never be turned into an invented output ceiling.
struct OpenAIModelListResponse: Decodable {
    struct Item: Decodable {
        var id: String
        var ownedBy: String?
        var contextLength: Int?
        var maxContextLength: Int?
        var maxInputTokens: Int?
        var maxOutputTokens: Int?
        var maxCompletionTokens: Int?
        var modelSpec: ModelSpec?

        struct ModelSpec: Decodable {
            var capabilities: ReasoningCapabilities?

            struct ReasoningCapabilities: Decodable {
                var supportsReasoning: Bool?
                var supportsReasoningEffort: Bool?
                var reasoningEffortOptions: [String]?
                var defaultReasoningEffort: String?

                enum CodingKeys: String, CodingKey {
                    case supportsReasoning, supportsReasoningEffort
                    case reasoningEffortOptions, defaultReasoningEffort
                }

                init(from decoder: any Decoder) throws {
                    let fields = try decoder.container(keyedBy: CodingKeys.self)
                    supportsReasoning = try? fields.decodeIfPresent(Bool.self, forKey: .supportsReasoning)
                    supportsReasoningEffort = try? fields.decodeIfPresent(Bool.self, forKey: .supportsReasoningEffort)
                    reasoningEffortOptions = try? fields.decodeIfPresent([String].self, forKey: .reasoningEffortOptions)
                    defaultReasoningEffort = try? fields.decodeIfPresent(String.self, forKey: .defaultReasoningEffort)
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case id
            case ownedBy = "owned_by"
            case contextLength = "context_length"
            case maxContextLength = "max_context_length"
            case maxInputTokens = "max_input_tokens"
            case maxOutputTokens = "max_output_tokens"
            case maxCompletionTokens = "max_completion_tokens"
            case modelSpec = "model_spec"
        }

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            // Preserve every pre-existing identity/limit decoding contract.
            id = try fields.decode(String.self, forKey: .id)
            ownedBy = try fields.decodeIfPresent(String.self, forKey: .ownedBy)
            contextLength = try fields.decodeIfPresent(Int.self, forKey: .contextLength)
            maxContextLength = try fields.decodeIfPresent(Int.self, forKey: .maxContextLength)
            maxInputTokens = try fields.decodeIfPresent(Int.self, forKey: .maxInputTokens)
            maxOutputTokens = try fields.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
            maxCompletionTokens = try fields.decodeIfPresent(Int.self, forKey: .maxCompletionTokens)
            // A malformed optional extension must not discard an otherwise
            // usable legacy model or the rest of the provider's listing.
            modelSpec = try? fields.decodeIfPresent(ModelSpec.self, forKey: .modelSpec)
        }

        /// These are the endpoint's native tokens, not Floe enum values.
        /// Keep a bounded, inert list and do not infer a thinking dialect or
        /// a disable capability from a token such as `none`.
        var reasoningMetadata: ModelReasoningMetadata? {
            guard let facts = modelSpec?.capabilities else { return nil }
            let options = facts.reasoningEffortOptions.map { values in
                var seen = Set<String>()
                return values.prefix(32).filter { Self.isEffortToken($0) && seen.insert($0).inserted }
            }
            let defaultEffort = facts.defaultReasoningEffort.flatMap { value -> String? in
                guard Self.isEffortToken(value), options?.contains(value) != false else { return nil }
                return value
            }
            guard facts.supportsReasoning != nil || facts.supportsReasoningEffort != nil
                    || options != nil || defaultEffort != nil else { return nil }
            return ModelReasoningMetadata(
                supportsReasoning: facts.supportsReasoning,
                supportsReasoningEffort: facts.supportsReasoningEffort,
                supportedEfforts: options,
                defaultEffort: defaultEffort
            )
        }

        private static func isEffortToken(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy { byte in
                switch byte {
                case 45, 48...57, 65...90, 95, 97...122: true
                default: false
                }
            }
        }

        /// First trusted context-window field that is actually positive. A
        /// zero or negative earlier field (some gateways report 0 for
        /// "unknown") must not mask a later valid value.
        var metadataContextTokens: Int? {
            [contextLength, maxContextLength, maxInputTokens]
                .compactMap { $0 }
                .first { $0 > 0 }
        }

        /// First trusted output-ceiling field that is actually positive.
        var metadataMaxOutputTokens: Int? {
            [maxOutputTokens, maxCompletionTokens]
                .compactMap { $0 }
                .first { $0 > 0 }
        }
    }
    var data: [Item]
}

/// Wire shape of an Anthropic `GET /v1/models` response.
struct AnthropicModelListResponse: Decodable {
    struct Item: Decodable {
        var id: String
        var displayName: String?
        var contextLength: Int?
        var maxContextLength: Int?
        var maxInputTokens: Int?
        var maxOutputTokens: Int?
        var maxCompletionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case contextLength = "context_length"
            case maxContextLength = "max_context_length"
            case maxInputTokens = "max_input_tokens"
            case maxOutputTokens = "max_output_tokens"
            case maxCompletionTokens = "max_completion_tokens"
        }

        var metadataContextTokens: Int? {
            [contextLength, maxContextLength, maxInputTokens]
                .compactMap { $0 }
                .first { $0 > 0 }
        }

        var metadataMaxOutputTokens: Int? {
            [maxOutputTokens, maxCompletionTokens]
                .compactMap { $0 }
                .first { $0 > 0 }
        }
    }
    var data: [Item]
}

/// Fetches model listings from provider endpoints. Static, no state.
enum ModelDiscovery {

    /// Fetches the OpenAI-compatible `/models` listing. Applies the provider's
    /// bearer credential and non-secret headers. Maps remote identifiers to
    /// `ModelProfile` values using any limits metadata the endpoint actually
    /// reports; absent output metadata stays 0 ("unset") so adapters own the
    /// protocol default and user overrides survive a catalog merge.
    static func fetchOpenAICompatibleModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] {
        // The plan catalog is descriptive, never an undocumented account
        // listing. Fence the common wire entry too, so a future caller cannot
        // reintroduce /models outside the editor's disabled refresh control.
        guard ProviderBillingEndpoint.resolve(provider.baseURL) == nil else {
            throw FloeError.invalidConfiguration(FloeL10n.l("providers.model_discovery.subscription_catalog"))
        }
        let url = provider.baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = credentials.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in provider.nonSecretHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await BoundedHTTP.data(for: request, maxBytes: 4 * 1_024 * 1_024)
        try ensureSuccess(response, data: data, secret: credentials.apiKey)
        let decoded = try JSONDecoder().decode(OpenAIModelListResponse.self, from: data)
        return decoded.data.prefix(500).compactMap { item in
            mapOpenAIItem(
                providerID: provider.id,
                id: item.id,
                displayName: item.id,
                contextTokens: item.metadataContextTokens,
                maxOutputTokens: item.metadataMaxOutputTokens,
                reasoningMetadata: item.reasoningMetadata
            )
        }
    }

    /// Fetches the Anthropic `/v1/models` listing using the `x-api-key` header.
    static func fetchAnthropicModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] {
        let url = provider.baseURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AnthropicMessagesAdapter.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let apiKey = credentials.apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        for (field, value) in provider.nonSecretHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await BoundedHTTP.data(for: request, maxBytes: 4 * 1_024 * 1_024)
        try ensureSuccess(response, data: data, secret: credentials.apiKey)
        let decoded = try JSONDecoder().decode(AnthropicModelListResponse.self, from: data)
        return decoded.data.prefix(500).compactMap { item in
            mapAnthropicItem(
                providerID: provider.id,
                id: item.id,
                displayName: item.displayName ?? item.id,
                contextTokens: item.metadataContextTokens,
                maxOutputTokens: item.metadataMaxOutputTokens
            )
        }
    }

    /// Trusted context-window metadata. Only positive integers are accepted;
    /// larger values are clamped to the documented ten-million-token ceiling.
    /// Nil means the endpoint did not report a trustworthy value.
    static func sanitizedContextTokens(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return min(value, 10_000_000)
    }

    /// Trusted output-ceiling metadata, clamped to the resolved context
    /// window. Zero, negative or absent values become 0 ("unset") — never an
    /// invented provider-side limit.
    static func sanitizedMaxOutputTokens(_ value: Int?, contextTokens: Int) -> Int {
        guard let value, value > 0 else { return 0 }
        return min(value, contextTokens)
    }

    /// Maps one OpenAI-compatible `/models` item. Pure and synchronous so the
    /// limits contract can be tested without network access.
    static func mapOpenAIItem(
        providerID: UUID,
        id: String,
        displayName: String,
        contextTokens: Int?,
        maxOutputTokens: Int?,
        reasoningMetadata: ModelReasoningMetadata? = nil
    ) -> ModelProfile? {
        mapItem(
            providerID: providerID,
            id: id,
            displayName: displayName,
            contextTokens: contextTokens,
            maxOutputTokens: maxOutputTokens,
            defaultContextTokens: 128_000,
            reasoningMetadata: reasoningMetadata
        )
    }

    /// Maps one Anthropic `/v1/models` item with Anthropic's default window.
    static func mapAnthropicItem(
        providerID: UUID,
        id: String,
        displayName: String,
        contextTokens: Int?,
        maxOutputTokens: Int?
    ) -> ModelProfile? {
        mapItem(
            providerID: providerID,
            id: id,
            displayName: displayName,
            contextTokens: contextTokens,
            maxOutputTokens: maxOutputTokens,
            defaultContextTokens: 200_000
        )
    }

    private static func mapItem(
        providerID: UUID,
        id: String,
        displayName: String,
        contextTokens: Int?,
        maxOutputTokens: Int?,
        defaultContextTokens: Int,
        reasoningMetadata: ModelReasoningMetadata? = nil
    ) -> ModelProfile? {
        guard !id.isEmpty, id.utf8.count <= 256 else { return nil }
        let context = sanitizedContextTokens(contextTokens) ?? defaultContextTokens
        return ModelProfile(
            providerID: providerID,
            remoteModelID: id,
            displayName: displayName,
            limits: ModelLimits(
                contextTokens: context,
                maxOutputTokens: 0
            ),
            capabilities: [.text, .tools],
            reasoningMetadata: reasoningMetadata,
            // Discovery has no user preference. A direct canonical upsert
            // must retain a saved choice rather than defaulting it to false.
            omitReasoningParameters: nil
        )
    }

    /// Throws a normalized provider error for non-2xx responses. The body is
    /// truncated and never includes credentials (the request carries them,
    /// not the response). Auth failures (401/403) surface the provider's own
    /// message so the user knows the key is invalid, not just "HTTP 401".
    private static func ensureSuccess(_ response: URLResponse, data: Data, secret: String?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let rawBody = String(decoding: data.prefix(1024), as: UTF8.self)
            let body = SecretRedactor.redact(rawBody, secret: secret)
            // Auth failures: surface the provider's message directly so the
            // user sees "api key invalid" instead of a bare HTTP status.
            if http.statusCode == 401 || http.statusCode == 403 {
                throw FloeError.validationFailed(FloeL10n.l("providers.model_discovery.api_key_is_invalid_or_expired", body))
            }
            throw FloeError.internalError("Model discovery failed (HTTP \(http.statusCode)): \(body)")
        }
    }
}
