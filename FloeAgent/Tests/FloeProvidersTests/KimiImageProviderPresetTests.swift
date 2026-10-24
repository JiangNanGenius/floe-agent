// FloeProvidersTests — Native Kimi Code supplier entry and saved identity.
// Offline: factory/metadata only; no credentials or account requests.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

@Suite("FloeProviders.KimiImageProviderPreset")
struct KimiImageProviderPresetTests {
    @Test("The native image supplier list contains Kimi Code without a catalog")
    func nativeImageSupplier() throws {
        let preset = try #require(ProviderPreset.imagePresets.first { $0.id == .kimiCode })
        #expect(preset.displayName == "Kimi Code")
        #expect(preset.kind == .custom)
        #expect(preset.defaultBaseURL.absoluteString == "https://api.kimi.com/coding/v1")
        #expect(preset.defaultProtocol == .openAIChatCompletions)
        #expect(preset.supportedProtocols == [.openAIChatCompletions])
        #expect(preset.supportsModelDiscovery)
        #expect(preset.authStyle == .bearer)
        let profile = ProviderProfile(
            kind: preset.kind,
            wireProtocol: preset.defaultProtocol,
            baseURL: preset.defaultBaseURL,
            presetID: preset.id.rawValue
        )
        #expect(ImageProviderAdapterFactory().adapter(for: profile) is KimiImageAdapter)
        #expect(profile.secretRef == nil)
        #expect(ProviderServiceOfferResolver.officialModelIDs(for: preset.kind, role: .image).isEmpty)
    }

    @Test("Saved Kimi endpoints resolve to the named template without changing aliases")
    func savedEndpointIdentity() {
        for endpoint in ["https://api.kimi.com/coding", "https://api.kimi.com/coding/v1/"] {
            let profile = ProviderProfile(
                kind: .custom,
                wireProtocol: .openAIChatCompletions,
                baseURL: URL(string: endpoint)!,
                displayName: "My image account"
            )
            let preset = ProviderPreset.preset(for: profile.kind, baseURL: profile.baseURL)
            #expect(preset.id == .kimiCode)
            #expect((profile.displayName ?? preset.displayName) == "My image account")
        }
        #expect(ProviderPreset.preset(for: .custom).id == .custom)
        #expect(ProviderPreset.preset(
            for: .custom, baseURL: URL(string: "https://api.moonshot.ai/v1")
        ).id == .custom)
        #expect(ProviderPreset.preset(
            for: .custom, baseURL: URL(string: "https://api.kimi.com")
        ).id == .custom)
    }

    @Test("Template identity round-trips separately from the generic custom template")
    func stableTemplateIdentity() throws {
        let data = try JSONEncoder().encode(ProviderTemplateID.kimiCode)
        #expect(try JSONDecoder().decode(ProviderTemplateID.self, from: data) == .kimiCode)
        #expect(ProviderTemplateID.kimiCode.rawValue == "kimi-code")
        #expect(ProviderPreset.all.filter { $0.id == .kimiCode }.count == 1)
        #expect(ProviderPreset.imagePresets.contains { $0.id == .custom })
    }
}
