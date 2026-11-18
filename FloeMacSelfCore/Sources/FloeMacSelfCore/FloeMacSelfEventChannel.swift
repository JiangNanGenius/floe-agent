// SPDX-License-Identifier: MPL-2.0
//
// Bounded host-facing event projection. The harness event channel is itself
// `bufferingNewest` with no replay; this wrapper is also newest-bounded and
// adds only factual composition-layer lifecycle events. Consumers MUST
// reconcile with `snapshot()` / durable reads and must never treat a missing
// event as completion.

import Foundation
import FloeAgentRuntime

/// One host-facing event. `.harness` is the exact upstream value; the other
/// cases are factual observations made by this composition layer.
public enum FloeMacSelfSessionEvent: Sendable, Hashable {
    /// Durable launch identities were committed before the run started.
    /// Consumers that attach later read `FloeMacSelfSessionHandle.identity`.
    case prepared(FloeMacSelfSessionIdentity)
    /// The real `ConversationRunService` event, unmodified.
    case harness(HarnessEvent)
    /// The supervisor could not start or complete the runtime start call.
    case startFailed(FloeMacSelfFailure)
    /// The run task returned and the durable terminal state was read back.
    case ended(FloeMacSelfTerminalReceipt)
}

/// Thread-safe multicast channel with a bounded newest-value buffer per
/// subscriber. No event is replayed: a late subscriber starts at the next
/// event. `finish()` is idempotent and drops later yields.
public final class FloeMacSelfSessionEventChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<FloeMacSelfSessionEvent>.Continuation] = [:]
    private var isFinished = false
    private let bufferLimit: Int

    public init(bufferLimit: Int = 256) {
        self.bufferLimit = min(2_048, max(32, bufferLimit))
    }

    public func stream() -> AsyncStream<FloeMacSelfSessionEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(bufferLimit)) { continuation in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.finish()
                return
            }
            continuations[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
        }
    }

    public func yield(_ event: FloeMacSelfSessionEvent) {
        lock.lock()
        let active = Array(continuations.values)
        let finished = isFinished
        lock.unlock()
        guard !finished else { return }
        active.forEach { $0.yield(event) }
    }

    public func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let active = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        active.forEach { $0.finish() }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }
}

/// Records the last upstream terminal event observed on the live stream. It
/// is diagnostics only; durable confirmation always comes from the stores.
final class FloeMacSelfTerminalObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var terminal: HarnessTerminal?

    func record(_ terminal: HarnessTerminal) {
        lock.lock()
        self.terminal = terminal
        lock.unlock()
    }

    var snapshot: HarnessTerminal? {
        lock.lock()
        defer { lock.unlock() }
        return terminal
    }
}
