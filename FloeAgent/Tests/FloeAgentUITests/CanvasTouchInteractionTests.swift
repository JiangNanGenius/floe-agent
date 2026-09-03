#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp
@testable import FloeCore
import FloePersistence

private actor GeneratedAssetReservationBeginTestGate {
    private var began = false
    private var beginWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspendBegin() async {
        began = true
        let waiters = beginWaiters
        beginWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilBeginSuspends() async {
        guard !began else { return }
        await withCheckedContinuation { continuation in
            beginWaiters.append(continuation)
        }
    }

    func releaseBegin() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

@Suite("FloeApp.CanvasTouchInteraction")
struct CanvasTouchInteractionTests {
    @Test("Pinch zoom keeps the content under the gesture centroid fixed")
    func anchorPreservingZoom() {
        let anchor = CGPoint(x: 420, y: 260)
        let initial = CanvasViewportTransform(
            scale: 0.8,
            pan: CGSize(width: -130, height: 75)
        )
        let contentBefore = CGPoint(
            x: (anchor.x - initial.pan.width) / CGFloat(initial.scale),
            y: (anchor.y - initial.pan.height) / CGFloat(initial.scale)
        )

        let zoomed = initial.zoomed(by: 1.75, around: anchor)
        let contentAfter = CGPoint(
            x: (anchor.x - zoomed.pan.width) / CGFloat(zoomed.scale),
            y: (anchor.y - zoomed.pan.height) / CGFloat(zoomed.scale)
        )

        #expect(abs(contentAfter.x - contentBefore.x) < 0.0001)
        #expect(abs(contentAfter.y - contentBefore.y) < 0.0001)
    }

    @Test("Repeated pinch updates clamp without shifting the anchor")
    func zoomLimits() {
        let anchor = CGPoint(x: 180, y: 120)
        let initial = CanvasViewportTransform(
            scale: 1,
            pan: CGSize(width: 20, height: -40)
        )

        let maximum = initial.zoomed(by: 20, around: anchor)
        let minimum = maximum.zoomed(by: 0.001, around: anchor)

        #expect(maximum.scale == 3)
        #expect(minimum.scale == 0.3)
        let point = CGPoint(
            x: (anchor.x - initial.pan.width) / CGFloat(initial.scale),
            y: (anchor.y - initial.pan.height) / CGFloat(initial.scale)
        )
        #expect(abs((anchor.x - minimum.pan.width) / CGFloat(minimum.scale) - point.x) < 0.0001)
        #expect(abs((anchor.y - minimum.pan.height) / CGFloat(minimum.scale) - point.y) < 0.0001)
    }

    @Test("Two-finger pan applies incremental translation")
    func incrementalPan() {
        let initial = CanvasViewportTransform(
            scale: 1.25,
            pan: CGSize(width: -20, height: 50)
        )
        let moved = initial
            .panned(by: CGSize(width: 18, height: -6))
            .panned(by: CGSize(width: -3, height: 11))

        #expect(moved.scale == initial.scale)
        #expect(moved.pan == CGSize(width: -5, height: 55))
    }
}

@Suite("FloeApp saved image batch atomicity")
struct CanvasSavedImageBatchAtomicityTests {
    @Test("Reservation stays active while durable begin is suspended")
    @MainActor
    func reservationActivityCoversActorReentrantBegin() async throws {
        let activity = GeneratedAssetReservationActivityRegistry()
        let reservationID = UUID()
        let gate = GeneratedAssetReservationBeginTestGate()
        let begin = Task { @MainActor in
            try await activity.begin(id: reservationID) {
                await gate.suspendBegin()
            }
        }

        await gate.waitUntilBeginSuspends()
        #expect(!activity.shouldReconcile(id: reservationID))
        await gate.releaseBegin()
        try await begin.value
        // Successful persistence keeps the guard through the later Canvas
        // commit; only finalize/abandon is allowed to release it.
        #expect(!activity.shouldReconcile(id: reservationID))
        activity.finish(id: reservationID)
        #expect(activity.shouldReconcile(id: reservationID))

        enum SimulatedBeginFailure: Error { case failed }
        await #expect(throws: SimulatedBeginFailure.self) {
            try await activity.begin(id: reservationID) {
                throw SimulatedBeginFailure.failed
            }
        }
        #expect(activity.shouldReconcile(id: reservationID))
    }

    @Test("Provider image count is exact before persistence")
    func exactProviderCardinality() throws {
        let images = (0..<4).map { Data([UInt8($0)]) }

        #expect(try MediaGenerationImageBatchContract.validatedImages(
            images,
            requestedOutputCount: 4
        ) == images)
        #expect(throws: FloeError.self) {
            _ = try MediaGenerationImageBatchContract.validatedImages(
                Array(images.prefix(3)),
                requestedOutputCount: 4
            )
        }
        #expect(throws: FloeError.self) {
            _ = try MediaGenerationImageBatchContract.validatedImages(
                images + [Data([0xFF])],
                requestedOutputCount: 4
            )
        }
    }

    @Test("Repeated image bytes reuse the canonical asset row id")
    func canonicalAssetIDIsReused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "floe-canonical-asset-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let relativePath = "Materials/existing.png"
        let localURL = root.appendingPathComponent("FloeAgent/\(relativePath)")
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: localURL)
        let canonicalID = UUID()
        let record = CreativeAssetRecord(
            id: canonicalID,
            contentHash: "same-image-bytes",
            kind: .image,
            displayName: "Existing",
            mimeType: "image/png",
            localRelativePath: relativePath,
            byteCount: 4,
            referenceCount: 2
        )

        let reference = try #require(
            MediaGenerationAssetReusePolicy.localReferenceIfAvailable(
                for: record,
                applicationSupportRoot: root
            )
        )
        #expect(reference.id == canonicalID)
        #expect(reference.contentHash == record.contentHash)
        #expect(reference.localRelativePath == relativePath)

        var traversal = record
        traversal.localRelativePath = "../outside.png"
        #expect(MediaGenerationAssetReusePolicy.localReferenceIfAvailable(
            for: traversal,
            applicationSupportRoot: root
        ) == nil)

        let throwawayCandidateID = UUID()
        #expect(throwawayCandidateID != canonicalID)
        let throwawayPath = MediaGenerationAssetReusePolicy.generatedRelativePath(
            assetID: throwawayCandidateID,
            isPNG: true
        )
        var missingCanonical = record
        missingCanonical.localRelativePath = throwawayPath
        #expect(MediaGenerationAssetReusePolicy.usesThrowawayCandidatePath(
            record: missingCanonical,
            candidateID: throwawayCandidateID,
            candidateRelativePath: throwawayPath
        ))
        let repairedPath = MediaGenerationAssetReusePolicy.generatedRelativePath(
            assetID: canonicalID,
            isPNG: true
        )
        #expect(repairedPath.hasPrefix("Materials/\(canonicalID.uuidString)"))
        #expect(!repairedPath.contains(throwawayCandidateID.uuidString))
    }

    @Test("Material library resolves database identity from stored path first")
    func materialLibraryPathIndex() throws {
        let canonicalID = UUID()
        let cloudStyleURL = URL(fileURLWithPath: "/tmp/cloud-downloaded-name.png")
        let record = CreativeAssetRecord(
            id: canonicalID,
            contentHash: "cloud-path-index",
            kind: .image,
            displayName: "Cloud material",
            localRelativePath: "Materials/cloud-downloaded-name.png"
        )
        let index = CanvasMaterialAssetRecordIndex(records: [record])

        #expect(index.record(for: cloudStyleURL)?.id == canonicalID)

        let legacyID = UUID()
        let legacyURL = URL(
            fileURLWithPath: "/tmp/\(legacyID.uuidString)-legacy.png"
        )
        let legacy = CreativeAssetRecord(
            id: legacyID,
            contentHash: "legacy-filename-index",
            kind: .image,
            displayName: "Legacy"
        )
        #expect(CanvasMaterialAssetRecordIndex(records: [legacy])
            .record(for: legacyURL)?.id == legacyID)
    }

    @Test("Interleaved requests cannot delete another request's provisional asset")
    func interleavedProvisionalClaims() {
        let assetID = UUID()
        let contentHash = "shared-output-hash"
        let preexistingHash = "preexisting-output-hash"
        var claims = ProvisionalGeneratedAssetClaims()

        // Requests A and B register the hash before either persistence await.
        claims.registerReturnedHashes([contentHash])
        claims.registerReturnedHashes([contentHash])
        claims.bindCanonicalAsset(
            contentHash: contentHash,
            assetID: assetID,
            wasInserted: true
        )
        #expect(claims.pendingClaims[contentHash] == 2)

        let requestBDeletion = claims.resolveReturnedHashes(
            [contentHash],
            deleteWhenUnclaimed: true
        )
        #expect(requestBDeletion.isEmpty)
        #expect(claims.pendingClaims[contentHash] == 1)

        let requestAClaim = claims.resolveReturnedHashes(
            [contentHash],
            deleteWhenUnclaimed: false
        )
        #expect(requestAClaim.isEmpty)
        #expect(claims.pendingClaims[contentHash] == nil)

        // The inverse completion order is the dangerous one: the file-backed
        // canvas commit can happen before its detached reference-count update.
        // Once A commits, B abandoning the final pending claim must not delete.
        claims.registerReturnedHashes([contentHash, contentHash])
        claims.bindCanonicalAsset(
            contentHash: contentHash,
            assetID: assetID,
            wasInserted: true
        )
        #expect(claims.resolveReturnedHashes(
            [contentHash],
            deleteWhenUnclaimed: false
        ).isEmpty)
        #expect(claims.pendingClaims[contentHash] == 1)
        #expect(claims.resolveReturnedHashes(
            [contentHash],
            deleteWhenUnclaimed: true
        ).isEmpty)
        #expect(claims.pendingClaims[contentHash] == nil)

        // If both requests abandon instead, only the second resolution may
        // hand the canonical row to safe deletion.
        claims.registerReturnedHashes([contentHash, contentHash])
        claims.bindCanonicalAsset(
            contentHash: contentHash,
            assetID: assetID,
            wasInserted: true
        )
        #expect(claims.resolveReturnedHashes(
            [contentHash],
            deleteWhenUnclaimed: true
        ).isEmpty)
        #expect(claims.resolveReturnedHashes(
            [contentHash],
            deleteWhenUnclaimed: true
        ) == Set([assetID]))

        // A canonical row that predated this service is never cleanup-owned.
        claims.registerReturnedHashes([preexistingHash])
        claims.bindCanonicalAsset(
            contentHash: preexistingHash,
            assetID: UUID(),
            wasInserted: false
        )
        #expect(claims.resolveReturnedHashes(
            [preexistingHash],
            deleteWhenUnclaimed: true
        ).isEmpty)

        // A four-output provider response may fail during the persistence
        // loop after reserving only the first two duplicate outputs. All four
        // registered claims still resolve, while the caller separately
        // releases exactly the two established DB reservations.
        let partialHash = "partial-loop-duplicate-hash"
        let partialAssetID = UUID()
        let returnedHashes = Array(repeating: partialHash, count: 4)
        claims.registerReturnedHashes(returnedHashes)
        claims.bindCanonicalAsset(
            contentHash: partialHash,
            assetID: partialAssetID,
            wasInserted: true
        )
        claims.bindCanonicalAsset(
            contentHash: partialHash,
            assetID: partialAssetID,
            wasInserted: false
        )
        #expect(claims.pendingClaims[partialHash] == 4)
        #expect(claims.resolveReturnedHashes(
            returnedHashes,
            deleteWhenUnclaimed: true
        ) == Set([partialAssetID]))
        #expect(claims.pendingClaims[partialHash] == nil)
    }

    @Test("Four saved images publish through one complete canvas patch")
    func fourImageCommitPlanIsComplete() throws {
        let taskID = UUID()
        let resultIDs = (0..<4).map { _ in UUID() }
        let actualSourceIDs = [UUID(), UUID()]
        let staleSourceID = UUID()
        let attemptID = "atomic-four-image-attempt"
        let groupID = UUID()
        let configuration = CanvasGenerationConfiguration(
            kind: .image,
            prompt: "基于参考图生成四张",
            modelID: nil,
            aspectRatio: "16:9",
            resolution: "2K",
            quality: nil,
            count: 4,
            sourceNodeIDs: [staleSourceID]
        )
        let assets = (0..<4).map { index in
            CanvasAssetReference(
                contentHash: "atomic-result-\(index)",
                localRelativePath: "Materials/atomic-result-\(index).png",
                mimeType: "image/png",
                byteCount: Int64(index + 1)
            )
        }
        let plan = try CanvasSavedImageBatchCommitPlanner.plan(
            configurationNodeID: taskID,
            preparedResultNodeIDs: resultIDs,
            assets: assets,
            configuration: configuration,
            sourceNodeIDs: actualSourceIDs,
            generationAttemptID: attemptID,
            groupID: groupID
        )

        #expect(plan.resultNodeIDs == resultIDs)
        #expect(plan.sourceNodeIDs == actualSourceIDs)
        #expect(plan.groupID == groupID)
        #expect(plan.operations.count == 6)
        let resultUpdates = plan.operations.filter {
            $0.kind == .update && $0.nodeID.map(Set(resultIDs).contains) == true
        }
        #expect(resultUpdates.count == 4)
        #expect(resultUpdates.allSatisfy {
            $0.asset != nil
                && $0.metadata?["generationState"] == CanvasGenerationTaskState.ready.rawValue
                && $0.metadata?["generationAttemptID"] == attemptID
                && $0.metadata?["generationSourceNodeIDs"]
                    == actualSourceIDs.map(\.uuidString).joined(separator: ",")
        })
        #expect(!resultUpdates.contains {
            $0.metadata?["generationSourceNodeIDs"] == staleSourceID.uuidString
        })
        let group = try #require(plan.operations.first { $0.kind == .group })
        #expect(group.nodeID == groupID)
        #expect(group.nodeIDs == resultIDs)
        let taskUpdate = try #require(plan.operations.first {
            $0.kind == .update && $0.nodeID == taskID
        })
        #expect(taskUpdate.metadata?["generationState"]
            == CanvasGenerationTaskState.ready.rawValue)
        #expect(taskUpdate.metadata?["generationResultNodeIDs"]
            == resultIDs.map(\.uuidString).joined(separator: ","))
        #expect(taskUpdate.metadata?["generationGroupID"] == groupID.uuidString)
    }

    @Test("Generation source connection commands keep metadata canonical and never revive deletions")
    func generationConfigurationOpenPreservesSourcesAndResults() throws {
        let source = CanvasNode(
            kind: .image,
            position: .init(x: 40, y: 120),
            size: .init(width: 240, height: 180),
            metadata: ["generationPrompt": "Golden mountain reference"]
        )
        let secondSource = CanvasNode(
            kind: .image,
            position: .init(x: 40, y: 420),
            size: .init(width: 240, height: 180),
            metadata: ["generationPrompt": "Misty valley reference"]
        )
        let task = CanvasNode(
            kind: .generationTask,
            text: "图片生成",
            position: .init(x: 420, y: 120),
            size: .init(width: 340, height: 210),
            metadata: CanvasGenerationConfiguration(
                kind: .image,
                prompt: "Generate four variants",
                modelID: nil,
                aspectRatio: "16:9",
                count: 4,
                sourceNodeIDs: [source.id]
            ).metadata
        )
        let results = (0..<4).map { index in
            CanvasNode(
                kind: .image,
                text: "Result \(index + 1)",
                position: .init(x: 860, y: Double(index) * 280),
                size: .init(width: 320, height: 260)
            )
        }
        let document = CanvasDocument(
            name: "Canvas",
            nodes: [source, secondSource, task] + results,
            connections: [
                CanvasConnection(
                    sourceNodeID: source.id,
                    destinationNodeID: task.id,
                    kind: .source
                )
            ] + results.map {
                CanvasConnection(
                    sourceNodeID: task.id,
                    destinationNodeID: $0.id,
                    kind: .generatedFrom
                )
            }
        )
        let presentation = CanvasGenerationConfigurationPresentation.opening(
            nodeID: results[0].id,
            configurationNodeID: task.id
        )
        #expect(presentation.selectedNodeIDs == Set([task.id, results[0].id]))
        #expect(presentation.requestedSourceNodeIDs == nil)
        #expect(CanvasGenerationConfigurationPresentation.referenceNodeIDs(
            selectedNodeIDs: presentation.selectedNodeIDs,
            configurationNodeID: task.id,
            document: document
        ) == Set([source.id]))

        let inherited = try CanvasGenerationContextResolver.resolvedNodeIDs(
            requestedIDs: presentation.requestedSourceNodeIDs.map(Array.init),
            configurationNodeID: task.id,
            document: document
        )
        #expect(inherited == [source.id])
        let unchangedPlan = try CanvasGenerationConfigurationPlanner.plan(
            kind: .image,
            prompt: "Generate four variants",
            sourceNodeIDs: inherited,
            position: task.position,
            existingConfigurationNodeID: task.id,
            metadata: task.metadata,
            document: document
        )
        var project = CanvasProject(
            id: UUID(),
            name: "Edit",
            documents: [document],
            selectedDocumentID: document.id
        )
        (project, _) = try CanvasCommandService.applying(
            CanvasPatch(
                canvasID: project.id,
                documentID: document.id,
                expectedRevision: project.revision,
                operations: unchangedPlan.operations
            ),
            to: project
        )
        var saved = try #require(project.documents.first)
        #expect(saved.connections.filter {
            $0.kind == .source && $0.destinationNodeID == task.id
        }.map(\.sourceNodeID) == [source.id])
        #expect(saved.connections.filter {
            $0.kind == .generatedFrom && $0.sourceNodeID == task.id
        }.count == 4)

        // A UI disconnect is an explicit source edit. Its command updates the
        // task fallback metadata in the same revision as the edge removal.
        let onlySourceConnection = try #require(saved.connections.first {
            $0.kind == .source
                && $0.sourceNodeID == source.id
                && $0.destinationNodeID == task.id
        })
        let disconnectOperations = try #require(
            CanvasConnectionCommandPlanner.disconnecting(
                onlySourceConnection.id,
                document: saved
            )
        )
        (project, _) = try CanvasCommandService.applying(
            CanvasPatch(
                canvasID: project.id,
                documentID: document.id,
                expectedRevision: project.revision,
                operations: disconnectOperations
            ),
            to: project
        )
        saved = try #require(project.documents.first)
        #expect(saved.nodes.first(where: { $0.id == task.id })?
            .metadata["generationSourceNodeIDs"] == "")
        #expect(!saved.connections.contains {
            $0.kind == .source && $0.destinationNodeID == task.id
        })

        // Reopening with nil means "not edited in this sheet". Because the
        // explicit disconnect cleared the fallback, saving cannot revive it.
        let reopened = CanvasGenerationConfigurationPresentation.opening(
            nodeID: results[0].id,
            configurationNodeID: task.id
        )
        let afterDisconnect = try CanvasGenerationContextResolver.resolvedNodeIDs(
            requestedIDs: reopened.requestedSourceNodeIDs.map(Array.init),
            configurationNodeID: task.id,
            document: saved
        )
        #expect(afterDisconnect.isEmpty)
        let noRevivalPlan = try CanvasGenerationConfigurationPlanner.plan(
            kind: .image,
            prompt: "Generate four variants",
            sourceNodeIDs: afterDisconnect,
            position: task.position,
            existingConfigurationNodeID: task.id,
            metadata: try #require(saved.nodes.first(where: { $0.id == task.id }))
                .metadata,
            document: saved
        )
        (project, _) = try CanvasCommandService.applying(
            CanvasPatch(
                canvasID: project.id,
                documentID: document.id,
                expectedRevision: project.revision,
                operations: noRevivalPlan.operations
            ),
            to: project
        )
        saved = try #require(project.documents.first)
        #expect(!saved.connections.contains {
            $0.kind == .source && $0.destinationNodeID == task.id
        })
        #expect(saved.connections.filter {
            $0.kind == .generatedFrom && $0.sourceNodeID == task.id
        }.count == 4)

        // The connector UI requests an ordinary arrow. A generation-task
        // destination canonicalizes it to an explicit source edge and updates
        // metadata atomically.
        let connectFirst = try #require(CanvasConnectionCommandPlanner.connecting(
            source.id,
            to: task.id,
            requestedKind: .arrow,
            sourcePort: .trailing,
            destinationPort: .leading,
            document: saved
        ))
        #expect(connectFirst.first?.connectionKind == .source)
        (project, _) = try CanvasCommandService.applying(
            CanvasPatch(
                canvasID: project.id,
                documentID: document.id,
                expectedRevision: project.revision,
                operations: connectFirst
            ),
            to: project
        )
        saved = try #require(project.documents.first)
        let connectSecond = try #require(CanvasConnectionCommandPlanner.connecting(
            secondSource.id,
            to: task.id,
            requestedKind: .source,
            sourcePort: .trailing,
            destinationPort: .leading,
            document: saved
        ))
        (project, _) = try CanvasCommandService.applying(
            CanvasPatch(
                canvasID: project.id,
                documentID: document.id,
                expectedRevision: project.revision,
                operations: connectSecond
            ),
            to: project
        )
        saved = try #require(project.documents.first)
        let bothSources = [source.id, secondSource.id]
            .sorted { $0.uuidString < $1.uuidString }
        #expect(saved.connections.filter {
            $0.kind == .source && $0.destinationNodeID == task.id
        }.map(\.sourceNodeID).sorted { $0.uuidString < $1.uuidString } == bothSources)
        #expect(saved.nodes.first(where: { $0.id == task.id })?
            .metadata["generationSourceNodeIDs"]
            == bothSources.map(\.uuidString).joined(separator: ","))

        // Removing one of multiple inputs retains only the actual remaining
        // incoming source in both edge topology and fallback metadata.
        let firstOfTwo = try #require(saved.connections.first {
            $0.kind == .source
                && $0.sourceNodeID == source.id
                && $0.destinationNodeID == task.id
        })
        let removeFirst = try #require(CanvasConnectionCommandPlanner.disconnecting(
            firstOfTwo.id,
            document: saved
        ))
        (project, _) = try CanvasCommandService.applying(
            CanvasPatch(
                canvasID: project.id,
                documentID: document.id,
                expectedRevision: project.revision,
                operations: removeFirst
            ),
            to: project
        )
        saved = try #require(project.documents.first)
        #expect(saved.connections.filter {
            $0.kind == .source && $0.destinationNodeID == task.id
        }.map(\.sourceNodeID) == [secondSource.id])
        #expect(saved.nodes.first(where: { $0.id == task.id })?
            .metadata["generationSourceNodeIDs"] == secondSource.id.uuidString)

        // Reverse preserves the typed relationship, but the generation task
        // is no longer its destination; therefore its canonical inputs empty.
        let remaining = try #require(saved.connections.first {
            $0.kind == .source
                && $0.sourceNodeID == secondSource.id
                && $0.destinationNodeID == task.id
        })
        let reverse = try #require(CanvasConnectionCommandPlanner.reversing(
            remaining.id,
            document: saved
        ))
        (project, _) = try CanvasCommandService.applying(
            CanvasPatch(
                canvasID: project.id,
                documentID: document.id,
                expectedRevision: project.revision,
                operations: reverse
            ),
            to: project
        )
        saved = try #require(project.documents.first)
        #expect(saved.connections.contains {
            $0.id == remaining.id
                && $0.kind == .source
                && $0.sourceNodeID == task.id
                && $0.destinationNodeID == secondSource.id
                && $0.sourcePort == .leading
                && $0.destinationPort == .trailing
        })
        #expect(!saved.connections.contains {
            $0.kind == .source && $0.destinationNodeID == task.id
        })
        #expect(saved.nodes.first(where: { $0.id == task.id })?
            .metadata["generationSourceNodeIDs"] == "")
        #expect(saved.connections.filter {
            $0.kind == .generatedFrom && $0.sourceNodeID == task.id
        }.count == 4)
    }

    @Test("Failure and cancellation update the whole graph in one operation list")
    func terminalStatePlansCoverEveryNode() {
        let nodeIDs = (0..<5).map { _ in UUID() }
        let failure = CanvasGenerationStatePatchPlanner.operations(
            state: .failed,
            nodeIDs: nodeIDs,
            error: "provider returned only three images"
        )
        let cancelledAttemptID = "cancelled-attempt"
        let cancellation = CanvasGenerationCancellationPlanner.operations(
            nodeIDs: nodeIDs + [nodeIDs[0]],
            cancelledAttemptID: cancelledAttemptID
        )

        #expect(failure.count == 5)
        #expect(Set(failure.compactMap(\.nodeID)) == Set(nodeIDs))
        #expect(failure.allSatisfy {
            $0.metadata?["generationState"] == CanvasGenerationTaskState.failed.rawValue
                && $0.metadata?["generationError"] == "provider returned only three images"
        })
        #expect(cancellation.count == 5)
        #expect(Set(cancellation.compactMap(\.nodeID)) == Set(nodeIDs))
        #expect(cancellation.allSatisfy {
            $0.metadata?["generationState"] == CanvasGenerationTaskState.cancelled.rawValue
                && $0.metadata?["generationError"] == ""
                && $0.metadata?["generationErrorDetail"] == ""
                && $0.metadata?["generationAttemptID"] == cancelledAttemptID
        })
    }

    @Test("Reservation recovery finalizes only a complete exact Canvas commit")
    func generatedReservationRecoveryRequiresEveryExactSlot() {
        let canvasID = UUID(), documentID = UUID(), configurationID = UUID()
        let attemptID = "recovered-four-image-attempt"
        let assetIDs = (0..<4).map { _ in UUID() }
        let resultIDs = (0..<4).map { _ in UUID() }
        let slots = (0..<4).map { index in
            GeneratedAssetReservationSlotRecord(
                index: index,
                resultNodeID: resultIDs[index],
                candidateAssetID: assetIDs[index],
                contentHash: "recovery-\(index)",
                candidateRelativePath: "Materials/recovery-\(index).png",
                canonicalAssetID: assetIDs[index],
                wasInserted: true,
                state: .reserved
            )
        }
        let batch = GeneratedAssetReservationBatchRecord(
            id: UUID(), canvasID: canvasID, documentID: documentID,
            configurationNodeID: configurationID,
            generationAttemptID: attemptID, expectedCount: 4,
            state: .reserved, slots: slots,
            createdAt: Date(), updatedAt: Date()
        )
        let task = CanvasNode(
            id: configurationID,
            kind: .generationTask,
            text: "Generate four",
            position: .init(x: 0, y: 0),
            size: .init(width: 340, height: 210),
            metadata: [
                "generationAttemptID": attemptID,
                "generationState": CanvasGenerationTaskState.ready.rawValue
            ]
        )
        let results = (0..<4).map { index in
            CanvasNode(
                id: resultIDs[index],
                kind: .image,
                text: "Result \(index)",
                position: .init(x: 400, y: Double(index) * 280),
                size: .init(width: 320, height: 260),
                asset: CanvasAssetReference(id: assetIDs[index]),
                metadata: ["generationAttemptID": attemptID]
            )
        }
        let completeDocument = CanvasDocument(
            id: documentID,
            name: "Canvas",
            nodes: [task] + results
        )
        let complete = CanvasProject(
            id: canvasID,
            name: "Recovery",
            documents: [completeDocument],
            selectedDocumentID: documentID
        )
        #expect(GeneratedAssetReservationRecoveryPolicy.decision(
            batch: batch,
            project: complete
        ) == .finalize)

        var partial = complete
        partial.documents[0].nodes[2].asset = nil
        #expect(GeneratedAssetReservationRecoveryPolicy.decision(
            batch: batch,
            project: partial
        ) == .retain)

        var explicitlyUnpublished = complete
        for index in explicitlyUnpublished.documents[0].nodes.indices {
            if resultIDs.contains(explicitlyUnpublished.documents[0].nodes[index].id) {
                explicitlyUnpublished.documents[0].nodes[index].asset = nil
            }
        }
        explicitlyUnpublished.documents[0].nodes[0]
            .metadata["generationState"] = CanvasGenerationTaskState.running.rawValue
        #expect(GeneratedAssetReservationRecoveryPolicy.decision(
            batch: batch,
            project: explicitlyUnpublished
        ) == .abandon)

        var damagedReady = explicitlyUnpublished
        damagedReady.documents[0].nodes[0]
            .metadata["generationState"] = CanvasGenerationTaskState.ready.rawValue
        #expect(GeneratedAssetReservationRecoveryPolicy.decision(
            batch: batch,
            project: damagedReady
        ) == .retain)

        var confirmedDocumentRemoval = complete
        confirmedDocumentRemoval.documents.removeAll()
        #expect(GeneratedAssetReservationRecoveryPolicy.decision(
            batch: batch,
            project: confirmedDocumentRemoval
        ) == .abandon)

        var mismatchedProject = complete
        mismatchedProject.id = UUID()
        #expect(GeneratedAssetReservationRecoveryPolicy.decision(
            batch: batch,
            project: mismatchedProject
        ) == .retain)
    }
}
#endif
