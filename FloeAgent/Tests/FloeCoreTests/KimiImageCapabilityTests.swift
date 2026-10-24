// FloeCoreTests — Kimi Code endpoint identity. The image adapter is exposed
// only for the exact route variants with grounded upstream evidence
// (https api.kimi.com, path /coding or /coding/v1, no query/fragment):
// identity is host PLUS verified path scope, never host alone. The Moonshot
// platform API, the bare host, unknown paths and unrelated proxies must not
// be reclassified, and host comparison must be exact, not substring.

import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.KimiImageCapability")
struct KimiImageCapabilityTests {

    private func profile(_ base: String, presetID: String? = nil) -> ProviderProfile {
        ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: base)!,
            presetID: presetID
        )
    }

    @Test("Only the verified Kimi Code route variants are recognized")
    func verifiedVariantsMatch() {
        #expect(KimiCodeEndpointIdentity.apiHosts == ["api.kimi.com"])
        #expect(KimiCodeEndpointIdentity.basePathVariants == ["/coding", "/coding/v1"])
        // Coding Plan default base without the OpenAI-compatible suffix…
        #expect(KimiCodeEndpointIdentity.matches(profile("https://api.kimi.com/coding")))
        // …and with it…
        #expect(KimiCodeEndpointIdentity.matches(profile("https://api.kimi.com/coding/v1")))
        // Case- and trailing-slash-insensitive.
        #expect(KimiCodeEndpointIdentity.matches(profile("https://API.KIMI.COM/Coding/V1")))
        #expect(KimiCodeEndpointIdentity.matches(profile("https://api.kimi.com/coding/")))
    }

    @Test("The API root always resolves to the verified /coding/v1 path")
    func apiRootNormalization() throws {
        let codingOnly = try #require(KimiCodeEndpointIdentity.apiRoot(for: URL(string: "https://api.kimi.com/coding")!))
        #expect(codingOnly.absoluteString == "https://api.kimi.com/coding/v1")
        let withV1 = try #require(KimiCodeEndpointIdentity.apiRoot(for: URL(string: "https://api.kimi.com/coding/v1")!))
        #expect(withV1.absoluteString == "https://api.kimi.com/coding/v1")
        let trailing = try #require(KimiCodeEndpointIdentity.apiRoot(for: URL(string: "https://api.kimi.com/coding/v1/")!))
        #expect(trailing.absoluteString == "https://api.kimi.com/coding/v1")
        let cased = try #require(KimiCodeEndpointIdentity.apiRoot(for: URL(string: "https://api.kimi.com/Coding")!))
        #expect(cased.absoluteString == "https://api.kimi.com/coding/v1")
    }

    @Test("Related or unevidenced bases are never reclassified")
    func unevidencedBasesDoNotMatch() {
        // Host alone proves nothing about the route: the bare root and any
        // other path are rejected rather than guessed.
        #expect(!KimiCodeEndpointIdentity.matches(profile("https://api.kimi.com")))
        #expect(!KimiCodeEndpointIdentity.matches(profile("https://api.kimi.com/")))
        #expect(!KimiCodeEndpointIdentity.matches(profile("https://api.kimi.com/v1")))
        #expect(!KimiCodeEndpointIdentity.matches(profile("https://api.kimi.com/coding/v2")))
        #expect(!KimiCodeEndpointIdentity.matches(profile("https://api.kimi.com/coding/models")))
        // Query or fragment spellings are not evidenced either.
        #expect(!KimiCodeEndpointIdentity.matches(profile("https://api.kimi.com/coding/v1?key=abc")))
        // Plain HTTP to the coding path is rejected by identity, not just by
        // profile validation.
        #expect(!KimiCodeEndpointIdentity.matches(profile("http://api.kimi.com/coding/v1")))
        // Exact host compare, not a substring sweep.
        #expect(!KimiCodeEndpointIdentity.matches(profile("https://api.kimi.com.attacker.example/coding/v1")))
        #expect(!KimiCodeEndpointIdentity.matches(profile("https://proxy.example.com/coding/v1")))
        #expect(!KimiCodeEndpointIdentity.matches(profile("https://localhost:8443/coding/v1")))
    }

    @Test("Moonshot platform presets never gain the image route")
    func platformPresetIdentityIsNotEnough() {
        // A conversation provider imported from the Moonshot catalog preset
        // keeps zero image capability: no upstream image evidence exists for
        // the platform API hosts.
        let platform = profile("https://api.moonshot.ai/v1", presetID: "moonshot")
        #expect(!KimiCodeEndpointIdentity.matches(platform))
        #expect(KimiCodeEndpointIdentity.apiRoot(for: platform.baseURL) == nil)
        #expect(platform.presetID == "moonshot")
    }
}
