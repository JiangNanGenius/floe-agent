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
        private let lock = NSLock()
        private var queue: [UInt8] = []
        private(set) var log: [LogEvent] = []
        /// Compressed blocking window per exchange (ms).
        var simulatedWaitMs: Int = 5

        func record(_ kind: String, bytes: Int) {
            lock.lock()
            log.append(.init(kind: kind, bytes: bytes, at: .now))
            lock.unlock()
        }
        var events: [LogEvent] { lock.lock(); defer { lock.unlock() }; return log }

        func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
            .exited(0, "", "", nil, 0, 0)
        }

        func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
            record("open", bytes: 0)
            return ShellOpenResult(sessionID: request.sessionID, initialOutput: "", alive: true)
        }

        func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
            if let input = request.input, !input.isEmpty {
                record("write", bytes: input.utf8.count)
                // Scripted echo shell: whatever arrives becomes output.
                lock.lock(); queue.append(contentsOf: input.utf8); lock.unlock()
            }
            try? await Task.sleep(for: .milliseconds(simulatedWaitMs))
            lock.lock()
            let chunk = Array(queue.prefix(max(1, min(request.maxBytes, 64 * 1024))))
            queue.removeFirst(chunk.count)
            lock.unlock()
            record("read", bytes: chunk.count)
            return ShellExchangeResult(
                output: String(decoding: chunk, as: UTF8.self),
                alive: true,
                terminalOutput: Data(chunk),
                bytesRead: chunk.count,
                bytesWritten: request.input?.utf8.count ?? 0
            )
        }

        func closeSession(sessionID: String) async { record("close", bytes: 0) }
        func signalSession(sessionID: String, signal: ShellSignal) async { record("signal:\(signal.rawValue)", bytes: 0) }
        func resizeSession(sessionID: String, columns: Int, rows: Int) async {}

        /// Queues `byteCount` bytes of sustained output (a `cat big.txt`
        /// equivalent) before the next read.
        func scriptOutput(_ byteCount: Int) {
            lock.lock()
            queue.append(contentsOf: [UInt8](repeating: UInt8(ascii: "x"), count: byteCount))
            lock.unlock()
        }
    }

    private func makeOwner(backend: MockShellBackend) -> LocalTerminalOwner {
        let center = ShellSessionCenter(backend: backend)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-cadence-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return LocalTerminalOwner(root: root, sessions: center)
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
        let wrote = backend.events.last { $0.kind == "write" }
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
        backend.scriptOutput(256 * 1024)
        let start = ContinuousClock.now
        var drained = 0
        while drained < 256 * 1024 {
            await owner.pollOnceForTesting()
            drained = backend.events.filter { $0.kind == "read" }.reduce(0) { $0 + $1.bytes }
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
}
#endif
