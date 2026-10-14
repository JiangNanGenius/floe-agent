// FloeExecutionTests — HELLO probe cancellation and token-stream wake coverage.
//
// The retry probe races a console read against a bounded sleep. Left
// unhandled, a PARENT-task cancellation while the guest is silent cancelled
// only the sleep: the reader stayed suspended on a non-cancellable
// continuation, the task group could not exit, and the probe hung until some
// external close. These tests drive the real `LinuxGuestCommandChannel` over
// the scripted console used by `LinuxGuestHostChannelTests` (nothing is
// stubbed below the channel) and prove:
//
//  * a cancelled silent probe terminates promptly with CancellationError and
//    unregisters its attempt token (no orphan waiter, no second HELLO);
//  * a probe entered with the cancellation flag already set fails before it
//    writes anything;
//  * a normal multi-chunk answer still assembles across chunk boundaries —
//    cancelling the losing sleep after a read wins does not close the token
//    stream between chunks;
//  * the attempt window stays bounded, every attempt draws a fresh token, and
//    a late answer for an expired attempt is dropped by the router instead of
//    being spliced into a later attempt's parse.
//
// Every await on an unstructured task is BOUNDED: a regression fails the test
// instead of hanging the suite, and no stuck task is awaited past the bound.

import Foundation
import XCTest
import FloeCore
@testable import FloeExecution

// MARK: - bounded observation helpers

/// Lock-backed box for cross-task test observation.
private final class ProbeTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?

    func store(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// Bounded observation of an unstructured task: nil when the task did not
/// finish inside `timeout`. The task is cancelled and NEVER awaited past the
/// bound, so a stuck probe cannot hang the suite.
private func boundedProbeOutcome<T: Sendable>(
    _ task: Task<T, any Error>,
    timeout: TimeInterval
) async -> Result<T, any Error>? {
    let box = ProbeTestBox<Result<T, any Error>>()
    let observer = Task {
        do { box.store(.success(try await task.value)) } catch { box.store(.failure(error)) }
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let outcome = box.value {
            observer.cancel()
            return outcome
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    observer.cancel()
    task.cancel()
    return nil
}

/// Polls a test condition without blocking the actor.
private func probeWaitUntil(
    timeout: TimeInterval = 5,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Lock-backed HELLO attempt counter for the retry-window test.
private final class HelloAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Late console pushes need a reference to a console created after the
/// responder closure exists.
private final class ScriptedConsoleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var console: ScriptedHostConsole?

    func store(_ console: ScriptedHostConsole) {
        lock.lock()
        self.console = console
        lock.unlock()
    }

    func push(_ chunks: [Data]) {
        lock.lock()
        let console = self.console
        lock.unlock()
        console?.push(chunks)
    }
}

// MARK: - token stream wake semantics

final class LinuxGuestTokenStreamCancellationTests: XCTestCase {
    /// The lost-wake case: `cancelWait` lands BEFORE the reader registers, and
    /// the next cancellation-aware read must still complete — without closing
    /// the stream for later chunks.
    func testRecordedCancellationIsHonoredByTheNextReadAndLeavesTheStreamOpen() async {
        let stream = LinuxGuestTokenStream()
        await stream.cancelWait()
        let first = await stream.nextCancellable()
        XCTAssertNil(first, "a recorded cancellation must complete the next read")
        var finished = await stream.isFinished()
        XCTAssertFalse(finished, "cancelWait must not close the stream")

        await stream.push(Data("late-chunk".utf8))
        let second = await stream.nextCancellable()
        XCTAssertEqual(second, Data("late-chunk".utf8), "a later chunk must still be readable")
        finished = await stream.isFinished()
        XCTAssertFalse(finished)
    }

    /// A reader already suspended in `nextCancellable` is woken immediately,
    /// and the stream stays open for data (the wake is not a finish).
    func testCancellingASuspendedReadWakesItWithoutClosingTheStream() async {
        let stream = LinuxGuestTokenStream()
        let read = Task { () throws -> Data? in await stream.nextCancellable() }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(read.isCancelled)
        await stream.cancelWait()
        guard let outcome = await boundedProbeOutcome(read, timeout: 5) else {
            return XCTFail("a cancelled read was left suspended (orphan waiter)")
        }
        guard case .success(let value) = outcome else {
            return XCTFail("the cancelled read failed with \(outcome)")
        }
        XCTAssertNil(value)

        await stream.push(Data("after-cancel".utf8))
        let after = await stream.next()
        XCTAssertEqual(after, Data("after-cancel".utf8), "the stream must remain readable after a cancellation wake")
    }

    /// The plain read used by long-lived token consumers is unaffected by a
    /// recorded cancellation flag (only probe reads are cancellation-aware).
    func testPlainNextIsUnaffectedByRecordedCancellation() async {
        let stream = LinuxGuestTokenStream()
        await stream.cancelWait()
        await stream.push(Data("plain".utf8))
        let chunk = await stream.next()
        XCTAssertEqual(chunk, Data("plain".utf8))
    }
}

// MARK: - probe cancellation composition

final class LinuxGuestProbeCancellationTests: XCTestCase {
    func testCancelledSilentProbeFailsPromptlyAndCleansUpItsToken() async throws {
        let console = ScriptedHostConsole { _ in [] } // silent guest
        let channel = LinuxGuestCommandChannel(transport: console)

        let probe = Task { try await channel.probeCapabilities(timeout: 30) }
        let sent = await probeWaitUntil { HostFrames.first("HELLO", in: console.writtenText) != nil }
        XCTAssertTrue(sent, "the probe never wrote HELLO")

        let started = Date()
        probe.cancel()
        guard let outcome = await boundedProbeOutcome(probe, timeout: 5) else {
            return XCTFail("a cancelled silent probe did not finish within 5s (orphan waiter)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 3,
            "cancellation of a silent probe must be prompt, not deadline-bound"
        )
        guard case .failure(let error) = outcome else {
            return XCTFail("expected CancellationError, got \(outcome)")
        }
        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(error)")
        XCTAssertEqual(
            HostFrames.all("HELLO", in: console.writtenText).count, 1,
            "a cancelled probe must not start another attempt"
        )
        let live = await channel.liveTokenCount
        XCTAssertEqual(live, 0, "the cancelled attempt left its token registered")
        await channel.close()
    }

    func testAlreadyCancelledProbeFailsBeforeWritingHello() async throws {
        let console = ScriptedHostConsole { _ in [] }
        let channel = LinuxGuestCommandChannel(transport: console)

        let probe = Task { () throws -> String? in
            // A cancelled task's sleep returns immediately and leaves the
            // cancellation flag set, so the probe is entered already
            // cancelled in every interleaving.
            try? await Task.sleep(for: .seconds(60))
            return try await channel.probeCapabilities(timeout: 30)
        }
        probe.cancel()
        guard let outcome = await boundedProbeOutcome(probe, timeout: 5) else {
            return XCTFail("an already-cancelled probe did not finish within 5s")
        }
        guard case .failure(let error) = outcome, error is CancellationError else {
            return XCTFail("expected CancellationError, got \(outcome)")
        }
        XCTAssertEqual(
            HostFrames.all("HELLO", in: console.writtenText).count, 0,
            "an already-cancelled probe must not write HELLO"
        )
        let live = await channel.liveTokenCount
        XCTAssertEqual(live, 0)
        await channel.close()
    }

    /// The read-wins path: the losing sleep is cancelled as soon as the first
    /// chunk is consumed, and the stream must stay open for the second half.
    func testMultiChunkHelloAnswerStillReadsWhenTheLosingSleeperIsCancelled() async throws {
        let console = ScriptedHostConsole { data in
            let text = String(decoding: data, as: UTF8.self)
            guard let hello = HostFrames.first("HELLO", in: text) else { return [] }
            // Only the first half of the CAPS frame: the probe's first read
            // wins and its losing sleep is cancelled mid-answer.
            let caps = GuestFrames.caps(hello.token)
            return [caps.prefix(caps.count / 2)]
        }
        let channel = LinuxGuestCommandChannel(transport: console)
        let probe = Task { try await channel.probeCapabilities(timeout: 4, requireCurrentProtocol: true) }
        let sent = await probeWaitUntil { HostFrames.first("HELLO", in: console.writtenText) != nil }
        XCTAssertTrue(sent, "the probe never wrote HELLO")
        guard let hello = HostFrames.first("HELLO", in: console.writtenText) else {
            return XCTFail("no HELLO frame was captured")
        }
        // Deliberately after the first read returned and the parser armed the
        // next bounded read: the second half must not be lost to the
        // cancelled losing sleeper.
        try await Task.sleep(for: .milliseconds(200))
        let caps = GuestFrames.caps(hello.token)
        console.push([caps.suffix(from: caps.count / 2)])

        guard let outcome = await boundedProbeOutcome(probe, timeout: 5) else {
            return XCTFail("the probe never assembled the multi-chunk answer")
        }
        guard case .success(let capsLine) = outcome else {
            return XCTFail("expected the assembled CAPS answer, got \(outcome)")
        }
        XCTAssertEqual(capsLine?.contains("protocol=3"), true, "assembled CAPS payload was \(capsLine ?? "nil")")
        await channel.close()
    }

    /// Each attempt is bounded by its own window inside the caller's deadline,
    /// draws a fresh token, and a late answer addressed to an EXPIRED attempt
    /// is dropped by the router: the assembled answer must be the live
    /// attempt's, never the stale one.
    func testEachAttemptDrawsAFreshTokenAndLateAnswersAreIgnored() async throws {
        let attempts = HelloAttemptCounter()
        let box = ScriptedConsoleBox()
        let console = ScriptedHostConsole { data in
            let text = String(decoding: data, as: UTF8.self)
            guard let hello = HostFrames.first("HELLO", in: text) else { return [] }
            switch attempts.next() {
            case 1:
                // Expired attempt: its answer arrives after the retry window,
                // when its token is no longer registered.
                let stale = GuestFrames.caps(hello.token, hostArchive: "stale")
                Task {
                    try? await Task.sleep(for: .seconds(5.2))
                    box.push([stale])
                }
                return []
            case 2:
                // Live attempt: answered later than the stale frame, so a
                // spliced parse would be visible in the result.
                let fresh = GuestFrames.caps(hello.token)
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    box.push([fresh])
                }
                return []
            default:
                return []
            }
        }
        box.store(console)
        let channel = LinuxGuestCommandChannel(transport: console)
        let started = Date()
        let probe = Task { try await channel.probeCapabilities(timeout: 5.8, requireCurrentProtocol: true) }
        guard let outcome = await boundedProbeOutcome(probe, timeout: 12) else {
            return XCTFail("the bounded probe never completed")
        }
        let elapsed = Date().timeIntervalSince(started)
        guard case .success(let capsLine) = outcome else {
            return XCTFail("expected the live CAPS answer, got \(outcome)")
        }
        XCTAssertEqual(capsLine?.contains("protocol=3"), true)
        XCTAssertEqual(
            capsLine?.contains("hostArchive=stale"), false,
            "a late answer for an expired attempt was spliced into the live parse"
        )
        XCTAssertEqual(capsLine?.contains("hostArchive=create,extract,list,decompress"), true)
        XCTAssertEqual(attempts.value, 2, "the probe must retry once inside the caller's deadline")
        XCTAssertGreaterThanOrEqual(elapsed, 5.0, "the first attempt's retry window must be a real bound")
        XCTAssertLessThan(elapsed, 7.0, "the probe must stay inside its caller deadline")
        await channel.close()
    }
}
