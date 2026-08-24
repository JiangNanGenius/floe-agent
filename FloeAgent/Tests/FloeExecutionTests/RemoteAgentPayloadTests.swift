import Testing
@testable import FloeExecution

@Suite("Bundled remote agent payload")
struct RemoteAgentPayloadTests {
    @Test("Agent and updater sources are available at runtime")
    func loadsBundledSources() throws {
        let agent = try RemoteAgentPayload.agentSource()
        let updater = try RemoteAgentPayload.updaterSource()

        #expect(agent.contains("FloeRemoteAgent"))
        #expect(updater.contains("JiangNanGenius/floe-agent"))
    }
}
