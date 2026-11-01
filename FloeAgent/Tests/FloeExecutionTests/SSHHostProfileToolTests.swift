import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeSSH
import FloeTools
@testable import FloeExecution

@Suite("FloeExecution saved host tools")
struct SSHHostProfileToolTests {
    @Test("Model host editor stores VNC credentialInput through the secure writer")
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
        let updateRecorder = RemoteHostUpdateRecorder()
        let resolver = VNCPasswordResolverRecorder()
        let runID = UUID()
        let tool = SSHUpdateHostTool(
            store: store,
            passwordWriter: { savedHostID, savedConnectionID, secret in
                await recorder.record(hostID: savedHostID, connectionID: savedConnectionID, secret: secret)
                return SecretReference(
                    keychainAccount: "host.vnc.\(savedHostID.uuidString).\(savedConnectionID.uuidString)",
                    synchronizable: false
                )
            },
            passwordDeleter: { _, _ in },
            secretDeleter: { _ in },
            credentialInputResolver: { input, slot in
                await resolver.record(input: input, slot: slot)
                return CredentialInputResolution(secret: Data("resolved-vnc".utf8)) {
                    await resolver.consume(slot.fieldPath)
                }
            },
            updateObserver: { savedHostID, endpointIDs in
                await updateRecorder.record(hostID: savedHostID, endpointIDs: endpointIDs)
            }
        )
        let placeholder = "⟨credential:00000000-0000-0000-0000-000000000001⟩"
        let arguments = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"{"hostID":"\#(hostID.uuidString)","vncConnections":[{"id":"\#(connectionID.uuidString)","displayName":"Direct desktop","transport":"direct","host":"lab.local","port":5900,"credentialInput":"\#(placeholder)"}]}"#.utf8)
        )

        try tool.validate(arguments)
        var context = ToolContext(runID: runID, cancellation: CancellationToken())
        context.executionToolName = SSHUpdateHostTool.name
        let output = try await tool.execute(arguments, context: context)

        let captured = await recorder.value
        #expect(captured?.hostID == hostID)
        #expect(captured?.connectionID == connectionID)
        #expect(captured?.secret == Data("resolved-vnc".utf8))
        let resolveCalls = await resolver.calls
        #expect(resolveCalls.count == 1)
        #expect(resolveCalls.first?.fieldPath == "vncConnections.0.credentialInput")
        #expect(resolveCalls.first?.runID == runID)
        #expect(resolveCalls.first?.toolName == SSHUpdateHostTool.name)
        #expect(resolveCalls.first?.hostID == hostID)
        #expect(await resolver.consumed == ["vncConnections.0.credentialInput"])
        #expect(!output.summary.contains("00000000-0000-0000-0000-000000000001"))
        #expect(output.summary.contains(#""passwordConfigured":true"#))
        #expect(output.summary.contains(#""configuredVNCCount":1"#))
        let saved = try #require(await store.host(id: hostID))
        let endpoints = try JSONDecoder().decode(
            [VNCEndpoint].self,
            from: Data(try #require(saved.vncEndpointsJSON).utf8)
        )
        #expect(endpoints.first?.passwordRef?.keychainAccount == "host.vnc.\(hostID.uuidString).\(connectionID.uuidString)")
        #expect(await updateRecorder.value?.hostID == hostID)
        #expect(await updateRecorder.value?.endpointIDs == [connectionID])
    }

    @Test("Legacy password field remains placeholder-only compatible")
    func acceptsLegacyPasswordPlaceholder() throws {
        let hostID = UUID()
        let arguments = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"{"hostID":"\#(hostID.uuidString)","vncConnections":[{"displayName":"Direct desktop","transport":"direct","host":"lab.local","port":5900,"password":"⟨credential:00000000-0000-0000-0000-000000000001⟩"}]}"#.utf8)
        )
        #expect(arguments.vncConnections?.first?.credentialInput == "⟨credential:00000000-0000-0000-0000-000000000001⟩")
    }

    @Test("Model host editor accepts raw VNC credentialInput and hands it only to secure storage")
    func acceptsRawVNCPassword() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = RemoteHostStore(database: database)
        let hostID = UUID()
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
                return SecretReference(keychainAccount: "host.vnc.secure", synchronizable: false)
            },
            secretDeleter: { _ in }
        )
        let arguments = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"{"hostID":"\#(hostID.uuidString)","vncConnections":[{"displayName":"Direct desktop","transport":"direct","host":"lab.local","port":5900,"credentialInput":"raw-secret"}]}"#.utf8)
        )

        try tool.validate(arguments)
        _ = try await tool.execute(arguments, context: ToolContext(runID: UUID(), cancellation: CancellationToken()))
        #expect(String(data: await recorder.value?.secret ?? Data(), encoding: .utf8) == "raw-secret")
    }
}

private actor RemoteHostUpdateRecorder {
    struct Value: Sendable {
        var hostID: UUID
        var endpointIDs: Set<UUID>
    }

    private(set) var value: Value?

    func record(hostID: UUID, endpointIDs: Set<UUID>) {
        value = Value(hostID: hostID, endpointIDs: endpointIDs)
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

private actor VNCPasswordResolverRecorder {
    struct Call: Sendable {
        var input: Data
        var fieldPath: String
        var runID: UUID
        var toolName: String
        var hostID: UUID?
    }

    private(set) var calls: [Call] = []
    private(set) var consumed: [String] = []

    func record(input: Data, slot: CredentialInputSlot) {
        calls.append(Call(
            input: input,
            fieldPath: slot.fieldPath,
            runID: slot.runID,
            toolName: slot.toolName,
            hostID: slot.hostID
        ))
    }

    func consume(_ fieldPath: String) {
        consumed.append(fieldPath)
    }
}
