import Foundation
import Testing
@testable import FloeExecution

@Suite("Bundled remote agent payload")
struct RemoteAgentPayloadTests {
    @Test("Agent and updater sources are available at runtime")
    func loadsBundledSources() throws {
        let agent = try RemoteAgentPayload.agentSource()
        let updater = try RemoteAgentPayload.updaterSource()

        #expect(agent.contains("FloeRemoteAgent"))
        #expect(agent.contains("requested_id=body.get(\"task_id\")"))
        #expect(agent.contains("VERSION = \"\(RemoteAgentPayload.version)\""))
        #expect(updater.contains("JiangNanGenius/floe-agent"))
    }

    @Test("Durable task ids are stable for reconnect")
    func stableTaskID() {
        let runID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let first = RemoteAgentTaskService.taskID(runID: runID, toolCallID: "call-7")
        let second = RemoteAgentTaskService.taskID(runID: runID, toolCallID: "call-7")
        #expect(first == second)
        #expect(first.count < 128)
    }
}
