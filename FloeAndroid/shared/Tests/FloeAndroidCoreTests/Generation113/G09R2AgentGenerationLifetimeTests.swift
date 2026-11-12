// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 agent generation lifetime regressions (Full112 four-image
// `expired/outcomeUnknown` evidence, job-f5e25bf678e2493a).
// Authored source; the coordinator executes the combined gate (this lane
// performs NO build/test execution). Every case drives the REAL production
// `G09R2AgentGenerationService` against a temporary explicit root and an
// in-memory GRDB database with a synthetic image adapter at the provider
// boundary — no network, no device, no provider call.
//
// The device evidence showed five accepted image submissions that later
// polled as `expired/outcomeUnknown/ready=false` while the App was still in
// the foreground; the provider outcome was NOT established. These cases pin
// the general lifetime defects that can strand a real paid result:
//
//  * a local worker stop arriving AFTER the provider returned verified bytes
//    must still publish those bytes and commit their receipt (a cancelled
//    local waiter is not proof the provider failed);
//  * a process/worker death AFTER the deterministic output files were
//    written but BEFORE the receipt CAS must be adopted by the refresh/
//    relaunch pump from the ORIGINAL pinned workspace, with no provider call
//    and no resubmission;
//  * a partial batch is never claimed as delivered;
//  * an already-terminal unknown outcome is never resurrected;
//  * a migrated/revoked output owner is never repaired into a new workspace;
//  * a replayed tool call (same idempotency identity and exact request)
//    attaches to the ORIGINAL durable row even after it became terminal, so
//    a replay cannot pay twice;
//  * background/foreground-style refresh churn while a legitimate worker is
//    still dispatching never expires the live row and delivers exactly once.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders

final class G09R2AgentGenerationLifetimeTests: XCTestCase {
    private var roots: [URL] = []
    private var databases: [DatabaseManager] = []
    private var epochs: [UInt64] = []
    private var gates: [Gate] = []
    private static let epochLock = NSLock()
    nonisolated(unsafe) private static var epochCounter: UInt64 = 90_000

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

    /// Deterministic open/continuation gate; entering after `open()` passes
    /// through immediately.
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

    /// A real 1x1 RGBA PNG (valid bytes, never a text placeholder).
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
        let workspaceStore: SQLiteWorkspaceStore
        let jobStore: MediaGenerationJobStore
        let epoch: UInt64
        let conversationID: UUID
        let runID: UUID
        let providerID: UUID
        let modelID: UUID
        let workspaceID: UUID
        let imageAdapter: GatedImageAdapter
    }

    private final class GatedImageAdapter: ImageProviderAdapter, @unchecked Sendable {
        private let lock = NSLock()
        private var _performCount = 0
        var resultImages: [Data] = []
        var performHandler: (() async throws -> RemoteImageResult)?

        var performCount: Int {
            lock.lock(); defer { lock.unlock() }
            return _performCount
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
            lock.withLock { _performCount += 1 }
            if let performHandler { return try await performHandler() }
            return RemoteImageResult(images: resultImages)
        }
    }

    private func makeFixture(
        afterImageBytesWritten: (@Sendable () async -> Void)? = nil,
        abandonAfterImageWrite: Bool = false
    ) async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "floe-agent-generation-lifetime-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
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
                workspaceRecord.internalRelativePath
                    ?? "PrivateTasks/\(conversationID.uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true)
        let configuration = ModelConfigurationStore(database: manager)
        let provider = ProviderProfile(
            kind: .openAI,
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
        let root = try XCTUnwrap(
            RuntimeStorageRoot(validatingAbsoluteDirectory: url.path))
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
            afterImageBytesWritten: afterImageBytesWritten,
            abandonAfterImageWrite: abandonAfterImageWrite)
        let epoch = Self.nextEpoch()
        epochs.append(epoch)
        return Fixture(
            service: service, rootURL: url, workspaceURL: workspace,
            database: manager, workspaceStore: workspaceStore,
            jobStore: MediaGenerationJobStore(database: manager),
            epoch: epoch, conversationID: conversationID, runID: UUID(),
            providerID: provider.id, modelID: model.id,
            workspaceID: workspaceRecord.id, imageAdapter: imageAdapter)
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

    private func waitForWorkerSettled(
        _ fixture: Fixture, jobID: UUID, timeout: TimeInterval = 10
    ) async throws {
        let key = jobID.uuidString.lowercased()
        try await waitFor("worker settle for \(key)", timeout: timeout) {
            !G09R2GenerationService.shared.hasActiveWorker(jobID: key)
        }
    }

    private func resolvedWorkspace(_ fixture: Fixture) -> URL {
        fixture.workspaceURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func payloadData(_ payload: G09R2AgentGenerationPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    /// Seeds a durable image row with the exact pinned ORIGINAL target. The
    /// default age is past the freshness bound so a pump/status pass would
    /// classify it unknown without the deterministic-output recovery.
    private func seedPreparingImageJob(
        _ fixture: Fixture, prompt: String = "synthetic",
        count: Int = 1,
        createdAt: Date = Date().addingTimeInterval(
            -(G09R2GenerationService.stalePreparingSeconds + 60)),
        state: MediaGenerationJobState = .preparing,
        lastError: String? = nil,
        pinned: Bool = true,
        receiptSha256: String? = nil,
        receiptCount: Int = 1
    ) async throws -> (id: UUID, payload: G09R2AgentGenerationPayload) {
        let jobID = UUID()
        var payload = G09R2AgentGenerationPayload(
            prompt: prompt, routeID: fixture.modelID.uuidString.lowercased(),
            providerID: fixture.providerID, modelID: fixture.modelID,
            remoteModelID: "synthetic-image-1", count: count,
            targetWorkspaceID: pinned ? fixture.workspaceID : nil,
            targetWorkspaceRootPath: pinned
                ? resolvedWorkspace(fixture).path : nil)
        if let receiptSha256 {
            let images = (1...max(1, receiptCount)).map { index in
                G09R2AgentGenerationProducerImage(
                    index: index,
                    relativePath:
                        "GeneratedMedia/image-\(jobID.uuidString.lowercased())-\(index).png",
                    mimeType: "image/png",
                    byteCount: Int64(Self.pngBytes.count),
                    sha256: receiptSha256)
            }
            payload.producerReceipt = G09R2AgentGenerationProducerReceipt(
                jobID: jobID,
                ownerKind: MediaJobOwnerKind.conversation.rawValue,
                ownerID: fixture.conversationID,
                requestDigest: payload.requestDigest(),
                providerID: payload.providerID,
                modelID: payload.modelID,
                remoteModelID: payload.remoteModelID,
                count: payload.count,
                images: images)
        }
        let job = MediaGenerationJob(
            id: jobID,
            providerID: fixture.providerID, modelID: fixture.modelID,
            mediaKind: .image, credentialReference: nil,
            sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: try payloadData(payload), state: state,
            createdAt: createdAt, lastError: lastError)
        let creation = try await fixture.jobStore.createJob(
            job, owner: .conversation(fixture.conversationID),
            originRunID: fixture.runID,
            idempotencyKey: "seed-\(UUID().uuidString)")
        return (creation.job.id, payload)
    }

    private func writeDeterministicImage(
        _ fixture: Fixture, jobID: UUID, index: Int,
        bytes: Data = G09R2AgentGenerationLifetimeTests.pngBytes,
        extension ext: String = "png"
    ) throws -> URL {
        let directory = resolvedWorkspace(fixture)
            .appendingPathComponent("GeneratedMedia", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            "image-\(jobID.uuidString.lowercased())-\(index).\(ext)")
        try bytes.write(to: url)
        return url
    }

    // MARK: - Late local stop after a verified provider result

    /// The provider returned verified bytes, then the local worker was
    /// cancelled before delivery. The paid result must still be published
    /// with its receipt: a cancelled local waiter is not proof the provider
    /// failed and must not strand readable output.
    func testLateLocalStopAfterProviderSuccessStillPublishesVerifiedArtifacts() async throws {
        let fixture = try await makeFixture()
        let entered = expectation(description: "provider dispatch entered")
        let release = Gate()
        gates.append(release)
        fixture.imageAdapter.performHandler = {
            entered.fulfill()
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
        await fulfillment(of: [entered], timeout: 10)
        let cancelled = G09R2GenerationService.shared.requestCancel(
            jobID: summary.jobID.uuidString.lowercased(), epoch: fixture.epoch)
        XCTAssertTrue(cancelled, "the exact live worker must receive the local stop")
        release.open()
        try await waitFor("ready settlement despite the late local stop") {
            guard let owned = try await fixture.jobStore.ownedJob(id: summary.jobID)
            else { return false }
            return owned.job.state == .ready
        }
        try await waitForWorkerSettled(fixture, jobID: summary.jobID)
        let fetched = try await fixture.jobStore.ownedJob(id: summary.jobID)
        let owned = try XCTUnwrap(fetched)
        let payload = try JSONDecoder().decode(
            G09R2AgentGenerationPayload.self, from: owned.job.requestJSON)
        let artifact = try XCTUnwrap(payload.artifacts?.first)
        XCTAssertEqual(artifact.sha256, FloeDigest.sha256Hex(Self.pngBytes))
        XCTAssertEqual(artifact.byteCount, Int64(Self.pngBytes.count))
        let delivered = fixture.workspaceURL.appendingPathComponent(
            artifact.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: delivered.path))
        XCTAssertEqual(
            try FloeDigest.sha256Hex(ofFileAt: delivered), artifact.sha256,
            "the committed file must be the verified provider bytes")
        XCTAssertEqual(fixture.imageAdapter.performCount, 1,
                       "delivery must never resubmit the paid request")
    }

    // MARK: - Producer-receipt recovery (App-owned truth)

    /// The worker recorded the App-owned producer receipt from the REAL
    /// provider bytes, wrote the verified file, then stopped before the final
    /// CAS (the process-death window). A refresh must adopt ONLY bytes that
    /// match that trusted receipt, with no provider call.
    func testRefreshAdoptsRealProducerReceiptAfterPostWriteAbandon() async throws {
        let fixture = try await makeFixture(abandonAfterImageWrite: true)
        fixture.imageAdapter.resultImages = [Self.pngBytes]
        let summary = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: "key-\(UUID().uuidString)",
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a square", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        try await waitForWorkerSettled(fixture, jobID: summary.jobID)
        let fetched = try await fixture.jobStore.ownedJob(id: summary.jobID)
        let abandoned = try XCTUnwrap(fetched)
        XCTAssertEqual(abandoned.job.state, .submitted,
                       "the simulated post-write death leaves the row non-terminal")
        let abandonedPayload = try JSONDecoder().decode(
            G09R2AgentGenerationPayload.self, from: abandoned.job.requestJSON)
        let receipt = try XCTUnwrap(abandonedPayload.producerReceipt)
        XCTAssertEqual(receipt.requestDigest, abandonedPayload.requestDigest())
        XCTAssertEqual(receipt.images.count, 1)
        XCTAssertEqual(receipt.images[0].sha256,
                       FloeDigest.sha256Hex(Self.pngBytes))
        let path = fixture.workspaceURL.appendingPathComponent(
            receipt.images[0].relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        let statuses = try await fixture.service.refreshConversationJobs(
            epoch: fixture.epoch, conversationID: fixture.conversationID)
        let status = try XCTUnwrap(statuses.first { $0.jobID == summary.jobID })
        XCTAssertEqual(status.state, .ready)
        XCTAssertTrue(status.ready)
        XCTAssertEqual(status.artifacts?.first?.sha256,
                       FloeDigest.sha256Hex(Self.pngBytes))
        XCTAssertEqual(status.artifacts?.first?.byteCount,
                       Int64(Self.pngBytes.count))
        XCTAssertEqual(fixture.imageAdapter.performCount, 1,
                       "recovery must never call the provider again")
    }

    /// A valid PNG at the exact deterministic name but with NO durable
    /// producer receipt is not provider delivery: the workspace is
    /// model-writable and a filename/valid image/self-hash is not authority.
    func testForgedWorkspaceImageWithoutProducerReceiptIsNotAdopted() async throws {
        let fixture = try await makeFixture()
        let seeded = try await seedPreparingImageJob(fixture)
        _ = try writeDeterministicImage(fixture, jobID: seeded.id, index: 1)

        let statuses = try await fixture.service.refreshConversationJobs(
            epoch: fixture.epoch, conversationID: fixture.conversationID)
        let status = try XCTUnwrap(statuses.first { $0.jobID == seeded.id })
        XCTAssertFalse(status.ready)
        XCTAssertNil(status.artifacts)
        XCTAssertEqual(status.state, .expired)
        XCTAssertEqual(status.lastError, "outcomeUnknown")
        XCTAssertEqual(fixture.imageAdapter.performCount, 0)
    }

    /// A durable producer receipt is trusted proof only when the workspace
    /// bytes match its exact digest; a valid but different PNG is rejected.
    func testTamperedProducerReceiptIsNotAdopted() async throws {
        let fixture = try await makeFixture()
        let seeded = try await seedPreparingImageJob(
            fixture,
            receiptSha256: String(repeating: "a", count: 64))
        _ = try writeDeterministicImage(fixture, jobID: seeded.id, index: 1)

        let statuses = try await fixture.service.refreshConversationJobs(
            epoch: fixture.epoch, conversationID: fixture.conversationID)
        let status = try XCTUnwrap(statuses.first { $0.jobID == seeded.id })
        XCTAssertFalse(status.ready)
        XCTAssertNil(status.artifacts)
        XCTAssertEqual(status.state, .expired)
        XCTAssertEqual(status.lastError, "outcomeUnknown")
        XCTAssertEqual(fixture.imageAdapter.performCount, 0)
    }

    /// `status(refresh:false)` is read-only: it must not adopt files or
    /// mutate the durable row. The explicit refresh path is the adoption
    /// boundary.
    func testStatusWithoutRefreshDoesNotAdoptOrMutate() async throws {
        let fixture = try await makeFixture()
        let seeded = try await seedPreparingImageJob(
            fixture, receiptSha256: FloeDigest.sha256Hex(Self.pngBytes))
        _ = try writeDeterministicImage(fixture, jobID: seeded.id, index: 1)

        let status = try await fixture.service.status(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: seeded.id, refresh: false)
        XCTAssertEqual(status.state, .preparing)
        XCTAssertFalse(status.ready)
        XCTAssertNil(status.artifacts)
        let fetched = try await fixture.jobStore.ownedJob(id: seeded.id)
        XCTAssertEqual(fetched?.job.state, .preparing)
        XCTAssertEqual(fixture.imageAdapter.performCount, 0)
    }

    /// A partial batch (one of two requested images) is not a delivered
    /// result: the pump keeps the row honest and the stale classification
    /// settles it unknown without inventing artifacts.
    func testPartialImageBatchIsNeverClaimedAsDelivered() async throws {
        let fixture = try await makeFixture()
        let seeded = try await seedPreparingImageJob(
            fixture, count: 2,
            receiptSha256: FloeDigest.sha256Hex(Self.pngBytes),
            receiptCount: 2)
        _ = try writeDeterministicImage(fixture, jobID: seeded.id, index: 1)

        let statuses = try await fixture.service.refreshConversationJobs(
            epoch: fixture.epoch, conversationID: fixture.conversationID)
        let status = try XCTUnwrap(statuses.first { $0.jobID == seeded.id })
        XCTAssertFalse(status.ready)
        XCTAssertNil(status.artifacts)
        XCTAssertEqual(status.state, .expired)
        XCTAssertEqual(status.lastError, "outcomeUnknown")
        XCTAssertEqual(fixture.imageAdapter.performCount, 0)
    }

    /// A truncated/foreign file under the expected name is not a generated
    /// artifact. Recovery must re-sniff the bytes and keep the row unknown.
    func testCorruptDeterministicFileIsNotAdopted() async throws {
        let fixture = try await makeFixture()
        let seeded = try await seedPreparingImageJob(
            fixture, receiptSha256: FloeDigest.sha256Hex(Self.pngBytes))
        _ = try writeDeterministicImage(
            fixture, jobID: seeded.id, index: 1,
            bytes: Data("not-a-png".utf8))

        let statuses = try await fixture.service.refreshConversationJobs(
            epoch: fixture.epoch, conversationID: fixture.conversationID)
        let status = try XCTUnwrap(statuses.first { $0.jobID == seeded.id })
        XCTAssertFalse(status.ready)
        XCTAssertNil(status.artifacts)
        XCTAssertEqual(status.state, .expired)
        XCTAssertEqual(status.lastError, "outcomeUnknown")
        XCTAssertEqual(fixture.imageAdapter.performCount, 0)
    }

    /// A terminal unknown settlement is not a recoverable handle: a later
    /// refresh must not resurrect it just because a job-identified file is
    /// present. (The row was already shown to the user as unknown/expired.)
    func testTerminalUnknownOutcomeIsNotResurrectedByDeterministicFile() async throws {
        let fixture = try await makeFixture()
        let seeded = try await seedPreparingImageJob(
            fixture, createdAt: Date().addingTimeInterval(-600),
            state: .expired, lastError: "outcomeUnknown",
            receiptSha256: FloeDigest.sha256Hex(Self.pngBytes))
        _ = try writeDeterministicImage(fixture, jobID: seeded.id, index: 1)

        let status = try await fixture.service.status(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: seeded.id, refresh: true)
        XCTAssertEqual(status.state, .expired)
        XCTAssertFalse(status.ready)
        XCTAssertNil(status.artifacts)
        XCTAssertEqual(fixture.imageAdapter.performCount, 0)
    }

    /// A migrated/revoked output owner fences adoption: the old workspace's
    /// bytes are never republished into the new owner, and no current/guessed
    /// root is selected.
    func testMigratedWorkspaceOwnerFencesDeterministicAdoption() async throws {
        let fixture = try await makeFixture()
        let seeded = try await seedPreparingImageJob(
            fixture, receiptSha256: FloeDigest.sha256Hex(Self.pngBytes))
        _ = try writeDeterministicImage(fixture, jobID: seeded.id, index: 1)
        let other = WorkspaceRecord(
            name: "Moved task", rootBookmark: Data(),
            kind: .privateTask,
            internalRelativePath:
                "PrivateTasks/\(fixture.conversationID.uuidString)-moved")
        try await fixture.workspaceStore.saveWorkspace(other)
        try await fixture.workspaceStore.assignConversation(
            workspaceID: other.id, conversationID: fixture.conversationID)

        let status = try await fixture.service.status(
            epoch: fixture.epoch, conversationID: fixture.conversationID,
            jobID: seeded.id, refresh: true)
        XCTAssertFalse(status.ready)
        XCTAssertNil(status.artifacts)
        XCTAssertEqual(status.state, .expired)
        XCTAssertEqual(status.lastError, "outcomeUnknown")
        XCTAssertEqual(fixture.imageAdapter.performCount, 0)
        let newDirectory = fixture.rootURL
            .appendingPathComponent("Workspace", isDirectory: true)
            .appendingPathComponent(
                other.internalRelativePath ?? "", isDirectory: true)
            .appendingPathComponent("GeneratedMedia", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: newDirectory.path),
                       "nothing may be published into the replacement owner")
    }

    // MARK: - Replay never pays twice

    /// The first call dispatched and settled `outcomeUnknown`. Replaying the
    /// EXACT same tool operation must return that durable row, not create a
    /// new paying job — even though the old row is terminal.
    func testReplayedToolCallAfterUnknownAttachesWithoutSecondPaidSubmission() async throws {
        let fixture = try await makeFixture()
        fixture.imageAdapter.performHandler = {
            throw URLError(.networkConnectionLost)
        }
        let key = "replay-\(UUID().uuidString)"
        let first = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: key,
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a triangle", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        try await waitFor("durable outcomeUnknown settlement") {
            guard let owned = try await fixture.jobStore.ownedJob(id: first.jobID)
            else { return false }
            return owned.job.state == .expired
        }
        try await waitForWorkerSettled(fixture, jobID: first.jobID)
        fixture.imageAdapter.performHandler = nil
        fixture.imageAdapter.resultImages = [Self.pngBytes]

        let replay = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: key,
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a triangle", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        XCTAssertEqual(replay.jobID, first.jobID)
        XCTAssertTrue(replay.deduplicated)
        XCTAssertEqual(replay.state, .expired)
        XCTAssertEqual(fixture.imageAdapter.performCount, 1,
                       "a replayed identical call must never pay a second time")
    }

    /// A replay after the first job was delivered must report that delivered
    /// row and its artifacts, not start a new paying job.
    func testReplayedToolCallAfterReadyAttachesToDeliveredJob() async throws {
        let fixture = try await makeFixture()
        fixture.imageAdapter.resultImages = [Self.pngBytes]
        let key = "replay-\(UUID().uuidString)"
        let first = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: key,
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a star", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        try await waitFor("first ready") {
            guard let owned = try await fixture.jobStore.ownedJob(id: first.jobID)
            else { return false }
            return owned.job.state == .ready
        }
        let replay = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: key,
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a star", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        XCTAssertEqual(replay.jobID, first.jobID)
        XCTAssertTrue(replay.deduplicated)
        XCTAssertEqual(replay.state, .ready)
        XCTAssertEqual(fixture.imageAdapter.performCount, 1)
    }

    /// A DIFFERENT request under the SAME submitting-operation key is a
    /// contract violation: the atomic store must refuse it, never attach the
    /// old job and never create a second paying job.
    func testConflictingReusedOperationKeyIsRefused() async throws {
        let fixture = try await makeFixture()
        fixture.imageAdapter.resultImages = [Self.pngBytes]
        let key = "replay-\(UUID().uuidString)"
        _ = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: key,
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a circle", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        do {
            _ = try await fixture.service.submitImage(
                epoch: fixture.epoch,
                conversationID: fixture.conversationID,
                runID: fixture.runID,
                idempotencyKey: key,
                workspaceRootURL: fixture.workspaceURL,
                prompt: "draw a square", selection: nil, legacyModelID: nil,
                count: 1, size: nil, aspectRatio: nil, resolution: nil,
                quality: nil, referenceRelativePath: nil)
            XCTFail("a different request under the same key must be refused")
        } catch let error as FloeError {
            XCTAssertEqual(error.reason, "idempotencyConflict")
        }
        XCTAssertEqual(fixture.imageAdapter.performCount, 1,
                       "a refused conflict must never pay a second time")
        let jobs = try await fixture.jobStore.jobs(
            owner: .conversation(fixture.conversationID))
        XCTAssertEqual(jobs.count, 1)
    }

    // MARK: - Background/foreground refresh retains a live owner

    /// While the provider dispatch is legitimately in flight, status/resume
    /// churn (the background/foreground and relaunch pump path) must never
    /// expire the row; the one provider call delivers exactly once.
    func testRefreshChurnDuringLiveDispatchKeepsOwnerAndDeliversOnce() async throws {
        let fixture = try await makeFixture()
        let entered = expectation(description: "provider dispatch entered")
        let release = Gate()
        gates.append(release)
        fixture.imageAdapter.performHandler = {
            entered.fulfill()
            await release.enterAndWait()
            return RemoteImageResult(images: [Self.pngBytes])
        }
        let summary = try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: fixture.conversationID,
            runID: fixture.runID,
            idempotencyKey: "key-\(UUID().uuidString)",
            workspaceRootURL: fixture.workspaceURL,
            prompt: "draw a dot", selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
        await fulfillment(of: [entered], timeout: 10)
        for _ in 0..<6 {
            let status = try await fixture.service.status(
                epoch: fixture.epoch, conversationID: fixture.conversationID,
                jobID: summary.jobID, refresh: true)
            XCTAssertFalse(status.terminated,
                           "a live dispatch must not be expired by refresh churn")
            await fixture.service.resumeStaleJobs(
                epoch: fixture.epoch, conversationID: fixture.conversationID)
        }
        release.open()
        try await waitFor("single ready settlement") {
            guard let owned = try await fixture.jobStore.ownedJob(id: summary.jobID)
            else { return false }
            return owned.job.state == .ready
        }
        try await waitForWorkerSettled(fixture, jobID: summary.jobID)
        XCTAssertEqual(fixture.imageAdapter.performCount, 1)
        let finalSnapshot = try await fixture.jobStore.ownedJob(id: summary.jobID)
        let finalOwned = try XCTUnwrap(finalSnapshot)
        let payload = try JSONDecoder().decode(
            G09R2AgentGenerationPayload.self, from: finalOwned.job.requestJSON)
        XCTAssertEqual(payload.artifacts?.count, 1)
    }
}
