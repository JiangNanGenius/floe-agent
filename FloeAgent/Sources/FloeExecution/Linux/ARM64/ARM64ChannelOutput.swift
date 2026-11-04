// SPDX-License-Identifier: MPL-2.0
// Pull-based bounded byte pipe. The native worker never waits for a reader.
import Foundation

public enum ARM64ChannelEvent: Sendable, Equatable {
    case consumerTerminated
    case backpressureTimeout(pendingBytes: Int)
    case byteLimitExceeded(pendingBytes: Int)
    case generationDiscarded(droppedBytes: Int)
    case detached
}

final class ARM64ChannelOutput: @unchecked Sendable {
    static let maxElementBytes = 256 * 1024
    static let maxPendingBytes = 8 * 1024 * 1024
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var head = 0
    private var byteCount = 0
    private var delivered = 0
    private var discarded = 0
    private var closed = false
    private var waiter: CheckedContinuation<Data?, Never>?
    private var cachedStream: AsyncStream<Data>?
    private var onEvent: @Sendable (ARM64ChannelEvent) -> Void
    private var onCapacity: @Sendable () -> Void = {}
    private var fullSince: Date?
    let backpressureDeadline: TimeInterval

    init(backpressureDeadline: TimeInterval = 30,
         onEvent: @escaping @Sendable (ARM64ChannelEvent) -> Void) {
        self.backpressureDeadline = backpressureDeadline
        self.onEvent = onEvent
    }

    var stream: AsyncStream<Data> {
        lock.withLock {
            if let cachedStream { return cachedStream }
            let created = AsyncStream<Data>(unfolding: { [weak self] in
                await self?.next()
            }, onCancel: { [weak self] in
                self?.finish(.consumerTerminated)
            })
            cachedStream = created
            return created
        }
    }

    func setCapacityHandler(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { onCapacity = action }
    }
    func setEventForwarder(_ handler: @escaping @Sendable (ARM64ChannelEvent) -> Void) {
        lock.withLock { onEvent = handler }
    }
    var isFinished: Bool { lock.withLock { closed } }
    var pendingByteCount: Int { lock.withLock { byteCount } }
    var discardedBytes: Int { lock.withLock { discarded } }
    var deliveredBytes: Int { lock.withLock { delivered } }

    func hasCapacityFor(_ count: Int) -> Bool {
        let outcome: (Bool, Int?) = lock.withLock {
            guard !closed else { return (false, nil) }
            if count <= Self.maxPendingBytes - byteCount {
                fullSince = nil
                return (true, nil)
            }
            if fullSince == nil { fullSince = Date() }
            return (false, Date().timeIntervalSince(fullSince!) >= backpressureDeadline ? byteCount : nil)
        }
        if let pending = outcome.1 { finish(.backpressureTimeout(pendingBytes: pending)) }
        return outcome.0
    }

    func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        var waiting: CheckedContinuation<Data?, Never>?
        let accepted = lock.withLock {
            guard !closed else { discarded += bytes.count; return false }
            guard bytes.count <= Self.maxPendingBytes - byteCount else { return false }
            if let current = waiter {
                waiter = nil
                waiting = current
                delivered += bytes.count
            } else {
                chunks.append(bytes)
                byteCount += bytes.count
            }
            return true
        }
        if accepted { waiting?.resume(returning: bytes) }
        else if !isFinished { finish(.byteLimitExceeded(pendingBytes: pendingByteCount + bytes.count)) }
    }

    private func next() async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var immediate: Data?
                var shouldResume = false
                var capacity: (@Sendable () -> Void)?
                lock.withLock {
                    if Task.isCancelled || closed {
                        shouldResume = true
                    } else if head < chunks.count {
                        immediate = chunks[head]
                        chunks[head] = Data()
                        head += 1
                        byteCount -= immediate!.count
                        delivered += immediate!.count
                        if head == chunks.count { chunks.removeAll(keepingCapacity: true); head = 0 }
                        else if head >= 256 && head >= chunks.count / 2 {
                            chunks.removeFirst(head); head = 0
                        }
                        fullSince = nil
                        capacity = onCapacity
                        shouldResume = true
                    } else if waiter == nil {
                        waiter = continuation
                    } else {
                        // The transport contract permits one reader only.
                        shouldResume = true
                    }
                }
                if shouldResume { continuation.resume(returning: immediate) }
                capacity?()
            }
        } onCancel: { [weak self] in self?.finish(.consumerTerminated) }
    }

    private func finish(_ event: ARM64ChannelEvent) {
        let state: (CheckedContinuation<Data?, Never>?, (@Sendable (ARM64ChannelEvent) -> Void)?) = lock.withLock {
            guard !closed else { return (nil, nil) }
            closed = true
            discarded += byteCount
            byteCount = 0
            chunks.removeAll(keepingCapacity: false)
            head = 0
            let current = waiter
            waiter = nil
            return (current, onEvent)
        }
        state.0?.resume(returning: nil)
        state.1?(event)
    }
    func abortGeneration() { finish(.generationDiscarded(droppedBytes: pendingByteCount)) }
    func finishDetached() { finish(.detached) }
}
