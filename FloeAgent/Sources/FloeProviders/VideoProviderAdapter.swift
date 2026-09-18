import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore

public struct RemoteVideoRequest: Sendable, Codable, Hashable {
    public var prompt: String
    public var modelRemoteID: String
    public var options: VideoGenerationOptions
    public var referenceAssetURLs: [URL]

    public init(
        prompt: String, modelRemoteID: String,
        options: VideoGenerationOptions = .init(), referenceAssetURLs: [URL] = []
    ) {
        self.prompt = prompt; self.modelRemoteID = modelRemoteID
        self.options = options; self.referenceAssetURLs = referenceAssetURLs
    }
}

public struct RemoteVideoSubmission: Sendable, Codable, Hashable {
    public var providerTaskID: String
    public var estimatedCompletionAt: Date?
    public var resultRetentionExpiresAt: Date?
    public var resultURL: URL?
    public var resultURLExpiresAt: Date?

    public init(
        providerTaskID: String,
        estimatedCompletionAt: Date? = nil,
        resultRetentionExpiresAt: Date? = nil,
        resultURL: URL? = nil,
        resultURLExpiresAt: Date? = nil
    ) {
        self.providerTaskID = providerTaskID
        self.estimatedCompletionAt = estimatedCompletionAt
        self.resultRetentionExpiresAt = resultRetentionExpiresAt
        self.resultURL = resultURL
        self.resultURLExpiresAt = resultURLExpiresAt
    }
}

public struct RemoteVideoStatus: Sendable, Codable, Hashable {
    public var state: MediaGenerationJobState
    public var progress: Double?
    public var resultURL: URL?
    public var resultURLExpiresAt: Date?
    public var error: String?
}

public enum RemoteVideoError: Error, Sendable, Hashable {
    case unsupportedProvider
    case invalidRequest(String)
    case invalidResponse(String)
    case requestFailed(String)
}

extension RemoteVideoError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            "The selected provider does not support video generation."
        case .invalidRequest(let detail):
            "The video request is not valid. \(detail)"
        case .invalidResponse(let detail):
            "The video provider returned an invalid response. \(detail)"
        case .requestFailed(let detail):
            "The video provider could not complete the request. \(detail)"
        }
    }
}

public protocol VideoProviderAdapter: Sendable {
    func submit(
        _ request: RemoteVideoRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteVideoSubmission

    func status(
        taskID: String,
        modelRemoteID: String,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteVideoStatus

    func cancel(
        taskID: String,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws
}

public struct VideoProviderAdapterFactory: Sendable {
    public init() {}
    public func adapter(for provider: ProviderProfile) -> (any VideoProviderAdapter)? {
        switch provider.kind {
        case .googleGemini: GoogleVideoAdapter()
        case .volcengineArk: VolcengineVideoAdapter()
        case .alibabaStudio: AlibabaVideoAdapter()
        case .openAI, .anthropic, .local, .custom: nil
        }
    }
}

private enum VideoHTTP {
    /// API calls carry the provider credential on every request. CFNetwork
    /// forwards request headers across redirects, so a redirect is only
    /// followed when it stays on the same HTTPS host; anything else is
    /// refused instead of leaking the key to a third party.
    private final class SameHostRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        static let shared = SameHostRedirectPolicy()

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            guard let originalHost = task.originalRequest?.url?.host,
                  let target = request.url,
                  target.scheme?.lowercased() == "https",
                  target.user == nil, target.password == nil,
                  let targetHost = target.host,
                  targetHost.caseInsensitiveCompare(originalHost) == .orderedSame else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 900
        return URLSession(
            configuration: configuration,
            delegate: SameHostRedirectPolicy.shared,
            delegateQueue: nil
        )
    }()

    static func request(
        url: URL, method: String = "GET", body: Data? = nil,
        provider: ProviderProfile, credentials: ProviderCredentials,
        googleKey: Bool = false
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let key = credentials.apiKey {
            request.setValue(googleKey ? key : "Bearer \(key)", forHTTPHeaderField: googleKey ? "x-goog-api-key" : "Authorization")
        }
        for (name, value) in provider.nonSecretHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return request
    }

    static func data(for request: URLRequest, secret: String?) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteVideoError.invalidResponse("Provider returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = SecretRedactor.redact(String(decoding: data.prefix(1024), as: UTF8.self), secret: secret)
            throw RemoteVideoError.requestFailed("HTTP \(http.statusCode): \(message)")
        }
        return data
    }

    static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteVideoError.invalidResponse("Provider returned invalid JSON")
        }
        return value
    }
}

public struct GoogleVideoAdapter: VideoProviderAdapter {
    public init() {}
    public func submit(_ request: RemoteVideoRequest, provider: ProviderProfile, credentials: ProviderCredentials) async throws -> RemoteVideoSubmission {
        if request.modelRemoteID.hasPrefix("gemini-omni-") {
            return try await submitOmni(request, provider: provider, credentials: credentials)
        }
        let model = try Self.safeComponent(request.modelRemoteID)
        // Veo lives on the v1beta surface; Interactions/Omni stays on the
        // configured version root. Custom host/prefix is preserved.
        let root = VideoEndpointRouting.googleRoot(baseURL: provider.baseURL, modelRemoteID: request.modelRemoteID)
        let url = root.appendingPathComponent("models/\(model):predictLongRunning")
        let encoded = try JSONSerialization.data(withJSONObject: Self.veoRequestBody(request))
        let data = try await VideoHTTP.data(for: VideoHTTP.request(url: url, method: "POST", body: encoded, provider: provider, credentials: credentials, googleKey: true), secret: credentials.apiKey)
        let json = try VideoHTTP.dictionary(data)
        guard let name = json["name"] as? String, !name.isEmpty else { throw RemoteVideoError.invalidResponse("Google returned no operation name") }
        return .init(providerTaskID: name, estimatedCompletionAt: Date().addingTimeInterval(120), resultRetentionExpiresAt: nil)
    }

    /// Documented Veo request body. The inline reference form is
    /// `instances[].referenceImages[].image.inlineData` (Gemini API Veo
    /// reference, retrieved 2026-09-19); reference images require an
    /// 8-second video, so a conflicting explicit duration is rejected before
    /// the paid call instead of after it.
    static func veoRequestBody(_ request: RemoteVideoRequest) throws -> [String: Any] {
        guard request.referenceAssetURLs.count <= VideoReferenceImagePolicy.maximumAssets else {
            throw RemoteVideoError.invalidRequest("Veo accepts one reference image in this app.")
        }
        var instance: [String: Any] = ["prompt": request.prompt]
        if let reference = request.referenceAssetURLs.first {
            if let duration = request.options.durationSeconds, duration != 8 {
                throw RemoteVideoError.invalidRequest("Veo reference images require durationSeconds 8.")
            }
            let inline = try VideoReferenceImagePolicy.inlineImage(from: reference, providerName: "Google Veo")
            instance["referenceImages"] = [[
                "image": ["inlineData": ["mimeType": inline.mimeType, "data": inline.base64]],
                "referenceType": "asset"
            ]]
        }
        return ["instances": [instance], "parameters": Self.parameters(request.options)]
    }
    public func status(taskID: String, modelRemoteID: String, provider: ProviderProfile, credentials: ProviderCredentials) async throws -> RemoteVideoStatus {
        if modelRemoteID.hasPrefix("gemini-omni-") {
            return try await omniStatus(taskID: taskID, provider: provider, credentials: credentials)
        }
        let root = VideoEndpointRouting.googleRoot(baseURL: provider.baseURL, modelRemoteID: modelRemoteID)
        let url = root.appendingPathComponent(taskID)
        let data = try await VideoHTTP.data(for: VideoHTTP.request(url: url, provider: provider, credentials: credentials, googleKey: true), secret: credentials.apiKey)
        let json = try VideoHTTP.dictionary(data)
        if let error = json["error"] as? [String: Any] { return .init(state: .failed, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: error["message"] as? String) }
        guard json["done"] as? Bool == true else { return .init(state: .running, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: nil) }
        let response = json["response"] as? [String: Any]
        // The Gemini API returns `response.generateVideoResponse.generatedSamples[0].video.uri`
        // (official REST example, retrieved 2026-09-19); Vertex-shaped
        // responses use `response.generatedVideos[0].video`. Both are accepted.
        if let raw = Self.veoVideoURI(response), let uri = URL(string: raw) {
            return .init(state: .completed, progress: 1, resultURL: uri, resultURLExpiresAt: nil, error: nil)
        }
        // A completed operation without a durable download URL is a truthful
        // failure, not a silent "running" state that would poll forever.
        return .init(
            state: .failed, progress: nil, resultURL: nil, resultURLExpiresAt: nil,
            error: "Google completed the operation without a downloadable video URI."
        )
    }

    /// Extracts the download URI from either documented completed-operation
    /// response shape.
    static func veoVideoURI(_ response: [String: Any]?) -> String? {
        if let generated = response?["generateVideoResponse"] as? [String: Any],
           let samples = generated["generatedSamples"] as? [[String: Any]],
           let video = samples.first?["video"] as? [String: Any] {
            if let uri = (video["uri"] as? String) ?? (video["gcsUri"] as? String) { return uri }
        }
        if let videos = response?["generatedVideos"] as? [[String: Any]],
           let video = videos.first?["video"] as? [String: Any] {
            if let uri = (video["uri"] as? String) ?? (video["gcsUri"] as? String) { return uri }
        }
        return nil
    }
    public func cancel(taskID: String, provider: ProviderProfile, credentials: ProviderCredentials) async throws {
        if taskID.hasPrefix("interactions/") { return }
        // Veo operation names (`models/.../operations/...`) are the only
        // cancellable Google tasks that reach this branch, and they always
        // live on the v1beta surface.
        let root = VideoEndpointRouting.googleRoot(baseURL: provider.baseURL, modelRemoteID: "veo")
        let url = root.appendingPathComponent("\(taskID):cancel")
        _ = try await VideoHTTP.data(for: VideoHTTP.request(url: url, method: "POST", body: Data("{}".utf8), provider: provider, credentials: credentials, googleKey: true), secret: credentials.apiKey)
    }
    private static func safeComponent(_ value: String) throws -> String {
        guard value.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil else { throw RemoteVideoError.invalidRequest("Invalid model ID") }
        return value
    }
    private static func parameters(_ options: VideoGenerationOptions) -> [String: Any] {
        var result: [String: Any] = [:]
        if let value = options.aspectRatio { result["aspectRatio"] = value }
        if let value = options.durationSeconds { result["durationSeconds"] = value }
        if let value = options.resolution { result["resolution"] = value }
        if let value = options.includeAudio { result["generateAudio"] = value }
        return result
    }

    private func submitOmni(
        _ request: RemoteVideoRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteVideoSubmission {
        let url = provider.baseURL.appendingPathComponent("interactions")
        let body = try Self.omniRequestBody(request)
        let data = try await VideoHTTP.data(
            for: VideoHTTP.request(
                url: url, method: "POST",
                body: try JSONSerialization.data(withJSONObject: body),
                provider: provider, credentials: credentials, googleKey: true
            ),
            secret: credentials.apiKey
        )
        let json = try VideoHTTP.dictionary(data)
        guard let id = json["id"] as? String, !id.isEmpty else {
            throw RemoteVideoError.invalidResponse("Google Interactions returned no interaction ID")
        }
        // `delivery: uri` returns a Google-hosted file that may still be
        // processing; the poll path waits for the documented ACTIVE state
        // before the durable download starts.
        return .init(
            providerTaskID: "interactions/\(id)",
            estimatedCompletionAt: Date().addingTimeInterval(120),
            resultURL: nil
        )
    }

    /// Documented Omni interaction body. `response_format` carries
    /// `type`/`delivery`/`resolution`/`aspect_ratio`; an input image becomes a
    /// content part and selects the explicit `image_to_video` task instead of
    /// letting the model guess what the image means.
    static func omniRequestBody(_ request: RemoteVideoRequest) throws -> [String: Any] {
        var responseFormat: [String: Any] = ["type": "video", "delivery": "uri"]
        if let resolution = request.options.resolution {
            responseFormat["resolution"] = resolution.lowercased()
        }
        if let ratio = request.options.aspectRatio { responseFormat["aspect_ratio"] = ratio }
        var body: [String: Any] = [
            "model": request.modelRemoteID,
            "response_format": responseFormat
        ]
        var videoConfig: [String: Any] = [:]
        if request.referenceAssetURLs.isEmpty {
            body["input"] = request.prompt
        } else {
            // Interactions take content parts; the image part is the
            // documented inline form (`{"type":"image","data":...,"mime_type":...}`).
            guard request.referenceAssetURLs.count <= VideoReferenceImagePolicy.maximumAssets else {
                throw RemoteVideoError.invalidRequest("Gemini Omni accepts one reference image in this app.")
            }
            var parts: [[String: Any]] = []
            for reference in request.referenceAssetURLs {
                let inline = try VideoReferenceImagePolicy.inlineImage(from: reference, providerName: "Gemini Omni")
                parts.append(["type": "image", "data": inline.base64, "mime_type": inline.mimeType])
            }
            parts.append(["type": "text", "text": request.prompt])
            body["input"] = parts
            videoConfig["task"] = "image_to_video"
        }
        if let duration = request.options.durationSeconds { videoConfig["duration_seconds"] = duration }
        if !videoConfig.isEmpty { body["generation_config"] = ["video_config": videoConfig] }
        return body
    }

    private func omniStatus(
        taskID: String,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteVideoStatus {
        guard taskID.range(of: #"^interactions/[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw RemoteVideoError.invalidRequest("Invalid Google interaction ID")
        }
        let data = try await VideoHTTP.data(
            for: VideoHTTP.request(
                url: provider.baseURL.appendingPathComponent(taskID),
                provider: provider, credentials: credentials, googleKey: true
            ),
            secret: credentials.apiKey
        )
        let json = try VideoHTTP.dictionary(data)
        let status = (json["status"] as? String)?.lowercased() ?? ""
        if status == "failed" {
            return .init(state: .failed, progress: nil, resultURL: nil, resultURLExpiresAt: nil,
                         error: (json["error"] as? [String: Any])?["message"] as? String)
        }
        if let url = Self.omniVideoURL(json) {
            // With URI delivery the returned file must reach ACTIVE before it
            // can be downloaded; polling the interaction alone would move a
            // still-processing file into the download path and fail it.
            return try await Self.omniFileStatus(
                uri: url, provider: provider, credentials: credentials
            )
        }
        if status == "completed" {
            return .init(state: .failed, progress: nil, resultURL: nil, resultURLExpiresAt: nil,
                         error: "Google returned an inline video without a durable download URL.")
        }
        return .init(state: .running, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: nil)
    }

    /// Polls the documented `files/{id}` resource for URI-delivered videos.
    /// `ACTIVE` becomes a completed result; `PROCESSING`/`PENDING` stay
    /// running; `FAILED` is terminal. An older/unknown file surface falls back
    /// to the interaction's own URI so a working download is not blocked by an
    /// unavailable status route.
    private static func omniFileStatus(
        uri: URL,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteVideoStatus {
        let fileID = uri.lastPathComponent
        guard !fileID.isEmpty,
              fileID.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil else {
            return .init(state: .completed, progress: 1, resultURL: uri, resultURLExpiresAt: nil, error: nil)
        }
        // The file resource lives where the provider pointed. Only a Google
        // media host receives the API key; anything else is used directly.
        let statusURL: URL?
        if let host = uri.host, !host.isEmpty {
            statusURL = VideoDownloadRedirectPolicy.isAllowedMediaRedirectHost(host)
                ? uri : nil
        } else {
            let relative = uri.path.hasPrefix("/") ? String(uri.path.dropFirst()) : uri.path
            statusURL = relative.isEmpty
                ? nil : provider.baseURL.appendingPathComponent(relative)
        }
        guard let statusURL else {
            return .init(state: .completed, progress: 1, resultURL: uri, resultURLExpiresAt: nil, error: nil)
        }
        do {
            let data = try await VideoHTTP.data(
                for: VideoHTTP.request(
                    url: statusURL,
                    provider: provider, credentials: credentials, googleKey: true
                ),
                secret: credentials.apiKey
            )
            let json = try VideoHTTP.dictionary(data)
            if let decoded = Self.decodeOmniFileState(json, uri: uri) { return decoded }
            return .init(state: .completed, progress: 1, resultURL: uri, resultURLExpiresAt: nil, error: nil)
        } catch {
            // The file-status route is not available on this base URL; the
            // interaction URI is still the provider's own result and is used
            // as-is rather than losing a completed video.
            return .init(state: .completed, progress: 1, resultURL: uri, resultURLExpiresAt: nil, error: nil)
        }
    }

    /// Pure decision for one `files/{id}` payload. Returns nil when the state
    /// is not one of the documented values so the caller can use the URI.
    static func decodeOmniFileState(_ json: [String: Any], uri: URL) -> RemoteVideoStatus? {
        let state = (json["state"] as? [String: Any])?["name"] as? String
            ?? (json["state"] as? String)
        switch state?.uppercased() {
        case "ACTIVE":
            return .init(state: .completed, progress: 1, resultURL: uri, resultURLExpiresAt: nil, error: nil)
        case "FAILED":
            return .init(state: .failed, progress: nil, resultURL: nil, resultURLExpiresAt: nil,
                         error: (json["error"] as? [String: Any])?["message"] as? String
                            ?? "Google reported the generated video file as FAILED.")
        case "PROCESSING", "PENDING":
            return .init(state: .running, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: nil)
        default:
            return nil
        }
    }

    private static func omniVideoURL(_ json: [String: Any]) -> URL? {
        if let output = json["output_video"] as? [String: Any],
           let raw = output["uri"] as? String, let url = URL(string: raw) { return url }
        guard let steps = json["steps"] as? [[String: Any]] else { return nil }
        for step in steps.reversed() {
            guard let content = step["content"] as? [[String: Any]] else { continue }
            if let raw = content.first(where: { ($0["type"] as? String) == "video" })?["uri"] as? String,
               let url = URL(string: raw) { return url }
        }
        return nil
    }
}

public struct VolcengineVideoAdapter: VideoProviderAdapter {
    public init() {}
    public func submit(_ request: RemoteVideoRequest, provider: ProviderProfile, credentials: ProviderCredentials) async throws -> RemoteVideoSubmission {
        let url = provider.baseURL.appendingPathComponent("contents/generations/tasks")
        let body = try Self.requestBody(request)
        let data = try await VideoHTTP.data(for: VideoHTTP.request(url: url, method: "POST", body: try JSONSerialization.data(withJSONObject: body), provider: provider, credentials: credentials), secret: credentials.apiKey)
        let json = try VideoHTTP.dictionary(data)
        guard let id = json["id"] as? String else { throw RemoteVideoError.invalidResponse("Volcengine returned no task ID") }
        return .init(providerTaskID: id, estimatedCompletionAt: Date().addingTimeInterval(180), resultRetentionExpiresAt: nil)
    }
    static func requestBody(_ request: RemoteVideoRequest) throws -> [String: Any] {
        let latest = request.modelRemoteID.contains("seedance-2-5")
        guard VideoReferenceImagePolicy.supportsReferenceImages(
            providerKind: .volcengineArk, modelRemoteID: request.modelRemoteID
        ) else {
            throw RemoteVideoError.invalidRequest("This Ark model has no verified image input route.")
        }
        guard request.referenceAssetURLs.count <= 1 else { throw RemoteVideoError.invalidRequest("This mode accepts one first-frame image") }
        var content: [[String: Any]] = [["type": "text", "text": request.prompt]]
        if let image = request.referenceAssetURLs.first {
            // Documented url forms for image_url.url: public https URL, base64
            // data URI or asset ID. Local file URLs are never uploaded.
            guard image.scheme?.lowercased() == "https" || image.scheme?.lowercased() == "data" else {
                throw RemoteVideoError.invalidRequest("Upload the reference image before generating video")
            }
            if image.scheme?.lowercased() == "data" {
                _ = try VideoReferenceImagePolicy.inlineImage(from: image, providerName: "Volcengine Ark")
            }
            content.append(["type": "image_url", "image_url": ["url": image.absoluteString], "role": "first_frame"])
        }
        var body: [String: Any] = ["model": request.modelRemoteID, "content": content]
        if let value = request.options.durationSeconds {
            if latest && !(4...30).contains(value) { throw RemoteVideoError.invalidRequest("Seedance 2.5 supports 4–30 seconds") }
            body["duration"] = value
        }
        if latest && !request.referenceAssetURLs.isEmpty { body["ratio"] = "adaptive" }
        else if let value = request.options.aspectRatio { body["ratio"] = value }
        if let value = request.options.resolution {
            if latest && !["480p", "720p", "1080p"].contains(value.lowercased()) { throw RemoteVideoError.invalidRequest("Unsupported Seedance 2.5 resolution") }
            body["resolution"] = value.lowercased()
        }
        if let value = request.options.includeAudio { body["generate_audio"] = value }
        if let value = request.options.watermark { body["watermark"] = value }
        if let value = request.options.seed {
            guard !latest else { throw RemoteVideoError.invalidRequest("Seedance 2.5 does not support a fixed seed") }
            body["seed"] = value
        }
        return body
    }
    public func status(taskID: String, modelRemoteID: String, provider: ProviderProfile, credentials: ProviderCredentials) async throws -> RemoteVideoStatus {
        let data = try await VideoHTTP.data(for: VideoHTTP.request(url: provider.baseURL.appendingPathComponent("contents/generations/tasks/\(taskID)"), provider: provider, credentials: credentials), secret: credentials.apiKey)
        return try Self.decodeStatus(VideoHTTP.dictionary(data))
    }
    public func cancel(taskID: String, provider: ProviderProfile, credentials: ProviderCredentials) async throws {
        _ = try await VideoHTTP.data(for: VideoHTTP.request(url: provider.baseURL.appendingPathComponent("contents/generations/tasks/\(taskID)"), method: "DELETE", provider: provider, credentials: credentials), secret: credentials.apiKey)
    }
    static func decodeStatus(_ json: [String: Any]) throws -> RemoteVideoStatus {
        let status = (json["status"] as? String)?.lowercased() ?? ""
        let content = json["content"] as? [String: Any]
        let url = ((content?["video_url"] ?? json["video_url"]) as? String).flatMap(URL.init(string:))
        let error = Self.errorMessage(json)
        switch status {
        case "succeeded", "completed":
            return .init(
                state: .completed, progress: 1, resultURL: url,
                // Ark keeps the task for 7 days but the signed result URL is
                // documented as valid for 24 hours.
                resultURLExpiresAt: url == nil ? nil : Date().addingTimeInterval(24 * 3600),
                error: nil
            )
        case "failed":
            return .init(state: .failed, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: error)
        case "expired":
            return .init(state: .expired, progress: nil, resultURL: nil, resultURLExpiresAt: nil,
                         error: error ?? "The provider task expired before the result was downloaded.")
        case "cancelled":
            return .init(state: .cancelled, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: nil)
        default:
            return .init(state: .running, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: nil)
        }
    }

    /// Ark reports errors as an object (`{"code": ..., "message": ...}`) on
    /// status/poll responses and as a string on some legacy routes.
    static func errorMessage(_ json: [String: Any]) -> String? {
        if let text = json["error"] as? String, !text.isEmpty { return text }
        if let object = json["error"] as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty {
                if let code = object["code"] as? String, !code.isEmpty { return "\(code): \(message)" }
                return message
            }
        }
        if let message = json["message"] as? String, !message.isEmpty { return message }
        return nil
    }
}

public struct AlibabaVideoAdapter: VideoProviderAdapter {
    public init() {}
    public func submit(_ request: RemoteVideoRequest, provider: ProviderProfile, credentials: ProviderCredentials) async throws -> RemoteVideoSubmission {
        let url = Self.apiRoot(for: provider)
            .appendingPathComponent("services/aigc/video-generation/video-synthesis")
        let body = try Self.requestBody(request)
        var urlRequest = VideoHTTP.request(url: url, method: "POST", body: try JSONSerialization.data(withJSONObject: body), provider: provider, credentials: credentials)
        urlRequest.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        let json = try VideoHTTP.dictionary(try await VideoHTTP.data(for: urlRequest, secret: credentials.apiKey))
        let output = json["output"] as? [String: Any]
        guard let id = output?["task_id"] as? String else { throw RemoteVideoError.invalidResponse("Alibaba returned no task ID") }
        return .init(providerTaskID: id, estimatedCompletionAt: Date().addingTimeInterval(180), resultRetentionExpiresAt: nil)
    }
    static func requestBody(_ request: RemoteVideoRequest) throws -> [String: Any] {
        let latest = request.modelRemoteID.hasPrefix("wan3.0-")
        let modern = latest || request.modelRemoteID.hasPrefix("wan2.7-")
        var input: [String: Any] = ["prompt": request.prompt]
        var parameters: [String: Any] = [:]
        if !request.referenceAssetURLs.isEmpty {
            // Only the 3.x first-frame field has a documented image request in
            // this adapter; other Wan models stay text-only rather than
            // silently dropping the image.
            guard VideoReferenceImagePolicy.supportsReferenceImages(
                providerKind: .alibabaStudio, modelRemoteID: request.modelRemoteID
            ), request.referenceAssetURLs.count == 1,
                  let image = request.referenceAssetURLs.first,
                  image.scheme?.lowercased() == "https" || image.scheme?.lowercased() == "data" else {
                throw RemoteVideoError.invalidRequest("This mode accepts one uploaded Wan 3.0 first-frame image")
            }
            if image.scheme?.lowercased() == "data" {
                _ = try VideoReferenceImagePolicy.inlineImage(from: image, providerName: "DashScope Wan")
            }
            input["media"] = [["type": "first_frame", "url": image.absoluteString]]
            parameters["ratio"] = "adaptive"
        } else if let value = request.options.aspectRatio, modern { parameters["ratio"] = value }
        if let value = request.options.durationSeconds {
            if latest && !(2...30).contains(value) { throw RemoteVideoError.invalidRequest("Wan 3.0 supports 2–30 seconds") }
            parameters["duration"] = value
        }
        if let value = request.options.resolution {
            if latest && !["480P", "720P", "1080P"].contains(value.uppercased()) { throw RemoteVideoError.invalidRequest("Unsupported Wan 3.0 resolution") }
            parameters[modern ? "resolution" : "size"] = modern ? value.uppercased() : value
        }
        if let value = request.options.includeAudio { parameters["audio"] = value }
        if let value = request.options.watermark { parameters["watermark"] = value }
        if let value = request.options.seed { parameters["seed"] = value }
        if let value = request.options.promptOptimization { parameters["prompt_extend"] = value }
        return ["model": request.modelRemoteID, "input": input, "parameters": parameters]
    }
    public func status(taskID: String, modelRemoteID: String, provider: ProviderProfile, credentials: ProviderCredentials) async throws -> RemoteVideoStatus {
        let json = try VideoHTTP.dictionary(try await VideoHTTP.data(for: VideoHTTP.request(url: Self.apiRoot(for: provider).appendingPathComponent("tasks/\(taskID)"), provider: provider, credentials: credentials), secret: credentials.apiKey))
        return try Self.decodeStatus(json)
    }
    static func decodeStatus(_ json: [String: Any]) throws -> RemoteVideoStatus {
        let output = json["output"] as? [String: Any] ?? [:]
        let status = (output["task_status"] as? String)?.uppercased() ?? ""
        let url = (output["video_url"] as? String).flatMap(URL.init(string:))
        let message = Self.errorMessage(json)
        switch status {
        case "SUCCEEDED":
            return .init(
                state: .completed, progress: 1, resultURL: url,
                // DashScope documents the result URL as valid for 24 hours.
                resultURLExpiresAt: url == nil ? nil : Date().addingTimeInterval(24 * 3600),
                error: nil
            )
        case "FAILED":
            return .init(state: .failed, progress: nil, resultURL: nil, resultURLExpiresAt: nil,
                         error: message ?? "The provider reported a failed task without a message.")
        case "CANCELED", "CANCELLED":
            return .init(state: .cancelled, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: nil)
        case "UNKNOWN":
            // Official docs (Model Studio "文生视频" task-query reference,
            // retrieved 2026-09-19): UNKNOWN means "任务不存在或状态未知",
            // and appears when the task_id is unknown or older than its
            // documented 24-hour query validity. Treating it as running would
            // poll forever; reporting it as expired is the documented cause,
            // with the provider's own message attached when present.
            return .init(state: .expired, progress: nil, resultURL: nil, resultURLExpiresAt: nil,
                         error: message ?? "供应商返回 UNKNOWN：任务不存在或状态未知（task_id 查询有效期 24 小时，超时后即为该状态）。")
        default:
            return .init(state: .running, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: nil)
        }
    }
    public func cancel(taskID: String, provider: ProviderProfile, credentials: ProviderCredentials) async throws {
        let url = Self.apiRoot(for: provider).appendingPathComponent("tasks/\(taskID)/cancel")
        _ = try await VideoHTTP.data(for: VideoHTTP.request(url: url, method: "POST", body: Data("{}".utf8), provider: provider, credentials: credentials), secret: credentials.apiKey)
    }

    /// Native DashScope API root. The chat preset points at
    /// `/compatible-mode/v1` and workspace subdomains carry no path; both are
    /// normalized to `{root}/api/v1` while custom hosts are preserved.
    static func apiRoot(for provider: ProviderProfile) -> URL {
        VideoEndpointRouting.dashScopeAPIRoot(baseURL: provider.baseURL)
    }

    /// DashScope reports the failure reason under `output.message` with an
    /// optional `output.code`; some routes also return a top-level `message`.
    static func errorMessage(_ json: [String: Any]) -> String? {
        let output = json["output"] as? [String: Any] ?? [:]
        if let message = output["message"] as? String, !message.isEmpty {
            if let code = output["code"] as? String, !code.isEmpty { return "\(code): \(message)" }
            return message
        }
        if let message = json["message"] as? String, !message.isEmpty { return message }
        return nil
    }
}
