// FloeAppTests — T6 creative MATERIAL source authorization (production factory).
//
// The exact defect this locks down: a run used to be authorized to read an
// EXISTING creative asset whenever the model simply claimed its own task as
// the target owner — the model could pair its task UUID with any foreign
// asset UUID and read the bytes. The production port now requires a REAL
// stored link:
//   * a durable media job whose committed local asset IS this asset and that
//     was submitted by this run (or belongs to the run's task);
//   * or a persisted owner envelope that binds this exact asset as its first
//     result / source identity and records the run's task as origin.
// A claimed owner string alone proves nothing for an existing asset, while
// the explicitly approved owner-task namespace stays available for pending
// (not-yet-materialized) requests, and the trusted UI (nil run) keeps the
// manual import/read path.
//
// These run in the FloeApp unit-test bundle (full App target, T7).

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeTools
@testable import FloeApp

/// Mutable live run→task binding for the task-change test (the production
/// binding reads the durable run store on every call).
@MainActor
private final class RunTaskBindingBox {
    var task: UUID?
    init(task: UUID?) { self.task = task }
}

@Suite("T6 creative material link and bounded reads")
@MainActor
struct T6CreativeMaterialLinkTests {

    private struct Composition {
        let environment: AppEnvironment
        let service: DesignTargetService
        let workflow: DesignOwnerWorkflow
    }

    private func makeComposition() async throws -> Composition {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let composition = DesignOwnerWorkflowFactory.make(
            environment: environment,
            canvasService: environment.designCanvasService,
            adapters: environment.designAdapterCenter)
        return Composition(
            environment: environment,
            service: composition.service,
            workflow: composition.workflow)
    }

    @discardableResult
    private func makeTask(_ environment: AppEnvironment, title: String) async throws -> UUID {
        let conversationID = UUID()
        try await environment.conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: title, createdAt: Date(), updatedAt: Date()))
        return conversationID
    }

    private func makeRun(
        _ environment: AppEnvironment, conversationID: UUID
    ) async throws -> UUID {
        let runID = UUID()
        try await environment.runStore.saveRun(RunRecord(
            id: runID, conversationID: conversationID,
            state: "running", goal: "creative", startedAt: Date()))
        return runID
    }

    /// Writes REAL bytes under the shared artifact root and registers the
    /// content-addressed row. Returns the record id and the file URL so the
    /// test can clean up.
    @discardableResult
    private func saveAsset(
        _ environment: AppEnvironment, bytes: Data, name: String
    ) async throws -> (id: UUID, url: URL) {
        let assetID = UUID()
        let relative = "Materials/t6-link-\(name).png"
        let url = try FloeArtifactStore.root().appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic])
        try await environment.creativeAssetStore.save(CreativeAssetRecord(
            id: assetID, contentHash: FloeDigest.sha256Hex(bytes), kind: .image,
            displayName: "\(name).png", mimeType: "image/png",
            localRelativePath: relative, byteCount: Int64(bytes.count),
            tags: ["test"], referenceCount: 0))
        return (assetID, url)
    }

    private func target(
        ownerID: String, assetID: UUID, origin: String? = nil
    ) -> DesignTarget {
        DesignTarget(
            kind: .creativeDocument,
            ownerID: ownerID,
            documentID: "",
            sourceID: assetID.uuidString,
            originConversationID: origin,
            requestedOutputKind: nil)
    }

    private func removeOwnerState(_ target: DesignTarget) {
        guard let root = try? FloeArtifactStore.root() else { return }
        let url = root
            .appendingPathComponent("DesignRevisions", isDirectory: true)
            .appendingPathComponent("owners", isDirectory: true)
            .appendingPathComponent(target.stableKey, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }

    /// The media job table has FK references to the configured provider and
    /// model rows; a durable job can only exist for a real configuration.
    private func configureJobProvider(
        _ environment: AppEnvironment
    ) async throws -> (ProviderProfile, ModelProfile) {
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://link-double.example/v1")!,
            displayName: "Link Job Provider")
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "link-job-model",
            displayName: "Link Job Model",
            limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.imageGeneration])
        try await environment.configurationStore.saveProvider(provider)
        try await environment.configurationStore.saveModel(model)
        return (provider, model)
    }

    // MARK: - Claimed owner cannot read a foreign asset

    @Test("A claimed owner-task cannot read an unlinked foreign asset")
    func claimedOwnerCannotReadForeignAsset() async throws {
        let composition = try await makeComposition()
        let environment = composition.environment
        let task = try await makeTask(environment, title: "Forged owner")
        let run = try await makeRun(environment, conversationID: task)

        let bytes = Data("foreign asset bytes".utf8)
        let (assetID, url) = try await saveAsset(environment, bytes: bytes, name: "foreign")
        defer { try? FileManager.default.removeItem(at: url) }

        // The model claims its OWN task as the owner but names a foreign
        // asset it does not own.
        let forged = target(ownerID: task.uuidString, assetID: assetID)
        await #expect(throws: (any Error).self) {
            _ = try await composition.service.resolve(forged, runID: run)
        }

        // Trusted UI (nil run) keeps the manual import/read path.
        let uiResolved = try await composition.service.resolve(forged, runID: nil)
        #expect(uiResolved.contentSHA256 == FloeDigest.sha256Hex(bytes))

        // The owner-task namespace stays approved for a PENDING request with
        // no material yet.
        let pending = DesignTarget(
            kind: .creativeDocument,
            ownerID: task.uuidString,
            documentID: "",
            sourceID: UUID().uuidString,
            originConversationID: task.uuidString,
            requestedOutputKind: .image)
        #expect(await composition.service.authorize(pending, runID: run))

        // An unknown run is never authorized.
        let unknown = target(ownerID: "creative-library", assetID: assetID)
        await #expect(throws: (any Error).self) {
            _ = try await composition.service.resolve(unknown, runID: UUID())
        }
    }

    // MARK: - Durable job link

    @Test("A durable job's committed asset is readable by its run and task")
    func jobLinkedAssetIsReadable() async throws {
        let composition = try await makeComposition()
        let environment = composition.environment
        let task = try await makeTask(environment, title: "Job owner")
        let run = try await makeRun(environment, conversationID: task)
        let otherTask = try await makeTask(environment, title: "Other task")
        let otherRun = try await makeRun(environment, conversationID: otherTask)

        let bytes = Data("generated by a durable job".utf8)
        let (assetID, url) = try await saveAsset(environment, bytes: bytes, name: "job")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = MediaGenerationJobStore(database: environment.database)
        let (provider, model) = try await configureJobProvider(environment)
        let job = MediaGenerationJob(
            providerID: provider.id, modelID: model.id, mediaKind: .image,
            credentialReference: nil, canvasID: nil, documentID: nil,
            sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: Data("{}".utf8),
            localAssetID: assetID)
        _ = try await store.createJob(
            job, owner: .conversation(task), originRunID: run,
            idempotencyKey: "t6-link-job")

        // The producing run reads it even though it claims a foreign owner.
        let linked = target(ownerID: "creative-library", assetID: assetID)
        let resolved = try await composition.service.resolve(linked, runID: run)
        #expect(resolved.contentSHA256 == FloeDigest.sha256Hex(bytes))

        // A run of a DIFFERENT task cannot read it.
        await #expect(throws: (any Error).self) {
            _ = try await composition.service.resolve(linked, runID: otherRun)
        }
    }

    // MARK: - Envelope bound-result link
    @Test("A stored envelope binding the asset as first result authorizes the origin task's run")
    func envelopeBoundResultAuthorizesOriginRun() async throws {
        let composition = try await makeComposition()
        let environment = composition.environment
        let task = try await makeTask(environment, title: "Bound origin")
        let otherTask = try await makeTask(environment, title: "Unrelated task")
        let run = try await makeRun(environment, conversationID: task)
        let otherRun = try await makeRun(environment, conversationID: otherTask)

        let bytes = Data("bound first result".utf8)
        let (assetID, url) = try await saveAsset(environment, bytes: bytes, name: "bound")
        defer { try? FileManager.default.removeItem(at: url) }

        let requestTarget = DesignTarget(
            kind: .creativeDocument,
            ownerID: "creative-library",
            documentID: "",
            sourceID: UUID().uuidString,
            originConversationID: task.uuidString,
            requestedOutputKind: .image)
        let begun = try await composition.workflow.beginCreativeRequest(
            target: requestTarget,
            operationID: "t6-link-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Bound request"),
            runID: nil)
        defer { removeOwnerState(requestTarget) }
        _ = try await composition.workflow.bindFirstResult(
            target: requestTarget,
            operationID: "t6-link-bind",
            expectedOwnerRevision: begun.envelope.revision,
            bytes: bytes,
            format: "png",
            displayName: "bound.png",
            boundResultID: assetID.uuidString,
            runID: nil)

        let assetTarget = target(ownerID: "creative-library", assetID: assetID)
        let resolved = try await composition.service.resolve(assetTarget, runID: run)
        #expect(resolved.contentSHA256 == FloeDigest.sha256Hex(bytes))

        // A different task's run is denied even though the asset exists.
        await #expect(throws: (any Error).self) {
            _ = try await composition.service.resolve(assetTarget, runID: otherRun)
        }
    }

    // MARK: - Live task-change revocation

    @Test("A run whose live task binding moves loses access to previously linked material")
    func liveTaskChangeRevokesAccess() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let taskA = try await makeTask(environment, title: "Task A")
        let taskB = try await makeTask(environment, title: "Task B")
        let run = UUID()
        let binding = RunTaskBindingBox(task: taskA)
        let envelopeStore = ArtifactDesignOwnerStore()
        let port = AppCreativeDocumentPort(
            assetStore: environment.creativeAssetStore,
            artifactRoot: { try FloeArtifactStore.root() },
            envelopes: envelopeStore,
            runTaskBinding: { _ in binding.task },
            generatedAssetLink: { _, _, _ in false })
        let service = DesignTargetService(adapters: [DesignCreativeOwnerAdapter(port: port)])
        let workflow = DesignOwnerWorkflow(
            targets: service,
            store: envelopeStore,
            payloads: ArtifactOwnerPayloadStore())

        let bytes = Data("live task change".utf8)
        let (assetID, url) = try await saveAsset(environment, bytes: bytes, name: "livetask")
        defer { try? FileManager.default.removeItem(at: url) }

        let requestTarget = DesignTarget(
            kind: .creativeDocument,
            ownerID: "creative-library",
            documentID: "",
            sourceID: UUID().uuidString,
            originConversationID: taskA.uuidString,
            requestedOutputKind: .image)
        let begun = try await workflow.beginCreativeRequest(
            target: requestTarget, operationID: "t6-live-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Live binding"), runID: nil)
        _ = try await workflow.bindFirstResult(
            target: requestTarget, operationID: "t6-live-bind",
            expectedOwnerRevision: begun.envelope.revision,
            bytes: bytes, format: "png", displayName: "live.png",
            boundResultID: assetID.uuidString, runID: nil)
        defer { removeOwnerState(requestTarget) }

        let assetTarget = target(ownerID: "creative-library", assetID: assetID)
        let resolved = try await service.resolve(assetTarget, runID: run)
        #expect(resolved.contentSHA256 == FloeDigest.sha256Hex(bytes))

        // The live mapping moves the run to another task: the SAME call must
        // be denied without any retargeting.
        binding.task = taskB
        await #expect(throws: (any Error).self) {
            _ = try await service.resolve(assetTarget, runID: run)
        }
    }

    // MARK: - Bounded read (the recorded byte count cannot lie)

    @Test("The real on-disk size is capped BEFORE any read")
    func oversizedFileIsRefusedBeforeRead() async throws {
        let composition = try await makeComposition()
        let environment = composition.environment

        let assetID = UUID()
        let relative = "Materials/t6-oversize-\(assetID.uuidString).png"
        let url = try FloeArtifactStore.root().appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(AppWorkspaceFilePort.maxSourceBytes) + 1)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: url) }

        // The record LIES about the size (1 byte).
        try await environment.creativeAssetStore.save(CreativeAssetRecord(
            id: assetID, contentHash: FloeDigest.sha256Hex(Data([0x01])), kind: .image,
            displayName: "oversize.png", mimeType: "image/png",
            localRelativePath: relative, byteCount: 1,
            tags: ["test"], referenceCount: 0))

        let oversized = target(ownerID: "creative-library", assetID: assetID)
        await #expect(throws: (any Error).self) {
            _ = try await composition.service.resolve(oversized, runID: nil)
        }
    }

    // MARK: - Model-authored request source identity (F1)

    @Test("A model-authored request source identity cannot read a foreign asset")
    func modelAuthoredSourceIdentityCannotReadForeignAsset() async throws {
        let composition = try await makeComposition()
        let environment = composition.environment
        let task = try await makeTask(environment, title: "Circular source")
        let run = try await makeRun(environment, conversationID: task)
        let bytes = Data("circular foreign bytes".utf8)
        let (assetID, url) = try await saveAsset(environment, bytes: bytes, name: "circular")
        defer { try? FileManager.default.removeItem(at: url) }

        // The model names an EXISTING asset as its creative request source
        // (model JSON) and begins a request under its own task.
        let requestTarget = DesignTarget(
            kind: .creativeDocument, ownerID: task.uuidString, documentID: "",
            sourceID: assetID.uuidString, originConversationID: task.uuidString,
            requestedOutputKind: .image)
        _ = try await composition.workflow.beginCreativeRequest(
            target: requestTarget, operationID: "f1-begin",
            expectedOwnerRevision: 0, brief: DesignBrief(goal: "circular"), runID: run)
        defer { removeOwnerState(requestTarget) }

        // The materialized (no requested kind) target with the same claimed
        // source must fail closed: the request's source identity is
        // model-authored and is NOT proof that the run may read the bytes.
        let material = DesignTarget(
            kind: .creativeDocument, ownerID: task.uuidString, documentID: "",
            sourceID: assetID.uuidString, originConversationID: task.uuidString,
            requestedOutputKind: nil)
        await #expect(throws: (any Error).self) {
            _ = try await composition.service.resolve(material, runID: run)
        }

        // A GENUINE strictly bound first result still resolves through the
        // same port: the asset is the committed result of a durable job owned
        // by this run/task (the only trusted link a model run can present).
        let (provider, model) = try await configureJobProvider(environment)
        let jobStore = MediaGenerationJobStore(database: environment.database)
        let job = MediaGenerationJob(
            providerID: provider.id, modelID: model.id, mediaKind: .image,
            credentialReference: nil, canvasID: nil, documentID: nil,
            sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: Data("{}".utf8),
            localAssetID: assetID)
        _ = try await jobStore.createJob(
            job, owner: .conversation(task), originRunID: run,
            idempotencyKey: "f1-genuine-job")
        let genuineSource = UUID().uuidString
        let genuineTarget = DesignTarget(
            kind: .creativeDocument, ownerID: task.uuidString, documentID: "",
            sourceID: genuineSource, originConversationID: task.uuidString,
            requestedOutputKind: .image)
        let begun = try await composition.workflow.beginCreativeRequest(
            target: genuineTarget, operationID: "f1-genuine-begin",
            expectedOwnerRevision: 0, brief: DesignBrief(goal: "genuine"), runID: run)
        defer { removeOwnerState(genuineTarget) }
        let bound = try await composition.workflow.bindFirstResult(
            target: genuineTarget, operationID: "f1-genuine-bind",
            expectedOwnerRevision: begun.envelope.revision,
            bytes: bytes, format: "png", displayName: "genuine.png",
            boundResultID: assetID.uuidString, runID: run)
        #expect(bound.envelope.creativeFirstResultProvenance == .generationJob)
        let genuineMaterial = DesignTarget(
            kind: .creativeDocument, ownerID: task.uuidString, documentID: "",
            sourceID: assetID.uuidString, originConversationID: task.uuidString,
            requestedOutputKind: nil)
        let resolved = try await composition.service.resolve(genuineMaterial, runID: run)
        #expect(resolved.contentSHA256 == FloeDigest.sha256Hex(bytes))
    }
}
#endif
