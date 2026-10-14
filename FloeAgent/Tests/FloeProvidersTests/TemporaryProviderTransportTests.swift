// FloeProvidersTests — Temporary-chat provider transport privacy.
//
// The ephemeralTransport flag must route temporary conversation requests onto
// a scoped ephemeral session (no shared on-disk URLCache/cookie/credential
// storage) WITHOUT mutating or wiping the ordinary global session/cache, and
// the per-request cache directive stays as defense in depth on the URLRequest.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeModels
@testable import FloeProviders

@Suite("FloeProviders.TemporaryTransport")
struct TemporaryProviderTransportTests {

    @Test("Ephemeral transport uses a dedicated session with every storage slot nilled")
    func ephemeralSessionIsScoped() {
        let session = ProviderTransport.session(ephemeral: true)
        #expect(session !== URLSession.shared)
        let configuration = session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    @Test("Ordinary transport keeps using the shared session untouched")
    func ordinaryTransportKeepsSharedSession() {
        let session = ProviderTransport.session(ephemeral: false)
        #expect(session === URLSession.shared)
        // The ordinary/global cache is never mutated by a temporary chat.
        #expect(URLSession.shared.configuration.urlCache != nil)
    }

    @Test("The ephemeral session is one shared scoped instance")
    func ephemeralSessionIsStable() {
        #expect(ProviderTransport.session(ephemeral: true) === ProviderTransport.session(ephemeral: true))
    }

    @Test("ephemeralTransport sets the no-cache directive on every wire adapter's URLRequest")
    func ephemeralURLRequestCarriesCacheDirective() throws {
        let provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "https://example.test/v1"))
        )
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "text",
            displayName: "Text",
            limits: .init(contextTokens: 4096, maxOutputTokens: 1024),
            capabilities: [.text, .tools]
        )
        let credentials = ProviderCredentials(apiKey: "test-key")
        var request = ProviderStreamRequest(
            provider: provider,
            model: model,
            messages: [(role: "user", content: "hi")],
            ephemeralTransport: true
        )
        request.allToolNames = ["tools.list", "tools.search"]

        let responses = try OpenAIResponsesAdapter().buildURLRequest(request: request, credentials: credentials)
        #expect(responses.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        let chat = try OpenAIChatCompletionsAdapter().buildURLRequest(request: request, credentials: credentials)
        #expect(chat.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        let anthropic = try AnthropicMessagesAdapter().buildURLRequest(request: request, credentials: credentials)
        #expect(anthropic.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)

        var ordinary = request
        ordinary.ephemeralTransport = false
        let ordinaryRequest = try OpenAIResponsesAdapter().buildURLRequest(request: ordinary, credentials: credentials)
        #expect(ordinaryRequest.cachePolicy != .reloadIgnoringLocalAndRemoteCacheData)
    }
}
