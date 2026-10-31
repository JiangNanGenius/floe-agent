// FloeProviders — OpenAI Realtime transcription adapter (native WebSocket).
//
// SPDX-License-Identifier: MPL-2.0
//
// `wss://api.openai.com/v1/realtime?intent=transcription` with a Bearer key.
// The session is a transcription session (not a conversation):
//
//   session.update   type=transcription, PCM 24 kHz input,
//                    audio.input.transcription.model=gpt-live-transcribe,
//                    turn_detection=null
//   append           input_audio_buffer.append (Base64 PCM16)
//   commit           input_audio_buffer.commit (client VAD)
//   receive          conversation.item.input_audio_transcription.delta /
//                    .completed / .failed, keyed by item_id
//
// `input_audio_buffer.committed` reconciles the server item with the caller's
// turn. Events are typed partial/final/failed updates; a slow consumer applies
// backpressure instead of losing deltas. `finish` drains to the final event and
// closes; `cancel` discards queued events and never becomes a provider failure
// (so it must not trigger cloud fallback or route switching).
//
// All optional session fields are gated by the model capability catalog: a
// model that does not document `languages`, `prompt` or `keywords` never
// receives them. Frames, transcripts and the event queue are bounded; provider
// error text is dropped and only a redacted category leaves this adapter.

import Foundation
import FloeCore

public struct OpenAIRealtimeTranscriptionAdapter: ASRLiveTranscribing {
    public static let supportedSampleRate = 24_000
    public static let maximumAppendAudioBytes = 1 * 1024 * 1024
    public static let maximumFrameBytes = 1 * 1024 * 1024
    public static let maximumTranscriptCharacters = 2_000_000
    public static let maximumEvents = 20_000

    private let transport: any ASRWebSocketTransport

    public init(transport: any ASRWebSocketTransport) {
        self.transport = transport
    }

    #if !canImport(FoundationNetworking)
    public init(session: URLSession? = nil) {
        self.transport = URLSessionWebSocketTransport(
            session: session ?? ASRTransportSecurity.makeWebSocketSession())
    }
    #endif

    public func startLiveSession(
        _ request: ASRLiveSessionRequest,
        credential: String
    ) async throws -> any ASRLiveSession {
        let profile = request.profile
        guard profile.provider == .openaiCompatible else {
            throw ASRTranscriptionError.invalidConfiguration(
                "this adapter only serves OpenAI-compatible profiles")
        }
        guard profile.provider.supports(profile.billingRoute) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "billing route is not available for this provider")
        }
        guard let liveModel = profile.liveModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !liveModel.isEmpty else {
            throw ASRTranscriptionError.invalidConfiguration(
                "live transcription model is required")
        }
        let capabilities = ASRModelCapabilityCatalog.capabilities(
            for: .openaiCompatible, modelID: liveModel)
        guard capabilities.supportsLiveTranscription else {
            throw ASRTranscriptionError.invalidConfiguration(
                "this model does not support live transcription")
        }
        guard request.inputSampleRate == Self.supportedSampleRate else {
            throw ASRTranscriptionError.invalidConfiguration(
                "realtime transcription requires 24 kHz PCM input")
        }
        // Validate the endpoint before the credential is used. The endpoint
        // helper requires wss/https and composes intent=transcription once.
        let endpoint = try ASROpenAIRealtimeEndpoint.endpointURL(
            base: profile.resolvedLiveEndpoint)
        let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ASRTranscriptionError.credentialMissing }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.timeoutInterval = 30
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let connection: any ASRWebSocketConnection
        do {
            connection = try await transport.connect(urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let asr = error as? ASRTranscriptionError {
                if case .transport(.cancelled) = asr { throw CancellationError() }
                throw asr
            }
            let mapped = ASRTransportErrorMapping.failure(error)
            if case .transport(.cancelled) = mapped { throw CancellationError() }
            throw mapped
        }

        let languages = request.languages.isEmpty
            ? profile.languages
            : request.languages
        let prompt = request.prompt ?? profile.prompt
        let keywords = request.keywords.isEmpty
            ? profile.keywords
            : request.keywords
        let session = OpenAIRealtimeTranscriptionSession(
            connection: connection,
            request: request,
            modelID: liveModel,
            capabilities: capabilities,
            languages: languages,
            prompt: prompt,
            keywords: keywords)
        do {
            try await session.start()
        } catch {
            await session.cancel()
            throw error
        }
        return session
    }
}

/// One live utterance. The actor serialises feed/commit/finish and the socket
/// receive loop; the bounded event stream is the only consumer-facing queue.
public actor OpenAIRealtimeTranscriptionSession: ASRLiveSession {
    public nonisolated let events: ASRBoundedEventStream<ASRLiveEvent>
    public nonisolated let turnID: UUID

    private enum State: Sendable, Hashable {
        case idle
        case active
        case terminal
        case cancelled
    }

    private let connection: any ASRWebSocketConnection
    private let request: ASRLiveSessionRequest
    private let modelID: String
    private let capabilities: ASRModelCapabilities
    private let languages: [String]
    private let prompt: String?
    private let keywords: [String]

    private var state: State = .idle
    private var commitSent = false
    private var audioBytes = 0
    private var partialText = ""
    private var itemID: String?
    private var sequence = 0
    private var receivedEventCount = 0
    private var finalReceived = false
    private var streamError: ASRTranscriptionError?
    private var receiveTask: Task<Void, Never>?

    init(
        connection: any ASRWebSocketConnection,
        request: ASRLiveSessionRequest,
        modelID: String,
        capabilities: ASRModelCapabilities,
        languages: [String],
        prompt: String?,
        keywords: [String]
    ) {
        self.connection = connection
        self.request = request
        self.modelID = modelID
        self.capabilities = capabilities
        self.languages = languages
        self.prompt = prompt
        self.keywords = keywords
        self.turnID = request.turnID
        self.events = ASRBoundedEventStream(capacity: request.eventQueueCapacity)
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard state == .idle else { return }
        state = .active
        do {
            try await sendJSON(Self.sessionUpdate(
                modelID: modelID,
                capabilities: capabilities,
                languages: languages,
                prompt: prompt,
                keywords: keywords))
        } catch {
            await failOrCancel(error, cancelReceiving: true)
            throw error
        }
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
    }

    public func feed(_ audio: Data) async throws {
        guard state == .active else {
            if state == .cancelled { throw CancellationError() }
            throw ASRTranscriptionError.invalidConfiguration(
                "the live session has already ended")
        }
        guard !commitSent else {
            throw ASRTranscriptionError.invalidConfiguration(
                "the utterance was already committed")
        }
        guard !audio.isEmpty else { return }
        guard audio.count <= OpenAIRealtimeTranscriptionAdapter.maximumAppendAudioBytes else {
            throw ASRTranscriptionError.invalidConfiguration(
                "audio chunk exceeds the live append limit")
        }
        guard audio.count % 2 == 0 else {
            throw ASRTranscriptionError.invalidConfiguration(
                "live audio must be 16-bit PCM")
        }
        guard audioBytes + audio.count <= request.maximumAudioBytes else {
            throw ASRTranscriptionError.invalidConfiguration(
                "audio exceeds the live session limit")
        }
        audioBytes += audio.count
        do {
            try await sendJSON([
                "type": "input_audio_buffer.append",
                "audio": audio.base64EncodedString(),
            ])
        } catch {
            await failOrCancel(error, cancelReceiving: true)
            throw error
        }
    }

    public func endUtterance() async throws {
        guard state == .active else {
            if state == .cancelled { throw CancellationError() }
            throw ASRTranscriptionError.invalidConfiguration(
                "the live session has already ended")
        }
        guard !commitSent else { return }
        guard audioBytes > 0 else {
            throw ASRTranscriptionError.invalidConfiguration(
                "no audio has been fed to the live session")
        }
        commitSent = true
        do {
            try await sendJSON(["type": "input_audio_buffer.commit"])
        } catch {
            await failOrCancel(error, cancelReceiving: true)
            throw error
        }
    }

    public func finish() async throws {
        if state == .cancelled { throw CancellationError() }
        if let streamError { throw streamError }
        guard state != .idle else {
            throw ASRTranscriptionError.invalidConfiguration(
                "the live session has not started")
        }
        if state == .terminal { return }
        if !commitSent {
            guard audioBytes > 0 else {
                throw ASRTranscriptionError.invalidConfiguration(
                    "no audio has been fed to the live session")
            }
            commitSent = true
            do {
                try await sendJSON(["type": "input_audio_buffer.commit"])
            } catch {
                await failOrCancel(error, cancelReceiving: true)
                throw error
            }
        }
        await waitForTerminal(timeout: request.finishTimeoutSeconds)
        if state == .cancelled { throw CancellationError() }
        if let streamError { throw streamError }
        guard state == .terminal else {
            await cancel()
            throw ASRTranscriptionError.transport(.timedOut)
        }
    }

    public func cancel() async {
        guard state != .cancelled else { return }
        state = .cancelled
        receiveTask?.cancel()
        receiveTask = nil
        connection.cancel()
        events.abandon(throwing: CancellationError())
    }

    // MARK: - Receive loop

    private func runReceiveLoop() async {
        do {
            while state == .active {
                let message = try await connection.receive()
                try Task.checkCancellation()
                switch message {
                case .text(let text):
                    try await handleFrame(text)
                case .data(let data):
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw ASRTranscriptionError.providerRejected
                    }
                    try await handleFrame(text)
                }
                if state == .terminal { break }
            }
            if state == .terminal {
                connection.close()
            } else if state == .active {
                // The server closed without the documented final event.
                await terminate(
                    error: .providerRejected, cancelReceiving: false)
            }
        } catch is CancellationError {
            await cancel()
        } catch {
            let mapped = Self.asRedacted(error)
            if case .transport(.cancelled) = mapped {
                await cancel()
            } else {
                await terminate(error: mapped, cancelReceiving: false)
            }
        }
    }

    private func handleFrame(_ text: String) async throws {
        guard text.utf8.count <= request.maximumEventBytes else {
            throw ASRTranscriptionError.responseTooLarge
        }
        receivedEventCount += 1
        guard receivedEventCount <= OpenAIRealtimeTranscriptionAdapter.maximumEvents else {
            throw ASRTranscriptionError.responseTooLarge
        }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let type = Self.string(dictionary["type"]) else {
            throw ASRTranscriptionError.providerRejected
        }
        switch type {
        case "input_audio_buffer.committed":
            if let id = Self.string(dictionary["item_id"]), !id.isEmpty {
                itemID = id
            }
        case "conversation.item.input_audio_transcription.delta":
            guard !finalReceived else { return }
            guard accepts(itemID: Self.string(dictionary["item_id"])) else { return }
            guard let delta = Self.string(dictionary["delta"]), !delta.isEmpty else {
                return
            }
            partialText += delta
            guard partialText.count <= OpenAIRealtimeTranscriptionAdapter
                .maximumTranscriptCharacters else {
                throw ASRTranscriptionError.responseTooLarge
            }
            sequence += 1
            try await events.send(.partial(
                turnID: turnID,
                itemID: itemID,
                delta: delta,
                sequence: sequence))
        case "conversation.item.input_audio_transcription.completed":
            guard !finalReceived else { return }
            guard accepts(itemID: Self.string(dictionary["item_id"])) else { return }
            let transcript = (Self.string(dictionary["transcript"]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let finalText = transcript.isEmpty ? partialText : transcript
            guard finalText.count <= OpenAIRealtimeTranscriptionAdapter
                .maximumTranscriptCharacters else {
                throw ASRTranscriptionError.responseTooLarge
            }
            finalReceived = true
            sequence += 1
            // Deliver the final into the event stream BEFORE marking the
            // session terminal: `finish()` polls the state and must not return
            // until the final (or failure) event is enqueued.
            try await events.send(.final(
                turnID: turnID,
                itemID: itemID,
                transcript: finalText,
                sequence: sequence))
            events.finish()
            state = .terminal
        case "conversation.item.input_audio_transcription.failed":
            guard accepts(itemID: Self.string(dictionary["item_id"])) else { return }
            streamError = .providerRejected
            sequence += 1
            try await events.send(.failed(
                turnID: turnID,
                itemID: itemID,
                error: .providerRejected,
                sequence: sequence))
            events.finish()
            state = .terminal
        case "error":
            // Provider message text is untrusted and deliberately dropped.
            streamError = .providerRejected
            sequence += 1
            try await events.send(.failed(
                turnID: turnID,
                itemID: itemID,
                error: .providerRejected,
                sequence: sequence))
            events.finish()
            state = .terminal
        default:
            // session.updated, input_audio_buffer.*, rate_limits.updated and
            // future event types are ignored for forward compatibility.
            break
        }
    }

    // MARK: - Sending

    private func sendJSON(_ object: [String: Any]) async throws {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "could not encode the realtime event")
        }
        do {
            try await connection.send(.text(text))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let asr = error as? ASRTranscriptionError {
                if case .transport(.cancelled) = asr { throw CancellationError() }
                throw asr
            }
            let mapped = ASRTransportErrorMapping.failure(error)
            if case .transport(.cancelled) = mapped { throw CancellationError() }
            throw mapped
        }
    }

    static func sessionUpdate(
        modelID: String,
        capabilities: ASRModelCapabilities,
        languages: [String],
        prompt: String?,
        keywords: [String]
    ) -> [String: Any] {
        var transcription: [String: Any] = ["model": modelID]
        if capabilities.supportsPrompt,
           let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            transcription["prompt"] = String(
                prompt.prefix(ASRProfile.maximumPromptCharacters))
        }
        if capabilities.supportsKeywords, !keywords.isEmpty {
            transcription["keywords"] = Array(
                keywords.prefix(ASRProfile.maximumKeywords))
        }
        if capabilities.languageParameter == .array, !languages.isEmpty {
            transcription["languages"] = Array(languages.prefix(ASRProfile.maximumLanguages))
        }
        let input: [String: Any] = [
            "format": [
                "type": "audio/pcm",
                "rate": OpenAIRealtimeTranscriptionAdapter.supportedSampleRate,
            ],
            "transcription": transcription,
            "turn_detection": NSNull(),
        ]
        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": input],
            ],
        ]
    }

    // MARK: - Terminal handling

    private func waitForTerminal(timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while state == .active {
            if Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func failOrCancel(_ error: Error, cancelReceiving: Bool) async {
        if error is CancellationError {
            await cancel()
        } else {
            await terminate(
                error: Self.asRedacted(error), cancelReceiving: cancelReceiving)
        }
    }

    private func terminate(error: ASRTranscriptionError, cancelReceiving: Bool) async {
        guard state != .cancelled, state != .terminal else { return }
        state = .terminal
        streamError = error
        if cancelReceiving {
            receiveTask?.cancel()
            receiveTask = nil
        }
        connection.cancel()
        events.finish(throwing: error)
    }

    private static func asRedacted(_ error: Error) -> ASRTranscriptionError {
        if let asr = error as? ASRTranscriptionError { return asr }
        if error is CancellationError { return .transport(.cancelled) }
        return ASRTransportErrorMapping.failure(error)
    }

    /// Match a transcription event to the committed server item. A late event
    /// for a different item is ignored instead of being misattributed to this
    /// turn. Before `input_audio_buffer.committed` arrives, the first event's
    /// item id is adopted (it is still keyed in the emitted event).
    private func accepts(itemID frameItem: String?) -> Bool {
        guard let frameItem, !frameItem.isEmpty else { return true }
        if let itemID { return itemID == frameItem }
        itemID = frameItem
        return true
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }
}
