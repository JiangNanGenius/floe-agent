import Foundation
import Testing
@testable import FloeSSH

@Suite("FloeSSH remote device profiles")
struct RemoteDeviceProfileTests {
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
}
