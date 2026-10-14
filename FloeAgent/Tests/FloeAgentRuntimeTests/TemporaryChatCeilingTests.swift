// FloeAgentRuntimeTests — Temporary chat tool ceiling end-to-end through the
// REAL runtime: the exact web-only set ConversationCenter computes
// (`TemporaryChatToolPolicy.allowedToolNames(from:)`) is enforced at the
// main-run dispatch, on the provider wire (schemas/allToolNames), and at
// child dispatch. Wrappers, delegation and batch/jobs cannot widen it, and a
// read-only web tool inside the ceiling still executes normally.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeSecurity
import FloeTools
import FloeTestSupport
@testable import FloeProviders
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.TemporaryChatCeiling")
struct TemporaryChatCeilingTests {

    /// Descriptors the executor "installs": the full ordinary catalog. The
    /// temporary ceiling must narrow this to the web pair — absence from the
    // catalog is NOT what denies the other families.
    private func ordinaryCatalog() -> [String: ToolCatalog.Descriptor] {
        [
            "web.fetch": ToolCatalog.Descriptor(
                name: "web.fetch",
                riskLabels: [.networkAccess],
                isSideEffecting: false,
                effect: .readOnly
            ),
            "web.search": ToolCatalog.Descriptor(
                name: "web.search",
                riskLabels: [.networkAccess],
                isSideEffecting: false,
                effect: .readOnly
            ),
            "workspace.writeFile": ToolCatalog.Descriptor(
                name: "workspace.writeFile",
                riskLabels: [.writesFiles],
                isSideEffecting: true,
                effect: .mutating
            ),
            "delegate": ToolCatalog.Descriptor(
                name: "delegate",
                riskLabels: [.executesLocalCode],
                isSideEffecting: true,
                executionBoundary: .mainRunOnly,
                supportsConcurrentBatchDispatch: true
            ),
            "batch.run": ToolCatalog.Descriptor(
                name: "batch.run",
                riskLabels: [.executesLocalCode],
                isSideEffecting: true
            ),
            "jobs.submit": ToolCatalog.Descriptor(
                name: "jobs.submit",
                riskLabels: [.executesLocalCode],
                isSideEffecting: true
            ),
            "memory.remember": ToolCatalog.Descriptor(
                name: "memory.remember",
                riskLabels: [],
                isSideEffecting: false,
                effect: .mutating
            ),
        ]
    }

    /// The exact set the center installs for a temporary run.
    private func temporaryCeiling() -> Set<String> {
        TemporaryChatToolPolicy.allowedToolNames(from: Set(ordinaryCatalog().keys))
    }

    private func makeRuntime(
        adapter: MockAdapter,
        executor: any ToolExecutor,
        policy: any ApprovalPolicy = FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil))
    ) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: temporaryCeiling(),
                // Mirror ConversationCenter's temporary-run configuration:
                // the web ceiling rides together with the public-only
                // boundary and the ephemeral provider transport.
                pauseTimeout: 0.1,
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0,
                providerRetryJitterRatio: 0,
                ephemeralTransport: true,
                publicWebOnly: true
            ),
            adapter: adapter,
            policy: policy,
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
    }

    @Test("Main-run dispatch: denied ceiling tools never execute and stay off the provider wire; the in-ceiling read-only web tool executes")
    func mainRunCeilingIsEnforced() async throws {
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(
                id: "denied-write", toolName: "workspace.writeFile",
                arguments: #"{"path":"a.txt","text":"x"}"#))],
            [.toolRequest(try TestFixtures.toolCall(
                id: "denied-batch", toolName: "batch.run",
                arguments: #"{"items":[]}"#))],
            [.toolRequest(try TestFixtures.toolCall(
                id: "allowed-fetch", toolName: "web.fetch",
                arguments: #"{"url":"https://example.com"}"#))],
            [.completed(.init(stopReason: .endTurn))],
        ]
        let executor = MockExecutor()
        executor.descriptors = ordinaryCatalog()
        let audit = MockAuditSink()
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: temporaryCeiling(),
                // Mirror ConversationCenter's temporary-run configuration:
                // the web ceiling rides together with the public-only
                // boundary and the ephemeral provider transport.
                pauseTimeout: 0.1,
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0,
                providerRetryJitterRatio: 0,
                ephemeralTransport: true,
                publicWebOnly: true
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: audit,
            checkpointStore: MockCheckpointStore()
        )

        try await runtime.start(goal: "research a public page")

        // The denied families never reached the executor...
        #expect(executor.executedCalls.map(\.toolName) == ["web.fetch"])
        // ...the in-ceiling read-only web tool did execute exactly once...
        #expect(executor.executedCalls.first?.id == "allowed-fetch")
        // ...and both denials were recorded as ceiling decisions.
        let decisions = audit.entries.map(\.decision)
        #expect(decisions.contains("deny:skill-capability"))

        // The provider wire itself advertises only the ceiling plus the two
        // always-callable discovery tools — schemas and the raw allToolNames
        // list cannot leak the denied families.
        let wireRequest = try #require(adapter.requests.first)
        let wireCeiling = temporaryCeiling().union([ToolDiscovery.name, ToolDiscovery.listName])
        let schemaNames = Set(wireRequest.toolSchemas.map(\.name))
        #expect(schemaNames.isSubset(of: wireCeiling))
        #expect(!schemaNames.contains("workspace.writeFile"))
        #expect(!schemaNames.contains("delegate"))
        #expect(Set(wireRequest.allToolNames).isSubset(of: wireCeiling))
    }

    /// Executor that records the exact ToolContext the runtime built, so the
    /// suite can prove the public-web-only boundary reaches the execute path.
    final class ContextCapturingExecutor: ToolExecutor, @unchecked Sendable {
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

    @Test("Child dispatch: the inherited ceiling denies delegation, batch, jobs and workspace tools before the executor")
    func childDispatchCeilingIsInherited() async throws {
        let adapter = MockAdapter()
        let executor = ContextCapturingExecutor(descriptors: ordinaryCatalog())
        let runtime = makeRuntime(adapter: adapter, executor: executor)
        let identity = ChildExecutionIdentity(
            parentRunID: await runtime.runID,
            rootTaskID: UUID(),
            delegateCallID: "call-temp"
        )
        func childContext() -> ToolContext {
            ToolContext(
                runID: UUID(),
                scope: .local,
                // Children inherit the run ceiling — the same value the
                // runtime copies into ToolContext for delegated children.
                allowedToolNames: temporaryCeiling(),
                workspaceRootURL: nil,
                cancellation: CancellationToken(),
                conversationID: UUID()
            )
        }

        for denied in ["delegate", "batch.run", "jobs.submit", "workspace.writeFile", "memory.remember"] {
            let call = try TestFixtures.toolCall(id: "child-\(denied)", toolName: denied, arguments: #"{"x":1}"#)
            let result = await runtime.dispatchChildTool(call, identity: identity, childContext: childContext())
            #expect(result.status == .denied, "\(denied) must be denied, got \(result.status.rawValue)")
        }
        #expect(executor.entries.isEmpty)

        // The ceiling's own read-only web tool stays reachable for children,
        // and the public-web-only boundary reaches the actual execute path.
        let fetch = try TestFixtures.toolCall(id: "child-fetch", toolName: "web.fetch", arguments: #"{"url":"https://example.com"}"#)
        let fetched = await runtime.dispatchChildTool(fetch, identity: identity, childContext: childContext())
        #expect(fetched.status == .ok)
        #expect(executor.entries.map(\.call.toolName) == ["web.fetch"])
        #expect(executor.entries.first?.context.publicWebOnly == true)
    }
}
