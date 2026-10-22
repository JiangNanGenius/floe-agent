// FloeProviders — Incremental streaming transport primitives for TTS.
//
// SPDX-License-Identifier: MPL-2.0
//
// Shared plumbing for the speech adapters: ordered incremental HTTP byte
// chunking (never a buffered whole response), SSE audio extraction with hard
// size bounds, and redacted failure mapping. All provider responses and error
// bodies are UNTRUSTED: they only ever become bounded PCM data or fixed
// category errors — no raw text is surfaced (a provider could echo the
// credential).

import Foundation
import FloeCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Bounds

/// Hard ceilings for one streamed synthesis response. A provider exceeding a
/// ceiling is a protocol error, not an unbounded allocation.
public enum TTSSpeechLimits {
    /// 8 MiB of audio ≈ 2.8 min of 24 kHz s16le mono per segment.
    public static let maxSegmentAudioBytes = 8 * 1024 * 1024
    /// Max raw bytes of one SSE data field before the stream is rejected.
    public static let maxSSEEventBytes = 512 * 1024
    /// Max bytes of one Volcengine WebSocket frame payload.
    public static let maxWSFrameBytes = 1 * 1024 * 1024 + 64 * 1024
    /// Max PCM emitted per single TTSAudioChunk (128 KiB ≈ 2.7 s at 24 kHz).
    public static let maxChunkBytes = 128 * 1024
    /// Low first-audio latency: HTTP bodies are grouped into ~4 KiB even
    /// (sample-aligned) chunks pulled demand-driven, never dropped.
    public static let chunkTargetBytes = 4096
    /// In-flight audio chunks the consumer may lag behind by. The producer
    /// AWAITS at the ceiling (backpressure to the socket), it never drops.
    public static let channelSlotCapacity = 8
}

// MARK: - Redacted failure mapping

/// Maps a thrown error to a lane-safe category. The underlying description is
/// NEVER carried (it may contain request data); only URLError codes classify.
public func TTSTransportFailure(for error: Error) -> TTSTransportFailure {
    if error is CancellationError { return .cancelled }
    let ns = error as NSError?
    if ns?.domain == NSURLErrorDomain {
        switch ns?.code {
        case NSURLErrorCannotFindHost, NSURLErrorResourceUnavailable: return .cannotResolveHost
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost: return .cannotConnect
        case NSURLErrorTimedOut: return .timedOut
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorBadServerResponse: return .tlsFailure
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed: return .notReachable
        case NSURLErrorCancelled: return .cancelled
        default: return .unknown
        }
    }
    return .unknown
}

/// Fixed request headers for every speech call: JSON in, no cache reuse, no
/// cookies; ephemeral-safe directives only.
public func TTSSpeechRequestHeaders(accept: String?) -> [String: String] {
    var headers: [String: String] = [
        "Content-Type": "application/json",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
    ]
    if let accept { headers["Accept"] = accept }
    return headers
}

// MARK: - Incremental audio stream (demand-driven, lossless)

/// Groups response bytes into ordered even-size (sample-aligned) Data chunks
/// BY DEMAND. On Apple platforms the backend is the SDK's byte-wise
/// `URLSession.AsyncBytes`: `next()` only pulls bytes while a consumer awaits,
/// so there is no intermediate lossy queue anywhere in the transport, and
/// cancelling the consuming task cancels the URLSession task (AsyncBytes
/// contract). The buffered backend exists ONLY for the
/// `canImport(FoundationNetworking)` cross-compile CI target (Linux is a
/// build/test target, never the speech app runtime — same precedent as
/// `SSEBytePump`); the iOS runtime never takes it. It is also what focused
/// tests use to verify grouping determinism on any host.
public struct TTSSpeechByteChunks: AsyncSequence, Sendable {
    public typealias Element = Data

    fileprivate enum Backend: Sendable {
        case buffered([UInt8])
        #if !canImport(FoundationNetworking)
        case bytes(URLSession.AsyncBytes)
        #endif
    }

    private let backend: Backend
    public let chunkBytes: Int

    /// Sample-aligned grouping (even, ≥ 2).
    private static func aligned(_ chunkBytes: Int) -> Int {
        Swift.max(2, chunkBytes / 2 * 2)
    }

    public init(buffered: Data, chunkBytes: Int = TTSSpeechLimits.chunkTargetBytes) {
        self.backend = .buffered([UInt8](buffered))
        self.chunkBytes = Self.aligned(chunkBytes)
    }

    #if !canImport(FoundationNetworking)
    public init(bytes: URLSession.AsyncBytes, chunkBytes: Int = TTSSpeechLimits.chunkTargetBytes) {
        self.backend = .bytes(bytes)
        self.chunkBytes = Self.aligned(chunkBytes)
    }
    #endif

    public struct Iterator: AsyncIteratorProtocol {
        private enum Pull {
            case buffered([UInt8], Int)
            #if !canImport(FoundationNetworking)
            case bytes(URLSession.AsyncBytes.Iterator)
            #endif
        }
        private var pull: Pull
        private let chunkBytes: Int

        fileprivate init(backend: Backend, chunkBytes: Int) {
            self.chunkBytes = chunkBytes
            switch backend {
            case .buffered(let bytes):
                self.pull = .buffered(bytes, 0)
                #if !canImport(FoundationNetworking)
            case .bytes(let bytes):
                self.pull = .bytes(bytes.makeAsyncIterator())
                #endif
            }
        }

        public mutating func next() async throws -> Data? {
            switch pull {
            case .buffered(let bytes, var position):
                if Task.isCancelled { throw CancellationError() }
                guard position < bytes.count else { return nil }
                let end = Swift.min(position + chunkBytes, bytes.count)
                let piece = Data(bytes[position..<end])
                position = end
                pull = .buffered(bytes, position)
                return piece
                #if !canImport(FoundationNetworking)
            case .bytes(var underlying):
                var collected: [UInt8] = []
                collected.reserveCapacity(chunkBytes)
                while collected.count < chunkBytes {
                    guard let byte = try await underlying.next() else { break }
                    collected.append(byte)
                }
                pull = .bytes(underlying)
                guard !collected.isEmpty else { return nil }
                return Data(collected)
                #endif
            }
        }
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(backend: backend, chunkBytes: chunkBytes)
    }
}

/// Opens speech HTTP calls and hands back the lossless byte sequence.
enum TTSSpeechHTTP {
    /// Result of a validated start: status + incremental chunks. Non-2xx or
    /// transport failures map to redacted `TTSSynthesisError`s; the response's
    /// trace header becomes the logID BEFORE the body is dropped.
    struct Opened: Sendable {
        let statusCode: Int
        let logID: String?
        let chunks: TTSSpeechByteChunks
    }

    static func open(
        request: URLRequest,
        session: URLSession,
        provider: TTSSpeakerProvider,
        route: TTSBillingRoute? = nil
    ) async throws -> Opened {
        // SDK contract (verified 2026-10-22 against Xcode 27.1):
        // `bytes(for:)` returns `(URLSession.AsyncBytes, URLResponse)`.
        let (chunks, response) = try await begin(request: request, session: session, provider: provider)
        guard let http = response as? HTTPURLResponse else {
            throw TTSSynthesisError.transport(provider: provider, failure: .unknown)
        }
        let logID = traceLogID(from: http)
        guard (200..<300).contains(http.statusCode) else {
            throw classifyHTTPStatus(
                provider: provider, statusCode: http.statusCode, logID: logID, route: route)
        }
        return Opened(statusCode: http.statusCode, logID: logID, chunks: chunks)
    }

    /// POSTs a JSON body and returns the incremental byte sequence.
    static func post(
        url: URL,
        headers: [String: String],
        body: Data,
        session: URLSession,
        provider: TTSSpeakerProvider,
        route: TTSBillingRoute? = nil
    ) async throws -> Opened {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return try await open(request: request, session: session, provider: provider, route: route)
    }

    /// Log ID from the headers of a response; providers expose their trace IDs
    /// under different names.
    static func traceLogID(from response: URLResponse?) -> String? {
        guard let http = response as? HTTPURLResponse else { return nil }
        for field in ["X-Tt-Logid", "x-request-id", "request-id", "Xi-Trace-Id"] {
            if let value = http.value(forHTTPHeaderField: field) {
                return TTSSynthesisError.sanitizedLogID(value)
            }
        }
        return nil
    }

    private static func begin(
        request: URLRequest,
        session: URLSession,
        provider: TTSSpeakerProvider
    ) async throws -> (TTSSpeechByteChunks, URLResponse) {
        do {
            #if canImport(FoundationNetworking)
            // Buffered build-target fallback (see TTSSpeechByteChunks above).
            let (data, response) = try await session.data(for: request)
            return (TTSSpeechByteChunks(buffered: data), response)
            #else
            let (bytes, response) = try await session.bytes(for: request)
            return (TTSSpeechByteChunks(bytes: bytes), response)
            #endif
        } catch {
            let failure = TTSTransportFailure(for: error)
            if case .cancelled = failure { throw TTSSynthesisError.cancelled }
            throw TTSSynthesisError.transport(provider: provider, failure: failure)
        }
    }

    /// Fixed status classification. Provider bodies are never read on failure.
    /// `route` is the request's EXPLICIT billing channel: an auth/quota status
    /// on a token/agent-plan call must be labelled with that route, never the
    /// pay-as-you-go default (wrong label could mislead the user into editing
    /// the wrong key). Unknown route defaults to the pay-as-you-go label only
    /// for routes that have no plan channel (ElevenLabs/OpenAI).
    static func classifyHTTPStatus(
        provider: TTSSpeakerProvider,
        statusCode: Int,
        logID: String?,
        route: TTSBillingRoute? = nil
    ) -> TTSSynthesisError {
        switch statusCode {
        case 401, 403:
            return .authentication(
                provider: provider, route: route ?? .payAsYouGo, logID: logID)
        case 402, 429:
            return .quotaOrRateLimited(
                provider: provider, route: route ?? .payAsYouGo, logID: logID)
        default:
            return .httpStatus(provider: provider, statusCode: statusCode, logID: logID)
        }
    }
}

// MARK: - Error normalization (redacted)

/// Collapses any thrown error into a lane-safe `TTSSynthesisError`. Provider
/// or system message TEXT is never carried (it can echo request content or
/// credentials); only categories, numeric codes and sanitized trace IDs.
enum TTSSpeechNormalize {
    static func normalize(_ error: Error, provider: TTSSpeakerProvider) -> Error {
        if let speechError = error as? TTSSynthesisError { return speechError }
        if error is CancellationError { return TTSSynthesisError.cancelled }
        if error is VolcSpeechFrame.DecodeError {
            return TTSSynthesisError.providerRejected(provider: provider, code: nil, logID: nil)
        }
        let ns = error as NSError?
        if ns?.domain == NSURLErrorDomain, ns?.code == NSURLErrorCancelled {
            return TTSSynthesisError.cancelled
        }
        return TTSSynthesisError.transport(provider: provider, failure: TTSTransportFailure(for: error))
    }
}

// MARK: - PCM chunking (sample alignment)

/// Splits PCM payloads at the chunk ceiling while preserving 16-bit sample
/// alignment: every piece EXCEPT the last is even-byte-counted. An odd trailing
/// byte is carried into the next split call by the caller or lands in the last
/// piece; consumers that schedule buffers must tolerate a final odd tail by
/// padding one zero byte (documented in the lane contract).
public enum TTSSpeechPCMChunking {
    public static func split(_ pcm: Data) -> [Data] {
        let limit = TTSSpeechLimits.maxChunkBytes
        guard pcm.count > limit else { return pcm.isEmpty ? [] : [pcm] }
        var pieces: [Data] = []
        var index = pcm.startIndex
        while pcm.distance(from: index, to: pcm.endIndex) > limit {
            let alignedEnd = limit - (limit % 2)
            let end = pcm.index(index, offsetBy: alignedEnd)
            pieces.append(pcm.subdata(in: index..<end))
            index = end
        }
        if index < pcm.endIndex { pieces.append(pcm.subdata(in: index..<pcm.endIndex)) }
        return pieces
    }
}

// MARK: - SSE audio event mapping (shared by Volcengine SSE + Alibaba SSE)

/// One audio-bearing event decoded from a provider SSE data JSON.
public enum TTSSSEAudioEvent: Sendable, Hashable {
    case audio(Data)
    case finished
    case rejected(code: Int?, logID: String?)
}

/// Minimal strict JSON field helpers (no stringified-error fallbacks).
enum TTSSpeechJSON {
    static func dictionary(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func string(_ dict: [String: Any], _ key: String) -> String? {
        dict[key] as? String
    }

    static func int(_ dict: [String: Any], _ key: String) -> Int? {
        if let value = dict[key] as? Int { return value }
        if let value = dict[key] as? NSNumber,
           CFGetTypeID(value) == CFNumberGetTypeID() { return value.intValue }
        if let string = dict[key] as? String, let value = Int(string) { return value }
        return nil
    }

    static func dictionary(_ dict: [String: Any], _ key: String) -> [String: Any]? {
        dict[key] as? [String: Any]
    }

    /// Base64 with common provider variants (standard + whitespace tolerated).
    static func base64Data(_ value: String?) -> Data? {
        guard let value, !value.isEmpty else { return nil }
        let cleaned = value.filter { !$0.isNewline && !$0.isWhitespace }
        return Data(base64Encoded: cleaned)
    }
}
