// FloeApp — Assistant file transcription and generated-audio services.
//
// SPDX-License-Identifier: MPL-2.0
//
// This service owns the concrete, discoverable services that assistant file
// tools may use. It never invents a capability: a service is listed only when
// its real local model/profile is present, and a selected service that becomes
// unavailable fails honestly instead of falling through to a paid route.
//
// Default policy is automatic: a ready local service first, then an explicitly
// configured cloud service, then the system voice/recognizer. A failure or a
// user cancellation of the selected service NEVER switches provider. The
// ordinary read-aloud selection is not changed here.

#if canImport(UIKit)
import Foundation
import AVFoundation
import Speech
import Combine
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
import FloeTools

enum AssistantAudioCapability: String, Codable, Sendable, Hashable {
    case transcription
    case synthesis
}

struct AssistantAudioServiceDescriptor: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let capability: AssistantAudioCapability
    let title: String
    let provider: String
    let local: Bool
    let ready: Bool
    let detail: String?
    let requiresCredential: Bool
    let requiresAuthorization: Bool

    init(
        id: String,
        capability: AssistantAudioCapability,
        title: String,
        provider: String,
        local: Bool,
        ready: Bool,
        detail: String? = nil,
        requiresCredential: Bool,
        requiresAuthorization: Bool = false
    ) {
        self.id = id
        self.capability = capability
        self.title = title
        self.provider = provider
        self.local = local
        self.ready = ready
        self.detail = detail
        self.requiresCredential = requiresCredential
        self.requiresAuthorization = requiresAuthorization
    }
}

struct AssistantAudioPreferences: Codable, Sendable, Equatable {
    static let defaultASRModelID = "whisper-1"
    /// Ordered ready-service priority for automatic selection. An empty array
    /// means the deterministic default (ready local, configured cloud, then
    /// system). Explicit tool `service` arguments bypass this list.
    var transcriptionPriority: [String]
    var synthesisPriority: [String]
    /// Canonical OpenAI-compatible base, or nil for the official endpoint.
    var asrBaseURL: String?
    var asrModelID: String

    init(
        transcriptionPriority: [String] = [],
        synthesisPriority: [String] = [],
        asrBaseURL: String? = nil,
        asrModelID: String = defaultASRModelID
    ) {
        self.transcriptionPriority = Self.deduplicated(transcriptionPriority)
        self.synthesisPriority = Self.deduplicated(synthesisPriority)
        self.asrBaseURL = asrBaseURL
        self.asrModelID = asrModelID
    }

    private enum CodingKeys: String, CodingKey {
        case transcriptionPriority, synthesisPriority
        case transcriptionServiceID, synthesisServiceID
        case asrBaseURL, asrModelID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Migration: the first per-tool version stored ONE explicit service
        // preference. Keep that identity as the first priority entry instead
        // of silently dropping it or substituting another provider.
        if container.contains(.transcriptionPriority) {
            transcriptionPriority = Self.deduplicated(
                (try? container.decode([String].self, forKey: .transcriptionPriority)) ?? [])
        } else {
            let legacy = try container.decodeIfPresent(String.self, forKey: .transcriptionServiceID)
            transcriptionPriority = legacy.flatMap(Self.nonEmpty).map { [$0] } ?? []
        }
        if container.contains(.synthesisPriority) {
            synthesisPriority = Self.deduplicated(
                (try? container.decode([String].self, forKey: .synthesisPriority)) ?? [])
        } else {
            let legacy = try container.decodeIfPresent(String.self, forKey: .synthesisServiceID)
            synthesisPriority = legacy.flatMap(Self.nonEmpty).map { [$0] } ?? []
        }
        asrBaseURL = try container.decodeIfPresent(String.self, forKey: .asrBaseURL)
        asrModelID = try container.decodeIfPresent(String.self, forKey: .asrModelID)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? Self.defaultASRModelID
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcriptionPriority, forKey: .transcriptionPriority)
        try container.encode(synthesisPriority, forKey: .synthesisPriority)
        try container.encodeIfPresent(asrBaseURL, forKey: .asrBaseURL)
        try container.encode(asrModelID, forKey: .asrModelID)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let value = nonEmpty(value), seen.insert(value).inserted else { return nil }
            return value
        }
    }
}

enum AssistantAudioError: Error, LocalizedError, Equatable {
    case serviceUnavailable(String)
    case noReadyService(AssistantAudioCapability)
    case invalidConfiguration(String)
    case credentialMissing
    case credentialChangedRequiresNewKey
    case textEmpty
    case textTooLong(Int)
    case audioTooLong
    case emptyAudio
    case unsupportedOutputFormat(String)
    case outputExists
    case outputUnavailable
    case temporaryWriteRefused
    case timedOutputUnavailable
    case transcriptionUnavailable
    case transcriptionFailed
    case synthesisFailed

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable(let id):
            return "The selected audio service is not available: \(id). Choose another ready service in Voice settings."
        case .noReadyService(let capability):
            return capability == .transcription
                ? "No ready file-transcription service is configured. Install the recognition model or configure a cloud transcription service."
                : "No ready audio-generation service is configured. Install a local voice or configure a cloud voice."
        case .invalidConfiguration(let reason):
            return "Audio service configuration is invalid: \(reason)"
        case .credentialMissing:
            return "The selected cloud service has no credential."
        case .credentialChangedRequiresNewKey:
            return "The transcription endpoint changed. Enter the key for the new endpoint."
        case .textEmpty:
            return "Text is empty."
        case .textTooLong(let limit):
            return "Text is too long for one audio file (maximum \(limit) characters)."
        case .audioTooLong:
            return "Generated audio exceeded the bounded file limit."
        case .emptyAudio:
            return "The service returned no audio."
        case .unsupportedOutputFormat(let value):
            return "Unsupported audio output format: \(value). Use wav, m4a, caf or aiff."
        case .outputExists:
            return "The output file already exists; choose a new filename."
        case .outputUnavailable:
            return "The output location is unavailable."
        case .temporaryWriteRefused:
            return "Temporary chat cannot generate or write audio files."
        case .timedOutputUnavailable:
            return "The service returned no segment timing, so SRT/VTT output is unavailable."
        case .transcriptionUnavailable:
            return "The selected transcription service is not ready."
        case .transcriptionFailed:
            return "Transcription failed."
        case .synthesisFailed:
            return "Speech synthesis failed."
        }
    }
}

struct AssistantAudioTranscriptionResult: Sendable {
    let text: String
    let segments: [TimedSpeechSegment]
    let service: AssistantAudioServiceDescriptor
    let engine: String
    let language: String?
}

struct AssistantAudioSynthesisResult: Sendable {
    let outputURL: URL
    let byteCount: Int
    let sha256: String
    let duration: Double
    let sampleRate: Int
    let mimeType: String
    let uti: String?
    let service: AssistantAudioServiceDescriptor
    let inlineArtifact: ToolArtifactReference?
}

@MainActor
final class AssistantAudioService: ObservableObject {
    enum ID {
        static let transcriptionEnhanced = "asr.local.enhanced"
        static let transcriptionSystem = "asr.local.system"
        static let transcriptionCloud = "asr.cloud.openai-compatible"

        static func synthesis(_ source: SpeechOutputSource) -> String {
            "tts." + source.id
        }
    }

    nonisolated static let maximumTextCharacters = 12_000
    nonisolated static let maximumAudioBytes = 16 * 1024 * 1024
    nonisolated static let maximumTranscriptionBytes = OpenAITranscriptionAdapter.maximumAudioBytes

    @Published private(set) var preferences: AssistantAudioPreferences
    @Published private(set) var services: [AssistantAudioServiceDescriptor] = []
    @Published private(set) var asrCredentialConfigured = false
    @Published private(set) var lastRefreshError: String?

    private let settings: TTSSettingsService
    private let speech: TTSSpeechService
    private let asrAdapter: any ASRTranscribing
    private let keychain: any KeychainProbeStore
    private let defaults: UserDefaults
    private var sourceByID: [String: SpeechOutputSource] = [:]
    private static let storageKey = "voice.assistantAudio.v1"
    private static let asrAccount = "asr.openai-compatible.payAsYouGo"

    init(
        settings: TTSSettingsService,
        speech: TTSSpeechService,
        defaults: UserDefaults = .standard,
        keychain: any KeychainProbeStore = KeychainStore(
            service: "org.floeagent.ios.assistant-audio", synchronizable: false),
        asrAdapter: any ASRTranscribing = OpenAITranscriptionAdapter()
    ) {
        self.settings = settings
        self.speech = speech
        self.defaults = defaults
        self.keychain = keychain
        self.asrAdapter = asrAdapter
        self.preferences = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(AssistantAudioPreferences.self, from: $0) }
            ?? AssistantAudioPreferences()
        Task { [weak self] in await self?.refreshAvailability() }
    }

    var transcriptionServices: [AssistantAudioServiceDescriptor] {
        services.filter { $0.capability == .transcription && $0.ready }
    }

    var synthesisServices: [AssistantAudioServiceDescriptor] {
        services.filter { $0.capability == .synthesis && $0.ready }
    }

    var hasASRProfile: Bool {
        asrCredentialConfigured && asrValidationProblem == nil
            && !preferences.asrModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var asrValidationProblem: String? {
        guard let raw = preferences.asrBaseURL, !raw.isEmpty else { return nil }
        return OpenAITranscriptionEndpoint.validationProblem(for: raw)
    }

    func service(id: String?, for capability: AssistantAudioCapability) -> AssistantAudioServiceDescriptor? {
        guard let id, !id.isEmpty else {
            return automaticService(for: capability)
        }
        return services.first { $0.id == id && $0.capability == capability && $0.ready }
    }

    func selectionTitle(for capability: AssistantAudioCapability) -> String {
        guard let id = priorityIDs(for: capability).first else { return FloeL10n.l("voice.assistant.automatic") }
        return services.first(where: { $0.id == id })?.title ?? FloeL10n.l("voice.assistant.unavailable")
    }

    /// Saved priority order (may contain currently unavailable IDs; those are
    /// retained so a temporarily missing model/credential does not erase the
    /// user's identity or reorder the rest).
    func priorityIDs(for capability: AssistantAudioCapability) -> [String] {
        switch capability {
        case .transcription: return preferences.transcriptionPriority
        case .synthesis: return preferences.synthesisPriority
        }
    }

    /// Ready services in the user's saved order, with any newly ready service
    /// appended in the deterministic default order (local, cloud, system).
    func orderedServices(for capability: AssistantAudioCapability) -> [AssistantAudioServiceDescriptor] {
        let ready = services.filter { $0.capability == capability && $0.ready }
        let byID = Dictionary(uniqueKeysWithValues: ready.map { ($0.id, $0) })
        let priority = priorityIDs(for: capability)
        var result = priority.compactMap { byID[$0] }
        let seen = Set(result.map(\.id))
        result.append(contentsOf: ready
            .filter { !seen.contains($0.id) }
            .sorted {
                let left = Self.automaticRank($0), right = Self.automaticRank($1)
                if left != right { return left < right }
                return $0.title < $1.title
            })
        return result
    }

    /// Persist a reordered ready-service list. Saved IDs that are not currently
    /// ready are retained after the visible ready order (automatic selection
    /// skips them) so an offline/removed service never silently loses identity.
    func setPriority(
        _ orderedReadyIDs: [String],
        for capability: AssistantAudioCapability,
        preservingUnavailable: Bool = true
    ) {
        let existing = priorityIDs(for: capability)
        let ordered = orderedReadyIDs.filter { !$0.isEmpty }
        let readySet = Set(services
            .filter { $0.capability == capability && $0.ready }
            .map(\.id))
        let unavailable = preservingUnavailable
            ? existing.filter { !readySet.contains($0) }
            : []
        let extraReady = preservingUnavailable
            ? existing.filter { readySet.contains($0) && !ordered.contains($0) }
            : []
        // Keep the visible reordered ready order authoritative. Unavailable
        // saved identities move to the end only when the user explicitly
        // reorders; a legacy single preference with no reorder stays first and
        // is restored to its original position when it becomes ready.
        let priority = ordered + extraReady + unavailable
        let values = AssistantAudioPreferences(
            transcriptionPriority: capability == .transcription ? priority : preferences.transcriptionPriority,
            synthesisPriority: capability == .synthesis ? priority : preferences.synthesisPriority,
            asrBaseURL: preferences.asrBaseURL,
            asrModelID: preferences.asrModelID)
        preferences = values
        persist()
    }

    func hasUnavailablePriority(for capability: AssistantAudioCapability) -> Bool {
        let ready = Set(services.filter { $0.capability == capability && $0.ready }.map(\.id))
        return priorityIDs(for: capability).contains { !ready.contains($0) }
    }

    func refresh() async { await refreshAvailability() }

    func refreshAvailability() async {
        let enhancedInstalled = await WhisperModelStore.shared.isInstalled()
        let systemRecognizer = SFSpeechRecognizer(locale: Locale.current)
        let authorization = SFSpeechRecognizer.authorizationStatus()
        let systemAvailable = systemRecognizer?.isAvailable == true
            && authorization != .denied && authorization != .restricted
        let systemAuthorized = authorization == .authorized
        asrCredentialConfigured = hasASRCredential

        var next: [AssistantAudioServiceDescriptor] = []
        var nextSources: [String: SpeechOutputSource] = [:]

        if enhancedInstalled {
            next.append(AssistantAudioServiceDescriptor(
                id: ID.transcriptionEnhanced,
                capability: .transcription,
                title: "On-device recognition",
                provider: "whisper",
                local: true,
                ready: true,
                detail: "Enhanced file model · no upload",
                requiresCredential: false))
        }
        if hasASRProfile {
            next.append(AssistantAudioServiceDescriptor(
                id: ID.transcriptionCloud,
                capability: .transcription,
                title: "Cloud transcription",
                provider: "openai-compatible",
                local: false,
                ready: true,
                detail: "\(preferences.asrModelID) · sends the audio to the configured service",
                requiresCredential: true))
        }
        if systemAvailable {
            next.append(AssistantAudioServiceDescriptor(
                id: ID.transcriptionSystem,
                capability: .transcription,
                title: "System recognition",
                provider: "apple",
                local: true,
                ready: true,
                detail: systemAuthorized
                    ? "Uses Apple speech on this device"
                    : "May ask for Speech Recognition permission",
                requiresCredential: false,
                requiresAuthorization: !systemAuthorized))
        }

        for source in settings.outputSources {
            guard let snapshot = settings.assistantSnapshot(for: source) else { continue }
            let id = ID.synthesis(source)
            let local = !snapshot.provider.requiresCloudCredential
            let detail: String?
            if source == .system {
                detail = "Built-in system voice"
            } else if snapshot.provider == .onDevice,
                      settings.localModelDescriptor(snapshot.modelID)?.engine == MossSpeechPreparation.mossEngine {
                detail = "On-device model · no upload"
            } else if snapshot.provider == .onDevice {
                detail = "On-device voice · no upload"
            } else {
                detail = "Configured cloud voice"
            }
            next.append(AssistantAudioServiceDescriptor(
                id: id,
                capability: .synthesis,
                title: settings.outputSourceTitle(for: source),
                provider: snapshot.provider.rawValue,
                local: local,
                ready: true,
                detail: detail,
                requiresCredential: snapshot.provider.requiresCloudCredential))
            nextSources[id] = source
        }

        next.sort { left, right in
            if left.capability != right.capability {
                return left.capability.rawValue < right.capability.rawValue
            }
            let lr = Self.automaticRank(left), rr = Self.automaticRank(right)
            if lr != rr { return lr < rr }
            return left.title < right.title
        }
        services = next
        sourceByID = nextSources
        lastRefreshError = next.isEmpty ? "No audio service is ready" : nil
    }

    // MARK: - Transcription

    func transcribe(
        fileURL: URL,
        language: VoiceRecognitionLanguage,
        serviceID: String? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> AssistantAudioTranscriptionResult {
        await refreshAvailability()
        try Task.checkCancellation()
        let requested = serviceID
        guard let descriptor = service(id: requested, for: .transcription) else {
            if let requested, !requested.isEmpty {
                throw AssistantAudioError.serviceUnavailable(requested)
            }
            throw AssistantAudioError.noReadyService(.transcription)
        }
        switch descriptor.id {
        case ID.transcriptionEnhanced:
            let result: FileSpeechResult
            do {
                result = try await FileSpeechTranscriber.shared.transcribeResult(
                    url: fileURL,
                    language: language,
                    allowAppleFallback: false,
                    preferApple: false,
                    progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AssistantAudioError.transcriptionFailed
            }
            return AssistantAudioTranscriptionResult(
                text: SpeechCaptionExport.plainText(segments: result.segments),
                segments: result.segments,
                service: descriptor,
                engine: result.engine.rawValue,
                language: language.recognitionCode)
        case ID.transcriptionSystem:
            let result: FileSpeechResult
            do {
                result = try await FileSpeechTranscriber.shared.transcribeResult(
                    url: fileURL,
                    language: language,
                    allowAppleFallback: true,
                    preferApple: true,
                    progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AssistantAudioError.transcriptionFailed
            }
            return AssistantAudioTranscriptionResult(
                text: SpeechCaptionExport.plainText(segments: result.segments),
                segments: result.segments,
                service: descriptor,
                engine: result.engine.rawValue,
                language: language.recognitionCode)
        case ID.transcriptionCloud:
            return try await transcribeCloud(
                fileURL: fileURL, language: language, descriptor: descriptor)
        default:
            throw AssistantAudioError.serviceUnavailable(descriptor.id)
        }
    }

    private func transcribeCloud(
        fileURL: URL,
        language: VoiceRecognitionLanguage,
        descriptor: AssistantAudioServiceDescriptor
    ) async throws -> AssistantAudioTranscriptionResult {
        guard hasASRProfile else { throw AssistantAudioError.transcriptionUnavailable }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= Self.maximumTranscriptionBytes else {
            throw AssistantAudioError.invalidConfiguration("audio must be between 1 byte and 25 MiB")
        }
        let audio: Data
        do {
            audio = try await Self.detached {
                try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AssistantAudioError.transcriptionFailed
        }
        guard audio.count <= Self.maximumTranscriptionBytes else {
            throw AssistantAudioError.invalidConfiguration("audio exceeds the 25 MiB transcription limit")
        }
        let duration = await Self.mediaDuration(fileURL)
        let request = ASRTranscriptionRequest(
            endpointBaseURL: preferences.asrBaseURL,
            modelID: preferences.asrModelID,
            language: language.recognitionCode,
            filename: fileURL.lastPathComponent,
            mimeType: Self.mimeType(for: fileURL.pathExtension),
            audio: audio,
            durationSeconds: duration)
        let credential = try asrCredential()
        let result: ASRTranscriptionResult
        do {
            result = try await asrAdapter.transcribe(request, credential: credential)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ASRTranscriptionError {
            throw Self.mapASRError(error)
        } catch {
            throw AssistantAudioError.transcriptionFailed
        }
        let segments = result.segments.map {
            TimedSpeechSegment(start: $0.start, end: $0.end, text: $0.text, words: [])
        }
        return AssistantAudioTranscriptionResult(
            text: result.text,
            segments: segments,
            service: descriptor,
            engine: "cloud",
            language: result.language ?? language.recognitionCode)
    }

    // MARK: - Synthesis

    func synthesize(
        text: String,
        outputURL: URL,
        serviceID: String? = nil,
        runID: UUID? = nil
    ) async throws -> AssistantAudioSynthesisResult {
        await refreshAvailability()
        try Task.checkCancellation()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AssistantAudioError.textEmpty }
        guard text.count <= Self.maximumTextCharacters else {
            throw AssistantAudioError.textTooLong(Self.maximumTextCharacters)
        }
        let requestedService = serviceID
        guard let descriptor = service(id: requestedService, for: .synthesis) else {
            if let requestedService, !requestedService.isEmpty {
                throw AssistantAudioError.serviceUnavailable(requestedService)
            }
            throw AssistantAudioError.noReadyService(.synthesis)
        }
        guard let source = sourceByID[descriptor.id],
              let snapshot = settings.assistantSnapshot(for: source) else {
            throw AssistantAudioError.serviceUnavailable(descriptor.id)
        }
        let ext = outputURL.pathExtension.lowercased()
        guard AssistantAudioFileWriter.supportedFormats.contains(ext) else {
            throw AssistantAudioError.unsupportedOutputFormat(ext)
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw AssistantAudioError.outputExists
        }

        // Markdown syntax is never spoken. Cloud voices receive the literal
        // final prose including URLs; local voices use the full URL
        // pronunciation projection (port/final slash included) because this
        // is generated audio, not the ordinary Read-links toggle. MOSS gets
        // its accepted flatPause paragraph planning only after projection.
        var assistantSnapshot = snapshot
        assistantSnapshot.readLinksAloud = true
        let projected = AnswerSpeechText.spokenText(
            trimmed,
            destination: AnswerSpeechText.destination(
                for: assistantSnapshot, text: trimmed))
        let engine = settings.localModelDescriptor(snapshot.modelID)?.engine
        let prepared = MossSpeechPreparation.prepareParagraphs(projected, engine: engine)
        let segments = Self.completeSentences(prepared)
        guard !segments.isEmpty else { throw AssistantAudioError.textEmpty }

        let credential: String
        if snapshot.provider.requiresCloudCredential {
            do {
                credential = try await settings.credential(for: snapshot)
            } catch TTSSettingsFailure.credentialChangedRequiresNewKey {
                throw AssistantAudioError.credentialChangedRequiresNewKey
            } catch {
                throw AssistantAudioError.credentialMissing
            }
        } else {
            credential = ""
        }

        let session = UUID()
        var pcm = Data()
        var sampleRate = 24_000
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            let request = TTSSynthesisRequest(
                sessionID: session,
                segmentIndex: index,
                provider: snapshot.provider,
                billingRoute: snapshot.billingRoute,
                region: snapshot.alibabaRegion,
                openAIBaseURL: snapshot.openAIBaseURL,
                modelID: snapshot.modelID,
                voiceID: snapshot.voiceID,
                text: segment,
                speechRateRatio: 1.0,
                language: snapshot.language)
            let stream = speech.synthesize(request, credential: credential)
            var sawFinal = false
            do {
                for try await chunk in stream {
                    try Task.checkCancellation()
                    guard chunk.sessionID == session, chunk.segmentIndex == index else { continue }
                    guard (8_000...192_000).contains(chunk.sampleRate) else {
                        throw AssistantAudioError.invalidConfiguration("unsupported audio sample rate")
                    }
                    sampleRate = chunk.sampleRate
                    pcm.append(chunk.pcm)
                    guard pcm.count <= Self.maximumAudioBytes else {
                        throw AssistantAudioError.audioTooLong
                    }
                    if chunk.isFinal { sawFinal = true }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TTSSynthesisError {
                throw Self.mapTTSError(error)
            } catch {
                throw AssistantAudioError.synthesisFailed
            }
            guard sawFinal else {
                throw AssistantAudioError.invalidConfiguration("audio stream ended before the final chunk")
            }
        }
        guard !pcm.isEmpty else { throw AssistantAudioError.emptyAudio }
        // Immutable snapshots: synthesis accumulates in mutable locals, and
        // the detached writers below run concurrently.
        let resolvedPCM = pcm
        let resolvedSampleRate = sampleRate

        let written: WrittenAssistantAudio
        do {
            written = try await Self.detached {
                try AssistantAudioFileWriter.write(
                    pcm: resolvedPCM, sampleRate: resolvedSampleRate, to: outputURL)
            }
        } catch is CancellationError {
            throw CancellationError()
        }
        let inline: ToolArtifactReference?
        do {
            inline = try await Self.detached {
                try AssistantAudioInlinePlayer.makeReference(
                    pcm: resolvedPCM,
                    sampleRate: resolvedSampleRate,
                    runID: runID,
                    title: outputURL.deletingPathExtension().lastPathComponent)
            }
        } catch {
            inline = nil
        }
        return AssistantAudioSynthesisResult(
            outputURL: outputURL,
            byteCount: written.byteCount,
            sha256: written.sha256,
            duration: written.duration,
            sampleRate: written.sampleRate,
            mimeType: written.mimeType,
            uti: written.uti,
            service: descriptor,
            inlineArtifact: inline ?? nil)
    }

    // MARK: - ASR profile

    func saveASRProfile(baseURL: String, modelID: String, credential: String) throws {
        let normalized: String?
        do {
            normalized = try OpenAITranscriptionEndpoint.normalized(baseURL)
        } catch {
            throw AssistantAudioError.invalidConfiguration("endpoint must be a valid HTTPS address")
        }
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.count <= 128 else {
            throw AssistantAudioError.invalidConfiguration("transcription model is required")
        }
        let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if OpenAITranscriptionEndpoint.originChanged(from: preferences.asrBaseURL, to: normalized),
           key.isEmpty {
            throw AssistantAudioError.credentialChangedRequiresNewKey
        }
        if !key.isEmpty {
            try keychain.store(account: Self.asrAccount, secret: Data(key.utf8))
        }
        guard hasASRCredential else { throw AssistantAudioError.credentialMissing }
        var next = preferences
        next.asrBaseURL = normalized
        next.asrModelID = model
        preferences = next
        persist()
        Task { [weak self] in await self?.refreshAvailability() }
    }

    func removeASRProfile() throws {
        try keychain.delete(account: Self.asrAccount)
        var next = preferences
        next.asrBaseURL = nil
        next.asrModelID = AssistantAudioPreferences.defaultASRModelID
        // Keep the cloud ID in the saved priority list. It stays truthfully
        // unavailable and is skipped; removing the credential never silently
        // substitutes a different provider.
        preferences = next
        persist()
        Task { [weak self] in await self?.refreshAvailability() }
    }

    func asrCredential() throws -> String {
        guard let data = try? keychain.read(account: Self.asrAccount),
              let value = String(data: data, encoding: .utf8),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantAudioError.credentialMissing
        }
        return value
    }

    private var hasASRCredential: Bool {
        (try? keychain.read(account: Self.asrAccount))?.isEmpty == false
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    // MARK: - Selection policy

    private func automaticService(for capability: AssistantAudioCapability) -> AssistantAudioServiceDescriptor? {
        let ready = services.filter { $0.capability == capability && $0.ready }
        let byID = Dictionary(uniqueKeysWithValues: ready.map { ($0.id, $0) })
        for id in priorityIDs(for: capability) {
            if let descriptor = byID[id] { return descriptor }
        }
        return ready.sorted {
            let left = Self.automaticRank($0), right = Self.automaticRank($1)
            if left != right { return left < right }
            return $0.title < $1.title
        }.first
    }

    private static func automaticRank(_ descriptor: AssistantAudioServiceDescriptor) -> Int {
        switch descriptor.capability {
        case .transcription:
            if descriptor.id == ID.transcriptionEnhanced { return 0 }
            if descriptor.id == ID.transcriptionCloud { return 1 }
            return 2
        case .synthesis:
            if descriptor.provider == "apple" { return 2 }
            if descriptor.local { return 0 }
            return 1
        }
    }

    // MARK: - Errors

    private static func mapASRError(_ error: ASRTranscriptionError) -> AssistantAudioError {
        switch error {
        case .invalidConfiguration(let reason): return .invalidConfiguration(reason)
        case .credentialMissing: return .credentialMissing
        case .authentication, .quotaOrRateLimited, .httpStatus, .transport,
             .providerRejected, .emptyResult, .responseTooLarge:
            return .transcriptionFailed
        }
    }

    private static func mapTTSError(_ error: TTSSynthesisError) -> AssistantAudioError {
        switch error {
        case .credentialMissing, .authentication:
            return .credentialMissing
        case .invalidConfiguration(let reason):
            return .invalidConfiguration(reason)
        case .quotaOrRateLimited, .transport, .httpStatus, .providerRejected,
             .streamTruncated, .cancelled:
            return .synthesisFailed
        }
    }

    // MARK: - Pure helpers

    /// Run bounded file/audio work away from the MainActor while propagating
    /// cancellation into the detached operation.
    nonisolated private static func detached<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func completeSentences(_ text: String) -> [String] {
        var segmenter = TTSTextSegmenter(policy: .completeSentences)
        var result = segmenter.append(text)
        result.append(contentsOf: segmenter.finish())
        if result.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return result
    }

    nonisolated static func mediaDuration(_ url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    nonisolated static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "mp4": return "video/mp4"
        case "mp3": return "audio/mpeg"
        case "aiff", "aif": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        case "webm": return "audio/webm"
        case "mov": return "video/quicktime"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - File writer

struct WrittenAssistantAudio: Sendable {
    let byteCount: Int
    let sha256: String
    let duration: Double
    let sampleRate: Int
    let mimeType: String
    let uti: String?
}

enum AssistantAudioFileWriter {
    static let supportedFormats: Set<String> = ["wav", "m4a", "caf", "aiff"]
    static let maximumPCMBytes = AssistantAudioService.maximumAudioBytes

    static func write(
        pcm: Data,
        sampleRate: Int,
        to outputURL: URL
    ) throws -> WrittenAssistantAudio {
        guard !pcm.isEmpty, pcm.count % 2 == 0,
              (8_000...192_000).contains(sampleRate),
              pcm.count <= maximumPCMBytes else {
            throw AssistantAudioError.emptyAudio
        }
        let format = outputURL.pathExtension.lowercased()
        guard supportedFormats.contains(format) else {
            throw AssistantAudioError.unsupportedOutputFormat(format)
        }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw AssistantAudioError.outputExists
        }
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".floe-audio-\(UUID().uuidString).\(format)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        if format == "wav" {
            try wavData(pcm: pcm, sampleRate: sampleRate).write(to: temporary, options: .atomic)
        } else {
            try writeCompressed(pcm: pcm, sampleRate: sampleRate, to: temporary, format: format)
        }
        try Task.checkCancellation()
        try verify(temporary, expectedDuration: Double(pcm.count) / (2 * Double(sampleRate)))
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw AssistantAudioError.emptyAudio }
        let digest = try FloeDigest.sha256Hex(ofFileAt: temporary)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            throw AssistantAudioError.outputExists
        }
        do {
            try FileManager.default.moveItem(at: temporary, to: outputURL)
        } catch {
            throw AssistantAudioError.outputUnavailable
        }
        let verified = try? AVAudioFile(forReading: outputURL)
        let duration = verified.map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0
        return WrittenAssistantAudio(
            byteCount: size,
            sha256: digest,
            duration: duration,
            sampleRate: sampleRate,
            mimeType: mimeType(for: format),
            uti: uti(for: format))
    }

    static func wavData(pcm: Data, sampleRate: Int) -> Data {
        var data = Data(capacity: 44 + pcm.count)
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(Data("RIFF".utf8))
        appendLE(UInt32(36 + pcm.count))
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2))
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        data.append(Data("data".utf8))
        appendLE(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    static func writeCompressed(
        pcm: Data,
        sampleRate: Int,
        to destination: URL,
        format: String
    ) throws {
        let settings: [String: Any]
        switch format {
        case "m4a":
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
        case "caf":
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        case "aiff":
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: true,
            ]
        default:
            throw AssistantAudioError.unsupportedOutputFormat(format)
        }
        let file = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false)
        let frameCapacity: AVAudioFrameCount = 4_096
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: frameCapacity) else {
            throw AssistantAudioError.outputUnavailable
        }
        var index = 0
        let sampleCount = pcm.count / 2
        while index < sampleCount {
            try Task.checkCancellation()
            let frames = min(Int(frameCapacity), sampleCount - index)
            buffer.frameLength = AVAudioFrameCount(frames)
            guard let channel = buffer.floatChannelData?[0] else {
                throw AssistantAudioError.outputUnavailable
            }
            for frame in 0..<frames {
                let low = UInt16(pcm[(index + frame) * 2])
                let high = UInt16(pcm[(index + frame) * 2 + 1]) << 8
                channel[frame] = Float(Int16(bitPattern: low | high)) / 32768
            }
            try file.write(from: buffer)
            index += frames
        }
    }

    private static func verify(_ url: URL, expectedDuration: Double) throws {
        guard expectedDuration.isFinite, expectedDuration > 0 else {
            throw AssistantAudioError.emptyAudio
        }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw AssistantAudioError.emptyAudio }
        let actual = Double(file.length) / file.fileFormat.sampleRate
        let tolerance = max(0.25, expectedDuration * 0.02)
        guard actual.isFinite, abs(actual - expectedDuration) <= tolerance else {
            throw AssistantAudioError.outputUnavailable
        }
    }

    static func mimeType(for format: String) -> String {
        switch format {
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "caf": return "audio/x-caf"
        case "aiff": return "audio/aiff"
        default: return "application/octet-stream"
        }
    }

    static func uti(for format: String) -> String? {
        switch format {
        case "wav": return "com.microsoft.waveform-audio"
        case "m4a": return "com.apple.m4a-audio"
        case "caf": return "com.apple.coreaudio-format"
        case "aiff": return "public.aiff-audio"
        default: return nil
        }
    }
}

// MARK: - Inline player artifact

enum AssistantAudioInlinePlayer {
    static let maximumHTMLBytes = 1_000_000

    static func makeReference(
        pcm: Data,
        sampleRate: Int,
        runID: UUID?,
        title: String
    ) throws -> ToolArtifactReference? {
        guard !pcm.isEmpty, pcm.count % 2 == 0 else { return nil }
        let wav = AssistantAudioFileWriter.wavData(pcm: pcm, sampleRate: sampleRate)
        if let html = html(audio: wav, mimeType: "audio/wav", title: title),
           html.count <= maximumHTMLBytes {
            return try reference(html: html, runID: runID)
        }
        guard let aac = aacPreview(pcm: pcm, sampleRate: sampleRate),
              let html = html(audio: aac, mimeType: "audio/mp4", title: title),
              html.count <= maximumHTMLBytes else {
            return nil
        }
        return try reference(html: html, runID: runID)
    }

    static func html(audio: Data, mimeType: String, title: String) -> Data? {
        guard !audio.isEmpty, audio.count <= 700_000,
              mimeType == "audio/wav" || mimeType == "audio/mp4" else { return nil }
        let safeTitle = escape(title.isEmpty ? "Generated audio" : title)
        let base64 = audio.base64EncodedString()
        let document = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { font: -apple-system-body; margin: 12px; color: CanvasText; background: Canvas; }
        p { margin: 0 0 8px; font-size: 13px; opacity: .72; }
        audio { width: 100%; }
        </style></head><body>
        <p>\(safeTitle)</p>
        <audio controls preload="metadata" src="data:\(mimeType);base64,\(base64)"></audio>
        </body></html>
        """
        return Data(document.utf8)
    }

    private static func reference(html: Data, runID: UUID?) throws -> ToolArtifactReference {
        let root = try FloeArtifactStore.root()
        let runComponent = (runID ?? UUID()).uuidString
        let relativeDirectory = "ChangeArtifacts/\(runComponent)"
        let directory = root.appendingPathComponent(relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString.lowercased()).html"
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try html.write(to: url, options: .atomic)
        return ToolArtifactReference(
            id: UUID(),
            relativePath: "\(relativeDirectory)/\(name)",
            mimeType: "text/html",
            byteCount: html.count,
            sha256: FloeDigest.sha256Hex(html))
    }

    private static func aacPreview(pcm: Data, sampleRate: Int) -> Data? {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(".floe-audio-preview-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            try AssistantAudioFileWriter.writeCompressed(
                pcm: pcm, sampleRate: sampleRate, to: temporary, format: "m4a")
            guard let check = try? AVAudioFile(forReading: temporary), check.length > 0 else {
                return nil
            }
            let data = try Data(contentsOf: temporary, options: [.mappedIfSafe])
            guard !data.isEmpty, data.count <= 700_000 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
#endif
