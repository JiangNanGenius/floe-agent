// FloeProviders — Kimi Code (Moonshot Coding Plan) remote image adapter.
//
// Protocol grounding — read-only reference evidence from the OpenMinis
// implementation (GitHub OpenMinis/OpenMinis, immutable commit
// b4c0661d5631ebab4d1a2e6f3fd4c805d4030a6c, GPL-3.0; no upstream code was
// copied or executed — this adapter is an independent Floe implementation of
// the factual wire protocol):
//   * src/ios/Providers/ProviderTypes.swift:16-21 — the `kimiCode` provider
//     type is an OpenAI-compatible coding upstream reached with the device
//     OAuth bearer (or a plain API key bearer) through the shared OpenAI
//     transport.
//   * src/ios/Providers/LLMProviderFactory.swift:375-381 — default base
//     `https://api.kimi.com/coding` with `/v1` appended; the real endpoints
//     live under `/coding/v1/…` (bare `/coding/chat/completions` 404s).
//   * src/ios/Providers/ProviderInstance.swift:236-246 — `.kimiCode`
//     image-output models flow through the shared OpenAI-compatible image
//     route (`/v1/images/generations` vs `/v1/chat/completions`).
//   * src/ios/NativeOffloads/ModelUseOffloadBridge.swift:513-723 and
//     1607-1617 — the image request is ONE synchronous POST to
//     `/v1/images/generations` (multipart `/v1/images/edits` when input
//     images exist). A missing images route is recognised by a 404/405 or a
//     chat-completion-shaped body; there is no async job/polling protocol
//     anywhere on this path, so this adapter polls nothing. Upstream's "auto"
//     endpoint mode additionally falls back to streaming chat-completions
//     image output on the SAME provider. Floe deliberately exposes ONLY the
//     direct images route from this tool: a missing route is surfaced as a
//     route-fallback-eligible refusal (the existing service may switch to
//     another configured image provider), and chat text is NEVER converted
//     into a fabricated image success here.
//   * src/ios/Providers/OpenAI/OpenAIProvider.swift:1697-1866 — request
//     `{model, prompt, n, size?, quality?, response_format:"b64_json"}`; a
//     400 that names `response_format`/`b64_json` is retried once WITHOUT
//     the field; response `{data:[{b64_json|url, revised_prompt}]}` with
//     `url` payloads downloaded by the client.
//
// Capability honesty: the upstream never demonstrates Kimi-specific batch
// (`n > 1`) or multi-reference editing, so this adapter pins one output per
// request and exactly one edit reference. `size` is transmitted only when it
// is an explicit WxH dimension; unverified labels such as `2K` or `16:9`
// never cross the wire. Chat-completions image output for a Kimi model is
// conversation-path behaviour, not this tool: when the images endpoint
// answers with a chat shape, the adapter reports the route as missing
// instead of emulating success. Credentials resolve from the Keychain at the
// call site and are never logged.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FloeCore

public struct KimiImageAdapter: ImageProviderAdapter {
    private let session: URLSession

    public init() { session = .shared }

    init(session: URLSession) { self.session = session }

    public func supportedOperations(for provider: ProviderProfile) -> Set<RemoteImageOperation> {
        [.generate, .edit]
    }

    public func maximumSourceImages(
        for operation: RemoteImageOperation,
        modelRemoteID: String?
    ) -> Int {
        operation == .edit ? 1 : 0
    }

    public func maximumOutputImages(modelRemoteID: String?) -> Int { 1 }

    public func perform(
        _ request: RemoteImageRequest,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        guard supports(request.operation, for: provider) else {
            throw RemoteImageError.unsupportedOperation(request.operation, provider: "Kimi Code")
        }
        // Defense in depth: only the evidenced Coding Plan route variants are
        // executable, even if this adapter is constructed directly instead of
        // through the factory identity gate.
        guard let root = KimiCodeEndpointIdentity.apiRoot(for: provider) else {
            throw RemoteImageError.requestFailed(
                "Kimi Code base URL is not a verified Coding Plan route (api.kimi.com /coding or /coding/v1, HTTPS)"
            )
        }
        try validateSourceImageCount(request, providerName: "Kimi Code")
        try validateOutputImageCount(request, providerName: "Kimi Code")
        guard let model = request.modelRemoteID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else {
            throw RemoteImageError.requestFailed("Kimi Code image model ID is required")
        }
        switch request.operation {
        case .generate:
            return try await performGenerate(request, model: model, root: root, provider: provider, credentials: credentials)
        case .edit:
            return try await performEdit(request, model: model, root: root, provider: provider, credentials: credentials)
        case .variation, .inpaint, .upscale, .removeBackground:
            throw RemoteImageError.unsupportedOperation(request.operation, provider: "Kimi Code")
        }
    }

    // MARK: - Generation (synchronous JSON POST, no polling)

    private struct GenerationBody: Encodable {
        var model: String
        var prompt: String
        var n: Int
        var size: String?
        var response_format: String?
    }

    private func performGenerate(
        _ request: RemoteImageRequest,
        model: String,
        root: URL,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        // Verified root: always …/coding/v1/images/generations even when the
        // configured base is the bare `…/coding` default.
        let url = root.appendingPathComponent("images/generations")
        var body = GenerationBody(
            model: model,
            prompt: request.prompt,
            n: 1,
            size: try Self.nativeSize(for: request, provider: provider),
            response_format: "b64_json"
        )
        // Upstream-probed contract: some OpenAI-compatible Kimi fronts reject
        // an explicit `response_format`. Retry exactly once without the field,
        // mirroring the verified request probe.
        var didDropResponseFormat = false
        while true {
            let urlRequest = try RemoteImageHTTP.post(
                url: url,
                apiKey: credentials.apiKey,
                authHeader: "Authorization",
                extraHeaders: provider.nonSecretHeaders,
                body: body
            )
            let (data, response) = try await BoundedHTTP.data(
                for: urlRequest,
                session: session,
                maxBytes: 32 * 1_024 * 1_024
            )
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if !didDropResponseFormat, status == 400, Self.rejectsResponseFormat(data) {
                body.response_format = nil
                didDropResponseFormat = true
                continue
            }
            try RemoteImageHTTP.validate(
                response,
                data: data,
                provider: "Kimi Code",
                apiKey: credentials.apiKey,
                allowRouteFallback: true
            )
            return try await Self.decodedResult(from: data, request: request, model: model)
        }
    }

    // MARK: - Editing (multipart, single reference)

    private func performEdit(
        _ request: RemoteImageRequest,
        model: String,
        root: URL,
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> RemoteImageResult {
        guard !request.sourceImages.isEmpty else {
            throw RemoteImageError.requestFailed("Kimi Code image editing requires a source image")
        }
        guard request.mask == nil else {
            throw RemoteImageError.requestFailed(
                "Kimi Code image editing does not accept a mask; the verified upstream route has no mask field"
            )
        }
        let boundary = "FloeKimiImage-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        func file(_ name: String, _ filename: String, _ data: Data) throws {
            // The declared multipart type must match the real bytes; an
            // unknown payload is rejected instead of spoofed as PNG.
            guard let mime = ImageWireFormat.sniffMimeType(data) else {
                throw RemoteImageError.requestFailed("Source image bytes are not a supported image format (png/jpeg/gif/webp)")
            }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        field("model", model)
        field("prompt", request.prompt)
        field("n", "1")
        field("response_format", "b64_json")
        if let size = try Self.nativeSize(for: request, provider: provider) {
            field("size", size)
        }
        // Upstream sends the first reference as `image`; a Kimi-specific
        // multi-reference allowance was never demonstrated, so the limit
        // above keeps this to exactly that field.
        try file("image", "source-1", request.sourceImages[0])
        body.append(Data("--\(boundary)--\r\n".utf8))

        var urlRequest = URLRequest(url: root.appendingPathComponent("images/edits"))
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
        try RemoteImageHTTP.validate(
            response,
            data: data,
            provider: "Kimi Code",
            apiKey: credentials.apiKey,
            allowRouteFallback: true
        )
        return try await Self.decodedResult(from: data, request: request, model: model)
    }

    // MARK: - Shared wire helpers

    /// Only an explicit pixel dimension is transmitted. The preset resolver
    /// returns `nil` for this provider family unless the caller supplied a
    /// native size; unverified tier labels never reach the Kimi wire.
    private static func nativeSize(
        for request: RemoteImageRequest,
        provider: ProviderProfile
    ) throws -> String? {
        guard let raw = try ImageGenerationPresetResolver.nativeSize(
            provider: provider.kind,
            modelRemoteID: request.modelRemoteID,
            operation: request.operation,
            selection: request.selection
        ) else { return nil }
        let normalized = raw.lowercased()
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "*", with: "x")
        guard normalized.range(of: #"^\d{1,4}x\d{1,4}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return normalized
    }

    private static func rejectsResponseFormat(_ data: Data) -> Bool {
        let body = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        return body.contains("response_format") || body.contains("b64_json")
    }

    private static func decodedResult(
        from data: Data,
        request: RemoteImageRequest,
        model: String
    ) async throws -> RemoteImageResult {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = root?["data"] as? [[String: Any]]
        if items == nil, root?["choices"] != nil {
            // The upstream probe classifies a chat-shaped body from the
            // images endpoint as a missing route, never as success. Surfaced
            // as a route-fallback-eligible 404 so the existing service can
            // honestly re-route or report.
            throw RemoteImageError.providerRejected(
                statusCode: 404,
                message: "Kimi Code answered the images endpoint with a chat-completion response; the image route is unavailable for this model."
            )
        }
        let images = try await RemoteImageDecoder.images(
            from: data,
            b64Key: "b64_json",
            urlKey: "url",
            requestedCount: request.count
        )
        guard !images.isEmpty else {
            throw RemoteImageError.invalidResponse("Kimi Code returned no images")
        }
        let revised = (items ?? [])
            .compactMap { $0["revised_prompt"] as? String }
            .filter { !$0.isEmpty }
        return RemoteImageResult(
            images: images,
            revisedPrompt: revised.isEmpty ? nil : revised.joined(separator: "\n"),
            metadata: ["model": model]
        )
    }
}
