// FloeProvidersTests — QA SSE parser edge corpus (Round 1, QA/Yan).
// Boundaries beyond the engineer's fragmentation corpus: empty input,
// comment-only streams, EOF without newline, empty event values, non-numeric
// retry, one-byte-at-a-time extreme fragmentation, mixed CR/LF endings,
// mid-stream invalid UTF-8 replacement, NUL-containing ids.

import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeProviders

@Suite("QA.SSEParserEdges")
struct SSEParserEdgeTests {

    @Test("Empty input yields no events and finishes cleanly")
    func emptyInput() throws {
        var parser = SSEParser()
        let events = try parser.finish()
        #expect(events.isEmpty)
    }

    @Test("Comment-only stream yields no events")
    func commentOnly() throws {
        var parser = SSEParser()
        var events = parser.feed(Array(": heartbeat\n: another\n".utf8))
        events += try parser.finish()
        #expect(events.isEmpty)
    }

    @Test("data: with no trailing newline flushes at EOF")
    func dataWithoutTrailingNewline() throws {
        var parser = SSEParser()
        _ = parser.feed(Array("data: hello".utf8))
        let events = try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == "hello")
    }

    @Test("data: immediately at EOF with empty value emits empty-data event")
    func emptyDataAtEOF() throws {
        var parser = SSEParser()
        _ = parser.feed(Array("data:".utf8))
        let events = try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == "")
    }

    @Test("event: with empty value keeps the default message type")
    func emptyEventValue() throws {
        var parser = SSEParser()
        var events = parser.feed(Array("event:\ndata: x\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].event == "")
    }

    @Test("retry: with a non-numeric value is ignored")
    func nonNumericRetry() throws {
        var parser = SSEParser()
        var events = parser.feed(Array("retry: abc\ndata: x\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].retry == nil)
    }

    @Test("retry: with a negative value is ignored per spec")
    func negativeRetry() throws {
        var parser = SSEParser()
        var events = parser.feed(Array("retry: -5\ndata: x\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].retry == nil)
    }

    @Test("retry: with leading zeros parses as decimal")
    func leadingZeroRetry() throws {
        var parser = SSEParser()
        var events = parser.feed(Array("retry: 007\ndata: x\n\n".utf8))
        events += try parser.finish()
        #expect(events[0].retry == 7)
    }

    @Test("One-byte-at-a-time feed of a multi-line event equals whole-buffer parse")
    func byteByByteEquivalence() throws {
        let stream = "event: named\nid: 9\nretry: 250\ndata: part1\ndata: part2\n\n"
        var whole = SSEParser()
        var wholeEvents = whole.feed(Array(stream.utf8))
        wholeEvents += try whole.finish()

        var drip = SSEParser()
        var dripEvents: [SSEEvent] = []
        for byte in stream.utf8 {
            dripEvents += drip.feed(CollectionOfOne(byte))
        }
        dripEvents += try drip.finish()

        #expect(dripEvents == wholeEvents)
        #expect(dripEvents.count == 1)
        #expect(dripEvents[0].data == "part1\npart2")
        #expect(dripEvents[0].event == "named")
        #expect(dripEvents[0].id == "9")
        #expect(dripEvents[0].retry == 250)
    }

    @Test("Mixed CR / LF / CRLF / CRCRLF endings all terminate lines")
    func mixedLineEndings() throws {
        // "data: a\r\n" + "\r\n" → event a; "data: b\r" + "\r\n"? No:
        // construct explicitly: a (CRLF), blank (LF), b (CR), blank (CRLF).
        var parser = SSEParser()
        var events = parser.feed(Array("data: a\r\n\ndata: b\r\r\ndata: c\n\n".utf8))
        events += try parser.finish()
        #expect(events.map(\.data) == ["a", "b", "c"])
    }

    @Test("\\r\\r\\n sequence: first CR ends line, CRCR emits blank, LF swallowed")
    func crcrlfSequence() throws {
        var parser = SSEParser()
        // "data: x\r" → line; "\r" → blank line (event dispatched);
        // "\n" → swallowed as the LF half of CRLF.
        var events = parser.feed(Array("data: x\r\r\ndata: y\r\r\n".utf8))
        events += try parser.finish()
        #expect(events.map(\.data) == ["x", "y"])
    }

    @Test("Mid-stream invalid UTF-8 bytes are replaced with U+FFFD, not fatal")
    func midStreamInvalidUTF8() throws {
        var parser = SSEParser()
        var bytes = Array("data: caf".utf8)
        bytes.append(0xE9) // lone continuation-less byte → invalid UTF-8
        bytes.append(contentsOf: Array("\n\n".utf8))
        var events = parser.feed(bytes)
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == "caf\u{FFFD}")
    }

    @Test("id: containing NUL is ignored per spec")
    func nulInIDIgnored() throws {
        var parser = SSEParser()
        var events = parser.feed(Array("id: a\u{0}b\ndata: x\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].id == nil)
    }

    @Test("Line containing only a colon is a comment (ignored)")
    func loneColonLine() throws {
        var parser = SSEParser()
        var events = parser.feed(Array(":\ndata: x\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == "x")
    }

    @Test("BOM mid-stream is treated as content, merging into the data payload")
    func midStreamBOMIsContent() throws {
        var parser = SSEParser()
        // The BOM (EF BB BF) lands before "data: y", so the line becomes
        // "\u{FEFF}data: y" whose field name is not "data" — but it IS
        // appended to the pending data of the previous event? No: unknown
        // fields are ignored. Observe actual behavior and pin it.
        var events = parser.feed(Array("data: x\n\n\u{FEFF}data: y\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == "x")
    }

    @Test("Incomplete BOM prefix bytes are treated as content at finish()")
    func incompleteBOMPrefix() throws {
        var parser = SSEParser()
        _ = parser.feed([0xEF]) // first BOM byte only
        let events = try parser.finish()
        // A lone 0xEF is invalid UTF-8 as a final line; the parser replays it
        // as content, which is not valid UTF-8 → replacement char, no throw
        // (only .inLine truncated tails throw; bomPending replays as content).
        #expect(events.isEmpty)
    }

    @Test("Very long single line (1 MiB) parses without truncation")
    func longLine() throws {
        let payload = String(repeating: "x", count: 1_048_576)
        var parser = SSEParser()
        var events = parser.feed(Array("data: \(payload)\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data.count == 1_048_576)
    }
}


#if !os(Linux)
// Actual URLSession.bytes(for:) + production Chat decoder, no server/account.
// A held HTTP body intentionally never sends EOF. Only the response owner
// can make the DONE cases return, by stopping and joining its real reader.
private final class FU13HTTPScenario: @unchecked Sendable {
    let frames: [Data]
    let finishesHTTP: Bool
    private let lock = NSLock()
    private var stopped = false
    init(frames: [Data], finishesHTTP: Bool) { self.frames = frames; self.finishesHTTP = finishesHTTP }
    func markStopped() { lock.withLock { stopped = true } }
    var didStop: Bool { lock.withLock { stopped } }
}

private final class FU13HTTPScenarios: @unchecked Sendable {
    static let shared = FU13HTTPScenarios()
    private let lock = NSLock()
    private var values: [String: FU13HTTPScenario] = [:]
    func install(_ value: FU13HTTPScenario, id: String) { lock.withLock { values[id] = value } }
    func value(id: String) -> FU13HTTPScenario? { lock.withLock { values[id] } }
    func remove(id: String) { _ = lock.withLock { values.removeValue(forKey: id) } }
}

private final class FU13HTTPProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var scenario: FU13HTTPScenario?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stream-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let id = url.pathComponents.dropFirst().first,
              let fixture = FU13HTTPScenarios.shared.value(id: id),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        lock.withLock { scenario = fixture }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for frame in fixture.frames { client?.urlProtocol(self, didLoad: frame) }
        if fixture.finishesHTTP { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { lock.withLock { scenario }?.markStopped() }
}

private actor FU13StreamReceipt {
    var events: [AgentEvent] = []
    var ended = false
    var error: String?
    func append(_ event: AgentEvent) { events.append(event) }
    func finish(error: String? = nil) { self.error = error; ended = true }
}

@Suite("Chat SSE actual HTTP termination")
struct ChatSSECompletionTests {
    private struct Result: Sendable {
        let events: [AgentEvent]
        let endedBeforeCleanup: Bool
        let stoppedBeforeCleanup: Bool
        let error: String?
    }
    private func frame(delta: [String: Any] = [:], finish: String? = nil, usage: [String: Any]? = nil) throws -> Data {
        var value: [String: Any] = ["id": "fixture", "choices": [["index": 0, "delta": delta]]]
        if let finish { value["choices"] = [["index": 0, "delta": delta, "finish_reason": finish]] }
        if let usage { value["choices"] = []; value["usage"] = usage }
        return Data("data: \(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))\n\n".utf8)
    }
    private var done: Data { Data("data: [DONE]\n\n".utf8) }

    private func completions(_ events: [AgentEvent]) -> [AgentEvent.StopReason] {
        events.compactMap { event -> AgentEvent.StopReason? in
            guard case .completed(let value) = event else { return nil }
            return value.stopReason
        }
    }
    private func text(_ events: [AgentEvent], reasoning: Bool = false) -> String {
        events.compactMap { event -> String? in
            switch event {
            case .reasoningSummary(let value) where reasoning: return value.text
            case .textDelta(let value) where !reasoning: return value.text
            default: return nil
            }
        }.joined()
    }
    private func outputs(_ events: [AgentEvent]) -> [Int] {
        events.compactMap { event -> Int? in
            guard case .usage(let value) = event else { return nil }
            return value.outputTokens
        }
    }
    private func calls(_ events: [AgentEvent]) -> [String] {
        events.compactMap { event -> String? in
            guard case .toolRequest(let value) = event else { return nil }
            return value.id
        }
    }

    private func collect(_ frames: [Data], finishesHTTP: Bool) async throws -> Result {
        let id = UUID().uuidString
        let fixture = FU13HTTPScenario(frames: frames, finishesHTTP: finishesHTTP)
        FU13HTTPScenarios.shared.install(fixture, id: id)
        defer { FU13HTTPScenarios.shared.remove(id: id) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FU13HTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        let provider = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
            baseURL: try #require(URL(string: "https://stream-fixture.invalid/\(id)/v1")))
        let model = ModelProfile(providerID: provider.id, remoteModelID: "fixture", displayName: "Fixture",
            limits: .init(contextTokens: 4096, maxOutputTokens: 1024), capabilities: [.text, .tools])
        let request = ProviderStreamRequest(provider: provider, model: model, messages: [("user", "Fixture")])
        let receipt = FU13StreamReceipt()
        let consumer = Task {
            do {
                let values = OpenAIChatCompletionsAdapter().stream(request: request, credentials: .init(apiKey: "fixture-only"), session: session)
                for try await event in values { await receipt.append(event) }
                await receipt.finish()
            } catch { await receipt.finish(error: error.localizedDescription) }
        }
        // Bounded fixture wait only. This does not change any production timeout.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await receipt.ended), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let result = Result(events: await receipt.events, endedBeforeCleanup: await receipt.ended,
                            stoppedBeforeCleanup: fixture.didStop, error: await receipt.error)
        consumer.cancel()
        session.invalidateAndCancel()
        await consumer.value
        return result
    }

    @Test("DONE preserves prior usage and ends/joins a response that never sends HTTP EOF")
    func doneEndsOwnedReaderWithoutEOF() async throws {
        let result = try await collect([
            frame(delta: ["reasoning_content": "Thinking"]), frame(delta: ["content": "Answer"]),
            frame(finish: "stop"), frame(usage: ["prompt_tokens": 4, "completion_tokens": 2, "total_tokens": 6]), done,
            frame(delta: ["content": "MUST NOT ARRIVE AFTER DONE"])
        ], finishesHTTP: false)
        #expect(result.endedBeforeCleanup, "Production adapter must stop at DONE, not wait for HTTP EOF/watchdog")
        #expect(result.stoppedBeforeCleanup, "Owned URLSession reader must actually be cancelled before completion returns")
        #expect(result.error == nil)
        #expect(completions(result.events) == [.endTurn])
        #expect(text(result.events) == "Answer")
        #expect(outputs(result.events) == [2])
    }

    @Test("Long reasoning followed by length/DONE is retained and reports maxTokens exactly once")
    func reasoningLengthEndsWithoutPretendingFinalText() async throws {
        let reasoning = String(repeating: "推理", count: 16_384)
        let result = try await collect([frame(delta: ["reasoning_content": reasoning]), frame(finish: "length"), done], finishesHTTP: false)
        #expect(result.endedBeforeCleanup && result.stoppedBeforeCleanup)
        #expect(text(result.events, reasoning: true) == reasoning)
        #expect(completions(result.events) == [.maxTokens])
        #expect(!result.events.contains { if case .textDelta = $0 { true } else { false } })
    }

    @Test("Unexpected EOF and partial tool DONE cannot manufacture completion or a callable tool")
    func incompleteStreamsHaveNoFalseCompletion() async throws {
        let eof = try await collect([frame(delta: ["content": "Partial"] )], finishesHTTP: true)
        #expect(eof.endedBeforeCleanup)
        #expect(!eof.events.contains { if case .completed = $0 { true } else { false } })
        let partial = try await collect([frame(delta: ["tool_calls": [["index": 0, "id": "partial", "type": "function", "function": ["name": "exec.shell", "arguments": "{"]]]]), done], finishesHTTP: false)
        #expect(partial.endedBeforeCleanup && partial.stoppedBeforeCleanup)
        #expect(!partial.events.contains { if case .completed = $0 { true } else { false } })
        #expect(!partial.events.contains { if case .toolRequest = $0 { true } else { false } })
        #expect(partial.events.contains { if case .error(let value) = $0 { value.kind == .malformedToolArguments } else { false } })
    }

    @Test("Complete tool call plus DONE emits one request and one completion without reading later calls")
    func completeToolRemainsSingleAcrossDoneBoundary() async throws {
        let complete: [String: Any] = ["tool_calls": [["index": 0, "id": "one", "type": "function", "function": ["name": "exec.shell", "arguments": "{}"]]]]
        let result = try await collect([frame(delta: complete), frame(finish: "tool_calls"), done, frame(delta: complete), frame(finish: "tool_calls")], finishesHTTP: false)
        #expect(result.endedBeforeCleanup && result.stoppedBeforeCleanup)
        #expect(calls(result.events) == ["one"])
        #expect(completions(result.events) == [.toolUse])
    }
}
#endif
