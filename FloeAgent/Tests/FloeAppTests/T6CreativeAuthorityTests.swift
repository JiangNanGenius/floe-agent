// FloeAppTests — T6 creative owner authority handshake (production factory).
//
// Locks down the real `DesignOwnerWorkflowFactory` creative port wiring per
// the published T5 contract:
//   * an agent run may start/continue a creative request owned by its OWN
//     durable task (run→task from the run store) and bind its first result;
//   * a request/asset linked to the run's task through the shared owner
//     envelope origin is also reachable;
//   * a cross-task, unknown-run or unlinked target is denied (the model
//     cannot widen via a supplied owner UUID);
//   * the trusted UI (nil run) remains authorized.
//
// These run in the FloeApp unit-test bundle (full App target, T7).

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeApp

@Suite("T6 creative owner run authority")
@MainActor
struct T6CreativeAuthorityTests {

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
    private func makeTask(
        _ environment: AppEnvironment, title: String
    ) async throws -> UUID {
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

    private func creativeTarget(
        ownerID: String, requestID: UUID, origin: String? = nil,
        kind: DesignContentType? = .image
    ) -> DesignTarget {
        DesignTarget(
            kind: .creativeDocument,
            ownerID: ownerID,
            documentID: "",
            sourceID: requestID.uuidString,
            originConversationID: origin,
            requestedOutputKind: kind)
    }

    /// Removes the owner envelope this test created under the shared artifact
    /// root (task-owned state must not leak between runs).
    private func removeOwnerState(_ target: DesignTarget) {
        guard let root = try? FloeArtifactStore.root() else { return }
        let url = root
            .appendingPathComponent("DesignRevisions", isDirectory: true)
            .appendingPathComponent("owners", isDirectory: true)
            .appendingPathComponent(target.stableKey, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes REAL bytes under the shared artifact root and registers the
    /// content-addressed creative asset row.
    @discardableResult
    private func saveAsset(
        _ environment: AppEnvironment, bytes: Data, name: String
    ) async throws -> (id: UUID, url: URL) {
        let assetID = UUID()
        let relative = "Materials/t7c-auth-\(name)-\(assetID.uuidString).png"
        let url = try FloeArtifactStore.root().appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic])
        try await environment.creativeAssetStore.save(CreativeAssetRecord(
            id: assetID, contentHash: FloeDigest.sha256Hex(bytes), kind: .image,
            displayName: "\(name).png", mimeType: "image/png",
            localRelativePath: relative, byteCount: Int64(bytes.count),
            tags: ["t7c"], referenceCount: 0))
        return (assetID, url)
    }

    /// A REAL durable media-generation job→asset record: the only link that
    /// lets a run bind an asset it did not itself author.
    private func linkAssetViaJob(
        _ environment: AppEnvironment, assetID: UUID, task: UUID, run: UUID, key: String
    ) async throws {
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://t7c-auth-double.example/v1")!,
            displayName: "T7C Auth Job Provider")
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "t7c-auth-job-model",
            displayName: "T7C Auth Job Model",
            limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.imageGeneration])
        try await environment.configurationStore.saveProvider(provider)
        try await environment.configurationStore.saveModel(model)
        let store = MediaGenerationJobStore(database: environment.database)
        let job = MediaGenerationJob(
            providerID: provider.id, modelID: model.id, mediaKind: .image,
            credentialReference: nil, canvasID: nil, documentID: nil,
            sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: Data("{}".utf8),
            localAssetID: assetID)
        _ = try await store.createJob(
            job, owner: .conversation(task), originRunID: run,
            idempotencyKey: key)
    }

    /// The REAL registered tool family over the shared composition (the same
    /// registration the agent runtime uses).
    private func makeRegistry(_ composition: Composition) -> ToolRunnerRegistry {
        let registry = ToolRunnerRegistry()
        registerDesignAgentTools(
            capabilities: { composition.environment.designAdapterCenter.capabilityRegistry() },
            adapters: composition.environment.designAdapterCenter,
            environment: composition.environment,
            authorize: { _, _ in false },
            targets: composition.service,
            ownerWorkflow: composition.workflow,
            canvasService: composition.environment.designCanvasService,
            registry: registry)
        return registry
    }

    private func creativeRequestTarget(
        ownerID: String, requestID: UUID, origin: String?
    ) -> DesignTarget {
        DesignTarget(
            kind: .creativeDocument, ownerID: ownerID, documentID: "",
            sourceID: requestID.uuidString, originConversationID: origin,
            requestedOutputKind: .image)
    }

    private func materialTarget(
        ownerID: String, assetID: UUID, origin: String?
    ) -> DesignTarget {
        DesignTarget(
            kind: .creativeDocument, ownerID: ownerID, documentID: "",
            sourceID: assetID.uuidString, originConversationID: origin,
            requestedOutputKind: nil)
    }

    // MARK: - Run-owned request (allowed)

    @Test("A run may start and bind a creative request owned by its own task")
    func runOwnedRequestIsAuthorizedAndBinds() async throws {
        let composition = try await makeComposition()
        let environment = composition.environment
        let task = try await makeTask(environment, title: "Creative owner")
        let run = try await makeRun(environment, conversationID: task)
        let requestID = UUID()
        let target = creativeTarget(
            ownerID: task.uuidString, requestID: requestID,
            origin: task.uuidString)

        #expect(await composition.service.authorize(target, runID: run))

        let begun = try await composition.workflow.beginCreativeRequest(
            target: target,
            operationID: "ai-creative-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "A calm product hero image"),
            runID: run)
        #expect(begun.request.state == .awaitingFirstResult)
        defer { removeOwnerState(target) }

        // The REAL generated result: verified bytes + the durable media job
        // that produced them. Only that independently trusted job→asset link
        // lets the run bind; a bare id or its own payload can never.
        let bytes = Data("not-a-real-png-but-verified-bytes".utf8)
        let (assetID, url) = try await saveAsset(
            environment, bytes: bytes, name: "run-owned")
        defer { try? FileManager.default.removeItem(at: url) }
        try await linkAssetViaJob(
            environment, assetID: assetID, task: task, run: run, key: "t7c-run-owned-bind")

        let bound = try await composition.workflow.bindFirstResult(
            target: target,
            operationID: "ai-creative-bind",
            expectedOwnerRevision: begun.envelope.revision,
            bytes: bytes,
            format: "png",
            displayName: "generated.png",
            boundResultID: assetID.uuidString,
            runID: run)
        #expect(bound.envelope.project.creativeRequest?.state == .firstResultBound)
        #expect(bound.envelope.project.creativeRequest?.boundResultID == assetID.uuidString)
        #expect(bound.revision.contentSHA256 == FloeDigest.sha256Hex(bytes))
        // The run's bind recorded the durable-job provenance, not a claimed id.
        #expect(bound.envelope.creativeFirstResultProvenance == .generationJob)

        // Replay is idempotent: same revision, no second binding.
        let replay = try await composition.workflow.bindFirstResult(
            target: target,
            operationID: "ai-creative-bind",
            expectedOwnerRevision: begun.envelope.revision,
            bytes: bytes,
            format: "png",
            displayName: "generated.png",
            boundResultID: assetID.uuidString,
            runID: run)
        #expect(replay.revision.id == bound.revision.id)

        // The same run resolves the bound result through the material path.
        let material = materialTarget(
            ownerID: task.uuidString, assetID: assetID, origin: task.uuidString)
        let resolved = try await composition.service.resolve(material, runID: run)
        #expect(resolved.contentSHA256 == FloeDigest.sha256Hex(bytes))
    }

    // MARK: - Envelope origin linkage (UI-started request for a task)

    @Test("An envelope recording the run's task as origin authorizes the run")
    func envelopeOriginLinkageAuthorizesRun() async throws {
        let composition = try await makeComposition()
        let environment = composition.environment
        let task = try await makeTask(environment, title: "Origin task")
        let run = try await makeRun(environment, conversationID: task)
        // A request started in-app (trusted UI) but attributed to this task.
        let requestID = UUID()
        let target = creativeTarget(
            ownerID: "creative-library", requestID: requestID,
            origin: task.uuidString)
        #expect(await composition.service.authorize(target, runID: nil))

        let begun = try await composition.workflow.beginCreativeRequest(
            target: target,
            operationID: "ui-creative-begin",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Library request"),
            runID: nil)
        #expect(begun.request.originConversationID == task.uuidString)

        // The run's task owns the recorded origin: the target is reachable.
        #expect(await composition.service.authorize(target, runID: run))

        // A different task's run is not.
        let otherTask = try await makeTask(environment, title: "Other task")
        let otherRun = try await makeRun(environment, conversationID: otherTask)
        #expect(await composition.service.authorize(target, runID: otherRun) == false)
        removeOwnerState(target)
    }

    // MARK: - Denied: cross-task / unknown run

    @Test("A cross-task owner and an unknown run are denied")
    func crossTaskAndUnknownRunAreDenied() async throws {
        let composition = try await makeComposition()
        let environment = composition.environment
        let task = try await makeTask(environment, title: "Own task")
        let otherTask = try await makeTask(environment, title: "Other task")
        let run = try await makeRun(environment, conversationID: task)

        let crossTask = creativeTarget(
            ownerID: otherTask.uuidString, requestID: UUID(),
            origin: otherTask.uuidString)
        #expect(await composition.service.authorize(crossTask, runID: run) == false)

        let ownTarget = creativeTarget(
            ownerID: task.uuidString, requestID: UUID(), origin: task.uuidString)
        #expect(await composition.service.authorize(ownTarget, runID: UUID()) == false)

        await #expect(throws: (any Error).self) {
            _ = try await composition.workflow.beginCreativeRequest(
                target: crossTask,
                operationID: "ai-cross-task",
                expectedOwnerRevision: 0,
                brief: DesignBrief(goal: "should fail"),
                runID: run)
        }
    }

    // MARK: - Existing asset ownership + trusted UI

    @Test("Existing creative assets obey run-task linkage; trusted UI stays authorized")
    func existingAssetOwnershipAndTrustedUI() async throws {
        let composition = try await makeComposition()
        let environment = composition.environment
        let task = try await makeTask(environment, title: "Asset owner task")
        let run = try await makeRun(environment, conversationID: task)

        // A real content-addressed creative asset on disk.
        let bytes = Data("creative asset bytes".utf8)
        let digest = FloeDigest.sha256Hex(bytes)
        let assetID = UUID()
        let relative = "Materials/t6-auth-\(assetID.uuidString).png"
        let url = try FloeArtifactStore.root().appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: [.atomic])
        try await environment.creativeAssetStore.save(CreativeAssetRecord(
            id: assetID, contentHash: digest, kind: .image,
            displayName: "asset.png", mimeType: "image/png",
            localRelativePath: relative, byteCount: Int64(bytes.count),
            tags: ["test"], referenceCount: 0))
        defer { try? FileManager.default.removeItem(at: url) }

        // The creation envelope links this asset identity to the task.
        let requestTarget = creativeTarget(
            ownerID: "creative-library", requestID: assetID,
            origin: task.uuidString)
        _ = try await composition.workflow.beginCreativeRequest(
            target: requestTarget,
            operationID: "ui-creative-begin-asset",
            expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "Asset request"),
            runID: nil)
        defer { removeOwnerState(requestTarget) }

        let assetTarget = creativeTarget(
            ownerID: "creative-library", requestID: assetID,
            origin: task.uuidString, kind: nil)

        // F1: the request's model-authored source identity is NOT proof of
        // ownership — a run cannot read existing bytes merely because its own
        // creative request named them. The materialized target stays denied
        // for the run (only a durable job link or a strictly bound first
        // result authorizes existing bytes).
        await #expect(throws: (any Error).self) {
            _ = try await composition.service.resolve(assetTarget, runID: run)
        }

        // An unlinked asset (no envelope, different creation id) is denied
        // for a run even though the asset exists.
        let unrelatedAssetID = UUID()
        let unrelatedRelative = "Materials/t6-auth-\(unrelatedAssetID.uuidString).png"
        let unrelatedURL = try FloeArtifactStore.root()
            .appendingPathComponent(unrelatedRelative)
        try bytes.write(to: unrelatedURL, options: [.atomic])
        try await environment.creativeAssetStore.save(CreativeAssetRecord(
            id: unrelatedAssetID, contentHash: digest, kind: .image,
            displayName: "asset2.png", mimeType: "image/png",
            localRelativePath: unrelatedRelative, byteCount: Int64(bytes.count),
            tags: ["test"], referenceCount: 0))
        defer { try? FileManager.default.removeItem(at: unrelatedURL) }
        let unrelatedTarget = creativeTarget(
            ownerID: "creative-library", requestID: unrelatedAssetID,
            origin: task.uuidString, kind: nil)
        await #expect(throws: (any Error).self) {
            _ = try await composition.service.resolve(unrelatedTarget, runID: run)
        }

        // Trusted UI (nil run) remains authorized for the same target.
        let uiResolved = try await composition.service.resolve(assetTarget, runID: nil)
        #expect(uiResolved.contentSHA256 == digest)
    }

    // MARK: - T7C: model-authored first-result bindings cannot mint authority

    @Test("The registered bind tool refuses a foreign asset with model-authored bytes and leaves no effects")
    func registeredToolRefusesForeignAssetBindWithoutEffects() async throws {
        let composition = try await makeComposition()
        let environment = composition.environment
        let task = try await makeTask(environment, title: "Tool bind owner")
        let run = try await makeRun(environment, conversationID: task)
        let otherTask = try await makeTask(environment, title: "Foreign job owner")
        let otherRun = try await makeRun(environment, conversationID: otherTask)
        // A real retained library asset that IS a durable job result — but of
        // a DIFFERENT task/run. It stays unreadable for this run even with the
        // real job record (foreign task), and a model payload cannot be bound
        // under its identity.
        let (foreignID, foreignURL) = try await saveAsset(
            environment, bytes: Data("foreign retained bytes".utf8), name: "foreign")
        defer { try? FileManager.default.removeItem(at: foreignURL) }
        try await linkAssetViaJob(
            environment, assetID: foreignID, task: otherTask, run: otherRun,
            key: "t7c-foreign-job")

        let registry = makeRegistry(composition)
        #expect(registry.runner(named: "design.creativeBegin") != nil)
        #expect(registry.runner(named: "design.creativeBindFirstResult") != nil)
        let context = ToolContext(
            runID: run, toolCallID: "t7c-tool-call", approvalGrantID: UUID(),
            cancellation: CancellationToken(), conversationID: task)
        let requestID = UUID()
        let targetJSON: [String: Any] = [
            "kind": "creativeDocument",
            "ownerID": task.uuidString,
            "sourceID": requestID.uuidString,
            "requestedOutputKind": "image",
            "originConversationID": task.uuidString
        ]
        let begin = try #require(registry.runner(named: "design.creativeBegin"))
        _ = try await begin.run(
            try JSONSerialization.data(withJSONObject: [
                "target": targetJSON, "operationID": "t7c-tool-begin", "goal": "hero"
            ], options: [.sortedKeys]),
            context)
        let requestTarget = creativeRequestTarget(
            ownerID: task.uuidString, requestID: requestID, origin: task.uuidString)
        defer { removeOwnerState(requestTarget) }
        let begunState = try #require(await composition.workflow.state(requestTarget))
        let revisionBefore = begunState.revision

        // The model's OWN valid payload (a real file the tool can read).
        let ownPayload = Data("model-authored payload".utf8)
        let payloadPath = "ChangeArtifacts/t7c-auth-\(UUID().uuidString.lowercased()).png"
        let payloadURL = try FloeArtifactStore.root().appendingPathComponent(payloadPath)
        try FileManager.default.createDirectory(
            at: payloadURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ownPayload.write(to: payloadURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: payloadURL) }

        let bindArgs = try JSONSerialization.data(withJSONObject: [
            "target": targetJSON,
            "operationID": "t7c-tool-bind",
            "expectedOwnerRevision": revisionBefore,
            "boundResultID": foreignID.uuidString,
            "payloadRelativePath": payloadPath
        ], options: [.sortedKeys])
        let bind = try #require(registry.runner(named: "design.creativeBindFirstResult"))
        do {
            _ = try await bind.run(bindArgs, context)
            Issue.record(
                "the registered bind tool recorded a model payload for a foreign asset id")
        } catch {
            // Expected: refused before any payload/CAS effect.
        }

        // Direct shared API with the same runID refuses identically.
        do {
            _ = try await composition.workflow.bindFirstResult(
                target: requestTarget, operationID: "t7c-direct-bind",
                expectedOwnerRevision: revisionBefore,
                bytes: ownPayload, format: "png", displayName: "forged.png",
                boundResultID: foreignID.uuidString, runID: run)
            Issue.record("the direct shared bind recorded a model payload for a foreign asset id")
        } catch {
            // Expected.
        }

        // No effects: revision unchanged, request still awaiting, no owner
        // payload revision staged, and the foreign bytes are unreachable.
        let after = try #require(await composition.workflow.state(requestTarget))
        #expect(after.revision == revisionBefore)
        #expect(after.project.creativeRequest?.state == .awaitingFirstResult)
        let revisionsDirectory = try FloeArtifactStore.root()
            .appendingPathComponent("DesignRevisions", isDirectory: true)
            .appendingPathComponent("owners", isDirectory: true)
            .appendingPathComponent(requestTarget.stableKey, isDirectory: true)
            .appendingPathComponent("revisions", isDirectory: true)
        let staged = (try? FileManager.default.contentsOfDirectory(
            atPath: revisionsDirectory.path)) ?? []
        #expect(staged.isEmpty)
        await #expect(throws: (any Error).self) {
            _ = try await composition.service.resolve(
                materialTarget(ownerID: task.uuidString, assetID: foreignID,
                               origin: task.uuidString),
                runID: run)
        }
        await #expect(throws: (any Error).self) {
            _ = try await composition.workflow.freezeInput(
                target: requestTarget, operationID: "t7c-tool-freeze",
                expectedOwnerRevision: revisionBefore, runID: run)
        }
        await #expect(throws: (any Error).self) {
            _ = try await composition.workflow.exportVerified(
                target: requestTarget, artifactID: "missing", revisionID: "missing",
                runID: run
            ) { _, _, _ in }
        }
    }

    @Test("A trusted-UI first-material selection records provenance and stays run-readable for its task")
    func trustedUISelectionRecordsProvenanceAndResolves() async throws {
        let composition = try await makeComposition()
        let environment = composition.environment
        let task = try await makeTask(environment, title: "UI selection task")
        let run = try await makeRun(environment, conversationID: task)
        let otherTask = try await makeTask(environment, title: "Other UI task")
        let otherRun = try await makeRun(environment, conversationID: otherTask)

        let bytes = Data("user selected library asset".utf8)
        let (assetID, url) = try await saveAsset(environment, bytes: bytes, name: "ui-selected")
        defer { try? FileManager.default.removeItem(at: url) }

        let requestID = UUID()
        let requestTarget = creativeRequestTarget(
            ownerID: "creative-library", requestID: requestID, origin: task.uuidString)
        let begun = try await composition.workflow.beginCreativeRequest(
            target: requestTarget, operationID: "t7c-ui-begin", expectedOwnerRevision: 0,
            brief: DesignBrief(goal: "UI selected material"), runID: nil)
        defer { removeOwnerState(requestTarget) }
        // The trusted UI binds the REAL asset bytes (the same call the panel's
        // explicit library selection makes).
        let bound = try await composition.workflow.bindFirstResult(
            target: requestTarget, operationID: "t7c-ui-bind",
            expectedOwnerRevision: begun.envelope.revision,
            bytes: bytes, format: "png", displayName: "ui-selected.png",
            boundResultID: assetID.uuidString, runID: nil)
        #expect(bound.envelope.creativeFirstResultProvenance == .trustedUIManualImport)
        #expect(bound.envelope.project.creativeRequest?.state == .firstResultBound)

        // The origin task's run resolves the material and the pending target;
        // another task's run is denied through every path.
        let material = materialTarget(
            ownerID: "creative-library", assetID: assetID, origin: task.uuidString)
        let resolved = try await composition.service.resolve(material, runID: run)
        #expect(resolved.contentSHA256 == FloeDigest.sha256Hex(bytes))
        let boundRead = try await composition.service.resolve(requestTarget, runID: run)
        #expect(boundRead.contentSHA256 == FloeDigest.sha256Hex(bytes))
        await #expect(throws: (any Error).self) {
            _ = try await composition.service.resolve(material, runID: otherRun)
        }
        await #expect(throws: (any Error).self) {
            _ = try await composition.service.resolve(requestTarget, runID: otherRun)
        }
    }

    @Test("An unproven legacy bound record fails closed for runs and is never mutated")
    func legacyUnprovenBoundRecordFailsClosedAndIsPreserved() async throws {
        let composition = try await makeComposition()
        let environment = composition.environment
        let task = try await makeTask(environment, title: "Legacy record task")
        let run = try await makeRun(environment, conversationID: task)

        // The REAL asset the unproven record names.
        let assetBytes = Data("real legacy asset".utf8)
        let (assetID, url) = try await saveAsset(environment, bytes: assetBytes, name: "legacy")
        defer { try? FileManager.default.removeItem(at: url) }

        // A pre-gate model-authored record: firstResultBound with a model
        // payload digest and NO provenance (directly persisted, the state the
        // old bind could produce).
        let requestID = UUID()
        let requestTarget = creativeRequestTarget(
            ownerID: task.uuidString, requestID: requestID, origin: task.uuidString)
        defer { removeOwnerState(requestTarget) }
        let store = ArtifactDesignOwnerStore()
        var project = DesignWorkflowEngine.createProject(
            nodeID: requestTarget.stableKey, contentType: .image)
        project.creativeRequest = DesignCreativeRequest(
            requestedKind: .image,
            state: .firstResultBound,
            boundResultID: assetID.uuidString,
            boundFormat: "png",
            boundContentSHA256: FloeDigest.sha256Hex(Data("model payload".utf8)),
            originConversationID: task.uuidString,
            environmentID: nil)
        let envelope = DesignOwnerEnvelope(
            target: requestTarget, project: project, revision: 0)
        _ = try await store.save(envelope, targetKey: requestTarget.stableKey, expectedRevision: nil)
        let before = try #require(await store.load(targetKey: requestTarget.stableKey))

        // Runs are denied through both the material and the bound-request path.
        await #expect(throws: (any Error).self) {
            _ = try await composition.service.resolve(
                materialTarget(ownerID: task.uuidString, assetID: assetID,
                               origin: task.uuidString),
                runID: run)
        }
        await #expect(throws: (any Error).self) {
            _ = try await composition.service.resolve(requestTarget, runID: run)
        }
        // The trusted UI keeps its manual read of the real retained asset.
        let uiRead = try await composition.service.resolve(
            materialTarget(ownerID: task.uuidString, assetID: assetID,
                           origin: task.uuidString),
            runID: nil)
        #expect(uiRead.contentSHA256 == FloeDigest.sha256Hex(assetBytes))

        // Nothing was rewritten: the record and its revision are preserved.
        let after = try #require(await store.load(targetKey: requestTarget.stableKey))
        #expect(after.revision == before.revision)
        #expect(after.project.creativeRequest == before.project.creativeRequest)
        #expect(after.creativeFirstResultProvenance == nil)
    }
}
#endif
