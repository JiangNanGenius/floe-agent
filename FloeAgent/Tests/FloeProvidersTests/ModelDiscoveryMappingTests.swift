// FloeProvidersTests — `/models` discovery mapping contract: trusted limit
// metadata is used when present, absent metadata keeps the context default
// and leaves output unset, and a merge never discards a user's explicit cap.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

@Suite("FloeProviders.ModelDiscoveryMapping")
struct ModelDiscoveryMappingTests {

    @Test("Discovery preserves reported native effort tokens and false versus unknown without guessing a dialect")
    func reasoningMetadataRetainsReportedNativeCapabilities() throws {
        let json = #"""
        {"data":[
          {"id":"custom-reasoning","model_spec":{"capabilities":{
            "supportsReasoning":true,"supportsReasoningEffort":true,
            "reasoningEffortOptions":["none","high","max","high","not an effort"],
            "defaultReasoningEffort":"high"}}},
          {"id":"custom-no-reasoning","model_spec":{"capabilities":{
            "supportsReasoning":false,"supportsReasoningEffort":false}}},
          {"id":"custom-fixed-reasoning","model_spec":{"capabilities":{
            "supportsReasoning":true,"supportsReasoningEffort":false}}},
          {"id":"unknown-custom"},
          {"id":"invalid-default","model_spec":{"capabilities":{
            "reasoningEffortOptions":["high","max"],"defaultReasoningEffort":"medium"}}}
        ]}
        """#
        let decoded = try JSONDecoder().decode(OpenAIModelListResponse.self, from: Data(json.utf8))
        let item = try #require(decoded.data.first)
        let metadata = try #require(item.reasoningMetadata)
        #expect(metadata.supportsReasoning == true)
        #expect(metadata.supportsReasoningEffort == true)
        #expect(metadata.supportedEfforts == ["none", "high", "max"])
        #expect(metadata.defaultEffort == "high")
        #expect(metadata.canDisableThinking == nil)
        #expect(decoded.data[1].reasoningMetadata?.supportsReasoning == false)
        #expect(decoded.data[1].reasoningMetadata?.supportsReasoningEffort == false)
        // The observed public shape can emit reasoning without allowing
        // callers to select an effort. These flags must remain independent.
        #expect(decoded.data[2].reasoningMetadata?.supportsReasoning == true)
        #expect(decoded.data[2].reasoningMetadata?.supportsReasoningEffort == false)
        #expect(decoded.data[2].reasoningMetadata?.supportedEfforts == nil)
        #expect(decoded.data[2].reasoningMetadata?.defaultEffort == nil)
        #expect(decoded.data[3].reasoningMetadata == nil)
        #expect(decoded.data[4].reasoningMetadata?.defaultEffort == nil)

        let model = try #require(ModelDiscovery.mapOpenAIItem(
            providerID: UUID(), id: item.id, displayName: item.id,
            contextTokens: nil, maxOutputTokens: nil, reasoningMetadata: metadata
        ))
        #expect(model.reasoningMetadata == metadata)
        #expect(model.reasoningEffort == nil)
        let encoded = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(ModelProfile.self, from: encoded).reasoningMetadata == metadata)
        var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "reasoningMetadata")
        legacyObject.removeValue(forKey: "omitReasoningParameters")
        let legacy = try JSONDecoder().decode(ModelProfile.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        #expect(legacy.reasoningMetadata == nil)
        #expect(legacy.omitReasoningParameters == nil)
        #expect(legacy.effectiveOmitReasoningParameters == false)
        #expect(legacy.id == model.id && legacy.remoteModelID == model.remoteModelID)
        var optedOut = model
        optedOut.omitReasoningParameters = true
        let roundTrip = try JSONDecoder().decode(ModelProfile.self, from: JSONEncoder().encode(optedOut))
        #expect(roundTrip.omitReasoningParameters == true)
        #expect(roundTrip.effectiveOmitReasoningParameters)
        #expect(model.omitReasoningParameters == nil)
        #expect(model.effectiveOmitReasoningParameters == false)
        let newModelRoundTrip = try JSONDecoder().decode(ModelProfile.self, from: encoded)
        #expect(newModelRoundTrip == model)
        let manual = ModelProfile(providerID: model.providerID, remoteModelID: "manual-model",
                                  displayName: "Manual model", limits: model.limits)
        #expect(manual.omitReasoningParameters == false)
        #expect(try JSONDecoder().decode(ModelProfile.self, from: JSONEncoder().encode(manual)) == manual)

        let malformedExtensions = #"""
        {"data":[
          {"id":"ordinary","context_length":32000},
          {"id":"bad-spec","model_spec":"unknown-extension"},
          {"id":"bad-capabilities","model_spec":{"capabilities":123}},
          {"id":"bad-effort-values","model_spec":{"capabilities":{
            "supportsReasoning":true,"supportsReasoningEffort":false,
            "reasoningEffortOptions":["high",1],"defaultReasoningEffort":42}}},
          {"id":"bad-boolean","model_spec":{"capabilities":{
            "supportsReasoning":"true","supportsReasoningEffort":{},
            "reasoningEffortOptions":["high"],"defaultReasoningEffort":"high"}}}
        ]}
        """#
        let tolerant = try JSONDecoder().decode(OpenAIModelListResponse.self, from: Data(malformedExtensions.utf8))
        #expect(tolerant.data.map(\.id) == ["ordinary", "bad-spec", "bad-capabilities", "bad-effort-values", "bad-boolean"])
        #expect(tolerant.data[0].metadataContextTokens == 32_000)
        #expect(tolerant.data[1].reasoningMetadata == nil)
        #expect(tolerant.data[2].reasoningMetadata == nil)
        #expect(tolerant.data[3].reasoningMetadata?.supportsReasoning == true)
        #expect(tolerant.data[3].reasoningMetadata?.supportsReasoningEffort == false)
        #expect(tolerant.data[3].reasoningMetadata?.supportedEfforts == nil)
        #expect(tolerant.data[3].reasoningMetadata?.defaultEffort == nil)
        #expect(tolerant.data[4].reasoningMetadata?.supportsReasoning == nil)
        #expect(tolerant.data[4].reasoningMetadata?.supportsReasoningEffort == nil)
        #expect(tolerant.data[4].reasoningMetadata?.supportedEfforts == ["high"])
        #expect(tolerant.data[4].reasoningMetadata?.canDisableThinking == nil)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(OpenAIModelListResponse.self, from: Data(#"{"data":[{"context_length":32000}]}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(OpenAIModelListResponse.self, from: Data(#"{"data":[{"id":"strict-legacy","context_length":"wrong-type"}]}"#.utf8))
        }
    }

    @Test("Native metadata refresh does not overwrite explicit capability or effort choices")
    func reasoningMetadataMergePreservesExplicitUserChoices() throws {
        let providerID = UUID()
        let local = ModelProfile(
            providerID: providerID, remoteModelID: "custom-model", displayName: "My model",
            limits: .init(contextTokens: 32_000, maxOutputTokens: 4_096),
            capabilities: [.text], reasoningEffort: .low, explicitCapabilities: [.tools],
            omitReasoningParameters: true
        )
        let metadata = ModelReasoningMetadata(
            supportsReasoning: true, supportsReasoningEffort: true,
            supportedEfforts: ["high", "max"], defaultEffort: "high"
        )
        var remote = try #require(ModelDiscovery.mapOpenAIItem(
            providerID: providerID, id: local.remoteModelID, displayName: "Provider name",
            contextTokens: 1_000_000, maxOutputTokens: nil, reasoningMetadata: metadata
        ))
        remote.reasoningEffort = .maximum
        remote.omitReasoningParameters = false
        let merged = try #require(ModelCatalogMerger.merge(existing: [local], discovered: [remote]).first)
        #expect(merged.id == local.id && merged.displayName == local.displayName)
        #expect(merged.limits == local.limits)
        #expect(merged.reasoningEffort == .low)
        #expect(merged.capabilities == local.capabilities)
        #expect(merged.explicitCapabilities == local.explicitCapabilities)
        #expect(merged.reasoningMetadata == metadata)
        #expect(merged.omitReasoningParameters == true)
        remote.reasoningMetadata = nil
        let refreshed = try #require(ModelCatalogMerger.merge(existing: [merged], discovered: [remote]).first)
        #expect(refreshed.reasoningMetadata == metadata)
        #expect(refreshed.reasoningEffort == .low)
        #expect(refreshed.effectiveOmitReasoningParameters)
    }

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
        #expect(model.limits.maxOutputTokens == 0)
        #expect(model.limits.configuredMaxOutputTokens == nil)
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
        #expect(negativeContext.limits.maxOutputTokens == 0)
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
        #expect(model.limits.maxOutputTokens == 0)

        // Capacity metadata never opts the user into a provider output limit.
        let bounded = try #require(ModelDiscovery.mapOpenAIItem(
            providerID: UUID(),
            id: "bounded",
            displayName: "Bounded",
            contextTokens: 4_096,
            maxOutputTokens: 65_536
        ))
        #expect(bounded.limits.contextTokens == 4_096)
        #expect(bounded.limits.maxOutputTokens == 0)
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
        #expect(withMetadata.limits.maxOutputTokens == 0)

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
        #expect(model.limits.maxOutputTokens == 0)
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
