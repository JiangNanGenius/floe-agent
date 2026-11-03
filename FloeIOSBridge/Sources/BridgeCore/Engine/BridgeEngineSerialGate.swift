import Foundation

/// One process-wide serialization slot for every XCTest SDK entry the
/// automation engine owns.
///
/// RPC actions acquire it and hold it across awaits, loops and multi-step
/// gestures. Frame capture only tries the slot opportunistically: if an action
/// owns it, the capture returns nil instead of starting a parallel SDK call.
/// A lock-based gate is intentional: `release` must be synchronous so a
/// `defer` can never forget to free the slot while unwinding.
public final class BridgeEngineSerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Waits until the slot is free, then takes ownership. Cancellation is
    /// handled by the caller's dispatch permit, not by silently removing a
    /// waiter: a timed-out queued operation still returns without acting when
    /// it finally reaches the slot.
    public func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !busy {
                busy = true
                lock.unlock()
                continuation.resume()
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    /// Returns false when an action or frame capture already owns the slot.
    public func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !busy else { return false }
        busy = true
        return true
    }

    /// Frees the slot and resumes exactly one waiter, which inherits ownership.
    public func release() {
        lock.lock()
        if waiters.isEmpty {
            busy = false
            lock.unlock()
            return
        }
        let next = waiters.removeFirst()
        lock.unlock()
        next.resume()
    }

    public var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return busy
    }

    public var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    /// Test-only observation: whether a waiter was queued. It reports no
    /// request content.
    public var hasWaiters: Bool {
        waitingCount > 0
    }
}
