// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DeepSeekTranscriptionAdapter: ASRTranscribing {
    private let transport: any ASRHTTPTransport

    public init(transport: any ASRHTTPTransport = URLSessionASRHTTPTransport(session: ASRTransportSecurity.makeHTTPSession())) {
        self.transport = transport
    }

    /// Validates a complete single-request file by its bytes. The media pipeline uses
    /// this same check before preserving an original recording, including both stereo channels.
    public static func inspectFile(_ data: Data) throws -> (filename: String, mimeType: String, durationSeconds: Double) {
        guard !data.isEmpty, data.count <= DeepSeekSpeechAPI.maximumFileBytes else {
            throw ASRTranscriptionError.invalidConfiguration("DeepSeek requires a complete audio file up to 8 MiB")
        }
        let file: (filename: String, mimeType: String, durationSeconds: Double)
        if data.starts(with: Data("OggS".utf8)) {
            file = ("speech.ogg", "audio/ogg", try opusDuration(data))
        } else {
            guard data.starts(with: Data("RIFF".utf8)), data.count >= 12,
                  data.dropFirst(8).prefix(4).elementsEqual("WAVE".utf8) else {
                throw ASRTranscriptionError.invalidConfiguration("DeepSeek requires PCM16 WAV or Ogg Opus")
            }
            let riffSize = data.dropFirst(4).prefix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard Int(riffSize) + 8 == data.count else {
                throw ASRTranscriptionError.invalidConfiguration("DeepSeek requires a complete WAV file")
            }
            let audio = try ASRVendorAudioDetector.inspect(data, filename: "speech.wav", mimeType: "audio/wav", provider: .deepSeek)
            guard let duration = audio.durationSeconds else {
                throw ASRTranscriptionError.invalidConfiguration("DeepSeek requires a complete PCM16 WAV file")
            }
            file = ("speech.wav", "audio/wav", duration)
        }
        guard file.durationSeconds > 0, file.durationSeconds <= DeepSeekSpeechAPI.maximumAudioSeconds else {
            throw ASRTranscriptionError.invalidConfiguration("DeepSeek audio must be at most 120 seconds per request")
        }
        return file
    }

    public func transcribe(_ request: ASRTranscriptionRequest, credential: String) async throws -> ASRTranscriptionResult {
        var profile = ASRProfile.deepSeek()
        profile.fileEndpoint = request.endpointBaseURL
        return try await transcribe(.init(profile: profile, audio: request.audio, filename: request.filename,
                                         mimeType: request.mimeType, sourceDurationSeconds: request.durationSeconds),
                                    credential: credential)
    }

    public func transcribe(_ request: ASRFileTranscriptionRequest, credential: String) async throws -> ASRTranscriptionResult {
        try Task.checkCancellation()
        guard request.profile.provider == .deepSeek, request.profile.validationProblem() == nil else {
            throw ASRTranscriptionError.invalidConfiguration("invalid DeepSeek speech profile")
        }
        let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ASRTranscriptionError.credentialMissing }
        let file = try Self.inspectFile(request.audio)

        let boundary = "floe-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(file.filename)\"\r\nContent-Type: \(file.mimeType)\r\n\r\n".utf8)
        body.append(request.audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var post = URLRequest(url: DeepSeekSpeechAPI.asrURL, timeoutInterval: 600)
        post.httpMethod = "POST"
        post.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        post.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        let response: ASRHTTPResponse
        do { response = try await transport.perform(post, body: body) }
        catch {
            let failure = ASRTransportErrorMapping.failure(error)
            if Task.isCancelled || failure == .transport(.cancelled) { throw CancellationError() }
            throw failure
        }
        try Task.checkCancellation()
        if let url = response.url, !ASRTransportSecurity.sameOrigin(DeepSeekSpeechAPI.asrURL, url) {
            throw ASRTranscriptionError.providerRejected
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw ASRTranscriptionError.authentication
        case 402, 429: throw ASRTranscriptionError.quotaOrRateLimited
        default: throw ASRTranscriptionError.httpStatus(response.statusCode)
        }
        guard response.body.count <= ASRTransportLimits.maximumResponseBodyBytes else {
            throw ASRTranscriptionError.responseTooLarge
        }
        struct Result: Decodable { let text: String; let duration_ms: Int }
        guard let value = try? JSONDecoder().decode(Result.self, from: response.body),
              (0...120_000).contains(value.duration_ms) else { throw ASRTranscriptionError.providerRejected }
        let text = value.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A silent part of a longer recording is a valid recognition result.
        return ASRTranscriptionResult(text: text, segments: [], timing: value.duration_ms > 0 ? .sourceSpanOnly : .none)
    }

    /// Opus granules are measured at 48 kHz; the initial pre-skip is not audible time.
    private static func opusDuration(_ data: Data) throws -> Double {
        let invalid = ASRTranscriptionError.invalidConfiguration("a complete mono or stereo Ogg Opus file is required")
        let bytes = [UInt8](data)
        func u32(at offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
        var offset = 0
        var serial: UInt32?
        var nextPage: UInt32 = 0
        var preSkip: UInt64 = 0
        var duration: Double = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 27,
                  bytes[offset..<offset + 4].elementsEqual("OggS".utf8), bytes[offset + 4] == 0 else { throw invalid }
            let flags = bytes[offset + 5]
            let segmentCount = Int(bytes[offset + 26])
            let start = offset + 27 + segmentCount
            guard flags < 8, start <= bytes.count else { throw invalid }
            let length = bytes[(offset + 27)..<start].reduce(0) { $0 + Int($1) }
            let end = start + length
            guard end <= bytes.count else { throw invalid }
            let currentSerial = u32(at: offset + 14)
            let sequence = u32(at: offset + 18)
            if serial == nil {
                guard flags & 3 == 2, sequence == 0, segmentCount > 0, bytes[offset + 27] >= 19, length >= 19,
                      bytes[start..<start + 8].elementsEqual("OpusHead".utf8),
                      (1..<16).contains(bytes[start + 8]), [1, 2].contains(bytes[start + 9]) else { throw invalid }
                serial = currentSerial
                preSkip = UInt64(bytes[start + 10]) | UInt64(bytes[start + 11]) << 8
            } else {
                guard serial == currentSerial, flags & 2 == 0, sequence == nextPage else { throw invalid }
            }
            nextPage = sequence &+ 1
            if flags & 4 != 0 {
                let granule = bytes[(offset + 6)..<(offset + 14)].reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard granule != .max, granule >= preSkip else { throw invalid }
                duration += Double(granule - preSkip) / 48_000
                serial = nil
            }
            offset = end
        }
        guard serial == nil, duration > 0 else { throw invalid }
        return duration
    }
}
