// FloeAgentRuntimeTests — a run with required background work outstanding
// parks honestly (checkpointed, no terminal completion) instead of finishing
// and letting a completion callback start a new unsolicited turn.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
import FloeTestSupport

private actor DependencyLabels {
    private var labels: [RunDependencyLabel]
    init(_ labels: [RunDependencyLabel]) { self.labels = labels }
    func value() -> [RunDependencyLabel] { labels }
    func resolve() { labels = [] }
}

@Suite("FloeAgentRuntime.DependencyWait")
struct DependencyWaitTests {

    private func makeRuntime(
        adapter: MockAdapter,
        sink: MockSink,
        checkpointStore: MockCheckpointStore,
        dependencies: @escaping @Sendable () async -> [RunDependencyLabel]
    ) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                outstandingDependencies: dependencies
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            checkpointStore: checkpointStore,
            sink: sink
        )
    }

    @Test("An outstanding required job parks the run instead of completing it")
    func parksOnOutstandingDependency() async throws {
        let adapter = MockAdapter()
        adapter.script = [[
            .textDelta(.init(text: "The export job is running; I will continue when it finishes.")),
            .completed(AgentEvent.CompletionInfo(stopReason: .endTurn))
        ]]
        let sink = MockSink()
        let checkpointStore = MockCheckpointStore()
        let labels = DependencyLabels([
            RunDependencyLabel(identifier: UUID().uuidString, kind: "job", label: "document.pdf.export")
        ])
        let runtime = makeRuntime(
            adapter: adapter, sink: sink, checkpointStore: checkpointStore,
            dependencies: { await labels.value() })
        try await runtime.start(goal: "export the report")
        let state = await runtime.state
        guard case .checkpointed(let reference) = state else {
            Issue.record("expected the run to park as checkpointed, got \(state.name)")
            return
        }
        #expect((reference.reason ?? "").hasPrefix(FloeAgentRuntime.dependencyWaitReasonPrefix))
        #expect((reference.reason ?? "").contains("document.pdf.export") == false)
        // A recovery checkpoint was written BEFORE parking, so the same run
        // resumes with the job result even after a process restart.
        #expect(!checkpointStore.saved.isEmpty)
        // The parked run is not terminal.
        #expect(state.name == "checkpointed")
    }

    @Test("No outstanding dependency keeps the ordinary completion")
    func completesWhenNoDependency() async throws {
        let adapter = MockAdapter()
        adapter.script = [[
            .textDelta(.init(text: "Done.")),
            .completed(AgentEvent.CompletionInfo(stopReason: .endTurn))
        ]]
        let runtime = makeRuntime(
            adapter: adapter, sink: MockSink(), checkpointStore: MockCheckpointStore(),
            dependencies: { [] })
        try await runtime.start(goal: "say done")
        #expect(await runtime.state.name == "completed")
    }

    @Test("A run without a dependency source keeps its historical completion")
    func completesWithoutDependencySource() async throws {
        let adapter = MockAdapter()
        adapter.script = [[
            .textDelta(.init(text: "Done.")),
            .completed(AgentEvent.CompletionInfo(stopReason: .endTurn))
        ]]
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id)),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            checkpointStore: MockCheckpointStore(),
            sink: MockSink()
        )
        try await runtime.start(goal: "say done")
        #expect(await runtime.state.name == "completed")
    }

    @Test("The dependency marker prefix is the stable shared contract")
    func markerPrefix() {
        #expect(FloeAgentRuntime.dependencyWaitReasonPrefix == "awaiting.finite.job")
    }
}
