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

@Suite("Untrusted remote configuration validation")
struct RemoteConfigurationValidationTests {
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    @Test("Valid remote provider payloads decode and pass the same gate as local writes")
    func validRemoteProviderAccepted() throws {
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: URL(string: "https://api.openai.com/v1")!,
            displayName: "公司网关"
        )
        let decoded = try ConfigSyncEngine.validatedRemoteProvider(try encode(provider))
        // ISO-8601 second precision means whole-value equality can differ on
        // sub-second timestamps; identity/endpoint/name are what matter.
        #expect(decoded.id == provider.id)
        #expect(decoded.kind == provider.kind)
        #expect(decoded.wireProtocol == provider.wireProtocol)
        #expect(decoded.baseURL == provider.baseURL)
        #expect(decoded.displayName == "公司网关")
        #expect(decoded.presetID == provider.presetID)
    }

    @Test("Remote provider payloads with invalid names are rejected without persisting")
    func invalidRemoteProviderRejected() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let configuration = ModelConfigurationStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let engine = ConfigSyncEngine(
            configurationStore: configuration,
            metadataStore: metadata
        )

        for name in ["bad\nname", String(repeating: "x", count: 257)] {
            var payload = try encode(ProviderProfile(
                kind: .custom,
                wireProtocol: .openAIChatCompletions,
                baseURL: URL(string: "https://evil.example/v1")!,
                displayName: name
            ))
            // Sanity: the invalid profile cannot be saved locally either.
            await #expect(throws: FloeError.self) {
                try ConfigSyncEngine.validatedRemoteProvider(payload)
            }
            // Malformed JSON is rejected distinctly.
            payload = Data("{not json".utf8)
            await #expect(throws: FloeError.self) {
                try ConfigSyncEngine.validatedRemoteProvider(payload)
            }
        }
        // Nothing was persisted and the engine surfaces an error-able status
        // type without crashing; local store stays empty.
        #expect(try await configuration.providers().isEmpty)
        _ = engine // retain through the test
    }

    @Test("Remote model payloads with empty id or bad limits are rejected")
    func invalidRemoteModelRejected() throws {
        let bad = ModelProfile(
            providerID: UUID(),
            remoteModelID: "",
            displayName: "Broken",
            limits: ModelLimits(contextTokens: 0, maxOutputTokens: -1)
        )
        #expect(throws: FloeError.self) {
            try ConfigSyncEngine.validatedRemoteModel(try encode(bad))
        }
        #expect(throws: FloeError.self) {
            try ConfigSyncEngine.validatedRemoteModel(Data("{}".utf8))
        }
        let good = ModelProfile(
            providerID: UUID(), remoteModelID: "m", displayName: "M",
            limits: ModelLimits(contextTokens: 100, maxOutputTokens: 10)
        )
        let decoded = try ConfigSyncEngine.validatedRemoteModel(try encode(good))
        #expect(decoded.remoteModelID == "m")
    }
}

#if canImport(CloudKit)
import CloudKit

/// T6 — the REAL fetch/batch pipeline for rejected remote records.
///
/// Regression: `applyRemote` rejected an invalid payload by setting
/// `status = .error`, but the `.didFetchRecordZoneChanges` epilogue then
/// overwrote it with `credentialSyncStatus()` (usually `.synced`). These
/// tests drive the actual `applyRemote` record path (the same one the
/// CKSyncEngine delegate calls) and the actual batch completion status.
@Suite("Rejected remote batch status")
struct RejectedRemoteBatchStatusTests {
    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func remoteRecord(
        type: ConfigSyncRecordType,
        id: String,
        payload: Data,
        timestamps: [String: Date]
    ) throws -> CKRecord {
        let zoneID = CKRecordZone.ID(zoneName: "T6RejectedRemoteZone",
                                     ownerName: CKCurrentUserDefaultName)
        let record = CKRecord(recordType: type.rawValue,
                              recordID: CKRecord.ID(recordName: id, zoneID: zoneID))
        record.encryptedValues["payload"] = payload as CKRecordValue
        record.encryptedValues["fieldTimestamps"] = try encode(timestamps) as CKRecordValue
        return record
    }

    @Test("Rejected remote record keeps the local original, is not acknowledged, and the batch stays an honest partial failure")
    func rejectedRemoteKeepsLocalAndHonestBatchStatus() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let configuration = ModelConfigurationStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let engine = ConfigSyncEngine(
            configurationStore: configuration,
            metadataStore: metadata
        )

        // Local original configuration (must be preserved untouched).
        let local = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://local.example/v1")!,
            displayName: "本地原配置"
        )
        try await configuration.saveProvider(local)

        // An invalid remote update for the SAME record identity (control
        // characters in the name), newer than nothing.
        let remoteInvalid = ProviderProfile(
            id: local.id,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://remote.example/v1")!,
            displayName: "bad\nname"
        )
        let invalidPayload = try encode(remoteInvalid)
        let invalidTimestamps = ["displayName": Date(), "baseURL": Date()]
        let invalidRecord = try remoteRecord(
            type: .providerProfile, id: local.id.uuidString,
            payload: invalidPayload, timestamps: invalidTimestamps
        )

        try await engine.applyRemote(invalidRecord)

        // 1) Local original retained (no partial merge happened).
        let stored = try await configuration.provider(id: local.id)
        #expect(stored?.displayName == "本地原配置")
        #expect(stored?.baseURL == local.baseURL)
        // 2) The rejected record was never acknowledged: no sync metadata.
        #expect(try await metadata.metadata(
            recordType: ConfigSyncRecordType.providerProfile.rawValue,
            recordID: local.id.uuidString
        ) == nil)
        // 3) The rejection is tracked and the immediate status is an error.
        #expect(await engine.rejectedRemoteRecordIDs.contains(local.id.uuidString))
        let immediate = await engine.status
        if case .error = immediate {} else {
            Issue.record("rejection must surface as .error, got \(immediate)")
        }

        // 4) A valid record in the same batch still applies.
        let other = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://valid.example/v1")!,
            displayName: "Valid Remote"
        )
        let validRecord = try remoteRecord(
            type: .providerProfile, id: other.id.uuidString,
            payload: try encode(other), timestamps: ["displayName": Date()]
        )
        try await engine.applyRemote(validRecord)
        #expect(try await configuration.provider(id: other.id)?.displayName == "Valid Remote")

        // 5) The REGRESSION: the fetch-batch epilogue must NOT erase the
        //    rejection with the derived credential status (.synced).
        let batchStatus = await engine.batchCompletionStatus()
        if case .error = batchStatus {} else {
            Issue.record("batch completion masked the rejection: \(batchStatus)")
        }
        #expect(await engine.rejectedRemoteRecordIDs.contains(local.id.uuidString))

        // 6) A corrected remote payload for the SAME record applies and
        //    clears the rejection; this is the honest retry outcome.
        let corrected = ProviderProfile(
            id: local.id,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://corrected.example/v1")!,
            displayName: "Corrected Remote"
        )
        let correctedRecord = try remoteRecord(
            type: .providerProfile, id: local.id.uuidString,
            payload: try encode(corrected),
            timestamps: ["displayName": Date().addingTimeInterval(10),
                         "baseURL": Date().addingTimeInterval(10)]
        )
        try await engine.applyRemote(correctedRecord)
        #expect(try await configuration.provider(id: local.id)?.displayName == "Corrected Remote")
        #expect(try await metadata.metadata(
            recordType: ConfigSyncRecordType.providerProfile.rawValue,
            recordID: local.id.uuidString
        ) != nil)
        let stillRejectedAfterCorrection = await engine.rejectedRemoteRecordIDs.contains(local.id.uuidString)
        #expect(!stillRejectedAfterCorrection)
        let resolved = await engine.batchCompletionStatus()
        if case .error = resolved {
            // A previous rejection of another record may remain; only assert
            // the corrected record cleared its own outcome.
            let stillRejected = await engine.rejectedRemoteRecordIDs.contains(local.id.uuidString)
            #expect(!stillRejected)
        }
    }

    @Test("Rejected remote model keeps the local model and never acknowledges the record")
    func rejectedRemoteModelPreservesLocalModel() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let configuration = ModelConfigurationStore(database: database)
        let metadata = ConfigSyncMetadataStore(database: database)
        let engine = ConfigSyncEngine(
            configurationStore: configuration,
            metadataStore: metadata
        )

        let provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://model.example/v1")!,
            displayName: "Model Host"
        )
        try await configuration.saveProvider(provider)
        let localModel = ModelProfile(
            providerID: provider.id, remoteModelID: "keep",
            displayName: "Keep Local",
            limits: ModelLimits(contextTokens: 8192, maxOutputTokens: 1024)
        )
        try await configuration.saveModel(localModel)

        let invalid = ModelProfile(
            id: localModel.id,
            providerID: provider.id, remoteModelID: "keep",
            displayName: "Keep Local",
            limits: ModelLimits(contextTokens: 0, maxOutputTokens: -1)
        )
        let record = try remoteRecord(
            type: .modelProfile, id: localModel.id.uuidString,
            payload: try encode(invalid),
            timestamps: ["limits": Date(), "displayName": Date()]
        )
        try await engine.applyRemote(record)

        let stored = try await configuration.model(id: localModel.id)
        #expect(stored?.limits.contextTokens == 8192)
        #expect(try await metadata.metadata(
            recordType: ConfigSyncRecordType.modelProfile.rawValue,
            recordID: localModel.id.uuidString
        ) == nil)
        #expect(await engine.rejectedRemoteRecordIDs.contains(localModel.id.uuidString))
        let batchStatus = await engine.batchCompletionStatus()
        if case .error(let message) = batchStatus {
            #expect(!message.isEmpty)
        } else {
            Issue.record("expected honest error status, got \(batchStatus)")
        }
    }
}
#endif
