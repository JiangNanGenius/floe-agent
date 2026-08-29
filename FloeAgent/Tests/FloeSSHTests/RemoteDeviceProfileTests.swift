import Foundation
import Testing
@testable import FloeSSH

@Suite("FloeSSH remote device profiles")
struct RemoteDeviceProfileTests {
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

    @Test("Connection failures preserve actionable authentication reasons")
    func authenticationFailureReason() {
        let error = NSError(
            domain: "Citadel",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Permission denied (publickey,password)"]
        )
        let normalized = SSHConnectionService.normalizedConnectionError(error, profile: profile())

        guard case .authenticationFailed(let user, let address) = normalized else {
            Issue.record("Expected authenticationFailed, got \(normalized)")
            return
        }
        #expect(user == "operator")
        #expect(address == "server.example")
        #expect(normalized.localizedDescription.contains("saved password/key"))
    }

    @Test("Connection failures preserve timeout and refusal reasons")
    func transportFailureReasons() {
        let timeout = SSHConnectionService.normalizedConnectionError(
            NSError(domain: NSPOSIXErrorDomain, code: 60),
            profile: profile()
        )
        let refused = SSHConnectionService.normalizedConnectionError(
            NSError(domain: NSPOSIXErrorDomain, code: 61),
            profile: profile()
        )

        guard case .timedOut(let address, let port) = timeout else {
            Issue.record("Expected timedOut, got \(timeout)")
            return
        }
        #expect(address == "server.example")
        #expect(port == 2222)
        guard case .connectionRefused(let refusedAddress, let refusedPort) = refused else {
            Issue.record("Expected connectionRefused, got \(refused)")
            return
        }
        #expect(refusedAddress == "server.example")
        #expect(refusedPort == 2222)
    }
}
