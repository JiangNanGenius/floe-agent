// FloeAppTests — T6 durable creative generation boundary.
//
// The exact defect this locks down: the creative first-result path called the
// provider directly and bound a synthetic `generated-<digest>` id that could
// never be resolved back to a real creative asset. It now runs through the
// EXISTING durable media job pipeline:
//   confirmation (actual model/parameters/cost) → persistent job (written
//   before the provider call) → real content-addressed asset → ready job →
//   the SAME bindFirstResult with the actual asset UUID against the ORIGINAL
//   submission revision → reopen.
// Unknown submissions are never resent, a ready result binds without a second
// paid call, a manual edit during generation conflicts with the result
// retained for explicit resolution, stop-waiting keeps the unresolved receipt
// (it is not a provider cancellation), and an acknowledged discard warns
// about a possible duplicate charge.
//
// Provider calls are injected deterministic doubles; no paid call runs here.
// These execute in the FloeApp unit-test bundle (full App target, T7).

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeTools
import FloeProviders
@testable import FloeApp

private actor GenerationPerformCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

@Suite("T6 durable creative generation")
@MainActor
struct T6DurableGenerationTests {

    /// A minimal PNG-magic payload: the service sniffs the REAL encoded
    /// format from the bytes, and the bind stores/verifies the digest.
    private static func pngBytes() -> Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            + Data(repeating: 0x42, count: 32)
    }

    private func makeEnvironment() async throws -> AppEnvironment {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        return environment
    }

    /// A configured, enabled image route (provider + model + preference) so
    /// the real capability gate and route resolution are exercised.
    @discardableResult
    private func configureImageRoute(
        _ environment: AppEnvironment
    ) async throws -> (ProviderProfile, ModelProfile) {
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://image-double.example/v1")!,
            displayName: "Image Double")
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "image-double-1",
            displayName: "Image Double Model",
            limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
            pricing: PricingMetadata(
                inputPerMillion: Decimal(string: "0.5"),
                outputPerMillion: Decimal(string: "2"),
                currency: "USD"),
            capabilities: [.imageGeneration])
        try await environment.configurationStore.saveProvider(provider)
        try await environment.configurationStore.saveModel(model)
        var preferences = (try? await environment.configurationStore.preferences())
            ?? ModelSelectionPreferences()
        preferences.auxiliaryImageMode = .separate
        preferences.imageGenerationModelID = model.id
        try await environment.conversationCenter.saveModelPreferences(preferences)
        return (provider, model)
    }

    private func creativeTarget() -> DesignTarget {
        DesignTarget(
            kind: .creativeDocument,
            ownerID: "creative-library",
            documentID: "",
            sourceID: UUID().uuidString,
            requestedOutputKind: .image)
    }

    private func submission(
        target: DesignTarget,
        request: DesignCreativeRequest,
        provider: ProviderProfile,
        model: ModelProfile,
        frozenOwnerRevision: Int64
    ) -> DesignCreativeImageSubmission {
        DesignCreativeImageSubmission(
            targetStableKey: target.stableKey,
            ownerID: target.ownerID,
            requestID: target.sourceID,
            environmentID: nil,
            originConversationID: nil,
            originRunID: nil,
            owner: DesignOwnerWorkflowModel.mediaJobOwner(
                originConversationID: nil, targetStableKey: target.stableKey),
            providerID: provider.id,
            modelID: model.id,
            prompt: "A calm product hero",
            selection: ImageGenerationSelection(),
            displayNameStem: "hero",
            idempotencyKey: DesignOwnerWorkflowModel.generationIdempotencyKey(
                target: target, request: request),
            frozenOwnerRevision: frozenOwnerRevision)
    }

    private func removeOwnerState(_ target: DesignTarget) {
        guard let root = try? FloeArtifactStore.root() else { return }
        let url = root
            .appendingPathComponent("DesignRevisions", isDirectory: true)
            .appendingPathComponent("owners", isDirectory: true)
            .appendingPathComponent(target.stableKey, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }

    private func removeGeneratedFiles(_ records: [CreativeAssetRecord?]) {
        guard let root = try? FloeArtifactStore.root() else { return }
        for record in records {
            guard let relative = record?.localRelativePath, !relative.contains("..") else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(relative))
        }
    }

    // MARK: - Service boundary

    @Test("A double submission creates a durable job, a real asset row, and dedupes")
    func submissionPersistsJobAndRealAsset() async throws {
        let environment = try await makeEnvironment()
        let (provider, model) = try await configureImageRoute(environment)
        let workflow = environment.designOwnerWorkflow
        let target = creativeTarget()
        let begun = try await workflow.beginCreativeRequest(
            target: target, operationID: "t6-gen-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "A calm product hero"), runID: nil)
        defer { removeOwnerState(target) }
        let request = try #require(begun.envelope.project.creativeRequest)
        let submission = submission(
            target: target, request: request, provider: provider, model: model,
            frozenOwnerRevision: begun.envelope.revision)
        let counter = GenerationPerformCounter()

        let first = try await environment.mediaGenerationService.submitDesignCreativeImage(
            submission
        ) { _, _, _ in
            await counter.increment()
            return RemoteImageResult(images: [Self.pngBytes()])
        }
        #expect(first.deduplicated == false)
        #expect(first.job.state == .ready)
        let asset = try #require(first.asset)
        #expect(first.job.localAssetID == asset.id)
        #expect(asset.contentHash == FloeDigest.sha256Hex(Self.pngBytes()))
        #expect(asset.localRelativePath?.hasPrefix("Materials/") == true)
        defer { removeGeneratedFiles([asset]) }

        // The bytes are real and match the stored content hash.
        let root = try FloeArtifactStore.root()
        let relative = try #require(asset.localRelativePath)
        let stored = try Data(contentsOf: root.appendingPathComponent(relative))
        #expect(FloeDigest.sha256Hex(stored) == asset.contentHash)

        // Durable readback by the operation identity (reopen), including the
        // ORIGINAL submission revision.
        let store = MediaGenerationJobStore(database: environment.database)
        let reloaded = try #require(
            try await store.ownedJob(idempotencyKey: submission.idempotencyKey))
        #expect(reloaded.job.state == .ready)
        #expect(reloaded.job.localAssetID == asset.id)
        #expect(DesignOwnerWorkflowModel.generationOriginalRevision(
            from: reloaded.job.requestJSON) == begun.envelope.revision)

        // The SAME operation dedupes: no second provider call, same asset.
        let second = try await environment.mediaGenerationService.submitDesignCreativeImage(
            submission
        ) { _, _, _ in
            await counter.increment()
            return RemoteImageResult(images: [Self.pngBytes()])
        }
        #expect(second.deduplicated)
        #expect(second.asset?.id == asset.id)
        #expect(await counter.count == 1)
    }

    @Test("A transport failure leaves an unknown job that is never resubmitted")
    func unknownSubmissionIsNotResent() async throws {
        let environment = try await makeEnvironment()
        let (provider, model) = try await configureImageRoute(environment)
        let target = creativeTarget()
        let begun = try await environment.designOwnerWorkflow.beginCreativeRequest(
            target: target, operationID: "t6-gen-unknown-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Unknown outcome"), runID: nil)
        defer { removeOwnerState(target) }
        let request = try #require(begun.envelope.project.creativeRequest)
        let submission = submission(
            target: target, request: request, provider: provider, model: model,
            frozenOwnerRevision: begun.envelope.revision)
        let counter = GenerationPerformCounter()

        await #expect(throws: (any Error).self) {
            _ = try await environment.mediaGenerationService.submitDesignCreativeImage(
                submission
            ) { _, _, _ in
                await counter.increment()
                throw URLError(.timedOut)
            }
        }
        let store = MediaGenerationJobStore(database: environment.database)
        let unknown = try #require(
            try await store.ownedJob(idempotencyKey: submission.idempotencyKey))
        // No provider task id and no terminal state: the remote outcome is
        // UNKNOWN and must never be resubmitted automatically.
        #expect(unknown.job.state == .preparing)
        #expect(unknown.job.providerTaskID == nil)

        let second = try await environment.mediaGenerationService.submitDesignCreativeImage(
            submission
        ) { _, _, _ in
            await counter.increment()
            return RemoteImageResult(images: [Self.pngBytes()])
        }
        #expect(second.deduplicated)
        #expect(second.awaitingUnknownOutcome)
        #expect(second.asset == nil)
        #expect(await counter.count == 1)
    }

    // MARK: - Cancellation semantics

    @Test("Stop-waiting after dispatch keeps the unresolved receipt (never a provider cancel)")
    func cancellationAfterDispatchKeepsUnknown() async throws {
        let environment = try await makeEnvironment()
        let (provider, model) = try await configureImageRoute(environment)
        let target = creativeTarget()
        let begun = try await environment.designOwnerWorkflow.beginCreativeRequest(
            target: target, operationID: "t6-gen-stop-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Stop waiting"), runID: nil)
        defer { removeOwnerState(target) }
        let request = try #require(begun.envelope.project.creativeRequest)
        let submission = submission(
            target: target, request: request, provider: provider, model: model,
            frozenOwnerRevision: begun.envelope.revision)

        // The injected provider call reports cancellation AFTER dispatch.
        await #expect(throws: (any Error).self) {
            _ = try await environment.mediaGenerationService.submitDesignCreativeImage(
                submission
            ) { _, _, _ in
                throw CancellationError()
            }
        }
        let store = MediaGenerationJobStore(database: environment.database)
        let job = try #require(
            try await store.ownedJob(idempotencyKey: submission.idempotencyKey))
        // NOT cancelled: the request may already have reached the provider.
        #expect(job.job.state == .preparing)
        #expect(job.job.lastError == FloeL10n.l("design.owner.generate_stopped_unknown"))

        // A subsequent submission is suppressed as unknown (no resend).
        let second = try await environment.mediaGenerationService.submitDesignCreativeImage(
            submission
        ) { _, _, _ in
            Issue.record("the provider must not be called again")
            return RemoteImageResult(images: [Self.pngBytes()])
        }
        #expect(second.awaitingUnknownOutcome)
    }

    @Test("Cancellation before dispatch closes the job as cancelled")
    func preDispatchCancellationClosesJob() async throws {
        let environment = try await makeEnvironment()
        let (provider, model) = try await configureImageRoute(environment)
        let target = creativeTarget()
        let begun = try await environment.designOwnerWorkflow.beginCreativeRequest(
            target: target, operationID: "t6-gen-predispatch-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Cancel before dispatch"), runID: nil)
        defer { removeOwnerState(target) }
        let request = try #require(begun.envelope.project.creativeRequest)
        let submission = submission(
            target: target, request: request, provider: provider, model: model,
            frozenOwnerRevision: begun.envelope.revision)
        let counter = GenerationPerformCounter()

        let task = Task { @MainActor in
            try await environment.mediaGenerationService.submitDesignCreativeImage(
                submission
            ) { _, _, _ in
                await counter.increment()
                return RemoteImageResult(images: [Self.pngBytes()])
            }
        }
        task.cancel()
        _ = try? await task.value

        let store = MediaGenerationJobStore(database: environment.database)
        if let job = try? await store.ownedJob(
            idempotencyKey: submission.idempotencyKey) {
            // If the row was written before the pre-dispatch check, it is
            // closed as a definite local cancellation.
            #expect(job.job.state == .cancelled)
        }
        #expect(await counter.count == 0, "no provider dispatch before cancellation")
    }

    @Test("An acknowledged discard closes the local record with the honest reason")
    func acknowledgedDiscardClosesRecord() async throws {
        let environment = try await makeEnvironment()
        let (provider, model) = try await configureImageRoute(environment)
        let target = creativeTarget()
        let begun = try await environment.designOwnerWorkflow.beginCreativeRequest(
            target: target, operationID: "t6-gen-discard-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Discard"), runID: nil)
        defer { removeOwnerState(target) }
        let request = try #require(begun.envelope.project.creativeRequest)
        let submission = submission(
            target: target, request: request, provider: provider, model: model,
            frozenOwnerRevision: begun.envelope.revision)

        await #expect(throws: (any Error).self) {
            _ = try await environment.mediaGenerationService.submitDesignCreativeImage(
                submission
            ) { _, _, _ in
                throw URLError(.cannotConnectToHost)
            }
        }
        let store = MediaGenerationJobStore(database: environment.database)
        let job = try #require(
            try await store.ownedJob(idempotencyKey: submission.idempotencyKey))
        #expect(job.job.state == .preparing)

        try await environment.mediaGenerationService
            .discardUnknownDesignCreativeImage(jobID: job.job.id)
        let discarded = try #require(
            try await store.ownedJob(idempotencyKey: submission.idempotencyKey))
        #expect(discarded.job.state == .cancelled)
        // The record never claims a remote cancellation or refund.
        #expect(discarded.job.lastError == FloeL10n.l("design.owner.generate_discarded_unknown"))
    }

    // MARK: - Publication recovery

    @Test("A ready-transition failure after publish keeps the canonical asset readable")
    func readyTransitionFailurePreservesCanonicalAsset() async throws {
        let environment = try await makeEnvironment()
        let (provider, model) = try await configureImageRoute(environment)
        let target = creativeTarget()
        let begun = try await environment.designOwnerWorkflow.beginCreativeRequest(
            target: target, operationID: "t6-gen-late-fail-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Late transition failure"), runID: nil)
        defer { removeOwnerState(target) }
        let request = try #require(begun.envelope.project.creativeRequest)
        let submission = submission(
            target: target, request: request, provider: provider, model: model,
            frozenOwnerRevision: begun.envelope.revision)
        let digest = FloeDigest.sha256Hex(Self.pngBytes())
        let store = MediaGenerationJobStore(database: environment.database)

        // While the provider "runs", another actor closes the job. The ready
        // transition then fails AFTER the canonical row+file were published.
        await #expect(throws: (any Error).self) {
            _ = try await environment.mediaGenerationService.submitDesignCreativeImage(
                submission
            ) { _, _, _ in
                if let job = try? await store.ownedJob(
                    idempotencyKey: submission.idempotencyKey) {
                    _ = try? await store.transition(id: job.job.id, to: .cancelled)
                }
                return RemoteImageResult(images: [Self.pngBytes()])
            }
        }

        // The published asset row AND its file survived the failed transition.
        let canonical = try #require(
            try await environment.creativeAssetStore.asset(contentHash: digest))
        let relative = try #require(canonical.localRelativePath)
        let url = try FloeArtifactStore.root().appendingPathComponent(relative)
        #expect(FileManager.default.fileExists(atPath: url.path),
                "a committed canonical asset must never be deleted by the failure path")
        let stored = try Data(contentsOf: url)
        #expect(FloeDigest.sha256Hex(stored) == digest)
        defer { removeGeneratedFiles([canonical]) }
    }

    @Test("A published result whose ready transition failed reconciles to the SAME asset without a new call")
    func publishedResultWithFailedReadyTransitionReconcilesOnReopen() async throws {
        let environment = try await makeEnvironment()
        let (provider, model) = try await configureImageRoute(environment)
        let target = creativeTarget()
        let begun = try await environment.designOwnerWorkflow.beginCreativeRequest(
            target: target, operationID: "t7-recover-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Recover the same output"), runID: nil)
        defer { removeOwnerState(target) }
        let request = try #require(begun.envelope.project.creativeRequest)
        let key = DesignOwnerWorkflowModel.generationIdempotencyKey(
            target: target, request: request)
        let bytes = Self.pngBytes()
        let digest = FloeDigest.sha256Hex(bytes)
        // 1. The provider output was already published as a real canonical
        //    asset (row + file): exactly what the failed `.ready` transition
        //    leaves behind on disk.
        let root = try FloeArtifactStore.root()
        let relative = "Materials/T7B-recover-\(UUID().uuidString).png"
        let fileURL = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: fileURL, options: .atomic)
        let canonical = try await environment.creativeAssetStore.saveResolvingCanonical(
            CreativeAssetRecord(
                id: UUID(), contentHash: digest, kind: .image,
                displayName: "recovered.png", mimeType: "image/png",
                localRelativePath: relative, byteCount: Int64(bytes.count),
                tags: [], referenceCount: 0))
        defer { removeGeneratedFiles([canonical]) }
        // 2. The durable row is still unresolved but already names the asset
        //    (the failure path persists that association).
        let store = MediaGenerationJobStore(database: environment.database)
        let payload = try JSONEncoder().encode(DesignCreativeImageRequestPayload(
            targetStableKey: target.stableKey, ownerID: target.ownerID,
            requestID: target.sourceID, environmentID: nil,
            originConversationID: nil, providerID: provider.id, modelID: model.id,
            prompt: "Recover the same output", selection: ImageGenerationSelection(),
            frozenOwnerRevision: begun.envelope.revision))
        let job = MediaGenerationJob(
            providerID: provider.id, modelID: model.id, mediaKind: .image,
            credentialReference: nil, sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: payload, assetReferences: [canonical.id],
            state: .preparing, localAssetID: canonical.id)
        _ = try await store.createJob(
            job,
            owner: DesignOwnerWorkflowModel.mediaJobOwner(
                originConversationID: nil, targetStableKey: target.stableKey),
            originRunID: nil, idempotencyKey: key)

        // 3. A fresh panel reopen recovers the SAME asset and binds it — no
        //    second paid call, no lost association.
        let model_ = DesignOwnerWorkflowModel(target: target, environment: environment)
        await model_.reload()
        #expect(model_.generationAvailable)
        model_.requestGenerationConfirmation()
        #expect(model_.generationConfirmation != nil)
        await model_.confirmGeneration()
        #expect(model_.errorMessage == nil)
        #expect(model_.project?.creativeRequest?.state == .firstResultBound)
        #expect(model_.project?.creativeRequest?.boundResultID == canonical.id.uuidString)

        // 4. The durable record is repaired to `.ready` with the same asset.
        let repaired = try #require(try await store.ownedJob(idempotencyKey: key))
        #expect(repaired.job.state == .ready)
        #expect(repaired.job.localAssetID == canonical.id)

        // 5. The service reconcile entry returns the same outcome; a second
        //    submission of the exact operation never dispatches.
        let counter = GenerationPerformCounter()
        let outcome = try #require(try await environment.mediaGenerationService
            .recoverDesignCreativeImage(idempotencyKey: key))
        #expect(outcome.asset?.id == canonical.id)
        #expect(outcome.job.state == .ready)
        let repeated = try await environment.mediaGenerationService.submitDesignCreativeImage(
            submission(
                target: target, request: request, provider: provider, model: model,
                frozenOwnerRevision: begun.envelope.revision)
        ) { _, _, _ in
            await counter.increment()
            return RemoteImageResult(images: [Self.pngBytes()])
        }
        #expect(repeated.deduplicated)
        #expect(repeated.asset?.id == canonical.id)
        #expect(await counter.count == 0)
    }

    // MARK: - Confirmation, binding / reopen / late conflict

    @Test("No provider dispatch happens before the confirmation is accepted")
    func noDispatchBeforeConfirmation() async throws {
        let environment = try await makeEnvironment()
        _ = try await configureImageRoute(environment)
        let workflow = environment.designOwnerWorkflow
        let target = creativeTarget()
        let begun = try await workflow.beginCreativeRequest(
            target: target, operationID: "t6-gen-confirm-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Confirm first"), runID: nil)
        defer { removeOwnerState(target) }
        let request = try #require(begun.envelope.project.creativeRequest)
        let key = DesignOwnerWorkflowModel.generationIdempotencyKey(
            target: target, request: request)

        let model_ = DesignOwnerWorkflowModel(target: target, environment: environment)
        await model_.reload()
        model_.requestGenerationConfirmation()
        let confirmation = try #require(model_.generationConfirmation)
        #expect(confirmation.modelTitle.contains("Image Double Model"))
        #expect(!confirmation.parametersSummary.isEmpty)
        // The configured model publishes ordinary TOKEN pricing metadata.
        // That is not verified per-image billing, so the image confirmation
        // must NOT advertise an amount derived from it (no fabricated price).
        #expect(confirmation.costSummary == nil)

        // Nothing was persisted or dispatched yet.
        let store = MediaGenerationJobStore(database: environment.database)
        #expect(try await store.ownedJob(idempotencyKey: key) == nil)
    }

    @Test("A ready durable result binds the real asset UUID and reopens as bound")
    func readyResultBindsAndReopens() async throws {
        let environment = try await makeEnvironment()
        let (provider, model) = try await configureImageRoute(environment)
        let workflow = environment.designOwnerWorkflow
        let target = creativeTarget()
        let begun = try await workflow.beginCreativeRequest(
            target: target, operationID: "t6-gen-bind-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "A calm product hero"), runID: nil)
        defer { removeOwnerState(target) }
        let request = try #require(begun.envelope.project.creativeRequest)
        let submission = submission(
            target: target, request: request, provider: provider, model: model,
            frozenOwnerRevision: begun.envelope.revision)
        let seeded = try await environment.mediaGenerationService.submitDesignCreativeImage(
            submission
        ) { _, _, _ in RemoteImageResult(images: [Self.pngBytes()]) }
        let asset = try #require(seeded.asset)
        defer { removeGeneratedFiles([asset]) }

        let model_ = DesignOwnerWorkflowModel(target: target, environment: environment)
        await model_.reload()
        #expect(model_.generationAvailable)
        #expect(model_.generationResultAwaitingBind)

        model_.requestGenerationConfirmation()
        await model_.confirmGeneration()
        #expect(model_.errorMessage == nil)
        #expect(model_.project?.creativeRequest?.state == .firstResultBound)
        #expect(model_.project?.creativeRequest?.boundResultID == asset.id.uuidString)

        // Reopen: a fresh model sees the bound request and resolves the real
        // asset through the production target service (real asset UUID).
        let reopened = DesignOwnerWorkflowModel(target: target, environment: environment)
        await reopened.reload()
        #expect(reopened.isCreativeAwaitingFirstResult == false)
        #expect(reopened.currentArtifact?.currentRevisionID != nil)
        let resolved = try await environment.designTargetService.resolve(target, runID: nil)
        #expect(resolved.contentSHA256 == FloeDigest.sha256Hex(Self.pngBytes()))
    }

    @Test("A reopen after a manual revision change conflicts; explicit resolution binds")
    func reopenAfterManualRevisionConflictsThenResolves() async throws {
        let environment = try await makeEnvironment()
        let (provider, model) = try await configureImageRoute(environment)
        let workflow = environment.designOwnerWorkflow
        let target = creativeTarget()
        let begun = try await workflow.beginCreativeRequest(
            target: target, operationID: "t6-gen-reopen-conflict-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Original goal"), runID: nil)
        defer { removeOwnerState(target) }
        let request = try #require(begun.envelope.project.creativeRequest)
        let submission = submission(
            target: target, request: request, provider: provider, model: model,
            frozenOwnerRevision: begun.envelope.revision)
        let seeded = try await environment.mediaGenerationService.submitDesignCreativeImage(
            submission
        ) { _, _, _ in RemoteImageResult(images: [Self.pngBytes()]) }
        let asset = try #require(seeded.asset)
        defer { removeGeneratedFiles([asset]) }

        // The user edits the owner while the generation result awaits its
        // bind (or before the app reopens).
        _ = try await workflow.updateBrief(
            target: target, operationID: "t6-gen-reopen-conflict-edit",
            expectedOwnerRevision: begun.envelope.revision,
            brief: DesignBrief(goal: "Edited by the user"), runID: nil)

        // A FRESH model reopening the request must bind against the ORIGINAL
        // submission revision from the durable payload, never the current one.
        let model_ = DesignOwnerWorkflowModel(target: target, environment: environment)
        await model_.reload()
        model_.requestGenerationConfirmation()
        await model_.confirmGeneration()
        #expect(model_.errorMessage != nil)
        #expect(model_.generationResultAwaitingBind)
        #expect(model_.project?.creativeRequest?.state == .awaitingFirstResult)

        // The result is retained: an explicit user action resolves it against
        // the current revision (never automatic).
        await model_.bindRetainedResultToCurrentRevision()
        #expect(model_.errorMessage == nil)
        #expect(model_.project?.creativeRequest?.state == .firstResultBound)
        #expect(model_.project?.creativeRequest?.boundResultID == asset.id.uuidString)
    }

    // MARK: - Missing published result (F2) and truthful cancellation (F3)

    /// Deletes only the contained file of a just-published result, leaving the
    /// canonical row (the materials-manager deletion the review describes).
    private func removePublishedFile(_ asset: CreativeAssetRecord) throws {
        let root = try FloeArtifactStore.root()
        let relative = try #require(asset.localRelativePath)
        try FileManager.default.removeItem(at: root.appendingPathComponent(relative))
    }

    @Test("A missing published result is an explicit state; only an acknowledged replacement re-runs")
    func missingReadyResultRequiresExplicitReplacement() async throws {
        let environment = try await makeEnvironment()
        let (provider, model) = try await configureImageRoute(environment)
        let target = creativeTarget()
        let begun = try await environment.designOwnerWorkflow.beginCreativeRequest(
            target: target, operationID: "f2-begin", expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Missing result"), runID: nil)
        defer { removeOwnerState(target) }
        let request = try #require(begun.envelope.project.creativeRequest)
        let submission = submission(
            target: target, request: request, provider: provider, model: model,
            frozenOwnerRevision: begun.envelope.revision)
        let counter = GenerationPerformCounter()
        let seeded = try await environment.mediaGenerationService.submitDesignCreativeImage(
            submission
        ) { _, _, _ in
            await counter.increment()
            return RemoteImageResult(images: [Self.pngBytes()])
        }
        let asset = try #require(seeded.asset)
        defer { removeGeneratedFiles([asset]) }
        try removePublishedFile(asset)

        // Recovery reports the explicit missing state; nothing is sent.
        let recovered = try #require(try await environment.mediaGenerationService
            .recoverDesignCreativeImage(idempotencyKey: submission.idempotencyKey))
        #expect(recovered.resultMissing)
        #expect(recovered.asset == nil)
        #expect(await counter.count == 1)

        // A plain resubmission does NOT dispatch: it returns the same missing
        // state (never a silent new paid call, never a stale-id bind).
        let deduped = try await environment.mediaGenerationService.submitDesignCreativeImage(
            submission
        ) { _, _, _ in
            await counter.increment()
            return RemoteImageResult(images: [Self.pngBytes()])
        }
        #expect(deduped.deduplicated)
        #expect(deduped.resultMissing)
        #expect(await counter.count == 1)

        // The panel exposes the missing state instead of a ready-to-bind
        // dead end.
        let model_ = DesignOwnerWorkflowModel(target: target, environment: environment)
        await model_.reload()
        #expect(model_.generationResultMissing)
        #expect(model_.generationResultAwaitingBind == false)

        // The acknowledged replacement performs ONE new submission with a NEW
        // durable job row; the stale ready id is never reused.
        let replacement = try await environment.mediaGenerationService
            .replaceMissingDesignCreativeResult(jobID: recovered.job.id) { _, _, _ in
                await counter.increment()
                return RemoteImageResult(images: [Self.pngBytes()])
            }
        #expect(replacement.job.id != recovered.job.id)
        #expect(replacement.asset != nil)
        #expect(await counter.count == 2)
        let store = MediaGenerationJobStore(database: environment.database)
        let stale = try #require(try await store.ownedJob(id: recovered.job.id))
        #expect(stale.job.state == .ready, "the stale record is preserved for audit")
    }

    @Test("An acknowledged discard of a missing result closes the dangling record; nothing is resent")
    func missingResultDiscardClosesDanglingRecord() async throws {
        let environment = try await makeEnvironment()
        let (provider, model) = try await configureImageRoute(environment)
        let target = creativeTarget()
        let begun = try await environment.designOwnerWorkflow.beginCreativeRequest(
            target: target, operationID: "f2-discard-begin", expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Discard missing"), runID: nil)
        defer { removeOwnerState(target) }
        let request = try #require(begun.envelope.project.creativeRequest)
        let submission = submission(
            target: target, request: request, provider: provider, model: model,
            frozenOwnerRevision: begun.envelope.revision)
        let counter = GenerationPerformCounter()
        let seeded = try await environment.mediaGenerationService.submitDesignCreativeImage(
            submission
        ) { _, _, _ in
            await counter.increment()
            return RemoteImageResult(images: [Self.pngBytes()])
        }
        let asset = try #require(seeded.asset)
        defer { removeGeneratedFiles([asset]) }
        try removePublishedFile(asset)

        try await environment.mediaGenerationService
            .discardMissingDesignCreativeResult(jobID: seeded.job.id)
        let store = MediaGenerationJobStore(database: environment.database)
        let closed = try #require(try await store.ownedJob(id: seeded.job.id))
        #expect(closed.job.state == .cancelled)
        #expect(closed.job.lastError == FloeL10n.l("design.owner.generate_missing_discarded"))
        #expect(await counter.count == 1)

        // A later explicit submission is a NEW durable attempt, not automatic.
        let next = try await environment.mediaGenerationService.submitDesignCreativeImage(
            submission
        ) { _, _, _ in
            await counter.increment()
            return RemoteImageResult(images: [Self.pngBytes()])
        }
        #expect(next.job.id != seeded.job.id)
        #expect(await counter.count == 2)
    }

    @Test("A pre-dispatch cancellation is reported as a definite cancel, not unknown")
    func preDispatchCancellationReportsDefiniteCancel() async throws {
        let environment = try await makeEnvironment()
        _ = try await configureImageRoute(environment)
        let target = creativeTarget()
        let begun = try await environment.designOwnerWorkflow.beginCreativeRequest(
            target: target, operationID: "f3-begin", expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Cancel before dispatch"), runID: nil)
        defer { removeOwnerState(target) }
        let request = try #require(begun.envelope.project.creativeRequest)

        let model_ = DesignOwnerWorkflowModel(target: target, environment: environment)
        await model_.reload()
        model_.requestGenerationConfirmation()
        #expect(model_.generationConfirmation != nil)
        model_.startConfirmedGeneration()
        // Both calls are main-actor synchronous, so the generation Task cannot
        // have started: the service observes Task.isCancelled BEFORE any
        // provider dispatch and durably closes the job as `.cancelled`.
        model_.cancelGeneration()
        let store = MediaGenerationJobStore(database: environment.database)
        let key = DesignOwnerWorkflowModel.generationIdempotencyKey(
            target: target, request: request)
        var settled: OwnedMediaGenerationJob?
        for _ in 0..<400 {
            settled = try? await store.ownedJob(idempotencyKey: key)
            if !model_.generating, model_.statusNote != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(model_.generating == false)
        #expect(model_.generationUnknownOutcome == false)
        #expect(model_.statusNote == FloeL10n.l("design.owner.generate_canceled_confirmed"))
        // A pre-dispatch cancel either never wrote a durable row (the write
        // itself was cancelled) or wrote one closed as `.cancelled`; neither
        // is an unknown remote outcome.
        if let settled {
            #expect(settled.job.state == .cancelled)
        }
    }
}
#endif
