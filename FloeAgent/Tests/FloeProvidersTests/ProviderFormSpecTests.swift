// FloeProvidersTests — Role-specific provider form contract.
//
// Offline and pure: the resolver is checked against the shipped adapter
// factories and the product-owned official media manifest only. No network,
// no credentials, no catalog document from disk (synthetic entries only).

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

@Suite("FloeProviders.ProviderFormSpec")
struct ProviderFormSpecModuleTests {

    private func preset(_ id: ProviderTemplateID) -> ProviderPreset {
        guard let found = ProviderPreset.all.first(where: { $0.id == id }) else {
            Issue.record("preset \(id.rawValue) must remain shipped")
            return .custom
        }
        return found
    }

    // MARK: - Supplier routes

    @Test("Image role offers exactly the five suppliers with a shipped image adapter")
    func eligibleImagePresets() {
        #expect(
            ProviderFormSpecResolver.eligiblePresets(for: .image).map(\.id)
                == [.openAI, .volcengineArk, .alibabaStudio, .googleGemini, .kimiCode]
        )
    }

    @Test("Video role offers only the three suppliers with a native video adapter")
    func eligibleVideoPresets() {
        #expect(
            ProviderFormSpecResolver.eligiblePresets(for: .video).map(\.id)
                == [.volcengineArk, .alibabaStudio, .googleGemini]
        )
    }

    @Test("Conversation keeps the shipped chat presets unchanged")
    func eligibleConversationPresets() {
        #expect(
            ProviderFormSpecResolver.eligiblePresets(for: .conversation)
                == ProviderPreset.chatPresets
        )
    }

    @Test("A legacy saved route stays selectable so editing is never stranded")
    func legacyRouteKeptSelectable() {
        // An existing provider saved before the role forms shipped could hold
        // an Anthropic image row. The form must still offer the current
        // preset (readable/editable) even though no new add would list it.
        let spec = ProviderFormSpecResolver.resolve(
            role: .image, preset: preset(.anthropic), baseURL: nil
        )
        #expect(spec.eligiblePresets.contains(preset(.anthropic)))
        #expect(!spec.roleAdapterAvailable)
        #expect(spec.mediaProbe == .unavailable)
        #expect(spec.unavailableReason?.contains("image adapter") == true)
        #expect(spec.seedModelIDs.isEmpty)
    }

    // MARK: - Field visibility

    @Test("Native media forms hide chat-only fields; chat forms keep them")
    func mediaFieldsHiddenForNativePresets() {
        for (role, id) in [
            (ProviderCatalogServiceRole.image, ProviderTemplateID.openAI),
            (.image, .volcengineArk),
            (.video, .alibabaStudio),
            (.video, .googleGemini)
        ] {
            let spec = ProviderFormSpecResolver.resolve(
                role: role, preset: preset(id), baseURL: nil
            )
            #expect(!spec.showsProtocolPicker, "\(id.rawValue) media hides the wire-protocol picker")
            #expect(!spec.showsToolNameCompatibility, "\(id.rawValue) media hides tool-name rewriting")
            #expect(!spec.showsHeadersField, "\(id.rawValue) media hides the custom-header editor")
            #expect(spec.roleAdapterAvailable)
            #expect(spec.requiredRegion == nil, "no shipped adapter consumes region today")
        }
        let chat = ProviderFormSpecResolver.resolve(
            role: .conversation, preset: preset(.volcengineArk), baseURL: nil
        )
        #expect(chat.showsProtocolPicker)
        #expect(chat.showsToolNameCompatibility)
        #expect(chat.showsHeadersField)
        #expect(chat.mediaProbe == .chatOnly)
    }

    @Test("Advanced custom chat endpoints keep every field they really use")
    func customChatKeepsAdvancedFields() {
        let spec = ProviderFormSpecResolver.resolve(
            role: .conversation, preset: preset(.custom), baseURL: nil
        )
        #expect(spec.showsProtocolPicker)
        #expect(spec.showsHeadersField)
        #expect(spec.showsModelListingRefresh)
        #expect(spec.eligiblePresets.contains(preset(.custom)))
    }

    // MARK: - Verified candidate tables

    @Test("Image seeds come from the official manifest in stable order")
    func imageSeeds() throws {
        #expect(
            ProviderFormSpecResolver.resolve(
                role: .image, preset: preset(.openAI), baseURL: nil
            ).seedModelIDs
                == ["gpt-image-2.5-flare", "gpt-image-2.5-sunburst", "gpt-image-2"]
        )
        #expect(
            ProviderFormSpecResolver.resolve(
                role: .image, preset: preset(.volcengineArk), baseURL: nil
            ).seedModelIDs
                == [
                    "doubao-seedream-5-0-pro-260628",
                    "doubao-seedream-5-0-lite-260128",
                    "doubao-seedream-4-0-250828"
                ]
        )
        #expect(
            ProviderFormSpecResolver.resolve(
                role: .image, preset: preset(.alibabaStudio), baseURL: nil
            ).seedModelIDs
                == ["qwen-image-3.0-pro", "wan2.7-image-pro"]
        )
        #expect(
            ProviderFormSpecResolver.resolve(
                role: .image, preset: preset(.googleGemini), baseURL: nil
            ).seedModelIDs
                == [
                    "gemini-2.5-flash-image",
                    "gemini-3.1-flash-lite-image",
                    "gemini-3.1-flash-image",
                    "gemini-3-pro-image"
                ]
        )
    }

    @Test("Video seeds come from the official manifest in stable order")
    func videoSeeds() {
        #expect(
            ProviderFormSpecResolver.resolve(
                role: .video, preset: preset(.volcengineArk), baseURL: nil
            ).seedModelIDs
                == ["doubao-seedance-2-5-260628", "doubao-seedance-2-0-260128"]
        )
        #expect(
            ProviderFormSpecResolver.resolve(
                role: .video, preset: preset(.alibabaStudio), baseURL: nil
            ).seedModelIDs
                == ["wan3.0-video"]
        )
        #expect(
            ProviderFormSpecResolver.resolve(
                role: .video, preset: preset(.googleGemini), baseURL: nil
            ).seedModelIDs
                == ["gemini-omni-flash-preview", "veo-3.1-generate-preview"]
        )
    }

    @Test("Kimi Code images trust the account listing and invent no identifiers")
    func kimiTrustsAccountListing() {
        let spec = ProviderFormSpecResolver.resolve(
            role: .image, preset: preset(.kimiCode), baseURL: nil
        )
        #expect(spec.roleAdapterAvailable)
        #expect(spec.trustsDiscoveryForMedia)
        #expect(spec.seedModelIDs.isEmpty)
        #expect(spec.mediaProbe == .contractWithCredentialListing)
    }

    @Test("A Kimi URL edited under the generic custom preset still resolves the real route")
    func customEndpointIdentityResolves() {
        // The VM resolves `effectiveFormPreset` through the same endpoint rule;
        // the module probe honors the URL directly.
        let kimiURL = ProviderPreset.kimiCode.defaultBaseURL
        let spec = ProviderFormSpecResolver.resolve(
            role: .image, preset: preset(.kimiCode), baseURL: kimiURL
        )
        #expect(spec.roleAdapterAvailable)
        let moonshot = ProviderFormSpecResolver.resolve(
            role: .image,
            preset: preset(.custom),
            baseURL: URL(string: "https://api.moonshot.cn/v1")
        )
        #expect(!moonshot.roleAdapterAvailable)
        #expect(moonshot.mediaProbe == .unavailable)
    }

    @Test("Generic custom endpoints are never a media route")
    func genericCustomIsNeverMedia() {
        for role in [ProviderCatalogServiceRole.image, .video] {
            let spec = ProviderFormSpecResolver.resolve(
                role: role, preset: preset(.custom), baseURL: nil
            )
            #expect(!spec.roleAdapterAvailable, "\(role.rawValue)")
            #expect(spec.mediaProbe == .unavailable, "\(role.rawValue)")
        }
    }

    // MARK: - Honest verification policy

    @Test("Only exact verified identifiers count for the media merge")
    func exactMatchPolicy() {
        let spec = ProviderFormSpecResolver.resolve(
            role: .image, preset: preset(.openAI), baseURL: nil
        )
        #expect(spec.isVerifiedMediaModel("gpt-image-2"))
        #expect(spec.isVerifiedMediaModel(" gpt-image-2 "))
        #expect(!spec.isVerifiedMediaModel("GPT-IMAGE-2"))
        #expect(!spec.isVerifiedMediaModel("gpt-4o"))
        #expect(!spec.isVerifiedMediaModel(""))
        // A manifest model of the OTHER family is not verified here.
        #expect(!spec.isVerifiedMediaModel("doubao-seedream-5-0-pro-260628"))
    }

    @Test("Declared catalog offers extend the verified table")
    func declaredOffersExtendSeeds() {
        let entry = ProviderCatalogEntry(
            presetID: "openai",
            name: "OpenAI",
            kind: .openAI,
            defaultProtocol: .openAIResponses,
            baseURL: URL(string: "https://api.openai.com/v1"),
            models: ["gpt-5"],
            availability: .available,
            upstreamID: "openai",
            authStyle: "bearer",
            serviceOffers: [
                ProviderCatalogServiceOffer(role: .image, models: ["account-image-priv-1"])
            ]
        )
        let spec = ProviderFormSpecResolver.resolve(
            role: .image,
            preset: preset(.openAI),
            baseURL: entry.baseURL,
            catalogEntry: entry
        )
        #expect(spec.seedModelIDs == [
            "gpt-image-2.5-flare", "gpt-image-2.5-sunburst", "gpt-image-2",
            "account-image-priv-1"
        ])
        #expect(spec.isVerifiedMediaModel("account-image-priv-1"))
    }

    // MARK: - Connection probes

    @Test("Media probes are honest about live coverage and never paid")
    func probePlans() {
        #expect(
            ProviderFormSpecResolver.resolve(
                role: .image, preset: preset(.openAI), baseURL: nil
            ).mediaProbe == .contractWithCredentialListing
        )
        #expect(
            ProviderFormSpecResolver.resolve(
                role: .video, preset: preset(.volcengineArk), baseURL: nil
            ).mediaProbe == .contractWithCredentialListing
        )
        // Google's native media surface exposes no free listing in this app:
        // the editor must report contract verification, not "Connected".
        #expect(
            ProviderFormSpecResolver.resolve(
                role: .image, preset: preset(.googleGemini), baseURL: nil
            ).mediaProbe == .contractOnly
        )
        #expect(
            ProviderFormSpecResolver.resolve(
                role: .video, preset: preset(.googleGemini), baseURL: nil
            ).mediaProbe == .contractOnly
        )
    }

    @Test("Image operations come from the concrete adapter contract")
    func imageOperations() {
        let volc = ProviderFormSpecResolver.resolve(
            role: .image, preset: preset(.volcengineArk), baseURL: nil
        )
        #expect(!volc.imageOperations.isEmpty)
        #expect(volc.imageOperations.first == .generate)
        let chat = ProviderFormSpecResolver.resolve(
            role: .conversation, preset: preset(.openAI), baseURL: nil
        )
        #expect(chat.imageOperations.isEmpty)
    }

    // MARK: - Catalog entry eligibility

    private func syntheticEntry(
        presetID: String,
        kind: ProviderKind,
        baseURL: String?,
        declared: [ProviderCatalogServiceOffer]? = nil,
        availability: ProviderCatalogAvailability = .available
    ) -> ProviderCatalogEntry {
        ProviderCatalogEntry(
            presetID: presetID,
            name: presetID,
            kind: kind,
            defaultProtocol: .openAIChatCompletions,
            baseURL: baseURL.flatMap(URL.init(string:)),
            models: ["chat-model"],
            availability: availability,
            upstreamID: presetID,
            authStyle: "bearer",
            serviceOffers: declared
        )
    }

    @Test("Supplier eligibility follows shipped adapters, not names")
    func entryEligibility() {
        let openai = syntheticEntry(presetID: "openai", kind: .openAI, baseURL: "https://api.openai.com/v1")
        #expect(ProviderFormSpecResolver.isCatalogEntry(openai, eligibleFor: .image))
        #expect(!ProviderFormSpecResolver.isCatalogEntry(openai, eligibleFor: .video))

        let volc = syntheticEntry(
            presetID: "volcengine-ark", kind: .volcengineArk,
            baseURL: "https://ark.cn-beijing.volces.com/api/v3"
        )
        #expect(ProviderFormSpecResolver.isCatalogEntry(volc, eligibleFor: .image))
        #expect(ProviderFormSpecResolver.isCatalogEntry(volc, eligibleFor: .video))

        let anthropic = syntheticEntry(
            presetID: "anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com"
        )
        #expect(!ProviderFormSpecResolver.isCatalogEntry(anthropic, eligibleFor: .image))
        #expect(!ProviderFormSpecResolver.isCatalogEntry(anthropic, eligibleFor: .video))

        // A chat-only gateway (DeepSeek-like custom kind) is never a media
        // route, even with a chat-carrying name.
        let gateway = syntheticEntry(presetID: "deepseek", kind: .custom, baseURL: "https://api.deepseek.com/v1")
        #expect(ProviderFormSpecResolver.isCatalogEntry(gateway, eligibleFor: .conversation))
        #expect(!ProviderFormSpecResolver.isCatalogEntry(gateway, eligibleFor: .image))
        #expect(!ProviderFormSpecResolver.isCatalogEntry(gateway, eligibleFor: .video))

        // Kimi Code: image through the account listing (requiresDiscovery),
        // never video.
        let kimi = syntheticEntry(
            presetID: "kimi-code", kind: .custom, baseURL: "https://api.kimi.com/coding/v1"
        )
        #expect(ProviderFormSpecResolver.isCatalogEntry(kimi, eligibleFor: .image))
        #expect(!ProviderFormSpecResolver.isCatalogEntry(kimi, eligibleFor: .video))

        // A declared image offer on a route with no shipped adapter stays
        // ineligible (real adapter beats a directory claim).
        let claimed = syntheticEntry(
            presetID: "claims-image", kind: .custom, baseURL: "https://images.example.com/v1",
            declared: [ProviderCatalogServiceOffer(role: .image, models: ["x-1"])]
        )
        #expect(!ProviderFormSpecResolver.isCatalogEntry(claimed, eligibleFor: .image))

        // Unsupported entries never become media routes; hidden presets are
        // ineligible for every role.
        let unsupported = syntheticEntry(
            presetID: "bedrock", kind: .openAI,
            baseURL: "https://bedrock-runtime.amazonaws.com",
            availability: .unsupported
        )
        #expect(!ProviderFormSpecResolver.isCatalogEntry(unsupported, eligibleFor: .image))
        #expect(!ProviderFormSpecResolver.isCatalogEntry(unsupported, eligibleFor: .video))
        let hidden = syntheticEntry(
            presetID: "github-copilot", kind: .openAI, baseURL: "https://api.openai.com/v1"
        )
        #expect(!ProviderFormSpecResolver.isCatalogEntry(hidden, eligibleFor: .conversation))
        #expect(!ProviderFormSpecResolver.isCatalogEntry(hidden, eligibleFor: .image))
    }
}
