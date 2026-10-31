// FloeProviders — OpenAI-compatible file transcription (ASR) adapter.
//
// SPDX-License-Identifier: MPL-2.0
//
// `POST <base>/audio/transcriptions` with multipart/form-data. The wire shape
// is selected from the model capability catalog:
//
//   gpt-transcribe      JSON (or SSE with stream=true), `languages[]`,
//                       optional prompt/keywords. No legacy verbose fields.
//   whisper-1           legacy `language`, `response_format=verbose_json`,
//                       `timestamp_granularities[]=segment`.
//   unknown compatible  conservative JSON + singular `language`; no timestamp
//                       or streaming parameters.
//
// The adapter consumes the request bytes once, validates the endpoint before
// any key is used, and returns only bounded text/timing. Provider response
// bodies, headers, keys and endpoint user info never enter an error. Modern
// text-only results never become a fabricated whole-duration caption segment:
// `ASRTranscriptionResult.timing` reports `.sourceSpanOnly` instead.

import Foundation
import FloeCore

public struct OpenAITranscriptionAdapter: ASRTranscribing {
    /// Documented provider upload ceiling. Larger files fail locally before
    /// any network access instead of being partially uploaded.
    public static let maximumAudioBytes = 25 * 1024 * 1024
    /// A transcript is small; a pathological body is refused. The native
    /// transport enforces the same ceiling while bytes arrive, and this check
    /// remains as defense in depth for an injected transport.
    public static let maximumResponseBytes = ASRTransportLimits.maximumResponseBodyBytes
    public static let maximumSSEEventBytes = 512 * 1024
    public static let maximumSSEEvents = 20_000
    public static let maximumSegments = 10_000
    public static let maximumTextCharacters = 2_000_000
    public static let maximumDetectedLanguages = 8

    private let transport: any ASRHTTPTransport

    /// Default initializer kept source-compatible: the existing app and tests
    /// pass a URLSession (or nil for the guarded ephemeral session).
    public init(session: URLSession? = nil) {
        self.transport = URLSessionASRHTTPTransport(
            session: session ?? ASRTransportSecurity.makeHTTPSession())
    }

    /// Focused-test / alternate transport seam.
    public init(transport: any ASRHTTPTransport) {
        self.transport = transport
    }

    // MARK: - Legacy request

    public func transcribe(
        _ request: ASRTranscriptionRequest,
        credential: String
    ) async throws -> ASRTranscriptionResult {
        let languages: [String]
        if !request.languages.isEmpty {
            languages = request.languages
        } else if let language = request.language, !language.isEmpty {
            languages = [language]
        } else {
            languages = []
        }
        return try await perform(
            endpointBaseURL: request.endpointBaseURL,
            modelID: request.modelID,
            languages: languages,
            prompt: nil,
            keywords: [],
            filename: request.filename,
            mimeType: request.mimeType,
            audio: request.audio,
            durationSeconds: request.durationSeconds,
            streamsResponse: request.streamsResponse,
            credential: credential)
    }

    // MARK: - Profile-driven request

    public func transcribe(
        _ request: ASRFileTranscriptionRequest,
        credential: String
    ) async throws -> ASRTranscriptionResult {
        let profile = request.profile
        guard profile.provider == .openaiCompatible else {
            throw ASRTranscriptionError.invalidConfiguration(
                "this adapter only serves OpenAI-compatible profiles")
        }
        guard profile.provider.supports(profile.billingRoute) else {
            throw ASRTranscriptionError.invalidConfiguration(
                "billing route is not available for this provider")
        }
        let languages = request.languages.isEmpty
            ? profile.languages
            : request.languages
        return try await perform(
            endpointBaseURL: profile.resolvedFileEndpoint,
            modelID: profile.fileModelID,
            languages: languages,
            prompt: profile.prompt,
            keywords: profile.keywords,
            filename: request.filename,
            mimeType: request.mimeType,
            audio: request.audio,
            durationSeconds: request.sourceDurationSeconds,
            streamsResponse: request.streamsResponse,
            credential: credential)
    }

    // MARK: - Request

    private func perform(
        endpointBaseURL: String?,
        modelID: String,
        languages: [String],
        prompt: String?,
        keywords: [String],
        filename: String,
        mimeType: String,
        audio: Data,
        durationSeconds: Double?,
        streamsResponse: Bool,
        credential: String
    ) async throws -> ASRTranscriptionResult {
        guard !audio.isEmpty else {
            throw ASRTranscriptionError.invalidConfiguration("audio file is empty")
        }
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw ASRTranscriptionError.invalidConfiguration("transcription model is required")
        }
        let capabilities = ASRModelCapabilityCatalog.capabilities(
            for: .openaiCompatible, modelID: model)
        guard capabilities.supportsFileTranscription else {
            throw ASRTranscriptionError.invalidConfiguration(
                "this model does not support file transcription")
        }
        guard audio.count <= Self.maximumAudioBytes else {
            throw ASRTranscriptionError.invalidConfiguration(
                "audio exceeds the 25 MiB transcription limit")
        }
        guard audio.count <= capabilities.maximumFileBytes else {
            throw ASRTranscriptionError.invalidConfiguration(
                "audio exceeds the model's transcription limit")
        }
        // Validate the endpoint before the credential is even trimmed: an
        // unsafe URL must never be combined with a key.
        let endpoint = try OpenAITranscriptionEndpoint.endpointURL(base: endpointBaseURL)
        let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ASRTranscriptionError.credentialMissing }

        let normalizedLanguages = Self.normalizedLanguages(languages)
        let boundary = "floe-asr-\(UUID().uuidString.lowercased())"
        var body = Data()
        Self.appendField("model", model, boundary: boundary, to: &body)
        switch capabilities.languageParameter {
        case .array:
            for language in normalizedLanguages {
                Self.appendField("languages[]", language, boundary: boundary, to: &body)
            }
        case .singular:
            if let language = normalizedLanguages.first {
                Self.appendField("language", language, boundary: boundary, to: &body)
            }
        case .none:
            break
        }
        if capabilities.supportsPrompt,
           let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty {
            Self.appendField(
                "prompt",
                String(prompt.prefix(ASRProfile.maximumPromptCharacters)),
                boundary: boundary,
                to: &body)
        }
        if capabilities.supportsKeywords {
            for keyword in Self.normalizedKeywords(keywords) {
                Self.appendField("keywords[]", keyword, boundary: boundary, to: &body)
            }
        }
        switch capabilities.fileResponseFormat {
        case .json:
            Self.appendField("response_format", "json", boundary: boundary, to: &body)
        case .verboseJSON:
            Self.appendField("response_format", "verbose_json", boundary: boundary, to: &body)
        case .automatic:
            // Modern `gpt-transcribe` defaults to JSON; do not send an
            // optional field the model does not require.
            break
        }
        if capabilities.supportsTimestampGranularities {
            Self.appendField(
                "timestamp_granularities[]", "segment", boundary: boundary, to: &body)
        }
        let wantsStream = streamsResponse && capabilities.supportsFileStreaming
        if wantsStream {
            Self.appendField("stream", "true", boundary: boundary, to: &body)
        }
        Self.appendFile(
            field: "file",
            filename: Self.safeFilename(filename),
            mimeType: Self.safeMimeType(mimeType),
            data: audio,
            boundary: boundary,
            to: &body)
        body.append(Data("--\(boundary)--\r\n".utf8))

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 180
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(
            wantsStream ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let response: ASRHTTPResponse
        do {
            response = try await transport.perform(urlRequest, body: body)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let asr = error as? ASRTranscriptionError {
                // Transport cancellation is never a provider failure.
                if case .transport(.cancelled) = asr { throw CancellationError() }
                throw asr
            }
            if Self.isCancellation(error) { throw CancellationError() }
            throw ASRTransportErrorMapping.failure(error)
        }
        try Task.checkCancellation()
        if let responseURL = response.url,
           !ASRTransportSecurity.sameOrigin(endpoint, responseURL) {
            // A redirect/origin swap must never be treated as this request.
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
        return try Self.parse(
            response.body,
            capabilities: capabilities,
            sourceDurationSeconds: durationSeconds,
            contentType: response.headers["content-type"])
    }

    // MARK: - Response

    static func parse(
        _ data: Data,
        capabilities: ASRModelCapabilities,
        sourceDurationSeconds: Double?,
        contentType: String?
    ) throws -> ASRTranscriptionResult {
        guard !data.isEmpty else { throw ASRTranscriptionError.emptyResult }
        let looksLikeSSE = Self.looksLikeSSE(data, contentType: contentType)
        if looksLikeSSE {
            let outcome = try Self.parseSSE(data)
            return try Self.finalize(
                text: outcome.text,
                segments: [],
                language: outcome.languages.first,
                detectedLanguages: outcome.languages,
                sourceDurationSeconds: sourceDurationSeconds)
        }
        return try Self.parseJSON(
            data, sourceDurationSeconds: sourceDurationSeconds)
    }

    private struct SSEOutcome {
        var text: String
        var languages: [String]
    }

    private static func parseSSE(_ data: Data) throws -> SSEOutcome {
        guard let content = String(data: data, encoding: .utf8) else {
            throw ASRTranscriptionError.providerRejected
        }
        var deltas = ""
        var finalText: String?
        var languages: [String] = []
        var sawDone = false
        var sawEvent = false
        var eventCount = 0
        var dataLines: [String] = []

        func dispatch() throws {
            guard !dataLines.isEmpty else { return }
            let payload = dataLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            dataLines.removeAll(keepingCapacity: true)
            guard !payload.isEmpty else { return }
            if payload == "[DONE]" {
                sawDone = true
                return
            }
            guard payload.utf8.count <= maximumSSEEventBytes else {
                throw ASRTranscriptionError.responseTooLarge
            }
            guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)),
                  let dictionary = object as? [String: Any] else {
                throw ASRTranscriptionError.providerRejected
            }
            let type = string(dictionary["type"])
            switch type {
            case "transcript.text.delta":
                guard let delta = string(dictionary["delta"]), !delta.isEmpty else { return }
                sawEvent = true
                deltas += delta
                guard deltas.count <= maximumTextCharacters else {
                    throw ASRTranscriptionError.responseTooLarge
                }
            case "transcript.text.done":
                sawEvent = true
                sawDone = true
                if let text = string(dictionary["text"]) {
                    finalText = text
                }
                languages = parseLanguages(dictionary["languages"])
            case "error":
                // Error payload text is untrusted and deliberately dropped.
                throw ASRTranscriptionError.providerRejected
            default:
                // Unknown event types are ignored for forward compatibility.
                break
            }
        }

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty {
                eventCount += 1
                guard eventCount <= maximumSSEEvents else {
                    throw ASRTranscriptionError.responseTooLarge
                }
                try dispatch()
                continue
            }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("data:") {
                var payload = String(line.dropFirst(5))
                if payload.hasPrefix(" ") { payload.removeFirst() }
                dataLines.append(payload)
            }
        }
        if !dataLines.isEmpty {
            eventCount += 1
            guard eventCount <= maximumSSEEvents else {
                throw ASRTranscriptionError.responseTooLarge
            }
            try dispatch()
        }
        guard sawDone else {
            // A stream that ends before the documented final event must not be
            // presented as a completed transcript.
            if sawEvent { throw ASRTranscriptionError.providerRejected }
            throw ASRTranscriptionError.emptyResult
        }
        let text = (finalText ?? deltas)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ASRTranscriptionError.emptyResult }
        return SSEOutcome(text: text, languages: languages)
    }

    private static func parseJSON(
        _ data: Data,
        sourceDurationSeconds: Double?
    ) throws -> ASRTranscriptionResult {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw ASRTranscriptionError.providerRejected
        }
        if dictionary["error"] != nil {
            throw ASRTranscriptionError.providerRejected
        }
        var text = (string(dictionary["text"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var segments: [ASRTranscriptionSegment] = []
        if let rawSegments = dictionary["segments"] as? [Any] {
            guard rawSegments.count <= maximumSegments else {
                throw ASRTranscriptionError.responseTooLarge
            }
            for item in rawSegments {
                guard let item = item as? [String: Any],
                      let start = double(item["start"]),
                      let end = double(item["end"]),
                      start.isFinite, end.isFinite, start >= 0, end > start,
                      let segmentText = string(item["text"]) else { continue }
                let trimmed = segmentText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                segments.append(ASRTranscriptionSegment(
                    start: start, end: end, text: trimmed))
            }
        }
        if text.isEmpty {
            text = segments.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let detected = parseLanguages(dictionary["languages"])
        let language = string(dictionary["language"])
        return try finalize(
            text: text,
            segments: segments,
            language: language ?? detected.first,
            detectedLanguages: detected,
            sourceDurationSeconds: sourceDurationSeconds)
    }

    private static func finalize(
        text rawText: String,
        segments: [ASRTranscriptionSegment],
        language: String?,
        detectedLanguages: [String],
        sourceDurationSeconds: Double?
    ) throws -> ASRTranscriptionResult {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ASRTranscriptionError.emptyResult }
        guard text.count <= maximumTextCharacters else {
            throw ASRTranscriptionError.responseTooLarge
        }
        guard segments.count <= maximumSegments else {
            throw ASRTranscriptionError.responseTooLarge
        }
        var totalSegmentCharacters = 0
        for segment in segments {
            totalSegmentCharacters += segment.text.count
            guard totalSegmentCharacters <= maximumTextCharacters else {
                throw ASRTranscriptionError.responseTooLarge
            }
        }
        let timing: ASRTimingProvenance
        if !segments.isEmpty {
            timing = .providerSegments
        } else if let sourceDurationSeconds,
                  sourceDurationSeconds.isFinite,
                  sourceDurationSeconds > 0 {
            // The source span is real, but there is no speech alignment. This
            // is explicitly not a caption segment.
            timing = .sourceSpanOnly
        } else {
            timing = .none
        }
        let cleanedLanguages = normalizeLanguages(detectedLanguages)
        let candidate = language?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let primary: String?
        if let candidate, !candidate.isEmpty, candidate.count <= 32 {
            primary = candidate
        } else {
            primary = cleanedLanguages.first
        }
        return ASRTranscriptionResult(
            text: text,
            segments: segments,
            language: primary,
            timing: timing,
            detectedLanguages: cleanedLanguages)
    }

    // MARK: - Bounds / helpers

    private static func looksLikeSSE(_ data: Data, contentType: String?) -> Bool {
        if let contentType = contentType?.lowercased(),
           contentType.contains("text/event-stream") {
            return true
        }
        guard let string = String(data: data.prefix(256), encoding: .utf8) else {
            return false
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("data:") || trimmed.hasPrefix("event:")
    }

    static func normalizedLanguages(_ raw: [String]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for language in raw {
            let value = language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 32 else { continue }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(value)
            if result.count == 8 { break }
        }
        return result
    }

    private static func normalizeLanguages(_ raw: [String]) -> [String] {
        normalizedLanguages(raw)
    }

    static func normalizedKeywords(_ raw: [String]) -> [String] {
        var result: [String] = []
        for keyword in raw {
            var value = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if value.contains("<") || value.contains(">")
                || value.contains("\r") || value.contains("\n") { continue }
            if value.count > ASRProfile.maximumKeywordCharacters {
                value = String(value.prefix(ASRProfile.maximumKeywordCharacters))
            }
            result.append(value)
            if result.count == ASRProfile.maximumKeywords { break }
        }
        return result
    }

    private static func parseLanguages(_ raw: Any?) -> [String] {
        guard let array = raw as? [Any] else { return [] }
        var result: [String] = []
        var seen = Set<String>()
        for item in array.prefix(Self.maximumDetectedLanguages) {
            let code: String?
            if let string = item as? String {
                code = string
            } else if let dictionary = item as? [String: Any] {
                code = string(dictionary["code"])
            } else {
                code = nil
            }
            guard let code else { continue }
            let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 32 else { continue }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(value)
        }
        return result
    }

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
    }

    // MARK: - Multipart

    private static func appendField(
        _ name: String,
        _ value: String,
        boundary: String,
        to body: inout Data
    ) {
        let safeName = name.replacingOccurrences(of: "\"", with: "")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(safeName)\"\r\n\r\n".utf8))
        body.append(Data(value.utf8))
        body.append(Data("\r\n".utf8))
    }

    private static func appendFile(
        field: String,
        filename: String,
        mimeType: String,
        data: Data,
        boundary: String,
        to body: inout Data
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    private static func safeFilename(_ raw: String) -> String {
        var value = (raw as NSString).lastPathComponent
        value = value.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        if value.isEmpty || value.count > 200 { return "audio.bin" }
        return value
    }

    private static func safeMimeType(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 128,
              value.range(of: "^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$",
                          options: .regularExpression) != nil else {
            return "application/octet-stream"
        }
        return value
    }
}
