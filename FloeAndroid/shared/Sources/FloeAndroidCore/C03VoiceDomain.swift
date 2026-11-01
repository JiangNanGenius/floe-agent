// SPDX-License-Identifier: MPL-2.0
//
// C03 voice domain — source-only speech implementation.
//
// System recognition/TTS live in the Android host (C03SystemSpeechRecognizer,
// C03SystemTextToSpeech). This file owns only the optional, explicitly
// configured CLOUD ASR/TTS path and the timed-subtitle write-back:
//
//  * the selected provider/model is an EXISTING configured provider/model;
//    its credential is the provider's existing `secretRef`, resolved through
//    the existing SecretGatewayRegistry. There is no generic API-key field,
//    no bundled/downloaded voice model and no automatic paid fallback;
//  * cloud requests use the shared FloeTransport incremental transport with
//    redirects refused, so a configured credential cannot be forwarded to a
//    different origin;
//  * media transcription resolves the real selected G09 media project/asset
//    by project ID + session token + trusted storage/origin. No caller path,
//    filename search or preview blob is accepted;
//  * subtitle write-back uses the existing MediaProjectStore CAS and the
//    exact-project `commitApplied` transaction. A stale revision, failed
//    save or cancelled task leaves the original project file untouched;
//  * long media uses this cloud route (or a future task Linux route supplied
//    by Main), never the interactive system recognizer.
//
// This file is authored source; it is not compiled by this package.
import Foundation
import FloeCore
import FloePersistence
import FloeAndroidWorkbench
import FloeTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Bounded error vocabulary

public enum C03VoiceErrorCode: String, Codable, Sendable, Equatable {
    case unconfigured
    case credentialMissing
    case transportUnavailable
    case unsupportedModel
    case providerRejected
    case authentication
    case quotaOrRateLimited
    case network
    case cancelled
    case invalidSelection
    case fileTooLarge
    case fileUnreadable
    case unsupportedMedia
    /// No real decoder exists for this source audio track on the device.
    case codecUnavailable
    /// Provider returned text but no real segment timing; no subtitle write.
    case needsTiming
    case staleRevision
    case sessionRequired
    case projectNotFound
    case mediaUnavailable
    case writeFailed
    case timeout
    case busy
    case invalidResponse
    case emptyTranscript
    case permissionRequired
    case coreUnavailable
    case needsCoreUpdate
    case internalFailure
}

public struct C03VoiceError: Error, Sendable, Equatable {
    public let code: C03VoiceErrorCode
    /// Lane-authored, bounded reason. Never provider text, a URL or a secret.
    public let reason: String?
    public let retryable: Bool

    public init(_ code: C03VoiceErrorCode, _ reason: String? = nil,
                retryable: Bool = false) {
        self.code = code
        self.reason = reason.map { String($0.prefix(120)) }
        self.retryable = retryable
    }
}

// MARK: - Public value shapes

public struct C03VoiceSelection: Codable, Sendable, Equatable {
    public var engine: String
    public var providerID: UUID?
    public var modelID: UUID?
    public var voiceID: String?
    public var language: String?
    public var rate: Double

    public init(engine: String = "cloud", providerID: UUID? = nil,
                modelID: UUID? = nil, voiceID: String? = nil,
                language: String? = nil, rate: Double = 1.0) {
        self.engine = engine
        self.providerID = providerID
        self.modelID = modelID
        self.voiceID = voiceID
        self.language = language
        self.rate = rate.isFinite ? min(2.0, max(0.5, rate)) : 1.0
    }

    public var configured: Bool { providerID != nil && modelID != nil }
}

public struct C03VoiceOwner: Codable, Sendable, Equatable {
    public var conversationID: UUID?
    public var taskID: UUID?
    public var environmentID: String?
    public var projectID: UUID?
    /// RAM-only temporary conversation. Cloud microphone capture is refused.
    public var temporary: Bool

    public init(conversationID: UUID? = nil, taskID: UUID? = nil,
                environmentID: String? = nil, projectID: UUID? = nil,
                temporary: Bool = false) {
        self.conversationID = conversationID
        self.taskID = taskID
        self.environmentID = environmentID
        self.projectID = projectID
        self.temporary = temporary
    }
}

/// How a provider response can be used. Text-only responses are never
/// converted into full-clip subtitles with invented timing.
public enum C03TranscriptTiming: String, Codable, Sendable, Equatable {
    case providerSegments
    case textOnly
}

public struct C03TimedSegment: Codable, Sendable, Equatable, Hashable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    public func normalized() -> C03TimedSegment? {
        guard start.isFinite, end.isFinite, start >= 0, end > start,
              end - start <= 24 * 60 * 60 else { return nil }
        let clean = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= 2_000 else { return nil }
        return C03TimedSegment(start: start, end: end, text: clean)
    }
}

public struct C03Transcript: Sendable, Equatable {
    public var segments: [C03TimedSegment]
    public var language: String?
    public var providerName: String
    public var modelDisplayName: String
    /// Plain transcript text. Always present for a completed ASR response.
    public var text: String
    public var timing: C03TranscriptTiming

    public init(segments: [C03TimedSegment], language: String?,
                providerName: String, modelDisplayName: String,
                text: String = "", timing: C03TranscriptTiming = .providerSegments) {
        self.segments = segments
        self.language = language
        self.providerName = providerName
        self.modelDisplayName = modelDisplayName
        self.text = text
        self.timing = timing
    }
}

public struct C03SpeechModelChoice: Codable, Sendable, Equatable {
    public var providerID: UUID
    public var providerName: String
    public var modelID: UUID
    public var remoteModelID: String
    public var displayName: String
    public var likelyASR: Bool
    public var likelyTTS: Bool
    public var credentialConfigured: Bool

    public init(providerID: UUID, providerName: String, modelID: UUID,
                remoteModelID: String, displayName: String,
                likelyASR: Bool, likelyTTS: Bool,
                credentialConfigured: Bool) {
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.remoteModelID = remoteModelID
        self.displayName = displayName
        self.likelyASR = likelyASR
        self.likelyTTS = likelyTTS
        self.credentialConfigured = credentialConfigured
    }
}

public struct C03SpeechCapabilities: Codable, Sendable, Equatable {
    public var cloudReady: Bool
    public var transportReady: Bool
    public var asrModels: [C03SpeechModelChoice]
    public var ttsModels: [C03SpeechModelChoice]
    public var maxAudioBytes: Int64
    public var maxChunkBytes: Int64
    public var maxSourceDurationSeconds: Int
    public var maxTextCharacters: Int
    public var maxSegments: Int
    public var ttsSampleRate: Int

    public init(cloudReady: Bool = false, transportReady: Bool = false,
                asrModels: [C03SpeechModelChoice] = [],
                ttsModels: [C03SpeechModelChoice] = [],
                maxAudioBytes: Int64 = Int64(C03VoiceDomain.maxMediaBytes),
                maxChunkBytes: Int64 = Int64(C03VoiceDomain.maxChunkBytes),
                maxSourceDurationSeconds: Int = C03VoiceDomain.maxSourceDurationSeconds,
                maxTextCharacters: Int = C03VoiceDomain.maxTextCharacters,
                maxSegments: Int = C03VoiceDomain.maxSegments,
                ttsSampleRate: Int = C03VoiceDomain.ttsSampleRate) {
        self.cloudReady = cloudReady
        self.transportReady = transportReady
        self.asrModels = asrModels
        self.ttsModels = ttsModels
        self.maxAudioBytes = maxAudioBytes
        self.maxChunkBytes = maxChunkBytes
        self.maxSourceDurationSeconds = maxSourceDurationSeconds
        self.maxTextCharacters = maxTextCharacters
        self.maxSegments = maxSegments
        self.ttsSampleRate = ttsSampleRate
    }
}

public struct C03MediaContext: Sendable, Equatable {
    public var projectID: UUID
    public var sessionToken: String
    public var storage: G09StorageLayerDTO
    public var origin: G09CreativeOriginDTO?
    public var expectedRevision: Int64
    public var assetID: UUID

    public init(projectID: UUID, sessionToken: String,
                storage: G09StorageLayerDTO, origin: G09CreativeOriginDTO?,
                expectedRevision: Int64, assetID: UUID) {
        self.projectID = projectID
        self.sessionToken = sessionToken
        self.storage = storage
        self.origin = origin
        self.expectedRevision = expectedRevision
        self.assetID = assetID
    }
}

public struct C03MediaFile: Sendable {
    public var data: Data
    public var filename: String
    public var mimeType: String
    public var durationSeconds: Double?
    public var projectRevision: Int64
    public var assetKind: MediaAssetKind
}

/// Bounded source descriptor used by the native chunker. It carries no bytes:
/// the host decodes the exact validated asset one chunk at a time.
public struct C03MediaDescriptor: Sendable {
    public var url: URL
    public var filename: String
    public var mimeType: String
    public var byteSize: Int64
    public var durationSeconds: Double?
    public var projectRevision: Int64
    public var assetKind: MediaAssetKind
}

public struct C03TranscriptionPlan: Sendable {
    public var operationID: String
    public var sourcePath: String
    public var stagingPath: String
    public var sourceBytes: Int64
    public var durationSeconds: Double
    public var chunkLimitBytes: Int64
    public var estimatedChunks: Int
}

public struct C03UtteranceStagingPlan: Sendable {
    public var pathToken: String
    public var path: String
    public var maxDurationSeconds: Int
}

public struct C03SubtitleReceipt: Codable, Sendable, Equatable {
    public var projectID: UUID
    public var revision: Int64
    public var canUndo: Bool
    public var canRedo: Bool
    public var opID: String
    public var idempotent: Bool

    public init(projectID: UUID, revision: Int64, canUndo: Bool,
                canRedo: Bool, opID: String, idempotent: Bool) {
        self.projectID = projectID
        self.revision = revision
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.opID = opID
        self.idempotent = idempotent
    }
}

// MARK: - Resolved route (never Codable, never logged)

struct C03ResolvedSpeechRoute: Sendable {
    var providerID: UUID
    var modelID: UUID
    var providerName: String
    var remoteModelID: String
    var baseURL: URL
    var credential: String
    var epoch: UInt64
}

enum C03SpeechEndpoint {
    static func audioURL(base: URL, path: String) -> URL? {
        guard base.scheme?.lowercased() == "https",
              let host = base.host, !host.isEmpty,
              base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = base.port
        var value = base.percentEncodedPath
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix(path) {
            components.percentEncodedPath = value
            return components.url
        }
        if !value.hasSuffix("/v1") {
            if value.isEmpty { value = "/v1" } else { value += "/v1" }
        }
        components.percentEncodedPath = value + path
        return components.url
    }
}

// MARK: - Provider/model/credential resolution

struct C03SpeechRouteResolver: Sendable {
    func resolve(_ selection: C03VoiceSelection)
        async throws -> C03ResolvedSpeechRoute
    {
        guard selection.configured,
              let providerID = selection.providerID,
              let modelID = selection.modelID else {
            throw C03VoiceError(.invalidSelection, "providerAndModelRequired")
        }
        guard let composition = G02RuntimeComposition.shared.installedComposition,
              composition.epoch > 0 else {
            throw C03VoiceError(.unconfigured, "runtimeNotInstalled", retryable: true)
        }
        guard G02RuntimeComposition.shared.transportGate.admitsCloudNetwork else {
            throw C03VoiceError(.transportUnavailable, "cloudTransportNotAdmitted", retryable: true)
        }
        let store = composition.cluster.modelConfigurationStore
        guard let model = try await store.model(id: modelID),
              model.providerID == providerID,
              model.isEnabled else {
            throw C03VoiceError(.unconfigured, "modelUnavailable")
        }
        guard let provider = try await store.provider(id: providerID),
              provider.isEnabled else {
            throw C03VoiceError(.unconfigured, "providerUnavailable")
        }
        guard provider.wireProtocol == .openAIResponses
                || provider.wireProtocol == .openAIChatCompletions else {
            throw C03VoiceError(.unsupportedModel, "providerProtocolNotOpenAICompatible")
        }
        guard let secretRef = provider.secretRef else {
            throw C03VoiceError(.credentialMissing, "providerCredentialNotConfigured")
        }
        guard provider.baseURL.scheme?.lowercased() == "https" else {
            throw C03VoiceError(.invalidSelection, "providerEndpointMustUseHTTPS")
        }
        let reference = SecretGatewayNaming.opaqueReference(for: secretRef)
        let secretData: Data
        do {
            guard let data = try await SecretGatewayRegistry.shared.read(reference: reference),
                  !data.isEmpty else {
                throw C03VoiceError(.credentialMissing, "providerCredentialUnreadable")
            }
            secretData = data
        } catch let typed as C03VoiceError {
            throw typed
        } catch {
            throw C03VoiceError(.credentialMissing, "providerCredentialUnavailable")
        }
        guard let credential = String(data: secretData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !credential.isEmpty else {
            throw C03VoiceError(.credentialMissing, "providerCredentialInvalid")
        }
        return C03ResolvedSpeechRoute(
            providerID: provider.id,
            modelID: model.id,
            providerName: provider.displayName ?? provider.kind.rawValue,
            remoteModelID: model.remoteModelID,
            baseURL: provider.baseURL,
            credential: credential,
            epoch: composition.epoch)
    }

    func revalidate(_ route: C03ResolvedSpeechRoute) throws {
        guard let composition = G02RuntimeComposition.shared.installedComposition,
              composition.epoch == route.epoch else {
            throw C03VoiceError(.coreUnavailable, "rootChanged", retryable: true)
        }
        guard G02RuntimeComposition.shared.transportGate.admitsCloudNetwork else {
            throw C03VoiceError(.transportUnavailable, "cloudTransportNotAdmitted", retryable: true)
        }
    }
}

// MARK: - Capability catalogue

enum C03SpeechCatalog {
    static func capabilities() async throws -> C03SpeechCapabilities {
        guard let composition = G02RuntimeComposition.shared.installedComposition,
              composition.epoch > 0 else {
            throw C03VoiceError(.unconfigured, "runtimeNotInstalled", retryable: true)
        }
        let transportReady = G02RuntimeComposition.shared.transportGate.admitsCloudNetwork
        let store = composition.cluster.modelConfigurationStore
        let providers = (try? await store.providers()) ?? []
        let models = (try? await store.models()) ?? []
        let providerByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        let gatewayReady = SecretGatewayRegistry.shared.isRegistered
        var asr: [C03SpeechModelChoice] = []
        var tts: [C03SpeechModelChoice] = []
        for model in models where model.isEnabled {
            guard let provider = providerByID[model.providerID], provider.isEnabled,
                  provider.wireProtocol == .openAIResponses
                    || provider.wireProtocol == .openAIChatCompletions,
                  provider.baseURL.scheme?.lowercased() == "https" else { continue }
            let lower = model.remoteModelID.lowercased()
            let likelyASR = lower.contains("whisper")
                || lower.contains("transcrib")
                || lower.contains("speech-to-text")
                || lower.contains("stt")
                || lower.contains("-asr")
            let likelyTTS = lower.contains("tts")
                || lower.contains("text-to-speech")
                || lower.contains("speech")
                || lower.contains("voice")
            let choice = C03SpeechModelChoice(
                providerID: provider.id,
                providerName: provider.displayName ?? provider.kind.rawValue,
                modelID: model.id,
                remoteModelID: model.remoteModelID,
                displayName: model.displayName,
                likelyASR: likelyASR,
                likelyTTS: likelyTTS,
                credentialConfigured: provider.secretRef != nil && gatewayReady)
            if likelyASR { asr.append(choice) }
            if likelyTTS { tts.append(choice) }
        }
        asr.sort { lhs, rhs in
            lhs.providerName == rhs.providerName
                ? lhs.displayName < rhs.displayName
                : lhs.providerName < rhs.providerName
        }
        tts.sort { lhs, rhs in
            lhs.providerName == rhs.providerName
                ? lhs.displayName < rhs.displayName
                : lhs.providerName < rhs.providerName
        }
        let cappedASR = Array(asr.prefix(80))
        let cappedTTS = Array(tts.prefix(80))
        let hasCredential = (cappedASR + cappedTTS).contains {
            $0.credentialConfigured
        }
        return C03SpeechCapabilities(
            cloudReady: transportReady && gatewayReady && hasCredential
                && !(cappedASR.isEmpty && cappedTTS.isEmpty),
            transportReady: transportReady,
            asrModels: cappedASR,
            ttsModels: cappedTTS)
    }
}

// MARK: - Cloud ASR (OpenAI-compatible transcription endpoint)

struct C03CloudASRClient: Sendable {
    func transcribe(
        route: C03ResolvedSpeechRoute,
        file: C03MediaFile,
        language: String?
    ) async throws -> C03Transcript {
        try C03SpeechRouteResolver().revalidate(route)
        let endpoint = C03SpeechEndpoint.audioURL(
            base: route.baseURL, path: "/audio/transcriptions")
        guard let endpoint else {
            throw C03VoiceError(.invalidSelection, "transcriptionEndpointInvalid")
        }
        guard !file.data.isEmpty else {
            throw C03VoiceError(.fileUnreadable, "audioFileEmpty")
        }
        guard file.data.count <= C03VoiceDomain.maxMediaBytes else {
            throw C03VoiceError(.fileTooLarge, "audioFileTooLarge")
        }
        let boundary = "floe-c03-\(UUID().uuidString.lowercased())"
        var body = Data()
        appendField("model", route.remoteModelID, boundary: boundary, to: &body)
        if let language, !language.isEmpty {
            appendField("language", String(language.prefix(64)), boundary: boundary, to: &body)
        }
        appendField("response_format", "verbose_json", boundary: boundary, to: &body)
        appendField("timestamp_granularities[]", "segment", boundary: boundary, to: &body)
        appendFile(
            field: "file",
            filename: C03CloudASRClient.safeFilename(file.filename),
            mimeType: C03CloudASRClient.safeMimeType(file.mimeType),
            data: file.data,
            boundary: boundary,
            to: &body)
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(route.credential)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (responseData, response) = try await C03CloudHTTP.collect(
            request: request,
            maxBytes: C03VoiceDomain.maxASRResponseBytes)
        guard let http = response as? HTTPURLResponse else {
            throw C03VoiceError(.invalidResponse, "noHTTPResponse")
        }
        try C03CloudHTTP.validate(status: http.statusCode)
        return try C03CloudASRClient.parse(
            responseData,
            durationSeconds: file.durationSeconds,
            providerName: route.providerName,
            modelDisplayName: route.remoteModelID)
    }

    private struct Response: Decodable {
        struct Segment: Decodable {
            let start: Double?
            let end: Double?
            let text: String?
        }
        let text: String?
        let language: String?
        let segments: [Segment]?
    }

    static func parse(
        _ data: Data,
        durationSeconds: Double?,
        providerName: String,
        modelDisplayName: String
    ) throws -> C03Transcript {
        _ = durationSeconds
        guard !data.isEmpty else {
            throw C03VoiceError(.emptyTranscript, "emptyProviderResponse")
        }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw C03VoiceError(.invalidResponse, "invalidTranscriptionJSON")
        }
        var segments: [C03TimedSegment] = []
        for item in decoded.segments ?? [] {
            guard let start = item.start, let end = item.end,
                  let text = item.text else { continue }
            if let normalized = C03TimedSegment(start: start, end: end, text: text).normalized() {
                segments.append(normalized)
            }
            if segments.count > C03VoiceDomain.maxSegments {
                throw C03VoiceError(.invalidResponse, "tooManySegments")
            }
        }
        segments.sort { $0.start < $1.start }
        var fullText = (decoded.text ?? "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if fullText.isEmpty {
            fullText = segments.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !fullText.isEmpty else {
            throw C03VoiceError(.emptyTranscript, "noRecognizedText")
        }
        let language = decoded.language.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A text-only provider response stays text-only. Callers may use the
        // plain text for dictation, but subtitle write-back must reject it
        // with `needsTiming`; inventing [0, duration] is not provider timing.
        return C03Transcript(
            segments: segments,
            language: language?.nilIfEmpty,
            providerName: providerName,
            modelDisplayName: modelDisplayName,
            text: fullText,
            timing: segments.isEmpty ? .textOnly : .providerSegments)
    }

    private static func appendField(
        _ name: String, _ value: String, boundary: String, to body: inout Data
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    private static func appendFile(
        field: String, filename: String, mimeType: String,
        data: Data, boundary: String, to body: inout Data
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data(
            "Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n"
                .utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    static func safeFilename(_ raw: String) -> String {
        var value = (raw as NSString).lastPathComponent
        value = value
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        if value.isEmpty || value.count > 200 { return "audio.bin" }
        return value
    }

    static func safeMimeType(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 128,
              value.range(of: "^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$",
                          options: .regularExpression) != nil else {
            return "application/octet-stream"
        }
        return value
    }
}

// MARK: - Cloud TTS (OpenAI-compatible speech endpoint)

struct C03SynthesizedAudio: Sendable {
    var fileURL: URL
    var sampleRate: Int
    var durationSeconds: Double
}

struct C03CloudTTSClient: Sendable {
    func synthesize(
        route: C03ResolvedSpeechRoute,
        text: String,
        voiceID: String,
        rate: Double,
        outputURL: URL
    ) async throws -> C03SynthesizedAudio {
        try C03SpeechRouteResolver().revalidate(route)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else {
            throw C03VoiceError(.invalidSelection, "emptyText")
        }
        guard cleanText.count <= C03VoiceDomain.maxTextCharacters else {
            throw C03VoiceError(.invalidSelection, "textTooLong")
        }
        guard !voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw C03VoiceError(.invalidSelection, "voiceIDRequired")
        }
        let endpoint = C03SpeechEndpoint.audioURL(base: route.baseURL, path: "/audio/speech")
        guard let endpoint else {
            throw C03VoiceError(.invalidSelection, "speechEndpointInvalid")
        }
        let chunks = C03TextSplitter.split(cleanText, maxCharacters: 1_800)
        guard !chunks.isEmpty, chunks.count <= 24 else {
            throw C03VoiceError(.invalidSelection, "textTooLong")
        }
        var pcm = Data()
        for chunk in chunks {
            var payload: [String: Any] = [
                "model": route.remoteModelID,
                "input": chunk,
                "voice": voiceID,
                "response_format": "pcm",
            ]
            if abs(rate - 1.0) > 0.001 {
                payload["speed"] = min(2.0, max(0.5, rate))
            }
            let body: Data
            do {
                body = try JSONSerialization.data(withJSONObject: payload)
            } catch {
                throw C03VoiceError(.invalidSelection, "requestEncodingFailed")
            }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("Bearer \(route.credential)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("audio/L16", forHTTPHeaderField: "Accept")
            request.httpBody = body
            let (data, response) = try await C03CloudHTTP.collect(
                request: request,
                maxBytes: C03VoiceDomain.maxTTSResponseBytes)
            guard let http = response as? HTTPURLResponse else {
                throw C03VoiceError(.invalidResponse, "noHTTPResponse")
            }
            try C03CloudHTTP.validate(status: http.statusCode)
            guard !data.isEmpty, data.count % 2 == 0 else {
                throw C03VoiceError(.invalidResponse, "invalidPCMResponse")
            }
            if pcm.count + data.count > C03VoiceDomain.maxTTSAudioBytes {
                throw C03VoiceError(.invalidResponse, "ttsAudioTooLong")
            }
            pcm.append(data)
            try Task.checkCancellation()
        }
        guard !pcm.isEmpty else {
            throw C03VoiceError(.emptyTranscript, "emptySpeechAudio")
        }
        let wav = C03CloudTTSClient.wav(pcm: pcm,
                                        sampleRate: C03VoiceDomain.ttsSampleRate)
        let parent = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true)
            try wav.write(to: outputURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw C03VoiceError(.writeFailed, "audioWriteFailed")
        }
        return C03SynthesizedAudio(
            fileURL: outputURL,
            sampleRate: C03VoiceDomain.ttsSampleRate,
            durationSeconds: Double(pcm.count)
                / Double(C03VoiceDomain.ttsSampleRate * 2))
    }

    static func wav(pcm: Data, sampleRate: Int) -> Data {
        let byteRate = UInt32(sampleRate * 2)
        let blockAlign = UInt16(2)
        var result = Data()
        result.append(Data("RIFF".utf8))
        result.append(littleEndian(UInt32(36 + pcm.count)))
        result.append(Data("WAVEfmt ".utf8))
        result.append(littleEndian(UInt32(16)))
        result.append(littleEndian(UInt16(1)))
        result.append(littleEndian(UInt16(1)))
        result.append(littleEndian(UInt32(sampleRate)))
        result.append(littleEndian(byteRate))
        result.append(littleEndian(blockAlign))
        result.append(littleEndian(UInt16(16)))
        result.append(Data("data".utf8))
        result.append(littleEndian(UInt32(pcm.count)))
        result.append(pcm)
        return result
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: MemoryLayout<T>.size)
    }
}

enum C03TextSplitter {
    static func split(_ text: String, maxCharacters: Int) -> [String] {
        let clean = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let limit = max(200, maxCharacters)
        if clean.count <= limit { return [clean] }
        var result: [String] = []
        var current = ""
        for character in clean {
            current.append(character)
            let boundary = character == "\n"
                || character == "。" || character == "！" || character == "？"
                || character == "!" || character == "?"
                || character == "."
            if boundary && current.count >= limit / 2 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            } else if current.count >= limit {
                if let space = current.lastIndex(of: " "),
                   current.distance(from: current.startIndex, to: space) >= limit / 2 {
                    let head = String(current[..<space])
                    let tail = String(current[current.index(after: space)...])
                    let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { result.append(trimmed) }
                    current = tail
                } else {
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { result.append(trimmed) }
                    current = ""
                }
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result.isEmpty ? [clean] : result
    }
}

// MARK: - Shared HTTP plumbing

enum C03CloudHTTP {
    static func collect(
        request: URLRequest,
        maxBytes: Int
    ) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = StreamingTransport.makeSession(
            configuration: configuration,
            refuseAllRedirects: true)
        defer { session.invalidateAndCancel() }
        do {
            return try await StreamingTransport.collect(
                request, via: session, maxBytes: maxBytes)
        } catch is CancellationError {
            throw C03VoiceError(.cancelled, "requestCancelled")
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw C03VoiceError(.cancelled, "requestCancelled")
            case .timedOut: throw C03VoiceError(.network, "requestTimedOut", retryable: true)
            case .cannotFindHost, .dnsLookupFailed:
                throw C03VoiceError(.network, "cannotResolveHost", retryable: true)
            case .cannotConnectToHost, .networkConnectionLost:
                throw C03VoiceError(.network, "cannotConnect", retryable: true)
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                throw C03VoiceError(.network, "tlsFailure")
            case .notConnectedToInternet, .dataNotAllowed:
                throw C03VoiceError(.network, "notReachable", retryable: true)
            default:
                throw C03VoiceError(.network, "transportFailure", retryable: true)
            }
        } catch let error as IncrementalTransportError {
            switch error {
            case .responseTooLarge(_):
                throw C03VoiceError(.invalidResponse, "responseTooLarge")
            case .pendingBufferSaturated(_):
                throw C03VoiceError(.network, "transportBackpressure", retryable: true)
            case .sessionNotStreamable(_):
                throw C03VoiceError(.coreUnavailable, "transportSessionInvalid", retryable: true)
            case .noHTTPResponse:
                throw C03VoiceError(.invalidResponse, "noHTTPResponse")
            }
        } catch {
            throw C03VoiceError(.network, "transportFailure", retryable: true)
        }
    }

    static func validate(status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw C03VoiceError(.authentication, "providerAuth")
        case 429: throw C03VoiceError(.quotaOrRateLimited, "providerQuota", retryable: false)
        case 400, 404, 422:
            throw C03VoiceError(.providerRejected, "providerRejectedRequest", retryable: false)
        case 500...599:
            throw C03VoiceError(.providerRejected, "providerServerError", retryable: true)
        default:
            throw C03VoiceError(.providerRejected, "providerHTTPStatus", retryable: false)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

// MARK: - Timed subtitle planning (pure)

public enum C03SubtitlePlanner {
    /// Merges real provider-timed segments into the existing caption track.
    /// Manual captions are always preserved in replace mode; only prior
    /// transcription-sourced captions are replaced. The result is sorted by
    /// the source media timeline and has no caller-controlled text/state.
    public static func plan(
        existing: [CaptionSegment],
        segments: [C03TimedSegment],
        replaceTranscribed: Bool,
        assetID: UUID? = nil,
        clips: [VideoClip] = []
    ) -> [CaptionSegment] {
        let normalized = segments.compactMap { $0.normalized() }
        let kept = replaceTranscribed
            ? existing.filter { $0.source != .transcription }
            : existing
        let added = timedCaptions(
            segments: normalized,
            assetID: assetID,
            clips: clips)
        return (kept + added).sorted {
            if abs($0.start - $1.start) > 0.000_1 { return $0.start < $1.start }
            return $0.end < $1.end
        }
    }

    /// Maps source-media ASR seconds onto the REAL placed clip timeline:
    /// trim start, per-clip speed and leading cross-dissolve placement are the
    /// exact `MediaTimelineMath` rules the preview/export use. Without a
    /// matching clip (audio-only project) the source timeline is the only
    /// truthful coordinate system.
    public static func timedCaptions(
        segments: [C03TimedSegment],
        assetID: UUID?,
        clips: [VideoClip]
    ) -> [CaptionSegment] {
        let normalized = segments.compactMap { $0.normalized() }
        guard let assetID else {
            return normalized.map {
                CaptionSegment(start: $0.start, end: $0.end,
                               text: $0.text, source: .transcription)
            }
        }
        let placements = MediaTimelineMath.placeClips(clips)
            .filter { $0.clip.assetID == assetID && $0.clip.speed > 0 }
        guard !placements.isEmpty else {
            return normalized.map {
                CaptionSegment(start: $0.start, end: $0.end,
                               text: $0.text, source: .transcription)
            }
        }
        var result: [CaptionSegment] = []
        for placement in placements {
            let clip = placement.clip
            for segment in normalized {
                let sourceStart = max(segment.start, clip.trimStart)
                let sourceEnd = min(segment.end, clip.trimEnd)
                guard sourceEnd > sourceStart else { continue }
                let start = placement.timelineStart
                    + (sourceStart - clip.trimStart) / clip.speed
                let end = placement.timelineStart
                    + (sourceEnd - clip.trimStart) / clip.speed
                guard start.isFinite, end.isFinite, end > start else { continue }
                result.append(CaptionSegment(
                    start: start, end: end,
                    text: segment.text, source: .transcription))
            }
        }
        return result
    }
}

// MARK: - Text-only refusal + chunked source timeline

public enum C03SubtitleWritePolicy {
    /// Subtitle write-back requires REAL provider-timed segments. Plain text
    /// (including gpt-transcribe text-only responses) is a valid dictation
    /// result but is NOT alignment evidence, so it never becomes a
    /// full-clip `.transcription` cue. The original project stays untouched.
    public static func validate(_ transcript: C03Transcript) throws {
        guard transcript.timing == .providerSegments else {
            throw C03VoiceError(.needsTiming, "providerReturnedNoTiming")
        }
        guard !transcript.segments.compactMap({ $0.normalized() }).isEmpty else {
            throw C03VoiceError(.needsTiming, "providerReturnedNoTiming")
        }
    }
}

enum C03ChunkTimeline {
    /// Shift one chunk's provider-relative segments onto the real source
    /// timeline. A segment that crosses the chunk boundary is clipped to the
    /// decoded audio that actually existed; nothing is fabricated.
    static func shift(
        _ segments: [C03TimedSegment],
        sourceStart: Double,
        sourceDuration: Double
    ) -> [C03TimedSegment] {
        guard sourceStart.isFinite, sourceStart >= 0,
              sourceDuration.isFinite, sourceDuration > 0 else { return [] }
        let chunkEnd = sourceStart + sourceDuration
        var result: [C03TimedSegment] = []
        for segment in segments {
            guard let clean = segment.normalized() else { continue }
            let start = max(sourceStart, sourceStart + clean.start)
            let end = min(chunkEnd, sourceStart + clean.end)
            guard start.isFinite, end.isFinite, end > start else { continue }
            if let shifted = C03TimedSegment(
                start: start,
                end: end,
                text: clean.text
            ).normalized() {
                result.append(shifted)
            }
        }
        return result.sorted { lhs, rhs in
            if abs(lhs.start - rhs.start) > 0.000_1 { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }
    }

    /// Merge already-shifted chunk segments, drop exact duplicates produced by
    /// a provider repeating boundary text, and keep the existing segment cap.
    static func merge(
        _ existing: [C03TimedSegment],
        _ appended: [C03TimedSegment],
        maxSegments: Int
    ) -> [C03TimedSegment] {
        var seen = Set<String>()
        var result: [C03TimedSegment] = []
        for segment in (existing + appended) {
            guard let clean = segment.normalized() else { continue }
            let key = "\(Int((clean.start * 1_000).rounded()))|" +
                "\(Int((clean.end * 1_000).rounded()))|\(clean.text)"
            if !seen.insert(key).inserted { continue }
            result.append(clean)
        }
        let sorted = result.sorted { lhs, rhs in
            if abs(lhs.start - rhs.start) > 0.000_1 { return lhs.start < rhs.start }
            return lhs.end < rhs.end
        }
        return Array(sorted.prefix(max(1, maxSegments)))
    }
}

// MARK: - Trusted media resolution + timed subtitle write-back

actor C03SubtitleService {
    static let shared = C03SubtitleService()

    private struct LoadedEnvelope: Sendable {
        var envelope: G09R2VideoEnvelopeDTO
        var rootURL: URL
    }

    func loadDescriptor(_ context: C03MediaContext) async throws -> C03MediaDescriptor {
        guard G02RuntimeComposition.shared.transportGate.admitsCloudNetwork else {
            throw C03VoiceError(.transportUnavailable, "transportNotAdmitted", retryable: true)
        }
        let loaded = try await loadEnvelope(context, expectedRevision: context.expectedRevision)
        guard loaded.envelope.writable else {
            throw C03VoiceError(.mediaUnavailable, "projectNotWritable")
        }
        guard let asset = loaded.envelope.project.asset(context.assetID) else {
            throw C03VoiceError(.mediaUnavailable, "assetMissing")
        }
        guard asset.kind == .audio || asset.kind == .video else {
            throw C03VoiceError(.unsupportedMedia, "assetHasNoAudio")
        }
        guard G09CreativeAssetHost.safeRelativePath(asset.relativePath),
              asset.relativePath.hasPrefix("Workbench/Assets/") else {
            throw C03VoiceError(.mediaUnavailable, "assetPathInvalid")
        }
        let target = loaded.rootURL
            .appendingPathComponent(asset.relativePath)
            .standardizedFileURL
        guard target.path.hasPrefix(loaded.rootURL.path + "/") else {
            throw C03VoiceError(.mediaUnavailable, "assetEscapesRoot")
        }
        let values: URLResourceValues
        do {
            values = try target.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw C03VoiceError(.fileUnreadable, "assetUnreadable")
        }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize, size > 0 else {
            throw C03VoiceError(.fileUnreadable, "assetUnreadable")
        }
        guard Int64(size) <= C03VoiceDomain.maxSourceBytes else {
            throw C03VoiceError(.fileTooLarge, "sourceFileTooLarge")
        }
        let duration = asset.metadata?.durationSeconds
        if let duration, duration.isFinite,
           duration > Double(C03VoiceDomain.maxSourceDurationSeconds) {
            throw C03VoiceError(.fileTooLarge, "sourceDurationTooLong")
        }
        return C03MediaDescriptor(
            url: target,
            filename: asset.originalName,
            mimeType: Self.mimeType(for: asset),
            byteSize: Int64(size),
            durationSeconds: duration,
            projectRevision: loaded.envelope.project.revision,
            assetKind: asset.kind)
    }

    func loadFile(_ context: C03MediaContext) async throws -> C03MediaFile {
        let descriptor = try await loadDescriptor(context)
        guard descriptor.byteSize <= Int64(C03VoiceDomain.maxMediaBytes) else {
            // The single-shot compatibility path stays explicit about its
            // provider request cap; the host uses the chunked plan instead.
            throw C03VoiceError(.fileTooLarge, "audioFileTooLarge")
        }
        let data: Data
        do {
            data = try Data(contentsOf: descriptor.url)
        } catch {
            throw C03VoiceError(.fileUnreadable, "assetReadFailed")
        }
        guard Int64(data.count) == descriptor.byteSize,
              data.count <= C03VoiceDomain.maxMediaBytes else {
            throw C03VoiceError(.fileTooLarge, "assetChangedWhileReading")
        }
        return C03MediaFile(
            data: data,
            filename: descriptor.filename,
            mimeType: descriptor.mimeType,
            durationSeconds: descriptor.durationSeconds,
            projectRevision: descriptor.projectRevision,
            assetKind: descriptor.assetKind)
    }

    func write(
        _ context: C03MediaContext,
        transcript: C03Transcript,
        expectedRevision: Int64,
        replaceTranscribed: Bool,
        opID: String
    ) async throws -> C03SubtitleReceipt {
        guard !opID.isEmpty, G09CreativeWire.safeOperationID(opID) else {
            throw C03VoiceError(.invalidSelection, "invalidOperationID")
        }
        // Refuse text-only timing before touching the project file.
        try C03SubtitleWritePolicy.validate(transcript)
        guard let composition = G02RuntimeComposition.shared.installedComposition,
              composition.epoch > 0 else {
            throw C03VoiceError(.coreUnavailable, "runtimeNotInstalled", retryable: true)
        }
        let loaded = try await loadEnvelope(context, expectedRevision: expectedRevision)
        guard loaded.envelope.writable else {
            throw C03VoiceError(.mediaUnavailable, "projectNotWritable")
        }
        guard loaded.envelope.project.revision == expectedRevision else {
            throw C03VoiceError(.staleRevision, "projectChanged")
        }
        let normalized = transcript.segments.compactMap { $0.normalized() }
        guard !normalized.isEmpty else {
            throw C03VoiceError(.emptyTranscript, "noTimedSegments")
        }
        guard normalized.count <= C03VoiceDomain.maxSegments else {
            throw C03VoiceError(.invalidResponse, "tooManySegments")
        }
        var timeline = loaded.envelope.project.videoTimeline ?? VideoTimeline()
        let existing = timeline.captions
        let combined = C03SubtitlePlanner.plan(
            existing: existing,
            segments: normalized,
            replaceTranscribed: replaceTranscribed,
            assetID: context.assetID,
            clips: timeline.clips)
        guard combined != existing else {
            return C03SubtitleReceipt(
                projectID: loaded.envelope.project.id,
                revision: loaded.envelope.project.revision,
                canUndo: MediaTransactions.canUndo(loaded.envelope.project),
                canRedo: MediaTransactions.canRedo(loaded.envelope.project),
                opID: opID,
                idempotent: true)
        }
        var project = loaded.envelope.project
        let checkpoint = project.memento()
        timeline.captions = combined
        project.videoTimeline = timeline
        project.revision = loaded.envelope.project.revision + 1
        project.updatedAt = Date()
        project.undoHistory = Array(
            (loaded.envelope.project.undoHistory + [checkpoint]).suffix(100))
        project.redoHistory = []
        let host = G09MediaProjectHost(
            root: composition.cluster.identity.root,
            workspaceStore: composition.cluster.workspaceStore,
            conversationStore: composition.cluster.conversationStore)
        do {
            let committed = try await host.commitApplied(
                project,
                expectedRevision: expectedRevision,
                sessionToken: context.sessionToken,
                storage: context.storage,
                origin: context.origin,
                opID: opID)
            return C03SubtitleReceipt(
                projectID: committed.project.id,
                revision: committed.project.revision,
                canUndo: MediaTransactions.canUndo(committed.project),
                canRedo: MediaTransactions.canRedo(committed.project),
                opID: opID,
                idempotent: false)
        } catch {
            throw Self.map(error)
        }
    }

    private func loadEnvelope(
        _ context: C03MediaContext,
        expectedRevision: Int64
    ) async throws -> LoadedEnvelope {
        guard let composition = G02RuntimeComposition.shared.installedComposition,
              composition.epoch > 0 else {
            throw C03VoiceError(.coreUnavailable, "runtimeNotInstalled", retryable: true)
        }
        let request = G09R2VideoLoadRequest(
            context: G09R2ProjectContextDTO(
                projectID: context.projectID,
                sessionToken: context.sessionToken,
                storage: context.storage,
                origin: context.origin))
        let result: G09R2MediaFoundation.VideoLoadResult
        do {
            result = try await G09R2MediaFoundation.shared.loadVideo(
                service: BridgeV5.service,
                epoch: composition.epoch,
                request: request)
        } catch {
            throw Self.map(error)
        }
        guard result.envelope.project.id == context.projectID else {
            throw C03VoiceError(.mediaUnavailable, "projectIdentityMismatch")
        }
        guard result.envelope.project.revision == expectedRevision else {
            throw C03VoiceError(.staleRevision, "projectChanged")
        }
        let root = URL(fileURLWithPath: result.envelope.mediaRootPath,
                       isDirectory: true).standardizedFileURL
        let accepted = URL(
            fileURLWithPath: composition.cluster.identity.root.path,
            isDirectory: true).standardizedFileURL
        guard root.path == accepted.path
                || root.path.hasPrefix(accepted.path + "/") else {
            throw C03VoiceError(.mediaUnavailable, "mediaRootOutsideAcceptedRoot")
        }
        return LoadedEnvelope(envelope: result.envelope, rootURL: root)
    }

    private static func mimeType(for asset: MediaAssetReference) -> String {
        switch (asset.relativePath as NSString).pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "ogg", "opus": return "audio/ogg"
        case "flac": return "audio/flac"
        case "webm": return "audio/webm"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }

    private static func map(_ error: Error) -> C03VoiceError {
        if let typed = error as? C03VoiceError { return typed }
        let code: String
        if let creative = error as? G09CreativeError {
            code = creative.code
        } else if let r2 = error as? G09R2Error {
            code = r2.code
        } else {
            code = "unknown"
        }
        switch code {
        case "revisionConflict":
            return C03VoiceError(.staleRevision, "revisionConflict")
        case "sessionRequired", "staleSession":
            return C03VoiceError(.sessionRequired, "mediaSessionRequired")
        case "mediaProjectNotFound":
            return C03VoiceError(.projectNotFound, "projectNotFound")
        case "invalidOrigin", "untrustedOwner", "crossOwnerRefused":
            return C03VoiceError(.mediaUnavailable, "ownerRefused")
        case "writeFailed", "storageUnavailable", "outcomeUnknown":
            return C03VoiceError(.writeFailed, "projectWriteFailed")
        case "assetMissing", "assetReferenceInvalid":
            return C03VoiceError(.mediaUnavailable, "assetUnavailable")
        default:
            return C03VoiceError(.mediaUnavailable, "mediaOperationFailed")
        }
    }
}

// MARK: - Canonical non-secret voice settings (existing app_settings store)

public struct C03VoiceSelectionWire: Sendable, Equatable {
    public var providerID: String?
    public var modelID: String?
    public var voiceID: String
    public var language: String?
    public var rate: Double

    public init(providerID: String? = nil, modelID: String? = nil,
                voiceID: String = "", language: String? = nil, rate: Double = 1.0) {
        self.providerID = providerID
        self.modelID = modelID
        self.voiceID = voiceID
        self.language = language
        self.rate = rate
    }

    var configured: Bool {
        !(providerID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !(modelID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func normalized() -> C03VoiceSelectionWire {
        C03VoiceSelectionWire(
            providerID: Self.bounded(providerID, 128),
            modelID: Self.bounded(modelID, 128),
            voiceID: String(voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(200)),
            language: Self.bounded(language, 64),
            rate: rate.isFinite ? min(2.0, max(0.5, rate)) : 1.0)
    }

    var jsonObject: [String: Any] {
        var value: [String: Any] = [
            "voiceID": voiceID,
            "rate": rate,
        ]
        if let providerID { value["providerID"] = providerID }
        if let modelID { value["modelID"] = modelID }
        if let language { value["language"] = language }
        return value
    }

    static func parse(_ value: Any?) -> C03VoiceSelectionWire {
        guard let object = value as? [String: Any] else { return C03VoiceSelectionWire() }
        return C03VoiceSelectionWire(
            providerID: bounded(object["providerID"] as? String, 128),
            modelID: bounded(object["modelID"] as? String, 128),
            voiceID: String((object["voiceID"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
            language: bounded(object["language"] as? String, 64),
            rate: doubleValue(object["rate"]) ?? 1.0)
    }

    private static func bounded(_ value: String?, _ limit: Int) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= limit else { return nil }
        return clean
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let number = value as? Double { return number }
        return nil
    }
}

public struct C03VoiceSettingsWire: Sendable, Equatable {
    public var schema: Int
    public var inputLanguage: String?
    public var inputEngine: String
    public var outputEngine: String
    public var systemVoiceName: String?
    public var systemVoiceLocale: String?
    public var rate: Double
    public var pitch: Double
    public var cloudInput: C03VoiceSelectionWire
    public var cloudOutput: C03VoiceSelectionWire
    public var transcriptionProviderID: String?
    public var transcriptionModelID: String?
    public var transcriptionLanguage: String?
    public var replaceTranscribedCaptions: Bool

    public static let currentSchema = 2

    static let knownKeys: Set<String> = [
        "schema", "revision", "inputLanguage", "inputEngine", "outputEngine",
        "systemVoiceName", "systemVoiceLocale", "rate", "pitch", "cloudInput",
        "cloudOutput", "transcriptionProviderID", "transcriptionModelID",
        "transcriptionLanguage", "replaceTranscribedCaptions",
    ]

    public init() {
        self.schema = Self.currentSchema
        self.inputLanguage = nil
        self.inputEngine = "system"
        self.outputEngine = "system"
        self.systemVoiceName = nil
        self.systemVoiceLocale = nil
        self.rate = 1.0
        self.pitch = 0.0
        self.cloudInput = C03VoiceSelectionWire()
        self.cloudOutput = C03VoiceSelectionWire()
        self.transcriptionProviderID = nil
        self.transcriptionModelID = nil
        self.transcriptionLanguage = nil
        self.replaceTranscribedCaptions = true
    }

    public init?(json: [String: Any]) {
        guard !C03VoiceSettingsService.containsSecret(json) else { return nil }
        guard let rawSchema = integerValue(json["schema"]),
              rawSchema >= 1, rawSchema <= Self.currentSchema else { return nil }
        let defaultSelection = C03VoiceSelectionWire()
        self.schema = rawSchema
        self.inputLanguage = Self.bounded(json["inputLanguage"] as? String, 64)
        // Schema 1 had no interactive input engine; system remains the
        // documented first-use default and the existing output choice survives.
        self.inputEngine = rawSchema >= 2
            ? Self.engine(json["inputEngine"] as? String)
            : "system"
        self.outputEngine = Self.engine(json["outputEngine"] as? String)
        self.systemVoiceName = Self.bounded(json["systemVoiceName"] as? String, 200)
        self.systemVoiceLocale = Self.bounded(json["systemVoiceLocale"] as? String, 64)
        self.rate = (doubleValue(json["rate"]) ?? 1.0).coerce(0.5, 2.0)
        self.pitch = (doubleValue(json["pitch"]) ?? 0.0).coerce(-6.0, 6.0)
        self.cloudInput = rawSchema >= 2
            ? C03VoiceSelectionWire.parse(json["cloudInput"])
            : defaultSelection
        self.cloudOutput = C03VoiceSelectionWire.parse(json["cloudOutput"])
        self.transcriptionProviderID = Self.bounded(
            json["transcriptionProviderID"] as? String, 128)
        self.transcriptionModelID = Self.bounded(
            json["transcriptionModelID"] as? String, 128)
        self.transcriptionLanguage = Self.bounded(
            json["transcriptionLanguage"] as? String, 64)
        if let flag = json["replaceTranscribedCaptions"] as? Bool {
            self.replaceTranscribedCaptions = flag
        } else if let number = json["replaceTranscribedCaptions"] as? NSNumber {
            self.replaceTranscribedCaptions = number.boolValue
        } else {
            self.replaceTranscribedCaptions = true
        }
        self.normalize()
    }

    mutating func normalize() {
        schema = Self.currentSchema
        inputLanguage = Self.bounded(inputLanguage, 64)
        inputEngine = Self.engine(inputEngine)
        outputEngine = Self.engine(outputEngine)
        systemVoiceName = Self.bounded(systemVoiceName, 200)
        systemVoiceLocale = Self.bounded(systemVoiceLocale, 64)
        rate = rate.isFinite ? rate.coerce(0.5, 2.0) : 1.0
        pitch = pitch.isFinite ? pitch.coerce(-6.0, 6.0) : 0.0
        cloudInput = cloudInput.normalized()
        cloudOutput = cloudOutput.normalized()
        transcriptionProviderID = Self.bounded(transcriptionProviderID, 128)
        transcriptionModelID = Self.bounded(transcriptionModelID, 128)
        transcriptionLanguage = Self.bounded(transcriptionLanguage, 64)
    }

    var jsonObject: [String: Any] {
        var value: [String: Any] = [
            "schema": schema,
            "inputEngine": inputEngine,
            "outputEngine": outputEngine,
            "rate": rate,
            "pitch": pitch,
            "cloudInput": cloudInput.jsonObject,
            "cloudOutput": cloudOutput.jsonObject,
            "replaceTranscribedCaptions": replaceTranscribedCaptions,
        ]
        if let inputLanguage { value["inputLanguage"] = inputLanguage }
        if let systemVoiceName { value["systemVoiceName"] = systemVoiceName }
        if let systemVoiceLocale { value["systemVoiceLocale"] = systemVoiceLocale }
        if let transcriptionProviderID {
            value["transcriptionProviderID"] = transcriptionProviderID
        }
        if let transcriptionModelID { value["transcriptionModelID"] = transcriptionModelID }
        if let transcriptionLanguage {
            value["transcriptionLanguage"] = transcriptionLanguage
        }
        return value
    }

    static func engine(_ value: String?) -> String {
        value == "cloud" ? "cloud" : "system"
    }

    private static func bounded(_ value: String?, _ limit: Int) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.utf8.count <= limit else { return nil }
        return clean
    }
}

public struct C03SettingsSnapshot: Sendable, Equatable {
    public var found: Bool
    public var unreadable: Bool
    public var revision: Int64
    public var settings: C03VoiceSettingsWire?
}

public struct C03SettingsSaveOutcome: Sendable, Equatable {
    public var revision: Int64
    public var settings: C03VoiceSettingsWire
}

/// Canonical settings live in the EXISTING `app_settings` row. The actor
/// serializes read-modify-write in this process and the bridge rechecks the
/// exact root epoch before/after the write; a future/unreadable row is never
/// overwritten. This is offline-safe: only provider requests use the network
/// admission gate.
public actor C03VoiceSettingsService {
    public static let shared = C03VoiceSettingsService()
    static let key = "voice.settings.v1"

    public init() {}

    public func load(epoch: UInt64) async throws -> C03SettingsSnapshot {
        try requireEpoch(epoch)
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            throw C03VoiceError(.coreUnavailable, "runtimeNotInstalled", retryable: true)
        }
        let raw: String?
        do {
            raw = try await composition.cluster.settingsStore.value(forKey: Self.key)
        } catch {
            throw C03VoiceError(.coreUnavailable, "settingsStoreUnavailable", retryable: true)
        }
        guard let raw else {
            return C03SettingsSnapshot(
                found: false, unreadable: false, revision: 0, settings: nil)
        }
        guard let object = Self.object(from: raw), !Self.containsSecret(object),
              let settings = C03VoiceSettingsWire(json: object),
              let revision = Self.revision(object, raw: raw),
              revision < Int64.max else {
            // Preserve the exact bytes. No default is written over this row.
            // A revision that is not an exact non-negative integer, or one
            // that cannot advance without overflow, is unreadable/refused.
            return C03SettingsSnapshot(
                found: true, unreadable: true, revision: 0, settings: nil)
        }
        return C03SettingsSnapshot(
            found: true, unreadable: false, revision: revision, settings: settings)
    }

    public func save(
        settingsJSON: Data,
        expectedRevision: Int64,
        epoch: UInt64
    ) async throws -> C03SettingsSaveOutcome {
        try requireEpoch(epoch)
        guard expectedRevision >= 0, expectedRevision < Int64.max else {
            throw C03VoiceError(.invalidSelection, "invalidExpectedRevision")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: settingsJSON),
              let settingsObject = parsed as? [String: Any] else {
            throw C03VoiceError(.invalidSelection, "invalidVoiceSettings")
        }
        guard !Self.containsSecret(settingsObject) else {
            throw C03VoiceError(.invalidSelection, "settingsContainSecret")
        }
        guard let incoming = C03VoiceSettingsWire(json: settingsObject) else {
            throw C03VoiceError(.invalidSelection, "invalidVoiceSettings")
        }
        var normalized = incoming
        normalized.normalize()
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            throw C03VoiceError(.coreUnavailable, "runtimeNotInstalled", retryable: true)
        }
        let store = composition.cluster.settingsStore
        let raw: String?
        do {
            raw = try await store.value(forKey: Self.key)
        } catch {
            throw C03VoiceError(.coreUnavailable, "settingsStoreUnavailable", retryable: true)
        }
        let decision = C03SettingsCAS.decide(
            currentRaw: raw, expectedRevision: expectedRevision)
        let currentRevision: Int64
        switch decision {
        case .unreadable:
            throw C03VoiceError(.invalidSelection, "settingsUnreadable")
        case .stale:
            throw C03VoiceError(.staleRevision, "settingsChanged")
        case .write(let nextRevision):
            currentRevision = nextRevision - 1
        }
        var currentObject: [String: Any] = [:]
        if let raw, let object = Self.object(from: raw) {
            currentObject = object
        }
        try requireEpoch(epoch)
        var merged = currentObject
        for (key, value) in currentObject
            where !C03VoiceSettingsWire.knownKeys.contains(key) {
            merged[key] = value
        }
        for (key, value) in normalized.jsonObject {
            merged[key] = value
        }
        merged["schema"] = C03VoiceSettingsWire.currentSchema
        merged["revision"] = currentRevision + 1
        guard JSONSerialization.isValidJSONObject(merged),
              let data = try? JSONSerialization.data(withJSONObject: merged),
              let json = String(data: data, encoding: .utf8) else {
            throw C03VoiceError(.invalidSelection, "settingsEncodeFailed")
        }
        let wrote: Bool
        do {
            // The STORE performs the authoritative compare-and-swap in one
            // writer transaction. Reading `raw` above only prepares the
            // merged document; it never authorizes an unconditional write.
            wrote = try await store.compareAndSetValue(
                json, forKey: Self.key, expectedValue: raw)
        } catch {
            throw C03VoiceError(.writeFailed, "settingsWriteFailed", retryable: true)
        }
        guard wrote else {
            throw C03VoiceError(.staleRevision, "settingsChanged")
        }
        try requireEpoch(epoch)
        return C03SettingsSaveOutcome(
            revision: currentRevision + 1,
            settings: normalized)
    }

    private func requireEpoch(_ epoch: UInt64) throws {
        guard let composition = G02RuntimeComposition.shared.installedComposition,
              composition.epoch == epoch else {
            throw C03VoiceError(.coreUnavailable, "rootRetired", retryable: true)
        }
    }

    private struct RevisionEnvelope: Decodable {
        let revision: Int64?
    }

    /// Exact stored revision. A missing key is revision 0; an explicit null,
    /// boolean, fractional value, negative or overflowing value is refused
    /// rather than coerced (JSONDecoder's `Int64` is strict here).
    static func revision(_ object: [String: Any], raw: String) -> Int64? {
        guard let value = object["revision"] else { return 0 }
        guard !(value is NSNull) else { return nil }
        guard let envelope = try? JSONDecoder().decode(
            RevisionEnvelope.self, from: Data(raw.utf8)),
              let revision = envelope.revision,
              revision >= 0, revision < Int64.max else {
            return nil
        }
        return revision
    }

    static func object(from raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any] else { return nil }
        return object
    }

    static func containsSecret(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for (key, nested) in object {
                let lower = key.lowercased()
                if lower.contains("apikey") || lower.contains("api_key") ||
                    lower.contains("secret") || lower.contains("token") ||
                    lower.contains("password") || lower == "authorization" {
                    return true
                }
                if containsSecret(nested) { return true }
            }
        } else if let array = value as? [Any] {
            return array.contains(where: containsSecret)
        }
        return false
    }
}

public enum C03SettingsCASDecision: Sendable, Equatable {
    case write(nextRevision: Int64)
    case stale(expected: Int64, actual: Int64)
    case unreadable
}

/// Pure compare-and-swap decision used by the canonical settings service and
/// by source tests. It never mutates storage and never rewrites unreadable or
/// future-schema bytes.
public enum C03SettingsCAS {
    public static func decide(
        currentRaw: String?,
        expectedRevision: Int64
    ) -> C03SettingsCASDecision {
        guard let raw = currentRaw else {
            return expectedRevision == 0
                ? .write(nextRevision: 1)
                : .stale(expected: expectedRevision, actual: 0)
        }
        guard let object = C03VoiceSettingsService.object(from: raw),
              !C03VoiceSettingsService.containsSecret(object),
              C03VoiceSettingsWire(json: object) != nil,
              let actual = C03VoiceSettingsService.revision(object, raw: raw),
              actual < Int64.max else {
            return .unreadable
        }
        return actual == expectedRevision
            ? .write(nextRevision: actual + 1)
            : .stale(expected: expectedRevision, actual: actual)
    }
}

/// Exact integer for schema fields. `NSNumber`/`Int` bridging alone would
/// accept `true` as 1 and `1.5` as 1; malformed rows must stay unreadable.
private func integerValue(_ value: Any?) -> Int? {
    guard let value, !(value is NSNull),
          let number = value as? NSNumber else { return nil }
    let type = String(cString: number.objCType)
    guard type != "c", type != "B", type != "d", type != "f" else {
        return nil
    }
    guard let parsed = Int64(number.stringValue),
          parsed >= Int64(Int.min), parsed <= Int64(Int.max) else {
        return nil
    }
    return Int(parsed)
}

private func doubleValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let number = value as? Double { return number }
    return nil
}

private extension Double {
    func coerce(_ minimum: Double, _ maximum: Double) -> Double {
        min(maximum, max(minimum, self))
    }
}

// MARK: - Operation status

public enum C03OperationState: String, Sendable, Equatable {
    case running
    case completed
    case failed
    case cancelled
}

public struct C03ASRStatus: Sendable, Equatable {
    public var state: C03OperationState
    public var progress: Double
    public var segmentCount: Int
    public var failure: C03VoiceError?

    public init(state: C03OperationState, progress: Double,
                segmentCount: Int, failure: C03VoiceError? = nil) {
        self.state = state
        self.progress = progress
        self.segmentCount = segmentCount
        self.failure = failure
    }
}

public struct C03TTSStatus: Sendable, Equatable {
    public var state: C03OperationState
    public var progress: Double
    public var audioPath: String?
    public var sampleRate: Int
    public var durationSeconds: Double?
    public var failure: C03VoiceError?

    public init(state: C03OperationState, progress: Double,
                audioPath: String?, sampleRate: Int,
                durationSeconds: Double?, failure: C03VoiceError? = nil) {
        self.state = state
        self.progress = progress
        self.audioPath = audioPath
        self.sampleRate = sampleRate
        self.durationSeconds = durationSeconds
        self.failure = failure
    }
}

// MARK: - Owned cloud operations

/// One actor owns every in-flight cloud operation. Each start is bounded,
/// cancellable and root-epoch fenced. Transcript/audio files are released on
/// completion, explicit release or cancellation; nothing is cached in a new
/// database or a shared voice directory.
public actor C03VoiceDomain {
    public static let shared = C03VoiceDomain()

    public static let maxMediaBytes = 25 * 1024 * 1024
    public static let maxChunkBytes = 20 * 1024 * 1024
    public static let maxSourceBytes: Int64 = 8 * 1024 * 1024 * 1024
    public static let maxSourceDurationSeconds = 12 * 60 * 60
    public static let maxUtteranceBytes = 8 * 1024 * 1024
    public static let maxTextCharacters = 6_000
    public static let maxSegments = 2_000
    public static let ttsSampleRate = 24_000
    public static let maxASRResponseBytes = 8 * 1024 * 1024
    public static let maxTTSResponseBytes = 32 * 1024 * 1024
    public static let maxTTSAudioBytes = 64 * 1024 * 1024

    private enum ASROperationKind: Equatable {
        case single
        case chunked
        case utterance
    }

    private struct InflightChunk {
        var token: String
        var index: Int
        var task: Task<C03Transcript, Error>
    }

    private struct ASROperation {
        var status: C03ASRStatus
        var transcript: C03Transcript?
        var context: C03MediaContext?
        var kind: ASROperationKind
        var route: C03ResolvedSpeechRoute?
        var sourceURL: URL?
        var stagingURL: URL?
        var chunkCount: Int
        var expectedChunks: Int
        var sourceDuration: Double
        var language: String?
        var epoch: UInt64
        var owner: C03VoiceOwner?
        /// The `Voice` root owned when the operation was created. Cleanup
        /// uses this captured root even if the live composition was retired
        /// before cancellation drained.
        var voiceRoot: URL?
        var task: Task<Void, Never>?
        /// Unique token for the task that owns this operation. A late task
        /// result whose token no longer matches is dropped, never applied.
        var taskToken: String?
        /// Monotonic per-operation cancel fence. It is set BEFORE the network
        /// task is cancelled and is never cleared, so a late success cannot
        /// resurrect a cancelled/failed operation.
        var cancelRequested: Bool
        /// The ONE provider dispatch allowed for the next sequential chunk.
        /// Reserved before any await; cleared only after real settlement.
        var inflightChunk: InflightChunk?
    }

    private struct UtteranceStaging {
        var path: URL
        var owner: C03VoiceOwner
        var epoch: UInt64
        var createdAt: Date
        var voiceRoot: URL?
    }

    private struct TTSOperation {
        var status: C03TTSStatus
        var outputURL: URL?
        var epoch: UInt64
        var voiceRoot: URL?
        var task: Task<Void, Never>?
        var taskToken: String?
        var cancelRequested: Bool
    }

    private var asrOperations: [String: ASROperation] = [:]
    private var ttsOperations: [String: TTSOperation] = [:]
    private var operationOrder: [String] = []
    private var utteranceStaging: [String: UtteranceStaging] = [:]

    /// Real provider dispatch seam. The production initializer uses the
    /// existing `C03CloudASRClient`; tests inject a bounded fake that never
    /// touches a provider or the App cloud.
    private let asrTranscriber:
        @Sendable (C03ResolvedSpeechRoute, C03MediaFile, String?) async throws
            -> C03Transcript
    /// Root-epoch fence. Production reads the one installed composition; the
    /// test initializer supplies a fixed synthetic epoch.
    private let epochFence: @Sendable (UInt64) -> Bool
    /// The only directory this actor may clean. Production resolves the
    /// installed root's `Voice` directory; tests supply their own fixture.
    private let ownedVoiceRoot: @Sendable () -> URL?
    /// The current root epoch, used only by the root-stop admission fence.
    private let currentEpoch: @Sendable () -> UInt64?
    /// RootStop closes new admissions while it drains every owned task and
    /// keeps them closed for that root epoch. A genuinely new epoch reopens
    /// admissions on the next start check; the same retired epoch does not.
    private var acceptsNewWork = true
    private var closedEpoch: UInt64?

    public init() {
        self.asrTranscriber = { route, file, language in
            try await C03CloudASRClient().transcribe(
                route: route, file: file, language: language)
        }
        self.epochFence = { epoch in
            guard epoch > 0,
                  let composition = G02RuntimeComposition.shared.installedComposition
            else { return false }
            return composition.epoch == epoch
        }
        self.ownedVoiceRoot = {
            G02RuntimeComposition.shared.installedComposition?
                .cluster.identity.root.artifactStoreURL
                .appendingPathComponent("Voice", isDirectory: true)
        }
        self.currentEpoch = {
            G02RuntimeComposition.shared.installedComposition?.epoch
        }
    }

    init(
        asrTranscriber: @escaping @Sendable
            (C03ResolvedSpeechRoute, C03MediaFile, String?) async throws
                -> C03Transcript,
        epochFence: @escaping @Sendable (UInt64) -> Bool,
        ownedVoiceRoot: @escaping @Sendable () -> URL?,
        currentEpoch: @escaping @Sendable () -> UInt64? = {
            G02RuntimeComposition.shared.installedComposition?.epoch
        }
    ) {
        self.asrTranscriber = asrTranscriber
        self.epochFence = epochFence
        self.ownedVoiceRoot = ownedVoiceRoot
        self.currentEpoch = currentEpoch
    }

    private func requireEpoch(_ epoch: UInt64) throws {
        guard epoch > 0, epochFence(epoch) else {
            throw C03VoiceError(.coreUnavailable, "rootRetired", retryable: true)
        }
    }

    private func requireAcceptingNewWork() throws {
        if !acceptsNewWork {
            let epoch = currentEpoch()
            if let epoch, epoch > 0, epoch != closedEpoch {
                acceptsNewWork = true
                closedEpoch = nil
            } else {
                throw C03VoiceError(.coreUnavailable, "rootStopping", retryable: true)
            }
        }
    }

    /// Removes only paths that live under the ONE owned `Voice` directory.
    /// A staging/source value can never cause a delete outside that root.
    private func removeOwned(_ url: URL?) {
        Self.removeOwned(url, root: ownedVoiceRoot())
    }

    private nonisolated static func removeOwned(_ url: URL?, root: URL?) {
        guard let url, let root = root?.standardizedFileURL else { return }
        let target = url.standardizedFileURL
        let path = target.path
        guard path == root.path || path.hasPrefix(root.path + "/") else {
            return
        }
        try? FileManager.default.removeItem(at: target)
    }

    private func cleanupStaging(_ operation: ASROperation) {
        let root = operation.voiceRoot ?? ownedVoiceRoot()
        Self.removeOwned(operation.stagingURL, root: root)
        if operation.kind == .utterance {
            Self.removeOwned(operation.sourceURL, root: root)
        }
    }

    private func pruneUtteranceStaging() {
        let cutoff = Date().addingTimeInterval(-10 * 60)
        let expired = utteranceStaging
            .filter { $0.value.createdAt < cutoff }
            .map(\.key)
        for token in expired {
            if let staging = utteranceStaging.removeValue(forKey: token) {
                Self.removeOwned(
                    staging.path, root: staging.voiceRoot ?? ownedVoiceRoot())
            }
        }
    }

    public func capabilities() async throws -> C03SpeechCapabilities {
        try await C03SpeechCatalog.capabilities()
    }

    // MARK: ASR

    public func startTranscription(
        context: C03MediaContext,
        selection: C03VoiceSelection,
        language: String?,
        owner: C03VoiceOwner
    ) async throws -> String {
        try requireAcceptingNewWork()
        guard selection.configured else {
            throw C03VoiceError(.invalidSelection, "providerAndModelRequired")
        }
        let route = try await C03SpeechRouteResolver().resolve(selection)
        try requireAcceptingNewWork()
        let file = try await C03SubtitleService.shared.loadFile(context)
        try requireAcceptingNewWork()
        try requireEpoch(route.epoch)
        guard file.data.count <= Self.maxMediaBytes else {
            throw C03VoiceError(.fileTooLarge, "audioFileTooLarge")
        }
        let id = UUID().uuidString.lowercased()
        let token = UUID().uuidString.lowercased()
        asrOperations[id] = ASROperation(
            status: C03ASRStatus(state: .running, progress: 0, segmentCount: 0),
            transcript: nil,
            context: context,
            kind: .single,
            route: route,
            sourceURL: nil,
            stagingURL: nil,
            chunkCount: 0,
            expectedChunks: 1,
            sourceDuration: file.durationSeconds ?? 0,
            language: language?.nilIfEmpty,
            epoch: route.epoch,
            owner: owner,
            voiceRoot: ownedVoiceRoot(),
            task: nil,
            taskToken: token,
            cancelRequested: false,
            inflightChunk: nil)
        remember(id)
        let transcriber = asrTranscriber
        let task = Task { [weak self] in
            do {
                let transcript = try await transcriber(
                    route, file, language?.nilIfEmpty)
                await self?.finishASR(id, token: token, result: .success(transcript))
            } catch is CancellationError {
                await self?.finishASR(
                    id, token: token,
                    result: .failure(C03VoiceError(.cancelled, "transcriptionCancelled")))
            } catch let error as C03VoiceError {
                await self?.finishASR(id, token: token, result: .failure(error))
            } catch {
                await self?.finishASR(
                    id, token: token,
                    result: .failure(C03VoiceError(.internalFailure, "transcriptionFailed")))
            }
        }
        asrOperations[id]?.task = task
        return id
    }

    // MARK: Bounded long-media plan/chunk/finish

    public func planTranscription(
        context: C03MediaContext,
        selection: C03VoiceSelection,
        language: String?,
        owner: C03VoiceOwner,
        epoch: UInt64
    ) async throws -> C03TranscriptionPlan {
        try requireAcceptingNewWork()
        try requireEpoch(epoch)
        guard selection.configured else {
            throw C03VoiceError(.invalidSelection, "providerAndModelRequired")
        }
        guard !owner.temporary else {
            throw C03VoiceError(.invalidSelection, "temporaryMediaOwnerRefused")
        }
        let route = try await C03SpeechRouteResolver().resolve(selection)
        let descriptor = try await C03SubtitleService.shared.loadDescriptor(context)
        try requireAcceptingNewWork()
        try requireEpoch(epoch)
        guard route.epoch == epoch,
              let composition = G02RuntimeComposition.shared.installedComposition,
              composition.epoch == epoch else {
            throw C03VoiceError(.coreUnavailable, "rootChanged", retryable: true)
        }
        let id = UUID().uuidString.lowercased()
        let staging = composition.cluster.identity.root.artifactStoreURL
            .appendingPathComponent("Voice/ASR", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: true)
        } catch {
            throw C03VoiceError(.writeFailed, "chunkStagingUnavailable", retryable: true)
        }
        let estimated = max(
            1,
            Int(ceil(Double(descriptor.byteSize) / Double(C03VoiceDomain.maxChunkBytes))))
        asrOperations[id] = ASROperation(
            status: C03ASRStatus(state: .running, progress: 0, segmentCount: 0),
            transcript: nil,
            context: context,
            kind: .chunked,
            route: route,
            sourceURL: descriptor.url,
            stagingURL: staging,
            chunkCount: 0,
            expectedChunks: estimated,
            sourceDuration: descriptor.durationSeconds ?? 0,
            language: language?.nilIfEmpty,
            epoch: epoch,
            owner: owner,
            voiceRoot: ownedVoiceRoot(),
            task: nil,
            taskToken: nil,
            cancelRequested: false,
            inflightChunk: nil)
        remember(id)
        return C03TranscriptionPlan(
            operationID: id,
            sourcePath: descriptor.url.path,
            stagingPath: staging.path,
            sourceBytes: descriptor.byteSize,
            durationSeconds: descriptor.durationSeconds ?? 0,
            chunkLimitBytes: C03VoiceDomain.maxChunkBytes,
            estimatedChunks: estimated)
    }

    public func applyChunk(
        operationID: String,
        chunkIndex: Int,
        sourceStart: Double,
        sourceDuration: Double,
        sampleRate: Int,
        channels: Int
    ) async throws -> Int {
        guard var operation = asrOperations[operationID],
              operation.kind == .chunked else {
            throw C03VoiceError(.invalidSelection, "unknownChunkOperation")
        }
        if operation.cancelRequested || operation.status.state == .cancelled {
            throw C03VoiceError(.cancelled, "chunkOperationCancelled")
        }
        guard operation.status.state == .running else {
            if operation.status.state == .failed {
                throw operation.status.failure
                    ?? C03VoiceError(.providerRejected, "chunkOperationFailed")
            }
            throw C03VoiceError(.invalidSelection, "unknownChunkOperation")
        }
        try requireEpoch(operation.epoch)
        // A duplicate of the chunk already in flight must be refused BEFORE
        // it can inspect a file or start a second provider dispatch.
        if operation.inflightChunk != nil {
            throw C03VoiceError(.busy, "chunkAlreadyInflight", retryable: true)
        }
        guard chunkIndex == operation.chunkCount else {
            throw C03VoiceError(.invalidSelection, "chunkOutOfOrder")
        }
        guard sourceStart.isFinite, sourceStart >= 0,
              sourceDuration.isFinite, sourceDuration > 0,
              sourceDuration <= 30.0 * 60.0,
              sampleRate >= 8_000, sampleRate <= 192_000,
              channels >= 1, channels <= 8 else {
            throw C03VoiceError(.invalidSelection, "invalidChunkTiming")
        }
        if operation.sourceDuration > 0,
           sourceStart + sourceDuration > operation.sourceDuration + 1.0 {
            throw C03VoiceError(.invalidSelection, "chunkOutsideSource")
        }
        guard let staging = operation.stagingURL,
              let route = operation.route else {
            throw C03VoiceError(.coreUnavailable, "chunkOperationLost", retryable: false)
        }
        let target = staging.appendingPathComponent(
            String(format: "chunk-%05d.wav", chunkIndex)).standardizedFileURL
        guard target.path.hasPrefix(staging.standardizedFileURL.path + "/") else {
            throw C03VoiceError(.invalidSelection, "chunkPathInvalid")
        }
        let values: URLResourceValues
        do {
            values = try target.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw C03VoiceError(.fileUnreadable, "chunkUnreadable")
        }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 44,
              Int64(size) <= Int64(C03VoiceDomain.maxChunkBytes) else {
            throw C03VoiceError(.fileTooLarge, "chunkSizeInvalid")
        }
        let data: Data
        do {
            data = try Data(contentsOf: target)
        } catch {
            throw C03VoiceError(.fileUnreadable, "chunkReadFailed")
        }
        defer { try? FileManager.default.removeItem(at: target) }
        let file = C03MediaFile(
            data: data,
            filename: String(format: "chunk-%05d.wav", chunkIndex),
            mimeType: "audio/wav",
            durationSeconds: sourceDuration,
            projectRevision: 0,
            assetKind: .audio)

        // Reserve the ONE in-flight token before the first await. It is
        // stored on the operation, so a concurrent duplicate sees it and is
        // rejected without a provider dispatch.
        let token = UUID().uuidString.lowercased()
        let transcriber = asrTranscriber
        let language = operation.language
        let owner = operation.owner
        let epoch = operation.epoch
        let dispatch = Task.detached(priority: .userInitiated) {
            try await transcriber(route, file, language)
        }
        operation.inflightChunk = InflightChunk(
            token: token, index: chunkIndex, task: dispatch)
        asrOperations[operationID] = operation

        let transcript: C03Transcript
        do {
            transcript = try await dispatch.value
        } catch {
            clearInflightChunk(operationID, token: token)
            if let typed = error as? C03VoiceError { throw typed }
            if error is CancellationError {
                throw C03VoiceError(.cancelled, "chunkCancelled")
            }
            throw C03VoiceError(.network, "chunkTransportFailed", retryable: true)
        }

        // Re-read the actor state after the await. A cancelled, failed,
        // superseded, re-rooted or re-owned operation cannot accept this
        // result, and its late callback never mutates the transcript.
        guard var current = asrOperations[operationID],
              current.kind == .chunked else {
            clearInflightChunk(operationID, token: token)
            throw C03VoiceError(.coreUnavailable, "chunkOperationLost", retryable: false)
        }
        if current.cancelRequested || current.status.state == .cancelled {
            clearInflightChunk(operationID, token: token)
            throw C03VoiceError(.cancelled, "chunkSuperseded")
        }
        guard current.inflightChunk?.token == token else {
            clearInflightChunk(operationID, token: token)
            throw C03VoiceError(.coreUnavailable, "chunkOperationLost", retryable: false)
        }
        guard current.epoch == epoch, current.owner == owner else {
            clearInflightChunk(operationID, token: token)
            throw C03VoiceError(.coreUnavailable, "chunkOwnerChanged", retryable: false)
        }
        do {
            try requireEpoch(current.epoch)
        } catch {
            clearInflightChunk(operationID, token: token)
            throw error
        }
        guard !current.cancelRequested,
              current.status.state == .running,
              chunkIndex == current.chunkCount else {
            clearInflightChunk(operationID, token: token)
            throw C03VoiceError(.cancelled, "chunkSuperseded")
        }
        current.inflightChunk = nil
        let shifted = C03ChunkTimeline.shift(
            transcript.segments,
            sourceStart: sourceStart,
            sourceDuration: sourceDuration)
        let merged = C03ChunkTimeline.merge(
            current.transcript?.segments ?? [],
            shifted,
            maxSegments: C03VoiceDomain.maxSegments)
        let combinedText = [
            current.transcript?.text ?? "",
            transcript.text,
        ].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        current.transcript = C03Transcript(
            segments: merged,
            language: transcript.language,
            providerName: transcript.providerName,
            modelDisplayName: transcript.modelDisplayName,
            text: String(combinedText.prefix(200_000)),
            timing: merged.isEmpty ? .textOnly : .providerSegments)
        current.chunkCount += 1
        let estimated = max(1, current.expectedChunks)
        current.status = C03ASRStatus(
            state: .running,
            progress: min(0.99, Double(current.chunkCount) / Double(estimated)),
            segmentCount: merged.count)
        asrOperations[operationID] = current
        return merged.count
    }

    private func clearInflightChunk(_ id: String, token: String) {
        guard var operation = asrOperations[id],
              operation.inflightChunk?.token == token else { return }
        operation.inflightChunk = nil
        asrOperations[id] = operation
    }

    public func finishChunks(
        operationID: String,
        totalChunks: Int,
        sourceDuration: Double
    ) async throws -> Int {
        guard var operation = asrOperations[operationID],
              operation.kind == .chunked else {
            throw C03VoiceError(.invalidSelection, "unknownChunkOperation")
        }
        if operation.cancelRequested || operation.status.state == .cancelled {
            throw C03VoiceError(.cancelled, "chunkOperationCancelled")
        }
        if operation.status.state == .failed {
            throw operation.status.failure
                ?? C03VoiceError(.providerRejected, "chunkOperationFailed")
        }
        try requireEpoch(operation.epoch)
        guard operation.status.state == .running else {
            throw C03VoiceError(.busy, "chunkOperationNotRunning", retryable: true)
        }
        guard operation.inflightChunk == nil else {
            throw C03VoiceError(.busy, "chunkStillInflight", retryable: true)
        }
        guard totalChunks > 0, totalChunks == operation.chunkCount else {
            throw C03VoiceError(.invalidSelection, "chunkSetIncomplete")
        }
        if sourceDuration.isFinite, sourceDuration > 0 {
            operation.sourceDuration = sourceDuration
        }
        let segments = operation.transcript?.segments ?? []
        guard !segments.isEmpty else {
            // Text-only ASR is a valid transcript but not alignment evidence.
            operation.status = C03ASRStatus(
                state: .failed,
                progress: 0,
                segmentCount: 0,
                failure: C03VoiceError(.needsTiming, "providerReturnedNoTiming"))
            asrOperations[operationID] = operation
            cleanupStaging(operation)
            throw C03VoiceError(.needsTiming, "providerReturnedNoTiming")
        }
        operation.status = C03ASRStatus(
            state: .completed, progress: 1, segmentCount: segments.count)
        asrOperations[operationID] = operation
        cleanupStaging(operation)
        return segments.count
    }

    // MARK: Finite cloud microphone utterance

    public func beginUtterance(
        owner: C03VoiceOwner,
        epoch: UInt64,
        maxDurationSeconds: Int = 60
    ) async throws -> C03UtteranceStagingPlan {
        try requireAcceptingNewWork()
        try requireEpoch(epoch)
        guard !owner.temporary else {
            throw C03VoiceError(.invalidSelection, "cloudInputUnavailableInTemporaryChat")
        }
        guard owner.conversationID != nil || owner.taskID != nil else {
            throw C03VoiceError(.invalidSelection, "voiceOwnerRequired")
        }
        guard let composition = G02RuntimeComposition.shared.installedComposition else {
            throw C03VoiceError(.coreUnavailable, "runtimeNotInstalled", retryable: true)
        }
        guard composition.epoch == epoch else {
            throw C03VoiceError(.coreUnavailable, "rootChanged", retryable: true)
        }
        let root = composition.cluster.identity.root.artifactStoreURL
            .appendingPathComponent("Voice/Utterances", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw C03VoiceError(.writeFailed, "utteranceStagingUnavailable", retryable: true)
        }
        pruneUtteranceStaging()
        try requireAcceptingNewWork()
        let token = UUID().uuidString.lowercased()
        let path = root.appendingPathComponent("utterance-\(token).wav")
        utteranceStaging[token] = UtteranceStaging(
            path: path, owner: owner, epoch: epoch, createdAt: Date(),
            voiceRoot: ownedVoiceRoot())
        return C03UtteranceStagingPlan(
            pathToken: token,
            path: path.path,
            maxDurationSeconds: min(max(5, maxDurationSeconds), 60))
    }

    public func startUtterance(
        pathToken: String,
        path: String,
        selection: C03VoiceSelection,
        language: String?,
        owner: C03VoiceOwner,
        epoch: UInt64
    ) async throws -> String {
        try requireAcceptingNewWork()
        try requireEpoch(epoch)
        guard !owner.temporary,
              owner.conversationID != nil || owner.taskID != nil else {
            throw C03VoiceError(.invalidSelection, "cloudInputUnavailableInTemporaryChat")
        }
        guard selection.configured else {
            throw C03VoiceError(.invalidSelection, "providerAndModelRequired")
        }
        guard let staging = utteranceStaging[pathToken],
              staging.owner == owner,
              staging.epoch == epoch,
              staging.path.path == path else {
            throw C03VoiceError(.invalidSelection, "utteranceStagingExpired")
        }
        utteranceStaging.removeValue(forKey: pathToken)
        let target = URL(fileURLWithPath: path).standardizedFileURL
        guard target.path.hasPrefix(staging.path.deletingLastPathComponent().path + "/") else {
            throw C03VoiceError(.invalidSelection, "utterancePathInvalid")
        }
        let values: URLResourceValues
        do {
            values = try target.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        } catch {
            throw C03VoiceError(.fileUnreadable, "utteranceUnreadable")
        }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 44,
              Int64(size) <= Int64(C03VoiceDomain.maxUtteranceBytes) else {
            throw C03VoiceError(.fileTooLarge, "utteranceSizeInvalid")
        }
        let data: Data
        do {
            data = try Data(contentsOf: target)
        } catch {
            throw C03VoiceError(.fileUnreadable, "utteranceReadFailed")
        }
        let ownedRoot = ownedVoiceRoot()
        let route: C03ResolvedSpeechRoute
        do {
            route = try await C03SpeechRouteResolver().resolve(selection)
            try requireAcceptingNewWork()
            try requireEpoch(epoch)
            guard route.epoch == epoch else {
                throw C03VoiceError(.coreUnavailable, "rootChanged", retryable: true)
            }
        } catch {
            Self.removeOwned(target, root: ownedRoot)
            throw error
        }
        let id = UUID().uuidString.lowercased()
        let token = UUID().uuidString.lowercased()
        let file = C03MediaFile(
            data: data,
            filename: "utterance.wav",
            mimeType: "audio/wav",
            durationSeconds: nil,
            projectRevision: 0,
            assetKind: .audio)
        asrOperations[id] = ASROperation(
            status: C03ASRStatus(state: .running, progress: 0, segmentCount: 0),
            transcript: nil,
            context: nil,
            kind: .utterance,
            route: route,
            sourceURL: target,
            stagingURL: nil,
            chunkCount: 1,
            expectedChunks: 1,
            sourceDuration: 0,
            language: language?.nilIfEmpty,
            epoch: epoch,
            owner: owner,
            voiceRoot: ownedRoot,
            task: nil,
            taskToken: token,
            cancelRequested: false,
            inflightChunk: nil)
        remember(id)
        let transcriber = asrTranscriber
        let task = Task { [weak self] in
            defer { C03VoiceDomain.removeOwned(target, root: ownedRoot) }
            do {
                let transcript = try await transcriber(
                    route, file, language?.nilIfEmpty)
                await self?.finishASR(id, token: token, result: .success(transcript))
            } catch is CancellationError {
                await self?.finishASR(
                    id, token: token,
                    result: .failure(C03VoiceError(.cancelled, "utteranceCancelled")))
            } catch let error as C03VoiceError {
                await self?.finishASR(id, token: token, result: .failure(error))
            } catch {
                await self?.finishASR(
                    id, token: token,
                    result: .failure(C03VoiceError(.internalFailure, "utteranceFailed")))
            }
        }
        asrOperations[id]?.task = task
        return id
    }

    public func asrText(_ id: String) throws -> String {
        guard let operation = asrOperations[id] else {
            throw C03VoiceError(.invalidSelection, "unknownOperation")
        }
        if operation.cancelRequested || operation.status.state == .cancelled {
            throw C03VoiceError(.cancelled, "operationCancelled")
        }
        if operation.status.state == .failed {
            throw operation.status.failure
                ?? C03VoiceError(.providerRejected, "transcriptionFailed")
        }
        guard operation.status.state == .completed else {
            throw C03VoiceError(.busy, "transcriptionNotCompleted", retryable: true)
        }
        return operation.transcript?.text ?? ""
    }

    public func asrStatus(_ id: String) throws -> C03ASRStatus {
        guard let operation = asrOperations[id] else {
            throw C03VoiceError(.invalidSelection, "unknownOperation")
        }
        return operation.status
    }

    public func asrPage(
        _ id: String,
        offset: Int,
        limit: Int
    ) throws -> (segments: [C03TimedSegment], nextOffset: Int, total: Int) {
        guard let operation = asrOperations[id] else {
            throw C03VoiceError(.invalidSelection, "unknownOperation")
        }
        if operation.cancelRequested || operation.status.state == .cancelled {
            throw C03VoiceError(.cancelled, "operationCancelled")
        }
        if operation.status.state == .failed {
            throw operation.status.failure
                ?? C03VoiceError(.providerRejected, "transcriptionFailed")
        }
        guard let transcript = operation.transcript else {
            if operation.status.state == .running {
                return ([], max(0, offset), 0)
            }
            throw C03VoiceError(.emptyTranscript, "noTranscript")
        }
        let safeOffset = min(max(0, offset), transcript.segments.count)
        let safeLimit = min(max(1, limit), 200)
        let end = min(safeOffset + safeLimit, transcript.segments.count)
        let page = Array(transcript.segments[safeOffset..<end])
        return (page, end, transcript.segments.count)
    }

    /// Requests cancellation and waits for the real provider task to settle.
    /// The state is NOT reported as completed/cancelled merely because
    /// `Task.cancel()` was called: the operation keeps ownership, the
    /// transcript is dropped immediately, and staging is removed only after
    /// the task has actually drained. A bridge timeout therefore leaves an
    /// honest pending operation owned here rather than a fake terminal state.
    public func cancelTranscription(_ id: String) async {
        guard var operation = asrOperations[id] else { return }
        operation.cancelRequested = true
        operation.transcript = nil
        let task = operation.task
        let inflight = operation.inflightChunk?.task
        operation.task?.cancel()
        operation.inflightChunk?.task.cancel()
        // Keep `.running` until settlement. `asrText`/`asrPage` already
        // refuse a cancel-requested operation, so no partial result leaks.
        asrOperations[id] = operation

        if let task { await task.value }
        if let inflight { _ = try? await inflight.value }

        guard var drained = asrOperations[id] else { return }
        drained.task = nil
        drained.taskToken = nil
        drained.inflightChunk = nil
        drained.transcript = nil
        cleanupStaging(drained)
        drained.sourceURL = nil
        drained.stagingURL = nil
        drained.status = C03ASRStatus(
            state: .cancelled, progress: 0,
            segmentCount: 0,
            failure: C03VoiceError(.cancelled, "transcriptionCancelled"))
        asrOperations[id] = drained
    }

    public func writeSubtitles(
        operationID: String,
        expectedRevision: Int64,
        replaceTranscribed: Bool,
        opID: String
    ) async throws -> C03SubtitleReceipt {
        guard let operation = asrOperations[operationID] else {
            throw C03VoiceError(.invalidSelection, "unknownOperation")
        }
        guard !operation.cancelRequested,
              operation.status.state == .completed,
              let transcript = operation.transcript,
              let context = operation.context else {
            throw C03VoiceError(.busy, "transcriptionNotCompleted")
        }
        try requireEpoch(operation.epoch)
        return try await C03SubtitleService.shared.write(
            context,
            transcript: transcript,
            expectedRevision: expectedRevision,
            replaceTranscribed: replaceTranscribed,
            opID: opID)
    }

    private func finishASR(
        _ id: String,
        token: String,
        result: Result<C03Transcript, C03VoiceError>
    ) {
        guard var operation = asrOperations[id],
              operation.taskToken == token else {
            // A superseded/removed task's late result is dropped. Success
            // audio/file cleanup happens through the task's own defer and
            // the operation's owned staging cleanup; no transcript is kept.
            return
        }
        operation.task = nil
        operation.taskToken = nil
        let cancelled = operation.cancelRequested
            || operation.status.state == .cancelled
        let rootLost = !epochFence(operation.epoch)
        if cancelled || rootLost || operation.status.state != .running {
            operation.transcript = nil
            operation.status = C03ASRStatus(
                state: .cancelled, progress: 0, segmentCount: 0,
                failure: C03VoiceError(
                    rootLost
                        ? C03VoiceErrorCode.coreUnavailable
                        : C03VoiceErrorCode.cancelled,
                    rootLost ? "rootChanged" : "transcriptionCancelled",
                    retryable: rootLost))
            asrOperations[id] = operation
            cleanupStaging(operation)
            return
        }
        switch result {
        case .success(let transcript):
            operation.transcript = transcript
            operation.status = C03ASRStatus(
                state: .completed, progress: 1,
                segmentCount: transcript.segments.count,
                failure: nil)
            asrOperations[id] = operation
            // The utterance source is owned by this operation and is no
            // longer needed once the provider result is admitted.
            if operation.kind == .utterance {
                cleanupStaging(operation)
            }
        case .failure(let error):
            operation.transcript = nil
            operation.status = C03ASRStatus(
                state: error.code == .cancelled ? .cancelled : .failed,
                progress: 0, segmentCount: 0, failure: error)
            asrOperations[id] = operation
            cleanupStaging(operation)
        }
    }

    // MARK: TTS

    public func startSynthesis(
        text: String,
        selection: C03VoiceSelection,
        owner: C03VoiceOwner
    ) async throws -> String {
        guard selection.configured else {
            throw C03VoiceError(.invalidSelection, "providerAndModelRequired")
        }
        guard let voiceID = selection.voiceID?.nilIfEmpty else {
            throw C03VoiceError(.invalidSelection, "voiceIDRequired")
        }
        _ = owner
        try requireAcceptingNewWork()
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty, cleanText.count <= Self.maxTextCharacters else {
            throw C03VoiceError(.invalidSelection, "textInvalid")
        }
        guard let composition = G02RuntimeComposition.shared.installedComposition,
              composition.epoch > 0 else {
            throw C03VoiceError(.coreUnavailable, "runtimeNotInstalled", retryable: true)
        }
        let route = try await C03SpeechRouteResolver().resolve(selection)
        try requireAcceptingNewWork()
        try requireEpoch(route.epoch)
        guard route.epoch == composition.epoch else {
            throw C03VoiceError(.coreUnavailable, "rootChanged", retryable: true)
        }
        let id = UUID().uuidString.lowercased()
        let token = UUID().uuidString.lowercased()
        let directory = composition.cluster.identity.root.artifactStoreURL
            .appendingPathComponent("Voice/TTS", isDirectory: true)
        let outputURL = directory.appendingPathComponent("\(id).wav")
        ttsOperations[id] = TTSOperation(
            status: C03TTSStatus(
                state: .running, progress: 0, audioPath: nil,
                sampleRate: Self.ttsSampleRate, durationSeconds: nil),
            outputURL: outputURL,
            epoch: route.epoch,
            voiceRoot: ownedVoiceRoot(),
            task: nil,
            taskToken: token,
            cancelRequested: false)
        remember(id)
        let ownedRoot = ownedVoiceRoot()
        let task = Task { [weak self] in
            do {
                let audio = try await C03CloudTTSClient().synthesize(
                    route: route,
                    text: cleanText,
                    voiceID: voiceID,
                    rate: selection.rate,
                    outputURL: outputURL)
                await self?.finishTTS(
                    id, token: token, voiceRoot: ownedRoot,
                    result: .success(audio))
            } catch is CancellationError {
                C03VoiceDomain.removeOwned(outputURL, root: ownedRoot)
                await self?.finishTTS(
                    id, token: token, voiceRoot: ownedRoot,
                    result: .failure(C03VoiceError(.cancelled, "synthesisCancelled")))
            } catch let error as C03VoiceError {
                C03VoiceDomain.removeOwned(outputURL, root: ownedRoot)
                await self?.finishTTS(
                    id, token: token, voiceRoot: ownedRoot,
                    result: .failure(error))
            } catch {
                C03VoiceDomain.removeOwned(outputURL, root: ownedRoot)
                await self?.finishTTS(
                    id, token: token, voiceRoot: ownedRoot,
                    result: .failure(C03VoiceError(.internalFailure, "synthesisFailed")))
            }
        }
        ttsOperations[id]?.task = task
        return id
    }

    public func ttsStatus(_ id: String) throws -> C03TTSStatus {
        guard let operation = ttsOperations[id] else {
            throw C03VoiceError(.invalidSelection, "unknownOperation")
        }
        return operation.status
    }

    public func cancelSynthesis(_ id: String) async {
        guard var operation = ttsOperations[id] else { return }
        operation.cancelRequested = true
        let task = operation.task
        operation.task?.cancel()
        ttsOperations[id] = operation
        if let task { await task.value }
        guard var drained = ttsOperations[id] else { return }
        drained.task = nil
        drained.taskToken = nil
        Self.removeOwned(
            drained.outputURL, root: drained.voiceRoot ?? ownedVoiceRoot())
        drained.status = C03TTSStatus(
            state: .cancelled, progress: 0, audioPath: nil,
            sampleRate: Self.ttsSampleRate, durationSeconds: nil,
            failure: C03VoiceError(.cancelled, "synthesisCancelled"))
        ttsOperations[id] = drained
    }

    public func releaseSynthesis(_ id: String) async {
        guard var operation = ttsOperations[id] else { return }
        operation.cancelRequested = true
        let task = operation.task
        operation.task?.cancel()
        ttsOperations[id] = operation
        if let task { await task.value }
        let removed = ttsOperations.removeValue(forKey: id)
        Self.removeOwned(
            removed?.outputURL ?? operation.outputURL,
            root: removed?.voiceRoot ?? operation.voiceRoot ?? ownedVoiceRoot())
    }

    private func finishTTS(
        _ id: String,
        token: String,
        voiceRoot: URL?,
        result: Result<C03SynthesizedAudio, C03VoiceError>
    ) {
        guard var operation = ttsOperations[id],
              operation.taskToken == token else {
            if case .success(let audio) = result {
                Self.removeOwned(audio.fileURL, root: voiceRoot ?? ownedVoiceRoot())
            }
            return
        }
        operation.task = nil
        operation.taskToken = nil
        let rootLost = !epochFence(operation.epoch)
        if operation.cancelRequested || rootLost
            || operation.status.state != .running {
            Self.removeOwned(
                operation.outputURL,
                root: operation.voiceRoot ?? voiceRoot ?? ownedVoiceRoot())
            operation.status = C03TTSStatus(
                state: .cancelled, progress: 0, audioPath: nil,
                sampleRate: Self.ttsSampleRate, durationSeconds: nil,
                failure: C03VoiceError(
                    rootLost
                        ? C03VoiceErrorCode.coreUnavailable
                        : C03VoiceErrorCode.cancelled,
                    rootLost ? "rootChanged" : "synthesisCancelled",
                    retryable: rootLost))
            ttsOperations[id] = operation
            return
        }
        switch result {
        case .success(let audio):
            operation.status = C03TTSStatus(
                state: .completed, progress: 1,
                audioPath: audio.fileURL.path,
                sampleRate: audio.sampleRate,
                durationSeconds: audio.durationSeconds,
                failure: nil)
        case .failure(let error):
            Self.removeOwned(
                operation.outputURL,
                root: operation.voiceRoot ?? voiceRoot ?? ownedVoiceRoot())
            operation.status = C03TTSStatus(
                state: error.code == .cancelled ? .cancelled : .failed,
                progress: 0, audioPath: nil,
                sampleRate: Self.ttsSampleRate, durationSeconds: nil,
                failure: error)
        }
        ttsOperations[id] = operation
    }

    // MARK: Root stop / cancellation

    /// Closes new admissions, requests cancellation of every owned task, and
    /// waits for the REAL tasks to settle before deleting their staging or
    /// dropping ownership. If a provider never settles, this method keeps the
    /// operations and their files; the bridge may time out honestly while the
    /// actor still owns the work. Nothing is marked complete by `cancel()`.
    public func cancelAll() async {
        closedEpoch = currentEpoch()
        acceptsNewWork = false
        let asrIDs = Array(asrOperations.keys)
        let ttsIDs = Array(ttsOperations.keys)
        var asrTasks: [Task<Void, Never>] = []
        var chunkTasks: [Task<C03Transcript, Error>] = []
        var ttsTasks: [Task<Void, Never>] = []

        for id in asrIDs {
            guard var operation = asrOperations[id] else { continue }
            operation.cancelRequested = true
            operation.transcript = nil
            operation.task?.cancel()
            operation.inflightChunk?.task.cancel()
            if let task = operation.task { asrTasks.append(task) }
            if let task = operation.inflightChunk?.task {
                chunkTasks.append(task)
            }
            asrOperations[id] = operation
        }
        for id in ttsIDs {
            guard var operation = ttsOperations[id] else { continue }
            operation.cancelRequested = true
            operation.task?.cancel()
            if let task = operation.task { ttsTasks.append(task) }
            ttsOperations[id] = operation
        }

        for task in asrTasks { await task.value }
        for task in chunkTasks { _ = try? await task.value }
        for task in ttsTasks { await task.value }

        for id in asrIDs {
            guard var operation = asrOperations[id] else { continue }
            operation.task = nil
            operation.taskToken = nil
            operation.inflightChunk = nil
            operation.transcript = nil
            cleanupStaging(operation)
            operation.sourceURL = nil
            operation.stagingURL = nil
            operation.status = C03ASRStatus(
                state: .cancelled, progress: 0, segmentCount: 0,
                failure: C03VoiceError(.cancelled, "transcriptionCancelled"))
            asrOperations[id] = operation
        }
        for id in ttsIDs {
            guard var operation = ttsOperations[id] else { continue }
            operation.task = nil
            operation.taskToken = nil
            Self.removeOwned(
                operation.outputURL,
                root: operation.voiceRoot ?? ownedVoiceRoot())
            operation.status = C03TTSStatus(
                state: .cancelled, progress: 0, audioPath: nil,
                sampleRate: Self.ttsSampleRate, durationSeconds: nil,
                failure: C03VoiceError(.cancelled, "synthesisCancelled"))
            ttsOperations[id] = operation
        }
        for (_, staging) in utteranceStaging {
            Self.removeOwned(
                staging.path, root: staging.voiceRoot ?? ownedVoiceRoot())
        }
        utteranceStaging.removeAll()
        // Remove only the operations captured at entry: a start that raced
        // the admission close is fenced by `requireAcceptingNewWork` and is
        // never swept here without cancellation.
        for id in asrIDs { asrOperations.removeValue(forKey: id) }
        for id in ttsIDs { ttsOperations.removeValue(forKey: id) }
        operationOrder.removeAll { asrIDs.contains($0) || ttsIDs.contains($0) }
    }

    // MARK: Test-only seams (never called by the production bridge)

    func cancelRequestedForTesting(_ id: String) -> Bool {
        asrOperations[id]?.cancelRequested ?? false
    }

    func hasASROperationForTesting(_ id: String) -> Bool {
        asrOperations[id] != nil
    }

    /// Seeds one chunked operation in a synthetic Voice staging root. Used by
    /// source tests; production always creates operations through
    /// `planTranscription`, which validates the real G09 asset.
    @discardableResult
    func installChunkedOperationForTesting(
        epoch: UInt64,
        owner: C03VoiceOwner,
        stagingURL: URL,
        sourceDuration: Double,
        expectedChunks: Int = 1,
        language: String? = nil
    ) -> String {
        let id = UUID().uuidString.lowercased()
        let route = C03ResolvedSpeechRoute(
            providerID: UUID(),
            modelID: UUID(),
            providerName: "fixture",
            remoteModelID: "fixture",
            baseURL: URL(string: "https://fixture.invalid")!,
            credential: "",
            epoch: epoch)
        asrOperations[id] = ASROperation(
            status: C03ASRStatus(state: .running, progress: 0, segmentCount: 0),
            transcript: nil,
            context: nil,
            kind: .chunked,
            route: route,
            sourceURL: nil,
            stagingURL: stagingURL,
            chunkCount: 0,
            expectedChunks: max(1, expectedChunks),
            sourceDuration: sourceDuration,
            language: language,
            epoch: epoch,
            owner: owner,
            voiceRoot: ownedVoiceRoot(),
            task: nil,
            taskToken: nil,
            cancelRequested: false,
            inflightChunk: nil)
        remember(id)
        return id
    }

    private func remember(_ id: String) {
        operationOrder.append(id)
        var index = 0
        while operationOrder.count > 64, index < operationOrder.count {
            let candidate = operationOrder[index]
            if pruneIfSettled(candidate) {
                operationOrder.remove(at: index)
            } else {
                index += 1
            }
        }
    }

    /// Prunes only an operation whose real task has settled. A cancel-requested
    /// operation with a live task/upload remains owned until drain.
    private func pruneIfSettled(_ id: String) -> Bool {
        if var operation = asrOperations[id] {
            guard operation.status.state != .running,
                  operation.task == nil,
                  operation.inflightChunk == nil else { return false }
            cleanupStaging(operation)
            operation.sourceURL = nil
            operation.stagingURL = nil
            asrOperations.removeValue(forKey: id)
            return true
        }
        if let operation = ttsOperations[id] {
            guard operation.task == nil,
                  operation.status.state == .cancelled
                    || operation.status.state == .failed else { return false }
            Self.removeOwned(
                operation.outputURL,
                root: operation.voiceRoot ?? ownedVoiceRoot())
            ttsOperations.removeValue(forKey: id)
            return true
        }
        return true
    }
}

private extension C03OperationState {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .running: return false
        }
    }
}
