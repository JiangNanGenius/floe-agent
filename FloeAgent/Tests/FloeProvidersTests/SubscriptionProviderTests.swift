import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

private func subscriptionEntry(
    presetID: String,
    baseURL: URL,
    models: [String],
    offers: [ProviderCatalogServiceOffer]? = nil,
    metadata: [String: ProviderCatalogModelMetadata]? = nil
) -> ProviderCatalogEntry {
    ProviderCatalogEntry(
        presetID: presetID,
        name: presetID,
        kind: .custom,
        defaultProtocol: .openAIChatCompletions,
        baseURL: baseURL,
        domains: [baseURL.host ?? ""],
        models: models,
        availability: .available,
        upstreamID: presetID,
        authStyle: "bearer",
        serviceOffers: offers,
        modelMetadata: metadata
    )
}

@Suite("Subscription provider isolation")
struct SubscriptionProviderTests {
    @Test("Subscription presets survive reopening without inheriting PAYG media lists")
    func independentPresets() {
        for preset in [ProviderPreset.volcengineAgentPlan, .alibabaTokenPlan] {
            #expect(ProviderPreset.preset(for: preset.kind, baseURL: preset.defaultBaseURL).id == preset.id)
            #expect(ProviderPreset.chatPresets.contains(preset))
            let spec = ProviderFormSpecResolver.resolve(role: .conversation, preset: preset, baseURL: preset.defaultBaseURL)
            #expect(spec.templateID == preset.id)
            // Neither subscription gateway documents /models discovery.
            #expect(!preset.supportsModelDiscovery)
            #expect(!spec.showsModelListingRefresh)
        }
        #expect(ProviderFormSpecResolver.eligiblePresets(for: .image).contains(.alibabaTokenPlan))
        #expect(ProviderFormSpecResolver.eligiblePresets(for: .image).contains(.volcengineAgentPlan))
        #expect(ProviderFormSpecResolver.eligiblePresets(for: .video).contains(.alibabaTokenPlan))
        #expect(!ProviderFormSpecResolver.eligiblePresets(for: .video).contains(.volcengineAgentPlan))
    }

    @Test("Agent Plan image candidates come from its own declared offer only")
    func agentPlanImageSeedsAreNotPayg() {
        let entry = subscriptionEntry(
            presetID: "volcengine-agent-plan",
            baseURL: ProviderPreset.volcengineAgentPlan.defaultBaseURL,
            models: ["ark-code-latest"],
            offers: [ProviderCatalogServiceOffer(role: .image, models: ["doubao-seedream-5.0-lite"])],
            metadata: ["doubao-seedream-5.0-lite": .init(input: ["text", "image"], output: ["image"])]
        )
        let spec = ProviderFormSpecResolver.resolve(
            role: .image,
            preset: .volcengineAgentPlan,
            baseURL: ProviderPreset.volcengineAgentPlan.defaultBaseURL,
            catalogEntry: entry
        )
        #expect(spec.seedModelIDs == ["doubao-seedream-5.0-lite"])
        #expect(spec.mediaProbe == .contractOnly)
        #expect(!spec.showsModelListingRefresh)
        // An older catalog entry without an offer must not fall back to the
        // same-origin PAYG manifest.
        let emptyEntry = subscriptionEntry(
            presetID: "volcengine-agent-plan",
            baseURL: ProviderPreset.volcengineAgentPlan.defaultBaseURL,
            models: ["ark-code-latest"]
        )
        #expect(ProviderFormSpecResolver.resolve(
            role: .image,
            preset: .volcengineAgentPlan,
            baseURL: ProviderPreset.volcengineAgentPlan.defaultBaseURL,
            catalogEntry: emptyEntry
        ).seedModelIDs.isEmpty)
    }

    @Test("Token Plan image/video candidates use only its declared offers")
    func tokenPlanMediaSeeds() {
        let imageEntry = subscriptionEntry(
            presetID: "alibaba-token-plan",
            baseURL: ProviderPreset.alibabaTokenPlan.defaultBaseURL,
            models: ["qwen3.8-flash"],
            offers: [
                ProviderCatalogServiceOffer(role: .image, models: ["qwen-image-3.0-pro", "wan2.7-image"]),
                ProviderCatalogServiceOffer(role: .video, models: ["wan3.0-video", "happyhorse-1.1-t2v"])
            ]
        )
        let image = ProviderFormSpecResolver.resolve(
            role: .image,
            preset: .alibabaTokenPlan,
            baseURL: ProviderPreset.alibabaTokenPlan.defaultBaseURL,
            catalogEntry: imageEntry
        )
        #expect(image.seedModelIDs == ["qwen-image-3.0-pro", "wan2.7-image"])
        #expect(image.mediaProbe == .contractOnly)
        #expect(!image.showsModelListingRefresh)
        let video = ProviderFormSpecResolver.resolve(
            role: .video,
            preset: .alibabaTokenPlan,
            baseURL: ProviderPreset.alibabaTokenPlan.defaultBaseURL,
            catalogEntry: imageEntry
        )
        #expect(video.seedModelIDs == ["wan3.0-video", "happyhorse-1.1-t2v"])
        #expect(video.mediaProbe == .contractOnly)
    }

    @Test("Same-origin PAYG and Agent Plan cannot reuse a saved key")
    func billingCredentialBoundary() {
        let compatible = ProviderConfigurationValidation.ProviderConnectionIdentity.isCompatible
        #expect(!compatible(.volcengineArk, ProviderPreset.volcengineArk.defaultBaseURL,
                            .custom, ProviderPreset.volcengineAgentPlan.defaultBaseURL))
        // Legacy manually entered Plan profiles keep their key on reopening.
        #expect(compatible(.volcengineArk, ProviderPreset.volcengineAgentPlan.defaultBaseURL,
                           .custom, ProviderPreset.volcengineAgentPlan.defaultBaseURL))
        #expect(!compatible(.alibabaStudio, ProviderPreset.alibabaStudio.defaultBaseURL,
                            .custom, ProviderPreset.alibabaTokenPlan.defaultBaseURL))
    }

    @Test("Lookalike hosts, nonstandard ports and Coding Plan are not Agent Plan")
    func exactEndpointIdentity() {
        for address in [
            "https://ark.cn-beijing.volces.com.attacker.example/api/plan/v3",
            "https://ark.cn-beijing.volces.com:8443/api/plan/v3",
            "http://ark.cn-beijing.volces.com/api/plan/v3",
            "https://ark.cn-beijing.volces.com/api/coding/v3",
            "https://coding.dashscope.aliyuncs.com/v1"
        ] {
            #expect(ProviderBillingEndpoint.resolve(URL(string: address)!) == nil)
        }
    }
}
