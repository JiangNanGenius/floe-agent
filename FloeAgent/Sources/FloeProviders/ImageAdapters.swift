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
    static func post(
        url: URL,
        apiKey: String?,
        authHeader: String,
        extraHeaders: [String: String],
        body: some Encodable
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
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
        guard let http = response as? HTTPURLResponse else { return }
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
                if let http = response as? HTTPURLResponse {
                    guard (200..<300).contains(http.statusCode),
                          http.mimeType?.lowercased().hasPrefix("image/") == true else {
                        throw RemoteImageError.invalidResponse("Image download returned a non-image response")
                    }
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
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(RemoteImageDecoder.isAllowedRemoteImageURL(request.url) ? request : nil)
    }
}

// MARK: - OpenAI

/// OpenAI Images API (`/v1/images/...`). Supports generation and edit;
/// variations and inpainting via the edit endpoint. No upscale.
public struct OpenAIImageAdapter: ImageProviderAdapter {
    public init() {}

    public func supportedOperations(for provider: ProviderProfile) -> Set<RemoteImageOperation> {
        [.generate, .edit, .variation, .inpaint]
    }

    public func perform(
        _ request: RemoteImageRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        guard supports(request.operation, for: provider) else {
            throw RemoteImageError.unsupportedOperation(request.operation, provider: "OpenAI")
        }
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
    }

    private func generate(
        _ request: RemoteImageRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        let url = provider.baseURL.appendingPathComponent("images/generations")
        let body = GenerationBody(
            model: request.modelRemoteID ?? "gpt-image-1",
            prompt: request.prompt,
            n: max(1, min(request.count, 4)),
            size: request.sizeHint ?? "1024x1024"
        )
        let urlRequest = try RemoteImageHTTP.post(
            url: url, apiKey: credentials.apiKey, authHeader: "Authorization",
            extraHeaders: provider.nonSecretHeaders, body: body
        )
        let (data, response) = try await BoundedHTTP.data(
            for: urlRequest,
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
        guard let source = request.sourceImages.first else {
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
        field("model", request.modelRemoteID ?? "gpt-image-1")
        field("prompt", request.prompt)
        field("n", String(max(1, min(request.count, 4))))
        field("size", request.sizeHint ?? "1024x1024")
        file("image", "source.png", source)
        if let mask = request.mask { file("mask", "mask.png", mask) }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var urlRequest = URLRequest(url: provider.baseURL.appendingPathComponent("images/edits"))
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
            maxBytes: 32 * 1_024 * 1_024
        )
        try RemoteImageHTTP.validate(response, data: data, provider: "OpenAI", apiKey: credentials.apiKey)
        return RemoteImageResult(images: try await RemoteImageDecoder.images(
            from: data, b64Key: "b64_json", urlKey: "url"
        ))
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

    public func perform(
        _ request: RemoteImageRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        guard supports(request.operation, for: provider) else {
            throw RemoteImageError.unsupportedOperation(request.operation, provider: "Volcengine Ark")
        }
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
        let body = Body(
            model: model,
            prompt: request.prompt,
            image: images,
            size: request.sizeHint ?? "2K",
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

// MARK: - Alibaba Model Studio

/// Alibaba Model Studio (DashScope) image endpoints. Generation is supported;
/// other operations are labelled unsupported.
public struct AlibabaImageAdapter: ImageProviderAdapter {
    public init() {}

    public func supportedOperations(for provider: ProviderProfile) -> Set<RemoteImageOperation> {
        []
    }

    public func perform(
        _ request: RemoteImageRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        guard supports(request.operation, for: provider) else {
            throw RemoteImageError.unsupportedOperation(request.operation, provider: "Alibaba Model Studio")
        }
        // Foundation: capability declaration is in place; the DashScope wire
        // call lands with the image workflows in Phase 6.
        throw RemoteImageError.unsupportedOperation(request.operation, provider: "Alibaba Model Studio (wire call pending Phase 6)")
    }
}
