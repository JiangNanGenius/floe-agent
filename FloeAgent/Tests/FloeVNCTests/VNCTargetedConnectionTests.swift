import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeVNC

@Suite("VNC explicit endpoint selection")
struct VNCTargetedConnectionTests {
    private let hostID = UUID()
    private let connectionID = UUID()

    private func context() -> ToolContext {
        ToolContext(runID: UUID(), cancellation: CancellationToken())
    }

    @Test("Target arguments require both UUIDs or neither")
    func targetArgumentValidation() throws {
        let emptyTarget = try VNCTargetArguments.resolve(nil, nil)
        #expect(emptyTarget == nil)
        let resolved = try VNCTargetArguments.resolve(hostID.uuidString, connectionID.uuidString)
        let target = try #require(resolved)
        #expect(target.hostID == hostID)
        #expect(target.connectionID == connectionID)
        #expect(throws: (any Error).self) {
            try VNCTargetArguments.resolve(hostID.uuidString, nil)
        }
        #expect(throws: (any Error).self) {
            try VNCTargetArguments.resolve(nil, connectionID.uuidString)
        }
        #expect(throws: (any Error).self) {
            try VNCTargetArguments.resolve("not-a-uuid", connectionID.uuidString)
        }
    }

    @Test("Connect routes an explicit target to the targeted action only")
    func connectUsesExplicitTarget() async throws {
        let recorder = ConnectionActionRecorder()
        let status = VNCToolConnectionStatus(
            state: .connected,
            configuredEndpointCount: 2,
            sessionID: UUID(),
            target: "localhost:5900",
            hostID: hostID,
            connectionID: connectionID,
            connectionName: "Console",
            transport: "sshTunnel",
            toolManaged: true,
            idleTimeoutSeconds: 300
        )
        let tool = VNCConnectTool(
            connection: {
                await recorder.recordLegacy()
                return nil
            },
            targetedConnection: { host, connection, _ in
                await recorder.recordTarget(host: host, connection: connection)
                return nil
            },
            statusProvider: { status }
        )

        let output = try await tool.execute(
            .init(hostID: hostID.uuidString, connectionID: connectionID.uuidString),
            context: context()
        )

        #expect(await recorder.value?.targetHostID == hostID)
        #expect(await recorder.value?.targetConnectionID == connectionID)
        #expect(await recorder.value?.legacyCount == 0)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any]
        )
        #expect(json["hostID"] as? String == hostID.uuidString)
        #expect(json["connectionID"] as? String == connectionID.uuidString)
        #expect(json["connectionName"] as? String == "Console")
        #expect(json["transport"] as? String == "sshTunnel")
        #expect(json["connectionState"] as? String == "connected")
    }

    @Test("Connect without target arguments preserves the existing action")
    func connectPreservesLegacyCall() async throws {
        let recorder = ConnectionActionRecorder()
        let tool = VNCConnectTool(
            connection: {
                await recorder.recordLegacy()
                return nil
            },
            targetedConnection: { host, connection, _ in
                await recorder.recordTarget(host: host, connection: connection)
                return nil
            },
            statusProvider: {
                VNCToolConnectionStatus(state: .connected, configuredEndpointCount: 1)
            }
        )
        _ = try await tool.execute(.init(), context: context())
        #expect(await recorder.value?.legacyCount == 1)
        #expect(await recorder.value?.targetHostID == nil)
    }

    @Test("Explicit target with no wired action fails honestly")
    func explicitTargetWithoutWiringFails() async throws {
        let tool = VNCConnectTool(
            connection: { nil },
            statusProvider: {
                VNCToolConnectionStatus(state: .disconnected, configuredEndpointCount: 2)
            }
        )
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(
                .init(hostID: hostID.uuidString, connectionID: connectionID.uuidString),
                context: context()
            )
        }
    }

    @Test("Reconnect routes an explicit target to the targeted action")
    func reconnectUsesExplicitTarget() async throws {
        let recorder = ConnectionActionRecorder()
        let hostID = self.hostID
        let connectionID = self.connectionID
        let tool = VNCReconnectTool(
            reconnect: {
                await recorder.recordLegacy()
                return nil
            },
            targetedReconnect: { host, connection, _ in
                await recorder.recordTarget(host: host, connection: connection)
                return nil
            },
            statusProvider: {
                VNCToolConnectionStatus(
                    state: .connected,
                    configuredEndpointCount: 1,
                    hostID: hostID,
                    connectionID: connectionID
                )
            }
        )
        _ = try await tool.execute(
            .init(hostID: hostID.uuidString, connectionID: connectionID.uuidString),
            context: context()
        )
        #expect(await recorder.value?.targetHostID == hostID)
        #expect(await recorder.value?.legacyCount == 0)
    }

    @Test("Connect and reconnect reject a partial target before execution")
    func partialTargetValidation() throws {
        let connect = VNCConnectTool(
            connection: { nil },
            statusProvider: { VNCToolConnectionStatus(state: .disconnected, configuredEndpointCount: 1) }
        )
        #expect(throws: (any Error).self) {
            try connect.validate(.init(hostID: hostID.uuidString))
        }
        let reconnect = VNCReconnectTool(
            reconnect: { nil },
            statusProvider: { VNCToolConnectionStatus(state: .disconnected, configuredEndpointCount: 1) }
        )
        #expect(throws: (any Error).self) {
            try reconnect.validate(.init(connectionID: connectionID.uuidString))
        }
    }
}

private actor ConnectionActionRecorder {
    struct Value: Sendable {
        var legacyCount = 0
        var targetHostID: UUID?
        var targetConnectionID: UUID?
    }

    private(set) var value: Value?

    func recordLegacy() {
        var current = value ?? Value()
        current.legacyCount += 1
        value = current
    }

    func recordTarget(host: UUID, connection: UUID) {
        var current = value ?? Value()
        current.targetHostID = host
        current.targetConnectionID = connection
        value = current
    }
}
