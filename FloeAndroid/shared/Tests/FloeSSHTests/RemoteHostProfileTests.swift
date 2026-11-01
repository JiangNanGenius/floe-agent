import Foundation
import Testing
import FloeCore
@testable import FloeSSH

@Suite("FloeSSH remote host profiles (Android)")
struct RemoteHostProfileTests {
    private func profile() -> RemoteHostProfile {
        RemoteHostProfile(
            displayName: "Test host",
            address: "server.example",
            port: 2222,
            user: "operator",
            auth: .none
        )
    }

    @Test("Legacy VNC metadata remains an SSH tunnel")
    func legacyVNCDecoding() throws {
        let endpoint = try JSONDecoder().decode(
            VNCEndpoint.self,
            from: Data(#"{"host":"localhost","port":5901}"#.utf8)
        )

        #expect(endpoint.transport == .sshTunnel)
        #expect(endpoint.displayName == "VNC")
        #expect(endpoint.host == "localhost")
        #expect(endpoint.port == 5901)
    }

    @Test("A direct-only management device does not require SSH")
    func directOnlyDevice() throws {
        let profile = RemoteHostProfile(
            displayName: "Lab display",
            address: "",
            user: "",
            auth: .none,
            deviceKind: .appliance,
            isRemoteExecutionEnvironment: false,
            vncEndpoints: [
                VNCEndpoint(transport: .direct, host: "display.local", port: 5900)
            ]
        )

        try profile.validate()
        #expect(profile.hasSSHConnection == false)
    }

    @Test("Guardian execution environments still require SSH")
    func guardianRequiresSSH() {
        let profile = RemoteHostProfile(
            displayName: "Incomplete executor",
            address: "",
            user: "",
            auth: .none,
            isRemoteExecutionEnvironment: true
        )

        #expect(throws: (any Error).self) {
            try profile.validate()
        }
    }

    @Test("Jump chain is bounded and every hop needs a credential")
    func jumpChainValidation() throws {
        let reference = SecretReference(keychainAccount: "floe.ssh.test.jump", synchronizable: false)
        let hop = JumpHop(address: "jump.example", port: 22, user: "jump", auth: .password(reference))
        var profile = RemoteHostProfile(
            displayName: "Jumped",
            address: "target.example",
            user: "target",
            auth: .password(reference),
            jumpChain: Array(repeating: hop, count: RemoteHostProfile.maxJumpHops)
        )
        try profile.validate()

        profile.jumpChain.append(hop)
        #expect(throws: (any Error).self) { try profile.validate() }

        profile.jumpChain = [JumpHop(address: "jump.example", user: "jump", auth: .none)]
        #expect(throws: (any Error).self) { try profile.validate() }
    }

    @Test("Stored profile JSON carries references, never secret bytes")
    func storedProfileCarriesReferencesOnly() throws {
        let reference = SecretReference(keychainAccount: "floe.ssh.profile.password", synchronizable: false)
        let profile = RemoteHostProfile(
            displayName: "Persisted",
            address: "server.example",
            user: "operator",
            auth: .password(reference)
        )
        let row = try profile.storedHost()

        #expect(row.authJSON.contains("floe.ssh.profile.password"))
        #expect(!row.authJSON.contains("hunter2"))
        #expect(row.authJSON.contains("\"password\""))
        #expect(row.hostKeyPolicy == "trustOnFirstUse")

        let decoded = try RemoteHostProfile(stored: row)
        #expect(decoded.auth == .password(reference))
    }

    @Test("Pinned fingerprints are normalized before storage")
    func pinnedFingerprintStorage() throws {
        let profile = RemoteHostProfile(
            displayName: "Pinned",
            address: "server.example",
            user: "operator",
            auth: .password(SecretReference(keychainAccount: "floe.ssh.pinned.key", synchronizable: false)),
            hostKeyPolicy: .pinned(fingerprintSHA256: "SHA256:abc=")
        )
        let row = try profile.storedHost()
        #expect(row.hostKeyPolicy == "pinned:SHA256:abc=")
        let decoded = try RemoteHostProfile(stored: row)
        #expect(decoded.hostKeyPolicy == .pinned(fingerprintSHA256: "SHA256:abc="))
    }
}
