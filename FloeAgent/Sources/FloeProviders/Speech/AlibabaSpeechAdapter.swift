// FloeProviders — Alibaba Model Studio speech TTS adapter (two explicit channels).
//
// SPDX-License-Identifier: MPL-2.0
//
// Token Plan and pay-as-you-go are fully isolated per the official docs
// (2026-10-22): different key prefixes (`sk-sp-` plan keys vs `sk-` metered
// keys), different hosts, and mixing them yields 401/403 plus unexpected
// billing. Both channels use the SAME native TTS multimodal path —
// POST .../api/v1/services/audio/tts/SpeechSynthesizer with `X-DashScope-SSE:
// enable` streams base64 PCM chunks (SSE) — not chat completions:
//
//   tokenPlan    https://token-plan.cn-beijing.maas.aliyuncs.com/...  (plan key;
//                qwen-audio-3.0-tts-plus has NO built-in voices — an existing
//                cloned/designed voice ID is mandatory, nothing is invented)
//   payAsYouGo   https://dashscope.aliyuncs.com/... (cn-beijing) or
//                https://dashscope-intl.aliyuncs.com/... (ap-southeast-1)
//
// Rate/pitch knobs: this endpoint documents no speed parameter, so
// speechRateRatio is intentionally ignored rather than approximated.

import Foundation
import FloeCore

public struct AlibabaSpeechAdapter: TTSSpeechProviding {
    public static let tokenPlanBase = "https://token-plan.cn-beijing.maas.aliyuncs.com"
    public static let payAsYouGoBeijing = "https://dashscope.aliyuncs.com"
    public static let payAsYouGoSingapore = "https://dashscope-intl.aliyuncs.com"
    public static let speechPath = "/api/v1/services/audio/tts/SpeechSynthesizer"

    public static let supportedRegions: [String] = ["cn-beijing", "ap-southeast-1"]

    /// Models whose official docs state there is no built-in voice list
    /// (custom voice ID required). UI uses this to hide any suggestion list.
    public static let manualVoiceOnlyModels: Set<String> = ["qwen-audio-3.0-tts-plus"]

    let session: URLSession

    public init(session: URLSession? = nil) {
        // Default TTS transport is the module-internal ephemeral session: no
        // shared URLCache/cookie/credential storage, so speech traffic never
        // writes provider responses to disk (temporary-chat privacy rule too).
        self.session = session ?? ProviderTransport.session(ephemeral: true)
    }

    public static func endpoint(request: TTSSynthesisRequest) throws -> URL {
        let base: String
        switch request.billingRoute {
        case .tokenPlan:
            base = tokenPlanBase   // plan is cn-beijing only per official docs
        case .payAsYouGo:
            switch request.region ?? "cn-beijing" {
            case "cn-beijing": base = payAsYouGoBeijing
            case "ap-southeast-1": base = payAsYouGoSingapore
            default:
                throw TTSSynthesisError.invalidConfiguration("unknown Alibaba region")
            }
        case .agentPlan:
            throw TTSSynthesisError.invalidConfiguration("Alibaba has no agent-plan route")
        }
        guard let url = URL(string: base + speechPath) else {
            throw TTSSynthesisError.invalidConfiguration("endpoint build failed")
        }
        return url
    }

    public static func makeHeaders(credential: String) -> [String: String] {
        var headers = TTSSpeechRequestHeaders(accept: "text/event-stream")
        headers["Authorization"] = "Bearer \(credential)"
        headers["X-DashScope-SSE"] = "enable"
        return headers
    }

    public static func makeBody(for request: TTSSynthesisRequest) -> Data {
        let payload: [String: Any] = [
            "model": request.modelID,
            "input": [
                "text": request.text,
                "voice": request.voiceID,
                "format": "pcm",
                "sample_rate": request.format.sampleRate,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    public func synthesize(
        _ request: TTSSynthesisRequest,
        credential: String
    ) -> TTSAudioChunkStream {
        ttssRunStream(provider: .alibaba) { sender in
            guard request.validationProblem() == nil else {
                throw TTSSynthesisError.invalidConfiguration(
                    request.validationProblem() ?? "invalid request")
            }
            let url = try Self.endpoint(request: request)
            let opened = try await TTSSpeechHTTP.post(
                url: url,
                headers: Self.makeHeaders(credential: credential),
                body: Self.makeBody(for: request),
                session: session,
                provider: .alibaba,
                route: request.billingRoute)
            var parser = SSEParser()
            var sequence = 0
            var received = 0
            var sawStop = false
            for try await chunk in opened.chunks {
                received += chunk.count
                if received > TTSSpeechLimits.maxSegmentAudioBytes {
                    throw TTSSynthesisError.streamTruncated(provider: .alibaba)
                }
                for event in parser.feed(chunk) {
                    switch Self.classify(TTSSpeechJSON.dictionary(Data(event.data.utf8))) {
                    case .audio(let pcm):
                        for piece in TTSSpeechPCMChunking.split(pcm) {
                            try await sender.send(TTSAudioChunk(
                                sessionID: request.sessionID, segmentIndex: request.segmentIndex,
                                sequence: sequence, pcm: piece,
                                sampleRate: request.format.sampleRate))
                            sequence += 1
                        }
                    case .finished:
                        sawStop = true
                    case .rejected(let authentication, let quota, let logID):
                        if authentication {
                            throw TTSSynthesisError.authentication(
                                provider: .alibaba, route: request.billingRoute, logID: logID)
                        }
                        if quota {
                            throw TTSSynthesisError.quotaOrRateLimited(
                                provider: .alibaba, route: request.billingRoute, logID: logID)
                        }
                        throw TTSSynthesisError.providerRejected(
                            provider: .alibaba, code: nil, logID: logID)
                    case .ignored:
                        break
                    }
                }
            }
            if !sawStop {
                throw TTSSynthesisError.streamTruncated(provider: .alibaba)
            }
            try await sender.send(TTSAudioChunk(
                sessionID: request.sessionID, segmentIndex: request.segmentIndex,
                sequence: sequence, pcm: Data(),
                sampleRate: request.format.sampleRate, isFinal: true))
            sender.finish()
        }
    }

    /// SSE event classification. Error CODE strings are matched against a
    /// fixed table; provider message text never leaves the adapter.
    enum SSEEventClassification: Equatable, Sendable {
        case audio(Data)
        case finished
        case rejected(authentication: Bool, quota: Bool, logID: String?)
        case ignored
    }

    static func classify(_ dict: [String: Any]?) -> SSEEventClassification {
        guard let dict else { return .ignored }
        if let codeString = TTSSpeechJSON.string(dict, "code"), !codeString.isEmpty {
            let lowered = codeString.lowercased()
            let isAuth = lowered.contains("apikey") || lowered.contains("auth")
                || lowered.contains("forbidden") || lowered.contains("unauthorized")
            let isQuota = lowered.contains("throttling") || lowered.contains("quota")
                || lowered.contains("limit")
            return .rejected(
                authentication: isAuth,
                quota: isQuota,
                logID: TTSSynthesisError.sanitizedLogID(TTSSpeechJSON.string(dict, "request_id")))
        }
        let output = TTSSpeechJSON.dictionary(dict, "output")
        let audio = output.flatMap { TTSSpeechJSON.dictionary($0, "audio") }
        if let base64 = audio.flatMap({ TTSSpeechJSON.string($0, "data") }),
           let pcm = TTSSpeechJSON.base64Data(base64), !pcm.isEmpty {
            return .audio(pcm)
        }
        if TTSSpeechJSON.string(output ?? [:], "finish_reason") == "stop" {
            return .finished
        }
        return .ignored
    }
}
