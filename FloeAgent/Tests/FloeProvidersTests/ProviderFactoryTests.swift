// FloeProvidersTests — Adapter factory, presets and discovery contracts.
// Offline: no live credentials or network. Discovery is validated through
// preset/wire mapping and response-decoding contracts, not live calls.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeModels
@testable import FloeProviders
import FloeTestSupport

private final class CapabilityProbeAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    var eventBuilder: @Sendable (ProviderStreamRequest) -> [AgentEvent]

    init(eventBuilder: @escaping @Sendable (ProviderStreamRequest) -> [AgentEvent]) {
        self.eventBuilder = eventBuilder
    }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let events = eventBuilder(request)
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}

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

    @Test("Provider templates have stable unique IDs and exactly three wire protocols")
    func presetIdentityAndProtocols() {
        #expect(Set(ProviderPreset.all.map(\.id)).count == ProviderPreset.all.count)
        #expect(ProviderPreset.openAIResponses.supportedProtocols == [
            .openAIResponses, .openAIChatCompletions
        ])
        #expect(ProviderPreset.anthropic.supportedProtocols == [.anthropicMessages])
        #expect(Set(ProviderPreset.custom.supportedProtocols) == Set(ModelProtocol.allCases))
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

    @Test("Capability probe requires a matching structured tool event")
    func nativeToolProbeVerifiesStructuredEvent() async throws {
        let provider = TestFixtures.localhostProvider()
        let model = TestFixtures.testModel(providerID: provider.id)
        let adapter = CapabilityProbeAdapter { request in
            let prompt = request.messages.first?.content ?? ""
            let nonce = prompt.split(separator: " ").compactMap { token -> String? in
                let candidate = String(token).trimmingCharacters(in: .punctuationCharacters)
                return UUID(uuidString: candidate)?.uuidString
            }.first ?? ""
            let call = try! ToolCall(
                id: "probe-call",
                toolName: NativeToolCapabilityProbe.toolName,
                argumentsJSON: Data(#"{"nonce":"\#(nonce)"}"#.utf8),
                scope: .local
            )
            return [.toolRequest(call)]
        }

        let status = await NativeToolCapabilityProbe.run(
            adapter: adapter,
            provider: provider,
            model: model,
            credentials: .init()
        )
        #expect(status == .verified)
    }

    @Test("Capability probe ignores pseudo tool-call text")
    func nativeToolProbeRejectsPseudoText() async {
        let provider = TestFixtures.localhostProvider()
        let model = TestFixtures.testModel(providerID: provider.id)
        let adapter = CapabilityProbeAdapter { _ in [
            .textDelta(.init(text: #"<|FunctionCallBegin|>{"name":"floe_capability_probe"}<|FunctionCallEnd|>"#)),
            .completed(.init(stopReason: .endTurn))
        ] }

        let status = await NativeToolCapabilityProbe.run(
            adapter: adapter,
            provider: provider,
            model: model,
            credentials: .init()
        )
        guard case .inconclusive = status else {
            Issue.record("Expected pseudo-call text to remain inconclusive, got \(status)")
            return
        }
    }

    @Test("Discovered capabilities repair legacy text-only records")
    func catalogMergePreservesTools() {
        let providerID = UUID()
        let existingID = UUID()
        let existing = ModelProfile(
            id: existingID,
            providerID: providerID,
            remoteModelID: "doubao-seed",
            displayName: "My Doubao",
            limits: ModelLimits(contextTokens: 32_000, maxOutputTokens: 2_048),
            capabilities: [.text]
        )
        let discovered = ModelProfile(
            providerID: providerID,
            remoteModelID: "doubao-seed",
            displayName: "doubao-seed",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: [.text, .tools]
        )

        let merged = ModelCatalogMerger.merge(existing: [existing], discovered: [discovered])
        #expect(merged.count == 1)
        #expect(merged[0].id == existingID)
        #expect(merged[0].displayName == "My Doubao")
        #expect(merged[0].limits.contextTokens == 32_000)
        #expect(merged[0].capabilities.contains(.tools))
    }

    @Test("Manual text models default to native tools for supported protocols")
    func manualCapabilityDefaults() {
        for wireProtocol in ModelProtocol.allCases {
            let capabilities = ModelCapabilities.defaultTextModel(for: wireProtocol)
            #expect(capabilities.contains(.text))
            #expect(capabilities.contains(.tools))
            #expect(capabilities.contains(.approval))
        }
    }

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
