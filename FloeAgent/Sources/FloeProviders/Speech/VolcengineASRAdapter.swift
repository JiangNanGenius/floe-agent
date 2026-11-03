// FloeProviders — Volcengine Doubao large-model streaming ASR.
//
// SPDX-License-Identifier: MPL-2.0
//
// File transcription is a bounded replay of the supported audio container over
// the same v3 SAUC WebSocket used for live input; live transcription streams
// PCM16 mono 16 kHz in ~200 ms packets and commits one utterance with the
// documented final (negative) packet. Pay-as-you-go and Agent Plan have
// separate hosts/paths and credentials; a plan key is never sent to the
// pay-as-you-go endpoint (or the reverse). New-console `X-Api-Key` is the
// primary credential; legacy `legacy:<appId>:<accessToken>` is accepted only
// for explicit pay-as-you-go use.
//
// Provider response bodies and error text are never surfaced. Results carry
// only provider-supplied text and timings; a text-only result never invents a
// whole-file caption segment.

import Foundation
import FloeCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct VolcengineASRAdapter: ASRTranscribing, ASRLiveTranscribing {
    static let packetBytes = 6_400 // 200 ms @ 16 kHz, mono, 16-bit
    static let maximumAudioBytes = 25 * 1024 * 1024
    static let maximumEventBytes = 1 * 1024 * 1024
    static let maximumTranscriptCharacters = 2_000_000
    static let maximumReceivedMessages = 20_000
    static let fileFinishTimeoutSeconds = 120.0
    /// Production file replay keeps the documented 200 ms audio packets and
    /// uses the documented lower-bound 100 ms packet cadence (2x real-time).
    /// The live microphone path is paced by the caller's capture clock.
    static let replayPacketIntervalNanoseconds: UInt64 = 100_000_000

    private let webSocketTransport: any ASRWebSocketTransport
    private let replayDelayNanoseconds: UInt64
    private let fileByteLimit: Int
    private let fileFinishTimeoutSeconds: Double

    public init(webSocketTransport: any ASRWebSocketTransport) {
        self.webSocketTransport = webSocketTransport
        self.replayDelayNanoseconds = Self.replayPacketIntervalNanoseconds
        self.fileByteLimit = Self.maximumAudioBytes
        self.fileFinishTimeoutSeconds = Self.fileFinishTimeoutSeconds
    }

    /// Focused-test seam. Production callers use the public initializer.
    init(
        webSocketTransport: any ASRWebSocketTransport,
        replayDelayNanoseconds: UInt64,
        fileByteLimit: Int = VolcengineASRAdapter.maximumAudioBytes,
        fileFinishTimeoutSeconds: Double = VolcengineASRAdapter.fileFinishTimeoutSeconds
    ) {
        self.webSocketTransport = webSocketTransport
        self.replayDelayNanoseconds = replayDelayNanoseconds
        self.fileByteLimit = fileByteLimit
        self.fileFinishTimeoutSeconds = fileFinishTimeoutSeconds
    }

    #if !canImport(FoundationNetworking)
    public init(session: URLSession? = nil) {
        self.init(webSocketTransport: URLSessionWebSocketTransport(
            session: session ?? ASRTransportSecurity.makeWebSocketSession()))
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
        let profile = ASRProfile.volcengine(
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
                "volcengine transcription model is required")
        }
        guard request.audio.count <= Swift.min(fileByteLimit, capabilities.maximumFileBytes) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "audio exceeds the Volcengine transcription size limit")
        }
        let input = try ASRVendorAudioDetector.inspect(
            request.audio,
            filename: request.filename,
            mimeType: request.mimeType,
            provider: .volcengine)
        let authentication = try VolcengineAuthentication.resolve(
            credential, route: profile.billingRoute)
        let endpoint = try Self.endpointURL(profile: profile, preferLive: false)
        let connectID = UUID().uuidString.lowercased()
        let requestID = UUID().uuidString.lowercased()
        var urlRequest = Self.makeURLRequest(
            endpoint: endpoint,
            profile: profile,
            authentication: authentication,
            connectID: connectID,
            requestID: requestID)
        urlRequest.timeoutInterval = 30

        let connection = try await connect(urlRequest)
        let configuration = try Self.configuration(
            modelID: modelID,
            input: input,
            live: false)
        let session = VolcengineFileSession(
            connection: connection,
            configuration: configuration,
            audio: input.data,
            maximumEventBytes: Swift.min(Self.maximumEventBytes, 8 * 1024 * 1024),
            replayDelayNanoseconds: replayDelayNanoseconds,
            finishTimeoutSeconds: fileFinishTimeoutSeconds,
            sourceDurationSeconds: request.sourceDurationSeconds ?? input.durationSeconds)
        return try await session.run()
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
            for: .volcengine, modelID: liveModel)
        guard capabilities.supportsLiveTranscription else {
            throw ASRTranscriptionError.invalidConfiguration(
                "this model does not support live transcription")
        }
        guard request.inputSampleRate == 16_000 else {
            throw ASRTranscriptionError.invalidConfiguration(
                "Volcengine live transcription requires 16 kHz PCM input")
        }
        let authentication = try VolcengineAuthentication.resolve(
            credential, route: profile.billingRoute)
        let endpoint = try Self.endpointURL(profile: profile, preferLive: true)
        let connectID = UUID().uuidString.lowercased()
        let requestID = UUID().uuidString.lowercased()
        var urlRequest = Self.makeURLRequest(
            endpoint: endpoint,
            profile: profile,
            authentication: authentication,
            connectID: connectID,
            requestID: requestID)
        urlRequest.timeoutInterval = 30

        let connection = try await connect(urlRequest)
        let liveInput = ASRVendorAudioInput(
            data: Data(),
            format: .pcm,
            sampleRate: 16_000,
            channelCount: 1,
            durationSeconds: nil,
            mimeType: "audio/L16")
        let configuration = try Self.configuration(
            modelID: liveModel,
            input: liveInput,
            live: true)
        let session = VolcengineLiveSession(
            connection: connection,
            request: request,
            requestID: requestID,
            configuration: configuration)
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
        guard profile.provider == .volcengine else {
            throw ASRTranscriptionError.invalidConfiguration(
                "this adapter only serves Volcengine profiles")
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

    static func endpointURL(profile: ASRProfile, preferLive: Bool) throws -> URL {
        let raw = preferLive
            ? (profile.resolvedLiveEndpoint ?? profile.resolvedFileEndpoint)
            : (profile.resolvedFileEndpoint ?? profile.resolvedLiveEndpoint)
        guard let raw else {
            throw ASRTranscriptionError.invalidConfiguration(
                "Volcengine transcription endpoint is required")
        }
        var components = try ASRVendorEndpoint.webSocketComponents(raw)
        let plan = profile.billingRoute == .agentPlan
        let fullPath = plan
            ? "/api/v3/plan/sauc/bigmodel_async"
            : "/api/v3/sauc/bigmodel_async"
        let suffixes = plan
            ? ["/api/v3/plan/sauc", "/api/v3/plan", "/api/v3"]
            : ["/api/v3/sauc", "/api/v3"]
        ASRVendorEndpoint.composePath(
            &components, baseSuffixes: suffixes, fullPath: fullPath)
        guard let url = components.url else {
            throw ASRTranscriptionError.invalidConfiguration(
                "Volcengine transcription endpoint is not a valid URL")
        }
        return url
    }

    private static func makeURLRequest(
        endpoint: URL,
        profile: ASRProfile,
        authentication: VolcengineAuthentication,
        connectID: String,
        requestID: String
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        authentication.apply(to: &request)
        let resourceID = profile.resourceID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ASRProviderRouting.volcengineResourceID
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectID, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private func connect(_ request: URLRequest) async throws -> any ASRWebSocketConnection {
        do {
            return try await webSocketTransport.connect(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let asr = error as? ASRTranscriptionError { throw asr }
            if Self.isCancellation(error) { throw CancellationError() }
            throw ASRTransportErrorMapping.failure(error)
        }
    }

    static func configuration(
        modelID: String,
        input: ASRVendorAudioInput,
        live: Bool
    ) throws -> Data {
        let format: String
        var codec: String?
        switch input.format {
        case .pcm:
            format = "pcm"
        case .wav:
            format = "wav"
        case .mp3:
            format = "mp3"
            codec = "raw"
        case .oggOpus:
            format = "ogg"
            codec = "opus"
        }
        var audio: [String: Any] = [
            "format": format,
            "rate": live ? 16_000 : (input.sampleRate ?? 16_000),
            "bits": 16,
            "channel": live ? 1 : (input.channelCount ?? 1),
        ]
        if let codec { audio["codec"] = codec }
        let request: [String: Any] = [
            // The catalogue's product name is not the SAUC protocol's model
            // selector. Both official 2.0 names use `bigmodel` with the 2.0
            // resource header; preserve explicitly configured custom names.
            "model_name": Self.wireModelName(modelID),
            "show_utterances": true,
            "enable_itn": true,
            "enable_punc": true,
            "enable_ddc": false,
        ]
        let root: [String: Any] = [
            "user": ["uid": "floe-ios", "platform": "iOS"],
            "audio": audio,
            "request": request,
        ]
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(
                withJSONObject: root, options: [.sortedKeys]) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "could not encode the Volcengine request")
        }
        return data
    }

    static func wireModelName(_ modelID: String) -> String {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized.lowercased() {
        case "doubao-seed-asr-2.0", "seed-asr-2.0", "bigmodel":
            return "bigmodel"
        default:
            return normalized
        }
    }

    static func parseObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw ASRTranscriptionError.providerRejected
        }
        return dictionary
    }

    static func mapCodec(_ error: VolcengineASRFrame.CodecError) -> ASRTranscriptionError {
        switch error {
        case .oversized:
            return .responseTooLarge
        case .truncated, .badVersion, .badMessageType, .badCompression:
            return .providerRejected
        }
    }

    static func mapProviderError(_ code: Int) -> ASRTranscriptionError {
        switch code {
        case 45_000_002:
            return .emptyResult
        case 45_000_081:
            return .transport(.timedOut)
        case 45_000_151:
            return .invalidConfiguration("provider rejected the audio format")
        case 45_000_001:
            return .invalidConfiguration("provider rejected the request configuration")
        default:
            return .providerRejected
        }
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

// MARK: - Authentication

struct VolcengineAuthentication {
    let apiKey: String?
    let appID: String?
    let accessToken: String?

    static func resolve(
        _ credential: String,
        route: ASRBillingRoute
    ) throws -> VolcengineAuthentication {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ASRTranscriptionError.credentialMissing
        }
        if value.hasPrefix("legacy:") {
            guard route == .payAsYouGo else {
                throw ASRTranscriptionError.invalidConfiguration(
                    "legacy Volcengine AppID credentials are only supported for pay-as-you-go")
            }
            let parts = value.split(
                separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else {
                throw ASRTranscriptionError.invalidConfiguration(
                    "legacy Volcengine credential must be legacy:<appId>:<accessToken>")
            }
            let appID = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            let token = String(parts[2]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appID.isEmpty, !token.isEmpty else {
                throw ASRTranscriptionError.invalidConfiguration(
                    "legacy Volcengine AppID and access token are required")
            }
            try validateHeaderValue(appID)
            try validateHeaderValue(token)
            return VolcengineAuthentication(
                apiKey: nil, appID: appID, accessToken: token)
        }
        try validateHeaderValue(value)
        return VolcengineAuthentication(
            apiKey: value, appID: nil, accessToken: nil)
    }

    func apply(to request: inout URLRequest) {
        if let apiKey {
            request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        }
        if let appID {
            request.setValue(appID, forHTTPHeaderField: "X-Api-App-Key")
        }
        if let accessToken {
            request.setValue(accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        }
    }

    private static func validateHeaderValue(_ value: String) throws {
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .newlines) == nil,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "the Volcengine credential contains invalid characters")
        }
    }
}

// MARK: - File session (WS replay + timed result)

private final class VolcengineFileSession: @unchecked Sendable {
    private let connection: any ASRWebSocketConnection
    private let configuration: Data
    private let audio: Data
    private let maximumEventBytes: Int
    private let replayDelayNanoseconds: UInt64
    private let finishTimeoutSeconds: Double
    private let sourceDurationSeconds: Double?
    private let receivedMessages = ASRVendorLockedCounter()
    private let timeoutTask = ASRVendorTaskHolder()

    init(
        connection: any ASRWebSocketConnection,
        configuration: Data,
        audio: Data,
        maximumEventBytes: Int,
        replayDelayNanoseconds: UInt64,
        finishTimeoutSeconds: Double,
        sourceDurationSeconds: Double?
    ) {
        self.connection = connection
        self.configuration = configuration
        self.audio = audio
        self.maximumEventBytes = maximumEventBytes
        self.replayDelayNanoseconds = replayDelayNanoseconds
        self.finishTimeoutSeconds = finishTimeoutSeconds
        self.sourceDurationSeconds = sourceDurationSeconds
    }

    func run() async throws -> ASRTranscriptionResult {
        let reader = Task { try await receive() }
        let timedOut = ASRVendorLockedFlag()
        // The send phase is bounded from the real packet count and the
        // production replay cadence, so a 5-minute PCM chunk is never killed
        // by the final-result deadline while it is still being sent. The
        // final-result deadline starts only after the last packet is sent.
        let sendTimeout = Task { [connection] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.nanoseconds(sendBudgetSeconds()))
            } catch {
                return
            }
            timedOut.set()
            reader.cancel()
            connection.cancel()
        }
        timeoutTask.set(sendTimeout)
        do {
            let result = try await withTaskCancellationHandler {
                try await sendAll()
                sendTimeout.cancel()
                let finalTimeout = Task { [connection] in
                    do {
                        try await Task.sleep(
                            nanoseconds: Self.nanoseconds(finalTimeoutSeconds()))
                    } catch {
                        return
                    }
                    timedOut.set()
                    reader.cancel()
                    connection.cancel()
                }
                timeoutTask.set(finalTimeout)
                return try await reader.value
            } onCancel: {
                // A parent cancellation must promptly release both the
                // unstructured reader and the socket, not wait for a send or
                // finish deadline. Cancellation stays CancellationError.
                timeoutTask.cancel()
                reader.cancel()
                connection.cancel()
            }
            timeoutTask.cancel()
            try Task.checkCancellation()
            connection.close()
            return result
        } catch {
            timeoutTask.cancel()
            reader.cancel()
            connection.cancel()
            // Join the reader now that the socket is cancelled. The
            // ASRWebSocketConnection contract requires cancel() to unblock a
            // pending receive; cancellation remains CancellationError.
            _ = try? await reader.value
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            if timedOut.get() {
                throw ASRTranscriptionError.transport(.timedOut)
            }
            if let asr = error as? ASRTranscriptionError {
                if case .transport(.cancelled) = asr { throw CancellationError() }
                throw asr
            }
            let mapped = ASRTransportErrorMapping.failure(error)
            if case .transport(.cancelled) = mapped { throw CancellationError() }
            throw mapped
        }
    }

    private func sendBudgetSeconds() -> Double {
        let packets = (audio.count + VolcengineASRAdapter.packetBytes - 1)
            / VolcengineASRAdapter.packetBytes
        let replay = Double(replayDelayNanoseconds) / 1_000_000_000
        // Packet cadence + connection/send overhead. Bounded so a pathological
        // file cannot hold the session forever.
        return min(max(Double(packets) * replay + 30, 30), 3_600)
    }

    private func finalTimeoutSeconds() -> Double {
        finishTimeoutSeconds.isFinite && finishTimeoutSeconds > 0
            ? min(finishTimeoutSeconds, 600)
            : VolcengineASRAdapter.fileFinishTimeoutSeconds
    }

    private static func nanoseconds(_ seconds: Double) -> UInt64 {
        UInt64(min(max(seconds, 0.05), 3_600) * 1_000_000_000)
    }

    private func sendAll() async throws {
        let frame = try VolcengineASRFrame.clientFullRequest(configuration)
        try await connection.send(.data(frame))
        var offset = 0
        while offset < audio.count {
            try Task.checkCancellation()
            let end = Swift.min(offset + VolcengineASRAdapter.packetBytes, audio.count)
            let chunk = audio.subdata(in: offset..<end)
            let isLast = end == audio.count
            let audioFrame = try VolcengineASRFrame.clientAudio(chunk, isLast: isLast)
            try await connection.send(.data(audioFrame))
            offset = end
            if !isLast, replayDelayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: replayDelayNanoseconds)
            }
        }
    }

    private func receive() async throws -> ASRTranscriptionResult {
        var builder = ASRVendorSegmentBuilder()
        var text = ""
        while true {
            try Task.checkCancellation()
            let message = try await connection.receive()
            guard receivedMessages.increment(
                limit: VolcengineASRAdapter.maximumReceivedMessages) else {
                throw ASRTranscriptionError.responseTooLarge
            }
            let data: Data
            switch message {
            case .data(let payload):
                data = payload
            case .text(let payload):
                guard let payloadData = payload.data(using: .utf8) else {
                    throw ASRTranscriptionError.providerRejected
                }
                data = payloadData
            }
            let decoded: VolcengineASRFrame.Decoded
            do {
                decoded = try VolcengineASRFrame.decode(
                    data, maximumEventBytes: maximumEventBytes)
            } catch let error as VolcengineASRFrame.CodecError {
                throw VolcengineASRAdapter.mapCodec(error)
            } catch {
                throw ASRTranscriptionError.providerRejected
            }
            switch decoded {
            case .ack:
                continue
            case .error(let code, _):
                throw VolcengineASRAdapter.mapProviderError(code)
            case .json(let payload, let isFinal, _):
                let object = try VolcengineASRAdapter.parseObject(payload)
                if let result = ASRVendorJSON.resultObject(object["result"]) {
                    if let newText = ASRVendorJSON.string(result["text"]) {
                        let trimmed = newText.trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            text = newText
                            guard text.count <= VolcengineASRAdapter
                                .maximumTranscriptCharacters else {
                                throw ASRTranscriptionError.responseTooLarge
                            }
                        }
                    }
                    if let utterances = ASRVendorJSON.array(result["utterances"]) {
                        for raw in utterances {
                            guard let utterance = ASRVendorJSON.dictionary(raw) else {
                                continue
                            }
                            var start = ASRVendorJSON.double(utterance["start_time"])
                            var end = ASRVendorJSON.double(utterance["end_time"])
                            if start == nil || end == nil,
                               let span = builder.spanFromWords(utterance["words"]) {
                                if start == nil { start = span.start }
                                if end == nil { end = span.end }
                            }
                            try builder.add(
                                startMilliseconds: start,
                                endMilliseconds: end,
                                text: ASRVendorJSON.string(utterance["text"]) ?? "")
                        }
                    }
                }
                if isFinal {
                    let segments = builder.segments()
                    let trimmedText = text.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    let finalText = trimmedText.isEmpty
                        ? segments.map(\.text).joined(separator: "")
                        : trimmedText
                    guard !finalText.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty else {
                        throw ASRTranscriptionError.emptyResult
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
                    return ASRTranscriptionResult(
                        text: finalText,
                        segments: segments,
                        language: nil,
                        timing: timing,
                        detectedLanguages: [])
                }
            }
        }
    }
}

// MARK: - Live session (one utterance)

actor VolcengineLiveSession: ASRLiveSession {
    nonisolated let events: ASRBoundedEventStream<ASRLiveEvent>
    nonisolated let turnID: UUID

    private enum State: Sendable, Hashable {
        case idle
        case active
        case terminal
        case cancelled
    }

    private let connection: any ASRWebSocketConnection
    private let request: ASRLiveSessionRequest
    private let requestID: String
    private let configuration: Data
    private let maximumEventBytes: Int

    private var state: State = .idle
    private var pendingAudio = Data()
    private var pendingOffset = 0
    private var audioBytes = 0
    private var commitSent = false
    private var partialText = ""
    private var sequence = 0
    private var receivedMessages = 0
    private var streamError: ASRTranscriptionError?
    private var receiveTask: Task<Void, Never>?

    init(
        connection: any ASRWebSocketConnection,
        request: ASRLiveSessionRequest,
        requestID: String,
        configuration: Data
    ) {
        self.connection = connection
        self.request = request
        self.requestID = requestID
        self.configuration = configuration
        self.maximumEventBytes = request.maximumEventBytes
        self.turnID = request.turnID
        self.events = ASRBoundedEventStream(
            capacity: request.eventQueueCapacity)
    }

    func start() async throws {
        guard state == .idle else { return }
        state = .active
        do {
            let frame = try VolcengineASRFrame.clientFullRequest(configuration)
            try await connection.send(.data(frame))
        } catch {
            let mapped = VolcengineASRAdapter.asRedacted(error)
            terminate(error: mapped)
            throw mapped
        }
        receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
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
        while availablePendingBytes >= VolcengineASRAdapter.packetBytes {
            let chunk = pendingChunk(VolcengineASRAdapter.packetBytes)
            try await sendAudio(chunk, isLast: false)
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
        try await sendAudio(remaining, isLast: true)
    }

    func finish() async throws {
        if state == .cancelled { throw CancellationError() }
        if let streamError { throw streamError }
        guard state != .idle else {
            throw ASRTranscriptionError.invalidConfiguration(
                "the live session has not started")
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
            while state == .active {
                let message = try await connection.receive()
                try Task.checkCancellation()
                guard state == .active else { break }
                let data: Data
                switch message {
                case .data(let payload):
                    data = payload
                case .text(let payload):
                    guard let payloadData = payload.data(using: .utf8) else {
                        throw ASRTranscriptionError.providerRejected
                    }
                    data = payloadData
                }
                receivedMessages += 1
                guard receivedMessages <= VolcengineASRAdapter
                    .maximumReceivedMessages else {
                    throw ASRTranscriptionError.responseTooLarge
                }
                let decoded: VolcengineASRFrame.Decoded
                do {
                    decoded = try VolcengineASRFrame.decode(
                        data, maximumEventBytes: maximumEventBytes)
                } catch let error as VolcengineASRFrame.CodecError {
                    throw VolcengineASRAdapter.mapCodec(error)
                } catch {
                    throw ASRTranscriptionError.providerRejected
                }
                try await handle(decoded)
                if state == .terminal { break }
            }
            if state == .terminal {
                connection.close()
            } else if state == .active {
                terminate(error: .providerRejected)
            }
        } catch is CancellationError {
            await cancel()
        } catch {
            let mapped = VolcengineASRAdapter.asRedacted(error)
            if case .transport(.cancelled) = mapped {
                await cancel()
            } else if state == .active {
                terminate(error: mapped)
            }
        }
    }

    private func handle(_ decoded: VolcengineASRFrame.Decoded) async throws {
        switch decoded {
        case .ack:
            return
        case .error(let code, _):
            try await fail(error: VolcengineASRAdapter.mapProviderError(code))
        case .json(let payload, let isFinal, _):
            let object = try VolcengineASRAdapter.parseObject(payload)
            var utteranceBuilder = ASRVendorSegmentBuilder()
            if let result = ASRVendorJSON.resultObject(object["result"]) {
                if let newText = ASRVendorJSON.string(result["text"]) {
                    let trimmed = newText.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, newText != partialText {
                        if newText.hasPrefix(partialText) {
                            let delta = String(newText.dropFirst(partialText.count))
                            if !delta.isEmpty {
                                try await sendPartial(delta)
                            }
                        } else {
                            // SAUC sends cumulative hypotheses and may revise
                            // punctuation or earlier words on every packet.
                            // Dropping non-prefix updates freezes the visible
                            // transcript until the utterance ends.
                            sequence += 1
                            try await events.send(.partialReplacement(
                                turnID: turnID, itemID: requestID,
                                transcript: newText, sequence: sequence))
                        }
                        partialText = newText
                        guard partialText.count <= VolcengineASRAdapter
                            .maximumTranscriptCharacters else {
                            throw ASRTranscriptionError.responseTooLarge
                        }
                    }
                }
                if let utterances = ASRVendorJSON.array(result["utterances"]) {
                    for raw in utterances {
                        guard let utterance = ASRVendorJSON.dictionary(raw) else {
                            continue
                        }
                        var start = ASRVendorJSON.double(utterance["start_time"])
                        var end = ASRVendorJSON.double(utterance["end_time"])
                        if start == nil || end == nil,
                           let span = utteranceBuilder.spanFromWords(utterance["words"]) {
                            if start == nil { start = span.start }
                            if end == nil { end = span.end }
                        }
                        try utteranceBuilder.add(
                            startMilliseconds: start,
                            endMilliseconds: end,
                            text: ASRVendorJSON.string(utterance["text"]) ?? "")
                    }
                }
            }
            if isFinal {
                var finalText = partialText.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                if finalText.isEmpty {
                    finalText = utteranceBuilder.segments()
                        .map(\.text).joined(separator: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !finalText.isEmpty else {
                    try await fail(error: .emptyResult)
                    return
                }
                sequence += 1
                try await events.send(.final(
                    turnID: turnID,
                    itemID: requestID,
                    transcript: finalText,
                    sequence: sequence))
                events.finish()
                state = .terminal
                connection.close()
            }
        }
    }

    private func sendPartial(_ delta: String) async throws {
        sequence += 1
        try await events.send(.partial(
            turnID: turnID,
            itemID: requestID,
            delta: delta,
            sequence: sequence))
    }

    private func fail(error: ASRTranscriptionError) async throws {
        guard state == .active else { return }
        streamError = error
        state = .terminal
        sequence += 1
        try? await events.send(.failed(
            turnID: turnID,
            itemID: requestID,
            error: error,
            sequence: sequence))
        events.finish()
        connection.cancel()
    }

    private func terminate(error: ASRTranscriptionError) {
        guard state != .cancelled, state != .terminal else { return }
        state = .terminal
        streamError = error
        connection.cancel()
        events.finish(throwing: error)
    }

    private func waitForTerminal(timeout: Double) async {
        let seconds = timeout.isFinite && timeout > 0 ? min(timeout, 300) : 30
        let deadline = Date().addingTimeInterval(seconds)
        while state == .active {
            if Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Sending

    private func sendAudio(_ pcm: Data, isLast: Bool) async throws {
        do {
            let frame = try VolcengineASRFrame.clientAudio(pcm, isLast: isLast)
            try await connection.send(.data(frame))
        } catch {
            let mapped = VolcengineASRAdapter.asRedacted(error)
            terminate(error: mapped)
            throw mapped
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
}
