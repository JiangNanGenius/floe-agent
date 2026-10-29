// FloeProvidersTests — Checked-in Volcengine Agent Plan catalog contract.
//
// Offline: reads only the bundled resource and exercises the pure catalog /
// role / capability resolvers. No network, no credentials, no paid call.
//
// The expected rows follow the official plan table updated 2026-10-29:
// https://ark.volcengine.com/region:cn-beijing/docs/agent-plan-personal-plan-overview
// Image ids follow the Agent Plan visual-model page:
// https://ark.volcengine.com/region:cn-beijing/docs/agent-plan-personal-visual-models

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

@Suite("FloeProviders.AgentPlanCatalog")
struct AgentPlanCatalogTests {

    private func bundledCatalog() throws -> ProviderCatalogIndex {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent("FloeApp/Resources/ProviderCatalog.json")
        let catalogURL = try #require(
            [Bundle.main.url(forResource: "ProviderCatalog", withExtension: "json"), sourceURL]
                .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) },
            "The actual app/source provider catalog must be present for this qualification")
        return try ProviderCatalogIndex.validated(from: Data(contentsOf: catalogURL))
    }

    private func agentPlan(in index: ProviderCatalogIndex) throws -> ProviderCatalogEntry {
        try #require(index.entry(presetID: "volcengine-agent-plan"))
    }

    @Test("Agent Plan seeds only current non-retired chat models plus the selector")
    func currentChatRows() throws {
        let entry = try agentPlan(in: try bundledCatalog())
        #expect(entry.models == [
            "ark-code-latest",
            "deepseek-v4-flash",
            "deepseek-v4-pro",
            "deepseek-v4.1-flash",
            "deepseek-v4.1-flash-economy",
            "doubao-seed-2.0-mini",
            "doubao-seed-2.1-lite",
            "doubao-seed-2.1-pro",
            "doubao-seed-evolving",
            "glm-5.3",
            "glm-5.3-flash",
            "kimi-k2.8-preview",
            "kimi-k3",
            "kimi-k3.1-pro",
        ])
        #expect(entry.models == entry.models.sorted())
        // The table marks these retiring; existing saved rows survive a
        // catalog update, but a new editor must not seed them.
        #expect(!entry.models.contains("minimax-m3"))
        #expect(!entry.models.contains("kimi-k2.7-code"))
    }

    @Test("Official context/output limits and only verified image inputs become capabilities")
    func documentedMetadataAndCapabilities() throws {
        let entry = try agentPlan(in: try bundledCatalog())
        let metadata = try #require(entry.modelMetadata)

        let limits: [String: (context: Int, output: Int)] = [
            "doubao-seed-2.0-mini": (262_144, 131_072),
            "doubao-seed-2.1-lite": (1_048_576, 262_144),
            "deepseek-v4-flash": (1_048_576, 393_216),
            "glm-5.3-flash": (1_048_576, 131_072),
            "doubao-seed-2.1-pro": (1_048_576, 262_144),
            "doubao-seed-evolving": (1_048_576, 262_144),
            "glm-5.3": (1_048_576, 131_072),
            "kimi-k2.8-preview": (1_048_576, 1_048_576),
            "deepseek-v4-pro": (1_048_576, 393_216),
            "kimi-k3": (1_048_576, 131_072),
            "kimi-k3.1-pro": (1_048_576, 1_048_576),
            "deepseek-v4.1-flash": (1_048_576, 393_216),
            "deepseek-v4.1-flash-economy": (1_048_576, 393_216),
        ]
        // The selector is documented as a selector, not a fixed model row:
        // the official table publishes no independent limits for it.
        #expect(metadata["ark-code-latest"]?.contextTokens == nil)
        #expect(metadata["ark-code-latest"]?.maxOutputTokens == nil)
        #expect(ProviderCatalogCapabilityResolver.supportsImageInput(metadata["ark-code-latest"]) == true)

        // Verified image input from the plan table / official model pages.
        // No vision is inferred from a model name alone.
        let imageInput: Set<String> = [
            "ark-code-latest",
            "doubao-seed-2.0-mini",
            "doubao-seed-2.1-lite",
            "doubao-seed-2.1-pro",
            "doubao-seed-evolving",
            "glm-5.3-flash",
            "deepseek-v4.1-flash",
            "deepseek-v4.1-flash-economy",
        ]

        for (remoteID, expected) in limits {
            let facts = try #require(metadata[remoteID], "missing metadata for \(remoteID)")
            #expect(facts.contextTokens == expected.context, "\(remoteID) context")
            #expect(facts.maxOutputTokens == expected.output, "\(remoteID) output")
            #expect(
                ProviderCatalogCapabilityResolver.supportsImageInput(facts) == imageInput.contains(remoteID),
                "\(remoteID) vision must follow official evidence"
            )
        }

        let base = ModelCapabilities.defaultTextModel(for: .openAIChatCompletions)
        #expect(
            ProviderCatalogCapabilityResolver.capabilities(
                for: metadata["glm-5.3-flash"], base: base
            ).contains(.vision)
        )
        #expect(
            !ProviderCatalogCapabilityResolver.capabilities(
                for: metadata["deepseek-v4-flash"], base: base
            ).contains(.vision)
        )

        // Only the two table rows that cannot disable thinking are recorded
        // with the always-reasoning flag. Toggleable models stay unknown.
        #expect(metadata["glm-5.3"]?.reasoning == true)
        #expect(metadata["kimi-k3"]?.reasoning == true)
        #expect(metadata["glm-5.3-flash"]?.reasoning == nil)
        #expect(metadata["kimi-k3.1-pro"]?.reasoning == nil)

        // Metadata remains descriptive of declared ids only.
        let declared = Set(entry.models)
            .union(entry.serviceOffers?.flatMap(\.models) ?? [])
        #expect(Set(metadata.keys).isSubset(of: declared))
    }

    @Test("Image offer is the plan-only Seedream set and never leaks into chat")
    func imageRoleBoundary() throws {
        let entry = try agentPlan(in: try bundledCatalog())
        let offer = try #require(entry.serviceOffers?.first { $0.role == .image })
        #expect(offer.models == [
            "doubao-seedream-5-0-pro",
            "doubao-seedream-5.0-flash",
            "doubao-seedream-5.0-lite",
        ])
        // The official table also lists Seedance video; this round explicitly
        // keeps Agent Plan video closed and preserves the PAYG route.
        #expect(entry.serviceOffers?.contains { $0.role == .video } != true)
        #expect(Set(entry.models).isDisjoint(with: offer.models))

        let preset = ProviderPreset.volcengineAgentPlan
        let imageSpec = ProviderFormSpecResolver.resolve(
            role: .image,
            preset: preset,
            baseURL: preset.defaultBaseURL,
            catalogEntry: entry
        )
        #expect(imageSpec.seedModelIDs == offer.models)
        #expect(imageSpec.roleAdapterAvailable)
        #expect(imageSpec.mediaProbe == .contractOnly)
        #expect(!imageSpec.showsModelListingRefresh)
        #expect(imageSpec.imageOperations.contains(.generate))
        #expect(imageSpec.imageOperations.contains(.edit))
        #expect(!imageSpec.imageOperations.contains(.upscale))
        #expect(imageSpec.isVerifiedMediaModel("doubao-seedream-5.0-flash"))
        #expect(!imageSpec.isVerifiedMediaModel("glm-5.3"))
        #expect(!imageSpec.isVerifiedMediaModel("doubao-seedance-2.0"))

        let conversationSpec = ProviderFormSpecResolver.resolve(
            role: .conversation,
            preset: preset,
            baseURL: preset.defaultBaseURL,
            catalogEntry: entry
        )
        #expect(conversationSpec.seedModelIDs.isEmpty)
        #expect(conversationSpec.mediaProbe == .chatOnly)
        #expect(!conversationSpec.showsModelListingRefresh)

        let metadata = try #require(entry.modelMetadata)
        for remoteID in offer.models {
            let facts = try #require(metadata[remoteID])
            #expect(facts.input?.contains("image") == true)
            #expect(facts.output == ["image"])
        }
    }
}
