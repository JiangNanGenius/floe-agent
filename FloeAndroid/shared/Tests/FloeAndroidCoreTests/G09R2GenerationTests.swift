// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 generation/candidate source-authored regression tests.
//
// These are AUTHORED, NOT RUN by the generation16 source lane. They use
// synthetic injected adapters and a synthetic result download; no provider,
// network, API key or device is involved. The combined native qualification
// batch owns actual execution.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloePersistence
import FloeProviders
import FloeAndroidWorkbench

final class G09R2GenerationTests: XCTestCase {
    private var roots: [URL] = []
    private var epochs: [UInt64] = []
    private var database: DatabaseManager?
    private static let epochLock = NSLock()
    nonisolated(unsafe) private static var epochCounter: UInt64 = 7_000

    override func tearDown() async throws {
        if let database { try? await database.close() }
        database = nil
        for epoch in epochs {
            _ = G09R2ForegroundCoordinator.shared.releaseAll(epoch: epoch)
        }
        epochs.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        try await super.tearDown()
    }

    private static func nextEpoch() -> UInt64 {
        epochLock.lock(); defer { epochLock.unlock() }
        epochCounter += 1
        return epochCounter
    }

    // MARK: - Synthetic gate / adapters

    private actor Gate {
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?

        func wait() async {
            if opened { return }
            await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }

        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    private final class SyntheticImageAdapter: ImageProviderAdapter,
                                               @unchecked Sendable {
        private let lock = NSLock()
        private var callCount = 0
        private var started = false
        private let gate: Gate?
        private let failure: RemoteImageError?
        private let images: [Data]

        init(gate: Gate? = nil, failure: RemoteImageError? = nil,
             images: [Data]? = nil) {
            self.gate = gate
            self.failure = failure
            self.images = images ?? [SyntheticImageAdapter.png()]
        }

        var calls: Int {
            lock.lock(); defer { lock.unlock() }
            return callCount
        }

        var didStart: Bool {
            lock.lock(); defer { lock.unlock() }
            return started
        }

        func supportedOperations(for provider: ProviderProfile)
            -> Set<RemoteImageOperation> { [.generate, .edit] }

        func maximumSourceImages(for operation: RemoteImageOperation,
                                 modelRemoteID: String?) -> Int { 1 }

        func maximumOutputImages(modelRemoteID: String?) -> Int { 4 }

        private func recordStart() {
            lock.lock(); callCount += 1; started = true; lock.unlock()
        }

        func perform(
            _ request: RemoteImageRequest, provider: ProviderProfile,
            credentials: ProviderCredentials
        ) async throws -> RemoteImageResult {
            recordStart()
            if let gate { await gate.wait() }
            if let failure { throw failure }
            return RemoteImageResult(images: images)
        }

        static func png(width: Int = 16, height: Int = 16) -> Data {
            var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            func be32(_ value: Int) -> Data {
                Data([
                    UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                    UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
                ])
            }
            data.append(be32(13))
            data.append(Data("IHDR".utf8))
            data.append(be32(width))
            data.append(be32(height))
            data.append(Data([8, 6, 0, 0, 0]))
            data.append(Data([0, 0, 0, 0]))
            return data
        }
    }

    private final class SyntheticVideoAdapter: VideoProviderAdapter,
                                               @unchecked Sendable {
        private let lock = NSLock()
        private var submitCount = 0

        var submits: Int {
            lock.lock(); defer { lock.unlock() }
            return submitCount
        }

        private func recordSubmit() {
            lock.lock(); submitCount += 1; lock.unlock()
        }

        func submit(
            _ request: RemoteVideoRequest, provider: ProviderProfile,
            credentials: ProviderCredentials
        ) async throws -> RemoteVideoSubmission {
            recordSubmit()
            return RemoteVideoSubmission(providerTaskID: "synthetic-task-1")
        }

        func status(
            taskID: String, modelRemoteID: String,
            provider: ProviderProfile, credentials: ProviderCredentials
        ) async throws -> RemoteVideoStatus {
            // `RemoteVideoStatus` has no public memberwise initializer in the
            // frozen provider target; decode the exact Codable value instead of
            // reaching into the provider module.
            try JSONDecoder().decode(
                RemoteVideoStatus.self,
                from: Data("""
                {"state":"completed","progress":1,\
                "resultURL":"https://example.com/synthetic.mp4",\
                "resultURLExpiresAt":\(Date().addingTimeInterval(3_600).timeIntervalSinceReferenceDate)}
                """.utf8))
        }

        func cancel(
            taskID: String, provider: ProviderProfile,
            credentials: ProviderCredentials
        ) async throws {}
    }

    private struct Fixture {
        let service: G09CreativeDomainService
        let cluster: G09R2BoundCluster
        let generation: G09R2GenerationService
        let env: G09R2GenerationEnvironment
        let epoch: UInt64
        let projectID: UUID
        let modelID: UUID
        let session: String
        let imageAdapter: SyntheticImageAdapter?
        let videoAdapter: SyntheticVideoAdapter?
    }

    private func makeFixture(
        kind: MediaProjectKind,
        imageAdapter: SyntheticImageAdapter? = nil,
        videoAdapter: SyntheticVideoAdapter? = nil,
        download: (@Sendable (URL, URL, Int64) async throws
            -> G09R2DownloadReceipt)? = nil
    ) async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-r2-generation-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        database = manager
        let configuration = ModelConfigurationStore(database: manager)
        let provider = ProviderProfile(
            kind: kind == .image ? .openAI : .googleGemini,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://synthetic.example/v1")!,
            displayName: "Synthetic Provider", isEnabled: true)
        try await configuration.saveProvider(provider)
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: kind == .image
                ? "gpt-image-1" : "veo-3.1-generate-preview",
            displayName: "Synthetic \(kind.rawValue)",
            limits: ModelLimits(contextTokens: 4_096, maxOutputTokens: 256),
            capabilities: kind == .image
                ? [.imageGeneration] : [.videoGeneration],
            useSurfaces: kind == .image
                ? [.imageGeneration] : [.videoGeneration],
            isEnabled: true)
        try await configuration.saveModel(model)

        let workspaceStore = SQLiteWorkspaceStore(database: manager)
        let conversationStore = SQLiteConversationStore(database: manager)
        let root = try XCTUnwrap(
            RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        let service = G09CreativeDomainService()
        let epoch = Self.nextEpoch()
        epochs.append(epoch)
        _ = try await service.bind(
            epoch: epoch,
            storage: G09CreativeStorageContext(
                root: root, database: manager,
                workspaceStore: workspaceStore,
                conversationStore: conversationStore))
        let bound = await service.r2BoundCluster()
        let cluster = try XCTUnwrap(bound)
        let created = try await cluster.media.create(
            name: "Generation \(kind.rawValue)", kind: kind,
            width: 640, height: 360, frameRate: kind == .video ? 30 : nil,
            storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        let session = "session-r2-generation-\(kind.rawValue)"
        try await service.r2RegisterMediaSession(
            projectID: created.project.id, token: session)
        let env = G09R2GenerationEnvironment(
            root: root, database: manager, configuration: configuration)
        let platform = G09R2GenerationPlatform(
            imageAdapter: { _ in
                imageAdapter.map { $0 as any ImageProviderAdapter }
            },
            videoAdapter: { _ in
                videoAdapter.map { $0 as any VideoProviderAdapter }
            },
            credentials: { _ in
                ProviderCredentials(apiKey: "synthetic-test-key-not-real")
            },
            download: download ?? { source, target, maximum in
                let bytes = Self.syntheticMP4()
                try bytes.write(to: target, options: [])
                return G09R2DownloadReceipt(
                    fileURL: target, byteCount: Int64(bytes.count),
                    sha256: FloeDigest.sha256Hex(bytes))
            })
        let generation = G09R2GenerationService(
            platform: platform,
            environmentProvider: { candidateEpoch in
                candidateEpoch == epoch ? env : nil
            })
        return Fixture(
            service: service, cluster: cluster, generation: generation,
            env: env, epoch: epoch, projectID: created.project.id,
            modelID: model.id,
            session: session, imageAdapter: imageAdapter,
            videoAdapter: videoAdapter)
    }

    /// Simulates the App host's confirmed foreground lease for this exact
    /// fixture job (production path is the DB-backed trusted-host C ABI).
    private func confirmForeground(
        _ fixture: Fixture, jobID: String, kind: G09R2GenerationKind
    ) -> Bool {
        G09R2ForegroundCoordinator.shared.registerLease(
            jobID: jobID, epoch: fixture.epoch,
            projectID: fixture.projectID,
            token: "synthetic-foreground-1", kind: kind)
    }

    private func context(_ fixture: Fixture) -> G09R2ProjectContextDTO {
        G09R2ProjectContextDTO(
            projectID: fixture.projectID,
            sessionToken: fixture.session,
            storage: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
    }

    private func imageRequest(
        routeID: String, count: Int = 1
    ) -> G09R2ImageGenerationRequestDTO {
        G09R2ImageGenerationRequestDTO(
            prompt: "synthetic prompt", modelRouteID: routeID,
            size: nil, count: count, sourceAssetID: nil,
            referenceAssetIDs: [], idempotencyKey: "idem-image-1")
    }

    private func videoRequest(routeID: String) -> G09R2VideoGenerationRequestDTO {
        G09R2VideoGenerationRequestDTO(
            prompt: "synthetic video", modelRouteID: routeID,
            durationSeconds: nil, aspectRatio: nil, resolution: nil,
            sourceAssetID: nil, referenceAssetIDs: [],
            idempotencyKey: "idem-video-1")
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await predicate()
    }

    // MARK: - Image submit / terminal replay / candidate adopt

    func testImageSubmitReportsProviderOnceAndAdoptsCandidateOnce() async throws {
        let adapter = SyntheticImageAdapter()
        let fixture = try await makeFixture(kind: .image, imageAdapter: adapter)
        let context = context(fixture)
        let request = imageRequest(routeID: fixture.modelID.uuidString.lowercased())
        let handle = try await fixture.generation.submitImage(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2ImageSubmitRequest(
                context: context, expectedRevision: 0, opID: "image-op-1",
                request: request))
        XCTAssertFalse(handle.idempotent)
        XCTAssertEqual(handle.projectID, fixture.projectID)
        XCTAssertTrue(confirmForeground(
            fixture, jobID: handle.requestID, kind: .image))

        let completed = await waitUntil {
            let status = try? await fixture.generation.imageStatus(
                service: fixture.service, epoch: fixture.epoch,
                request: G09R2ImageStatusRequest(
                    context: context, requestID: handle.requestID))
            return status?.state == .completed
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(adapter.calls, 1)

        let status = try await fixture.generation.imageStatus(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2ImageStatusRequest(
                context: context, requestID: handle.requestID))
        let candidate = try XCTUnwrap(status.candidate)
        XCTAssertEqual(candidate.projectID, fixture.projectID)
        XCTAssertTrue(G09CreativeAssetHost.safeRelativePath(
            candidate.relativePath))

        // A terminal operation replay returns the SAME handle and never calls
        // the provider again.
        let replay = try await fixture.generation.submitImage(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2ImageSubmitRequest(
                context: context, expectedRevision: 0, opID: "image-op-1",
                request: request))
        XCTAssertTrue(replay.idempotent)
        XCTAssertEqual(replay.requestID, handle.requestID)
        XCTAssertEqual(adapter.calls, 1)

        // Adoption is one revision CAS with one undo step.
        let receipt = try await fixture.generation.acceptCandidate(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2CandidateAcceptRequest(
                context: context, expectedRevision: 0,
                candidateID: candidate.candidateID, opID: "accept-op-1"))
        XCTAssertEqual(receipt.revision, 1)
        XCTAssertTrue(receipt.canUndo)
        XCTAssertFalse(receipt.idempotent)

        let loaded = try await fixture.cluster.media.load(
            id: fixture.projectID,
            requested: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        XCTAssertEqual(loaded.project.revision, 1)
        XCTAssertEqual(loaded.project.assets.count, 1)
        XCTAssertEqual(loaded.project.imageLayers.count, 1)
        XCTAssertEqual(
            loaded.project.imageLayers.first?.assetID,
            loaded.project.assets.first?.id)

        // Replaying the same adopt opID against the CURRENT revision is a
        // receipt replay, not a second asset/layer.
        let adoptReplay = try await fixture.generation.acceptCandidate(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2CandidateAcceptRequest(
                context: context, expectedRevision: 1,
                candidateID: candidate.candidateID, opID: "accept-op-1"))
        XCTAssertTrue(adoptReplay.idempotent)
        XCTAssertEqual(adoptReplay.revision, 1)
        let reloaded = try await fixture.cluster.media.load(
            id: fixture.projectID,
            requested: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        XCTAssertEqual(reloaded.project.assets.count, 1)
        XCTAssertEqual(reloaded.project.imageLayers.count, 1)
    }

    // MARK: - Unknown outcome replay

    func testUnknownImageOutcomeIsDurableAndNeverResubmitted() async throws {
        let adapter = SyntheticImageAdapter(
            failure: .requestFailed("synthetic transport timeout"))
        let fixture = try await makeFixture(kind: .image, imageAdapter: adapter)
        let context = context(fixture)
        let request = imageRequest(routeID: fixture.modelID.uuidString.lowercased())
        let handle = try await fixture.generation.submitImage(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2ImageSubmitRequest(
                context: context, expectedRevision: 0, opID: "image-op-unknown",
                request: request))
        XCTAssertTrue(confirmForeground(
            fixture, jobID: handle.requestID, kind: .image))
        let unknown = await waitUntil {
            let status = try? await fixture.generation.imageStatus(
                service: fixture.service, epoch: fixture.epoch,
                request: G09R2ImageStatusRequest(
                    context: context, requestID: handle.requestID))
            return status?.state == .failed || status?.state == .outcomeUnknown
        }
        XCTAssertTrue(unknown)
        XCTAssertEqual(adapter.calls, 1)
        let replay = try await fixture.generation.submitImage(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2ImageSubmitRequest(
                context: context, expectedRevision: 0, opID: "image-op-unknown",
                request: request))
        XCTAssertTrue(replay.idempotent)
        XCTAssertEqual(adapter.calls, 1)
    }

    // MARK: - Honest foreground admission

    func testForegroundDeniedNeverDispatchesProviderOrPublishesCandidate() async throws {
        let adapter = SyntheticImageAdapter()
        let fixture = try await makeFixture(kind: .image, imageAdapter: adapter)
        let context = context(fixture)
        let handle = try await fixture.generation.submitImage(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2ImageSubmitRequest(
                context: context, expectedRevision: 0, opID: "image-op-denied",
                request: imageRequest(routeID: fixture.modelID.uuidString.lowercased())))
        G09R2ForegroundCoordinator.shared.denyAdmission(
            jobID: handle.requestID, epoch: fixture.epoch,
            reason: "notificationsBlocked")
        let refused = await waitUntil {
            let status = try? await fixture.generation.imageStatus(
                service: fixture.service, epoch: fixture.epoch,
                request: G09R2ImageStatusRequest(
                    context: context, requestID: handle.requestID))
            return status?.state == .failed
        }
        XCTAssertTrue(refused)
        XCTAssertEqual(adapter.calls, 0,
                       "startDenied must not send a paid provider request")
        XCTAssertEqual(
            G09R2ForegroundCoordinator.shared.leaseCount(epoch: fixture.epoch),
            0)
        let candidates = try await fixture.generation.candidates(
            service: fixture.service, epoch: fixture.epoch, context: context)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testForegroundLeaseIsExactJobEpochAndToken() async throws {
        let gate = Gate()
        let adapter = SyntheticImageAdapter(gate: gate)
        let fixture = try await makeFixture(kind: .image, imageAdapter: adapter)
        let context = context(fixture)
        let handle = try await fixture.generation.submitImage(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2ImageSubmitRequest(
                context: context, expectedRevision: 0, opID: "image-op-lease",
                request: imageRequest(routeID: fixture.modelID.uuidString.lowercased())))
        XCTAssertTrue(confirmForeground(
            fixture, jobID: handle.requestID, kind: .image))
        let started = await waitUntil { adapter.didStart }
        XCTAssertTrue(started)
        XCTAssertEqual(
            G09R2ForegroundCoordinator.shared.leaseCount(epoch: fixture.epoch), 1)
        XCTAssertFalse(G09R2ForegroundCoordinator.shared.releaseLease(
            jobID: handle.requestID, epoch: fixture.epoch, token: "foreign"))
        XCTAssertFalse(G09R2ForegroundCoordinator.shared.releaseLease(
            jobID: handle.requestID, epoch: fixture.epoch + 1,
            token: "synthetic-foreground-1"))
        XCTAssertEqual(
            G09R2ForegroundCoordinator.shared.leaseCount(epoch: fixture.epoch), 1)
        XCTAssertTrue(G09R2ForegroundCoordinator.shared.releaseLease(
            jobID: handle.requestID, epoch: fixture.epoch,
            token: "synthetic-foreground-1"))
        XCTAssertEqual(
            G09R2ForegroundCoordinator.shared.leaseCount(epoch: fixture.epoch), 0)
        await gate.open()
        let settled = await waitUntil {
            fixture.generation.pendingWorkerCount(epoch: fixture.epoch) == 0
        }
        XCTAssertTrue(settled)
    }

    // MARK: - Root drain / no late write

    func testRootStopWaitsForActualWorkerAndPreventsLateWrites() async throws {
        let gate = Gate()
        let adapter = SyntheticImageAdapter(gate: gate)
        let fixture = try await makeFixture(kind: .image, imageAdapter: adapter)
        let context = context(fixture)
        let handle = try await fixture.generation.submitImage(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2ImageSubmitRequest(
                context: context, expectedRevision: 0, opID: "image-op-gate",
                request: imageRequest(routeID: fixture.modelID.uuidString.lowercased())))
        XCTAssertTrue(confirmForeground(
            fixture, jobID: handle.requestID, kind: .image))
        let started = await waitUntil { adapter.didStart }
        XCTAssertTrue(started)
        XCTAssertFalse(fixture.generation.requestRootStop(
            epoch: fixture.epoch),
            "a live provider worker must keep the root bound")
        await gate.open()
        let workerSettled = await waitUntil {
            fixture.generation.pendingWorkerCount(epoch: fixture.epoch) == 0
        }
        XCTAssertTrue(workerSettled)
        XCTAssertFalse(fixture.generation.requestRootStop(epoch: fixture.epoch),
                       "the App foreground lease is a separate real owner")
        XCTAssertTrue(G09R2ForegroundCoordinator.shared.releaseLease(
            jobID: handle.requestID, epoch: fixture.epoch,
            token: "synthetic-foreground-1"))
        let drained = await waitUntil {
            fixture.generation.requestRootStop(epoch: fixture.epoch)
        }
        XCTAssertTrue(drained)
        try await Task.sleep(for: .milliseconds(200))
        let candidates = try await fixture.generation.candidates(
            service: fixture.service, epoch: fixture.epoch, context: context)
        XCTAssertTrue(candidates.isEmpty,
                      "a stopped generation must not publish a late candidate")
        do {
            let project = try await fixture.cluster.media.load(
                id: fixture.projectID,
                requested: G09StorageLayerDTO(kind: .appOwned),
                origin: G09CreativeOriginDTO(kind: .standalone))
            XCTAssertEqual(project.project.revision, 0)
            XCTAssertTrue(project.project.assets.isEmpty)
        }
    }

    // MARK: - Video submit / download / deliver / adopt

    func testVideoSubmitPollsDownloadsDeliversAndAdoptsClip() async throws {
        let adapter = SyntheticVideoAdapter()
        let fixture = try await makeFixture(kind: .video, videoAdapter: adapter)
        let context = context(fixture)
        let handle = try await fixture.generation.submitVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoSubmitRequest(
                context: context, expectedRevision: 0, opID: "video-op-1",
                request: videoRequest(routeID: fixture.modelID.uuidString.lowercased())))
        XCTAssertFalse(handle.idempotent)
        XCTAssertTrue(confirmForeground(
            fixture, jobID: handle.jobID, kind: .video))
        let submitted = await waitUntil {
            adapter.submits == 1
        }
        XCTAssertTrue(submitted)

        let ready = await waitUntil(timeout: 15) {
            let status = try? await fixture.generation.refreshJob(
                service: fixture.service, epoch: fixture.epoch,
                context: context, jobID: handle.jobID)
            return status?.state == .completed
        }
        XCTAssertTrue(ready)
        let delivered = try await fixture.generation.deliverResult(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2JobDeliverRequest(
                context: context, jobID: handle.jobID, opID: "deliver-op-1"))
        XCTAssertEqual(delivered.outcome, .ready)
        let candidate = try XCTUnwrap(delivered.candidate)
        XCTAssertEqual(candidate.kind, .video)
        XCTAssertTrue(G09CreativeAssetHost.safeRelativePath(
            candidate.relativePath))

        let receipt = try await fixture.generation.acceptCandidate(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2CandidateAcceptRequest(
                context: context, expectedRevision: 0,
                candidateID: candidate.candidateID, opID: "accept-video-1"))
        XCTAssertEqual(receipt.revision, 1)
        let loaded = try await fixture.cluster.media.load(
            id: fixture.projectID,
            requested: G09StorageLayerDTO(kind: .appOwned),
            origin: G09CreativeOriginDTO(kind: .standalone))
        XCTAssertEqual(loaded.project.videoTimeline?.clips.count, 1)
        XCTAssertEqual(loaded.project.assets.count, 1)

        // A repeated submission with the SAME key attaches to the terminal job
        // instead of paying for a second provider task.
        let replay = try await fixture.generation.submitVideo(
            service: fixture.service, epoch: fixture.epoch,
            request: G09R2VideoSubmitRequest(
                context: context, expectedRevision: 1, opID: "video-op-1",
                request: videoRequest(routeID: fixture.modelID.uuidString.lowercased())))
        XCTAssertTrue(replay.idempotent)
        XCTAssertEqual(adapter.submits, 1)
    }

    // MARK: - Synthetic media bytes

    private static func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        let size = UInt32(payload.count + 8)
        data.append(contentsOf: [
            UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
        ])
        data.append(Data(type.utf8))
        data.append(payload)
        return data
    }

    private static func be32(_ value: Int) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }

    private static func syntheticMP4() -> Data {
        var ftypPayload = Data("isom".utf8)
        ftypPayload.append(be32(0))
        ftypPayload.append(Data("isom".utf8))
        let ftyp = box("ftyp", ftypPayload)

        var mvhdPayload = Data([0, 0, 0, 0])
        mvhdPayload.append(be32(0))
        mvhdPayload.append(be32(0))
        mvhdPayload.append(be32(1_000))
        mvhdPayload.append(be32(2_000))
        let mvhd = box("mvhd", mvhdPayload)

        var tkhdPayload = Data([0, 0, 0, 1])
        tkhdPayload.append(Data(repeating: 0, count: 72))
        tkhdPayload.append(be32(640 << 16))
        tkhdPayload.append(be32(360 << 16))
        let tkhd = box("tkhd", tkhdPayload)
        let trak = box("trak", tkhd)
        let moov = box("moov", mvhd + trak)
        return ftyp + moov
    }
}
