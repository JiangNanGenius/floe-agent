// FloeProviders — DeepSeek continuous speech synthesis over the official
// /v1/tools/tts WebSocket.
//
// SPDX-License-Identifier: MPL-2.0
//
// Official guide: https://api-docs.deepseek.com/zh-cn/guides/tts/
//
// Two entry points share one wire implementation:
//
// * `DeepSeekStreamingSpeechSession` — ONE WebSocket session for a whole
//   spoken round. The caller feeds the model's body as an `AsyncStream<String>`
//   of ordered text deltas; a send lane forwards them verbatim as incremental
//   `{"event":"text"}` messages and emits exactly one `{"event":"finish_text"}`
//   when the text stream ends, while a RECEIVE lane runs in parallel and
//   turns the server's binary messages into ordered 24 kHz s16le mono PCM
//   chunks. The session ends on the documented text `finish` event. This is
//   the true incremental path: text deltas flow while the model is still
//   generating and audio plays continuously.
//
// * `DeepSeekStreamingSpeechAdapter` — the `TTSSpeechProviding` conformance
//   for one bounded synthesis REQUEST (one sentence): the same session with a
//   single-delta text stream. Used by seams that synthesize per segment.
//
// The guide documents no per-sentence audio boundary inside one session, so
// round audio is emitted with the aggregated unit's identity and sentence
// attribution stays the consumer's job. Teardown rules (no orphaned
// connections, no long fallback waits):
//
// * a SEND-lane failure records the first error and cancels the connection
//   immediately, so a blocked receive never waits out a server timeout; the
//   recorded (sanitized) error is what the consumer sees;
// * consumer cancellation cancels the connection inside the cancellation
//   handler, interrupting a blocked receive on the spot;
// * a drained success closes gracefully; every other exit cancels.
//
// Provider error/message text NEVER leaves these types: finish codes map to
// fixed `TTSSynthesisError` categories only. Handshake-level failures (auth,
// quota) are not observable as HTTP statuses on a WebSocket upgrade; they
// surface as transport categories, with post-handshake failures carried by
// the documented finish codes.

import Foundation
import FloeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Shared wire helpers

enum DeepSeekStreamingWire {
    /// Build the documented `wss://api.deepseek.com/v1/tools/tts` upgrade
    /// request: `voice_id` + `format=pcm` query, bearer credential header,
    /// no cache reuse. The host/path stay pinned to the single FloeCore
    /// source of truth (DeepSeekSpeechAPI.ttsURL, scheme upgraded to wss).
    static func makeHandshake(voiceID: String, credential: String) throws -> URLRequest {
        guard DeepSeekSpeechAPI.voices.contains(voiceID) else {
            throw TTSSynthesisError.invalidConfiguration("invalid DeepSeek speech configuration")
        }
        guard var components = URLComponents(
            url: DeepSeekSpeechAPI.ttsURL, resolvingAgainstBaseURL: false) else {
            throw TTSSynthesisError.invalidConfiguration("endpoint build failed")
        }
        components.scheme = "wss"
        components.queryItems = [
            URLQueryItem(name: "voice_id", value: voiceID),
            URLQueryItem(name: "format", value: "pcm"),
        ]
        guard let url = components.url else {
            throw TTSSynthesisError.invalidConfiguration("endpoint build failed")
        }
        var handshake = URLRequest(url: url, timeoutInterval: 30)
        handshake.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        handshake.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return handshake
    }

    /// Strict JSON encoding for one text event (speech text is untrusted
    /// content and may carry quotes/controls — never interpolated).
    static func textEvent(_ chunk: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["event": "text", "text": chunk])
        return String(data: data, encoding: .utf8)!
    }

    static let finishTextEvent = #"{"event":"finish_text"}"#

    /// Splits one bounded text into ordered `text` event payloads. The
    /// concatenation of the returned chunks equals `text` EXACTLY (no trim,
    /// no reformat — billing-identical). A chunk closes at the first
    /// whitespace/sentence-punctuation boundary at/after `maxCharacters`;
    /// without a natural boundary it hard-closes at `maxCharacters * 2`
    /// (legal: the server concatenates text events verbatim).
    static func textChunks(_ text: String, maxCharacters: Int = 24) -> [String] {
        let boundary: Set<Character> = [
            " ", "\t", "\n", "\r", ",", ".", "!", "?", ";", ":",
            "，", "。", "！", "？", "；", "：", "、", "-", "—", "…",
        ]
        var chunks: [String] = []
        var current = ""
        current.reserveCapacity(Swift.min(text.count, maxCharacters * 2))
        for character in text {
            current.append(character)
            if current.count >= maxCharacters, boundary.contains(character) {
                chunks.append(current)
                current = ""
            } else if current.count >= maxCharacters * 2 {
                chunks.append(current)
                current = ""
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// One session may carry at most 10,000 billing characters / 64 KiB of
    /// text. Checked incrementally against the cumulative forwarded text
    /// (identical arithmetic to the whole-text POST route); throws the same
    /// lane errors the moment the cap is crossed.
    struct SessionTextBudget: Sendable {
        private(set) var billedCharacters = 0
        private(set) var byteCount = 0

        /// Returns the event payload to send, or throws when the budget
        /// would be exceeded. Whitespace is billed like any other scalar
        /// (parity with the POST body), so no non-empty delta is dropped.
        mutating func forward(_ delta: String) throws -> String {
            let hanIdeographs = #/[\p{Script=Han}&&\p{Ideographic}]/#.matchingSemantics(.unicodeScalar)
            billedCharacters += delta.unicodeScalars.prefix(10_001).count
                + delta.ranges(of: hanIdeographs).count
            byteCount += delta.utf8.count
            guard billedCharacters <= 10_000 else {
                throw TTSSynthesisError.invalidConfiguration(
                    "DeepSeek text exceeds 10,000 billing characters")
            }
            guard byteCount <= 64 * 1024 else {
                throw TTSSynthesisError.invalidConfiguration("DeepSeek request exceeds 64 KiB")
            }
            return delta
        }
    }

    /// First failure wins between the parallel send/receive lanes. A
    /// send-lane failure is recorded here and cancels the connection, so a
    /// blocked receive never sits out a server timeout, and the recorded
    /// (sanitized) error — not the receive-side teardown noise — is what
    /// the consumer sees.
    final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?

        func record(_ error: Error) {
            lock.lock()
            if stored == nil { stored = error }
            lock.unlock()
        }

        func errorValue() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    enum FinishOutcome {
        case success
        case failure(Error)
        /// Not a finish event: keep receiving.
        case notFinish
    }

    static func finishEventOutcome(_ text: String) -> FinishOutcome {
        guard let data = text.data(using: .utf8),
              let dict = TTSSpeechJSON.dictionary(data),
              TTSSpeechJSON.string(dict, "event") == "finish",
              let code = TTSSpeechJSON.string(dict, "code") else { return .notFinish }
        if code == "success" { return .success }
        return .failure(error(forFinishCode: code))
    }

    /// Documented finish codes -> fixed categories. The provider `message`
    /// text is NEVER carried (it may echo request content). WS codes are
    /// strings, so the Int? slot of `providerRejected` stays nil rather than
    /// inventing numeric identities.
    static func error(forFinishCode code: String) -> TTSSynthesisError {
        switch code {
        case "input_timeout":
            return .transport(provider: .deepSeek, failure: .timedOut)
        default:
            // content_filter, invalid_input, service_error, unknown codes.
            return .providerRejected(provider: .deepSeek, code: nil, logID: nil)
        }
    }
}

// MARK: - Round-scoped continuous session (the true incremental entry)

/// One continuous DeepSeek TTS WebSocket session for a whole spoken round.
/// Created per round from the round-frozen voice + resolved credential;
/// `synthesize` takes the round's text as ordered deltas and returns the
/// round's continuous PCM as ordered chunks stamped with the caller's
/// `sessionID` / `segmentIndex` (the aggregated round unit's identity).
public struct DeepSeekStreamingSpeechSession: Sendable {
    public let voiceID: String
    private let credential: String
    private let transport: (any ASRWebSocketTransport)?

    public init(voiceID: String, credential: String, transport: (any ASRWebSocketTransport)? = nil) {
        self.voiceID = voiceID
        self.credential = credential
        #if canImport(FoundationNetworking)
        // URLSessionWebSocketTask is Apple-platform API. The Linux
        // cross-compile target keeps the protocol seam (fakes compile and
        // run there) but ships no native transport: synthesize fails closed.
        self.transport = transport
        #else
        self.transport = transport ?? URLSessionWebSocketTransport(
            session: ASRTransportSecurity.makeWebSocketSession())
        #endif
    }

    /// Feeds `text` deltas to one WebSocket session and streams the PCM
    /// result. Deltas are forwarded in order, verbatim (whitespace included),
    /// as incremental `text` events; `finish_text` is sent exactly once when
    /// the text stream completes. Sending runs in parallel with reception;
    /// audio chunks are emitted as they arrive. The stream ends on the
    /// server's `finish` event (final empty chunk) or throws a mapped,
    /// redacted error; cancelling the consumer's iteration interrupts a
    /// blocked receive immediately (the socket is cancelled inside the
    /// cancellation handler) and terminates the send lane.
    public func synthesize(
        text: AsyncStream<String>,
        sessionID: UUID,
        segmentIndex: Int
    ) -> TTSAudioChunkStream {
        ttssRunStream(provider: .deepSeek) { sender in
            try Task.checkCancellation()
            let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw TTSSynthesisError.credentialMissing(provider: .deepSeek, route: .payAsYouGo)
            }
            guard let transport else {
                throw TTSSynthesisError.invalidConfiguration(
                    "DeepSeek streaming synthesis requires an Apple-platform WebSocket transport")
            }
            let connection = try await transport.connect(
                DeepSeekStreamingWire.makeHandshake(voiceID: voiceID, credential: key))
            var completedNormally = false
            let failure = DeepSeekStreamingWire.FailureBox()
            // SEND lane, running in PARALLEL with reception: ordered verbatim
            // deltas as incremental `text` events, then exactly one
            // `finish_text` after the last delta. Detached (not a structured
            // child) so a caller text stream that is still open at teardown
            // can never wedge the receive lane or the socket cleanup: it is
            // cancelled on every exit path below, and the stream contract
            // requires the caller to terminate it at round-text completion.
            // Any send failure is recorded and cancels the connection so the
            // receive lane cannot sit out a server timeout.
            let sendTask = Task.detached { [text] in
                do {
                    var budget = DeepSeekStreamingWire.SessionTextBudget()
                    for await delta in text {
                        try Task.checkCancellation()
                        guard !delta.isEmpty else { continue }
                        let payload = try budget.forward(delta)
                        try await connection.send(.text(DeepSeekStreamingWire.textEvent(payload)))
                    }
                    try Task.checkCancellation()
                    try await connection.send(.text(DeepSeekStreamingWire.finishTextEvent))
                } catch {
                    // Cancellation is teardown, not a round failure: only a
                    // genuine send failure is recorded (and it cancels the
                    // connection so the receive lane cannot sit out a server
                    // timeout). Cleanup ordering belongs to the defer below.
                    let nsError = error as NSError?
                    let isTeardown = error is CancellationError
                        || (nsError?.domain == NSURLErrorDomain && nsError?.code == NSURLErrorCancelled)
                    if !isTeardown {
                        failure.record(error)
                        connection.cancel()
                    }
                }
            }
            defer {
                sendTask.cancel()
                if completedNormally { connection.close() } else { connection.cancel() }
            }

            do {
                // RECEIVE lane: binary messages become ordered PCM chunks
                // (backpressured, lossless); the documented finish event ends
                // the round with exactly one final chunk. Consumer
                // cancellation cancels the socket inside the handler, which
                // interrupts a blocked receive on the spot.
                try await withTaskCancellationHandler {
                    try await Self.receiveRound(
                        connection: connection, sessionID: sessionID,
                        segmentIndex: segmentIndex, sender: sender)
                } onCancel: {
                    connection.cancel()
                }
            } catch {
                // A send-lane failure is the actionable root cause: surface
                // the recorded (sanitized) error instead of the receive-side
                // teardown noise.
                if let sendError = failure.errorValue() { throw sendError }
                throw error
            }
            sender.finish()
            completedNormally = true
        }
    }

    /// Ordered PCM reception for one round: binary messages -> chunks, the
    /// documented `finish` event -> exactly one final empty chunk. A finish
    /// without any audio is a failed synthesis, not a playable empty answer
    /// (same rule as the POST route).
    private static func receiveRound(
        connection: any ASRWebSocketConnection,
        sessionID: UUID,
        segmentIndex: Int,
        sender: TTSAudioChunkSender
    ) async throws {
        var sequence = 0
        var receivedAudioBytes = 0
        receiveLoop: while true {
            let message = try await connection.receive()
            switch message {
            case .data(let pcm):
                receivedAudioBytes += pcm.count
                if receivedAudioBytes > TTSSpeechLimits.maxSegmentAudioBytes {
                    throw TTSSynthesisError.streamTruncated(provider: .deepSeek)
                }
                for piece in TTSSpeechPCMChunking.split(pcm) {
                    try await sender.send(TTSAudioChunk(
                        sessionID: sessionID, segmentIndex: segmentIndex,
                        sequence: sequence, pcm: piece,
                        sampleRate: TTSAudioFormat.pcm24k.sampleRate))
                    sequence += 1
                }
            case .text(let text):
                switch DeepSeekStreamingWire.finishEventOutcome(text) {
                case .success:
                    break receiveLoop
                case .failure(let error):
                    throw error
                case .notFinish:
                    // Unknown/forward-compatible events are ignored; only
                    // the documented finish event (or a failure) ends the
                    // session.
                    continue
                }
            }
        }
        guard receivedAudioBytes > 0 else {
            throw TTSSynthesisError.streamTruncated(provider: .deepSeek)
        }
        try Task.checkCancellation()
        try await sender.send(TTSAudioChunk(
            sessionID: sessionID, segmentIndex: segmentIndex,
            sequence: sequence, pcm: Data(),
            sampleRate: TTSAudioFormat.pcm24k.sampleRate, isFinal: true))
    }
}

// MARK: - Per-request adapter (TTSSpeechProviding)

public struct DeepSeekStreamingSpeechAdapter: TTSSpeechProviding {
    private let transport: (any ASRWebSocketTransport)?

    public init(transport: (any ASRWebSocketTransport)? = nil) {
        #if canImport(FoundationNetworking)
        self.transport = transport
        #else
        self.transport = transport ?? URLSessionWebSocketTransport(
            session: ASRTransportSecurity.makeWebSocketSession())
        #endif
    }

    public func synthesize(_ request: TTSSynthesisRequest, credential: String) -> TTSAudioChunkStream {
        ttssRunStream(provider: .deepSeek) { sender in
            try Task.checkCancellation()
            // Parity with the whole-text POST route: identical voice, billing
            // and body bounds are enforced before anything is dispatched.
            _ = try DeepSeekSpeechAdapter.body(for: request)
            let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw TTSSynthesisError.credentialMissing(provider: .deepSeek, route: .payAsYouGo)
            }
            guard let transport else {
                throw TTSSynthesisError.invalidConfiguration(
                    "DeepSeek streaming synthesis requires an Apple-platform WebSocket transport")
            }
            let connection = try await transport.connect(
                DeepSeekStreamingWire.makeHandshake(voiceID: request.voiceID, credential: key))
            var completedNormally = false
            defer {
                if completedNormally { connection.close() } else { connection.cancel() }
            }

            // Incremental input: ordered text events whose concatenation is
            // EXACTLY the request text (billing-identical), then one
            // finish_text. Cooperative cancellation between sends.
            for chunk in DeepSeekStreamingWire.textChunks(request.text) {
                try Task.checkCancellation()
                try await connection.send(.text(DeepSeekStreamingWire.textEvent(chunk)))
            }
            try Task.checkCancellation()
            try await connection.send(.text(DeepSeekStreamingWire.finishTextEvent))

            // Consumer cancellation cancels the socket inside the handler,
            // interrupting a blocked receive on the spot.
            try await withTaskCancellationHandler {
                try await Self.receiveRequest(connection: connection, request: request, sender: sender)
            } onCancel: {
                connection.cancel()
            }
            sender.finish()
            completedNormally = true
        }
    }

    private static func receiveRequest(
        connection: any ASRWebSocketConnection,
        request: TTSSynthesisRequest,
        sender: TTSAudioChunkSender
    ) async throws {
        var sequence = 0
        var receivedAudioBytes = 0
        receiveLoop: while true {
            let message = try await connection.receive()
            switch message {
            case .data(let pcm):
                receivedAudioBytes += pcm.count
                if receivedAudioBytes > TTSSpeechLimits.maxSegmentAudioBytes {
                    throw TTSSynthesisError.streamTruncated(provider: .deepSeek)
                }
                for piece in TTSSpeechPCMChunking.split(pcm) {
                    try await sender.send(TTSAudioChunk(
                        sessionID: request.sessionID, segmentIndex: request.segmentIndex,
                        sequence: sequence, pcm: piece,
                        sampleRate: request.format.sampleRate))
                    sequence += 1
                }
            case .text(let text):
                switch DeepSeekStreamingWire.finishEventOutcome(text) {
                case .success:
                    break receiveLoop
                case .failure(let error):
                    throw error
                case .notFinish:
                    // Unknown/forward-compatible events are ignored; only
                    // the documented finish event (or a failure) ends the
                    // session.
                    continue
                }
            }
        }
        // A finish without any audio is a failed synthesis, not a
        // playable empty answer (same rule as the POST route).
        guard receivedAudioBytes > 0 else {
            throw TTSSynthesisError.streamTruncated(provider: .deepSeek)
        }
        try Task.checkCancellation()
        try await sender.send(TTSAudioChunk(
            sessionID: request.sessionID, segmentIndex: request.segmentIndex,
            sequence: sequence, pcm: Data(),
            sampleRate: request.format.sampleRate, isFinal: true))
    }
}
