import Foundation
import Testing
import FloeCore
@testable import FloeSSH

@Suite("FloeSSH transport contract (Android)")
struct SSHTransportContractTests {
    private func profile() -> RemoteHostProfile {
        RemoteHostProfile(
            displayName: "Test host",
            address: "server.example",
            port: 2222,
            user: "operator",
            auth: .password(SecretReference(keychainAccount: "floe.ssh.test.password", synchronizable: false))
        )
    }

    @Test("Authentication failures preserve actionable reasons without secrets")
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
        #expect(normalized.category == .authenticationFailed)
        #expect(normalized.stage == .authentication)
        #expect(normalized.retryable == false)
        #expect(normalized.toolSummary.contains(#""category":"authenticationFailed""#))
        #expect(!normalized.toolSummary.lowercased().contains("hunter2"))
    }

    @Test("Transport failures preserve timeout and refusal categories")
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
        #expect(timeout.retryable)
        #expect(refused.retryable)
        #expect(timeout.toolSummary.contains(#""stage":"transport""#))
    }

    @Test("Changed host keys carry the exact observed challenge")
    func changedKeyCarriesChallenge() {
        let challenge = HostKeyChallenge(
            hostID: UUID(),
            address: "server.example",
            port: 22,
            keyType: "ssh-ed25519",
            fingerprintSHA256: "SHA256:new"
        )
        let error = SSHConnectionError.hostKeyChanged(
            expected: "SHA256:old",
            received: "SHA256:new",
            challenge: challenge
        )
        #expect(error.category == .hostKeyChanged)
        #expect(error.stage == .hostKeyVerification)
        #expect(error.retryable == false)
        #expect(error.target == "server.example:22")
        if case .hostKeyChanged(_, _, let carried) = error {
            #expect(carried == challenge)
        } else {
            Issue.record("Expected hostKeyChanged")
        }
    }
}
