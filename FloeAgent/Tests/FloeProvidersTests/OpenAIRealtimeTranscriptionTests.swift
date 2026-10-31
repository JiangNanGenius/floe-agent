// Focused qualification tests — OpenAI Realtime transcription.
//
// A fake WebSocket transport implements the shared FloeCore protocol, so the
// test verifies the real session.update/append/commit frames, real item-id
// reconciliation, event ordering, bounded backpressure, final drain and
// cancellation with no provider call or network. It also verifies the
// endpoint/credential policy before any transport connection.

import Foundation
import Testing
import FloeCore
@testable import FloeProviders

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    func read() -> Value {
        withLock { $0 }
    }
}

private final class FakeASRInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [ASRWebSocketMessage] = []
    private var waiter: CheckedContinuation<ASRWebSocketMessage, Error>?
    private var terminalError: Error?
    private var closed = false

    func push(_ message: ASRWebSocketMessage) {
        var pending: CheckedContinuation<ASRWebSocketMessage, Error>?
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            pending = waiter
        } else {
            messages.append(message)
        }
        lock.unlock()
        pending?.resume(returning: message)
    }

    func fail(_ error: Error) {
        var pending: CheckedContinuation<ASRWebSocketMessage, Error>?
        lock.lock()
        terminalError = error
        closed = true
        pending = waiter
        waiter = nil
        messages.removeAll()
        lock.unlock()
        pending?.resume(throwing: error)
    }

    func close() {
        var pending: CheckedContinuation<ASRWebSocketMessage, Error>?
        lock.lock()
        closed = true
        pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }

    func next() async throws -> ASRWebSocketMessage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ASRWebSocketMessage, Error>) in
                var immediate: Result<ASRWebSocketMessage, Error>?
                lock.lock()
                if !messages.isEmpty {
                    immediate = .success(messages.removeFirst())
                } else if let terminalError {
                    immediate = .failure(terminalError)
                } else if closed {
                    immediate = .failure(CancellationError())
                } else {
                    waiter = continuation
                }
                lock.unlock()
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            self.close()
        }
    }
}

private final class FakeASRConnection: ASRWebSocketConnection, @unchecked Sendable {
    private let inbox = FakeASRInbox()
    private let sent = LockedBox<[ASRWebSocketMessage]>([])
    private let closed = LockedBox(false)
    var sendFailure: Error?

    func send(_ message: ASRWebSocketMessage) async throws {
        if closed.read() { throw CancellationError() }
        if let sendFailure { throw sendFailure }
        sent.withLock { $0.append(message) }
    }

    func receive() async throws -> ASRWebSocketMessage {
        try await inbox.next()
    }

    func close() {
        closed.withLock { $0 = true }
        inbox.close()
    }

    func cancel() {
        closed.withLock { $0 = true }
        inbox.close()
    }

    func push(_ message: ASRWebSocketMessage) {
        inbox.push(message)
    }

    func pushJSON(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        inbox.push(.text(String(decoding: data, as: UTF8.self)))
    }

    func pushText(_ text: String) {
        inbox.push(.text(text))
    }

    func snapshotSent() -> [ASRWebSocketMessage] {
        sent.read()
    }

    func isClosed() -> Bool {
        closed.read()
    }
}

private final class FakeASRTransport: ASRWebSocketTransport, @unchecked Sendable {
    let connection: FakeASRConnection
    let requests = LockedBox<[URLRequest]>([])
    var connectionFailure: Error?

    init(connection: FakeASRConnection = FakeASRConnection()) {
        self.connection = connection
    }

    func connect(_ request: URLRequest) async throws -> any ASRWebSocketConnection {
        requests.withLock { $0.append(request) }
        if let connectionFailure { throw connectionFailure }
        return connection
    }
}

@Suite("OpenAI realtime transcription", .serialized)
struct OpenAIRealtimeTranscriptionTests {
    private func makeProfile(
        liveEndpoint: String? = "https://relay.example/openai/v1",
        liveModel: String = "gpt-live-transcribe"
    ) -> ASRProfile {
        ASRProfile.openAICompatible(
            liveModelID: liveModel,
            liveEndpoint: liveEndpoint,
            languages: ["en"],
            prompt: "Support call",
            keywords: ["AC-42"])
    }

    private func makeSession(
        adapter: OpenAIRealtimeTranscriptionAdapter,
        profile: ASRProfile,
        turnID: UUID = UUID(),
        maximumAudioBytes: Int = 64 * 1024 * 1024,
        maximumEventBytes: Int = 1 * 1024 * 1024,
        eventQueueCapacity: Int = 256
    ) async throws -> any ASRLiveSession {
        try await adapter.startLiveSession(
            ASRLiveSessionRequest(
                profile: profile,
                turnID: turnID,
                maximumAudioBytes: maximumAudioBytes,
                maximumEventBytes: maximumEventBytes,
                eventQueueCapacity: eventQueueCapacity),
            credential: "sk-test-secret")
    }

    private func sentJSON(_ connection: FakeASRConnection) throws -> [[String: Any]] {
        try connection.snapshotSent().compactMap { message in
            guard case .text(let text) = message else { return nil }
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
            return object as? [String: Any]
        }
    }

    @Test("session.update is the exact transcription contract and endpoint policy holds")
    func sessionUpdateContract() async throws {
        let connection = FakeASRConnection()
        let transport = FakeASRTransport(connection: connection)
        let adapter = OpenAIRealtimeTranscriptionAdapter(transport: transport)
        let turnID = UUID()
        let session = try await makeSession(
            adapter: adapter, profile: makeProfile(), turnID: turnID)
        #expect(session.turnID == turnID)

        let request = try #require(transport.requests.read().first)
        #expect(request.url?.absoluteString
            == "wss://relay.example/openai/v1/realtime?intent=transcription")
        #expect(request.value(forHTTPHeaderField: "Authorization")
            == "Bearer sk-test-secret")
        #expect(request.url?.query?.contains("model") != true)

        let frames = try sentJSON(connection)
        #expect(frames.count == 1)
        let update = frames[0]
        #expect(update["type"] as? String == "session.update")
        let sessionDictionary = try #require(update["session"] as? [String: Any])
        #expect(sessionDictionary["type"] as? String == "transcription")
        let audio = try #require(sessionDictionary["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        #expect(input["turn_detection"] is NSNull)
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(transcription["model"] as? String == "gpt-live-transcribe")
        #expect(transcription["prompt"] as? String == "Support call")
        #expect(transcription["keywords"] as? [String] == ["AC-42"])
        #expect(transcription["languages"] as? [String] == ["en"])
        #expect(transcription["language"] == nil)
        let frameText = try #require(connection.snapshotSent().first)
        if case .text(let text) = frameText {
            #expect(!text.contains("server_vad"))
            #expect(!text.contains("semantic_vad"))
        } else {
            Issue.record("expected a text frame")
        }
    }

    @Test("append/commit bytes and item-keyed partial/final ordering")
    func appendCommitAndEvents() async throws {
        let connection = FakeASRConnection()
        let transport = FakeASRTransport(connection: connection)
        let adapter = OpenAIRealtimeTranscriptionAdapter(transport: transport)
        let turnID = UUID()
        let session = try await makeSession(
            adapter: adapter, profile: makeProfile(), turnID: turnID)
        let audio = Data([1, 2, 3, 4])
        try await session.feed(audio)
        try await session.endUtterance()

        let sent = try sentJSON(connection)
        #expect(sent.count == 3)
        #expect(sent[1]["type"] as? String == "input_audio_buffer.append")
        #expect(sent[1]["audio"] as? String == audio.base64EncodedString())
        #expect(sent[2]["type"] as? String == "input_audio_buffer.commit")

        try connection.pushJSON([
            "type": "input_audio_buffer.committed",
            "item_id": "item_003",
            "previous_item_id": NSNull(),
        ])
        // A late/foreign item event is ignored rather than misattributed.
        try connection.pushJSON([
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "item_other",
            "content_index": 0,
            "delta": "WRONG",
        ])
        try connection.pushJSON([
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "item_003",
            "content_index": 0,
            "delta": "Hel",
        ])
        try connection.pushJSON([
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "item_003",
            "content_index": 0,
            "delta": "lo",
        ])
        // Finish must wait for the final event to be enqueued, then return.
        try connection.pushJSON([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "item_003",
            "content_index": 0,
            "transcript": "Hello",
        ])
        try await session.finish()

        var iterator = session.events.makeAsyncIterator()
        let first = try #require(try await iterator.next())
        #expect(first.kind == .partial)
        #expect(first.text == "Hel")
        #expect(first.itemID == "item_003")
        #expect(first.turnID == turnID)
        let second = try #require(try await iterator.next())
        #expect(second.kind == .partial)
        #expect(second.text == "lo")
        #expect(second.itemID == "item_003")
        #expect(second.sequence > first.sequence)
        let final = try #require(try await iterator.next())
        #expect(final.kind == .final)
        #expect(final.text == "Hello")
        #expect(final.itemID == "item_003")
        #expect(final.turnID == turnID)
        #expect(final.sequence > second.sequence)
        #expect(try await iterator.next() == nil)
        #expect(connection.isClosed())
    }

    @Test("Cancel discards queued events and never produces a final")
    func cancelNoFinal() async throws {
        let connection = FakeASRConnection()
        let transport = FakeASRTransport(connection: connection)
        let adapter = OpenAIRealtimeTranscriptionAdapter(transport: transport)
        let session = try await makeSession(adapter: adapter, profile: makeProfile())
        try await session.feed(Data([1, 2, 3, 4]))
        try await session.endUtterance()
        try connection.pushJSON([
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "item_1",
            "delta": "late",
        ])
        await session.cancel()
        var iterator = session.events.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("expected cancellation")
        } catch is CancellationError {
            // Expected: no final and no buffered partial after cancel.
        }
        do {
            try await session.finish()
            Issue.record("expected cancellation from finish")
        } catch is CancellationError {
            // Expected.
        }
        #expect(connection.isClosed())
        let sent = try sentJSON(connection)
        #expect(sent.contains { $0["type"] as? String == "input_audio_buffer.commit" })
        #expect(sent.filter {
            $0["type"] as? String == "input_audio_buffer.append"
        }.count == 1)
    }

    @Test("Provider failure is a typed failed event and finish reports it")
    func providerFailedEvent() async throws {
        let connection = FakeASRConnection()
        let transport = FakeASRTransport(connection: connection)
        let adapter = OpenAIRealtimeTranscriptionAdapter(transport: transport)
        let turnID = UUID()
        let session = try await makeSession(
            adapter: adapter, profile: makeProfile(), turnID: turnID)
        try await session.feed(Data([1, 2]))
        try await session.endUtterance()
        try connection.pushJSON([
            "type": "input_audio_buffer.committed",
            "item_id": "item_9",
        ])
        try connection.pushJSON([
            "type": "conversation.item.input_audio_transcription.failed",
            "item_id": "item_9",
        ])
        do {
            try await session.finish()
            Issue.record("expected providerRejected")
        } catch let error as ASRTranscriptionError {
            #expect(error == .providerRejected)
        }
        var iterator = session.events.makeAsyncIterator()
        let failed = try #require(try await iterator.next())
        #expect(failed.kind == .failed)
        #expect(failed.failure == .providerRejected)
        #expect(failed.itemID == "item_9")
        #expect(failed.turnID == turnID)
        #expect(try await iterator.next() == nil)
    }

    @Test("Oversized frames fail with a bounded redacted error")
    func oversizedFrame() async throws {
        let connection = FakeASRConnection()
        let transport = FakeASRTransport(connection: connection)
        let adapter = OpenAIRealtimeTranscriptionAdapter(transport: transport)
        let session = try await makeSession(
            adapter: adapter,
            profile: makeProfile(),
            maximumEventBytes: 1_024)
        connection.pushText(String(repeating: "x", count: 2_048))
        var iterator = session.events.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("expected responseTooLarge")
        } catch let error as ASRTranscriptionError {
            #expect(error == .responseTooLarge)
        }
        do {
            try await session.finish()
            Issue.record("expected responseTooLarge from finish")
        } catch let error as ASRTranscriptionError {
            #expect(error == .responseTooLarge)
        }
    }

    @Test("Audio caps and utterance boundaries are enforced before sending")
    func audioBounds() async throws {
        let connection = FakeASRConnection()
        let transport = FakeASRTransport(connection: connection)
        let adapter = OpenAIRealtimeTranscriptionAdapter(transport: transport)
        let session = try await makeSession(
            adapter: adapter,
            profile: makeProfile(),
            maximumAudioBytes: 8)
        do {
            try await session.feed(Data(repeating: 0, count: 10))
            Issue.record("expected audio limit")
        } catch let error as ASRTranscriptionError {
            if case .invalidConfiguration = error {} else {
                Issue.record("unexpected error \(error)")
            }
        }
        do {
            try await session.feed(Data([0, 1, 2]))
            Issue.record("expected PCM16 alignment error")
        } catch let error as ASRTranscriptionError {
            if case .invalidConfiguration = error {} else {
                Issue.record("unexpected error \(error)")
            }
        }
        try await session.feed(Data([0, 1]))
        try await session.endUtterance()
        do {
            try await session.feed(Data([0, 1]))
            Issue.record("expected committed-utterance error")
        } catch let error as ASRTranscriptionError {
            if case .invalidConfiguration = error {} else {
                Issue.record("unexpected error \(error)")
            }
        }
        // No append frame was emitted for the rejected chunks; one valid
        // append plus the commit follows the session.update.
        let sent = try sentJSON(connection)
        #expect(sent.filter { $0["type"] as? String == "input_audio_buffer.append" }.count == 1)
        await session.cancel()
    }

    @Test("A slow consumer applies backpressure without losing deltas")
    func boundedBackpressureNoLoss() async throws {
        let connection = FakeASRConnection()
        let transport = FakeASRTransport(connection: connection)
        let adapter = OpenAIRealtimeTranscriptionAdapter(transport: transport)
        let session = try await makeSession(
            adapter: adapter,
            profile: makeProfile(),
            eventQueueCapacity: 8)
        try await session.feed(Data([1, 2]))
        try await session.endUtterance()
        for index in 0..<20 {
            try connection.pushJSON([
                "type": "conversation.item.input_audio_transcription.delta",
                "item_id": "item_1",
                "delta": "d\(index)",
            ])
        }
        try connection.pushJSON([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "item_1",
            "transcript": "final",
        ])
        var iterator = session.events.makeAsyncIterator()
        var seen: [String] = []
        var lastSequence = 0
        for index in 0..<20 {
            let event = try #require(try await iterator.next())
            #expect(event.kind == .partial)
            #expect(event.sequence > lastSequence)
            lastSequence = event.sequence
            seen.append(event.text)
            #expect(event.text == "d\(index)")
        }
        let final = try #require(try await iterator.next())
        #expect(final.kind == .final)
        #expect(final.text == "final")
        #expect(seen.count == 20)
        try await session.finish()
    }

    @Test("Invalid endpoint/credential/model never reaches the transport")
    func preflightIsolation() async throws {
        let connection = FakeASRConnection()
        let transport = FakeASRTransport(connection: connection)
        let adapter = OpenAIRealtimeTranscriptionAdapter(transport: transport)

        do {
            _ = try await adapter.startLiveSession(
                ASRLiveSessionRequest(profile: makeProfile(
                    liveEndpoint: "ws://relay.example/v1")),
                credential: "sk-test-secret")
            Issue.record("expected insecure endpoint rejection")
        } catch let error as ASRTranscriptionError {
            #expect(error == .invalidConfiguration("endpoint must use wss"))
        }
        #expect(transport.requests.read().isEmpty)

        do {
            _ = try await adapter.startLiveSession(
                ASRLiveSessionRequest(profile: makeProfile()),
                credential: "   ")
            Issue.record("expected missing credential")
        } catch let error as ASRTranscriptionError {
            #expect(error == .credentialMissing)
        }
        #expect(transport.requests.read().isEmpty)

        do {
            _ = try await adapter.startLiveSession(
                ASRLiveSessionRequest(profile: makeProfile(liveModel: "whisper-1")),
                credential: "sk-test-secret")
            Issue.record("expected unsupported live model")
        } catch let error as ASRTranscriptionError {
            if case .invalidConfiguration = error {} else {
                Issue.record("unexpected error \(error)")
            }
        }
        #expect(transport.requests.read().isEmpty)
    }

    @Test("Transport cancellation is CancellationError, not a typed provider failure")
    func cancellationIsNotFailure() async throws {
        let connection = FakeASRConnection()
        connection.sendFailure = URLError(.cancelled)
        let transport = FakeASRTransport(connection: connection)
        let adapter = OpenAIRealtimeTranscriptionAdapter(transport: transport)
        await #expect(throws: CancellationError.self) {
            _ = try await adapter.startLiveSession(
                ASRLiveSessionRequest(profile: makeProfile()),
                credential: "sk-test-secret")
        }
        #expect(transport.requests.read().count == 1)
        #expect(connection.isClosed())
    }

    @Test("Finish without audio refuses instead of committing an empty turn")
    func emptyFinish() async throws {
        let connection = FakeASRConnection()
        let transport = FakeASRTransport(connection: connection)
        let adapter = OpenAIRealtimeTranscriptionAdapter(transport: transport)
        let session = try await makeSession(adapter: adapter, profile: makeProfile())
        do {
            try await session.finish()
            Issue.record("expected no-audio rejection")
        } catch let error as ASRTranscriptionError {
            if case .invalidConfiguration = error {} else {
                Issue.record("unexpected error \(error)")
            }
        }
        await session.cancel()
    }

#if !canImport(FoundationNetworking)
    @Test("The native WebSocket task bounds one inbound message")
    func nativeWebSocketMessageLimit() {
        #expect(ASRTransportLimits.maximumWebSocketMessageBytes == 8 * 1024 * 1024)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: URLRequest(
            url: URL(string: "wss://relay.example/v1/realtime?intent=transcription")!))
        // Constructing the connection applies the ceiling without resuming the
        // task, so this test makes no network connection.
        _ = URLSessionWebSocketConnection(task: task)
        #expect(task.maximumMessageSize
            == ASRTransportLimits.maximumWebSocketMessageBytes)
        task.cancel(with: .goingAway, reason: nil)
    }
#endif
}
