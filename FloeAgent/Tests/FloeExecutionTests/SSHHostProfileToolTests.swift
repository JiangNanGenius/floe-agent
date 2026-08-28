import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeSSH
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution saved host tools")
struct SSHHostProfileToolTests {
    @Test("Model host editor stores VNC passwords through the secure writer")
    func storesVNCPasswordAndReturnsOnlyMetadata() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = RemoteHostStore(database: database)
        let hostID = UUID()
        let connectionID = UUID()
        try await store.saveHost(
            id: hostID,
            displayName: "Lab",
            address: "lab.local",
            port: 22,
            user: "operator",
            authJSON: String(decoding: try JSONEncoder().encode(SSHAuthMethod.none), as: UTF8.self),
            jumpChainJSON: "[]",
            hostKeyPolicy: "trustOnFirstUse",
            allowsLegacyAlgorithms: false,
            vncEndpointJSON: nil,
            isRemoteExecutionEnvironment: false,
            vncEndpointsJSON: "[]"
        )
        let recorder = VNCPasswordRecorder()
        let tool = SSHUpdateHostTool(
            store: store,
            passwordWriter: { savedHostID, savedConnectionID, secret in
                await recorder.record(hostID: savedHostID, connectionID: savedConnectionID, secret: secret)
                return SecretReference(
                    keychainAccount: "host.vnc.\(savedHostID.uuidString).\(savedConnectionID.uuidString)",
                    synchronizable: false
                )
            },
            passwordDeleter: { _, _ in }
        )
        let arguments = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"{"hostID":"\#(hostID.uuidString)","vncConnections":[{"id":"\#(connectionID.uuidString)","displayName":"Direct desktop","transport":"direct","host":"lab.local","port":5900,"password":"⟨credential:00000000-0000-0000-0000-000000000001⟩"}]}"#.utf8)
        )

        try tool.validate(arguments)
        let output = try await tool.execute(
            arguments,
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )

        let captured = await recorder.value
        #expect(captured?.hostID == hostID)
        #expect(captured?.connectionID == connectionID)
        #expect(String(data: captured?.secret ?? Data(), encoding: .utf8)?.hasPrefix("⟨credential:") == true)
        #expect(!output.summary.contains("00000000-0000-0000-0000-000000000001"))
        #expect(output.summary.contains(#""passwordConfigured":true"#))
        let saved = try #require(await store.host(id: hostID))
        let endpoints = try JSONDecoder().decode(
            [VNCEndpoint].self,
            from: Data(try #require(saved.vncEndpointsJSON).utf8)
        )
        #expect(endpoints.first?.passwordRef?.keychainAccount == "host.vnc.\(hostID.uuidString).\(connectionID.uuidString)")
    }

    @Test("Model host editor rejects raw VNC passwords before persistence")
    func rejectsRawVNCPassword() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = RemoteHostStore(database: database)
        let hostID = UUID()
        let tool = SSHUpdateHostTool(
            store: store,
            passwordWriter: { _, _, _ in
                Issue.record("Raw password must be rejected before the secure writer")
                return SecretReference(keychainAccount: "unexpected", synchronizable: false)
            }
        )
        let arguments = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"{"hostID":"\#(hostID.uuidString)","vncConnections":[{"displayName":"Direct desktop","transport":"direct","host":"lab.local","port":5900,"password":"raw-secret"}]}"#.utf8)
        )

        #expect(throws: FloeError.self) {
            try tool.validate(arguments)
        }
    }
}

private actor VNCPasswordRecorder {
    struct Value: Sendable {
        var hostID: UUID
        var connectionID: UUID
        var secret: Data
    }

    private(set) var value: Value?

    func record(hostID: UUID, connectionID: UUID, secret: Data) {
        value = Value(hostID: hostID, connectionID: connectionID, secret: secret)
    }
}
