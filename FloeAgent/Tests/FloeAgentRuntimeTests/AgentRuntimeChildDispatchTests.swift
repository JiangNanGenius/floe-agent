// FloeAgentRuntimeTests — canonical child dispatch through the real runtime.
//
// These tests exercise the ACTUAL dispatch seam: `dispatchChildTool` on a
// live FloeAgentRuntime with a real approval policy, real audit sink, real
// runtime-issued authority and real mutation leases. Nothing here is a
// policy-helper mock: the executor sees the context the runtime built.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeSecurity
import FloeTools
import FloeTestSupport
@testable import FloeProviders
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.ChildDispatch")
struct AgentRuntimeChildDispatchTests {
    // MARK: - Harness

    /// Records every executed call with the exact ToolContext the runtime
    /// built, so tests can assert reachable authority, grants and identity.
    final class CapturingExecutor: ToolExecutor, @unchecked Sendable {
        struct Entry {
            var call: ToolCall
            var context: ToolContext
        }

        private let storage = AsyncLock<[Entry]>([])
        private let descriptors: [String: ToolCatalog.Descriptor]

        init(descriptors: [String: ToolCatalog.Descriptor]) {
            self.descriptors = descriptors
        }

        var entries: [Entry] { storage.withLock { $0 } }

        func descriptor(named name: String) -> ToolCatalog.Descriptor? { descriptors[name] }

        var allDescriptors: [ToolCatalog.Descriptor] {
            descriptors.values.sorted { $0.name < $1.name }
        }

        func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            try context.cancellation.throwIfCancelled()
            storage.withLock { $0.append(Entry(call: call, context: context)) }
            return ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
        }
    }

    /// Executor whose first execution parks on a gate, so a second conflicting
    /// child call can be observed while the first still holds the lease.
    final class GatedExecutor: ToolExecutor, @unchecked Sendable {
        private let storage = AsyncLock<[String]>([])
        private let gate: GatedExecutorGate
        private let descriptors: [String: ToolCatalog.Descriptor]

        init(descriptors: [String: ToolCatalog.Descriptor], gate: GatedExecutorGate) {
            self.descriptors = descriptors
            self.gate = gate
        }

        var executedOrder: [String] { storage.withLock { $0 } }

        func descriptor(named name: String) -> ToolCatalog.Descriptor? { descriptors[name] }

        var allDescriptors: [ToolCatalog.Descriptor] {
            descriptors.values.sorted { $0.name < $1.name }
        }

        func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            let index = storage.withLock { state -> Int in
                state.append(call.id)
                return state.count
            }
            if index == 1 { await gate.wait() }
            return ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
        }
    }

    actor GatedExecutorGate {
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

    /// A real read-only tool that parks until the test releases it, so a
    /// sibling can be observed exchanging a message while this child is still
    /// in flight.
    struct SlowEchoTool: AgentTool {
        struct Arguments: Decodable, Sendable {}

        static let name = "test.echo"
        static let toolDescription = "Slow read-only echo used to hold a child in flight"
        static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
        static let riskLabels: Set<RiskLabel> = []
        static let isSideEffecting = false

        let gate: GatedExecutorGate

        func validate(_ args: Arguments) throws {}

        func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
            try context.cancellation.throwIfCancelled()
            await gate.wait()
            return ToolExecutionOutput(summary: "echo", fullOutputSHA256: "d", exitStatus: 0)
        }
    }

    /// One provider adapter serving two live children at once. It routes by
    /// the subtask text and drives child A through the real `delegate.peers`
    /// discovery + `delegate.message` send, then parks child B in the gated
    /// tool so the message is delivered at B's next safe boundary.
    final class TwoChildAdapter: ProviderAdapter, @unchecked Sendable {
        let protocolKind: ModelProtocol = .openAIResponses
        private let storage = AsyncLock<[ProviderStreamRequest]>([])

        var requests: [ProviderStreamRequest] { storage.withLock { $0 } }

        func requests(forSide marker: String) -> [ProviderStreamRequest] {
            requests.filter { Self.text(of: $0).contains(marker) }
        }

        private static func text(of request: ProviderStreamRequest) -> String {
            request.effectiveMessages
                .flatMap(\.content)
                .compactMap { part -> String? in
                    if case .text(let text) = part { return text }
                    return nil
                }
                .joined(separator: "\n")
        }

        private static func firstPeerID(_ output: String) -> String? {
            guard let start = output.firstIndex(of: "{"),
                  let end = output.lastIndex(of: "}") else { return nil }
            let json = String(output[start...end])
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let peers = object["peers"] as? [[String: Any]] else { return nil }
            return peers.compactMap { $0["childID"] as? String }.first
        }

        func stream(
            request: ProviderStreamRequest,
            credentials: ProviderCredentials
        ) -> AsyncThrowingStream<AgentEvent, Error> {
            let priorRequests = storage.withLock { state -> [ProviderStreamRequest] in
                state.append(request)
                return state.dropLast()
            }
            let text = Self.text(of: request)
            let isA = text.contains("A-SIDE-TASK")
            return AsyncThrowingStream { continuation in
                if isA {
                    let results = Array(request.toolResults)
                    let messaged = results.contains { $0.callID == "msg-1" }
                    let peersOutput = results.last { $0.callID.hasPrefix("peers-") }?.output
                    if messaged {
                        continuation.yield(.textDelta(.init(text: "A finished after messaging")))
                        continuation.yield(.completed(.init(stopReason: .endTurn)))
                    } else if let peersOutput, let target = Self.firstPeerID(peersOutput) {
                        let arguments = Data(
                            #"{"to":"\#(target)","message":"SIBLING-CLAIM file a.md is mine"}"#.utf8
                        )
                        continuation.yield(.toolRequest(try! ToolCall(
                            id: "msg-1", toolName: "delegate.message",
                            argumentsJSON: arguments, scope: .local
                        )))
                    } else {
                        let attempts = results.filter { $0.callID.hasPrefix("peers-") }.count
                        continuation.yield(.toolRequest(try! ToolCall(
                            id: "peers-\(attempts + 1)", toolName: "delegate.peers",
                            argumentsJSON: Data("{}".utf8), scope: .local
                        )))
                    }
                } else {
                    let ownRequests = priorRequests.filter { Self.text(of: $0).contains("B-SIDE-TASK") }
                    if ownRequests.isEmpty {
                        continuation.yield(.toolRequest(try! ToolCall(
                            id: "echo-1", toolName: "test.echo",
                            argumentsJSON: Data("{}".utf8), scope: .local
                        )))
                    } else {
                        continuation.yield(.textDelta(.init(text: "B finished")))
                        continuation.yield(.completed(.init(stopReason: .endTurn)))
                    }
                }
                continuation.finish()
            }
        }

        func listModels(
            provider: ProviderProfile,
            credentials: ProviderCredentials
        ) async throws -> [ModelProfile] { [] }
    }

    @Test("two live sibling children in one batch exchange a message while both are in flight")
    func twoChildInFlightMessaging() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-child-peers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let gate = GatedExecutorGate()
        let registry = ToolRunnerRegistry()
        registry.register(SlowEchoTool(gate: gate))
        let runners = SubagentRunnerRegistry()
        registerDelegateTool(registry: registry, runners: runners)
        let executor = CatalogToolExecutor(runners: registry)
        let provider = TestFixtures.localhostProvider()
        let runID = UUID()
        let conversationID = UUID()
        let adapter = TwoChildAdapter()
        await runners.register(
            SubagentRunner(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                adapter: adapter,
                credentials: ProviderCredentials(),
                executor: executor
            ),
            for: runID
        )
        let delegateA = try TestFixtures.toolCall(
            id: "delegate-a", toolName: "delegate",
            arguments: #"{"task":"A-SIDE-TASK coordinate with the live sibling","type":"explore","maxIterations":10}"#
        )
        let delegateB = try TestFixtures.toolCall(
            id: "delegate-b", toolName: "delegate",
            arguments: #"{"task":"B-SIDE-TASK hold the slow read open","type":"research","maxIterations":4}"#
        )
        let parentAdapter = MockAdapter()
        parentAdapter.script = [
            [.toolRequest(delegateA), .toolRequest(delegateB)],
            [.textDelta(.init(text: "parent done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: ["delegate", "test.echo", "delegate.peers", "delegate.message"],
                workspaceRootURL: root
            ),
            adapter: parentAdapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore(),
            runID: runID
        )
        let startTask = Task { try await runtime.start(goal: "run two sibling subagents") }

        // Wait until the message was really accepted by the bus AND child B is
        // genuinely parked mid-run — that is the in-flight overlap.
        var inFlight = false
        var waited = 0
        while waited < 400 {
            let accepted = await SubagentPeerBus.shared.auditEntries.contains { $0.accepted }
            if accepted, await gate.hasEntered {
                inFlight = true
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
            waited += 1
        }
        #expect(inFlight, "expected the sibling message while child B was still parked in flight")
        await gate.open()
        try await startTask.value

        // Child B really received the message at its next safe boundary.
        let bRequests = adapter.requests(forSide: "B-SIDE-TASK")
        #expect(bRequests.count >= 2)
        let body = bRequests[1].effectiveMessages
            .flatMap(\.content)
            .compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }
            .joined(separator: "\n")
        #expect(body.contains("SIBLING-CLAIM file a.md is mine"))
        #expect(body.contains("untrusted coordination data"))
        // Child A discovered the sibling through delegate.peers before sending.
        let aRequests = adapter.requests(forSide: "A-SIDE-TASK")
        #expect(aRequests.count >= 3)
    }

    private let conversationID = UUID()

    private func makeRuntime(
        executor: any ToolExecutor,
        allowedToolNames: Set<String>? = ["test.write", "test.echo", "delegate", "workspace.writeFile"]
    ) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: allowedToolNames,
                workspaceRootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            adapter: ActiveParentTestAdapter(),
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
    }

    private func mutatingDescriptors() -> [String: ToolCatalog.Descriptor] {
        [
            "test.write": ToolCatalog.Descriptor(
                name: "test.write",
                riskLabels: [.writesFiles],
                isSideEffecting: true
            ),
            "workspace.writeFile": ToolCatalog.Descriptor(
                name: "workspace.writeFile",
                riskLabels: [.writesFiles],
                isSideEffecting: true,
                effect: .mutating
            ),
            "test.echo": ToolCatalog.Descriptor(
                name: "test.echo",
                riskLabels: [],
                isSideEffecting: false
            ),
            "delegate": ToolCatalog.Descriptor(
                name: "delegate",
                riskLabels: [.executesLocalCode],
                isSideEffecting: true,
                executionBoundary: .mainRunOnly,
                supportsConcurrentBatchDispatch: true
            )
        ]
    }

    private func identity(_ runtime: FloeAgentRuntime, delegateCallID: String = "call-delegate") async -> ChildExecutionIdentity {
        ChildExecutionIdentity(
            parentRunID: await runtime.runID,
            rootTaskID: conversationID,
            delegateCallID: delegateCallID
        )
    }

    private func childContext(
        conversationID: UUID,
        allowedToolNames: Set<String>?,
        workspaceRootURL: URL?
    ) -> ToolContext {
        ToolContext(
            runID: UUID(),
            scope: .local,
            allowedToolNames: allowedToolNames,
            workspaceRootURL: workspaceRootURL,
            cancellation: CancellationToken(),
            conversationID: conversationID
        )
    }

    // MARK: - Boundary enforcement

    @Test("a child can never invoke delegate, even when the model emits it")
    func nestedDelegateIsDenied() async throws {
        try await ActiveParentTestScope.withScope {
            let executor = CapturingExecutor(descriptors: mutatingDescriptors())
            let runtime = makeRuntime(executor: executor)
            try await ActiveParentTestScope.activate(runtime)
            let call = try TestFixtures.toolCall(id: "nested-1", toolName: "delegate", arguments: #"{"task":"go"}"#)
            let result = await runtime.dispatchChildTool(
                call,
                identity: await identity(runtime),
                childContext: childContext(
                    conversationID: conversationID,
                    allowedToolNames: ["test.write", "test.echo", "delegate"],
                    workspaceRootURL: nil
                )
            )
            #expect(result.status == .denied)
            #expect(result.outputSummary.contains("main-run only"))
            #expect(executor.entries.isEmpty)

        }
    }

    @Test("a child call outside the effective ceiling is denied before the executor")
    func ceilingIsEnforced() async throws {
        try await ActiveParentTestScope.withScope {
            let executor = CapturingExecutor(descriptors: mutatingDescriptors())
            let runtime = makeRuntime(executor: executor, allowedToolNames: ["test.echo"])
            try await ActiveParentTestScope.activate(runtime)
            let call = try TestFixtures.toolCall(id: "over-1", toolName: "test.write", arguments: #"{"path":"a.txt"}"#)
            let result = await runtime.dispatchChildTool(
                call,
                identity: await identity(runtime),
                childContext: childContext(
                    conversationID: conversationID,
                    allowedToolNames: ["test.echo"],
                    workspaceRootURL: nil
                )
            )
            #expect(result.status == .denied)
            #expect(executor.entries.isEmpty)

        }
    }

    @Test("a cross-run or nested identity is refused")
    func foreignIdentityRefused() async throws {
        try await ActiveParentTestScope.withScope {
            let executor = CapturingExecutor(descriptors: mutatingDescriptors())
            let runtime = makeRuntime(executor: executor)
            try await ActiveParentTestScope.activate(runtime)
            let call = try TestFixtures.toolCall(id: "x", toolName: "test.echo", arguments: "{}")
            let foreign = ChildExecutionIdentity(
                parentRunID: UUID(),
                rootTaskID: conversationID,
                delegateCallID: "other"
            )
            let crossRun = await runtime.dispatchChildTool(
                call, identity: foreign,
                childContext: childContext(conversationID: conversationID, allowedToolNames: ["test.echo"], workspaceRootURL: nil)
            )
            #expect(crossRun.status == .denied)
            #expect(crossRun.outputSummary.contains("different run"))

            let nested = ChildExecutionIdentity(
                parentRunID: await runtime.runID,
                rootTaskID: conversationID,
                delegateCallID: "nested",
                depth: 2
            )
            let nestedResult = await runtime.dispatchChildTool(
                call, identity: nested,
                childContext: childContext(conversationID: conversationID, allowedToolNames: ["test.echo"], workspaceRootURL: nil)
            )
            #expect(nestedResult.status == .denied)
            #expect(nestedResult.outputSummary.contains("Nested delegation"))
            #expect(executor.entries.isEmpty)

        }
    }

    // MARK: - Canonical execution + authority

    @Test("an approved mutating child call executes with grant, identity and runtime authority")
    func approvedChildCallExecutes() async throws {
        try await ActiveParentTestScope.withScope {
            let executor = CapturingExecutor(descriptors: mutatingDescriptors())
            let runtime = makeRuntime(executor: executor)
            try await ActiveParentTestScope.activate(runtime)
            let call = try TestFixtures.toolCall(
                id: "write-1", toolName: "test.write",
                arguments: #"{"path":"notes/a.md","text":"one"}"#
            )
            let result = await runtime.dispatchChildTool(
                call,
                identity: await identity(runtime),
                childContext: childContext(
                    conversationID: conversationID,
                    allowedToolNames: ["test.write", "test.echo", "delegate"],
                    workspaceRootURL: URL(fileURLWithPath: NSTemporaryDirectory())
                )
            )
            #expect(result.status == .ok, "status=\(result.status.rawValue) output=\(result.outputSummary)")
            let entry = try #require(executor.entries.first)
            #expect(entry.context.approvalGrantID != nil)
            #expect(entry.context.childExecution?.identity.delegateCallID == "call-delegate")
            #expect(entry.context.runtimeAuthority?.toolName == "test.write")
            #expect(entry.context.runtimeAuthority?.operationID == "write-1")
            #expect(entry.context.runtimeAuthority?.approvalGrantID == entry.context.approvalGrantID)

        }
    }

    @Test("runtime authority binds the concrete target, call, payload and task")
    func authorityBindsConcreteOperation() async throws {
        try await ActiveParentTestScope.withScope {
            let executor = CapturingExecutor(descriptors: mutatingDescriptors())
            let runtime = makeRuntime(executor: executor)
            try await ActiveParentTestScope.activate(runtime)
            let call = try TestFixtures.toolCall(
                id: "write-2", toolName: "workspace.writeFile",
                arguments: #"{"path":"notes/a.md","text":"one","expectedRevision":"rev-7"}"#
            )
            _ = await runtime.dispatchChildTool(
                call,
                identity: await identity(runtime),
                childContext: childContext(
                    conversationID: conversationID,
                    allowedToolNames: ["workspace.writeFile", "test.echo", "delegate"],
                    workspaceRootURL: URL(fileURLWithPath: NSTemporaryDirectory())
                )
            )
            let entry = try #require(executor.entries.first)
            let context = entry.context
            let token = try #require(context.runtimeAuthority)

            let binding = context.runtimeAuthorityBinding(
                toolName: "workspace.writeFile",
                operation: "apply",
                canonicalTarget: RuntimeAuthorityDigest.canonicalTarget(
                    for: call,
                    descriptor: executor.descriptor(named: call.toolName),
                    workspaceRootURL: context.workspaceRootURL
                ),
                baseRevision: RuntimeAuthorityDigest.baseRevision(in: call.argumentsJSON),
                payloadDigest: RuntimeAuthorityDigest.payloadDigest(call.argumentsJSON)
            )
            #expect(await RuntimeAuthorityStore.shared.validate(token, binding: binding) == .valid)
            #expect(binding.canonicalTarget.hasSuffix("notes/a.md"))
            #expect(binding.baseRevision == "rev-7")
            #expect(binding.taskID == conversationID)

            // Cross-target replay with identical content/SHA is refused.
            let otherTarget = context.runtimeAuthorityBinding(
                toolName: "workspace.writeFile",
                operation: "apply",
                canonicalTarget: "file:/tmp/elsewhere/a.md",
                baseRevision: binding.baseRevision,
                payloadDigest: binding.payloadDigest
            )
            if case .mismatch = await RuntimeAuthorityStore.shared.validate(token, binding: otherTarget) {
            } else {
                Issue.record("expected a cross-target mismatch")
            }

            // Altered command on the same target/base is refused.
            let alteredPayload = RuntimeAuthorityDigest.payloadDigest(
                Data(#"{"path":"notes/a.md","text":"two","expectedRevision":"rev-7"}"#.utf8)
            )
            let altered = context.runtimeAuthorityBinding(
                toolName: "workspace.writeFile",
                operation: "apply",
                canonicalTarget: binding.canonicalTarget,
                baseRevision: binding.baseRevision,
                payloadDigest: alteredPayload
            )
            if case .mismatch = await RuntimeAuthorityStore.shared.validate(token, binding: altered) {
            } else {
                Issue.record("expected an altered-command mismatch")
            }

            // Wrong task / operation / approved call replay is refused.
            for wrong in [
                context.runtimeAuthorityBinding(
                    toolName: "workspace.writeFile", operation: "export",
                    canonicalTarget: binding.canonicalTarget,
                    baseRevision: binding.baseRevision, payloadDigest: binding.payloadDigest
                ),
                RuntimeAuthorityBinding(
                    runID: binding.runID, taskID: UUID(),
                    environmentBinding: binding.environmentBinding,
                    canonicalTarget: binding.canonicalTarget, toolName: binding.toolName,
                    operation: binding.operation, operationID: binding.operationID,
                    idempotencyKey: binding.idempotencyKey, baseRevision: binding.baseRevision,
                    payloadDigest: binding.payloadDigest
                ),
                RuntimeAuthorityBinding(
                    runID: binding.runID, taskID: binding.taskID,
                    environmentBinding: binding.environmentBinding,
                    canonicalTarget: binding.canonicalTarget, toolName: binding.toolName,
                    operation: binding.operation, operationID: "other-call",
                    idempotencyKey: binding.idempotencyKey, baseRevision: binding.baseRevision,
                    payloadDigest: binding.payloadDigest
                )
            ] {
                if case .mismatch = await RuntimeAuthorityStore.shared.validate(token, binding: wrong) {
                } else {
                    Issue.record("expected a mismatch for a replayed binding")
                }
            }

            // A successful consume is single-use.
            #expect(await RuntimeAuthorityStore.shared.consume(token, binding: binding) == .valid)
            #expect(await RuntimeAuthorityStore.shared.consume(token, binding: binding) == .alreadyConsumed)

        }
    }

    @Test("a child executing without the canonical dispatcher falls back to a fail-closed read-only ceiling")
    func legacyFallbackIsFailClosed() async throws {
        let executor = CapturingExecutor(descriptors: mutatingDescriptors())
        // No handoff on the parent context: the runner's fail-closed path.
        let mutating = try TestFixtures.toolCall(id: "m", toolName: "test.write", arguments: #"{"path":"a"}"#)
        let denied = try await SubagentRunner.executeFailClosedChildCall(
            mutating,
            runID: UUID(),
            parentContext: ToolContext(
                runID: UUID(), scope: .local,
                allowedToolNames: ["test.write", "test.echo"],
                cancellation: CancellationToken()
            ),
            allowedToolNames: ["test.write", "test.echo"],
            executor: executor
        )
        #expect(denied.status == .denied)
        #expect(executor.entries.isEmpty)

        let read = try TestFixtures.toolCall(id: "r", toolName: "test.echo", arguments: "{}")
        let allowed = try await SubagentRunner.executeFailClosedChildCall(
            read,
            runID: UUID(),
            parentContext: ToolContext(
                runID: UUID(), scope: .local,
                allowedToolNames: ["test.write", "test.echo"],
                cancellation: CancellationToken()
            ),
            allowedToolNames: ["test.write", "test.echo"],
            executor: executor
        )
        #expect(allowed.status == .ok)
        #expect(executor.entries.count == 1)
    }

    // MARK: - Mutation leases through the actual seam

    @Test("two concurrent child writes to the same file serialize on the canonical lease")
    func sameFileChildWritesSerialize() async throws {
        try await ActiveParentTestScope.withScope {
            let gate = GatedExecutorGate()
            let executor = GatedExecutor(descriptors: mutatingDescriptors(), gate: gate)
            let runtime = makeRuntime(executor: executor, allowedToolNames: ["workspace.writeFile"])
            try await ActiveParentTestScope.activate(runtime)
            let first = try TestFixtures.toolCall(
                id: "w-a", toolName: "workspace.writeFile", arguments: #"{"path":"shared/a.md","text":"one"}"#
            )
            let second = try TestFixtures.toolCall(
                id: "w-b", toolName: "workspace.writeFile", arguments: #"{"path":"shared/a.md","text":"two"}"#
            )
            let partial = childContext(
                conversationID: conversationID,
                allowedToolNames: ["workspace.writeFile"],
                workspaceRootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            )
            let firstTask = Task {
                await runtime.dispatchChildTool(first, identity: await identity(runtime, delegateCallID: "d1"), childContext: partial)
            }
            // Wait until the first call really entered the executor and parked.
            var waited = 0
            while executor.executedOrder.isEmpty, waited < 200 {
                try await Task.sleep(nanoseconds: 20_000_000)
                waited += 1
            }
            #expect(executor.executedOrder == ["w-a"])

            let secondTask = Task {
                await runtime.dispatchChildTool(second, identity: await identity(runtime, delegateCallID: "d2"), childContext: partial)
            }
            try await Task.sleep(nanoseconds: 250_000_000)
            // The second sibling must be blocked behind the same-file lease.
            #expect(executor.executedOrder == ["w-a"])
            await gate.open()
            let firstResult = await firstTask.value
            let secondResult = await secondTask.value
            #expect(firstResult.status == .ok, "first=\(firstResult.outputSummary)")
            #expect(secondResult.status == .ok, "second=\(secondResult.outputSummary)")
            #expect(executor.executedOrder == ["w-a", "w-b"])

        }
    }

    // MARK: - End-to-end delegated write through the canonical chain

    actor ChildWriteRecorder {
        struct Record: Sendable { var path: String; var digest: String }
        private var storage: [Record] = []
        var records: [Record] { storage }
        func record(path: String, digest: String) { storage.append(Record(path: path, digest: digest)) }
    }

    /// A real file-writing tool registered like a production workspace tool.
    struct RecordingWriteTool: AgentTool {
        struct Arguments: Decodable, Sendable {
            var path: String
            var text: String
        }

        static let name = "test.realwrite"
        static let toolDescription = "Write a real file in the task workspace"
        static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string"},"text":{"type":"string"}},"required":["path","text"],"additionalProperties":false}"#
        static let riskLabels: Set<RiskLabel> = [.writesFiles]
        static let isSideEffecting = true
        static let toolEffect: ToolEffect = .mutating

        let recorder: ChildWriteRecorder

        func validate(_ args: Arguments) throws {
            guard !args.path.isEmpty else { throw FloeError.validationFailed("path must not be empty") }
        }

        func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
            try context.cancellation.throwIfCancelled()
            try context.authorizeWorkspacePath(args.path)
            let root = context.workspaceRootURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let target = root.appendingPathComponent(args.path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data(args.text.utf8)
            try data.write(to: target, options: .atomic)
            await recorder.record(path: args.path, digest: FloeDigest.sha256Hex(data))
            return ToolExecutionOutput(
                summary: "wrote \(args.path) (\(data.count) bytes)",
                fullOutputSHA256: FloeDigest.sha256Hex(data),
                exitStatus: 0
            )
        }
    }

    @Test("a delegated execute child really writes a file through the canonical dispatch chain")
    func endToEndChildWrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-child-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = ChildWriteRecorder()
        let registry = ToolRunnerRegistry()
        registry.register(RecordingWriteTool(recorder: recorder))
        let runners = SubagentRunnerRegistry()
        registerDelegateTool(registry: registry, runners: runners)
        let executor = CatalogToolExecutor(runners: registry)

        let provider = TestFixtures.localhostProvider()
        let runID = UUID()
        let conversationID = UUID()
        let delegateCall = try TestFixtures.toolCall(
            id: "delegate-1", toolName: "delegate",
            arguments: #"{"task":"write child/out.txt","type":"execute"}"#
        )
        let writeCall = try TestFixtures.toolCall(
            id: "write-1", toolName: "test.realwrite",
            arguments: #"{"path":"child/out.txt","text":"hello from child"}"#
        )
        let parentAdapter = MockAdapter()
        parentAdapter.script = [
            [.toolRequest(delegateCall)],
            [.textDelta(.init(text: "delegated work complete")), .completed(.init(stopReason: .endTurn))]
        ]
        let childAdapter = MockAdapter()
        childAdapter.script = [
            [.toolRequest(writeCall)],
            [.textDelta(.init(text: "child finished")), .completed(.init(stopReason: .endTurn))]
        ]
        await runners.register(
            SubagentRunner(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                adapter: childAdapter,
                credentials: ProviderCredentials(),
                executor: executor
            ),
            for: runID
        )
        let audit = MockAuditSink()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: ["delegate", "test.realwrite"],
                workspaceRootURL: root
            ),
            adapter: parentAdapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: audit,
            checkpointStore: MockCheckpointStore(),
            runID: runID
        )
        try await runtime.start(goal: "delegate the write")

        // 1. The child's real side effect exists with its exact bytes.
        let written = try Data(contentsOf: root.appendingPathComponent("child/out.txt"))
        #expect(String(decoding: written, as: UTF8.self) == "hello from child")
        let records = await recorder.records
        #expect(records.map(\.path) == ["child/out.txt"])
        #expect(records.first?.digest == FloeDigest.sha256Hex(Data("hello from child".utf8)))
        // 2. The child really executed through the runtime, and the audit
        //    chain records both the envelope and the child's own call.
        #expect(audit.entries.contains { $0.toolName == "delegate" })
        #expect(audit.entries.contains { $0.toolName == "test.realwrite" && $0.decision.hasPrefix("allow") })
    }

    @Test("a main-run conversation.spawn call really spawns through the canonical runtime")
    func mainRunSpawnIsAuthorizedByRuntimeProvenance() async throws {
        let sourceID = UUID()
        let spawnedID = UUID()
        let recorder = SpawnCallRecorder(result: ConversationSpawnResult(
            conversationID: spawnedID, title: "New task", workspaceID: nil
        ))
        let registry = ToolRunnerRegistry()
        // Production registration path: catalog entries + registry runners.
        registerConversationTools(
            registry: registry,
            reader: EmptyConversationReader(),
            currentConversationID: { _ in sourceID },
            hasExplicitUserAuthority: { _ in true },
            spawner: { request in try await recorder.spawn(request) }
        )
        let executor = CatalogToolExecutor(runners: registry)
        let provider = TestFixtures.localhostProvider()
        let spawnCall = try TestFixtures.toolCall(
            id: "spawn-1", toolName: "conversation.spawn",
            arguments: #"{"title":"New task","objective":"Do the work"}"#
        )
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(spawnCall)],
            [.textDelta(.init(text: "task created")), .completed(.init(stopReason: .endTurn))]
        ]
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: ["conversation.spawn"],
                workspaceRootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
        try await runtime.start(goal: "please create a new task")

        // The visible task really was created through the runtime's own
        // context. The spawn tool now requires the runtime-issued
        // `.mainRunDelegate` provenance for this exact run + call id, so
        // reaching the spawner proves the runtime minted it for a non-delegate
        // main-run call (it was previously nil for everything except
        // `delegate`, which a wrapper could reconstruct around).
        let request = try #require(await recorder.request)
        #expect(request.sourceConversationID == sourceID)
        #expect(request.title == "New task")
        #expect(request.objective == "Do the work")
    }

    @Test("a registered main-run wrapper cannot forward its own context into raw delegate or conversation.spawn")
    func mainWrapperCannotForwardIntoMainOnlyTools() async throws {
        let conversationID = UUID()
        let sourceID = UUID()
        let recorder = SpawnCallRecorder(result: ConversationSpawnResult(
            conversationID: UUID(), title: "Forwarded", workspaceID: nil
        ))
        let registry = ToolRunnerRegistry()
        let runners = SubagentRunnerRegistry()
        registerDelegateTool(registry: registry, runners: runners)
        registerConversationTools(
            registry: registry,
            reader: EmptyConversationReader(),
            currentConversationID: { _ in sourceID },
            hasExplicitUserAuthority: { _ in true },
            spawner: { request in try await recorder.spawn(request) }
        )
        let delegateRunner = try #require(registry.runner(named: "delegate"))
        let spawnRunner = try #require(registry.runner(named: "conversation.spawn"))
        let probe = WrapperForwardingProbe()
        registry.register(ForwardingMainWrapperTool(
            delegateRunner: delegateRunner,
            spawnRunner: spawnRunner,
            spawnProbe: probe
        ))

        let provider = TestFixtures.localhostProvider()
        let wrapperCall = try TestFixtures.toolCall(
            id: "wrapper-1", toolName: "test.mainwrapper", arguments: #"{"note":"forward"}"#
        )
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(wrapperCall)],
            [.textDelta(.init(text: "wrapper done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: ["test.mainwrapper", "delegate", "conversation.spawn"],
                workspaceRootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: CatalogToolExecutor(runners: registry),
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
        try await runtime.start(goal: "run the wrapper")

        // The wrapper held a genuine runtime-issued origin for ITS OWN call and
        // forwarded the identical context into the raw registry entries: the
        // tool-name binding must refuse both, and no visible task may appear.
        let snapshot = await probe.snapshot()
        #expect(snapshot.delegateDenied == true,
                "a wrapper's own main origin must not authorize raw delegate")
        #expect(snapshot.spawnThrew == true,
                "a wrapper's own main origin must not authorize raw conversation.spawn")
        #expect(await recorder.request == nil)
    }

    @Test("two concurrent child writes to different files really run concurrently")
    func distinctFileChildWritesRun() async throws {
        try await ActiveParentTestScope.withScope {
            let gate = GatedExecutorGate()
            let executor = GatedExecutor(descriptors: mutatingDescriptors(), gate: gate)
            let runtime = makeRuntime(executor: executor, allowedToolNames: ["workspace.writeFile"])
            try await ActiveParentTestScope.activate(runtime)
            let first = try TestFixtures.toolCall(
                id: "w-c", toolName: "workspace.writeFile", arguments: #"{"path":"shared/c.md","text":"one"}"#
            )
            let second = try TestFixtures.toolCall(
                id: "w-d", toolName: "workspace.writeFile", arguments: #"{"path":"shared/d.md","text":"two"}"#
            )
            let partial = childContext(
                conversationID: conversationID,
                allowedToolNames: ["workspace.writeFile"],
                workspaceRootURL: URL(fileURLWithPath: NSTemporaryDirectory())
            )
            let firstTask = Task {
                await runtime.dispatchChildTool(first, identity: await identity(runtime, delegateCallID: "d3"), childContext: partial)
            }
            var waited = 0
            while executor.executedOrder.isEmpty, waited < 200 {
                try await Task.sleep(nanoseconds: 20_000_000)
                waited += 1
            }
            #expect(executor.executedOrder == ["w-c"])
            // Disjoint canonical files must not block behind the first call, even
            // though it is still parked inside the executor.
            let secondTask = Task {
                await runtime.dispatchChildTool(second, identity: await identity(runtime, delegateCallID: "d4"), childContext: partial)
            }
            var enteredSecond = false
            waited = 0
            while !enteredSecond, waited < 100 {
                enteredSecond = executor.executedOrder.count == 2
                if !enteredSecond { try await Task.sleep(nanoseconds: 20_000_000) }
                waited += 1
            }
            #expect(executor.executedOrder == ["w-c", "w-d"])
            await gate.open()
            let firstResult = await firstTask.value
            let secondResult = await secondTask.value
            #expect(firstResult.status == .ok)
            #expect(secondResult.status == .ok)

        }
    }
}

/// Records the visible-task spawn request that really reached the spawner.
private actor SpawnCallRecorder {
    private(set) var request: ConversationSpawnRequest?
    let result: ConversationSpawnResult
    init(result: ConversationSpawnResult) { self.result = result }
    func spawn(_ request: ConversationSpawnRequest) async throws -> ConversationSpawnResult {
        self.request = request
        return result
    }
}

/// Test-only main-run wrapper: when the runtime executes it (with a real
/// runtime-issued origin for its own call), it forwards that IDENTICAL context
/// — same runID, callID and origin — into the raw registry entries of the
/// main-only tools. This is the wrapper bypass the tool-name binding must stop.
private struct ForwardingMainWrapperTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var note: String?
    }

    static let name = "test.mainwrapper"
    static let toolDescription = "Test-only wrapper that forwards its own tool context into raw main-only registry entries."
    static let parametersJSON = #"{"type":"object","properties":{"note":{"type":"string"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let delegateRunner: AnyAgentTool
    let spawnRunner: AnyAgentTool
    let spawnProbe: WrapperForwardingProbe

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        var delegateDenied = false
        do {
            let outcome = try await delegateRunner.execute(
                argumentsJSON: Data(#"{"task":"forwarded nested delegation"}"#.utf8),
                context: context
            )
            delegateDenied = outcome.summary.contains("status=denied")
        } catch {
            delegateDenied = false
        }
        var spawnThrew = false
        do {
            _ = try await spawnRunner.execute(
                argumentsJSON: Data(#"{"title":"forwarded","objective":"forwarded"}"#.utf8),
                context: context
            )
        } catch {
            spawnThrew = true
        }
        await spawnProbe.record(delegateDenied: delegateDenied, spawnThrew: spawnThrew)
        return ToolExecutionOutput(
            digesting: "wrapper forwarded delegateDenied=\(delegateDenied) spawnThrew=\(spawnThrew)"
        )
    }
}

private actor WrapperForwardingProbe {
    struct Snapshot {
        var delegateDenied: Bool?
        var spawnThrew: Bool?
    }

    private var delegateDenied: Bool?
    private var spawnThrew: Bool?

    func record(delegateDenied: Bool, spawnThrew: Bool) {
        self.delegateDenied = delegateDenied
        self.spawnThrew = spawnThrew
    }

    func snapshot() -> Snapshot {
        Snapshot(delegateDenied: delegateDenied, spawnThrew: spawnThrew)
    }
}

/// Minimal reader for the conversation tools that are not under test here.
private struct EmptyConversationReader: ConversationHistoryReader {
    func search(_ request: ConversationSearchRequest) async throws -> [ConversationSearchHit] { [] }
    func read(_ request: ConversationPageRequest) async throws -> ConversationHistoryPage {
        ConversationHistoryPage(conversationID: request.conversationID, messages: [])
    }
    func readMessages(ids: [UUID]) async throws -> [ConversationHistoryMessage] { [] }
}
