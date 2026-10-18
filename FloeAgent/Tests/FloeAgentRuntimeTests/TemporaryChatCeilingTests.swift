// FloeAgentRuntimeTests — Temporary chat public-web ceiling end-to-end
// through the REAL runtime: the descriptor-derived ceiling the center
// computes (`TemporaryChatToolPolicy.allowedToolNames(from descriptors:)`) is
// enforced on the provider wire (schemas/allToolNames), at main-run dispatch
// and at child dispatch, with the typed `temporaryReadOnly` runtime authority.
// Private reads, discovery, mixed tools, wrappers, delegation and batch/jobs
// cannot widen it; in-ceiling public web search/fetch reads still execute
// normally.

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

    /// Descriptors the executor "installs": a representative ordinary catalog
    /// including genuinely read-only private tools. The temporary ceiling must
    /// narrow this to the public web tools — absence from the catalog is NOT
    /// what denies the private families.
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
            "web.searchAI": ToolCatalog.Descriptor(
                name: "web.searchAI",
                riskLabels: [.networkAccess],
                isSideEffecting: false,
                effect: .readOnly
            ),
            "notes.read": ToolCatalog.Descriptor(
                name: "notes.read",
                riskLabels: [.readsFiles],
                isSideEffecting: false,
                effect: .readOnly
            ),
            "mail.read": ToolCatalog.Descriptor(
                name: "mail.read",
                riskLabels: [.networkAccess, .accessesCredentials],
                isSideEffecting: false,
                effect: .readOnly
            ),
            "apple.calendar.list": ToolCatalog.Descriptor(
                name: "apple.calendar.list",
                riskLabels: [.persistsPersonalData],
                isSideEffecting: false,
                effect: .readOnly
            ),
            "skill.list": ToolCatalog.Descriptor(
                name: "skill.list",
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
            // Mixed read/write tool: allowed read actions in an ordinary
            // read-only policy, but not part of temporary chat at all.
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
        policy: any ApprovalPolicy = FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
        allowedToolNames: Set<String>? = nil
    ) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: allowedToolNames ?? temporaryCeiling(),
                // Mirror ConversationCenter's temporary-run configuration:
                // the public-web-only boundary, the ephemeral transport and
                // the typed `temporaryReadOnly` runtime authority ride
                // together.
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

    @Test("Main-run dispatch: private reads and writes never execute and stay off the provider wire; public web fetch executes")
    func mainRunCeilingIsEnforced() async throws {
        // Deliberately WIDER than the ceiling: the canonical policy must deny
        // a private read even when a wrapper puts its name in the active set.
        let wideNames: Set<String> = [
            "web.fetch", "web.search", "web.searchAI", "notes.read", "mail.read",
            "apple.calendar.list", "media.models", "workspace.writeFile",
            "exec.shell",
        ]
        let adapter = MockAdapter()
        adapter.script = [
            [
                .toolRequest(try TestFixtures.toolCall(
                    id: "denied-notes", toolName: "notes.read", arguments: "{}")),
                .toolRequest(try TestFixtures.toolCall(
                    id: "denied-mail", toolName: "mail.read", arguments: #"{"action":"message"}"#)),
                .toolRequest(try TestFixtures.toolCall(
                    id: "denied-media", toolName: "media.models", arguments: #"{"action":"list"}"#)),
                .toolRequest(try TestFixtures.toolCall(
                    id: "denied-write", toolName: "workspace.writeFile",
                    arguments: #"{"path":"a.txt","text":"x"}"#)),
                .toolRequest(try TestFixtures.toolCall(
                    id: "denied-exec", toolName: "exec.shell", arguments: #"{"command":"id"}"#)),
                .toolRequest(try TestFixtures.toolCall(
                    id: "allowed-fetch", toolName: "web.fetch",
                    arguments: #"{"url":"https://example.com"}"#)),
            ],
            [.completed(.init(stopReason: .endTurn))],
        ]
        let executor = ContextCapturingExecutor(descriptors: ordinaryCatalog())
        let audit = MockAuditSink()
        let runtime = makeRuntime(
            adapter: adapter, executor: executor, auditSink: audit,
            allowedToolNames: wideNames)
        try await runtime.start(goal: "research a public page with web.fetch")

        // Only the public web fetch reached the executor; every private or
        // mutating call was denied by the canonical temporary boundary.
        #expect(executor.entries.map(\.call.toolName) == ["web.fetch"])
        #expect(executor.entries.first?.call.id == "allowed-fetch")
        let decisions = audit.entries.map(\.decision)
        #expect(decisions.contains("deny:temporary-readonly"))

        // The provider wire itself advertises only the public web tools plus
        // the always-callable discovery tools — schemas and the raw
        // allToolNames list cannot leak private or denied families.
        let wireRequest = try #require(adapter.requests.first)
        let wireCeiling = temporaryCeiling().union([ToolDiscovery.name, ToolDiscovery.listName])
        let schemaNames = Set(wireRequest.toolSchemas.map(\.name))
        #expect(schemaNames.isSubset(of: wireCeiling))
        #expect(Set(wireRequest.allToolNames).isSubset(of: wireCeiling))
        for privateName in ["notes.read", "mail.read", "apple.calendar.list", "media.models", "workspace.writeFile", "exec.shell"] {
            #expect(!schemaNames.contains(privateName), "\(privateName) must not reach the wire")
            #expect(!wireRequest.allToolNames.contains(privateName), "\(privateName) must not be advertised")
        }
        // The public web read executed with the temporary runtime authority
        // and the public-web-only execution context.
        let contextEntry = try #require(executor.entries.first { $0.call.id == "allowed-fetch" })
        #expect(contextEntry.context.temporaryReadOnly)
        #expect(contextEntry.context.publicWebOnly)
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

    @Test("Child dispatch: temporary children cannot inherit private reads, mixed tools, delegation, jobs or execution")
    func childDispatchCeilingIsInherited() async throws {
        let adapter = MockAdapter()
        let executor = ContextCapturingExecutor(descriptors: ordinaryCatalog())
        let runtime = makeRuntime(adapter: adapter, executor: executor)
        let identity = ChildExecutionIdentity(
            parentRunID: await runtime.runID,
            rootTaskID: UUID(),
            delegateCallID: "call-temp"
        )
        // The child inherits the parent's ACTUAL temporary name set (fetch,
        // search and configured AI search), plus private/mixed/write/
        // execution/delegation names that are deliberately wider than the
        // ceiling. Deriving the public half from `temporaryCeiling()` keeps the
        // fixture faithful if the policy ever adds another public web tool.
        let childAllowedNames = temporaryCeiling().union([
            "notes.read", "mail.read", "apple.calendar.list", "media.models",
            "workspace.writeFile", "exec.shell", "delegate", "batch.run",
            "jobs.submit", "memory.remember",
        ])
        func childContext() -> ToolContext {
            ToolContext(
                runID: UUID(),
                scope: .local,
                allowedToolNames: childAllowedNames,
                workspaceRootURL: nil,
                cancellation: CancellationToken(),
                conversationID: UUID(),
                temporaryReadOnly: true
            )
        }

        for denied in [
            "notes.read", "mail.read", "apple.calendar.list", "media.models",
            "workspace.writeFile", "exec.shell", "delegate", "batch.run",
            "jobs.submit", "memory.remember",
        ] {
            let call = try TestFixtures.toolCall(
                id: "child-\(denied)", toolName: denied, arguments: #"{"x":1}"#)
            let result = await runtime.dispatchChildTool(
                call, identity: identity, childContext: childContext())
            #expect(result.status == .denied, "\(denied) must be denied, got \(result.status.rawValue)")
        }
        #expect(executor.entries.isEmpty)

        // The public web tools stay reachable for temporary children, and the
        // public-web-only boundary reaches the actual execute path.
        let fetch = try TestFixtures.toolCall(
            id: "child-fetch", toolName: "web.fetch",
            arguments: #"{"url":"https://example.com"}"#)
        let fetched = await runtime.dispatchChildTool(
            fetch, identity: identity, childContext: childContext())
        #expect(fetched.status == .ok)
        let search = try TestFixtures.toolCall(
            id: "child-search", toolName: "web.search",
            arguments: #"{"query":"weather"}"#)
        let searched = await runtime.dispatchChildTool(
            search, identity: identity, childContext: childContext())
        #expect(searched.status == .ok)
        let aiSearch = try TestFixtures.toolCall(
            id: "child-ai-search", toolName: "web.searchAI",
            arguments: #"{"query":"weather summary"}"#)
        let aiSearched = await runtime.dispatchChildTool(
            aiSearch, identity: identity, childContext: childContext())
        #expect(aiSearched.status == .ok)
        #expect(executor.entries.map(\.call.toolName) == ["web.fetch", "web.search", "web.searchAI"])
        #expect(executor.entries.allSatisfy { $0.context.publicWebOnly })
        #expect(executor.entries.allSatisfy { $0.context.temporaryReadOnly })

        // Frozen catalog identity: even a stale/forged child context that
        // excludes the public pair cannot dispatch it.
        let forgedFrozen = ToolContext(
            runID: UUID(),
            scope: .local,
            allowedToolNames: ["web.fetch", "notes.read"],
            publicWebOnly: true,
            cancellation: CancellationToken(),
            conversationID: UUID(),
            temporaryReadOnly: true,
            frozenEffectiveCatalogNames: ["notes.read"]
        )
        let forgedFetch = try TestFixtures.toolCall(
            id: "child-forged-fetch", toolName: "web.fetch",
            arguments: #"{"url":"https://example.com"}"#)
        let forgedResult = await runtime.dispatchChildTool(
            forgedFetch, identity: identity, childContext: forgedFrozen)
        #expect(forgedResult.status == .denied)
        #expect(forgedResult.outputSummary.contains("offered catalog"))
    }
}
