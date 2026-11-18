// SPDX-License-Identifier: MPL-2.0
//
// Explicitly isolated test fixtures for the Mac self-owned runtime. Every
// database and workspace lives under a fresh 0700 temporary directory; no
// user database, Keychain item, workspace or simulator is touched.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity
import FloePersistence
import FloeAgentRuntime
@testable import FloeMacSelfCore

// MARK: - Gates

/// A one-shot async gate used to keep a synthetic provider stream open until
/// the test is ready to observe live events. Termination resumes waiters so a
/// cancelled consumer never leaves a suspended fixture task behind.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func cancelWaiters() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

// MARK: - Scripted provider

/// Scripted test provider. This is a test double only; the production
/// composition layer requires a host-injected real adapter.
final class ScriptedProviderAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol
    private let scripts: [[AgentEvent]]
    private let holdFirstEvent: Bool
    private let keepStreamOpen: Bool
    private let gate: AsyncGate?
    private let lock = NSLock()
    private var callCount = 0
    private var recordedRequests: [ProviderStreamRequest] = []

    init(
        protocolKind: ModelProtocol = .openAIResponses,
        scripts: [[AgentEvent]],
        holdFirstEvent: Bool = false,
        keepStreamOpen: Bool = false
    ) {
        self.protocolKind = protocolKind
        self.scripts = scripts
        self.holdFirstEvent = holdFirstEvent
        self.keepStreamOpen = keepStreamOpen
        self.gate = (holdFirstEvent || keepStreamOpen) ? AsyncGate() : nil
    }

    var requests: [ProviderStreamRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func openGate() async {
        await gate?.open()
    }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        lock.lock()
        recordedRequests.append(request)
        let index = callCount
        callCount += 1
        let events = index < scripts.count ? scripts[index] : []
        lock.unlock()
        let holdFirst = holdFirstEvent
        let keepOpen = keepStreamOpen
        let gate = self.gate
        return AsyncThrowingStream { continuation in
            let task = Task {
                for (offset, event) in events.enumerated() {
                    if holdFirst, offset == 0, let gate {
                        await gate.wait()
                    }
                    continuation.yield(event)
                }
                if keepOpen, let gate {
                    await gate.wait()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                if let gate {
                    Task { await gate.cancelWaiters() }
                }
            }
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] {
        []
    }
}

// MARK: - Executor and audit

final class RecordingToolExecutor: ToolExecutor, @unchecked Sendable {
    private let descriptorsByName: [String: ToolCatalog.Descriptor]
    private let lock = NSLock()
    private var calls: [ToolCall] = []

    init(descriptors: [ToolCatalog.Descriptor]) {
        self.descriptorsByName = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.name, $0) })
    }

    var executedCalls: [ToolCall] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        descriptorsByName[name]
    }

    var allDescriptors: [ToolCatalog.Descriptor] {
        descriptorsByName.values.sorted { $0.name < $1.name }
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        try context.cancellation.throwIfCancelled()
        lock.withLock {
            calls.append(call)
        }
        return ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: "fixture ok",
            outputDigest: FloeDigest.sha256Hex(Data("fixture ok".utf8))
        )
    }
}

final class RecordingAuditSink: AuditSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AuditEntry] = []

    var entries: [AuditEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ entry: AuditEntry) async throws {
        lock.withLock {
            storage.append(entry)
        }
    }
}

// MARK: - Fixture

/// Holds the first real shutdown result. `alreadyClosed` is only a later
/// summary and can never replace the original inventory evidence.
struct SelfCoreShutdownEvidence {
    private(set) var original: FloeMacSelfShutdownReceipt?
    private(set) var compromised = false

    mutating func record(_ receipt: FloeMacSelfShutdownReceipt) {
        guard !receipt.alreadyClosed else { return }
        if let original, original != receipt {
            compromised = true
        } else if original == nil {
            original = receipt
        }
        if !Self.isComplete(receipt) { compromised = true }
    }

    mutating func recordFailure() { compromised = true }

    func permitsCleanup(current: FloeMacSelfShutdownReceipt) -> Bool {
        guard !compromised, Self.isComplete(current), let original,
              Self.isComplete(original), !original.alreadyClosed else { return false }
        return current.alreadyClosed || current == original
    }

    private static func isComplete(_ receipt: FloeMacSelfShutdownReceipt) -> Bool {
        receipt.databaseClosed && receipt.preservedRunIDs.isEmpty
            && receipt.admissionInventoryAvailable
            && receipt.retainedAdmissionConversationIDs.isEmpty
    }
}

final class SelfCoreFixture: @unchecked Sendable {
    static let fixtureToolName = "fixture.write"

    let root: URL
    let databaseURL: URL
    let workspaceRoot: URL
    let owner: FloeMacSelfHostIdentity
    let runtime: FloeMacSelfRuntime
    let allowResidualAdmissions: Bool
    private let shutdownReceiptLock = NSLock()
    private var shutdownEvidence = SelfCoreShutdownEvidence()
    private var preservationRequired = false
    private var preserved = false

    private init(
        root: URL,
        databaseURL: URL,
        workspaceRoot: URL,
        owner: FloeMacSelfHostIdentity,
        runtime: FloeMacSelfRuntime,
        allowResidualAdmissions: Bool
    ) {
        self.root = root
        self.databaseURL = databaseURL
        self.workspaceRoot = workspaceRoot
        self.owner = owner
        self.runtime = runtime
        self.allowResidualAdmissions = allowResidualAdmissions
    }

    static func make(
        bootstrap: Bool = true,
        allowResidualAdmissions: Bool = false
    ) async throws -> SelfCoreFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-mac-self-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let databaseURL = root.appendingPathComponent("floe-self.sqlite")
        let owner = FloeMacSelfHostIdentity(displayName: "FloeMacSelfCoreTests")
        let provenance = try makeHostProvenance(databaseURL: databaseURL)
        let runtime = try FloeMacSelfRuntime(
            databaseURL: databaseURL,
            owner: owner,
            provenance: provenance
        )
        if bootstrap {
            _ = try await runtime.bootstrap()
        }
        return SelfCoreFixture(
            root: root,
            databaseURL: databaseURL,
            workspaceRoot: workspaceRoot,
            owner: owner,
            runtime: runtime,
            allowResidualAdmissions: allowResidualAdmissions
        )
    }

    /// Inserts a real workspace row for tool-enabled sessions. The workspace
    /// record and the host boundary deliberately share the same identifier;
    /// the fixture does not pretend an empty bookmark proves ownership.
    func createWorkspace(named name: String) async throws -> UUID {
        let database = try DatabaseManager(path: databaseURL)
        try await database.migrate()
        let store = SQLiteWorkspaceStore(database: database)
        let id = UUID()
        try await store.saveWorkspace(WorkspaceRecord(
            id: id,
            name: name,
            rootBookmark: Data(),
            kind: .project
        ))
        try await database.close()
        return id
    }

    func shutdown(
        cancelActive: Bool,
        allowUnconfirmed: Bool = false,
        timeout: TimeInterval = 30
    ) async throws -> FloeMacSelfShutdownReceipt {
        do {
            let receipt = try await runtime.shutdown(
                cancelActive: cancelActive,
                allowUnconfirmed: allowUnconfirmed,
                timeout: timeout
            )
            shutdownReceiptLock.withLock { shutdownEvidence.record(receipt) }
            return receipt
        } catch {
            shutdownReceiptLock.withLock {
                shutdownEvidence.recordFailure()
                preservationRequired = true
            }
            throw error
        }
    }

    func dispose(preserveEvidence: Bool = false) async throws {
        if shutdownReceiptLock.withLock({ preserved }) { return }
        let receipt: FloeMacSelfShutdownReceipt
        do {
            receipt = try await shutdown(cancelActive: true, allowUnconfirmed: false, timeout: 5)
        } catch {
            throw SelfCoreFixtureCleanupError(root: root, reason: "shutdown failed: \(error)")
        }
        try finishDisposal(receipt, preserveEvidence: preserveEvidence, actualShutdown: true)
    }

    /// The test fixture owns this root, but must retain it as evidence if any
    /// run or database closure is unconfirmed. Injecting the shutdown result
    /// lets the regression test exercise failure without deleting that root.
    func disposeAfterShutdown(
        _ shutdown: () async throws -> FloeMacSelfShutdownReceipt
    ) async throws {
        let receipt: FloeMacSelfShutdownReceipt
        do {
            receipt = try await shutdown()
        } catch {
            shutdownReceiptLock.withLock { preservationRequired = true }
            throw SelfCoreFixtureCleanupError(root: root, reason: "shutdown failed: \(error)")
        }
        // A synthetic result can test rejection but is never a cleanup
        // credential. Only `dispose()` invokes the real runtime shutdown.
        try finishDisposal(receipt, preserveEvidence: true, actualShutdown: false)
    }

    private func finishDisposal(
        _ receipt: FloeMacSelfShutdownReceipt,
        preserveEvidence: Bool,
        actualShutdown: Bool
    ) throws {
        let basicValid = receipt.databaseClosed && receipt.preservedRunIDs.isEmpty
        let retained = !receipt.retainedAdmissionConversationIDs.isEmpty
            || !receipt.admissionInventoryAvailable
        if !basicValid || retained {
            shutdownReceiptLock.withLock { preservationRequired = true }
        }
        guard basicValid else {
            throw SelfCoreFixtureCleanupError(
                root: root,
                reason: "shutdown did not confirm database closure and every run"
            )
        }
        if retained {
            guard allowResidualAdmissions else {
                throw SelfCoreFixtureCleanupError(
                    root: root,
                    reason: "shutdown retained unresolved admission evidence"
                )
            }
            // Retain the database and lock evidence for host reconciliation.
            // The test explicitly opted into this state.
            if actualShutdown { shutdownReceiptLock.withLock { preserved = true } }
            return
        }
        if actualShutdown {
            let allowed = shutdownReceiptLock.withLock {
                shutdownEvidence.permitsCleanup(current: receipt)
            }
            guard allowed else {
                shutdownReceiptLock.withLock { preservationRequired = true }
                throw SelfCoreFixtureCleanupError(root: root, reason: "original shutdown evidence is missing or unconfirmed")
            }
        } else if receipt.alreadyClosed {
            // Test-injected `alreadyClosed` must not become actual evidence.
            shutdownReceiptLock.withLock { preservationRequired = true }
            throw SelfCoreFixtureCleanupError(root: root, reason: "synthetic shutdown cannot confirm earlier closure")
        }
        let mustPreserve = shutdownReceiptLock.withLock { preservationRequired }
        if preserveEvidence || mustPreserve || !actualShutdown {
            if actualShutdown { shutdownReceiptLock.withLock { preserved = true } }
            return
        }
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            throw SelfCoreFixtureCleanupError(root: root, reason: "fixture cleanup failed: \(error)")
        }
    }

    // MARK: Providers and tools

    func makeProvider(
        scripts: [[AgentEvent]],
        holdFirstEvent: Bool = false,
        keepStreamOpen: Bool = false,
        protocolKind: ModelProtocol = .openAIResponses,
        remoteModelID: String = "fixture-model",
        capabilities: ModelCapabilities = [.text, .tools]
    ) -> (binding: FloeMacSelfProviderBinding, adapter: ScriptedProviderAdapter) {
        Self.makeProviderBinding(
            scripts: scripts,
            holdFirstEvent: holdFirstEvent,
            keepStreamOpen: keepStreamOpen,
            protocolKind: protocolKind,
            remoteModelID: remoteModelID,
            capabilities: capabilities
        )
    }

    static func makeProviderBinding(
        scripts: [[AgentEvent]],
        holdFirstEvent: Bool = false,
        keepStreamOpen: Bool = false,
        protocolKind: ModelProtocol = .openAIResponses,
        remoteModelID: String = "fixture-model",
        capabilities: ModelCapabilities = [.text, .tools]
    ) -> (binding: FloeMacSelfProviderBinding, adapter: ScriptedProviderAdapter) {
        let adapter = ScriptedProviderAdapter(
            protocolKind: protocolKind,
            scripts: scripts,
            holdFirstEvent: holdFirstEvent,
            keepStreamOpen: keepStreamOpen
        )
        let provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIResponses,
            baseURL: URL(string: "https://localhost:8443")!,
            displayName: "Fixture Provider",
            secretRef: nil,
            region: nil,
            nonSecretHeaders: [:],
            isEnabled: true,
            allowsPlainHTTP: false,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncRevision: 0
        )
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: remoteModelID,
            displayName: "Fixture Model",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: capabilities,
            isEnabled: true
        )
        return (
            FloeMacSelfProviderBinding(
                provider: provider,
                model: model,
                adapter: adapter,
                credentials: ProviderCredentials()
            ),
            adapter
        )
    }

    func makeHostGate(
        workspaceID: UUID,
        allowedToolNames: Set<String>,
        root: URL? = nil,
        issuer: String = "fixture-tests"
    ) -> FloeMacSelfHostGate {
        let rootURL = (root ?? workspaceRoot)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        return FloeMacSelfHostGate(
            workspaceID: workspaceID,
            workspaceRootPath: rootURL.path,
            approvalPolicySource: "fixture.human-approval-policy.v1",
            toolCorpusIdentifier: "fixture.tool-corpus.v1",
            approvedToolNames: allowedToolNames,
            issuer: issuer
        )
    }

    func makeToolBinding(
        workspaceID: UUID,
        allowedToolNames: Set<String> = [SelfCoreFixture.fixtureToolName],
        descriptor: ToolCatalog.Descriptor? = nil,
        ownership: FloeMacSelfExecutionOwnership = .nativeHost,
        boundaryRoot: URL? = nil,
        hostGate: FloeMacSelfHostGate? = nil
    ) throws -> (binding: FloeMacSelfToolBinding, executor: RecordingToolExecutor, audit: RecordingAuditSink) {
        let descriptor = descriptor ?? Self.fixtureDescriptor
        let executor = RecordingToolExecutor(descriptors: [descriptor])
        let audit = RecordingAuditSink()
        let gate = try CatastrophicActionGate.withBundledPatterns()
        let root = boundaryRoot ?? workspaceRoot
        let boundary = FloeMacSelfTaskBoundary(
            workspaceID: workspaceID,
            workspaceRootURL: root,
            allowedWorkspacePaths: [],
            ownership: ownership
        )
        let resolvedGate = hostGate ?? makeHostGate(
            workspaceID: workspaceID,
            allowedToolNames: allowedToolNames,
            root: root
        )
        let binding = FloeMacSelfToolBinding(
            executor: executor,
            policy: HumanApprovalPolicy(),
            gate: gate,
            auditSink: audit,
            boundary: boundary,
            allowedToolNames: allowedToolNames,
            hostGate: resolvedGate
        )
        return (binding, executor, audit)
    }

    static var fixtureDescriptor: ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: fixtureToolName,
            toolDescription: "Fixture write used to exercise the real approval path",
            parametersJSON: #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"],"additionalProperties":false}"#,
            riskLabels: [.writesFiles],
            isSideEffecting: true
        )
    }

    static func hostScopedDescriptor() -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: "fixture.remote",
            toolDescription: "Fixture host-scoped action",
            parametersJSON: #"{"type":"object","additionalProperties":false}"#,
            riskLabels: [.executesRemoteCommand],
            isSideEffecting: true
        )
    }

    static func fixtureCall(id: String = "call-fixture-1") throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: fixtureToolName,
            argumentsJSON: Data(#"{"text":"hello"}"#.utf8),
            scope: .local
        )
    }

    // MARK: Requests

    func newConversationRequest(
        goal: String,
        workspaceID: UUID? = nil,
        title: String = "Fixture chat",
        chatFastMode: Bool = true
    ) -> FloeMacSelfSessionRequest {
        FloeMacSelfSessionRequest(
            workspaceID: workspaceID,
            conversationTitle: title,
            goal: goal,
            mode: .chat,
            context: FloeMacSelfRunContext(workspaceName: "Fixture"),
            chatFastMode: chatFastMode
        )
    }

    func continuationRequest(
        conversationID: UUID,
        goal: String,
        workspaceID: UUID? = nil,
        chatFastMode: Bool = true
    ) -> FloeMacSelfSessionRequest {
        FloeMacSelfSessionRequest(
            conversationID: conversationID,
            workspaceID: workspaceID,
            goal: goal,
            mode: .chat,
            context: FloeMacSelfRunContext(workspaceName: "Fixture"),
            chatFastMode: chatFastMode
        )
    }
}

// MARK: - Event collection and waiting

actor SessionEventCollector {
    private var storage: [FloeMacSelfSessionEvent] = []

    func collect(_ stream: AsyncStream<FloeMacSelfSessionEvent>) async {
        for await event in stream {
            storage.append(event)
        }
    }

    var events: [FloeMacSelfSessionEvent] { storage }

    func harnessEvents() -> [HarnessEvent] {
        storage.compactMap { event in
            if case .harness(let harness) = event { return harness }
            return nil
        }
    }

    func hasEnded() -> Bool {
        storage.contains { event in
            if case .ended = event { return true }
            return false
        }
    }

    func hasTerminalHarnessEvent() -> Bool {
        harnessEvents().contains { event in
            if case .terminal = event { return true }
            return false
        }
    }
}

func startEventCollector(
    _ handle: FloeMacSelfSessionHandle
) -> (collector: SessionEventCollector, task: Task<Void, Never>) {
    let collector = SessionEventCollector()
    let task = Task { await collector.collect(handle.events()) }
    return (collector, task)
}

struct SelfCoreFixtureCleanupError: Error, CustomStringConvertible {
    let root: URL
    let reason: String

    var description: String { "Fixture retained at \(root.path): \(reason)" }
}

/// Runs against a fresh temporary database. The fixture is removed only after
/// every run and the database have a confirmed shutdown; failures preserve it.
func withSelfCoreFixture(
    bootstrap: Bool = true,
    allowResidualAdmissions: Bool = false,
    _ body: (SelfCoreFixture) async throws -> Void
) async throws {
    let fixture = try await SelfCoreFixture.make(
        bootstrap: bootstrap,
        allowResidualAdmissions: allowResidualAdmissions
    )
    do {
        try await body(fixture)
    } catch {
        let original = error
        do {
            try await fixture.dispose(preserveEvidence: true)
            Issue.record("Fixture retained after test failure: \(fixture.root.path)")
        } catch {
            // Preserve both the original failure and the cleanup evidence.
            Issue.record("Fixture shutdown/cleanup also failed: \(error)")
        }
        throw original
    }
    try await fixture.dispose()
}

func approvalCommand(
    handle: FloeMacSelfSessionHandle,
    pending: AgentState.WaitingApproval,
    decision: ApprovalDecision
) -> FloeMacSelfApprovalCommand {
    FloeMacSelfApprovalCommand(
        conversationID: handle.identity.conversationID,
        runID: handle.identity.runID,
        workspaceID: handle.identity.workspaceID,
        callID: pending.toolCall.id,
        toolName: pending.toolCall.toolName,
        decision: decision
    )
}

func eventually(
    timeout: TimeInterval = 10,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(max(0.2, timeout))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

func selfCoreError(
    _ operation: () async throws -> Void
) async -> FloeMacSelfCoreError? {
    do {
        try await operation()
        return nil
    } catch let error as FloeMacSelfCoreError {
        return error
    } catch {
        return nil
    }
}

/// Unique 0700 root that is intentionally retained. Used only by tests that
/// create an unresolved admission/run state; the test process never deletes
/// that evidence.
func makeSelfCoreEvidenceRoot(prefix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-mac-self-core-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return root
}

/// Host-side preparation for the verified authority primitive. The fixture
/// acts as the host: it requires the parent directory and database file to
/// exist, tightens their modes to the private values the primitive enforces,
/// and captures the exact identities the runtime will bind. This records what
/// the filesystem currently says; it does not authenticate the host.
func makeHostProvenance(
    databaseURL: URL,
    lockDirectory: URL? = nil
) throws -> FloeMacSelfHostProvenance {
    let directory = databaseURL.deletingLastPathComponent()
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: directory.path
    )
    if !FileManager.default.fileExists(atPath: databaseURL.path) {
        try Data().write(to: databaseURL)
    }
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: databaseURL.path
    )
    return try FloeMacSelfHostProvenance.capture(
        directoryPath: directory.standardizedFileURL.path,
        lockDirectoryPath: (lockDirectory ?? directory).standardizedFileURL.path,
        databaseName: databaseURL.lastPathComponent
    )
}

/// Unique isolated root for authority-lock and direct-store tests. The root is
/// removed only when the body succeeds. A failing body leaves the directory as
/// evidence; the helper never removes a path it did not create.
func withSelfCoreTempDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-mac-self-core-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    try await body(root)
    try? FileManager.default.removeItem(at: root)
}

/// Direct SQLite setup used to reproduce a crash's durable bytes. It opens its
/// own DatabaseManager, migrates once, and must be closed by the caller before
/// a FloeMacSelfRuntime acquires the authority lock on the same path.
func makeSeededDatabase(
    at databaseURL: URL
) async throws -> (database: DatabaseManager, launch: SQLiteRunLaunchStore, workspace: SQLiteWorkspaceStore) {
    let database = try DatabaseManager(path: databaseURL)
    try await database.migrate()
    try await database.writer { db in
        try FloeMacSelfAdmissionStore.installSchema(in: db)
    }
    return (
        database,
        SQLiteRunLaunchStore(database: database),
        SQLiteWorkspaceStore(database: database)
    )
}
