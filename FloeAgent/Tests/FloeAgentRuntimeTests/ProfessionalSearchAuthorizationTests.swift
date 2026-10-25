// FloeAgentRuntimeTests — native professional-search runtime authority.
// Recording executors prove policy/context behavior without FloeExecution,
// network, credentials or an App/component build.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeSecurity
@testable import FloeTools
import FloeTestSupport
@testable import FloeProviders
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.ProfessionalSearchAuthorization", .serialized)
struct ProfessionalSearchAuthorizationTests {
    private actor ParentGate {
        private var entered = false
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func park() async {
            entered = true
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func isParked() -> Bool { entered }
        func open() {
            opened = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
        struct Entry {
            var call: ToolCall
            var context: ToolContext
            var expectedAuthorizationIdentity: String?
        }
        private let storage: AsyncLock<[Entry]>
        private let descriptors: [String: ToolCatalog.Descriptor]
        private let gate: ParentGate?
        init(descriptors: [String: ToolCatalog.Descriptor], gate: ParentGate? = nil) {
            self.descriptors = descriptors
            self.gate = gate
            storage = AsyncLock([])
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
            storage.withLock {
                $0.append(Entry(
                    call: call, context: context,
                    expectedAuthorizationIdentity: expectedAuthorizationIdentity
                ))
            }
            if call.id == "hold" { await gate?.park() }
            return ToolResult(callID: call.id, status: .ok, outputSummary: "native read ok", outputDigest: "d")
        }
    }

    private func descriptor(_ name: String) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            parametersJSON: #"{"type":"object","additionalProperties":true}"#,
            riskLabels: [.networkAccess],
            isSideEffecting: false,
            effect: .readOnly
        )
    }

    private func account(
        registry: ToolRunnerRegistry,
        name: String = "Parent Account"
    ) -> ProfessionalSearchAuthority.Account {
        ProfessionalSearchAuthority.register(
            serverID: UUID(), displayName: name, registry: registry
        ) { _, _ in
            ToolExecutionOutput(summary: "{}", fullOutputSHA256: "")
        }
    }

    private func makeRuntime(
        adapter: MockAdapter,
        executor: RecordingExecutor,
        authority: ProfessionalSearchAuthority.Frozen,
        allowed: Set<String> = ["web.search"],
        plan: Bool = false
    ) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(
            configuration: .init(
                conversationID: UUID(), provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                conversationMode: plan ? .plan : .chat,
                allowedToolNames: allowed,
                professionalSearchAuthority: authority
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
    }

    private func withActiveParent(
        runtime: FloeAgentRuntime,
        gate: ParentGate,
        body: () async throws -> Void
    ) async throws {
        let parent = Task { try await runtime.start(goal: "hold parent for child dispatch") }
        do {
            var attempts = 0
            while await gate.isParked() == false, attempts < 500 {
                try await Task.sleep(nanoseconds: 10_000_000)
                attempts += 1
            }
            let parked = await gate.isParked()
            try #require(parked)
            try await body()
        } catch {
            await gate.open()
            await runtime.cancel()
            _ = try? await parent.value
            throw error
        }
        await gate.open()
        try await parent.value
    }

    @Test("Native professional read auto-approves with the base identity and frozen context")
    func ordinaryNativeReadUsesFrozenAuthority() async throws {
        let registry = ToolRunnerRegistry()
        let registered = account(registry: registry)
        let authority = ProfessionalSearchAuthority.freeze(
            registry: registry, allowedToolNames: ["web.search"]
        )
        let web = descriptor("web.search")
        let executor = RecordingExecutor(descriptors: [web.name: web])
        let adapter = MockAdapter()
        adapter.script = [[
            .toolRequest(try TestFixtures.toolCall(
                id: "professional", toolName: "web.search",
                arguments: #"{"query":"公司档案","source":"professional"}"#
            ))
        ], [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        try await makeRuntime(adapter: adapter, executor: executor, authority: authority)
            .start(goal: "native professional read")
        let entry = try #require(executor.entries.first)
        #expect(executor.entries.count == 1)
        #expect(entry.context.professionalSearchAuthority?.accounts == [registered])
        #expect(entry.context.professionalSearchAuthority?.isBound(to: registry) == true)
        #expect(entry.expectedAuthorizationIdentity == web.authorizationIdentity)
        #expect(adapter.requests.dropFirst().first?.toolResults.first?.output.contains("native read ok") == true)
    }

    @Test("Plan mode denies professional source before execution while preserving native read metadata")
    func planDeniesProfessionalSource() async throws {
        let registry = ToolRunnerRegistry()
        _ = account(registry: registry)
        let authority = ProfessionalSearchAuthority.freeze(
            registry: registry, allowedToolNames: ["web.search"],
            allowsProfessionalSource: false
        )
        let web = descriptor("web.search")
        let executor = RecordingExecutor(descriptors: [web.name: web])
        let adapter = MockAdapter()
        adapter.script = [[
            .toolRequest(try TestFixtures.toolCall(
                id: "plan-professional", toolName: "web.search",
                arguments: #"{"query":"学术文献","source":"professional"}"#
            ))
        ], [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        try await makeRuntime(adapter: adapter, executor: executor, authority: authority, plan: true)
            .start(goal: "plan professional read")
        #expect(executor.entries.isEmpty)
        let denial = try #require(adapter.requests.dropFirst().first?.toolResults.first)
        #expect(denial.output.contains("public web search only"))
        #expect(web.effect == .readOnly && !web.isSideEffecting)
    }

    @Test("Canonical child dispatch inherits only the parent's frozen registry and accounts")
    func childCannotSubstituteAuthority() async throws {
        let parentRegistry = ToolRunnerRegistry()
        let otherRegistry = ToolRunnerRegistry()
        let parentAccount = account(registry: parentRegistry)
        _ = account(registry: otherRegistry, name: "Other Account")
        let otherAuthority = ProfessionalSearchAuthority.freeze(
            registry: otherRegistry, allowedToolNames: ["web.search", "delegate"]
        )
        let parentAuthority = ProfessionalSearchAuthority.freeze(
            registry: parentRegistry, allowedToolNames: ["web.search", "delegate"]
        )
        let gate = ParentGate()
        let executor = RecordingExecutor(descriptors: [
            "delegate": descriptor("delegate"),
            "web.search": descriptor("web.search"),
        ], gate: gate)
        let adapter = MockAdapter()
        adapter.script = [[
            .toolRequest(try TestFixtures.toolCall(
                id: "hold", toolName: "delegate", arguments: "{}"
            ))
        ], [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        let runtime = makeRuntime(
            adapter: adapter, executor: executor, authority: parentAuthority,
            allowed: ["web.search", "delegate"]
        )
        try await withActiveParent(runtime: runtime, gate: gate) {
            let parentEntry = try #require(executor.entries.first { $0.call.id == "hold" })
            let identity = try #require(parentEntry.context.childExecution?.identity)
            let forgedContext = ToolContext(
                runID: await runtime.runID,
                allowedToolNames: ["web.search", "delegate"],
                professionalSearchAuthority: otherAuthority,
                cancellation: CancellationToken(),
                childBudget: ChildBudgetContext(maximumIterations: 2, reserve: { true }, finish: {}),
                frozenEffectiveCatalogNames: ["web.search", "delegate"]
            )
            let call = try TestFixtures.toolCall(
                id: "child-professional", toolName: "web.search",
                arguments: #"{"query":"公司档案","source":"professional"}"#
            )
            let result = await runtime.dispatchChildTool(
                call, identity: identity, childContext: forgedContext
            )
            #expect(result.status == .ok)
            let childEntry = try #require(executor.entries.first { $0.call.id == "child-professional" })
            #expect(childEntry.context.professionalSearchAuthority?.accounts == [parentAccount])
            #expect(childEntry.context.professionalSearchAuthority?.isBound(to: parentRegistry) == true)
            #expect(childEntry.context.professionalSearchAuthority?.isBound(to: otherRegistry) == false)
        }
    }
}
