// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 agent generation outcome-repair regressions (preparing→expired
// `outcomeUnknown` device failure, job-64a7a7ad60074707).
// Authored source; executed by Main's combined gate (this lane performs NO
// build/test execution). Every test drives the REAL production
// `G09R2AgentGenerationService` against a temporary explicit root and an
// in-memory GRDB database with synthetic image adapters at the provider
// boundary — no network, no device, no provider call, never seeded inactive
// rows where a live worker is the production truth:
//
//  * the run-launch recovery pump (`resumeStaleJobs`) must NEVER classify a
//    handle-less preparing/submitted row younger than `stalePreparingSeconds`
//    as unknown — that is the exact submission window (durable row inserted,
//    worker registration the next synchronous step) the fire-and-forget pump
//    can interleave with, expiring a brand-new approved image job as
//    `expired/outcomeUnknown` before dispatch (a possible cause of the
//    DEVICE_FAILURE receipt; actual upstream acceptance remains unknown);
//  * concurrent `video.status` churn while the one-shot image worker owns the
//    row never reports terminal (the model-visible symptom guard);
//  * a post-dispatch transport failure stays durable `outcomeUnknown` under
//    recovery/status churn — exactly ONE upstream submission, the original
//    unknown preserved, never an automatic resubmission; a DISTINCT later
//    request is a new job (anti-duplicate intact);
//  * a late local stop landing AFTER the verified bytes reached the pinned
//    workspace keeps the artifact receipt (CAS publish boundary) — real
//    delivered bytes are never stranded behind a no-artifact unknown row.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloePersistence
import FloeProviders

final class G09R2AgentGenerationOutcomeRepairTests: XCTestCase {
    private var roots: [URL] = []
    private var databases: [DatabaseManager] = []
    private var epochs: [UInt64] = []
    private var gates: [Gate] = []
    private static let epochLock = NSLock()
    nonisolated(unsafe) private static var epochCounter: UInt64 = 60_000

    override func tearDown() async throws {
        // Drain the workers this test owned BEFORE closing the databases:
        // a background worker that touches a closed GRDB connection crashes
        // the whole test process, even when the test body already failed.
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

    /// A real 1x1 RGBA PNG (valid bytes, not a text placeholder).
    private static let pngBytes = Data([
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xDF, 0xC0, 0xF0,
        0x1F, 0x00, 0x06, 0x80, 0x02, 0x7F, 0x10, 0x4C, 0x1B, 0xE1, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ])

    private struct Fixture {
        let service: G09R2AgentGenerationService
        let rootURL: URL
        let workspaceURL: URL
        let database: DatabaseManager
        let jobStore: MediaGenerationJobStore
        let epoch: UInt64
        let conversationID: UUID
        let runID: UUID
        let providerID: UUID
        let modelID: UUID
        let imageAdapter: GatedImageAdapter
    }

    /// Deterministic open/continuation gate: `enterAndWait()` suspends until
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

    private func makeFixture(
        afterImageBytesWritten: (@Sendable () async -> Void)? = nil
    ) async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-agent-generation-outcome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        let manager = try DatabaseManager.inMemory()
        try await manager.migrate()
        databases.append(manager)
        let conversationID = UUID()
        // The ORIGINAL durable conversation→workspace ownership the run's
        // workspace root comes from; submission pins this exact binding.
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
            kind: .openAI,
            // The wire protocol value is inert for these tests: adapters are
            // injected at the platform boundary, so the synthetic provider
            // never speaks a real wire protocol.
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://synthetic.example/v1")!,
            displayName: "Synthetic Provider", isEnabled: true)
        try await configuration.saveProvider(provider)
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "synthetic-image-1",
            displayName: "Synthetic image model",
            limits: ModelLimits(contextTokens: 4_096, maxOutputTokens: 256),
            capabilities: [.imageGeneration],
            useSurfaces: [.imageGeneration],
            isEnabled: true)
        try await configuration.saveModel(model)
        let root = try XCTUnwrap(RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
        let environment = G09R2GenerationEnvironment(
            root: root, database: manager, configuration: configuration)
        let imageAdapter = GatedImageAdapter()
        let platform = G09R2GenerationPlatform(
            imageAdapter: { _ in imageAdapter },
            videoAdapter: { _ in nil },
            credentials: { _ in ProviderCredentials(apiKey: "synthetic-key") },
            download: { _, _, _ in
                throw G09R2Error(.providerRejected, detail: "downloadUnused")
            })
        let service = G09R2AgentGenerationService(
            platform: platform, environmentProvider: { _ in environment },
            afterImageBytesWritten: afterImageBytesWritten)
        let epoch = Self.nextEpoch()
        epochs.append(epoch)
        return Fixture(
            service: service, rootURL: url, workspaceURL: workspace,
            database: manager,
            jobStore: MediaGenerationJobStore(database: manager),
            epoch: epoch, conversationID: conversationID, runID: UUID(),
            providerID: provider.id, modelID: model.id,
            imageAdapter: imageAdapter)
    }

    /// A bounded, state-driven wait (never a blind sleep).
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

    private func waitForWorkerSettled(
        _ fixture: Fixture, jobID: UUID, timeout: TimeInterval = 10
    ) async throws {
        let key = jobID.uuidString.lowercased()
        try await waitFor("worker settle for \(key)", timeout: timeout) {
            !G09R2GenerationService.shared.hasActiveWorker(jobID: key)
        }
    }

    private func payloadData(_ payload: G09R2AgentGenerationPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private func seedHandlelessJob(
        _ fixture: Fixture, createdAt: Date
    ) async throws -> UUID {
        let payload = G09R2AgentGenerationPayload(
            prompt: "synthetic", routeID: fixture.modelID.uuidString.lowercased(),
            providerID: fixture.providerID, modelID: fixture.modelID,
            remoteModelID: "synthetic-image-1", count: 1)
        let job = MediaGenerationJob(
            providerID: fixture.providerID, modelID: fixture.modelID,
            mediaKind: .image, credentialReference: nil,
            sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: try payloadData(payload),
            createdAt: createdAt)
        let creation = try await fixture.jobStore.createJob(
            job, owner: .conversation(fixture.conversationID),
            originRunID: fixture.runID, idempotencyKey: "key-\(UUID().uuidString)")
        return creation.job.id
    }

    // MARK: - Recovery pump freshness gate (the DEVICE_FAILURE regression)

    /// Reproduces the exact submission-window state — durable preparing row
    /// inserted, worker registration the next synchronous step — and proves
    /// the fire-and-forget launch pump can no longer expire it. Before the
    /// freshness gate this was the preparing→expired `outcomeUnknown` race:
    /// the pump read the job table between the row insert and
    /// `startWorker`, saw no live worker, and classified a milliseconds-old
    /// approved job unknown before any provider dispatch.
    func testRecoveryPumpNeverExpiresFreshHandlelessImageJob() async throws {
        let fixture = try await makeFixture()
        let freshID = try await seedHandlelessJob(fixture, createdAt: Date())
        let staleID = try await seedHandlelessJob(
            fixture,
            createdAt: Date().addingTimeInterval(
                -(G09R2GenerationService.stalePreparingSeconds + 60)))

        await fixture.service.resumeStaleJobs(
            epoch: fixture.epoch, conversationID: fixture.conversationID)

        let fresh = try await fixture.jobStore.ownedJob(id: freshID)
        XCTAssertEqual(fresh?.job.state, .preparing,
                       "a fresh handle-less row is owned by a starting worker; "
                       + "the pump must never expire it")
        XCTAssertNil(fresh?.job.lastError)
        let stale = try await fixture.jobStore.ownedJob(id: staleID)
        XCTAssertEqual(stale?.job.state, .expired,
                       "a genuinely stale handle-less row classifies unknown")
        XCTAssertEqual(stale?.job.lastError, "outcomeUnknown")
        // The fresh row survives a second pump pass after the stale one was
        // classified (classification must not overreach).
        await fixture.service.resumeStaleJobs(
            epoch: fixture.epoch, conversationID: fixture.conversationID)
        let freshAgain = try await fixture.jobStore.ownedJob(id: freshID)
        XCTAssertEqual(freshAgain?.job.state, .preparing)
    }

    // MARK: - Concurrent pump + submission invariant

    /// End-to-end invariant: while a real submission dispatches through the
    /// shared worker table, recovery-pump churn can never expire the new row
    /// and the job settles to real delivered bytes with exactly one upstream
    /// provider call.
    func testSubmitImageConcurrentRecoveryPumpDeliversRealBytesWithSingleDispatch() async throws {
        let fixture = try await makeFixture()
        let release = Gate()
        gates.append(release)
        fixture.imageAdapter.performHandler = {
            await release.enterAndWait()
            return RemoteImageResult(images: [Self.pngBytes])
        }
        let summary = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: "key-\(UUID().uuidString)",
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a square", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        // Pump churn overlaps the live dispatch window.
        await fixture.service.resumeStaleJobs(
            epoch: fixture.epoch, conversationID: fixture.conversationID)
        try await waitFor("adapter entered dispatch", timeout: 10) {
            fixture.imageAdapter.performCount == 1
        }
        for _ in 0..<10 {
            await fixture.service.resumeStaleJobs(
                epoch: fixture.epoch, conversationID: fixture.conversationID)
        }
        let mid = try await fixture.jobStore.ownedJob(id: summary.jobID)
        XCTAssertFalse(mid?.job.state.isTerminal ?? true,
                       "the row must stay live while its worker owns it")
        release.open()
        try await waitFor("ready settlement", timeout: 10) {
            guard let owned = try await fixture.jobStore.ownedJob(id: summary.jobID)
            else { return false }
            return owned.job.state.isTerminal
        }
        try await waitForWorkerSettled(fixture, jobID: summary.jobID)
        let settled = try await fixture.jobStore.ownedJob(id: summary.jobID)
        let owned = try XCTUnwrap(settled)
        XCTAssertEqual(owned.job.state, .ready)
        XCTAssertEqual(fixture.imageAdapter.performCount, 1,
                       "recovery churn must never produce a second paid submission")
        let payload = try JSONDecoder().decode(
            G09R2AgentGenerationPayload.self, from: owned.job.requestJSON)
        let artifact = try XCTUnwrap(payload.artifacts?.first)
        XCTAssertEqual(artifact.mimeType, "image/png")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.workspaceURL.appendingPathComponent(artifact.relativePath).path))
    }

    // MARK: - Status churn during live dispatch (model-visible symptom guard)

    /// The exact device symptom: `video.status` churn while the one-shot
    /// image worker owns the row must never report terminal/expired.
    func testStatusChurnDuringLiveImageDispatchNeverReportsTerminal() async throws {
        let fixture = try await makeFixture()
        let entered = Gate()
        gates.append(entered)
        let release = Gate()
        gates.append(release)
        fixture.imageAdapter.performHandler = {
            entered.open()
            await release.enterAndWait()
            return RemoteImageResult(images: [Self.pngBytes])
        }
        let summary = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: "key-\(UUID().uuidString)",
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a circle", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        try await waitFor("adapter entered", timeout: 10) {
            fixture.imageAdapter.performCount == 1
        }
        // Concurrent status churn against the live row.
        let service = fixture.service
        let epoch = fixture.epoch
        let conversationID = fixture.conversationID
        let jobID = summary.jobID
        let statuses = await withTaskGroup(of: G09R2AgentJobStatus.self, returning: [G09R2AgentJobStatus].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (try? await service.status(
                        epoch: epoch, conversationID: conversationID,
                        jobID: jobID, refresh: true))
                        ?? G09R2AgentJobStatus(
                            jobID: jobID, state: .failed, terminated: true,
                            canCancel: false, ready: false, providerTaskID: nil,
                            resultURL: nil, resultURLExpiresAt: nil, artifacts: nil,
                            workspaceRelativePath: nil, deliveredByteCount: nil,
                            deliveredSHA256: nil, nextPollAt: nil, lastError: "statusError")
                }
            }
            var collected: [G09R2AgentJobStatus] = []
            for await status in group { collected.append(status) }
            return collected
        }
        XCTAssertEqual(statuses.count, 8)
        for status in statuses {
            XCTAssertFalse(status.terminated,
                           "status churn must never report terminal while the worker owns the row")
            XCTAssertTrue(status.state == .preparing || status.state == .submitted,
                          "unexpected live state \(status.state.rawValue)")
        }
        release.open()
        try await waitFor("ready settlement", timeout: 10) {
            guard let owned = try await fixture.jobStore.ownedJob(id: summary.jobID)
            else { return false }
            return owned.job.state == .ready
        }
        try await waitForWorkerSettled(fixture, jobID: summary.jobID)
        let settled = try await fixture.jobStore.ownedJob(id: summary.jobID)
        XCTAssertEqual(settled?.job.state, .ready)
        XCTAssertEqual(fixture.imageAdapter.performCount, 1)
    }

    // MARK: - Post-dispatch unknown under recovery churn (no resubmission)

    /// A post-dispatch transport failure settles durable `outcomeUnknown`;
    /// status/recovery churn afterwards never resubmits and never rewrites
    /// the original unknown settlement. A DISTINCT later request is a new
    /// job with exactly one new upstream call (anti-duplicate preserved).
    func testPostDispatchTransportFailureStaysUnknownUnderRecoveryChurn() async throws {
        let fixture = try await makeFixture()
        let transport = URLError(.networkConnectionLost)
        fixture.imageAdapter.performHandler = {
            throw transport
        }
        let summary = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: "key-\(UUID().uuidString)",
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a triangle", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        try await waitFor("durable outcomeUnknown", timeout: 10) {
            guard let owned = try await fixture.jobStore.ownedJob(id: summary.jobID)
            else { return false }
            return owned.job.state == .expired
                && owned.job.lastError == "outcomeUnknown"
        }
        try await waitForWorkerSettled(fixture, jobID: summary.jobID)
        // Recovery/status churn: nothing may resubmit or rewrite the unknown.
        for _ in 0..<5 {
            _ = try? await fixture.service.status(
                epoch: fixture.epoch, conversationID: fixture.conversationID,
                jobID: summary.jobID, refresh: true)
        }
        for _ in 0..<2 {
            await fixture.service.resumeStaleJobs(
                epoch: fixture.epoch, conversationID: fixture.conversationID)
        }
        let settled = try await fixture.jobStore.ownedJob(id: summary.jobID)
        let owned = try XCTUnwrap(settled)
        XCTAssertEqual(owned.job.state, .expired)
        XCTAssertEqual(owned.job.lastError, "outcomeUnknown",
                       "the original unknown settlement must be preserved verbatim")
        XCTAssertEqual(fixture.imageAdapter.performCount, 1,
                       "unknown must never trigger an automatic resubmission")
        let payload = try JSONDecoder().decode(
            G09R2AgentGenerationPayload.self, from: owned.job.requestJSON)
        XCTAssertNil(payload.artifacts)

        // A distinct later request (new idempotency identity) is a NEW job.
        fixture.imageAdapter.performHandler = nil
        fixture.imageAdapter.resultImages = [Self.pngBytes]
        let retry = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: "key-\(UUID().uuidString)",
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a triangle", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        XCTAssertNotEqual(retry.jobID, summary.jobID)
        try await waitFor("retry ready", timeout: 10) {
            guard let owned = try await fixture.jobStore.ownedJob(id: retry.jobID)
            else { return false }
            return owned.job.state == .ready
        }
        try await waitForWorkerSettled(fixture, jobID: retry.jobID)
        XCTAssertEqual(fixture.imageAdapter.performCount, 2,
                       "an explicit distinct retry performs exactly one new call")
        // The original unknown job is untouched by the retry.
        let original = try await fixture.jobStore.ownedJob(id: summary.jobID)
        XCTAssertEqual(original?.job.state, .expired)
        XCTAssertEqual(original?.job.lastError, "outcomeUnknown")
    }

    // MARK: - Late stop after delivered bytes keeps the artifact receipt

    /// The fixture pauses exactly after verified bytes, before the receipt
    /// CAS. The live worker must accept cancellation in this observed window.
    func testLateStopAfterDeliveredBytesKeepsArtifactReceipt() async throws {
        let bytesWritten = expectation(description: "verified image bytes written")
        let release = Gate()
        gates.append(release)
        let fixture = try await makeFixture(afterImageBytesWritten: {
            bytesWritten.fulfill()
            await release.enterAndWait()
        })
        fixture.imageAdapter.resultImages = [Self.pngBytes]
        let summary = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: "key-\(UUID().uuidString)",
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a dot", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        await fulfillment(of: [bytesWritten], timeout: 10)
        let beforeCommit = try await fixture.jobStore.ownedJob(id: summary.jobID)
        XCTAssertFalse(try XCTUnwrap(beforeCommit).job.state.isTerminal,
                       "receipt commit must still be paused")
        let cancelMatched = G09R2GenerationService.shared.requestCancel(
            jobID: summary.jobID.uuidString.lowercased(), epoch: fixture.epoch)
        XCTAssertTrue(cancelMatched, "the late stop must cancel the live worker")
        release.open()
        try await waitFor("ready settlement despite the late stop", timeout: 10) {
            guard let owned = try await fixture.jobStore.ownedJob(id: summary.jobID)
            else { return false }
            return owned.job.state == .ready
        }
        try await waitForWorkerSettled(fixture, jobID: summary.jobID)
        let settled = try await fixture.jobStore.ownedJob(id: summary.jobID)
        let owned = try XCTUnwrap(settled)
        XCTAssertEqual(owned.job.state, .ready,
                       "verified delivered bytes must keep their receipt; a late stop "
                       + "after the write cannot downgrade them to no-artifact unknown")
        let payload = try JSONDecoder().decode(
            G09R2AgentGenerationPayload.self, from: owned.job.requestJSON)
        let artifact = try XCTUnwrap(payload.artifacts?.first)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.workspaceURL.appendingPathComponent(artifact.relativePath).path))
    }

}
