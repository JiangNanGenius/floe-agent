// SPDX-License-Identifier: MPL-2.0
#if canImport(Darwin)
import XCTest
import Foundation
import FloeCore
import FloeTransport
@testable import FloeProviders
@testable import FloeTools

/// Deterministic test gate: only `set()` after the scripted server has
/// written its FINAL byte and closed. Observing `value == false` at an
/// event's arrival is a structural proof the client saw that event BEFORE
/// end-of-response — no clock-margin flakiness.
final class CloseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    func set() { lock.lock(); closed = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}

/// G02-P3 host behavioural suite for the REAL incremental seam. These tests
/// run the exact functions the Linux/Android provider/MCP branches call
/// (`BoundedHTTP.androidBounded`, `IncrementalSSEPipeline.events`,
/// `MCPIncrementalCollect.execute`, `StreamingTransport.collect/stream`) over
/// the delegate transport against a synthetic loopback fixture. They prove
/// mechanism (incrementality, early caps, bounded pipeline, terminal-once,
/// policy forwarding, explicit recoverable overflow) BEFORE any device run.
/// They are NOT proof of Android FoundationNetworking internals, real cloud
/// TLS/hostname behaviour or G02 business completion (Main's gates).
final class IncrementalTransportTests: XCTestCase {

    private var fixture: ScriptedLoopbackFixture?

    private func startFixture() throws -> ScriptedLoopbackFixture {
        let server = try ScriptedLoopbackFixture()
        server.start()
        fixture = server
        return server
    }

    private func url(_ server: ScriptedLoopbackFixture, _ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(server.port)\(path)")!
    }

    private func request(_ server: ScriptedLoopbackFixture,
                         _ path: String,
                         method: String = "GET",
                         body: Data? = nil,
                         headers: [String: String] = [:],
                         timeout: TimeInterval? = nil) -> URLRequest {
        var request = URLRequest(url: url(server, path))
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let timeout { request.timeoutInterval = timeout }
        return request
    }

    /// The provider streaming mirrors — the same construction the Android
    /// product path uses, so host coverage exercises the real body.
    private func providerSessions() -> (default: URLSession, ephemeral: URLSession) {
        (ProviderTransport.streamingSession(ephemeral: false),
         ProviderTransport.streamingSession(ephemeral: true))
    }

    override func tearDown() {
        fixture?.stop()
        fixture = nil
        super.tearDown()
    }

    // MARK: - bounded relay contract (callback -> parser -> consumer)

    func testRelayKeepsOrderAndRefusesOverflowWithoutLoss() async throws {
        let relay = BoundedAsyncRelay<Data>(maxCount: 3, maxBytes: 30, byteCount: { $0.count })
        XCTAssertTrue(relay.trySend(Data(repeating: 1, count: 10)))
        XCTAssertTrue(relay.trySend(Data(repeating: 2, count: 10)))
        XCTAssertTrue(relay.trySend(Data(repeating: 3, count: 10)))
        // Fourth chunk fits neither count nor bytes: explicit false, NOT a
        // silent drop, and nothing already buffered is disturbed.
        XCTAssertFalse(relay.trySend(Data(repeating: 4, count: 10)))
        XCTAssertEqual(relay.pendingCount, 3)
        XCTAssertEqual(relay.pendingBytes, 30)
        for expected in [UInt8(1), 2, 3] {
            let next = try await relay.next()
            let expectedData = Data(repeating: expected, count: 10)
            XCTAssertEqual(next, expectedData)
        }
        relay.terminate(.success(()))
        let drained = try await relay.next()
        XCTAssertNil(drained)
    }

    func testRelayCommittedContentDrainsBeforeTerminalError() async throws {
        let relay = BoundedAsyncRelay<Data>(maxCount: 8, maxBytes: .max, byteCount: { $0.count })
        XCTAssertTrue(relay.trySend(Data([1])))
        XCTAssertTrue(relay.trySend(Data([2])))
        relay.terminate(.failure(IncrementalTransportError.pendingBufferSaturated(maxBufferedBytes: 1)))
        // Explicit recoverable error AFTER committed bytes — never before.
        let drainedA = try await relay.next()
        let drainedB = try await relay.next()
        XCTAssertEqual(drainedA, Data([1]))
        XCTAssertEqual(drainedB, Data([2]))
        do {
            _ = try await relay.next()
            XCTFail("terminal error must surface after drain")
        } catch let error as IncrementalTransportError {
            guard case .pendingBufferSaturated = error else { return XCTFail("wrong case: \(error)") }
        }
        // Terminal is exactly-once; later producers are fenced.
        XCTAssertFalse(relay.terminate(.success(())))
        XCTAssertFalse(relay.trySend(Data([3])))
    }

    func testRelaySendBackpressuresAndFencesParkedProducer() async throws {
        let relay = BoundedAsyncRelay<Data>(maxCount: 1, maxBytes: .max, byteCount: { $0.count })
        XCTAssertTrue(relay.trySend(Data([1])))
        actor SentFlag {
            var value: Bool?
            func set(_ v: Bool) { value = v }
            func get() -> Bool? { value }
        }
        let flag = SentFlag()
        let producer = Task.detached { () -> Bool in
            let sent = await relay.send(Data([2]))  // parks: full
            await flag.set(sent)
            return sent
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        // Consumer drains slot #1 -> parked producer acquires the room.
        let popped = try await relay.next()
        XCTAssertEqual(popped, Data([1]))
        var spins = 0
        var current = await flag.get()
        while current == nil, spins < 40 {
            try await Task.sleep(nanoseconds: 25_000_000)
            current = await flag.get()
            spins += 1
        }
        XCTAssertEqual(current, true, "send must complete once room frees")
        let poppedTwo = try await relay.next()
        XCTAssertEqual(poppedTwo, Data([2]))
        // Refill to full and park a NEW producer, then terminate: the parked
        // producer must be released with false while committed content stays
        // drainable before the terminal.
        XCTAssertTrue(relay.trySend(Data([4])))          // maxCount == 1: now full
        let parked = Task.detached { () -> Bool in await relay.send(Data([5])) }
        try await Task.sleep(nanoseconds: 60_000_000)    // it parks
        relay.terminate(.success(()))
        let outcome = await parked.value
        XCTAssertFalse(outcome, "parked producer must unwind false on terminal")
        let committed = try await relay.next()
        XCTAssertEqual(committed, Data([4]))
        let end = try await relay.next()
        XCTAssertNil(end)
        _ = await producer.value  // first producer completed normally after room freed
    }

    // MARK: - collect: early caps (Android non-stream path)

    func testCollectServesDeclaredLengthBodyExactly() async throws {
        let server = try startFixture()
        let payload = Data("model-catalog".utf8)
        server.register(path: "/models") { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "application/json",
                "content-length": "\(payload.count)",
            ])
            connection.sendRaw(payload)
        }
        let (data, response) = try await StreamingTransport.collect(
            request(server, "/models"), via: providerSessions().default, maxBytes: 4096)
        XCTAssertEqual(data, payload)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(server.count(for: "/models"), 1)
    }

    func testCollectRejectsDeclaredOversizeBeforeBody() async throws {
        let server = try startFixture()
        server.register(path: "/huge-declared") { connection in
            connection.sendHead(status: 200, headers: ["content-length": "200000"])
            ScriptedLoopbackFixture.sleep(50)
            for _ in 0..<20 {
                connection.sendRaw(Data(repeating: 0x41, count: 10_000))
                ScriptedLoopbackFixture.sleep(25)
            }
        }
        do {
            _ = try await StreamingTransport.collect(
                request(server, "/huge-declared"), via: providerSessions().default, maxBytes: 16_384)
            return XCTFail("expected responseTooLarge")
        } catch let error as IncrementalTransportError {
            XCTAssertEqual(error, .responseTooLarge(maxBytes: 16_384))
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(server.sawClientAbort(for: "/huge-declared"),
                      "declared-length rejection must close the request early")
    }

    func testCollectStopsEarlyOnUndeclaredChunkedOversize() async throws {
        let server = try startFixture()
        server.register(path: "/huge-streamed") { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "application/json", "transfer-encoding": "chunked",
            ])
            var written = 0
            while written < 100_000 {
                connection.sendChunk(Data(repeating: 0x42, count: 8_192))
                if connection.clientGone { return }
                written += 8_192
                ScriptedLoopbackFixture.sleep(20)
            }
            connection.finishChunked()
        }
        do {
            _ = try await StreamingTransport.collect(
                request(server, "/huge-streamed"), via: providerSessions().default, maxBytes: 16_384)
            return XCTFail("expected responseTooLarge from observed bytes")
        } catch let error as IncrementalTransportError {
            XCTAssertEqual(error, .responseTooLarge(maxBytes: 16_384))
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(server.sawClientAbort(for: "/huge-streamed"))
    }

    func testBoundedHTTPAndroidBodyFailsClosedOnOversize() async throws {
        // The EXACT function the Android BoundedHTTP.data branch calls. The
        // provider-visible message ("Provider response exceeds N bytes") is
        // mapped from this typed error byte-for-byte like the Apple branch.
        let server = try startFixture()
        server.register(path: "/models-oversize") { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "application/json", "transfer-encoding": "chunked",
            ])
            for _ in 0..<10 {
                connection.sendChunk(Data(repeating: 0x43, count: 4_096))
                ScriptedLoopbackFixture.sleep(20)
            }
            connection.finishChunked()
        }
        do {
            _ = try await BoundedHTTP.androidBounded(
                request: request(server, "/models-oversize"),
                session: providerSessions().default,
                maxBytes: 8_192)
            return XCTFail("expected over-cap error")
        } catch let error as IncrementalTransportError {
            guard case .responseTooLarge(let cap) = error else { return XCTFail("wrong case") }
            XCTAssertEqual(cap, 8_192)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(server.sawClientAbort(for: "/models-oversize"))
    }

    // MARK: - stream: real incrementality through the pump pipeline

    /// A deterministic TWO-WAY barrier, not a timing margin: the server
    /// writes only the FIRST partial event, then refuses the final bytes and
    /// the end-of-response until it observes the client's own
    /// `clientSawFirstEvent` flag. Only a genuinely incremental client can
    /// ever open the barrier; a buffered client (which by construction has
    /// no event until after EOF) times the barrier out and the fixture
    /// records `sawFirstBeforeEnd == false`. The same fixture therefore
    /// doubles as a NEGATIVE CONTROL: `data(for:)` buffered replay MUST be
    /// detected as non-incremental, proving the gate is not vacuous.
    final class BarrierGate: @unchecked Sendable {
        private let lock = NSLock()
        private var clientSawFirstEvent = false
        private var sawFirstBeforeEnd = false
        private var endClosed = false
        private var eventCount = 0
        private var firstAt: Date?
        private var secondAt: Date?

        struct Snapshot {
            var sawFirstBeforeEnd = false
            var endClosed = false
            var eventCount = 0
            var firstArrivedWhileOpen = false
            var secondAt: Date?
        }

        // Synchronous lock-wrapped helpers: calling THESE from async contexts
        // is legal; raw NSLock.lock() is not.
        func noteEventArrival() -> (count: Int, arrivedWhileOpen: Bool) {
            lock.lock()
            defer { lock.unlock() }
            eventCount += 1
            switch eventCount {
            case 1: firstAt = Date()
            case 2: secondAt = Date()
            default: break
            }
            return (eventCount, !endClosed)
        }

        func markClientSawFirst() {
            lock.lock(); clientSawFirstEvent = true; lock.unlock()
        }

        var clientHasSeenFirst: Bool {
            lock.lock(); defer { lock.unlock() }; return clientSawFirstEvent
        }

        func recordBarrierOutcome(opened: Bool) {
            lock.lock(); sawFirstBeforeEnd = opened; lock.unlock()
        }

        func markEndClosed() {
            lock.lock(); endClosed = true; lock.unlock()
        }

        var snapshot: Snapshot {
            lock.lock(); defer { lock.unlock() }
            var value = Snapshot()
            value.sawFirstBeforeEnd = sawFirstBeforeEnd
            value.endClosed = endClosed
            value.eventCount = eventCount
            value.secondAt = secondAt
            return value
        }
    }

    private func barrierScriptedEndpoint(server: ScriptedLoopbackFixture,
                                         path: String,
                                         gate: BarrierGate,
                                         barrierTimeoutMs: Int = 2_000) {
        let event1 = Data("data: {\"choices\":[{\"delta\":{\"content\":\"one\"}}]}\n\n".utf8)
        let event2 = Data("data: {\"choices\":[{\"delta\":{\"content\":\"two\"}}]}\n\n".utf8)
        let done = Data("data: [DONE]\n\n".utf8)
        server.register(path: path) { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "text/event-stream", "transfer-encoding": "chunked",
            ])
            connection.sendChunk(event1)
            // WAIT for the client to prove it parsed event 1 while the
            // response is still open. Bounded owned TEST deadline.
            var waited = 0
            var opened = false
            while waited < barrierTimeoutMs {
                opened = gate.clientHasSeenFirst
                if opened { break }
                ScriptedLoopbackFixture.sleep(10)
                waited += 10
            }
            gate.recordBarrierOutcome(opened: opened)
            connection.sendChunk(event2)
            connection.sendChunk(done)
            connection.finishChunked()
            gate.markEndClosed()
        }
    }

    func testPipelineDeliversFirstEventThroughTwoWayBarrier() async throws {
        let server = try startFixture()
        let gate = BarrierGate()
        barrierScriptedEndpoint(server: server, path: "/v1/chat/completions", gate: gate)
        let stream = IncrementalSSEPipeline.events(
            urlRequest: request(server, "/v1/chat/completions"),
            via: providerSessions().default)
        var firstArrivedWhileOpen = false
        var firstAt: Date?
        var secondAt: Date?
        var eventCount = 0
        do {
            for try await _ in stream {
                let arrival = gate.noteEventArrival()
                if arrival.count == 1 {
                    firstArrivedWhileOpen = arrival.arrivedWhileOpen
                    firstAt = Date()
                    gate.markClientSawFirst()   // opens the barrier
                }
                eventCount = arrival.count
                if arrival.count == 2 { secondAt = Date(); break }
            }
        }
        let final = gate.snapshot
        XCTAssertTrue(final.sawFirstBeforeEnd,
                      "the fixture must have observed the client parsing event 1 BEFORE it sent the tail")
        XCTAssertTrue(firstArrivedWhileOpen, "the client must have seen event 1 before the server closed")
        XCTAssertEqual(eventCount, 2)
        if let firstAt, let secondAt {
            XCTAssertGreaterThan(secondAt.timeIntervalSince(firstAt), 0.001,
                                 "events must arrive spread over the barrier handshake, not batched")
        }
    }

    func testBufferedDataReplayIsDetectedAsNonIncremental() async throws {
        // Negative control on the SAME two-way barrier: the old Linux/Android
        // `data(for:)` fallback style cannot open the barrier (it has no
        // event until after the server's bounded deadline expired), so the
        // fixture records sawFirstBeforeEnd == false and the full body still
        // parses identically. This proves the incremental assertion above is
        // NOT vacuous and that buffered replay is exactly what we replaced.
        let server = try startFixture()
        let gate = BarrierGate()
        barrierScriptedEndpoint(server: server, path: "/v1/buffered", gate: gate)
        let bufferedSession = URLSession(configuration: .ephemeral)
        let (data, response) = try await bufferedSession.data(
            for: request(server, "/v1/buffered"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let bufferedFinal = gate.snapshot
        XCTAssertFalse(bufferedFinal.sawFirstBeforeEnd,
                       "buffered replay must be unable to open the pre-EOF client barrier")
        XCTAssertTrue(bufferedFinal.endClosed,
                      "the barrier deadline must have been reached and the response completed")
        // The SAME buffered bytes still parse via the ORIGINAL parser —
        // semantics preserved, mechanism not incremental.
        var parser = SSEParser()
        var events = parser.feed(data)
        events.append(contentsOf: try parser.finish())
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.last?.data == "[DONE]")
    }

    func testPipelineFlushesSmallFirstEventAndHandlesBOMCRFLFSplitUnicode() async throws {
        let server = try startFixture()
        let emoji = Array("😀".utf8)   // F0 9F 98 80
        server.register(path: "/sse/mixed") { connection in
            // BOM at stream start, tiny first event with CRLF, then one line
            // with the emoji split mid-codepoint AND the CRLF terminator
            // split across two writes (…\r in one, \n… in the next).
            connection.sendRaw(Data([0xEF, 0xBB, 0xBF]))
            connection.sendRaw(Data("data: first\r\n\r\n".utf8))
            connection.sendRaw(Data("data: ".utf8) + Data(emoji[0..<2]))
            ScriptedLoopbackFixture.sleep(40)
            connection.sendRaw(Data(emoji[2...]) + Data("tail\r".utf8))
            ScriptedLoopbackFixture.sleep(40)
            connection.sendRaw(Data("\n\r\n".utf8))   // completes the split line
            connection.sendRaw(Data("data: end\r\n\r\n".utf8))
        }
        let stream = IncrementalSSEPipeline.events(
            urlRequest: request(server, "/sse/mixed"), via: providerSessions().ephemeral)
        var events: [SSEEvent] = []
        for try await event in stream { events.append(event) }
        XCTAssertEqual(events.map(\.data), ["first", "😀tail", "end"],
                       "original SSEParser semantics (BOM skip, CR/LF/CRLF lines, UTF-8 reassembly) must hold")
    }

    func testPipelineExactUnicodeEventsAcrossEveryChunkBoundary() async throws {
        let server = try startFixture()
        let line = "data: 表情😀tail\n\n"
        let bytes = Array(line.utf8)
        server.register(path: "/sse/unicode-exact") { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "text/event-stream", "transfer-encoding": "chunked",
            ])
            var index = 0
            while index < bytes.count {
                let end = min(index + 3, bytes.count)   // guaranteed mid-codepoint splits
                connection.sendChunk(Data(bytes[index..<end]))
                index = end
                ScriptedLoopbackFixture.sleep(5)
            }
            connection.finishChunked()
        }
        let stream = IncrementalSSEPipeline.events(
            urlRequest: request(server, "/sse/unicode-exact"), via: providerSessions().default)
        var events: [SSEEvent] = []
        for try await event in stream { events.append(event) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data, "表情😀tail")
    }

    func testPipelineHttpErrorSentinelKeepsStatusAndBoundedBody() async throws {
        let server = try startFixture()
        let closeGate = CloseGate()
        server.register(path: "/sse/boom") { connection in
            connection.sendHead(status: 500, headers: [
                "content-type": "application/json", "transfer-encoding": "chunked",
            ])
            for _ in 0..<16 {
                connection.sendChunk(Data(repeating: 0x45, count: 4_096))
                if connection.clientGone { return }
                ScriptedLoopbackFixture.sleep(10)
            }
            connection.finishChunked()
            closeGate.set()
        }
        let stream = IncrementalSSEPipeline.events(
            urlRequest: request(server, "/sse/boom"), via: providerSessions().default)
        var events: [SSEEvent] = []
        for try await event in stream { events.append(event) }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.event, "__http_error__")
        let payload = events.first!.data
        XCTAssertTrue(payload.hasPrefix("500\n"), payload)
        XCTAssertLessThanOrEqual(payload.utf8.count, 4096 + 8)
        try await Task.sleep(nanoseconds: 200_000_000)
        // The honest expectation is the OPPOSITE of a completed response:
        // the prefix bound must ABORT the download (the server notices the
        // gone client mid-script). A fully-written close would prove the
        // prefix bound did nothing.
        XCTAssertTrue(server.sawClientAbort(for: "/sse/boom"),
                      "error prefix bound must stop reading, not download the full error body")
        XCTAssertFalse(closeGate.value,
                       "the error body must NOT have been fully written when the bound is enforced")
    }

    func testPipelineSlowConsumerSaturatesWithExplicitRecoverableError() async throws {
        let server = try startFixture()
        server.register(path: "/sse/flood") { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "text/event-stream", "transfer-encoding": "chunked",
            ])
            for index in 0..<64 {
                let line = "data: ev\(index)-\(String(repeating: "x", count: 128))\n\n"
                connection.sendChunk(Data(line.utf8))
                if connection.clientGone { return }
                ScriptedLoopbackFixture.sleep(10)
            }
            connection.finishChunked()
        }
        var limits = IncrementalSSEPipeline.Limits()
        limits.maxBufferedBodyBytes = 1_024
        limits.maxPendingEvents = 2
        limits.maxPendingEventBytes = 512
        let stream = IncrementalSSEPipeline.events(
            urlRequest: request(server, "/sse/flood"), via: providerSessions().default, limits: limits)
        var committed: [SSEEvent] = []
        do {
            for try await event in stream {
                committed.append(event)
                ScriptedLoopbackFixture.sleep(120)  // deliberately slow consumer
            }
            return XCTFail("slow consumer must saturate explicitly")
        } catch let error as IncrementalTransportError {
            guard case .pendingBufferSaturated(let maxBytes) = error else {
                return XCTFail("expected pendingBufferSaturated, got \(error)")
            }
            XCTAssertEqual(maxBytes, 1_024)
            XCTAssertFalse(committed.isEmpty, "committed events must surface BEFORE the error")
            XCTAssertTrue(committed.first!.data.hasPrefix("ev0-"),
                          "committed prefix must be ordered from the first event")
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(server.sawClientAbort(for: "/sse/flood"),
                      "saturation must cancel the owned request, not keep downloading")
    }

    func testConsumerCancellationClosesOwnedRequestAndKeepsSessionUsable() async throws {
        let server = try startFixture()
        let defaultSession = providerSessions().default
        server.register(path: "/sse/cancel-me") { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "text/event-stream", "transfer-encoding": "chunked",
            ])
            connection.sendChunk(Data("data: a1\n\n".utf8))
            for _ in 0..<20 {
                connection.sendChunk(Data("data: later\n\n".utf8))
                if connection.clientGone { return }
                ScriptedLoopbackFixture.sleep(50)
            }
            connection.finishChunked()
        }
        server.register(path: "/sse/second-unrelated") { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "text/event-stream", "transfer-encoding": "chunked",
            ])
            connection.sendChunk(Data("data: complete\n\n".utf8))
            connection.finishChunked()
        }
        actor Counter {
            var value = 0
            func bump() { value += 1 }
        }
        let stream = IncrementalSSEPipeline.events(
            urlRequest: request(server, "/sse/cancel-me"), via: defaultSession)
        let seen = Counter()
        let consumer = Task { () -> (any Error)? in
            do {
                for try await _ in stream { await seen.bump() }
            } catch {
                return error
            }
            return nil
        }
        var spins = 0
        var seenCount = await seen.value
        while seenCount == 0, spins < 200 {
            try await Task.sleep(nanoseconds: 25_000_000)
            seenCount = await seen.value
            spins += 1
        }
        XCTAssertGreaterThan(seenCount, 0, "first event must arrive before cancellation")
        await consumer.cancel()  // same ownership path as continuation.onTermination
        _ = await consumer.value
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(server.sawClientAbort(for: "/sse/cancel-me"),
                      "cancelling the consumer must cancel the OWNED task")
        // The session is NOT invalidated: a second unrelated request on the
        // SAME session still completes normally.
        let second = IncrementalSSEPipeline.events(
            urlRequest: request(server, "/sse/second-unrelated"), via: defaultSession)
        var secondEvents: [SSEEvent] = []
        for try await event in second { secondEvents.append(event) }
        XCTAssertEqual(secondEvents.map(\.data), ["complete"])
        XCTAssertEqual(server.count(for: "/sse/second-unrelated"), 1)
    }

    func testRequestTimeoutSurfacesPlatformTimedOut() async throws {
        let server = try startFixture()
        server.register(path: "/slow-headers") { connection in
            ScriptedLoopbackFixture.sleep(2_500)
            connection.sendHead(status: 200, headers: ["content-length": "2"])
            connection.sendRaw(Data("ok".utf8))
        }
        do {
            _ = try await StreamingTransport.collect(
                request(server, "/slow-headers", timeout: 0.5),
                via: providerSessions().default, maxBytes: 1024)
            return XCTFail("expected timeout")
        } catch {
            let urlError = error as? URLError
            XCTAssertEqual(urlError?.code, .timedOut, "got \(error)")
        }
    }

    func testPlainSessionFailsClosedNeverRecreated() async throws {
        // A caller-owned NON-streaming session: reads must fail closed with
        // the typed error — never move onto a recreated session.
        let plain = URLSession(configuration: .ephemeral)
        do {
            _ = try await StreamingTransport.collect(
                URLRequest(url: URL(string: "http://127.0.0.1:1/none")!),
                via: plain, maxBytes: 10)
            return XCTFail("plain session must fail closed")
        } catch let error as IncrementalTransportError {
            guard case .sessionNotStreamable = error else { return XCTFail("wrong case: \(error)") }
        }
        XCTAssertFalse(StreamingTransport.isStreamable(plain))
        XCTAssertTrue(StreamingTransport.isStreamable(providerSessions().default))
        XCTAssertTrue(StreamingTransport.isStreamable(providerSessions().ephemeral))
    }

    func testEphemeralStreamingConfigurationKeepsTemporaryIsolationPolicy() throws {
        // The exact original nilled-storage properties (shared factory so
        // the plain Apple session and the streaming mirror cannot drift).
        let configuration = ProviderTransport.ephemeralConfiguration()
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
    }

    // MARK: - MCP collect seam

    private func mcpSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.httpMaximumConnectionsPerHost = 2
        return StreamingTransport.makeSession(configuration: configuration,
                                              policyDelegate: MCPNoRedirectSessionDelegate())
    }

    func testMCPIncrementalCollectServesJSONWithinCap() async throws {
        let server = try startFixture()
        let body = Data(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#.utf8)
        server.register(path: "/mcp") { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "application/json", "content-length": "\(body.count)",
            ])
            connection.sendRaw(body)
        }
        let (data, response) = try await MCPIncrementalCollect.execute(
            request(server, "/mcp", method: "POST",
                    body: Data("{}".utf8), headers: ["Authorization": "Bearer synthetic-fixture"]),
            via: mcpSession(), maxBytes: MCPRemoteClient.maximumResponseBytes)
        XCTAssertEqual(data, body)
        XCTAssertEqual(response.statusCode, 200)
    }

    func testMCPIncrementalCollectCancelsOversizeEarly() async throws {
        let server = try startFixture()
        server.register(path: "/mcp/huge") { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "application/json", "transfer-encoding": "chunked",
            ])
            for _ in 0..<64 {
                connection.sendChunk(Data(repeating: 0x7B, count: 8_192))
                if connection.clientGone { return }
                ScriptedLoopbackFixture.sleep(15)
            }
            connection.finishChunked()
        }
        do {
            _ = try await MCPIncrementalCollect.execute(
                request(server, "/mcp/huge", method: "POST", body: Data("{}".utf8)),
                via: mcpSession(), maxBytes: 32_768)
            return XCTFail("expected responseTooLarge")
        } catch let error as MCPClientError {
            guard case .responseTooLarge(let cap) = error else { return XCTFail("wrong case: \(error)") }
            XCTAssertEqual(cap, 32_768)
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(server.sawClientAbort(for: "/mcp/huge"),
                      "MCP cap must stop the download at the crossing, not after")
    }

    func testMCPRedirectPolicyNeverForwardsAuthToAnotherEndpoint() async throws {
        let server = try startFixture()
        server.register(path: "/mcp/redirect") { connection in
            connection.sendHead(status: 302, headers: [
                "location": "http://127.0.0.1:\(server.port)/mcp/stealer",
                "content-length": "0",
            ])
        }
        server.register(path: "/mcp/stealer") { connection in
            connection.sendHead(status: 200, headers: ["content-length": "2"])
            connection.sendRaw(Data("ok".utf8))
        }
        do {
            _ = try await MCPIncrementalCollect.execute(
                request(server, "/mcp/redirect", method: "POST",
                        body: Data("{}".utf8),
                        headers: ["Authorization": "Bearer synthetic-secret"]),
                via: mcpSession(), maxBytes: 4096)
            return XCTFail("redirect must surface as typed httpError")
        } catch let error as MCPClientError {
            guard case .httpError(let status, _) = error else { return XCTFail("wrong case: \(error)") }
            XCTAssertEqual(status, 302, "the 3xx itself must be the fail-closed final response")
        }
        XCTAssertEqual(server.count(for: "/mcp/stealer"), 0,
                       "MCP no-redirect policy must forward NOTHING to the new location")
    }

    func testUnpoliciedSessionFollowsLikeStockDefault() async throws {
        // Control for the test above: with NO policy object the transport
        // follows exactly like the stock shared session (providers' path).
        let server = try startFixture()
        let session = StreamingTransport.makeSession(configuration: URLSessionConfiguration.ephemeral)
        let payload = Data("followed".utf8)
        server.register(path: "/hop") { connection in
            connection.sendHead(status: 302, headers: [
                "location": "http://127.0.0.1:\(server.port)/landed", "content-length": "0",
            ])
        }
        server.register(path: "/landed") { connection in
            connection.sendHead(status: 200, headers: ["content-length": "\(payload.count)"])
            connection.sendRaw(payload)
        }
        let (data, response) = try await StreamingTransport.collect(
            request(server, "/hop"), via: session, maxBytes: 4096)
        XCTAssertEqual(data, payload)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(server.count(for: "/landed"), 1)
    }

    func testMCPInjectedPlainSessionFailsClosedTypedList() async throws {
        let server = try startFixture()
        server.register(path: "/mcp/plain") { connection in
            connection.sendHead(status: 200, headers: ["content-length": "2"])
            connection.sendRaw(Data("{}".utf8))
        }
        do {
            _ = try await MCPIncrementalCollect.execute(
                request(server, "/mcp/plain", method: "POST", body: Data("{}".utf8)),
                via: URLSession.shared, maxBytes: 4096)
            return XCTFail("injected plain session must fail closed")
        } catch let error as MCPClientError {
            guard case .invalidResponse(let detail) = error else { return XCTFail("wrong case: \(error)") }
            XCTAssertTrue(detail.contains("injected session"), detail)
        }
    }

    func testHTTPStatusAndAuthErrorMappingMatchesOriginalContract() async throws {
        let server = try startFixture()
        server.register(path: "/mcp/401") { connection in
            connection.sendHead(status: 401, headers: ["content-length": "5"])
            connection.sendRaw(Data("nope!".utf8))
        }
        server.register(path: "/mcp/500-huge") { connection in
            connection.sendHead(status: 500, headers: [
                "content-type": "text/plain", "transfer-encoding": "chunked",
            ])
            for _ in 0..<4 { connection.sendChunk(Data(repeating: 0x45, count: 4_096)) }
            connection.finishChunked()
        }
        do {
            _ = try await MCPIncrementalCollect.execute(
                request(server, "/mcp/401", method: "POST", body: Data("{}".utf8)),
                via: mcpSession(), maxBytes: 4096)
            return XCTFail("401 must map to authenticationRequired")
        } catch let error as MCPClientError {
            guard case .authenticationRequired = error else { return XCTFail("wrong: \(error)") }
        }
        do {
            _ = try await MCPIncrementalCollect.execute(
                request(server, "/mcp/500-huge", method: "POST", body: Data("{}".utf8)),
                via: mcpSession(), maxBytes: 2_097_152)
            return XCTFail("500 must map to httpError")
        } catch let error as MCPClientError {
            guard case .httpError(let status, let body) = error else { return XCTFail("wrong: \(error)") }
            XCTAssertEqual(status, 500)
            XCTAssertLessThanOrEqual(body.utf8.count, 1_024, "error body stays 1 KiB-bounded")
        }
    }

    // MARK: - original session-level authentication/trust policy forwarding

    /// Implements ONLY the SESSION-level challenge callback (the classic
    /// server-trust / pinning shape) and records what the router forwarded.
    final class SessionChallengePolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(method: String, host: String?)] = []
        private let disposition: URLSession.AuthChallengeDisposition

        init(disposition: URLSession.AuthChallengeDisposition) {
            self.disposition = disposition
            super.init()
        }

        var recorded: [(method: String, host: String?)] {
            lock.lock(); defer { lock.unlock() }; return storage
        }

        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            lock.lock()
            storage.append((challenge.protectionSpace.authenticationMethod,
                            challenge.protectionSpace.host))
            lock.unlock()
            completionHandler(disposition, nil)
        }
    }

    private func challengeFixture(_ server: ScriptedLoopbackFixture, path: String) {
        server.register(path: path) { connection in
            connection.sendHead(status: 401, headers: [
                "www-authenticate": "Basic realm=\"floe-fixture\"",
                "content-length": "5",
            ])
            connection.sendRaw(Data("nope!".utf8))
        }
    }

    func testSessionLevelAuthRejectionIsForwardedAndNeverSilentlyDefaulted() async throws {
        let server = try startFixture()
        challengeFixture(server, path: "/auth/basic-reject")
        let policy = SessionChallengePolicy(disposition: .cancelAuthenticationChallenge)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = StreamingTransport.makeSession(configuration: configuration,
                                                     policyDelegate: policy)
        do {
            let (_, response) = try await StreamingTransport.collect(
                request(server, "/auth/basic-reject"), via: session, maxBytes: 1024)
            // A bypass would deliver the default-handled 401 response here.
            XCTFail("original rejection must not become a delivered response "
                    + "(status \((response as? HTTPURLResponse)?.statusCode ?? -1))")
        } catch {
            // The ORIGINAL policy's rejection surfaced as a transport failure.
            XCTAssertFalse(error is IncrementalTransportError,
                           "rejection must surface as a platform/auth error, got \(error)")
        }
        XCTAssertEqual(policy.recorded.count, 1,
                       "the session-level original handler must have received the challenge")
        XCTAssertEqual(policy.recorded.first?.method, "NSURLAuthenticationMethodHTTPBasic")
    }

    func testSessionLevelAuthDefaultPassThroughKeepsStandardFlow() async throws {
        let server = try startFixture()
        challengeFixture(server, path: "/auth/basic-default")
        let policy = SessionChallengePolicy(disposition: .performDefaultHandling)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = StreamingTransport.makeSession(configuration: configuration,
                                                     policyDelegate: policy)
        let (data, response) = try await StreamingTransport.collect(
            request(server, "/auth/basic-default"), via: session, maxBytes: 1024)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "nope!")
        XCTAssertEqual(policy.recorded.count, 1,
                       "the original session-level handler must be consulted, not bypassed")
    }

    func testNoPolicyKeepsPlatformDefaultChallengeHandling() async throws {
        // No original handler: the platform default (no credentials -> the
        // 401 itself) is preserved; the transport adds no trust decision.
        let server = try startFixture()
        challengeFixture(server, path: "/auth/basic-nopolicy")
        let session = StreamingTransport.makeSession(
            configuration: URLSessionConfiguration.ephemeral)
        let (_, response) = try await StreamingTransport.collect(
            request(server, "/auth/basic-nopolicy"), via: session, maxBytes: 1024)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
    }

    // MARK: - terminal-once under races

    func testTerminalDeliveredExactlyOnceUnderCompletionCancelRace() async throws {
        let server = try startFixture()
        server.register(path: "/sse/race") { connection in
            connection.sendHead(status: 200, headers: [
                "content-type": "text/event-stream", "transfer-encoding": "chunked",
            ])
            connection.sendChunk(Data("data: r1\n\n".utf8))
            ScriptedLoopbackFixture.sleep(30)
            connection.finishChunked()
        }
        let stream = try StreamingTransport.stream(
            request(server, "/sse/race"), via: providerSessions().default, maxBufferedBytes: 4096)
        // Cancel exactly while the server closes: one of the two paths must
        // win; the terminal counter proves it happened ONCE.
        let consumer = Task { () -> Error? in
            do { for try await _ in stream {} } catch { return error }
            return nil
        }
        try await Task.sleep(nanoseconds: 45_000_000)
        stream.cancelOwned()
        _ = await consumer.value
        for _ in 0..<20 {
            if stream.terminalDeliveries >= 1 { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stream.terminalDeliveries, 1,
                       "cancellation racing EOF must still terminate exactly once")
    }
}

extension ScriptedLoopbackFixture.Connection {
    /// Records the client abort detected by failed writes; handlers poll it
    /// between scripted chunks so long floods stop promptly after cancellation.
    var clientGone: Bool { fixture.sawClientAbort(for: request.path) }
}
#endif
