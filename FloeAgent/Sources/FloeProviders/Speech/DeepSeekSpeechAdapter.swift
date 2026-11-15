// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DeepSeekSpeechAdapter: TTSSpeechProviding {
    let session: URLSession
    public static let voices = DeepSeekSpeechAPI.voices.map {
        TTSSpeechVoice(voiceID: $0, displayName: $0.capitalized, kind: .builtin)
    }

    public init(session: URLSession? = nil) {
        self.session = session ?? ASRTransportSecurity.makeHTTPSession()
    }

    static func body(for request: TTSSynthesisRequest) throws -> Data {
        guard request.provider == .deepSeek, let voice = DeepSeekSpeechAPI.voices.first(where: { $0 == request.voiceID }),
              request.validationProblem() == nil else {
            throw TTSSynthesisError.invalidConfiguration("invalid DeepSeek speech configuration")
        }
        let scalarCount = request.text.unicodeScalars.prefix(10_001).count
        let hanIdeographs = #/[\p{Script=Han}&&\p{Ideographic}]/#.matchingSemantics(.unicodeScalar)
        guard scalarCount <= 10_000, scalarCount + request.text.ranges(of: hanIdeographs).count <= 10_000 else {
            throw TTSSynthesisError.invalidConfiguration("DeepSeek text exceeds 10,000 billing characters")
        }
        let body = try JSONEncoder().encode(["text": request.text, "voice_id": voice, "format": "pcm"])
        guard body.count <= 64 * 1024 else { throw TTSSynthesisError.invalidConfiguration("DeepSeek request exceeds 64 KiB") }
        return body
    }

    public func synthesize(_ request: TTSSynthesisRequest, credential: String) -> TTSAudioChunkStream {
        ttssRunStream(provider: .deepSeek) { sender in
            try Task.checkCancellation()
            let data = try Self.body(for: request)
            let key = credential.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw TTSSynthesisError.credentialMissing(provider: .deepSeek, route: .payAsYouGo) }
            var headers = TTSSpeechRequestHeaders(accept: nil)
            headers["Authorization"] = "Bearer " + key
            headers["Accept-Encoding"] = "identity"
            let opened = try await TTSSpeechHTTP.post(url: DeepSeekSpeechAPI.ttsURL, headers: headers, body: data,
                session: session, provider: .deepSeek, route: .payAsYouGo)
            if let mime = opened.mimeType, !["audio/pcm", "audio/l16", "audio/raw", "audio/x-pcm", "application/octet-stream"].contains(mime) {
                throw TTSSynthesisError.providerRejected(provider: .deepSeek, code: nil, logID: opened.logID)
            }
            try await ttssForwardRawPCM(opened.chunks, request: request, sender: sender, completeResponse: opened)
        }
    }
}
