// FloeAgentRuntimeTests — multi-client coordination on one shared environment.
//
// Parent run + delegated children can use the SAME execution environment
// (the TinyEMU Linux guest, a local backend, …). These tests exercise the
// runtime-side coordination that makes that safe:
//
//   * explicit, frozen environment identity (never a first-project fallback),
//   * a per-client session identity and a bounded client-scoped session token,
//   * per-client cancellation scopes (child cancel ≠ parent/sibling cancel),
//   * canonical mutation lease coverage for parent AND children,
//   * lifecycle operations that wait for active consumers instead of tearing
//     the backend down underneath them.
//
// They are barrier-start overlap tests: the first client is parked INSIDE the
// executor while the second is observed, so a serialized success is never
// presented as concurrency evidence.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeSecurity
import FloeTools
import FloeTestSupport
@testable import FloeProviders
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.SharedEnvironmentConcurrency")
struct SharedEnvironmentConcurrencyTests {
    // MARK: - Fixtures

    /// Parks one execution until the test explicitly releases it, so two
    /// clients can be observed overlapping (or queued) at a real boundary.
    actor EnvGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        private var entered = false

        var hasEntered: Bool { entered }

        func wait() async {
            entered = true
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Records the exact contexts the runtime built; can park its first call.
    final class ContextRecordingExecutor: ToolExecutor, @unchecked Sendable {
        struct Entry {
            var call: ToolCall
            var context: ToolContext
            var expectedAuthorizationIdentity: String?
        }

        private let storage = AsyncLock<[Entry]>([])
        private let descriptors: [String: ToolCatalog.Descriptor]
        private let gate: EnvGate?
        private let parkFirstCall: Bool
        private let counter = AsyncLock(0)

        init(
            descriptors: [String: ToolCatalog.Descriptor],
            gate: EnvGate? = nil,
            parkFirstCall: Bool = false
        ) {
            self.descriptors = descriptors
            self.gate = gate
            self.parkFirstCall = parkFirstCall
        }

        var entries: [Entry] { storage.withLock { $0 } }

        func descriptor(named name: String) -> ToolCatalog.Descriptor? { descriptors[name] }

        var allDescriptors: [ToolCatalog.Descriptor] {
            descriptors.values.sorted { $0.name < $1.name }
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
            storage.withLock {
                $0.append(Entry(
                    call: call, context: context,
                    expectedAuthorizationIdentity: expectedAuthorizationIdentity
                ))
            }
            if parkFirstCall, let gate {
                let index = counter.withLock { state -> Int in
                    state += 1
                    return state
                }
                if index == 1 { await gate.wait() }
            }
            return ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
        }
    }

    /// One real write tool whose FIRST execution parks, so a second write to
    /// the same target can be observed waiting on the canonical lease.
    final class LeaseWriteTool: AgentTool, @unchecked Sendable {
        struct Arguments: Decodable, Sendable {
            var path: String
            var text: String
        }

        static let name = "test.leasewrite"
        static let toolDescription = "Gated real write used to observe canonical mutation leases"
        static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string"},"text":{"type":"string"}},"required":["path","text"],"additionalProperties":false}"#
        static let riskLabels: Set<RiskLabel> = [.writesFiles]
        static let isSideEffecting = true
        static let toolEffect: ToolEffect = .mutating

        private let gate: EnvGate
        private let executed = AsyncLock<[String]>([])

        init(gate: EnvGate) {
            self.gate = gate
        }

        var executedPaths: [String] { executed.withLock { $0 } }

        func validate(_ args: Arguments) throws {
            guard !args.path.isEmpty else { throw FloeError.validationFailed("path must not be empty") }
        }

        func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
            try context.cancellation.throwIfCancelled()
            let entered = executed.withLock { state -> Int in
                state.append(args.path)
                return state.count
            }
            if entered == 1 { await gate.wait() }
            return ToolExecutionOutput(
                summary: "wrote \(args.path)", fullOutputSHA256: "d", exitStatus: 0
            )
        }
    }

    /// Routes `delegate` envelopes to the registry-backed executor (which runs
    /// the child through the real SubagentRunner) and everything else to the
    /// recording executor.
    final class DuallyRoutedExecutor: ToolExecutor, @unchecked Sendable {
        let primary: ContextRecordingExecutor
        let delegate: CatalogToolExecutor

        init(primary: ContextRecordingExecutor, delegate: CatalogToolExecutor) {
            self.primary = primary
            self.delegate = delegate
        }

        func descriptor(named name: String) -> ToolCatalog.Descriptor? {
            primary.descriptor(named: name) ?? delegate.descriptor(named: name)
        }

        var allDescriptors: [ToolCatalog.Descriptor] {
            // The runtime's offered catalog must include BOTH the tools the
            // recording executor serves and the registry-backed delegate
            // envelope entry.
            primary.allDescriptors + delegate.allDescriptors
        }

        func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            try await execute(call, expectedAuthorizationIdentity: nil, context: context)
        }

        func execute(
            _ call: ToolCall,
            expectedAuthorizationIdentity: String?,
            context: ToolContext
        ) async throws -> ToolResult {
            if call.toolName == "delegate" {
                return try await delegate.execute(
                    call, expectedAuthorizationIdentity: expectedAuthorizationIdentity, context: context
                )
            }
            return try await primary.execute(
                call, expectedAuthorizationIdentity: expectedAuthorizationIdentity, context: context
            )
        }
    }

    private func identity(
        _ runtime: FloeAgentRuntime,
        delegateCallID: String = "call-delegate"
    ) async -> ChildExecutionIdentity {
        ChildExecutionIdentity(
            parentRunID: await runtime.runID,
            rootTaskID: UUID(),
            delegateCallID: delegateCallID
        )
    }

    private func childContext(
        identity: ChildExecutionIdentity,
        allowedToolNames: Set<String>,
        workspaceRootURL: URL?,
        environmentID: String? = nil
    ) -> ToolContext {
        ToolContext(
            runID: identity.parentRunID,
            scope: .local,
            allowedToolNames: allowedToolNames,
            workspaceRootURL: workspaceRootURL,
            cancellation: CancellationToken(),
            childBudget: ChildBudgetContext(maximumIterations: 4, reserve: { true }, finish: {}),
            environmentID: environmentID,
            conversationID: identity.rootTaskID
        )
    }

    private func waitForGate(_ gate: EnvGate, attempts: Int = 300) async {
        var waited = 0
        while !(await gate.hasEntered), waited < attempts {
            try? await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
    }

    // MARK: - Environment identity

    @Test("the run's explicit environment identity reaches main and child call contexts, and never invents one")
    func environmentIdentityPropagates() async throws {
        let provider = TestFixtures.localhostProvider()
        let runID = UUID()
        let registry = ToolRunnerRegistry()
        let runners = SubagentRunnerRegistry()
        registerDelegateTool(registry: registry, runners: runners)
        let childExecutor = CatalogToolExecutor(runners: registry)

        let recording = ContextRecordingExecutor(descriptors: [
            "test.echo": .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        ])
        let mainAdapter = MockAdapter()
        let mainEcho = try TestFixtures.toolCall(id: "echo-main", toolName: "test.echo", arguments: "{}")
        let delegateCall = try TestFixtures.toolCall(
            id: "delegate-1", toolName: "delegate",
            arguments: #"{"task":"child echo","type":"explore"}"#
        )
        mainAdapter.script = [
            [.toolRequest(mainEcho), .toolRequest(delegateCall)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let childAdapter = MockAdapter()
        let childEcho = try TestFixtures.toolCall(id: "echo-child", toolName: "test.echo", arguments: "{}")
        childAdapter.script = [
            [.toolRequest(childEcho)],
            [.textDelta(.init(text: "child done")), .completed(.init(stopReason: .endTurn))]
        ]
        await runners.register(
            SubagentRunner(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                adapter: childAdapter,
                credentials: ProviderCredentials(),
                executor: childExecutor
            ),
            for: runID
        )
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                environmentID: "env-shared-1"
            ),
            adapter: mainAdapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: DuallyRoutedExecutor(primary: recording, delegate: childExecutor),
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore(),
            runID: runID
        )
        try await runtime.start(goal: "environment identity")

        let mainEntry = try #require(recording.entries.first { $0.call.id == "echo-main" })
        #expect(mainEntry.context.environmentID == "env-shared-1")
        #expect(mainEntry.context.clientSessionID == "run:\(runID.uuidString)")
        #expect(
            mainEntry.context.clientScopedSessionToken
                == "run:\(runID.uuidString)-echo-main"
        )

        // The delegated child's own call context carries the same explicit
        // environment, plus its own client identity — never the parent's.
        let childEntry = try #require(recording.entries.first { $0.call.id == "echo-child" })
        #expect(childEntry.context.environmentID == "env-shared-1")
        #expect(childEntry.context.childExecution?.identity.delegateCallID == "delegate-1")
        let sessionID = try #require(childEntry.context.clientSessionID)
        #expect(sessionID.hasPrefix("child:"))
        #expect(sessionID != mainEntry.context.clientSessionID)
        #expect(
            childEntry.context.clientScopedSessionToken != mainEntry.context.clientScopedSessionToken
        )
    }

    @Test("no environment identity is invented when the run does not declare one")
    func noFirstProjectFallback() async throws {
        let recording = ContextRecordingExecutor(descriptors: [
            "test.echo": .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        ])
        let provider = TestFixtures.localhostProvider()
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "e", toolName: "test.echo", arguments: "{}"))],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                environmentID: nil
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: recording,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
        try await runtime.start(goal: "no environment")
        let entry = try #require(recording.entries.first)
        #expect(entry.context.environmentID == nil)
    }

    @Test("the client-scoped session token is unique per client even for identical call ids")
    func clientScopedSessionTokenIsUnique() {
        let runID = UUID()
        let childID = UUID()
        let main = ToolContext(
            runID: runID, toolCallID: "call_1", cancellation: CancellationToken(),
            clientSessionID: "run:\(runID.uuidString)"
        )
        let childA = ToolContext(
            runID: runID, toolCallID: "call_1", cancellation: CancellationToken(),
            clientSessionID: "child:\(childID.uuidString)"
        )
        let childB = ToolContext(
            runID: runID, toolCallID: "call_1", cancellation: CancellationToken(),
            clientSessionID: "child:\(UUID().uuidString)"
        )
        #expect(main.clientScopedSessionToken != childA.clientScopedSessionToken)
        #expect(childA.clientScopedSessionToken != childB.clientScopedSessionToken)
        // The token stays a bounded printable token even for a pathological
        // call id (the guest channel rejects tokens beyond its ceiling).
        let long = ToolContext(
            runID: runID,
            toolCallID: String(repeating: "x", count: 400),
            cancellation: CancellationToken(),
            clientSessionID: "child:\(childID.uuidString)"
        )
        #expect(long.clientScopedSessionToken.utf8.count <= 96)
        #expect(long.clientScopedSessionToken.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7f })
    }

    // MARK: - Cancellation scopes

    @Test("child cancellation scopes are isolated from the parent and siblings, and the parent propagates")
    func childCancellationScopes() {
        let parent = CancellationToken()
        let childA = parent.derived()
        let childB = parent.derived()
        #expect(!childA.isCancelled && !childB.isCancelled)

        childA.cancel()
        #expect(childA.isCancelled)
        #expect(!childB.isCancelled, "cancelling one child must not cancel its sibling")
        #expect(!parent.isCancelled, "cancelling a child must not cancel the parent run")

        parent.cancel()
        #expect(childB.isCancelled, "parent cancellation must propagate to every descendant")
        // A token derived after the parent was cancelled is born cancelled:
        // no new work can slip past an inherited cancellation.
        let late = parent.derived()
        #expect(late.isCancelled)
    }

    // MARK: - Mutation leases across parent and children

    /// Adapter that yields the parent's write turn immediately and delays the
    /// final turn until the test releases it, so the child's settle and the
    /// parent's second checkpoint can never race.
    final class LeaseRaceAdapter: ProviderAdapter, @unchecked Sendable {
        let protocolKind: ModelProtocol = .openAIResponses
        private let state = AsyncLock<Int>(0)
        private let firstCall: @Sendable () -> ToolCall
        private let releaseSecondTurn: @Sendable () async -> Void

        init(firstCall: @escaping @Sendable () -> ToolCall, releaseSecondTurn: @escaping @Sendable () async -> Void) {
            self.firstCall = firstCall
            self.releaseSecondTurn = releaseSecondTurn
        }

        func stream(
            request: ProviderStreamRequest,
            credentials: ProviderCredentials
        ) -> AsyncThrowingStream<AgentEvent, Error> {
            let index = state.withLock { value -> Int in
                value += 1
                return value
            }
            return AsyncThrowingStream { continuation in
                Task {
                    if index == 1 {
                        continuation.yield(.toolRequest(firstCall()))
                    } else {
                        await releaseSecondTurn()
                        continuation.yield(.textDelta(.init(text: "done")))
                        continuation.yield(.completed(.init(stopReason: .endTurn)))
                    }
                    continuation.finish()
                }
            }
        }

        func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
    }

    @Test("a main-run write to a target a child holds serializes on the same canonical lease")
    func parentAndChildWritesSerialize() async throws {
        let gate = EnvGate()
        let writeTool = LeaseWriteTool(gate: gate)
        let registry = ToolRunnerRegistry()
        registry.register(writeTool)
        let executor = CatalogToolExecutor(runners: registry)
        let provider = TestFixtures.localhostProvider()
        let parentWrite = try TestFixtures.toolCall(
            id: "main-w", toolName: "test.leasewrite",
            arguments: #"{"path":"same.txt","text":"main"}"#
        )
        let childSettled = EnvGate()
        let adapter = LeaseRaceAdapter(
            firstCall: { parentWrite },
            releaseSecondTurn: { await childSettled.wait() }
        )
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: ["test.leasewrite"],
                workspaceRootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
        // The MAIN run issues its write first and parks inside the executor
        // while holding the canonical target lease.
        let parentTask = Task { try await runtime.start(goal: "main write") }
        await waitForGate(gate)
        #expect(await gate.hasEntered)

        // A child then writes the SAME file: it must queue on the same lease.
        let childWrite = try TestFixtures.toolCall(
            id: "child-w", toolName: "test.leasewrite",
            arguments: #"{"path":"same.txt","text":"child"}"#
        )
        let childIdentity = await identity(runtime, delegateCallID: "d-child")
        let childTask = Task {
            await runtime.dispatchChildTool(
                childWrite,
                identity: childIdentity,
                childContext: self.childContext(
                    identity: childIdentity,
                    allowedToolNames: ["test.leasewrite"],
                    workspaceRootURL: URL(fileURLWithPath: NSTemporaryDirectory())
                )
            )
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(
            writeTool.executedPaths == ["same.txt"],
            "the child write must wait for the main run's lease"
        )

        // Release the main write; only then may the child acquire the lease
        // and execute.
        await gate.open()
        let childResult = await childTask.value
        #expect(childResult.status == .ok, "\(childResult.outputSummary)")
        #expect(writeTool.executedPaths == ["same.txt", "same.txt"])
        await childSettled.open()
        try await parentTask.value
    }

    // MARK: - Trusted child context through the canonical dispatch path

    @Test("a delegated call carries the child's own token, environment, client and skill provenance to the executor")
    func childContextStateReachesExecutor() async throws {
        let recording = ContextRecordingExecutor(descriptors: [
            "test.echo": .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        ])
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: TestFixtures.localhostProvider().id),
                environmentID: "env-child-state"
            ),
            adapter: MockAdapter(),
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: recording,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
        let childToken = CancellationToken()
        let identity = await identity(runtime, delegateCallID: "d-state")
        let childContext = ToolContext(
            runID: await runtime.runID,
            scope: .local,
            activeSkillIDs: ["floe-child-guide"],
            allowedToolNames: ["test.echo"],
            cancellation: childToken,
            childBudget: ChildBudgetContext(maximumIterations: 2, reserve: { true }, finish: {}),
            environmentID: "env-child-state",
            conversationID: identity.rootTaskID,
            // Deliberately spoofed: the runtime must ignore a passed client
            // identity for a delegated call and derive the real one from the
            // trusted child identity.
            clientSessionID: "spoofed-session",
            frozenEffectiveCatalogNames: ["test.echo"]
        )
        let call = try TestFixtures.toolCall(id: "state-1", toolName: "test.echo", arguments: "{}")
        let result = await runtime.dispatchChildTool(call, identity: identity, childContext: childContext)
        #expect(result.status == .ok)
        let entry = try #require(recording.entries.first)
        // The executor sees the CHILD's actual cancellation scope (so
        // cancelling this child stops only its own calls)…
        #expect(entry.context.cancellation === childToken)
        // …the child's explicit environment, client identity and skill
        // provenance…
        #expect(entry.context.environmentID == "env-child-state")
        #expect(entry.context.clientSessionID == "child:\(identity.childID.uuidString)")
        #expect(entry.context.activeSkillIDs == ["floe-child-guide"])
        // …while the trusted child identity and the parent's authority are
        // intact.
        #expect(entry.context.childExecution?.identity == identity)
        #expect(entry.context.temporaryReadOnly == false)

        // Cancelling the child token leaves the parent run's token alive: a
        // sibling client is unaffected.
        childToken.cancel()
        #expect(childToken.isCancelled)
        #expect(await runtime.state.name == "idle")
    }

    @Test("a delegated context cannot retarget the run's environment binding")
    func childEnvironmentBindingIsValidated() async throws {
        let recording = ContextRecordingExecutor(descriptors: [
            "test.echo": .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        ])
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: TestFixtures.localhostProvider().id),
                environmentID: "env-bound"
            ),
            adapter: MockAdapter(),
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: recording,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
        let identity = await identity(runtime, delegateCallID: "d-env")
        let forged = ToolContext(
            runID: await runtime.runID,
            allowedToolNames: ["test.echo"],
            cancellation: CancellationToken(),
            childBudget: ChildBudgetContext(maximumIterations: 2, reserve: { true }, finish: {}),
            environmentID: "env-somewhere-else"
        )
        let call = try TestFixtures.toolCall(id: "env-1", toolName: "test.echo", arguments: "{}")
        let result = await runtime.dispatchChildTool(call, identity: identity, childContext: forged)
        #expect(result.status == .denied)
        #expect(result.outputSummary.contains("env-somewhere-else"))
        #expect(result.outputSummary.contains("env-bound"))
        #expect(recording.entries.isEmpty)
    }

    @Test("identical model call ids and idempotency keys across parent and two children never collide")
    func identicalProviderCallIDsDoNotCollide() async throws {
        let recording = ContextRecordingExecutor(descriptors: [
            "test.echo": .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        ])
        let audit = MockAuditSink()
        let adapter = MockAdapter()
        // The parent run emits the same provider call id and idempotency key
        // that both children will use.
        var parentCall = try ToolCall(
            id: "call_1",
            toolName: "test.echo",
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
        parentCall.idempotencyKey = "dup-key"
        adapter.script = [
            [.toolRequest(parentCall)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: TestFixtures.localhostProvider().id),
                environmentID: "env-shared"
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: recording,
            auditSink: audit,
            checkpointStore: MockCheckpointStore()
        )
        func childCall() throws -> ToolCall {
            var call = try ToolCall(
                id: "call_1",
                toolName: "test.echo",
                argumentsJSON: Data("{}".utf8),
                scope: .local
            )
            call.idempotencyKey = "dup-key"
            return call
        }
        // Two distinct child clients with DIFFERENT identities but identical
        // provider call ids/keys, plus the parent run.
        let identityA = await identity(runtime, delegateCallID: "d-A")
        let identityB = await identity(runtime, delegateCallID: "d-B")
        let resultA = await runtime.dispatchChildTool(
            try childCall(), identity: identityA,
            childContext: childContext(
                identity: identityA, allowedToolNames: ["test.echo"],
                workspaceRootURL: nil, environmentID: "env-shared"
            )
        )
        let resultB = await runtime.dispatchChildTool(
            try childCall(), identity: identityB,
            childContext: childContext(
                identity: identityB, allowedToolNames: ["test.echo"],
                workspaceRootURL: nil, environmentID: "env-shared"
            )
        )
        try await runtime.start(goal: "parent echo")
        #expect(resultA.status == .ok, "\(resultA.outputSummary)")
        #expect(resultB.status == .ok, "\(resultB.outputSummary)")
        #expect(!resultA.outputSummary.contains("duplicate"))
        #expect(!resultB.outputSummary.contains("duplicate"))
        // Provider-visible feedback keeps the ORIGINAL model call id for each
        // client, while the runtime correlates execution by run/child identity.
        #expect(resultA.callID == "call_1")
        #expect(resultB.callID == "call_1")
        // All three clients really executed; none was silently skipped as a
        // duplicate of another client's identical id/key.
        #expect(recording.entries.count == 3)
        #expect(recording.entries.allSatisfy { $0.call.id == "call_1" })
        // Each client's execution was correlated with its own identity: the
        // two child entries have distinct child identities and distinct
        // client session ids.
        let childEntries = recording.entries.filter { $0.context.childExecution != nil }
        #expect(childEntries.count == 2)
        let childIDs = Set(childEntries.compactMap { $0.context.childExecution?.identity.childID })
        #expect(childIDs == [identityA.childID, identityB.childID])
        let sessionIDs = Set(childEntries.compactMap(\.context.clientSessionID))
        #expect(sessionIDs.count == 2)
        // The audit trail recorded all three executions (no lost or merged
        // entry under the shared provider id).
        let allowed = audit.entries.filter { $0.decision.hasPrefix("allow") }
        #expect(allowed.count == 3)
    }

    // MARK: - Environment lifecycle gate

    @Test("consumer admission waits for an active lifecycle lease and admits concurrent consumers after it clears")
    func consumerAdmissionRespectsLifecycleLease() async throws {
        let coordinator = SharedEnvironmentCoordinator()
        let lifecycle = try await coordinator.acquireLifecycle(
            environmentID: "env-L", label: "environment.hardRestartLinux", timeout: 0.2
        )
        // A late consumer must NOT be admitted while the lifecycle lease is
        // held: it is suspended, not dispatched.
        let admitted = AsyncLock(false)
        let lateConsumer = Task {
            let ticket = try await coordinator.acquireConsumer(
                environmentID: "env-L", label: "exec.shell", timeout: 5
            )
            admitted.withLock { $0 = true }
            return ticket
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(admitted.withLock { $0 } == false, "a late consumer must wait for the lifecycle lease")
        #expect(await coordinator.activeConsumerCount(environmentID: "env-L") == 0)
        // The same admission fails boundedly with the real holder when the
        // wait budget is exhausted…
        do {
            _ = try await coordinator.acquireConsumer(
                environmentID: "env-L", label: "exec.shell", timeout: 0.15
            )
            Issue.record("expected a bounded refusal while the lifecycle lease is held")
        } catch let busy as EnvironmentBusyError {
            #expect(busy.message.contains("hardRestartLinux"))
        }
        // …and a cancelled caller aborts instead of hanging.
        let cancelled = CancellationToken()
        cancelled.cancel()
        do {
            _ = try await coordinator.acquireConsumer(
                environmentID: "env-L", label: "exec.shell", timeout: 5, cancellation: cancelled
            )
            Issue.record("expected cancellation to abort consumer admission")
        } catch let error as FloeError {
            #expect(error == .cancelled)
        }

        // Releasing the lifecycle lease admits the waiting consumer…
        await coordinator.releaseLifecycle(lifecycle)
        let first = try await lateConsumer.value
        #expect(admitted.withLock { $0 })
        // …and ordinary consumers remain concurrent with each other.
        let second = try await coordinator.acquireConsumer(
            environmentID: "env-L", label: "exec.localPython", timeout: 0.2
        )
        #expect(await coordinator.activeConsumerCount(environmentID: "env-L") == 2)
        await coordinator.endConsumer(first)
        await coordinator.endConsumer(second)
        #expect(await coordinator.isIdle())
    }

    @Test("a lifecycle operation waits bounded for active consumers and refuses with their real labels")
    func lifecycleWaitsForConsumers() async throws {
        let coordinator = SharedEnvironmentCoordinator()
        let consumer = await coordinator.beginConsumer(environmentID: "env-A", label: "exec.shell [child:1]")
        #expect(await coordinator.activeConsumerCount(environmentID: "env-A") == 1)
        do {
            _ = try await coordinator.acquireLifecycle(
                environmentID: "env-A", label: "environment.hardRestartLinux", timeout: 0.15
            )
            Issue.record("expected an EnvironmentBusyError while a consumer is active")
        } catch let busy as EnvironmentBusyError {
            #expect(busy.message.contains("exec.shell [child:1]"))
            #expect(busy.message.contains("hardRestartLinux"))
        }
        await coordinator.endConsumer(consumer)
        let ticket = try await coordinator.acquireLifecycle(
            environmentID: "env-A", label: "environment.hardRestartLinux", timeout: 0.15
        )
        // A second lifecycle operation on the same environment waits; a
        // cancelled caller aborts instead of hanging.
        do {
            _ = try await coordinator.acquireLifecycle(
                environmentID: "env-A", label: "environment.stopLinux", timeout: 0.15
            )
            Issue.record("expected the second lifecycle operation to wait and time out")
        } catch let busy as EnvironmentBusyError {
            #expect(busy.message.contains("another lifecycle operation"))
        }
        let cancelled = CancellationToken()
        cancelled.cancel()
        do {
            _ = try await coordinator.acquireLifecycle(
                environmentID: "env-A", label: "environment.stopLinux",
                timeout: 5, cancellation: cancelled
            )
            Issue.record("expected cancellation to abort the lifecycle wait")
        } catch let error as FloeError {
            #expect(error == .cancelled)
        }
        await coordinator.releaseLifecycle(ticket)
        #expect(await coordinator.isIdle())
    }

    @Test("the runtime refuses a lifecycle call while a child consumer is in flight, without executing it")
    func runtimeLifecycleRefusesUnderActiveConsumer() async throws {
        let gate = EnvGate()
        let executor = ContextRecordingExecutor(
            descriptors: [
                "exec.shell": .init(
                    name: "exec.shell", riskLabels: [.executesLocalCode],
                    isSideEffecting: true, effect: .mutating
                ),
                "environment.hardRestartLinux": .init(
                    name: "environment.hardRestartLinux", riskLabels: [.executesLocalCode],
                    isSideEffecting: true, effect: .mutating
                )
            ],
            gate: gate,
            parkFirstCall: true
        )
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: TestFixtures.localhostProvider().id),
                allowedToolNames: ["exec.shell", "environment.hardRestartLinux"],
                environmentID: "env-VM",
                environmentLifecycleWait: 0.2
            ),
            adapter: MockAdapter(),
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
        // A child consumer parks inside the executor and stays registered as
        // an active consumer of the same environment.
        let childCall = try TestFixtures.toolCall(
            id: "child-shell", toolName: "exec.shell",
            arguments: #"{"command":"sleep 1"}"#
        )
        let childIdentity = await identity(runtime, delegateCallID: "d-shell")
        let childTask = Task {
            await runtime.dispatchChildTool(
                childCall,
                identity: childIdentity,
                childContext: self.childContext(
                    identity: childIdentity,
                    allowedToolNames: ["exec.shell", "environment.hardRestartLinux"],
                    workspaceRootURL: nil,
                    environmentID: "env-VM"
                )
            )
        }
        await waitForGate(gate)
        #expect(await gate.hasEntered)

        // A second client (another delegated child of the same task) asks for
        // a hard restart. The runtime must refuse it, bounded, naming the real
        // active consumer — and never reach the executor.
        let restartCall = try TestFixtures.toolCall(
            id: "restart-1", toolName: "environment.hardRestartLinux", arguments: #"{"vcpus":2}"#
        )
        let restartIdentity = await identity(runtime, delegateCallID: "d-restart")
        let restartResult = await runtime.dispatchChildTool(
            restartCall,
            identity: restartIdentity,
            childContext: childContext(
                identity: restartIdentity,
                allowedToolNames: ["exec.shell", "environment.hardRestartLinux"],
                workspaceRootURL: nil,
                environmentID: "env-VM"
            )
        )
        #expect(restartResult.status == .failed)
        #expect(restartResult.outputSummary.contains("busy"))
        #expect(restartResult.outputSummary.contains("exec.shell"))
        #expect(!executor.entries.contains { $0.call.id == "restart-1" })

        await gate.open()
        let childResult = await childTask.value
        #expect(childResult.status == .ok)
        #expect(executor.entries.contains { $0.call.id == "child-shell" })
    }

    @Test("a runtime consumer call cannot dispatch while a lifecycle operation owns the environment")
    func runtimeConsumerWaitsForLifecycle() async throws {
        let gate = EnvGate()
        let executor = ContextRecordingExecutor(
            descriptors: [
                "exec.shell": .init(
                    name: "exec.shell", riskLabels: [.executesLocalCode],
                    isSideEffecting: true, effect: .mutating
                ),
                "environment.hardRestartLinux": .init(
                    name: "environment.hardRestartLinux", riskLabels: [.executesLocalCode],
                    isSideEffecting: true, effect: .mutating
                )
            ],
            gate: gate,
            parkFirstCall: true
        )
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: TestFixtures.localhostProvider(),
                model: TestFixtures.testModel(providerID: TestFixtures.localhostProvider().id),
                allowedToolNames: ["exec.shell", "environment.hardRestartLinux"],
                environmentID: "env-VM",
                environmentLifecycleWait: 0.2
            ),
            adapter: MockAdapter(),
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
        // The lifecycle operation owns the environment and parks inside the
        // executor.
        let restartCall = try TestFixtures.toolCall(
            id: "restart-owner", toolName: "environment.hardRestartLinux", arguments: #"{"vcpus":2}"#
        )
        let restartIdentity = await identity(runtime, delegateCallID: "d-restart")
        let restartTask = Task {
            await runtime.dispatchChildTool(
                restartCall,
                identity: restartIdentity,
                childContext: self.childContext(
                    identity: restartIdentity,
                    allowedToolNames: ["exec.shell", "environment.hardRestartLinux"],
                    workspaceRootURL: nil,
                    environmentID: "env-VM"
                )
            )
        }
        await waitForGate(gate)
        #expect(await gate.hasEntered)

        // A consumer arriving mid-lifecycle must not dispatch: bounded wait,
        // then a truthful refusal naming the lifecycle holder.
        let shellCall = try TestFixtures.toolCall(
            id: "late-shell", toolName: "exec.shell", arguments: #"{"command":"echo hi"}"#
        )
        let shellIdentity = await identity(runtime, delegateCallID: "d-late")
        let shellResult = await runtime.dispatchChildTool(
            shellCall,
            identity: shellIdentity,
            childContext: childContext(
                identity: shellIdentity,
                allowedToolNames: ["exec.shell", "environment.hardRestartLinux"],
                workspaceRootURL: nil,
                environmentID: "env-VM"
            )
        )
        #expect(shellResult.status == .failed)
        #expect(shellResult.outputSummary.contains("busy") || shellResult.outputSummary.contains("restarting"))
        #expect(shellResult.outputSummary.contains("hardRestartLinux"))
        #expect(!executor.entries.contains { $0.call.id == "late-shell" })

        await gate.open()
        let restartResult = await restartTask.value
        #expect(restartResult.status == .ok)
        // Once the lifecycle clears, a consumer dispatches normally.
        let retryCall = try TestFixtures.toolCall(
            id: "later-shell", toolName: "exec.shell", arguments: #"{"command":"echo hi"}"#
        )
        let retryIdentity = await identity(runtime, delegateCallID: "d-retry")
        let retryResult = await runtime.dispatchChildTool(
            retryCall,
            identity: retryIdentity,
            childContext: childContext(
                identity: retryIdentity,
                allowedToolNames: ["exec.shell", "environment.hardRestartLinux"],
                workspaceRootURL: nil,
                environmentID: "env-VM"
            )
        )
        #expect(retryResult.status == .ok)
    }

    @Test("a delegation envelope never holds an environment consumer, so the child's own lifecycle call executes")
    func delegateEnvelopeDoesNotHoldEnvironmentConsumer() async throws {
        let provider = TestFixtures.localhostProvider()
        let runID = UUID()
        let registry = ToolRunnerRegistry()
        let runners = SubagentRunnerRegistry()
        registerDelegateTool(registry: registry, runners: runners)
        let childExecutor = CatalogToolExecutor(runners: registry)

        let recording = ContextRecordingExecutor(descriptors: [
            "environment.hardRestartLinux": .init(
                name: "environment.hardRestartLinux", riskLabels: [.executesLocalCode],
                isSideEffecting: true, effect: .mutating
            )
        ])
        let mainAdapter = MockAdapter()
        let delegateCall = try TestFixtures.toolCall(
            id: "delegate-lifecycle", toolName: "delegate",
            arguments: #"{"task":"restart the shared environment","type":"execute","maxIterations":4}"#
        )
        mainAdapter.script = [
            [.toolRequest(delegateCall)],
            [.textDelta(.init(text: "parent done")), .completed(.init(stopReason: .endTurn))]
        ]
        let childAdapter = MockAdapter()
        let restartCall = try TestFixtures.toolCall(
            id: "child-restart", toolName: "environment.hardRestartLinux",
            arguments: #"{"vcpus":2}"#
        )
        childAdapter.script = [
            [.toolRequest(restartCall)],
            [.textDelta(.init(text: "child done")), .completed(.init(stopReason: .endTurn))]
        ]
        await runners.register(
            SubagentRunner(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                adapter: childAdapter,
                credentials: ProviderCredentials(),
                executor: childExecutor
            ),
            for: runID
        )
        let audit = MockAuditSink()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: ["delegate", "environment.hardRestartLinux"],
                environmentID: "env-delegate-lifecycle",
                environmentLifecycleWait: 0.3
            ),
            adapter: mainAdapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: DuallyRoutedExecutor(primary: recording, delegate: childExecutor),
            auditSink: audit,
            checkpointStore: MockCheckpointStore(),
            runID: runID
        )
        try await runtime.start(goal: "delegate a lifecycle call")

        // The child's own lifecycle call really executed through the real
        // nested envelope. The ancestor delegation must NOT hold a consumer
        // ticket for the child's whole lifetime: that would make this
        // legitimate call wait out the bounded budget and fail as busy.
        let restartEntry = try #require(recording.entries.first { $0.call.id == "child-restart" })
        #expect(restartEntry.context.environmentID == "env-delegate-lifecycle")
        #expect(restartEntry.context.childExecution?.identity.delegateCallID == "delegate-lifecycle")
        #expect(childAdapter.requests.count == 2, "the child loop really ran inside the envelope")
        let restartDecision = audit.entries.first { $0.toolName == "environment.hardRestartLinux" }?.decision
        #expect(restartDecision?.hasPrefix("allow") == true, "child lifecycle call must not be refused busy")
        #expect(
            !audit.entries.contains {
                $0.toolName == "environment.hardRestartLinux"
                    && $0.decision == "deny:environment-busy"
            }
        )
    }

    @Test("two lifecycle operations on distinct environments never block each other")
    func distinctEnvironmentsStayIndependent() async throws {
        let coordinator = SharedEnvironmentCoordinator()
        // env-A lifecycle held; a consumer runs on env-B.
        let ticketA = try await coordinator.acquireLifecycle(
            environmentID: "env-A", label: "environment.hardRestartLinux", timeout: 0.15
        )
        let consumerB = await coordinator.beginConsumer(environmentID: "env-B", label: "exec.shell")
        // A lifecycle op on env-C is unaffected by env-A's exclusive ticket
        // and by env-B's consumer: distinct environments stay independent.
        let ticketC = try await coordinator.acquireLifecycle(
            environmentID: "env-C", label: "environment.stopLinux", timeout: 0.15
        )
        #expect(await coordinator.activeConsumerCount(environmentID: "env-A") == 0)
        #expect(await coordinator.activeConsumerCount(environmentID: "env-B") == 1)
        // The active env-B consumer does NOT block env-A's lifecycle release.
        await coordinator.releaseLifecycle(ticketA)
        await coordinator.releaseLifecycle(ticketC)
        // …and env-B's consumer still blocks an env-B lifecycle op.
        do {
            _ = try await coordinator.acquireLifecycle(
                environmentID: "env-B", label: "environment.stopLinux", timeout: 0.15
            )
            Issue.record("expected env-B's active consumer to block its lifecycle op")
        } catch let busy as EnvironmentBusyError {
            #expect(busy.message.contains("exec.shell"))
        }
        await coordinator.endConsumer(consumerB)
        #expect(await coordinator.isIdle())
    }
}
