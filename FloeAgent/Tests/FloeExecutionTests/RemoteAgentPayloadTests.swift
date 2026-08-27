import Foundation
import Testing
@testable import FloeExecution
import FloeSSH
import FloeTools

private actor FakeRemoteAgentManager: RemoteAgentManaging {
    let hostID = UUID()
    var installedVersion: String
    var checkCount = 0
    var updateCount = 0

    init(installedVersion: String) {
        self.installedVersion = installedVersion
    }

    func check(
        hostID: UUID?,
        cancellation: CancellationToken?
    ) async throws -> RemoteAgentInstaller.Result {
        checkCount += 1
        try? await Task.sleep(for: .milliseconds(30))
        return .init(
            hostID: hostID ?? self.hostID,
            targetKind: .linux,
            version: installedVersion,
            exitCode: 0,
            output: "checked"
        )
    }

    func installOrUpdate(
        hostID: UUID?,
        cancellation: CancellationToken?
    ) async throws -> RemoteAgentInstaller.Result {
        updateCount += 1
        installedVersion = RemoteAgentPayload.version
        return .init(
            hostID: hostID ?? self.hostID,
            targetKind: .linux,
            version: installedVersion,
            exitCode: 0,
            output: "updated"
        )
    }

    func counts() -> (checks: Int, updates: Int) {
        (checkCount, updateCount)
    }
}

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

    @Test("First helper use upgrades a stale host and later uses are cached")
    func readinessUpgradesThenCaches() async throws {
        let manager = FakeRemoteAgentManager(installedVersion: "0.9.0")
        let readiness = RemoteAgentReadinessCoordinator(manager: manager)

        let first = try await readiness.ensureReady(hostID: nil)
        let second = try await readiness.ensureReady(hostID: nil)
        let counts = await manager.counts()

        #expect(first.action == .updated)
        #expect(first.version == RemoteAgentPayload.version)
        #expect(second.action == .cached)
        #expect(counts.checks == 1)
        #expect(counts.updates == 1)
    }

    @Test("Concurrent first uses share one guardian version check")
    func readinessCoalescesConcurrentChecks() async throws {
        let manager = FakeRemoteAgentManager(installedVersion: RemoteAgentPayload.version)
        let readiness = RemoteAgentReadinessCoordinator(manager: manager)

        async let first = readiness.ensureReady(hostID: nil)
        async let second = readiness.ensureReady(hostID: nil)
        _ = try await (first, second)
        let counts = await manager.counts()

        #expect(counts.checks == 1)
        #expect(counts.updates == 0)
    }

    @Test("Guardian is not installed on a device that is only a management target")
    func readinessHonorsExecutionEnvironmentSwitch() async {
        let manager = FakeRemoteAgentManager(installedVersion: "0.9.0")
        let readiness = RemoteAgentReadinessCoordinator(
            manager: manager,
            eligibility: { _ in false }
        )

        await #expect(throws: (any Error).self) {
            _ = try await readiness.ensureReady(hostID: UUID())
        }
        let counts = await manager.counts()
        #expect(counts.checks == 0)
        #expect(counts.updates == 0)
    }
}
