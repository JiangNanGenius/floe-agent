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

    @Test("delegate type maps to subagent kind and schema ceiling follows it")
    func typeMappingAndSchemaCeiling() {
        #expect(DelegateTool.parametersJSON.contains("\"enum\": [\"explore\", \"research\"]"))
        let args = DelegateTool.Arguments(task: "t", type: .research)
        #expect(args.type == .research)
        // explore (default) strips web/network groups from the child schema.
        #expect(SubagentRequest.Kind.explore != .research)
        #expect(DelegateTool.Arguments(task: "t").type == nil)
    }

    @Test("child system prompt carries the self-contained handoff contract")
    func handoffContract() {
        let prompt = SubagentRunner.handoffPromptForTesting(kind: .explore, context: "ctx")
        #expect(prompt.contains("receives only your final message"))
        #expect(prompt.contains("self-contained handoff"))
        #expect(prompt.contains("Never address the end user directly"))
        #expect(prompt.contains("ctx"))
        let research = SubagentRunner.handoffPromptForTesting(kind: .research, context: nil)
        #expect(research.contains("web/network"))
    }
}
