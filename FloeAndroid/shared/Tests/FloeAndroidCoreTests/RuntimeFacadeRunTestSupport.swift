// SPDX-License-Identifier: MPL-2.0
//
// RB-4 RunDomain test support. AUTHORED, NOT EXECUTED — no assertion here
// is a run. Fixtures use the REAL original file-backed `DatabaseManager`
// (the original schema-46 migration chain), the REAL store objects and the
// REAL `ConversationRunService`/`FloeAgentRuntime`; ONLY the model stream
// and tool runners are synthetic test doubles (injected through the
// component overrides — never production fallback paths).
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
@testable import FloeAndroidCore

// MARK: - Synthetic provider adapter (TEST ONLY model stream)

/// Streams a pre-scripted AgentEvent sequence through the ORIGINAL adapter
/// surface to drive the real runtime/harness channel deterministically.
/// It performs NO I/O and never fabricates a provider wire.
final class ScriptedRunAdapter: ProviderAdapter, @unchecked Sendable {
    struct Script {
        var events: [AgentEvent]
        /// Optional gate: stalls after the listed prefix until released
        /// (cancellation-during-await tests).
        var stallAfter: Int
        var gate: RunGateBox?
        init(events: [AgentEvent], stallAfter: Int = 0, gate: RunGateBox? = nil) {
            self.events = events
            self.stallAfter = stallAfter
            self.gate = gate
        }
    }

    private let lock = NSLock()
    private var scripts: [Int: Script] = [:]
    private var defaultScript: Script
    private var requestIndex = 0
    private var _requests: [ProviderStreamRequest] = []
    /// REAL stream-termination witnesses for cancellation proof: set ONLY
    /// when the provider stream actually terminates (and when the producer
    /// really observed cancellation), never by a test-side tick.
    private let terminationLock = NSLock()
    private var _streamTerminations = 0
    private var _streamCancellations = 0
    var streamTerminationCount: Int {
        terminationLock.lock(); defer { terminationLock.unlock() }
        return _streamTerminations
    }
    var streamCancellationCount: Int {
        terminationLock.lock(); defer { terminationLock.unlock() }
        return _streamCancellations
    }

    init(defaultScript: Script) {
        self.defaultScript = defaultScript
    }

    var protocolKind: ModelProtocol { .openAIChatCompletions }

    func enqueue(script: Script, forRequest index: Int) {
        lock.lock(); scripts[index] = script; lock.unlock()
    }

    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _requests.count }
    var lastRequest: ProviderStreamRequest? {
        lock.lock(); defer { lock.unlock() }; return _requests.last
    }

    func stream(request: ProviderStreamRequest,
                credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        lock.lock()
        let index = requestIndex
        requestIndex += 1
        _requests.append(request)
        let script = scripts[index] ?? defaultScript
        lock.unlock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                for (position, event) in script.events.enumerated() {
                    if Task.isCancelled {
                        withScopedLock(self.terminationLock) { self._streamCancellations += 1 }
                        continuation.finish(); return
                    }
                    if position == script.stallAfter, let gate = script.gate {
                        await gate.waitThroughCancellation()
                        if Task.isCancelled {
                            withScopedLock(self.terminationLock) { self._streamCancellations += 1 }
                            continuation.finish(); return
                        }
                    }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                withScopedLock(self.terminationLock) { self._streamTerminations += 1 }
                task.cancel()
            }
        }
    }

    func listModels(provider: ProviderProfile,
                    credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
    func testConnection(provider: ProviderProfile,
                        credentials: ProviderCredentials) async throws {}
}

/// Cancellable rendezvous used by stream fault injection (test-only).
final class RunGateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var _waiting = false
    /// True once a waiter actually entered the gate (lets tests sequence
    /// off the REAL stall instead of a sleep guess).
    var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return _waiting }
    func release() { lock.lock(); released = true; lock.unlock() }
    func waitThroughCancellation() async {
        withScopedLock(lock) { _waiting = true }
        while !Task.isCancelled {
            let ready = withScopedLock(lock) { released }
            if ready { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

// MARK: - Test tool doubles (registered into an ISOLATED registry)

/// Non-side-effecting echo tool: proves stream→toolRequest→toolResult
/// projection and dispatch through the REAL runtime pipeline.
struct FixtureEchoTool: AgentTool {
    struct Arguments: Decodable, Sendable { var message: String }
    static let name = "fixture.echo"
    static let toolDescription = "Deterministic test echo"
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let payload = "echo:\(args.message)"
        return ToolExecutionOutput(
            summary: payload,
            fullOutputSHA256: RunWireDigest.sha256Hex(Data(payload.utf8)))
    }
}

/// Side-effecting fixture: under HumanApprovalPolicy this MUST escalate to
/// a real approval card (pending request + review state), never auto-run.
struct FixtureSideEffectTool: AgentTool {
    struct Arguments: Decodable, Sendable { var target: String }
    static let name = "fixture.side"
    static let toolDescription = "Deterministic test side effect"
    static let riskLabels: Set<RiskLabel> = [.writesFiles]
    static let isSideEffecting = true
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let payload = "side:\(args.target)"
        return ToolExecutionOutput(
            summary: payload,
            fullOutputSHA256: RunWireDigest.sha256Hex(Data(payload.utf8)))
    }
}

/// A tool that cooperatively waits for cancellation, so "cancel during a
/// live await" tests observe the REAL runtime cancel contract.
struct FixtureBlockingTool: AgentTool {
    struct Arguments: Decodable, Sendable { var unused: String? }
    static let name = "fixture.block"
    static let toolDescription = "Blocks until cancelled"
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let started = RunGateBox()
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        Self.started.release()
        while !context.cancellation.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return ToolExecutionOutput(
            summary: "cancelled",
            fullOutputSHA256: RunWireDigest.sha256Hex(Data("cancelled".utf8)))
    }
}

enum FixtureTools {
    static func registerAll(into registry: ToolRunnerRegistry) {
        ToolCatalog.register(FixtureEchoTool.self)
        ToolCatalog.register(FixtureSideEffectTool.self)
        ToolCatalog.register(FixtureBlockingTool.self)
        registry.register(FixtureEchoTool())
        registry.register(FixtureSideEffectTool())
        registry.register(FixtureBlockingTool())
    }
}

// MARK: - Ingress-port doubles (explicitly test-only; production binds the
// vault-07/P8/RB6/RB3b originals)

final class TestSecretGateway: AndroidSecretGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]
    var failReads = false
    /// C05 queue-retirement regressions (job-7cb6799042f94ec7): a
    /// deterministic read-count gate. When set, reads AFTER the Nth fail —
    /// used to land the start pipeline's step-8 `serviceAssemblyFailed`
    /// refusal (the credentials resolve) while the step-4 admission
    /// resolve still succeeds, with no sleeps and no races. Default nil
    /// keeps every existing suite byte-identical.
    var failReadsAfter: Int?
    private var _readCount = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return _readCount }
    func seed(reference: String, value: String) {
        lock.lock(); store[reference] = Data(value.utf8); lock.unlock()
    }
    func read(reference: String) async throws -> Data? {
        try withScopedLock(lock) {
            _readCount += 1
            if failReads { throw FloeError.internalError("fixture read failure") }
            if let limit = failReadsAfter, _readCount > limit {
                throw FloeError.internalError("fixture read failure (past read \(limit))")
            }
            return store[reference]
        }
    }
    func write(reference: String, value: Data) async throws {
        withScopedLock(lock) { store[reference] = value }
    }
    func delete(reference: String) async throws {
        withScopedLock(lock) { store[reference] = nil }
    }
}

final class TestNormalizer: RunCredentialArgumentNormalizing, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    func normalized(call: ToolCall, runOwner: RunCredentialOwner) async throws -> ToolCall {
        withScopedLock(lock) { seen.append(call.id) }
        return call
    }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return seen.count }
}

final class TestStaging: RunStagedAttachmentAuthority, @unchecked Sendable {
    var refuse = false
    var imageHandles: Set<String> = []
    var unknownHandles: Set<String> = []
    var resolved: [String] = []
    // RUN-S4 repair: lease bookkeeping the repair tests observe.
    private let leaseLock = NSLock()
    private var reservations: [String: UUID] = [:]
    private var _commits: [(handle: String, conversationID: UUID, messageID: UUID)] = []
    private var _releases: [String] = []
    private var _discarded: [String] = []
    /// Leases the authority actually handed out (handle → lease).
    private var _issued: [String: RunAttachmentLease] = [:]
    /// Handles whose lease was COMMITTED (the real authority refuses a
    /// second reservation for them: typed double-launch refusal).
    private var _consumed: Set<String> = []

    var commits: [(handle: String, conversationID: UUID, messageID: UUID)] {
        leaseLock.lock(); defer { leaseLock.unlock() }; return _commits
    }
    var releases: [String] {
        leaseLock.lock(); defer { leaseLock.unlock() }; return _releases
    }
    /// Handles whose staged bytes were DISCARDED — must stay empty: staged
    /// bytes are preserved on release and never discarded after commit.
    var discarded: [String] {
        leaseLock.lock(); defer { leaseLock.unlock() }; return _discarded
    }
    var reservedHandles: [String] {
        leaseLock.lock(); defer { leaseLock.unlock() }
        return Array(reservations.keys)
    }

    func resolve(handle: String, conversationID: UUID?, epoch: UInt64) async throws
        -> AttachmentRef {
        if refuse { throw RunStagingError.unbound }
        if unknownHandles.contains(handle) { throw RunStagingError.handleUnknown }
        lock()
        resolved.append(handle)
        unlock()
        return makeRef(handle: handle, conversationID: conversationID)
    }

    func reserve(handle: String, conversationID: UUID?, runID: UUID,
                 epoch: UInt64) async throws -> RunAttachmentLease {
        if refuse { throw RunStagingError.unbound }
        if unknownHandles.contains(handle) { throw RunStagingError.handleUnknown }
        let lease = try withScopedLock(leaseLock) { () throws -> RunAttachmentLease in
            if _consumed.contains(handle) {
                throw RunStagingError.handleAlreadyReserved
            }
            if let owner = reservations[handle], owner != runID {
                throw RunStagingError.handleAlreadyReserved
            }
            reservations[handle] = runID
            let lease = RunAttachmentLease(
                leaseID: UUID(), handle: handle, runID: runID,
                ref: makeRef(handle: handle, conversationID: conversationID))
            _issued[handle] = lease
            return lease
        }
        lock()
        resolved.append(handle)
        unlock()
        return lease
    }

    func commitAcknowledged(_ lease: RunAttachmentLease, conversationID: UUID,
                            messageID: UUID, epoch: UInt64) async {
        withScopedLock(leaseLock) {
            _commits.append((lease.handle, conversationID, messageID))
            reservations.removeValue(forKey: lease.handle)
            _consumed.insert(lease.handle)
        }
    }

    func releaseReservation(_ lease: RunAttachmentLease, epoch: UInt64) async {
        withScopedLock(leaseLock) {
            _releases.append(lease.handle)
            reservations.removeValue(forKey: lease.handle)
            // Staged bytes are PRESERVED on release — the user keeps their
            // staged file. Nothing here discards bytes.
        }
    }

    private func makeRef(handle: String, conversationID: UUID?) -> AttachmentRef {
        let kind: AttachmentRef.Kind = imageHandles.contains(handle) ? .image : .document
        return AttachmentRef(
            id: UUID(),
            conversationID: conversationID,
            messageID: nil,
            kind: kind,
            displayName: "fixture-\(handle.prefix(6))",
            uti: kind == .image ? "public.png" : "public.data",
            byteCount: 8,
            sha256: String(repeating: "0", count: 64),
            storage: .applicationSupport,
            urlBookmark: nil,
            relativePath: "attachments/\(handle)",
            createdAt: Date())
    }

    private let stateLock = NSLock()
    private func lock() { stateLock.lock() }
    private func unlock() { stateLock.unlock() }
}

/// RUN-S4 repair: trusted bounded image-loader double. Produces the
/// ORIGINAL ConversationImagePart from the validated staged lease — no
/// path authority, no wire binary.
final class TestImageLoader: RunStagedImageLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(handle: String, maxBytes: Int)] = []
    var fail = false
    var payloadBase64 = "aW1hZ2UtcGF5bG9hZA=="
    var requests: [(handle: String, maxBytes: Int)] {
        lock.lock(); defer { lock.unlock() }; return _requests
    }
    func imagePart(for lease: RunAttachmentLease,
                   maxBytes: Int) async throws -> ConversationImagePart {
        withScopedLock(lock) { _requests.append((lease.handle, maxBytes)) }
        if fail { throw FloeError.validationFailed("fixture image load failure") }
        return ConversationImagePart(mimeType: "image/png", base64: payloadBase64)
    }
}

/// RUN-S2 repair: a launch store that fails atomically, proving the staged
/// leases are released (bytes preserved) when the ORIGINAL prepare throws.
struct FailingLaunchStore: RunLaunchStore, Sendable {
    func prepare(_ request: RunLaunchRequest) async throws -> PreparedRun {
        throw FloeError.storageCorrupted("fixture prepare failure")
    }
}

final class TestToolCancellation: RunOwnedToolCancellation, @unchecked Sendable {
    var bound = true
    private let lock = NSLock()
    private var _cancelled: [(UUID, String?)] = []
    var cancelled: [(UUID, String?)] { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func cancelOwnedTool(runID: UUID, callID: String?, epoch: UInt64) async -> Bool {
        guard bound else { return false }
        withScopedLock(lock) { _cancelled.append((runID, callID)) }
        return true
    }
}

final class TestEnvironmentProof: RunEnvironmentOwnershipProving, @unchecked Sendable {
    var knownEnvironment: String?
    var knownJob: (id: String, run: UUID)?
    /// Test-only: accept any requested job id (the run id is minted inside
    /// the launch, so a job test cannot know it beforehand).
    var acceptAnyJob = false
    func proveEnvironment(_ id: String, conversationID: UUID, epoch: UInt64) async -> Bool {
        knownEnvironment == id
    }
    func proveJob(_ id: String, runID: UUID, epoch: UInt64) async -> Bool {
        acceptAnyJob || (knownJob?.id == id && knownJob?.run == runID)
    }
}

final class TestIntelligenceFeed: RunIntelligencePostCommitFeeding, @unchecked Sendable {
    private let lock = NSLock()
    private var commits: [(RunIntelligenceEvent, String)] = []
    private var terminals: [(RunIntelligenceCompletionEvent, String)] = []
    /// Optional stall so the delete-drain test can observe a REAL in-flight
    /// P8 lease (Main's acquire-then-deliver correction). `stallDeliver`
    /// gates BOTH hooks; `stallTerminalDeliver` gates only the terminal
    /// hook (RUN-S3 repair tests sequence the two feeds independently).
    var stallDeliver: RunGateBox?
    var stallTerminalDeliver: RunGateBox?
    func ordinaryUserMessageCommitted(_ event: RunIntelligenceEvent,
                                      feedToken: String) async {
        if let stall = stallDeliver { await stall.waitThroughCancellation() }
        withScopedLock(lock) { commits.append((event, feedToken)) }
    }
    func ordinaryRunCompleted(_ event: RunIntelligenceCompletionEvent,
                              feedToken: String) async {
        if let stall = stallDeliver { await stall.waitThroughCancellation() }
        if let stall = stallTerminalDeliver { await stall.waitThroughCancellation() }
        withScopedLock(lock) { terminals.append((event, feedToken)) }
    }
    var counts: (user: Int, terminal: Int) {
        lock.lock(); defer { lock.unlock() }; return (commits.count, terminals.count)
    }
    var userEvents: [RunIntelligenceEvent] {
        lock.lock(); defer { lock.unlock() }; return commits.map { $0.0 }
    }
    var terminalEvents: [RunIntelligenceCompletionEvent] {
        lock.lock(); defer { lock.unlock() }; return terminals.map { $0.0 }
    }
    var tokens: [String] {
        lock.lock(); defer { lock.unlock() }
        return commits.map { $0.1 } + terminals.map { $0.1 }
    }
}

struct TestRevisionReader: RunConversationRevisionReading {
    let database: DatabaseManager
    func digest(conversationID: UUID) async throws -> String? {
        try await database.reader { db in
            try ConversationRowRevision.digest(db: db, conversationID: conversationID)
        }
    }
    func ordinaryExists(conversationID: UUID) async throws -> Bool {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT purpose FROM conversations WHERE id = ?",
                arguments: [conversationID.uuidString]) else { return false }
            let purpose: String = row["purpose"]
            return purpose == "ordinary"
        }
    }
}

// MARK: - Fixture harness (REAL stores on a temporary directory)

/// `XCTUnwrap` is an autoclosure and cannot host `await`; this wrapper takes
/// an already-evaluated optional so inline dictionary/argument positions stay
/// valid (`try unwrapAsync(await value())`). Assertion text is preserved.
func unwrapAsync<T>(_ value: T?, file: StaticString = #filePath,
                    line: UInt = #line) throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

/// Scoped `NSLock` seam for async test doubles: `NSLock.lock()` is
/// `noasync` under Swift 6, so async code must enter the critical section
/// through this synchronous closure (never hold the lock across an await).
@inline(__always)
func withScopedLock<T>(_ lock: NSLock, _ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
}

/// The SAME owned store cluster read from the accepted generation (one
/// business DatabaseManager; the fixture never opens a second one).
struct OwnedStoreSnapshot {
    let database: DatabaseManager
    let conversations: SQLiteConversationStore
    let runs: SQLiteRunStore
    let inputs: SQLiteRunningInputStore
    let children: SQLiteChildRunStore
    let launches: SQLiteRunLaunchStore
    let models: ModelConfigurationStore
    let workspace: SQLiteWorkspaceStore
    let checkpoints: FileCheckpointStore
}

/// Nonblocking completion observation for one owned drain Task: set ONLY
/// when the drain really returns, inspected while the real lease is still
/// held. `await task.result` as a pending probe would self-join and is never
/// used for pending checks.
final class DrainObservationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var observed: ConversationQuiescenceReport?
    func markFinished(_ report: ConversationQuiescenceReport?) {
        lock.lock(); finished = true; observed = report; lock.unlock()
    }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var report: ConversationQuiescenceReport? {
        lock.lock(); defer { lock.unlock() }; return observed
    }
}

final class RunDomainFixture: @unchecked Sendable {
    let root: URL
    let database: DatabaseManager
    let conversationStore: SQLiteConversationStore
    let runStore: SQLiteRunStore
    let inputStore: SQLiteRunningInputStore
    let childStore: SQLiteChildRunStore
    let launchStore: SQLiteRunLaunchStore
    let modelStore: ModelConfigurationStore
    let workspaceStore: SQLiteWorkspaceStore
    let intelligence: SQLiteIntelligenceStore
    let checkpoints: FileCheckpointStore
    let effects: FacadeEffectPump
    let events: FacadeEventPump
    let content: FacadeContentReader
    let registry = ToolRunnerRegistry()
    let gateway = TestSecretGateway()
    let normalizer = TestNormalizer()
    let staging = TestStaging()
    let imageLoader = TestImageLoader()
    let cancellation = TestToolCancellation()
    let environmentProof = TestEnvironmentProof()
    let feed = TestIntelligenceFeed()
    let adapter: ScriptedRunAdapter
    let providerID: UUID
    let modelID: UUID
    let modelProfile: ModelProfile
    let providerProfile: ProviderProfile
    /// Domains created through the fixture, retired at teardown so a failed
    /// test cannot leave a live producer holding owned work.
    private let domainsLock = NSLock()
    private var createdDomains: [FacadeRunDomain] = []

    /// ACTUAL accepted bootstrap epoch (strictly monotonic per fixture).
    let epoch: UInt64
    /// Exact owner token for the fixture's REAL bootstrap generation.
    let bootstrapToken: String

    /// Registers the ORIGINAL gateway naming singleton with the fixture
    /// gateway. Test suites call `SecretGatewayRegistry.shared.unregister()`
    /// in tearDown so cross-suite leakage is impossible.
    /// Serializes generation transitions across tests: XCTest teardown is
    /// asynchronous, so every `make` first retires the PREVIOUS fixture
    /// through the REAL shutdown control.
    nonisolated(unsafe) private static var previousFixture: RunDomainFixture?
    private static let fixtureLock = NSLock()

    static func make(adapter: ScriptedRunAdapter? = nil) async throws -> RunDomainFixture {
        let previous = fixtureLock.withLock { () -> RunDomainFixture? in
            let value = previousFixture
            previousFixture = nil
            return value
        }
        if let previous { await previous.tearDown() }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("floe-rb4-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The accepted bootstrap admits ONLY a strictly newer epoch.
        let epoch = DispatchTime.now().uptimeNanoseconds
        let token = String(format: "%016llx", UInt64.random(in: 1...UInt64.max))
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root.standardizedFileURL.path,
            ownerToken: token, epoch: epoch) else {
            throw NSError(domain: "fixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "bootstrap start rejected"])
        }
        var waited = 0
        while AndroidRuntimeBootstrap.currentPumps()?.storeReady != true, waited < 30_000 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 10
        }
        guard AndroidRuntimeBootstrap.currentPumps()?.storeReady == true,
              let generation = AndroidRuntimeBootstrap.currentGenerationForTesting(),
              generation.epoch == epoch else {
            throw NSError(domain: "fixture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "bootstrap store never ready: "
                                            + AndroidRuntimeBootstrap.statusSnapshotJSON()])
        }
        guard let database = await generation.owner.ownedDatabaseForTesting(),
              let conversations = await generation.owner.conversationStore,
              let runs = await generation.owner.runStore,
              let inputs = await generation.owner.runningInputStore,
              let children = await generation.owner.childRunStore,
              let launches = await generation.owner.runLaunchStore,
              let models = await generation.owner.modelConfigurationStore,
              let workspace = await generation.owner.workspaceStore,
              let checkpointStore = await generation.owner.checkpointStore else {
            throw NSError(domain: "fixture", code: 4,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "owned store cluster incomplete"])
        }
        let fixture = RunDomainFixture(
            root: root,
            stores: OwnedStoreSnapshot(database: database,
                                       conversations: conversations,
                                       runs: runs, inputs: inputs,
                                       children: children, launches: launches,
                                       models: models, workspace: workspace,
                                       checkpoints: checkpointStore),
            epoch: epoch, bootstrapToken: token,
            adapter: adapter ?? ScriptedRunAdapter(defaultScript: .init(events: [
                .textDelta(.init(text: "fixture answer")),
                .completed(.init(stopReason: .endTurn)),
            ])))
        try await fixture.bootstrapConfiguration()
        fixtureLock.withLock { previousFixture = fixture }
        return fixture
    }

    private init(root: URL, stores: OwnedStoreSnapshot, epoch: UInt64,
                 bootstrapToken: String, adapter: ScriptedRunAdapter) {
        self.root = root
        self.database = stores.database
        self.epoch = epoch
        self.bootstrapToken = bootstrapToken
        conversationStore = stores.conversations
        runStore = stores.runs
        inputStore = stores.inputs
        childStore = stores.children
        launchStore = stores.launches
        modelStore = stores.models
        workspaceStore = stores.workspace
        intelligence = SQLiteIntelligenceStore(database: stores.database)
        checkpoints = stores.checkpoints
        effects = FacadeEffectPump(generation: epoch)
        events = FacadeEventPump()
        content = FacadeContentReader(generation: epoch)
        self.adapter = adapter
        providerID = UUID()
        modelID = UUID()
        var provider = ProviderProfile(
            kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://fixtures.invalid/v1")!)
        provider.id = providerID
        provider.secretRef = SecretReference(keychainAccount: "fixture-provider",
                                             synchronizable: false)
        provider.displayName = "Fixture"
        providerProfile = provider
        var model = ModelProfile(
            providerID: providerID, remoteModelID: "fixture-model",
            displayName: "Fixture Model",
            limits: ModelLimits(contextTokens: 16_000, maxOutputTokens: 2_048),
            capabilities: [.text, .tools, .vision])
        model.id = modelID
        modelProfile = model
        FixtureTools.registerAll(into: registry)
    }

    private func bootstrapConfiguration() async throws {
        try await modelStore.saveProvider(providerProfile)
        try await modelStore.saveModel(modelProfile)
        var preferences = try await modelStore.preferences()
        preferences.defaultAgentModelID = modelID
        try await modelStore.savePreferences(preferences)
        SecretGatewayRegistry.shared.register(gateway)
        // Seed under the SAME canonical opaque reference the resolver reads.
        if let ref = providerProfile.secretRef {
            gateway.seed(
                reference: SecretGatewayNaming.opaqueReference(for: ref),
                value: "sk-fixture-not-a-real-key")
        }
    }

    var fixtureCorpus: Data {
        Data(#"{"patterns":[{"id":"fixture-rm-rf","regex":"rm\\s+-rf\\s+/","reason":"fixture"}]}"#.utf8)
    }

    func components(transportQualified: Bool = true,
                    corpus: Data? = nil,
                    normalizer: (any RunCredentialArgumentNormalizing)? = nil,
                    staging: (any RunStagedAttachmentAuthority)? = nil,
                    stagedImages: (any RunStagedImageLoading)? = nil,
                    cancellation: (any RunOwnedToolCancellation)? = nil,
                    environmentProof: (any RunEnvironmentOwnershipProving)? = nil,
                    feed: (any RunIntelligencePostCommitFeeding)? = nil,
                    contextEpoch: UInt64? = nil) -> RunDomainComponents {
        RunDomainComponents(
            context: RunIngressContext(
                epoch: contextEpoch ?? epoch,
                catastrophicCorpusBytes: corpus ?? fixtureCorpus,
                isTransportQualified: transportQualified),
            durable: RunPersistenceBundle(
                identity: .ordinary,
                conversations: conversationStore,
                runs: runStore,
                runningInputs: inputStore,
                launches: launchStore,
                childRuns: childStore,
                intelligence: intelligence),
            checkpoints: checkpoints,
            modelStore: modelStore,
            workspaceStore: workspaceStore,
            effects: effects,
            events: events,
            content: content,
            conversationRevisions: TestRevisionReader(database: database),
            credentialNormalizer: normalizer ?? self.normalizer,
            stagedAttachments: staging ?? self.staging,
            // RUN-S4 repair: the image loader stays UNBOUND by default —
            // image handles refuse typed until a test binds the qualified
            // loader (the original refusal tests keep their meaning).
            stagedImages: stagedImages,
            toolCancellation: cancellation ?? self.cancellation,
            environmentProof: environmentProof ?? self.environmentProof,
            intelligenceFeed: feed ?? self.feed,
            personalizationProvider: nil,
            adapterFactoryOverride: { [adapter] _ in adapter },
            registry: registry)
    }

    /// ONE owned factory/register for every domain the fixture creates
    /// (makeDomain/makeImageDomain/custom P8 domains): teardown retires them
    /// ALL through the REAL generation retirement, so no live producer can
    /// hold owned work that blocks the next fixture's bootstrap.
    func trackDomain(_ domain: FacadeRunDomain) -> FacadeRunDomain {
        withScopedLock(domainsLock) { createdDomains.append(domain) }
        return domain
    }

    func makeCustomDomain(_ components: RunDomainComponents) -> FacadeRunDomain {
        trackDomain(FacadeRunDomain(components: components))
    }

    func makeDomain(transportQualified: Bool = true,
                    corpus: Data? = nil) -> FacadeRunDomain {
        makeCustomDomain(components(
            transportQualified: transportQualified, corpus: corpus))
    }

    /// RUN-S4 repair: a domain with the trusted image loader explicitly
    /// bound (default domains leave it unbound — image handles then refuse
    /// typed before any IO).
    func makeImageDomain() -> FacadeRunDomain {
        makeCustomDomain(components(stagedImages: imageLoader))
    }

    /// A domain whose catastrophic gate corpus is EXPLICITLY absent (the
    /// honest needsCorpus refusal path; `components(corpus: nil)` would
    /// substitute the fixture corpus).
    func makeAbsentCorpusDomain() -> FacadeRunDomain {
        let base = components(transportQualified: true)
        return makeCustomDomain(RunDomainComponents(
            context: RunIngressContext(epoch: epoch,
                                       catastrophicCorpusBytes: nil,
                                       isTransportQualified: true),
            durable: base.durable,
            checkpoints: base.checkpoints,
            modelStore: base.modelStore,
            workspaceStore: base.workspaceStore,
            effects: base.effects,
            events: base.events,
            content: base.content,
            conversationRevisions: base.conversationRevisions,
            credentialNormalizer: base.credentialNormalizer,
            stagedAttachments: base.stagedAttachments,
            stagedImages: base.stagedImages,
            toolCancellation: base.toolCancellation,
            environmentProof: base.environmentProof,
            intelligenceFeed: base.intelligenceFeed,
            personalizationProvider: base.personalizationProvider,
            adapterFactoryOverride: base.adapterFactoryOverride,
            registry: base.registry))
    }

    /// Creates a REAL ordinary conversation through the ORIGINAL
    /// launch-store atomic path (the same machinery production uses) and
    /// returns the committed conversation id.
    func makeOrdinaryConversation(goal: String = "seed") async throws -> UUID {
        let prepared = try await launchStore.prepare(RunLaunchRequest(
            goal: goal,
            conversationMode: "chat",
            initialPolicy: DraftTaskPolicy(approvalMode: .ask),
            providerID: providerID,
            modelID: modelID))
        // Close the seeding run so it never looks live to drain tests.
        try await runStore.updateRunState(id: prepared.run.id, state: "completed",
                                          endedAt: Date())
        return prepared.conversation.id
    }

    /// Reads the CURRENT opaque revision (floe.conversation-row.v1) for CAS
    /// envelopes.
    func revision(conversationID: UUID) async throws -> String {
        try await TestRevisionReader(database: database)
            .digest(conversationID: conversationID) ?? ""
    }

    func runState(_ runID: UUID) async throws -> String? {
        try await runStore.run(id: runID)?.state
    }

    func durableEvents(_ runID: UUID) async throws -> [RunEventRecord] {
        try await runStore.events(runID: runID, afterSequence: 0, limit: 400)
    }

    func hasTerminalEvent(_ runID: UUID) async throws -> Bool {
        (try await durableEvents(runID)).contains { $0.kind == .terminal }
    }

    func nonTerminal(_ runID: UUID) async throws -> Bool {
        guard let state = try await runState(runID) else { return false }
        return FacadeRunDomain.activeRunStates.contains(state)
    }

    /// Envelope object for the launch commands (payload built by callers).
    func launchEnvelope(conversationID: UUID, payload: [String: Any],
                        revisionVersion: String, correlation: String) -> RunCommandEnvelope {
        RunCommandEnvelope(object: [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.launch.rawValue,
            "command": "run.start",
            "stateful": true,
            "correlationID": correlation,
            "owner": ["taskID": conversationID.uuidString],
            "revision": [
                "resourceID": ConversationRowRevision.resourceID(conversationID: conversationID),
                "version": revisionVersion,
            ],
            "payload": payload,
        ])
    }

    func executionEnvelope(command: String, conversationID: UUID, runID: UUID,
                           payload: [String: Any]?, correlation: String,
                           revision: [String: String]? = nil) -> RunCommandEnvelope {
        var object: [String: Any] = [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.taskExecution.rawValue,
            "command": command,
            "stateful": true,
            "correlationID": correlation,
            "owner": ["taskID": conversationID.uuidString, "runID": runID.uuidString],
        ]
        if let revision { object["revision"] = revision }
        if let payload { object["payload"] = payload }
        return RunCommandEnvelope(object: object)
    }

    /// Minimal-48KiB-safe valid DraftTaskPolicy payload for launches.
    func startPayload(goal: String, mode: String = "chat") -> [String: Any] {
        [
            "goal": goal,
            "mode": mode,
            "providerID": providerID.uuidString,
            "modelID": modelID.uuidString,
            "approvalMode": "ask",
        ]
    }

    /// REAL fixture retirement (RB6 protocol): `shutdown` only ENQUEUES the
    /// internal control, so wait for ITS effect-receipt terminal AND the
    /// authoritative `ownedStorePhase == closed` / generation-gone facts
    /// before closing or removing anything. `currentPumps() == nil` is NOT a
    /// retirement proof (it returns nil for a retiring generation).
    func tearDown() async {
        SecretGatewayRegistry.shared.unregister()
        // Retire every fixture-owned domain through the REAL generation
        // retirement (cancels live producers) and wait for the registry to
        // reach ZERO before the bootstrap shutdown/drain. This prevents a
        // failed test from leaving owned work that blocks the next fixture.
        let domains = withScopedLock(domainsLock) { createdDomains }
        for domain in domains {
            await domain.beginGenerationRetirement()
        }
        let drainDeadline = Date().addingTimeInterval(25)
        while RuntimeOwnedWorkRegistry.shared.count(for: epoch) > 0,
              Date() < drainDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        var receipt: String?
        switch AndroidRuntimeBootstrap.shutdown(expectedEpoch: epoch,
                                                ownerToken: bootstrapToken) {
        case .accepted(let value), .idempotent(let value):
            receipt = value
        case .rejected:
            break
        }
        var storeClosed = false
        var generationGone = false
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let data = AndroidRuntimeBootstrap.statusSnapshotJSON().data(using: .utf8),
               let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                storeClosed = (status["ownedStorePhase"] as? String) == "closed"
                let phase = status["phase"] as? String
                generationGone = status["generation"] == nil
                    && (phase == "stopped" || phase == "failed")
            }
            if storeClosed && generationGone { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = receipt
        let residual = RuntimeOwnedWorkRegistry.shared.countsByKind(for: epoch)
        guard storeClosed, generationGone else {
            // A fixture whose generation cannot really retire leaves leaked
            // ownership for the NEXT test: fail loudly instead of silently
            // "passing" an isolated run.
            XCTFail("fixture generation did not really retire: storeClosed=\(storeClosed) "
                        + "generationGone=\(generationGone) residualOwned=\(residual) "
                        + "status=\(AndroidRuntimeBootstrap.statusSnapshotJSON())")
            return
        }
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - RB5 ephemeral session bundle (RUN-S2 repair fixture)

/// ONE coherent ephemeral store set for a hosted temporary session: the
/// SAME `EphemeralRunStore` instance is shared by the bundle's `runs` slot
/// and the launcher's store (Main correction: two parallel run-store
/// instances proved nothing about a working temporary path). The exact
/// shape RB5's `RuntimeFacadeTemporaryRunAdapter` assembles per session.
struct EphemeralRunBundleSet {
    let conversations: EphemeralConversationStore
    let runs: EphemeralRunStore
    let runningInputs: EphemeralRunningInputStore
    let launches: EphemeralRunLaunchStore
    let bundle: RunPersistenceBundle

    init(hostedConversationID: UUID) {
        let record = ConversationRecord(
            id: hostedConversationID, title: "tmp", createdAt: Date(),
            updatedAt: Date(), titleOrigin: .autoPending, purpose: .temporary)
        let conversationStore = EphemeralConversationStore(record: record)
        let runStore = EphemeralRunStore(hostedConversationID: hostedConversationID)
        let inputStore = EphemeralRunningInputStore(hostedConversationID: hostedConversationID)
        let launchStore = EphemeralRunLaunchStore(
            hostedConversationID: hostedConversationID,
            conversationStore: conversationStore,
            runStore: runStore)
        self.conversations = conversationStore
        self.runs = runStore
        self.runningInputs = inputStore
        self.launches = launchStore
        self.bundle = RunPersistenceBundle(
            identity: .temporary,
            conversations: conversationStore,
            runs: runStore,
            runningInputs: inputStore,
            launches: launchStore,
            childRuns: nil,
            intelligence: nil)
    }
}

extension RunDomainFixture {
    /// Durable snapshot helpers for the isolation assertions: counts over
    /// the REAL file-backed schema-46 tables plus the checkpoint directory.
    func durableConversationCount() async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? 0
        }
    }
    func durableRunCount() async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM runs") ?? 0
        }
    }
    func durableMessageCount() async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
    }
    var checkpointFileCount: Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("checkpoints"),
            includingPropertiesForKeys: nil)) ?? []
        return files.count
    }
}

extension XCTestCase {
    /// Bounded explicit-poll helper. Used ONLY to wait for real settled
    /// evidence; tests assert the OBSERVED value, never a timeout
    /// assumption.
    // The condition is awaited IN THIS task (never detached), so it does
    // not need @Sendable; requiring it forced XCTestCase/fixture captures
    // that are perfectly safe here (test-only helper).
    func pollFor(timeoutSeconds: Double = 6,
                 _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    /// Waits for the durable terminal of one facade-owned run (the track
    /// task retires ownership at the real terminal; this observes that).
    func waitDurableTerminal(fixture: RunDomainFixture, runID: UUID,
                             timeoutSeconds: Double = 8) async -> String? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let state = try? await fixture.runState(runID),
               !FacadeRunDomain.activeRunStates.contains(state) {
                return state
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return try? await fixture.runState(runID)
    }

    /// Effect stream walk: returns all effects appended so far for a
    /// receipt through the reviewed pump (the same poll path the wire uses).
    func pollEffects(_ pump: FacadeEffectPump, receipt: String)
        -> [RuntimeEffectItem] {
        var collected: [RuntimeEffectItem] = []
        var sequence = 0
        for _ in 0..<10 {
            switch pump.poll(receipt: receipt, afterSequence: sequence) {
            case .page(let effects, let next, _, _):
                collected.append(contentsOf: effects)
                if next == sequence { return collected }
                sequence = next
            case .notFound, .expired:
                return collected
            }
        }
        return collected
    }
}

/// JSONValue construction shortcuts for payload dictionaries (kept local;
/// the wire payload grammar itself is owned by the frozen BridgeV3).
enum FixtureJSON {
    static func object(_ pairs: [String: Any]) -> SettingsDomainV1.JSONValue {
        var out: [String: SettingsDomainV1.JSONValue] = [:]
        for (key, rawValue) in pairs {
            out[key] = value(for: rawValue)
        }
        return .object(out)
    }

    private static func value(for raw: Any) -> SettingsDomainV1.JSONValue {
        switch raw {
        case let text as String: return .string(text)
        case let int as Int: return .integer(Int64(int))
        case let int64 as Int64: return .integer(int64)
        case let bool as Bool: return .boolean(bool)
        case is NSNull: return .null
        case let array as [Any]: return .array(array.map { value(for: $0) })
        case let dict as [String: Any]: return object(dict)
        default: return .null
        }
    }

    static func dictionary(_ value: SettingsDomainV1.JSONValue?) -> [String: Any]? {
        guard let value, case .object(let object) = value else { return nil }
        var out: [String: Any] = [:]
        for (key, item) in object {
            switch item {
            case .string(let text): out[key] = text
            case .integer(let number): out[key] = number
            case .fractional(let number): out[key] = number
            case .boolean(let flag): out[key] = flag
            case .null: out[key] = NSNull()
            case .array(let items): out[key] = items.map { plain($0) }
            case .object: out[key] = dictionary(item)
            }
        }
        return out
    }

    private static func plain(_ value: SettingsDomainV1.JSONValue) -> Any {
        switch value {
        case .string(let text): return text
        case .integer(let number): return number
        case .fractional(let number): return number
        case .boolean(let flag): return flag
        case .null: return NSNull()
        case .array(let items): return items.map { plain($0) }
        case .object(let object): return object.mapValues { plain($0) }
        }
    }
}
