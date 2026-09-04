// FloeProvidersTests — Capability-aware remote image adapters. Unsupported
// operations must throw rather than fabricate output; the factory only
// returns adapters for provider families with real image capability.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders
import FloeTestSupport

private final class ImageAdapterURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var statusCode: Int
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []

    static func prepare(_ newStubs: [Stub]) {
        lock.lock()
        stubs = newStubs
        requests = []
        lock.unlock()
    }

    static func snapshotRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recordedRequest = request
        if recordedRequest.httpBody == nil, let stream = recordedRequest.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            recordedRequest.httpBody = body
        }
        Self.lock.lock()
        Self.requests.append(recordedRequest)
        let stub = Self.stubs.isEmpty
            ? Stub(statusCode: 500, body: Data(#"{"error":"missing stub"}"#.utf8))
            : Self.stubs.removeFirst()
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("FloeProviders.ImageAdapters", .serialized)
struct ImageAdapterTests {

    private func provider(kind: ProviderKind) -> ProviderProfile {
        ProviderProfile(
            kind: kind,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://localhost:8443")!
        )
    }

    @Test("Factory returns adapters only for image-capable provider families")
    func factoryCoverage() {
        let factory = ImageProviderAdapterFactory()
        #expect(factory.adapter(for: provider(kind: .openAI)) is OpenAIImageAdapter)
        #expect(factory.adapter(for: provider(kind: .volcengineArk)) is VolcengineImageAdapter)
        #expect(factory.adapter(for: provider(kind: .alibabaStudio)) is AlibabaImageAdapter)
        #expect(factory.adapter(for: provider(kind: .googleGemini)) is GoogleGeminiImageAdapter)
        // Anthropic and custom endpoints expose no remote image adapter.
        #expect(factory.adapter(for: provider(kind: .anthropic)) == nil)
        #expect(factory.adapter(for: provider(kind: .custom)) == nil)
    }

    @Test("Each adapter declares an honest capability set")
    func capabilitySets() {
        let openai = OpenAIImageAdapter()
        #expect(openai.supportedOperations(for: provider(kind: .openAI)).contains(.generate))
        #expect(openai.supportedOperations(for: provider(kind: .openAI)).contains(.edit))
        #expect(!openai.supportedOperations(for: provider(kind: .openAI)).contains(.upscale))

        let ark = VolcengineImageAdapter()
        #expect(ark.supportedOperations(for: provider(kind: .volcengineArk)).contains(.generate))
        #expect(ark.supportedOperations(for: provider(kind: .volcengineArk)).contains(.edit))

        let alibaba = AlibabaImageAdapter()
        #expect(alibaba.supportedOperations(for: provider(kind: .alibabaStudio)).contains(.generate))
        #expect(alibaba.supportedOperations(for: provider(kind: .alibabaStudio)).contains(.edit))

        let google = GoogleGeminiImageAdapter()
        #expect(google.supportedOperations(for: provider(kind: .googleGemini)) == [.generate, .edit])

        #expect(openai.maximumSourceImages(for: .edit, modelRemoteID: "gpt-image-2") == 16)
        #expect(ark.maximumSourceImages(for: .edit, modelRemoteID: "doubao-seedream-5-0") == 10)
        #expect(alibaba.maximumSourceImages(for: .edit, modelRemoteID: "wan2.7-image") == 9)
        #expect(alibaba.maximumSourceImages(for: .edit, modelRemoteID: "qwen-image-3") == 3)
        #expect(google.maximumSourceImages(for: .edit, modelRemoteID: "gemini-2.5-flash-image") == 3)
        #expect(openai.maximumOutputImages(modelRemoteID: "gpt-image-2") == 4)
        #expect(ark.maximumOutputImages(modelRemoteID: "doubao-seedream-5-0") == 4)
        #expect(alibaba.maximumOutputImages(modelRemoteID: "wan2.7-image") == 4)
        #expect(google.maximumOutputImages(modelRemoteID: "gemini-3-pro-image") == 1)
    }

    @Test("Reference limit resolves the strictest model and provider capability")
    func referenceCapabilityResolution() {
        let arkProvider = provider(kind: .volcengineArk)
        let seedream = ModelProfile(
            providerID: arkProvider.id,
            remoteModelID: "doubao-seedream-4-0-250828",
            displayName: "Seedream 4.0",
            limits: .init(contextTokens: 1, maxOutputTokens: 0),
            capabilities: [.imageGeneration, .imageEditing]
        )
        #expect(ImageReferenceCapabilityResolver.maximumReferenceImages(
            provider: arkProvider,
            model: seedream
        ) == 10)

        var generationOnly = seedream
        generationOnly.capabilities = [.imageGeneration]
        #expect(ImageReferenceCapabilityResolver.maximumReferenceImages(
            provider: arkProvider,
            model: generationOnly
        ) == 0)
    }

    @Test("Unsupported operations throw unsupportedOperation, never fabricate")
    func unsupportedThrows() async {
        let adapter = OpenAIImageAdapter()
        let openAIProvider = provider(kind: .openAI)
        let request = RemoteImageRequest(operation: .upscale, prompt: "bigger")
        await #expect(throws: RemoteImageError.self) {
            _ = try await adapter.perform(request, provider: openAIProvider, credentials: ProviderCredentials())
        }
    }

    @Test("supports() is consistent with supportedOperations()")
    func supportsConsistency() {
        let adapter = AlibabaImageAdapter()
        let alibabaProvider = provider(kind: .alibabaStudio)
        #expect(adapter.supports(.generate, for: alibabaProvider))
        #expect(adapter.supports(.edit, for: alibabaProvider))
        #expect(!adapter.supports(.removeBackground, for: alibabaProvider))
    }

    @Test("Remote image failures preserve their actionable message")
    func localizedErrors() {
        let request = RemoteImageError.requestFailed("Provider HTTP 429: quota exceeded")
        let invalid = RemoteImageError.invalidResponse("No image payload")
        #expect(request.localizedDescription == "Provider HTTP 429: quota exceeded")
        #expect(invalid.localizedDescription == "No image payload")
        #expect(RemoteImageError.unsupportedOperation(.edit, provider: "Example")
            .localizedDescription.contains("Example"))
    }

    @Test("OpenAI GPT Image 2 preserves a configurable proxy base URL")
    func openAIProxyWireContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageAdapterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
        ImageAdapterURLProtocol.prepare([
            .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
                "data": [["b64_json": image.base64EncodedString()]]
            ]))
        ])
        let adapter = OpenAIImageAdapter(session: session)
        let profile = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIResponses,
            baseURL: URL(string: "https://proxy.example/openai/v1")!
        )
        let result = try await adapter.perform(
            RemoteImageRequest(
                operation: .generate,
                prompt: "draw a lake",
                selection: ImageGenerationSelection(
                    aspectRatio: "16:9",
                    resolution: "1K",
                    quality: "high"
                )
            ),
            provider: profile,
            credentials: ProviderCredentials(apiKey: "test-key")
        )
        #expect(result.images == [image])
        let request = try #require(ImageAdapterURLProtocol.snapshotRequests().first)
        #expect(request.url?.path == "/openai/v1/images/generations")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.timeoutInterval >= 300)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-image-2")
        #expect(json["size"] as? String == "1536x864")
        #expect(json["quality"] as? String == "high")
    }

    @Test("OpenAI GPT Image edits transmit every reference without truncation")
    func openAIMultipleReferenceWireContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageAdapterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let output = Data([0x89, 0x50, 0x4E, 0x47, 0x44])
        ImageAdapterURLProtocol.prepare([
            .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
                "data": [["b64_json": output.base64EncodedString()]]
            ]))
        ])
        let sources = (0..<5).map { index in
            Data([0x89, 0x50, 0x4E, 0x47, UInt8(index)])
        }
        let adapter = OpenAIImageAdapter(session: session)
        let result = try await adapter.perform(
            RemoteImageRequest(
                operation: .edit, prompt: "blend every reference",
                sourceImages: sources, modelRemoteID: "gpt-image-2"
            ),
            provider: provider(kind: .openAI),
            credentials: ProviderCredentials(apiKey: "test-key")
        )
        #expect(result.images == [output])
        let request = try #require(ImageAdapterURLProtocol.snapshotRequests().first)
        #expect(request.timeoutInterval >= 300)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.components(separatedBy: "name=\"image[]\"").count - 1 == 5)
        #expect(body.contains("filename=\"source-5.png\""))
    }

    @Test("Volcengine Seedream edits transmit all five reference images")
    func volcengineFiveReferenceWireContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageAdapterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let output = Data([0x89, 0x50, 0x4E, 0x47, 0x55])
        ImageAdapterURLProtocol.prepare([
            .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
                "data": [["b64_json": output.base64EncodedString()]]
            ]))
        ])
        let references = (0..<5).map { index in
            Data([0x89, 0x50, 0x4E, 0x47, UInt8(index)])
        }
        let adapter = VolcengineImageAdapter(session: session)
        let result = try await adapter.perform(
            RemoteImageRequest(
                operation: .edit,
                prompt: "compose all five references",
                sourceImages: references,
                modelRemoteID: "doubao-seedream-5-0-260128"
            ),
            provider: provider(kind: .volcengineArk),
            credentials: ProviderCredentials(apiKey: "test-key")
        )

        #expect(result.images == [output])
        let request = try #require(ImageAdapterURLProtocol.snapshotRequests().first)
        #expect(request.url?.path == "/images/generations")
        #expect(request.timeoutInterval >= 300)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let images = try #require(json["image"] as? [String])
        #expect(images.count == 5)
        #expect(images.allSatisfy { $0.hasPrefix("data:image/png;base64,") })
    }

    @Test("OpenAI exposes one excess output to the service cardinality gate")
    func openAIExcessOutputObservationContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageAdapterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let providerImages = (0..<6).map {
            Data([0x89, 0x50, 0x4E, 0x47, UInt8($0)])
        }
        ImageAdapterURLProtocol.prepare([
            .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
                "data": providerImages.map { ["b64_json": $0.base64EncodedString()] }
            ]))
        ])

        let result = try await OpenAIImageAdapter(session: session).perform(
            RemoteImageRequest(
                operation: .generate,
                prompt: "four variations",
                count: 4,
                modelRemoteID: "gpt-image-2"
            ),
            provider: provider(kind: .openAI),
            credentials: ProviderCredentials(apiKey: "test-key")
        )

        // The adapter keeps expected + 1, but never decodes an unbounded
        // response. MediaGenerationService can therefore reject 5 != 4.
        #expect(result.images == Array(providerImages.prefix(5)))
    }

    @Test("Unsupported reference counts fail before networking")
    func excessiveReferencesFailBeforeNetworking() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageAdapterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let references = (0..<4).map { Data([UInt8($0)]) }

        ImageAdapterURLProtocol.prepare([])
        await #expect(throws: RemoteImageError.self) {
            _ = try await GoogleGeminiImageAdapter(session: session).perform(
                RemoteImageRequest(
                    operation: .edit, prompt: "blend",
                    sourceImages: references,
                    modelRemoteID: "gemini-2.5-flash-image"
                ),
                provider: provider(kind: .googleGemini),
                credentials: ProviderCredentials(apiKey: "test-key")
            )
        }
        #expect(ImageAdapterURLProtocol.snapshotRequests().isEmpty)

        ImageAdapterURLProtocol.prepare([])
        await #expect(throws: RemoteImageError.self) {
            _ = try await GoogleGeminiImageAdapter(session: session).perform(
                RemoteImageRequest(
                    operation: .generate, prompt: "four versions",
                    count: 4, modelRemoteID: "gemini-3-pro-image"
                ),
                provider: provider(kind: .googleGemini),
                credentials: ProviderCredentials(apiKey: "test-key")
            )
        }
        #expect(ImageAdapterURLProtocol.snapshotRequests().isEmpty)

        ImageAdapterURLProtocol.prepare([])
        await #expect(throws: RemoteImageError.self) {
            _ = try await AlibabaImageAdapter(session: session).perform(
                RemoteImageRequest(
                    operation: .edit, prompt: "blend",
                    sourceImages: references,
                    modelRemoteID: "qwen-image-3"
                ),
                provider: provider(kind: .alibabaStudio),
                credentials: ProviderCredentials(apiKey: "test-key")
            )
        }
        #expect(ImageAdapterURLProtocol.snapshotRequests().isEmpty)
    }

    @Test("Provider preset resolver never sends an aspect label as native size")
    func providerPresetResolution() throws {
        let ark = try ImageGenerationPresetResolver.nativeSize(
            provider: .volcengineArk,
            modelRemoteID: "doubao-seedream-4-0-250828",
            operation: .generate,
            selection: ImageGenerationSelection(aspectRatio: "16:9", resolution: "2K")
        )
        #expect(ark == "2560x1440")

        let alibaba = try ImageGenerationPresetResolver.nativeSize(
            provider: .alibabaStudio,
            modelRemoteID: "wan2.7-image-pro",
            operation: .generate,
            selection: ImageGenerationSelection(aspectRatio: "3:4", resolution: "2K")
        )
        #expect(alibaba == "1728*2368")

        let gemini = try ImageGenerationPresetResolver.nativeSize(
            provider: .googleGemini,
            modelRemoteID: "gemini-3-pro-image",
            operation: .generate,
            selection: ImageGenerationSelection(aspectRatio: "9:16", resolution: "4K")
        )
        #expect(gemini == nil)
    }

    @Test("Nano Banana Pro uses native Gemini JSON through a configurable proxy")
    func googleGeminiProxyWireContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageAdapterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x02])
        ImageAdapterURLProtocol.prepare([
            .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
                "candidates": [["content": ["parts": [
                    ["text": "completed"],
                    ["inlineData": ["mimeType": "image/png", "data": image.base64EncodedString()]]
                ]]]]
            ]))
        ])
        let adapter = GoogleGeminiImageAdapter(session: session)
        let profile = ProviderProfile(
            kind: .googleGemini,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://proxy.example/google/v1")!
        )
        let result = try await adapter.perform(
            RemoteImageRequest(
                operation: .generate,
                prompt: "draw a lake",
                sizeHint: "2048x2048",
                modelRemoteID: "gemini-3-pro-image"
            ),
            provider: profile,
            credentials: ProviderCredentials(apiKey: "google-test-key")
        )
        #expect(result.images == [image])
        #expect(result.revisedPrompt == "completed")
        let request = try #require(ImageAdapterURLProtocol.snapshotRequests().first)
        #expect(request.url?.path == "/google/v1/models/gemini-3-pro-image:generateContent")
        #expect(request.timeoutInterval >= 300)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "google-test-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let contents = try #require(json["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == "draw a lake")
        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["responseModalities"] as? [String] == ["IMAGE"])
        let responseFormat = try #require(config["responseFormat"] as? [String: Any])
        let format = try #require(responseFormat["image"] as? [String: Any])
        #expect(format["aspectRatio"] as? String == "1:1")
        #expect(format["imageSize"] as? String == "2K")
    }

    @Test("Gemini exposes one excess output to the service cardinality gate")
    func googleGeminiExcessOutputObservationContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageAdapterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let providerImages = (0..<3).map {
            Data([0x89, 0x50, 0x4E, 0x47, UInt8($0 + 10)])
        }
        ImageAdapterURLProtocol.prepare([
            .init(statusCode: 200, body: try JSONSerialization.data(withJSONObject: [
                "candidates": [["content": ["parts": providerImages.map {
                    ["inlineData": [
                        "mimeType": "image/png",
                        "data": $0.base64EncodedString()
                    ]]
                }]]]
            ]))
        ])

        let result = try await GoogleGeminiImageAdapter(session: session).perform(
            RemoteImageRequest(
                operation: .generate,
                prompt: "one image",
                count: 1,
                modelRemoteID: "gemini-3-pro-image"
            ),
            provider: provider(kind: .googleGemini),
            credentials: ProviderCredentials(apiKey: "google-test-key")
        )

        #expect(result.images == Array(providerImages.prefix(2)))
    }

    @Test("DashScope current image models use multimodal generation for editing")
    func dashScopeMultimodalEditingContract() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageAdapterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ImageAdapterURLProtocol.prepare([
            .init(statusCode: 200, body: Data(#"{"output":{"choices":[{"message":{"content":[]}}]}}"#.utf8))
        ])

        let adapter = AlibabaImageAdapter(session: session)
        let profile = ProviderProfile(
            kind: .alibabaStudio,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!
        )
        await #expect(throws: RemoteImageError.self) {
            _ = try await adapter.perform(
                RemoteImageRequest(
                    operation: .edit,
                    prompt: "make it warmer",
                    sourceImages: (0..<5).map {
                        Data([0x89, 0x50, 0x4E, 0x47, UInt8($0)])
                    },
                    modelRemoteID: "wan2.7-image"
                ),
                provider: profile,
                credentials: ProviderCredentials(apiKey: "test-key")
            )
        }

        let request = try #require(ImageAdapterURLProtocol.snapshotRequests().first)
        #expect(request.url?.path == "/api/v1/services/aigc/multimodal-generation/generation")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.value(forHTTPHeaderField: "X-DashScope-Async") == nil)
        #expect(request.timeoutInterval >= 300)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "wan2.7-image")
        let input = try #require(json["input"] as? [String: Any])
        let messages = try #require(input["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "make it warmer")
        #expect(content.dropFirst().count == 5)
        #expect(content.dropFirst().allSatisfy {
            ($0["image"] as? String)?.hasPrefix("data:image/png;base64,") == true
        })
    }

    @Test("Alibaba legacy image models use the image-synthesis protocol")
    func alibabaLegacyWireContract() async throws {
        let requests = try await exerciseAlibabaSubmission(model: "wan2.5-t2i-preview", size: "1024x1024")
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/api/v1/services/aigc/text2image/image-synthesis")
        #expect(requests[1].url?.path == "/api/v1/tasks/task-123")
        #expect(requests[0].value(forHTTPHeaderField: "X-DashScope-Async") == "enable")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

        let body = try #require(requests[0].httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try #require(json["input"] as? [String: Any])
        let parameters = try #require(json["parameters"] as? [String: Any])
        #expect(input["prompt"] as? String == "draw a lake")
        #expect(parameters["size"] as? String == "1024*1024")
        #expect(parameters["n"] as? Int == 4)
    }

    @Test("Alibaba Wan 2.6 image models use the message protocol")
    func alibabaWan26WireContract() async throws {
        let requests = try await exerciseAlibabaSubmission(model: "wan2.6-t2i", size: nil)
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/api/v1/services/aigc/image-generation/generation")

        let body = try #require(requests[0].httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let input = try #require(json["input"] as? [String: Any])
        let messages = try #require(input["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let parameters = try #require(json["parameters"] as? [String: Any])
        #expect(messages.first?["role"] as? String == "user")
        #expect(content.first?["text"] as? String == "draw a lake")
        #expect(parameters["size"] as? String == "1280*1280")
        #expect(parameters["prompt_extend"] as? Bool == true)
        #expect(parameters["watermark"] as? Bool == false)
    }

    @Test("Alibaba rejects result URLs outside its configured trust boundary")
    func alibabaRejectsUntrustedResultHost() async throws {
        let pollBody = Data(
            #"{"output":{"task_id":"task-123","task_status":"SUCCEEDED","results":[{"url":"https://example.com/result.png"}]}}"#.utf8
        )
        let requests = try await exerciseAlibabaSubmission(
            model: "wan2.5-t2i-preview",
            size: nil,
            pollBody: pollBody
        )
        #expect(requests.count == 2)
    }

    private func exerciseAlibabaSubmission(
        model: String,
        size: String?,
        pollBody: Data = Data(#"{"output":{"task_id":"task-123","task_status":"FAILED"}}"#.utf8)
    ) async throws -> [URLRequest] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageAdapterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ImageAdapterURLProtocol.prepare([
            .init(statusCode: 200, body: Data(#"{"output":{"task_id":"task-123","task_status":"PENDING"}}"#.utf8)),
            .init(statusCode: 200, body: pollBody)
        ])

        let adapter = AlibabaImageAdapter(session: session)
        let profile = ProviderProfile(
            kind: .alibabaStudio,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!
        )
        let request = RemoteImageRequest(
            operation: .generate,
            prompt: "draw a lake",
            sizeHint: size,
            count: 4,
            modelRemoteID: model
        )
        await #expect(throws: RemoteImageError.self) {
            _ = try await adapter.perform(
                request,
                provider: profile,
                credentials: ProviderCredentials(apiKey: "test-key")
            )
        }
        return ImageAdapterURLProtocol.snapshotRequests()
    }
}
