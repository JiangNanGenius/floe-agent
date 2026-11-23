// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeCore
@testable import FloeProviders

// Local, deterministic stand-ins for the WebSocket transport: no user keys,
// no real traffic. The socket scripts inbound messages (audio frames, finish
// events, failures, parks) and records everything sent to it.

private enum FakeDeepSeekError: Error {
    case scriptExhausted
    case unscriptedConnection
}

private final class FakeDeepSeekSocket: ASRWebSocketConnection, @unchecked Sendable {
    enum Step {
        case message(ASRWebSocketMessage)
        /// Returned only AFTER the client has sent finish_text — models the
        /// real server (the finish event never precedes finish_text) and
        /// makes send-side assertions deterministic.
        case finishResponse(ASRWebSocketMessage)
        case fail(Error)
        /// Never delivers until the task is cancelled.
        case park
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var sentMessages: [ASRWebSocketMessage] = []
    private var firstSendWaiters: [CheckedContinuation<Void, Never>] = []
    /// When true the FIRST receive parks until the first send — proves the
    /// send and receive lanes run in parallel.
    private let gateFirstReceiveOnSend: Bool
    private var gateConsumed = false
    /// When set, every send fails with this error (send-failure regression).
    private let sendFailure: Error?
    private var sentFinishText = false
    private(set) var closeCount = 0
    private(set) var cancelCount = 0

    init(steps: [Step], gateFirstReceiveOnSend: Bool = false, sendFailure: Error? = nil) {
        self.steps = steps
        self.gateFirstReceiveOnSend = gateFirstReceiveOnSend
        self.sendFailure = sendFailure
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var sent: [ASRWebSocketMessage] { withLock { sentMessages } }

    func send(_ message: ASRWebSocketMessage) async throws {
        if let sendFailure { throw sendFailure }
        let waiters: [CheckedContinuation<Void, Never>] = withLock {
            sentMessages.append(message)
            if case .text(let json) = message,
               let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               dict["event"] as? String == "finish_text" {
                sentFinishText = true
            }
            let waiters = firstSendWaiters
            firstSendWaiters = []
            return waiters
        }
        waiters.forEach { $0.resume() }
    }

    func receive() async throws -> ASRWebSocketMessage {
        if gateFirstReceiveOnSend, !withLock({ gateConsumed }) {
            withLock { gateConsumed = true }
            await withCheckedContinuation { continuation in
                let shouldWait: Bool = withLock {
                    if !sentMessages.isEmpty { return false }
                    firstSendWaiters.append(continuation)
                    return true
                }
                if !shouldWait { continuation.resume() }
            }
        }
        let step: Step? = withLock { steps.isEmpty ? nil : steps.removeFirst() }
        guard let step else { throw FakeDeepSeekError.scriptExhausted }
        switch step {
        case .message(let message): return message
        case .finishResponse(let message):
            while !Task.isCancelled, !withLock({ sentFinishText }) {
                try await Task.sleep(for: .milliseconds(5))
            }
            try Task.checkCancellation()
            return message
        case .fail(let error): throw error
        case .park:
            // Models a transport whose pending receive is failed by
            // cancel(): loops until task cancellation or socket cancel.
            while !Task.isCancelled {
                if withLock({ cancelCount > 0 }) { throw URLError(.cancelled) }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw CancellationError()
        }
    }

    func close() { withLock { closeCount += 1 } }
    func cancel() { withLock { cancelCount += 1 } }
}

private final class FakeDeepSeekTransport: ASRWebSocketTransport, @unchecked Sendable {
    enum ConnectStep {
        case socket(FakeDeepSeekSocket)
        case fail(Error)
    }

    struct RecordedRequest: Sendable {
        let url: URL?
        let authorization: String?
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private var steps: [ConnectStep]
    private var recorded: [RecordedRequest] = []

    init(steps: [ConnectStep]) { self.steps = steps }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var requests: [RecordedRequest] { withLock { recorded } }

    func connect(_ request: URLRequest) async throws -> any ASRWebSocketConnection {
        withLock {
            recorded.append(RecordedRequest(
                url: request.url,
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                timeout: request.timeoutInterval))
        }
        let step: ConnectStep? = withLock { steps.isEmpty ? nil : steps.removeFirst() }
        guard let step else { throw FakeDeepSeekError.unscriptedConnection }
        switch step {
        case .socket(let socket): return socket
        case .fail(let error): throw error
        }
    }
}

final class DeepSeekStreamingSpeechTests: XCTestCase, @unchecked Sendable {
    private let sessionID = UUID(uuidString: "3F6B2A10-1111-2222-3333-444455556666")!

    // MARK: - Helpers

    private func request(
        text: String = "你好，世界。",
        voice: String = "stella",
        provider: TTSSpeakerProvider = .deepSeek,
        segmentIndex: Int = 0
    ) -> TTSSynthesisRequest {
        TTSSynthesisRequest(
            sessionID: sessionID, segmentIndex: segmentIndex,
            provider: provider, billingRoute: .payAsYouGo,
            modelID: "", voiceID: voice, text: text,
            speechRateRatio: 1.0, format: .pcm24k)
    }

    private func collect(_ stream: TTSAudioChunkStream) async throws -> [TTSAudioChunk] {
        var chunks: [TTSAudioChunk] = []
        for try await chunk in stream { chunks.append(chunk) }
        return chunks
    }

    private func finishSuccess() -> ASRWebSocketMessage {
        .text(#"{"event":"finish","code":"success","message":"done"}"#)
    }

    private func textEvents(_ socket: FakeDeepSeekSocket) -> [String] {
        socket.sent.compactMap { message in
            if case .text(let json) = message,
               let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               dict["event"] as? String == "text" {
                return dict["text"] as? String
            }
            return nil
        }
    }

    private func eventNames(_ socket: FakeDeepSeekSocket) -> [String] {
        socket.sent.compactMap { message in
            guard case .text(let json) = message,
                  let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return dict["event"] as? String
        }
    }

    // MARK: - Round session (the true incremental entry)

    func testRoundSessionSendsDeltasInParallelAndFinishesOnceAtStreamEnd() async throws {
        let socket = FakeDeepSeekSocket(
            steps: [
                .message(.data(Data([1, 2, 3, 4]))),
                .message(.data(Data([5, 6]))),
                .finishResponse(finishSuccess()),
            ],
            gateFirstReceiveOnSend: true)   // receive #1 blocks until send #1: lanes are parallel
        let transport = FakeDeepSeekTransport(steps: [.socket(socket)])
        let session = DeepSeekStreamingSpeechSession(
            voiceID: "stella", credential: "fixture-key", transport: transport)

        let (textStream, continuation) = AsyncStream<String>.makeStream()
        let stream = session.synthesize(
            text: textStream, sessionID: sessionID, segmentIndex: 7)
        let consumer = Task { try await collect(stream) }
        // Feed the round body as model-paced deltas, then TERMINATE the
        // stream (the coordinator's contract): finish_text rides on end.
        continuation.yield("你好")
        continuation.yield("，世界")
        continuation.yield("。")
        continuation.finish()

        let chunks = try await consumer.value
        XCTAssertEqual(chunks.map(\.pcm), [Data([1, 2, 3, 4]), Data([5, 6]), Data()])
        XCTAssertEqual(chunks.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(chunks.map(\.sampleRate), [24_000, 24_000, 24_000])
        XCTAssertEqual(chunks.map(\.sessionID), [sessionID, sessionID, sessionID])
        XCTAssertEqual(chunks.map(\.segmentIndex), [7, 7, 7])
        XCTAssertEqual(chunks.map(\.isFinal), [false, false, true])

        XCTAssertEqual(eventNames(socket), ["text", "text", "text", "finish_text"])
        XCTAssertEqual(textEvents(socket).joined(), "你好，世界。")
        XCTAssertEqual(socket.closeCount, 1)
        XCTAssertEqual(socket.cancelCount, 0)
    }

    func testRoundSessionEmptyDeltasAreSkippedWhitespaceIsBilled() async throws {
        let socket = FakeDeepSeekSocket(steps: [
            .message(.data(Data([1, 2]))),
            .finishResponse(finishSuccess()),
        ])
        let session = DeepSeekStreamingSpeechSession(
            voiceID: "stella", credential: "fixture-key",
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        let (textStream, continuation) = AsyncStream<String>.makeStream()
        let stream = session.synthesize(text: textStream, sessionID: sessionID, segmentIndex: 0)
        let consumer = Task { try await collect(stream) }
        continuation.yield("")        // never forwarded
        continuation.yield(" ")       // whitespace IS forwarded (billed)
        continuation.yield("字")
        continuation.finish()
        let chunks = try await consumer.value
        XCTAssertEqual(chunks.last?.isFinal, true)
        XCTAssertEqual(textEvents(socket), [" ", "字"])
        XCTAssertEqual(eventNames(socket), ["text", "text", "finish_text"])
    }

    func testRoundSessionCancelMidRoundTerminatesAndCancelsSocket() async throws {
        let socket = FakeDeepSeekSocket(steps: [
            .message(.data(Data([1, 2]))),
            .park,
        ])
        let session = DeepSeekStreamingSpeechSession(
            voiceID: "stella", credential: "fixture-key",
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        let (textStream, continuation) = AsyncStream<String>.makeStream()
        let stream = session.synthesize(text: textStream, sessionID: sessionID, segmentIndex: 0)
        let consumer = Task { try await collect(stream) }
        continuation.yield("被打断的一轮")
        try await Task.sleep(for: .milliseconds(200))
        consumer.cancel()
        do {
            _ = try await consumer.value
            XCTFail("cancelled round session succeeded")
        } catch let error as TTSSynthesisError {
            XCTAssertEqual(error, .cancelled)
        }
        // The caller's stream stays open (model still generating): the
        // session must still unwind and kill the socket.
        XCTAssertGreaterThanOrEqual(socket.cancelCount, 1)
        XCTAssertEqual(socket.closeCount, 0)
        continuation.finish()
    }

    func testRoundSessionSendFailureImmediatelyCancelsAndSurfacesSanitizedError() async throws {
        // The receive lane parks forever (no scripted inbound): without the
        // send-failure -> connection-cancel path this would wait out a
        // server timeout instead of failing promptly.
        let socket = FakeDeepSeekSocket(
            steps: [.park], sendFailure: URLError(.networkConnectionLost))
        let session = DeepSeekStreamingSpeechSession(
            voiceID: "stella", credential: "fixture-key",
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        let (textStream, continuation) = AsyncStream<String>.makeStream()
        let stream = session.synthesize(text: textStream, sessionID: sessionID, segmentIndex: 0)
        let consumer = Task { try await collect(stream) }
        continuation.yield("触发发送失败")
        continuation.finish()
        do {
            _ = try await consumer.value
            XCTFail("expected send failure")
        } catch let error as TTSSynthesisError {
            XCTAssertEqual(error, .transport(provider: .deepSeek, failure: .cannotConnect))
        }
        XCTAssertGreaterThanOrEqual(socket.cancelCount, 1)
        XCTAssertEqual(socket.closeCount, 0)
    }

    func testRoundSessionFinishErrorCodesMapToFixedRedactedErrors() async throws {
        for (code, expected) in [
            (#"{"event":"finish","code":"content_filter","message":"risky body text"}"#, TTSSynthesisError.providerRejected(provider: .deepSeek, code: nil, logID: nil)),
            (#"{"event":"finish","code":"invalid_input","message":"bad text"}"#, .providerRejected(provider: .deepSeek, code: nil, logID: nil)),
            (#"{"event":"finish","code":"service_error","message":"boom"}"#, .providerRejected(provider: .deepSeek, code: nil, logID: nil)),
            (#"{"event":"finish","code":"input_timeout","message":"slow"}"#, .transport(provider: .deepSeek, failure: .timedOut)),
        ] as [(String, TTSSynthesisError)] {
            let socket = FakeDeepSeekSocket(steps: [
                .message(.data(Data([1, 2]))),
                .message(.text(code)),
            ])
            let session = DeepSeekStreamingSpeechSession(
                voiceID: "stella", credential: "fixture-key",
                transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
            let (textStream, continuation) = AsyncStream<String>.makeStream()
            continuation.yield("文本")
            continuation.finish()
            let stream = session.synthesize(text: textStream, sessionID: sessionID, segmentIndex: 0)
            do {
                _ = try await collect(stream)
                XCTFail("expected failure for \(code)")
            } catch let error as TTSSynthesisError {
                XCTAssertEqual(error, expected)
            }
            XCTAssertEqual(socket.cancelCount, 1)
            XCTAssertEqual(socket.closeCount, 0)
        }
    }

    func testRoundSessionDisconnectMidRoundKeepsReceivedFrames() async throws {
        let socket = FakeDeepSeekSocket(steps: [
            .message(.data(Data([1, 2, 3, 4]))),
            .fail(URLError(.networkConnectionLost)),
        ])
        let session = DeepSeekStreamingSpeechSession(
            voiceID: "stella", credential: "fixture-key",
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        let (textStream, continuation) = AsyncStream<String>.makeStream()
        continuation.yield("断了")
        continuation.finish()
        let stream = session.synthesize(text: textStream, sessionID: sessionID, segmentIndex: 0)
        var received: [TTSAudioChunk] = []
        do {
            for try await chunk in stream { received.append(chunk) }
            XCTFail("expected disconnect failure")
        } catch let error as TTSSynthesisError {
            XCTAssertEqual(error, .transport(provider: .deepSeek, failure: .cannotConnect))
        }
        // Already-received audio stays delivered, in order, no replay/final.
        XCTAssertEqual(received.map(\.pcm), [Data([1, 2, 3, 4])])
        XCTAssertEqual(received.map(\.isFinal), [false])
        XCTAssertGreaterThanOrEqual(socket.cancelCount, 1)
    }

    func testRoundSessionBillingCapStopsForwarding() async throws {
        let socket = FakeDeepSeekSocket(steps: [.park])
        let session = DeepSeekStreamingSpeechSession(
            voiceID: "stella", credential: "fixture-key",
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        let (textStream, continuation) = AsyncStream<String>.makeStream()
        let stream = session.synthesize(text: textStream, sessionID: sessionID, segmentIndex: 0)
        let consumer = Task { try await collect(stream) }
        continuation.yield(String(repeating: "字", count: 4_000))   // 8,000 billing
        continuation.yield(String(repeating: "字", count: 1_001))   // +2,002 > 10,000
        continuation.finish()
        do {
            _ = try await consumer.value
            XCTFail("expected billing cap failure")
        } catch let error as TTSSynthesisError {
            guard case .invalidConfiguration = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(eventNames(socket).contains("finish_text"))
        XCTAssertGreaterThanOrEqual(socket.cancelCount, 1)
    }

    func testRoundSessionFinishWithoutAudioIsTruncated() async throws {
        let socket = FakeDeepSeekSocket(steps: [.finishResponse(finishSuccess())])
        let session = DeepSeekStreamingSpeechSession(
            voiceID: "stella", credential: "fixture-key",
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        let (textStream, continuation) = AsyncStream<String>.makeStream()
        continuation.yield("无声")
        continuation.finish()
        let stream = session.synthesize(text: textStream, sessionID: sessionID, segmentIndex: 0)
        do {
            _ = try await collect(stream)
            XCTFail("expected truncation")
        } catch let error as TTSSynthesisError {
            XCTAssertEqual(error, .streamTruncated(provider: .deepSeek))
        }
        XCTAssertEqual(eventNames(socket), ["text", "finish_text"])
    }

    func testRoundSessionFramesAfterFinishAreNotDelivered() async throws {
        let socket = FakeDeepSeekSocket(steps: [
            .message(.data(Data([1, 2]))),
            .message(finishSuccess()),
            .message(.data(Data([9, 9]))),
        ])
        let session = DeepSeekStreamingSpeechSession(
            voiceID: "stella", credential: "fixture-key",
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        let (textStream, continuation) = AsyncStream<String>.makeStream()
        continuation.yield("完")
        continuation.finish()
        let stream = session.synthesize(text: textStream, sessionID: sessionID, segmentIndex: 0)
        let chunks = try await collect(stream)
        XCTAssertEqual(chunks.map(\.pcm), [Data([1, 2]), Data()])
        XCTAssertEqual(chunks.last?.isFinal, true)
        XCTAssertEqual(socket.closeCount, 1)
    }

    func testRoundSessionHandshakeFailureSurfacesAsTransport() async throws {
        let transport = FakeDeepSeekTransport(
            steps: [.fail(URLError(.cannotConnectToHost))])
        let session = DeepSeekStreamingSpeechSession(
            voiceID: "stella", credential: "fixture-key", transport: transport)
        let (textStream, continuation) = AsyncStream<String>.makeStream()
        continuation.finish()
        let stream = session.synthesize(text: textStream, sessionID: sessionID, segmentIndex: 0)
        do {
            _ = try await collect(stream)
            XCTFail("expected handshake failure")
        } catch let error as TTSSynthesisError {
            XCTAssertEqual(error, .transport(provider: .deepSeek, failure: .cannotConnect))
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testRoundSessionRejectsBadVoiceAndEmptyCredentialBeforeConnecting() async throws {
        for credential in ["fixture-key", "   "] {
            let transport = FakeDeepSeekTransport(steps: [])
            let session = DeepSeekStreamingSpeechSession(
                voiceID: "unknown", credential: credential, transport: transport)
            let (textStream, continuation) = AsyncStream<String>.makeStream()
            continuation.finish()
            let stream = session.synthesize(text: textStream, sessionID: sessionID, segmentIndex: 0)
            do {
                _ = try await collect(stream)
                XCTFail("expected configuration failure")
            } catch let error as TTSSynthesisError {
                if credential == "fixture-key" {
                    guard case .invalidConfiguration = error else { return XCTFail("\(error)") }
                } else {
                    XCTAssertEqual(error, .credentialMissing(provider: .deepSeek, route: .payAsYouGo))
                }
            }
            XCTAssertEqual(transport.requests.count, 0)
        }
    }

    // MARK: - Per-sentence adapter (TTSSpeechProviding)

    func testAdapterHandshakeTargetsOfficialEndpointWithVoicePCMAndAuth() async throws {
        let socket = FakeDeepSeekSocket(steps: [
            .message(.data(Data([1, 2]))),
            .message(finishSuccess()),
        ])
        let transport = FakeDeepSeekTransport(steps: [.socket(socket)])
        let adapter = DeepSeekStreamingSpeechAdapter(transport: transport)
        let chunks = try await collect(adapter.synthesize(request(), credential: "fixture-key"))
        XCTAssertEqual(chunks.last?.isFinal, true)
        XCTAssertEqual(transport.requests.count, 1)
        let recorded = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(recorded.url?.scheme, "wss")
        XCTAssertEqual(recorded.url?.host, "api.deepseek.com")
        XCTAssertEqual(recorded.url?.path, "/v1/tools/tts")
        XCTAssertEqual(recorded.url?.query, "voice_id=stella&format=pcm")
        XCTAssertEqual(recorded.authorization, "Bearer fixture-key")
        XCTAssertEqual(recorded.timeout, 30)
        XCTAssertEqual(socket.closeCount, 1)
        XCTAssertEqual(socket.cancelCount, 0)
    }

    func testAdapterSendsIncrementalChunksEqualToTextThenFinishText() async throws {
        let socket = FakeDeepSeekSocket(steps: [
            .message(.data(Data([1, 2]))),
            .message(finishSuccess()),
        ])
        let adapter = DeepSeekStreamingSpeechAdapter(
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        let text = String(repeating: "句子测试。", count: 8)   // 40 chars, several events
        _ = try await collect(adapter.synthesize(request(text: text), credential: "fixture-key"))
        let events = eventNames(socket)
        XCTAssertEqual(events.last, "finish_text")
        XCTAssertEqual(events.dropLast().allSatisfy { $0 == "text" }, true)
        XCTAssertGreaterThan(events.count, 2)   // genuinely incremental
        XCTAssertEqual(textEvents(socket).joined(), text)
    }

    func testAdapterSmallAudioFramesForwardInOrderWithOneFinal() async throws {
        let socket = FakeDeepSeekSocket(steps: [
            .message(.data(Data([1, 2, 3, 4]))),
            .message(.data(Data([5, 6]))),
            .message(finishSuccess()),
        ])
        let adapter = DeepSeekStreamingSpeechAdapter(
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        let chunks = try await collect(adapter.synthesize(request(), credential: "fixture-key"))
        XCTAssertEqual(chunks.map(\.pcm), [Data([1, 2, 3, 4]), Data([5, 6]), Data()])
        XCTAssertEqual(chunks.map(\.sequence), [0, 1, 2])
        XCTAssertEqual(chunks.map(\.sampleRate), [24_000, 24_000, 24_000])
        XCTAssertEqual(chunks.map(\.sessionID), [sessionID, sessionID, sessionID])
        XCTAssertEqual(chunks.map(\.isFinal), [false, false, true])
    }

    func testAdapterCancelMidStreamTerminatesAndCancelsSocket() async throws {
        let socket = FakeDeepSeekSocket(steps: [
            .message(.data(Data([1, 2]))),
            .park,
        ])
        let adapter = DeepSeekStreamingSpeechAdapter(
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        let stream = adapter.synthesize(request(), credential: "fixture-key")
        let consumer = Task { try await collect(stream) }
        try await Task.sleep(for: .milliseconds(200))
        consumer.cancel()
        do {
            _ = try await consumer.value
            XCTFail("cancelled synthesis succeeded")
        } catch let error as TTSSynthesisError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertGreaterThanOrEqual(socket.cancelCount, 1)
        XCTAssertEqual(socket.closeCount, 0)
    }

    func testAdapterFinishErrorCodesMapToFixedRedactedErrors() async throws {
        for (code, expected) in [
            (#"{"event":"finish","code":"content_filter","message":"risky body text"}"#, TTSSynthesisError.providerRejected(provider: .deepSeek, code: nil, logID: nil)),
            (#"{"event":"finish","code":"input_timeout","message":"slow"}"#, .transport(provider: .deepSeek, failure: .timedOut)),
        ] as [(String, TTSSynthesisError)] {
            let socket = FakeDeepSeekSocket(steps: [
                .message(.data(Data([1, 2]))),
                .message(.text(code)),
            ])
            let adapter = DeepSeekStreamingSpeechAdapter(
                transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
            do {
                _ = try await collect(adapter.synthesize(request(), credential: "fixture-key"))
                XCTFail("expected failure for \(code)")
            } catch let error as TTSSynthesisError {
                XCTAssertEqual(error, expected)
            }
            XCTAssertEqual(socket.cancelCount, 1)
        }
    }

    func testAdapterDisconnectKeepsReceivedFramesAndFails() async throws {
        let socket = FakeDeepSeekSocket(steps: [
            .message(.data(Data([1, 2, 3, 4]))),
            .fail(URLError(.networkConnectionLost)),
        ])
        let adapter = DeepSeekStreamingSpeechAdapter(
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        var received: [TTSAudioChunk] = []
        do {
            for try await chunk in adapter.synthesize(request(), credential: "fixture-key") {
                received.append(chunk)
            }
            XCTFail("expected disconnect failure")
        } catch let error as TTSSynthesisError {
            XCTAssertEqual(error, .transport(provider: .deepSeek, failure: .cannotConnect))
        }
        XCTAssertEqual(received.map(\.pcm), [Data([1, 2, 3, 4])])
        XCTAssertFalse(received.contains(where: \.isFinal))
    }

    func testAdapterFinishWithoutAudioIsTruncated() async throws {
        let socket = FakeDeepSeekSocket(steps: [.message(finishSuccess())])
        let adapter = DeepSeekStreamingSpeechAdapter(
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        do {
            _ = try await collect(adapter.synthesize(request(), credential: "fixture-key"))
            XCTFail("expected truncation")
        } catch let error as TTSSynthesisError {
            XCTAssertEqual(error, .streamTruncated(provider: .deepSeek))
        }
    }

    func testAdapterOversizeAudioIsRejected() async throws {
        let socket = FakeDeepSeekSocket(steps: [
            .message(.data(Data(repeating: 0, count: TTSSpeechLimits.maxSegmentAudioBytes + 1))),
            .message(finishSuccess()),
        ])
        let adapter = DeepSeekStreamingSpeechAdapter(
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        do {
            _ = try await collect(adapter.synthesize(request(), credential: "fixture-key"))
            XCTFail("expected oversize rejection")
        } catch let error as TTSSynthesisError {
            XCTAssertEqual(error, .streamTruncated(provider: .deepSeek))
        }
    }

    func testAdapterInvalidConfigurationSendsNothing() async throws {
        let transport = FakeDeepSeekTransport(steps: [])
        let adapter = DeepSeekStreamingSpeechAdapter(transport: transport)
        let badRequests = [
            request(provider: .openAI),                       // wrong provider
            request(voice: "unknown"),                        // unsupported voice
            request(text: " "),                               // blank text
            request(text: String(repeating: "字", count: 5_001)),  // 10,002 billing chars
        ]
        for bad in badRequests {
            do {
                _ = try await collect(adapter.synthesize(bad, credential: "fixture-key"))
                XCTFail("expected invalid-configuration failure for \(bad)")
            } catch let error as TTSSynthesisError {
                guard case .invalidConfiguration = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testAdapterEmptyCredentialSendsNothing() async throws {
        let transport = FakeDeepSeekTransport(steps: [])
        let adapter = DeepSeekStreamingSpeechAdapter(transport: transport)
        do {
            _ = try await collect(adapter.synthesize(request(), credential: "  "))
            XCTFail("expected credential failure")
        } catch let error as TTSSynthesisError {
            XCTAssertEqual(error, .credentialMissing(provider: .deepSeek, route: .payAsYouGo))
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testAdapterIgnoresUnknownTextEventsAndDropsFramesAfterFinish() async throws {
        let socket = FakeDeepSeekSocket(steps: [
            .message(.text(#"{"event":"progress","value":1}"#)),
            .message(.text("not json")),
            .message(.data(Data([1, 2]))),
            .message(finishSuccess()),
            .message(.data(Data([9, 9]))),
        ])
        let adapter = DeepSeekStreamingSpeechAdapter(
            transport: FakeDeepSeekTransport(steps: [.socket(socket)]))
        let chunks = try await collect(adapter.synthesize(request(), credential: "fixture-key"))
        XCTAssertEqual(chunks.map(\.pcm), [Data([1, 2]), Data()])
        XCTAssertEqual(chunks.last?.isFinal, true)
    }

    // MARK: - Wire helpers

    func testTextChunksAreConcatenationExactAndBounded() {
        let cases = [
            "你好，世界。",
            "Hello, world. This is Floe speaking.",
            String(repeating: "无标点中文字符串", count: 12),   // no natural boundary
            "a",
            " ",
        ]
        for text in cases {
            let chunks = DeepSeekStreamingWire.textChunks(text)
            XCTAssertEqual(chunks.joined(), text, "concatenation must be exact")
            XCTAssertFalse(chunks.contains(where: { $0.isEmpty }))
            XCTAssertFalse(chunks.contains(where: { $0.count > 48 }))
        }
        // Multi-chunk only when needed; punctuation is preferred.
        let short = DeepSeekStreamingWire.textChunks("你好，世界。")
        XCTAssertEqual(short, ["你好，世界。"])
    }

    func testFinishEventOutcomeParsing() {
        func assertSuccess(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
            guard case .success = DeepSeekStreamingWire.finishEventOutcome(text) else {
                return XCTFail("expected success for \(text)", file: file, line: line)
            }
        }
        func assertFailure(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
            guard case .failure = DeepSeekStreamingWire.finishEventOutcome(text) else {
                return XCTFail("expected failure for \(text)", file: file, line: line)
            }
        }
        func assertNotFinish(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
            guard case .notFinish = DeepSeekStreamingWire.finishEventOutcome(text) else {
                return XCTFail("expected not-finish for \(text)", file: file, line: line)
            }
        }
        assertSuccess(#"{"event":"finish","code":"success","message":"x"}"#)
        assertFailure(#"{"event":"finish","code":"content_filter","message":"x"}"#)
        assertFailure(#"{"event":"finish","code":"input_timeout","message":"x"}"#)
        assertNotFinish(#"{"event":"text","text":"hi"}"#)
        assertNotFinish("garbage")
    }
}
