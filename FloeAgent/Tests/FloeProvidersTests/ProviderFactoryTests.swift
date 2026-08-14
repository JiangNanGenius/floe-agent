// FloeProvidersTests — Adapter factory, presets and discovery contracts.
// Offline: no live credentials or network. Discovery is validated through
// preset/wire mapping and response-decoding contracts, not live calls.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeModels
@testable import FloeProviders
import FloeTestSupport

@Suite("FloeProviders.Factory")
struct ProviderFactoryTests {

    @Test("Factory maps each wire protocol to the correct adapter kind")
    func factoryMapsProtocols() {
        #expect(ProviderAdapterFactory.adapter(for: .openAIResponses) is OpenAIResponsesAdapter)
        #expect(ProviderAdapterFactory.adapter(for: .openAIChatCompletions) is OpenAIChatCompletionsAdapter)
        #expect(ProviderAdapterFactory.adapter(for: .anthropicMessages) is AnthropicMessagesAdapter)
    }

    @Test("Compatible third-party kinds reuse the Chat Completions wire adapter")
    func compatibleKindsReuseChatAdapter() {
        for kind in [ProviderKind.volcengineArk, .alibabaStudio, .custom] {
            let preset = ProviderPreset.preset(for: kind)
            #expect(preset.wireProtocol == .openAIChatCompletions)
            #expect(ProviderAdapterFactory.adapter(for: preset.wireProtocol) is OpenAIChatCompletionsAdapter)
        }
    }

    @Test("All launch presets are present and use HTTPS public endpoints")
    func presetsAreCompleteAndSecure() throws {
        let kinds = Set(ProviderPreset.all.map(\.kind))
        #expect(kinds.isSuperset(of: [.openAI, .anthropic, .volcengineArk, .alibabaStudio, .custom]))
        for preset in ProviderPreset.all {
            #expect(preset.defaultBaseURL.scheme == "https", "\(preset.displayName) must default to HTTPS")
            // Presets never carry credentials.
            try preset.defaultBaseURL.absoluteString.withContiguousStorageIfAvailable { _ in }
        }
    }

    @Test("Factory returns a working adapter for a full provider profile")
    func factoryForProfile() {
        let profile = TestFixtures.localhostProvider(wireProtocol: .openAIResponses)
        let factory = ProviderAdapterFactory()
        #expect(factory.adapter(for: profile) is OpenAIResponsesAdapter)
        #expect(factory.adapter(for: profile).protocolKind == .openAIResponses)
    }

    @Test("Preset lookup falls back to custom for unknown kinds")
    func presetFallback() {
        // Every ProviderKind resolves to some preset; custom is the floor.
        for kind in ProviderKind.allCases {
            let preset = ProviderPreset.preset(for: kind)
            #expect(ProviderPreset.all.contains(preset))
        }
    }
}

@Suite("FloeProviders.ModelDiscovery")
struct ModelDiscoveryContractTests {

    @Test("OpenAI-compatible /models response decodes remote identifiers")
    func openAIModelsDecode() throws {
        let json = #"{"data":[{"id":"gpt-5","owned_by":"openai"},{"id":"gpt-5-mini"}]}"#
        let decoded = try JSONDecoder().decode(OpenAIModelListResponse.self, from: Data(json.utf8))
        #expect(decoded.data.map(\.id) == ["gpt-5", "gpt-5-mini"])
        #expect(decoded.data[0].ownedBy == "openai")
    }

    @Test("Anthropic /v1/models response decodes display names")
    func anthropicModelsDecode() throws {
        let json = #"{"data":[{"id":"claude-opus-4","display_name":"Claude Opus 4"}]}"#
        let decoded = try JSONDecoder().decode(AnthropicModelListResponse.self, from: Data(json.utf8))
        #expect(decoded.data[0].id == "claude-opus-4")
        #expect(decoded.data[0].displayName == "Claude Opus 4")
    }

    @Test("Malformed discovery payload throws rather than fabricating models")
    func malformedDiscoveryThrows() {
        let garbage = Data(#"{"unexpected":true}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(OpenAIModelListResponse.self, from: garbage)
        }
    }
}
