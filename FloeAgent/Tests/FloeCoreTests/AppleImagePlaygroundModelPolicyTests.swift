import Foundation
import Testing
@testable import FloeCore

@Suite("Image Playground model routing is independent of explicit use")
@MainActor
struct AppleImagePlaygroundModelPolicyTests {
    @Test func automaticPrefersCloudAndNeverOverridesAnExplicitCloudChoice() {
        #expect(!AppleImagePlaygroundModelIdentity.shouldUse(explicitNative: false, explicitOther: false,
            preferredNative: false, hasCloud: true, automaticEnabled: true, systemAvailable: true))
        #expect(!AppleImagePlaygroundModelIdentity.shouldUse(explicitNative: false, explicitOther: true,
            preferredNative: true, hasCloud: false, automaticEnabled: true, systemAvailable: true))
    }
    @Test func offOnlyDisablesAutomaticParticipation() {
        #expect(!AppleImagePlaygroundModelIdentity.shouldUse(explicitNative: false, explicitOther: false,
            preferredNative: true, hasCloud: false, automaticEnabled: false, systemAvailable: true))
        #expect(AppleImagePlaygroundModelIdentity.shouldUse(explicitNative: true, explicitOther: false,
            preferredNative: false, hasCloud: true, automaticEnabled: false, systemAvailable: true))
    }
    @Test func automaticCanUseTheOnlyAvailableSystemRouteOrASavedExplicitPreference() {
        #expect(AppleImagePlaygroundModelIdentity.shouldUse(explicitNative: false, explicitOther: false,
            preferredNative: false, hasCloud: false, automaticEnabled: true, systemAvailable: true))
        #expect(AppleImagePlaygroundModelIdentity.shouldUse(explicitNative: false, explicitOther: false,
            preferredNative: true, hasCloud: true, automaticEnabled: true, systemAvailable: true))
        #expect(!AppleImagePlaygroundModelIdentity.shouldUse(explicitNative: false, explicitOther: false,
            preferredNative: true, hasCloud: false, automaticEnabled: true, systemAvailable: false))
    }
    @Test func explicitUnavailableNativeSelectionReachesTheNativeAvailabilityErrorInsteadOfCloud() {
        #expect(AppleImagePlaygroundModelIdentity.shouldUse(explicitNative: true, explicitOther: false,
            preferredNative: false, hasCloud: true, automaticEnabled: false, systemAvailable: false))
    }
    @Test func preferenceHasItsOwnDurableKey() throws {
        let name = "native-image-policy-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppleImagePlaygroundModelIdentity.automaticRoutingEnabled(in: defaults))
        defaults.set(false, forKey: AppleImagePlaygroundModelIdentity.automaticDefaultsKey)
        #expect(!AppleImagePlaygroundModelIdentity.automaticRoutingEnabled(in: defaults))
    }
    @Test func nativeProfileIsAnImageModelAndCannotBecomeTheChatModel() {
        let provider = UUID()
        let profile = AppleImagePlaygroundModelIdentity.profile(providerID: provider, available: false, supportsEditing: false)
        #expect(profile.id == AppleImagePlaygroundModelIdentity.profileID && profile.providerID == provider)
        #expect(profile.supportsImageGenerationSurface && !profile.supportsChatAgentSurface)
        #expect(!profile.isEnabled && !profile.capabilities.contains(.text))
        #expect(AppleImagePlaygroundModelIdentity.matches("图乐园"))
        #expect(AppleImagePlaygroundModelIdentity.matches("Apple Image Playground"))
        #expect(!AppleImagePlaygroundModelIdentity.matches("Google Imagen"))
    }
}
