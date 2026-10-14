// FloeProvidersTests — Optional multi-service metadata and real-adapter
// filtering. Offline: synthetic catalog documents only, no network and no
// credentials.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

@Suite("FloeProviders.ProviderServiceOffers")
struct ProviderServiceOfferTests {

    @Test("Media roles come from shipped adapters, never model-name guesses")
    func adapterMediaRolesAreReal() {
        #expect(
            ProviderServiceOfferResolver.adapterSupportedMediaRoles(for: .openAI) == [.image]
        )
        for kind in [ProviderKind.volcengineArk, .alibabaStudio, .googleGemini] {
            #expect(
                ProviderServiceOfferResolver.adapterSupportedMediaRoles(for: kind)
                    == [.image, .video],
                "\(kind.rawValue) ships both media adapters"
            )
        }
        for kind in [ProviderKind.anthropic, .custom, .local] {
            #expect(ProviderServiceOfferResolver.adapterSupportedMediaRoles(for: kind).isEmpty)
        }
    }

    @Test("OpenAI kind offers image from the official manifest and conversation via discovery")
    func openAIKindOffersImageAndConversationDiscovery() throws {
        let offers = ProviderServiceOfferResolver.resolvedOffers(
            for: .openAI,
            baseURL: URL(string: "https://api.openai.com/v1"),
            authStyle: "bearer",
            availability: .available,
            declared: nil
        )
        let image = try #require(offers.first { $0.role == .image })
        #expect(image.isUsable)
        #expect(image.connection == .shared)
        #expect(!image.requiresDiscovery)
        #expect(image.models == ProviderServiceOfferResolver.officialModelIDs(for: .openAI, role: .image))
        #expect(!image.models.isEmpty)
        #expect(offers.first { $0.role == .video } == nil)

        let conversation = try #require(offers.first { $0.role == .conversation })
        #expect(conversation.isUsable)
        #expect(conversation.requiresDiscovery)
        #expect(conversation.models.isEmpty)
    }

    @Test("Custom kind offers only conversation, and only through real discovery")
    func customKindOffersConversationDiscovery() throws {
        let offers = ProviderServiceOfferResolver.resolvedOffers(
            for: .custom,
            baseURL: URL(string: "https://api.deepseek.com"),
            authStyle: "bearer",
            availability: .available,
            declared: nil
        )
        #expect(offers.count == 1)
        let conversation = try #require(offers.first)
        #expect(conversation.role == .conversation)
        #expect(conversation.isUsable)
        #expect(conversation.requiresDiscovery)
    }

    @Test("Gemini conversation is offered only when the catalog declares a compatible route")
    func geminiConversationRequiresDeclaredRoute() {
        let withoutDeclaration = ProviderServiceOfferResolver.resolvedOffers(
            for: .googleGemini,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1"),
            authStyle: "apiKeyHeader",
            availability: .available,
            declared: nil
        )
        #expect(withoutDeclaration.contains { $0.role == .conversation } == false)

        let declared = ProviderCatalogServiceOffer(
            role: .conversation,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai"),
            authStyle: "apiKeyHeader",
            protocols: [.openAIChatCompletions],
            models: ["gemini-2.5-pro"]
        )
        let withDeclaration = ProviderServiceOfferResolver.resolvedOffers(
            for: .googleGemini,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1"),
            authStyle: "apiKeyHeader",
            availability: .available,
            declared: [declared]
        )
        let conversation = withDeclaration.first { $0.role == .conversation }
        #expect(conversation?.isUsable == true)
        #expect(conversation?.requiresDiscovery == false)
        #expect(conversation?.models == ["gemini-2.5-pro"])
        // Same origin, different path: the connection stays shared.
        #expect(conversation?.connection == .shared)
    }

    @Test("A different endpoint host becomes visibly distinct, never shared")
    func differentHostIsDistinct() throws {
        let declared = ProviderCatalogServiceOffer(
            role: .image,
            baseURL: URL(string: "https://images.example.com/v1"),
            authStyle: "bearer",
            models: ["custom-image-1"]
        )
        let offers = ProviderServiceOfferResolver.resolvedOffers(
            for: .openAI,
            baseURL: URL(string: "https://api.openai.com/v1"),
            authStyle: "bearer",
            availability: .available,
            declared: [declared]
        )
        let image = try #require(offers.first { $0.role == .image })
        #expect(image.isUsable)
        #expect(image.connection == .distinct)
        #expect(image.reason != nil)
        #expect(image.models == ["custom-image-1"])
    }

    @Test("Different auth style becomes distinct; same origin alias stays shared")
    func authDifferenceIsDistinct() throws {
        let declared = ProviderCatalogServiceOffer(
            role: .image,
            authStyle: "apiKeyHeader",
            models: ["image-x"]
        )
        let offers = ProviderServiceOfferResolver.resolvedOffers(
            for: .openAI,
            baseURL: URL(string: "https://api.openai.com/v1"),
            authStyle: "bearer",
            availability: .available,
            declared: [declared]
        )
        let image = try #require(offers.first { $0.role == .image })
        #expect(image.connection == .distinct)
        #expect(image.reason?.contains("authentication") == true)

        // Same origin, different path and no auth change: shared.
        let alias = ProviderCatalogServiceOffer(
            role: .image,
            baseURL: URL(string: "https://api.openai.com/v1/images"),
            models: ["gpt-image-2"]
        )
        let sharedOffers = ProviderServiceOfferResolver.resolvedOffers(
            for: .openAI,
            baseURL: URL(string: "https://api.openai.com/v1"),
            authStyle: "bearer",
            availability: .available,
            declared: [alias]
        )
        #expect(sharedOffers.first { $0.role == .image }?.connection == .shared)
    }

    @Test("A declared role without a shipped adapter stays explicitly unusable")
    func declaredRoleWithoutAdapterIsUnusable() throws {
        let declared = ProviderCatalogServiceOffer(
            role: .video,
            models: ["some-video-model"]
        )
        let offers = ProviderServiceOfferResolver.resolvedOffers(
            for: .openAI,
            baseURL: URL(string: "https://api.openai.com/v1"),
            authStyle: "bearer",
            availability: .available,
            declared: [declared]
        )
        let video = try #require(offers.first { $0.role == .video })
        #expect(!video.isUsable)
        #expect(video.reason?.contains("no shipped adapter") == true)
    }

    @Test("Unsupported catalog entries never produce offers")
    func unsupportedEntriesProduceNoOffers() {
        let offers = ProviderServiceOfferResolver.resolvedOffers(
            for: .openAI,
            baseURL: nil,
            authStyle: "bearer",
            availability: .unsupported,
            declared: [ProviderCatalogServiceOffer(role: .image, models: ["x"])]
        )
        #expect(offers.isEmpty)
    }

    // MARK: - Catalog validation gate

    private func entry(
        serviceOffers: [ProviderCatalogServiceOffer]?
    ) -> ProviderCatalogEntry {
        ProviderCatalogEntry(
            presetID: "openai",
            name: "OpenAI",
            aliases: [],
            kind: .openAI,
            defaultProtocol: .openAIResponses,
            baseURL: URL(string: "https://api.openai.com/v1"),
            domains: ["api.openai.com"],
            models: ["gpt-5"],
            availability: .available,
            unsupportedReason: nil,
            upstreamID: "openai",
            authStyle: "bearer",
            toolNameCompatibility: false,
            serviceOffers: serviceOffers
        )
    }

    private func document(_ entry: ProviderCatalogEntry) -> ProviderCatalogDocument {
        ProviderCatalogDocument(
            schemaVersion: 1,
            source: .init(
                project: "models.dev",
                url: "https://models.dev",
                license: "MIT",
                documentSHA256: String(repeating: "a", count: 64),
                fetchedAt: "2026-10-09T00:00:00Z"
            ),
            providers: [entry]
        )
    }

    private func expectRejection(
        _ offers: [ProviderCatalogServiceOffer],
        containing token: String
    ) throws {
        let data = try JSONEncoder().encode(document(entry(serviceOffers: offers)))
        do {
            _ = try ProviderCatalogIndex.validated(from: data)
            Issue.record("expected rejection containing '\(token)'")
        } catch let error as ProviderCatalogValidationError {
            #expect(error.message.contains(token), "\(error.message)")
        }
    }

    @Test("Valid service offers round-trip through the activation gate")
    func validOffersRoundTrip() throws {
        let offers = [
            ProviderCatalogServiceOffer(role: .image, models: ["gpt-image-2"]),
            ProviderCatalogServiceOffer(
                role: .video,
                baseURL: URL(string: "https://api.openai.com/v1/video"),
                protocols: [.openAIChatCompletions],
                models: ["video-1"],
                note: "region us-east"
            )
        ]
        let data = try JSONEncoder().encode(document(entry(serviceOffers: offers)))
        let index = try ProviderCatalogIndex.validated(from: data)
        #expect(index.all.first?.serviceOffers == offers)
    }

    @Test("Documents written before optional offers existed still decode as nil")
    func legacyDocumentDecodesNilOffers() throws {
        let data = try JSONEncoder().encode(document(entry(serviceOffers: nil)))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var providers = try #require(object["providers"] as? [[String: Any]])
        providers[0].removeValue(forKey: "serviceOffers")
        object["providers"] = providers
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let index = try ProviderCatalogIndex.validated(from: legacy)
        #expect(index.all.first?.serviceOffers == nil)
    }

    @Test("Malformed service offers are rejected at the activation gate")
    func malformedOffersRejected() throws {
        let base = ProviderCatalogServiceOffer(role: .image, models: ["gpt-image-2"])
        try expectRejection(
            [base, base],
            containing: "duplicate service offer role"
        )
        try expectRejection(
            [ProviderCatalogServiceOffer(role: .image, models: (0...100).map { "m-\($0)" })],
            containing: "more than 100 models"
        )
        try expectRejection(
            [ProviderCatalogServiceOffer(role: .image, models: ["bad model"])],
            containing: "invalid"
        )
        try expectRejection(
            [ProviderCatalogServiceOffer(role: .image, authStyle: "oauth", models: ["m"])],
            containing: "unknown service offer authStyle"
        )
        try expectRejection(
            [ProviderCatalogServiceOffer(
                role: .image,
                baseURL: URL(string: "http://api.openai.com/v1"),
                models: ["m"]
            )],
            containing: "must be https"
        )
        try expectRejection(
            [ProviderCatalogServiceOffer(role: .image, protocols: [], models: ["m"])],
            containing: "1...3"
        )
        try expectRejection(
            [ProviderCatalogServiceOffer(
                role: .image,
                models: ["m"],
                note: String(repeating: "n", count: 257)
            )],
            containing: "note must be 1...256"
        )
        let five: [ProviderCatalogServiceOffer] = [
            .init(role: .image, models: ["a"]),
            .init(role: .video, models: ["b"]),
            .init(role: .conversation, models: ["c"])
        ]
        try expectRejection(
            five + [.init(role: .conversation, models: ["d"])],
            containing: "duplicate service offer role"
        )
    }
}
