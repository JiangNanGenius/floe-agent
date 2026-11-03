// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 agent generation lifecycle tests (job-6b686caa5ffe4761).
// Authored source; executed by Main's combined gate (this lane performs NO
// build/test execution). They exercise the conversation-owned agent
// generation lifecycle against temporary explicit roots and an in-memory
// GRDB database with synthetic provider adapters — no network, no device,
// no provider call:
//
//  * operation identity: provider call id preferred; the no-call-id fallback
//    is deterministic (replay attaches to the SAME durable job) and distinct
//    per request — never a random UUID;
//  * video option validation rides the REAL `VideoModelRegistry` contract
//    (audio supported for the Ark Seedance family) instead of the guessed
//    catalog-DTO reconstruction whose `codecs` list is always empty;
//  * the accepted provider task ID is persisted BEFORE any poll await and
//    the provider outcome settles truthfully;
//  * cancel is honest: provider-confirmed, locally settled without a task
//    ID, and a provider-cancel failure is an error that leaves the row
//    non-terminal;
//  * reference images are refused on symlink escape / traversal / oversize
//    BEFORE any provider dispatch (rooted `WorkspacePathGuard`, not a
//    lexical prefix check);
//  * generated image extensions follow the sniffed bytes (JPEG bytes are
//    never committed with a lying `.png` name);
//  * a replayed identical submission deduplicates onto the SAME durable job
//    (no duplicate paid submission).
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloePersistence
import FloeProviders

final class G09R2AgentGenerationLifecycleTests: XCTestCase {
    private var roots: [URL] = []
    private var databases: [DatabaseManager] = []
    private static let epochLock = NSLock()
    nonisolated(unsafe) private static var epochCounter: UInt64 = 40_000

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

    // MARK: - Fixtures

    /// A real 1x1 RGBA PNG (valid bytes, not a text placeholder).
    private static let pngBytes = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
        0x54, 0x78, 0xDA, 0x62, 0xFA, 0xFF, 0xFF, 0x3F,
        0x00, 0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59,
        0xE7, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    /// A minimal but valid 1x1 baseline-JPEG header (SOI + SOF0).
    private static let jpegBytes = Data([
        0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08,
        0x00, 0x01, 0x00, 0x01, 0x03,
        0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
    ])

    private struct Fixture {
        let service: G09R2AgentGenerationService
        let root: RuntimeStorageRoot
        let rootURL: URL
        let workspaceURL: URL
        let database: DatabaseManager
        let configuration: ModelConfigurationStore
        let jobStore: MediaGenerationJobStore
        let epoch: UInt64
        let conversationID: UUID
        let runID: UUID
        let providerID: UUID
        let modelID: UUID
        let imageAdapter: FakeImageAdapter
        let videoAdapter: FakeVideoAdapter
    }

    private final class FakeImageAdapter: ImageProviderAdapter, @unchecked Sendable {
        private let lock = NSLock()
        private var _performCount = 0
        private var _receivedSourceImages: [Data] = []
        var resultImages: [Data] = []

        var performCount: Int { lock.lock(); defer { lock.unlock() }; return _performCount }
        var receivedSourceImages: [Data] {
            lock.lock(); defer { lock.unlock() }; return _receivedSourceImages
        }

        func supportedOperations(for provider: ProviderProfile) -> Set<RemoteImageOperation> {
            [.generate, .edit]
        }

        func maximumSourceImages(
            for operation: RemoteImageOperation, modelRemoteID: String?
        ) -> Int { 1 }

        func maximumOutputImages(modelRemoteID: String?) -> Int { 4 }

        func perform(
            _ request: RemoteImageRequest,
            provider: ProviderProfile,
            credentials: ProviderCredentials
        ) async throws -> RemoteImageResult {
            lock.withLock {
                _performCount += 1
                _receivedSourceImages = request.sourceImages
            }
            return RemoteImageResult(images: resultImages)
        }
    }

    private final class FakeVideoAdapter: VideoProviderAdapter, @unchecked Sendable {
        private let lock = NSLock()
        private var _submitCount = 0
        private var _cancelCount = 0
        var submission: RemoteVideoSubmission
        var statusHandler: (String) async throws -> RemoteVideoStatus = { _ in
            Self.makeStatus(state: .failed, error: "syntheticFailure")
        }
        var cancelError: Error?

        var submitCount: Int { lock.lock(); defer { lock.unlock() }; return _submitCount }
        var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return _cancelCount }

        init(submission: RemoteVideoSubmission) {
            self.submission = submission
        }

        /// `RemoteVideoStatus` exposes no public initializer; its public
        /// Codable conformance is the stable construction seam.
        static func makeStatus(
            state: MediaGenerationJobState, error: String? = nil,
            resultURL: URL? = nil
        ) -> RemoteVideoStatus {
            var json: [String: Any] = ["state": state.rawValue]
            if let error { json["error"] = error }
            if let resultURL { json["resultURL"] = resultURL.absoluteString }
            let data = try! JSONSerialization.data(withJSONObject: json)
            return try! JSONDecoder().decode(RemoteVideoStatus.self, from: data)
        }

        func submit(
            _ request: RemoteVideoRequest,
            provider: ProviderProfile,
            credentials: ProviderCredentials
        ) async throws -> RemoteVideoSubmission {
            lock.withLock { _submitCount += 1 }
            return submission
        }

        func status(
            taskID: String, modelRemoteID: String,
            provider: ProviderProfile, credentials: ProviderCredentials
        ) async throws -> RemoteVideoStatus {
            try await statusHandler(taskID)
        }

        func cancel(
            taskID: String, provider: ProviderProfile,
            credentials: ProviderCredentials
        ) async throws {
            lock.withLock { _cancelCount += 1 }
            if let cancelError { throw cancelError }
        }
    }

    private func makeFixture(
        modelRemoteID: String = "gpt-image-1",
        video: Bool = false
    ) async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-agent-generation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        databases.append(manager)
        let conversationID = UUID()
        // The ORIGINAL durable conversation→workspace ownership the run's
        // workspace root comes from. Submission pins this exact binding, so
        // the fixture must register a real private-task workspace instead of
        // pointing at an arbitrary directory.
        let conversationStore = ConversationStore(database: manager)
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "Synthetic task",
            createdAt: Date(), updatedAt: Date()))
        let workspaceStore = SQLiteWorkspaceStore(database: manager)
        let workspaceRecord = try await workspaceStore.ensureWorkspace(
            conversationID: conversationID, title: "Synthetic task")
        let workspace = url
            .appendingPathComponent("Workspace", isDirectory: true)
            .appendingPathComponent(
                workspaceRecord.internalRelativePath ?? "PrivateTasks/\(conversationID.uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let configuration = ModelConfigurationStore(database: manager)
        let provider = ProviderProfile(
            kind: video ? .volcengineArk : .openAI,
            // The wire protocol value is inert for these tests: adapters and
            // contracts are injected/resolved from the provider kind and the
            // remote model ID, so the synthetic provider speaks the ordinary
            // chat-completions protocol.
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: video ? "https://ark-synthetic.example/api/v3" : "https://synthetic.example/v1")!,
            displayName: "Synthetic Provider", isEnabled: true)
        try await configuration.saveProvider(provider)
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: modelRemoteID,
            displayName: "Synthetic model",
            limits: ModelLimits(contextTokens: 4_096, maxOutputTokens: 256),
            capabilities: video ? [.videoGeneration] : [.imageGeneration],
            useSurfaces: video ? [.videoGeneration] : [.imageGeneration],
            isEnabled: true)
        try await configuration.saveModel(model)
        let root = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        let environment = G09R2GenerationEnvironment(
            root: root, database: manager, configuration: configuration)
        let imageAdapter = FakeImageAdapter()
        let videoAdapter = FakeVideoAdapter(submission: RemoteVideoSubmission(
            providerTaskID: "synthetic-task-1"))
        let platform = G09R2GenerationPlatform(
            imageAdapter: { _ in video ? nil : imageAdapter },
            videoAdapter: { _ in video ? videoAdapter : nil },
            credentials: { _ in ProviderCredentials(apiKey: "synthetic-key") },
            download: { url, destination, _ in
                throw G09R2Error(.providerRejected, detail: "downloadUnused")
            })
        let service = G09R2AgentGenerationService(
            platform: platform, environmentProvider: { _ in environment })
        return Fixture(
            service: service, root: root, rootURL: url, workspaceURL: workspace,
            database: manager, configuration: configuration,
            jobStore: MediaGenerationJobStore(database: manager),
            epoch: Self.nextEpoch(), conversationID: conversationID, runID: UUID(),
            providerID: provider.id, modelID: model.id,
            imageAdapter: imageAdapter, videoAdapter: videoAdapter)
    }

    /// Waits until the durable job reaches a terminal state or the bounded
    /// synthetic budget elapses.
    private func waitForTerminal(
        _ store: MediaGenerationJobStore, jobID: UUID, timeout: TimeInterval = 8
    ) async throws -> OwnedMediaGenerationJob? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let owned = try await store.ownedJob(id: jobID),
               owned.job.state.isTerminal {
                return owned
            }
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        return try await store.ownedJob(id: jobID)
    }

    private func payloadData(_ payload: G09R2AgentGenerationPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    // MARK: - Operation identity

    func testIdempotencyKeyPrefersProviderCallID() {
        let runID = UUID()
        let key = G09R2AgentGenerationService.idempotencyKey(
            runID: runID, toolCallID: "call-7", requestDigest: "ignored")
        XCTAssertEqual(key, "\(runID.uuidString):call-7")
    }

    func testIdempotencyKeyFallbackIsDeterministicAndDistinct() {
        let runID = UUID()
        let first = G09R2AgentGenerationService.idempotencyKey(
            runID: runID, toolCallID: nil, requestDigest: "digest-a")
        let replay = G09R2AgentGenerationService.idempotencyKey(
            runID: runID, toolCallID: nil, requestDigest: "digest-a")
        let distinct = G09R2AgentGenerationService.idempotencyKey(
            runID: runID, toolCallID: nil, requestDigest: "digest-b")
        XCTAssertEqual(first, replay, "a replayed identical request must attach to the SAME job")
        XCTAssertNotEqual(first, distinct, "a distinct request must never merge into another job")
        XCTAssertTrue(first.hasPrefix("\(runID.uuidString):agent-generation:"))
        // Whitespace-only call ids are absent ids.
        let blank = G09R2AgentGenerationService.idempotencyKey(
            runID: runID, toolCallID: "   ", requestDigest: "digest-a")
        XCTAssertEqual(blank, first)
    }

    // MARK: - Video option validation against the real contract

    func testVideoOptionsUseRealContractNotGuessedCatalogCodecs() async throws {
        // Regression: the catalog DTO's `codecs` list is ALWAYS empty, so the
        // removed `videoRoute` reconstruction advertised supportsAudio=false
        // and rejected every legitimate audio request. The service now
        // validates against `VideoModelRegistry.contract`, where the Ark
        // Seedance family documents audio support.
        let fixture = try await makeFixture(
            modelRemoteID: "doubao-seedance-2-5-260628", video: true)
        let catalog = try await fixture.service.catalog(epoch: fixture.epoch)
        let route = try XCTUnwrap(catalog.video.first)
        XCTAssertTrue(route.parameters.codecs.isEmpty, "catalog projection carries no codec list")
        let contract = VideoModelRegistry.contract(
            model: try await fixture.configuration.models().first!,
            provider: try await fixture.configuration.providers().first!)
        XCTAssertTrue(contract.supportsAudio)
        let options = try VideoRequestValidator.validate(
            VideoGenerationOptions(includeAudio: true),
            contract: contract, modelRemoteID: route.remoteModelID)
        XCTAssertEqual(options.includeAudio, true)
    }

    // MARK: - Submit / persist / settle

    func testSubmitVideoPersistsProviderTaskIDAndSettlesTruthfully() async throws {
        let fixture = try await makeFixture(video: true)
        let summary = try await fixture.service.submitVideo(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: "key-\(UUID().uuidString)",
            workspaceRootURL: fixture.workspaceURL,
            prompt: "a synthetic clip",
            selection: nil, legacyModelID: nil,
            aspectRatio: nil, resolution: nil, durationSeconds: nil,
            includeAudio: nil, watermark: nil, seed: nil,
            referenceRelativePath: nil)
        XCTAssertEqual(summary.deduplicated, false)
        let terminal = try await waitForTerminal(fixture.jobStore, jobID: summary.jobID)
        let owned = try XCTUnwrap(terminal)
        // The accepted provider task identity was persisted BEFORE the poll.
        XCTAssertEqual(owned.job.providerTaskID, "synthetic-task-1")
        // The synthetic status answers failed; the row settles failed, never
        // a false ready/cancelled.
        XCTAssertEqual(owned.job.state, .failed)
        XCTAssertEqual(fixture.videoAdapter.submitCount, 1)
    }

    func testReplayedIdenticalSubmitDeduplicatesOntoSameJob() async throws {
        let fixture = try await makeFixture(video: true)
        let key = "key-\(UUID().uuidString)"
        let first = try await fixture.service.submitVideo(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: key,
            workspaceRootURL: fixture.workspaceURL,
            prompt: "a synthetic clip",
            selection: nil, legacyModelID: nil,
            aspectRatio: nil, resolution: nil, durationSeconds: nil,
            includeAudio: nil, watermark: nil, seed: nil,
            referenceRelativePath: nil)
        let replay = try await fixture.service.submitVideo(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: key,
            workspaceRootURL: fixture.workspaceURL,
            prompt: "a synthetic clip",
            selection: nil, legacyModelID: nil,
            aspectRatio: nil, resolution: nil, durationSeconds: nil,
            includeAudio: nil, watermark: nil, seed: nil,
            referenceRelativePath: nil)
        XCTAssertEqual(replay.jobID, first.jobID)
        XCTAssertTrue(replay.deduplicated)
        _ = try await waitForTerminal(fixture.jobStore, jobID: first.jobID)
        XCTAssertEqual(fixture.videoAdapter.submitCount, 1, "a replay must never pay twice")
    }

    // MARK: - Cancel honesty

    func testCancelWithoutProviderTaskIDSettlesCancelled() async throws {
        let fixture = try await makeFixture()
        let payload = G09R2AgentGenerationPayload(
            prompt: "synthetic", routeID: fixture.modelID.uuidString.lowercased(),
            providerID: fixture.providerID, modelID: fixture.modelID,
            remoteModelID: "gpt-image-1", count: 1)
        let job = MediaGenerationJob(
            providerID: fixture.providerID, modelID: fixture.modelID,
            mediaKind: .image, credentialReference: nil,
            sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: try payloadData(payload))
        let creation = try await fixture.jobStore.createJob(
            job, owner: .conversation(fixture.conversationID),
            originRunID: fixture.runID, idempotencyKey: "key-\(UUID().uuidString)")
        let status = try await fixture.service.cancel(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: creation.job.id)
        XCTAssertEqual(status.state, .cancelled)
    }

    func testCancelWithProviderTaskRefusesWhenProviderCancelFails() async throws {
        let fixture = try await makeFixture(video: true)
        fixture.videoAdapter.cancelError = FloeError.validationFailed("providerRefused")
        let payload = G09R2AgentGenerationPayload(
            prompt: "synthetic", routeID: fixture.modelID.uuidString.lowercased(),
            providerID: fixture.providerID, modelID: fixture.modelID,
            remoteModelID: "doubao-seedance-2-5-260628", count: 1)
        let job = MediaGenerationJob(
            providerID: fixture.providerID, modelID: fixture.modelID,
            mediaKind: .video, credentialReference: nil,
            sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: try payloadData(payload),
            state: .submitted)
        var submitted = job
        submitted.providerTaskID = "task-cancel"
        let creation = try await fixture.jobStore.createJob(
            submitted, owner: .conversation(fixture.conversationID),
            originRunID: fixture.runID, idempotencyKey: "key-\(UUID().uuidString)")
        do {
            _ = try await fixture.service.cancel(
                epoch: fixture.epoch, conversationID: fixture.conversationID,
                jobID: creation.job.id)
            XCTFail("a provider cancel failure must throw, never report success")
        } catch {
            // expected
        }
        let fetched = try await fixture.jobStore.ownedJob(id: creation.job.id)
        let owned = try XCTUnwrap(fetched)
        XCTAssertFalse(owned.job.state == .cancelled,
                       "a failed provider cancel must NOT mark the job cancelled")
        XCTAssertEqual(fixture.videoAdapter.cancelCount, 1)
    }

    func testCancelProviderConfirmedSettlesCancelled() async throws {
        let fixture = try await makeFixture(video: true)
        let payload = G09R2AgentGenerationPayload(
            prompt: "synthetic", routeID: fixture.modelID.uuidString.lowercased(),
            providerID: fixture.providerID, modelID: fixture.modelID,
            remoteModelID: "doubao-seedance-2-5-260628", count: 1)
        let job = MediaGenerationJob(
            providerID: fixture.providerID, modelID: fixture.modelID,
            mediaKind: .video, credentialReference: nil,
            sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: try payloadData(payload),
            state: .submitted)
        var submitted = job
        submitted.providerTaskID = "task-cancel-ok"
        let creation = try await fixture.jobStore.createJob(
            submitted, owner: .conversation(fixture.conversationID),
            originRunID: fixture.runID, idempotencyKey: "key-\(UUID().uuidString)")
        let status = try await fixture.service.cancel(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: creation.job.id)
        XCTAssertEqual(status.state, .cancelled)
        XCTAssertEqual(fixture.videoAdapter.cancelCount, 1)
    }

    // MARK: - Reference image authority (no lexical-only checks)

    func testReferenceImageSymlinkEscapeRefusedBeforeDispatch() async throws {
        let fixture = try await makeFixture()
        // A symlink inside the workspace that points OUT of the workspace.
        let outside = fixture.rootURL.appendingPathComponent("outside.png")
        try Self.pngBytes.write(to: outside)
        let link = fixture.workspaceURL.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(
            atPath: link.path, withDestinationPath: outside.path)
        do {
            _ = try await fixture.service.submitImage(
                epoch: fixture.epoch,
                conversationID: fixture.conversationID,
                runID: fixture.runID,
                idempotencyKey: "key-\(UUID().uuidString)",
                workspaceRootURL: fixture.workspaceURL,
                prompt: "edit this", selection: nil, legacyModelID: nil,
                count: 1, size: nil, aspectRatio: nil, resolution: nil,
                quality: nil, referenceRelativePath: "link.png")
            XCTFail("a symlink escape must be refused before any provider dispatch")
        } catch {
            // expected
        }
        XCTAssertEqual(fixture.imageAdapter.performCount, 0)
    }

    func testReferenceImageTraversalRefusedBeforeDispatch() async throws {
        let fixture = try await makeFixture()
        do {
            _ = try await fixture.service.submitImage(
                epoch: fixture.epoch,
                conversationID: fixture.conversationID,
                runID: fixture.runID,
                idempotencyKey: "key-\(UUID().uuidString)",
                workspaceRootURL: fixture.workspaceURL,
                prompt: "edit this", selection: nil, legacyModelID: nil,
                count: 1, size: nil, aspectRatio: nil, resolution: nil,
                quality: nil, referenceRelativePath: "../root/anything.png")
            XCTFail("a traversal path must be refused before any provider dispatch")
        } catch {
            // expected
        }
        XCTAssertEqual(fixture.imageAdapter.performCount, 0)
    }

    func testReferenceImageOversizeRefusedBeforeRead() async throws {
        let fixture = try await makeFixture()
        // Larger than the 12 MiB image-source bound; size is asserted BEFORE
        // the bytes are read.
        let oversized = fixture.workspaceURL.appendingPathComponent("big.png")
        let chunk = Data(repeating: 0, count: 1_048_576)
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        for _ in 0..<13 { try handle.write(contentsOf: chunk) }
        try handle.close()
        do {
            _ = try await fixture.service.submitImage(
                epoch: fixture.epoch,
                conversationID: fixture.conversationID,
                runID: fixture.runID,
                idempotencyKey: "key-\(UUID().uuidString)",
                workspaceRootURL: fixture.workspaceURL,
                prompt: "edit this", selection: nil, legacyModelID: nil,
                count: 1, size: nil, aspectRatio: nil, resolution: nil,
                quality: nil, referenceRelativePath: "big.png")
            XCTFail("an oversized reference must be refused")
        } catch {
            // expected
        }
        XCTAssertEqual(fixture.imageAdapter.performCount, 0)
    }

    func testReferenceImageAcceptedThroughRootedGuard() async throws {
        let fixture = try await makeFixture()
        let reference = fixture.workspaceURL.appendingPathComponent("ref.png")
        try Self.pngBytes.write(to: reference)
        fixture.imageAdapter.resultImages = [Self.pngBytes]
        let summary = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: "key-\(UUID().uuidString)",
            workspaceRootURL: fixture.workspaceURL,
            prompt: "edit this", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: "ref.png")
        _ = try await waitForTerminal(fixture.jobStore, jobID: summary.jobID)
        XCTAssertEqual(fixture.imageAdapter.performCount, 1)
        XCTAssertEqual(fixture.imageAdapter.receivedSourceImages, [Self.pngBytes])
    }

    // MARK: - Delivery extensions follow the sniffed bytes

    func testGeneratedImageExtensionFollowsSniffedBytes() async throws {
        let fixture = try await makeFixture()
        // JPEG provider bytes must NOT be committed with a lying `.png` name.
        fixture.imageAdapter.resultImages = [Self.jpegBytes]
        let summary = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: "key-\(UUID().uuidString)",
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a square", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        let fetched = try await fixture.jobStore.ownedJob(id: summary.jobID)
        let owned = try XCTUnwrap(fetched)
        XCTAssertEqual(owned.job.state, .ready)
        let payload = try JSONDecoder().decode(
            G09R2AgentGenerationPayload.self, from: owned.job.requestJSON)
        let path = try XCTUnwrap(payload.workspaceRelativePath)
        XCTAssertTrue(path.hasSuffix(".jpg"), "extension must follow the sniffed JPEG bytes, got \(path)")
        // Single-artifact results keep the honest legacy scalar view AND the
        // typed artifact receipt.
        let artifact = try XCTUnwrap(payload.artifacts?.first)
        XCTAssertEqual(artifact.relativePath, path)
        XCTAssertEqual(artifact.mimeType, "image/jpeg")
        XCTAssertEqual(artifact.byteCount, payload.deliveredByteCount)
        XCTAssertEqual(artifact.sha256, payload.deliveredSHA256)
        let delivered = fixture.workspaceURL.appendingPathComponent(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: delivered.path))
        XCTAssertEqual(
            try FloeDigest.sha256Hex(ofFileAt: delivered),
            try XCTUnwrap(payload.deliveredSHA256))
    }

    /// Two-image batches persist a typed per-artifact array (real path, MIME,
    /// bytes, individual hash); the legacy scalar fields stay nil instead of
    /// smuggling a comma-joined fake path/digest.
    func testTwoImageBatchPersistsTypedArtifactArray() async throws {
        let fixture = try await makeFixture()
        fixture.imageAdapter.resultImages = [Self.pngBytes, Self.jpegBytes]
        let summary = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: "key-\(UUID().uuidString)",
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw two squares", selection: nil, legacyModelID: nil,
            count: 2, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        let fetched = try await fixture.jobStore.ownedJob(id: summary.jobID)
        let owned = try XCTUnwrap(fetched)
        XCTAssertEqual(owned.job.state, .ready)
        let payload = try JSONDecoder().decode(
            G09R2AgentGenerationPayload.self, from: owned.job.requestJSON)
        let artifacts = try XCTUnwrap(payload.artifacts)
        XCTAssertEqual(artifacts.count, 2)
        XCTAssertEqual(artifacts[0].mimeType, "image/png")
        XCTAssertTrue(artifacts[0].relativePath.hasSuffix(".png"))
        XCTAssertEqual(artifacts[0].byteCount, Int64(Self.pngBytes.count))
        XCTAssertEqual(artifacts[0].sha256, FloeDigest.sha256Hex(Self.pngBytes))
        XCTAssertEqual(artifacts[1].mimeType, "image/jpeg")
        XCTAssertTrue(artifacts[1].relativePath.hasSuffix(".jpg"))
        XCTAssertEqual(artifacts[1].sha256, FloeDigest.sha256Hex(Self.jpegBytes))
        // The scalar legacy view is explicitly absent for a batch: never a
        // comma-joined path or digest.
        XCTAssertNil(payload.workspaceRelativePath)
        XCTAssertNil(payload.deliveredByteCount)
        XCTAssertNil(payload.deliveredSHA256)
        // The status projection exposes the same typed array.
        let status = try await fixture.service.status(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: summary.jobID, refresh: false)
        XCTAssertEqual(status.artifacts, artifacts)
        XCTAssertNil(status.workspaceRelativePath)
        // Both files actually exist at their recorded paths.
        for artifact in artifacts {
            let url = fixture.workspaceURL.appendingPathComponent(artifact.relativePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    // MARK: - Ownership

    func testCompetingStoreInstancesCannotOverwriteTerminalSettlement() async throws {
        let fixture = try await makeFixture()
        let database = fixture.database
        let job = MediaGenerationJob(
            providerID: fixture.providerID, modelID: fixture.modelID,
            mediaKind: .video, credentialReference: nil,
            sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: Data(), state: .running)
        let identity = "atomic-settlement-\(UUID().uuidString)"
        _ = try await fixture.jobStore.createJob(
            job, owner: .conversation(fixture.conversationID),
            originRunID: fixture.runID, idempotencyKey: identity)
        let winners = try await withThrowingTaskGroup(of: Bool.self) { group in
            for state in [MediaGenerationJobState.ready, .cancelled] {
                group.addTask {
                    let store = MediaGenerationJobStore(database: database)
                    do {
                        _ = try await store.transition(id: job.id, to: state) {
                            $0.lastError = state.rawValue
                        }
                        return true
                    } catch MediaGenerationJobStoreError.invalidStateTransition {
                        return false
                    }
                }
            }
            var count = 0
            for try await won in group { if won { count += 1 } }
            return count
        }
        XCTAssertEqual(winners, 1)
        let fetched = try await fixture.jobStore.ownedJob(id: job.id)
        let settled = try XCTUnwrap(fetched)
        XCTAssertTrue(settled.job.state == .ready || settled.job.state == .cancelled)
        XCTAssertEqual(settled.job.lastError, settled.job.state.rawValue)
        XCTAssertEqual(settled.owner, .conversation(fixture.conversationID))
        XCTAssertEqual(settled.originRunID, fixture.runID)
        XCTAssertEqual(settled.idempotencyKey, identity)
    }

    func testStatusRefusesJobOwnedByAnotherConversation() async throws {
        let fixture = try await makeFixture()
        let payload = G09R2AgentGenerationPayload(
            prompt: "synthetic", routeID: fixture.modelID.uuidString.lowercased(),
            providerID: fixture.providerID, modelID: fixture.modelID,
            remoteModelID: "gpt-image-1", count: 1)
        let job = MediaGenerationJob(
            providerID: fixture.providerID, modelID: fixture.modelID,
            mediaKind: .image, credentialReference: nil,
            sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: try payloadData(payload))
        let creation = try await fixture.jobStore.createJob(
            job, owner: .conversation(UUID()),
            originRunID: fixture.runID, idempotencyKey: "key-\(UUID().uuidString)")
        do {
            _ = try await fixture.service.status(
                epoch: fixture.epoch, conversationID: fixture.conversationID,
                jobID: creation.job.id, refresh: false)
            XCTFail("a foreign-owned job must not be readable")
        } catch {
            // expected
        }
    }
}
