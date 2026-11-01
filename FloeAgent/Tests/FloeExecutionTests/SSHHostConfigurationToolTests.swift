import Foundation
import Testing
import FloeCore
import FloePersistence
import FloeSSH
import FloeTools
@testable import FloeExecution

@Suite("SSH host configuration tools")
struct SSHHostConfigurationToolTests {
    private func makeStore() async throws -> RemoteHostStore {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return RemoteHostStore(database: database)
    }

    private func seedHost(
        in store: RemoteHostStore,
        id: UUID = UUID(),
        auth: SSHAuthMethod = .password(SecretReference(keychainAccount: "host.ssh.seeded", synchronizable: false)),
        hostKeyPolicy: String = "trustOnFirstUse",
        vncEndpoints: [VNCEndpoint] = [],
        auxiliary: [RemoteAuxiliaryConnection] = []
    ) async throws -> RemoteHostStore.StoredHost {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let stored = RemoteHostStore.StoredHost(
            id: id,
            displayName: "Studio mini",
            address: "studio.local",
            port: 22,
            user: "floe",
            authJSON: String(decoding: try encoder.encode(auth), as: UTF8.self),
            jumpChainJSON: "[]",
            hostKeyPolicy: hostKeyPolicy,
            allowsLegacyAlgorithms: false,
            vncEndpointJSON: try vncEndpoints.first.map {
                String(decoding: try encoder.encode($0), as: UTF8.self)
            },
            deviceKind: RemoteDeviceKind.mac.rawValue,
            isRemoteExecutionEnvironment: true,
            vncEndpointsJSON: String(decoding: try encoder.encode(vncEndpoints), as: UTF8.self),
            auxiliaryConnectionsJSON: String(decoding: try encoder.encode(auxiliary), as: UTF8.self)
        )
        try await store.saveHost(stored)
        return stored
    }

    private func storedEndpoints(_ host: RemoteHostStore.StoredHost?) throws -> [VNCEndpoint] {
        guard let json = host?.vncEndpointsJSON else { return [] }
        return try JSONDecoder().decode([VNCEndpoint].self, from: Data(json.utf8))
    }

    private func storedAuxiliary(_ host: RemoteHostStore.StoredHost?) throws -> [RemoteAuxiliaryConnection] {
        guard let json = host?.auxiliaryConnectionsJSON else { return [] }
        return try JSONDecoder().decode([RemoteAuxiliaryConnection].self, from: Data(json.utf8))
    }

    private func summaryJSON(_ output: ToolExecutionOutput) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any]
        )
    }

    // MARK: - Creation

    @Test("Create host stores SSH and VNC credentials through the injected writer")
    func createHostStoresCredentials() async throws {
        let store = try await makeStore()
        let sshWriter = SSHCredentialWriterRecorder()
        let vncWriter = VNCWriterRecorder()
        let observer = HostUpdateRecorder()
        let tool = SSHCreateHostTool(
            store: store,
            credentialWriter: { hostID, input, label, method in
                await sshWriter.record(hostID: hostID, input: input, label: label, method: method)
                return SecretReference(keychainAccount: "host.ssh.\(hostID.uuidString)", synchronizable: false)
            },
            vncPasswordWriter: { hostID, connectionID, input in
                await vncWriter.record(hostID: hostID, connectionID: connectionID, input: input)
                return SecretReference(
                    keychainAccount: "host.vnc.\(hostID.uuidString).\(connectionID.uuidString)",
                    synchronizable: false
                )
            },
            secretDeleter: { _ in },
            updateObserver: { hostID, endpointIDs in
                await observer.record(hostID: hostID, endpointIDs: endpointIDs)
            }
        )
        let endpointID = UUID()
        let arguments = try JSONDecoder().decode(
            SSHCreateHostTool.Arguments.self,
            from: Data(#"""
            {
              "displayName": "Studio mini",
              "address": "studio.local",
              "port": 2222,
              "user": "floe",
              "authMethod": "password",
              "credentialInput": "ssh-raw-secret",
              "vncConnections": [
                {"id": "\#(endpointID.uuidString)", "displayName": "Console", "transport": "sshTunnel", "host": "localhost", "port": 5900, "credentialInput": "vnc-raw-secret"}
              ]
            }
            """#.utf8)
        )

        try tool.validate(arguments)
        let output = try await tool.execute(
            arguments,
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )

        let saved = try #require(await store.hosts().first)
        #expect(saved.displayName == "Studio mini")
        #expect(saved.address == "studio.local")
        #expect(saved.port == 2222)
        #expect(saved.user == "floe")
        #expect(await sshWriter.value?.input == Data("ssh-raw-secret".utf8))
        #expect(await sshWriter.value?.method == .password)
        #expect(await vncWriter.value?.input == Data("vnc-raw-secret".utf8))
        let auth = try JSONDecoder().decode(SSHAuthMethod.self, from: Data(saved.authJSON.utf8))
        guard case .password(let reference) = auth else {
            Issue.record("Expected password authentication")
            return
        }
        #expect(reference.keychainAccount == "host.ssh.\(saved.id.uuidString)")
        let endpoints = try storedEndpoints(saved)
        #expect(endpoints.count == 1)
        #expect(endpoints.first?.id == endpointID)
        #expect(endpoints.first?.passwordRef?.keychainAccount
            == "host.vnc.\(saved.id.uuidString).\(endpointID.uuidString)")
        #expect(await observer.value?.hostID == saved.id)
        #expect(await observer.value?.endpointIDs == [endpointID])

        #expect(!output.summary.contains("ssh-raw-secret"))
        #expect(!output.summary.contains("vnc-raw-secret"))
        let json = try summaryJSON(output)
        #expect(json["created"] as? Bool == true)
        #expect(json["hostID"] as? String == saved.id.uuidString)
        #expect(json["credentialStored"] as? Bool == true)
        #expect(json["configuredVNCCount"] as? Int == 1)
    }

    @Test("Create host rejects an unresolved credential placeholder before writing")
    func createHostRejectsUnresolvedCredentialReference() async throws {
        let store = try await makeStore()
        let recorder = SSHCredentialWriterRecorder()
        let placeholder = "⟨credential:00000000-0000-0000-0000-000000000001⟩"
        let tool = SSHCreateHostTool(
            store: store,
            credentialWriter: { hostID, input, label, method in
                await recorder.record(hostID: hostID, input: input, label: label, method: method)
                return SecretReference(keychainAccount: "host.ssh.\(hostID.uuidString)", synchronizable: false)
            },
            secretDeleter: { _ in }
        )
        let arguments = try JSONDecoder().decode(
            SSHCreateHostTool.Arguments.self,
            from: Data(#"""
            {"displayName":"Lab","address":"lab.local","user":"operator","authMethod":"deviceKey","credentialInput":"\#(placeholder)","keyType":"ed25519"}
            """#.utf8)
        )
        try tool.validate(arguments)
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(
                arguments,
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }
        #expect(await recorder.value == nil)
        #expect(try await store.hosts().isEmpty)
    }

    @Test("Create host resolves the exact capture slot and consumes it after commit")
    func createHostResolvesReferenceWithCanonicalSlot() async throws {
        let store = try await makeStore()
        let sshWriter = SSHCredentialWriterRecorder()
        let vncWriter = VNCWriterRecorder()
        let resolver = CredentialResolverRecorder()
        let runID = UUID()
        let endpointID = UUID()
        let sshPlaceholder = "⟨credential:11111111-1111-1111-1111-111111111111⟩"
        let vncPlaceholder = "⟨credential:22222222-2222-2222-2222-222222222222⟩"
        let tool = SSHCreateHostTool(
            store: store,
            credentialWriter: { hostID, input, label, method in
                await sshWriter.record(hostID: hostID, input: input, label: label, method: method)
                return SecretReference(keychainAccount: "host.ssh.\(hostID.uuidString)", synchronizable: false)
            },
            vncPasswordWriter: { hostID, connectionID, input in
                await vncWriter.record(hostID: hostID, connectionID: connectionID, input: input)
                return SecretReference(
                    keychainAccount: "host.vnc.\(hostID.uuidString).\(connectionID.uuidString)",
                    synchronizable: false
                )
            },
            secretDeleter: { _ in },
            credentialInputResolver: { input, slot in
                await resolver.record(input, slot: slot)
                let secret = slot.expectedKind == .vncPassword
                    ? Data("resolved-vnc".utf8) : Data("resolved-ssh".utf8)
                return CredentialInputResolution(secret: secret) {
                    await resolver.consume(slot.fieldPath)
                }
            }
        )
        var context = ToolContext(runID: runID, cancellation: CancellationToken())
        context.executionToolName = SSHCreateHostTool.name
        let arguments = try JSONDecoder().decode(
            SSHCreateHostTool.Arguments.self,
            from: Data(#"""
            {
              "displayName": "Lab",
              "address": "lab.local",
              "user": "operator",
              "authMethod": "deviceKey",
              "credentialInput": "\#(sshPlaceholder)",
              "keyType": "ed25519",
              "vncConnections": [
                {"id": "\#(endpointID.uuidString)", "displayName": "Console", "transport": "direct", "host": "lab.local", "port": 5900, "credentialInput": "\#(vncPlaceholder)"}
              ]
            }
            """#.utf8)
        )
        try tool.validate(arguments)
        let output = try await tool.execute(arguments, context: context)

        let saved = try #require(await store.hosts().first)
        let calls = await resolver.calls
        #expect(calls.count == 2)
        #expect(calls[0].input == Data(sshPlaceholder.utf8))
        #expect(calls[0].runID == runID)
        #expect(calls[0].toolName == SSHCreateHostTool.name)
        #expect(calls[0].fieldPath == "credentialInput")
        #expect(calls[0].expectedKind == .sshPrivateKey)
        #expect(calls[0].hostID == saved.id)
        #expect(calls[1].input == Data(vncPlaceholder.utf8))
        #expect(calls[1].fieldPath == "vncConnections.0.credentialInput")
        #expect(calls[1].expectedKind == .vncPassword)
        #expect(calls[1].hostID == saved.id)
        #expect(await sshWriter.value?.input == Data("resolved-ssh".utf8))
        #expect(await vncWriter.value?.input == Data("resolved-vnc".utf8))
        #expect(await resolver.consumed == ["credentialInput", "vncConnections.0.credentialInput"])
        #expect(!output.summary.contains(sshPlaceholder))
        #expect(!output.summary.contains(vncPlaceholder))
        let auth = try JSONDecoder().decode(SSHAuthMethod.self, from: Data(saved.authJSON.utf8))
        guard case .deviceGeneratedKey = auth else {
            Issue.record("Expected device-generated key authentication")
            return
        }
    }

    @Test("Create host rejects unsafe auth and identity combinations")
    func createHostValidation() async throws {
        let store = try await makeStore()
        let tool = SSHCreateHostTool(
            store: store,
            credentialWriter: { hostID, _, _, _ in
                SecretReference(keychainAccount: "host.ssh.\(hostID.uuidString)", synchronizable: false)
            },
            secretDeleter: { _ in }
        )
        let noAuth = try JSONDecoder().decode(
            SSHCreateHostTool.Arguments.self,
            from: Data(#"{"displayName":"Panel","address":"panel.local","user":"operator","authMethod":"none","isRemoteExecutionEnvironment":true}"#.utf8)
        )
        #expect(throws: (any Error).self) { try tool.validate(noAuth) }

        let pinnedWithoutFingerprint = try JSONDecoder().decode(
            SSHCreateHostTool.Arguments.self,
            from: Data(#"{"displayName":"Panel","address":"panel.local","user":"operator","authMethod":"password","credentialInput":"secret","hostKeyPolicy":"pinned"}"#.utf8)
        )
        #expect(throws: (any Error).self) { try tool.validate(pinnedWithoutFingerprint) }

        let missingCredential = try JSONDecoder().decode(
            SSHCreateHostTool.Arguments.self,
            from: Data(#"{"displayName":"Panel","address":"panel.local","user":"operator","authMethod":"password"}"#.utf8)
        )
        #expect(throws: (any Error).self) { try tool.validate(missingCredential) }

        let badVNC = try JSONDecoder().decode(
            SSHCreateHostTool.Arguments.self,
            from: Data(#"{"displayName":"Panel","address":"panel.local","user":"operator","authMethod":"password","credentialInput":"secret","vncConnections":[{"displayName":"Bad","transport":"direct","host":"","port":5900}]}"#.utf8)
        )
        #expect(throws: (any Error).self) { try tool.validate(badVNC) }
    }

    // MARK: - Authentication changes

    @Test("Set host auth replaces the method and preserves unrelated connections")
    func setHostAuthPreservesConnections() async throws {
        let store = try await makeStore()
        let endpoint = VNCEndpoint(
            id: UUID(), displayName: "Console", transport: .sshTunnel,
            host: "localhost", port: 5900,
            passwordRef: SecretReference(keychainAccount: "host.vnc.existing", synchronizable: false)
        )
        let host = try await seedHost(in: store, vncEndpoints: [endpoint])
        let recorder = SSHCredentialWriterRecorder()
        let tool = SSHSetHostAuthTool(
            store: store,
            credentialWriter: { hostID, input, label, method in
                await recorder.record(hostID: hostID, input: input, label: label, method: method)
                return SecretReference(keychainAccount: "host.ssh.\(hostID.uuidString)", synchronizable: false)
            },
            secretDeleter: { _ in }
        )
        let arguments = try JSONDecoder().decode(
            SSHSetHostAuthTool.Arguments.self,
            from: Data(#"{"hostID":"\#(host.id.uuidString)","authMethod":"deviceKey","credentialInput":"generated-key","keyType":"ed25519"}"#.utf8)
        )
        try tool.validate(arguments)
        _ = try await tool.execute(
            arguments,
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )

        let saved = try #require(await store.host(id: host.id))
        let auth = try JSONDecoder().decode(SSHAuthMethod.self, from: Data(saved.authJSON.utf8))
        guard case .deviceGeneratedKey(_, let keyType) = auth else {
            Issue.record("Expected device key auth")
            return
        }
        #expect(keyType == .ed25519)
        #expect(await recorder.value?.method == .deviceKey)
        #expect(try storedEndpoints(saved) == [endpoint])
        #expect(saved.isRemoteExecutionEnvironment == true)
    }

    @Test("Set host auth none removes the SSH secret and disables execution")
    func removeHostAuth() async throws {
        let store = try await makeStore()
        let host = try await seedHost(in: store)
        let deleter = SSHCredentialDeleterRecorder()
        let tool = SSHSetHostAuthTool(
            store: store,
            credentialWriter: { hostID, _, _, _ in
                SecretReference(keychainAccount: "host.ssh.\(hostID.uuidString)", synchronizable: false)
            },
            secretDeleter: { reference in await deleter.record(reference) }
        )
        let arguments = try JSONDecoder().decode(
            SSHSetHostAuthTool.Arguments.self,
            from: Data(#"{"hostID":"\#(host.id.uuidString)","authMethod":"none"}"#.utf8)
        )
        try tool.validate(arguments)
        let output = try await tool.execute(
            arguments,
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        let saved = try #require(await store.host(id: host.id))
        let auth = try JSONDecoder().decode(SSHAuthMethod.self, from: Data(saved.authJSON.utf8))
        #expect(auth == .none)
        #expect(saved.isRemoteExecutionEnvironment == false)
        #expect(await deleter.value?.keychainAccount == "host.ssh.seeded")
        let json = try summaryJSON(output)
        #expect(json["credentialRemoved"] as? Bool == true)
    }

    // MARK: - Non-destructive endpoint editing

    @Test("Update host merges endpoint operations and preserves unmentioned connections")
    func updateHostMergesEndpoints() async throws {
        let store = try await makeStore()
        let endpointA = VNCEndpoint(
            id: UUID(), displayName: "A", transport: .direct, host: "a.local", port: 5900,
            passwordRef: SecretReference(keychainAccount: "host.vnc.a", synchronizable: false)
        )
        let endpointB = VNCEndpoint(
            id: UUID(), displayName: "B", transport: .sshTunnel, host: "localhost", port: 5901,
            passwordRef: SecretReference(keychainAccount: "host.vnc.b", synchronizable: false)
        )
        let auxiliary = RemoteAuxiliaryConnection(
            id: UUID(), displayName: "Console", kind: .telnet, host: "a.local", port: 23
        )
        let host = try await seedHost(
            in: store,
            vncEndpoints: [endpointA, endpointB],
            auxiliary: [auxiliary]
        )
        let writer = VNCWriterRecorder()
        let deleter = VNCDeleterRecorder()
        let observer = HostUpdateRecorder()
        let tool = SSHUpdateHostTool(
            store: store,
            passwordWriter: { hostID, connectionID, input in
                await writer.record(hostID: hostID, connectionID: connectionID, input: input)
                return SecretReference(
                    keychainAccount: "host.vnc.\(hostID.uuidString).\(connectionID.uuidString)",
                    synchronizable: false
                )
            },
            secretDeleter: { reference in await deleter.record(reference) },
            updateObserver: { hostID, endpointIDs in
                await observer.record(hostID: hostID, endpointIDs: endpointIDs)
            }
        )
        let addedID = UUID()
        let arguments = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"""
            {
              "hostID": "\#(host.id.uuidString)",
              "updateVNCConnections": [
                {"id": "\#(endpointB.id.uuidString)", "displayName": "B renamed", "transport": "sshTunnel", "host": "localhost", "port": 5902}
              ],
              "addVNCConnections": [
                {"id": "\#(addedID.uuidString)", "displayName": "C", "transport": "direct", "host": "c.local", "port": 5900, "credentialInput": "c-secret"}
              ],
              "removeVNCConnectionIDs": ["\#(endpointA.id.uuidString)"]
            }
            """#.utf8)
        )
        try tool.validate(arguments)
        let output = try await tool.execute(
            arguments,
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )

        let saved = try #require(await store.host(id: host.id))
        let endpoints = try storedEndpoints(saved)
        #expect(endpoints.count == 2)
        #expect(endpoints.contains { $0.id == endpointB.id && $0.displayName == "B renamed" && $0.port == 5902 })
        #expect(endpoints.first { $0.id == endpointB.id }?.passwordRef?.keychainAccount == "host.vnc.b")
        #expect(endpoints.contains { $0.id == addedID && $0.passwordRef != nil })
        #expect(!endpoints.contains { $0.id == endpointA.id })
        #expect(try storedAuxiliary(saved) == [auxiliary])
        #expect(await writer.value?.input == Data("c-secret".utf8))
        #expect(await deleter.value?.account == "host.vnc.a")
        #expect(await observer.value?.endpointIDs == Set([endpointA.id, endpointB.id, addedID]))
        let json = try summaryJSON(output)
        #expect(json["configuredVNCCount"] as? Int == 2)
        #expect(json["credentialsUpdated"] as? Int == 1)
        #expect(json["credentialsRemoved"] as? Int == 1)
    }

    @Test("Update host resolves operation references at their exact array paths")
    func updateHostOperationPathsUseExactArrayIndex() async throws {
        let store = try await makeStore()
        let existing = VNCEndpoint(
            id: UUID(), displayName: "A", transport: .direct, host: "a.local", port: 5900,
            passwordRef: SecretReference(keychainAccount: "host.vnc.existing", synchronizable: false)
        )
        let host = try await seedHost(in: store, vncEndpoints: [existing])
        let resolver = CredentialResolverRecorder()
        let writer = VNCWriterRecorder()
        let addedID = UUID()
        let updatePlaceholder = "⟨credential:55555555-5555-5555-5555-555555555555⟩"
        let addPlaceholder = "⟨credential:66666666-6666-6666-6666-666666666666⟩"
        let tool = SSHUpdateHostTool(
            store: store,
            passwordWriter: { hostID, connectionID, input in
                await writer.record(hostID: hostID, connectionID: connectionID, input: input)
                return SecretReference(
                    keychainAccount: "host.vnc.\(hostID.uuidString).\(connectionID.uuidString).new",
                    synchronizable: false
                )
            },
            secretDeleter: { _ in },
            credentialInputResolver: { input, slot in
                await resolver.record(input, slot: slot)
                return CredentialInputResolution(secret: Data("resolved-\(slot.fieldPath)".utf8)) {
                    await resolver.consume(slot.fieldPath)
                }
            }
        )
        let runID = UUID()
        var context = ToolContext(runID: runID, cancellation: CancellationToken())
        context.executionToolName = SSHUpdateHostTool.name
        let arguments = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"""
            {
              "hostID": "\#(host.id.uuidString)",
              "updateVNCConnections": [
                {"id": "\#(existing.id.uuidString)", "displayName": "A2", "transport": "direct", "host": "a.local", "port": 5901, "credentialInput": "\#(updatePlaceholder)"}
              ],
              "addVNCConnections": [
                {"id": "\#(addedID.uuidString)", "displayName": "B", "transport": "direct", "host": "b.local", "port": 5900, "password": "\#(addPlaceholder)"}
              ]
            }
            """#.utf8)
        )
        try tool.validate(arguments)
        let output = try await tool.execute(arguments, context: context)

        let calls = await resolver.calls
        #expect(calls.count == 2)
        #expect(calls[0].fieldPath == "updateVNCConnections.0.credentialInput")
        #expect(calls[0].expectedKind == .vncPassword)
        #expect(calls[0].runID == runID)
        #expect(calls[0].toolName == SSHUpdateHostTool.name)
        #expect(calls[0].hostID == host.id)
        #expect(calls[1].fieldPath == "addVNCConnections.0.password")
        #expect(calls[1].expectedKind == .vncPassword)
        #expect(await resolver.consumed == [
            "updateVNCConnections.0.credentialInput",
            "addVNCConnections.0.password"
        ])
        #expect(await writer.value?.input == Data("resolved-addVNCConnections.0.password".utf8))
        #expect(!output.summary.contains(updatePlaceholder))
        #expect(!output.summary.contains(addPlaceholder))
        let saved = try #require(await store.host(id: host.id))
        let endpoints = try storedEndpoints(saved)
        #expect(endpoints.count == 2)
        #expect(endpoints.first { $0.id == existing.id }?.passwordRef != nil)
        #expect(endpoints.first { $0.id == addedID }?.passwordRef != nil)
    }

    @Test("Update host resolves replacement references at their exact array paths")
    func updateHostReplacementUsesExactArrayPath() async throws {
        let store = try await makeStore()
        let existing = VNCEndpoint(
            id: UUID(), displayName: "A", transport: .direct, host: "a.local", port: 5900,
            passwordRef: SecretReference(keychainAccount: "host.vnc.replacement-old", synchronizable: false)
        )
        let host = try await seedHost(in: store, vncEndpoints: [existing])
        let resolver = CredentialResolverRecorder()
        let writer = VNCWriterRecorder()
        let newID = UUID()
        let firstPlaceholder = "⟨credential:77777777-7777-7777-7777-777777777777⟩"
        let secondPlaceholder = "⟨credential:88888888-8888-8888-8888-888888888888⟩"
        let tool = SSHUpdateHostTool(
            store: store,
            passwordWriter: { hostID, connectionID, input in
                await writer.record(hostID: hostID, connectionID: connectionID, input: input)
                return SecretReference(
                    keychainAccount: "host.vnc.\(hostID.uuidString).\(connectionID.uuidString).new",
                    synchronizable: false
                )
            },
            secretDeleter: { _ in },
            credentialInputResolver: { input, slot in
                await resolver.record(input, slot: slot)
                return CredentialInputResolution(secret: Data("resolved".utf8)) {
                    await resolver.consume(slot.fieldPath)
                }
            }
        )
        let arguments = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"""
            {
              "hostID": "\#(host.id.uuidString)",
              "vncConnections": [
                {"id": "\#(existing.id.uuidString)", "displayName": "A", "transport": "direct", "host": "a.local", "port": 5900, "credentialInput": "\#(firstPlaceholder)"},
                {"id": "\#(newID.uuidString)", "displayName": "B", "transport": "direct", "host": "b.local", "port": 5900, "credentialInput": "\#(secondPlaceholder)"}
              ]
            }
            """#.utf8)
        )
        try tool.validate(arguments)
        _ = try await tool.execute(
            arguments,
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )

        let calls = await resolver.calls
        #expect(calls.count == 2)
        #expect(calls[0].fieldPath == "vncConnections.0.credentialInput")
        #expect(calls[1].fieldPath == "vncConnections.1.credentialInput")
        #expect(await resolver.consumed == [
            "vncConnections.0.credentialInput",
            "vncConnections.1.credentialInput"
        ])
        #expect(await writer.value?.input == Data("resolved".utf8))
        let saved = try #require(await store.host(id: host.id))
        #expect(try storedEndpoints(saved).count == 2)
    }

    @Test("Update host rejects malformed and unresolved references before mutation")
    func updateHostRejectsUnauthorizedReferences() async throws {
        let store = try await makeStore()
        let existing = VNCEndpoint(
            id: UUID(), displayName: "A", transport: .direct, host: "a.local", port: 5900,
            passwordRef: SecretReference(keychainAccount: "host.vnc.unauthorized-old", synchronizable: false)
        )
        let host = try await seedHost(in: store, vncEndpoints: [existing])
        let resolver = CredentialResolverRecorder()
        let malformedWriter = VNCWriterRecorder()
        let malformedTool = SSHUpdateHostTool(
            store: store,
            passwordWriter: { hostID, connectionID, input in
                await malformedWriter.record(hostID: hostID, connectionID: connectionID, input: input)
                return SecretReference(keychainAccount: "unexpected", synchronizable: false)
            },
            secretDeleter: { _ in },
            credentialInputResolver: { input, slot in
                await resolver.record(input, slot: slot)
                return CredentialInputResolution(secret: Data("unexpected".utf8))
            }
        )
        let malformed = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"""
            {"hostID":"\#(host.id.uuidString)","updateVNCConnections":[{"id":"\#(existing.id.uuidString)","displayName":"A","transport":"direct","host":"a.local","port":5900,"credentialInput":"⟨credential:not-a-uuid⟩"}]}
            """#.utf8)
        )
        await #expect(throws: (any Error).self) {
            _ = try await malformedTool.execute(
                malformed,
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }
        #expect(await resolver.calls.isEmpty)
        #expect(await malformedWriter.value == nil)

        let embedded = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"""
            {"hostID":"\#(host.id.uuidString)","updateVNCConnections":[{"id":"\#(existing.id.uuidString)","displayName":"A","transport":"direct","host":"a.local","port":5900,"credentialInput":"prefix ⟨credential:bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb⟩"}]}
            """#.utf8)
        )
        await #expect(throws: (any Error).self) {
            _ = try await malformedTool.execute(
                embedded,
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }
        #expect(await resolver.calls.isEmpty)
        #expect(await malformedWriter.value == nil)

        let unresolvedWriter = VNCWriterRecorder()
        let unresolvedTool = SSHUpdateHostTool(
            store: store,
            passwordWriter: { hostID, connectionID, input in
                await unresolvedWriter.record(hostID: hostID, connectionID: connectionID, input: input)
                return SecretReference(keychainAccount: "unexpected", synchronizable: false)
            },
            secretDeleter: { _ in }
        )
        let unresolved = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"""
            {"hostID":"\#(host.id.uuidString)","updateVNCConnections":[{"id":"\#(existing.id.uuidString)","displayName":"A","transport":"direct","host":"a.local","port":5900,"credentialInput":"⟨credential:99999999-9999-9999-9999-999999999999⟩"}]}
            """#.utf8)
        )
        await #expect(throws: (any Error).self) {
            _ = try await unresolvedTool.execute(
                unresolved,
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }
        #expect(await unresolvedWriter.value == nil)

        let deniedWriter = VNCWriterRecorder()
        let deniedResolver = CredentialResolverRecorder()
        let deniedTool = SSHUpdateHostTool(
            store: store,
            passwordWriter: { hostID, connectionID, input in
                await deniedWriter.record(hostID: hostID, connectionID: connectionID, input: input)
                return SecretReference(keychainAccount: "unexpected", synchronizable: false)
            },
            secretDeleter: { _ in },
            credentialInputResolver: { input, slot in
                await deniedResolver.record(input, slot: slot)
                throw TestFailure.saveFailed
            }
        )
        let denied = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"""
            {"hostID":"\#(host.id.uuidString)","updateVNCConnections":[{"id":"\#(existing.id.uuidString)","displayName":"A","transport":"direct","host":"a.local","port":5900,"credentialInput":"⟨credential:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa⟩"}]}
            """#.utf8)
        )
        await #expect(throws: (any Error).self) {
            _ = try await deniedTool.execute(
                denied,
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }
        let deniedCalls = await deniedResolver.calls
        #expect(deniedCalls.count == 1)
        #expect(await deniedWriter.value == nil)
        let saved = try #require(await store.host(id: host.id))
        #expect(try storedEndpoints(saved) == [existing])
    }

    @Test("Update host replacement remains compatible and removes omitted endpoints")
    func updateHostReplacementCompatibility() async throws {
        let store = try await makeStore()
        let endpointA = VNCEndpoint(
            id: UUID(), displayName: "A", transport: .direct, host: "a.local", port: 5900,
            passwordRef: SecretReference(keychainAccount: "host.vnc.a", synchronizable: false)
        )
        let endpointB = VNCEndpoint(
            id: UUID(), displayName: "B", transport: .direct, host: "b.local", port: 5900,
            passwordRef: SecretReference(keychainAccount: "host.vnc.b", synchronizable: false)
        )
        let host = try await seedHost(in: store, vncEndpoints: [endpointA, endpointB])
        let deleter = VNCDeleterRecorder()
        let tool = SSHUpdateHostTool(
            store: store,
            passwordWriter: nil,
            secretDeleter: { reference in await deleter.record(reference) }
        )
        let arguments = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"""
            {"hostID":"\#(host.id.uuidString)","vncConnections":[{"id":"\#(endpointB.id.uuidString)","displayName":"B only","transport":"direct","host":"b.local","port":5900}]}
            """#.utf8)
        )
        try tool.validate(arguments)
        _ = try await tool.execute(
            arguments,
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        let saved = try #require(await store.host(id: host.id))
        let endpoints = try storedEndpoints(saved)
        #expect(endpoints.count == 1)
        #expect(endpoints.first?.id == endpointB.id)
        #expect(endpoints.first?.passwordRef?.keychainAccount == "host.vnc.b")
        #expect(await deleter.value?.account == "host.vnc.a")
    }

    @Test("Update host disabling SSH removes the old auth revision and fixed alias")
    func updateHostDisableSSHCleansAuth() async throws {
        let store = try await makeStore()
        let oldReference = SecretReference(keychainAccount: "host.ssh.disable-old", synchronizable: false)
        let host = try await seedHost(in: store, auth: .password(oldReference))
        let secretDeleter = SecretReferenceRecorder()
        let aliasDeleted = DeletionActionRecorder()
        let tool = SSHUpdateHostTool(
            store: store,
            secretDeleter: { reference in await secretDeleter.record(reference) },
            aliasDeleter: { hostID in await aliasDeleted.record(hostID) }
        )
        let arguments = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"{"hostID":"\#(host.id.uuidString)","isSSHEnabled":false}"#.utf8)
        )
        try tool.validate(arguments)
        let output = try await tool.execute(
            arguments,
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(await secretDeleter.value?.keychainAccount == oldReference.keychainAccount)
        #expect(await aliasDeleted.value == host.id)
        let saved = try #require(await store.host(id: host.id))
        let auth = try JSONDecoder().decode(SSHAuthMethod.self, from: Data(saved.authJSON.utf8))
        #expect(auth == .none)
        #expect(saved.isRemoteExecutionEnvironment == false)
        let json = try summaryJSON(output)
        #expect(json["sshCredentialRemoved"] as? Bool == true)
    }

    @Test("Update host refuses mixed or unknown endpoint operations before writing")
    func updateHostRejectsUnsafeOperations() async throws {
        let store = try await makeStore()
        let endpoint = VNCEndpoint(
            id: UUID(), displayName: "A", transport: .direct, host: "a.local", port: 5900,
            passwordRef: SecretReference(keychainAccount: "host.vnc.a", synchronizable: false)
        )
        let host = try await seedHost(in: store, vncEndpoints: [endpoint])
        let writer = VNCWriterRecorder()
        let deleter = VNCDeleterRecorder()
        let tool = SSHUpdateHostTool(
            store: store,
            passwordWriter: { hostID, connectionID, input in
                await writer.record(hostID: hostID, connectionID: connectionID, input: input)
                return SecretReference(keychainAccount: "unexpected", synchronizable: false)
            },
            secretDeleter: { reference in await deleter.record(reference) }
        )

        let mixed = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"{"hostID":"\#(host.id.uuidString)","vncConnections":[],"addVNCConnections":[{"displayName":"B","transport":"direct","host":"b.local","port":5900}]}"#.utf8)
        )
        #expect(throws: (any Error).self) { try tool.validate(mixed) }

        let unknown = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"{"hostID":"\#(host.id.uuidString)","removeVNCConnectionIDs":["\#(UUID().uuidString)"]}"#.utf8)
        )
        try tool.validate(unknown)
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(
                unknown,
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }
        #expect(await writer.value == nil)
        #expect(await deleter.value == nil)
        let reloaded = try await store.host(id: host.id)
        #expect(try storedEndpoints(reloaded) == [endpoint])
    }

    // MARK: - Identity verification

    @Test("Verify host requests the canonical task approval for a first-use key")
    func verifyHostApprovesFirstUseKey() async throws {
        let store = try await makeStore()
        let host = try await seedHost(in: store)
        let approval = NestedApprovalRecorder(outcome: .allowed)
        let challenge = HostKeyChallenge(
            hostID: host.id, address: "studio.local", port: 22,
            keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:first-use"
        )
        let probe: SSHHostConnectionProbe = { profile, decision in
            guard await decision(challenge) else {
                throw SSHConnectionError.hostKeyRejected(challenge)
            }
        }
        let tool = SSHVerifyHostTool(store: store, probe: probe)
        let context = ToolContext(
            runID: UUID(),
            cancellation: CancellationToken(),
            nestedApproval: approval.handle
        )
        let output = try await tool.execute(.init(hostID: host.id.uuidString), context: context)

        let json = try summaryJSON(output)
        #expect(output.exitStatus == 0)
        #expect(json["connected"] as? Bool == true)
        #expect(json["authenticated"] as? Bool == true)
        #expect(json["identityVerification"] as? String == "approved")
        #expect(json["hostKeyFingerprint"] as? String == "SHA256:first-use")
        let reason = try #require(approval.reason)
        #expect(reason.contains("SHA256:first-use"))
        #expect(reason.contains("ssh-ed25519"))
    }

    @Test("Verify host fails closed without an interactive approval surface")
    func verifyHostWithoutApprovalSurface() async throws {
        let store = try await makeStore()
        let host = try await seedHost(in: store)
        let challenge = HostKeyChallenge(
            hostID: host.id, address: "studio.local", port: 22,
            keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:needs-approval"
        )
        let probe: SSHHostConnectionProbe = { _, decision in
            guard await decision(challenge) else {
                throw SSHConnectionError.hostKeyRejected(challenge)
            }
        }
        let tool = SSHVerifyHostTool(store: store, probe: probe)
        let output = try await tool.execute(
            .init(hostID: host.id.uuidString),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        let json = try summaryJSON(output)
        #expect(output.exitStatus == 2)
        #expect(json["category"] as? String == "hostKeyRejected")
        #expect(json["identityDecision"] as? String == "unavailable")
        #expect(json["requiresUserAction"] as? Bool == true)
        #expect((json["nextAction"] as? String)?.contains("active conversation") == true)
    }

    @Test("Verify host reports a denied approval without reporting success")
    func verifyHostDeniedApproval() async throws {
        let store = try await makeStore()
        let host = try await seedHost(in: store)
        let approval = NestedApprovalRecorder(outcome: .denied(reason: "not my device"))
        let challenge = HostKeyChallenge(
            hostID: host.id, address: "studio.local", port: 22,
            keyType: "ssh-ed25519", fingerprintSHA256: "SHA256:denied"
        )
        let tool = SSHVerifyHostTool(store: store, probe: { _, decision in
            guard await decision(challenge) else {
                throw SSHConnectionError.hostKeyRejected(challenge)
            }
        })
        let output = try await tool.execute(
            .init(hostID: host.id.uuidString),
            context: ToolContext(
                runID: UUID(),
                cancellation: CancellationToken(),
                nestedApproval: approval.handle
            )
        )
        let json = try summaryJSON(output)
        #expect(output.exitStatus == 2)
        #expect(json["category"] as? String == "hostKeyRejected")
        #expect(json["identityDecision"] as? String == "denied")
    }

    @Test("Verify host never requests approval for a changed fingerprint")
    func verifyHostChangedFingerprintFailsClosed() async throws {
        let store = try await makeStore()
        let host = try await seedHost(
            in: store,
            hostKeyPolicy: "pinned:SHA256:expected"
        )
        let approval = NestedApprovalRecorder(outcome: .allowed)
        let probe: SSHHostConnectionProbe = { _, _ in
            throw SSHConnectionError.hostKeyChanged(
                expected: "SHA256:expected",
                received: "SHA256:received"
            )
        }
        let tool = SSHVerifyHostTool(store: store, probe: probe)
        let output = try await tool.execute(
            .init(hostID: host.id.uuidString),
            context: ToolContext(
                runID: UUID(),
                cancellation: CancellationToken(),
                nestedApproval: approval.handle
            )
        )
        let json = try summaryJSON(output)
        #expect(output.exitStatus == 2)
        #expect(json["category"] as? String == "hostKeyChanged")
        #expect(json["retryable"] as? Bool == false)
        #expect(json["expectedFingerprint"] as? String == "SHA256:expected")
        #expect(json["receivedFingerprint"] as? String == "SHA256:received")
        #expect(approval.reason == nil)
    }

    @Test("Verify host reports pinned identity without an approval request")
    func verifyHostPinnedIdentity() async throws {
        let store = try await makeStore()
        let host = try await seedHost(
            in: store,
            hostKeyPolicy: "pinned:SHA256:pinned-identity"
        )
        let tool = SSHVerifyHostTool(store: store, probe: { _, _ in })
        let output = try await tool.execute(
            .init(hostID: host.id.uuidString),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        let json = try summaryJSON(output)
        #expect(output.exitStatus == 0)
        #expect(json["identityVerification"] as? String == "pinnedMatch")
        #expect(json["hostKeyFingerprint"] as? String == "SHA256:pinned-identity")
    }

    @Test("Verify host reports authentication failure without retry")
    func verifyHostAuthenticationFailure() async throws {
        let store = try await makeStore()
        let host = try await seedHost(in: store)
        let tool = SSHVerifyHostTool(store: store, probe: { profile, _ in
            throw SSHConnectionError.authenticationFailed(
                user: profile.user,
                address: profile.address
            )
        })
        let output = try await tool.execute(
            .init(hostID: host.id.uuidString),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        let json = try summaryJSON(output)
        #expect(output.exitStatus == 2)
        #expect(json["category"] as? String == "authenticationFailed")
        #expect(json["stage"] as? String == "authentication")
        #expect(json["retryable"] as? Bool == false)
        #expect((json["nextAction"] as? String)?.contains("ssh.setHostAuth") == true)
    }

    @Test("Verify host refuses a host without SSH authentication")
    func verifyHostRequiresAuth() async throws {
        let store = try await makeStore()
        let host = try await seedHost(in: store, auth: .none)
        let tool = SSHVerifyHostTool(store: store, probe: { _, _ in })
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(
                .init(hostID: host.id.uuidString),
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }
    }

    // MARK: - Credential revision integrity

    @Test("Set host auth keeps the previous secret when host save fails")
    func setHostAuthSaveFailurePreservesOldSecret() async throws {
        let store = try await makeStore()
        let oldReference = SecretReference(
            keychainAccount: "host.ssh.old-revision",
            synchronizable: false
        )
        let host = try await seedHost(
            in: store,
            auth: .password(oldReference)
        )
        let bag = SecretBag()
        await bag.put(Data("old-password".utf8), at: oldReference)
        let writer = SSHCredentialWriterRecorder()
        let deleter = SecretReferenceRecorder()
        let tool = SSHSetHostAuthTool(
            store: store,
            credentialWriter: { hostID, input, _, method in
                let reference = await bag.stage(input, prefix: "host.ssh.\(hostID.uuidString)")
                await writer.record(hostID: hostID, input: input, label: "Studio mini", method: method)
                return reference
            },
            secretDeleter: { reference in
                await deleter.record(reference)
                await bag.remove(reference)
            },
            saveHostOverride: { _ in throw TestFailure.saveFailed }
        )
        let arguments = try JSONDecoder().decode(
            SSHSetHostAuthTool.Arguments.self,
            from: Data(#"{"hostID":"\#(host.id.uuidString)","authMethod":"deviceKey","credentialInput":"new-key","keyType":"ed25519"}"#.utf8)
        )
        try tool.validate(arguments)
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(
                arguments,
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }

        #expect(await bag.value(oldReference) == Data("old-password".utf8))
        let saved = try #require(await store.host(id: host.id))
        let auth = try JSONDecoder().decode(SSHAuthMethod.self, from: Data(saved.authJSON.utf8))
        #expect(auth == .password(oldReference))
        #expect(await writer.value?.method == .deviceKey)
        let stagedAccounts = await bag.stagedAccounts
        #expect(stagedAccounts.count == 1)
        #expect(await bag.value(SecretReference(keychainAccount: stagedAccounts[0], synchronizable: false)) == nil)
        #expect(await deleter.value?.keychainAccount == stagedAccounts[0])
    }

    @Test("Credential writer failure leaves the previous auth and host untouched")
    func setHostAuthWriterFailurePreservesOldSecret() async throws {
        let store = try await makeStore()
        let oldReference = SecretReference(
            keychainAccount: "host.ssh.old-writer",
            synchronizable: false
        )
        let host = try await seedHost(in: store, auth: .password(oldReference))
        let bag = SecretBag()
        await bag.put(Data("old".utf8), at: oldReference)
        let deleter = SecretReferenceRecorder()
        let tool = SSHSetHostAuthTool(
            store: store,
            credentialWriter: { _, _, _, _ in
                throw TestFailure.saveFailed
            },
            secretDeleter: { reference in await deleter.record(reference) }
        )
        let arguments = try JSONDecoder().decode(
            SSHSetHostAuthTool.Arguments.self,
            from: Data(#"{"hostID":"\#(host.id.uuidString)","authMethod":"password","credentialInput":"new"}"#.utf8)
        )
        try tool.validate(arguments)
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(
                arguments,
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }
        #expect(await bag.value(oldReference) == Data("old".utf8))
        #expect(await deleter.value == nil)
        let saved = try #require(await store.host(id: host.id))
        let auth = try JSONDecoder().decode(SSHAuthMethod.self, from: Data(saved.authJSON.utf8))
        #expect(auth == .password(oldReference))
    }

    @Test("Set host auth resolves the exact capture slot and consumes it after commit")
    func setHostAuthResolvesReferenceWithCanonicalSlot() async throws {
        let store = try await makeStore()
        let oldReference = SecretReference(
            keychainAccount: "host.ssh.canonical-old",
            synchronizable: false
        )
        let host = try await seedHost(in: store, auth: .password(oldReference))
        let resolver = CredentialResolverRecorder()
        let writer = SSHCredentialWriterRecorder()
        let deleter = SecretReferenceRecorder()
        let runID = UUID()
        let placeholder = "⟨credential:33333333-3333-3333-3333-333333333333⟩"
        let tool = SSHSetHostAuthTool(
            store: store,
            credentialWriter: { hostID, input, label, method in
                await writer.record(hostID: hostID, input: input, label: label, method: method)
                return SecretReference(
                    keychainAccount: "host.ssh.\(hostID.uuidString).new",
                    synchronizable: false
                )
            },
            secretDeleter: { reference in await deleter.record(reference) },
            credentialInputResolver: { input, slot in
                await resolver.record(input, slot: slot)
                return CredentialInputResolution(secret: Data("resolved-auth".utf8)) {
                    await resolver.consume(slot.fieldPath)
                }
            }
        )
        var context = ToolContext(runID: runID, cancellation: CancellationToken())
        context.executionToolName = SSHSetHostAuthTool.name
        let arguments = try JSONDecoder().decode(
            SSHSetHostAuthTool.Arguments.self,
            from: Data(#"""
            {"hostID":"\#(host.id.uuidString)","authMethod":"password","credentialInput":"\#(placeholder)"}
            """#.utf8)
        )
        try tool.validate(arguments)
        _ = try await tool.execute(arguments, context: context)

        let calls = await resolver.calls
        #expect(calls.count == 1)
        #expect(calls[0].input == Data(placeholder.utf8))
        #expect(calls[0].runID == runID)
        #expect(calls[0].toolName == SSHSetHostAuthTool.name)
        #expect(calls[0].fieldPath == "credentialInput")
        #expect(calls[0].expectedKind == .sshPassword)
        #expect(calls[0].hostID == host.id)
        #expect(await writer.value?.input == Data("resolved-auth".utf8))
        #expect(await resolver.consumed == ["credentialInput"])
        #expect(await deleter.value == oldReference)
        let saved = try #require(await store.host(id: host.id))
        let auth = try JSONDecoder().decode(SSHAuthMethod.self, from: Data(saved.authJSON.utf8))
        guard case .password(let newReference) = auth else {
            Issue.record("Expected password authentication")
            return
        }
        #expect(newReference.keychainAccount == "host.ssh.\(host.id.uuidString).new")
    }

    @Test("Set host auth save failure leaves the capture retryable and the old secret intact")
    func setHostAuthSaveFailureDoesNotConsumeCapture() async throws {
        let store = try await makeStore()
        let oldReference = SecretReference(
            keychainAccount: "host.ssh.capture-old",
            synchronizable: false
        )
        let host = try await seedHost(in: store, auth: .password(oldReference))
        let bag = SecretBag()
        await bag.put(Data("old".utf8), at: oldReference)
        let resolver = CredentialResolverRecorder()
        let deleter = SecretReferenceRecorder()
        let placeholder = "⟨credential:44444444-4444-4444-4444-444444444444⟩"
        let tool = SSHSetHostAuthTool(
            store: store,
            credentialWriter: { hostID, input, _, _ in
                await bag.stage(input, prefix: "host.ssh.\(hostID.uuidString)")
            },
            secretDeleter: { reference in
                await deleter.record(reference)
                await bag.remove(reference)
            },
            credentialInputResolver: { input, slot in
                await resolver.record(input, slot: slot)
                return CredentialInputResolution(secret: Data("resolved-auth".utf8)) {
                    await resolver.consume(slot.fieldPath)
                }
            },
            saveHostOverride: { _ in throw TestFailure.saveFailed }
        )
        let arguments = try JSONDecoder().decode(
            SSHSetHostAuthTool.Arguments.self,
            from: Data(#"""
            {"hostID":"\#(host.id.uuidString)","authMethod":"password","credentialInput":"\#(placeholder)"}
            """#.utf8)
        )
        try tool.validate(arguments)
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(
                arguments,
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }

        #expect(await resolver.consumed.isEmpty)
        let deletedReference = await deleter.value
        #expect(deletedReference?.keychainAccount.hasPrefix(
            "host.ssh.\(host.id.uuidString).revision"
        ) == true)
        #expect(await bag.value(oldReference) == Data("old".utf8))
        let saved = try #require(await store.host(id: host.id))
        let auth = try JSONDecoder().decode(SSHAuthMethod.self, from: Data(saved.authJSON.utf8))
        #expect(auth == .password(oldReference))
    }

    @Test("Raw credential input never asks the resolver for authority")
    func rawCredentialInputBypassesResolver() async throws {
        let store = try await makeStore()
        let host = try await seedHost(
            in: store,
            auth: .password(SecretReference(keychainAccount: "host.ssh.raw-old", synchronizable: false))
        )
        let resolver = CredentialResolverRecorder()
        let writer = SSHCredentialWriterRecorder()
        let tool = SSHSetHostAuthTool(
            store: store,
            credentialWriter: { hostID, input, label, method in
                await writer.record(hostID: hostID, input: input, label: label, method: method)
                return SecretReference(
                    keychainAccount: "host.ssh.\(hostID.uuidString).raw",
                    synchronizable: false
                )
            },
            secretDeleter: { _ in },
            credentialInputResolver: { input, slot in
                await resolver.record(input, slot: slot)
                throw TestFailure.saveFailed
            }
        )
        let arguments = try JSONDecoder().decode(
            SSHSetHostAuthTool.Arguments.self,
            from: Data(#"{"hostID":"\#(host.id.uuidString)","authMethod":"password","credentialInput":"raw-secret-value"}"#.utf8)
        )
        try tool.validate(arguments)
        _ = try await tool.execute(
            arguments,
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(await resolver.calls.isEmpty)
        #expect(await writer.value?.input == Data("raw-secret-value".utf8))
    }

    @Test("Update host keeps old endpoint secrets when host save fails")
    func updateHostSaveFailurePreservesEndpointSecret() async throws {
        let store = try await makeStore()
        let endpointA = VNCEndpoint(
            id: UUID(), displayName: "A", transport: .direct, host: "a.local", port: 5900,
            passwordRef: SecretReference(keychainAccount: "host.vnc.old-a", synchronizable: false)
        )
        let endpointB = VNCEndpoint(
            id: UUID(), displayName: "B", transport: .direct, host: "b.local", port: 5900,
            passwordRef: SecretReference(keychainAccount: "host.vnc.old-b", synchronizable: false)
        )
        let auxiliary = RemoteAuxiliaryConnection(
            id: UUID(), displayName: "Console", kind: .telnet, host: "a.local", port: 23
        )
        let host = try await seedHost(
            in: store,
            vncEndpoints: [endpointA, endpointB],
            auxiliary: [auxiliary]
        )
        let bag = SecretBag()
        let refA = try #require(endpointA.passwordRef)
        let refB = try #require(endpointB.passwordRef)
        await bag.put(Data("old-a".utf8), at: refA)
        await bag.put(Data("old-b".utf8), at: refB)
        let writer = VNCWriterRecorder()
        let deleter = SecretReferenceRecorder()
        let tool = SSHUpdateHostTool(
            store: store,
            passwordWriter: { hostID, connectionID, input in
                let reference = await bag.stage(
                    input,
                    prefix: "host.vnc.\(hostID.uuidString).\(connectionID.uuidString)"
                )
                await writer.record(hostID: hostID, connectionID: connectionID, input: input)
                return reference
            },
            secretDeleter: { reference in
                await deleter.record(reference)
                await bag.remove(reference)
            },
            saveHostOverride: { _ in throw TestFailure.saveFailed }
        )
        let arguments = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"""
            {
              "hostID": "\#(host.id.uuidString)",
              "updateVNCConnections": [
                {"id": "\#(endpointA.id.uuidString)", "displayName": "A2", "transport": "direct", "host": "a.local", "port": 5901, "credentialInput": "new-a"}
              ]
            }
            """#.utf8)
        )
        try tool.validate(arguments)
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(
                arguments,
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }

        #expect(await bag.value(refA) == Data("old-a".utf8))
        #expect(await bag.value(refB) == Data("old-b".utf8))
        let saved = try #require(await store.host(id: host.id))
        let endpoints = try storedEndpoints(saved)
        #expect(endpoints.first { $0.id == endpointA.id }?.passwordRef == endpointA.passwordRef)
        #expect(endpoints.first { $0.id == endpointB.id }?.passwordRef == endpointB.passwordRef)
        #expect(try storedAuxiliary(saved) == [auxiliary])
        let staged = await bag.stagedAccounts
        #expect(staged.count == 1)
        #expect(await bag.value(SecretReference(keychainAccount: staged[0], synchronizable: false)) == nil)
        #expect(await deleter.value?.keychainAccount == staged[0])
    }

    @Test("Update host never deletes a reference another saved host still uses")
    func updateHostRetainsSharedReference() async throws {
        let store = try await makeStore()
        let shared = SecretReference(keychainAccount: "host.vnc.shared", synchronizable: false)
        let endpointA = VNCEndpoint(
            id: UUID(), displayName: "Shared A", transport: .direct,
            host: "a.local", port: 5900, passwordRef: shared
        )
        let endpointB = VNCEndpoint(
            id: UUID(), displayName: "Shared B", transport: .direct,
            host: "b.local", port: 5900, passwordRef: shared
        )
        let host = try await seedHost(in: store, vncEndpoints: [endpointA])
        _ = try await seedHost(in: store, vncEndpoints: [endpointB])
        let deleter = SecretReferenceRecorder()
        let tool = SSHUpdateHostTool(
            store: store,
            passwordWriter: nil,
            secretDeleter: { reference in await deleter.record(reference) }
        )
        let arguments = try JSONDecoder().decode(
            SSHUpdateHostTool.Arguments.self,
            from: Data(#"""
            {"hostID":"\#(host.id.uuidString)","removeVNCConnectionIDs":["\#(endpointA.id.uuidString)"]}
            """#.utf8)
        )
        try tool.validate(arguments)
        let output = try await tool.execute(
            arguments,
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(await deleter.value == nil)
        let json = try summaryJSON(output)
        #expect(json["credentialsRemoved"] as? Int == 0)
    }

    @Test("Update host deletes a replaced secret only after a successful save", arguments: [false, true])
    func updateHostCommitDeletesReplacedSecret(replacementArray: Bool) async throws {
        let store = try await makeStore()
        let oldReference = SecretReference(keychainAccount: "host.vnc.old-a", synchronizable: false)
        let untouchedReference = SecretReference(keychainAccount: "host.vnc.untouched", synchronizable: false)
        let endpointA = VNCEndpoint(
            id: UUID(), displayName: "A", transport: .direct, host: "a.local", port: 5900,
            passwordRef: oldReference
        )
        let endpointB = VNCEndpoint(
            id: UUID(), displayName: "B", transport: .direct, host: "b.local", port: 5900,
            passwordRef: untouchedReference
        )
        let host = try await seedHost(in: store, vncEndpoints: [endpointA, endpointB])
        let bag = SecretBag()
        await bag.put(Data("old-a".utf8), at: oldReference)
        await bag.put(Data("untouched".utf8), at: untouchedReference)
        let writer = VNCWriterRecorder()
        let deleter = SecretReferenceRecorder()
        let tool = SSHUpdateHostTool(
            store: store,
            passwordWriter: { hostID, connectionID, input in
                let reference = await bag.stage(
                    input,
                    prefix: "host.vnc.\(hostID.uuidString).\(connectionID.uuidString)"
                )
                await writer.record(hostID: hostID, connectionID: connectionID, input: input)
                return reference
            },
            secretDeleter: { reference in
                await deleter.record(reference)
                await bag.remove(reference)
            }
        )
        let collectionKey = replacementArray ? "vncConnections" : "updateVNCConnections"
        var entries: [[String: Any]] = [[
            "id": endpointA.id.uuidString, "displayName": "A", "transport": "direct",
            "host": "a.local", "port": 5900, "credentialInput": "new-a"
        ]]
        if replacementArray {
            // A replacement array includes B explicitly. Its unrelated saved
            // password must survive just as it does in the incremental path.
            entries.append(["id": endpointB.id.uuidString, "displayName": "B", "transport": "direct",
                            "host": "b.local", "port": 5900])
        }
        let arguments = try JSONDecoder().decode(SSHUpdateHostTool.Arguments.self,
            from: JSONSerialization.data(withJSONObject: ["hostID": host.id.uuidString, collectionKey: entries]))
        try tool.validate(arguments)
        let output = try await tool.execute(
            arguments,
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        let saved = try #require(await store.host(id: host.id))
        let endpoints = try storedEndpoints(saved)
        let storedA = try #require(endpoints.first { $0.id == endpointA.id })
        let storedNewReference = try #require(storedA.passwordRef)
        #expect(storedNewReference.keychainAccount.hasPrefix("host.vnc.\(host.id.uuidString).\(endpointA.id.uuidString).revision") == true)
        #expect(await bag.value(oldReference) == nil)
        #expect(await bag.value(untouchedReference) == Data("untouched".utf8))
        #expect(await bag.value(storedNewReference) == Data("new-a".utf8))
        #expect(await deleter.value?.keychainAccount == oldReference.keychainAccount)
        let json = try summaryJSON(output)
        #expect(json["credentialsRemoved"] as? Int == 1)
    }

    @Test("Create host rolls back every staged secret when host save fails")
    func createHostSaveFailureRollsBackStagedSecrets() async throws {
        let store = try await makeStore()
        let bag = SecretBag()
        let tool = SSHCreateHostTool(
            store: store,
            credentialWriter: { hostID, input, _, _ in
                await bag.stage(input, prefix: "host.ssh.\(hostID.uuidString)")
            },
            vncPasswordWriter: { hostID, connectionID, input in
                await bag.stage(
                    input,
                    prefix: "host.vnc.\(hostID.uuidString).\(connectionID.uuidString)"
                )
            },
            secretDeleter: { reference in await bag.remove(reference) },
            saveHostOverride: { _ in throw TestFailure.saveFailed }
        )
        let arguments = try JSONDecoder().decode(
            SSHCreateHostTool.Arguments.self,
            from: Data(#"""
            {
              "displayName": "Rollback",
              "address": "rollback.local",
              "user": "floe",
              "authMethod": "password",
              "credentialInput": "ssh-secret",
              "vncConnections": [
                {"displayName": "Console", "transport": "direct", "host": "rollback.local", "port": 5900, "credentialInput": "vnc-secret"}
              ]
            }
            """#.utf8)
        )
        try tool.validate(arguments)
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(
                arguments,
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }
        #expect(await bag.values.isEmpty)
        let remainingHosts = try await store.hosts()
        #expect(remainingHosts.isEmpty)
    }

    // MARK: - Deletion

    @Test("Deletion closes sessions, removes metadata, then cleans only unshared credentials")
    func deletionCoordinatorOrderingAndSharing() async throws {
        let hostReference = SecretReference(keychainAccount: "host.ssh.host-a", synchronizable: false)
        let sharedEndpointReference = SecretReference(keychainAccount: "host.vnc.shared", synchronizable: false)
        let privateEndpointReference = SecretReference(keychainAccount: "host.vnc.private", synchronizable: false)
        let host = RemoteHostProfile(
            id: UUID(),
            displayName: "Host A",
            address: "a.local",
            user: "floe",
            auth: .password(hostReference),
            vncEndpoints: [
                VNCEndpoint(displayName: "Shared", passwordRef: sharedEndpointReference),
                VNCEndpoint(displayName: "Private", passwordRef: privateEndpointReference)
            ]
        )
        let otherHost = RemoteHostProfile(
            id: UUID(),
            displayName: "Host B",
            address: "b.local",
            user: "floe",
            auth: .password(SecretReference(keychainAccount: "host.ssh.host-b", synchronizable: false)),
            vncEndpoints: [
                VNCEndpoint(displayName: "Borrowed", passwordRef: sharedEndpointReference)
            ]
        )
        let events = DeletionEventRecorder()
        let hooks = SSHHostDeletionHooks(
            shutdownSessions: { hostID in
                await events.record("sessions:\(hostID.uuidString)")
                return 2
            },
            removeMetadata: { hostID in
                await events.record("metadata:\(hostID.uuidString)")
                return true
            },
            cleanupCredentials: { hostID, _, deletable, retained in
                await events.record("cleanup:\(hostID.uuidString)")
                await events.record("deletable:\(deletable.map(\.keychainAccount).joined(separator: ","))")
                await events.record("retained:\(retained.sorted().joined(separator: ","))")
                return SSHHostCredentialCleanupResult(deleted: deletable.count, pending: false)
            }
        )
        let receipt = try await SSHHostDeletionCoordinator.delete(
            host: host,
            otherHosts: [otherHost],
            sharedAccounts: [],
            hooks: hooks
        )

        #expect(receipt.sessionsClosed == 2)
        #expect(receipt.credentialsDeleted == 2)
        #expect(receipt.credentialsRetained == 1)
        #expect(receipt.syncDeferred == true)
        let recorded = await events.value
        #expect(recorded.first == "sessions:\(host.id.uuidString)")
        #expect(recorded[1] == "metadata:\(host.id.uuidString)")
        #expect(recorded[2] == "cleanup:\(host.id.uuidString)")
        #expect(recorded.contains("deletable:host.ssh.host-a,host.vnc.private"))
        #expect(recorded.contains("retained:host.vnc.shared"))
    }

    @Test("Metadata removal failure aborts before credential cleanup")
    func deletionMetadataFailureSkipsCredentials() async throws {
        let hostReference = SecretReference(keychainAccount: "host.ssh.keep", synchronizable: false)
        let host = RemoteHostProfile(
            id: UUID(),
            displayName: "Keep",
            address: "keep.local",
            user: "floe",
            auth: .password(hostReference)
        )
        let events = DeletionEventRecorder()
        let hooks = SSHHostDeletionHooks(
            shutdownSessions: { _ in
                await events.record("sessions")
                return 0
            },
            removeMetadata: { _ in
                await events.record("metadata")
                throw TestFailure.saveFailed
            },
            cleanupCredentials: { _, _, _, _ in
                await events.record("cleanup")
                return SSHHostCredentialCleanupResult(deleted: 0, pending: false)
            }
        )
        await #expect(throws: (any Error).self) {
            _ = try await SSHHostDeletionCoordinator.delete(
                host: host,
                otherHosts: [],
                sharedAccounts: [],
                hooks: hooks
            )
        }
        #expect(await events.value == ["sessions", "metadata"])
    }

    @Test("Shared credential references are never marked deletable")
    func sharedCredentialReferencesRetained() {
        let shared = SecretReference(keychainAccount: "host.vnc.shared", synchronizable: false)
        let cardShared = SecretReference(keychainAccount: "credential.card", synchronizable: false)
        let privateReference = SecretReference(keychainAccount: "host.ssh.private", synchronizable: false)
        let host = RemoteHostProfile(
            id: UUID(),
            displayName: "A",
            address: "a.local",
            user: "floe",
            auth: .password(privateReference),
            vncEndpoints: [
                VNCEndpoint(displayName: "Shared", passwordRef: shared),
                VNCEndpoint(displayName: "Card", passwordRef: cardShared)
            ]
        )
        let otherHost = RemoteHostProfile(
            id: UUID(),
            displayName: "B",
            address: "b.local",
            user: "floe",
            auth: .none,
            vncEndpoints: [VNCEndpoint(displayName: "Borrowed", passwordRef: shared)]
        )
        let deletable = SSHHostCredentialReferences.deletable(
            ownedBy: host,
            otherHosts: [otherHost],
            sharedAccounts: [cardShared.keychainAccount]
        )
        #expect(deletable == [privateReference])
        #expect(SSHHostCredentialReferences.owned(by: host).count == 3)
    }

    @Test("ssh.deleteHost delegates to the injected App action")
    func deleteHostToolDelegates() async throws {
        let store = try await makeStore()
        let host = try await seedHost(in: store)
        let recorder = DeletionActionRecorder()
        let tool = SSHDeleteHostTool(
            store: store,
            deletion: { hostID in
                await recorder.record(hostID)
                return SSHHostDeletionReceipt(
                    sessionsClosed: 1,
                    credentialsDeleted: 2,
                    credentialsRetained: 1,
                    credentialCleanupPending: false,
                    syncDeferred: false
                )
            }
        )
        let output = try await tool.execute(
            .init(hostID: host.id.uuidString),
            context: ToolContext(runID: UUID(), cancellation: CancellationToken())
        )
        #expect(await recorder.value == host.id)
        let json = try summaryJSON(output)
        #expect(json["deleted"] as? Bool == true)
        #expect(json["hostID"] as? String == host.id.uuidString)
        #expect(json["remoteSystemChanged"] as? Bool == false)
        #expect(json["sessionsClosed"] as? Int == 1)
        #expect(json["credentialsDeleted"] as? Int == 2)
        #expect(json["credentialsRetained"] as? Int == 1)
        let remaining = try await store.host(id: host.id)
        #expect(remaining != nil)
    }

    @Test("ssh.deleteHost propagates metadata failure and leaves the profile intact")
    func deleteHostToolFailurePreservesProfile() async throws {
        let store = try await makeStore()
        let host = try await seedHost(in: store)
        let tool = SSHDeleteHostTool(
            store: store,
            deletion: { _ in throw TestFailure.saveFailed }
        )
        await #expect(throws: (any Error).self) {
            _ = try await tool.execute(
                .init(hostID: host.id.uuidString),
                context: ToolContext(runID: UUID(), cancellation: CancellationToken())
            )
        }
        let remaining = try await store.host(id: host.id)
        #expect(remaining != nil)
    }

    @Test("ssh.deleteHost validates an exact UUID")
    func deleteHostToolValidation() throws {
        let store = try DatabaseManager.inMemory()
        let tool = SSHDeleteHostTool(
            store: RemoteHostStore(database: store),
            deletion: { _ in
                SSHHostDeletionReceipt(
                    sessionsClosed: 0,
                    credentialsDeleted: 0,
                    credentialsRetained: 0,
                    credentialCleanupPending: false,
                    syncDeferred: false
                )
            }
        )
        #expect(throws: (any Error).self) {
            try tool.validate(.init(hostID: "not-a-uuid"))
        }
    }
}

// MARK: - Test doubles

private enum TestFailure: Error {
    case saveFailed
}

private actor SecretBag {
    private(set) var values: [String: Data] = [:]
    private(set) var stagedAccounts: [String] = []

    func put(_ data: Data, at reference: SecretReference) {
        values[reference.keychainAccount] = data
    }

    func stage(_ data: Data, prefix: String) -> SecretReference {
        let account = "\(prefix).revision\(stagedAccounts.count + 1)"
        stagedAccounts.append(account)
        values[account] = data
        return SecretReference(keychainAccount: account, synchronizable: false)
    }

    func remove(_ reference: SecretReference) {
        values.removeValue(forKey: reference.keychainAccount)
    }

    func value(_ reference: SecretReference) -> Data? {
        values[reference.keychainAccount]
    }
}

private actor SecretReferenceRecorder {
    private(set) var value: SecretReference?

    func record(_ reference: SecretReference) { value = reference }
}

private actor DeletionEventRecorder {
    private(set) var value: [String] = []

    func record(_ event: String) { value.append(event) }
}

private actor DeletionActionRecorder {
    private(set) var value: UUID?

    func record(_ hostID: UUID) { value = hostID }
}

// MARK: - Recorders

private actor SSHCredentialWriterRecorder {
    struct Value: Sendable {
        var hostID: UUID
        var input: Data
        var label: String
        var method: SSHHostAuthMethodInput
    }

    private(set) var value: Value?

    func record(hostID: UUID, input: Data, label: String, method: SSHHostAuthMethodInput) {
        value = Value(hostID: hostID, input: input, label: label, method: method)
    }
}

private actor SSHCredentialDeleterRecorder {
    private(set) var value: SecretReference?

    func record(_ reference: SecretReference) { value = reference }
}

private actor VNCWriterRecorder {
    struct Value: Sendable {
        var hostID: UUID
        var connectionID: UUID
        var input: Data
    }

    private(set) var value: Value?

    func record(hostID: UUID, connectionID: UUID, input: Data) {
        value = Value(hostID: hostID, connectionID: connectionID, input: input)
    }
}

private actor VNCDeleterRecorder {
    struct Value: Sendable {
        var account: String
    }

    private(set) var value: Value?

    func record(_ reference: SecretReference) {
        value = Value(account: reference.keychainAccount)
    }
}

private actor CredentialResolverRecorder {
    struct Call: Sendable {
        var input: Data
        var runID: UUID
        var toolName: String
        var fieldPath: String
        var expectedKind: CredentialKind
        var hostID: UUID?
    }

    private(set) var calls: [Call] = []
    private(set) var consumed: [String] = []

    func record(_ input: Data, slot: CredentialInputSlot) {
        calls.append(Call(
            input: input,
            runID: slot.runID,
            toolName: slot.toolName,
            fieldPath: slot.fieldPath,
            expectedKind: slot.expectedKind,
            hostID: slot.hostID
        ))
    }

    func consume(_ fieldPath: String) {
        consumed.append(fieldPath)
    }
}

private actor HostUpdateRecorder {
    struct Value: Sendable {
        var hostID: UUID
        var endpointIDs: Set<UUID>
    }

    private(set) var value: Value?

    func record(hostID: UUID, endpointIDs: Set<UUID>) {
        value = Value(hostID: hostID, endpointIDs: endpointIDs)
    }
}

private final class NestedApprovalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: NestedApprovalOutcome
    private var recordedReason: String?

    init(outcome: NestedApprovalOutcome) {
        self.outcome = outcome
    }

    var reason: String? { lock.withLock { recordedReason } }

    var handle: RuntimeNestedApprovalHandle {
        RuntimeNestedApprovalHandle { [weak self] reason in
            guard let self else { return .unavailable }
            self.lock.withLock { self.recordedReason = reason }
            return self.outcome
        }
    }
}
