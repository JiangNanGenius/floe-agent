// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeMacVNC

@Suite("VNC failure normalization")
struct MacVNCFailureNormalizationTests {
    private func failure(
        _ description: String,
        domain: String = "test",
        code: Int = 1,
        passwordConfigured: Bool = true
    ) -> MacVNCConnectionFailure {
        let error = NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: description])
        return MacVNCConnectionFailure.normalized(
            error, host: "10.0.0.2", port: 5900, passwordConfigured: passwordConfigured
        )
    }

    @Test func authenticationRejectionWithPasswordIsAuthFailure() {
        let result = failure("Authentication failed")
        #expect(result.category == .authenticationFailed)
        #expect(result.stage == .authentication)
        #expect(result.retryable == false)
        #expect(result.host == "10.0.0.2")
        #expect(result.port == 5900)
    }

    @Test func authenticationRejectionWithoutPasswordIsCredentialMissing() {
        let result = failure("password invalid", passwordConfigured: false)
        #expect(result.category == .credentialMissing)
        #expect(result.stage == .credentialResolution)
        #expect(result.retryable == false)
    }

    @Test func timeoutsAreRetryableTransportFailures() {
        let result = failure("The operation timed out")
        #expect(result.category == .timedOut)
        #expect(result.stage == .transport)
        #expect(result.retryable == true)
    }

    @Test func refusedConnectionsAreRetryable() {
        let result = failure("Connection refused")
        #expect(result.category == .connectionRefused)
        #expect(result.stage == .transport)
        #expect(result.retryable == true)
    }

    @Test func unreachableHostsAreRetryable() {
        let result = failure("No route to host")
        #expect(result.category == .networkUnreachable)
        #expect(result.stage == .transport)
        #expect(result.retryable == true)
    }

    @Test func dnsFailuresAreUnreachable() {
        let result = failure("nodename nor servname not known, or DNS error")
        #expect(result.category == .networkUnreachable)
        #expect(result.message.contains("resolved"))
    }

    @Test func protocolMismatchesAreTerminal() {
        let result = failure("Unsupported protocol version")
        #expect(result.category == .protocolIncompatible)
        #expect(result.stage == .handshake)
        #expect(result.retryable == false)
    }

    @Test func unknownErrorsFallBackToHandshakeFailure() {
        let result = failure("")
        #expect(result.category == .handshakeFailed)
        #expect(result.stage == .handshake)
        #expect(result.retryable == true)
        #expect(result.underlyingCode == "test:1")
    }

    @Test func normalizedFailuresAreSecretFree() {
        let result = failure("password=leaked auth token")
        #expect(!result.message.contains("leaked"))
        #expect(!result.message.contains("token"))
    }
}
