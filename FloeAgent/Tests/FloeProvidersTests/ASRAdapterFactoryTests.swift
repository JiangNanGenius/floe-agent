// Focused qualification tests — factory routing and capability decisions.
// These do not create a network session or require a credential.

import Foundation
import Testing
import FloeCore
@testable import FloeProviders

@Test func factoryReturnsConcreteFileAdaptersForSupportedRoutes() throws {
    let openAI = ASRProfile.openAICompatible()
    let openAIFile = try ASRAdapterFactory.fileAdapter(for: openAI)
    #expect(openAIFile is OpenAITranscriptionAdapter)

    let volcenginePayg = ASRProfile.volcengine(billingRoute: .payAsYouGo)
    let volcenginePaygFile = try ASRAdapterFactory.fileAdapter(
        for: volcenginePayg)
    #expect(volcenginePaygFile is VolcengineASRAdapter)
    let volcenginePlan = ASRProfile.volcengine(billingRoute: .agentPlan)
    let volcenginePlanFile = try ASRAdapterFactory.fileAdapter(
        for: volcenginePlan)
    #expect(volcenginePlanFile is VolcengineASRAdapter)

    let alibabaPayg = ASRProfile.alibaba(billingRoute: .payAsYouGo)
    let alibabaPaygFile = try ASRAdapterFactory.fileAdapter(for: alibabaPayg)
    #expect(alibabaPaygFile is AlibabaASRAdapter)
    let alibabaPlan = ASRProfile.alibaba(billingRoute: .tokenPlan)
    let alibabaPlanFile = try ASRAdapterFactory.fileAdapter(for: alibabaPlan)
    #expect(alibabaPlanFile is AlibabaASRAdapter)
}

@Test func factoryLiveRoutingAndTokenPlanDefaultNil() throws {
    let volcenginePayg = try ASRAdapterFactory.liveAdapter(
        for: ASRProfile.volcengine(billingRoute: .payAsYouGo))
    #expect(volcenginePayg != nil)
    let volcenginePlan = try ASRAdapterFactory.liveAdapter(
        for: ASRProfile.volcengine(billingRoute: .agentPlan))
    #expect(volcenginePlan != nil)
    let alibabaPayg = try ASRAdapterFactory.liveAdapter(
        for: ASRProfile.alibaba(billingRoute: .payAsYouGo))
    #expect(alibabaPayg is AlibabaASRAdapter)
    let alibabaTokenPlan = try ASRAdapterFactory.liveAdapter(
        for: ASRProfile.alibaba(billingRoute: .tokenPlan))
    #expect(alibabaTokenPlan == nil)
    let openAI = try ASRAdapterFactory.liveAdapter(
        for: ASRProfile.openAICompatible())
    #expect(openAI is OpenAIRealtimeTranscriptionAdapter)

    let fileOnly = ASRProfile.openAICompatible(liveModelID: nil)
    let fileOnlyLive = try ASRAdapterFactory.liveAdapter(for: fileOnly)
    #expect(fileOnlyLive == nil)
}

@Test func factoryTokenPlanManualLiveUsesProtocolCapabilityOnly() throws {
    let manual = ASRProfile.alibaba(
        billingRoute: .tokenPlan,
        liveModelID: "qwen-audio-3.1-asr-flash-streaming",
        liveEndpoint: "wss://example.com/api-ws/v1/inference")
    let manualLive = try ASRAdapterFactory.liveAdapter(for: manual)
    #expect(manualLive is AlibabaASRAdapter)

    let nonStreaming = ASRProfile.alibaba(
        billingRoute: .tokenPlan,
        liveModelID: "qwen-audio-3.0-asr-flash",
        liveEndpoint: "wss://example.com/api-ws/v1/inference")
    do {
        _ = try ASRAdapterFactory.liveAdapter(for: nonStreaming)
        Issue.record("non-streaming live model must be rejected")
    } catch let error as ASRTranscriptionError {
        guard case .invalidConfiguration = error else {
            Issue.record("expected invalidConfiguration, got \(error)")
            return
        }
    }
}

@Test func factoryRejectsInvalidRoutesAndUnsupportedFileModels() throws {
    let invalid = ASRProfile(
        name: "invalid",
        provider: .alibaba,
        billingRoute: .agentPlan,
        fileModelID: "qwen-audio-3.1-asr-flash",
        liveModelID: "qwen-audio-3.1-asr-flash-streaming")
    do {
        _ = try ASRAdapterFactory.fileAdapter(for: invalid)
        Issue.record("Alibaba Agent Plan is not a valid route")
    } catch let error as ASRTranscriptionError {
        guard case .invalidConfiguration = error else {
            Issue.record("expected invalidConfiguration, got \(error)")
            return
        }
    }

    let streamingAsFile = ASRProfile.alibaba(
        billingRoute: .payAsYouGo,
        fileModelID: "qwen-audio-3.1-asr-flash-streaming")
    do {
        _ = try ASRAdapterFactory.fileAdapter(for: streamingAsFile)
        Issue.record("a live-only model must not be a file adapter")
    } catch let error as ASRTranscriptionError {
        guard case .invalidConfiguration = error else {
            Issue.record("expected invalidConfiguration, got \(error)")
            return
        }
    }
}

@Test func factoryDoesNotRequireCredentialReferenceOrAccountTest() throws {
    let profile = ASRProfile.volcengine(
        billingRoute: .payAsYouGo,
        credentialReference: nil)
    #expect(profile.credentialReference == nil)
    let file = try ASRAdapterFactory.fileAdapter(for: profile)
    #expect(file is VolcengineASRAdapter)
    let live = try ASRAdapterFactory.liveAdapter(for: profile)
    #expect(live != nil)

    let tokenPlan = ASRProfile.alibaba(billingRoute: .tokenPlan)
    #expect(tokenPlan.credentialReference == nil)
    let tokenPlanFile = try ASRAdapterFactory.fileAdapter(for: tokenPlan)
    #expect(tokenPlanFile is AlibabaASRAdapter)
}
