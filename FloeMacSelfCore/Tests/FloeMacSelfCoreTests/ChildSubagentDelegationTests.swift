// SPDX-License-Identifier: MPL-2.0
//
// ChildSubagentDelegationTests — end-to-end behavioral tests for Mac owned
// background project subagents (shared iOS v1.8.57 delegation on Mac),
// driven through the real FloeMacSelfRuntime composition with a real SQLite
// database, the real ConversationRunService, the real SubagentRunnerRegistry
// and scripted provider adapters.
//
// Covered behavior:
// - a project Agent-style run delegates a background investigation child
//   that persists durably, uses the SELECTED provider/model, produces
//   structured output the parent settles into its final answer;
// - the child's wire catalog is confined to the read-only investigation
//   ceiling (explicit name allowlist + readOnly descriptor filter), never
//   the write tool or the delegation envelope itself;
// - cancelling ONE background child settles it durably as `.cancelled`
//   while its sibling completes, the parent still finishes by reconciling
//   the real outcomes, and the full child history remains readable after
//   the parent released its runner;
// - parent stop reaches exactly its own children (durable `.interrupted`);
// - two concurrent parents bind, surface and cancel independently;
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

    static func fixtureExecutor() -> RecordingToolExecutor {
        RecordingToolExecutor(descriptors: workspaceReadAllowlist.map(readDescriptor) + [writeDescriptor])
    }

    func makeBinding(
        fixture: SelfCoreFixture,
        workspaceID: UUID,
        executor: any ToolExecutor,
        allowed: Set<String>
    ) throws -> FloeMacSelfToolBinding {
        let gate = try CatastrophicActionGate.withBundledPatterns()
        let boundary = FloeMacSelfTaskBoundary(
            workspaceID: workspaceID,
            workspaceRootURL: fixture.workspaceRoot,
            allowedWorkspacePaths: [],
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
    /// several delegate calls are in flight, so the unique call id — never
    /// just "some pending card" — is what makes the wait correct.
    @discardableResult
    func approvePendingDelegate(handle: FloeMacSelfSessionHandle, callID: String) async throws -> Bool {
        let waiting = await eventually(timeout: 15) {
            let snapshot = await handle.snapshot()
            return snapshot?.pendingApproval?.toolCall.id == callID
        }
        guard waiting,
              let pending = await handle.snapshot()?.pendingApproval,
              pending.toolCall.id == callID else { return false }
        let command = approvalCommand(
            handle: handle,
            pending: pending,
            decision: .allow(
                scope: ApprovalScope(toolName: pending.toolCall.toolName, singleUse: true),
                expiresAt: nil
            )
        )
        return await handle.resolveApproval(command) == .accepted
    }

    /// Install a child runtime over the fixture database, bind the parent run
    /// (same selected provider, read-only child allowlist) and build the
    /// session tool binding with this runtime's private delegation tools.
    @discardableResult
    func bindParent(
        fixture: SelfCoreFixture,
        provider: FloeMacSelfProviderBinding,
        project: RecordingToolExecutor,
        workspaceID: UUID,
        conversationID: UUID,
        runID: UUID
    ) async throws -> (childRuntime: FloeMacChildSubagentRuntime, tools: FloeMacSelfToolBinding) {
        let store = try await fixture.runtime.childRunStoring()
        let childRuntime = FloeMacChildSubagentRuntime(childStore: store)
        await fixture.runtime.installChildSubagentRuntime(childRuntime)
        let composite = FloeMacDelegatingProjectToolExecutor(project: project, runners: childRuntime.registry)
        var allowed = Self.workspaceReadAllowlist.union([Self.writeToolName])
        allowed.formUnion(FloeMacDelegatingProjectToolExecutor.defaultDelegatingNames)
        let tools = try makeBinding(fixture: fixture, workspaceID: workspaceID, executor: composite, allowed: allowed)
        await childRuntime.bindParentRun(
            runID: runID,
            provider: provider.provider,
            model: provider.model,
            adapter: provider.adapter,
            credentials: provider.credentials,
            projectExecutor: composite,
            childToolAllowlist: Self.workspaceReadAllowlist
        )
        return (childRuntime, tools)
    }

    // MARK: - Read-only ceiling (unit level)

    @Test("Child executor exposes only the allowlisted read-only investigation tools")
    func readOnlyExecutorEnforcesAllowlistAndEffect() async throws {
        let project = Self.fixtureExecutor()
        let executor = FloeMacChildReadOnlyToolExecutor(
            wrapping: project,
            allowedNames: Self.workspaceReadAllowlist
        )
        #expect(executor.exposedToolNames == Self.workspaceReadAllowlist)
        #expect(Set(executor.allDescriptors.map(\.name)) == Self.workspaceReadAllowlist)
        #expect(executor.descriptor(named: Self.writeToolName) == nil)
        #expect(executor.descriptor(named: DelegateTool.name) == nil)
        // A read-only descriptor NOT in the explicit allowlist stays hidden.
        let extraRead = ToolCatalog.Descriptor(
            name: "workspace.extraRead",
            toolDescription: "not allowlisted",
            parametersJSON: #"{"type":"object","additionalProperties":false}"#,
            riskLabels: [.readsFiles],
            isSideEffecting: false,
            effect: .readOnly
        )
        let wider = RecordingToolExecutor(descriptors: [extraRead])
        let filtered = FloeMacChildReadOnlyToolExecutor(wrapping: wider, allowedNames: Self.workspaceReadAllowlist)
        #expect(filtered.exposedToolNames.isEmpty)
        // Fail-closed dispatch: a write call is denied, a read call executes.
        let denied = try await executor.execute(
            ToolCall(id: "w1", toolName: Self.writeToolName, argumentsJSON: Data("{}".utf8), scope: .local),
            context: ToolContext(runID: UUID(), toolCallID: "w1", scope: .local, cancellation: CancellationToken())
        )
        #expect(denied.status == .denied)
        let read = try await executor.execute(
            ToolCall(id: "r1", toolName: "workspace.readFile", argumentsJSON: Data(#"{"path":"."}"#.utf8), scope: .local),
            context: ToolContext(runID: UUID(), toolCallID: "r1", scope: .local, cancellation: CancellationToken())
        )
        #expect(read.status == .ok)
    }

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

    // MARK: - End-to-end: background child persists, uses selected provider, settles

    @Test("Background child persists, uses the selected provider, and its output settles into the parent")
    func backgroundChildEndToEnd() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Child workspace")
            let project = Self.fixtureExecutor()
            let base = fixture.makeProvider(scripts: []).binding
            let adapter = RoutedScriptedAdapter(rules: [
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
            ])
            let provider = FloeMacSelfProviderBinding(
                provider: base.provider, model: base.model,
                adapter: adapter, credentials: base.credentials
            )
            let conversationID = UUID(), runID = UUID()
            let bound = try await bindParent(
                fixture: fixture, provider: provider, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID
            )
            let handle = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate the investigation"),
                provider: provider,
                tools: bound.tools
            )
            #expect(try await approvePendingDelegate(handle: handle, callID: "delegate-1"))

            // Active phase: the child exists and is running in the durable store.
            let running = await eventually(timeout: 15) {
                guard let children = try? await bound.childRuntime.durableChildren(parentRunID: runID),
                      let child = children.first else { return false }
                return children.count == 1 && child.state == .running
            }
            #expect(running)
            await adapter.openChildGate()

            let terminal = try #require(await handle.waitForTerminal(timeout: 20))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            _ = try await handle.close()

            // Every provider request — the parent's AND the child's — used the
            // exact selected provider/model identity.
            let requests = adapter.requests
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

    // MARK: - End-to-end: child wire ceiling

    @Test("A delegated child's provider catalog carries only read-only investigation tools")
    func childWireCeilingExcludesWritesAndDelegation() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Ceiling workspace")
            let project = Self.fixtureExecutor()
            let readCall = try ToolCall(
                id: "child-read-1",
                toolName: "workspace.readFile",
                argumentsJSON: Data(#"{"path":"."}"#.utf8),
                scope: .local
            )
            let (provider, adapter) = fixture.makeProvider(scripts: [
                // Parent turn 1: foreground delegate (waits for the child).
                [.toolRequest(try delegateCall(id: "delegate-1", background: false, task: "read one file")), .completed(.init(stopReason: .toolUse))],
                // Child turn 1: call one read-only investigation tool.
                [.toolRequest(readCall), .completed(.init(stopReason: .toolUse))],
                // Child turn 2: final handoff.
                [.textDelta(.init(text: "child read the file")), .completed(.init(stopReason: .endTurn))],
                // Parent turn 2: final answer after the delegate receipt.
                [.textDelta(.init(text: "parent final answer")), .completed(.init(stopReason: .endTurn))],
            ])
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
            #expect(try await approvePendingDelegate(handle: handle, callID: "delegate-1"))
            let terminal = try #require(await handle.waitForTerminal(timeout: 20))
            #expect(terminal.confirmed)
            #expect(terminal.outcome == .completed)
            _ = try await handle.close()

            // The child turn that carried the read call (request index 1)
            // admitted the read tool schema — and nothing else mutating.
            let requests = adapter.requests
            #expect(requests.count == 4)
            let childRequest = requests[1]
            let schemaNames = Set(childRequest.toolSchemas.map(\.name))
            #expect(schemaNames.contains("workspace.readFile"))
            #expect(!schemaNames.contains(Self.writeToolName))
            #expect(!schemaNames.contains(DelegateTool.name))
            #expect(!schemaNames.contains(DelegateWaitTool.name))
            // The follow-up child request carried the pending call and its
            // result back to the model.
            #expect(requests[2].pendingToolCalls.map(\.id) == [readCall.id])
            #expect(requests[2].toolResults.contains { $0.callID == readCall.id })
            // The child really executed the read through the canonical path.
            #expect(project.executedCalls.contains { $0.id == readCall.id })
            // The delegate handoff returned a completed receipt to the parent.
            #expect(requests[3].toolResults.contains { $0.output.contains("status=ok") })
            await bound.childRuntime.releaseParentRun(runID)
        }
    }

    // MARK: - End-to-end: cancel one of two background children

    @Test("Cancelling one background child settles it cancelled, the sibling completes, history survives")
    func cancelOneBackgroundChildOfTwo() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Cancel workspace")
            let project = Self.fixtureExecutor()
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
            let binding = FloeMacSelfProviderBinding(
                provider: provider,
                model: model,
                adapter: adapter,
                credentials: ProviderCredentials()
            )
            let conversationID = UUID(), runID = UUID()
            let bound = try await bindParent(
                fixture: fixture, provider: binding, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID
            )
            let handle = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate both investigations"),
                provider: binding,
                tools: bound.tools
            )
            #expect(try await approvePendingDelegate(handle: handle, callID: "delegate-1"))
            #expect(try await approvePendingDelegate(handle: handle, callID: "delegate-2"))

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
            let requests = adapter.requests
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
            let project = Self.fixtureExecutor()
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
            let binding = FloeMacSelfProviderBinding(
                provider: provider,
                model: model,
                adapter: adapter,
                credentials: ProviderCredentials()
            )
            let conversationID = UUID(), runID = UUID()
            let bound = try await bindParent(
                fixture: fixture, provider: binding, project: project,
                workspaceID: workspaceID, conversationID: conversationID, runID: runID
            )
            let handle = try await fixture.runtime.startSession(
                agentRequest(conversationID: conversationID, workspaceID: workspaceID, runID: runID, goal: "Delegate then stop"),
                provider: binding,
                tools: bound.tools
            )
            #expect(try await approvePendingDelegate(handle: handle, callID: "delegate-1"))
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
                    project: Self.fixtureExecutor(),
                    runners: childRuntime.registry
                )
                var allowed = Self.workspaceReadAllowlist.union([Self.writeToolName])
                allowed.formUnion(FloeMacDelegatingProjectToolExecutor.defaultDelegatingNames)
                let tools = try makeBinding(fixture: fixture, workspaceID: workspaceID, executor: composite, allowed: allowed)
                await childRuntime.bindParentRun(
                    runID: runID,
                    provider: binding.provider,
                    model: binding.model,
                    adapter: binding.adapter,
                    credentials: binding.credentials,
                    projectExecutor: composite,
                    childToolAllowlist: Self.workspaceReadAllowlist
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
            #expect(try await approvePendingDelegate(handle: sessionA.handle, callID: "delegate-A"))
            #expect(try await approvePendingDelegate(handle: sessionB.handle, callID: "delegate-B"))

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
}
