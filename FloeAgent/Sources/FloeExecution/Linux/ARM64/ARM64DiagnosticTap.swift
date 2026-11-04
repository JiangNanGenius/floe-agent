// ARM64DiagnosticTap.swift — bounded diagnostics stream with honest
// dropped-diagnostic accounting.
//
// The engine's diagnostic ring is a fixed 64 KiB native buffer; when it
// overflows the engine counts drops (floe_ae_stats.diagnostic_dropped).
// This tap mirrors the console discipline: read only with consumer
// capacity, report local overflow explicitly, and surface the ENGINE's drop
// counter delta as an event so diagnostics loss is reported, never hidden.

import Foundation

public final class ARM64DiagnosticTap: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// The engine dropped diagnostics because its native ring overflowed;
        /// the count delta since the last report is included. Reported at
        /// most once per drain pass.
        case engineDroppedDiagnostics(delta: UInt64)
        case consumerOverflow(droppedBytes: Int)
        /// Buffered diagnostics of the outgoing generation were discarded
        /// (stop/restart). The stream stays live.
        case generationDiscarded(droppedBytes: Int)
        /// The tap was closed locally.
        case closed
    }

    /// Element slots of the bounded diagnostics stream.
    static let elementBufferLimit = 16
    static let maxElementBytes = 64 * 1024
    static let maxPendingBytes = 2 * 1024 * 1024

    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var onEvent: @Sendable (Event) -> Void
    private var pending = Data()
    private var delivering = false
    private var finished = false
    private var aborted = false
    private var lastEngineDropped: UInt64 = 0

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        var captured: AsyncStream<Data>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingOldest(Self.elementBufferLimit)) {
            captured = $0
        }
        self.continuation = captured
        self.onEvent = onEvent
    }

    public func setEventHandler(_ handler: @escaping @Sendable (Event) -> Void) {
        lock.lock()
        onEvent = handler
        lock.unlock()
    }

    private func emit(_ event: Event) {
        lock.lock()
        let handler = onEvent
        lock.unlock()
        handler(event)
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var hasConsumerCapacity: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished && !aborted && pending.count + Self.maxElementBytes <= Self.maxPendingBytes
    }

    // MARK: - Worker-side drain API

    func beginNativeDrain(generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !finished && !aborted
    }

    func appendNativeBytes(_ data: Data, generation: UInt64) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard !finished, !aborted else {
            lock.unlock()
            return
        }
        pending.append(data)
        if pending.count > Self.maxPendingBytes {
            let backlog = pending.count
            pending.removeAll(keepingCapacity: false)
            aborted = true
            finished = true
            lock.unlock()
            emit(.consumerOverflow(droppedBytes: backlog))
            continuation.finish()
            return
        }
        if delivering {
            lock.unlock()
            return
        }
        delivering = true
        lock.unlock()
        deliver()
    }

    func endNativeDrain(engineDroppedDelta: UInt64) {
        if engineDroppedDelta > 0 {
            emit(.engineDroppedDiagnostics(delta: engineDroppedDelta))
        }
    }

    /// Records the engine's cumulative drop counter; returns the delta so
    /// the worker can report it.
    func observeEngineDropped(_ cumulative: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let delta = cumulative >= lastEngineDropped ? cumulative - lastEngineDropped : cumulative
        lastEngineDropped = cumulative
        return delta
    }

    private func deliver() {
        while true {
            lock.lock()
            if finished || aborted || pending.isEmpty {
                delivering = false
                lock.unlock()
                return
            }
            let element = Data(pending.prefix(Self.maxElementBytes))
            lock.unlock()

            switch continuation.yield(element) {
            case .enqueued:
                lock.lock()
                let removeCount = min(element.count, pending.count)
                pending.removeFirst(removeCount)
                lock.unlock()
            case .terminated, .dropped:
                // Diagnostics never hard-fail: a slow/absent consumer stops
                // the stream instead of blocking the worker.
                lock.lock()
                finished = true
                delivering = false
                let backlog = pending.count
                pending.removeAll(keepingCapacity: false)
                lock.unlock()
                if backlog > 0 { emit(.consumerOverflow(droppedBytes: backlog)) }
                continuation.finish()
                return
            @unknown default:
                lock.lock()
                delivering = false
                lock.unlock()
                return
            }
        }
    }

    /// Stop/restart boundary: discard the outgoing generation's buffered
    /// diagnostics; the stream stays live.
    func abortGeneration() {
        lock.lock()
        aborted = true
        let backlog = pending.count
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
        if backlog > 0 {
            emit(.generationDiscarded(droppedBytes: backlog))
        }
    }

    func resumeGeneration() {
        lock.lock()
        aborted = false
        lock.unlock()
    }

    /// Final close by the owner.
    func close() {
        lock.lock()
        let wasFinished = finished
        finished = true
        aborted = true
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
        guard !wasFinished else { return }
        emit(.closed)
        continuation.finish()
    }

    /// The machine worker exited; buffered bytes belong to the ended
    /// generation.
    func machineStopped() { close() }
}
