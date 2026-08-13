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

    @Test("Provider metadata round-trips without an API-key body")
    func providerRoundTrip() async throws {
        let store = try await makeStore()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "https://api.openai.com/v1")),
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
}
