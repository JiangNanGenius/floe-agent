import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

@Suite("Subscription provider isolation")
struct SubscriptionProviderTests {
    @Test("Subscription presets survive reopening without inheriting PAYG media lists")
    func independentPresets() {
        for preset in [ProviderPreset.volcengineAgentPlan, .alibabaTokenPlan] {
            #expect(ProviderPreset.preset(for: preset.kind, baseURL: preset.defaultBaseURL).id == preset.id)
            #expect(ProviderPreset.chatPresets.contains(preset))
            let spec = ProviderFormSpecResolver.resolve(role: .conversation, preset: preset, baseURL: preset.defaultBaseURL)
            #expect(spec.templateID == preset.id)
        }
        #expect(!ProviderFormSpecResolver.eligiblePresets(for: .image).contains(.alibabaTokenPlan))
        #expect(ProviderFormSpecResolver.eligiblePresets(for: .image).contains(.volcengineAgentPlan))
        #expect(ProviderFormSpecResolver.verifiedMediaModelIDs(for: .volcengineAgentPlan, role: .image)
                == ["doubao-seedream-5.0-lite"])
    }

    @Test("Same-origin PAYG and Agent Plan cannot reuse a saved key")
    func billingCredentialBoundary() {
        let compatible = ProviderConfigurationValidation.ProviderConnectionIdentity.isCompatible
        #expect(!compatible(.volcengineArk, ProviderPreset.volcengineArk.defaultBaseURL,
                            .custom, ProviderPreset.volcengineAgentPlan.defaultBaseURL))
        // Legacy manually entered Plan profiles keep their key on reopening.
        #expect(compatible(.volcengineArk, ProviderPreset.volcengineAgentPlan.defaultBaseURL,
                           .custom, ProviderPreset.volcengineAgentPlan.defaultBaseURL))
        #expect(!compatible(.alibabaStudio, ProviderPreset.alibabaStudio.defaultBaseURL,
                            .custom, ProviderPreset.alibabaTokenPlan.defaultBaseURL))
    }

    @Test("Lookalike hosts, nonstandard ports and Coding Plan are not Agent Plan")
    func exactEndpointIdentity() {
        for address in [
            "https://ark.cn-beijing.volces.com.attacker.example/api/plan/v3",
            "https://ark.cn-beijing.volces.com:8443/api/plan/v3",
            "http://ark.cn-beijing.volces.com/api/plan/v3",
            "https://ark.cn-beijing.volces.com/api/coding/v3",
            "https://coding.dashscope.aliyuncs.com/v1"
        ] {
            #expect(ProviderBillingEndpoint.resolve(URL(string: address)!) == nil)
        }
    }
}
