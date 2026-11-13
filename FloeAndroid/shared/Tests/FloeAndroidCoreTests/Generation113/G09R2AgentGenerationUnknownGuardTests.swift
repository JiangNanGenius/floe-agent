// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 agent generation unknown-outcome anti-retry regressions (Full114
// fifth-submission defect, job-68d966b82345413c). Authored source; the
// coordinator executes the combined gate (this lane performs NO build/test
// execution). Every case drives the REAL production
// `G09R2AgentGenerationService`/`MediaGenerationJobStore` against a temporary
// explicit root and an in-memory GRDB database with synthetic adapters at the
// provider boundary — no network, no device, no provider call.
//
// Contract pinned here:
//  * an unresolved `outcomeUnknown` paid submission blocks a
//    CHANGED prompt/model/provider/tool-call retry in the SAME trusted
//    conversation+origin run, even when it races concurrently;
//  * the original unknown row is preserved (no rewrite, no replacement row)
//    and the caller is told which existing job owns the unknown truth;
//  * initial independent concurrent image submissions in one run still all
//    dispatch (the guard is not a same-run serializer);
//  * a genuinely new run, and a different conversation owner, are not
//    globally disabled;
//  * an explicit transport refusal before task creation does not block the
//    next distinct prompt; connection error names alone cannot prove that
//    a generation request was never accepted;
//  * the bounded non-secret failure diagnostic records how far the request
//    got and is excluded from the replay/request identity, so recording it
//    can never cause a conflict or a second paid submission.
import XCTest
import Foundation
@testable import FloeAndroidCore
import FloeCore
import FloePersistence
import FloeProviders
import FloeTransport

final class G09R2AgentGenerationUnknownGuardTests: XCTestCase {
    private var roots: [URL] = []
    private var databases: [DatabaseManager] = []
    private var epochs: [UInt64] = []
    private var gates: [Gate] = []
    private static let epochLock = NSLock()
    nonisolated(unsafe) private static var epochCounter: UInt64 = 120_000

    override func tearDown() async throws {
        // Drain this test's workers BEFORE closing the databases: a worker
        // that touches a closed GRDB connection crashes the test process.
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

    /// Deterministic open/continuation gate: entering after `open()` passes
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
        let jobStore: MediaGenerationJobStore
        let conversationID: UUID
        let runID: UUID
        let providerID: UUID
        let modelID: UUID
        let epoch: UInt64
        let imageAdapter: GatedImageAdapter
    }

    private final class GatedImageAdapter: ImageProviderAdapter, @unchecked Sendable {
        private let lock = NSLock()
        private var _performCount = 0
        var resultImages: [Data] = []
        var performHandler: ((RemoteImageRequest) async throws -> RemoteImageResult)?

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
            if let performHandler { return try await performHandler(request) }
            return RemoteImageResult(images: resultImages)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "floe-agent-generation-unknown-guard-\(UUID().uuidString)",
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
            platform: platform, environmentProvider: { _ in environment })
        let epoch = Self.nextEpoch()
        epochs.append(epoch)
        return Fixture(
            service: service, rootURL: url, workspaceURL: workspace,
            database: manager, jobStore: MediaGenerationJobStore(database: manager),
            conversationID: conversationID, runID: UUID(),
            providerID: provider.id, modelID: model.id,
            epoch: epoch, imageAdapter: imageAdapter)
    }

    /// Adds a second conversation with its own durable workspace binding in
    /// the same synthetic root (the owner-isolation boundary).
    private func addConversation(
        _ fixture: Fixture
    ) async throws -> (conversationID: UUID, workspaceURL: URL) {
        let conversationID = UUID()
        let conversationStore = SQLiteConversationStore(database: fixture.database)
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "Synthetic other task",
            createdAt: Date(), updatedAt: Date()))
        let workspaceStore = SQLiteWorkspaceStore(database: fixture.database)
        let record = try await workspaceStore.ensureWorkspace(
            conversationID: conversationID, title: "Synthetic other task")
        let workspace = fixture.rootURL
            .appendingPathComponent("Workspace", isDirectory: true)
            .appendingPathComponent(
                record.internalRelativePath
                    ?? "PrivateTasks/\(conversationID.uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace, withIntermediateDirectories: true)
        return (conversationID, workspace)
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

    @discardableResult
    private func submit(
        _ fixture: Fixture,
        prompt: String,
        runID: UUID? = nil,
        conversationID: UUID? = nil,
        workspaceURL: URL? = nil,
        key: String = "key-\(UUID().uuidString)"
    ) async throws -> G09R2AgentSubmissionSummary {
        try await fixture.service.submitImage(
            epoch: fixture.epoch,
            conversationID: conversationID ?? fixture.conversationID,
            runID: runID ?? fixture.runID,
            idempotencyKey: key,
            workspaceRootURL: workspaceURL ?? fixture.workspaceURL,
            prompt: prompt, selection: nil, legacyModelID: nil,
            count: 1, size: nil, aspectRatio: nil, resolution: nil,
            quality: nil, referenceRelativePath: nil)
    }

    private func waitForUnknown(
        _ fixture: Fixture, jobID: UUID, timeout: TimeInterval = 10
    ) async throws {
        try await waitFor("durable outcomeUnknown", timeout: timeout) {
            guard let owned = try await fixture.jobStore.ownedJob(id: jobID)
            else { return false }
            return owned.job.state == .expired
                && owned.job.lastError == "outcomeUnknown"
        }
        try await waitForWorkerSettled(fixture, jobID: jobID)
    }

    // MARK: - Same-run changed-prompt retry is refused

    /// The exact Full114 bypass: after an unknown settlement the model
    /// changed the prompt and got a fifth accepted job. The durable guard
    /// must return the ORIGINAL unknown row and pay nothing.
    func testChangedPromptInSameRunIsBlockedByDurableUnknownGuard() async throws {
        let fixture = try await makeFixture()
        fixture.imageAdapter.performHandler = { request in
            request.wirePhaseObserver?(.requestStarted)
            throw URLError(.networkConnectionLost)
        }
        let first = try await submit(fixture, prompt: "draw a triangle")
        try await waitForUnknown(fixture, jobID: first.jobID)
        XCTAssertEqual(fixture.imageAdapter.performCount, 1)

        fixture.imageAdapter.performHandler = nil
        fixture.imageAdapter.resultImages = [Self.pngBytes]
        let blocked = try await submit(fixture, prompt: "draw a purple triangle")
        XCTAssertEqual(blocked.jobID, first.jobID,
                       "the guard must return the original unknown row")
        XCTAssertTrue(blocked.deduplicated,
                      "no new job may be presented as a fresh submission")
        XCTAssertEqual(blocked.blockedByUnresolvedUnknown, first.jobID)
        XCTAssertEqual(blocked.lastError, "outcomeUnknown")
        XCTAssertEqual(blocked.state, .expired)
        XCTAssertEqual(fixture.imageAdapter.performCount, 1,
                       "a changed prompt must never buy a replacement")

        let rows = try await fixture.jobStore.jobs(
            owner: .conversation(fixture.conversationID))
        XCTAssertEqual(rows.count, 1, "no replacement row may be inserted")
        let originalRow = try await fixture.jobStore.ownedJob(id: first.jobID)
        let original = try XCTUnwrap(originalRow)
        XCTAssertEqual(original.job.state, .expired)
        XCTAssertEqual(original.job.lastError, "outcomeUnknown")

        // The bounded diagnostic is durable and non-secret: only the fixed
        // stage spelling and a URL error-class code, never the prompt.
        let payload = try JSONDecoder().decode(
            G09R2AgentGenerationPayload.self, from: original.job.requestJSON)
        let diagnostic = try XCTUnwrap(payload.diagnostics)
        XCTAssertEqual(diagnostic.stages, ["requestStarted"])
        XCTAssertEqual(diagnostic.failureCode, "urlError.networkConnectionLost")
        XCTAssertNil(diagnostic.relatedJobID)
        let diagnosticJSON = String(
            decoding: try JSONEncoder().encode(diagnostic), as: UTF8.self)
        XCTAssertFalse(diagnosticJSON.lowercased().contains("triangle"),
                       "the diagnostic must never carry prompt text")
        XCTAssertFalse(diagnosticJSON.contains("synthetic.example"),
                       "the diagnostic must never carry endpoint text")
    }

    /// Concurrent changed-prompt retries after the unknown settle to the SAME
    /// original row: one writer/one paid submission, no duplicate jobs.
    func testConcurrentChangedPromptRetriesAfterUnknownCreateNoReplacement() async throws {
        let fixture = try await makeFixture()
        fixture.imageAdapter.performHandler = { request in
            request.wirePhaseObserver?(.requestStarted)
            throw URLError(.networkConnectionLost)
        }
        let first = try await submit(fixture, prompt: "draw a triangle")
        try await waitForUnknown(fixture, jobID: first.jobID)

        fixture.imageAdapter.performHandler = nil
        fixture.imageAdapter.resultImages = [Self.pngBytes]
        let service = fixture.service
        let epoch = fixture.epoch
        let conversationID = fixture.conversationID
        let runID = fixture.runID
        let workspace = fixture.workspaceURL
        let results = try await withThrowingTaskGroup(
            of: G09R2AgentSubmissionSummary.self
        ) { group -> [G09R2AgentSubmissionSummary] in
            for index in 0..<8 {
                group.addTask {
                    try await service.submitImage(
                        epoch: epoch, conversationID: conversationID,
                        runID: runID,
                        idempotencyKey: "key-\(UUID().uuidString)",
                        workspaceRootURL: workspace,
                        prompt: "draw variant \(index)", selection: nil,
                        legacyModelID: nil, count: 1, size: nil,
                        aspectRatio: nil, resolution: nil, quality: nil,
                        referenceRelativePath: nil)
                }
            }
            var values: [G09R2AgentSubmissionSummary] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0.jobID == first.jobID })
        XCTAssertTrue(results.allSatisfy { $0.blockedByUnresolvedUnknown == first.jobID })
        XCTAssertEqual(fixture.imageAdapter.performCount, 1,
                       "concurrent changed-prompt retries must not pay")
        let rows = try await fixture.jobStore.jobs(
            owner: .conversation(fixture.conversationID))
        XCTAssertEqual(rows.count, 1)
    }

    // MARK: - Legitimate independent work is not globally disabled

    /// Initial independent submissions in one run are NOT serialized: the
    /// guard only activates once an unresolved unknown exists.
    func testInitialIndependentConcurrentImagesStillAllDispatch() async throws {
        let fixture = try await makeFixture()
        let release = Gate()
        gates.append(release)
        let entered = expectation(description: "both adapter calls entered")
        entered.expectedFulfillmentCount = 2
        fixture.imageAdapter.performHandler = { _ in
            entered.fulfill()
            await release.enterAndWait()
            return RemoteImageResult(images: [Self.pngBytes])
        }
        let service = fixture.service
        let epoch = fixture.epoch
        let conversationID = fixture.conversationID
        let runID = fixture.runID
        let workspace = fixture.workspaceURL
        let summaries = try await withThrowingTaskGroup(
            of: G09R2AgentSubmissionSummary.self
        ) { group -> [G09R2AgentSubmissionSummary] in
            for prompt in ["draw a red square", "draw a blue square"] {
                group.addTask {
                    try await service.submitImage(
                        epoch: epoch, conversationID: conversationID,
                        runID: runID,
                        idempotencyKey: "key-\(UUID().uuidString)",
                        workspaceRootURL: workspace,
                        prompt: prompt, selection: nil, legacyModelID: nil,
                        count: 1, size: nil, aspectRatio: nil, resolution: nil,
                        quality: nil, referenceRelativePath: nil)
                }
            }
            var values: [G09R2AgentSubmissionSummary] = []
            for try await value in group { values.append(value) }
            return values
        }
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertEqual(Set(summaries.map(\.jobID)).count, 2,
                       "initial independent requests must create two jobs")
        XCTAssertTrue(summaries.allSatisfy {
            $0.blockedByUnresolvedUnknown == nil && !$0.deduplicated
        })
        release.open()
        for summary in summaries {
            try await waitFor("ready for \(summary.jobID)") {
                guard let owned = try await fixture.jobStore.ownedJob(
                    id: summary.jobID) else { return false }
                return owned.job.state == .ready
            }
            try await waitForWorkerSettled(fixture, jobID: summary.jobID)
        }
        XCTAssertEqual(fixture.imageAdapter.performCount, 2)
    }

    /// A genuinely new user run is a separate trusted lineage: the guard is
    /// owner+run scoped, never a global kill switch.
    func testNewRunIsNotBlockedByAnotherRunsUnknown() async throws {
        let fixture = try await makeFixture()
        fixture.imageAdapter.performHandler = { request in
            request.wirePhaseObserver?(.requestStarted)
            throw URLError(.networkConnectionLost)
        }
        let first = try await submit(fixture, prompt: "draw a triangle")
        try await waitForUnknown(fixture, jobID: first.jobID)

        fixture.imageAdapter.performHandler = nil
        fixture.imageAdapter.resultImages = [Self.pngBytes]
        let retry = try await submit(
            fixture, prompt: "draw a purple triangle", runID: UUID())
        XCTAssertNotEqual(retry.jobID, first.jobID)
        XCTAssertNil(retry.blockedByUnresolvedUnknown)
        try await waitFor("new-run ready") {
            guard let owned = try await fixture.jobStore.ownedJob(id: retry.jobID)
            else { return false }
            return owned.job.state == .ready
        }
        try await waitForWorkerSettled(fixture, jobID: retry.jobID)
        XCTAssertEqual(fixture.imageAdapter.performCount, 2)
    }

    /// A different conversation owner is unrelated lineage: its submission is
    /// never blocked by another conversation's unknown job.
    func testDifferentConversationOwnerIsNotBlockedByUnknown() async throws {
        let fixture = try await makeFixture()
        fixture.imageAdapter.performHandler = { request in
            request.wirePhaseObserver?(.requestStarted)
            throw URLError(.networkConnectionLost)
        }
        let first = try await submit(fixture, prompt: "draw a triangle")
        try await waitForUnknown(fixture, jobID: first.jobID)

        let other = try await addConversation(fixture)
        fixture.imageAdapter.performHandler = nil
        fixture.imageAdapter.resultImages = [Self.pngBytes]
        let otherSummary = try await submit(
            fixture, prompt: "draw a triangle",
            conversationID: other.conversationID,
            workspaceURL: other.workspaceURL)
        XCTAssertNotEqual(otherSummary.jobID, first.jobID)
        XCTAssertNil(otherSummary.blockedByUnresolvedUnknown)
        try await waitFor("other owner ready") {
            guard let owned = try await fixture.jobStore.ownedJob(
                id: otherSummary.jobID) else { return false }
            return owned.job.state == .ready
        }
        try await waitForWorkerSettled(fixture, jobID: otherSummary.jobID)
        XCTAssertEqual(fixture.imageAdapter.performCount, 2)
        let original = try await fixture.jobStore.ownedJob(id: first.jobID)
        XCTAssertEqual(original?.job.state, .expired)
        XCTAssertEqual(original?.job.lastError, "outcomeUnknown")
    }

    // MARK: - Definite pre-dispatch failure vs real unknown

    /// The transport's registration refusal happens before creating any
    /// request task; this is actual non-dispatch evidence.
    func testDefinitePreDispatchFailureDoesNotBlockNextPrompt() async throws {
        let fixture = try await makeFixture()
        fixture.imageAdapter.performHandler = { request in
            request.wirePhaseObserver?(.requestStarted)
            throw IncrementalTransportError.sessionNotStreamable(reason: "synthetic refusal")
        }
        let first = try await submit(fixture, prompt: "draw a triangle")
        try await waitFor("definite pre-dispatch failure") {
            guard let owned = try await fixture.jobStore.ownedJob(id: first.jobID)
            else { return false }
            return owned.job.state == .failed
        }
        try await waitForWorkerSettled(fixture, jobID: first.jobID)
        let failedRow = try await fixture.jobStore.ownedJob(id: first.jobID)
        let failed = try XCTUnwrap(failedRow)
        XCTAssertEqual(failed.job.state, .failed)
        XCTAssertEqual(failed.job.lastError, "requestNotDispatched")
        let failedPayload = try JSONDecoder().decode(
            G09R2AgentGenerationPayload.self, from: failed.job.requestJSON)
        XCTAssertEqual(failedPayload.diagnostics?.stages,
                       [RemoteImageWirePhase.requestStarted.rawValue])
        XCTAssertEqual(
            failedPayload.diagnostics?.failureCode, "transport.sessionNotStreamable")

        fixture.imageAdapter.performHandler = nil
        fixture.imageAdapter.resultImages = [Self.pngBytes]
        let next = try await submit(fixture, prompt: "draw a circle")
        XCTAssertNotEqual(next.jobID, first.jobID,
                          "a definite pre-dispatch failure is not unknown")
        XCTAssertNil(next.blockedByUnresolvedUnknown)
        try await waitFor("next prompt ready") {
            guard let owned = try await fixture.jobStore.ownedJob(id: next.jobID)
            else { return false }
            return owned.job.state == .ready
        }
        try await waitForWorkerSettled(fixture, jobID: next.jobID)
        XCTAssertEqual(fixture.imageAdapter.performCount, 2)
    }

    func testConnectionErrorAfterRequestEntryDoesNotAuthorizeReplacement() async throws {
        let fixture = try await makeFixture()
        fixture.imageAdapter.performHandler = { request in
            request.wirePhaseObserver?(.requestStarted)
            throw URLError(.secureConnectionFailed)
        }
        let first = try await submit(fixture, prompt: "draw a triangle")
        try await waitForUnknown(fixture, jobID: first.jobID)
        try await waitForWorkerSettled(fixture, jobID: first.jobID)
        fixture.imageAdapter.performHandler = nil
        let blocked = try await submit(fixture, prompt: "draw another triangle")
        XCTAssertEqual(blocked.jobID, first.jobID)
        XCTAssertEqual(blocked.blockedByUnresolvedUnknown, first.jobID)
        XCTAssertEqual(fixture.imageAdapter.performCount, 1)
    }

    /// A provider reply that cannot be used (no image parts) after the HTTP
    /// response is a real ambiguous outcome: it stays `outcomeUnknown` and
    /// blocks a changed-prompt replacement.
    func testInvalidResponseAfterProviderReplyStaysUnknownAndBlocksRetry() async throws {
        let fixture = try await makeFixture()
        fixture.imageAdapter.performHandler = { request in
            request.wirePhaseObserver?(.requestStarted)
            request.wirePhaseObserver?(.responseReceived)
            throw RemoteImageError.invalidResponse("synthetic unusable reply")
        }
        let first = try await submit(fixture, prompt: "draw a triangle")
        try await waitForUnknown(fixture, jobID: first.jobID)
        let originalRow = try await fixture.jobStore.ownedJob(id: first.jobID)
        let original = try XCTUnwrap(originalRow)
        let payload = try JSONDecoder().decode(
            G09R2AgentGenerationPayload.self, from: original.job.requestJSON)
        XCTAssertEqual(payload.diagnostics?.stages,
                       ["requestStarted", "responseReceived"])
        XCTAssertEqual(payload.diagnostics?.failureCode, "invalidResponse")

        fixture.imageAdapter.performHandler = nil
        fixture.imageAdapter.resultImages = [Self.pngBytes]
        let blocked = try await submit(fixture, prompt: "draw a square")
        XCTAssertEqual(blocked.jobID, first.jobID)
        XCTAssertEqual(blocked.blockedByUnresolvedUnknown, first.jobID)
        XCTAssertEqual(fixture.imageAdapter.performCount, 1)
    }

    /// Direct contract of the definitive/ambiguous classifier: only errors
    /// that provably precede any HTTP acceptance are definite, and a provider
    /// response or an issued image-URL download proves the paid call already
    /// happened.
    func testDefinitePreDispatchClassifierTable() {
        typealias Service = G09R2AgentGenerationService
        let started = RemoteImageWirePhase.requestStarted.rawValue
        let responded = RemoteImageWirePhase.responseReceived.rawValue
        let download = RemoteImageWirePhase.downloadStarted.rawValue

        XCTAssertFalse(Service.isDefinitePreDispatchTransportFailure(
            URLError(.cannotFindHost), stages: []))
        XCTAssertFalse(Service.isDefinitePreDispatchTransportFailure(
            URLError(.cannotConnectToHost), stages: [started]))
        XCTAssertFalse(Service.isDefinitePreDispatchTransportFailure(
            URLError(.dnsLookupFailed), stages: []))
        XCTAssertFalse(Service.isDefinitePreDispatchTransportFailure(
            URLError(.notConnectedToInternet), stages: []))
        XCTAssertFalse(Service.isDefinitePreDispatchTransportFailure(
            URLError(.secureConnectionFailed), stages: []))
        XCTAssertTrue(Service.isDefinitePreDispatchTransportFailure(
            IncrementalTransportError.sessionNotStreamable(reason: "synthetic"),
            stages: []))
        // A timeout or connection loss may have reached the provider.
        XCTAssertFalse(Service.isDefinitePreDispatchTransportFailure(
            URLError(.timedOut), stages: [started]))
        XCTAssertFalse(Service.isDefinitePreDispatchTransportFailure(
            URLError(.networkConnectionLost), stages: [started]))
        // A response or a download proves the paid request completed.
        XCTAssertFalse(Service.isDefinitePreDispatchTransportFailure(
            IncrementalTransportError.sessionNotStreamable(reason: "synthetic"),
            stages: [started, responded, download]))
        XCTAssertFalse(Service.isDefinitePreDispatchTransportFailure(
            RemoteImageError.invalidResponse("synthetic"), stages: [responded]))
        XCTAssertFalse(Service.isDefinitePreDispatchTransportFailure(
            FloeError.validationFailed("synthetic"), stages: [started]))
    }

    // MARK: - Diagnostic must not change replay identity

    /// The failed row's diagnostic is written into the durable payload AFTER
    /// the paid call. Replaying the SAME submitting operation must still
    /// attach to that row (no idempotency conflict, no second payment).
    func testReplayAfterUnknownDiagnosticStillAttachesWithoutSecondPayment() async throws {
        let fixture = try await makeFixture()
        fixture.imageAdapter.performHandler = { request in
            request.wirePhaseObserver?(.requestStarted)
            throw URLError(.timedOut)
        }
        let key = "replay-\(UUID().uuidString)"
        let first = try await submit(fixture, prompt: "draw a dot", key: key)
        try await waitForUnknown(fixture, jobID: first.jobID)
        let failedRow = try await fixture.jobStore.ownedJob(id: first.jobID)
        let failed = try XCTUnwrap(failedRow)
        XCTAssertEqual(
            (try JSONDecoder().decode(
                G09R2AgentGenerationPayload.self,
                from: failed.job.requestJSON)).diagnostics?.failureCode,
            "urlError.timedOut")

        fixture.imageAdapter.performHandler = nil
        fixture.imageAdapter.resultImages = [Self.pngBytes]
        let replay = try await submit(
            fixture, prompt: "draw a dot", key: key)
        XCTAssertEqual(replay.jobID, first.jobID)
        XCTAssertTrue(replay.deduplicated)
        XCTAssertNil(replay.blockedByUnresolvedUnknown)
        XCTAssertEqual(fixture.imageAdapter.performCount, 1,
                       "an exact replay must never pay a second time")
    }
}
