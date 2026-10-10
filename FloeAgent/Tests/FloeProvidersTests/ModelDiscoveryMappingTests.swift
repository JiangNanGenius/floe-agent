// FloeProvidersTests — `/models` discovery mapping contract: trusted limit
// metadata is used when present, absent metadata keeps the context default
// and leaves output unset, and a merge never discards a user's explicit cap.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

@Suite("FloeProviders.ModelDiscoveryMapping")
struct ModelDiscoveryMappingTests {

    @Test("OpenAI-style metadata supplies both context and output limits")
    func openAIMetadataIsUsed() throws {
        let providerID = UUID()
        let model = try #require(ModelDiscovery.mapOpenAIItem(
            providerID: providerID,
            id: "meta-model",
            displayName: "Meta Model",
            contextTokens: 64_000,
            maxOutputTokens: 2_048
        ))
        #expect(model.limits.contextTokens == 64_000)
        #expect(model.limits.maxOutputTokens == 2_048)
        #expect(model.limits.configuredMaxOutputTokens == 2_048)
        #expect(model.capabilities.contains(.text))
        #expect(model.capabilities.contains(.tools))
    }

    @Test("Absent metadata keeps the context default and leaves output unset")
    func absentMetadataUsesUnsetOutput() throws {
        let model = try #require(ModelDiscovery.mapOpenAIItem(
            providerID: UUID(),
            id: "plain-model",
            displayName: "Plain",
            contextTokens: nil,
            maxOutputTokens: nil
        ))
        #expect(model.limits.contextTokens == 128_000)
        #expect(model.limits.maxOutputTokens == 0)
        #expect(model.limits.configuredMaxOutputTokens == nil)
    }

    @Test("Invalid metadata is ignored and output zero stays unset")
    func invalidMetadataIgnored() throws {
        let zeroAndNegative = try #require(ModelDiscovery.mapOpenAIItem(
            providerID: UUID(),
            id: "invalid",
            displayName: "Invalid",
            contextTokens: 0,
            maxOutputTokens: -5
        ))
        #expect(zeroAndNegative.limits.contextTokens == 128_000)
        #expect(zeroAndNegative.limits.maxOutputTokens == 0)

        let negativeContext = try #require(ModelDiscovery.mapOpenAIItem(
            providerID: UUID(),
            id: "invalid-context",
            displayName: "Invalid",
            contextTokens: -1,
            maxOutputTokens: 512
        ))
        #expect(negativeContext.limits.contextTokens == 128_000)
        #expect(negativeContext.limits.maxOutputTokens == 512)
    }

    @Test("Huge metadata is clamped to the documented ceilings")
    func hugeMetadataIsClamped() throws {
        let model = try #require(ModelDiscovery.mapOpenAIItem(
            providerID: UUID(),
            id: "huge",
            displayName: "Huge",
            contextTokens: 500_000_000,
            maxOutputTokens: 500_000_000
        ))
        #expect(model.limits.contextTokens == 10_000_000)
        #expect(model.limits.maxOutputTokens == 10_000_000)

        // Output can never exceed the resolved context window.
        let bounded = try #require(ModelDiscovery.mapOpenAIItem(
            providerID: UUID(),
            id: "bounded",
            displayName: "Bounded",
            contextTokens: 4_096,
            maxOutputTokens: 65_536
        ))
        #expect(bounded.limits.contextTokens == 4_096)
        #expect(bounded.limits.maxOutputTokens == 4_096)
    }

    @Test("Anthropic mapping uses Anthropic's default window and metadata")
    func anthropicVariant() throws {
        let withMetadata = try #require(ModelDiscovery.mapAnthropicItem(
            providerID: UUID(),
            id: "claude-x",
            displayName: "Claude X",
            contextTokens: 1_000_000,
            maxOutputTokens: 32_768
        ))
        #expect(withMetadata.limits.contextTokens == 1_000_000)
        #expect(withMetadata.limits.maxOutputTokens == 32_768)

        let withoutMetadata = try #require(ModelDiscovery.mapAnthropicItem(
            providerID: UUID(),
            id: "claude-y",
            displayName: "Claude Y",
            contextTokens: nil,
            maxOutputTokens: nil
        ))
        #expect(withoutMetadata.limits.contextTokens == 200_000)
        #expect(withoutMetadata.limits.maxOutputTokens == 0)
    }

    @Test("Decoded payloads expose every trusted alias and reject unusable ids")
    func decodedAliasesAndUnusableIDs() throws {
        let json = #"""
        {"data":[
        {"id":"gateway-a","context_length":32000,"max_completion_tokens":4096},
        {"id":"gateway-b","max_context_length":16000,"max_output_tokens":2048},
        {"id":"gateway-c","max_input_tokens":8000,"max_output_tokens":1024}
        ]}
        """#
        let decoded = try JSONDecoder().decode(OpenAIModelListResponse.self, from: Data(json.utf8))
        #expect(decoded.data.map(\.metadataContextTokens) == [32_000, 16_000, 8_000])
        #expect(decoded.data.map(\.metadataMaxOutputTokens) == [4_096, 2_048, 1_024])

        let anthropicJSON = #"{"data":[{"id":"claude-z","display_name":"Claude Z","max_input_tokens":180000,"max_output_tokens":8192}]}"#
        let anthropicDecoded = try JSONDecoder().decode(AnthropicModelListResponse.self, from: Data(anthropicJSON.utf8))
        #expect(anthropicDecoded.data[0].displayName == "Claude Z")
        #expect(anthropicDecoded.data[0].metadataContextTokens == 180_000)
        #expect(anthropicDecoded.data[0].metadataMaxOutputTokens == 8_192)

        #expect(ModelDiscovery.mapOpenAIItem(
            providerID: UUID(), id: "", displayName: "empty",
            contextTokens: nil, maxOutputTokens: nil
        ) == nil)
        let overlong = String(repeating: "a", count: 257)
        #expect(ModelDiscovery.mapOpenAIItem(
            providerID: UUID(), id: overlong, displayName: "long",
            contextTokens: nil, maxOutputTokens: nil
        ) == nil)
    }

    @Test("A zero first metadata field does not mask a later valid field")
    func zeroFirstFieldFallsThrough() throws {
        let json = #"""
        {"data":[
        {"id":"gateway-zero","context_length":0,"max_context_length":16000,"max_output_tokens":0,"max_completion_tokens":4096}
        ]}
        """#
        let decoded = try JSONDecoder().decode(OpenAIModelListResponse.self, from: Data(json.utf8))
        let item = try #require(decoded.data.first)
        #expect(item.metadataContextTokens == 16_000)
        #expect(item.metadataMaxOutputTokens == 4_096)

        let model = try #require(ModelDiscovery.mapOpenAIItem(
            providerID: UUID(),
            id: item.id,
            displayName: item.id,
            contextTokens: item.metadataContextTokens,
            maxOutputTokens: item.metadataMaxOutputTokens
        ))
        #expect(model.limits.contextTokens == 16_000)
        #expect(model.limits.maxOutputTokens == 4_096)
    }

    @Test("A merge keeps the existing explicit output limit when discovery reports unset")
    func mergeKeepsExplicitOutputLimit() throws {
        let providerID = UUID()
        let existing = ModelProfile(
            providerID: providerID,
            remoteModelID: "gateway-model",
            displayName: "My Gateway Model",
            limits: ModelLimits(contextTokens: 32_000, maxOutputTokens: 4_096),
            capabilities: [.text]
        )
        let discovered = try #require(ModelDiscovery.mapOpenAIItem(
            providerID: providerID,
            id: "gateway-model",
            displayName: "gateway-model",
            contextTokens: nil,
            maxOutputTokens: nil
        ))
        #expect(discovered.limits.maxOutputTokens == 0)

        let merged = ModelCatalogMerger.merge(existing: [existing], discovered: [discovered])
        #expect(merged.count == 1)
        #expect(merged[0].limits.maxOutputTokens == 4_096)
        #expect(merged[0].limits.contextTokens == 32_000)
    }
}
