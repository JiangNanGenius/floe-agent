import Foundation
import Testing
import FloeCore
@testable import FloePersistence

@Suite("FloePersistence.ModelConfigurationStore")
struct ModelConfigurationStoreTests {
    private func makeStore() async throws -> ModelConfigurationStore {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return ModelConfigurationStore(database: database)
    }

    @Test("Device-local reconciliation persists launch identities and disables removed models")
    func localCatalogReconciliation() async throws {
        let store = try await makeStore()
        let provider = ProviderProfile(
            id: ProviderProfile.onDeviceProviderID,
            kind: .local,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "http://127.0.0.1")),
            displayName: "On-device models",
            allowsPlainHTTP: true
        )
        let installed = ModelProfile(
            id: UUID(uuidString: "A1480001-0000-4000-8000-000000000001")!,
            providerID: provider.id,
            remoteModelID: "qwen-test",
            displayName: "Qwen Test",
            limits: .init(contextTokens: 8192, maxOutputTokens: 2048),
            capabilities: [.text, .vision, .tools]
        )

        _ = try await store.reconcileDeviceLocalProvider(
            provider: provider,
            availableModels: [installed]
        )
        #expect(try await store.provider(id: provider.id) != nil)
        #expect(try await store.model(id: installed.id)?.isEnabled == true)

        _ = try await store.reconcileDeviceLocalProvider(provider: provider, availableModels: [])
        #expect(try await store.model(id: installed.id)?.isEnabled == false)
    }

    @Test("Provider metadata round-trips without an API-key body")
    func providerRoundTrip() async throws {
        let store = try await makeStore()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "https://api.openai.com/v1")),
            displayName: "Primary OpenAI",
            secretRef: SecretReference(
                keychainAccount: "provider-test-account",
                synchronizable: true
            ),
            region: "global",
            nonSecretHeaders: ["OpenAI-Organization": "org_test"],
            createdAt: createdAt,
            updatedAt: createdAt,
            syncRevision: 4
        )

        try await store.saveProvider(provider)
        let loaded = try #require(await store.provider(id: provider.id))

        #expect(loaded == provider)
        #expect(try await store.providers() == [provider])
    }

    @Test("Saving an existing provider updates without deleting its models")
    func providerUpsertPreservesModels() async throws {
        let store = try await makeStore()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_100.250)
        var provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://gateway.example/v1")),
            createdAt: createdAt,
            updatedAt: createdAt
        )
        try await store.saveProvider(provider)

        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "example-vision",
            displayName: "Example Vision",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            pricing: PricingMetadata(inputPerMillion: 1.25, outputPerMillion: 5),
            capabilities: [.text, .vision, .tools]
        )
        try await store.saveModel(model)

        provider.region = "updated"
        provider.updatedAt = provider.updatedAt.addingTimeInterval(1)
        try await store.saveProvider(provider)

        #expect(try await store.provider(id: provider.id) == provider)
        #expect(try await store.models(providerID: provider.id) == [model])
    }

    @Test("Deleting a provider cascades to its models")
    func deleteProviderCascades() async throws {
        let store = try await makeStore()
        let provider = ProviderProfile(
            kind: .anthropic,
            wireProtocol: .anthropicMessages,
            baseURL: try #require(URL(string: "https://api.anthropic.com"))
        )
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "claude-test",
            displayName: "Claude Test",
            limits: ModelLimits(contextTokens: 200_000, maxOutputTokens: 8_192)
        )
        try await store.saveProvider(provider)
        try await store.saveModel(model)

        try await store.deleteProvider(id: provider.id)

        #expect(try await store.provider(id: provider.id) == nil)
        #expect(try await store.model(id: model.id) == nil)
    }

    @Test("Per-model reasoning effort round-trips")
    func reasoningEffortRoundTrip() async throws {
        let store = try await makeStore()
        let provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://api.deepseek.com"))
        )
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "deepseek-v4-flash",
            displayName: "DeepSeek V4 Flash",
            limits: ModelLimits(contextTokens: 1_048_576, maxOutputTokens: 65_536),
            reasoningEffort: .maximum
        )
        try await store.saveProvider(provider)
        try await store.saveModel(model)

        #expect(try await store.model(id: model.id)?.reasoningEffort == .maximum)
    }

    @Test("Rejects unsafe provider URLs and invalid model limits")
    func rejectsInvalidConfigurations() async throws {
        let store = try await makeStore()
        let unsafe = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "http://public.example/v1")),
            allowsPlainHTTP: true
        )
        await #expect(throws: FloeError.self) {
            try await store.saveProvider(unsafe)
        }

        let provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "https://public.example/v1"))
        )
        try await store.saveProvider(provider)
        let invalidModel = ModelProfile(
            providerID: provider.id,
            remoteModelID: "",
            displayName: "Broken",
            limits: ModelLimits(contextTokens: 0, maxOutputTokens: -1)
        )
        await #expect(throws: FloeError.self) {
            try await store.saveModel(invalidModel)
        }
    }

    @Test("Model context is required while maximum output may be unspecified")
    func optionalMaximumOutput() async throws {
        let store = try await makeStore()
        let provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "https://public.example/v1"))
        )
        try await store.saveProvider(provider)
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "provider-default-output",
            displayName: "Provider Default",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 0)
        )

        try await store.saveModel(model)
        #expect(try await store.model(id: model.id)?.limits.maxOutputTokens == 0)

        var invalid = model
        invalid.limits.contextTokens = 0
        await #expect(throws: FloeError.self) {
            try await store.saveModel(invalid)
        }
    }

    @Test("Models merge by provider and remote identifier")
    func modelIdentityMerge() async throws {
        let store = try await makeStore()
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "https://api.openai.com/v1"))
        )
        try await store.saveProvider(provider)
        let first = ModelProfile(
            providerID: provider.id,
            remoteModelID: "gpt-test",
            displayName: "First",
            limits: ModelLimits(contextTokens: 10, maxOutputTokens: 2)
        )
        var rediscovered = first
        rediscovered.id = UUID()
        rediscovered.displayName = "User Name"
        rediscovered.capabilities = [.text, .vision]

        try await store.saveModel(first)
        try await store.saveModel(rediscovered)
        let models = try await store.models(providerID: provider.id)

        #expect(models.count == 1)
        #expect(models[0].id == first.id)
        #expect(models[0].displayName == "User Name")
        #expect(models[0].capabilities.contains(.vision))
    }

    @Test("Provider bundle removes deselected chat models and preserves image models")
    func providerBundleSelection() async throws {
        let store = try await makeStore()
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "https://api.openai.com/v1"))
        )
        let kept = ModelProfile(
            providerID: provider.id, remoteModelID: "kept", displayName: "Kept",
            limits: ModelLimits(contextTokens: 10, maxOutputTokens: 2), capabilities: [.text]
        )
        let removed = ModelProfile(
            providerID: provider.id, remoteModelID: "removed", displayName: "Removed",
            limits: ModelLimits(contextTokens: 10, maxOutputTokens: 2), capabilities: [.text]
        )
        let image = ModelProfile(
            providerID: provider.id, remoteModelID: "image", displayName: "Image",
            limits: ModelLimits(contextTokens: 1, maxOutputTokens: 1),
            capabilities: [.imageGeneration]
        )
        try await store.saveProvider(provider)
        try await store.saveModel(kept)
        try await store.saveModel(removed)
        try await store.saveModel(image)

        _ = try await store.saveProviderBundle(provider: provider, models: [kept])
        let models = try await store.models(providerID: provider.id)
        #expect(Set(models.map(\.remoteModelID)) == ["kept", "image"])
    }

    @Test("Preferences enforce role capabilities and clear deleted references")
    func modelPreferences() async throws {
        let store = try await makeStore()
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "https://api.openai.com/v1"))
        )
        try await store.saveProvider(provider)
        let agent = ModelProfile(
            providerID: provider.id,
            remoteModelID: "agent",
            displayName: "Agent",
            limits: ModelLimits(contextTokens: 10, maxOutputTokens: 2),
            capabilities: [.text, .tools]
        )
        let image = ModelProfile(
            providerID: provider.id,
            remoteModelID: "image",
            displayName: "Image",
            limits: ModelLimits(contextTokens: 1, maxOutputTokens: 1),
            capabilities: [.imageGeneration, .imageEditing]
        )
        let vision = ModelProfile(
            providerID: provider.id,
            remoteModelID: "vision",
            displayName: "Vision",
            limits: ModelLimits(contextTokens: 10, maxOutputTokens: 2),
            capabilities: [.text, .vision]
        )
        try await store.saveModel(agent)
        try await store.saveModel(image)
        try await store.saveModel(vision)
        let preferences = ModelSelectionPreferences(
            onboardingStatus: .completed,
            defaultAgentModelID: agent.id,
            visionModelID: vision.id,
            auxiliaryImageMode: .shared,
            sharedImageModelID: image.id
        )
        try await store.savePreferences(preferences)
        #expect(try await store.preferences().defaultAgentModelID == agent.id)
        #expect(try await store.preferences().visionModelID == vision.id)
        #expect(try await store.preferences().sharedImageModelID == image.id)

        try await store.deleteModel(id: image.id)
        #expect(try await store.preferences().sharedImageModelID == nil)
    }

    @Test("Onboarding status persists independently from unfinished configuration")
    func onboardingStatusPersistence() async throws {
        let store = try await makeStore()
        #expect(try await store.preferences().onboardingStatus == .unseen)

        var preferences = try await store.preferences()
        preferences.onboardingStatus = .skipped
        try await store.savePreferences(preferences)
        #expect(try await store.preferences().onboardingStatus == .skipped)
        #expect(try await store.providers().isEmpty)
        #expect(try await store.models().isEmpty)
    }
}
