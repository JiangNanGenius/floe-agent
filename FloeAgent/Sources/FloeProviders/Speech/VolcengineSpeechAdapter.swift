// FloeProviders — Volcengine Doubao speech TTS adapter (two explicit channels).
//
// SPDX-License-Identifier: MPL-2.0
//
// Agent Plan and pay-as-you-go Doubao Voice are SEPARATE services with
// separate keys, resource bindings and endpoints (verified against the
// official Agent Plan voice docs and the V3 Doubao Voice docs on 2026-10-22):
//
//   agentPlan     wss://openspeech.bytedance.com/api/v3/plan/tts/unidirectional/stream
//                 (X-Api-Key: dedicated plan key, X-Api-Resource-Id: seed-tts-2.0,
//                  fresh X-Api-Connect-Id per session — never reused, even after
//                  a failed attempt; binary JSON frame codec, PCM frames streamed)
//   payAsYouGo    https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse
//                 (ordinary Doubao Voice API key — a different credential on a
//                  different URL; SSE data events carry base64 PCM chunks)
//
// A request never falls across channels: the route→(key, URL, resource)
// binding is fixed at dispatch time, and auth/quota failures surface as
// redacted errors for a MANUAL user decision. Streaming is demand-driven and
// lossless (SpeechChannel); cancellation closes the socket and the producer.

import Foundation
import FloeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct VolcengineSpeechAdapter: TTSSpeechProviding {
    public static let agentPlanWSURL =
        URL(string: "wss://openspeech.bytedance.com/api/v3/plan/tts/unidirectional/stream")!
    public static let payAsYouGoSSEURL =
        URL(string: "https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse")!

    /// Doubao TTS model ID → X-Api-Resource-Id (official docs table). The plan
    /// channel only exposes doubao-seed-tts-2.0; pay-as-you-go also supports 1.0.
    public static func resourceID(forModel modelID: String, route: TTSBillingRoute) -> String? {
        switch modelID {
        case "doubao-seed-tts-2.0", "seed-tts-2.0": return "seed-tts-2.0"
        case "doubao-seed-tts-1.0", "seed-tts-1.0":
            return route == .payAsYouGo ? "seed-tts-1.0" : nil
        default:
            return nil
        }
    }

    /// speech_rate knob: -50 → 0.5x … 100 → 2.0x (official param range).
    public static func speechRateParam(ratio: Double) -> Int {
        min(100, max(-50, Int(((ratio - 1.0) * 100.0).rounded())))
    }

    let session: URLSession

    public init(session: URLSession? = nil) {
        // Default TTS transport is the module-internal ephemeral session: no
        // shared URLCache/cookie/credential storage, so speech traffic never
        // writes provider responses to disk (temporary-chat privacy rule too).
        self.session = session ?? ProviderTransport.session(ephemeral: true)
    }

    // MARK: Payload construction (pure, tested)

    public static func makeBody(for request: TTSSynthesisRequest) -> Data {
        var audioParams: [String: Any] = [
            "format": "pcm",
            "sample_rate": request.format.sampleRate,
        ]
        let speechRate = speechRateParam(ratio: request.speechRateRatio)
        if speechRate != 0 { audioParams["speech_rate"] = speechRate }
        let payload: [String: Any] = [
            "user": ["uid": "floe-agent-ios"],
            "req_params": [
                "text": request.text,
                "speaker": request.voiceID,
                "audio_params": audioParams,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    public static func makeHeaders(
        credential: String,
        request: TTSSynthesisRequest,
        idSupplier: () -> String
    ) throws -> [String: String] {
        guard let resource = resourceID(forModel: request.modelID, route: request.billingRoute) else {
            throw TTSSynthesisError.invalidConfiguration(
                "unknown Volcengine TTS model for route \(request.billingRoute.rawValue)")
        }
        return [
            "X-Api-Key": credential,
            "X-Api-Resource-Id": resource,
            "X-Api-Request-Id": idSupplier(),
        ]
    }

    /// Success codes are the documented 200000 family; anything else in an
    /// error/JSON frame is rejected. Only the numeric code leaves the adapter.
    static func isProviderSuccess(code: Int?) -> Bool {
        guard let code else { return true }
        return code >= 200_000 && code < 300_000
    }

    // MARK: - Dispatch

    public func synthesize(
        _ request: TTSSynthesisRequest,
        credential: String
    ) -> TTSAudioChunkStream {
        if let problem = request.validationProblem() {
            let (stream, sender) = TTSAudioChunkStream.make()
            sender.finish(throwing: TTSSynthesisError.invalidConfiguration(problem))
            return stream
        }
        switch request.billingRoute {
        case .agentPlan:
            #if !canImport(FoundationNetworking)
            return synthesizeViaPlanWebSocket(request, credential: credential)
            #else
            // swift-corelibs-foundation WebSocket availability is not part of
            // the cross-platform CI contract; Linux is a build/test target,
            // never the app runtime. Fail closed (no fallback to pay-as-you-go).
            let (stream, sender) = TTSAudioChunkStream.make()
            sender.finish(throwing: TTSSynthesisError.invalidConfiguration(
                "Volcengine agent-plan WebSocket transport requires an Apple-platform build"))
            return stream
            #endif
        case .payAsYouGo: return synthesizeViaPayAsYouGoSSE(request, credential: credential)
        case .tokenPlan:
            let (stream, sender) = TTSAudioChunkStream.make()
            sender.finish(throwing: TTSSynthesisError.invalidConfiguration(
                "Volcengine has no token-plan route"))
            return stream
        }
    }

    // MARK: Pay-as-you-go SSE (incremental base64 PCM events)

    func makeSSEURLSessionRequest(
        _ request: TTSSynthesisRequest,
        credential: String,
        idSupplier: () -> String = { UUID().uuidString.lowercased() }
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: Self.payAsYouGoSSEURL, timeoutInterval: 60)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = Self.makeBody(for: request)
        let headers = try Self.makeHeaders(credential: credential, request: request, idSupplier: idSupplier)
        for (name, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return urlRequest
    }

    public func synthesizeViaPayAsYouGoSSE(
        _ request: TTSSynthesisRequest,
        credential: String
    ) -> TTSAudioChunkStream {
        ttssRunStream(provider: .volcengine) { sender in
            let urlRequest = try self.makeSSEURLSessionRequest(request, credential: credential)
            let opened = try await TTSSpeechHTTP.open(
                request: urlRequest, session: self.session, provider: .volcengine,
                route: request.billingRoute)
            var parser = SSEParser()
            var sequence = 0
            var received = 0
            for try await chunk in opened.chunks {
                received += chunk.count
                if received > TTSSpeechLimits.maxSegmentAudioBytes {
                    throw TTSSynthesisError.streamTruncated(provider: .volcengine)
                }
                for event in parser.feed(chunk) {
                    for item in Self.sseAudioEvents(from: Data(event.data.utf8)) {
                        switch item {
                        case .audio(let pcm):
                            for piece in TTSSpeechPCMChunking.split(pcm) {
                                try await sender.send(TTSAudioChunk(
                                    sessionID: request.sessionID, segmentIndex: request.segmentIndex,
                                    sequence: sequence, pcm: piece,
                                    sampleRate: request.format.sampleRate))
                                sequence += 1
                            }
                        case .rejected(let code, let logID):
                            throw TTSSynthesisError.providerRejected(
                                provider: .volcengine, code: code, logID: logID)
                        case .finished:
                            break
                        }
                    }
                }
            }
            try await sender.send(TTSAudioChunk(
                sessionID: request.sessionID, segmentIndex: request.segmentIndex,
                sequence: sequence, pcm: Data(),
                sampleRate: request.format.sampleRate, isFinal: true))
            sender.finish()
        }
    }

    /// Maps one SSE data JSON. Untrusted content: only numeric code + base64
    /// audio are extracted; message strings never leave here.
    static func sseAudioEvents(from data: Data) -> [TTSSSEAudioEvent] {
        guard let dict = TTSSpeechJSON.dictionary(data) else {
            return []
        }
        if let audio = TTSSpeechJSON.base64Data(TTSSpeechJSON.string(dict, "audio")) {
            return [.audio(audio)]
        }
        if let code = TTSSpeechJSON.int(dict, "code"), !isProviderSuccess(code: code) {
            return [.rejected(code: code, logID: TTSSynthesisError.sanitizedLogID(
                TTSSpeechJSON.string(dict, "conn_id") ?? TTSSpeechJSON.string(dict, "trace_id")))]
        }
        if let event = TTSSpeechJSON.string(dict, "event"), event.contains("Finish") {
            return [.finished]
        }
        return []
    }

    // MARK: Agent-plan frame disposition (pure, fixture-tested)

    /// Downstream session events of the plan unidirectional flow (official
    /// protocols.py EventType): the terminal event is only in the frame
    /// header — the 152 payload is `{}`.
    static let sessionFinishedEvent = 152
    static let sessionFailedEvent = 153

    /// One decoded plan-stream frame resolved to its lifecycle action. The
    /// receive loop applies exactly this decision, so captured-layout fixtures
    /// can pin termination and error propagation without a live socket.
    enum PlanFrameOutcome: Sendable, Equatable {
        case audio(Data)
        case continueSession
        case finish
        case reject(code: Int?, logID: String?)
        case ignore
    }

    /// Resolves a decoded server frame. Termination comes from the header event
    /// (152), never from a payload string: the captured SessionFinished body is
    /// `{}`, so the old "Finish" substring sniffing never matched and the
    /// session only ended through the server close (a transport failure).
    static func planFrameOutcome(_ frame: VolcSpeechFrame) -> PlanFrameOutcome {
        switch frame {
        case .serverAudio(let payload, _):
            return .audio(payload)
        case .serverJSON(let payload, let event):
            if event == sessionFinishedEvent { return .finish }
            let json = TTSSpeechJSON.dictionary(payload)
            if event == sessionFailedEvent {
                return .reject(
                    code: json.flatMap { TTSSpeechJSON.int($0, "code") } ?? sessionFailedEvent,
                    logID: planLogID(json))
            }
            // Non-terminal JSON events keep the strict code check: only a
            // documented success code (or no code at all) may pass.
            if let code = json.flatMap({ TTSSpeechJSON.int($0, "code") }),
               !isProviderSuccess(code: code) {
                return .reject(code: code, logID: planLogID(json))
            }
            return .continueSession
        case .serverError(let code, let payload):
            // Binary Error frames carry the numeric code in the header; only a
            // sanitized trace token leaves the adapter.
            return .reject(code: code, logID: planLogID(TTSSpeechJSON.dictionary(payload)))
        case .clientRequest, .clientFinish:
            return .ignore
        }
    }

    static func planLogID(_ json: [String: Any]?) -> String? {
        guard let json else { return nil }
        return TTSSynthesisError.sanitizedLogID(
            TTSSpeechJSON.string(json, "conn_id")
                ?? TTSSpeechJSON.string(json, "trace_id")
                ?? TTSSpeechJSON.string(json, "session_id"))
    }

    // MARK: Agent-plan WebSocket (unidirectional streaming)

#if !canImport(FoundationNetworking)
    // Apple-platforms only: URLSessionWebSocketTask is not part of the
    // cross-platform CI contract (see synthesize dispatch above).
    public func synthesizeViaPlanWebSocket(
        _ request: TTSSynthesisRequest,
        credential: String
    ) -> TTSAudioChunkStream {
        ttssRunStream(provider: .volcengine) { sender in
            guard let resource = Self.resourceID(
                forModel: request.modelID, route: request.billingRoute) else {
                throw TTSSynthesisError.invalidConfiguration(
                    "unknown Volcengine TTS model for the agent-plan route")
            }
            // Fresh connect id per session (documented: never reused,
            // including after a failed attempt).
            var headers = TTSSpeechRequestHeaders(accept: nil)
            headers["X-Api-Key"] = credential
            headers["X-Api-Resource-Id"] = resource
            headers["X-Api-Connect-Id"] = UUID().uuidString.lowercased()
            let socket = Self.makeWebSocketTask(
                url: Self.agentPlanWSURL, headers: headers, session: session)
            socket.resume()
            defer { socket.cancel(with: .goingAway, reason: nil) }

            try await sendFrame(.clientRequest(Self.makeBody(for: request)), via: socket)
            // The documented plan unidirectional flow is one FullClientRequest:
            // the server streams 352 audio and closes the session with header
            // event 152. Sending a second "finish" frame is not part of that
            // flow (the captured run received all audio plus 152 after the
            // single request frame), so no extra frame is sent.

            var sequence = 0
            var received = 0
            var sawFinalEvent = false
            receiveLoop: while true {
                let message = try await receiveMessage(socket)
                guard case .data(let frameBytes) = message else { continue receiveLoop }
                let frame = try VolcSpeechFrame.decode(frameBytes)
                switch Self.planFrameOutcome(frame) {
                case .audio(let payload):
                    received += payload.count
                    if received > TTSSpeechLimits.maxSegmentAudioBytes {
                        throw TTSSynthesisError.streamTruncated(provider: .volcengine)
                    }
                    for piece in TTSSpeechPCMChunking.split(payload) {
                        try await sender.send(TTSAudioChunk(
                            sessionID: request.sessionID, segmentIndex: request.segmentIndex,
                            sequence: sequence, pcm: piece,
                            sampleRate: request.format.sampleRate))
                        sequence += 1
                    }
                case .continueSession, .ignore:
                    break
                case .finish:
                    sawFinalEvent = true
                case .reject(let code, let logID):
                    throw TTSSynthesisError.providerRejected(
                        provider: .volcengine, code: code, logID: logID)
                }
                if sawFinalEvent { break receiveLoop }
            }
            try await sender.send(TTSAudioChunk(
                sessionID: request.sessionID, segmentIndex: request.segmentIndex,
                sequence: sequence, pcm: Data(),
                sampleRate: request.format.sampleRate, isFinal: true))
            sender.finish()
        }
    }

    private func sendFrame(_ frame: VolcSpeechFrame, via socket: URLSessionWebSocketTask) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            socket.send(.data(frame.encoded())) { error in
                if let error {
                    cont.resume(throwing: TTSSynthesisError.transport(
                        provider: .volcengine, failure: TTSTransportFailure(for: error)))
                } else {
                    cont.resume()
                }
            }
        }
    }

    private func receiveMessage(_ socket: URLSessionWebSocketTask) async throws
        -> URLSessionWebSocketTask.Message {
        do {
            return try await socket.receive()
        } catch {
            let failure = TTSTransportFailure(for: error)
            if case .cancelled = failure { throw TTSSynthesisError.cancelled }
            throw TTSSynthesisError.transport(provider: .volcengine, failure: failure)
        }
    }

    /// Seam so the frame plumbing is testable without a live socket.
    static func makeWebSocketTask(url: URL, headers: [String: String], session: URLSession)
        -> URLSessionWebSocketTask {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return session.webSocketTask(with: request)
    }
#endif
}
