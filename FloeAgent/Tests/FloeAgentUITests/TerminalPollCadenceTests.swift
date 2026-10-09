// FloeAppTests — Local terminal responsiveness: poll-cadence policy and a
// mock-backend measurement of interactive input latency and sustained
// output drain through the real LocalTerminalOwner loop.
//
// Evidence classes are labelled in the test names: the cadence tests are
// pure policy; the mock-backend test exercises the production owner loop
// against an in-process fake LocalShellBackend (NOT the real Linux guest);
// real-VM numbers belong to the device/simulator qualification with an
// installed Linux image (separately reported).

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeExecution
import FloeTools
import FloeCore
@testable import FloeApp

@Suite("FloeApp.TerminalPollCadence")
@MainActor
struct TerminalPollCadenceTests {

    @Test("Cadence policy: active rounds drain immediately, idle backs off to a 100 ms cap")
    func cadencePolicy() {
        var cadence = TerminalPollCadence()
        // Input sent or output read → no added delay (transport-speed drain).
        #expect(cadence.delayAfterExchange(sentInput: true, bytesRead: 0) == .zero)
        #expect(cadence.delayAfterExchange(sentInput: false, bytesRead: 10) == .zero)
        // Idle backoff: 10, 20, 30 ms …
        #expect(cadence.delayAfterExchange(sentInput: false, bytesRead: 0) == .milliseconds(10))
        #expect(cadence.delayAfterExchange(sentInput: false, bytesRead: 0) == .milliseconds(20))
        #expect(cadence.delayAfterExchange(sentInput: false, bytesRead: 0) == .milliseconds(30))
        // Activity resets the backoff.
        #expect(cadence.delayAfterExchange(sentInput: false, bytesRead: 5) == .zero)
        #expect(cadence.delayAfterExchange(sentInput: false, bytesRead: 0) == .milliseconds(10))
        // …capped at 100 ms.
        var capped = TerminalPollCadence()
        var last = Duration.zero
        for _ in 0..<30 { last = capped.delayAfterExchange(sentInput: false, bytesRead: 0) }
        #expect(last == .milliseconds(100))
    }

    @Test("Inactive cadence: stopped/never-opened/exited terminal backs off, busy open stays at the fast re-check")
    func inactiveVsBusyCadence() {
        var cadence = TerminalPollCadence()

        // Transient busy-work (opening/reconnecting or an exchange in flight)
        // keeps the fast 20 ms re-check so the first prompt is not delayed.
        #expect(cadence.delayWhileInactive(opening: true, exchangeInFlight: false) == .milliseconds(20))
        #expect(cadence.delayWhileInactive(opening: false, exchangeInFlight: true) == .milliseconds(20))

        // A genuinely inactive owner (stopped / never opened / exited /
        // disconnected) must NOT spin at the 50 Hz busy rate. It backs off
        // 20, 40, … capped at the pre-cadence idle period of 150 ms (~6.7 Hz).
        #expect(cadence.delayWhileInactive(opening: false, exchangeInFlight: false) == .milliseconds(20))
        #expect(cadence.delayWhileInactive(opening: false, exchangeInFlight: false) == .milliseconds(40))
        #expect(cadence.delayWhileInactive(opening: false, exchangeInFlight: false) == .milliseconds(60))
        var inactiveLast = Duration.zero
        for _ in 0..<20 { inactiveLast = cadence.delayWhileInactive(opening: false, exchangeInFlight: false) }
        #expect(inactiveLast == .milliseconds(150), "inactive terminal must cap at 150 ms, got \(inactiveLast)")

        // A busy round while reconnecting resets the inactive backoff, so once
        // it opens the next disconnect starts with short re-checks again.
        #expect(cadence.delayWhileInactive(opening: true, exchangeInFlight: false) == .milliseconds(20))
        #expect(cadence.delayWhileInactive(opening: false, exchangeInFlight: false) == .milliseconds(20))

        // Going live re-arms the sequence.
        cadence.noteLive()
        #expect(cadence.delayWhileInactive(opening: false, exchangeInFlight: false) == .milliseconds(20))
    }

    /// In-process fake backend with a scripted shell: writes are echoed into
    /// an output queue, reads drain the queue with the request's blocking
    /// window (compressed to keep the test fast; latency ratios are what the
    /// measurement compares, not absolute guest numbers).
    final class MockShellBackend: LocalShellBackend, @unchecked Sendable {
        struct LogEvent: Sendable {
            let kind: String
            let bytes: Int
            let at: ContinuousClock.Instant
        }
        /// Scripted shell state; the mock's protocol methods are all async,
        /// so an actor is the simplest correct protection.
        actor State {
            var queue: [UInt8] = []
            var log: [LogEvent] = []
            var exchangeError: Error?
            func drain(maxBytes: Int) -> [UInt8] {
                let bytes = Array(queue.prefix(maxBytes))
                queue.removeFirst(bytes.count)
                return bytes
            }
            func appendLog(_ event: LogEvent) { log.append(event) }
            func appendOutput(_ bytes: [UInt8]) { queue.append(contentsOf: bytes) }
            func setExchangeError(_ error: Error?) { exchangeError = error }
            func failNextExchange(_ error: Error) { exchangeError = error }
            func clearExchangeError() { exchangeError = nil }
        }
        private let state = State()
        /// Compressed blocking window per exchange (ms).
        var simulatedWaitMs: Int = 5

        func record(_ kind: String, bytes: Int) async {
            await state.appendLog(.init(kind: kind, bytes: bytes, at: .now))
        }
        var events: [LogEvent] {
            get async { await state.log }
        }

        func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
            .exited(code: 0, stdout: "", stderr: "", truncated: false, stderrTruncated: false, durationMs: 0)
        }

        func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
            await record("open", bytes: 0)
            return ShellOpenResult(sessionID: request.sessionID, initialOutput: "", alive: true)
        }

        func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
            if let error = await state.exchangeError { throw error }
            if let input = request.input, !input.isEmpty {
                await record("write", bytes: input.utf8.count)
                // Scripted echo shell: whatever arrives becomes output.
                await state.appendOutput(Array(input.utf8))
            }
            try? await Task.sleep(for: .milliseconds(simulatedWaitMs))
            let chunk: [UInt8] = await state.drain(maxBytes: max(1, min(request.maxBytes, 64 * 1024)))
            await record("read", bytes: chunk.count)
            return ShellExchangeResult(
                output: String(decoding: chunk, as: UTF8.self),
                alive: true,
                terminalOutput: Data(chunk),
                bytesRead: chunk.count,
                bytesWritten: request.input?.utf8.count ?? 0
            )
        }

        func closeSession(sessionID: String) async { await record("close", bytes: 0) }
        func signalSession(sessionID: String, signal: ShellSignal) async { await record("signal:\(signal.rawValue)", bytes: 0) }
        func resizeSession(sessionID: String, columns: Int, rows: Int) async {}

        /// Queues `byteCount` bytes of sustained output (a `cat big.txt`
        /// equivalent) before the next read.
        func scriptOutput(_ byteCount: Int) async {
            await state.appendOutput([UInt8](repeating: UInt8(ascii: "x"), count: byteCount))
        }

        /// Makes the next exchange fail with `error` (cancellation vs genuine).
        func failNextExchange(_ error: Error) async {
            await state.failNextExchange(error)
        }

        func clearExchangeError() async {
            await state.clearExchangeError()
        }
    }

    private func makeOwner(backend: MockShellBackend) -> LocalTerminalOwner {
        makeOwnerAndCenter(backend: backend).0
    }

    /// Returns the owner AND the exact `ShellSessionCenter` that owns its
    /// session, so lifecycle tests can assert the center's session inventory.
    private func makeOwnerAndCenter(backend: MockShellBackend) -> (LocalTerminalOwner, ShellSessionCenter) {
        let center = ShellSessionCenter(backend: backend)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-cadence-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LocalTerminalOwner(root: root, sessions: center), center)
    }

    @Test("Mock backend: a keystroke reaches the shell within one exchange round (owner loop)")
    func inputWriteLatencyThroughOwnerLoop() async throws {
        let backend = MockShellBackend()
        let owner = makeOwner(backend: backend)
        await owner.open()
        guard owner.alive, owner.sessionID != nil else {
            Issue.record("Mock session did not open (environment lease unavailable in this test host)")
            return
        }
        let typedAt = ContinuousClock.now
        owner.enqueue(Data("x".utf8))
        // Run the visible-loop body once: it must flush the pending key
        // without any idle backoff (input present → immediate exchange).
        await owner.pollOnceForTesting()
        let wrote = await backend.events.last { $0.kind == "write" }
        guard let wrote else {
            Issue.record("Pending input was never written to the backend")
            return
        }
        let latency = typedAt.duration(to: wrote.at)
        // One round trip through the (compressed) mock: the assertion bounds
        // the LOOP's added latency, not the mock's own sleep. The old fixed
        // 150 ms poll could not go below 150 ms here by construction.
        #expect(latency < .milliseconds(120), "keystroke write took \(latency) — idle backoff leaked into the input path")
        await owner.close()
    }

    @Test("Mock backend: sustained output drains back-to-back without the fixed 150 ms gaps")
    func sustainedOutputDrainThroughOwnerLoop() async throws {
        let backend = MockShellBackend()
        let owner = makeOwner(backend: backend)
        await owner.open()
        guard owner.alive else {
            Issue.record("Mock session did not open (environment lease unavailable in this test host)")
            return
        }
        await backend.scriptOutput(256 * 1024)
        let start = ContinuousClock.now
        var drained = 0
        while drained < 256 * 1024 {
            await owner.pollOnceForTesting()
            let readEvents = await backend.events.filter { $0.kind == "read" }
            drained = readEvents.reduce(0) { $0 + $1.bytes }
            if start.duration(to: .now) > .seconds(30) {
                Issue.record("Drain stalled at \(drained) bytes"); break
            }
        }
        let elapsed = start.duration(to: .now)
        // 256 KiB over 64 KiB exchanges = ~4 reads. With the old fixed sleep
        // each read carried an extra 150 ms (≥600 ms floor); the cadence
        // path adds ~0 while data flows. The mock's own per-read sleep (5ms)
        // is the only expected cost. Generous bound for scheduler jitter.
        #expect(elapsed < .milliseconds(1_500), "256 KiB drain took \(elapsed)")
        await owner.close()
    }

    @Test("View-loop cancellation is not a disconnect: session survives and resumes")
    func pollCancellationKeepsSessionAlive() async throws {
        let backend = MockShellBackend()
        let (owner, center) = makeOwnerAndCenter(backend: backend)
        await owner.open()
        guard owner.alive, let sessionID = owner.sessionID else {
            Issue.record("Mock session did not open")
            return
        }
        // A cancelled exchange (view loop/panel close) must not kill the shell.
        await backend.failNextExchange(CancellationError())
        await owner.pollOnceForTesting()
        #expect(owner.alive, "cancellation must not mark the live shell dead")
        #expect(owner.sessionID == sessionID, "cancellation must not drop the owned session")
        let afterCancel = await center.activeSessionIDs(runID: owner.id)
        #expect(afterCancel.contains(sessionID),
                "the session center must keep the session after cooperative cancellation")
        // And the same session keeps working afterwards.
        await backend.clearExchangeError()
        owner.enqueue(Data("x".utf8))
        await owner.pollOnceForTesting()
        #expect(owner.alive && owner.sessionID == sessionID)
        await owner.close()
    }

    @Test("A genuine exchange failure still tears the session down")
    func genuineExchangeFailureDisconnects() async throws {
        let backend = MockShellBackend()
        let (owner, center) = makeOwnerAndCenter(backend: backend)
        await owner.open()
        guard owner.alive, let sessionID = owner.sessionID else {
            Issue.record("Mock session did not open")
            return
        }
        await backend.failNextExchange(FloeError.validationFailed("simulated backend failure"))
        await owner.pollOnceForTesting()
        #expect(!owner.alive, "a real backend failure must mark the shell dead")
        let remaining = await center.activeSessionIDs(runID: owner.id)
        #expect(!remaining.contains(sessionID),
                "a real backend failure must close the session in the center")
    }
}
#endif
