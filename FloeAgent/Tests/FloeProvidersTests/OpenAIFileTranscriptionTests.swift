// Focused qualification tests — OpenAI-compatible file transcription.
//
// URLProtocol is the injectable HTTP transport: every assertion below checks
// the real multipart bytes, the real URL/headers, or a real decoded result.
// No provider call, network, App build or simulator is involved.

import Foundation
import Testing
import FloeCore
@testable import FloeProviders

private final class ASRURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var statusCode: Int
        var headers: [String: String] = [:]
        var body: Data
        var url: URL?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [Stub] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []

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
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            recorded.httpBody = body
        }
        Self.lock.lock()
        Self.requests.append(recorded)
        let stub = Self.stubs.isEmpty
            ? Stub(statusCode: 500, body: Data())
            : Self.stubs.removeFirst()
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: stub.url ?? request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct CancelledASRHTTPTransport: ASRHTTPTransport {
    func perform(_ request: URLRequest, body: Data) async throws -> ASRHTTPResponse {
        throw URLError(.cancelled)
    }
}

#if canImport(Darwin)
/// Streaming URLProtocol used only to prove the native transport bounds a
/// *live* response. `ASRURLProtocol` above delivers one completed body; this
/// one keeps producing chunks so a completed-length check would be too late.
private final class ASRStreamingURLProtocol: URLProtocol, @unchecked Sendable {
    struct Configuration: Sendable {
        var statusCode: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var chunkBytes: Int = 16 * 1024
        var totalChunks: Int = 512
        var chunkIntervalMilliseconds: Int = 1
        /// When set, delivered as one chunk instead of generated payload.
        var body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var configuration = Configuration()
    nonisolated(unsafe) private static var deliveredChunks = 0
    nonisolated(unsafe) private static var stopped = false

    private let timerLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var sentChunks = 0

    static func prepare(_ newConfiguration: Configuration) {
        lock.lock()
        configuration = newConfiguration
        deliveredChunks = 0
        stopped = false
        lock.unlock()
    }

    static func snapshot() -> (deliveredChunks: Int, stopped: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (deliveredChunks, stopped)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let configuration = Self.configuration
        Self.lock.unlock()

        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: configuration.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: configuration.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if let body = configuration.body {
            Self.noteChunk()
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let timer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "floe.asr.streaming.urlprotocol"))
        let interval = DispatchTimeInterval.milliseconds(
            Swift.max(1, configuration.chunkIntervalMilliseconds))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Self.isStopped || self.sentChunks >= configuration.totalChunks {
                self.cancelTimer()
                if !Self.isStopped {
                    self.client?.urlProtocolDidFinishLoading(self)
                }
                return
            }
            self.sentChunks += 1
            Self.noteChunk()
            self.client?.urlProtocol(
                self,
                didLoad: Data(repeating: 0x20, count: configuration.chunkBytes))
        }
        timerLock.lock()
        self.timer = timer
        timerLock.unlock()
        timer.resume()
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.stopped = true
        Self.lock.unlock()
        cancelTimer()
    }

    private func cancelTimer() {
        timerLock.lock()
        let timer = self.timer
        self.timer = nil
        timerLock.unlock()
        timer?.cancel()
    }

    private static func noteChunk() {
        lock.lock()
        deliveredChunks += 1
        lock.unlock()
    }

    private static var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}
#endif

@Suite("OpenAI file transcription", .serialized)
struct OpenAIFileTranscriptionTests {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ASRURLProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

#if canImport(Darwin)
    private func makeStreamingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ASRStreamingURLProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    private func waitForStreamingStop(
        timeout: TimeInterval = 3
    ) async -> (deliveredChunks: Int, stopped: Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = ASRStreamingURLProtocol.snapshot()
            if snapshot.stopped { return snapshot }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return ASRStreamingURLProtocol.snapshot()
    }
#endif

    private func bodyString(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    private func fieldCount(_ body: String, _ name: String) -> Int {
        body.components(separatedBy: "name=\"\(name)\"").count - 1
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test("Modern gpt-transcribe sends languages[] and parses detected languages")
    func modernJSONPayloadAndResponse() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        ASRURLProtocol.prepare([
            .init(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try json([
                    "text": "Bonjour, pouvez-vous m'entendre ?",
                    "languages": [["code": "fr"]],
                ]))
        ])
        let profile = ASRProfile.openAICompatible(
            fileEndpoint: "https://relay.example/openai/v1",
            credentialReference: ASRCredentialReference(
                service: "com.floe.asr", account: "openai-payg"),
            languages: ["en", "fr"],
            prompt: "A support call",
            keywords: ["AC-42"])
        let request = ASRFileTranscriptionRequest(
            profile: profile,
            audio: Data([0x01, 0x02, 0x03, 0x04]),
            filename: "memo.wav",
            mimeType: "audio/wav",
            sourceDurationSeconds: 12.5,
            streamsResponse: true)
        let adapter = OpenAITranscriptionAdapter(session: session)
        let result = try await adapter.transcribe(request, credential: "sk-test-secret")

        #expect(result.text == "Bonjour, pouvez-vous m'entendre ?")
        #expect(result.detectedLanguages == ["fr"])
        #expect(result.language == "fr")
        #expect(result.segments.isEmpty)
        #expect(result.timing == .sourceSpanOnly)

        let recorded = try #require(ASRURLProtocol.snapshotRequests().first)
        #expect(recorded.url?.absoluteString
            == "https://relay.example/openai/v1/audio/transcriptions")
        #expect(recorded.value(forHTTPHeaderField: "Authorization")
            == "Bearer sk-test-secret")
        #expect(recorded.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(recorded.value(forHTTPHeaderField: "Content-Type")?
            .hasPrefix("multipart/form-data; boundary=floe-asr-") == true)
        let body = bodyString(recorded)
        #expect(fieldCount(body, "model") == 1)
        #expect(body.contains("gpt-transcribe"))
        #expect(fieldCount(body, "languages[]") == 2)
        #expect(fieldCount(body, "language") == 0)
        #expect(fieldCount(body, "stream") == 1)
        #expect(fieldCount(body, "prompt") == 1)
        #expect(fieldCount(body, "keywords[]") == 1)
        #expect(!body.contains("verbose_json"))
        #expect(!body.contains("timestamp_granularities"))
    }

    @Test("Modern SSE deltas and final event produce one bounded transcript")
    func modernSSE() async throws {
        let sse = """
        event: transcript.text.delta
        data: {"type":"transcript.text.delta","delta":"Hel"}

        event: transcript.text.delta
        data: {"type":"transcript.text.delta","delta":"lo"}

        event: transcript.text.done
        data: {"type":"transcript.text.done","text":"Hello","languages":[{"code":"fr"}]}

        """
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        ASRURLProtocol.prepare([
            .init(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Data(sse.utf8))
        ])
        let adapter = OpenAITranscriptionAdapter(session: session)
        let profile = ASRProfile.openAICompatible(
            fileEndpoint: "https://relay.example/v1")
        let result = try await adapter.transcribe(
            ASRFileTranscriptionRequest(
                profile: profile,
                audio: Data([0, 1, 2, 3]),
                filename: "memo.wav",
                mimeType: "audio/wav",
                streamsResponse: true),
            credential: "sk-test-secret")
        #expect(result.text == "Hello")
        #expect(result.detectedLanguages == ["fr"])
        #expect(result.segments.isEmpty)
        #expect(result.timing == .none)
        let body = bodyString(try #require(ASRURLProtocol.snapshotRequests().first))
        #expect(fieldCount(body, "stream") == 1)
    }

    @Test("An SSE stream without the final event is rejected, not truncated")
    func truncatedSSE() async throws {
        let sse = """
        data: {"type":"transcript.text.delta","delta":"partial"}

        """
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        ASRURLProtocol.prepare([
            .init(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: Data(sse.utf8))
        ])
        let adapter = OpenAITranscriptionAdapter(session: session)
        let profile = ASRProfile.openAICompatible(
            fileEndpoint: "https://relay.example/v1")
        await #expect(throws: ASRTranscriptionError.self) {
            _ = try await adapter.transcribe(
                ASRFileTranscriptionRequest(
                    profile: profile,
                    audio: Data([0, 1, 2, 3]),
                    filename: "memo.wav",
                    mimeType: "audio/wav"),
                credential: "sk-test-secret")
        }
    }

    @Test("Whisper keeps the legacy language/verbose segment contract")
    func whisperLegacyPayloadAndSegments() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        ASRURLProtocol.prepare([
            .init(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try json([
                    "text": "Hello world",
                    "language": "en",
                    "segments": [
                        ["start": 0.0, "end": 1.5, "text": "Hello"],
                        ["start": 1.5, "end": 3.0, "text": "world"],
                    ],
                ]))
        ])
        let profile = ASRProfile.openAICompatible(
            fileModelID: "whisper-1",
            liveModelID: nil,
            fileEndpoint: "https://relay.example/v1")
        let adapter = OpenAITranscriptionAdapter(session: session)
        let result = try await adapter.transcribe(
            ASRFileTranscriptionRequest(
                profile: profile,
                audio: Data([0, 1, 2, 3]),
                filename: "memo.wav",
                mimeType: "audio/wav",
                languages: ["en", "fr"],
                sourceDurationSeconds: 3.0,
                streamsResponse: true),
            credential: "sk-test-secret")
        #expect(result.text == "Hello world")
        #expect(result.language == "en")
        #expect(result.segments == [
            ASRTranscriptionSegment(start: 0, end: 1.5, text: "Hello"),
            ASRTranscriptionSegment(start: 1.5, end: 3, text: "world"),
        ])
        #expect(result.timing == .providerSegments)
        let recorded = try #require(ASRURLProtocol.snapshotRequests().first)
        let body = bodyString(recorded)
        #expect(fieldCount(body, "language") == 1)
        #expect(fieldCount(body, "languages[]") == 0)
        #expect(fieldCount(body, "response_format") == 1)
        #expect(body.contains("verbose_json"))
        #expect(fieldCount(body, "timestamp_granularities[]") == 1)
        #expect(fieldCount(body, "stream") == 0)
    }

    @Test("Unknown compatible model receives only the minimum wire arguments")
    func unknownModelMinimumBody() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        ASRURLProtocol.prepare([
            .init(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try json(["text": "ok"]))
        ])
        let profile = ASRProfile.openAICompatible(
            fileModelID: "relay-asr-v2",
            liveModelID: nil,
            fileEndpoint: "https://relay.example/v1",
            prompt: "must not be sent",
            keywords: ["must-not-be-sent"])
        let adapter = OpenAITranscriptionAdapter(session: session)
        _ = try await adapter.transcribe(
            ASRFileTranscriptionRequest(
                profile: profile,
                audio: Data([0, 1, 2, 3]),
                filename: "memo.wav",
                mimeType: "audio/wav",
                languages: ["en", "fr"],
                streamsResponse: true),
            credential: "sk-test-secret")
        let body = bodyString(try #require(ASRURLProtocol.snapshotRequests().first))
        #expect(body.contains("relay-asr-v2"))
        #expect(fieldCount(body, "language") == 1)
        #expect(body.contains("\r\n\r\nen\r\n"))
        #expect(fieldCount(body, "languages[]") == 0)
        #expect(fieldCount(body, "prompt") == 0)
        #expect(fieldCount(body, "keywords[]") == 0)
        #expect(fieldCount(body, "response_format") == 0)
        #expect(fieldCount(body, "stream") == 0)
        #expect(fieldCount(body, "timestamp_granularities[]") == 0)
    }

    @Test("Legacy request API stays source-compatible and never fabricates timing")
    func legacyRequestTextOnly() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        ASRURLProtocol.prepare([
            .init(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try json(["text": "Text only", "language": "en"]))
        ])
        let adapter = OpenAITranscriptionAdapter(session: session)
        let result = try await adapter.transcribe(
            ASRTranscriptionRequest(
                endpointBaseURL: "https://relay.example/v1",
                modelID: "whisper-1",
                language: "en",
                filename: "memo.wav",
                mimeType: "audio/wav",
                audio: Data([0, 1, 2, 3]),
                durationSeconds: 10),
            credential: "sk-test-secret")
        #expect(result.text == "Text only")
        #expect(result.segments.isEmpty)
        #expect(result.timing == .sourceSpanOnly)
        let body = bodyString(try #require(ASRURLProtocol.snapshotRequests().first))
        #expect(fieldCount(body, "language") == 1)
        #expect(fieldCount(body, "languages[]") == 0)
    }

    @Test("Invalid endpoint fails before a key or request is used")
    func invalidEndpointDoesNotSend() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        ASRURLProtocol.prepare([])
        let adapter = OpenAITranscriptionAdapter(session: session)
        let profile = ASRProfile.openAICompatible(
            fileEndpoint: "http://relay.example/v1")
        do {
            _ = try await adapter.transcribe(
                ASRFileTranscriptionRequest(
                    profile: profile,
                    audio: Data([0, 1, 2, 3]),
                    filename: "memo.wav",
                    mimeType: "audio/wav"),
                credential: "sk-test-secret")
            Issue.record("expected invalid configuration")
        } catch let error as ASRTranscriptionError {
            #expect(error == .invalidConfiguration("endpoint must use https"))
            #expect(!String(describing: error).contains("sk-test-secret"))
        }
        #expect(ASRURLProtocol.snapshotRequests().isEmpty)
    }

    @Test("A cross-origin response is rejected even if a redirect slips through")
    func crossOriginResponseRejected() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        ASRURLProtocol.prepare([
            .init(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: try json(["text": "stolen"]),
                url: URL(string: "https://evil.example/audio/transcriptions"))
        ])
        let adapter = OpenAITranscriptionAdapter(session: session)
        let profile = ASRProfile.openAICompatible(
            fileEndpoint: "https://relay.example/v1")
        await #expect(throws: ASRTranscriptionError.self) {
            _ = try await adapter.transcribe(
                ASRFileTranscriptionRequest(
                    profile: profile,
                    audio: Data([0, 1, 2, 3]),
                    filename: "memo.wav",
                    mimeType: "audio/wav"),
                credential: "sk-test-secret")
        }
        #expect(ASRURLProtocol.snapshotRequests().count == 1)
    }

    @Test("Redirect policy never allows a credential to cross an origin")
    func redirectPolicy() {
        let original = URL(string: "https://api.example/v1/realtime")!
        #expect(ASRRedirectGuard.isAllowed(
            from: original, to: URL(string: "https://api.example/v1/other")!))
        #expect(!ASRRedirectGuard.isAllowed(
            from: original, to: URL(string: "https://evil.example/v1/realtime")!))
        #expect(!ASRRedirectGuard.isAllowed(
            from: original, to: URL(string: "https://api.example:8443/v1/realtime")!))
        #expect(!ASRRedirectGuard.isAllowed(
            from: original, to: URL(string: "http://api.example/v1/realtime")!))
    }

    @Test("Transport cancellation stays CancellationError, never a provider failure")
    func cancellationIsNotFailure() async throws {
        let adapter = OpenAITranscriptionAdapter(
            transport: CancelledASRHTTPTransport())
        let profile = ASRProfile.openAICompatible(
            fileEndpoint: "https://relay.example/v1")
        await #expect(throws: CancellationError.self) {
            _ = try await adapter.transcribe(
                ASRFileTranscriptionRequest(
                    profile: profile,
                    audio: Data([0, 1, 2, 3]),
                    filename: "memo.wav",
                    mimeType: "audio/wav"),
                credential: "sk-test-secret")
        }
    }

    @Test("An oversized provider body is refused before parsing")
    func oversizedResponse() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        ASRURLProtocol.prepare([
            .init(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(repeating: 0x20,
                           count: OpenAITranscriptionAdapter.maximumResponseBytes + 1))
        ])
        let adapter = OpenAITranscriptionAdapter(session: session)
        let profile = ASRProfile.openAICompatible(
            fileEndpoint: "https://relay.example/v1")
        do {
            _ = try await adapter.transcribe(
                ASRFileTranscriptionRequest(
                    profile: profile,
                    audio: Data([0, 1, 2, 3]),
                    filename: "memo.wav",
                    mimeType: "audio/wav"),
                credential: "sk-test-secret")
            Issue.record("expected responseTooLarge")
        } catch let error as ASRTranscriptionError {
            #expect(error == .responseTooLarge)
        }
    }

    @Test("Provider body and key never appear in an HTTP error")
    func redactedHTTPError() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        ASRURLProtocol.prepare([
            .init(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"bad key sk-test-secret"}"#.utf8))
        ])
        let adapter = OpenAITranscriptionAdapter(session: session)
        let profile = ASRProfile.openAICompatible(
            fileEndpoint: "https://relay.example/v1")
        do {
            _ = try await adapter.transcribe(
                ASRFileTranscriptionRequest(
                    profile: profile,
                    audio: Data([0, 1, 2, 3]),
                    filename: "memo.wav",
                    mimeType: "audio/wav"),
                credential: "sk-test-secret")
            Issue.record("expected httpStatus")
        } catch let error as ASRTranscriptionError {
            #expect(error == .httpStatus(400))
            #expect(!String(describing: error).contains("sk-test-secret"))
            #expect(!String(describing: error).contains("bad key"))
        }
    }

#if canImport(Darwin)
    @Test("The native transport stops an oversized streaming response early")
    func nativeOversizedStreamingResponse() async throws {
        ASRStreamingURLProtocol.prepare(.init(
            chunkBytes: 16 * 1024,
            totalChunks: 512,
            chunkIntervalMilliseconds: 1))
        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        // A small test-only ceiling exercises the same streaming bound as the
        // production 8 MiB ceiling without moving 8 MiB through the test host.
        let transport = URLSessionASRHTTPTransport(
            session: session, maximumResponseBodyBytes: 64 * 1024)
        let adapter = OpenAITranscriptionAdapter(transport: transport)
        let profile = ASRProfile.openAICompatible(
            fileEndpoint: "https://relay.example/v1")
        do {
            _ = try await adapter.transcribe(
                ASRFileTranscriptionRequest(
                    profile: profile,
                    audio: Data([0, 1, 2, 3]),
                    filename: "memo.wav",
                    mimeType: "audio/wav"),
                credential: "sk-test-secret")
            Issue.record("expected responseTooLarge")
        } catch let error as ASRTranscriptionError {
            #expect(error == .responseTooLarge)
        }
        let snapshot = await waitForStreamingStop()
        #expect(snapshot.stopped)
        // The producer has 512 chunks (8 MiB) available; cancellation must stop
        // it after the bounded prefix, not after the whole body.
        #expect(snapshot.deliveredChunks < 512)
        #expect(snapshot.deliveredChunks <= 64)
    }

    @Test("A declared oversized response is cancelled before its body starts")
    func nativeDeclaredOversizeResponse() async throws {
        ASRStreamingURLProtocol.prepare(.init(
            headers: [
                "Content-Type": "application/json",
                "Content-Length": "\(ASRTransportLimits.maximumResponseBodyBytes + 1)",
            ],
            chunkBytes: 16 * 1024,
            totalChunks: 512,
            chunkIntervalMilliseconds: 5))
        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        let transport = URLSessionASRHTTPTransport(session: session)
        do {
            _ = try await transport.perform(
                URLRequest(url: URL(
                    string: "https://relay.example/v1/audio/transcriptions")!),
                body: Data([0, 1, 2, 3]))
            Issue.record("expected responseTooLarge")
        } catch let error as ASRTranscriptionError {
            #expect(error == .responseTooLarge)
        }
        let snapshot = await waitForStreamingStop()
        #expect(snapshot.stopped)
        #expect(snapshot.deliveredChunks == 0)
    }

    @Test("A body exactly at the receive ceiling is accepted")
    func nativeResponseAtCeiling() async throws {
        let body = Data(#"{"text":"ok"}"#.utf8)
        ASRStreamingURLProtocol.prepare(.init(body: body))
        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        let transport = URLSessionASRHTTPTransport(
            session: session, maximumResponseBodyBytes: body.count)
        let response = try await transport.perform(
            URLRequest(url: URL(
                string: "https://relay.example/v1/audio/transcriptions")!),
            body: Data([0, 1, 2, 3]))
        #expect(response.statusCode == 200)
        #expect(response.body == body)
    }

    @Test("The production receive ceiling matches the adapter's response cap")
    func nativeCeilingMatchesAdapter() {
        #expect(ASRTransportLimits.maximumResponseBodyBytes
            == OpenAITranscriptionAdapter.maximumResponseBytes)
    }

    @Test("The bounded task delegate keeps the credential on the origin")
    func boundedDelegateRedirectPolicy() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let delegate = ASRBoundedHTTPTaskDelegate(maximumBytes: 1_024)
        let original = URL(string: "https://relay.example/v1/audio/transcriptions")!
        let task = session.dataTask(with: URLRequest(url: original))
        let redirect = HTTPURLResponse(
            url: original,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!

        let crossOrigin = URL(string: "https://evil.example/v1/audio/transcriptions")!
        var crossOriginCalled = false
        var crossOriginAllowed: URLRequest?
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: crossOrigin)
        ) { request in
            crossOriginCalled = true
            crossOriginAllowed = request
        }
        #expect(crossOriginCalled)
        #expect(crossOriginAllowed == nil)

        let sameOrigin = URL(string: "https://relay.example/v1/other")!
        var sameOriginAllowed: URLRequest?
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: redirect,
            newRequest: URLRequest(url: sameOrigin)
        ) { request in
            sameOriginAllowed = request
        }
        #expect(sameOriginAllowed?.url == sameOrigin)
    }

    @Test("Cancelling the calling task cancels the native upload promptly")
    func nativeCancellation() async throws {
        ASRStreamingURLProtocol.prepare(.init(
            chunkBytes: 16 * 1024,
            totalChunks: 4_096,
            chunkIntervalMilliseconds: 1))
        let session = makeStreamingSession()
        defer { session.invalidateAndCancel() }
        let adapter = OpenAITranscriptionAdapter(
            transport: URLSessionASRHTTPTransport(session: session))
        let profile = ASRProfile.openAICompatible(
            fileEndpoint: "https://relay.example/v1")
        let task = Task {
            try await adapter.transcribe(
                ASRFileTranscriptionRequest(
                    profile: profile,
                    audio: Data([0, 1, 2, 3]),
                    filename: "memo.wav",
                    mimeType: "audio/wav"),
                credential: "sk-test-secret")
        }
        for _ in 0..<400 {
            if ASRStreamingURLProtocol.snapshot().deliveredChunks > 0 { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation is not a provider failure.
        }
        let snapshot = await waitForStreamingStop()
        #expect(snapshot.stopped)
        #expect(snapshot.deliveredChunks < 4_096)
    }
#endif
}
