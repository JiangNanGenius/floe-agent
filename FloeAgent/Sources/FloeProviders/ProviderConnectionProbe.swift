// FloeProviders — honest connection probe for subscription gateways.
//
// Ordinary providers expose the OpenAI-compatible `GET /models` listing, so
// the wire adapter's default `testConnection` is that free listing. The two
// subscription gateways do not document that route:
//
//   * Volcengine Agent Plan (`/api/plan/v3`) publishes explicit model names
//     and no /models endpoint.
//   * Alibaba Token Plan publishes its supported model list in the product
//     overview and documents chat under `/compatible-mode/v1`, again with no
//     listing contract.
//
// Running the listing probe there fails with HTTP 404 and makes a working
// subscription look disconnected. The honest probe is one minimal
// chat-completions request with a model the user actually selected. It is
// only executed on an explicit Test action; opening or saving the editor
// never sends a request.
//
// Official references verified 2026-10-30:
// * https://docs.volcengine.com/docs/ark/agent-plan-personal-opencode?lang=zh
// * https://help.aliyun.com/zh/model-studio/token-plan-personal-overview
// * https://help.aliyun.com/zh/model-studio/token-plan-multimodal-gen

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore

/// Connection checks report actionable statuses without displaying a service's
/// response body, which may contain account data or an echoed credential.
public enum ProviderConnectionError: LocalizedError, Sendable, Equatable {
    case apiKeyRequired
    case savedKeyUnavailable
    case modelRequired
    case httpStatus(Int)
    case invalidResponse
    case noCompletion
    case rejected

    public var errorDescription: String? {
        switch self {
        case .apiKeyRequired: FloeL10n.l("providers.connection_test.key_required")
        case .savedKeyUnavailable: FloeL10n.l("providers.connection_test.saved_key_unavailable")
        case .modelRequired: FloeL10n.l("providers.no_models")
        case .httpStatus(401): FloeL10n.l("providers.model_discovery.api_key_is_invalid_or_expired")
        case .httpStatus(403): FloeL10n.l("providers.connection_test.model_permission")
        case .httpStatus(429): FloeL10n.l("providers.connection_test.quota")
        case .httpStatus(let status): FloeL10n.l("providers.connection_test.http_error", status)
        case .invalidResponse: FloeL10n.l("providers.connection_test.invalid_response")
        case .noCompletion: FloeL10n.l("providers.connection_test.no_completion")
        case .rejected: FloeL10n.l("providers.connection_test.rejected")
        }
    }

    static func validate(_ response: URLResponse, credentials: ProviderCredentials) throws {
        guard let http = response as? HTTPURLResponse else { throw Self.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401, credentials.apiKey == nil {
                throw Self.apiKeyRequired
            }
            throw Self.httpStatus(http.statusCode)
        }
    }
}

public enum ProviderConnectionProbe {

    /// A compatible wire protocol can carry an API key even when a server
    /// does not require one. Only known supplier connections declare it
    /// mandatory before the first contact with the endpoint.
    public static func requiresAPIKey(
        for provider: ProviderProfile,
        catalogEntry: ProviderCatalogEntry? = nil
    ) -> Bool {
        typealias Connection = ProviderConfigurationValidation.ProviderConnectionIdentity
        guard provider.kind != .local,
              let target = Connection.key(kind: provider.kind, baseURL: provider.baseURL) else { return false }

        if let catalogEntry, catalogEntry.availability == .available,
           let endpoint = catalogEntry.baseURL,
           Connection.key(kind: provider.kind, baseURL: endpoint) == target {
            return catalogEntry.authStyle != "none"
        }
        return ProviderPreset.all.contains { preset in
            preset.id != .custom && preset.authStyle != .none
                && Connection.key(kind: provider.kind, baseURL: preset.defaultBaseURL) == target
        }
    }

    /// True when the adapter's default listing probe must be replaced by a
    /// minimal selected-model chat request.
    public static func usesMinimalChatProbe(provider: ProviderProfile) -> Bool {
        ProviderBillingEndpoint.resolve(provider.baseURL) != nil
    }

    /// Runs the honest probe for one profile.
    ///
    /// - For subscription gateways: one non-streaming, output-bounded chat
    ///   completion for `modelRemoteID`. A missing selection is a validation
    ///   failure, never an invented model or a `/models` fallback.
    /// - For every other profile: the caller's existing adapter (or the
    ///   shipped factory adapter when none is supplied) keeps its existing
    ///   `testConnection` behavior. Passing the editor's adapter is important:
    ///   PAYG/provider-specific probes must not be replaced by a fresh
    ///   generic adapter.
    ///
    public static func testConnection(
        provider: ProviderProfile,
        credentials: ProviderCredentials,
        modelRemoteID: String?,
        adapter: (any ProviderAdapter)? = nil
    ) async throws {
        try await testConnection(
            provider: provider,
            credentials: credentials,
            modelRemoteID: modelRemoteID,
            adapter: adapter,
            session: .shared
        )
    }

    /// Internal session-injectable form used by offline contract tests.
    static func testConnection(
        provider: ProviderProfile,
        credentials: ProviderCredentials,
        modelRemoteID: String?,
        adapter: (any ProviderAdapter)? = nil,
        session: URLSession
    ) async throws {
        guard usesMinimalChatProbe(provider: provider) else {
            let resolved = adapter ?? ProviderAdapterFactory().adapter(for: provider)
            try await resolved.testConnection(
                provider: provider,
                credentials: credentials
            )
            return
        }
        guard let model = modelRemoteID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else {
            throw ProviderConnectionError.modelRequired
        }
        let request = try minimalChatRequest(
            provider: provider,
            credentials: credentials,
            modelRemoteID: model
        )
        let (data, response) = try await BoundedHTTP.data(
            for: request,
            session: session,
            maxBytes: 1_024 * 1_024
        )
        try ProviderConnectionError.validate(response, credentials: credentials)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderConnectionError.invalidResponse
        }
        if let providerError = object["error"], !(providerError is NSNull) {
            throw ProviderConnectionError.rejected
        }
        // A 200 with `{}` (or any payload without a completion choice) is not
        // proof that chat inference works.
        guard let choices = object["choices"] as? [[String: Any]],
              !choices.isEmpty,
              choices.contains(where: { $0["message"] is [String: Any] }) else {
            throw ProviderConnectionError.noCompletion
        }
    }

    /// Hard output cap for the paid-but-tiny probe. Sixteen output tokens is
    /// enough for the one-word reply while preventing a reasoning model from
    /// generating hundreds of billed tokens.
    public static let probeMaxOutputTokens = 16

    /// The exact minimal request used by the subscription probe. Exposed for
    /// offline contract tests: path `/chat/completions`, bearer credential,
    /// the selected model, a short text message and a bounded output.
    public static func minimalChatRequest(
        provider: ProviderProfile,
        credentials: ProviderCredentials,
        modelRemoteID: String
    ) throws -> URLRequest {
        let url = provider.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = credentials.apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (field, value) in provider.nonSecretHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let body: [String: Any] = [
            "model": modelRemoteID,
            "messages": [["role": "user", "content": "Connection test. Reply OK."]],
            "stream": false
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
