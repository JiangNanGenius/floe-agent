import Foundation
import Testing
import FloeCore
import FloeProviders
import FloeTools
import FloeTestSupport
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.SubagentSafety")
struct SubagentSafetyTests {
    @Test("delegate is strictly read-only and exposes no write override")
    func descriptorIsReadOnly() {
        #expect(!DelegateTool.isSideEffecting)
        #expect(DelegateTool.toolEffect == .readOnly)
        #expect(!DelegateTool.parametersJSON.contains("allowWrites"))
    }

    @Test("delegate fails closed when the shared child budget has no slot")
    func missingBudgetFailsClosed() async throws {
        let provider = TestFixtures.localhostProvider()
        let runner = SubagentRunner(
            provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            adapter: MockAdapter(),
            credentials: ProviderCredentials(),
            executor: MockExecutor()
        )
        let runners = SubagentRunnerRegistry()
        let runID = UUID()
        await runners.register(runner, for: runID)
        let tool = DelegateTool(runners: runners)
        let output = try await tool.execute(
            .init(task: "inspect the workspace"),
            context: ToolContext(runID: runID, cancellation: CancellationToken())
        )

        #expect(output.exitStatus == 1)
        #expect(output.summary.contains("budget is unavailable"))
    }
}
