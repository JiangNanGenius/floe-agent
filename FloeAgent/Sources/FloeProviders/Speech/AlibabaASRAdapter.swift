// FloeProviders — Alibaba Model Studio Qwen audio ASR.
//
// SPDX-License-Identifier: MPL-2.0
//
// File transcription posts the documented sync multimodal-generation payload
// (Base64 data URI + `parameters.format`/`sample_rate`) to the configured
// workspace/generation endpoint. Pay-as-you-go uses the `dashscope` default;
// Token Plan uses the dedicated token-plan host and the 3.0 file model. The
// live route uses the documented `/api-ws/v1/inference` run-task binary
// duplex flow for the 3.1 streaming model.
//
// Token Plan is callable without any membership/entitlement check. Its
// default profile has no live route, so the App files each utterance; if the
// user explicitly supplies both a streaming model and a live endpoint, the
// live adapter accepts that protocol configuration. Provider bodies and error
// text never leave this adapter.

import Foundation
import FloeCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AlibabaASRAdapter: ASRTranscribing, ASRLiveTranscribing {
    static let maximumAudioBytes = 20 * 1024 * 1024
    static let maximumResponseBytes = 8 * 1024 * 1024
    static let maximumRequestBytes = 32 * 1024 * 1024
    static let maximumTranscriptCharacters = 2_000_000
    static let maximumReceivedMessages = 20_000
    static let maximumFileSeconds = 300.0
    static let livePacketBytes = 3_200 // 100 ms @ 16 kHz, mono, 16-bit
    static let startTimeoutSeconds = 15.0

    private let httpTransport: any ASRHTTPTransport
    private let webSocketTransport: any ASRWebSocketTransport
    private let fileByteLimit: Int

    public init(
        httpTransport: any ASRHTTPTransport,
        webSocketTransport: any ASRWebSocketTransport
    ) {
        self.httpTransport = httpTransport
        self.webSocketTransport = webSocketTransport
        self.fileByteLimit = Self.maximumAudioBytes
    }

    /// Focused-test seam. Production callers use the public initializer.
    init(
        httpTransport: any ASRHTTPTransport,
        webSocketTransport: any ASRWebSocketTransport,
        fileByteLimit: Int
    ) {
        self.httpTransport = httpTransport
        self.webSocketTransport = webSocketTransport
        self.fileByteLimit = fileByteLimit
    }

    #if !canImport(FoundationNetworking)
    public init(session: URLSession? = nil) {
        let session = session ?? ASRTransportSecurity.makeHTTPSession()
        self.init(
            httpTransport: URLSessionASRHTTPTransport(session: session),
            webSocketTransport: URLSessionWebSocketTransport(session: session))
    }
    #endif

    // MARK: - Legacy request compatibility

    public func transcribe(
        _ request: ASRTranscriptionRequest,
        credential: String
    ) async throws -> ASRTranscriptionResult {
        let languages = !request.languages.isEmpty
            ? request.languages
            : (request.language.map { [$0] } ?? [])
        let profile = ASRProfile.alibaba(
            billingRoute: .payAsYouGo,
            fileModelID: request.modelID,
            fileEndpoint: request.endpointBaseURL,
            languages: languages)
        let fileRequest = ASRFileTranscriptionRequest(
            profile: profile,
            audio: request.audio,
            filename: request.filename,
            mimeType: request.mimeType,
            languages: languages,
            sourceDurationSeconds: request.durationSeconds,
            streamsResponse: false)
        return try await transcribe(fileRequest, credential: credential)
    }

    // MARK: - File transcription

    public func transcribe(
        _ request: ASRFileTranscriptionRequest,
        credential: String
    ) async throws -> ASRTranscriptionResult {
        let profile = try Self.validatedProfile(request.profile)
        let capabilities = profile.fileCapabilities
        guard capabilities.supportsFileTranscription else {
            throw ASRTranscriptionError.invalidConfiguration(
                "this model does not support file transcription")
        }
        let modelID = profile.fileModelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            throw ASRTranscriptionError.invalidConfiguration(
                "Alibaba transcription model is required")
        }
        guard request.audio.count <= Swift.min(
            fileByteLimit, capabilities.maximumFileBytes) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "audio exceeds the Alibaba transcription size limit")
        }
        let input = try ASRVendorAudioDetector.inspect(
            request.audio,
            filename: request.filename,
            mimeType: request.mimeType,
            provider: .alibaba)
        if let duration = request.sourceDurationSeconds ?? input.durationSeconds,
           duration.isFinite, duration > Self.maximumFileSeconds {
            throw ASRTranscriptionError.invalidConfiguration(
                "audio exceeds the 5-minute per-request limit; split it into shorter segments")
        }
        let endpoint = try Self.fileEndpointURL(profile)
        let key = try Self.bearer(credential)
        let body = try Self.makeRequestBody(
            modelID: modelID, input: input)
        guard body.count <= Self.maximumRequestBytes else {
            throw ASRTranscriptionError.invalidConfiguration(
                "audio exceeds the Alibaba request size limit")
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 300
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("disable", forHTTPHeaderField: "X-DashScope-SSE")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let response: ASRHTTPResponse
        do {
            response = try await httpTransport.perform(urlRequest, body: body)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let asr = error as? ASRTranscriptionError { throw asr }
            if Self.isCancellation(error) { throw CancellationError() }
            throw ASRTransportErrorMapping.failure(error)
        }
        try Task.checkCancellation()
        if let responseURL = response.url,
           !ASRTransportSecurity.sameOrigin(endpoint, responseURL) {
            throw ASRTranscriptionError.providerRejected
        }
        switch response.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ASRTranscriptionError.authentication
        case 402, 429:
            throw ASRTranscriptionError.quotaOrRateLimited
        default:
            throw ASRTranscriptionError.httpStatus(response.statusCode)
        }
        guard response.body.count <= Self.maximumResponseBytes else {
            throw ASRTranscriptionError.responseTooLarge
        }
        let result = try Self.parseResponse(
            response.body,
            sourceDurationSeconds: request.sourceDurationSeconds ?? input.durationSeconds)
        return result
    }

    // MARK: - Live transcription

    public func startLiveSession(
        _ request: ASRLiveSessionRequest,
        credential: String
    ) async throws -> any ASRLiveSession {
        let profile = try Self.validatedProfile(request.profile)
        guard let liveModel = profile.liveModelID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !liveModel.isEmpty else {
            throw ASRTranscriptionError.invalidConfiguration(
                "live transcription model is required")
        }
        let capabilities = ASRModelCapabilityCatalog.capabilities(
            for: .alibaba, modelID: liveModel)
        guard capabilities.supportsLiveTranscription else {
            throw ASRTranscriptionError.invalidConfiguration(
                "this model does not support live transcription")
        }
        guard request.inputSampleRate == 8_000 || request.inputSampleRate == 16_000 else {
            throw ASRTranscriptionError.invalidConfiguration(
                "Alibaba live transcription supports 8 kHz or 16 kHz PCM input")
        }
        let endpoint = try Self.liveEndpointURL(profile)
        let key = try Self.bearer(credential)
        let taskID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let runTask = try Self.makeRunTask(
            taskID: taskID,
            modelID: liveModel,
            sampleRate: request.inputSampleRate)

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.timeoutInterval = 30
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // The official examples use lowercase `bearer`; HTTP auth schemes are
        // case-insensitive. Keep the documented spelling.
        urlRequest.setValue("bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let connection: any ASRWebSocketConnection
        do {
            connection = try await webSocketTransport.connect(urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let asr = error as? ASRTranscriptionError { throw asr }
            if Self.isCancellation(error) { throw CancellationError() }
            throw ASRTransportErrorMapping.failure(error)
        }
        let session = AlibabaLiveSession(
            connection: connection,
            request: request,
            taskID: taskID,
            runTask: runTask)
        do {
            try await session.start()
        } catch {
            await session.cancel()
            throw error
        }
        return session
    }

    // MARK: - Validation / routing

    private static func validatedProfile(_ profile: ASRProfile) throws -> ASRProfile {
        guard profile.provider == .alibaba else {
            throw ASRTranscriptionError.invalidConfiguration(
                "this adapter only serves Alibaba profiles")
        }
        guard profile.provider.supports(profile.billingRoute) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "billing route is not available for this provider")
        }
        if let problem = profile.validationProblem() {
            throw ASRTranscriptionError.invalidConfiguration(problem)
        }
        return profile
    }

    static func fileEndpointURL(_ profile: ASRProfile) throws -> URL {
        guard let raw = profile.resolvedFileEndpoint else {
            throw ASRTranscriptionError.invalidConfiguration(
                "Alibaba transcription endpoint is required")
        }
        var components = try ASRVendorEndpoint.httpsComponents(raw)
        ASRVendorEndpoint.composePath(
            &components,
            baseSuffixes: [
                "/api/v1/services/aigc/multimodal-generation",
                "/api/v1",
            ],
            fullPath: "/api/v1/services/aigc/multimodal-generation/generation")
        guard let url = components.url else {
            throw ASRTranscriptionError.invalidConfiguration(
                "Alibaba transcription endpoint is not a valid URL")
        }
        return url
    }

    static func liveEndpointURL(_ profile: ASRProfile) throws -> URL {
        guard let raw = profile.resolvedLiveEndpoint else {
            throw ASRTranscriptionError.invalidConfiguration(
                "Alibaba live transcription endpoint is not configured")
        }
        var components = try ASRVendorEndpoint.webSocketComponents(raw)
        ASRVendorEndpoint.composePath(
            &components,
            baseSuffixes: ["/api-ws/v1"],
            fullPath: "/api-ws/v1/inference")
        guard let url = components.url else {
            throw ASRTranscriptionError.invalidConfiguration(
                "Alibaba live transcription endpoint is not a valid URL")
        }
        return url
    }

    static func bearer(_ credential: String) throws -> String {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ASRTranscriptionError.credentialMissing
        }
        guard value.rangeOfCharacter(from: .newlines) == nil,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "the Alibaba credential contains invalid characters")
        }
        return value
    }

    static func alibabaFormat(_ format: ASRVendorAudioFormat) -> String {
        switch format {
        case .wav: return "wav"
        case .mp3: return "mp3"
        case .oggOpus: return "opus"
        case .pcm: return "pcm"
        }
    }

    static func makeRequestBody(
        modelID: String,
        input: ASRVendorAudioInput
    ) throws -> Data {
        let dataURI = "data:\(input.mimeType);base64,"
            + input.data.base64EncodedString()
        let root: [String: Any] = [
            "model": modelID,
            "input": [
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "input_audio",
                                "input_audio": ["data": dataURI],
                            ],
                        ],
                    ],
                ],
            ],
            "parameters": [
                "format": alibabaFormat(input.format),
                "sample_rate": String(input.sampleRate ?? 16_000),
            ],
        ]
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(
                withJSONObject: root, options: [.sortedKeys]) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "could not encode the Alibaba request")
        }
        return data
    }

    static func makeRunTask(
        taskID: String,
        modelID: String,
        sampleRate: Int
    ) throws -> Data {
        let root: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": modelID,
                "parameters": [
                    "sample_rate": sampleRate,
                    "format": "pcm",
                ],
                "input": [:],
            ],
        ]
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(
                withJSONObject: root, options: [.sortedKeys]) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "could not encode the Alibaba live task")
        }
        return data
    }

    static func makeFinishTask(taskID: String) throws -> Data {
        let root: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex",
            ],
            "payload": ["input": [:]],
        ]
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(
                withJSONObject: root, options: [.sortedKeys]) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "could not encode the Alibaba finish task")
        }
        return data
    }

    // MARK: - Response parsing

    static func parseResponse(
        _ data: Data,
        sourceDurationSeconds: Double?
    ) throws -> ASRTranscriptionResult {
        guard !data.isEmpty else { throw ASRTranscriptionError.emptyResult }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw ASRTranscriptionError.providerRejected
        }
        guard let output = ASRVendorJSON.dictionary(root["output"]) else {
            throw ASRTranscriptionError.providerRejected
        }
        var builder = ASRVendorSegmentBuilder()
        if let sentences = ASRVendorJSON.array(output["sentences"]) {
            for raw in sentences {
                guard let sentence = ASRVendorJSON.dictionary(raw) else { continue }
                try addSentence(sentence, to: &builder)
            }
        }
        if let sentence = ASRVendorJSON.dictionary(output["sentence"]) {
            try addSentence(sentence, to: &builder)
        }
        let segments = builder.segments()
        var text = (ASRVendorJSON.string(output["text"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = segments.map(\.text).joined(separator: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty || !segments.isEmpty else {
            throw ASRTranscriptionError.emptyResult
        }
        guard text.count <= maximumTranscriptCharacters else {
            throw ASRTranscriptionError.responseTooLarge
        }
        let timing: ASRTimingProvenance
        if !segments.isEmpty {
            timing = .providerSegments
        } else if let duration = sourceDurationSeconds,
                  duration.isFinite, duration > 0 {
            timing = .sourceSpanOnly
        } else {
            timing = .none
        }
        if text.isEmpty {
            text = segments.map(\.text).joined(separator: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ASRTranscriptionResult(
            text: text,
            segments: segments,
            language: nil,
            timing: timing,
            detectedLanguages: [])
    }

    private static func addSentence(
        _ sentence: [String: Any],
        to builder: inout ASRVendorSegmentBuilder
    ) throws {
        if ASRVendorJSON.bool(sentence["heartbeat"]) == true { return }
        var start = ASRVendorJSON.double(sentence["begin_time"])
        var end = ASRVendorJSON.double(sentence["end_time"])
        if start == nil || end == nil,
           let span = builder.spanFromWords(sentence["words"]) {
            if start == nil { start = span.start }
            if end == nil { end = span.end }
        }
        try builder.add(
            startMilliseconds: start,
            endMilliseconds: end,
            text: ASRVendorJSON.string(sentence["text"]) ?? "")
    }

    static func parseEvent(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw ASRTranscriptionError.providerRejected
        }
        return dictionary
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    static func asRedacted(_ error: Error) -> ASRTranscriptionError {
        if let asr = error as? ASRTranscriptionError { return asr }
        if error is CancellationError { return .transport(.cancelled) }
        return ASRTransportErrorMapping.failure(error)
    }
}

// MARK: - Live session (one utterance)

actor AlibabaLiveSession: ASRLiveSession {
    nonisolated let events: ASRBoundedEventStream<ASRLiveEvent>
    nonisolated let turnID: UUID

    private enum State: Sendable, Hashable {
        case idle
        case starting
        case active
        case terminal
        case cancelled
    }

    private let connection: any ASRWebSocketConnection
    private let request: ASRLiveSessionRequest
    private let taskID: String
    private let runTask: Data
    private let finishTask: Data

    private var state: State = .idle
    private var startError: ASRTranscriptionError?
    private var pendingAudio = Data()
    private var pendingOffset = 0
    private var audioBytes = 0
    private var commitSent = false
    private var finalizedSentences: [Int: String] = [:]
    private var sentenceOrder: [Int] = []
    private var currentSentenceID: Int?
    private var currentSentenceText: String?
    private var lastAggregate = ""
    private var timingBuilder = ASRVendorSegmentBuilder()
    private var sequence = 0
    private var receivedMessages = 0
    private var streamError: ASRTranscriptionError?
    private var receiveTask: Task<Void, Never>?

    init(
        connection: any ASRWebSocketConnection,
        request: ASRLiveSessionRequest,
        taskID: String,
        runTask: Data
    ) {
        self.connection = connection
        self.request = request
        self.taskID = taskID
        self.runTask = runTask
        self.finishTask = (try? AlibabaASRAdapter.makeFinishTask(taskID: taskID))
            ?? Data("{\"header\":{\"action\":\"finish-task\"}}".utf8)
        self.turnID = request.turnID
        self.events = ASRBoundedEventStream(
            capacity: request.eventQueueCapacity)
    }

    func start() async throws {
        guard state == .idle else { return }
        state = .starting
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
        }
        do {
            try await connection.send(.text(String(decoding: runTask, as: UTF8.self)))
        } catch {
            let mapped = AlibabaASRAdapter.asRedacted(error)
            terminate(error: mapped)
            throw mapped
        }
        await waitForReady()
        if let startError { throw startError }
        if state == .cancelled { throw CancellationError() }
        guard state == .active else {
            throw ASRTranscriptionError.providerRejected
        }
    }

    // MARK: - ASRLiveSession

    func feed(_ audio: Data) async throws {
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
        guard audio.count % 2 == 0 else {
            throw ASRTranscriptionError.invalidConfiguration(
                "live audio must be 16-bit PCM")
        }
        guard audioBytes + audio.count <= request.maximumAudioBytes else {
            throw ASRTranscriptionError.invalidConfiguration(
                "audio exceeds the live session limit")
        }
        audioBytes += audio.count
        pendingAudio.append(audio)
        while availablePendingBytes >= AlibabaASRAdapter.livePacketBytes {
            let chunk = pendingChunk(AlibabaASRAdapter.livePacketBytes)
            try await sendAudio(chunk)
        }
        compactPending()
    }

    func endUtterance() async throws {
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
        let remaining = pendingChunk(availablePendingBytes)
        pendingAudio.removeAll()
        pendingOffset = 0
        if !remaining.isEmpty {
            try await sendAudio(remaining)
        }
        do {
            try await connection.send(
                .text(String(decoding: finishTask, as: UTF8.self)))
        } catch {
            let mapped = AlibabaASRAdapter.asRedacted(error)
            terminate(error: mapped)
            throw mapped
        }
    }

    func finish() async throws {
        if state == .cancelled { throw CancellationError() }
        if let streamError { throw streamError }
        if state == .idle || state == .starting {
            throw ASRTranscriptionError.invalidConfiguration(
                "the live session is not ready")
        }
        if state == .terminal { return }
        if !commitSent {
            try await endUtterance()
        }
        await waitForTerminal(timeout: request.finishTimeoutSeconds)
        if state == .cancelled { throw CancellationError() }
        if let streamError { throw streamError }
        guard state == .terminal else {
            await cancel()
            throw ASRTranscriptionError.transport(.timedOut)
        }
    }

    func cancel() async {
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
            while state == .starting || state == .active {
                let message = try await connection.receive()
                try Task.checkCancellation()
                guard state == .starting || state == .active else { break }
                let data: Data
                switch message {
                case .text(let payload):
                    guard let payloadData = payload.data(using: .utf8) else {
                        throw ASRTranscriptionError.providerRejected
                    }
                    data = payloadData
                case .data(let payload):
                    data = payload
                }
                receivedMessages += 1
                guard receivedMessages <= AlibabaASRAdapter.maximumReceivedMessages else {
                    throw ASRTranscriptionError.responseTooLarge
                }
                let object = try AlibabaASRAdapter.parseEvent(data)
                try await handle(object)
                if state == .terminal { break }
            }
            if state == .terminal {
                connection.close()
            } else if state == .starting || state == .active {
                terminate(error: .providerRejected)
            }
        } catch is CancellationError {
            await cancel()
        } catch {
            let mapped = AlibabaASRAdapter.asRedacted(error)
            if case .transport(.cancelled) = mapped {
                await cancel()
            } else if state == .starting || state == .active {
                terminate(error: mapped)
            }
        }
    }

    private func handle(_ object: [String: Any]) async throws {
        guard let header = ASRVendorJSON.dictionary(object["header"]),
              let event = ASRVendorJSON.string(header["event"]) else {
            throw ASRTranscriptionError.providerRejected
        }
        switch event {
        case "task-started":
            if state == .starting { state = .active }
        case "result-generated":
            guard state == .active else { return }
            let payload = ASRVendorJSON.dictionary(object["payload"])
            let output = ASRVendorJSON.dictionary(payload?["output"])
            if let sentence = ASRVendorJSON.dictionary(output?["sentence"]) {
                try await consumeSentence(sentence)
            }
            if let sentences = ASRVendorJSON.array(output?["sentences"]) {
                for raw in sentences {
                    guard let sentence = ASRVendorJSON.dictionary(raw) else { continue }
                    try await consumeSentence(sentence)
                }
            }
        case "task-finished":
            if let error = streamError {
                state = .terminal
                events.finish()
                connection.close()
                throw error
            }
            var finalText = aggregateText().trimmingCharacters(
                in: .whitespacesAndNewlines)
            if finalText.isEmpty {
                finalText = finalizedSentencesInOrder()
                    .joined(separator: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !finalText.isEmpty else {
                try await fail(error: .emptyResult)
                return
            }
            sequence += 1
            try await events.send(.final(
                turnID: turnID,
                itemID: taskID,
                transcript: finalText,
                sequence: sequence))
            events.finish()
            state = .terminal
            connection.close()
        case "task-failed":
            let mapped = ASRTranscriptionError.providerRejected
            if state == .starting {
                startError = mapped
                state = .terminal
                connection.cancel()
                events.finish(throwing: mapped)
            } else {
                try await fail(error: mapped)
            }
        default:
            // Unknown/new events are ignored for forward compatibility.
            return
        }
    }

    private func consumeSentence(_ sentence: [String: Any]) async throws {
        if ASRVendorJSON.bool(sentence["heartbeat"]) == true { return }
        let identifier = ASRVendorJSON.int(sentence["sentence_id"]) ?? 0
        let text = ASRVendorJSON.string(sentence["text"]) ?? ""
        let ended = ASRVendorJSON.bool(sentence["sentence_end"]) ?? false
        if ended {
            if finalizedSentences[identifier] == nil {
                sentenceOrder.append(identifier)
            }
            finalizedSentences[identifier] = text
            if currentSentenceID == identifier {
                currentSentenceID = nil
                currentSentenceText = nil
            }
        } else {
            if currentSentenceID != identifier {
                currentSentenceID = identifier
                currentSentenceText = text
            } else {
                currentSentenceText = text
            }
        }
        let aggregate = aggregateText()
        guard aggregate.count <= AlibabaASRAdapter.maximumTranscriptCharacters else {
            throw ASRTranscriptionError.responseTooLarge
        }
        if aggregate != lastAggregate {
            if aggregate.hasPrefix(lastAggregate) {
                let delta = String(aggregate.dropFirst(lastAggregate.count))
                if !delta.isEmpty {
                    sequence += 1
                    try await events.send(.partial(
                        turnID: turnID,
                        itemID: taskID,
                        delta: delta,
                        sequence: sequence))
                }
                lastAggregate = aggregate
            } else if lastAggregate.isEmpty, !aggregate.isEmpty {
                sequence += 1
                try await events.send(.partial(
                    turnID: turnID,
                    itemID: taskID,
                    delta: aggregate,
                    sequence: sequence))
                lastAggregate = aggregate
            }
            // A revision (the provider corrected an earlier sentence) is not
            // appended as a misleading delta; the final event replaces it.
        }
        // Parse timing for bounded validation. The shared live event surface
        // is text-only; timed file results use the same provider fields.
        var start = ASRVendorJSON.double(sentence["begin_time"])
        var end = ASRVendorJSON.double(sentence["end_time"])
        if start == nil || end == nil,
           let span = timingBuilder.spanFromWords(sentence["words"]) {
            if start == nil { start = span.start }
            if end == nil { end = span.end }
        }
        try timingBuilder.add(
            startMilliseconds: start,
            endMilliseconds: end,
            text: text)
    }

    private func aggregateText() -> String {
        finalizedSentencesInOrder().joined(separator: "")
            + (currentSentenceText ?? "")
    }

    private func finalizedSentencesInOrder() -> [String] {
        sentenceOrder.compactMap { finalizedSentences[$0] }
    }

    private func sendAudio(_ pcm: Data) async throws {
        do {
            try await connection.send(.data(pcm))
        } catch {
            let mapped = AlibabaASRAdapter.asRedacted(error)
            terminate(error: mapped)
            throw mapped
        }
    }

    private func fail(error: ASRTranscriptionError) async throws {
        guard state != .cancelled, state != .terminal else { return }
        streamError = error
        state = .terminal
        sequence += 1
        try? await events.send(.failed(
            turnID: turnID,
            itemID: taskID,
            error: error,
            sequence: sequence))
        events.finish()
        connection.cancel()
    }

    private func terminate(error: ASRTranscriptionError) {
        guard state != .cancelled, state != .terminal else { return }
        if state == .starting {
            startError = error
        }
        state = .terminal
        streamError = error
        connection.cancel()
        events.finish(throwing: error)
    }

    private func waitForReady() async {
        let deadline = Date().addingTimeInterval(
            AlibabaASRAdapter.startTimeoutSeconds)
        while state == .starting {
            if startError != nil { return }
            if Date() >= deadline {
                startError = .transport(.timedOut)
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitForTerminal(timeout: Double) async {
        let seconds = timeout.isFinite && timeout > 0 ? min(timeout, 300) : 30
        let deadline = Date().addingTimeInterval(seconds)
        while state == .active {
            if Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func compactPending() {
        guard pendingOffset > 0 else { return }
        if pendingOffset == pendingAudio.count {
            pendingAudio.removeAll(keepingCapacity: true)
            pendingOffset = 0
        } else if pendingOffset >= 64 * 1024 {
            pendingAudio.removeFirst(pendingOffset)
            pendingOffset = 0
        }
    }

    private var availablePendingBytes: Int {
        Swift.max(0, pendingAudio.count - pendingOffset)
    }

    private func pendingChunk(_ count: Int) -> Data {
        guard count > 0 else { return Data() }
        let start = pendingAudio.startIndex.advanced(by: pendingOffset)
        let end = start.advanced(by: count)
        let chunk = Data(pendingAudio[start..<end])
        pendingOffset += count
        return chunk
    }
}
