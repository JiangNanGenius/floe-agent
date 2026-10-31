// Focused host-test support: deterministic fake HTTP/WebSocket transports and
// provider fixtures. No network, credential, paid account or device action.

import Foundation
import Testing
import FloeCore
@testable import FloeProviders

struct TestTimeout: Error, Sendable {}

final class LockedBox<Value>: @unchecked Sendable {
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

    func write(_ newValue: Value) {
        withLock { $0 = newValue }
    }
}

// MARK: - HTTP fake

final class RecordingHTTPTransport: ASRHTTPTransport, @unchecked Sendable {
    struct Recorded {
        let request: URLRequest
        let body: Data
    }

    private let response: ASRHTTPResponse
    private let records = LockedBox<[Recorded]>([])
    var failure: Error?

    init(response: ASRHTTPResponse) {
        self.response = response
    }

    func perform(_ request: URLRequest, body: Data) async throws -> ASRHTTPResponse {
        records.withLock { $0.append(Recorded(request: request, body: body)) }
        if let failure { throw failure }
        return response
    }

    var recorded: [Recorded] { records.read() }
}

// MARK: - WebSocket fake

final class FakeWebSocketInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [ASRWebSocketMessage] = []
    private var waiter: CheckedContinuation<ASRWebSocketMessage, Error>?
    private var terminalError: Error?
    private var closed = false

    func push(_ message: ASRWebSocketMessage) {
        var pending: CheckedContinuation<ASRWebSocketMessage, Error>?
        var shouldResume = false
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            pending = waiter
            shouldResume = true
        } else {
            messages.append(message)
        }
        lock.unlock()
        if shouldResume {
            pending?.resume(returning: message)
        }
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

final class FakeWebSocketConnection: ASRWebSocketConnection, @unchecked Sendable {
    let inbox = FakeWebSocketInbox()
    let sent = LockedBox<[ASRWebSocketMessage]>([])
    let closeCount = LockedBox(0)
    let cancelCount = LockedBox(0)
    let finalPacketSeen = LockedBox(false)
    var onSend: (@Sendable (ASRWebSocketMessage) -> Void)?

    func send(_ message: ASRWebSocketMessage) async throws {
        if cancelCount.read() > 0 || closeCount.read() > 0 {
            throw CancellationError()
        }
        let bounded = sent.withLock { messages -> Bool in
            guard messages.count < 4096 else { return false }
            messages.append(message)
            return true
        }
        guard bounded else { throw TestTimeout() }
        onSend?(message)
    }

    func receive() async throws -> ASRWebSocketMessage {
        try await inbox.next()
    }

    func close() {
        closeCount.withLock { $0 += 1 }
        inbox.close()
    }

    func cancel() {
        cancelCount.withLock { $0 += 1 }
        inbox.close()
    }

    var lastSent: ASRWebSocketMessage? {
        sent.read().last
    }

    func waitForFinalPacket(timeout: Double = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if finalPacketSeen.read() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return finalPacketSeen.read()
    }
}

final class FakeWebSocketTransport: ASRWebSocketTransport, @unchecked Sendable {
    let connection: FakeWebSocketConnection
    private let requests = LockedBox<[URLRequest]>([])

    init(connection: FakeWebSocketConnection) {
        self.connection = connection
    }

    func connect(_ request: URLRequest) async throws -> any ASRWebSocketConnection {
        requests.withLock { $0.append(request) }
        return connection
    }

    var connectCount: Int { requests.read().count }
    var lastRequest: URLRequest? { requests.read().last }
}

// MARK: - Event collection with a bounded test timeout

func collectEvents(
    _ session: any ASRLiveSession,
    count: Int,
    timeout: Double = 3
) async throws -> [ASRLiveEvent] {
    try await withThrowingTaskGroup(of: [ASRLiveEvent].self) { group in
        group.addTask {
            var iterator = session.events.makeAsyncIterator()
            var events: [ASRLiveEvent] = []
            while events.count < count {
                guard let event = try await iterator.next() else { break }
                events.append(event)
            }
            return events
        }
        group.addTask {
            try await Task.sleep(
                nanoseconds: UInt64(max(0.05, timeout) * 1_000_000_000))
            throw TestTimeout()
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

func eventFailure(
    _ session: any ASRLiveSession,
    timeout: Double = 3
) async -> Error? {
    do {
        _ = try await collectEvents(session, count: 1, timeout: timeout)
        return nil
    } catch {
        return error
    }
}

// MARK: - Fixtures

extension Data {
    mutating func appendASCII(_ value: String) {
        append(Data(value.utf8))
    }

    mutating func appendLE16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}

func makeWAV(
    sampleRate: Int = 16_000,
    channels: UInt16 = 1,
    bits: UInt16 = 16,
    payload: Data = Data(count: 3_200)
) -> Data {
    let blockAlign = channels * bits / 8
    let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
    var data = Data()
    data.appendASCII("RIFF")
    data.appendLE32(UInt32(36 + payload.count))
    data.appendASCII("WAVE")
    data.appendASCII("fmt ")
    data.appendLE32(16)
    data.appendLE16(1) // PCM
    data.appendLE16(channels)
    data.appendLE32(UInt32(sampleRate))
    data.appendLE32(byteRate)
    data.appendLE16(blockAlign)
    data.appendLE16(bits)
    data.appendASCII("data")
    data.appendLE32(UInt32(payload.count))
    data.append(payload)
    return data
}

func makeMP3(frames: Int = 2) -> Data {
    // MPEG1 Layer III, 128 kbps, 44.1 kHz, no padding -> 417-byte frames.
    var data = Data()
    for _ in 0..<frames {
        data.append(contentsOf: [0xff, 0xfb, 0x90, 0x64])
        data.append(Data(count: 413))
    }
    return data
}

func makeOGG() -> Data {
    var data = Data()
    data.appendASCII("OggS")
    data.append(contentsOf: [0, 0])
    var granule: UInt64 = 48_000 // 1 second of Opus
    withUnsafeBytes(of: &granule) { data.append(contentsOf: $0) }
    data.append(contentsOf: [0, 0, 0, 0]) // serial
    data.append(contentsOf: [0, 0, 0, 0]) // page sequence
    data.append(contentsOf: [0, 0, 0, 0]) // checksum
    data.append(contentsOf: [0, 0]) // page segments
    data.appendASCII("OpusHead")
    data.append(contentsOf: [1, 1]) // version, channels
    data.append(contentsOf: [0, 0]) // pre-skip
    var rate: UInt32 = 16_000
    withUnsafeBytes(of: &rate) { data.append(contentsOf: $0) }
    data.append(contentsOf: [0, 0, 0]) // gain + mapping family
    return data
}

func jsonData(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func volcServerFrame(
    _ object: [String: Any],
    isFinal: Bool,
    sequence: Int?
) throws -> Data {
    try VolcengineASRFrame.serverJSON(
        try jsonData(object), isFinal: isFinal, sequence: sequence)
}

func volcErrorFrame(_ code: Int) -> Data {
    VolcengineASRFrame.serverError(code: code, json: Data("{}".utf8))
}

func aliEvent(
    _ event: String,
    taskID: String = "task",
    payload: [String: Any] = [:]
) throws -> ASRWebSocketMessage {
    let root: [String: Any] = [
        "header": ["event": event, "task_id": taskID],
        "payload": payload,
    ]
    let data = try jsonData(root)
    return .text(String(decoding: data, as: UTF8.self))
}

func aliResult(
    text: String,
    sentenceEnd: Bool = true,
    sentenceID: Int = 1,
    begin: Double = 170,
    end: Double? = 920,
    heartbeat: Bool = false
) throws -> ASRWebSocketMessage {
    var sentence: [String: Any] = [
        "sentence_id": sentenceID,
        "sentence_end": sentenceEnd,
        "begin_time": begin,
        "text": text,
        "heartbeat": heartbeat,
    ]
    if let end { sentence["end_time"] = end }
    return try aliEvent(
        "result-generated",
        payload: ["output": ["sentence": sentence]])
}

func aliStarted() throws -> ASRWebSocketMessage {
    try aliEvent("task-started")
}

func aliFinished() throws -> ASRWebSocketMessage {
    try aliEvent("task-finished")
}

func aliFailed(message: String = "provider detail that must not leak")
    throws -> ASRWebSocketMessage {
    let root: [String: Any] = [
        "header": [
            "event": "task-failed",
            "task_id": "task",
            "error_message": message,
        ],
        "payload": [:],
    ]
    return .text(String(decoding: try jsonData(root), as: UTF8.self))
}

func beUInt32(_ data: Data, at offset: Int) -> UInt32 {
    let bytes = [UInt8](data)
    return (UInt32(bytes[offset]) << 24)
        | (UInt32(bytes[offset + 1]) << 16)
        | (UInt32(bytes[offset + 2]) << 8)
        | UInt32(bytes[offset + 3])
}

func headerValue(_ request: URLRequest, _ name: String) -> String? {
    request.value(forHTTPHeaderField: name)
}
