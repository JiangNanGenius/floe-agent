// FloeAgentRuntimeTests — Temporary chat tool ceiling end-to-end through the
// REAL runtime: the descriptor-derived ceiling the center computes
// (`TemporaryChatToolPolicy.allowedToolNames(from descriptors:)`) is enforced
// at the main-run dispatch, on the provider wire (schemas/allToolNames), and
// at child dispatch, with the typed `temporaryReadOnly` runtime authority.
// Wrappers, delegation and batch/jobs cannot widen it, a verified mixed
// read/write tool runs its read actions and refuses its write actions at the
// canonical boundary, and an in-ceiling read still executes normally.

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
    /// temporary ceiling must narrow this to the descriptor-derived read-only
    /// set — absence from the catalog is NOT what denies the other families.
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
            "notes.read": ToolCatalog.Descriptor(
                name: "notes.read",
                riskLabels: [],
                isSideEffecting: false,
                effect: .readOnly
            ),
            "workspace.writeFile": ToolCatalog.Descriptor(
                name: "workspace.writeFile",
                riskLabels: [.writesFiles],
                isSideEffecting: true,
                effect: .mutating
            ),
            "exec.shell": ToolCatalog.Descriptor(
                name: "exec.shell",
                riskLabels: [.executesLocalCode],
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
            // Verified mixed read/write tool: the base descriptor is a real
            // mutating tool; the action policy is the authority.
            "media.models": ToolCatalog.Descriptor(
                name: "media.models",
                toolDescription: "List, inspect, install or remove media models",
                parametersJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["list","status","install","remove"]}},"required":["action"],"additionalProperties":false}"#,
                riskLabels: [.networkAccess],
                isSideEffecting: true,
                effect: .mutating
            ),
        ]
    }

    /// The exact set the center installs for a temporary run: derived from
    /// the actually offered descriptors by the current policy.
    private func temporaryCeiling() -> Set<String> {
        TemporaryChatToolPolicy.allowedToolNames(from: Array(ordinaryCatalog().values))
    }

    private func makeRuntime(
        adapter: MockAdapter,
        executor: any ToolExecutor,
        auditSink: MockAuditSink = MockAuditSink(),
        policy: any ApprovalPolicy = FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil))
    ) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: temporaryCeiling(),
                // Mirror ConversationCenter's temporary-run configuration:
                // the read-only ceiling rides together with the public-only
                // boundary, the ephemeral transport and the typed
                // `temporaryReadOnly` runtime authority.
                pauseTimeout: 0.1,
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0,
                providerRetryJitterRatio: 0,
                ephemeralTransport: true,
                publicWebOnly: true,
                temporaryReadOnly: true
            ),
            adapter: adapter,
            policy: policy,
            executor: executor,
            auditSink: auditSink,
            checkpointStore: MockCheckpointStore()
        )
    }

    @Test("Main-run dispatch: denied ceiling tools never execute and stay off the provider wire; verified read actions execute")
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
                id: "denied-install", toolName: "media.models",
                arguments: #"{"action":"install","model":"m1"}"#))],
            [.toolRequest(try TestFixtures.toolCall(
                id: "allowed-fetch", toolName: "web.fetch",
                arguments: #"{"url":"https://example.com"}"#))],
            [.toolRequest(try TestFixtures.toolCall(
                id: "allowed-list", toolName: "media.models",
                arguments: #"{"action":"list"}"#))],
            [.completed(.init(stopReason: .endTurn))],
        ]
        let executor = ContextCapturingExecutor(descriptors: ordinaryCatalog())
        let audit = MockAuditSink()
        let runtime = makeRuntime(adapter: adapter, executor: executor, auditSink: audit)
        // The goal names the mixed tool so this turn's discovery really loads
        // its (narrowed) schema onto the wire.
        try await runtime.start(goal: "check media.models then research a public page")

        // Denied families never reached the executor; the in-ceiling web tool
        // and the verified mixed-tool LIST action did.
        #expect(executor.entries.map(\.call.toolName).sorted() == ["media.models", "web.fetch"])
        #expect(executor.entries.first { $0.call.id == "allowed-list" }?.call.toolName == "media.models")
        #expect(executor.entries.first { $0.call.id == "denied-write" } == nil)
        #expect(executor.entries.first { $0.call.id == "denied-install" } == nil)
        let decisions = audit.entries.map(\.decision)
        #expect(decisions.contains("deny:skill-capability"))
        #expect(decisions.contains("deny:temporary-readonly"))

        // The provider wire itself advertises only the ceiling plus the two
        // always-callable discovery tools — schemas and the raw allToolNames
        // list cannot leak the denied families, and the verified mixed tool's
        // schema is narrowed to its read actions.
        let wireRequest = try #require(adapter.requests.first)
        let wireCeiling = temporaryCeiling().union([ToolDiscovery.name, ToolDiscovery.listName])
        let schemaNames = Set(wireRequest.toolSchemas.map(\.name))
        #expect(schemaNames.isSubset(of: wireCeiling))
        #expect(!schemaNames.contains("workspace.writeFile"))
        #expect(!schemaNames.contains("exec.shell"))
        #expect(!schemaNames.contains("delegate"))
        #expect(Set(wireRequest.allToolNames).isSubset(of: wireCeiling))
        let modelsSchema = try #require(wireRequest.toolSchemas.first { $0.name == "media.models" })
        #expect(modelsSchema.parametersJSON.contains("list"))
        #expect(!modelsSchema.parametersJSON.contains("install"))
        #expect(!modelsSchema.parametersJSON.contains("remove"))
        // The verified read action executed with the temporary runtime
        // authority on its context.
        let contextEntry = try #require(executor.entries.first { $0.call.id == "allowed-list" })
        #expect(contextEntry.context.temporaryReadOnly)
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

    @Test("Child dispatch: the inherited ceiling denies delegation, batch, jobs, execution and workspace tools before the executor")
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
                conversationID: UUID(),
                temporaryReadOnly: true
            )
        }

        for denied in ["delegate", "batch.run", "jobs.submit", "workspace.writeFile", "exec.shell", "memory.remember"] {
            let call = try TestFixtures.toolCall(id: "child-\(denied)", toolName: denied, arguments: #"{"x":1}"#)
            let result = await runtime.dispatchChildTool(call, identity: identity, childContext: childContext())
            #expect(result.status == .denied, "\(denied) must be denied, got \(result.status.rawValue)")
        }
        // A verified read action of a mixed tool is denied for its WRITE
        // action at the child boundary too.
        let install = try TestFixtures.toolCall(
            id: "child-install", toolName: "media.models", arguments: #"{"action":"install"}"#
        )
        let installResult = await runtime.dispatchChildTool(
            install, identity: identity, childContext: childContext()
        )
        #expect(installResult.status == .denied)
        #expect(installResult.outputSummary.contains("install"))
        #expect(executor.entries.isEmpty)

        // The ceiling's own read-only web tool and a verified mixed read
        // action stay reachable for children, and the public-web-only
        // boundary reaches the actual execute path.
        let fetch = try TestFixtures.toolCall(id: "child-fetch", toolName: "web.fetch", arguments: #"{"url":"https://example.com"}"#)
        let fetched = await runtime.dispatchChildTool(fetch, identity: identity, childContext: childContext())
        #expect(fetched.status == .ok)
        let status = try TestFixtures.toolCall(
            id: "child-status", toolName: "media.models", arguments: #"{"action":"status"}"#
        )
        let statusResult = await runtime.dispatchChildTool(status, identity: identity, childContext: childContext())
        #expect(statusResult.status == .ok)
        #expect(executor.entries.map(\.call.toolName) == ["web.fetch", "media.models"])
        #expect(executor.entries.first?.context.publicWebOnly == true)
        #expect(executor.entries.allSatisfy { $0.context.temporaryReadOnly })
    }
}
