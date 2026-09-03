// FloeProviders — Concrete remote image adapters for OpenAI, Volcengine Ark
// and Alibaba Model Studio. Each declares only the operations its provider's
// public image API actually supports; anything else throws
// `unsupportedOperation`. Request/response bodies are redacted before any
// error surface. No credentials are logged.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore

// MARK: - Shared plumbing

/// Builds an authorized JSON POST request and redacts error bodies.
enum RemoteImageHTTP {
    /// Image generation is a bounded, cancellable but intentionally long
    /// non-streaming request. Provider-side sequential batches routinely take
    /// longer than the generic 60–75 second networking defaults.
    static let nonStreamingRequestTimeout: TimeInterval = 300

    static func post(
        url: URL,
        apiKey: String?,
        authHeader: String,
        extraHeaders: [String: String],
        body: some Encodable
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = nonStreamingRequestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey {
            request.setValue("\(authHeader == "x-api-key" ? "" : "Bearer ")\(apiKey)", forHTTPHeaderField: authHeader)
        }
        for (field, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func validate(
        _ response: URLResponse,
        data: Data,
        provider: String,
        apiKey: String?
    ) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteImageError.invalidResponse("\(provider) returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = SecretRedactor.redact(
                String(decoding: data.prefix(512), as: UTF8.self),
                secret: apiKey
            )
            throw RemoteImageError.requestFailed("\(provider) HTTP \(http.statusCode): \(body)")
        }
    }
}

/// Decodes a base64 or URL image payload from a provider response.
enum RemoteImageDecoder {
    private static let maximumImages = 4
    private static let maximumImageBytes = 12 * 1_024 * 1_024

    static func images(from data: Data, b64Key: String, urlKey: String) async throws -> [Data] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = (object?["data"] as? [[String: Any]] ?? []).prefix(maximumImages)
        var images: [Data] = []
        for item in items {
            if let b64 = item[b64Key] as? String, let decoded = Data(base64Encoded: b64) {
                guard decoded.count <= maximumImageBytes else {
                    throw RemoteImageError.invalidResponse("Decoded image exceeds the 12 MiB limit")
                }
                images.append(decoded)
            } else if let urlString = item[urlKey] as? String, let url = URL(string: urlString) {
                guard isAllowedRemoteImageURL(url) else {
                    throw RemoteImageError.invalidResponse("Provider returned an unsafe image URL")
                }
                let request = URLRequest(url: url)
                let delegate = SafeImageRedirectDelegate()
                let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (imageData, response) = try await BoundedHTTP.data(
                    for: request,
                    session: session,
                    maxBytes: maximumImageBytes
                )
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      http.mimeType?.lowercased().hasPrefix("image/") == true else {
                    throw RemoteImageError.invalidResponse("Image download returned a non-image response")
                }
                images.append(imageData)
            }
        }
        return images
    }

    static func isAllowedRemoteImageURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.host != nil,
              !url.isLocalOrPrivateNetwork else { return false }
        return true
    }
}

private final class SafeImageRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>
    private let allowedDomainSuffixes: [String]

    init(allowedHosts: Set<String> = [], allowedDomainSuffixes: [String] = []) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.allowedDomainSuffixes = allowedDomainSuffixes.map { $0.lowercased() }
    }

    private func permits(_ url: URL?) -> Bool {
        guard RemoteImageDecoder.isAllowedRemoteImageURL(url) else { return false }
        guard !allowedHosts.isEmpty || !allowedDomainSuffixes.isEmpty else { return true }
        guard let host = url?.host?.lowercased() else { return false }
        return allowedHosts.contains(host) || allowedDomainSuffixes.contains {
            host == $0 || host.hasSuffix(".\($0)")
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(permits(request.url) ? request : nil)
    }
}

// MARK: - OpenAI

/// OpenAI Images API (`/v1/images/...`). Supports generation and edit;
/// variations and inpainting via the edit endpoint. No upscale.
public struct OpenAIImageAdapter: ImageProviderAdapter {
    private let session: URLSession

    public init() { session = .shared }

    init(session: URLSession) { self.session = session }

    public func supportedOperations(for provider: ProviderProfile) -> Set<RemoteImageOperation> {
        [.generate, .edit, .variation, .inpaint]
    }

    public func maximumSourceImages(
        for operation: RemoteImageOperation,
        modelRemoteID: String?
    ) -> Int {
        guard operation != .generate else { return 0 }
        let model = modelRemoteID?.lowercased() ?? ""
        return model.hasPrefix("gpt-image") ? 16 : 1
    }

    public func maximumOutputImages(modelRemoteID: String?) -> Int { 4 }

    public func perform(
        _ request: RemoteImageRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        guard supports(request.operation, for: provider) else {
            throw RemoteImageError.unsupportedOperation(request.operation, provider: "OpenAI")
        }
        try validateSourceImageCount(request, providerName: "OpenAI")
        try validateOutputImageCount(request, providerName: "OpenAI")
        // OpenAI's images endpoint is multipart for edits; the foundation
        // here performs generation via the JSON endpoint and labels
        // edit-family operations as requiring the multipart path. This keeps
        // the contract honest rather than emulating edits.
        switch request.operation {
        case .generate:
            return try await generate(request, provider: provider, credentials: credentials)
        case .edit, .variation, .inpaint:
            return try await edit(request, provider: provider, credentials: credentials)
        case .upscale, .removeBackground:
            throw RemoteImageError.unsupportedOperation(request.operation, provider: "OpenAI")
        }
    }

    private struct GenerationBody: Encodable {
        var model: String
        var prompt: String
        var n: Int
        var size: String
        var quality: String?
    }

    private func generate(
        _ request: RemoteImageRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        let url = provider.baseURL.appendingPathComponent("images/generations")
        let model = request.modelRemoteID ?? "gpt-image-2"
        let size = try ImageGenerationPresetResolver.nativeSize(
            provider: provider.kind, modelRemoteID: model,
            operation: request.operation, selection: request.selection
        ) ?? "1024x1024"
        let quality = try ImageGenerationPresetResolver.normalizedQuality(
            request.selection.quality, provider: provider.kind
        )
        let body = GenerationBody(
            model: model,
            prompt: request.prompt,
            n: max(1, min(request.count, 4)),
            size: size,
            quality: quality
        )
        let urlRequest = try RemoteImageHTTP.post(
            url: url, apiKey: credentials.apiKey, authHeader: "Authorization",
            extraHeaders: provider.nonSecretHeaders, body: body
        )
        let (data, response) = try await BoundedHTTP.data(
            for: urlRequest,
            session: session,
            maxBytes: 32 * 1_024 * 1_024
        )
        try RemoteImageHTTP.validate(
            response,
            data: data,
            provider: "OpenAI",
            apiKey: credentials.apiKey
        )
        let images = try await RemoteImageDecoder.images(from: data, b64Key: "b64_json", urlKey: "url")
        return RemoteImageResult(images: images)
    }

    private func edit(
        _ request: RemoteImageRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        guard !request.sourceImages.isEmpty else {
            throw RemoteImageError.requestFailed("OpenAI image editing requires a source image")
        }
        let boundary = "FloeImage-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        func file(_ name: String, _ filename: String, _ data: Data) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: image/png\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        let model = request.modelRemoteID ?? "gpt-image-2"
        let size = try ImageGenerationPresetResolver.nativeSize(
            provider: provider.kind, modelRemoteID: model,
            operation: request.operation, selection: request.selection
        ) ?? "1024x1024"
        let quality = try ImageGenerationPresetResolver.normalizedQuality(
            request.selection.quality, provider: provider.kind
        )
        field("model", model)
        field("prompt", request.prompt)
        field("n", String(max(1, min(request.count, 4))))
        field("size", size)
        if let quality { field("quality", quality) }
        let imageField = request.sourceImages.count == 1 ? "image" : "image[]"
        for (index, source) in request.sourceImages.enumerated() {
            file(imageField, "source-\(index + 1).png", source)
        }
        if let mask = request.mask { file("mask", "mask.png", mask) }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var urlRequest = URLRequest(url: provider.baseURL.appendingPathComponent("images/edits"))
        urlRequest.timeoutInterval = RemoteImageHTTP.nonStreamingRequestTimeout
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = credentials.apiKey {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in provider.nonSecretHeaders { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = body
        let (data, response) = try await BoundedHTTP.data(
            for: urlRequest,
            session: session,
            maxBytes: 32 * 1_024 * 1_024
        )
        try RemoteImageHTTP.validate(response, data: data, provider: "OpenAI", apiKey: credentials.apiKey)
        return RemoteImageResult(images: try await RemoteImageDecoder.images(
            from: data, b64Key: "b64_json", urlKey: "url"
        ))
    }
}

// MARK: - Google Gemini native image generation

/// Google Gemini native image API (`models/{model}:generateContent`). Nano
/// Banana models generate and edit through the same multimodal request. The
/// configured base URL is preserved so regional gateways and user proxies can
/// expose the standard path under their own prefix.
public struct GoogleGeminiImageAdapter: ImageProviderAdapter {
    private let session: URLSession
    private static let maximumImageBytes = 12 * 1_024 * 1_024
    private static let maximumRequestBytes = 48 * 1_024 * 1_024

    public init() { session = .shared }

    init(session: URLSession) { self.session = session }

    public func supportedOperations(for provider: ProviderProfile) -> Set<RemoteImageOperation> {
        [.generate, .edit]
    }

    public func maximumSourceImages(
        for operation: RemoteImageOperation,
        modelRemoteID: String?
    ) -> Int {
        guard operation == .edit else { return 0 }
        return modelRemoteID?.lowercased() == "gemini-2.5-flash-image" ? 3 : 14
    }

    public func maximumOutputImages(modelRemoteID: String?) -> Int { 1 }

    public func perform(
        _ request: RemoteImageRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        guard supports(request.operation, for: provider) else {
            throw RemoteImageError.unsupportedOperation(request.operation, provider: "Google Gemini Images")
        }
        try validateSourceImageCount(request, providerName: "Google Gemini Images")
        try validateOutputImageCount(request, providerName: "Google Gemini Images")
        guard let apiKey = credentials.apiKey, !apiKey.isEmpty else {
            throw RemoteImageError.requestFailed("Google Gemini API key is required")
        }
        let model = request.modelRemoteID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = model.flatMap { $0.isEmpty ? nil : $0 } ?? "gemini-3-pro-image"
        guard resolvedModel.range(of: #"^[A-Za-z0-9._-]{1,128}$"#, options: .regularExpression) != nil else {
            throw RemoteImageError.requestFailed("Google Gemini image model ID is invalid")
        }
        if request.operation == .edit, request.sourceImages.isEmpty {
            throw RemoteImageError.requestFailed("Google Gemini image editing requires a source image")
        }
        guard request.sourceImages.allSatisfy({ $0.count <= Self.maximumImageBytes }),
              request.sourceImages.reduce(0, { $0 + $1.count }) <= Self.maximumRequestBytes else {
            throw RemoteImageError.requestFailed("Google Gemini image inputs exceed the bounded request limit")
        }

        var parts = [GeminiPart(text: request.prompt, inlineData: nil)]
        parts.append(contentsOf: request.sourceImages.map {
            GeminiPart(
                text: nil,
                inlineData: GeminiInlineData(
                    mimeType: Self.mimeType(for: $0),
                    data: $0.base64EncodedString()
                )
            )
        })
        let format: GeminiImageFormat?
        if request.selection.aspectRatio != nil || request.selection.resolution != nil {
            let resolution = request.selection.resolution?.uppercased()
            format = GeminiImageFormat(
                aspectRatio: request.selection.aspectRatio,
                imageSize: resolvedModel == "gemini-2.5-flash-image" ? nil : resolution
            )
        } else {
            format = Self.imageFormat(from: request.sizeHint, model: resolvedModel)
        }
        let body = GeminiGenerateBody(
            contents: [GeminiContent(parts: parts)],
            generationConfig: GeminiGenerationConfig(
                responseModalities: ["IMAGE"],
                responseFormat: format.map { GeminiResponseFormat(image: $0) }
            )
        )
        let url = provider.baseURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("\(resolvedModel):generateContent")
        var urlRequest = try RemoteImageHTTP.post(
            url: url,
            apiKey: nil,
            authHeader: "x-goog-api-key",
            extraHeaders: provider.nonSecretHeaders,
            body: body
        )
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, response) = try await BoundedHTTP.data(
            for: urlRequest,
            session: session,
            maxBytes: 48 * 1_024 * 1_024
        )
        try RemoteImageHTTP.validate(
            response,
            data: data,
            provider: "Google Gemini Images",
            apiKey: apiKey
        )
        let decoded = try Self.decodeResponse(data)
        guard !decoded.images.isEmpty else {
            throw RemoteImageError.invalidResponse("Google Gemini returned no image parts")
        }
        return RemoteImageResult(
            images: Array(decoded.images.prefix(max(1, min(request.count, 4)))),
            revisedPrompt: decoded.text.isEmpty ? nil : decoded.text,
            metadata: ["model": resolvedModel]
        )
    }

    private struct GeminiGenerateBody: Encodable {
        let contents: [GeminiContent]
        let generationConfig: GeminiGenerationConfig
    }

    private struct GeminiContent: Encodable { let parts: [GeminiPart] }
    private struct GeminiPart: Encodable {
        let text: String?
        let inlineData: GeminiInlineData?
    }
    private struct GeminiInlineData: Encodable {
        let mimeType: String
        let data: String
    }
    private struct GeminiGenerationConfig: Encodable {
        let responseModalities: [String]
        let responseFormat: GeminiResponseFormat?
    }
    private struct GeminiResponseFormat: Encodable { let image: GeminiImageFormat }
    private struct GeminiImageFormat: Encodable {
        let aspectRatio: String?
        let imageSize: String?
    }

    private static func decodeResponse(_ data: Data) throws -> (images: [Data], text: String) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RemoteImageError.invalidResponse("Google Gemini returned invalid JSON")
        }
        let candidates = root["candidates"] as? [[String: Any]] ?? []
        var images: [Data] = []
        var text: [String] = []
        for candidate in candidates {
            let content = candidate["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            for part in parts {
                if let value = part["text"] as? String, !value.isEmpty { text.append(value) }
                let inline = (part["inlineData"] as? [String: Any])
                    ?? (part["inline_data"] as? [String: Any])
                guard let encoded = inline?["data"] as? String,
                      let image = Data(base64Encoded: encoded) else { continue }
                guard image.count <= maximumImageBytes else {
                    throw RemoteImageError.invalidResponse("Google Gemini image exceeds the 12 MiB limit")
                }
                images.append(image)
                if images.count == 4 { break }
            }
            if images.count == 4 { break }
        }
        return (images, text.joined(separator: "\n"))
    }

    private static func imageFormat(from hint: String?, model: String) -> GeminiImageFormat? {
        guard let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let upper = raw.uppercased()
        if ["512", "1K", "2K", "4K"].contains(upper) {
            return GeminiImageFormat(aspectRatio: nil, imageSize: upper)
        }
        if raw.range(of: #"^\d{1,2}:\d{1,2}$"#, options: .regularExpression) != nil {
            return GeminiImageFormat(aspectRatio: raw, imageSize: nil)
        }
        let dimensions = raw.lowercased().split(separator: "x").compactMap { Int($0) }
        guard dimensions.count == 2, dimensions[0] > 0, dimensions[1] > 0 else { return nil }
        let divisor = greatestCommonDivisor(dimensions[0], dimensions[1])
        let aspect = "\(dimensions[0] / divisor):\(dimensions[1] / divisor)"
        let longest = max(dimensions[0], dimensions[1])
        let size = model == "gemini-2.5-flash-image" ? nil : (longest >= 3_072 ? "4K" : longest >= 1_536 ? "2K" : "1K")
        return GeminiImageFormat(aspectRatio: aspect, imageSize: size)
    }

    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = lhs
        var b = rhs
        while b != 0 { (a, b) = (b, a % b) }
        return max(a, 1)
    }

    private static func mimeType(for data: Data) -> String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "image/webp" }
        return "image/jpeg"
    }
}

// MARK: - Volcengine Ark

/// Volcengine Ark Seedream/SeedEdit endpoints. Generation and edit are
/// supported; other operations are labelled unsupported.
public struct VolcengineImageAdapter: ImageProviderAdapter {
    public init() {}

    public func supportedOperations(for provider: ProviderProfile) -> Set<RemoteImageOperation> {
        [.generate, .edit, .variation, .inpaint]
    }

    public func maximumSourceImages(
        for operation: RemoteImageOperation,
        modelRemoteID: String?
    ) -> Int {
        operation == .generate ? 0 : 10
    }

    public func maximumOutputImages(modelRemoteID: String?) -> Int { 4 }

    public func perform(
        _ request: RemoteImageRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        guard supports(request.operation, for: provider) else {
            throw RemoteImageError.unsupportedOperation(request.operation, provider: "Volcengine Ark")
        }
        try validateSourceImageCount(request, providerName: "Volcengine Ark")
        try validateOutputImageCount(request, providerName: "Volcengine Ark")
        guard let model = request.modelRemoteID, !model.isEmpty else {
            throw RemoteImageError.requestFailed("Volcengine image model ID is required")
        }
        if request.operation != .generate, request.sourceImages.isEmpty {
            throw RemoteImageError.requestFailed("Volcengine image editing requires a source image")
        }
        struct Body: Encodable {
            var model: String
            var prompt: String
            var image: [String]?
            var size: String
            var sequential_image_generation: String
            var sequential_image_generation_options: [String: Int]?
            var response_format: String
            var watermark: Bool
        }
        let images = request.sourceImages.isEmpty ? nil : request.sourceImages.map {
            "data:\(Self.mimeType(for: $0));base64,\($0.base64EncodedString())"
        }
        let count = max(1, min(request.count, 4))
        let nativeSize = try ImageGenerationPresetResolver.nativeSize(
            provider: provider.kind, modelRemoteID: model,
            operation: request.operation, selection: request.selection
        ) ?? "2K"
        let body = Body(
            model: model,
            prompt: request.prompt,
            image: images,
            size: nativeSize,
            sequential_image_generation: count > 1 ? "auto" : "disabled",
            sequential_image_generation_options: count > 1 ? ["max_images": count] : nil,
            response_format: "b64_json",
            watermark: false
        )
        let urlRequest = try RemoteImageHTTP.post(
            url: provider.baseURL.appendingPathComponent("images/generations"),
            apiKey: credentials.apiKey,
            authHeader: "Authorization",
            extraHeaders: provider.nonSecretHeaders,
            body: body
        )
        let (data, response) = try await BoundedHTTP.data(
            for: urlRequest,
            maxBytes: 48 * 1_024 * 1_024
        )
        try RemoteImageHTTP.validate(
            response, data: data, provider: "Volcengine Ark", apiKey: credentials.apiKey
        )
        let output = try await RemoteImageDecoder.images(from: data, b64Key: "b64_json", urlKey: "url")
        guard !output.isEmpty else {
            throw RemoteImageError.invalidResponse("Volcengine returned no images")
        }
        return RemoteImageResult(images: output, metadata: ["model": model])
    }

    private static func mimeType(for data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }
}

// MARK: - DashScope (Alibaba Cloud Model Studio)

/// DashScope image endpoints. Current Wan image models use the multimodal
/// generation endpoint for both generation and editing; older text-to-image
/// models continue through the asynchronous task API.
public struct AlibabaImageAdapter: ImageProviderAdapter {
    private let session: URLSession

    public init() {
        session = .shared
    }

    init(session: URLSession) {
        self.session = session
    }

    private static let maximumPollAttempts = 60
    private static let pollIntervalNanoseconds: UInt64 = 2_000_000_000
    private static let maximumImageBytes = 12 * 1_024 * 1_024

    public func supportedOperations(for provider: ProviderProfile) -> Set<RemoteImageOperation> {
        [.generate, .edit]
    }

    public func maximumSourceImages(
        for operation: RemoteImageOperation,
        modelRemoteID: String?
    ) -> Int {
        guard operation == .edit else { return 0 }
        let model = modelRemoteID?.lowercased() ?? ""
        if model.contains("qwen-image") { return 3 }
        if model.contains("wan2.7") { return 9 }
        if model.contains("wan2.6") { return 4 }
        return 0
    }

    public func maximumOutputImages(modelRemoteID: String?) -> Int { 4 }

    public func perform(
        _ request: RemoteImageRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        guard supports(request.operation, for: provider) else {
            throw RemoteImageError.unsupportedOperation(request.operation, provider: "DashScope")
        }
        try validateSourceImageCount(request, providerName: "DashScope")
        try validateOutputImageCount(request, providerName: "DashScope")
        guard let model = request.modelRemoteID, !model.isEmpty else {
            throw RemoteImageError.requestFailed("DashScope image model ID is required")
        }

        let root = Self.dashScopeRoot(from: provider.baseURL)
        if Self.usesMultimodalImageProtocol(model) {
            return try await performMultimodal(
                request,
                model: model,
                root: root,
                provider: provider,
                credentials: credentials
            )
        }
        guard request.operation == .generate else {
            throw RemoteImageError.requestFailed(
                "DashScope model \(model) does not expose image editing; use wan2.6-image or newer"
            )
        }
        let taskID = try await submitTask(
            request,
            model: model,
            root: root,
            provider: provider,
            credentials: credentials
        )
        let imageURLs = try await pollForResults(
            taskID: taskID,
            root: root,
            provider: provider,
            credentials: credentials
        )
        let images = try await downloadImages(imageURLs, providerHost: root.host)
        guard !images.isEmpty else {
            throw RemoteImageError.invalidResponse("DashScope returned no images")
        }
        return RemoteImageResult(images: images, metadata: ["model": model])
    }

    // MARK: - Current multimodal generation/editing

    private struct MultimodalBody: Encodable {
        struct Input: Encodable {
            struct Message: Encodable {
                struct Content: Encodable {
                    var text: String?
                    var image: String?
                }
                var role: String
                var content: [Content]
            }
            var messages: [Message]
        }
        struct Parameters: Encodable {
            var prompt_extend: Bool
            var watermark: Bool
            var n: Int
            var enable_interleave: Bool
            var size: String
        }

        var model: String
        var input: Input
        var parameters: Parameters
    }

    private func performMultimodal(
        _ request: RemoteImageRequest,
        model: String,
        root: URL,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        if request.operation == .edit, request.sourceImages.isEmpty {
            throw RemoteImageError.requestFailed("DashScope image editing requires a source image")
        }
        var content = [MultimodalBody.Input.Message.Content(
            text: request.prompt,
            image: nil
        )]
        content.append(contentsOf: request.sourceImages.map {
            .init(text: nil, image: Self.imageDataURL($0))
        })
        let nativeSize = try ImageGenerationPresetResolver.nativeSize(
            provider: provider.kind, modelRemoteID: model,
            operation: request.operation, selection: request.selection
        ) ?? "2K"
        let body = MultimodalBody(
            model: model,
            input: .init(messages: [.init(role: "user", content: content)]),
            parameters: .init(
                prompt_extend: true,
                watermark: false,
                n: max(1, min(request.count, 4)),
                enable_interleave: false,
                size: nativeSize
            )
        )
        let apiURL = root
            .appendingPathComponent("api").appendingPathComponent("v1")
            .appendingPathComponent("services").appendingPathComponent("aigc")
            .appendingPathComponent("multimodal-generation").appendingPathComponent("generation")
        let urlRequest = try RemoteImageHTTP.post(
            url: apiURL,
            apiKey: credentials.apiKey,
            authHeader: "Authorization",
            extraHeaders: provider.nonSecretHeaders,
            body: body
        )
        let (data, response) = try await BoundedHTTP.data(
            for: urlRequest,
            session: session,
            maxBytes: 2 * 1_024 * 1_024
        )
        try RemoteImageHTTP.validate(
            response, data: data, provider: "DashScope", apiKey: credentials.apiKey
        )
        let urls = try Self.multimodalImageURLs(from: data)
        let images = try await downloadImages(urls, providerHost: root.host)
        guard !images.isEmpty else {
            throw RemoteImageError.invalidResponse("DashScope returned no images")
        }
        return RemoteImageResult(images: images, metadata: ["model": model])
    }

    // MARK: - Task submission

    private struct LegacySubmitBody: Encodable {
        struct Input: Encodable { var prompt: String }
        struct Parameters: Encodable { var size: String; var n: Int }

        var model: String
        var input: Input
        var parameters: Parameters
    }

    private struct Wan26SubmitBody: Encodable {
        struct Input: Encodable {
            struct Message: Encodable {
                struct Content: Encodable { var text: String }
                var role: String
                var content: [Content]
            }
            var messages: [Message]
        }
        struct Parameters: Encodable {
            var size: String
            var n: Int
            var prompt_extend: Bool
            var watermark: Bool
        }

        var model: String
        var input: Input
        var parameters: Parameters
    }

    private func submitTask(
        _ request: RemoteImageRequest,
        model: String,
        root: URL,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> String {
        let apiRoot = root
            .appendingPathComponent("api").appendingPathComponent("v1")
            .appendingPathComponent("services").appendingPathComponent("aigc")
        let count = max(1, min(request.count, 4))
        if Self.usesWan26Protocol(model) {
            let nativeSize = if request.sizeHint == nil,
                                request.selection.aspectRatio == nil,
                                request.selection.resolution == nil {
                "1280*1280"
            } else {
                try ImageGenerationPresetResolver.nativeSize(
                    provider: provider.kind, modelRemoteID: model,
                    operation: request.operation, selection: request.selection
                ) ?? "1280*1280"
            }
            let body = Wan26SubmitBody(
                model: model,
                input: .init(messages: [
                    .init(role: "user", content: [.init(text: request.prompt)])
                ]),
                parameters: .init(
                    size: nativeSize,
                    n: count,
                    prompt_extend: true,
                    watermark: false
                )
            )
            return try await postTask(
                url: apiRoot.appendingPathComponent("image-generation").appendingPathComponent("generation"),
                body: body,
                provider: provider,
                credentials: credentials
            )
        }

        let nativeSize = if request.sizeHint == nil,
                            request.selection.aspectRatio == nil,
                            request.selection.resolution == nil {
            "1024*1024"
        } else {
            try ImageGenerationPresetResolver.nativeSize(
                provider: provider.kind, modelRemoteID: model,
                operation: request.operation, selection: request.selection
            ) ?? "1024*1024"
        }
        let body = LegacySubmitBody(
            model: model,
            input: .init(prompt: request.prompt),
            parameters: .init(
                size: nativeSize,
                n: count
            )
        )
        return try await postTask(
            url: apiRoot.appendingPathComponent("text2image").appendingPathComponent("image-synthesis"),
            body: body,
            provider: provider,
            credentials: credentials
        )
    }

    private func postTask(
        url: URL,
        body: some Encodable,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> String {
        let urlRequest = try RemoteImageHTTP.post(
            url: url,
            apiKey: credentials.apiKey,
            authHeader: "Authorization",
            extraHeaders: provider.nonSecretHeaders.merging(
                ["X-DashScope-Async": "enable"], uniquingKeysWith: { _, new in new }
            ),
            body: body
        )
        let (data, response) = try await BoundedHTTP.data(
            for: urlRequest,
            session: session,
            maxBytes: 1_048_576
        )
        try RemoteImageHTTP.validate(
            response, data: data, provider: "DashScope", apiKey: credentials.apiKey
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let output = object?["output"] as? [String: Any],
              let taskID = output["task_id"] as? String, !taskID.isEmpty else {
            throw RemoteImageError.invalidResponse("DashScope task submission returned no task ID")
        }
        return taskID
    }

    // MARK: - Polling

    private func pollForResults(
        taskID: String,
        root: URL,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [URL] {
        let taskURL = root
            .appendingPathComponent("api").appendingPathComponent("v1")
            .appendingPathComponent("tasks").appendingPathComponent(taskID)

        for _ in 0..<Self.maximumPollAttempts {
            try Task.checkCancellation()
            var request = URLRequest(url: taskURL)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let key = credentials.apiKey {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            for (field, value) in provider.nonSecretHeaders {
                request.setValue(value, forHTTPHeaderField: field)
            }
            let (data, response) = try await BoundedHTTP.data(
                for: request,
                session: session,
                maxBytes: 1_048_576
            )
            try RemoteImageHTTP.validate(
                response, data: data, provider: "DashScope", apiKey: credentials.apiKey
            )
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let output = object?["output"] as? [String: Any]
            let status = output?["task_status"] as? String ?? "UNKNOWN"
            switch status {
            case "SUCCEEDED":
                let results = output?["results"] as? [[String: Any]] ?? []
                return results.compactMap {
                    ($0["url"] as? String).flatMap(URL.init(string:))
                }
            case "FAILED", "CANCELED", "CANCELLED":
                throw RemoteImageError.requestFailed("DashScope image task \(status)")
            default:
                try await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            }
        }
        throw RemoteImageError.requestFailed("DashScope image task timed out")
    }

    // MARK: - Download

    private func downloadImages(_ urls: [URL], providerHost: String?) async throws -> [Data] {
        var images: [Data] = []
        for url in urls.prefix(4) {
            try Task.checkCancellation()
            guard Self.isAllowedResultURL(url, providerHost: providerHost) else {
                throw RemoteImageError.invalidResponse("DashScope returned an unsafe image URL")
            }
            let request = URLRequest(url: url)
            let delegate = SafeImageRedirectDelegate(
                allowedHosts: Set([providerHost].compactMap { $0 }),
                allowedDomainSuffixes: ["aliyuncs.com"]
            )
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (imageData, response) = try await BoundedHTTP.data(
                for: request, session: session, maxBytes: Self.maximumImageBytes
            )
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.mimeType?.lowercased().hasPrefix("image/") == true else {
                throw RemoteImageError.invalidResponse("DashScope image download returned a non-image response")
            }
            images.append(imageData)
        }
        return images
    }

    // MARK: - Helpers

    /// The native DashScope API lives on the provider host root, not under the
    /// OpenAI-compatible `/compatible-mode/v1` prefix used for chat.
    private static func dashScopeRoot(from baseURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        return components.url ?? baseURL
    }

    /// DashScope sizes use an asterisk (`1024*1024`); normalise the common
    /// `1024x1024` spelling so a user-entered hint still parses.
    private static func usesWan26Protocol(_ model: String) -> Bool {
        model.lowercased().hasPrefix("wan2.6-t2i")
    }

    private static func usesMultimodalImageProtocol(_ model: String) -> Bool {
        let normalized = model.lowercased()
        return normalized.hasPrefix("wan2.6-image")
            || normalized.hasPrefix("wan2.7-image")
            || normalized.hasPrefix("qwen-image-3")
    }

    private static func imageDataURL(_ data: Data) -> String {
        let mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func multimodalImageURLs(from data: Data) throws -> [URL] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let output = object?["output"] as? [String: Any]
        let choices = output?["choices"] as? [[String: Any]] ?? []
        return choices.flatMap { choice -> [URL] in
            let message = choice["message"] as? [String: Any]
            let content = message?["content"] as? [[String: Any]] ?? []
            return content.compactMap { item in
                (item["image"] as? String).flatMap(URL.init(string:))
            }
        }
    }

    private static func isAllowedResultURL(_ url: URL, providerHost: String?) -> Bool {
        guard RemoteImageDecoder.isAllowedRemoteImageURL(url),
              let host = url.host?.lowercased() else { return false }
        let configuredHost = providerHost?.lowercased()
        return host == configuredHost || host == "aliyuncs.com" || host.hasSuffix(".aliyuncs.com")
    }

    private static func normalizedSize(_ hint: String?, defaultValue: String) -> String {
        let raw = (hint?.isEmpty == false ? hint! : defaultValue)
        return raw.replacingOccurrences(of: "x", with: "*")
            .replacingOccurrences(of: "X", with: "*")
    }
}
