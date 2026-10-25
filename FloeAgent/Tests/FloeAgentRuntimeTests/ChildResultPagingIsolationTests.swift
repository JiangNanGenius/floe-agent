import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
import FloeTools
import FloeTestSupport
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.ChildResultPagingIsolation")
struct ChildResultPagingIsolationTests {
    final class Counter: @unchecked Sendable {
        private let storage = AsyncLock(0)
        var value: Int { storage.withLock { $0 } }
        func increment() { storage.withLock { $0 += 1 } }
    }

    struct Echo: AgentTool {
        struct Arguments: Decodable, Sendable {}
        static let name = "test.pagingEcho"
        static let toolDescription = "Read-only reachability control"
        static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
        static let riskLabels: Set<RiskLabel> = []
        static let isSideEffecting = false
        let counter: Counter
        func validate(_ args: Arguments) throws {}
        func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
            counter.increment()
            return ToolExecutionOutput(summary: "child reached executor", fullOutputSHA256: "echo")
        }
    }

    @Test("An active restricted child cannot read real parent captures, while its allowed tool reaches the executor")
    func activeChildCannotReadParentCapture() async throws {
        try await ActiveParentTestScope.withScope {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("child-paging-isolation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try ActiveParentTestScope.afterStop { try? FileManager.default.removeItem(at: root) }
            let conversationID = UUID()
            let runID = UUID()
            let body = "parent-owned-captured-result-\(UUID().uuidString)"
            let store = ToolResultCaptureStore.shared(durableRoot: root)
            await store.capture(conversationID: conversationID, runID: runID,
                                callID: "parent-call", toolName: "exec.shell", status: "ok",
                                text: body, temporary: false)
            let paging = ToolResultPagingTool(store: store)
            // Establish real data and a sensitive control: a valid parent read
            // succeeds before testing the child dispatch boundary.
            let parentRead = try await paging.execute(.init(callID: "parent-call"), context: ToolContext(
                runID: runID, allowedToolNames: [ToolResultPagingTool.name],
                cancellation: CancellationToken(), conversationID: conversationID
            ))
            #expect(parentRead.summary.contains(body))

            let counter = Counter()
            let registry = ToolRunnerRegistry()
            registry.register(paging)
            registry.register(Echo(counter: counter))
            let executor = CatalogToolExecutor(runners: registry)
            #expect(executor.descriptor(named: ToolResultPagingTool.name)?.executionBoundary == .mainRunOnly)
            #expect(ToolResultPagingTool.descriptor.executionBoundary == ToolResultPagingTool.executionBoundary)
            #expect(ToolResultPagingTool.descriptor.supportsConcurrentBatchDispatch == ToolResultPagingTool.supportsConcurrentBatchDispatch)
            let provider = TestFixtures.localhostProvider()
            let runtime = FloeAgentRuntime(
                configuration: .init(conversationID: conversationID, provider: provider,
                                     model: TestFixtures.testModel(providerID: provider.id),
                                     allowedToolNames: [Echo.name, ToolResultPagingTool.name],
                                     toolResultCaptureRoot: root),
                adapter: ActiveParentTestAdapter(),
                policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
                executor: executor, auditSink: MockAuditSink(), checkpointStore: MockCheckpointStore(),
                runID: runID
            )
            try await ActiveParentTestScope.activate(runtime)
            #expect(await runtime.state.name == "streamingModel")
            let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: conversationID, delegateCallID: "delegate-1")
            let context = ToolContext(runID: UUID(), allowedToolNames: [Echo.name],
                                      cancellation: CancellationToken(), conversationID: conversationID,
                                      frozenEffectiveCatalogNames: [Echo.name])
            let pageCall = try TestFixtures.toolCall(id: "child-parent-page", toolName: ToolResultPagingTool.name,
                                                    arguments: #"{"callID":"parent-call"}"#)
            let denied = await runtime.dispatchChildTool(pageCall, identity: identity, childContext: context)
            #expect(denied.status == .denied)
            #expect(denied.outputSummary.contains("main-run only"))
            #expect(!denied.outputSummary.contains("no longer active"))
            #expect(!denied.outputSummary.contains(body))
            let echoCall = try TestFixtures.toolCall(id: "child-allowed-echo", toolName: Echo.name, arguments: "{}")
            let reached = await runtime.dispatchChildTool(echoCall, identity: identity, childContext: context)
            #expect(reached.status == .ok, "\(reached.outputSummary)")
            #expect(reached.outputSummary == "child reached executor")
            #expect(counter.value == 1)
        }
    }

    @Test("An intentionally idle parent still refuses an otherwise allowed child before execution")
    func inactiveParentStillDenied() async throws {
        let counter = Counter()
        let registry = ToolRunnerRegistry()
        registry.register(Echo(counter: counter))
        let provider = TestFixtures.localhostProvider()
        let conversationID = UUID()
        let runtime = FloeAgentRuntime(
            configuration: .init(conversationID: conversationID, provider: provider,
                                 model: TestFixtures.testModel(providerID: provider.id)),
            adapter: MockAdapter(),
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: CatalogToolExecutor(runners: registry),
            auditSink: MockAuditSink(), checkpointStore: MockCheckpointStore()
        )
        let identity = ChildExecutionIdentity(parentRunID: await runtime.runID, rootTaskID: conversationID, delegateCallID: "idle-delegate")
        let call = try TestFixtures.toolCall(id: "idle-call", toolName: Echo.name, arguments: "{}")
        let denied = await runtime.dispatchChildTool(call, identity: identity, childContext: ToolContext(
            runID: UUID(), allowedToolNames: [Echo.name], cancellation: CancellationToken(), conversationID: conversationID
        ))
        #expect(denied.status == .denied)
        #expect(denied.outputSummary.contains("no longer active"))
        #expect(counter.value == 0)
    }
}
