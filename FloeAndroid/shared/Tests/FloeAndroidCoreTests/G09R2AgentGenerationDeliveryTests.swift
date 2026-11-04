// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 agent generation DELIVERY closure tests (job-264a807c8a364c8a).
// Authored source; executed by Main's combined gate (this lane performs NO
// build/test execution).
//
// These tests pin the two production breaks that kept an accepted, paid,
// provider-succeeded video from becoming a readable workspace artifact:
//
//  * Every configured provider adapter reports a succeeded video as
//    `.completed` (Volcengine/Ark `succeeded`, DashScope `SUCCEEDED`,
//    Google Omni `ACTIVE`). The agent poll loop used to switch only on
//    `.ready`, so a succeeded task fell into the running self-transition and
//    spun non-terminal forever — `nextPollAt` kept advancing while the
//    durable row never delivered. The first test drives the REAL lifecycle
//    with a `.completed` status and asserts the row reaches `.ready` with
//    the typed artifact receipt and exactly one provider submission.
//  * The host refresh entry (`refreshConversationJobs`, BridgeV28) must
//    reconcile retained jobs through the bounded shared worker table and
//    return re-read durable projections — restarting a stalled poll worker
//    for a retained accepted row WITHOUT any resubmission.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders

final class G09R2AgentGenerationDeliveryTests: XCTestCase {
    private var roots: [URL] = []
    private var databases: [DatabaseManager] = []
    private var epochs: [UInt64] = []
    private var gates: [Gate] = []
    private static let epochLock = NSLock()
    nonisolated(unsafe) private static var epochCounter: UInt64 = 70_000

    override func tearDown() async throws {
        for gate in gates { gate.open() }
        gates.removeAll()
        let ownedEpochs = epochs
        epochs.removeAll()
        for epoch in ownedEpochs {
            _ = G09R2GenerationService.shared.requestRootStop(epoch: epoch)
        }
        if !ownedEpochs.isEmpty {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline,
                  ownedEpochs.contains(
                    where: { G09R2GenerationService.shared.hasActiveWorker(epoch: $0) }) {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        guard !ownedEpochs.contains(where: {
            G09R2GenerationService.shared.hasActiveWorker(epoch: $0)
        }) else {
            XCTFail("Owned generation workers did not drain; preserving their database and workspace")
            try await super.tearDown()
            return
        }
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

    /// Minimal but real ISO-BMFF bytes (ftyp + moov/mvhd), sniffable by the
    /// REAL `G09R2MediaProbe.videoFacts` — never a text placeholder.
    private static let mp4Bytes: Data = {
        var data = Data()
        data.append(contentsOf: [0, 0, 0, 24])
        data.append(contentsOf: Array("ftyp".utf8))
        data.append(contentsOf: Array("isom".utf8))
        data.append(contentsOf: [0, 0, 0, 0])
        data.append(contentsOf: Array("isom".utf8))
        data.append(contentsOf: Array("iso2".utf8))
        var mvhdPayload = Data(repeating: 0, count: 100)
        mvhdPayload.replaceSubrange(12...15, with: [0, 0, 0x03, 0xE8])
        mvhdPayload.replaceSubrange(16...19, with: [0, 0, 0x03, 0xE8])
        var mvhd = Data()
        var mvhdSize = UInt32(mvhdPayload.count + 8).bigEndian
        withUnsafeBytes(of: &mvhdSize) { mvhd.append(contentsOf: $0) }
        mvhd.append(contentsOf: Array("mvhd".utf8))
        mvhd.append(mvhdPayload)
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
        let rootURL: URL
        let workspaceURL: URL
        let database: DatabaseManager
        let jobStore: MediaGenerationJobStore
        let epoch: UInt64
        let conversationID: UUID
        let runID: UUID
        let modelID: UUID
        let providerID: UUID
        let videoAdapter: ScriptedVideoAdapter
    }

    /// A scriptable video adapter: the status handler decides every poll
    /// result, exactly like the real adapter contracts do (a succeeded task
    /// is reported as `.completed` with the result URL).
    private final class ScriptedVideoAdapter: VideoProviderAdapter, @unchecked Sendable {
        private let lock = NSLock()
        private var _submitCount = 0
        var submission: RemoteVideoSubmission
        var statusHandler: ((String) async throws -> RemoteVideoStatus)?

        var submitCount: Int { lock.lock(); defer { lock.unlock() }; return _submitCount }

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
        ) async throws { }
    }

    private func makeFixture() async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-agent-generation-delivery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        databases.append(manager)
        let conversationID = UUID()
        let conversationStore = SQLiteConversationStore(database: manager)
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
        let videoAdapter = ScriptedVideoAdapter(submission: RemoteVideoSubmission(
            providerTaskID: "synthetic-task-delivery"))
        let platform = G09R2GenerationPlatform(
            imageAdapter: { _ in nil },
            videoAdapter: { _ in videoAdapter },
            credentials: { _ in ProviderCredentials(apiKey: "synthetic-key") },
            download: { _, destination, _ in
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.mp4Bytes.write(to: destination)
                return G09R2DownloadReceipt(
                    fileURL: destination,
                    byteCount: Int64(Self.mp4Bytes.count),
                    sha256: FloeDigest.sha256Hex(Self.mp4Bytes))
            })
        let service = G09R2AgentGenerationService(
            platform: platform, environmentProvider: { _ in environment })
        let epoch = Self.nextEpoch()
        epochs.append(epoch)
        return Fixture(
            service: service, rootURL: url, workspaceURL: workspace,
            database: manager,
            jobStore: MediaGenerationJobStore(database: manager),
            epoch: epoch, conversationID: conversationID, runID: UUID(),
            modelID: model.id, providerID: provider.id, videoAdapter: videoAdapter)
    }

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

    private func submitVideo(_ fixture: Fixture) async throws -> G09R2AgentSubmissionSummary {
        try await fixture.service.submitVideo(
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
    }

    private func insertHistoricalReadyJob(
        _ fixture: Fixture, withLegacyReceipt: Bool
    ) async throws -> UUID {
        let providerID = fixture.providerID
        var payload = G09R2AgentGenerationPayload(
            prompt: "historical fixture", routeID: "fixture", providerID: providerID,
            modelID: fixture.modelID, remoteModelID: "fixture", count: 1)
        if withLegacyReceipt {
            payload.workspaceRelativePath = "GeneratedMedia/historical.mp4"
            payload.deliveredByteCount = 12
            payload.deliveredSHA256 = String(repeating: "a", count: 64)
        }
        let job = MediaGenerationJob(
            providerID: providerID, modelID: fixture.modelID, mediaKind: .video,
            credentialReference: nil, sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: try JSONEncoder().encode(payload), state: .ready)
        try await fixture.jobStore.save(
            job, owner: .conversation(fixture.conversationID), originRunID: fixture.runID)
        return job.id
    }

    func testHistoricalReadyRowWithoutReceiptDoesNotClaimDelivery() async throws {
        let fixture = try await makeFixture()
        let jobID = try await insertHistoricalReadyJob(fixture, withLegacyReceipt: false)
        let status = try await fixture.service.status(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: jobID, refresh: false)
        XCTAssertEqual(status.state, .ready, "retain the historical record")
        XCTAssertTrue(status.terminated)
        XCTAssertFalse(status.ready, "a state label is not a delivered artifact")
        XCTAssertEqual(status.toolExitStatus, 1)
        XCTAssertEqual(status.lastError, "missingArtifactReceipt")
        XCTAssertEqual(fixture.videoAdapter.submitCount, 0)
    }

    func testHistoricalSingleArtifactReceiptRemainsCompatible() async throws {
        let fixture = try await makeFixture()
        let jobID = try await insertHistoricalReadyJob(fixture, withLegacyReceipt: true)
        let status = try await fixture.service.status(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: jobID, refresh: false)
        XCTAssertTrue(status.ready)
        XCTAssertEqual(status.toolExitStatus, 0)
        XCTAssertEqual(status.workspaceRelativePath, "GeneratedMedia/historical.mp4")
        XCTAssertEqual(fixture.videoAdapter.submitCount, 0)
    }

    // MARK: - The `.completed` regression (provider-succeeded -> delivered)

    /// Every real adapter reports a succeeded task as `.completed` with the
    /// result URL. Before the poll handled `.completed`, the durable row spun
    /// in `.running` forever (fresh `nextPollAt`, no `lastError`) even though
    /// the provider had long finished — exactly the device-observed state.
    /// This test FAILS against that build (row never reaches `.ready`) and
    /// passes only when `.completed` rides the download/delivery path.
    func testProviderCompletedStatusDeliversReadyArtifact() async throws {
        let fixture = try await makeFixture()
        fixture.videoAdapter.statusHandler = { _ in
            ScriptedVideoAdapter.makeStatus(
                state: .completed,
                resultURL: URL(string: "https://ark-synthetic.example/result.mp4"))
        }
        let summary = try await submitVideo(fixture)
        try await waitFor("ready row with typed artifact") {
            let owned = try await fixture.jobStore.ownedJob(id: summary.jobID)
            return owned?.job.state == .ready
        }
        let ownedOptional = try await fixture.jobStore.ownedJob(id: summary.jobID)
        let owned = try XCTUnwrap(ownedOptional)
        XCTAssertEqual(owned.job.state, .ready)
        XCTAssertEqual(fixture.videoAdapter.submitCount, 1, "exactly one paid submission")

        let payload = try JSONDecoder().decode(
            G09R2AgentGenerationPayload.self, from: owned.job.requestJSON)
        XCTAssertEqual(payload.artifacts?.count, 1)
        let artifact = try XCTUnwrap(payload.artifacts?.first)
        XCTAssertEqual(artifact.relativePath,
                       "GeneratedMedia/video-\(summary.jobID.uuidString.lowercased()).mp4")
        XCTAssertEqual(artifact.byteCount, Int64(Self.mp4Bytes.count))
        XCTAssertEqual(artifact.sha256, FloeDigest.sha256Hex(Self.mp4Bytes))
        XCTAssertEqual(payload.workspaceRelativePath, artifact.relativePath)
        XCTAssertEqual(payload.deliveredSHA256, artifact.sha256)

        let delivered = fixture.workspaceURL
            .appendingPathComponent("GeneratedMedia", isDirectory: true)
            .appendingPathComponent("video-\(summary.jobID.uuidString.lowercased()).mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: delivered.path))
        let bytes = try Data(floeContentsOf: delivered)
        XCTAssertEqual(FloeDigest.sha256Hex(bytes), artifact.sha256)
    }

    // MARK: - Host refresh reconcile (BridgeV28 semantics)

    /// `refreshConversationJobs` restarts the bounded poll worker for a
    /// retained accepted row and returns the re-read durable projections. It
    /// NEVER submits: the provider submission count stays exactly one across
    /// the reconcile.
    func testRefreshRestoresRetainedJobWithoutResubmission() async throws {
        let fixture = try await makeFixture()
        let firstPollEntered = expectation(description: "first poll entered")
        let holdFirstPoll = Gate()
        gates.append(holdFirstPoll)
        fixture.videoAdapter.statusHandler = { _ in
            firstPollEntered.fulfill()
            await holdFirstPoll.enterAndWait()
            return ScriptedVideoAdapter.makeStatus(state: .running)
        }
        let summary = try await submitVideo(fixture)
        await fulfillment(of: [firstPollEntered], timeout: 10)

        // Stop the worker exactly like a root/local stop: the accepted row
        // must be retained non-terminal with its provider handle.
        G09R2GenerationService.shared.requestCancel(
            jobID: summary.jobID.uuidString.lowercased(), epoch: fixture.epoch)
        holdFirstPoll.open()
        try await waitFor("retained non-terminal row") {
            let owned = try await fixture.jobStore.ownedJob(id: summary.jobID)
            guard let owned, !owned.job.state.isTerminal else { return false }
            return owned.job.providerTaskID == "synthetic-task-delivery"
        }

        try await waitFor("cancelled worker fully settled before refresh") {
            !G09R2GenerationService.shared.hasActiveWorker(
                jobID: summary.jobID.uuidString.lowercased())
        }

        // From here the provider reports the REAL succeeded spelling.
        fixture.videoAdapter.statusHandler = { _ in
            ScriptedVideoAdapter.makeStatus(
                state: .completed,
                resultURL: URL(string: "https://ark-synthetic.example/result.mp4"))
        }
        let projections = try await fixture.service.refreshConversationJobs(
            epoch: fixture.epoch, conversationID: fixture.conversationID)
        XCTAssertEqual(fixture.videoAdapter.submitCount, 1, "refresh must never resubmit")
        XCTAssertEqual(projections.count, 1)
        XCTAssertEqual(projections.first?.jobID, summary.jobID)

        // The restarted bounded worker delivers against the SAME handle.
        try await waitFor("delivery after refresh") {
            let owned = try await fixture.jobStore.ownedJob(id: summary.jobID)
            return owned?.job.state == .ready
        }
        let settledOptional = try await fixture.jobStore.ownedJob(id: summary.jobID)
        let settled = try XCTUnwrap(settledOptional)
        XCTAssertEqual(settled.job.state, .ready)
        XCTAssertEqual(fixture.videoAdapter.submitCount, 1, "still exactly one submission")

        let refreshed = try await fixture.service.refreshConversationJobs(
            epoch: fixture.epoch, conversationID: fixture.conversationID)
        XCTAssertEqual(refreshed.count, 1)
        XCTAssertEqual(refreshed.first?.state, .ready)
        XCTAssertEqual(refreshed.first?.mediaKind, "video")
        XCTAssertEqual(refreshed.first?.deliveredSHA256,
                       FloeDigest.sha256Hex(Self.mp4Bytes))
    }
}

/// Deterministic open/continuation gate (same discipline as the sibling
/// suites: suspends until opened; pass-through after open).
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
