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

/// Wire shape of an OpenAI-compatible `GET /models` response.
struct OpenAIModelListResponse: Decodable {
    struct Item: Decodable {
        var id: String
        var ownedBy: String?

        enum CodingKeys: String, CodingKey {
            case id
            case ownedBy = "owned_by"
        }
    }
    var data: [Item]
}

/// Wire shape of an Anthropic `GET /v1/models` response.
struct AnthropicModelListResponse: Decodable {
    struct Item: Decodable {
        var id: String
        var displayName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }
    var data: [Item]
}

/// Fetches model listings from provider endpoints. Static, no state.
enum ModelDiscovery {

    /// Fetches the OpenAI-compatible `/models` listing. Applies the provider's
    /// bearer credential and non-secret headers. Maps remote identifiers to
    /// `ModelProfile` values with conservative default limits; the user can
    /// refine capabilities/limits afterwards.
    static func fetchOpenAICompatibleModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] {
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
            guard !item.id.isEmpty, item.id.utf8.count <= 256 else { return nil }
            return ModelProfile(
                providerID: provider.id,
                remoteModelID: item.id,
                displayName: item.id,
                limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
                capabilities: [.text, .tools]
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
            guard !item.id.isEmpty, item.id.utf8.count <= 256 else { return nil }
            return ModelProfile(
                providerID: provider.id,
                remoteModelID: item.id,
                displayName: item.displayName ?? item.id,
                limits: ModelLimits(contextTokens: 200_000, maxOutputTokens: 8_192),
                capabilities: [.text, .tools]
            )
        }
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
                throw FloeError.validationFailed("API key 无效或已过期：\(body)")
            }
            throw FloeError.internalError("Model discovery failed (HTTP \(http.statusCode)): \(body)")
        }
    }
}
