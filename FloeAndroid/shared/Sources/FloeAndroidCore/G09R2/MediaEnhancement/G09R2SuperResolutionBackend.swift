// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 media enhancement — configured cloud super-resolution backend.
//
// True super-resolution runs on the REAL, officially documented fal.ai model
// `fal-ai/bytedance-upscaler/upscale/video`
// (https://fal.ai/models/fal-ai/bytedance-upscaler/upscale/video/api,
// verified 2026-11-03). The transport implements the published fal protocols
// exactly as documented:
//
//  * Queue submit:   POST https://queue.fal.run/{endpoint}
//                    Authorization: Key $FAL_KEY ; body = model input JSON
//                    -> { request_id, response_url, status_url, cancel_url }
//  * Queue status:   GET  {status_url} -> {status: IN_QUEUE|IN_PROGRESS|COMPLETED,
//                                          error?, error_type?}
//  * Queue result:   GET  {response_url} -> model output JSON
//                    ({video: {url, content_type, file_name, file_size}})
//  * Queue cancel:   PUT  {cancel_url} -> {"status":"OK"|"CANCELLATION_REQUESTED"
//                                          |"ALREADY_COMPLETED"|"NOT_FOUND"}
//  * CDN upload:     POST https://rest.fal.ai/storage/upload/initiate
//                      ?storage_type=fal-cdn-v3   {file_name, content_type}
//                    -> {file_url, upload_url} ; PUT {upload_url} (bytes)
//                    Multipart (>90 MiB): initiate-multipart, per-part
//                    PUT {upload_url}/{n}{query} -> etag, then
//                    POST {upload_url}/complete{query} {parts:[{partNumber, etag}]}
//
// Model input contract (official schema): video_url (required),
// scale_ratio (1.1...10, output <= 4k), target_fps (16...60, preserved),
// enhancement_tier (fast|standard|pro), fidelity (high|medium),
// bit_depth (8|10|12; 10/12 require the pro tier).
//
// Enforced invariants (coordinator review 2026-11-03):
//  * The API credential (Authorization: Key) is sent ONLY to the two fixed
//    fal origins (`queue.fal.run`, `rest.fal.ai`) after an exact-host
//    allowlist check of the user-configured profile base URL. Queue
//    status/cancel/result URLs returned by a submit are reused only when they
//    are https and share the submit origin; anything else is refused.
//  * Redirects are never followed silently: the control session forwards only
//    same-origin https redirects and strips Authorization on any redirect;
//    the media session refuses all redirects. Media bytes are fetched from
//    the public fal CDN hosts only (`*.fal.media`, falserverless GCS), never
//    with the provider credential.
//  * The upload initiate answer is validated (https scheme, CDN host
//    allowlist) before any byte is written to the returned upload URL.
//  * Control-plane responses are read through a hard byte cap; uploads stream
//    from disk (single-shot body or 10 MiB multipart chunks); downloads are
//    written to a freshly created staged file in bounded chunks — media bytes
//    are never fully buffered in memory and never written byte-per-syscall.
//  * Every transport or cancellation failure after the backend accepted the
//    submission is surfaced as an unknown outcome carrying the EXACT remote
//    request ID; nothing drops the remote handle.
//  * Status/result/cancel NEVER reuse the full submission subpath: the
//    validated submit-envelope URLs are persisted as a typed accepted handle
//    before the first poll, and legacy records derive the canonical
//    owner/alias URLs exactly per the official fal-js parser (coordinator
//    correction 2026-11-03).
import Foundation
import FloeTransport
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum G09R2SuperResolutionBackendError: Error, Sendable, Equatable {
    /// Definite provider/transport refusal; safe to present and never retried.
    case refused(String)
    /// The provider answer violated the published contract.
    case invalidResponse(String)
}

/// Raised when the backend accepted work but its outcome could not be
/// confirmed. The per-job remote request ID travels with the error.
public struct G09R2SuperResolutionBackendUnknownError: Error, Sendable {
    public var remoteRequestID: String?
    public var acceptedHandle: G09R2SuperResolutionAcceptedHandle?
    public init(remoteRequestID: String? = nil,
                acceptedHandle: G09R2SuperResolutionAcceptedHandle? = nil) {
        self.remoteRequestID = remoteRequestID ?? acceptedHandle?.requestID
        self.acceptedHandle = acceptedHandle
    }
}

/// Crash-durable handle for ONE accepted fal queue request.
///
/// The official fal-js client (`libs/client/src/queue.ts`) never guesses
/// status/result/cancel URLs from the full submission path: it parses the
/// endpoint id into owner/alias (dropping any subpath) and rebuilds
/// `{queueBase}/{owner}/{alias}/requests/{request_id}[...]`. This transport
/// persists the ACTUAL validated URLs returned by the submit envelope
/// (response_url / status_url / cancel_url) so resume and cancel reuse the
/// exact same origins, and falls back to the canonical owner/alias shape
/// only for legacy records that predate the typed handle.
public struct G09R2SuperResolutionAcceptedHandle: Codable, Sendable, Equatable {
    public var requestID: String
    public var responseURL: URL
    public var statusURL: URL
    public var cancelURL: URL

    public init(requestID: String, responseURL: URL, statusURL: URL, cancelURL: URL) {
        self.requestID = requestID
        self.responseURL = responseURL
        self.statusURL = statusURL
        self.cancelURL = cancelURL
    }
}

/// Transport seam. Production uses the fal implementation; focused tests
/// inject a fake. Every call is stateless: the accepted handle is delivered
/// per submission through `onAccepted` (awaited BEFORE the first poll) and
/// returned at completion — it is never stored on shared mutable state.
public protocol G09R2SuperResolutionBackendTransport: Sendable {
    /// Uploads the input and submits the queue request. `onAccepted` is
    /// awaited with the backend's validated handle immediately after the
    /// submit is accepted, BEFORE the first status poll, so the caller can
    /// persist the exact handle durably (a later thrown unknown keeps that
    /// ID; an accepted job is never resubmitted). Then polls to completion
    /// and streams the enhanced media to `destination`. Returns the handle.
    func enhance(
        baseURL: URL,
        apiKey: String,
        input: URL,
        scaleFactor: Int,
        targetFPS: Double?,
        bitDepth: Int,
        destination: URL,
        onAccepted: @escaping @Sendable (G09R2SuperResolutionAcceptedHandle) async throws -> Void,
        progress: @escaping @Sendable (Double) async -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> G09R2SuperResolutionAcceptedHandle

    /// Best-effort cancellation of one exact remote request through its
    /// retained handle (never a guessed URL).
    func cancel(
        baseURL: URL,
        apiKey: String,
        handle: G09R2SuperResolutionAcceptedHandle
    ) async throws

    /// Resumes one previously accepted request using its retained handle:
    /// polls the official status endpoint, then streams the result to
    /// `destination`. Used for crash/relaunch recovery; an accepted or
    /// unknown job is NEVER resubmitted. Returns the same handle.
    func resume(
        baseURL: URL,
        apiKey: String,
        handle: G09R2SuperResolutionAcceptedHandle,
        destination: URL,
        progress: @escaping @Sendable (Double) async -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> G09R2SuperResolutionAcceptedHandle
}

// MARK: - Redirect policies

/// Control-plane policy: forward only same-origin https redirects; strip the
/// Authorization header on any redirect so the credential never crosses an
/// origin boundary. Mirrors the repository's GitHub redirect guard.
final class G09R2FalControlRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https",
              let newHost = request.url?.host?.lowercased(),
              let originalHost = task.originalRequest?.url?.host?.lowercased(),
              newHost == originalHost else {
            completionHandler(nil)
            return
        }
        var forwarded = request
        forwarded.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(forwarded)
    }
}

/// Media-download policy: fal media URLs are direct; refuse every redirect.
final class G09R2FalMediaRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - fal implementation

public final class G09R2FalSuperResolutionBackend: G09R2SuperResolutionBackendTransport, @unchecked Sendable {
    /// Official endpoint, published on the model API page.
    public static let defaultEndpointID = "fal-ai/bytedance-upscaler/upscale/video"

    /// Hosts that may receive the provider credential, exact match.
    static let authenticatedHosts: Set<String> = [
        "queue.fal.run", "rest.fal.ai",
    ]
    /// Public media/CDN hosts whose bytes may be fetched without credentials.
    static let mediaHosts: Set<String> = [
        "fal.media", "v3.fal.media", "v3b.fal.media", "refinery.fal.media",
        "storage.googleapis.com",
    ]
    /// Hosts the storage initiate answer may point at (validated before use).
    static let storageHosts: Set<String> = [
        "fal.media", "v3.fal.media", "v3b.fal.media", "rest.fal.ai",
        "storage.googleapis.com",
    ]

    static let multipartThresholdBytes: Int64 = 90 * 1024 * 1024
    static let multipartChunkBytes = 10 * 1024 * 1024
    static let maximumResultBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let maximumControlBytes = 1024 * 1024
    static let downloadChunkBytes = 1024 * 1024
    static let pollIntervalNanos: UInt64 = 5_000_000_000
    static let maximumPolls = 720 // one hour of polling
    static let maximumUploadBytes: Int64 = 4 * 1024 * 1024 * 1024

    private let controlSession: URLSession
    private let mediaSession: URLSession
    private let endpointID: String

    public init(configuration: URLSessionConfiguration = .default,
                endpointID: String = G09R2FalSuperResolutionBackend.defaultEndpointID) {
        self.controlSession = StreamingTransport.makeSession(
            configuration: configuration,
            policyDelegate: G09R2FalControlRedirectGuard())
        self.mediaSession = StreamingTransport.makeSession(
            configuration: configuration,
            policyDelegate: G09R2FalMediaRedirectGuard())
        self.endpointID = endpointID
    }

    // MARK: enhance

    public func enhance(
        baseURL: URL,
        apiKey: String,
        input: URL,
        scaleFactor: Int,
        targetFPS: Double?,
        bitDepth: Int,
        destination: URL,
        onAccepted: @escaping @Sendable (G09R2SuperResolutionAcceptedHandle) async throws -> Void,
        progress: @escaping @Sendable (Double) async -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> G09R2SuperResolutionAcceptedHandle {
        let queueBase = try Self.authenticatedQueueBase(from: baseURL)
        let credentials = try Self.credentials(apiKey)
        let inputBytes = try Self.boundedFileSize(input)
        if isCancelled() { throw CancellationError() }

        // 1. Upload the input to the fal CDN (streamed; multipart for large).
        let uploadedURL = try await upload(
            file: input, bytes: inputBytes, queueBase: queueBase,
            credentials: credentials, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        await progress(0.05)

        // 2. Submit the queue request (official model input schema). A
        // transport failure here may or may not have reached the queue, so it
        // is reported as unknown with no handle rather than a definite error.
        var body: [String: Any] = [
            "video_url": uploadedURL.absoluteString,
            "scale_ratio": scaleFactor,
            "fidelity": "high",
        ]
        if let targetFPS, targetFPS.isFinite {
            body["target_fps"] = targetFPS
        }
        // 10-bit output requires the pro tier (documented); sent verbatim.
        if bitDepth > 8 {
            body["enhancement_tier"] = "pro"
            body["bit_depth"] = bitDepth
        }
        let submission = try await submit(
            queueBase: queueBase, credentials: credentials, body: body)
        // Persist the accepted handle BEFORE the first subsequent await so a
        // crash here can never lose a known remote ID; a later thrown unknown
        // keeps this ID and the job is never resubmitted.
        let handle = submission.handle
        // From here the backend HAS accepted the request: every failure below
        // retains the exact handle and is reported as an unknown outcome.
        do {
            try await onAccepted(handle)
            if isCancelled() { throw CancellationError() }
            await progress(0.1)

            // 3. Poll the official status endpoint.
            try await poll(
                statusURL: handle.statusURL,
                credentials: credentials,
                isCancelled: isCancelled) { fraction in
                    await progress(0.1 + fraction * 0.6)
                }

            // 4. Fetch the model output JSON from the response URL.
            let output = try await result(
                responseURL: handle.responseURL,
                credentials: credentials)

            // 5. Stream the enhanced media into a freshly staged file.
            try await download(
                mediaURL: output.videoURL,
                destination: destination,
                isCancelled: isCancelled)
            await progress(1)
            return handle
        } catch let unknown as G09R2SuperResolutionBackendUnknownError {
            throw G09R2SuperResolutionBackendUnknownError(
                remoteRequestID: unknown.remoteRequestID ?? handle.requestID, acceptedHandle: handle)
        } catch is CancellationError {
            throw G09R2SuperResolutionBackendUnknownError(
                remoteRequestID: handle.requestID, acceptedHandle: handle)
        } catch let error as G09R2SuperResolutionBackendError {
            if case .refused("backendFailed") = error { throw error }
            throw G09R2SuperResolutionBackendUnknownError(acceptedHandle: handle)
        } catch {
            throw G09R2SuperResolutionBackendUnknownError(acceptedHandle: handle)
        }
    }

    public func cancel(
        baseURL: URL,
        apiKey: String,
        handle: G09R2SuperResolutionAcceptedHandle
    ) async throws {
        let credentials = try Self.credentials(apiKey)
        // The cancel URL comes from the retained handle (validated at submit
        // or derived canonically for legacy records) — never guessed from
        // the full submission subpath.
        try Self.requireSameOriginAuthenticatedQueueBase(baseURL, handle: handle)
        var request = URLRequest(url: handle.cancelURL)
        request.httpMethod = "PUT"
        let (_, http) = try await controlData(for: request, credentials: credentials)
        try requireSuccess(http)
    }

    public func resume(
        baseURL: URL,
        apiKey: String,
        handle: G09R2SuperResolutionAcceptedHandle,
        destination: URL,
        progress: @escaping @Sendable (Double) async -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> G09R2SuperResolutionAcceptedHandle {
        let credentials = try Self.credentials(apiKey)
        try Self.requireSameOriginAuthenticatedQueueBase(baseURL, handle: handle)
        do {
            if isCancelled() { throw CancellationError() }
            try await poll(
                statusURL: handle.statusURL, credentials: credentials,
                isCancelled: isCancelled) { fraction in
                    await progress(0.1 + fraction * 0.6)
                }
            let output = try await result(
                responseURL: handle.responseURL, credentials: credentials)
            try await download(
                mediaURL: output.videoURL, destination: destination,
                isCancelled: isCancelled)
            await progress(1)
            return handle
        } catch let unknown as G09R2SuperResolutionBackendUnknownError {
            throw G09R2SuperResolutionBackendUnknownError(
                remoteRequestID: unknown.remoteRequestID ?? handle.requestID, acceptedHandle: handle)
        } catch is CancellationError {
            throw G09R2SuperResolutionBackendUnknownError(
                remoteRequestID: handle.requestID, acceptedHandle: handle)
        } catch {
            throw error
        }
    }

    // MARK: - Capped control-plane read

    /// Reads one control-plane response under a hard byte cap and returns the
    /// raw HTTP status with the (capped) body — callers map status codes, so
    /// the poll loop can retry the official retryable statuses. Transport
    /// failures and over-cap answers are unknown outcomes / contract refusals,
    /// never unbounded buffers.
    private func controlData(
        for request: URLRequest,
        credentials: String,
        authenticate: Bool = true
    ) async throws -> (Data, HTTPURLResponse) {
        var signed = request
        if authenticate {
            signed.setValue("Key \(credentials)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await StreamingTransport.collect(
                signed, via: controlSession, maxBytes: Self.maximumControlBytes)
        } catch IncrementalTransportError.responseTooLarge {
            throw G09R2SuperResolutionBackendError.invalidResponse("controlResponseTooLarge")
        } catch {
            throw G09R2SuperResolutionBackendUnknownError(remoteRequestID: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            throw G09R2SuperResolutionBackendUnknownError(remoteRequestID: nil)
        }
        return (data, http)
    }

    private func requireSuccess(_ http: HTTPURLResponse) throws {
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 408 || http.statusCode == 429
                || (500...599).contains(http.statusCode) {
                throw G09R2SuperResolutionBackendUnknownError(remoteRequestID: nil)
            }
            throw G09R2SuperResolutionBackendError.refused("http\(http.statusCode)")
        }
    }

    // MARK: - Upload (official fal CDN storage protocol)

    private func upload(
        file: URL, bytes: Int64, queueBase: URL, credentials: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> URL {
        let restBase = Self.authenticatedRestBase(matching: queueBase)
        let contentType = "video/mp4"
        if bytes > Self.multipartThresholdBytes {
            return try await multipartUpload(
                file: file, bytes: bytes, restBase: restBase,
                credentials: credentials, isCancelled: isCancelled)
        }
        // Single-shot: initiate then stream the file body.
        let initiated = try await initiateUpload(
            restBase: restBase, credentials: credentials,
            multipart: false, fileName: file.lastPathComponent,
            contentType: contentType)
        var request = URLRequest(url: initiated.uploadURL)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // The signed CDN upload URL is origin-bound: no provider credential.
        let (_, response) = try await StreamingTransport.collectUpload(
            request, file: file, via: controlSession, maxBytes: Self.maximumControlBytes)
        guard let http = response as? HTTPURLResponse else {
            throw G09R2SuperResolutionBackendUnknownError(remoteRequestID: nil)
        }
        try requireSuccess(http)
        return initiated.fileURL
    }

    private func initiateUpload(
        restBase: URL, credentials: String, multipart: Bool,
        fileName: String, contentType: String
    ) async throws -> (fileURL: URL, uploadURL: URL) {
        var components = URLComponents(
            url: restBase.appendingPathComponent(
                multipart
                    ? "storage/upload/initiate-multipart"
                    : "storage/upload/initiate"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "storage_type", value: "fal-cdn-v3")]
        guard let url = components?.url else {
            throw G09R2SuperResolutionBackendError.invalidResponse("badUploadURL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "file_name": fileName,
            "content_type": contentType,
        ])
        let (data, http) = try await controlData(for: request, credentials: credentials)
        try requireSuccess(http)
        struct Initiated: Decodable {
            var file_url: String
            var upload_url: String
        }
        guard let decoded = try? JSONDecoder().decode(Initiated.self, from: data),
              let fileURL = URL(string: decoded.file_url),
              let uploadURL = URL(string: decoded.upload_url),
              Self.isStorageURL(fileURL),
              Self.isStorageURL(uploadURL) else {
            throw G09R2SuperResolutionBackendError.invalidResponse("badInitiate")
        }
        return (fileURL, uploadURL)
    }

    private func multipartUpload(
        file: URL, bytes: Int64, restBase: URL, credentials: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> URL {
        let initiated = try await initiateUpload(
            restBase: restBase, credentials: credentials, multipart: true,
            fileName: file.lastPathComponent, contentType: "video/mp4")
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let partCount = Int((bytes + Int64(Self.multipartChunkBytes) - 1)
            / Int64(Self.multipartChunkBytes))
        var parts: [(partNumber: Int, etag: String)] = []
        parts.reserveCapacity(partCount)
        for index in 0..<partCount {
            if isCancelled() { throw CancellationError() }
            let offset = UInt64(index * Self.multipartChunkBytes)
            try handle.seek(toOffset: offset)
            let remaining = bytes - Int64(offset)
            let chunkSize = Int(min(Int64(Self.multipartChunkBytes), remaining))
            guard let chunk = try handle.read(upToCount: chunkSize),
                  chunk.count == chunkSize else {
                throw G09R2SuperResolutionBackendError.refused("cdnReadFailed")
            }
            let partURL = Self.partURL(initiated.uploadURL, partNumber: index + 1)
            var request = URLRequest(url: partURL)
            request.httpMethod = "PUT"
            request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
            request.httpBody = chunk
            let (data, response) = try await StreamingTransport.collect(
                request, via: controlSession, maxBytes: Self.maximumControlBytes)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                throw G09R2SuperResolutionBackendError.refused("cdnPartFailed")
            }
            let etag = (try? JSONSerialization.jsonObject(with: data))
                .flatMap { $0 as? [String: Any] }
                .flatMap { $0["etag"] as? String }
                ?? http.value(forHTTPHeaderField: "Etag")
                ?? http.value(forHTTPHeaderField: "ETag")
            guard let etag, !etag.isEmpty else {
                throw G09R2SuperResolutionBackendError.invalidResponse("missingEtag")
            }
            parts.append((index + 1, etag))
        }
        // Complete the upload (signed CDN origin: no provider credential).
        var complete = URLComponents(
            url: initiated.uploadURL, resolvingAgainstBaseURL: false)
        complete?.path += "/complete"
        guard let completeURL = complete?.url else {
            throw G09R2SuperResolutionBackendError.invalidResponse("badCompleteURL")
        }
        var request = URLRequest(url: completeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "parts": parts.map {
                ["partNumber": $0.partNumber, "etag": $0.etag]
            },
        ])
        let (_, response) = try await StreamingTransport.collectUpload(
            request, file: file, via: controlSession, maxBytes: Self.maximumControlBytes)
        guard let http = response as? HTTPURLResponse else {
            throw G09R2SuperResolutionBackendUnknownError(remoteRequestID: nil)
        }
        try requireSuccess(http)
        return initiated.fileURL
    }

    static func partURL(_ uploadURL: URL, partNumber: Int) -> URL {
        var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false)
        components?.path += "/\(partNumber)"
        return components?.url ?? uploadURL.appendingPathComponent("\(partNumber)")
    }

    // MARK: - Queue (official queue.fal.run protocol)

    private struct Submission {
        var handle: G09R2SuperResolutionAcceptedHandle
    }

    private func submit(
        queueBase: URL, credentials: String, body: [String: Any]
    ) async throws -> Submission {
        let url = queueBase.appendingPathComponent(endpointID)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await controlData(for: request, credentials: credentials)
        try requireSuccess(http)
        struct Envelope: Decodable {
            var request_id: String?
            var response_url: String?
            var status_url: String?
            var cancel_url: String?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let requestID = envelope.request_id, !requestID.isEmpty else {
            throw G09R2SuperResolutionBackendUnknownError(remoteRequestID: nil)
        }
        // Reuse the returned URLs only when they are https and share the
        // submit origin; a missing cancel_url falls back to the canonical
        // owner/alias shape (the official fal-js rebuild), never to the full
        // submission subpath.
        let handle: G09R2SuperResolutionAcceptedHandle
        if let responseURL = envelope.response_url.flatMap(URL.init(string:)),
           let statusURL = envelope.status_url.flatMap(URL.init(string:)),
           Self.sameOrigin(responseURL, as: url),
           Self.sameOrigin(statusURL, as: url) {
            let cancelURL: URL
            if let returned = envelope.cancel_url.flatMap(URL.init(string:)),
               Self.sameOrigin(returned, as: url) {
                cancelURL = returned
            } else {
                cancelURL = Self.canonicalQueueURL(
                    queueBase: queueBase, endpointID: endpointID,
                    requestID: requestID, action: .cancel)
            }
            handle = G09R2SuperResolutionAcceptedHandle(
                requestID: requestID, responseURL: responseURL,
                statusURL: statusURL, cancelURL: cancelURL)
        } else {
            handle = Self.canonicalHandle(
                queueBase: queueBase, endpointID: endpointID,
                requestID: requestID)
        }
        return Submission(handle: handle)
    }

    private func poll(
        statusURL: URL,
        credentials: String,
        isCancelled: @escaping @Sendable () -> Bool,
        onFraction: @escaping @Sendable (Double) async -> Void
    ) async throws {
        var polls = 0
        while polls < Self.maximumPolls {
            if isCancelled() { throw CancellationError() }
            polls += 1
            try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
            if isCancelled() { throw CancellationError() }
            var request = URLRequest(url: statusURL)
            let (data, http) = try await controlData(for: request, credentials: credentials)
            if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                continue // bounded retry on the official retryable statuses
            }
            struct Status: Decodable {
                var status: String?
                var error: String?
                var error_type: String?
            }
            guard let status = try? JSONDecoder().decode(Status.self, from: data),
                  let state = status.status else {
                throw G09R2SuperResolutionBackendUnknownError(remoteRequestID: nil)
            }
            switch state {
            case "COMPLETED":
                if status.error != nil || status.error_type != nil {
                    throw G09R2SuperResolutionBackendError.refused("backendFailed")
                }
                return
            case "IN_QUEUE":
                await onFraction(0.1)
                continue
            case "IN_PROGRESS":
                await onFraction(min(0.9, Double(polls) / 60.0))
                continue
            default:
                throw G09R2SuperResolutionBackendUnknownError(remoteRequestID: nil)
            }
        }
        throw G09R2SuperResolutionBackendUnknownError(remoteRequestID: nil)
    }

    private struct ModelOutput {
        var videoURL: URL
    }

    private func result(
        responseURL: URL, credentials: String
    ) async throws -> ModelOutput {
        var request = URLRequest(url: responseURL)
        let (data, http) = try await controlData(for: request, credentials: credentials)
        guard http.statusCode == 200 else {
            throw G09R2SuperResolutionBackendUnknownError(remoteRequestID: nil)
        }
        struct Output: Decodable {
            struct Video: Decodable {
                var url: String?
            }
            var video: Video?
        }
        guard let output = try? JSONDecoder().decode(Output.self, from: data),
              let raw = output.video?.url,
              let url = URL(string: raw),
              Self.isAllowedMediaHost(url) else {
            throw G09R2SuperResolutionBackendUnknownError(remoteRequestID: nil)
        }
        return ModelOutput(videoURL: url)
    }

    // MARK: - Bounded streamed download

    private func download(
        mediaURL: URL, destination: URL,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws {
        var request = URLRequest(url: mediaURL)
        request.httpShouldHandleCookies = false
        let bytes = try StreamingTransport.stream(
            request, via: mediaSession, maxBufferedBytes: 2 * Self.downloadChunkBytes)
        defer { bytes.cancelOwned() }
        let response = try await bytes.response()
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw G09R2SuperResolutionBackendUnknownError(remoteRequestID: nil)
        }
        guard response.expectedContentLength <= Self.maximumResultBytes else {
            throw G09R2SuperResolutionBackendError.refused("resultTooLarge")
        }
        // Fresh staged file: create (or replace) before opening for writing,
        // then stream in bounded chunks — never one syscall per byte.
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw G09R2SuperResolutionBackendError.refused("stagingCreateFailed")
        }
        let handle = try FileHandle(forWritingTo: destination)
        var written: Int64 = 0
        do {
            for try await chunk in bytes {
                if isCancelled() { throw CancellationError() }
                guard Int64(chunk.count) <= Self.maximumResultBytes - written else {
                    throw G09R2SuperResolutionBackendError.refused("resultTooLarge")
                }
                written += Int64(chunk.count)
                try handle.write(contentsOf: chunk)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: - Origin / bound validation

    /// The configured profile must name the official fal queue origin exactly;
    /// the credential never travels anywhere else.
    static func authenticatedQueueBase(from baseURL: URL) throws -> URL {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              let host = components.host?.lowercased(),
              authenticatedHosts.contains(host) else {
            throw G09R2SuperResolutionBackendError.refused(
                "baseURL must be the official https://queue.fal.run origin")
        }
        return URL(string: "https://\(host)")!
    }

    /// Every retained handle URL must stay on the authenticated queue origin
    /// the credential was admitted for; a handle pointing anywhere else is
    /// refused instead of leaking the credential across an origin boundary.
    static func requireSameOriginAuthenticatedQueueBase(
        _ baseURL: URL, handle: G09R2SuperResolutionAcceptedHandle
    ) throws {
        let queueBase = try authenticatedQueueBase(from: baseURL)
        for url in [handle.responseURL, handle.statusURL, handle.cancelURL]
        where !sameOrigin(url, as: queueBase) {
            throw G09R2SuperResolutionBackendError.refused(
                "retained handle points outside the authenticated queue origin")
        }
    }

    static func authenticatedRestBase(matching queueBase: URL) -> URL {
        // The storage REST origin is the fixed official sibling of the queue
        // origin; both are in the authenticated allowlist.
        URL(string: "https://rest.fal.ai")!
    }

    // MARK: - Canonical queue handle (official fal-js derivation)

    /// One canonical queue sub-resource for a request.
    enum CanonicalQueueAction: String {
        case status
        case result
        case cancel
    }

    /// Official endpoint-id parse (`fal-js utils.ts parseEndpointId`):
    /// owner/alias are the first two path segments (or the two segments
    /// after a `workflows`/`comfy` namespace); any remaining subpath is
    /// DROPPED for queue status/result/cancel. The submission URL keeps the
    /// full id; only the derived request URLs use the shortened shape.
    static func parsedEndpoint(_ endpointID: String)
        -> (namespace: String?, owner: String, alias: String)? {
        let parts = endpointID.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard parts.count >= 2 else { return nil }
        let namespaces: Set<String> = ["workflows", "comfy"]
        if namespaces.contains(parts[0]) {
            guard parts.count >= 3 else { return nil }
            return (parts[0], parts[1], parts[2])
        }
        return (nil, parts[0], parts[1])
    }

    /// Builds the canonical queue URL for one request exactly like the
    /// official client: `queueBase/{namespace/}{owner}/{alias}/requests/{id}`
    /// plus the action suffix (`/status`, none for result, `/cancel`).
    static func canonicalQueueURL(
        queueBase: URL, endpointID: String, requestID: String,
        action: CanonicalQueueAction
    ) -> URL {
        guard let parsed = parsedEndpoint(endpointID) else {
            // Unusable configured endpoint: derive with the raw id escaped so
            // the URL stays well-formed; capability validation refuses the
            // configuration before any request is dispatched.
            return queueBase
                .appendingPathComponent(endpointID)
                .appendingPathComponent("requests")
                .appendingPathComponent(requestID)
                .appendingPathComponent(action.rawValue)
        }
        let prefix = parsed.namespace.map { "\($0)/" } ?? ""
        var url = queueBase
            .appendingPathComponent("\(prefix)\(parsed.owner)/\(parsed.alias)")
            .appendingPathComponent("requests")
            .appendingPathComponent(requestID)
        if action != .result {
            url = url.appendingPathComponent(action.rawValue)
        }
        return url
    }

    /// Canonical accepted handle for one request: the exact shape the
    /// official fal-js client rebuilds for status/result/cancel. Used when a
    /// legacy record retained only the request ID, and as the deterministic
    /// contract anchor for focused tests (a subpath endpoint must never leak
    /// its subpath into the derived URLs).
    static func canonicalHandle(
        queueBase: URL, endpointID: String, requestID: String
    ) -> G09R2SuperResolutionAcceptedHandle {
        G09R2SuperResolutionAcceptedHandle(
            requestID: requestID,
            responseURL: canonicalQueueURL(
                queueBase: queueBase, endpointID: endpointID,
                requestID: requestID, action: .result),
            statusURL: canonicalQueueURL(
                queueBase: queueBase, endpointID: endpointID,
                requestID: requestID, action: .status),
            cancelURL: canonicalQueueURL(
                queueBase: queueBase, endpointID: endpointID,
                requestID: requestID, action: .cancel))
    }

    static func sameOrigin(_ url: URL, as other: URL) -> Bool {
        guard let left = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: other, resolvingAgainstBaseURL: false) else {
            return false
        }
        return left.scheme == right.scheme
            && (left.host ?? "").lowercased() == (right.host ?? "").lowercased()
            && effectivePort(left) == effectivePort(right)
    }

    static func isAllowedMediaHost(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              let host = components.host?.lowercased() else { return false }
        return mediaHosts.contains(host) || host.hasSuffix(".fal.media")
    }

    static func isStorageURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https",
              let host = components.host?.lowercased() else { return false }
        return storageHosts.contains(host) || host.hasSuffix(".fal.media")
    }

    private static func effectivePort(_ components: URLComponents) -> Int? {
        components.port ?? ((components.scheme?.lowercased() == "https") ? 443 : 80)
    }

    static func credentials(_ apiKey: String) throws -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256,
              !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw G09R2SuperResolutionBackendError.refused("invalidCredential")
        }
        return trimmed
    }

    static func boundedFileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? Int64) ?? Int64((attributes[.size] as? Int) ?? 0)
        guard size > 0 else {
            throw G09R2SuperResolutionBackendError.refused("emptyInput")
        }
        guard size <= maximumUploadBytes else {
            throw G09R2SuperResolutionBackendError.refused("inputTooLarge")
        }
        return size
    }
}
