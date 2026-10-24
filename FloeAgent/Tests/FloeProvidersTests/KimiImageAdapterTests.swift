// FloeProvidersTests — Kimi Code image adapter synthetic transport contract.
//
// Everything here runs against stub URLProtocol sessions: the tests assert
// the request endpoint/headers/body shape, b64_json and URL response
// handling, the verified single-synchronous-request route (NO polling),
// the once-only response_format retry, failure mapping and cancellation.
// No real network, no real credentials; every key is a fixture.

import Foundation
import Testing
@testable import FloeCore
@testable import FloeProviders

private final class KimiImageStubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var statusCode: Int
        var body: Data
        var contentType: String = "application/json"
        var hangs: Bool = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []
    nonisolated(unsafe) private(set) static var stopCount = 0

    static func prepare(_ newStubs: [Stub]) {
        lock.lock()
        stubs = newStubs
        requests = []
        stopCount = 0
        lock.unlock()
    }

    static func snapshotRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func snapshotStopCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stopCount
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

        guard !stub.hangs else { return }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": stub.contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.stopCount += 1
        Self.lock.unlock()
    }
}

@Suite("FloeProviders.KimiImageAdapter", .serialized)
struct KimiImageAdapterTests {

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KimiImageStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func kimiProfile(host: String = "https://api.kimi.com/coding/v1") -> ProviderProfile {
        ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: host)!
        )
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Request wire contract

    @Test("Kimi generation is one synchronous POST with the verified body shape")
    func generateWireContract() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
        KimiImageStubProtocol.prepare([
            .init(statusCode: 200, body: try json([
                "data": [["b64_json": image.base64EncodedString(), "revised_prompt": "a calmer lake"]]
            ]))
        ])
        var provider = kimiProfile()
        provider.nonSecretHeaders = ["X-Organization": "org-1"]
        let adapter = KimiImageAdapter(session: session)
        let result = try await adapter.perform(
            RemoteImageRequest(
                operation: .generate,
                prompt: "draw a lake",
                modelRemoteID: "kimi-k2.7-code"
            ),
            provider: provider,
            credentials: ProviderCredentials(apiKey: "kimi-test-key")
        )
        #expect(result.images == [image])
        #expect(result.revisedPrompt == "a calmer lake")
        #expect(result.metadata["model"] == "kimi-k2.7-code")
        let requests = KimiImageStubProtocol.snapshotRequests()
        // Exactly one request: the verified route has NO async polling loop.
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://api.kimi.com/coding/v1/images/generations")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer kimi-test-key")
        #expect(request.value(forHTTPHeaderField: "X-Organization") == "org-1")
        #expect(request.timeoutInterval >= 300)
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "kimi-k2.7-code")
        #expect(json["prompt"] as? String == "draw a lake")
        #expect(json["n"] as? Int == 1)
        #expect(json["response_format"] as? String == "b64_json")
        // No verified Kimi size table exists: without an explicit dimension
        // the field is omitted, never guessed.
        #expect(json["size"] == nil)
        #expect(json["quality"] == nil)
    }

    @Test("The bare /coding default base is normalized to the verified /coding/v1 route")
    func codingBaseNormalizationContract() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x05])
        let success = try json(["data": [["b64_json": image.base64EncodedString()]]])
        KimiImageStubProtocol.prepare([
            .init(statusCode: 200, body: success),
            .init(statusCode: 200, body: success),
            .init(statusCode: 200, body: success)
        ])
        let adapter = KimiImageAdapter(session: session)
        for base in ["https://api.kimi.com/coding", "https://api.kimi.com/coding/v1", "https://api.kimi.com/coding/"] {
            _ = try await adapter.perform(
                RemoteImageRequest(operation: .generate, prompt: "lake", modelRemoteID: "kimi-k3"),
                provider: kimiProfile(host: base),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
        let requests = KimiImageStubProtocol.snapshotRequests()
        #expect(requests.count == 3)
        // Every variant hits the one evidenced endpoint, never
        // /coding/images/generations or a doubled /v1/v1.
        for request in requests {
            #expect(request.url?.absoluteString == "https://api.kimi.com/coding/v1/images/generations")
        }

        // A direct call with an unevidenced route variant is refused before
        // any networking, even bypassing the factory identity gate.
        KimiImageStubProtocol.prepare([])
        await #expect(throws: RemoteImageError.self) {
            _ = try await adapter.perform(
                RemoteImageRequest(operation: .generate, prompt: "lake", modelRemoteID: "kimi-k3"),
                provider: kimiProfile(host: "https://api.kimi.com/coding/v2"),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
        #expect(KimiImageStubProtocol.snapshotRequests().isEmpty)
    }

    @Test("Kimi generation transmits only explicit pixel dimensions as size")
    func sizeSanitizationContract() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x03])
        KimiImageStubProtocol.prepare([
            .init(statusCode: 200, body: try json(["data": [["b64_json": image.base64EncodedString()]]])),
            .init(statusCode: 200, body: try json(["data": [["b64_json": image.base64EncodedString()]]]))
        ])
        let adapter = KimiImageAdapter(session: session)
        // The manual picker's tier label never reaches the Kimi wire…
        _ = try await adapter.perform(
            RemoteImageRequest(
                operation: .generate,
                prompt: "lake",
                sizeHint: "2K",
                modelRemoteID: "kimi-k2.7-code"
            ),
            provider: kimiProfile(),
            credentials: ProviderCredentials(apiKey: "kimi-test-key")
        )
        // …while an explicit native dimension is forwarded (× → x normalized).
        _ = try await adapter.perform(
            RemoteImageRequest(
                operation: .generate,
                prompt: "lake",
                selection: ImageGenerationSelection(nativeSizeOverride: "1536×1024"),
                modelRemoteID: "kimi-k2.7-code"
            ),
            provider: kimiProfile(),
            credentials: ProviderCredentials(apiKey: "kimi-test-key")
        )
        let requests = KimiImageStubProtocol.snapshotRequests()
        #expect(requests.count == 2)
        let firstBody = try #require(requests[0].httpBody)
        let first = try #require(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        #expect(first["size"] == nil)
        let secondBody = try #require(requests[1].httpBody)
        let second = try #require(JSONSerialization.jsonObject(with: secondBody) as? [String: Any])
        #expect(second["size"] as? String == "1536x1024")
    }

    @Test("Kimi rejects a response_format refusal with exactly one retry without the field")
    func b64FormatRetryContract() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let image = Data([0x89, 0x50, 0x4E, 0x47, 0x04])
        KimiImageStubProtocol.prepare([
            .init(statusCode: 400, body: Data(
                #"{"error":{"message":"field response_format with value b64_json is unsupported"}}"#.utf8
            )),
            .init(statusCode: 200, body: try json(["data": [["b64_json": image.base64EncodedString()]]]))
        ])
        let result = try await KimiImageAdapter(session: session).perform(
            RemoteImageRequest(operation: .generate, prompt: "lake", modelRemoteID: "kimi-k3"),
            provider: kimiProfile(),
            credentials: ProviderCredentials(apiKey: "kimi-test-key")
        )
        #expect(result.images == [image])
        let requests = KimiImageStubProtocol.snapshotRequests()
        #expect(requests.count == 2)
        let retryBody = try #require(requests[1].httpBody)
        let retried = try #require(JSONSerialization.jsonObject(with: retryBody) as? [String: Any])
        #expect(retried["response_format"] == nil)
        #expect(retried["model"] as? String == "kimi-k3")
    }

    // MARK: - Response handling

    @Test("Kimi url responses are delegated to the shared bounded decoder")
    func urlResultDelegationContract() async throws {
        // The positive https-download branch lives inside the shared
        // RemoteImageDecoder (same "url" key as the OpenAI route); it builds
        // its own ephemeral session, which a test-injected or globally
        // registered URLProtocol does not intercept on this host. Rather
        // than touch shared plumbing or perform real network, this asserts
        // the adapter's url/b64 handling stays delegated: a mixed array with
        // no decodable image and no safe URL yields no fabricated success.
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        KimiImageStubProtocol.prepare([
            .init(statusCode: 200, body: try json([
                "data": [["url": "ftp://kimi-img-cdn.test/render.png",
                          "revised_prompt": "sharpened"]]
            ]))
        ])
        await #expect(throws: RemoteImageError.self) {
            _ = try await KimiImageAdapter(session: session).perform(
                RemoteImageRequest(operation: .generate, prompt: "harbor", modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
        #expect(KimiImageStubProtocol.snapshotRequests().count == 1)
    }

    @Test("Kimi result URLs must stay inside the HTTPS public-host boundary")
    func urlResultTrustBoundary() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        KimiImageStubProtocol.prepare([
            .init(statusCode: 200, body: try json([
                "data": [["url": "http://127.0.0.1/x.png"]]
            ]))
        ])
        await #expect(throws: RemoteImageError.self) {
            _ = try await KimiImageAdapter(session: session).perform(
                RemoteImageRequest(operation: .generate, prompt: "x", modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
    }

    @Test("A chat-completion body from the images endpoint is a missing route")
    func chatShapeRouteMissingContract() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        KimiImageStubProtocol.prepare([
            .init(statusCode: 200, body: try json([
                "choices": [["message": ["content": "I cannot generate images here"]]]
            ]))
        ])
        do {
            _ = try await KimiImageAdapter(session: session).perform(
                RemoteImageRequest(operation: .generate, prompt: "lake", modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
            Issue.record("Expected a missing-route refusal")
        } catch let error as RemoteImageError {
            // Upstream classifies this as endpoint-missing, which in Floe
            // maps to the route-fallback-eligible refusal family.
            #expect(error.allowsRouteFallback)
            if case .providerRejected(let status, _) = error {
                #expect(status == 404)
            } else {
                Issue.record("Expected providerRejected(404), got \(error)")
            }
        }
        // Never retried as chat, never polled: exactly one request.
        #expect(KimiImageStubProtocol.snapshotRequests().count == 1)
    }

    @Test("An empty images array is an invalid response, not success")
    func emptyDataIsRejected() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        KimiImageStubProtocol.prepare([
            .init(statusCode: 200, body: try json(["data": []]))
        ])
        await #expect(throws: RemoteImageError.self) {
            _ = try await KimiImageAdapter(session: session).perform(
                RemoteImageRequest(operation: .generate, prompt: "lake", modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
    }

    @Test("Kimi caps observed outputs so the service sees over-production")
    func excessOutputObservationContract() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let images = (0..<3).map { Data([0x89, 0x50, 0x4E, 0x47, UInt8($0)]) }
        KimiImageStubProtocol.prepare([
            .init(statusCode: 200, body: try json([
                "data": images.map { ["b64_json": $0.base64EncodedString()] }
            ]))
        ])
        let result = try await KimiImageAdapter(session: session).perform(
            RemoteImageRequest(operation: .generate, prompt: "lake", count: 1, modelRemoteID: "kimi-k3"),
            provider: kimiProfile(),
            credentials: ProviderCredentials(apiKey: "kimi-test-key")
        )
        // Requested 1: expected + 1 stays visible, the rest is not decoded.
        #expect(result.images == Array(images.prefix(2)))
    }

    // MARK: - Edit wire contract

    @Test("Kimi edit is one multipart POST with a single sniffed reference")
    func editWireContract() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let output = Data([0x89, 0x50, 0x4E, 0x47, 0x09])
        KimiImageStubProtocol.prepare([
            .init(statusCode: 200, body: try json(["data": [["b64_json": output.base64EncodedString()]]]))
        ])
        // Real JPEG magic bytes: the declared multipart type must be sniffed,
        // never defaulted to png.
        let source = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x01])
        let result = try await KimiImageAdapter(session: session).perform(
            RemoteImageRequest(
                operation: .edit,
                prompt: "make it warmer",
                sourceImages: [source],
                selection: ImageGenerationSelection(nativeSizeOverride: "1024x1024"),
                modelRemoteID: "kimi-k2.7-code"
            ),
            provider: kimiProfile(),
            credentials: ProviderCredentials(apiKey: "kimi-test-key")
        )
        #expect(result.images == [output])
        let requests = KimiImageStubProtocol.snapshotRequests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url?.absoluteString == "https://api.kimi.com/coding/v1/images/edits")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer kimi-test-key")
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(contentType.hasPrefix("multipart/form-data; boundary=FloeKimiImage-"))
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"model\""))
        #expect(body.contains("kimi-k2.7-code"))
        #expect(body.contains("make it warmer"))
        #expect(body.contains("name=\"n\""))
        #expect(body.components(separatedBy: "\r\n").contains { $0.hasPrefix("1") })
        #expect(body.contains("name=\"response_format\""))
        #expect(body.contains("b64_json"))
        #expect(body.contains("name=\"size\""))
        #expect(body.contains("1024x1024"))
        #expect(body.contains("name=\"image\""))
        #expect(body.contains("Content-Type: image/jpeg"))
        #expect(body.contains("filename=\"source-1\""))
        #expect(!body.contains("name=\"image[]\""))
        #expect(!body.contains("name=\"mask\""))
    }

    @Test("Edit input limits fail before networking")
    func editLimitsBeforeNetworking() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let adapter = KimiImageAdapter(session: session)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        KimiImageStubProtocol.prepare([])
        await #expect(throws: RemoteImageError.self) {
            _ = try await adapter.perform(
                RemoteImageRequest(operation: .edit, prompt: "warm", modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
        #expect(KimiImageStubProtocol.snapshotRequests().isEmpty)

        KimiImageStubProtocol.prepare([])
        await #expect(throws: RemoteImageError.self) {
            _ = try await adapter.perform(
                RemoteImageRequest(operation: .edit, prompt: "blend", sourceImages: [png, png], modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
        #expect(KimiImageStubProtocol.snapshotRequests().isEmpty)

        KimiImageStubProtocol.prepare([])
        await #expect(throws: RemoteImageError.self) {
            _ = try await adapter.perform(
                RemoteImageRequest(operation: .edit, prompt: "inpaint", sourceImages: [png], mask: png, modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
        #expect(KimiImageStubProtocol.snapshotRequests().isEmpty)

        // Generation must not smuggle references either.
        KimiImageStubProtocol.prepare([])
        await #expect(throws: RemoteImageError.self) {
            _ = try await adapter.perform(
                RemoteImageRequest(operation: .generate, prompt: "x", sourceImages: [png], modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
        #expect(KimiImageStubProtocol.snapshotRequests().isEmpty)
    }

    // MARK: - Capability honesty and refusals

    @Test("Kimi exposes only generate and edit with pinned batch limits")
    func capabilityContract() {
        let adapter = KimiImageAdapter()
        let provider = kimiProfile()
        #expect(adapter.supportedOperations(for: provider) == [.generate, .edit])
        for operation in [RemoteImageOperation.variation, .inpaint, .upscale, .removeBackground] {
            #expect(!adapter.supports(operation, for: provider))
        }
        #expect(adapter.maximumSourceImages(for: .generate, modelRemoteID: "kimi-k3") == 0)
        #expect(adapter.maximumSourceImages(for: .edit, modelRemoteID: "kimi-k3") == 1)
        #expect(adapter.maximumOutputImages(modelRemoteID: "kimi-k3") == 1)
    }

    @Test("Unsupported operations and missing model IDs throw before networking")
    func preflightRefusals() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let adapter = KimiImageAdapter(session: session)
        KimiImageStubProtocol.prepare([])
        await #expect(throws: RemoteImageError.self) {
            _ = try await adapter.perform(
                RemoteImageRequest(operation: .upscale, prompt: "bigger", modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
        await #expect(throws: RemoteImageError.self) {
            _ = try await adapter.perform(
                RemoteImageRequest(operation: .generate, prompt: "lake", modelRemoteID: nil),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
        await #expect(throws: RemoteImageError.self) {
            _ = try await adapter.perform(
                RemoteImageRequest(operation: .generate, prompt: "lake", modelRemoteID: "   "),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
        // Batch beyond the verified single output fails client-side.
        await #expect(throws: RemoteImageError.self) {
            _ = try await adapter.perform(
                RemoteImageRequest(operation: .generate, prompt: "lake", count: 4, modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
        #expect(KimiImageStubProtocol.snapshotRequests().isEmpty)
    }

    @Test("Failure statuses map honestly and never echo the credential")
    func failureMappingAndRedaction() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let apiKey = "sk-kimi-SUPERSECRET-0123456789abcdef"
        let secretBody =
            #"{"error":{"message":"invalid api key sk-kimi-SUPERSECRET-0123456789abcdef"}}"#

        KimiImageStubProtocol.prepare([
            .init(statusCode: 401, body: Data(#"{"error":{"message":"unauthorized"}}"#.utf8))
        ])
        do {
            _ = try await KimiImageAdapter(session: session).perform(
                RemoteImageRequest(operation: .generate, prompt: "lake", modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: apiKey)
            )
            Issue.record("Expected 401 refusal")
        } catch let error as RemoteImageError {
            #expect(error.allowsRouteFallback)  // explicit pre-execution auth refusal
        }

        KimiImageStubProtocol.prepare([
            .init(statusCode: 403, body: Data(#"{"error":{"message":"content policy"}}"#.utf8))
        ])
        do {
            _ = try await KimiImageAdapter(session: session).perform(
                RemoteImageRequest(operation: .generate, prompt: "lake", modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: apiKey)
            )
            Issue.record("Expected 403 refusal")
        } catch let error as RemoteImageError {
            // Policy refusals must never trigger a silent route switch.
            #expect(!error.allowsRouteFallback)
        }

        KimiImageStubProtocol.prepare([
            .init(statusCode: 500, body: Data(secretBody.utf8))
        ])
        do {
            _ = try await KimiImageAdapter(session: session).perform(
                RemoteImageRequest(operation: .generate, prompt: "lake", modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: apiKey)
            )
            Issue.record("Expected server failure")
        } catch let error as RemoteImageError {
            let message = error.localizedDescription
            #expect(!message.contains(apiKey))
            #expect(!message.contains("SUPERSECRET"))
        }
    }

    @Test("Cancellation stops the in-flight Kimi request")
    func cancellationContract() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        KimiImageStubProtocol.prepare([.init(statusCode: 200, body: Data(), hangs: true)])
        let adapter = KimiImageAdapter(session: session)
        let operation = Task {
            try await adapter.perform(
                RemoteImageRequest(operation: .generate, prompt: "slow lake", modelRemoteID: "kimi-k3"),
                provider: kimiProfile(),
                credentials: ProviderCredentials(apiKey: "kimi-test-key")
            )
        }
        try await Task.sleep(nanoseconds: 120_000_000)
        operation.cancel()
        do {
            _ = try await operation.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Propagated task cancellation.
        } catch let urlError as URLError {
            #expect(urlError.code == .cancelled || urlError.code == .networkConnectionLost)
        }
        // The request had genuinely started (one in-flight POST) and no
        // success was fabricated after cancellation. stopLoading teardown
        // timing is host-Foundation-specific, so it is not asserted.
        #expect(KimiImageStubProtocol.snapshotRequests().count == 1)
    }
}
