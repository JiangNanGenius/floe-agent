// FloeCoreTests — ProviderProfile validation boundaries.

import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.ProviderProfile")
struct ProviderProfileTests {

    private func profile(url: String, allowsPlainHTTP: Bool = false) -> ProviderProfile {
        ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIResponses,
            baseURL: URL(string: url)!,
            allowsPlainHTTP: allowsPlainHTTP
        )
    }

    @Test("Public HTTPS passes validation")
    func publicHTTPSPasses() throws {
        try profile(url: "https://api.openai.com").validate()
    }

    @Test("Public plain HTTP is rejected without acknowledgement")
    func publicHTTPRejected() {
        #expect(throws: FloeError.self) {
            try profile(url: "http://api.example.com").validate()
        }
    }

    @Test("Public plain HTTP is rejected even with acknowledgement")
    func publicHTTPRejectedWithAck() {
        #expect(throws: FloeError.self) {
            try profile(url: "http://203.0.113.10:8080", allowsPlainHTTP: true).validate()
        }
    }

    @Test("Localhost plain HTTP passes with acknowledgement")
    func localhostHTTPPasses() throws {
        try profile(url: "http://localhost:11434", allowsPlainHTTP: true).validate()
        try profile(url: "http://127.0.0.1:11434", allowsPlainHTTP: true).validate()
        try profile(url: "http://[::1]:8080", allowsPlainHTTP: true).validate()
    }

    @Test("RFC 1918 plain HTTP passes with acknowledgement")
    func privateNetworkHTTPPasses() throws {
        try profile(url: "http://10.0.0.5:8080", allowsPlainHTTP: true).validate()
        try profile(url: "http://192.168.1.20:8080", allowsPlainHTTP: true).validate()
        try profile(url: "http://172.16.0.3:8080", allowsPlainHTTP: true).validate()
        try profile(url: "http://172.31.255.255:8080", allowsPlainHTTP: true).validate()
        try profile(url: "http://169.254.1.1:8080", allowsPlainHTTP: true).validate()
    }

    @Test("172.15.x and 172.32.x are NOT private (boundary)")
    func privateRangeBoundary() {
        #expect(throws: FloeError.self) {
            try profile(url: "http://172.15.0.1:8080", allowsPlainHTTP: true).validate()
        }
        #expect(throws: FloeError.self) {
            try profile(url: "http://172.32.0.1:8080", allowsPlainHTTP: true).validate()
        }
    }

    @Test("Non-HTTP schemes are rejected")
    func nonHTTPSchemesRejected() {
        #expect(throws: FloeError.self) {
            try profile(url: "ftp://example.com").validate()
        }
    }

    @Test("Endpoint URL user info is rejected")
    func endpointUserInfoRejected() {
        #expect(throws: FloeError.self) {
            try profile(url: "https://user:password@example.com").validate()
        }
    }

    @Test("Provider display names are bounded single-line metadata")
    func displayNameValidation() throws {
        var valid = profile(url: "https://example.com")
        valid.displayName = "Company Gateway"
        try valid.validate()

        var multiline = valid
        multiline.displayName = "Company\nGateway"
        #expect(throws: FloeError.self) { try multiline.validate() }

        var oversized = valid
        oversized.displayName = String(repeating: "a", count: 257)
        #expect(throws: FloeError.self) { try oversized.validate() }
    }

    @Test("Secret-shaped non-secret headers are rejected case-insensitively")
    func secretHeadersRejected() {
        for name in ["Authorization", "x-api-key", "Cookie", "Proxy-Authorization"] {
            var candidate = profile(url: "https://example.com")
            candidate.nonSecretHeaders = [name: "must-not-enter-synced-metadata"]
            #expect(throws: FloeError.self) {
                try candidate.validate()
            }
        }
    }

    @Test("ModelProtocol Codable round-trip for all cases")
    func modelProtocolRoundTrip() throws {
        for value in ModelProtocol.allCases {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(ModelProtocol.self, from: data)
            #expect(decoded == value)
        }
    }

    @Test("ModelCapabilities OptionSet composition")
    func capabilitiesComposition() {
        let caps: ModelCapabilities = [.text, .tools, .approval]
        #expect(caps.contains(.text))
        #expect(caps.contains(.tools))
        #expect(caps.contains(.approval))
        #expect(!caps.contains(.vision))
    }

    @Test("Unspecified output uses a bounded local safety budget")
    func unspecifiedOutputSafetyBudget() {
        let ordinary = ModelLimits(contextTokens: 128_000, maxOutputTokens: 0)
        #expect(ordinary.configuredMaxOutputTokens == nil)
        #expect(ordinary.clientOutputSafetyBytes == 2_048_000)

        let extreme = ModelLimits(contextTokens: Int.max, maxOutputTokens: Int.max)
        #expect(extreme.clientOutputSafetyBytes == 8 * 1_024 * 1_024)
    }
}
