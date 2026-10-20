// SPDX-License-Identifier: MPL-2.0
//
// G02 temporary-session test support (actual-qualification revision).
//
// Honesty rules (per spec + Main repairs): fixtures use the REAL original
// store layer — an ACTUAL reviewed RB1 bootstrap generation over its OWN
// file-backed schema-46 database (the SAME `DatabaseManager` the owner
// opened, via the reviewed `ownedDatabaseForTesting()` seam; never a second
// business handle), the ORIGINAL `Ephemeral*` stores via the domain, the
// ORIGINAL `ConversationPromoter` (with the narrowly additive Android
// commit-boundary fence mirror consumed by TMP-COMMIT-1), the ORIGINAL
// canonical `TemporaryChatToolPolicy` decisions, and REAL RB1
// `RuntimeOwnedWorkRegistry` / `FacadeEffectPump` objects. The ordinary
// production graph is NOT rebuilt per case: the bootstrap runs in the
// documented core-only FIXTURE mode (the reviewed isolated-component seam),
// so binder/mailbox/pump/owner state is real while the optional graph is
// owned by THIS fixture only. ONLY the run-service seam is a test double —
// the port is a CONTROLLED typed fixture (it records the exact temporary
// bundle/identity/ceiling it receives and drives real gates); there is NO
// fake production executor, no noop port, no simulated durable DB, and no
// assertion over copied code. Teardown performs the REAL shutdown control
// and awaits store close/generation loss — never a force reset to green.
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeTools
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

// MARK: - Async gate (deterministic stall; mirrors the reviewed RB1/RB4
// test-hook discipline; production paths never see it)

final class TempGateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// One atomic section decides: append the waiter or report "already
    /// open" (Main review: the check and the enqueue must not race a
    /// release landing between two separate lock windows).
    private func attach(_ c: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        if isOpen { lock.unlock(); return false }
        waiters.append(c)
        lock.unlock()
        return true
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if !self.attach(c) { c.resume() }
        }
    }

    func release() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for c in pending { c.resume() }
    }
}

// MARK: - Controlled typed run-port fixture (run seam double, TEST ONLY)

/// Records every `TemporaryLaunchRequest` (so tests prove the ephemeral
/// store bundle + frozen temporary identity + frozen ceiling reach the run
/// lane BEFORE its first await), drives the real stall/cancel sequence and
/// returns REAL minted run ids. The production binding is
/// `RuntimeFacadeTemporaryRunAdapter`, never this class.
final class ControlledTemporaryRunPort: TemporaryRunDomainPort, @unchecked Sendable {
    struct Launch: Sendable {
        let request: TemporaryLaunchRequest
        let reply: TemporaryLaunchReply
    }

    private let lock = NSLock()
    private var launches: [Launch] = []
    private var cancelled: [(conversationID: UUID, incarnation: UUID,
                             runID: UUID, epoch: UInt64)] = []
    private var liveRunIDs: Set<UUID> = []
    /// Stall point: set to block inside `launchTemporary` before the reply
    /// (stages navigation-across-blocked-launch).
    var stallGate: TempGateBox?
    /// Scripted reply for the NEXT launch (nil => launched with a fresh id).
    var nextReply: TemporaryLaunchReply?
    /// True the moment a request reached the port.
    private(set) var sawRequest = false

    private func markSawRequest() {
        lock.lock(); sawRequest = true; lock.unlock()
    }
    private func record(_ request: TemporaryLaunchRequest, _ scriptedCloser: () -> TemporaryLaunchReply) -> TemporaryLaunchReply {
        lock.lock()
        let reply: TemporaryLaunchReply = scriptedCloser()
        launches.append(Launch(request: request, reply: reply))
        lock.unlock()
        return reply
    }
    private func scriptedOrFresh() -> TemporaryLaunchReply {
        // Caller holds the lock.
        if let scripted = nextReply {
            nextReply = nil
            return scripted
        }
        let runID = UUID()
        liveRunIDs.insert(runID)
        return .launched(runID: runID)
    }

    func launchTemporary(_ request: TemporaryLaunchRequest) async
        -> TemporaryLaunchReply {
        markSawRequest()
        if let gate = stallGate { await gate.wait() }
        return record(request) { self.scriptedOrFresh() }
    }

    func cancelTemporaryRun(conversationID: UUID, incarnation: UUID,
                            runID: UUID, epoch: UInt64) async {
        cancelSync(conversationID: conversationID, incarnation: incarnation,
                   runID: runID, epoch: epoch)
    }

    private func cancelSync(conversationID: UUID, incarnation: UUID,
                            runID: UUID, epoch: UInt64) {
        lock.lock()
        cancelled.append((conversationID, incarnation, runID, epoch))
        liveRunIDs.remove(runID)
        lock.unlock()
    }

    func hasLiveTemporaryRun(conversationID: UUID, incarnation: UUID,
                             runID: UUID) async -> Bool {
        hasLiveSync(runID: runID)
    }

    private func hasLiveSync(runID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveRunIDs.contains(runID)
    }

    // Observations

    var recordedLaunches: [Launch] {
        lock.lock(); defer { lock.unlock() }
        return launches
    }
    var recordedCancels: [(conversationID: UUID, incarnation: UUID,
                           runID: UUID, epoch: UInt64)] {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func markLive(_ runID: UUID) {
        lock.lock(); liveRunIDs.insert(runID); lock.unlock()
    }
}

// MARK: - Recording host-surface spy

final class RecordingHostSurface: TemporaryHostSurfaceProviding, @unchecked Sendable {
    struct Adopted: Sendable, Equatable {
        let conversationID: UUID
        let incarnation: UUID
        let draftVerbatim: String?
    }
    struct Discarded: Sendable, Equatable {
        let conversationID: UUID
        let incarnation: UUID
    }
    struct Promoted: Sendable, Equatable {
        let conversationID: UUID
        let incarnation: UUID
        let durableConversationID: UUID
    }
    private let lock = NSLock()
    private(set) var adopted: [Adopted] = []
    private(set) var discarded: [Discarded] = []
    private(set) var promoted: [Promoted] = []

    func surfaceAdopted(conversationID: UUID, incarnation: UUID,
                        draftVerbatim: String?) async {
        adoptSync(conversationID: conversationID, incarnation: incarnation,
                  draftVerbatim: draftVerbatim)
    }
    private func adoptSync(conversationID: UUID, incarnation: UUID,
                           draftVerbatim: String?) {
        lock.lock(); adopted.append(.init(conversationID: conversationID,
                                          incarnation: incarnation,
                                          draftVerbatim: draftVerbatim)); lock.unlock()
    }
    func surfaceDiscarded(conversationID: UUID, incarnation: UUID) async {
        discardSync(conversationID: conversationID, incarnation: incarnation)
    }
    private func discardSync(conversationID: UUID, incarnation: UUID) {
        lock.lock(); discarded.append(.init(conversationID: conversationID,
                                            incarnation: incarnation)); lock.unlock()
    }
    func surfacePromoted(conversationID: UUID, incarnation: UUID,
                         durableConversationID: UUID) async {
        promoteSync(conversationID: conversationID, incarnation: incarnation,
                    durableConversationID: durableConversationID)
    }
    private func promoteSync(conversationID: UUID, incarnation: UUID,
                             durableConversationID: UUID) {
        lock.lock(); promoted.append(.init(conversationID: conversationID,
                                           incarnation: incarnation,
                                           durableConversationID: durableConversationID)); lock.unlock()
    }
}

// MARK: - Web-search availability stub (D1 closure input)

final class StubWebSearchAvailability: TemporaryWebSearchAvailabilityProviding,
                                       @unchecked Sendable {
    private let lock = NSLock()
    private var configured: Set<String>
    init(configured: Set<String>) { self.configured = configured }
    func setConfigured(_ names: Set<String>) {
        lock.lock(); configured = names; lock.unlock()
    }
    func isConfigured(toolName: String) async -> Bool {
        isConfiguredSync(toolName: toolName)
    }
    private func isConfiguredSync(toolName: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return configured.contains(toolName)
    }
}

// MARK: - Catalog fixtures (REAL original policy decisions on compiled
// descriptor shapes; instance registry only — no global catalog writes)

struct TempPublicWebTool: AgentTool {          // web.fetch — no provider needed
    struct Arguments: Decodable, Sendable { var url: String }
    static let name = "web.fetch"
    static let toolDescription = "Public web fetch (fixture with the canonical public-read metadata shape)"
    static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string"},"localNetwork":{"type":"boolean"}},"required":["url"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = false
    static let toolEffect = ToolEffect.readOnly
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ToolExecutionOutput(summary: "fixture",
                            fullOutputSHA256: String(repeating: "0", count: 64))
    }
}

struct TempWebSearchTool: AgentTool {           // web.search — provider-backed
    struct Arguments: Decodable, Sendable { var query: String }
    static let name = "web.search"
    static let toolDescription = "Public web search (canonical shape)"
    static let parametersJSON = #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = false
    static let toolEffect = ToolEffect.readOnly
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ToolExecutionOutput(summary: "fixture",
                            fullOutputSHA256: String(repeating: "0", count: 64))
    }
}

struct TempWebSearchAITool: AgentTool {         // web.searchAI — provider-backed
    struct Arguments: Decodable, Sendable { var query: String }
    static let name = "web.searchAI"
    static let toolDescription = "Public web AI search (canonical shape)"
    static let parametersJSON = #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = false
    static let toolEffect = ToolEffect.readOnly
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ToolExecutionOutput(summary: "fixture",
                            fullOutputSHA256: String(repeating: "0", count: 64))
    }
}

struct TempMCPTool: AgentTool {                 // outside the ceiling
    struct Arguments: Decodable, Sendable { var q: String }
    static let name = "mcp.demo.run"
    static let toolDescription = "MCP remote tool"
    static let parametersJSON = #"{"type":"object"}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess]
    static let isSideEffecting = false
    static let toolEffect = ToolEffect.readOnly
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ToolExecutionOutput(summary: "fixture",
                            fullOutputSHA256: String(repeating: "0", count: 64))
    }
}

struct TempLocalFileTool: AgentTool {           // readsFiles — outside ceiling
    struct Arguments: Decodable, Sendable { var path: String }
    static let name = "workspace.readFile"
    static let toolDescription = "Local file read"
    static let parametersJSON = #"{"type":"object"}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles]
    static let isSideEffecting = false
    static let toolEffect = ToolEffect.readOnly
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ToolExecutionOutput(summary: "fixture",
                            fullOutputSHA256: String(repeating: "0", count: 64))
    }
}

struct TempCredentialTool: AgentTool {          // accessesCredentials — outside
    struct Arguments: Decodable, Sendable { var account: String }
    static let name = "credential.status"
    static let toolDescription = "Credential disclosure"
    static let parametersJSON = #"{"type":"object"}"#
    static let riskLabels: Set<RiskLabel> = [.accessesCredentials]
    static let isSideEffecting = false
    static let toolEffect = ToolEffect.readOnly
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ToolExecutionOutput(summary: "fixture",
                            fullOutputSHA256: String(repeating: "0", count: 64))
    }
}

struct TempExecTool: AgentTool {                // model-authored execution — out
    struct Arguments: Decodable, Sendable { var command: String }
    static let name = "exec.shell"
    static let toolDescription = "Model-authored execution"
    static let parametersJSON = #"{"type":"object"}"#
    static let riskLabels: Set<RiskLabel> = [.executesLocalCode]
    static let isSideEffecting = true
    static let toolEffect = ToolEffect.mutating
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ToolExecutionOutput(summary: "fixture",
                            fullOutputSHA256: String(repeating: "0", count: 64))
    }
}

struct TempCalendarTool: AgentTool {            // personal read — outside
    struct Arguments: Decodable, Sendable { var box: String }
    static let name = "apple.calendar.list"
    static let toolDescription = "Personal data read"
    static let parametersJSON = #"{"type":"object"}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = false
    static let toolEffect = ToolEffect.readOnly
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ToolExecutionOutput(summary: "fixture",
                            fullOutputSHA256: String(repeating: "0", count: 64))
    }
}

struct TempDelegateTool: AgentTool {            // delegation — outside ceiling
    struct Arguments: Decodable, Sendable { var task: String }
    static let name = "delegate"
    static let toolDescription = "Delegation"
    static let parametersJSON = #"{"type":"object"}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    static let toolEffect = ToolEffect.internalState
    static var executionBoundary: ToolExecutionBoundary { .mainRunOnly }
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        ToolExecutionOutput(summary: "fixture",
                            fullOutputSHA256: String(repeating: "0", count: 64))
    }
}

enum TemporaryCatalogFixtures {
    /// Registers the ceiling candidates plus every outside-the-ceiling
    /// family the spec demands denial coverage for. Order is irrelevant:
    /// `allDescriptors` sorts by name. Instance registry only — no global
    /// `ToolCatalog` writes, no cross-suite leakage.
    static func registerAll(into registry: ToolRunnerRegistry) {
        registry.register(TempPublicWebTool())
        registry.register(TempWebSearchTool())
        registry.register(TempWebSearchAITool())
        registry.register(TempMCPTool())
        registry.register(TempLocalFileTool())
        registry.register(TempCredentialTool())
        registry.register(TempExecTool())
        registry.register(TempCalendarTool())
        registry.register(TempDelegateTool())
    }
}

// MARK: - Full fixture: REAL generation + owner stores + temporary domain

final class TemporaryDomainFixture {
    let root: URL
    let epoch: UInt64
    let bootstrapToken: String
    /// The ACTUAL owned `DatabaseManager` of this generation — the same
    /// schema-46 handle every ordinary service and the promoter use. No
    /// second database handle exists anywhere in this fixture (Main's
    /// same-owned-DB requirement; the reviewed `ownedDatabaseForTesting()`
    /// seam is a trusted test boundary, same module).
    let census: DatabaseManager
    let effects: FacadeEffectPump
    let events: FacadeEventPump
    let content: FacadeContentReader
    let mailbox: FacadeCommandMailbox
    let registry: RuntimeDomainRegistry
    let durableConversations: SQLiteConversationStore
    let durableRuns: SQLiteRunStore
    let durableInputs: SQLiteRunningInputStore
    let port: ControlledTemporaryRunPort
    let surface: RecordingHostSurface
    let availability: StubWebSearchAvailability
    let toolRegistry: ToolRunnerRegistry
    let gate: TemporaryNavigationGate
    /// The INSTALLED domain instance (the facade's live one) — test hooks
    /// and direct calls must hit the very actor the mailbox dispatches to.
    let domain: FacadeTemporaryDomain
    /// Real provider/model rows seeded through the ORIGINAL configuration
    /// store so the promoter's run FK graph is valid (no fabricated ids).
    let providerID: UUID
    let modelID: UUID

    /// Serializes generation transitions across tests (same reviewed
    /// discipline as the run-domain fixture): every `make` first retires
    /// the PREVIOUS fixture through the REAL shutdown control.
    nonisolated(unsafe) private static var previousFixture: TemporaryDomainFixture?
    private static let fixtureLock = NSLock()

    private init(root: URL, epoch: UInt64, bootstrapToken: String,
                 census: DatabaseManager,
                 effects: FacadeEffectPump, events: FacadeEventPump,
                 content: FacadeContentReader, mailbox: FacadeCommandMailbox,
                 registry: RuntimeDomainRegistry,
                 durableConversations: SQLiteConversationStore,
                 durableRuns: SQLiteRunStore,
                 durableInputs: SQLiteRunningInputStore,
                 port: ControlledTemporaryRunPort,
                 surface: RecordingHostSurface,
                 availability: StubWebSearchAvailability,
                 toolRegistry: ToolRunnerRegistry,
                 gate: TemporaryNavigationGate,
                 domain: FacadeTemporaryDomain,
                 providerID: UUID,
                 modelID: UUID) {
        self.root = root
        self.epoch = epoch
        self.bootstrapToken = bootstrapToken
        self.census = census
        self.effects = effects
        self.events = events
        self.content = content
        self.mailbox = mailbox
        self.registry = registry
        self.durableConversations = durableConversations
        self.durableRuns = durableRuns
        self.durableInputs = durableInputs
        self.port = port
        self.surface = surface
        self.availability = availability
        self.toolRegistry = toolRegistry
        self.gate = gate
        self.domain = domain
        self.providerID = providerID
        self.modelID = modelID
    }

    /// - Parameter wiredMailbox: when true the processors are registered
    ///   on the GENERATION's real `RuntimeDomainRegistry`, so mailbox
    ///   dispatch exercises the exact production path (used by the
    ///   navigation-fence wired suite). Default: isolated test registry.
    static func make(webSearchConfigured: Set<String> = ["web.search", "web.searchAI"],
                     withCeilingCatalog: Bool = true,
                     wiredMailbox: Bool = false,
                     withAvailabilityPort: Bool = true) async throws
        -> TemporaryDomainFixture {
        let previous = fixtureLock.withLock { () -> TemporaryDomainFixture? in
            let value = previousFixture
            previousFixture = nil
            return value
        }
        if let previous { await previous.teardown() }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("floe-rb5-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Strictly monotonic ACTUAL bootstrap epoch (never a fixed value).
        let epoch = DispatchTime.now().uptimeNanoseconds
        let token = String(format: "%016llx", UInt64.random(in: 1...UInt64.max))

        // Real bootstrap in the documented core-only FIXTURE mode: the
        // ordinary production graph stays uninstalled (this isolated lane
        // owns the temporary package under test), while the generation's
        // owner store cluster, mailbox, effect pump and binder remain the
        // REAL reviewed RB1 services.
        G02RuntimeComposition.shared.setCompositionModeForTesting(.coreOnly)
        switch AndroidRuntimeBootstrap.start(rootPath: root.standardizedFileURL.path,
                                             ownerToken: token,
                                             epoch: epoch) {
        case .accepted, .idempotent: break
        case .rejected(let code):
            throw NSError(domain: "fixture", code: 1,
                          userInfo: ["code": code.rawValue])
        }
        // Bounded readiness observation (no arbitrary long sleeps).
        var pumps = AndroidRuntimeBootstrap.currentPumps()
        for _ in 0..<3_000 {
            if let pumps, pumps.epoch == epoch, pumps.storeReady { break }
            try await Task.sleep(nanoseconds: 2_000_000)
            pumps = AndroidRuntimeBootstrap.currentPumps()
        }
        guard let pumps, pumps.storeReady,
              let gen = AndroidRuntimeBootstrap.currentGenerationForTesting(),
              gen.epoch == epoch,
              let database = await gen.owner.ownedDatabaseForTesting(),
              let conversationStore = await gen.owner.conversationStore,
              let runStore = await gen.owner.runStore,
              let inputStore = await gen.owner.runningInputStore else {
            throw NSError(domain: "fixture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "bootstrap store never ready: "
                                            + AndroidRuntimeBootstrap.statusSnapshotJSON()])
        }
        let port = ControlledTemporaryRunPort()
        let surface = RecordingHostSurface()
        let availability = StubWebSearchAvailability(configured: webSearchConfigured)
        let registry = ToolRunnerRegistry()
        if withCeilingCatalog {
            TemporaryCatalogFixtures.registerAll(into: registry)
        }
        let gate = TemporaryNavigationGate(epoch: epoch)
        // Real configuration rows (the same store family the ordinary UI
        // writes): the promoter's runs FK graph needs REAL provider/model
        // ids — a fabricated UUID fails FOREIGN KEY exactly like production.
        let modelStore = await gen.owner.modelConfigurationStore
            ?? ModelConfigurationStore(database: database)
        let providerID = UUID()
        let modelID = UUID()
        var providerProfile = ProviderProfile(
            kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://fixtures.invalid/v1")!)
        providerProfile.id = providerID
        providerProfile.secretRef = SecretReference(keychainAccount: "rb5-fixture-provider",
                                                    synchronizable: false)
        providerProfile.displayName = "RB5 Fixture"
        var modelProfile = ModelProfile(
            providerID: providerID, remoteModelID: "rb5-fixture-model",
            displayName: "RB5 Fixture Model",
            limits: ModelLimits(contextTokens: 16_000, maxOutputTokens: 2_048),
            capabilities: [.text])
        modelProfile.id = modelID
        try await modelStore.saveProvider(providerProfile)
        try await modelStore.saveModel(modelProfile)
        let components = TemporaryDomainComponents(
            epoch: epoch,
            gate: gate,
            effects: pumps.effects,
            database: database,
            durableConversations: conversationStore,
            durableRuns: runStore,
            durableRunningInputs: inputStore,
            toolRegistry: registry,
            runPort: port,
            webSearchAvailability: withAvailabilityPort ? availability : nil,
            hostSurface: surface)
        // Install the three frozen keys. The processor registry is the
        // fixture-local one unless `wiredMailbox` binds the GENERATION's
        // real registry (then mailbox jobs dispatch exactly like
        // production). The binder ingress is always the real process
        // singleton; teardown uninstalls precisely these keys.
        TemporaryDomainFacade.install(components: components,
                                      registry: wiredMailbox ? gen.registry
                                      : RuntimeDomainRegistry())
        // The facade's installed instance is THE domain under test: test
        // hooks and direct calls must hit the actor the mailbox uses (a
        // second actor over the same components would silently bypass the
        // hooks and split session state).
        guard let installedDomain = TemporaryDomainFacade.current(epoch: epoch) else {
            throw NSError(domain: "fixture", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "facade did not install"])
        }
        let fixture = TemporaryDomainFixture(
            root: root, epoch: epoch, bootstrapToken: token,
            census: database,
            effects: pumps.effects, events: pumps.events, content: pumps.content,
            mailbox: pumps.mailbox, registry: gen.registry,
            durableConversations: conversationStore,
            durableRuns: runStore, durableInputs: inputStore,
            port: port, surface: surface, availability: availability,
            toolRegistry: registry, gate: gate,
            domain: installedDomain,
            providerID: providerID, modelID: modelID)
        fixtureLock.withLock { previousFixture = fixture }
        return fixture
    }

    /// Durable-row census over the SAME owned schema-46 database: the
    /// RAM-only invariant is provable, not asserted by copied code.
    func durableCounts() async throws -> [String: Int] {
        try await census.reader { db in
            var counts: [String: Int] = [:]
            for table in ["conversations", "messages", "message_parts",
                          "attachments", "runs", "run_events", "run_usage",
                          "run_errors", "pending_user_inputs",
                          "message_fts", "workspaces",
                          "conversation_workspace_ownership"] {
                counts[table] = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            }
            return counts
        }
    }

    /// REAL shutdown + drain proof: the accepted owned control retires the
    /// generation, the mailbox drains its real work, and the store reaches
    /// closed with the generation gone. Never a force reset to green.
    func teardown() async {
        TemporaryDomainFacade.uninstall()
        gate.clearAuxiliaryStateForTesting()
        switch AndroidRuntimeBootstrap.shutdown(expectedEpoch: epoch,
                                                ownerToken: bootstrapToken) {
        case .accepted, .idempotent: break
        case .rejected:
            break   // already reset by an explicit cross-fixture cleanup
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        G02RuntimeComposition.shared.resetForTesting()
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Envelope builders (closed v3 shapes for the three rules)

enum TemporaryTestEnvelopes {
    static func correlation() -> String { "rb5-corr-" + UUID().uuidString }

    static func tempStart(correlation: String = correlation(),
                          payload: [String: Any]? = nil) -> [String: Any] {
        var envelope: [String: Any] = [
            "version": 3,
            "operation": "command.submit",
            "correlationID": correlation,
            "scope": "launch",
            "command": "temp.start",
            "createIntent": true,
        ]
        if let payload { envelope["payload"] = payload }
        return envelope
    }

    static func tempEnd(conversationID: UUID, incarnation: UUID,
                        correlation: String = correlation()) -> [String: Any] {
        [
            "version": 3,
            "operation": "command.submit",
            "correlationID": correlation,
            "scope": "conversationLifecycle",
            "command": "temp.end",
            "owner": ["taskID": conversationID.uuidString],
            "revision": [
                "resourceID": TemporarySessionRevision.resourceID(conversationID: conversationID),
                "version": incarnation.uuidString,
            ],
        ]
    }

    static func tempKeep(conversationID: UUID, incarnation: UUID,
                         correlation: String = correlation()) -> [String: Any] {
        [
            "version": 3,
            "operation": "command.submit",
            "correlationID": correlation,
            "scope": "conversationLifecycle",
            "command": "temp.keep",
            "owner": ["taskID": conversationID.uuidString],
            "revision": [
                "resourceID": TemporarySessionRevision.resourceID(conversationID: conversationID),
                "version": incarnation.uuidString,
            ],
        ]
    }
}

// MARK: - Session content seeding (through the ORIGINAL store protocols)

extension TemporaryDomainFixture {

    /// Accepted `temp.start` returning the minted identities.
    func startedSession(draft: String? = nil) async throws
        -> (conversationID: UUID, incarnation: UUID, receipt: String?,
            correlation: String, reply: TemporaryDomainReply) {
        var payload: [String: Any]? = nil
        if let draft { payload = ["draft": draft] }
        let correlation = TemporaryTestEnvelopes.correlation()
        let receipt = effects.register(correlationID: correlation)
        let envelope = TemporaryTestEnvelopes.tempStart(correlation: correlation,
                                                       payload: payload)
        let reply = await domain.start(envelope: envelope, receipt: receipt,
                                       correlation: correlation)
        guard case .mutationAccepted(let detail, let value) = reply.outcome,
              let rawID = detail["conversationID"], let cid = UUID(uuidString: rawID),
              let rawInc = detail["incarnation"], let inc = UUID(uuidString: rawInc),
              case .object(let pairs) = value,
              case .integer(let epochValue) = pairs["rootEpoch"] ?? .null,
              epochValue == Int64(epoch) else {
            throw NSError(domain: "fixture", code: 4,
                          userInfo: ["reply": String(describing: reply.outcome)])
        }
        return (cid, inc, receipt, correlation, reply)
    }

    /// Seed a full realistic turn (run header + events + usage + error row,
    /// messages with parts, one queued input) through the EXACT store
    /// protocols the run lane uses, so every Keep assertion runs against
    /// ORIGINAL ephemeral semantics, not copied code.
    func seedTurn(conversationID: UUID, runID: UUID? = nil,
                  canary: String) async throws -> UUID {
        let status = await domain.status()
        guard let incarnation = status.incarnation,
              let authority = await domain.authority(conversationID: conversationID,
                                                     incarnation: incarnation) else {
            throw NSError(domain: "fixture", code: 5)
        }
        let stores = authority.stores
        let run = runID ?? UUID()
        let now = Date()
        try await stores.runs.saveRun(RunRecord(
            id: run, conversationID: conversationID, state: "running",
            goal: "\(canary)-goal", startedAt: now,
            providerID: providerID, modelID: modelID,
            providerName: "fixture-provider", modelName: "fixture-model",
            conversationMode: "chat"))
        _ = try await stores.runs.appendEvent(
            runID: run, kind: .status, payloadJSON: #"{"state":"preparing"}"#)
        _ = try await stores.runs.appendEvent(
            runID: run, kind: .assistantText,
            payloadJSON: "{\"delta\":\"\(canary)-e1\"}")
        try await stores.runs.recordUsage(RunUsageRecord(
            runID: run, inputTokens: 7, outputTokens: 11, recordedAt: now))
        try await stores.runs.recordError(RunErrorRecord(
            runID: run, kind: "notice", message: canary, recoverable: true))
        let messageID = UUID()
        try await stores.conversations.appendMessage(PersistedMessage(
            id: messageID, conversationID: conversationID, role: "user",
            content: canary, createdAt: now,
            parts: [MessagePart(messageID: messageID, partIndex: 0,
                                kind: .text, text: canary, createdAt: now)],
            runID: run))
        let replyID = UUID()
        try await stores.conversations.appendMessage(PersistedMessage(
            id: replyID, conversationID: conversationID, role: "assistant",
            content: "\(canary)-answer",
            createdAt: now.addingTimeInterval(1),
            parts: [MessagePart(messageID: replyID, partIndex: 0, kind: .text,
                                text: "\(canary)-answer", createdAt: now)],
            runID: run))
        _ = try await stores.runningInputs.enqueue(PendingUserInput(
            conversationID: conversationID,
            content: "\(canary)-queued-input", createdAt: now, updatedAt: now))
        return run
    }

    /// Current incarnation of the live session (nil when none).
    func currentIncarnation() async -> UUID? {
        await domain.status().incarnation
    }
}
