// Focused qualification tests — shared cloud ASR configuration.
//
// These compile the exact overlay source bytes in a minimal host package
// (FloeCore + the three FloeProviders speech files). No App, simulator,
// network or provider call is involved.

import Foundation
import Testing
import FloeCore

@Suite("Cloud ASR configuration")
struct ASRConfigurationTests {
    @Test("Provider route matrix is explicit and has no availability gate")
    func providerRoutes() {
        #expect(ASRProviderKind.openaiCompatible.supportedBillingRoutes == [.payAsYouGo])
        #expect(ASRProviderKind.volcengine.supportedBillingRoutes == [.payAsYouGo, .agentPlan])
        #expect(ASRProviderKind.alibaba.supportedBillingRoutes == [.payAsYouGo, .tokenPlan])
        #expect(ASRProviderKind.alibaba.supports(.tokenPlan))
        #expect(!ASRProviderKind.alibaba.supports(.agentPlan))
        #expect(ASRBillingRoute(.tokenPlan) == .tokenPlan)
        #expect(ASRBillingRoute.tokenPlan.ttsRoute == .tokenPlan)
    }

    @Test("Default OpenAI profile uses the current file and live models")
    func openAIDefaults() {
        let profile = ASRProfile.openAICompatible()
        #expect(profile.provider == .openaiCompatible)
        #expect(profile.billingRoute == .payAsYouGo)
        #expect(profile.fileModelID == "gpt-transcribe")
        #expect(profile.liveModelID == "gpt-live-transcribe")
        #expect(profile.fileCapabilities.languageParameter == .array)
        #expect(profile.fileCapabilities.supportsFileStreaming)
        #expect(!profile.fileCapabilities.supportsTimestampGranularities)
        #expect(profile.fileCapabilities.supportsKeywords)
        #expect(profile.liveCapabilities?.supportsLiveTranscription == true)
        #expect(profile.validationProblem() == nil)
        #expect(profile.resolvedFileEndpoint == nil)
        #expect(profile.resolvedLiveEndpoint == nil)
    }

    @Test("Whisper stays an explicit legacy compatibility profile")
    func whisperCapabilities() {
        let caps = ASRModelCapabilityCatalog.capabilities(
            for: .openaiCompatible, modelID: "whisper-1")
        #expect(caps.fileResponseFormat == .verboseJSON)
        #expect(caps.languageParameter == .singular)
        #expect(caps.supportsTimestampGranularities)
        #expect(!caps.supportsFileStreaming)
        #expect(caps.timing == .providerSegments)
        #expect(caps.supportsFileTranscription)
        #expect(!caps.supportsLiveTranscription)
    }

    @Test("Unknown compatible models receive conservative arguments only")
    func unknownModelCapabilities() {
        let caps = ASRModelCapabilityCatalog.capabilities(
            for: .openaiCompatible, modelID: "my-private-asr")
        #expect(caps.fileResponseFormat == .automatic)
        #expect(caps.languageParameter == .singular)
        #expect(!caps.supportsTimestampGranularities)
        #expect(!caps.supportsFileStreaming)
        #expect(!caps.supportsKeywords)
        #expect(!caps.supportsPrompt)
        #expect(caps.supportsFileTranscription)
        // Unknown models remain callable by configuration alone; the adapter
        // sends only the minimum body and surfaces a real provider error.
        #expect(caps.supportsLiveTranscription)
        #expect(caps.timing == .none)
    }

    @Test("Profiles encode no secret and keep a stable id")
    func profileCodable() throws {
        let ref = ASRCredentialReference(service: "com.floe.asr", account: "openai-payg")
        let profile = ASRProfile.openAICompatible(
            name: "Relay",
            fileEndpoint: "https://relay.example/v1",
            liveEndpoint: "wss://relay.example/v1",
            credentialReference: ref,
            languages: ["en", "zh", "EN"],
            prompt: "  A support call  ",
            keywords: ["AC-42", "bad<term>", "line\nbreak"])
        let data = try JSONEncoder().encode(profile)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("sk-"))
        #expect(text.contains("com.floe.asr"))
        #expect(profile.languages == ["en", "zh"])
        #expect(profile.prompt == "A support call")
        #expect(profile.keywords == ["AC-42"])
        let decoded = try JSONDecoder().decode(ASRProfile.self, from: data)
        #expect(decoded.id == profile.id)
        #expect(decoded == profile)
        #expect(decoded.credentialReference == ref)
    }

    @Test("Every shipped provider entry validates without any account gate")
    func everyProviderEntryCallable() {
        let profiles = [
            ASRProfile.openAICompatible(),
            ASRProfile.volcengine(billingRoute: .payAsYouGo),
            ASRProfile.volcengine(billingRoute: .agentPlan),
            ASRProfile.alibaba(billingRoute: .payAsYouGo),
            ASRProfile.alibaba(billingRoute: .tokenPlan),
        ]
        for profile in profiles {
            #expect(profile.validationProblem() == nil)
        }
    }

    @Test("Token Plan Alibaba profile is configurable with no account gate")
    func tokenPlanProfile() throws {
        let profile = ASRProfile.alibaba(billingRoute: .tokenPlan)
        #expect(profile.billingRoute == .tokenPlan)
        #expect(profile.fileModelID == "qwen-audio-3.0-asr-flash")
        #expect(profile.liveModelID == nil)
        #expect(profile.resolvedFileEndpoint == ASRProviderRouting.alibabaTokenPlanFileURL)
        #expect(profile.resolvedLiveEndpoint == nil)
        #expect(try profile.validated().id == profile.id)
        #expect(ASRProviderRouting.defaultResourceID(
            provider: .alibaba, route: .tokenPlan) == nil)
    }

    @Test("Volcengine plan routes never share the pay-as-you-go endpoint")
    func volcengineRoutes() {
        let payg = ASRProfile.volcengine(billingRoute: .payAsYouGo)
        let plan = ASRProfile.volcengine(billingRoute: .agentPlan)
        #expect(payg.resolvedLiveEndpoint == ASRProviderRouting.volcenginePayAsYouGoLiveURL)
        #expect(plan.resolvedLiveEndpoint == ASRProviderRouting.volcengineAgentPlanLiveURL)
        #expect(payg.resolvedLiveEndpoint != plan.resolvedLiveEndpoint)
        #expect(payg.resourceID == "volc.seedasr.sauc.duration")
    }

    @Test("Profile validation rejects invalid route and insecure endpoint")
    func profileValidation() {
        let invalidRoute = ASRProfile(
            name: "Bad",
            provider: .alibaba,
            billingRoute: .agentPlan,
            fileModelID: "qwen-audio-3.0-asr-flash")
        #expect(invalidRoute.validationProblem() != nil)
        #expect(throws: ASRTranscriptionError.self) { _ = try invalidRoute.validated() }
        let insecure = ASRProfile.openAICompatible(
            fileEndpoint: "http://relay.example/v1")
        #expect(insecure.validationProblem() != nil)
        let proxy = ASRProfile.openAICompatible(
            fileEndpoint: "https://relay.example/openai/v1")
        #expect(proxy.validationProblem() == nil)
        let query = ASRProfile.openAICompatible(
            fileEndpoint: "https://relay.example/v1?x=1")
        #expect(query.validationProblem() != nil)
    }

    @Test("File endpoint composes once and preserves a reverse-proxy prefix")
    func fileEndpoint() throws {
        let url = try OpenAITranscriptionEndpoint.endpointURL(
            base: "https://relay.example/openai/v1")
        #expect(url.absoluteString
            == "https://relay.example/openai/v1/audio/transcriptions")
        #expect(throws: ASRTranscriptionError.self) {
            _ = try OpenAITranscriptionEndpoint.endpointURL(
                base: "http://relay.example/v1")
        }
        #expect(OpenAITranscriptionEndpoint.originChanged(
            from: "https://relay.example/v1", to: "https://relay.example/v1/x") == false)
        #expect(OpenAITranscriptionEndpoint.originChanged(
            from: "https://a.example/v1", to: "https://b.example/v1"))
    }

    @Test("Realtime endpoint preserves prefixes/query and composes intent once")
    func realtimeEndpoint() throws {
        #expect(try ASROpenAIRealtimeEndpoint.endpointURL(base: nil)
            == ASROpenAIRealtimeEndpoint.officialURL)
        let upgraded = try ASROpenAIRealtimeEndpoint.endpointURL(
            base: "https://relay.example/openai/v1")
        #expect(upgraded.absoluteString
            == "wss://relay.example/openai/v1/realtime?intent=transcription")
        let full = try ASROpenAIRealtimeEndpoint.endpointURL(
            base: "wss://relay.example/openai/v1/realtime?intent=transcription&x=1")
        #expect(full.absoluteString
            == "wss://relay.example/openai/v1/realtime?x=1&intent=transcription")
        #expect(throws: ASRTranscriptionError.self) {
            _ = try ASROpenAIRealtimeEndpoint.endpointURL(base: "ws://relay.example/v1")
        }
        #expect(throws: ASRTranscriptionError.self) {
            _ = try ASROpenAIRealtimeEndpoint.endpointURL(
                base: "wss://user:key@relay.example/v1")
        }
        #expect(throws: ASRTranscriptionError.self) {
            _ = try ASROpenAIRealtimeEndpoint.endpointURL(
                base: "wss://relay.example/v1/realtime?intent=conversation")
        }
        #expect(ASROpenAIRealtimeEndpoint.originChanged(
            from: nil, to: "wss://relay.example/v1"))
        #expect(!ASROpenAIRealtimeEndpoint.originChanged(
            from: "https://relay.example/v1",
            to: "wss://relay.example/v1/realtime"))
    }
}

@Test func relayLiveDefaultKeepsConfiguredOriginAndPrefix() throws {
    for endpoint in ["https://relay.example/proxy/v1", "https://relay.example/proxy/v1/audio/transcriptions/"] {
        let profile = ASRProfile.openAICompatible(fileEndpoint: endpoint)
        let url = try ASROpenAIRealtimeEndpoint.endpointURL(base: profile.resolvedLiveEndpoint)
        #expect(url.host == "relay.example")
        #expect(url.path == "/proxy/v1/realtime")
        #expect(url.scheme == "wss")
    }
    let explicit = ASRProfile.openAICompatible(fileEndpoint: "https://relay.example/v1", liveEndpoint: "wss://live.example/v1/realtime")
    #expect(explicit.resolvedLiveEndpoint == "wss://live.example/v1/realtime")
}
