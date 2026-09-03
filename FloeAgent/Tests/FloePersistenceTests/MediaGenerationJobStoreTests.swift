import Foundation
import Testing
import FloeCore
@testable import FloePersistence

@Suite("Durable media generation jobs")
struct MediaGenerationJobStoreTests {
    @Test func concurrentIdenticalAssetsResolveOneCanonicalID() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CreativeAssetStore(database: database)
        let first = CreativeAssetRecord(
            id: UUID(),
            contentHash: "identical-generated-bytes",
            kind: .image,
            displayName: "First",
            mimeType: "image/png",
            localRelativePath: "Materials/first.png",
            byteCount: 128
        )
        let second = CreativeAssetRecord(
            id: UUID(),
            contentHash: first.contentHash,
            kind: .image,
            displayName: "Second",
            mimeType: "image/png",
            localRelativePath: "Materials/second.png",
            byteCount: 128
        )

        async let firstCanonical = store.saveResolvingCanonical(first)
        async let secondCanonical = store.saveResolvingCanonical(second)
        let resolvedPair = try await (firstCanonical, secondCanonical)
        let resolved = [resolvedPair.0, resolvedPair.1]

        #expect(Set(resolved.map(\.id)).count == 1)
        let canonicalID = try #require(resolved.first?.id)
        #expect(canonicalID == first.id || canonicalID == second.id)
        #expect(try await store.asset(id: canonicalID) != nil)
        #expect(try await store.asset(
            id: canonicalID == first.id ? second.id : first.id
        ) == nil)
        let matching = try await store.allAssets().filter {
            $0.contentHash == first.contentHash
        }
        #expect(matching.count == 1)
        #expect(matching.first?.id == canonicalID)
    }

    @Test func canonicalReservationsCountAndReleaseEveryDuplicateOutput() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CreativeAssetStore(database: database)
        let first = CreativeAssetRecord(
            id: UUID(), contentHash: "reserved-identical-bytes", kind: .image,
            displayName: "First", localRelativePath: "Materials/first.png"
        )
        let second = CreativeAssetRecord(
            id: UUID(), contentHash: first.contentHash, kind: .image,
            displayName: "Second", localRelativePath: "Materials/second.png"
        )

        async let firstCanonical = store.saveResolvingCanonical(
            first, reservingReferences: 1
        )
        async let secondCanonical = store.saveResolvingCanonical(
            second, reservingReferences: 1
        )
        let pair = try await (firstCanonical, secondCanonical)
        #expect(pair.0.id == pair.1.id)
        #expect(try await store.asset(id: pair.0.id)?.referenceCount == 2)

        // Releasing one failed output must not consume the other request's
        // reservation, even though both resolve to the same canonical row.
        try await store.releaseReferenceReservations(assetIDs: [pair.0.id])
        #expect(try await store.asset(id: pair.0.id)?.referenceCount == 1)
        await #expect(throws: FloeError.self) {
            _ = try await store.requestPermanentDeletion(assetID: pair.0.id)
        }
        try await store.releaseReferenceReservations(assetIDs: [pair.1.id])
        #expect(try await store.asset(id: pair.0.id)?.referenceCount == 0)

        // Existing-hash reuse reserves atomically as well.
        let reused = try await store.saveResolvingCanonical(
            second, reservingReferences: 1
        )
        #expect(reused.id == pair.0.id)
        #expect(reused.referenceCount == 1)
        try await store.releaseReferenceReservations(assetIDs: [reused.id])
        #expect(try await store.asset(id: reused.id)?.referenceCount == 0)
    }

    @Test func canonicalConflictNeverPublishesThrowawayCandidatePath() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CreativeAssetStore(database: database)
        let canonical = CreativeAssetRecord(
            id: UUID(), contentHash: "cloud-only-canonical", kind: .image,
            displayName: "Cloud only",
            cloudRecordName: "CreativeAsset-cloud-only-canonical"
        )
        try await store.save(canonical)
        let throwaway = CreativeAssetRecord(
            id: UUID(), contentHash: canonical.contentHash, kind: .image,
            displayName: "Generated candidate",
            localRelativePath: "Materials/\(UUID().uuidString)-generated.png"
        )

        let resolved = try await store.saveResolvingCanonical(
            throwaway,
            reservingReferences: 1
        )
        #expect(resolved.id == canonical.id)
        #expect(resolved.localRelativePath == nil)
        #expect(resolved.referenceCount == 1)
        try await store.releaseReferenceReservations(assetIDs: [resolved.id])
    }

    @Test func permanentDeletionReturnsAPathOnlyForAnActuallyDeletedRow() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CreativeAssetStore(database: database)
        let asset = CreativeAssetRecord(
            id: UUID(),
            contentHash: "delete-only-after-row",
            kind: .image,
            displayName: "Generated",
            localRelativePath: "Materials/generated.png",
            referenceCount: 1
        )
        try await store.save(asset)

        await #expect(throws: FloeError.self) {
            _ = try await store.requestPermanentDeletion(assetID: asset.id)
        }
        #expect(try await store.asset(id: asset.id)?.referenceCount == 1)

        try await store.adjustReference(assetID: asset.id, by: -1)
        let deletablePath = try await store.requestPermanentDeletion(assetID: asset.id)
        #expect(deletablePath == asset.localRelativePath)
        #expect(try await store.asset(id: asset.id) == nil)

        await #expect(throws: FloeError.self) {
            try await store.adjustReference(assetID: asset.id, by: 1)
        }
    }

    @Test func cloudReleaseAuthorizesLocalRemovalOnlyAfterConfirmedRowDeletion() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CreativeAssetStore(database: database)
        let asset = CreativeAssetRecord(
            id: UUID(),
            contentHash: "cloud-release-keeps-local",
            kind: .image,
            displayName: "Cloud Generated",
            localRelativePath: "Materials/cloud.png",
            cloudRecordName: "CreativeAsset-cloud-release-keeps-local"
        )
        try await store.save(asset)

        #expect(try await store.requestPermanentDeletion(assetID: asset.id) == nil)
        #expect(try await store.asset(id: asset.id) != nil)
        let pending = try await store.pendingReleases()
        #expect(pending.count == 1)
        #expect(pending[0].assetID == asset.id)
        #expect(pending[0].deleteLocalAfterRelease)

        let authorizedPath = try await store.confirmRelease(
            id: pending[0].id,
            assetID: asset.id,
            deleteLocalAfterRelease: true,
            deleteLocalFile: { _ in }
        )
        #expect(authorizedPath == asset.localRelativePath)
        #expect(try await store.asset(id: asset.id) == nil)
        #expect(try await store.pendingReleases().isEmpty)
    }

    @Test func cloudReleaseRetainsLocalFileWhenReferenceWinsConfirmationRace() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CreativeAssetStore(database: database)
        let asset = CreativeAssetRecord(
            id: UUID(),
            contentHash: "cloud-release-reference-race",
            kind: .image,
            displayName: "Cloud Referenced",
            localRelativePath: "Materials/referenced.png",
            cloudRecordName: "CreativeAsset-cloud-release-reference-race"
        )
        try await store.save(asset)
        #expect(try await store.requestPermanentDeletion(assetID: asset.id) == nil)
        let release = try #require(await store.pendingReleases().first)

        // A canvas commit references the asset after remote release began but
        // before its confirmation transaction reaches the local database.
        try await store.adjustReference(assetID: asset.id, by: 1)
        let authorizedPath = try await store.confirmRelease(
            id: release.id,
            assetID: asset.id,
            deleteLocalAfterRelease: true,
            deleteLocalFile: { _ in
                throw FloeError.internalError(
                    "Referenced assets must not authorize local deletion"
                )
            }
        )

        #expect(authorizedPath == nil)
        let retained = try #require(await store.asset(id: asset.id))
        #expect(retained.referenceCount == 1)
        #expect(retained.localRelativePath == asset.localRelativePath)
        #expect(retained.cloudRecordName == nil)
        #expect(try await store.pendingReleases().isEmpty)
    }

    @Test func failedLocalFileDeletionKeepsCloudReleaseRetryable() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CreativeAssetStore(database: database)
        let asset = CreativeAssetRecord(
            id: UUID(), contentHash: "retry-local-delete", kind: .image,
            displayName: "Retry Local Delete",
            localRelativePath: "Materials/retry.png",
            cloudRecordName: "CreativeAsset-retry-local-delete"
        )
        try await store.save(asset)
        _ = try await store.requestPermanentDeletion(assetID: asset.id)
        let release = try #require(await store.pendingReleases().first)
        try await store.markRelease(id: release.id, state: .releasing)

        await #expect(throws: FloeError.self) {
            _ = try await store.confirmRelease(
                id: release.id,
                assetID: asset.id,
                deleteLocalAfterRelease: true,
                deleteLocalFile: { _ in
                    throw FloeError.internalError("simulated unlink failure")
                }
            )
        }
        #expect(try await store.asset(id: asset.id) != nil)
        try await store.markRelease(
            id: release.id,
            state: .failed,
            error: "simulated unlink failure"
        )
        #expect(try await store.pendingReleases().map(\.id) == [release.id])

        let retryPath = try await store.confirmRelease(
            id: release.id,
            assetID: asset.id,
            deleteLocalAfterRelease: true,
            deleteLocalFile: { _ in }
        )
        #expect(retryPath == asset.localRelativePath)
        #expect(try await store.asset(id: asset.id) == nil)
        #expect(try await store.pendingReleases().isEmpty)
    }

    @Test func migrationAndCrashRecoveryKeepProviderTaskIdentity() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        #expect(try await database.userVersion() == DatabaseManager.currentSchemaVersion)

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

    @Test func deletesOnlyJobsOwnedByRequestedCanvasDocument() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let configuration = ModelConfigurationStore(database: database)
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: URL(string: "https://api.openai.com/v1")!
        )
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "gpt-image-1",
            displayName: "Image",
            limits: .init(contextTokens: 1, maxOutputTokens: 0),
            capabilities: [.imageGeneration]
        )
        try await configuration.saveProvider(provider)
        try await configuration.saveModel(model)

        let store = MediaGenerationJobStore(database: database)
        let canvasID = UUID(), firstDocumentID = UUID(), secondDocumentID = UUID()
        for documentID in [firstDocumentID, secondDocumentID] {
            try await store.save(MediaGenerationJob(
                providerID: provider.id,
                modelID: model.id,
                mediaKind: .image,
                credentialReference: nil,
                canvasID: canvasID,
                documentID: documentID,
                sourceNodeIDs: [],
                resultNodeID: UUID(),
                requestJSON: Data()
            ))
        }

        try await store.deleteJobs(canvasID: canvasID, documentID: firstDocumentID)
        let remaining = try await store.jobs(canvasID: canvasID)
        #expect(remaining.count == 1)
        #expect(remaining[0].documentID == secondDocumentID)
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

        _ = try await store.confirmRelease(
            id: release.id,
            assetID: asset.id,
            deleteLocalAfterRelease: false,
            deleteLocalFile: { _ in
                throw FloeError.internalError(
                    "Cloud-only release must retain the local file"
                )
            }
        )
        let retained = try #require(await store.asset(id: asset.id))
        #expect(retained.localRelativePath == "Materials/local.png")
        #expect(retained.cloudRecordName == nil)
    }

    @Test func fourDuplicateGeneratedSlotsReserveAndAbandonExactlyOnce() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CreativeAssetStore(database: database)
        let batchID = UUID()
        let hash = "four-identical-generated-slots"
        let slots = (0..<4).map { index in
            GeneratedAssetReservationSlotDraft(
                index: index,
                resultNodeID: UUID(),
                candidateAssetID: UUID(),
                contentHash: hash,
                candidateRelativePath: "Materials/four-\(index).png"
            )
        }
        try await store.beginGeneratedAssetReservationBatch(
            id: batchID,
            canvasID: UUID(),
            documentID: UUID(),
            configurationNodeID: UUID(),
            generationAttemptID: "four-slot-attempt",
            slots: slots
        )

        var canonicalIDs: [UUID] = []
        for slot in slots {
            let canonical = try await store.reserveGeneratedAsset(
                batchID: batchID,
                slotIndex: slot.index,
                candidate: CreativeAssetRecord(
                    id: slot.candidateAssetID,
                    contentHash: slot.contentHash,
                    kind: .image,
                    displayName: "Generated \(slot.index)",
                    localRelativePath: slot.candidateRelativePath
                )
            )
            canonicalIDs.append(canonical.id)
        }
        #expect(Set(canonicalIDs).count == 1)
        let canonicalID = try #require(canonicalIDs.first)
        #expect(try await store.asset(id: canonicalID)?.referenceCount == 4)
        let pending = try #require(
            await store.generatedAssetReservationBatch(id: batchID)
        )
        #expect(pending.state == .reserved)
        #expect(pending.slots.count == 4)
        #expect(pending.slots.allSatisfy { $0.canonicalAssetID == canonicalID })

        let firstAbandon = try await store
            .abandonGeneratedAssetReservationBatch(id: batchID)
        #expect(firstAbandon.slots.count == 4)
        #expect(firstAbandon.deletedLocalRelativePaths
            == [slots[0].candidateRelativePath])
        #expect(try await store.asset(id: canonicalID) == nil)
        let secondAbandon = try await store
            .abandonGeneratedAssetReservationBatch(id: batchID)
        #expect(secondAbandon.slots.isEmpty)
        #expect(secondAbandon.deletedLocalRelativePaths.isEmpty)
        #expect(try await store.asset(id: canonicalID) == nil)
        #expect(try await store.pendingGeneratedAssetReservationBatches().isEmpty)
        let terminal = try #require(
            await store.generatedAssetReservationBatch(id: batchID)
        )
        #expect(terminal.slots.allSatisfy { $0.canonicalAssetID == nil })
    }

    @Test func concurrentBatchesShareCanonicalAndSettleIndependently() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CreativeAssetStore(database: database)
        let firstBatch = UUID(), secondBatch = UUID()
        let firstSlot = GeneratedAssetReservationSlotDraft(
            index: 0, resultNodeID: UUID(), candidateAssetID: UUID(),
            contentHash: "shared-across-generated-batches",
            candidateRelativePath: "Materials/shared-first.png"
        )
        let secondSlot = GeneratedAssetReservationSlotDraft(
            index: 0, resultNodeID: UUID(), candidateAssetID: UUID(),
            contentHash: firstSlot.contentHash,
            candidateRelativePath: "Materials/shared-second.png"
        )
        for pair in [(firstBatch, firstSlot), (secondBatch, secondSlot)] {
            try await store.beginGeneratedAssetReservationBatch(
                id: pair.0, canvasID: UUID(), documentID: UUID(),
                configurationNodeID: UUID(),
                generationAttemptID: "attempt-\(pair.0.uuidString)",
                slots: [pair.1]
            )
        }

        async let first = store.reserveGeneratedAsset(
            batchID: firstBatch,
            slotIndex: 0,
            candidate: CreativeAssetRecord(
                id: firstSlot.candidateAssetID,
                contentHash: firstSlot.contentHash,
                kind: .image,
                displayName: "First",
                localRelativePath: firstSlot.candidateRelativePath
            )
        )
        async let second = store.reserveGeneratedAsset(
            batchID: secondBatch,
            slotIndex: 0,
            candidate: CreativeAssetRecord(
                id: secondSlot.candidateAssetID,
                contentHash: secondSlot.contentHash,
                kind: .image,
                displayName: "Second",
                localRelativePath: secondSlot.candidateRelativePath
            )
        )
        let pair = try await (first, second)
        #expect(pair.0.id == pair.1.id)
        #expect(try await store.asset(id: pair.0.id)?.referenceCount == 2)

        try await store.finalizeGeneratedAssetReservationBatch(id: firstBatch)
        _ = try await store.abandonGeneratedAssetReservationBatch(id: secondBatch)
        #expect(try await store.asset(id: pair.0.id)?.referenceCount == 1)
        // Both terminal operations are idempotent and cannot consume the
        // committed batch's live reference.
        try await store.finalizeGeneratedAssetReservationBatch(id: firstBatch)
        _ = try await store.abandonGeneratedAssetReservationBatch(id: secondBatch)
        #expect(try await store.asset(id: pair.0.id)?.referenceCount == 1)
    }

    @Test func pendingReservationSurvivesServiceRecreationBeforeCanvasCommit() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let firstStore = CreativeAssetStore(database: database)
        let batchID = UUID()
        let slot = GeneratedAssetReservationSlotDraft(
            index: 0, resultNodeID: UUID(), candidateAssetID: UUID(),
            contentHash: "restart-before-canvas",
            candidateRelativePath: "Materials/restart-before.png"
        )
        try await firstStore.beginGeneratedAssetReservationBatch(
            id: batchID, canvasID: UUID(), documentID: UUID(),
            configurationNodeID: UUID(), generationAttemptID: "restart-before",
            slots: [slot]
        )
        let asset = try await firstStore.reserveGeneratedAsset(
            batchID: batchID,
            slotIndex: 0,
            candidate: CreativeAssetRecord(
                id: slot.candidateAssetID, contentHash: slot.contentHash,
                kind: .image, displayName: "Restart before",
                localRelativePath: slot.candidateRelativePath
            )
        )

        // A new store has no process-local claim state, but sees the durable
        // owner and can release it after Canvas recovery proves no commit.
        let restartedStore = CreativeAssetStore(database: database)
        #expect(try await restartedStore
            .pendingGeneratedAssetReservationBatches().map(\.id) == [batchID])
        _ = try await restartedStore
            .abandonGeneratedAssetReservationBatch(id: batchID)
        #expect(try await restartedStore.asset(id: asset.id) == nil)
    }

    @Test func pendingReservationCanFinalizeAfterCanvasCommitAndServiceRecreation() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let firstStore = CreativeAssetStore(database: database)
        let batchID = UUID()
        let slot = GeneratedAssetReservationSlotDraft(
            index: 0, resultNodeID: UUID(), candidateAssetID: UUID(),
            contentHash: "restart-after-canvas",
            candidateRelativePath: "Materials/restart-after.png"
        )
        try await firstStore.beginGeneratedAssetReservationBatch(
            id: batchID, canvasID: UUID(), documentID: UUID(),
            configurationNodeID: UUID(), generationAttemptID: "restart-after",
            slots: [slot]
        )
        let asset = try await firstStore.reserveGeneratedAsset(
            batchID: batchID,
            slotIndex: 0,
            candidate: CreativeAssetRecord(
                id: slot.candidateAssetID, contentHash: slot.contentHash,
                kind: .image, displayName: "Restart after",
                localRelativePath: slot.candidateRelativePath
            )
        )

        let restartedStore = CreativeAssetStore(database: database)
        try await restartedStore
            .finalizeGeneratedAssetReservationBatch(id: batchID)
        #expect(try await restartedStore.asset(id: asset.id)?.referenceCount == 1)
        let finalized = try #require(
            await restartedStore.generatedAssetReservationBatch(id: batchID)
        )
        #expect(finalized.state == .committed)
        #expect(try await restartedStore.pendingGeneratedAssetReservationBatches().isEmpty)
    }

    @Test func creatorFirstReverseAbandonDeletesSharedGeneratedCanonical() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CreativeAssetStore(database: database)
        let creatorBatch = UUID(), followerBatch = UUID()
        let creator = GeneratedAssetReservationSlotDraft(
            index: 0, resultNodeID: UUID(), candidateAssetID: UUID(),
            contentHash: "reverse-abandon-shared-generated",
            candidateRelativePath: "Materials/reverse-creator.png"
        )
        let follower = GeneratedAssetReservationSlotDraft(
            index: 0, resultNodeID: UUID(), candidateAssetID: UUID(),
            contentHash: creator.contentHash,
            candidateRelativePath: "Materials/reverse-follower.png"
        )
        for pair in [(creatorBatch, creator), (followerBatch, follower)] {
            try await store.beginGeneratedAssetReservationBatch(
                id: pair.0, canvasID: UUID(), documentID: UUID(),
                configurationNodeID: UUID(),
                generationAttemptID: "reverse-\(pair.0.uuidString)",
                slots: [pair.1]
            )
        }
        let canonical = try await store.reserveGeneratedAsset(
            batchID: creatorBatch,
            slotIndex: 0,
            candidate: CreativeAssetRecord(
                id: creator.candidateAssetID,
                contentHash: creator.contentHash,
                kind: .image,
                displayName: "Creator",
                localRelativePath: creator.candidateRelativePath
            )
        )
        let reused = try await store.reserveGeneratedAsset(
            batchID: followerBatch,
            slotIndex: 0,
            candidate: CreativeAssetRecord(
                id: follower.candidateAssetID,
                contentHash: follower.contentHash,
                kind: .image,
                displayName: "Follower",
                localRelativePath: follower.candidateRelativePath
            )
        )
        #expect(reused.id == canonical.id)
        #expect(try await store.asset(id: canonical.id)?.referenceCount == 2)

        let creatorAbandon = try await store
            .abandonGeneratedAssetReservationBatch(id: creatorBatch)
        #expect(creatorAbandon.deletedLocalRelativePaths.isEmpty)
        #expect(try await store.asset(id: canonical.id)?.referenceCount == 1)
        let followerAbandon = try await store
            .abandonGeneratedAssetReservationBatch(id: followerBatch)
        #expect(followerAbandon.deletedLocalRelativePaths
            == [creator.candidateRelativePath])
        #expect(try await store.asset(id: canonical.id) == nil)
        #expect(try await store
            .abandonGeneratedAssetReservationBatch(id: followerBatch)
            .deletedLocalRelativePaths.isEmpty)
    }

    @Test func abandonNeverDeletesPreexistingCanonical() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CreativeAssetStore(database: database)
        let existing = CreativeAssetRecord(
            id: UUID(), contentHash: "preexisting-before-reservation",
            kind: .image, displayName: "User asset",
            localRelativePath: "Materials/user-existing.png"
        )
        try await store.save(existing)
        let batchID = UUID()
        let slot = GeneratedAssetReservationSlotDraft(
            index: 0, resultNodeID: UUID(), candidateAssetID: UUID(),
            contentHash: existing.contentHash,
            candidateRelativePath: "Materials/generated-duplicate.png"
        )
        try await store.beginGeneratedAssetReservationBatch(
            id: batchID, canvasID: UUID(), documentID: UUID(),
            configurationNodeID: UUID(), generationAttemptID: "preexisting",
            slots: [slot]
        )
        let canonical = try await store.reserveGeneratedAsset(
            batchID: batchID,
            slotIndex: 0,
            candidate: CreativeAssetRecord(
                id: slot.candidateAssetID, contentHash: slot.contentHash,
                kind: .image, displayName: "Duplicate",
                localRelativePath: slot.candidateRelativePath
            )
        )
        #expect(canonical.id == existing.id)
        let abandonment = try await store
            .abandonGeneratedAssetReservationBatch(id: batchID)
        #expect(abandonment.deletedLocalRelativePaths.isEmpty)
        #expect(try await store.asset(id: existing.id)?.referenceCount == 0)
        #expect(try await store.asset(id: existing.id)?.localRelativePath
            == existing.localRelativePath)
    }

    @Test func abandonNeverDeletesCanonicalWithCommittedReservationHistory() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = CreativeAssetStore(database: database)
        let committedBatch = UUID(), laterBatch = UUID()
        let committedSlot = GeneratedAssetReservationSlotDraft(
            index: 0, resultNodeID: UUID(), candidateAssetID: UUID(),
            contentHash: "ever-committed-generated",
            candidateRelativePath: "Materials/ever-committed.png"
        )
        try await store.beginGeneratedAssetReservationBatch(
            id: committedBatch, canvasID: UUID(), documentID: UUID(),
            configurationNodeID: UUID(), generationAttemptID: "committed",
            slots: [committedSlot]
        )
        let canonical = try await store.reserveGeneratedAsset(
            batchID: committedBatch,
            slotIndex: 0,
            candidate: CreativeAssetRecord(
                id: committedSlot.candidateAssetID,
                contentHash: committedSlot.contentHash,
                kind: .image,
                displayName: "Committed",
                localRelativePath: committedSlot.candidateRelativePath
            )
        )
        try await store.finalizeGeneratedAssetReservationBatch(id: committedBatch)
        try await store.adjustReference(assetID: canonical.id, by: -1)

        let laterSlot = GeneratedAssetReservationSlotDraft(
            index: 0, resultNodeID: UUID(), candidateAssetID: UUID(),
            contentHash: committedSlot.contentHash,
            candidateRelativePath: "Materials/later-duplicate.png"
        )
        try await store.beginGeneratedAssetReservationBatch(
            id: laterBatch, canvasID: UUID(), documentID: UUID(),
            configurationNodeID: UUID(), generationAttemptID: "later",
            slots: [laterSlot]
        )
        _ = try await store.reserveGeneratedAsset(
            batchID: laterBatch,
            slotIndex: 0,
            candidate: CreativeAssetRecord(
                id: laterSlot.candidateAssetID,
                contentHash: laterSlot.contentHash,
                kind: .image,
                displayName: "Later duplicate",
                localRelativePath: laterSlot.candidateRelativePath
            )
        )
        let abandonment = try await store
            .abandonGeneratedAssetReservationBatch(id: laterBatch)
        #expect(abandonment.deletedLocalRelativePaths.isEmpty)
        #expect(try await store.asset(id: canonical.id)?.referenceCount == 0)
        #expect(try await store.asset(id: canonical.id)?.localRelativePath
            == committedSlot.candidateRelativePath)
    }
}
