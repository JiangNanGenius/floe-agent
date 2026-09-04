import Foundation
import Testing
import FloeCore
@testable import FloePersistence
@testable import FloeSync

@Suite("Deferred configuration sync")
struct DeferredConfigSyncTests {
    @Test("Auxiliary LLM preference waits for its model dependency and restores independently")
    func auxiliaryDependency() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let configuration = ModelConfigurationStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let engine = ConfigSyncEngine(configurationStore: configuration, metadataStore: metadata)
        let provider = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://example.test/v1")!)
        try await configuration.saveProvider(provider)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "aux", displayName: "Aux",
            limits: .init(contextTokens: 4096, maxOutputTokens: 1024), capabilities: [.text])
        try await metadata.save(ConfigSyncMetadata(
            recordType: ConfigSyncRecordType.preference.rawValue, recordID: "default",
            deferredRemotePayload: try encode(ModelSelectionPreferences(generalAuxiliaryLLMModelID: model.id))))
        try await engine.retryDeferredRecords()
        #expect(try await configuration.preferences().generalAuxiliaryLLMModelID == nil)
        try await configuration.saveModel(model)
        try await engine.retryDeferredRecords()
        let restored = try await configuration.preferences()
        #expect(restored.generalAuxiliaryLLMModelID == model.id)
        #expect(restored.visionModelID == nil)
        #expect(restored.approvalModelID == nil)
        #expect(restored.defaultVideoModelID == nil)
    }

    @Test("Provider and model dependencies replay durable remote payloads in order")
    func dependenciesReplayInOrder() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let configuration = ModelConfigurationStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let engine = ConfigSyncEngine(
            configurationStore: configuration,
            metadataStore: metadata
        )

        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: try #require(URL(string: "https://example.test/v1")),
            displayName: "Media"
        )
        let video = ModelProfile(
            providerID: provider.id,
            remoteModelID: "video-test",
            displayName: "Video Test",
            limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.videoGeneration],
            isHiddenFromPrimaryPicker: true
        )
        try await metadata.save(ConfigSyncMetadata(
            recordType: ConfigSyncRecordType.modelProfile.rawValue,
            recordID: video.id.uuidString,
            deferredRemotePayload: try encode(video)
        ))

        try await engine.retryDeferredRecords()
        #expect(try await configuration.model(id: video.id) == nil)
        #expect(try await metadata.metadata(
            recordType: ConfigSyncRecordType.modelProfile.rawValue,
            recordID: video.id.uuidString
        )?.deferredRemotePayload != nil)

        try await configuration.saveProvider(provider)
        try await engine.retryDeferredRecords()
        #expect(try await configuration.model(id: video.id) == video)
        #expect(try await metadata.metadata(
            recordType: ConfigSyncRecordType.modelProfile.rawValue,
            recordID: video.id.uuidString
        )?.deferredRemotePayload == nil)

        let image = ModelProfile(
            providerID: provider.id,
            remoteModelID: "image-test",
            displayName: "Image Test",
            limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.imageGeneration],
            isHiddenFromPrimaryPicker: true
        )
        let preferences = ModelSelectionPreferences(
            auxiliaryImageMode: .separate,
            imageGenerationModelID: image.id,
            defaultVideoModelID: video.id
        )
        try await metadata.save(ConfigSyncMetadata(
            recordType: ConfigSyncRecordType.preference.rawValue,
            recordID: "default",
            deferredRemotePayload: try encode(preferences)
        ))

        try await engine.retryDeferredRecords()
        #expect(try await configuration.preferences().imageGenerationModelID == nil)
        #expect(try await metadata.metadata(
            recordType: ConfigSyncRecordType.preference.rawValue,
            recordID: "default"
        )?.deferredRemotePayload != nil)

        try await configuration.saveModel(image)
        try await engine.retryDeferredRecords()
        let restored = try await configuration.preferences()
        #expect(restored.imageGenerationModelID == image.id)
        #expect(restored.defaultVideoModelID == video.id)
        #expect(try await metadata.metadata(
            recordType: ConfigSyncRecordType.preference.rawValue,
            recordID: "default"
        )?.deferredRemotePayload == nil)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}
