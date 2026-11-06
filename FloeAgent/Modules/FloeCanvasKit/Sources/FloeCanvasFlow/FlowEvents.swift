import Foundation
import Synchronization
import FloeCanvasCore
import FloeCanvasIntegration

// MARK: - Runtime events
//
// The event stream is the UI's observation channel. It is bounded with
// `.bufferingNewest(capacity)` semantics and in-place coalescing: a slow
// consumer never grows memory without bound, per-node progress floods
// collapse to the latest state, and a terminal event is always delivered.
// Detaching a consumer NEVER cancels the service-owned run.

public enum FlowRunPhase: String, Codable, Hashable, Sendable {
    case running
    case paused
    case stepping
    case waitingReconcile
    case completed
    case failed
    case cancelled
}

public enum FlowRuntimeEvent: Sendable, Hashable {
    case runStarted(runID: UUID, revisionKeyBound: Bool)
    case stepScheduled(runID: UUID, nodeID: UUID, attempt: Int, callPath: String)
    case stepStarted(runID: UUID, nodeID: UUID, attempt: Int, external: Bool)
    case stepCompleted(runID: UUID, nodeID: UUID, attempt: Int, outputs: [String: FlowValue])
    case stepFailed(runID: UUID, nodeID: UUID, attempt: Int, error: String)
    case stepSkipped(runID: UUID, nodeID: UUID, reason: String)
    case conditionSelected(runID: UUID, nodeID: UUID, branchOutputPortID: UUID)
    case loopIteration(runID: UUID, nodeID: UUID, iteration: Int)
    case batchProgress(runID: UUID, nodeID: UUID, completedItems: Int, totalItems: Int)
    case breakpointHit(runID: UUID, nodeID: UUID)
    case paused(runID: UUID)
    case steppingPaused(runID: UUID, completedNodeID: UUID)
    case resumed(runID: UUID)
    case cancelled(runID: UUID)
    case reconcileRequired(runID: UUID, attemptID: UUID, nodeID: UUID)
    case reconciled(runID: UUID, attemptID: UUID, status: String)
    case lateDeliveryRecorded(runID: UUID, attemptID: UUID, nodeID: UUID)
    case checkpointSaved(runID: UUID)
    /// The durable checkpoint could NOT be written. Emitted ONLY on real
    /// journal failure — never paired with a lying `checkpointSaved`. The
    /// run stops scheduling new work (a non-terminal run transitions to
    /// `.failed`); already-submitted attempts stay durable for later
    /// reconcile/adoption. See `FlowRuntimeService.checkpoint`.
    case checkpointFailed(runID: UUID, error: String)
    case runFinished(runID: UUID, phase: FlowRunPhase)

    /// Events that may replace an earlier undelivered event with the same
    /// key (e.g. loop iteration counters).
    public var coalesceKey: String? {
        switch self {
        case .loopIteration(let runID, let nodeID, _):
            return "loop.\(runID.uuidString).\(nodeID.uuidString)"
        case .batchProgress(let runID, let nodeID, _, _):
            return "batch.\(runID.uuidString).\(nodeID.uuidString)"
        default:
            return nil
        }
    }
}

// MARK: - Demand-tracked bounded stream
//
// `FlowEventStream` implements genuine `.bufferingNewest(capacity)`
// semantics: events accumulate in a bounded queue until a consumer awaits
// `next()`, so memory is capped regardless of consumer speed. Overflow
// evicts the oldest NON-terminal event; the terminal `runFinished` is
// always kept and delivered last. Coalescing applies to queued events with
// the same key. `events(runID:)` bridges the stream into an `AsyncStream`
// by forwarding one element per consumer demand, keeping the same bounds.

public final class FlowEventStream: Sendable {
    struct State {
        var queue: [FlowRuntimeEvent] = []
        var coalesceIndexes: [String: Int] = [:]
        var waiter: CheckedContinuation<FlowRuntimeEvent?, Never>?
        var terminated = false
        var deliveredTerminal = false
    }

    private let capacity: Int
    private let state: Mutex<State>

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.state = Mutex(State())
    }

    deinit {
        state.withLock { $0.waiter?.resume(returning: nil) }
    }

    /// Producer entry point. Called by the runtime only.
    func append(_ event: FlowRuntimeEvent, terminal: Bool = false) {
        let waiter = state.withLock { state -> CheckedContinuation<FlowRuntimeEvent?, Never>? in
            guard !state.deliveredTerminal else { return nil }
            if let key = event.coalesceKey, let index = state.coalesceIndexes[key] {
                state.queue[index] = event
            } else {
                state.queue.append(event)
                if let key = event.coalesceKey {
                    state.coalesceIndexes[key] = state.queue.count - 1
                }
            }
            if state.queue.count > self.capacity {
                self.evictOldestNonTerminal(&state)
            }
            if terminal {
                state.terminated = true
            }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            return nil
        }
        // Resume outside the lock.
        waiter?.resume(returning: dequeueForDelivery())
    }

    private func evictOldestNonTerminal(_ state: inout State) {
        while state.queue.count > capacity {
            if let index = state.queue.firstIndex(where: {
                if case .runFinished = $0 { return false }
                return true
            }) {
                state.queue.remove(at: index)
            } else {
                break
            }
            rebuildCoalesceIndexes(&state)
        }
    }

    private func rebuildCoalesceIndexes(_ state: inout State) {
        state.coalesceIndexes.removeAll()
        for (index, event) in state.queue.enumerated() {
            if let key = event.coalesceKey {
                state.coalesceIndexes[key] = index
            }
        }
    }

    /// Consumer entry point: suspends until an event is available, the
    /// stream terminates (returns nil after the terminal event), or the
    /// stream is deallocated.
    public func next() async -> FlowRuntimeEvent? {
        // NOTE: `await` may not appear on the right-hand side of a
        // non-assignment operator (the `??` autoclosure does not support
        // concurrency), so the immediate and suspending paths are sequenced
        // with an explicit three-way switch instead of `?.map { $0 } ??`.
        enum Immediate {
            case event(FlowRuntimeEvent)
            case terminal
            case suspend
        }
        let immediate: Immediate = state.withLock { state in
            if let event = state.queue.first {
                state.queue.removeFirst()
                if let key = event.coalesceKey {
                    state.coalesceIndexes.removeValue(forKey: key)
                }
                if case .runFinished = event {
                    state.deliveredTerminal = true
                }
                return .event(event)
            }
            if state.terminated {
                state.deliveredTerminal = true
                return .terminal
            }
            return .suspend
        }
        switch immediate {
        case .event(let event):
            return event
        case .terminal:
            return nil
        case .suspend:
            return await withCheckedContinuation { continuation in
                state.withLock { state in
                    // Re-check under the lock: append may have raced us.
                    if let event = state.queue.first {
                        state.queue.removeFirst()
                        if let key = event.coalesceKey {
                            state.coalesceIndexes.removeValue(forKey: key)
                        }
                        if case .runFinished = event {
                            state.deliveredTerminal = true
                        }
                        continuation.resume(returning: event)
                    } else if state.terminated {
                        state.deliveredTerminal = true
                        continuation.resume(returning: nil)
                    } else {
                        state.waiter = continuation
                    }
                }
            }
        }
    }

    private func dequeueForDelivery() -> FlowRuntimeEvent? {
        state.withLock { state in
            guard let event = state.queue.first else {
                return state.terminated ? nil : nil
            }
            state.queue.removeFirst()
            if let key = event.coalesceKey {
                state.coalesceIndexes.removeValue(forKey: key)
            }
            if case .runFinished = event {
                state.deliveredTerminal = true
            }
            return event
        }
    }
}
