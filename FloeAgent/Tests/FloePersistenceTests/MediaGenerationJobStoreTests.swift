import Foundation
import Testing
import FloeCore
@testable import FloePersistence

@Suite("Durable media generation jobs")
struct MediaGenerationJobStoreTests {
    @Test func migrationAndCrashRecoveryKeepProviderTaskIdentity() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        #expect(try await database.userVersion() == 27)

        let configuration = ModelConfigurationStore(database: database)
        let provider = ProviderProfile(
            kind: .googleGemini, wireProtocol: .openAIResponses,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!
        )
        let model = ModelProfile(
            providerID: provider.id, remoteModelID: "veo-3.1-generate-preview",
            displayName: "Veo 3.1", limits: .init(contextTokens: 1, maxOutputTokens: 0),
            capabilities: [.videoGeneration], isHiddenFromPrimaryPicker: true
        )
        try await configuration.saveProvider(provider)
        try await configuration.saveModel(model)

        let store = MediaGenerationJobStore(database: database)
        var job = MediaGenerationJob(
            providerID: provider.id, modelID: model.id, mediaKind: .video,
            credentialReference: .init(keychainAccount: "provider.test", synchronizable: true),
            canvasID: UUID(), documentID: UUID(), sourceNodeIDs: [UUID()],
            resultNodeID: UUID(), requestJSON: Data("{\"prompt\":\"test\"}".utf8)
        )
        try await store.save(job)
        job.providerTaskID = "operations/abc"
        job.state = .submitted
        job.nextPollAt = Date(timeIntervalSince1970: 1)
        try await store.save(job)

        let restored = try #require(await store.job(id: job.id))
        #expect(restored.providerTaskID == "operations/abc")
        #expect(restored.credentialReference?.keychainAccount == "provider.test")
        #expect(String(decoding: restored.requestJSON, as: UTF8.self).contains("test"))
        #expect((try await store.dueJobs(at: Date())).map(\.id) == [job.id])
    }

    @Test func rejectsStateRegressionAndMakesDuplicateTransitionIdempotent() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let configuration = ModelConfigurationStore(database: database)
        let provider = ProviderProfile(kind: .volcengineArk, wireProtocol: .openAIChatCompletions, baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "seedance", displayName: "Seedance", limits: .init(contextTokens: 1, maxOutputTokens: 0), capabilities: [.videoGeneration])
        try await configuration.saveProvider(provider)
        try await configuration.saveModel(model)
        let store = MediaGenerationJobStore(database: database)
        let job = MediaGenerationJob(providerID: provider.id, modelID: model.id, mediaKind: .video, credentialReference: nil, canvasID: UUID(), documentID: UUID(), sourceNodeIDs: [], resultNodeID: UUID(), requestJSON: Data())
        try await store.save(job)
        _ = try await store.transition(id: job.id, to: .submitted)
        _ = try await store.transition(id: job.id, to: .running)
        _ = try await store.transition(id: job.id, to: .running)
        await #expect(throws: MediaGenerationJobStoreError.self) {
            _ = try await store.transition(id: job.id, to: .submitted)
        }
    }

    @Test func canvasSyncOperationIsIdempotentAndCreatesDeletionTombstone() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CanvasSyncOperationStore(database: database)
        let operation = CanvasSyncOperation(
            canvasID: UUID(), entityKind: .tombstone, entityID: UUID(),
            mutation: .delete, revision: 42
        )
        try await store.enqueue(operation)
        try await store.enqueue(operation)
        let pending = try await store.pending()
        #expect(pending.count == 1)
        #expect(pending[0].operation.operationID == operation.operationID)
        try await store.confirm(operationID: operation.operationID)
        #expect(try await store.pending().isEmpty)
    }

    @Test func cloudOnlyReleaseKeepsLocalAssetAfterConfirmedDeletion() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CreativeAssetStore(database: database)
        let asset = CreativeAssetRecord(
            id: UUID(), contentHash: "asset-sha256", kind: .image,
            displayName: "local.png", localRelativePath: "Materials/local.png",
            cloudRecordName: "CreativeAsset-asset-sha256", byteCount: 512
        )
        try await store.save(asset)
        try await store.requestCloudCopyDeletion(assetID: asset.id)
        let pending = try await store.pendingReleases()
        let release = try #require(pending.first)
        #expect(release.deleteLocalAfterRelease == false)

        try await store.confirmRelease(
            id: release.id, assetID: asset.id, deleteLocalAfterRelease: false
        )
        let retained = try #require(await store.asset(id: asset.id))
        #expect(retained.localRelativePath == "Materials/local.png")
        #expect(retained.cloudRecordName == nil)
    }
}
