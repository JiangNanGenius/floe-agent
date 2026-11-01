// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 owner-closure tests (authored source; executed by Main's combined
// gate). They exercise the REAL creative-document owner port, the shared
// first-result transaction, durable run→task / job→asset links and the trusted
// restructure claim/burn seam against temporary explicit roots and an in-memory
// GRDB database. No device/provider/Git/build action is performed here.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence
import FloeAndroidWorkbench

final class G09R2DesignOwnerClosureTests: XCTestCase {
    private var roots: [URL] = []
    private var databases: [DatabaseManager] = []
    private static let epochLock = NSLock()
    nonisolated(unsafe) private static var epochCounter: UInt64 = 12_000

    override func tearDown() async throws {
        for database in databases { try? await database.close() }
        databases.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try await super.tearDown()
    }

    private static func nextEpoch() -> UInt64 {
        epochLock.lock(); defer { epochLock.unlock() }
        epochCounter += 1
        return epochCounter
    }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date()

        func now() -> Date {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            value = value.addingTimeInterval(seconds)
        }
    }

    private struct Fixture {
        let design: G09R2DesignService
        let root: RuntimeStorageRoot
        let rootURL: URL
        let database: DatabaseManager
        let workspaceStore: SQLiteWorkspaceStore
        let conversationStore: SQLiteConversationStore
        let runStore: SQLiteRunStore
        let jobStore: MediaGenerationJobStore
        let assetStore: CreativeAssetStore
        let assets: G09CreativeAssetHost
        let epoch: UInt64
        let clock: TestClock
        let providerID: UUID
        let modelID: UUID
    }

    private func makeFixture() async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-design-owner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        databases.append(manager)
        let workspaceStore = SQLiteWorkspaceStore(database: manager)
        let conversationStore = SQLiteConversationStore(database: manager)
        let root = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        let assetStore = CreativeAssetStore(
            database: manager, reachabilityGuard: nil,
            deferPhysicalReclamation: true)
        let assets = G09CreativeAssetHost(root: root, store: assetStore)
        let canvas = G09CanvasProjectRepository(root: root)
        let clock = TestClock()
        let configuration = ModelConfigurationStore(database: manager)
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://synthetic.example/v1")!,
            displayName: "Synthetic Provider", isEnabled: true)
        try await configuration.saveProvider(provider)
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "gpt-image-1",
            displayName: "Synthetic image",
            limits: ModelLimits(contextTokens: 4_096, maxOutputTokens: 256),
            capabilities: [.imageGeneration],
            useSurfaces: [.imageGeneration],
            isEnabled: true)
        try await configuration.saveModel(model)
        let epoch = Self.nextEpoch()
        let design = G09R2DesignService(
            epoch: epoch,
            root: root,
            canvasRepository: canvas,
            assets: assets,
            workspaceStore: workspaceStore,
            conversationStore: conversationStore,
            database: manager,
            authorityClock: { clock.now() })
        return Fixture(
            design: design, root: root, rootURL: url,
            database: manager, workspaceStore: workspaceStore,
            conversationStore: conversationStore,
            runStore: SQLiteRunStore(database: manager),
            jobStore: MediaGenerationJobStore(database: manager),
            assetStore: assetStore, assets: assets,
            epoch: epoch, clock: clock,
            providerID: provider.id, modelID: model.id)
    }

    // MARK: - Fixtures

    /// A real 1x1 RGBA PNG (valid bytes, not a text placeholder).
    private static let pngBytes = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
        0x54, 0x78, 0xDA, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
        0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x56, 0xC7,
        0x2F, 0x0D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
        0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    private func stage(
        _ fixture: Fixture,
        sessionToken: String,
        data: Data,
        format: String
    ) throws -> G09R2StagedDesignPayloadDTO {
        let directory = fixture.root.artifactStoreURL
            .appendingPathComponent("CreativeIncoming", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let token = "\(sessionToken).\(UUID().uuidString.lowercased())"
        try data.write(to: directory.appendingPathComponent(token))
        return G09R2StagedDesignPayloadDTO(
            token: token,
            format: format,
            byteCount: Int64(data.count),
            sha256: FloeDigest.sha256Hex(data))
    }

    private func ingest(
        _ fixture: Fixture,
        bytes: Data,
        format: String,
        fileName: String = "result.png"
    ) async throws -> (id: UUID, record: CreativeAssetRecord) {
        let staging = fixture.rootURL.appendingPathComponent(
            "ingest-\(UUID().uuidString).\(format)")
        try bytes.write(to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let candidateID = UUID()
        let reference = try await fixture.assets.ingestForSourceCreate(
            staging: staging,
            fileName: fileName,
            mimeType: format == "png" ? "image/png" : nil,
            byteCount: Int64(bytes.count),
            sha256: FloeDigest.sha256Hex(bytes),
            candidateID: candidateID)
        let recordOptional = try await fixture.assetStore.asset(id: reference.id)
        let record = try XCTUnwrap(recordOptional)
        return (record.id, record)
    }

    private func materialURL(_ fixture: Fixture, record: CreativeAssetRecord) throws -> URL {
        let relative = try XCTUnwrap(record.localRelativePath)
        return fixture.root.artifactStoreURL
            .appendingPathComponent("Materials", isDirectory: true)
            .appendingPathComponent(relative)
    }

    private func makeWorkspaceFile(
        _ fixture: Fixture,
        content: String = "Original design"
    ) async throws -> (target: DesignTarget, binding: G09R2DesignBindingDTO, fileURL: URL) {
        let workspaceID = UUID()
        let conversationID = UUID()
        let relative = "PrivateTasks/\(conversationID.uuidString)"
        try await fixture.workspaceStore.saveWorkspace(WorkspaceRecord(
            id: workspaceID,
            name: "Owner closure workspace",
            rootBookmark: Data(),
            kind: .privateTask,
            internalRelativePath: relative))
        let directory = fixture.rootURL
            .appendingPathComponent("Workspace", isDirectory: true)
            .appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("design.md")
        try Data(content.utf8).write(to: fileURL)
        let target = DesignTarget(
            kind: .fileDocument,
            ownerID: workspaceID.uuidString.lowercased(),
            sourceID: "design.md")
        let binding = G09R2DesignBindingDTO(
            target: target,
            storage: G09StorageLayerDTO(
                kind: .workspace, workspaceID: workspaceID),
            sessionToken: "owner-closure-session")
        return (target, binding, fileURL)
    }

    private func creativeTarget(
        originConversationID: String? = nil
    ) -> DesignTarget {
        DesignTarget(
            kind: .creativeDocument,
            ownerID: "creative-library",
            sourceID: UUID().uuidString.lowercased(),
            originConversationID: originConversationID,
            requestedOutputKind: .image)
    }

    private func creativeBinding(_ target: DesignTarget) -> G09R2DesignBindingDTO {
        G09R2DesignBindingDTO(
            target: target,
            storage: G09StorageLayerDTO(kind: .appOwned),
            sessionToken: "creative-owner-session")
    }

    private func runAndTask(
        _ fixture: Fixture,
        title: String = "Creative run"
    ) async throws -> (runID: UUID, taskID: UUID) {
        let taskID = UUID()
        let now = Date()
        try await fixture.conversationStore.saveConversation(ConversationRecord(
            id: taskID, title: title, createdAt: now, updatedAt: now))
        let runID = UUID()
        try await fixture.runStore.saveRun(RunRecord(
            id: runID, conversationID: taskID, state: "running",
            goal: title, startedAt: now))
        return (runID, taskID)
    }

    // MARK: - Creative START / first result (trusted UI)

    func testCreativeBeginAndTrustedUIFirstResultBindReuseAssetAndEnvelope() async throws {
        let fixture = try await makeFixture()
        let design = fixture.design
        let target = creativeTarget()
        let binding = creativeBinding(target)

        let bound = try await design.bind(G09R2DesignBindRequest(
            binding: binding, expectedRevision: 0, opID: "creative-bind-1"))
        XCTAssertEqual(bound.envelope.project.creativeRequest?.state,
                       .awaitingFirstResult)
        XCTAssertEqual(bound.envelope.project.creativeRequest?.requestedKind,
                       .image)

        let briefed = try await design.beginCreativeRequest(
            G09R2DesignCreativeBeginRequest(
                binding: binding,
                expectedRevision: bound.envelope.revision,
                opID: "creative-begin-1",
                brief: DesignBrief(goal: "A precise image", audience: "Users")),
            trustedUI: true)
        XCTAssertEqual(briefed.envelope.project.brief?.goal, "A precise image")

        let ingested = try await ingest(
            fixture, bytes: Self.pngBytes, format: "png")
        let staged = try stage(
            fixture, sessionToken: binding.sessionToken,
            data: Self.pngBytes, format: "png")
        let first = try await design.bindCreativeFirstResult(
            G09R2DesignCreativeBindRequest(
                binding: binding,
                expectedRevision: briefed.envelope.revision,
                opID: "creative-first-result-1",
                boundResultID: ingested.id.uuidString.lowercased(),
                payload: staged,
                displayName: "first.png"),
            trustedUI: true)
        XCTAssertEqual(first.envelope.project.creativeRequest?.state,
                       .firstResultBound)
        XCTAssertEqual(first.envelope.creativeFirstResultProvenance,
                       .trustedUIManualImport)
        XCTAssertEqual(
            first.envelope.project.creativeRequest?.boundResultID,
            ingested.id.uuidString.lowercased())
        let artifact = try XCTUnwrap(first.envelope.project.artifacts.first)
        let current = try XCTUnwrap(artifact.currentRevision)
        XCTAssertEqual(current.contentSHA256, FloeDigest.sha256Hex(Self.pngBytes))
        XCTAssertEqual(current.payloadFormat, "png")

        // The live retained asset still resolves through the owner adapter.
        let preview = try await design.preview(G09R2DesignPreviewRequest(
            binding: binding,
            candidateID: nil,
            revisionID: nil,
            maxBytes: G09R2CreativeLimits.designPreviewBytes))
        XCTAssertEqual(preview.format, "png")
        XCTAssertEqual(preview.byteCount, Int64(Self.pngBytes.count))
        XCTAssertEqual(preview.sha256, FloeDigest.sha256Hex(Self.pngBytes))

        // A second different first result is refused as already bound.
        let other = try await ingest(
            fixture, bytes: Data("not the first result".utf8),
            format: "png", fileName: "second.png")
        let otherStaged = try stage(
            fixture, sessionToken: binding.sessionToken,
            data: Data("not the first result".utf8), format: "png")
        do {
            _ = try await design.bindCreativeFirstResult(
                G09R2DesignCreativeBindRequest(
                    binding: binding,
                    expectedRevision: first.envelope.revision,
                    opID: "creative-second-result-1",
                    boundResultID: other.id.uuidString.lowercased(),
                    payload: otherStaged),
                trustedUI: true)
            XCTFail("a second different first result must be refused")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "designConflict")
        }
        let unchanged = try await design.state(binding)
        XCTAssertEqual(unchanged.envelope.revision, first.envelope.revision)
    }

    func testCreativeBindRefusesMismatchedPayloadAndLeavesEnvelopeUntouched() async throws {
        let fixture = try await makeFixture()
        let design = fixture.design
        let target = creativeTarget()
        let binding = creativeBinding(target)
        let bound = try await design.bind(G09R2DesignBindRequest(
            binding: binding, expectedRevision: 0, opID: "creative-bind-mismatch"))
        let ingested = try await ingest(
            fixture, bytes: Self.pngBytes, format: "png")
        let different = Data("this is not the retained png".utf8)
        let staged = try stage(
            fixture, sessionToken: binding.sessionToken,
            data: different, format: "png")
        do {
            _ = try await design.bindCreativeFirstResult(
                G09R2DesignCreativeBindRequest(
                    binding: binding,
                    expectedRevision: bound.envelope.revision,
                    opID: "creative-bind-mismatch-result",
                    boundResultID: ingested.id.uuidString.lowercased(),
                    payload: staged),
                trustedUI: true)
            XCTFail("payload bytes that are not the asset must be refused")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "designPayloadMissing")
        }
        let after = try await design.state(binding)
        XCTAssertEqual(after.envelope.revision, bound.envelope.revision)
        XCTAssertEqual(after.envelope.project.creativeRequest?.state,
                       .awaitingFirstResult)
        XCTAssertTrue(after.envelope.project.artifacts.isEmpty)
    }

    func testCreativeLiveDigestTamperRefusesMaterialReadWithoutEnvelopeChange() async throws {
        let fixture = try await makeFixture()
        let design = fixture.design
        let target = creativeTarget()
        let binding = creativeBinding(target)
        _ = try await design.bind(G09R2DesignBindRequest(
            binding: binding, expectedRevision: 0, opID: "creative-tamper-bind"))
        let ingested = try await ingest(
            fixture, bytes: Self.pngBytes, format: "png")
        let staged = try stage(
            fixture, sessionToken: binding.sessionToken,
            data: Self.pngBytes, format: "png")
        let state = try await design.state(binding)
        let first = try await design.bindCreativeFirstResult(
            G09R2DesignCreativeBindRequest(
                binding: binding,
                expectedRevision: state.envelope.revision,
                opID: "creative-tamper-first",
                boundResultID: ingested.id.uuidString.lowercased(),
                payload: staged),
            trustedUI: true)

        // Replace the retained bytes behind the row: a live read must fail
        // closed, never return silently mismatched material.
        let url = try materialURL(fixture, record: ingested.record)
        try Data("tampered".utf8).write(to: url)
        do {
            _ = try await design.freeze(G09R2DesignFreezeRequest(
                binding: binding,
                expectedRevision: first.envelope.revision,
                opID: "creative-tamper-freeze",
                inputRevisionID: nil,
                specSHA256: nil,
                targetRevisionID: nil,
                desiredFormat: "png",
                workMode: .modify,
                preservationDigest: nil),
                trustedUI: true)
            XCTFail("tampered asset bytes must not be accepted")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "designPayloadMissing")
        }
        let after = try await design.state(binding)
        XCTAssertEqual(after.envelope.revision, first.envelope.revision)
    }

    // MARK: - Durable run/job provenance

    func testCreativeRunBindingRequiresDurableJobLinkAndOwnTask() async throws {
        let fixture = try await makeFixture()
        let target = creativeTarget()
        let binding = creativeBinding(target)
        _ = try await fixture.design.bind(G09R2DesignBindRequest(
            binding: binding, expectedRevision: 0, opID: "creative-run-bind"))
        let ingested = try await ingest(
            fixture, bytes: Self.pngBytes, format: "png")
        let run = try await runAndTask(fixture)
        let foreign = try await runAndTask(fixture, title: "Foreign run")

        let job = MediaGenerationJob(
            providerID: fixture.providerID, modelID: fixture.modelID,
            mediaKind: .image,
            credentialReference: nil, sourceNodeIDs: [],
            resultNodeID: UUID(), requestJSON: Data("{}".utf8),
            state: .ready, localAssetID: ingested.id)
        _ = try await fixture.jobStore.createJob(
            job, owner: .conversation(run.taskID),
            originRunID: run.runID, idempotencyKey: "\(run.runID):call-1")

        let store = G09R2DesignOwnerProjectStore(root: fixture.root)
        let port = G09R2DesignCreativeDocumentPort(
            assets: fixture.assets,
            envelopes: store,
            runAuthority: G09R2DesignCreativeRunAuthority(
                database: fixture.database))
        let provenance = try await port.verifyFirstResultBinding(
            ownerID: "creative-library",
            requestID: target.sourceID,
            environmentID: nil,
            boundResultID: ingested.id.uuidString.lowercased(),
            bytes: Self.pngBytes,
            format: "png",
            runID: run.runID)
        XCTAssertEqual(provenance, .generationJob)

        let resolved = try await port.resolve(
            ownerID: "creative-library",
            creationID: ingested.id.uuidString.lowercased(),
            environmentID: nil,
            runID: run.runID)
        XCTAssertEqual(resolved.contentSHA256, FloeDigest.sha256Hex(Self.pngBytes))

        // A run that did not submit/own the job is refused.
        do {
            _ = try await port.verifyFirstResultBinding(
                ownerID: "creative-library",
                requestID: target.sourceID,
                environmentID: nil,
                boundResultID: ingested.id.uuidString.lowercased(),
                bytes: Self.pngBytes,
                format: "png",
                runID: foreign.runID)
            XCTFail("a foreign run must not present another run's job link")
        } catch let error as DesignTargetError {
            guard case .notAuthorized = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        do {
            _ = try await port.resolve(
                ownerID: "creative-library",
                creationID: ingested.id.uuidString.lowercased(),
                environmentID: nil,
                runID: foreign.runID)
            XCTFail("a foreign run must not read the asset")
        } catch let error as DesignTargetError {
            guard case .notAuthorized = error else {
                return XCTFail("unexpected error \(error)")
            }
        }

        // The approved owner-task namespace still authorizes a pending request.
        let ownTaskAuthorized = await port.requestIsAuthorized(
            ownerID: run.taskID.uuidString,
            requestID: target.sourceID,
            environmentID: nil,
            runID: run.runID)
        XCTAssertTrue(ownTaskAuthorized)
        let foreignRequestAuthorized = await port.requestIsAuthorized(
            ownerID: "creative-library",
            requestID: UUID().uuidString,
            environmentID: nil,
            runID: foreign.runID)
        XCTAssertFalse(foreignRequestAuthorized)

        // A run of the SAME task that did not submit the job must be able to
        // read only through the persisted trusted-UI binding (origin task +
        // bound result + live digest), not through a claimed owner string.
        let envelopeTarget = creativeTarget(originConversationID: run.taskID.uuidString)
        let envelopeBinding = creativeBinding(envelopeTarget)
        _ = try await fixture.design.bind(G09R2DesignBindRequest(
            binding: envelopeBinding, expectedRevision: 0,
            opID: "creative-provenance-bind"))
        // A DIFFERENT asset that no generation job links: the only possible
        // run authorization is the persisted trusted-UI binding for this task.
        let envelopeBytes = Data("envelope-only asset bytes".utf8)
        let envelopeAsset = try await ingest(
            fixture, bytes: envelopeBytes, format: "png",
            fileName: "envelope.png")
        let state = try await fixture.design.state(envelopeBinding)
        let staged = try stage(
            fixture, sessionToken: envelopeBinding.sessionToken,
            data: envelopeBytes, format: "png")
        let first = try await fixture.design.bindCreativeFirstResult(
            G09R2DesignCreativeBindRequest(
                binding: envelopeBinding,
                expectedRevision: state.envelope.revision,
                opID: "creative-provenance-first",
                boundResultID: envelopeAsset.id.uuidString.lowercased(),
                payload: staged),
            trustedUI: true)
        XCTAssertEqual(first.envelope.creativeFirstResultProvenance,
                       .trustedUIManualImport)
        // The exact task's run may read the trusted-UI-selected result.
        _ = try await port.resolve(
            ownerID: "creative-library",
            creationID: envelopeAsset.id.uuidString.lowercased(),
            environmentID: nil,
            runID: run.runID)
        // A DIFFERENT run of the same task (no job link of its own) is still
        // authorized by the persisted trusted-UI provenance for that task.
        let sameTaskRunID = UUID()
        try await fixture.runStore.saveRun(RunRecord(
            id: sameTaskRunID, conversationID: run.taskID, state: "running",
            goal: "same task", startedAt: Date()))
        let viaEnvelope = try await port.resolve(
            ownerID: "creative-library",
            creationID: envelopeAsset.id.uuidString.lowercased(),
            environmentID: nil,
            runID: sameTaskRunID)
        XCTAssertEqual(
            viaEnvelope.contentSHA256, FloeDigest.sha256Hex(envelopeBytes))
    }

    func testCreativeRunCanBeginAndBindItsOwnDurableJobResult() async throws {
        let fixture = try await makeFixture()
        let run = try await runAndTask(fixture, title: "Run-created creative")
        let target = DesignTarget(
            kind: .creativeDocument,
            ownerID: run.taskID.uuidString.lowercased(),
            sourceID: UUID().uuidString.lowercased(),
            originConversationID: run.taskID.uuidString,
            requestedOutputKind: .image)
        let binding = G09R2DesignBindingDTO(
            target: target,
            storage: G09StorageLayerDTO(kind: .appOwned),
            sessionToken: "creative-run-session")
        let begun = try await fixture.design.beginCreativeRequest(
            G09R2DesignCreativeBeginRequest(
                binding: binding,
                expectedRevision: nil,
                opID: "creative-run-begin-1",
                brief: DesignBrief(goal: "Run-owned image")),
            runID: run.runID)
        XCTAssertEqual(begun.envelope.project.creativeRequest?.state,
                       .awaitingFirstResult)
        XCTAssertEqual(begun.envelope.project.creativeRequest?.requestedKind,
                       .image)

        let ingested = try await ingest(
            fixture, bytes: Self.pngBytes, format: "png")
        // Mirror the REAL generation21 shape: the job is document-owned and
        // carries the chat origin task in its durable request payload. The
        // job's localAssetID is the actual asset link.
        let job = MediaGenerationJob(
            providerID: fixture.providerID, modelID: fixture.modelID,
            mediaKind: .image,
            credentialReference: nil, sourceNodeIDs: [],
            resultNodeID: UUID(),
            requestJSON: Data(
                "{\"originKind\":\"chat\",\"originOwnerID\":\"\(run.taskID.uuidString)\"}".utf8),
            state: .ready, localAssetID: ingested.id)
        _ = try await fixture.jobStore.createJob(
            job, owner: .document(UUID()), originRunID: nil,
            idempotencyKey: "\(run.runID):call-run")
        let staged = try stage(
            fixture, sessionToken: binding.sessionToken,
            data: Self.pngBytes, format: "png")
        let bound = try await fixture.design.bindCreativeFirstResult(
            G09R2DesignCreativeBindRequest(
                binding: binding,
                expectedRevision: begun.envelope.revision,
                opID: "creative-run-bind-1",
                boundResultID: ingested.id.uuidString.lowercased(),
                payload: staged),
            runID: run.runID)
        XCTAssertEqual(bound.envelope.project.creativeRequest?.state,
                       .firstResultBound)
        XCTAssertEqual(bound.envelope.creativeFirstResultProvenance,
                       .generationJob)
    }

    func testVerifiedLocalBytesRejectsEscapingPathAndOversizeRow() async throws {
        let fixture = try await makeFixture()
        let bad = CreativeAssetRecord(
            id: UUID(), contentHash: FloeDigest.sha256Hex(Self.pngBytes),
            kind: .image, displayName: "escape.png",
            mimeType: "image/png", localRelativePath: "../escape.png",
            byteCount: Int64(Self.pngBytes.count))
        _ = try await fixture.assetStore.saveResolvingCanonical(bad)
        do {
            _ = try await fixture.assets.verifiedLocalBytes(id: bad.id)
            XCTFail("a traversing asset path must be refused")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error, .assetReferenceInvalid)
        }
    }

    // MARK: - Trusted restructure claim / burn

    private func prepareProposeConfirmation(
        _ fixture: Fixture,
        binding: G09R2DesignBindingDTO,
        artifactID: String,
        baseRevisionID: String,
        opID: String,
        constraints: DesignPreservationConstraints
    ) async throws -> (confirmation: G09R2DesignTrustedConfirmationDTO,
                       request: DesignRestructureAuthorityRequest) {
        let input = G09R2DesignAuthorityPrepareInput(
            binding: binding,
            operationKind: .propose,
            opID: opID,
            artifactID: artifactID,
            baseRevisionID: baseRevisionID,
            preservation: constraints)
        let confirmation = try await fixture.design.prepareTrustedRestructure(input)
        let status = await fixture.design.confirmTrustedRestructure(
            token: confirmation.token)
        XCTAssertEqual(status, G09R2DesignAuthorityStatus.ok)
        return (confirmation,
                DesignRestructureAuthorityRequest(
                    targetKey: confirmation.targetKey,
                    operationID: confirmation.operationID,
                    originalTaskOwnerID: confirmation.originalTaskOwnerID,
                    baseRevisionID: confirmation.baseRevisionID,
                    preservationDigest: confirmation.preservationDigest))
    }

    func testTrustedRestructureProposeAdoptBurnsSingleUseGrantAndReplays() async throws {
        let fixture = try await makeFixture()
        let design = fixture.design
        let setup = try await makeWorkspaceFile(fixture)
        _ = try await design.bind(G09R2DesignBindRequest(
            binding: setup.binding, expectedRevision: 0, opID: "restructure-bind"))
        _ = try await design.setBrief(G09R2DesignBriefRequest(
            binding: setup.binding, expectedRevision: 0,
            opID: "restructure-brief", brief: DesignBrief(goal: "Restructure")))
        _ = try await design.freeze(G09R2DesignFreezeRequest(
            binding: setup.binding, expectedRevision: 1,
            opID: "restructure-freeze", inputRevisionID: nil,
            specSHA256: nil, targetRevisionID: nil,
            desiredFormat: "md", workMode: .modify,
            preservationDigest: nil))
        let state = try await design.state(setup.binding)
        let artifact = try XCTUnwrap(state.envelope.project.artifacts.first)
        let base = try XCTUnwrap(
            artifact.revision(artifact.currentRevisionID ?? ""))

        let constraints = DesignPreservationConstraints(
            content: ["Keep the heading"],
            data: ["Keep numbers"],
            behavior: ["Keep links"],
            formatBounds: ["Stays Markdown"])
        let proposeOpID = "restructure-propose-1"
        let prepared = try await prepareProposeConfirmation(
            fixture, binding: setup.binding, artifactID: artifact.id,
            baseRevisionID: base.id, opID: proposeOpID,
            constraints: constraints)
        XCTAssertEqual(prepared.confirmation.preservationDigest,
                       constraints.canonicalDigest)
        XCTAssertEqual(prepared.confirmation.targetKey,
                       state.envelope.project.nodeID)

        let changed = Data("Restructured design\n".utf8)
        let staged = try stage(
            fixture, sessionToken: setup.binding.sessionToken,
            data: changed, format: "md")
        let workIntent = DesignWorkIntent(
            mode: .restructure,
            actualDesiredFormat: "md",
            operationID: proposeOpID)
        let proposed = try await design.propose(G09R2DesignProposeRequest(
            binding: setup.binding,
            expectedRevision: state.envelope.revision,
            opID: proposeOpID,
            artifactID: artifact.id,
            baseRevisionID: base.id,
            payload: staged,
            summary: "Restructure",
            diff: [],
            feedbackIDs: [],
            workIntent: workIntent))
        XCTAssertEqual(proposed.candidate.workMode, .restructure)
        XCTAssertEqual(proposed.candidate.preservationDigest,
                       constraints.canonicalDigest)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.root.artifactStoreURL
                .appendingPathComponent("CreativeIncoming")
                .appendingPathComponent(staged.token).path))

        // A replay of the exact proposal never needs or burns a second claim.
        let replayStaged = try stage(
            fixture, sessionToken: setup.binding.sessionToken,
            data: changed, format: "md")
        let replay = try await design.propose(G09R2DesignProposeRequest(
            binding: setup.binding,
            expectedRevision: state.envelope.revision,
            opID: proposeOpID,
            artifactID: artifact.id,
            baseRevisionID: base.id,
            payload: replayStaged,
            summary: "Restructure",
            diff: [],
            feedbackIDs: [],
            workIntent: workIntent))
        XCTAssertTrue(replay.replayed)

        let adoptOpID = "restructure-adopt-1"
        let adoptInput = G09R2DesignAuthorityPrepareInput(
            binding: setup.binding,
            operationKind: .adopt,
            opID: adoptOpID,
            candidateID: proposed.candidate.id,
            preservation: constraints)
        let adoptConfirmation = try await design.prepareTrustedRestructure(adoptInput)
        let adoptConfirmed = await design.confirmTrustedRestructure(
            token: adoptConfirmation.token)
        XCTAssertEqual(adoptConfirmed, G09R2DesignAuthorityStatus.ok)
        let afterPropose = try await design.state(setup.binding)
        let adopted = try await design.adopt(G09R2DesignAdoptRequest(
            binding: setup.binding,
            expectedRevision: afterPropose.envelope.revision,
            opID: adoptOpID,
            candidateID: proposed.candidate.id,
            mode: .updateOriginal))
        XCTAssertFalse(adopted.idempotent)
        XCTAssertEqual(
            try String(contentsOf: setup.fileURL, encoding: .utf8),
            String(decoding: changed, as: UTF8.self))

        // Replay of the applied adoption is idempotent and does not require a
        // fresh confirmation (the one-shot grant is already burned).
        let adoptReplay = try await design.adopt(G09R2DesignAdoptRequest(
            binding: setup.binding,
            expectedRevision: afterPropose.envelope.revision,
            opID: adoptOpID,
            candidateID: proposed.candidate.id,
            mode: .updateOriginal))
        XCTAssertTrue(adoptReplay.idempotent)
    }

    func testTrustedRestructureRefusesMissingWrongTargetAndWrongDigest() async throws {
        let fixture = try await makeFixture()
        let design = fixture.design
        let setup = try await makeWorkspaceFile(fixture)
        _ = try await design.bind(G09R2DesignBindRequest(
            binding: setup.binding, expectedRevision: 0, opID: "guard-bind"))
        _ = try await design.freeze(G09R2DesignFreezeRequest(
            binding: setup.binding, expectedRevision: 0,
            opID: "guard-freeze", inputRevisionID: nil,
            specSHA256: nil, targetRevisionID: nil,
            desiredFormat: "md", workMode: .modify,
            preservationDigest: nil))
        let state = try await design.state(setup.binding)
        let artifact = try XCTUnwrap(state.envelope.project.artifacts.first)
        let base = try XCTUnwrap(
            artifact.revision(artifact.currentRevisionID ?? ""))
        let constraints = DesignPreservationConstraints(
            content: ["Keep the heading"])

        // Missing confirmation: refused before any candidate/CAS.
        let missingStaged = try stage(
            fixture, sessionToken: setup.binding.sessionToken,
            data: Data("missing".utf8), format: "md")
        do {
            _ = try await design.propose(G09R2DesignProposeRequest(
                binding: setup.binding,
                expectedRevision: state.envelope.revision,
                opID: "guard-propose-missing",
                artifactID: artifact.id,
                baseRevisionID: base.id,
                payload: missingStaged,
                summary: "missing",
                diff: [],
                feedbackIDs: [],
                workIntent: DesignWorkIntent(
                    mode: .restructure, actualDesiredFormat: "md",
                    operationID: "guard-propose-missing")))
            XCTFail("a restructure without a trusted claim must fail closed")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "designConflict")
        }
        let unchanged = try await design.state(setup.binding)
        XCTAssertEqual(unchanged.envelope.revision, state.envelope.revision)
        XCTAssertTrue(unchanged.envelope.project.candidates.isEmpty)

        // Prepare/confirm for target A, then address target B with the same
        // operation id: the record is keyed by the exact target and refuses.
        _ = try await prepareProposeConfirmation(
            fixture, binding: setup.binding, artifactID: artifact.id,
            baseRevisionID: base.id, opID: "guard-propose-wrong-target",
            constraints: constraints)
        let other = try await makeWorkspaceFile(fixture, content: "Other")
        _ = try await design.bind(G09R2DesignBindRequest(
            binding: other.binding, expectedRevision: 0,
            opID: "guard-other-bind"))
        _ = try await design.freeze(G09R2DesignFreezeRequest(
            binding: other.binding, expectedRevision: 0,
            opID: "guard-other-freeze", inputRevisionID: nil,
            specSHA256: nil, targetRevisionID: nil,
            desiredFormat: "md", workMode: .modify,
            preservationDigest: nil))
        let otherState = try await design.state(other.binding)
        let otherArtifact = try XCTUnwrap(otherState.envelope.project.artifacts.first)
        let otherBase = try XCTUnwrap(
            otherArtifact.revision(otherArtifact.currentRevisionID ?? ""))
        let wrongStaged = try stage(
            fixture, sessionToken: other.binding.sessionToken,
            data: Data("wrong target".utf8), format: "md")
        do {
            _ = try await design.propose(G09R2DesignProposeRequest(
                binding: other.binding,
                expectedRevision: otherState.envelope.revision,
                opID: "guard-propose-wrong-target",
                artifactID: otherArtifact.id,
                baseRevisionID: otherBase.id,
                payload: wrongStaged,
                summary: "wrong target",
                diff: [],
                feedbackIDs: [],
                workIntent: DesignWorkIntent(
                    mode: .restructure, actualDesiredFormat: "md",
                    operationID: "guard-propose-wrong-target")))
            XCTFail("a confirmation for another target must not authorize this one")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "designConflict")
        }

        // Adopt prepare refuses constraints whose digest is not the recorded
        // candidate digest (before any grant is minted).
        let changed = Data("Candidate".utf8)
        let staging = try stage(
            fixture, sessionToken: setup.binding.sessionToken,
            data: changed, format: "md")
        let confirmed = try await prepareProposeConfirmation(
            fixture, binding: setup.binding, artifactID: artifact.id,
            baseRevisionID: base.id, opID: "guard-propose-adopt",
            constraints: constraints)
        let proposed = try await design.propose(G09R2DesignProposeRequest(
            binding: setup.binding,
            expectedRevision: unchanged.envelope.revision,
            opID: "guard-propose-adopt",
            artifactID: artifact.id,
            baseRevisionID: base.id,
            payload: staging,
            summary: "adopt guard",
            diff: [],
            feedbackIDs: [],
            workIntent: DesignWorkIntent(
                mode: .restructure, actualDesiredFormat: "md",
                operationID: "guard-propose-adopt")))
        XCTAssertEqual(proposed.candidate.preservationDigest,
                       constraints.canonicalDigest)
        _ = confirmed
        do {
            _ = try await design.prepareTrustedRestructure(
                G09R2DesignAuthorityPrepareInput(
                    binding: setup.binding,
                    operationKind: .adopt,
                    opID: "guard-adopt-digest",
                    candidateID: proposed.candidate.id,
                    preservation: DesignPreservationConstraints(
                        content: ["Different constraints"])))
            XCTFail("adopt must refuse constraints whose digest is not recorded")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "designConflict")
        }
    }

    func testTrustedRestructureStaleBaseIsRefusedBeforeBytesOrCAS() async throws {
        let fixture = try await makeFixture()
        let design = fixture.design
        let setup = try await makeWorkspaceFile(fixture)
        _ = try await design.bind(G09R2DesignBindRequest(
            binding: setup.binding, expectedRevision: 0, opID: "stale-bind"))
        _ = try await design.freeze(G09R2DesignFreezeRequest(
            binding: setup.binding, expectedRevision: 0,
            opID: "stale-freeze", inputRevisionID: nil,
            specSHA256: nil, targetRevisionID: nil,
            desiredFormat: "md", workMode: .modify,
            preservationDigest: nil))
        let before = try await design.state(setup.binding)
        let artifact = try XCTUnwrap(before.envelope.project.artifacts.first)
        let oldBase = try XCTUnwrap(
            artifact.revision(artifact.currentRevisionID ?? ""))

        // A normal modify proposal + adoption moves the current revision.
        let modifyStaged = try stage(
            fixture, sessionToken: setup.binding.sessionToken,
            data: Data("Modify first\n".utf8), format: "md")
        let modifyProposal = try await design.propose(G09R2DesignProposeRequest(
            binding: setup.binding,
            expectedRevision: before.envelope.revision,
            opID: "stale-modify-propose",
            artifactID: artifact.id,
            baseRevisionID: oldBase.id,
            payload: modifyStaged,
            summary: "modify first",
            diff: [],
            feedbackIDs: [],
            workIntent: nil))
        let afterModify = try await design.state(setup.binding)
        _ = try await design.adopt(G09R2DesignAdoptRequest(
            binding: setup.binding,
            expectedRevision: afterModify.envelope.revision,
            opID: "stale-modify-adopt",
            candidateID: modifyProposal.candidate.id,
            mode: .updateOriginal))
        let moved = try await design.state(setup.binding)
        let movedArtifact = try XCTUnwrap(moved.envelope.project.artifacts.first)
        let newBase = try XCTUnwrap(
            movedArtifact.revision(movedArtifact.currentRevisionID ?? ""))
        XCTAssertNotEqual(newBase.id, oldBase.id)

        let constraints = DesignPreservationConstraints(
            content: ["Keep the heading"])
        let prepared = try await prepareProposeConfirmation(
            fixture, binding: setup.binding, artifactID: movedArtifact.id,
            baseRevisionID: newBase.id, opID: "stale-propose",
            constraints: constraints)
        XCTAssertEqual(prepared.request.baseRevisionID, newBase.id)

        let restaged = try stage(
            fixture, sessionToken: setup.binding.sessionToken,
            data: Data("Restructure from a stale base\n".utf8), format: "md")
        do {
            _ = try await design.propose(G09R2DesignProposeRequest(
                binding: setup.binding,
                expectedRevision: moved.envelope.revision,
                opID: "stale-propose",
                artifactID: movedArtifact.id,
                baseRevisionID: oldBase.id,
                payload: restaged,
                summary: "stale",
                diff: [],
                feedbackIDs: [],
                workIntent: DesignWorkIntent(
                    mode: .restructure, actualDesiredFormat: "md",
                    operationID: "stale-propose")))
            XCTFail("a confirmation for a newer base must not authorize an old base")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "designConflict")
        }
        let after = try await design.state(setup.binding)
        XCTAssertEqual(after.envelope.revision, moved.envelope.revision)
        XCTAssertFalse(after.envelope.project.candidates.contains {
            $0.proposalOperationID == "stale-propose"
        })
    }

    func testTrustedRestructureExpiryAndRootStopRefuseLateClaims() async throws {
        let fixture = try await makeFixture()
        let design = fixture.design
        let setup = try await makeWorkspaceFile(fixture)
        _ = try await design.bind(G09R2DesignBindRequest(
            binding: setup.binding, expectedRevision: 0, opID: "expiry-bind"))
        _ = try await design.freeze(G09R2DesignFreezeRequest(
            binding: setup.binding, expectedRevision: 0,
            opID: "expiry-freeze", inputRevisionID: nil,
            specSHA256: nil, targetRevisionID: nil,
            desiredFormat: "md", workMode: .modify,
            preservationDigest: nil))
        let state = try await design.state(setup.binding)
        let artifact = try XCTUnwrap(state.envelope.project.artifacts.first)
        let base = try XCTUnwrap(
            artifact.revision(artifact.currentRevisionID ?? ""))
        let constraints = DesignPreservationConstraints(
            content: ["Keep the heading"])
        let input = G09R2DesignAuthorityPrepareInput(
            binding: setup.binding, operationKind: .propose,
            opID: "expiry-propose", artifactID: artifact.id,
            baseRevisionID: base.id, preservation: constraints)
        let confirmation = try await design.prepareTrustedRestructure(input)
        let firstConfirmed = await design.confirmTrustedRestructure(
            token: confirmation.token)
        XCTAssertEqual(firstConfirmed, G09R2DesignAuthorityStatus.ok)

        fixture.clock.advance(6 * 60.0)
        let staged = try stage(
            fixture, sessionToken: setup.binding.sessionToken,
            data: Data("late".utf8), format: "md")
        do {
            _ = try await design.propose(G09R2DesignProposeRequest(
                binding: setup.binding,
                expectedRevision: state.envelope.revision,
                opID: "expiry-propose",
                artifactID: artifact.id,
                baseRevisionID: base.id,
                payload: staged,
                summary: "late",
                diff: [],
                feedbackIDs: [],
                workIntent: DesignWorkIntent(
                    mode: .restructure, actualDesiredFormat: "md",
                    operationID: "expiry-propose")))
            XCTFail("an expired confirmation must be refused")
        } catch let error as G09R2Error {
            XCTAssertEqual(error.code, "designConflict")
        }

        // Root stop retires the authority: even a freshly confirmed record
        // cannot be used after the generation is fenced.
        let input2 = G09R2DesignAuthorityPrepareInput(
            binding: setup.binding, operationKind: .propose,
            opID: "root-stop-propose", artifactID: artifact.id,
            baseRevisionID: base.id, preservation: constraints)
        let confirmation2 = try await design.prepareTrustedRestructure(input2)
        let secondConfirmed = await design.confirmTrustedRestructure(
            token: confirmation2.token)
        XCTAssertEqual(secondConfirmed, G09R2DesignAuthorityStatus.ok)
        _ = await design.requestRootStop(epoch: fixture.epoch)
        let afterStop = await design.confirmTrustedRestructure(
            token: confirmation2.token)
        XCTAssertEqual(afterStop, G09R2DesignAuthorityStatus.retired)
        do {
            _ = try await design.propose(G09R2DesignProposeRequest(
                binding: setup.binding,
                expectedRevision: state.envelope.revision,
                opID: "root-stop-propose",
                artifactID: artifact.id,
                baseRevisionID: base.id,
                payload: staged,
                summary: "root stop",
                diff: [],
                feedbackIDs: [],
                workIntent: DesignWorkIntent(
                    mode: .restructure, actualDesiredFormat: "md",
                    operationID: "root-stop-propose")))
            XCTFail("design work after Root stop must fail closed")
        } catch let error as G09CreativeError {
            XCTAssertEqual(error, .staleGeneration)
        }
    }
}
