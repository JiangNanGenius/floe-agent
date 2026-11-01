// FloeProvidersTests — Volcengine Agent Plan image contract.
//
// Offline: bundled catalog + compiled parameter contracts only. No network,
// credentials or paid generation.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

@Suite("FloeProviders.AgentPlanImageContract")
struct AgentPlanImageContractTests {
    private func planProvider(
        id: UUID = UUID(),
        baseURL: String = "https://ark.cn-beijing.volces.com/api/plan/v3"
    ) -> ProviderProfile {
        ProviderProfile(
            id: id,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: baseURL)!
        )
    }

    private func model(_ remoteID: String, providerID: UUID) -> ModelProfile {
        ModelProfile(
            providerID: providerID,
            remoteModelID: remoteID,
            displayName: remoteID,
            limits: .init(contextTokens: 0, maxOutputTokens: 0),
            capabilities: [.imageGeneration, .imageEditing]
        )
    }

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

    @Test("Agent Plan image candidates are only the plan-supported pro/flash ids")
    func catalogCandidateBoundary() throws {
        let index = try bundledCatalog()
        let entry = try #require(index.entry(presetID: "volcengine-agent-plan"))
        let offer = try #require(entry.serviceOffers?.first { $0.role == .image })
        #expect(offer.models == [
            "doubao-seedream-5-0-pro",
            "doubao-seedream-5.0-flash",
        ])
        #expect(entry.modelMetadata?["doubao-seedream-5.0-lite"] == nil)
        #expect(!entry.models.contains("doubao-seedream-5.0-lite"))
        #expect(Set(entry.models).isDisjoint(with: offer.models))

        let preset = ProviderPreset.volcengineAgentPlan
        let spec = ProviderFormSpecResolver.resolve(
            role: .image,
            preset: preset,
            baseURL: preset.defaultBaseURL,
            catalogEntry: entry
        )
        #expect(spec.seedModelIDs == offer.models)
        #expect(spec.isVerifiedMediaModel("doubao-seedream-5-0-pro"))
        #expect(spec.isVerifiedMediaModel("doubao-seedream-5.0-flash"))
        #expect(!spec.isVerifiedMediaModel("doubao-seedream-5.0-lite"))
        #expect(!spec.isVerifiedMediaModel("doubao-seedream-5-0-pro-260628"))
    }

    @Test("Plan pro/flash declare one native image and a bounded four-candidate fanout")
    func planParameterContract() throws {
        let provider = planProvider()
        for remoteID in ["doubao-seedream-5-0-pro", "doubao-seedream-5.0-flash"] {
            let model = model(remoteID, providerID: provider.id)
            let contract = ImageGenerationPresetResolver.parameterContract(
                provider: provider, model: model, operation: .generate)
            #expect(contract.verifiedModel)
            #expect(contract.verificationBasis == .officialAgentPlanVisualModels)
            #expect(contract.accountUsability == "notChecked")
            #expect(contract.resolution == ["1K", "1.5K", "2K"])
            #expect(contract.defaultAspectRatio == nil)
            #expect(contract.maximumCount == 4)
            #expect(contract.maximumCountPerRequest == 1)
            #expect(contract.countStrategy == .sequentialSingleImageRequests)

            let effective = ImageGenerationPresetResolver.applyingDefaults(
                .init(), provider: provider, model: model, operation: .generate)
            #expect(effective.aspectRatio == nil)
            #expect(effective.resolution == "2K")
            #expect(try ImageGenerationPresetResolver.nativeSize(
                provider: .volcengineArk, modelRemoteID: remoteID,
                operation: .generate, selection: effective
            ) == "2K")
            #expect(try ImageGenerationPresetResolver.nativeSize(
                provider: .volcengineArk, modelRemoteID: remoteID,
                operation: .generate,
                selection: .init(aspectRatio: "16:9", resolution: "1K")
            ) == "1424x800")
            try ImageGenerationPresetResolver.validateSelection(
                .init(nativeSizeOverride: "1024x1024"),
                provider: provider, model: model, operation: .generate,
                count: 1, referenceCount: 0
            )
            #expect(throws: RemoteImageError.self) {
                try ImageGenerationPresetResolver.validateSelection(
                    .init(nativeSizeOverride: "512x512"),
                    provider: provider, model: model, operation: .generate,
                    count: 1, referenceCount: 0
                )
            }
        }
    }

    @Test("Lite is rejected as an Agent Plan model, not silently mapped to flash")
    func liteIsNotAPlanModel() throws {
        let provider = planProvider()
        let lite = model("doubao-seedream-5.0-lite", providerID: provider.id)
        #expect(Seedream5ImageFamily.resolve(lite.remoteModelID) == .lite)
        #expect(Seedream5ImageFamily.resolve(lite.remoteModelID)?.isAvailableOnAgentPlan == false)
        let contract = ImageGenerationPresetResolver.parameterContract(
            provider: provider, model: lite, operation: .generate)
        #expect(!contract.verifiedModel)
        #expect(contract.countStrategy == .unsupported)
        #expect(contract.maximumCount == 0)
        #expect(!ImageGenerationPresetResolver.isEligible(
            provider: provider, model: lite, operation: .generate))
        #expect(throws: RemoteImageError.self) {
            try ImageGenerationPresetResolver.validateSelection(
                .init(aspectRatio: "1:1", resolution: "2K"),
                provider: provider, model: lite, operation: .generate,
                count: 1, referenceCount: 0
            )
        }
    }

    @Test("User-configured plan image models do not require catalog or account verification")
    func unlistedPlanModelRemainsCallable() throws {
        let provider = planProvider()
        let custom = model("user-configured-future-image-model", providerID: provider.id)
        let contract = ImageGenerationPresetResolver.parameterContract(
            provider: provider, model: custom, operation: .generate)
        #expect(!contract.verifiedModel)
        #expect(contract.verificationBasis == .unreviewed)
        #expect(contract.accountUsability == "notChecked")
        #expect(ImageGenerationPresetResolver.isEligible(
            provider: provider, model: custom, operation: .generate))
        let selection = ImageGenerationPresetResolver.applyingDefaults(
            .init(), provider: provider, model: custom, operation: .generate)
        try ImageGenerationPresetResolver.validateSelection(
            selection, provider: provider, model: custom, operation: .generate,
            count: 1, referenceCount: 0)
        try ImageGenerationPresetResolver.validateSelection(
            .init(nativeSizeOverride: "1024x1024"), provider: provider, model: custom,
            operation: .generate, count: 1, referenceCount: 0)
        #expect(ImageProviderAdapterFactory().adapter(for: provider) is VolcengineImageAdapter)
        #expect(custom.remoteModelID == "user-configured-future-image-model")
    }

    @Test("Fallback is exact-only disabled and stays on the same billing channel")
    func fallbackPolicy() {
        let initial = planProvider()
        let samePlan = planProvider()
        let payg = ProviderProfile(
            kind: .volcengineArk,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!
        )
        #expect(!ImageRouteFallbackPolicy.allowsFallback(
            explicitSelection: true, autonomous: true,
            initialProvider: initial, candidateProvider: samePlan))
        #expect(ImageRouteFallbackPolicy.allowsFallback(
            explicitSelection: false, autonomous: true,
            initialProvider: initial, candidateProvider: samePlan))
        #expect(!ImageRouteFallbackPolicy.allowsFallback(
            explicitSelection: false, autonomous: true,
            initialProvider: initial, candidateProvider: payg))
        #expect(!ImageRouteFallbackPolicy.allowsFallback(
            explicitSelection: false, autonomous: false,
            initialProvider: initial, candidateProvider: samePlan))
        let unrelated = ProviderProfile(kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.openai.com/v1")!)
        #expect(!ImageRouteFallbackPolicy.allowsFallback(
            explicitSelection: false, autonomous: true,
            initialProvider: payg, candidateProvider: unrelated))
        #expect(ImageRouteFallbackPolicy.allowsFallback(
            explicitSelection: false, autonomous: true,
            initialProvider: payg, candidateProvider: payg))
    }
}
