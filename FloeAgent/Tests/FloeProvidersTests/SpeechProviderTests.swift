// FloeProvidersTests — TTS speech slice contract + determinism tests.
//
// SPDX-License-Identifier: MPL-2.0
//
// Deterministic unit coverage for the streaming-TTS backend: per-route request/
// header/body matrices, the Volcengine binary frame codec, SSE audio mapping,
// redaction (no provider message text or credentials ever surface), the
// lossless demand-driven channel (losslessness, capacity backpressure,
// waiter-wake, cancellation close, drain-before-terminal, byte-capped sync
// send), segmenter boundaries, PCM alignment, the `.onDevice` fail-closed
// routing contract and the ephemeral transport default. No network, no live
// keys: real-service behavior remains the device/primary gate.

import Foundation
import Testing
import FloeCore
@testable import FloeProviders

// MARK: - Helpers

private func jsonDictionary(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func makeChunk(_ byte: UInt8, count: Int = 4, final: Bool = false) -> TTSAudioChunk {
    TTSAudioChunk(
        sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        segmentIndex: 0,
        sequence: Int(byte),
        pcm: Data(repeating: byte, count: count),
        sampleRate: 24_000,
        isFinal: final)
}

private func cloudRequest(
    provider: TTSSpeakerProvider,
    route: TTSBillingRoute = .payAsYouGo,
    model: String = "model-x",
    voice: String = "voice-x",
    text: String = "Hello world.",
    region: String? = nil,
    rate: Double = 1.0,
    language: String? = nil,
    openAIBaseURL: String? = nil
) -> TTSSynthesisRequest {
    TTSSynthesisRequest(
        provider: provider, billingRoute: route, region: region,
        openAIBaseURL: openAIBaseURL,
        modelID: model, voiceID: voice, text: text,
        speechRateRatio: rate, language: language)
}

private func localRequest(
    provider: TTSSpeakerProvider = .onDevice,
    text: String = "你好世界。",
    model: String = "",
    voice: String = "",
    language: String? = nil
) -> TTSSynthesisRequest {
    TTSSynthesisRequest(
        provider: provider, billingRoute: .payAsYouGo, modelID: model,
        voiceID: voice, text: text, language: language)
}

private let fixedSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

/// Synchronous completion flag (Task has no `isFinished` on this toolchain;
/// producer-park assertions need "has this send returned yet?").
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    func mark() { lock.lock(); set = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return set }
}

/// Records everything the router hands it and emits a canned chunk sequence.
private final class RecordingLocalProvider: TTSSpeechProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [TTSSynthesisRequest] = []
    private var recordedCredentials: [String] = []

    var recorded: [(TTSSynthesisRequest, String)] {
        lock.lock(); defer { lock.unlock() }
        return zip(recordedRequests, recordedCredentials).map { ($0, $1) }
    }

    func synthesize(_ request: TTSSynthesisRequest, credential: String) -> TTSAudioChunkStream {
        lock.lock()
        recordedRequests.append(request)
        recordedCredentials.append(credential)
        lock.unlock()
        let (stream, sender) = TTSAudioChunkStream.make()
        Task {
            try? await sender.send(TTSAudioChunk(sessionID: request.sessionID, segmentIndex: request.segmentIndex,
                                                 sequence: 0, pcm: Data(repeating: 1, count: 8), sampleRate: 24_000))
            try? await sender.send(TTSAudioChunk(sessionID: request.sessionID, segmentIndex: request.segmentIndex,
                                                 sequence: 1, pcm: Data(repeating: 2, count: 8), sampleRate: 24_000, isFinal: true))
            sender.finish()
        }
        return stream
    }
}

private func drain(_ stream: TTSAudioChunkStream) async throws -> [TTSAudioChunk] {
    var collected: [TTSAudioChunk] = []
    for try await chunk in stream { collected.append(chunk) }
    return collected
}

private func speechError(from stream: TTSAudioChunkStream) async -> TTSSynthesisError? {
    do {
        _ = try await drain(stream)
        return nil
    } catch let error as TTSSynthesisError {
        return error
    } catch {
        return nil
    }
}

// MARK: - Provider / billing matrix

@Suite("Speech configuration matrix")
struct TTSSpeakerMatrixTests {
    @Test func supportedRoutesAreExact() {
        #expect(TTSSpeakerProvider.apple.supportedBillingRoutes == [])
        #expect(TTSSpeakerProvider.onDevice.supportedBillingRoutes == [])
        #expect(TTSSpeakerProvider.volcengine.supportedBillingRoutes == [.agentPlan, .payAsYouGo])
        #expect(TTSSpeakerProvider.alibaba.supportedBillingRoutes == [.tokenPlan, .payAsYouGo])
        #expect(TTSSpeakerProvider.elevenLabs.supportedBillingRoutes == [.payAsYouGo])
        #expect(TTSSpeakerProvider.openAI.supportedBillingRoutes == [.payAsYouGo])
    }

    @Test func localPathsNeverRequireCloudCredential() {
        #expect(!TTSSpeakerProvider.apple.requiresCloudCredential)
        #expect(!TTSSpeakerProvider.onDevice.requiresCloudCredential)
        for cloud in [TTSSpeakerProvider.volcengine, .elevenLabs, .openAI, .alibaba] {
            #expect(cloud.requiresCloudCredential)
        }
    }

    @Test func invalidPairingsAreConfigurationProblems() {
        let volcToken = cloudRequest(provider: .volcengine, route: .tokenPlan)
        #expect(volcToken.validationProblem()?.contains("not valid") == true)
        let alibabaAgent = cloudRequest(provider: .alibaba, route: .agentPlan)
        #expect(alibabaAgent.validationProblem()?.contains("not valid") == true)
        #expect(TTSBillingRoute.isValid(.tokenPlan, for: .alibaba))
        #expect(!TTSBillingRoute.isValid(.tokenPlan, for: .volcengine))
        #expect(!TTSBillingRoute.isValid(.agentPlan, for: .openAI))
    }

    @Test func cloudRequestsRequireModelAndVoice() {
        let missingVoice = cloudRequest(provider: .openAI, voice: " ")
        #expect(missingVoice.validationProblem()?.contains("voice") == true)
        let missingModel = cloudRequest(provider: .openAI, model: "")
        #expect(missingModel.validationProblem()?.contains("model") == true)
        let emptyText = cloudRequest(provider: .openAI, text: "   ")
        #expect(emptyText.validationProblem()?.contains("empty") == true)
    }

    @Test func localBypassesRouteModelVoiceButKeepsTextAndPCM() {
        #expect(localRequest().validationProblem() == nil)
        #expect(localRequest(provider: .apple).validationProblem() == nil)
        let appleNoText = localRequest(provider: .apple, text: " ")
        #expect(appleNoText.validationProblem()?.contains("empty") == true)
    }

    @Test func rateClampsToSupportedBand() {
        #expect(cloudRequest(provider: .openAI, rate: 0.1).speechRateRatio == 0.5)
        #expect(cloudRequest(provider: .openAI, rate: 3.0).speechRateRatio == 2.0)
        #expect(cloudRequest(provider: .openAI, rate: 1.25).speechRateRatio == 1.25)
    }

    @Test func languageHintNormalizes() {
        #expect(localRequest(language: "  zh-CN ").language == "zh-CN")
        #expect(localRequest(language: "").language == nil)
        #expect(localRequest(language: nil).language == nil)
        #expect(cloudRequest(provider: .openAI, language: "fr-FR").language == "fr-FR")
    }

    @Test func snapshotDefaultsAndCodability() throws {
        let defaults = TTSSettingsSnapshot()
        #expect(defaults.provider == .apple)
        #expect(defaults.autoReadEnabled == false)
        #expect(defaults.allowBargeIn == true)
        #expect(defaults.language == nil)
        #expect(defaults.connectionProviderID == nil)
        #expect(defaults.openAIBaseURL == nil)

        var snapshot = TTSSettingsSnapshot(provider: .onDevice, modelID: "local-1", voiceID: "v",
                                           language: "zh-CN")
        snapshot.autoReadEnabled = true
        snapshot.openAIBaseURL = "https://api.openai-proxy.org/v1"
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(TTSSettingsSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.openAIBaseURL == "https://api.openai-proxy.org/v1")

        // Backward compatibility: a v1 payload WITHOUT the optional `language`
        // key must decode with language == nil (settled multilingual contract).
        // The same payload predates the optional OpenAI base URL, which must
        // also decode as nil so the official endpoint stays the default.
        let legacy = Data("{\"provider\":\"volcengine\",\"billingRoute\":\"agentPlan\",\"alibabaRegion\":null,\"modelID\":\"doubao-seed-tts-2.0\",\"voiceID\":\"zh_female_vv_uranus_bigtts\",\"speechRateRatio\":1.0,\"autoReadEnabled\":false,\"allowBargeIn\":true,\"connectionProviderID\":null}".utf8)
        let legacySnapshot = try JSONDecoder().decode(TTSSettingsSnapshot.self, from: legacy)
        #expect(legacySnapshot.provider == .volcengine)
        #expect(legacySnapshot.language == nil)
        #expect(legacySnapshot.openAIBaseURL == nil)
    }

    @Test func onDeviceRawValueIsStable() throws {
        // Settings JSON stability: the persisted provider string is frozen.
        let data = try JSONEncoder().encode(TTSSpeakerProvider.onDevice)
        #expect(String(data: data, encoding: .utf8) == "\"onDevice\"")
    }
}

// MARK: - Volcengine frame codec

@Suite("Volcengine frame codec")
struct VolcSpeechFrameTests {
    @Test func clientRequestLayout() {
        let payload = Data(#"{"req_params":{"text":"hi"}}"#.utf8)
        let bytes = [UInt8](VolcSpeechFrame.clientRequest(payload).encoded())
        #expect(bytes[0] == 0x11)                              // version 0b0001 | header 0b0001
        #expect(bytes[1] == (0b0001 << 4))                      // full client request, flags 0
        #expect(bytes[2] == (0b0001 << 4))                      // JSON serialization, no compression
        #expect(bytes[3] == 0x00)
        let declared = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])
        #expect(Int(declared) == payload.count)
        #expect(Array(bytes.dropFirst(8)) == [UInt8](payload))
    }

    @Test func clientFinishSetsFlagBits() {
        let bytes = [UInt8](VolcSpeechFrame.clientFinish(Data("{}".utf8)).encoded())
        #expect(bytes[1] == (0b0001 << 4) | 0b0100)
    }

    @Test func serverFramesRoundTrip() throws {
        let audio = Data((0..<256).map { UInt8($0 % 256) })
        let audioFrame = try VolcSpeechFrame.decode(
            VolcSpeechFrame.serverAudio(audio, event: 350).encoded())
        guard case .serverAudio(let payload, let event) = audioFrame else {
            Issue.record("expected serverAudio"); return
        }
        #expect(payload == audio)
        #expect(event == 350)

        let json = Data(#"{"code":200000,"event":"task-finished"}"#.utf8)
        let jsonFrame = try VolcSpeechFrame.decode(
            VolcSpeechFrame.serverJSON(json, event: nil).encoded())
        guard case .serverJSON(let payload, let event) = jsonFrame else {
            Issue.record("expected serverJSON"); return
        }
        #expect(payload == json)
        #expect(event == nil)

        let errorFrame = try VolcSpeechFrame.decode(
            VolcSpeechFrame.serverError(code: -1_543_209, Data()).encoded())
        guard case .serverError(let code, _) = errorFrame else {
            Issue.record("expected serverError"); return
        }
        #expect(code == -1_543_209)
    }

    @Test func decodeRejectsMalformedFrames() {
        #expect(throws: VolcSpeechFrame.DecodeError.truncated) {
            try VolcSpeechFrame.decode(Data([0x11, 0x10, 0x10, 0x00, 0x00, 0x00]))
        }
        #expect(throws: VolcSpeechFrame.DecodeError.badVersion) {
            try VolcSpeechFrame.decode(Data([0x21, 0x10, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00]))
        }
        #expect(throws: VolcSpeechFrame.DecodeError.badMessageType) {
            // compression nibble set: gzip was never requested → protocol violation
            try VolcSpeechFrame.decode(Data([0x11, 0xB4, 0x11, 0x00, 0, 0, 0, 4, 1, 2, 3, 4]))
        }
        #expect(throws: VolcSpeechFrame.DecodeError.oversized) {
            // No event flag (0xB0): the declared payload size itself must trip
            // the frame ceiling before any payload read.
            try VolcSpeechFrame.decode(Data([0x11, 0xB0, 0x10, 0x00, 0x7F, 0xFF, 0xFF, 0xFF]))
        }
        #expect(throws: VolcSpeechFrame.DecodeError.truncated) {
            // declared payload longer than the buffer
            try VolcSpeechFrame.decode(Data([0x11, 0xB0, 0x00, 0x00, 0, 0, 0, 16, 1, 2, 3]))
        }
    }
}

// MARK: - Volcengine payloads / SSE mapping

@Suite("Volcengine request matrix")
struct VolcenginePayloadTests {
    @Test func resourceIDBindingPerRoute() {
        #expect(VolcengineSpeechAdapter.resourceID(forModel: "doubao-seed-tts-2.0", route: .agentPlan) == "seed-tts-2.0")
        #expect(VolcengineSpeechAdapter.resourceID(forModel: "doubao-seed-tts-2.0", route: .payAsYouGo) == "seed-tts-2.0")
        #expect(VolcengineSpeechAdapter.resourceID(forModel: "doubao-seed-tts-1.0", route: .payAsYouGo) == "seed-tts-1.0")
        #expect(VolcengineSpeechAdapter.resourceID(forModel: "doubao-seed-tts-1.0", route: .agentPlan) == nil)
        #expect(VolcengineSpeechAdapter.resourceID(forModel: "unknown-model", route: .payAsYouGo) == nil)
    }

    @Test func speechRateParamMapping() {
        #expect(VolcengineSpeechAdapter.speechRateParam(ratio: 0.5) == -50)
        #expect(VolcengineSpeechAdapter.speechRateParam(ratio: 1.0) == 0)
        #expect(VolcengineSpeechAdapter.speechRateParam(ratio: 1.234) == 23)
        #expect(VolcengineSpeechAdapter.speechRateParam(ratio: 2.0) == 100)
        #expect(VolcengineSpeechAdapter.speechRateParam(ratio: 0.1) == -50)
        #expect(VolcengineSpeechAdapter.speechRateParam(ratio: 3.0) == 100)
    }

    @Test func bodyCarriesPCMParams() throws {
        let body = try #require(jsonDictionary(
            VolcengineSpeechAdapter.makeBody(for: cloudRequest(
                provider: .volcengine, route: .payAsYouGo, model: "doubao-seed-tts-2.0",
                voice: "zh_female_vv_uranus_bigtts", rate: 1.0))))
        let reqParams = try #require(body["req_params"] as? [String: Any])
        #expect(reqParams["text"] as? String == "Hello world.")
        #expect(reqParams["speaker"] as? String == "zh_female_vv_uranus_bigtts")
        let audio = try #require(reqParams["audio_params"] as? [String: Any])
        #expect(audio["format"] as? String == "pcm")
        #expect(audio["sample_rate"] as? Int == 24_000)
        #expect(audio["speech_rate"] == nil)   // default 1.0x is omitted, never a substitute knob

        let fast = try #require(jsonDictionary(
            VolcengineSpeechAdapter.makeBody(for: cloudRequest(
                provider: .volcengine, model: "doubao-seed-tts-2.0", rate: 1.2))))
        let fastAudio = try #require((fast["req_params"] as? [String: Any])?["audio_params"] as? [String: Any])
        #expect(fastAudio["speech_rate"] as? Int == 20)
    }

    @Test func headersBindCredentialResourceAndFreshID() throws {
        let request = cloudRequest(provider: .volcengine, route: .agentPlan, model: "doubao-seed-tts-2.0")
        let headers = try VolcengineSpeechAdapter.makeHeaders(
            credential: "plan-key", request: request, idSupplier: { "fixed-id" })
        #expect(headers["X-Api-Key"] == "plan-key")
        #expect(headers["X-Api-Resource-Id"] == "seed-tts-2.0")
        #expect(headers["X-Api-Request-Id"] == "fixed-id")
        #expect(throws: (any Error).self) {
            try VolcengineSpeechAdapter.makeHeaders(
                credential: "k", request: cloudRequest(provider: .volcengine, model: "nope"),
                idSupplier: { "id" })
        }
    }

    @Test func sseEventMappingIsRedacted() throws {
        let pcm = Data([0x01, 0x02, 0x03, 0x04])
        #expect(VolcengineSpeechAdapter.sseAudioEvents(
            from: Data(#"{"audio":"\#(pcm.base64EncodedString())"}"#.utf8)) == [.audio(pcm)])
        let rejected = VolcengineSpeechAdapter.sseAudioEvents(from: Data(
            #"{"code":45000001,"message":"Invalid api key sk-secret","conn_id":"conn-9 \n"}"#.utf8))
        #expect(rejected == [.rejected(code: 45000001, logID: "conn-9")])
        // Provider message text never leaves the mapping (equality above already
        // proves only code + sanitized conn_id are carried).
        #expect(VolcengineSpeechAdapter.sseAudioEvents(
            from: Data(#"{"code":200000,"event":"SentenceEnd"}"#.utf8)) == [])
        #expect(VolcengineSpeechAdapter.sseAudioEvents(
            from: Data(#"{"event":"Finish"}"#.utf8)) == [.finished])
        #expect(VolcengineSpeechAdapter.sseAudioEvents(from: Data("not json".utf8)) == [])
    }

    @Test func successFamilyCodes() {
        #expect(VolcengineSpeechAdapter.isProviderSuccess(code: nil))
        #expect(VolcengineSpeechAdapter.isProviderSuccess(code: 200_000))
        #expect(VolcengineSpeechAdapter.isProviderSuccess(code: 299_999))
        #expect(!VolcengineSpeechAdapter.isProviderSuccess(code: 45_000))
        #expect(!VolcengineSpeechAdapter.isProviderSuccess(code: 45_000_001))
    }

    @Test func sseURLRequestBindsPayAsYouGoChannel() throws {
        let adapter = VolcengineSpeechAdapter(session: URLSession(configuration: .ephemeral))
        let urlRequest = try adapter.makeSSEURLSessionRequest(
            cloudRequest(provider: .volcengine, model: "doubao-seed-tts-2.0"),
            credential: "paygo-key", idSupplier: { "rid" })
        #expect(urlRequest.url == VolcengineSpeechAdapter.payAsYouGoSSEURL)
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "X-Api-Key") == "paygo-key")
        #expect(urlRequest.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(urlRequest.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        // The plan URL is never reachable from the pay-as-you-go builder.
        #expect(urlRequest.url?.scheme != "wss")
    }
}

// MARK: - Alibaba

@Suite("Alibaba request matrix")
struct AlibabaPayloadTests {
    @Test func endpointsBindRouteAndRegion() throws {
        let token = try AlibabaSpeechAdapter.endpoint(
            request: cloudRequest(provider: .alibaba, route: .tokenPlan, model: "qwen-audio-3.0-tts-plus"))
        #expect(token.absoluteString.hasPrefix(AlibabaSpeechAdapter.tokenPlanBase + AlibabaSpeechAdapter.speechPath))

        let defaultPaygo = try AlibabaSpeechAdapter.endpoint(
            request: cloudRequest(provider: .alibaba, route: .payAsYouGo))
        #expect(defaultPaygo.absoluteString.hasPrefix(AlibabaSpeechAdapter.payAsYouGoBeijing))
        let intl = try AlibabaSpeechAdapter.endpoint(
            request: cloudRequest(provider: .alibaba, route: .payAsYouGo, region: "ap-southeast-1"))
        #expect(intl.absoluteString.hasPrefix(AlibabaSpeechAdapter.payAsYouGoSingapore))
        #expect(throws: (any Error).self) {
            try AlibabaSpeechAdapter.endpoint(
                request: cloudRequest(provider: .alibaba, route: .payAsYouGo, region: "eu-west-1"))
        }
        #expect(throws: (any Error).self) {
            try AlibabaSpeechAdapter.endpoint(request: cloudRequest(provider: .alibaba, route: .agentPlan))
        }
    }

    @Test func headersAndBodyMatchDocumentedShape() throws {
        let headers = AlibabaSpeechAdapter.makeHeaders(credential: "sk-sp-plan")
        #expect(headers["Authorization"] == "Bearer sk-sp-plan")
        #expect(headers["X-DashScope-SSE"] == "enable")
        #expect(headers["Accept"] == "text/event-stream")

        let body = try #require(jsonDictionary(AlibabaSpeechAdapter.makeBody(for: cloudRequest(
            provider: .alibaba, route: .tokenPlan, model: "qwen-audio-3.0-tts-plus",
            voice: "clone-voice-7", rate: 1.5, language: "zh-CN"))))
        #expect(body["model"] as? String == "qwen-audio-3.0-tts-plus")
        let input = try #require(body["input"] as? [String: Any])
        #expect(input["text"] as? String == "Hello world.")
        #expect(input["voice"] as? String == "clone-voice-7")
        #expect(input["format"] as? String == "pcm")
        #expect(input["sample_rate"] as? Int == 24_000)
        // No documented speed knob and no documented language field: neither
        // speech_rate nor language may be invented into the body.
        #expect(input["speech_rate"] == nil)
        #expect(input["speed"] == nil)
        #expect(input["language"] == nil)
        #expect(input["language_type"] == nil)
        #expect(AlibabaSpeechAdapter.manualVoiceOnlyModels.contains("qwen-audio-3.0-tts-plus"))
    }

    @Test func sseClassificationCarriesNoMessageText() {
        let pcm = Data([0x10, 0x20])
        #expect(AlibabaSpeechAdapter.classify(jsonDictionary(Data(
            #"{"output":{"audio":{"data":"\#(pcm.base64EncodedString())"}}}"#.utf8))) == .audio(pcm))
        #expect(AlibabaSpeechAdapter.classify(jsonDictionary(Data(
            #"{"output":{"finish_reason":"stop"}}"#.utf8))) == .finished)

        let auth = AlibabaSpeechAdapter.classify(jsonDictionary(Data(
            #"{"code":"InvalidApiKey","message":"api-key sk-abc123 denied","request_id":"rid-1"}"#.utf8)))
        if case .rejected(let authentication, let quota, let logID) = auth {
            #expect(authentication && !quota && logID == "rid-1")
        } else { Issue.record("expected rejected") }

        let quotaEvent = AlibabaSpeechAdapter.classify(jsonDictionary(Data(
            #"{"code":"Throttling.RateQuota","request_id":"rid-2"}"#.utf8)))
        if case .rejected(let authentication, let quota, _) = quotaEvent {
            #expect(quota && !authentication)
        } else { Issue.record("expected rejected") }

        #expect(AlibabaSpeechAdapter.classify(jsonDictionary(Data(
            #"{"code":"InternalError","message":"boom"}"#.utf8))) ==
            .rejected(authentication: false, quota: false, logID: nil))
        #expect(AlibabaSpeechAdapter.classify(nil) == .ignored)
        #expect(AlibabaSpeechAdapter.classify(jsonDictionary(Data("garbage".utf8))) == .ignored)
        // Empty base64 → no audio event.
        #expect(AlibabaSpeechAdapter.classify(jsonDictionary(Data(
            #"{"output":{"audio":{"data":""}}}"#.utf8))) == .ignored)
    }
}

// MARK: - ElevenLabs / OpenAI

@Suite("ElevenLabs/OpenAI request matrix")
struct ElevenOpenMatrixTests {
    @Test func elevenStreamURLShape() throws {
        let url = try ElevenLabsSpeechAdapter.streamURL(voiceID: "9coobvih4h2q7ncd3jps")
        #expect(url.absoluteString ==
            "https://api.elevenlabs.io/v1/text-to-speech/9coobvih4h2q7ncd3jps/stream?output_format=pcm_24000")
        let sixteen = try ElevenLabsSpeechAdapter.streamURL(voiceID: "v", sampleRate: 16_000)
        #expect(sixteen.query?.contains("output_format=pcm_16000") == true)
        #expect(throws: (any Error).self) {
            try ElevenLabsSpeechAdapter.streamURL(voiceID: "   ")
        }
    }

    @Test func elevenBodySpeedKnobClampsAndOmitsDefault() throws {
        let plain = try #require(jsonDictionary(ElevenLabsSpeechAdapter.makeBody(
            for: cloudRequest(provider: .elevenLabs, model: "eleven_multilingual_v2", rate: 1.0))))
        #expect(plain["text"] as? String == "Hello world.")
        #expect(plain["model_id"] as? String == "eleven_multilingual_v2")
        #expect(plain["voice_settings"] == nil)

        let fast = try #require(jsonDictionary(ElevenLabsSpeechAdapter.makeBody(
            for: cloudRequest(provider: .elevenLabs, rate: 2.0))))
        let settings = try #require(fast["voice_settings"] as? [String: Any])
        #expect((settings["speed"] as? Double) == 1.5)   // documented ceiling

        let slow = try #require(jsonDictionary(ElevenLabsSpeechAdapter.makeBody(
            for: cloudRequest(provider: .elevenLabs, rate: 0.5))))
        let slowSettings = try #require(slow["voice_settings"] as? [String: Any])
        #expect((slowSettings["speed"] as? Double) == 0.7)  // documented floor
    }

    @Test func elevenVoicesRequestAndParsing() throws {
        let request = ElevenLabsSpeechAdapter.voicesRequest(credential: "xi-key")
        #expect(request.url?.absoluteString.hasPrefix("https://api.elevenlabs.io/v2/voices") == true)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "xi-key")
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)

        let longVoice = String(repeating: "v", count: 200)
        var entries: [[String: Any]] = [["voice_id": "a", "name": "Anna"]]
        entries.append(["name": "no id → skipped"])
        entries.append(["voice_id": longVoice])   // displayName falls back, both truncated
        for i in 0..<600 { entries.append(["voice_id": "id-\(i)"]) }
        let payload = try JSONSerialization.data(withJSONObject: ["voices": entries])
        let voices = ElevenLabsSpeechAdapter.parseVoices(payload)
        // The hard cap bounds the RAW list scanned (prefix(500)); one of the
        // first 500 raw entries has no voice_id, so 499 valid voices emerge.
        #expect(voices.count == 499)
        #expect(voices.count <= 500)
        #expect(voices[0].voiceID == "a" && voices[0].displayName == "Anna")
        #expect(voices[0].kind == .listed)
        let fallback = voices.first { $0.voiceID == String(longVoice.prefix(128)) }
        #expect(fallback?.displayName == String(longVoice.prefix(128)))
        #expect(voices.first { $0.voiceID == "no id" } == nil)   // missing voice_id skipped
    }

    @Test func openAIPCMRequestShape() throws {
        #expect(OpenAISpeechAdapter.endpoint.absoluteString == "https://api.openai.com/v1/audio/speech")
        let base = try #require(jsonDictionary(OpenAISpeechAdapter.makeBody(for: cloudRequest(
            provider: .openAI, model: OpenAISpeechAdapter.defaultModel, rate: 1.0, language: "ja-JP"))))
        #expect(base["response_format"] as? String == "pcm")
        #expect(base["model"] as? String == "gpt-4o-mini-tts")
        #expect(base["voice"] as? String == "voice-x")
        #expect(base["speed"] == nil)          // 1.0x omitted
        #expect(base["language"] == nil)       // never invented
        #expect(base["instructions"] == nil)

        // Core clamps speechRateRatio to 0.5…2.0, so the OpenAI documented
        // 0.25 floor is unreachable from the lane: body carries the lane floor.
        let quick = try #require(jsonDictionary(OpenAISpeechAdapter.makeBody(
            for: cloudRequest(provider: .openAI, rate: 0.1), instructions: "warm tone")))
        #expect(quick["speed"] as? Double == 0.5)
        #expect(quick["instructions"] as? String == "warm tone")
        #expect(OpenAISpeechAdapter.builtInVoices.count == 13)
        #expect(Set(OpenAISpeechAdapter.supportedModels).isSuperset(of: ["gpt-4o-mini-tts", "tts-1", "tts-1-hd"]))
    }

    @Test func authHeadersCarryCredentialOnly() {
        let openAI = OpenAISpeechAdapter.makeHeaders(credential: "sk-oai")
        #expect(openAI["Authorization"] == "Bearer sk-oai")
        #expect(openAI["Accept"] == "audio/L16")
        #expect(openAI["Cache-Control"] == "no-cache")
        let eleven = ElevenLabsSpeechAdapter.makeHeaders(credential: "xi")
        #expect(eleven["xi-api-key"] == "xi")
    }
}

// MARK: - OpenAI-compatible endpoint (optional base URL)

@Suite("OpenAI-compatible speech endpoint")
struct OpenAICompatibleEndpointTests {
    @Test func absentOverrideKeepsTheOfficialEndpoint() throws {
        #expect(TTSOpenAISpeechEndpoint.officialBaseURL == "https://api.openai.com/v1")
        #expect(try TTSOpenAISpeechEndpoint.speechURL(base: nil) == OpenAISpeechAdapter.endpoint)
        #expect(try TTSOpenAISpeechEndpoint.speechURL(base: "   ") == OpenAISpeechAdapter.endpoint)
        #expect(try OpenAISpeechAdapter.speechURL(for: cloudRequest(provider: .openAI))
            .absoluteString == "https://api.openai.com/v1/audio/speech")
        #expect(try TTSSpeechService().suggestedModels(for: .openAI)
            == OpenAISpeechAdapter.supportedModels)
        // Model IDs stay manual: a provider whose /models list omits a speech
        // model must not disable it (verified against the CloseAI proxy).
        #expect(TTSOpenAISpeechEndpoint.validationProblem(for: "") == nil)
    }

    @Test func closeAIBaseURLResolvesToTheDocumentedSpeechPath() throws {
        // Vendor-documented base (verified in primary's paid probe):
        // https://api.openai-proxy.org/v1 → POST /v1/audio/speech.
        let request = cloudRequest(
            provider: .openAI, model: "tts-1", voice: "alloy",
            openAIBaseURL: "https://api.openai-proxy.org/v1")
        #expect(request.validationProblem() == nil)
        #expect(try OpenAISpeechAdapter.speechURL(for: request).absoluteString
            == "https://api.openai-proxy.org/v1/audio/speech")
        // Canonical stored form trims, lowercases scheme/host and drops the
        // trailing slash; the adapter accepts documented vendor spellings.
        #expect(try TTSOpenAISpeechEndpoint.normalized("  HTTPS://API.OpenAI-Proxy.org/v1/ ")
            == "https://api.openai-proxy.org/v1")
        #expect(try OpenAISpeechAdapter.speechURL(for: cloudRequest(
            provider: .openAI, openAIBaseURL: "  HTTPS://API.OpenAI-Proxy.org/v1/ "))
            .absoluteString == "https://api.openai-proxy.org/v1/audio/speech")
        // Official body shape is unchanged by the address override.
        let body = try #require(jsonDictionary(OpenAISpeechAdapter.makeBody(for: request)))
        #expect(body["model"] as? String == "tts-1")
        #expect(body["voice"] as? String == "alloy")
        #expect(body["response_format"] as? String == "pcm")
    }

    @Test func reverseProxyPrefixesAndFullEndpointsArePreserved() throws {
        let cases: [(String, String)] = [
            // Bare host: the conventional /v1 prefix is added once.
            ("https://api.openai-proxy.org", "https://api.openai-proxy.org/v1/audio/speech"),
            // Reverse-proxy path prefixes survive verbatim.
            ("https://gw.example.com/proxy", "https://gw.example.com/proxy/v1/audio/speech"),
            ("https://gw.example.com/proxy/v1", "https://gw.example.com/proxy/v1/audio/speech"),
            // No duplicated /v1 or /audio/speech can be produced.
            ("https://gw.example.com/proxy/v1/v1", "https://gw.example.com/proxy/v1/audio/speech"),
            ("https://gw.example.com/proxy/v1/v1/v1", "https://gw.example.com/proxy/v1/audio/speech"),
            ("https://api.openai.com/v1/audio/speech", "https://api.openai.com/v1/audio/speech"),
            ("https://gw.example.com/audio/speech", "https://gw.example.com/audio/speech"),
            // A non-default port is part of the address and is kept.
            ("https://gw.example.com:8443/v1", "https://gw.example.com:8443/v1/audio/speech"),
        ]
        for (raw, expected) in cases {
            #expect(try TTSOpenAISpeechEndpoint.speechURL(base: raw).absoluteString == expected,
                    "unexpected resolution for \(raw)")
        }
    }

    @Test func unusableAddressesFailBeforeRequestOrCredentialUse() async {
        let invalid = [
            "http://api.openai-proxy.org/v1",         // plain HTTP is never enabled
            "https://user:pass@api.example.com/v1",   // credentials embedded in URL
            "https://api.example.com/v1?key=1",       // query parameters
            "https://api.example.com/v1#frag",        // fragment
            "https://api.example.com:0/v1",           // invalid port
            "https://api.example.com:70000/v1",
            "ftp://api.example.com/v1",
            "not a url",
            "https:///v1",                            // missing host
            "https://api example.com/v1",             // interior space
        ]
        for raw in invalid {
            #expect(TTSOpenAISpeechEndpoint.validationProblem(for: raw) != nil,
                    "expected rejection for \(raw)")
            #expect(throws: (any Error).self) {
                try TTSOpenAISpeechEndpoint.speechURL(base: raw)
            }
            #expect(cloudRequest(provider: .openAI, openAIBaseURL: raw).validationProblem() != nil,
                    "dispatch validation must reject \(raw)")
        }
        // The router rejects the frozen request before it reaches the
        // credential-bearing adapter call: no network is attempted.
        let request = cloudRequest(
            provider: .openAI, openAIBaseURL: "http://insecure.example/v1")
        let error = await speechError(from: TTSSpeechService().synthesize(
            request, credential: "synthetic-should-not-be-sent"))
        guard case .invalidConfiguration(let reason)? = error else {
            Issue.record("expected invalidConfiguration, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("https"))
    }

    @Test func blankAddressFallsBackToOfficialAndIsNotStored() throws {
        #expect(cloudRequest(provider: .openAI, openAIBaseURL: "   ").openAIBaseURL == nil)
        #expect(TTSSettingsSnapshot(openAIBaseURL: " \n ").openAIBaseURL == nil)
        #expect(try TTSOpenAISpeechEndpoint.normalized("   ") == nil)
        #expect(try TTSOpenAISpeechEndpoint.normalized(nil) == nil)
        #expect(try TTSOpenAISpeechEndpoint.speechURL(base: "  ") == OpenAISpeechAdapter.endpoint)
    }

    @Test func originChangeRequiresANewKeyButPathChangeDoesNot() {
        #expect(!TTSOpenAISpeechEndpoint.originChanged(from: nil, to: "https://api.openai.com/v1"))
        #expect(!TTSOpenAISpeechEndpoint.originChanged(from: "https://api.openai.com:443/v1", to: nil))
        #expect(TTSOpenAISpeechEndpoint.originChanged(from: nil, to: "https://api.openai-proxy.org/v1"))
        #expect(TTSOpenAISpeechEndpoint.originChanged(
            from: "https://api.openai-proxy.org/v1", to: "https://api.openai-proxy.org:8443/v1"))
        #expect(!TTSOpenAISpeechEndpoint.originChanged(
            from: "https://api.openai-proxy.org/v1", to: "https://api.openai-proxy.org/gateway/v1"))
    }

    @Test func otherProvidersKeepTheirEndpointsAndIgnoreTheAddress() throws {
        // The override belongs to the OpenAI route only: a stray value on
        // another profile can never retarget its documented endpoint.
        let volc = cloudRequest(
            provider: .volcengine, model: "doubao-seed-tts-2.0", voice: "v",
            openAIBaseURL: "https://ignored.example/v1")
        #expect(volc.validationProblem() == nil)
        #expect(VolcengineSpeechAdapter.resourceID(forModel: "doubao-seed-tts-2.0", route: .payAsYouGo) != nil)
        let alibaba = cloudRequest(
            provider: .alibaba, route: .tokenPlan, openAIBaseURL: "https://ignored.example/v1")
        #expect(try AlibabaSpeechAdapter.endpoint(request: alibaba).absoluteString
            .hasPrefix(AlibabaSpeechAdapter.tokenPlanBase + AlibabaSpeechAdapter.speechPath))
        let eleven = cloudRequest(provider: .elevenLabs, openAIBaseURL: "https://ignored.example/v1")
        #expect(try ElevenLabsSpeechAdapter.streamURL(voiceID: eleven.voiceID).host
            == "api.elevenlabs.io")
    }
}

// MARK: - HTTP classification + redaction

@Suite("Speech transport classification")
struct SpeechTransportTests {
    @Test func statusLabelsUseExplicitRoute() {
        let tokenPlan401 = TTSSpeechHTTP.classifyHTTPStatus(
            provider: .alibaba, statusCode: 401, logID: "rid", route: .tokenPlan)
        #expect(tokenPlan401 == .authentication(provider: .alibaba, route: .tokenPlan, logID: "rid"))
        let agentPlan429 = TTSSpeechHTTP.classifyHTTPStatus(
            provider: .volcengine, statusCode: 429, logID: nil, route: .agentPlan)
        #expect(agentPlan429 == .quotaOrRateLimited(provider: .volcengine, route: .agentPlan, logID: nil))
        let unlabeled401 = TTSSpeechHTTP.classifyHTTPStatus(
            provider: .openAI, statusCode: 403, logID: nil)
        #expect(unlabeled401 == .authentication(provider: .openAI, route: .payAsYouGo, logID: nil))
        let server500 = TTSSpeechHTTP.classifyHTTPStatus(
            provider: .elevenLabs, statusCode: 500, logID: "trace", route: .payAsYouGo)
        #expect(server500 == .httpStatus(provider: .elevenLabs, statusCode: 500, logID: "trace"))
    }

    @Test func traceIDsAreSanitizedOrDropped() {
        #expect(TTSSynthesisError.sanitizedLogID("abc-123_XYZ") == "abc-123_XYZ")
        #expect(TTSSynthesisError.sanitizedLogID("key: sk-secret\nheader: x") == "keysk-secretheaderx")
        #expect(TTSSynthesisError.sanitizedLogID(String(repeating: "a", count: 65)) == nil)
        #expect(TTSSynthesisError.sanitizedLogID("   ") == nil)
        #expect(TTSSynthesisError.sanitizedLogID(nil) == nil)
    }

    @Test func urLErrorCategoriesAreFixed() {
        func nsError(_ code: Int) -> NSError {
            NSError(domain: NSURLErrorDomain, code: code, userInfo: nil)
        }
        #expect(TTSTransportFailure(for: CancellationError()) == .cancelled)
        #expect(TTSTransportFailure(for: nsError(NSURLErrorCannotFindHost)) == .cannotResolveHost)
        #expect(TTSTransportFailure(for: nsError(NSURLErrorCannotConnectToHost)) == .cannotConnect)
        #expect(TTSTransportFailure(for: nsError(NSURLErrorTimedOut)) == .timedOut)
        #expect(TTSTransportFailure(for: nsError(NSURLErrorSecureConnectionFailed)) == .tlsFailure)
        #expect(TTSTransportFailure(for: nsError(NSURLErrorServerCertificateHasBadDate)) == .tlsFailure)
        #expect(TTSTransportFailure(for: nsError(NSURLErrorNotConnectedToInternet)) == .notReachable)
        #expect(TTSTransportFailure(for: nsError(NSURLErrorCancelled)) == .cancelled)
        #expect(TTSTransportFailure(for: nsError(-999_999)) == .unknown)
        #expect(TTSTransportFailure(for: NSError(domain: "other", code: 1)) == .unknown)
    }

    @Test func normalizationCarriesNoRawText() {
        let passthrough = TTSSpeechNormalize.normalize(
            TTSSynthesisError.streamTruncated(provider: .openAI), provider: .openAI)
        #expect((passthrough as? TTSSynthesisError) == .streamTruncated(provider: .openAI))
        let decodeError = TTSSpeechNormalize.normalize(
            VolcSpeechFrame.DecodeError.truncated, provider: .volcengine)
        #expect((decodeError as? TTSSynthesisError) ==
            .providerRejected(provider: .volcengine, code: nil, logID: nil))
        let cancelled = TTSSpeechNormalize.normalize(CancellationError(), provider: .alibaba)
        #expect((cancelled as? TTSSynthesisError) == .cancelled)
        let other = TTSSpeechNormalize.normalize(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut), provider: .elevenLabs)
        #expect((other as? TTSSynthesisError) == .transport(provider: .elevenLabs, failure: .timedOut))
    }

    @Test func byteChunkGroupingIsEvenAndLossless() async throws {
        // Grouping determinism (shared backend used by the cross-compile
        // fallback and by these tests on every host).
        let input = Data((0..<10).map { UInt8($0) })
        let chunks = TTSSpeechByteChunks(buffered: input, chunkBytes: 4)
        var collected = Data()
        for try await piece in chunks {
            #expect(piece.count == 4 || piece.count == 2)   // 4+4+2, sample-aligned
            #expect(piece.count % 2 == 0)
            collected.append(piece)
        }
        #expect(collected == input)
    }
}

// MARK: - Segmenter / chunking

@Suite("Speech text and PCM shaping")
struct SegmenterChunkingTests {
    @Test func sentenceBoundariesWithMinAndMax() {
        var segmenter = TTSTextSegmenter()
        // "Hi." is under the 8-char minimum: it keeps accumulating.
        #expect(segmenter.append("Hi.") == [])
        // Cutting after "." at 10 chars emits the first unit; " You?" (5)
        // stays pending under the minimum.
        #expect(segmenter.append(" there. You?") == ["Hi. there."])
        #expect(segmenter.finish() == ["You?"])

        // Long run without terminators forces max-size cuts.
        var forced = TTSTextSegmenter(minCharacters: 8, maxCharacters: 12)
        let out = forced.append("abcdefghijklmnopqrstuvwxyz")
        #expect(!out.isEmpty)
        #expect(out.allSatisfy { $0.count <= 12 })
        #expect(out.joined().count == 24)   // 26 fed, last 2 still pending
        #expect(forced.hasPendingText)
    }

    @Test func cjkAndNewlineTerminators() {
        var segmenter = TTSTextSegmenter()
        let segments = segmenter.append("你好世界，今天天气不错。我们出去走走吧！")
        #expect(segments.first?.hasSuffix("不错。") == true)
        let remainder = segmenter.append("继续。")
        // "我们出去走走吧！" ends at ！ but is only 9 chars ≥ min → emitted.
        #expect(remainder.isEmpty || remainder.first?.hasSuffix("。") == true)
    }

    @Test func finishFlushesRemainderAndClearsPending() {
        var segmenter = TTSTextSegmenter()
        #expect(segmenter.append("Short") == [])
        #expect(segmenter.hasPendingText)
        let rest = segmenter.finish()
        #expect(rest == ["Short"])
        #expect(!segmenter.hasPendingText)
        #expect(segmenter.finish() == [])
    }

    @Test func decimalPointsNeverSplitNumbers() {
        // Amount/latency decimals stay whole (coordinator-reported defect):
        // the ONLY cut in this sentence is the final period.
        var amounts = TTSTextSegmenter()
        #expect(amounts.append("The measured latency was 12865.50 ms for the batch.")
                == ["The measured latency was 12865.50 ms for the batch."])
        #expect(amounts.finish().isEmpty)

        var ratio = TTSTextSegmenter()
        #expect(ratio.append("Set speechRateRatio to 0.7 and retry. Then 12. The rest is later.")
                == ["Set speechRateRatio to 0.7 and retry.", "Then 12.", "The rest is later."])
        #expect(ratio.finish().isEmpty)
    }

    @Test func decimalLookaheadHoldsAcrossAppends() {
        // A number split across streaming appends must not cut at the period
        // while the lookahead is unknown; the re-scan resolves it.
        var streaming = TTSTextSegmenter()
        #expect(streaming.append("Total was 128.") == [])      // could still be 128.65
        #expect(streaming.append("65 ms.") == ["Total was 128.65 ms."])
        #expect(streaming.finish().isEmpty)

        // …and the same held period DOES terminate once a non-digit follows.
        var boundary = TTSTextSegmenter()
        #expect(boundary.append("We bought 12.") == [])
        #expect(boundary.append(" Next week 7.") == ["We bought 12."])
        #expect(boundary.finish() == ["Next week 7."])         // trailing digit+period: stays until EOF flush
    }

    @Test func ceilingPrefersWhitespaceKeepsWordsWhole() {
        var words = TTSTextSegmenter(minCharacters: 8, maxCharacters: 12)
        let cut = words.append("alpha beta gamma delta")
        // Cuts land at spaces ("alpha beta" / "gamma delta"), never mid-word
        // like "…g" / "del…".
        #expect(cut == ["alpha beta", "gamma delta"])
        #expect(words.finish().isEmpty)

        // A word longer than the ceiling still stays BOUNDED (order kept,
        // nothing lost) even though it must split: 12 + 8 = 20 fed.
        var longWord = TTSTextSegmenter(minCharacters: 8, maxCharacters: 12)
        #expect(longWord.append("antidisestablishment") == ["antidisestab"])
        #expect(longWord.finish() == ["lishment"])
    }

    @Test func whitespaceCutRespectsTheMinimumFloor() {
        // The preferred space boundary is only used at/after minCharacters;
        // here the ONLY space sits at index 5 (< min 16), so the ceiling
        // hard-cuts the full 20 instead of emitting an under-minimum word.
        var tiny = TTSTextSegmenter(minCharacters: 16, maxCharacters: 20)
        let out = tiny.append("ab cd efghijklmnopqrst")
        #expect(out == ["ab cd efghijklmnopqr"])
        #expect(out.allSatisfy { $0.count <= 20 })
        #expect(tiny.finish() == ["st"])
    }

    @Test func chunkingPreservesConcatenationAndAlignment() {
        #expect(TTSSpeechPCMChunking.split(Data()) == [])
        let small = Data(repeating: 7, count: 100)
        #expect(TTSSpeechPCMChunking.split(small) == [small])
        let exact = Data(repeating: 3, count: TTSSpeechLimits.maxChunkBytes)
        #expect(TTSSpeechPCMChunking.split(exact) == [exact])

        let oddTotal = TTSSpeechLimits.maxChunkBytes + 1
        let pieces = TTSSpeechPCMChunking.split(Data(repeating: 9, count: oddTotal))
        #expect(pieces.count == 2)
        #expect(pieces[0].count == TTSSpeechLimits.maxChunkBytes)   // even
        #expect(pieces[1].count == 1)                               // only-last-may-be-odd
        #expect(pieces.reduce(Data()) { acc, next in
            var merged = acc; merged.append(next); return merged
        }.count == oddTotal)

        let evenTail = Data(repeating: 5, count: TTSSpeechLimits.maxChunkBytes + 2)
        let evenPieces = TTSSpeechPCMChunking.split(evenTail)
        #expect(evenPieces.allSatisfy { $0.count % 2 == 0 })
        #expect(evenPieces.count == 2 && evenPieces[1].count == 2)
    }
}

// MARK: - Lossless channel

@Suite("Audio chunk channel determinism")
struct TTSAudioChunkStreamTests {
    @Test(.timeLimit(.minutes(1)))
    func losslessFastProducerSlowConsumer() async throws {
        let (stream, sender) = TTSAudioChunkStream.make(slotCapacity: 2, byteCapacity: 1024)
        let producer = Task {
            do {
                for i in 0..<40 {
                    try await sender.send(makeChunk(UInt8(i % 251), count: i % 7 == 0 ? 33 : 17))
                }
                try await sender.send(makeChunk(250, count: 0, final: true))
                sender.finish()
            } catch {
                sender.finish(throwing: error)
            }
        }
        let received = try await drain(stream)
        #expect(received.count == 41)
        #expect(received.last?.isFinal == true)
        for (index, chunk) in received.enumerated() where index < 40 {
            #expect(chunk.pcm == makeChunk(UInt8(index % 251), count: index % 7 == 0 ? 33 : 17).pcm)
        }
        _ = await producer.value
    }

    @Test(.timeLimit(.minutes(1)))
    func capacityBackpressureParksProducer() async throws {
        let (stream, sender) = TTSAudioChunkStream.make(slotCapacity: 1, byteCapacity: 64)
        try await sender.send(makeChunk(1, count: 4))
        let parkedReturn = OnceFlag()
        let parked = Task<Error?, Never> {
            do { try await sender.send(makeChunk(2, count: 4)) } catch { parkedReturn.mark(); return error }
            parkedReturn.mark()
            return nil
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!parkedReturn.isSet)                      // full → producer awaits (never drops)
        var it = stream.makeAsyncIterator()
        let first = try await it.next()
        #expect(first?.sequence == 1)
        let second = try await it.next()
        #expect(second?.sequence == 2)                    // woken slot delivered in order
        _ = await parked.value
        #expect(parkedReturn.isSet)
    }

    @Test(.timeLimit(.minutes(1)))
    func byteCapacityAlsoParksProducer() async throws {
        let (stream, sender) = TTSAudioChunkStream.make(slotCapacity: 8, byteCapacity: 10)
        try await sender.send(makeChunk(1, count: 8))
        let parkedReturn = OnceFlag()
        let parked = Task<Error?, Never> {
            do { try await sender.send(makeChunk(2, count: 8)) } catch { parkedReturn.mark(); return error }
            parkedReturn.mark()
            return nil
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!parkedReturn.isSet)                      // slots free, bytes full → still awaits
        var it = stream.makeAsyncIterator()
        _ = try await it.next()
        _ = await parked.value                            // only completes after a byte drains
        #expect(parkedReturn.isSet)
        _ = try await it.next()
        sender.finish()
    }

    @Test func drainBeforeEOF() async throws {
        let (stream, sender) = TTSAudioChunkStream.make(slotCapacity: 8)
        for i in 1...3 { try await sender.send(makeChunk(UInt8(i))) }
        sender.finish()                                   // queued chunks survive close
        let received = try await drain(stream)
        #expect(received.map(\.sequence) == [1, 2, 3])
    }

    @Test func drainBeforeTerminalFailure() async throws {
        let (stream, sender) = TTSAudioChunkStream.make(slotCapacity: 8)
        try await sender.send(makeChunk(1))
        try await sender.send(makeChunk(2))
        sender.finish(throwing: TTSSynthesisError.streamTruncated(provider: .openAI))
        var it = stream.makeAsyncIterator()
        #expect((try await it.next())?.sequence == 1)
        #expect((try await it.next())?.sequence == 2)
        await #expect(throws: TTSSynthesisError.streamTruncated(provider: .openAI)) {
            _ = try await it.next()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func consumerCancelClosesChannelAndWakesParkedSender() async throws {
        // slotCapacity 1 + an unbounded producer: the producer can only exit
        // via a send that throws, which guarantees a parked sender (and a live
        // consumer) at the moment of cancellation — a finite producer could
        // drain, self-EOF and close normally before the cancel ever lands.
        let (stream, sender) = TTSAudioChunkStream.make(slotCapacity: 1, byteCapacity: 8)
        let marker = Task { _ = try? await Task.sleep(nanoseconds: .max) }   // stand-in network producer
        sender.attach(marker)
        let producer = Task<Error?, Never> {
            var i: UInt8 = 0
            do {
                while true {
                    i = i &+ 1
                    try await sender.send(makeChunk(i, count: 4))
                }
            } catch { return error }
        }
        let consumer = Task<Error?, Never> {
            var it = stream.makeAsyncIterator()
            do {
                while true {
                    let chunk = try await it.next()
                    if chunk == nil { break }
                }
            } catch { return error }
            return nil
        }
        try await Task.sleep(for: .milliseconds(60))
        consumer.cancel()                                 // cancellation INSIDE next()
        let consumerError = await consumer.value
        #expect((consumerError as? TTSSynthesisError) == .cancelled,
                "consumer must observe cancellation, got \(String(describing: consumerError))")
        let producerError = await producer.value
        #expect((producerError as? TTSSynthesisError) == .cancelled,
                "parked send must wake and throw .cancelled — never hang, never drop silently")
        #expect(marker.isCancelled, "consumer close must cancel the attached producer task")
    }

    @Test func finishAfterCloseWakesNothingAndKeepsFirstFailure() async throws {
        let (stream, sender) = TTSAudioChunkStream.make(slotCapacity: 2)
        sender.finish(throwing: TTSSynthesisError.cancelled)
        sender.finish(throwing: TTSSynthesisError.invalidConfiguration("second close ignored"))
        let received = await speechError(from: stream)
        #expect(received == .cancelled)
        // Sends after close throw the retained terminal failure — no resurrection.
        do {
            try await sender.send(makeChunk(9))
            Issue.record("send after close must throw")
        } catch let error as TTSSynthesisError {
            #expect(error == .cancelled)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func attachAfterCloseCancelsImmediately() async throws {
        let (_, sender) = TTSAudioChunkStream.make()
        sender.finish()
        let late = Task { _ = try? await Task.sleep(nanoseconds: .max) }
        sender.attach(late)
        _ = await late.value                              // returns because attach cancelled it
        #expect(late.isCancelled)
    }

    @Test func sendBoundedByteCapClosesExplicitly() async throws {
        let (stream, sender) = TTSAudioChunkStream.make(slotCapacity: 4, byteCapacity: 8)
        #expect(sender.sendBounded(makeChunk(1, count: 8)))
        #expect(!sender.sendBounded(makeChunk(2, count: 4)))     // past the cap: false, explicit close
        var it = stream.makeAsyncIterator()
        #expect((try await it.next())?.sequence == 1)            // already-accepted chunk survives
        await #expect(throws: TTSSynthesisError.streamTruncated(provider: .apple)) {
            _ = try await it.next()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sendBoundedHandoffToParkedConsumer() async throws {
        let (stream, sender) = TTSAudioChunkStream.make(slotCapacity: 1, byteCapacity: 16)
        let consumer = Task { () -> TTSAudioChunk? in
            var it = stream.makeAsyncIterator()
            return try? await it.next()
        }
        try await Task.sleep(for: .milliseconds(40))             // consumer parks on empty
        #expect(sender.sendBounded(makeChunk(5, count: 6)))      // direct handoff
        let delivered = await consumer.value
        #expect(delivered?.sequence == 5)
    }

    @Test(.timeLimit(.minutes(2)))
    func concurrentProducersDeliverEveryByte() async throws {
        // Waiter-registration race probe: four producers park and wake while a
        // single consumer drains; every chunk must arrive EXACTLY once.
        for round in 0..<3 {
            let (stream, sender) = TTSAudioChunkStream.make(slotCapacity: 2, byteCapacity: 128)
            var producers: [Task<Void, Never>] = []
            for producerID in 0..<4 {
                producers.append(Task {
                    for n in 0..<8 {
                        let tag = UInt8(producerID * 8 + n)
                        try? await sender.send(makeChunk(tag, count: 3))
                    }
                })
            }
            let consumer = Task { () -> [UInt8] in
                var tags: [UInt8] = []
                do { for try await chunk in stream { tags.append(chunk.pcm.first ?? 0) } }
                catch { Issue.record("unexpected stream error round \(round): \(error)") }
                return tags
            }
            for producer in producers { await producer.value }
            sender.finish()
            let tags = await consumer.value
            #expect(tags.count == 32, "lossless: every chunk delivered, round \(round)")
            #expect(Set(tags).count == 32, "no duplicate delivery, round \(round)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func directHandoffSkipsQueueWhenConsumerParked() async throws {
        let (stream, sender) = TTSAudioChunkStream.make(slotCapacity: 1, byteCapacity: 16)
        let consumer = Task<Int, Never> { () -> Int in
            var count = 0
            do {
                for try await chunk in stream { count += chunk.pcm.count }
            } catch {
                Issue.record("parked-consumer stream failed: \(error)")
            }
            return count
        }
        try await Task.sleep(for: .milliseconds(40))     // parked on empty
        try await sender.send(makeChunk(1, count: 4))    // direct handoff
        try await sender.send(makeChunk(2, count: 4))    // queued, then delivered
        sender.finish()
        #expect(await consumer.value == 8)
    }
}

// MARK: - Router / on-device / transport defaults

@Suite("Speech service routing")
struct TTSSpeechServiceRoutingTests {
    @Test(.timeLimit(.minutes(1)))
    func onDeviceUsesInjectedLocalProvider() async throws {
        let recorder = RecordingLocalProvider()
        let service = TTSSpeechService(localProvider: recorder)
        let request = TTSSynthesisRequest(
            sessionID: fixedSessionID, provider: .onDevice, billingRoute: .payAsYouGo,
            modelID: "floe-local-1", voiceID: "lv2", text: "你好世界。", language: "zh-CN")
        let routed = service.provider(for: request) as? RecordingLocalProvider
        #expect(routed === recorder)

        let chunks = try await drain(service.synthesize(request, credential: ""))
        #expect(chunks.count == 2)
        #expect(chunks.last?.isFinal == true)
        #expect(chunks.allSatisfy { $0.sessionID == fixedSessionID })
        let recorded = recorder.recorded
        #expect(recorded.count == 1)
        #expect(recorded[0].0.language == "zh-CN")
        #expect(recorded[0].0.modelID == "floe-local-1")
        #expect(recorded[0].0.voiceID == "lv2")
        #expect(recorded[0].1.isEmpty)                   // local route: no credential consumed
    }

    @Test func onDeviceWithoutLocalProviderFailsClosed() async throws {
        let service = TTSSpeechService()                       // no local provider
        let request = localRequest()
        // provider(for:) stays total…
        #expect(service.provider(for: request) is TTSMissingLocalSpeechProvider)
        // …but dispatch fails with an ACTIONABLE configuration error, and the
        // router never substitutes apple or any cloud provider.
        let error = await speechError(from: service.synthesize(request, credential: ""))
        guard case .invalidConfiguration(let reason)? = error else {
            Issue.record("expected invalidConfiguration, got \(String(describing: error))"); return
        }
        #expect(reason.contains("local provider"))

        // Same contract through provider(for:).synthesize.
        let direct = await speechError(
            from: service.provider(for: request).synthesize(request, credential: "unused"))
        #expect(direct != nil)
    }

    @Test func invalidRequestsFailBeforeAnyDispatch() async throws {
        let service = TTSSpeechService()
        let mismatch = cloudRequest(provider: .volcengine, route: .tokenPlan)
        let error = await speechError(from: service.synthesize(mismatch, credential: "x"))
        guard case .invalidConfiguration(let reason)? = error else {
            Issue.record("expected invalidConfiguration"); return
        }
        #expect(reason.contains("not valid"))
        let empty = await speechError(from: service.synthesize(localRequest(text: "  "), credential: ""))
        #expect(empty == .invalidConfiguration("request text is empty"))
    }

    @Test func localCatalogEndpointsAreOffline() async throws {
        let service = TTSSpeechService()
        #expect(service.builtinVoices(for: .onDevice).isEmpty)
        #expect(service.suggestedModels(for: .onDevice).isEmpty)
        // fetchVoiceCatalog(.onDevice) must not touch the network: no throw, empty.
        let voices = try await service.fetchVoiceCatalog(provider: .onDevice, credential: "junk")
        #expect(voices.isEmpty)
        let cloudOnly = service.builtinVoices(for: .openAI)
        #expect(cloudOnly.count == 13)
    }

    @Test func defaultTransportIsTheSharedEphemeralSession() throws {
        let service = TTSSpeechService()
        let openAI = service.provider(for: cloudRequest(provider: .openAI)) as? OpenAISpeechAdapter
        let session = try #require(openAI?.session)
        #expect(session === ProviderTransport.ephemeralSession)
        let configuration = session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        // An injected session is honored instead.
        let custom = URLSession(configuration: .default)
        let routed = TTSSpeechService(session: custom)
        let volc = routed.provider(for: cloudRequest(provider: .volcengine)) as? VolcengineSpeechAdapter
        #expect(volc?.session === custom)
    }

    @Test func alibabaTokenPlanAuthFailureKeepsTokenPlanLabel() {
        // Regression for the checkpoint defect: a token-plan 401 must NEVER be
        // reported as pay-as-you-go (wrong key/route advice).
        let error = TTSSpeechHTTP.classifyHTTPStatus(
            provider: .alibaba, statusCode: 401,
            logID: TTSSynthesisError.sanitizedLogID("req-1"), route: .tokenPlan)
        #expect(error == .authentication(provider: .alibaba, route: .tokenPlan, logID: "req-1"))
    }
}

// MARK: - Apple local source (preflight paths that never touch live synthesis)

#if canImport(AVFoundation) && (os(iOS) || os(macOS))
@Suite("Apple PCM source preflight")
struct AppleSpeechSourceTests {
    @Test func emptyTextFailsBeforeAnySynthesizerWork() async {
        let adapter = AppleSystemSpeechAdapter()
        let error = await speechError(
            from: adapter.synthesize(localRequest(provider: .apple, text: " "), credential: ""))
        #expect(error == .invalidConfiguration("request text is empty"))
    }

    @Test func applePathBypassesCloudValidationThroughTheRouter() {
        let service = TTSSpeechService()
        // provider(for:) total for apple; validation problem nil with empty
        // model/voice; the router selects the LOCAL adapter (never onDevice's
        // fail-closed sentinel, never a cloud adapter). Actual offline write
        // completion stays the documented device-verification item.
        let request = localRequest(provider: .apple)
        #expect(request.validationProblem() == nil)
        #expect(service.provider(for: request) is AppleSystemSpeechAdapter)
    }
}
#endif
