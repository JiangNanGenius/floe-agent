// FloeProviders — OpenAI-compatible file transcription (ASR) adapter.
//
// SPDX-License-Identifier: MPL-2.0
//
// `POST <base>/audio/transcriptions` with multipart/form-data. This is the
// first cloud ASR route: a transcription-only OpenAI-compatible service with
// its own endpoint, model and Keychain credential. TTS-only vendors (for
// example Volcengine/Alibaba speech synthesis routes) are deliberately NOT
// treated as transcription providers here.
//
// The adapter consumes the request bytes ONCE, validates the endpoint before
// any key is used, asks for `verbose_json` + segment timestamp granularity and
// returns only bounded text/timing. Provider response bodies, headers, keys
// and endpoint user info never enter an error.

import Foundation
import FloeCore

public protocol ASRTranscribing: Sendable {
    func transcribe(
        _ request: ASRTranscriptionRequest,
        credential: String
    ) async throws -> ASRTranscriptionResult
}

public struct OpenAITranscriptionAdapter: ASRTranscribing {
    /// Documented provider upload ceiling. Larger files fail locally before
    /// any network access instead of being partially uploaded.
    public static let maximumAudioBytes = 25 * 1024 * 1024
    /// A verbose transcript is small; a pathological body is refused.
    public static let maximumResponseBytes = 8 * 1024 * 1024

    let session: URLSession

    public init(session: URLSession? = nil) {
        // Ephemeral by default: transcript audio/response bytes never land in
        // a shared URL cache or cookie store.
        self.session = session ?? ProviderTransport.session(ephemeral: true)
    }

    public func transcribe(
        _ request: ASRTranscriptionRequest,
        credential: String
    ) async throws -> ASRTranscriptionResult {
        guard !request.audio.isEmpty else {
            throw ASRTranscriptionError.invalidConfiguration("audio file is empty")
        }
        guard request.audio.count <= Self.maximumAudioBytes else {
            throw ASRTranscriptionError.invalidConfiguration("audio exceeds the 25 MiB transcription limit")
        }
        let model = request.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw ASRTranscriptionError.invalidConfiguration("transcription model is required")
        }
        let endpoint = try OpenAITranscriptionEndpoint.endpointURL(base: request.endpointBaseURL)
        let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ASRTranscriptionError.credentialMissing }

        let boundary = "floe-asr-\(UUID().uuidString.lowercased())"
        var body = Data()
        Self.appendField("model", model, boundary: boundary, to: &body)
        if let language = request.language?.trimmingCharacters(in: .whitespacesAndNewlines),
           !language.isEmpty {
            Self.appendField("language", language, boundary: boundary, to: &body)
        }
        Self.appendField("response_format", "verbose_json", boundary: boundary, to: &body)
        Self.appendField("timestamp_granularities[]", "segment", boundary: boundary, to: &body)
        Self.appendFile(
            field: "file",
            filename: Self.safeFilename(request.filename),
            mimeType: Self.safeMimeType(request.mimeType),
            data: request.audio,
            boundary: boundary,
            to: &body)
        body.append(Data("--\(boundary)--\r\n".utf8))

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 180
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let result: (Data, URLResponse)
        do {
            result = try await session.upload(for: urlRequest, from: body)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw ASRTranscriptionError.transport(Self.transportFailure(error))
        } catch {
            throw ASRTranscriptionError.transport(.unknown)
        }
        let data = result.0
        let response = result.1
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw ASRTranscriptionError.providerRejected
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            throw ASRTranscriptionError.authentication
        case 429:
            throw ASRTranscriptionError.quotaOrRateLimited
        default:
            throw ASRTranscriptionError.httpStatus(http.statusCode)
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw ASRTranscriptionError.responseTooLarge
        }
        return try Self.parse(data, durationSeconds: request.durationSeconds)
    }

    // MARK: - Response

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

    static func parse(_ data: Data, durationSeconds: Double?) throws -> ASRTranscriptionResult {
        guard !data.isEmpty else { throw ASRTranscriptionError.emptyResult }
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ASRTranscriptionError.providerRejected
        }
        var segments: [ASRTranscriptionSegment] = []
        for item in decoded.segments ?? [] {
            guard let start = item.start, let end = item.end,
                  start.isFinite, end.isFinite, start >= 0, end > start else { continue }
            let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            segments.append(ASRTranscriptionSegment(start: start, end: end, text: text))
        }
        var text = (decoded.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = segments.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { throw ASRTranscriptionError.emptyResult }
        if segments.isEmpty, let durationSeconds,
           durationSeconds.isFinite, durationSeconds > 0 {
            // Honest fallback timing: the provider returned no segments, so
            // the locally measured source duration is the only real span.
            segments = [ASRTranscriptionSegment(start: 0, end: durationSeconds, text: text)]
        }
        return ASRTranscriptionResult(
            text: text,
            segments: segments,
            language: decoded.language?.trimmingCharacters(in: .whitespacesAndNewlines))
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

    private static func transportFailure(_ error: URLError) -> TTSTransportFailure {
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed: return .cannotResolveHost
        case .cannotConnectToHost: return .cannotConnect
        case .timedOut: return .timedOut
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return .tlsFailure
        case .notConnectedToInternet, .networkConnectionLost: return .notReachable
        case .cancelled: return .cancelled
        default: return .unknown
        }
    }
}
