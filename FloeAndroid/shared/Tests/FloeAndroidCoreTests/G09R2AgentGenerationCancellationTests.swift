// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 agent generation settlement / target-fence race tests.
// Authored source; executed by Main's combined gate (this lane performs NO
// build/test execution). These tests exercise the REAL conversation-owned
// lifecycle with a LIVE shared worker and deterministic barriers/continuations
// — never seeded inactive rows, never blind sleeps:
//
//  * cancel failure/success against a live poll worker blocked inside the
//    synthetic provider status call (the exact worker-cancel race the seeded
//    rows could not prove): a provider cancel failure keeps the accepted job
//    non-terminal and queryable; a provider-confirmed cancel settles
//    `cancelled` and the racing worker publishes nothing afterwards;
//  * a ready-vs-cancel race during a delayed download: cancellation fences
//    the commit, no byte is published, the staged part is removed;
//  * an explicit workspace/target move during a delayed download fences the
//    delivery as a definite `targetChanged` — nothing is committed into the
//    old OR the new owner;
//  * post-dispatch generic provider/transport errors (submit and one-shot
//    image) settle durable `outcomeUnknown`, never a definite failure, while
//    typed provider rejections remain definite;
//  * the retained accepted job restarts on an explicit refresh against the
//    SAME provider handle — no accidental resubmission.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloePersistence
import FloeProviders

final class G09R2AgentGenerationCancellationTests: XCTestCase {
    private var roots: [URL] = []
    private var databases: [DatabaseManager] = []
    private static let epochLock = NSLock()
    nonisolated(unsafe) private static var epochCounter: UInt64 = 50_000

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

    /// A deterministic open/continuation gate: `enterAndWait()` suspends until
    /// `open()` runs; entering after `open()` passes through immediately.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func enterAndWait() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting.append(continuation)
                    lock.unlock()
                }
            }
        }

        func open() {
            lock.lock()
            isOpen = true
            let pending = waiting
            waiting.removeAll()
            lock.unlock()
            for continuation in pending { continuation.resume() }
        }
    }

    /// Minimal but real ISO-BMFF bytes: ftyp + moov/mvhd with a 1 s duration,
    /// sniffable by the REAL `G09R2MediaProbe.videoFacts` (never a text
    /// placeholder that would fail the delivered-video format check).
    private static let mp4Bytes: Data = {
        var data = Data()
        // ftyp box (24 bytes): size, type, major brand "isom", minor, compat.
        data.append(contentsOf: [0, 0, 0, 24])
        data.append(contentsOf: Array("ftyp".utf8))
        data.append(contentsOf: Array("isom".utf8))
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(contentsOf: Array("isom".utf8))
        data.append(contentsOf: Array("iso2".utf8))
        // mvhd payload (version 0): 100 bytes; timescale at +12, duration +16.
        var mvhdPayload = Data(repeating: 0, count: 100)
        mvhdPayload.replaceSubrange(12...15, with: [0, 0, 0x03, 0xE8]) // timescale 1000
        mvhdPayload.replaceSubrange(16...19, with: [0, 0, 0x03, 0xE8]) // duration 1000 -> 1s
        var mvhd = Data()
        var mvhdSize = UInt32(mvhdPayload.count + 8).bigEndian
        withUnsafeBytes(of: &mvhdSize) { mvhd.append(contentsOf: $0) }
        mvhd.append(contentsOf: Array("mvhd".utf8))
        mvhd.append(mvhdPayload)
        // moov box wrapping mvhd.
        var moov = Data()
        var moovSize = UInt32(mvhd.count + 8).bigEndian
        withUnsafeBytes(of: &moovSize) { moov.append(contentsOf: $0) }
        moov.append(contentsOf: Array("moov".utf8))
        moov.append(mvhd)
        data.append(moov)
        return data
    }()

    private struct Fixture {
        let service: G09R2AgentGenerationService
        let root: RuntimeStorageRoot
        let rootURL: URL
        let workspaceURL: URL
        let database: DatabaseManager
        let workspaceStore: SQLiteWorkspaceStore
        let jobStore: MediaGenerationJobStore
        let epoch: UInt64
        let conversationID: UUID
        let runID: UUID
        let modelID: UUID
        let videoAdapter: GatedVideoAdapter
    }

    private final class GatedVideoAdapter: VideoProviderAdapter, @unchecked Sendable {
        private let lock = NSLock()
        private var _submitCount = 0
        private var _cancelCount = 0
        var submission: RemoteVideoSubmission
        var submitHandler: (() async throws -> RemoteVideoSubmission)?
        var statusHandler: ((String) async throws -> RemoteVideoStatus)?
        var cancelError: Error?

        var submitCount: Int { lock.lock(); defer { lock.unlock() }; return _submitCount }
        var cancelCount: Int { lock.lock(); defer { lock.unlock() }; return _cancelCount }

        init(submission: RemoteVideoSubmission) {
            self.submission = submission
        }

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
            if let submitHandler { return try await submitHandler() }
            return submission
        }

        func status(
            taskID: String, modelRemoteID: String,
            provider: ProviderProfile, credentials: ProviderCredentials
        ) async throws -> RemoteVideoStatus {
            try await statusHandler?(taskID)
                ?? Self.makeStatus(state: .failed, error: "syntheticFailure")
        }

        func cancel(
            taskID: String, provider: ProviderProfile,
            credentials: ProviderCredentials
        ) async throws {
            lock.withLock { _cancelCount += 1 }
            if let cancelError { throw cancelError }
        }
    }

    private final class GatedImageAdapter: ImageProviderAdapter, @unchecked Sendable {
        private let lock = NSLock()
        private var _performCount = 0
        var resultImages: [Data] = []
        var performHandler: (() async throws -> RemoteImageResult)?

        var performCount: Int { lock.lock(); defer { lock.unlock() }; return _performCount }

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
            lock.withLock { _performCount += 1 }
            if let performHandler { return try await performHandler() }
            return RemoteImageResult(images: resultImages)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-agent-generation-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        databases.append(manager)
        let conversationID = UUID()
        // The ORIGINAL durable conversation→workspace ownership the run's
        // workspace root comes from; submission pins this exact binding.
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
            kind: .volcengineArk,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://ark-synthetic.example/api/v3")!,
            displayName: "Synthetic Provider", isEnabled: true)
        try await configuration.saveProvider(provider)
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "doubao-seedance-2-5-260628",
            displayName: "Synthetic model",
            limits: ModelLimits(contextTokens: 4_096, maxOutputTokens: 256),
            capabilities: [.videoGeneration],
            useSurfaces: [.videoGeneration],
            isEnabled: true)
        try await configuration.saveModel(model)
        let root = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        let environment = G09R2GenerationEnvironment(
            root: root, database: manager, configuration: configuration)
        let videoAdapter = GatedVideoAdapter(submission: RemoteVideoSubmission(
            providerTaskID: "synthetic-task-1"))
        let platform = G09R2GenerationPlatform(
            imageAdapter: { _ in nil },
            videoAdapter: { _ in videoAdapter },
            credentials: { _ in ProviderCredentials(apiKey: "synthetic-key") },
            download: { _, destination, _ in
                try Self.mp4Bytes.write(to: destination)
                return G09R2DownloadReceipt(
                    fileURL: destination,
                    byteCount: Int64(Self.mp4Bytes.count),
                    sha256: FloeDigest.sha256Hex(Self.mp4Bytes))
            })
        let service = G09R2AgentGenerationService(
            platform: platform, environmentProvider: { _ in environment })
        return Fixture(
            service: service, root: root, rootURL: url, workspaceURL: workspace,
            database: manager, workspaceStore: workspaceStore,
            jobStore: MediaGenerationJobStore(database: manager),
            epoch: Self.nextEpoch(), conversationID: conversationID, runID: UUID(),
            modelID: model.id, videoAdapter: videoAdapter)
    }

    /// A bounded, state-driven wait (never a blind sleep): the condition is
    /// re-evaluated against the durable store until it holds or the deadline
    /// fails the test.
    private func waitFor(
        _ description: String, timeout: TimeInterval = 10,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(description)")
    }

    /// Waits until the shared bounded worker table has no worker for the job.
    private func waitForWorkerSettled(
        _ fixture: Fixture, jobID: UUID, timeout: TimeInterval = 10
    ) async throws {
        let key = jobID.uuidString.lowercased()
        try await waitFor("worker settle for \(key)", timeout: timeout) {
            !G09R2GenerationService.shared.hasActiveWorker(jobID: key)
        }
    }

    private func currentState(_ fixture: Fixture, jobID: UUID) async throws
        -> OwnedMediaGenerationJob? {
        try await fixture.jobStore.ownedJob(id: jobID)
    }

    /// GeneratedMedia must never appear in a directory for these fenced cases.
    private func assertNoGeneratedMedia(_ directory: URL, _ message: String) {
        let generated = directory.appendingPathComponent("GeneratedMedia", isDirectory: true)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: generated.path), message)
    }

    // MARK: - Cancel failure against a live poll worker

    func testCancelProviderFailureRetainsAcceptedJobQueryably() async throws {
        let fixture = try await makeFixture()
        let statusEntered = expectation(description: "poll entered provider status")
        let release = Gate()
        fixture.videoAdapter.statusHandler = { _ in
            statusEntered.fulfill()
            await release.enterAndWait()
            return GatedVideoAdapter.makeStatus(state: .running)
        }
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
        await fulfillment(of: [statusEntered], timeout: 10)

        // The provider refuses the cancel: the call must throw and the ACCEPTED
        // job must remain non-terminal with its handle — never settled
        // terminal-unknown by the local worker stop.
        fixture.videoAdapter.cancelError = FloeError.validationFailed("providerRefused")
        do {
            _ = try await fixture.service.cancel(
                epoch: fixture.epoch, conversationID: fixture.conversationID,
                jobID: summary.jobID)
            XCTFail("a provider cancel failure must throw, never report success")
        } catch {
            // expected
        }
        let settledSnapshot1 = await currentState(fixture, jobID: summary.jobID)
        var owned = try XCTUnwrap(settledSnapshot1)
        XCTAssertFalse(owned.job.state.isTerminal,
                       "a failed provider cancel must NOT settle the accepted job terminal")
        XCTAssertEqual(owned.job.providerTaskID, "synthetic-task-1")

        // Release the racing poll worker: local stop + retention must keep the
        // job queryable, never resubmit, never a false terminal.
        release.open()
        try await waitForWorkerSettled(fixture, jobID: summary.jobID)
        let settledSnapshot2 = await currentState(fixture, jobID: summary.jobID)
        owned = try XCTUnwrap(settledSnapshot2)
        XCTAssertFalse(owned.job.state.isTerminal,
                       "local worker stop must retain the accepted job, not expire it")
        XCTAssertEqual(owned.job.providerTaskID, "synthetic-task-1")
        XCTAssertEqual(fixture.videoAdapter.submitCount, 1, "no resubmission")

        // The retained handle is still cancellable/queryable.
        let status = try await fixture.service.status(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: summary.jobID, refresh: false)
        XCTAssertTrue(status.canCancel)
        XCTAssertEqual(status.providerTaskID, "synthetic-task-1")
    }

    // MARK: - Provider-confirmed cancel against a live poll worker

    func testCancelProviderConfirmedWithLivePollWorkerSettlesCancelled() async throws {
        let fixture = try await makeFixture()
        let statusEntered = expectation(description: "poll entered provider status")
        let release = Gate()
        fixture.videoAdapter.statusHandler = { _ in
            statusEntered.fulfill()
            await release.enterAndWait()
            return GatedVideoAdapter.makeStatus(state: .running)
        }
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
        await fulfillment(of: [statusEntered], timeout: 10)

        let status = try await fixture.service.cancel(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: summary.jobID)
        XCTAssertEqual(status.state, .cancelled)
        XCTAssertEqual(fixture.videoAdapter.cancelCount, 1)

        // The racing poll worker must not resurrect or republish anything.
        release.open()
        try await waitForWorkerSettled(fixture, jobID: summary.jobID)
        let settledSnapshot3 = await currentState(fixture, jobID: summary.jobID)
        let owned = try XCTUnwrap(settledSnapshot3)
        XCTAssertEqual(owned.job.state, .cancelled)
        XCTAssertEqual(fixture.videoAdapter.submitCount, 1)
    }

    // MARK: - Ready-vs-cancel race during a delayed download

    func testReadyDownloadCancelRacePublishesNothing() async throws {
        let fixture = try await makeFixture()
        let downloadEntered = expectation(description: "download entered")
        let release = Gate()
        fixture.videoAdapter.statusHandler = { _ in
            GatedVideoAdapter.makeStatus(
                state: .ready,
                resultURL: URL(string: "https://ark-synthetic.example/result.mp4"))
        }
        let platformDownload: G09R2GenerationPlatform = G09R2GenerationPlatform(
            imageAdapter: { _ in nil },
            videoAdapter: { _ in fixture.videoAdapter },
            credentials: { _ in ProviderCredentials(apiKey: "synthetic-key") },
            download: { _, destination, _ in
                downloadEntered.fulfill()
                await release.enterAndWait()
                try Self.mp4Bytes.write(to: destination)
                return G09R2DownloadReceipt(
                    fileURL: destination,
                    byteCount: Int64(Self.mp4Bytes.count),
                    sha256: FloeDigest.sha256Hex(Self.mp4Bytes))
            })
        let service = G09R2AgentGenerationService(
            platform: platformDownload,
            environmentProvider: { _ in
                G09R2GenerationEnvironment(
                    root: fixture.root,
                    database: fixture.database,
                    configuration: ModelConfigurationStore(database: fixture.database))
            })
        let summary = try await service.submitVideo(
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
        await fulfillment(of: [downloadEntered], timeout: 10)

        // Cancel while the provider result download is blocked.
        let status = try await service.cancel(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: summary.jobID)
        XCTAssertEqual(status.state, .cancelled)

        // The delayed download completes afterwards; the stop/epoch/target
        // fence must keep every byte out of the workspace.
        release.open()
        try await waitForWorkerSettled(fixture, jobID: summary.jobID)
        let settledSnapshot4 = await currentState(fixture, jobID: summary.jobID)
        let owned = try XCTUnwrap(settledSnapshot4)
        XCTAssertEqual(owned.job.state, .cancelled)
        assertNoGeneratedMedia(fixture.workspaceURL,
                               "a cancelled delayed download must publish nothing")
    }

    // MARK: - Explicit workspace/target move during a delayed download

    func testTargetMoveDuringDownloadFencesDelivery() async throws {
        let fixture = try await makeFixture()
        let downloadEntered = expectation(description: "download entered")
        let release = Gate()
        fixture.videoAdapter.statusHandler = { _ in
            GatedVideoAdapter.makeStatus(
                state: .ready,
                resultURL: URL(string: "https://ark-synthetic.example/result.mp4"))
        }
        let platformDownload = G09R2GenerationPlatform(
            imageAdapter: { _ in nil },
            videoAdapter: { _ in fixture.videoAdapter },
            credentials: { _ in ProviderCredentials(apiKey: "synthetic-key") },
            download: { _, destination, _ in
                downloadEntered.fulfill()
                await release.enterAndWait()
                try Self.mp4Bytes.write(to: destination)
                return G09R2DownloadReceipt(
                    fileURL: destination,
                    byteCount: Int64(Self.mp4Bytes.count),
                    sha256: FloeDigest.sha256Hex(Self.mp4Bytes))
            })
        let service = G09R2AgentGenerationService(
            platform: platformDownload,
            environmentProvider: { _ in
                G09R2GenerationEnvironment(
                    root: fixture.root,
                    database: fixture.database,
                    configuration: ModelConfigurationStore(database: fixture.database))
            })
        let summary = try await service.submitVideo(
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
        await fulfillment(of: [downloadEntered], timeout: 10)

        // Explicit migration: the conversation is reassigned to a DIFFERENT
        // workspace while the provider download is in flight.
        let movedRelative = "PrivateTasks/\(fixture.conversationID.uuidString)-moved"
        let movedWorkspaceURL = fixture.rootURL
            .appendingPathComponent("Workspace", isDirectory: true)
            .appendingPathComponent(movedRelative, isDirectory: true)
        try FileManager.default.createDirectory(
            at: movedWorkspaceURL, withIntermediateDirectories: true)
        let moved = WorkspaceRecord(
            name: "Moved",
            rootBookmark: Data(),
            kind: .privateTask,
            internalRelativePath: movedRelative)
        try await fixture.workspaceStore.saveWorkspace(moved)
        try await fixture.workspaceStore.assignConversation(
            workspaceID: moved.id, conversationID: fixture.conversationID)

        release.open()
        try await waitFor("targetChanged terminal", timeout: 10) {
            guard let owned = try await fixture.jobStore.ownedJob(id: summary.jobID)
            else { return false }
            return owned.job.state == .failed && owned.job.lastError == "targetChanged"
        }
        let settledSnapshot5 = await currentState(fixture, jobID: summary.jobID)
        let owned = try XCTUnwrap(settledSnapshot5)
        XCTAssertEqual(owned.job.state, .failed)
        XCTAssertEqual(owned.job.lastError, "targetChanged")
        // Nothing may be committed into EITHER the original or the new owner.
        assertNoGeneratedMedia(fixture.workspaceURL,
                               "fenced delivery must not commit into the original owner")
        assertNoGeneratedMedia(movedWorkspaceURL,
                               "fenced delivery must not commit into the new owner")
        XCTAssertEqual(fixture.videoAdapter.submitCount, 1, "no resubmission")
    }

    // MARK: - Post-dispatch ambiguity vs typed rejection

    func testCancelDuringSubmitRetainsLateAcceptedHandle() async throws {
        let fixture = try await makeFixture()
        let entered = expectation(description: "provider is accepting the request")
        let release = Gate()
        let accepted = fixture.videoAdapter.submission
        fixture.videoAdapter.submitHandler = {
            entered.fulfill()
            await release.enterAndWait()
            return accepted
        }
        let summary = try await fixture.service.submitVideo(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            runID: fixture.runID, idempotencyKey: "key-\(UUID().uuidString)",
            workspaceRootURL: fixture.workspaceURL, prompt: "synthetic",
            selection: nil, legacyModelID: nil, aspectRatio: nil,
            resolution: nil, durationSeconds: nil, includeAudio: nil,
            watermark: nil, seed: nil, referenceRelativePath: nil)
        await fulfillment(of: [entered], timeout: 10)
        let stopped = try await fixture.service.cancel(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: summary.jobID)
        release.open()
        XCTAssertFalse(stopped.terminated)
        XCTAssertEqual(stopped.lastError, "outcomeUnknown")
        try await waitFor("late accepted handle retained", timeout: 10) {
            guard let row = try await fixture.jobStore.ownedJob(id: summary.jobID) else {
                return false
            }
            return row.job.providerTaskID == accepted.providerTaskID && !row.job.state.isTerminal
        }
        XCTAssertEqual(fixture.videoAdapter.submitCount, 1)
        XCTAssertEqual(fixture.videoAdapter.cancelCount, 0)
        assertNoGeneratedMedia(fixture.workspaceURL, "local stop must publish nothing")
    }

    func testPostDispatchVideoSubmitErrorIsUnknownNotDefinite() async throws {
        let fixture = try await makeFixture()
        // A generic transport-style failure AFTER dispatch must settle durable
        // outcomeUnknown (expired), never a definite failed.
        fixture.videoAdapter.submitHandler = {
            throw FloeError.validationFailed("transportTimeout")
        }
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
        try await waitFor("durable outcomeUnknown", timeout: 10) {
            guard let owned = try await fixture.jobStore.ownedJob(id: summary.jobID)
            else { return false }
            return owned.job.state == .expired
                && owned.job.lastError == "outcomeUnknown"
        }
        let settledSnapshot6 = await currentState(fixture, jobID: summary.jobID)
        let owned = try XCTUnwrap(settledSnapshot6)
        XCTAssertEqual(owned.job.state, .expired)
        XCTAssertEqual(owned.job.lastError, "outcomeUnknown")
        XCTAssertEqual(fixture.videoAdapter.submitCount, 1, "no resubmission")
    }

    func testTypedVideoRejectionRemainsDefinite() async throws {
        let fixture = try await makeFixture()
        // A typed provider rejection proves non-acceptance: definite failed.
        fixture.videoAdapter.submitHandler = {
            throw RemoteVideoError.requestFailed("providerRefused")
        }
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
        try await waitFor("definite providerRejected failure", timeout: 10) {
            guard let owned = try await fixture.jobStore.ownedJob(id: summary.jobID)
            else { return false }
            return owned.job.state == .failed
                && owned.job.lastError == "providerRejected"
        }
        let settledSnapshot7 = await currentState(fixture, jobID: summary.jobID)
        let owned = try XCTUnwrap(settledSnapshot7)
        XCTAssertEqual(owned.job.state, .failed)
        XCTAssertEqual(owned.job.lastError, "providerRejected")
    }

    func testPostDispatchImageErrorIsUnknownNotDefinite() async throws {
        let fixture = try await makeFixture()
        let imageAdapter = GatedImageAdapter()
        imageAdapter.performHandler = {
            throw FloeError.validationFailed("connectionLost")
        }
        let configuration = ModelConfigurationStore(database: fixture.database)
        let root = try XCTUnwrap(
            RuntimeStorageRoot(validatingAbsoluteDirectory: fixture.rootURL.path))
        let platform = G09R2GenerationPlatform(
            imageAdapter: { _ in imageAdapter },
            videoAdapter: { _ in fixture.videoAdapter },
            credentials: { _ in ProviderCredentials(apiKey: "synthetic-key") },
            download: { _, _, _ in
                throw FloeError.validationFailed("downloadUnused")
            })
        let service = G09R2AgentGenerationService(
            platform: platform,
            environmentProvider: { _ in
                G09R2GenerationEnvironment(
                    root: root, database: fixture.database,
                    configuration: configuration)
            })
        let summary = try await service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: "key-\(UUID().uuidString)",
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a square",
            selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        try await waitFor("durable outcomeUnknown", timeout: 10) {
            guard let owned = try await fixture.jobStore.ownedJob(id: summary.jobID)
            else { return false }
            return owned.job.state == .expired
                && owned.job.lastError == "outcomeUnknown"
        }
        let settledSnapshot8 = await currentState(fixture, jobID: summary.jobID)
        let owned = try XCTUnwrap(settledSnapshot8)
        XCTAssertEqual(owned.job.state, .expired,
                       "a post-dispatch image failure must be ambiguous, not definite")
        XCTAssertEqual(owned.job.lastError, "outcomeUnknown")
        XCTAssertEqual(imageAdapter.performCount, 1, "no resubmission")
    }

    // MARK: - Retained accepted job restarts on explicit refresh

    func testRetainedJobRestartsOnExplicitRefreshWithoutResubmit() async throws {
        let fixture = try await makeFixture()
        let statusEntered = expectation(description: "poll entered provider status")
        let release = Gate()
        fixture.videoAdapter.statusHandler = { _ in
            statusEntered.fulfill()
            await release.enterAndWait()
            return GatedVideoAdapter.makeStatus(state: .running)
        }
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
        await fulfillment(of: [statusEntered], timeout: 10)

        // Provider cancel fails -> the accepted job is retained non-terminal.
        fixture.videoAdapter.cancelError = FloeError.validationFailed("providerRefused")
        do {
            _ = try await fixture.service.cancel(
                epoch: fixture.epoch, conversationID: fixture.conversationID,
                jobID: summary.jobID)
            XCTFail("a provider cancel failure must throw")
        } catch {
            // expected
        }
        release.open()
        try await waitForWorkerSettled(fixture, jobID: summary.jobID)
        let settledSnapshot9 = await currentState(fixture, jobID: summary.jobID)
        var owned = try XCTUnwrap(settledSnapshot9)
        XCTAssertFalse(owned.job.state.isTerminal)
        XCTAssertEqual(owned.job.providerTaskID, "synthetic-task-1")

        // An explicit refresh restarts the bounded poll worker against the
        // SAME retained provider handle — never a second paid submission.
        fixture.videoAdapter.statusHandler = { _ in
            GatedVideoAdapter.makeStatus(state: .running)
        }
        fixture.videoAdapter.cancelError = nil
        _ = try await fixture.service.status(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: summary.jobID, refresh: true)
        try await waitFor("poll worker restart", timeout: 10) {
            G09R2GenerationService.shared.hasActiveWorker(
                jobID: summary.jobID.uuidString.lowercased())
        }
        XCTAssertEqual(fixture.videoAdapter.submitCount, 1,
                       "an explicit refresh re-queries the retained handle, never resubmits")

        // Settle truthfully at the end so nothing outlives the test.
        let cancelled = try await fixture.service.cancel(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: summary.jobID)
        XCTAssertEqual(cancelled.state, .cancelled)
        try await waitForWorkerSettled(fixture, jobID: summary.jobID)
        let settledSnapshot10 = await currentState(fixture, jobID: summary.jobID)
        owned = try XCTUnwrap(settledSnapshot10)
        XCTAssertEqual(owned.job.state, .cancelled)
        XCTAssertEqual(fixture.videoAdapter.submitCount, 1)
    }
}
