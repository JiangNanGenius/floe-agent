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
        let (data, response) = try await URLSession.shared.data(for: request)
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
        let url = provider.baseURL.appendingPathComponent("models/\(model):predictLongRunning")
        let body: [String: Any] = ["instances": [["prompt": request.prompt]], "parameters": Self.parameters(request.options)]
        let encoded = try JSONSerialization.data(withJSONObject: body)
        let data = try await VideoHTTP.data(for: VideoHTTP.request(url: url, method: "POST", body: encoded, provider: provider, credentials: credentials, googleKey: true), secret: credentials.apiKey)
        let json = try VideoHTTP.dictionary(data)
        guard let name = json["name"] as? String, !name.isEmpty else { throw RemoteVideoError.invalidResponse("Google returned no operation name") }
        return .init(providerTaskID: name, estimatedCompletionAt: Date().addingTimeInterval(120), resultRetentionExpiresAt: nil)
    }
    public func status(taskID: String, modelRemoteID: String, provider: ProviderProfile, credentials: ProviderCredentials) async throws -> RemoteVideoStatus {
        if modelRemoteID.hasPrefix("gemini-omni-") {
            return try await omniStatus(taskID: taskID, provider: provider, credentials: credentials)
        }
        let url = provider.baseURL.appendingPathComponent(taskID)
        let data = try await VideoHTTP.data(for: VideoHTTP.request(url: url, provider: provider, credentials: credentials, googleKey: true), secret: credentials.apiKey)
        let json = try VideoHTTP.dictionary(data)
        if let error = json["error"] as? [String: Any] { return .init(state: .failed, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: error["message"] as? String) }
        guard json["done"] as? Bool == true else { return .init(state: .running, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: nil) }
        let response = json["response"] as? [String: Any]
        let videos = response?["generatedVideos"] as? [[String: Any]]
        let video = videos?.first?["video"] as? [String: Any]
        let uri = (video?["uri"] as? String).flatMap(URL.init(string:))
        return .init(state: .completed, progress: 1, resultURL: uri, resultURLExpiresAt: nil, error: nil)
    }
    public func cancel(taskID: String, provider: ProviderProfile, credentials: ProviderCredentials) async throws {
        if taskID.hasPrefix("interactions/") { return }
        let url = provider.baseURL.appendingPathComponent("\(taskID):cancel")
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
        var responseFormat: [String: Any] = ["type": "video", "delivery": "uri"]
        if let resolution = request.options.resolution {
            responseFormat["resolution"] = resolution.lowercased()
        }
        var body: [String: Any] = [
            "model": request.modelRemoteID,
            "input": request.prompt,
            "response_format": responseFormat
        ]
        var videoConfig: [String: Any] = [:]
        if let ratio = request.options.aspectRatio { videoConfig["aspect_ratio"] = ratio }
        if let duration = request.options.durationSeconds { videoConfig["duration_seconds"] = duration }
        if !videoConfig.isEmpty { body["generation_config"] = ["video_config": videoConfig] }
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
        let resultURL = Self.omniVideoURL(json)
        return .init(
            providerTaskID: "interactions/\(id)",
            estimatedCompletionAt: resultURL == nil ? Date().addingTimeInterval(120) : Date(),
            resultURL: resultURL
        )
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
            return .init(state: .completed, progress: 1, resultURL: url, resultURLExpiresAt: nil, error: nil)
        }
        if status == "completed" {
            return .init(state: .failed, progress: nil, resultURL: nil, resultURLExpiresAt: nil,
                         error: "Google returned an inline video without a durable download URL.")
        }
        return .init(state: .running, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: nil)
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
        var body: [String: Any] = ["model": request.modelRemoteID, "content": [["type": "text", "text": request.prompt]]]
        if let duration = request.options.durationSeconds { body["duration"] = duration }
        if let ratio = request.options.aspectRatio { body["ratio"] = ratio }
        if let resolution = request.options.resolution { body["resolution"] = resolution }
        let data = try await VideoHTTP.data(for: VideoHTTP.request(url: url, method: "POST", body: try JSONSerialization.data(withJSONObject: body), provider: provider, credentials: credentials), secret: credentials.apiKey)
        let json = try VideoHTTP.dictionary(data)
        guard let id = json["id"] as? String else { throw RemoteVideoError.invalidResponse("Volcengine returned no task ID") }
        return .init(providerTaskID: id, estimatedCompletionAt: Date().addingTimeInterval(180), resultRetentionExpiresAt: nil)
    }
    public func status(taskID: String, modelRemoteID: String, provider: ProviderProfile, credentials: ProviderCredentials) async throws -> RemoteVideoStatus {
        let data = try await VideoHTTP.data(for: VideoHTTP.request(url: provider.baseURL.appendingPathComponent("contents/generations/tasks/\(taskID)"), provider: provider, credentials: credentials), secret: credentials.apiKey)
        return try Self.decodeStatus(VideoHTTP.dictionary(data))
    }
    public func cancel(taskID: String, provider: ProviderProfile, credentials: ProviderCredentials) async throws {
        _ = try await VideoHTTP.data(for: VideoHTTP.request(url: provider.baseURL.appendingPathComponent("contents/generations/tasks/\(taskID)"), method: "DELETE", provider: provider, credentials: credentials), secret: credentials.apiKey)
    }
    private static func decodeStatus(_ json: [String: Any]) throws -> RemoteVideoStatus {
        let status = (json["status"] as? String)?.lowercased() ?? ""
        let content = json["content"] as? [String: Any]
        let url = ((content?["video_url"] ?? json["video_url"]) as? String).flatMap(URL.init(string:))
        switch status {
        case "succeeded", "completed": return .init(state: .completed, progress: 1, resultURL: url, resultURLExpiresAt: nil, error: nil)
        case "failed": return .init(state: .failed, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: json["error"] as? String)
        case "cancelled": return .init(state: .cancelled, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: nil)
        default: return .init(state: .running, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: nil)
        }
    }
}

public struct AlibabaVideoAdapter: VideoProviderAdapter {
    public init() {}
    public func submit(_ request: RemoteVideoRequest, provider: ProviderProfile, credentials: ProviderCredentials) async throws -> RemoteVideoSubmission {
        let url = provider.baseURL.appendingPathComponent("services/aigc/video-generation/video-synthesis")
        let body: [String: Any] = ["model": request.modelRemoteID, "input": ["prompt": request.prompt], "parameters": ["duration": request.options.durationSeconds as Any, "size": request.options.resolution as Any]]
        var urlRequest = VideoHTTP.request(url: url, method: "POST", body: try JSONSerialization.data(withJSONObject: body), provider: provider, credentials: credentials)
        urlRequest.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
        let json = try VideoHTTP.dictionary(try await VideoHTTP.data(for: urlRequest, secret: credentials.apiKey))
        let output = json["output"] as? [String: Any]
        guard let id = output?["task_id"] as? String else { throw RemoteVideoError.invalidResponse("Alibaba returned no task ID") }
        return .init(providerTaskID: id, estimatedCompletionAt: Date().addingTimeInterval(180), resultRetentionExpiresAt: nil)
    }
    public func status(taskID: String, modelRemoteID: String, provider: ProviderProfile, credentials: ProviderCredentials) async throws -> RemoteVideoStatus {
        let json = try VideoHTTP.dictionary(try await VideoHTTP.data(for: VideoHTTP.request(url: provider.baseURL.appendingPathComponent("tasks/\(taskID)"), provider: provider, credentials: credentials), secret: credentials.apiKey))
        let output = json["output"] as? [String: Any] ?? [:]
        let status = (output["task_status"] as? String)?.uppercased() ?? ""
        let url = (output["video_url"] as? String).flatMap(URL.init(string:))
        switch status {
        case "SUCCEEDED": return .init(state: .completed, progress: 1, resultURL: url, resultURLExpiresAt: nil, error: nil)
        case "FAILED": return .init(state: .failed, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: output["message"] as? String)
        case "CANCELED", "CANCELLED": return .init(state: .cancelled, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: nil)
        default: return .init(state: .running, progress: nil, resultURL: nil, resultURLExpiresAt: nil, error: nil)
        }
    }
    public func cancel(taskID: String, provider: ProviderProfile, credentials: ProviderCredentials) async throws {
        let url = provider.baseURL.appendingPathComponent("tasks/\(taskID)/cancel")
        _ = try await VideoHTTP.data(for: VideoHTTP.request(url: url, method: "POST", body: Data("{}".utf8), provider: provider, credentials: credentials), secret: credentials.apiKey)
    }
}
