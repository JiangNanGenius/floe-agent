// SPDX-License-Identifier: MPL-2.0
//
// ChildSubagentDelegationTests — end-to-end behavioral tests for Mac owned
// background project subagents (shared iOS v1.8.57 delegation on Mac),
// driven through the real FloeMacSelfRuntime composition with a real SQLite
// database, the real ConversationRunService, the real SubagentRunnerRegistry
// and scripted provider adapters.
//
// Covered behavior (the user-corrected Mac policy: a delegated child inherits
// the parent task's EFFECTIVE runtime authority, exactly like iPad):
// - a project Agent-style run delegates a child that persists durably, uses
//   the SELECTED provider/model, and settles its output into the parent;
// - the child's wire catalog is the parent's effective ceiling (workspace
//   writes and web.fetch included when the parent holds them; the delegation
//   envelope stays main-run-only and invisible);
// - a child's side-effecting call executes for REAL only after the parent
//   runtime's canonical approval path grants exactly that call — an allowed
//   write lands on disk, a denied write leaves no side effect, and a
//   single-use grant never becomes standing authority;
// - the parent task's file scope and workspace root are live for children
//   (path-scoped tasks and root escapes fail closed);
// - nested delegation and delegate.wait fail closed for children;
// - WITHOUT the canonical handoff the shared runner keeps its fail-closed
//   read-only legacy ceiling (mutating calls denied, reads execute);
// - cancelling ONE background child settles it durably as `.cancelled`
//   while its sibling completes; parent stop reaches exactly its own
//   children; two concurrent parents stay independent;
// - the session lifecycle hooks are inert for runs nobody owns.

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

// MARK: - Scripted provider with a child-only gate

/// Scripted adapter whose CHILD requests park before their first event until
/// `openChildGate()` is called, while parent requests stream immediately.
/// This keeps a delegated child durably `running` (its model turn is
/// genuinely blocked waiting on the provider) so tests can observe the
/// active phase and exercise cancel/stop deterministically. The shared
/// fixture adapter cannot express this: its gate is global, which would also
/// park the parent's turns.
/// Gate whose wait is a cancellable sleep loop: the producer task inside the
/// adapter's stream is a child task of the consuming run, so run cancellation
/// propagates into the sleep and unwinds the provider stream instead of
/// deadlocking on a suspension that ignores cancellation.
actor CancellableChildGate {
    private var isOpen = false
    func open() { isOpen = true }
    func wait(continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async {
        while !isOpen {
            if Task.isCancelled {
                // Terminate the stream so a parked consumer's next() resumes
                // and the cancelled run can settle durably.
                continuation.finish()
                return
            }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }
}

/// One content-routed response rule. Rules are evaluated in order against
/// the request's MEANING (system-prompt role, settled tool receipts, child
/// prompt marker) — never against a global call counter, so concurrent
/// parent/child turns cannot race each other for the next script.
struct GatedScriptRule: Sendable {
    var matches: @Sendable (ProviderStreamRequest) -> Bool
    var script: [AgentEvent]
    /// Park on the child gate before serving (delegated child turns).
    var parkBeforeServing: Bool
}

/// Scripted adapter routing responses by request meaning. Parent turns are
/// served immediately; delegated child turns park until `openChildGate()`.
final class RoutedScriptedAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol
    private let rules: [GatedScriptRule]
    private let fallback: [AgentEvent]
    private let gate = CancellableChildGate()
    private let lock = NSLock()
    private var recordedRequests: [ProviderStreamRequest] = []
    private var offeredToolCalls = Set<String>()

    init(protocolKind: ModelProtocol = .openAIResponses, rules: [GatedScriptRule], fallback: [AgentEvent] = []) {
        self.protocolKind = protocolKind
        self.rules = rules
        self.fallback = fallback
    }

    var requests: [ProviderStreamRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func openChildGate() async {
        await gate.open()
    }

    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        let rule = rules.first(where: { $0.matches(request) })
        let proposed = rule?.script ?? fallback
        let callIDs = proposed.compactMap { event -> String? in
            if case .toolRequest(let call) = event { return call.id }
            return nil
        }
        lock.lock()
        recordedRequests.append(request)
        let alreadyOffered = callIDs.contains(where: offeredToolCalls.contains)
        offeredToolCalls.formUnion(callIDs)
        lock.unlock()
        let script: [AgentEvent] = alreadyOffered
            ? [.textDelta(.init(text: "The delegated research has finished.")), .completed(.init(stopReason: .endTurn))]
            : proposed
        let park = rule?.parkBeforeServing ?? false
        let gate = self.gate
        return AsyncThrowingStream { continuation in
            let task = Task {
                if park { await gate.wait(continuation: continuation) }
                for event in script {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] {
        []
    }
}

// MARK: - Request-matching helpers (meaning-based routing)

enum ScriptRoute {
    /// A delegated child's request (subagent system prompt).
    static func child(marker: String) -> @Sendable (ProviderStreamRequest) -> Bool {
        { request in
            request.messages.contains { $0.role == "system" && $0.content.contains(marker) }
        }
    }

    /// Any settled background-delegate receipt from an earlier parent turn.
    static let hasDelegateReceipt: @Sendable (ProviderStreamRequest) -> Bool = { request in
        request.toolResults.contains { $0.output.contains("status=started") || $0.output.contains("status=ok") }
            || request.replayedToolPairs.contains { $0.call.toolName == DelegateTool.name }
    }

    /// The parent turn that carries the injected subagent evidence.
    static let hasSubagentEvidence: @Sendable (ProviderStreamRequest) -> Bool = { request in
        request.messages.contains { $0.content.contains("subagent-evidence") }
    }

    /// A child request whose ledger already settled one exact tool call.
    static func childSettled(_ marker: String, callID: String) -> @Sendable (ProviderStreamRequest) -> Bool {
        { request in
            ScriptRoute.child(marker: marker)(request)
                && request.toolResults.contains { $0.callID == callID }
        }
    }
}

// MARK: - Real project fixture executor

/// The project executor used by the child-authority tests. Read fixtures
/// answer immediately; the ONE mutating tool (`workspace.createFile`)
/// performs an ACTUAL write inside the pinned root, so a test can prove the
/// child's inherited authority produced a real on-disk effect — and that a
/// denial or a scope violation produced none. The executor enforces, at its
/// own boundary, the same facts the Mac production tools enforce:
/// - a mutating call must carry a real approval grant (the parent runtime's
///   canonical path issues it AFTER approval; a forged child context cannot
///   mint one — no raw exec/write bypass);
/// - the parent task's persisted file scope (`allowedWorkspacePaths`) is
///   live for children via `ToolContext.authorizeWorkspacePath`;
/// - paths are confined to the task root (absolute paths and traversal fail
///   closed).
final class WorkspaceFixtureExecutor: ToolExecutor, @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var calls: [(call: ToolCall, status: ToolResult.Status)] = []
    private let descriptorsByName: [String: ToolCatalog.Descriptor]

    init(root: URL, descriptors: [ToolCatalog.Descriptor]) {
        self.root = root.standardizedFileURL
        self.descriptorsByName = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.name, $0) })
    }

    /// Calls that executed to a real `.ok` outcome (denied calls excluded).
    var executedCalls: [ToolCall] {
        lock.lock()
        defer { lock.unlock() }
        return calls.filter { $0.status == .ok }.map(\.call)
    }

    /// Every call that crossed the executor boundary, with its outcome —
    /// including executor-level denials (scope violations, escapes).
    var handledCalls: [(call: ToolCall, status: ToolResult.Status)] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var allDescriptors: [ToolCatalog.Descriptor] {
        descriptorsByName.values.sorted { $0.name < $1.name }
    }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        descriptorsByName[name]
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        try await execute(call, expectedAuthorizationIdentity: nil, context: context)
    }

    func execute(
        _ call: ToolCall,
        expectedAuthorizationIdentity: String?,
        context: ToolContext
    ) async throws -> ToolResult {
        try context.cancellation.throwIfCancelled()
        func record(_ status: ToolResult.Status) {
            lock.withLock { calls.append((call, status)) }
        }
        guard let descriptor = descriptorsByName[call.toolName] else {
            record(.failed)
            return ToolResult(callID: call.id, status: .failed,
                              outputSummary: "No runner registered for tool '\(call.toolName)'", outputDigest: "")
        }
        if let expectedAuthorizationIdentity,
           descriptor.authorizationIdentity != expectedAuthorizationIdentity {
            record(.denied)
            return ToolResult(callID: call.id, status: .denied,
                              outputSummary: "Tool authority changed after approval; review the updated tool before retrying",
                              outputDigest: "")
        }
        guard descriptor.effect != .readOnly else {
            record(.ok)
            return ToolResult(callID: call.id, status: .ok, outputSummary: "fixture read ok",
                              outputDigest: FloeDigest.sha256Hex(Data("fixture read ok".utf8)))
        }
        // Mutating path: real side effect, real guards.
        guard context.approvalGrantID != nil else {
            // The canonical dispatcher always issues a grant for an approved
            // call. A mutating call without one is a forged/wrapped context:
            // fail closed, never execute.
            record(.denied)
            return ToolResult(callID: call.id, status: .denied,
                              outputSummary: "Denied: mutating calls require the task's authorized approval grant",
                              outputDigest: "")
        }
        do {
            let object = (try? JSONSerialization.jsonObject(with: call.argumentsJSON)) as? [String: Any] ?? [:]
            guard let relative = object["path"] as? String, let text = object["text"] as? String,
                  !relative.isEmpty, relative.utf8.count <= 4_096 else {
                record(.failed)
                return ToolResult(callID: call.id, status: .failed,
                                  outputSummary: "Invalid write arguments", outputDigest: "")
            }
            // The parent task's persisted file scope governs children too.
            try context.authorizeWorkspacePath(relative)
            guard !relative.hasPrefix("/") else {
                record(.denied)
                return ToolResult(callID: call.id, status: .denied,
                                  outputSummary: "Denied: path is outside the task workspace", outputDigest: "")
            }
            let base = root.standardizedFileURL
            let candidate = base.appendingPathComponent(relative).standardizedFileURL
            guard candidate.path.hasPrefix(base.path + "/") else {
                record(.denied)
                return ToolResult(callID: call.id, status: .denied,
                                  outputSummary: "Denied: path is outside the task workspace", outputDigest: "")
            }
            try FileManager.default.createDirectory(
                at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: candidate, options: .atomic)
            record(.ok)
            return ToolResult(callID: call.id, status: .ok,
                              outputSummary: "wrote \(relative) (\(text.utf8.count) bytes)",
                              outputDigest: FloeDigest.sha256Hex(Data(text.utf8)))
        } catch {
            record(.denied)
            return ToolResult(callID: call.id, status: .denied,
                              outputSummary: "Denied: \(error.localizedDescription)", outputDigest: "")
        }
    }
}

// MARK: - Tests

@Suite("FloeMacSelfCore.ChildSubagentDelegation", .serialized)
struct ChildSubagentDelegationTests {
    /// Marker that identifies a delegated child's provider request (the
    /// subagent system prompt prefix minted by SubagentRunner).
    static let childMarker = "You are now running as a delegated subagent"
    // The actual Mac workspace investigation read tool names (mirrors
    // MacAgentWorkspaceTools.readToolNames; the package cannot import the
    // FloeMac target, so tests pin the same contract).
    static let workspaceReadAllowlist: Set<String> = [
        "workspace.listDirectory",
        "workspace.readFile",
        "workspace.inspectFileMetadata",
        "workspace.searchFiles",
        "workspace.readDocument",
    ]
    static let writeToolName = "workspace.createFile"
    static let webFetchToolName = "web.fetch"

    static func readDescriptor(_ name: String) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            toolDescription: "Fixture read \(name)",
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#,
            riskLabels: [.readsFiles],
            isSideEffecting: false,
            effect: .readOnly
        )
    }

    static let writeDescriptor = ToolCatalog.Descriptor(
        name: writeToolName,
        toolDescription: "Fixture write",
        parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"},"text":{"type":"string"}},"required":["path","text"],"additionalProperties":false}"#,
        riskLabels: [.writesFiles],
        isSideEffecting: true,
        effect: .mutating
    )

    /// A `web.fetch`-shaped read-only descriptor the PARENT executor offers.
    /// A canonical child now inherits it exactly like iPad: the wire catalog
    /// must include it (the parent holds it) while the per-call web tools
    /// still validate the exact delegated run identity at their boundary.
    static let parentWebFetchDescriptor = ToolCatalog.Descriptor(
        name: webFetchToolName,
        toolDescription: "Fixture public web fetch",
        parametersJSON: #"{"type":"object","properties":{"url":{"type":"string"}},"required":["url"],"additionalProperties":false}"#,
        riskLabels: [.readsFiles, .networkAccess],
        isSideEffecting: false,
        effect: .readOnly
    )

    static func fixtureExecutor(root: URL) -> WorkspaceFixtureExecutor {
        WorkspaceFixtureExecutor(
            root: root,
            descriptors: workspaceReadAllowlist.map(readDescriptor)
                + [writeDescriptor, parentWebFetchDescriptor]
        )
    }

    func makeBinding(
        fixture: SelfCoreFixture,
        workspaceID: UUID,
        executor: any ToolExecutor,
        allowed: Set<String>,
        allowedWorkspacePaths: [String] = []
    ) throws -> FloeMacSelfToolBinding {
        let gate = try CatastrophicActionGate.withBundledPatterns()
        let boundary = FloeMacSelfTaskBoundary(
            workspaceID: workspaceID,
            workspaceRootURL: fixture.workspaceRoot,
            allowedWorkspacePaths: allowedWorkspacePaths,
            ownership: .nativeHost
        )
        return FloeMacSelfToolBinding(
            executor: executor,
            policy: HumanApprovalPolicy(),
            gate: gate,
            auditSink: nil,
            boundary: boundary,
            allowedToolNames: allowed,
            hostGate: fixture.makeHostGate(workspaceID: workspaceID, allowedToolNames: allowed)
        )
    }

    func delegateCall(id: String, background: Bool, task: String = "investigate the fixture workspace") throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: DelegateTool.name,
            argumentsJSON: Data("{\"task\":\"\(task)\",\"background\":\(background ? "true" : "false")}".utf8),
            scope: .local
        )
    }

    func writeCall(id: String, path: String, text: String) throws -> ToolCall {
        let object: [String: Any] = ["path": path, "text": text]
        return try ToolCall(
            id: id,
            toolName: Self.writeToolName,
            argumentsJSON: JSONSerialization.data(withJSONObject: object),
            scope: .local
        )
    }

    func agentRequest(conversationID: UUID, workspaceID: UUID, runID: UUID, goal: String) -> FloeMacSelfSessionRequest {
        FloeMacSelfSessionRequest(
            newConversationID: conversationID,
            workspaceID: workspaceID,
            conversationTitle: "Child delegation task",
            goal: goal,
            mode: .chat,
            runID: runID,
            context: FloeMacSelfRunContext(workspaceName: "Child workspace"),
            chatFastMode: false
        )
    }

    /// Waits for the pending-approval card of ONE EXACT provider call id and
    /// allows it. The visible card may still belong to a previous call when
    /// several approvals are in flight, so the unique call id — never just
    /// "some pending card" — is what makes the wait correct.
    @discardableResult
    func allowPending(handle: FloeMacSelfSessionHandle, callID: String) async throws -> Bool {
        try await resolvePending(handle: handle, callID: callID) { pending in
            approvalCommand(
                handle: handle,
                pending: pending,
                decision: .allow(
                    scope: ApprovalScope(toolName: pending.toolCall.toolName, singleUse: true),
                    expiresAt: nil
                )
            )
        }
    }

    /// Waits for the pending-approval card of ONE EXACT provider call id and
    /// denies it. Used to prove a denial produces no side effect.
    @discardableResult
    func denyPending(handle: FloeMacSelfSessionHandle, callID: String, reason: String = "denied by the fixture user") async throws -> Bool {
        try await resolvePending(handle: handle, callID: callID) { pending in
            approvalCommand(
                handle: handle,
                pending: pending,
                decision: .deny(reason: reason)
            )
        }
    }

    private func resolvePending(
        handle: FloeMacSelfSessionHandle,
        callID: String,
        makeCommand: (AgentState.WaitingApproval) -> FloeMacSelfApprovalCommand
    ) async throws -> Bool {
        let waiting = await eventually(timeout: 15) {
            let snapshot = await handle.snapshot()
            return snapshot?.pendingApproval?.toolCall.id == callID
        }
        guard waiting,
              let pending = await handle.snapshot()?.pendingApproval,
              pending.toolCall.id == callID else { return false }
        return await handle.resolveApproval(makeCommand(pending)) == .accepted
    }

    /// Install a child runtime over the fixture database, bind the parent run
    /// (same selected provider, the run's own project executor as the child's
    /// discovery universe) and build the session tool binding with this
    /// runtime's private delegation tools.
    @discardableResult
    func bindParent(
        fixture: SelfCoreFixture,
        provider: FloeMacSelfProviderBinding,
        project: WorkspaceFixtureExecutor,
        workspaceID: UUID,
        conversationID: UUID,
        runID: UUID,
        allowedWorkspacePaths: [String] = []
    ) async throws -> (childRuntime: FloeMacChildSubagentRuntime, tools: FloeMacSelfToolBinding) {
        let store = try await fixture.runtime.childRunStoring()
        let childRuntime = FloeMacChildSubagentRuntime(childStore: store)
        await fixture.runtime.installChildSubagentRuntime(childRuntime)
        let composite = FloeMacDelegatingProjectToolExecutor(project: project, runners: childRuntime.registry)
        var allowed = Self.workspaceReadAllowlist.union([Self.writeToolName, Self.webFetchToolName])
        allowed.formUnion(FloeMacDelegatingProjectToolExecutor.defaultDelegatingNames)
        let tools = try makeBinding(
            fixture: fixture, workspaceID: workspaceID, executor: composite,
            allowed: allowed, allowedWorkspacePaths: allowedWorkspacePaths
        )
        await childRuntime.bindParentRun(
            runID: runID,
            provider: provider.provider,
            model: provider.model,
            adapter: provider.adapter,
            credentials: provider.credentials,
            projectExecutor: composite
        )
        return (childRuntime, tools)
    }

    func fixtureProvider(
        adapter: RoutedScriptedAdapter
    ) throws -> FloeMacSelfProviderBinding {
        let provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIResponses,
            baseURL: URL(string: "https://localhost:8443")!,
            displayName: "Fixture Provider",
            isEnabled: true
        )
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "fixture-model",
            displayName: "Fixture Model",
            limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
            capabilities: [.text, .tools],
            isEnabled: true
        )
        return FloeMacSelfProviderBinding(
            provider: provider,
            model: model,
            adapter: adapter,
            credentials: ProviderCredentials()
        )
    }

    // MARK: - Session lifecycle

    @Test("Session lifecycle hooks are inert for runs nobody owns")
    func lifecycleNoOpsForUnboundRun() async throws {
        let database = try DatabaseManager(path: FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-child-lifecycle-\(UUID().uuidString).sqlite"))
        try await database.migrate()
        let store = SQLiteChildRunStore(database: database)
        let runtime = FloeMacChildSubagentRuntime(childStore: store)
        let lifecycle = await runtime.sessionLifecycle(for: UUID(), conversationID: UUID())
        let settled = try await lifecycle.settle?() ?? []
        #expect(settled.isEmpty)
        try await lifecycle.markDelivered?([UUID()])  // no throw for unbound run
        #expect(try await lifecycle.isBackground?(UUID()) == false)
        await lifecycle.markInterrupted?()
        await lifecycle.cancelAll?()
        try await database.close()
    }

    // MARK: - Legacy fallback: no canonical handoff fails closed to read-only

    @Test("Without the canonical handoff the shared runner fails closed: reads execute, mutating calls are denied")
    func legacyRunnerWithoutHandoffFailsClosedToReadOnly() async throws {
        try await withSelfCoreFixture { fixture in
            let root = fixture.workspaceRoot
            let project = Self.fixtureExecutor(root: root)
            let readCall = try ToolCall(
                id: "legacy-read-1",
                toolName: "workspace.readFile",
                argumentsJSON: Data(#"{"path":"."}"#.utf8),
                scope: .local
            )
            let writeCall = try writeCall(id: "legacy-write-1", path: "legacy.txt", text: "should never land")
            let adapter = RoutedScriptedAdapter(rules: [
                // The misbehaving child still tries a write on its second turn.
                GatedScriptRule(
                    matches: ScriptRoute.childSettled(Self.childMarker, callID: "legacy-write-1"),
                    script: [.textDelta(.init(text: "child final")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.childSettled(Self.childMarker, callID: "legacy-read-1"),
                    script: [.toolRequest(writeCall), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.child(marker: Self.childMarker),
                    script: [.toolRequest(readCall), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
            ], fallback: [
                .textDelta(.init(text: "child final")), .completed(.init(stopReason: .endTurn)),
            ])
            let provider = try fixtureProvider(adapter: adapter)
            // A directly-constructed legacy context: budget present, NO
            // ChildExecutionHandoff (no dispatcher, no identity, no peers).
            let budget = ChildBudgetContext(
                maximumIterations: 6,
                reserve: { true },
                finish: {},
                remaining: { 6 }
            )
            let runID = UUID(), conversationID = UUID()
            var allowed = Self.workspaceReadAllowlist.union([Self.writeToolName])
            allowed.formUnion(FloeMacDelegatingProjectToolExecutor.defaultDelegatingNames)
            let context = ToolContext(
                runID: runID,
                toolCallID: "legacy-delegate-1",
                scope: .local,
                allowedToolNames: allowed,
                workspaceRootURL: root,
                cancellation: CancellationToken(),
                childBudget: budget,
                conversationID: conversationID
            )
            let runner = SubagentRunner(
                provider: provider.provider,
                model: provider.model,
                adapter: provider.adapter,
                credentials: provider.credentials,
                executor: project
            )
            let outcome = try await runner.runStructured(
                SubagentRequest(task: "investigate without a handoff", runID: runID),
                context: context
            )
            #expect(outcome.status == .completed)
            // The read executed through the legacy read-only path…
            #expect(project.executedCalls.contains { $0.id == readCall.id })
            // …the mutating call was denied BEFORE any execution…
            #expect(!project.executedCalls.contains { $0.id == writeCall.id })
            // …and the child model saw the fail-closed denial verbatim.
            let childRequests = adapter.requests.filter(ScriptRoute.child(marker: Self.childMarker))
            #expect(childRequests.count >= 3)
            let afterWrite = try #require(childRequests.first(where: {
                $0.toolResults.contains { $0.callID == writeCall.id }
            }))
            let receipt = try #require(afterWrite.toolResults.first { $0.callID == writeCall.id })
            #expect(receipt.output.contains("read-only"))
            // No durable identity exists for this unwired legacy run.
            #expect(try await FileManager.default.fileExists(
                atPath: root.appendingPathComponent("legacy.txt").path) == false)
        }
    }

    // MARK: - Inherited authority: successful child write through the canonical approval path

    @Test("A child's mutating call executes for real only after the parent runtime approves exactly that call")
    func childInheritsParentCeilingSuccessfulWrite() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Child workspace")
            let project = Self.fixtureExecutor(root: fixture.workspaceRoot)
            let write = try writeCall(id: "child-write-1", path: "child-output.txt", text: "hello from child")
            let provider = try fixtureProvider(adapter: RoutedScriptedAdapter(rules: [
                GatedScriptRule(
                    matches: ScriptRoute.child(marker: Self.childMarker),
                    script: [.toolRequest(write), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.hasDelegateReceipt,
                    script: [.textDelta(.init(text: "parent final answer")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: { _ in true },
                    script: [.toolRequest(try delegateCall(id: "delegate-1", background: false, task: "write the handoff file")), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
            ]))
            let conversationID = UUID(), runID = UUID()
            let bound = try await bindParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID
            )
            let handle = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate the write"),
                provider: provider,
                tools: bound.tools
            )
            #expect(try await allowPending(handle: handle, callID: "delegate-1"))
            // The child's side-effecting write resolves through the SAME parent
            // approval path: exactly this call id must appear before it runs.
            #expect(try await allowPending(handle: handle, callID: "child-write-1"))

            let terminal = try #require(await handle.waitForTerminal(timeout: 20))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            _ = try await handle.close()

            // The write is REAL: the file exists in the task workspace with
            // the exact bytes the child sent.
            let written = fixture.workspaceRoot.appendingPathComponent("child-output.txt")
            #expect(try String(contentsOf: written, encoding: .utf8) == "hello from child")
            #expect(project.executedCalls.contains { $0.id == write.id })

            // Every provider request — the parent's AND the child's — used the
            // exact selected provider/model identity.
            let requests = boundRequests(adapter: provider.adapter)
            #expect(requests.count == 4)
            #expect(requests.allSatisfy {
                $0.provider.id == provider.provider.id && $0.model.id == provider.model.id
            })

            // The child's wire catalog IS the parent's effective ceiling: the
            // read set and the mutating write tool are offered (the
            // progressive loader may defer individual tools; the real web
            // fetch eligibility is pinned by the dedicated ceiling test); the
            // delegation envelope stays main-run-only and invisible.
            let childRequest = requests[1]
            let schemaNames = Set(childRequest.toolSchemas.map(\.name))
            #expect(Self.workspaceReadAllowlist.isSubset(of: schemaNames))
            #expect(schemaNames.contains(Self.writeToolName))
            #expect(!schemaNames.contains(DelegateTool.name))
            #expect(!schemaNames.contains(DelegateWaitTool.name))
            // The follow-up child request carried the write call and its real
            // receipt back to the model.
            #expect(requests[2].pendingToolCalls.map(\.id) == [write.id])
            #expect(requests[2].toolResults.contains { $0.callID == write.id })

            // The child completed durably and the parent reconciled its
            // actual outcome.
            let children = try await bound.childRuntime.durableChildren(parentRunID: runID)
            #expect(children.count == 1)
            let child = try #require(children.first)
            #expect(child.state == .completed)
            #expect(child.conversationID == conversationID)
            #expect(child.resultSummary?.contains("research has finished") == true)
            await bound.childRuntime.releaseParentRun(runID)
        }
    }

    // MARK: - Denial with no side effect

    @Test("A denied child write leaves no side effect and the child reconciles the denial")
    func deniedChildWriteLeavesNoSideEffect() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Deny workspace")
            let project = Self.fixtureExecutor(root: fixture.workspaceRoot)
            let write = try writeCall(id: "child-write-1", path: "denied-output.txt", text: "must not land")
            let provider = try fixtureProvider(adapter: RoutedScriptedAdapter(rules: [
                GatedScriptRule(
                    matches: ScriptRoute.child(marker: Self.childMarker),
                    script: [.toolRequest(write), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.hasDelegateReceipt,
                    script: [.textDelta(.init(text: "parent final answer")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: { _ in true },
                    script: [.toolRequest(try delegateCall(id: "delegate-1", background: false, task: "write a file")), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
            ]))
            let conversationID = UUID(), runID = UUID()
            let bound = try await bindParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID
            )
            let handle = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate the write"),
                provider: provider,
                tools: bound.tools
            )
            #expect(try await allowPending(handle: handle, callID: "delegate-1"))
            // Deny exactly the child's write call.
            #expect(try await denyPending(handle: handle, callID: "child-write-1"))

            let terminal = try #require(await handle.waitForTerminal(timeout: 20))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            _ = try await handle.close()

            // NO side effect: the file never existed and the write never
            // reached the executor.
            #expect(FileManager.default.fileExists(
                atPath: fixture.workspaceRoot.appendingPathComponent("denied-output.txt").path) == false)
            #expect(!project.executedCalls.contains { $0.id == write.id })

            // The child model received the denial verbatim and finished by
            // reconciling it (the durable row records a real completion).
            let requests = boundRequests(adapter: provider.adapter)
            let childTurnTwo = try #require(requests.filter(ScriptRoute.child(marker: Self.childMarker)).last)
            let receipt = try #require(childTurnTwo.toolResults.first { $0.callID == write.id })
            #expect(receipt.output.contains("denied") || receipt.output.contains("Denied"))
            let children = try await bound.childRuntime.durableChildren(parentRunID: runID)
            #expect(children.count == 1)
            #expect(children.first?.state == .completed)
            await bound.childRuntime.releaseParentRun(runID)
        }
    }

    // MARK: - Single-use grant never becomes standing authority

    @Test("A single-use child grant is consumed by its call; the next mutating call needs a fresh decision")
    func singleUseChildGrantDoesNotBecomeStanding() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Grant workspace")
            let project = Self.fixtureExecutor(root: fixture.workspaceRoot)
            let first = try writeCall(id: "child-write-1", path: "grant-first.txt", text: "first")
            let second = try writeCall(id: "child-write-2", path: "grant-second.txt", text: "second")
            let provider = try fixtureProvider(adapter: RoutedScriptedAdapter(rules: [
                GatedScriptRule(
                    matches: ScriptRoute.childSettled(Self.childMarker, callID: "child-write-2"),
                    script: [.textDelta(.init(text: "child done after restricted work")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.childSettled(Self.childMarker, callID: "child-write-1"),
                    script: [.toolRequest(second), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.child(marker: Self.childMarker),
                    script: [.toolRequest(first), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.hasDelegateReceipt,
                    script: [.textDelta(.init(text: "parent final answer")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: { _ in true },
                    script: [.toolRequest(try delegateCall(id: "delegate-1", background: false, task: "write two files")), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
            ]))
            let conversationID = UUID(), runID = UUID()
            let bound = try await bindParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID
            )
            let handle = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate the writes"),
                provider: provider,
                tools: bound.tools
            )
            #expect(try await allowPending(handle: handle, callID: "delegate-1"))
            // First write: single-use grant, executes.
            #expect(try await allowPending(handle: handle, callID: "child-write-1"))
            // The single-use grant died with its call: the second write must
            // surface a FRESH approval card instead of riding the first grant.
            #expect(try await denyPending(handle: handle, callID: "child-write-2"))

            let terminal = try #require(await handle.waitForTerminal(timeout: 20))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            _ = try await handle.close()

            // Exactly the first file exists; the denied second write never
            // reached the executor.
            #expect(try String(contentsOf: fixture.workspaceRoot.appendingPathComponent("grant-first.txt"), encoding: .utf8) == "first")
            #expect(FileManager.default.fileExists(
                atPath: fixture.workspaceRoot.appendingPathComponent("grant-second.txt").path) == false)
            #expect(project.executedCalls.contains { $0.id == first.id })
            #expect(!project.executedCalls.contains { $0.id == second.id })
            // The child reconciled the second denial and still completed.
            let children = try await bound.childRuntime.durableChildren(parentRunID: runID)
            #expect(children.count == 1)
            #expect(children.first?.state == .completed)
            let requests = boundRequests(adapter: provider.adapter)
            let childTurnThree = try #require(requests.filter(ScriptRoute.child(marker: Self.childMarker)).last)
            let receipt = try #require(childTurnThree.toolResults.first { $0.callID == second.id })
            #expect(receipt.output.contains("denied") || receipt.output.contains("Denied"))
            await bound.childRuntime.releaseParentRun(runID)
        }
    }

    // MARK: - Parent file scope is live for children

    @Test("The parent task's persisted file scope governs child writes: in-scope lands, out-of-scope is denied")
    func parentFileScopeIsLiveForChildCalls() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Scoped workspace")
            let project = Self.fixtureExecutor(root: fixture.workspaceRoot)
            let inScope = try writeCall(id: "child-write-docs", path: "docs/ok.txt", text: "inside the scope")
            let outOfScope = try writeCall(id: "child-write-src", path: "src/evil.txt", text: "outside the scope")
            let provider = try fixtureProvider(adapter: RoutedScriptedAdapter(rules: [
                GatedScriptRule(
                    matches: ScriptRoute.childSettled(Self.childMarker, callID: "child-write-src"),
                    script: [.textDelta(.init(text: "child reconciled the scope denial")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.childSettled(Self.childMarker, callID: "child-write-docs"),
                    script: [.toolRequest(outOfScope), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.child(marker: Self.childMarker),
                    script: [.toolRequest(inScope), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.hasDelegateReceipt,
                    script: [.textDelta(.init(text: "parent final answer")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: { _ in true },
                    script: [.toolRequest(try delegateCall(id: "delegate-1", background: false, task: "write inside the task scope")), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
            ]))
            let conversationID = UUID(), runID = UUID()
            // The parent task is persisted with a "docs" file scope.
            let bound = try await bindParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID,
                allowedWorkspacePaths: ["docs"]
            )
            let handle = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate scoped writes"),
                provider: provider,
                tools: bound.tools
            )
            #expect(try await allowPending(handle: handle, callID: "delegate-1"))
            #expect(try await allowPending(handle: handle, callID: "child-write-docs"))
            // The out-of-scope write still passes the approval gate (the user
            // allowed the call) but the TASK SCOPE denies it at the executor
            // boundary — inherited authority never widens the file scope.
            #expect(try await allowPending(handle: handle, callID: "child-write-src"))

            let terminal = try #require(await handle.waitForTerminal(timeout: 20))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            _ = try await handle.close()

            #expect(try String(contentsOf: fixture.workspaceRoot.appendingPathComponent("docs/ok.txt"), encoding: .utf8) == "inside the scope")
            #expect(FileManager.default.fileExists(
                atPath: fixture.workspaceRoot.appendingPathComponent("src/evil.txt").path) == false)
            // The out-of-scope call DID cross the executor boundary (the user
            // granted it) and was denied there by the live task scope.
            let handled = project.handledCalls.first { $0.call.id == outOfScope.id }
            #expect(handled?.status == .denied)
            let requests = boundRequests(adapter: provider.adapter)
            let childTurnThree = try #require(requests.filter(ScriptRoute.child(marker: Self.childMarker)).last)
            let receipt = try #require(childTurnThree.toolResults.first { $0.callID == outOfScope.id })
            #expect(receipt.output.contains("does not permit"))
            await bound.childRuntime.releaseParentRun(runID)
        }
    }

    // MARK: - No cross-workspace access: root boundary

    @Test("A child write that escapes the parent workspace root is denied and never lands")
    func childWriteOutsideParentWorkspaceIsDenied() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Root boundary workspace")
            // A second, sibling task workspace the child must never reach.
            let foreignRoot = fixture.root.appendingPathComponent("ForeignWorkspace-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: foreignRoot) }
            let project = Self.fixtureExecutor(root: fixture.workspaceRoot)
            let escape = try writeCall(
                id: "child-write-escape",
                path: foreignRoot.appendingPathComponent("invade.txt").path,
                text: "cross-workspace intrusion"
            )
            let provider = try fixtureProvider(adapter: RoutedScriptedAdapter(rules: [
                GatedScriptRule(
                    matches: ScriptRoute.childSettled(Self.childMarker, callID: "child-write-escape"),
                    script: [.textDelta(.init(text: "child reconciled the root denial")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.child(marker: Self.childMarker),
                    script: [.toolRequest(escape), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.hasDelegateReceipt,
                    script: [.textDelta(.init(text: "parent final answer")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: { _ in true },
                    script: [.toolRequest(try delegateCall(id: "delegate-1", background: false, task: "try writing outside the workspace")), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
            ]))
            let conversationID = UUID(), runID = UUID()
            let bound = try await bindParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID
            )
            let handle = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate an escape attempt"),
                provider: provider,
                tools: bound.tools
            )
            #expect(try await allowPending(handle: handle, callID: "delegate-1"))
            // Even with the user's grant, the workspace root pin denies the
            // escape: inherited authority never crosses the task boundary.
            #expect(try await allowPending(handle: handle, callID: "child-write-escape"))

            let terminal = try #require(await handle.waitForTerminal(timeout: 20))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            _ = try await handle.close()

            #expect(FileManager.default.fileExists(
                atPath: foreignRoot.appendingPathComponent("invade.txt").path) == false)
            #expect(!project.executedCalls.contains { $0.id == escape.id })
            // The escape call reached the executor with a user grant and was
            // denied there by the workspace root pin.
            let handled = project.handledCalls.first { $0.call.id == escape.id }
            #expect(handled?.status == .denied)
            let requests = boundRequests(adapter: provider.adapter)
            let childTurnTwo = try #require(requests.filter(ScriptRoute.child(marker: Self.childMarker)).last)
            let receipt = try #require(childTurnTwo.toolResults.first { $0.callID == escape.id })
            #expect(receipt.output.contains("outside the task workspace"))
            await bound.childRuntime.releaseParentRun(runID)
        }
    }

    // MARK: - Unsupported actions fail closed for children

    @Test("Nested delegate and delegate.wait are denied to children; no grandchild row is ever created")
    func nestedDelegationFailsClosedForChildren() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Nested workspace")
            let project = Self.fixtureExecutor(root: fixture.workspaceRoot)
            let nestedDelegate = try ToolCall(
                id: "nested-1",
                toolName: DelegateTool.name,
                argumentsJSON: Data(#"{"task":"nested sub-subtask"}"#.utf8),
                scope: .local
            )
            let nestedWait = try ToolCall(
                id: "nested-wait-1",
                toolName: DelegateWaitTool.name,
                argumentsJSON: Data(#"{"childID":"\#(UUID().uuidString)","seconds":0}"#.utf8),
                scope: .local
            )
            let provider = try fixtureProvider(adapter: RoutedScriptedAdapter(rules: [
                GatedScriptRule(
                    matches: ScriptRoute.childSettled(Self.childMarker, callID: "nested-wait-1"),
                    script: [.textDelta(.init(text: "child finished without delegating")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.childSettled(Self.childMarker, callID: "nested-1"),
                    script: [.toolRequest(nestedWait), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.child(marker: Self.childMarker),
                    script: [.toolRequest(nestedDelegate), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.hasDelegateReceipt,
                    script: [.textDelta(.init(text: "parent final answer")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: { _ in true },
                    script: [.toolRequest(try delegateCall(id: "delegate-1", background: false, task: "try to delegate again")), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
            ]))
            let conversationID = UUID(), runID = UUID()
            let bound = try await bindParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID
            )
            let handle = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate a nested attempt"),
                provider: provider,
                tools: bound.tools
            )
            #expect(try await allowPending(handle: handle, callID: "delegate-1"))
            // No approval card is ever expected for the nested calls: the
            // canonical dispatcher refuses them before any approval request.
            let terminal = try #require(await handle.waitForTerminal(timeout: 20))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            _ = try await handle.close()

            // Both nested calls were denied with the main-run-only reason and
            // the child reconciled them.
            let requests = boundRequests(adapter: provider.adapter)
            let childTurnTwo = requests.filter(ScriptRoute.child(marker: Self.childMarker))
            #expect(childTurnTwo.count == 3)
            let delegateReceipt = try #require(childTurnTwo[1].toolResults.first { $0.callID == "nested-1" })
            #expect(delegateReceipt.output.contains("main-run only"))
            let waitReceipt = try #require(childTurnTwo[2].toolResults.first { $0.callID == "nested-wait-1" })
            #expect(waitReceipt.output.contains("main-run only"))
            // Exactly ONE durable child row exists: no nested run was created.
            let children = try await bound.childRuntime.durableChildren(parentRunID: runID)
            #expect(children.count == 1)
            #expect(children.first?.state == .completed)
            await bound.childRuntime.releaseParentRun(runID)
        }
    }

    // MARK: - Child wire catalog inherits the parent ceiling

    @Test("A delegated child inherits the parent's effective ceiling: web.fetch executes, writes are offered, delegation stays hidden")
    func childWireCatalogInheritsParentCeiling() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Ceiling workspace")
            let project = Self.fixtureExecutor(root: fixture.workspaceRoot)
            let readCall = try ToolCall(
                id: "child-read-1",
                toolName: "workspace.readFile",
                argumentsJSON: Data(#"{"path":"."}"#.utf8),
                scope: .local
            )
            let fetchCall = try ToolCall(
                id: "child-fetch-1",
                toolName: Self.webFetchToolName,
                argumentsJSON: Data(#"{"url":"https://example.com/"}"#.utf8),
                scope: .local
            )
            let provider = try fixtureProvider(adapter: RoutedScriptedAdapter(rules: [
                GatedScriptRule(
                    matches: ScriptRoute.child(marker: Self.childMarker),
                    script: [.toolRequest(readCall), .toolRequest(fetchCall), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: ScriptRoute.hasDelegateReceipt,
                    script: [.textDelta(.init(text: "parent final answer")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: { _ in true },
                    script: [.toolRequest(try delegateCall(id: "delegate-1", background: false, task: "read one file and fetch one page")), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
            ]))
            let conversationID = UUID(), runID = UUID()
            let bound = try await bindParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID
            )
            let handle = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate a read"),
                provider: provider,
                tools: bound.tools
            )
            #expect(try await allowPending(handle: handle, callID: "delegate-1"))
            let terminal = try #require(await handle.waitForTerminal(timeout: 20))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            _ = try await handle.close()

            // The child's first wire schema set admitted the parent's read
            // ceiling and the mutating write tool; the progressive loader may
            // defer individual tools (ChildToolDiscovery), so web.fetch
            // eligibility is proven by the REAL call below, not by the
            // first-turn schema array. The delegation envelope stays hidden.
            let requests = boundRequests(adapter: provider.adapter)
            #expect(requests.count == 4)
            let childRequest = requests[1]
            let schemaNames = Set(childRequest.toolSchemas.map(\.name))
            #expect(Self.workspaceReadAllowlist.isSubset(of: schemaNames))
            #expect(schemaNames.contains(Self.writeToolName))
            #expect(!schemaNames.contains(DelegateTool.name))
            #expect(!schemaNames.contains(DelegateWaitTool.name))
            // The follow-up child request carried BOTH pending calls and
            // their real receipts back to the model.
            #expect(Set(requests[2].pendingToolCalls.map(\.id)) == Set([readCall.id, fetchCall.id]))
            #expect(requests[2].toolResults.contains { $0.callID == readCall.id })
            #expect(requests[2].toolResults.contains { $0.callID == fetchCall.id })
            // Both calls really executed through the canonical path — a child
            // reaches web.fetch exactly when the parent holds it.
            #expect(project.executedCalls.contains { $0.id == readCall.id })
            #expect(project.executedCalls.contains { $0.id == fetchCall.id })
            // The delegate handoff returned a completed receipt to the parent.
            #expect(requests[3].toolResults.contains { $0.output.contains("status=ok") })
            await bound.childRuntime.releaseParentRun(runID)
        }
    }

    // MARK: - End-to-end: background child persists, uses selected provider, settles

    @Test("Background child persists, uses the selected provider, and its output settles into the parent")
    func backgroundChildEndToEnd() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Child workspace")
            let project = Self.fixtureExecutor(root: fixture.workspaceRoot)
            let provider = try fixtureProvider(adapter: RoutedScriptedAdapter(rules: [
                // The delegated child's single turn (parked until the test
                // observes the active phase and opens the gate).
                GatedScriptRule(
                    matches: ScriptRoute.child(marker: Self.childMarker),
                    script: [.textDelta(.init(text: "child findings about the project layout")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: true
                ),
                // Parent turn 1: delegate the investigation in the background.
                GatedScriptRule(
                    matches: { !ScriptRoute.hasDelegateReceipt($0) },
                    script: [.toolRequest(try delegateCall(id: "delegate-1", background: true)), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
                // Parent turn 2: the model answers, but completion is held
                // until background children settle.
                GatedScriptRule(
                    matches: { !ScriptRoute.hasSubagentEvidence($0) },
                    script: [.textDelta(.init(text: "parent draft")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
            ], fallback: [
                // Parent turn 3: after the subagent evidence was injected.
                .textDelta(.init(text: "parent final answer")), .completed(.init(stopReason: .endTurn)),
            ]))
            let conversationID = UUID(), runID = UUID()
            let bound = try await bindParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID
            )
            let adapter = provider.adapter as? RoutedScriptedAdapter
            let handle = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate the investigation"),
                provider: provider,
                tools: bound.tools
            )
            #expect(try await allowPending(handle: handle, callID: "delegate-1"))

            // Active phase: the child exists and is running in the durable store.
            let running = await eventually(timeout: 15) {
                guard let children = try? await bound.childRuntime.durableChildren(parentRunID: runID),
                      let child = children.first else { return false }
                return children.count == 1 && child.state == .running
            }
            #expect(running)
            await adapter?.openChildGate()

            let terminal = try #require(await handle.waitForTerminal(timeout: 20))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            _ = try await handle.close()

            // Every provider request — the parent's AND the child's — used the
            // exact selected provider/model identity.
            let requests = boundRequests(adapter: provider.adapter)
            #expect(requests.count == 4)
            #expect(requests.allSatisfy {
                $0.provider.id == provider.provider.id && $0.model.id == provider.model.id
            })

            // The child output is durably persisted and visible.
            let children = try await bound.childRuntime.durableChildren(parentRunID: runID)
            #expect(children.count == 1)
            let child = try #require(children.first)
            #expect(child.state == .completed)
            #expect(child.conversationID == conversationID)
            #expect(child.resultSummary?.contains("child findings about the project layout") == true)

            // History read-back: the conversation listing keeps the completed
            // child after the parent run ended.
            let history = try await bound.childRuntime.durableChildren(conversationID: conversationID)
            #expect(history.map(\.id) == [child.id])

            // The parent settled the child's actual output into its evidence
            // before finishing (turn-3 request carries the subagent evidence).
            #expect(requests[3].messages.contains { $0.content.contains("subagent-evidence") })
            #expect(requests[3].messages.contains { $0.content.contains("child findings about the project layout") })

            await bound.childRuntime.releaseParentRun(runID)
            // Release never deletes history.
            #expect(try await bound.childRuntime.durableChildren(conversationID: conversationID).map(\.id) == [child.id])
        }
    }

    // MARK: - End-to-end: cancel one of two background children

    @Test("Cancelling one background child settles it cancelled, the sibling completes, history survives")
    func cancelOneBackgroundChildOfTwo() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Cancel workspace")
            let project = Self.fixtureExecutor(root: fixture.workspaceRoot)
            let adapter = RoutedScriptedAdapter(rules: [
                // Delegated child turns (identical; either child may run either
                // subtask) — parked until the test opens the child gate.
                GatedScriptRule(
                    matches: ScriptRoute.child(marker: Self.childMarker),
                    script: [.textDelta(.init(text: "child findings")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: true
                ),
                // Parent turn 3: after both children settled.
                GatedScriptRule(
                    matches: ScriptRoute.hasSubagentEvidence,
                    script: [.textDelta(.init(text: "parent final answer")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                // Parent turn 2: the first delegate receipt is back, so the
                // model delegates the second investigation.
                GatedScriptRule(
                    matches: ScriptRoute.hasDelegateReceipt,
                    script: [.toolRequest(try delegateCall(id: "delegate-2", background: true, task: "second investigation")), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
            ], fallback: [
                // Parent turn 1: delegate the first investigation.
                .toolRequest(try delegateCall(id: "delegate-1", background: true, task: "first investigation")), .completed(.init(stopReason: .toolUse)),
            ])
            let provider = try fixtureProvider(adapter: adapter)
            let conversationID = UUID(), runID = UUID()
            let bound = try await bindParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID
            )
            let handle = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate both investigations"),
                provider: provider,
                tools: bound.tools
            )
            #expect(try await allowPending(handle: handle, callID: "delegate-1"))
            #expect(try await allowPending(handle: handle, callID: "delegate-2"))

            // Both children are actively running, parked on the child gate.
            let bothRunning = await eventually(timeout: 15) {
                guard let children = try? await bound.childRuntime.durableChildren(parentRunID: runID) else { return false }
                return children.count == 2 && children.allSatisfy { $0.state == .running }
            }
            #expect(bothRunning)
            var children = try await bound.childRuntime.durableChildren(parentRunID: runID)
            let ordered = children.sorted { $0.id.uuidString < $1.id.uuidString }
            let cancelledChild = try #require(ordered.first)
            let siblingChild = try #require(ordered.last)

            // Cancel exactly one.
            try await bound.childRuntime.cancelChild(
                runID: runID,
                conversationID: conversationID,
                childID: cancelledChild.id
            )
            let cancelledDurable = await eventually(timeout: 15) {
                guard let record = try? await bound.childRuntime.durableChildren(parentRunID: runID)
                    .first(where: { $0.id == cancelledChild.id }) else { return false }
                return record.state == .cancelled
            }
            #expect(cancelledDurable)
            // The sibling is untouched by the cancellation.
            #expect(try await bound.childRuntime.durableChildren(parentRunID: runID)
                .first(where: { $0.id == siblingChild.id })?.state == .running)

            // Release the child gate so the sibling and the parent can finish.
            await adapter.openChildGate()
            let terminal = try #require(await handle.waitForTerminal(timeout: 20))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            _ = try await handle.close()

            // Sibling completed with real output; cancelled child kept its
            // terminal cancelled row (not interrupted, not completed).
            children = try await bound.childRuntime.durableChildren(parentRunID: runID)
            #expect(children.count == 2)
            #expect(children.first { $0.id == cancelledChild.id }?.state == .cancelled)
            #expect(children.first { $0.id == siblingChild.id }?.state == .completed)
            #expect(children.first { $0.id == siblingChild.id }?.resultSummary?.contains("child findings") == true)

            // The parent reconciled the ACTUAL outcomes: the settle evidence
            // names the cancelled child as a non-success receipt.
            let requests = boundRequests(adapter: provider.adapter)
            let childRequests = requests.filter(ScriptRoute.child(marker: Self.childMarker))
            #expect(childRequests.contains { request in
                request.messages.contains { $0.content.contains(siblingChild.taskSummary) }
            })
            let finalRequest = try #require(requests.last)
            #expect(ScriptRoute.hasSubagentEvidence(finalRequest))
            #expect(finalRequest.messages.contains { $0.content.contains("status=cancelled") })
            #expect(finalRequest.messages.contains { $0.content.contains("child findings") })

            // History: both rows remain readable after the parent released.
            await bound.childRuntime.releaseParentRun(runID)
            let history = try await bound.childRuntime.durableChildren(conversationID: conversationID)
            #expect(history.count == 2)
            #expect(history.contains { $0.id == cancelledChild.id && $0.state == .cancelled })
        }
    }

    // MARK: - End-to-end: parent stop reaches its own children

    @Test("Stopping the parent interrupts its running background child durably")
    func parentStopInterruptsBackgroundChild() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Stop workspace")
            let project = Self.fixtureExecutor(root: fixture.workspaceRoot)
            let adapter = RoutedScriptedAdapter(rules: [
                // The child stays parked until the gate opens.
                GatedScriptRule(
                    matches: ScriptRoute.child(marker: Self.childMarker),
                    script: [.textDelta(.init(text: "child never finishes")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: true
                ),
                // Parent turn 1: delegate in the background.
                GatedScriptRule(
                    matches: { !ScriptRoute.hasDelegateReceipt($0) },
                    script: [.toolRequest(try delegateCall(id: "delegate-1", background: true)), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
            ], fallback: [
                // Any continuation turn after the delegate receipt.
                .textDelta(.init(text: "parent final answer")), .completed(.init(stopReason: .endTurn)),
            ])
            let provider = try fixtureProvider(adapter: adapter)
            let conversationID = UUID(), runID = UUID()
            let bound = try await bindParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID
            )
            let handle = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate then stop"),
                provider: provider,
                tools: bound.tools
            )
            #expect(try await allowPending(handle: handle, callID: "delegate-1"))
            let childRunning = await eventually(timeout: 15) {
                guard let children = try? await bound.childRuntime.durableChildren(parentRunID: runID),
                      let child = children.first else { return false }
                return child.state == .running
            }
            #expect(childRunning)

            // Parent stop: the wired lifecycle hooks interrupt this run's
            // children (durable, resumable `.interrupted` — never success).
            let receipt = await handle.cancelAndWait()
            #expect(receipt.terminal?.confirmed == true)

            let interrupted = await eventually(timeout: 15) {
                guard let children = try? await bound.childRuntime.durableChildren(parentRunID: runID),
                      let child = children.first else { return false }
                return child.state == .interrupted
            }
            #expect(interrupted)
            // Drain the parked provider stream only after the durable state
            // settled; the fixture shutdown does not own adapter tasks.
            await adapter.openChildGate()
            _ = try await handle.close()
            await bound.childRuntime.releaseParentRun(runID)
        }
    }

    // MARK: - End-to-end: default personal task workspace + reopened result

    /// Runs a body against a dedicated runtime whose private-task lease base
    /// is the fixture root, so a durable `.privateTask` workspace resolves
    /// through the real verified lease. Cleanup mirrors `withSelfCoreFixture`:
    /// the root is removed only after a confirmed shutdown; a failure keeps
    /// it as evidence.
    func withPersonalTaskRuntime(
        _ body: (URL, FloeMacSelfRuntime) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-child-personal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let databaseURL = root.appendingPathComponent("floe-self.sqlite")
        let owner = FloeMacSelfHostIdentity(displayName: "FloeMacSelfCoreTests")
        let provenance = try makeHostProvenance(databaseURL: databaseURL)
        let runtime = try FloeMacSelfRuntime(
            databaseURL: databaseURL,
            owner: owner,
            provenance: provenance,
            options: FloeMacSelfRuntimeOptions(privateTaskRootBaseURL: root)
        )
        do {
            _ = try await runtime.bootstrap()
            try await body(root, runtime)
            _ = try await runtime.shutdown(cancelActive: true, allowUnconfirmed: false, timeout: 30)
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record("Personal-task fixture retained at \(root.path): \(error)")
            throw error
        }
    }

    @Test("A personal task delegates against its per-task workspace; the completed result reads back after reopen and the child inherits the parent's ceiling")
    func personalTaskChildResultSurvivesReopen() async throws {
        let conversationID = UUID(), runID = UUID()
        let readCall = try ToolCall(
            id: "child-read-1",
            toolName: "workspace.readFile",
            argumentsJSON: Data(#"{"path":"."}"#.utf8),
            scope: .local
        )
        try await withPersonalTaskRuntime { root, runtime in
            // The default owner of an ordinary personal conversation:
            // idempotent per task, durable, keyed PrivateTasks/<task id>.
            let personal = try await runtime.ensurePersonalWorkspace(
                conversationID: conversationID, title: "Personal delegation task"
            )
            #expect(personal.kind == .privateTask)
            #expect(personal.internalRelativePath == "PrivateTasks/\(conversationID.uuidString)")
            let again = try await runtime.ensurePersonalWorkspace(
                conversationID: conversationID, title: "Personal delegation task"
            )
            #expect(again.id == personal.id)

            // Materialize the per-task leaf exactly like a host tool binding
            // does (owner-pinned), so the verified lease accepts the session.
            let personalRoot = root
                .appendingPathComponent("PrivateTasks/\(conversationID.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: personalRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )

            // Parent offers reads, the write tool and web.fetch; the child
            // inherits exactly that effective ceiling (no Mac-side allowlist).
            let project = WorkspaceFixtureExecutor(
                root: personalRoot,
                descriptors: Self.workspaceReadAllowlist.map(Self.readDescriptor)
                    + [Self.writeDescriptor, Self.parentWebFetchDescriptor]
            )
            let provider = try fixtureProvider(adapter: RoutedScriptedAdapter(rules: [
                GatedScriptRule(
                    matches: ScriptRoute.child(marker: Self.childMarker),
                    script: [.toolRequest(readCall), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: true
                ),
                GatedScriptRule(
                    matches: ScriptRoute.hasSubagentEvidence,
                    script: [.textDelta(.init(text: "personal task final answer")), .completed(.init(stopReason: .endTurn))],
                    parkBeforeServing: false
                ),
                GatedScriptRule(
                    matches: { !ScriptRoute.hasDelegateReceipt($0) },
                    script: [.toolRequest(try delegateCall(id: "delegate-1", background: true, task: "investigate the personal task workspace")), .completed(.init(stopReason: .toolUse))],
                    parkBeforeServing: false
                ),
            ], fallback: [
                .textDelta(.init(text: "personal task final answer")), .completed(.init(stopReason: .endTurn)),
            ]))

            let store = try await runtime.childRunStoring()
            let childRuntime = FloeMacChildSubagentRuntime(childStore: store)
            await runtime.installChildSubagentRuntime(childRuntime)
            let composite = FloeMacDelegatingProjectToolExecutor(
                project: project, runners: childRuntime.registry
            )
            var allowed = Self.workspaceReadAllowlist.union([Self.writeToolName, Self.webFetchToolName])
            allowed.formUnion(FloeMacDelegatingProjectToolExecutor.defaultDelegatingNames)
            let tools = FloeMacSelfToolBinding(
                executor: composite,
                policy: HumanApprovalPolicy(),
                gate: try CatastrophicActionGate.withBundledPatterns(),
                auditSink: nil,
                boundary: FloeMacSelfTaskBoundary(
                    workspaceID: personal.id,
                    workspaceRootURL: personalRoot,
                    allowedWorkspacePaths: [],
                    ownership: .nativeHost
                ),
                allowedToolNames: allowed,
                hostGate: FloeMacSelfHostGate(
                    workspaceID: personal.id,
                    workspaceRootPath: personalRoot.standardizedFileURL.path,
                    approvalPolicySource: "fixture.human-approval-policy.v1",
                    toolCorpusIdentifier: "fixture.tool-corpus.v1",
                    approvedToolNames: allowed,
                    issuer: "fixture-tests"
                )
            )
            await childRuntime.bindParentRun(
                runID: runID,
                provider: provider.provider,
                model: provider.model,
                adapter: provider.adapter,
                credentials: provider.credentials,
                projectExecutor: composite
            )

            let handle = try await runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: personal.id, runID: runID,
                             goal: "Delegate a personal investigation"),
                provider: provider,
                tools: tools
            )

            // Scoped approval: exactly the parent's delegate call needs a
            // decision; allowing it is single-use and scoped to this run.
            #expect(try await allowPending(handle: handle, callID: "delegate-1"))

            // The child is durably running; the read-only read it will make
            // settles without any further approval prompt (reads are not
            // side-effecting).
            let running = await eventually(timeout: 15) {
                guard let children = try? await childRuntime.durableChildren(parentRunID: runID),
                      let child = children.first else { return false }
                return children.count == 1 && child.conversationID == conversationID && child.state == .running
            }
            #expect(running)
            let noExtraCard = await eventually(timeout: 5) {
                await handle.snapshot()?.pendingApproval == nil
            }
            #expect(noExtraCard)
            let adapter = provider.adapter as? RoutedScriptedAdapter
            await adapter?.openChildGate()

            let terminal = try #require(await handle.waitForTerminal(timeout: 20))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            _ = try await handle.close()

            // The child executed its read through the canonical path with no
            // approval fence, and its wire catalog inherited the parent's
            // ceiling: reads + write + web.fetch in; delegation envelope out.
            #expect(project.executedCalls.contains { $0.id == readCall.id })
            let requests = try #require(adapter?.requests)
            let childRequests = requests.filter(ScriptRoute.child(marker: Self.childMarker))
            #expect(childRequests.count >= 2)
            let schemaNames = Set(childRequests[0].toolSchemas.map(\.name))
            #expect(Self.workspaceReadAllowlist.isSubset(of: schemaNames))
            #expect(schemaNames.contains(Self.writeToolName))
            #expect(!schemaNames.contains(DelegateTool.name))
            #expect(!schemaNames.contains(DelegateWaitTool.name))
            #expect(childRequests[1].toolResults.contains { $0.callID == readCall.id })
            #expect(requests.last?.messages.contains { $0.content.contains("subagent-evidence") } == true)

            await childRuntime.releaseParentRun(runID)

            // Reopen: a FRESH child runtime over the same durable store — the
            // exact shape the host builds after relaunch — reads the completed
            // child and its result without any live binding.
            let reopened = FloeMacChildSubagentRuntime(childStore: store)
            let history = try await reopened.durableChildren(conversationID: conversationID)
            #expect(history.count == 1)
            let completed = try #require(history.first)
            #expect(completed.state == .completed)
            #expect(completed.parentRunID == runID)
            #expect(completed.resultSummary?.contains("research has finished") == true)
        }
    }

    // MARK: - End-to-end: concurrent parents are independent

    @Test("Two concurrent parents delegate, surface and cancel children independently")
    func concurrentParentsStayIndependent() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Concurrent workspace")
            func makeParent(label: String) throws -> (binding: FloeMacSelfProviderBinding, adapter: RoutedScriptedAdapter) {
                let provider = ProviderProfile(
                    kind: .custom,
                    wireProtocol: .openAIResponses,
                    baseURL: URL(string: "https://localhost:8443")!,
                    displayName: "Fixture \(label)",
                    isEnabled: true
                )
                let model = ModelProfile(
                    providerID: provider.id,
                    remoteModelID: "fixture-model-\(label)",
                    displayName: "Fixture Model \(label)",
                    limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 8_192),
                    capabilities: [.text, .tools],
                    isEnabled: true
                )
                let adapter = RoutedScriptedAdapter(rules: [
                    // This parent's delegated child — parked on its own gate.
                    GatedScriptRule(
                        matches: ScriptRoute.child(marker: Self.childMarker),
                        script: [.textDelta(.init(text: "findings \(label)")), .completed(.init(stopReason: .endTurn))],
                        parkBeforeServing: true
                    ),
                    // Parent turn 1: delegate in the background.
                    GatedScriptRule(
                        matches: { !ScriptRoute.hasDelegateReceipt($0) },
                        script: [.toolRequest(try delegateCall(id: "delegate-\(label)", background: true, task: "investigation \(label)")), .completed(.init(stopReason: .toolUse))],
                        parkBeforeServing: false
                    ),
                ], fallback: [
                    // Any continuation turn after the delegate receipt.
                    .textDelta(.init(text: "final \(label)")), .completed(.init(stopReason: .endTurn)),
                ])
                return (FloeMacSelfProviderBinding(provider: provider, model: model, adapter: adapter, credentials: ProviderCredentials()), adapter)
            }
            let store = try await fixture.runtime.childRunStoring()
            let childRuntime = FloeMacChildSubagentRuntime(childStore: store)
            await fixture.runtime.installChildSubagentRuntime(childRuntime)

            func startParent(
                binding: FloeMacSelfProviderBinding,
                conversationID: UUID,
                runID: UUID
            ) async throws -> (handle: FloeMacSelfSessionHandle, tools: FloeMacSelfToolBinding) {
                let composite = FloeMacDelegatingProjectToolExecutor(
                    project: Self.fixtureExecutor(root: fixture.workspaceRoot),
                    runners: childRuntime.registry
                )
                var allowed = Self.workspaceReadAllowlist.union([Self.writeToolName, Self.webFetchToolName])
                allowed.formUnion(FloeMacDelegatingProjectToolExecutor.defaultDelegatingNames)
                let tools = try makeBinding(fixture: fixture, workspaceID: workspaceID, executor: composite, allowed: allowed)
                await childRuntime.bindParentRun(
                    runID: runID,
                    provider: binding.provider,
                    model: binding.model,
                    adapter: binding.adapter,
                    credentials: binding.credentials,
                    projectExecutor: composite
                )
                let handle = try await fixture.runtime.startSession(
                    agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate investigation"),
                    provider: binding,
                    tools: tools
                )
                return (handle, tools)
            }

            let parentA = try makeParent(label: "A")
            let parentB = try makeParent(label: "B")
            let conversationA = UUID(), runA = UUID()
            let conversationB = UUID(), runB = UUID()
            let sessionA = try await startParent(binding: parentA.binding, conversationID: conversationA, runID: runA)
            let sessionB = try await startParent(binding: parentB.binding, conversationID: conversationB, runID: runB)
            #expect(try await allowPending(handle: sessionA.handle, callID: "delegate-A"))
            #expect(try await allowPending(handle: sessionB.handle, callID: "delegate-B"))

            // Each parent sees exactly its own child.
            let bothActive = await eventually(timeout: 15) {
                guard let childrenA = try? await childRuntime.durableChildren(parentRunID: runA),
                      let childrenB = try? await childRuntime.durableChildren(parentRunID: runB) else { return false }
                return childrenA.count == 1 && childrenB.count == 1
                    && childrenA.first?.conversationID == conversationA
                    && childrenB.first?.conversationID == conversationB
            }
            #expect(bothActive)
            let childA = try #require(try await childRuntime.durableChildren(parentRunID: runA).first)
            let childB = try #require(try await childRuntime.durableChildren(parentRunID: runB).first)
            #expect(childA.id != childB.id)

            // Cancelling A's child never touches B's child.
            try await childRuntime.cancelChild(runID: runA, conversationID: conversationA, childID: childA.id)
            let aSettled = await eventually(timeout: 15) {
                guard let record = try? await childRuntime.durableChildren(parentRunID: runA)
                    .first(where: { $0.id == childA.id }) else { return false }
                return record.state == .cancelled
            }
            #expect(aSettled)
            #expect(try await childRuntime.durableChildren(parentRunID: runB)
                .first(where: { $0.id == childB.id })?.state == .running)

            await parentA.adapter.openChildGate()
            await parentB.adapter.openChildGate()
            let terminalA = try #require(await sessionA.handle.waitForTerminal(timeout: 20))
            let terminalB = try #require(await sessionB.handle.waitForTerminal(timeout: 20))
            #expect(terminalA.confirmed && terminalA.outcome == .completed)
            #expect(terminalB.confirmed && terminalB.outcome == .completed)
            _ = try await sessionA.handle.close()
            _ = try await sessionB.handle.close()

            // Each child used its own parent's selected provider identity.
            #expect(parentA.adapter.requests.allSatisfy {
                $0.provider.id == parentA.binding.provider.id && $0.model.id == parentA.binding.model.id
            })
            #expect(parentB.adapter.requests.allSatisfy {
                $0.provider.id == parentB.binding.provider.id && $0.model.id == parentB.binding.model.id
            })

            await childRuntime.releaseParentRun(runA)
            await childRuntime.releaseParentRun(runB)
            #expect(try await childRuntime.durableChildren(conversationID: conversationA).count == 1)
            #expect(try await childRuntime.durableChildren(conversationID: conversationB).count == 1)
        }
    }

    // MARK: - Helpers

    private func boundRequests(adapter: any ProviderAdapter) -> [ProviderStreamRequest] {
        (adapter as? RoutedScriptedAdapter)?.requests ?? []
    }
}
