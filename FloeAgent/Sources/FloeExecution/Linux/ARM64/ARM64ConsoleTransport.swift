// ARM64ConsoleTransport.swift — the independent per-console byte transport.
//
// One transport per engine channel (0 = PL011, 1...N = virtio-consoles).
// Channels are fully independent: closing ONE console detaches only that
// channel — its stream finishes, its pending generation is fenced — while
// the machine and every sibling channel (other projects, the control
// channel) keep running. Consumer termination or a local stream error is
// surfaced through the owner callback so the owner closes THAT project; the
// transport never stops the machine.

import Foundation

/// The minimal seam a console consumer needs. Intentionally the same shape
/// as the production `LinuxGuestConsoleTransport` (write/close/output) so the
/// later cutover can pass this transport to the existing command channel
/// without an adapter layer.
public protocol ARM64ConsoleByteTransport: Sendable {
    /// Writes the WHOLE frame or throws. A partial engine accept is retained
    /// and retried within the deadline; on stop/detach/cancellation the
    /// remainder is discarded, never executed later.
    func write(_ bytes: [UInt8]) async throws
    /// Detaches THIS console. The machine keeps running.
    func close() async
    /// Console output chunks in order. A single consumer iterates it; it
    /// persists across stop → restart generations and only ends on a
    /// terminal event or close().
    func output() async -> AsyncStream<Data>
}

/// Exactly-once completion token for work enqueued to the machine worker.
/// `claim()` must be called before starting engine side effects; after a
/// successful claim exactly one `resume*` call settles the awaiting task.
/// Cancellation paths never claim: a claimed op always finishes its
/// in-flight engine work and then resumes.
public final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var cancelled = false
    private var started = false
    private var finished = false
    public init(_ continuation: CheckedContinuation<T, Error>? = nil) { self.continuation = continuation }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func attach(_ continuation: CheckedContinuation<T, Error>) {
        let refuse = lock.withLock {
            if cancelled || finished { return true }
            self.continuation = continuation
            return false
        }
        if refuse { continuation.resume(throwing: CancellationError()) }
    }
    public func claim() -> Bool {
        lock.withLock { guard !cancelled, !finished, !started else { return false }; started = true; return true }
    }
    public func cancel(throwing error: Error) {
        let current = lock.withLock { cancelled = true; let value = continuation; continuation = nil; return value }
        current?.resume(throwing: error)
    }
    public func resume() where T == Void { resume(returning: ()) }
    public func resume(returning value: T) {
        let current = lock.withLock { finished = true; let old = continuation; continuation = nil; return old }
        current?.resume(returning: value)
    }
    public func resume(throwing error: Error) {
        let current = lock.withLock { finished = true; let old = continuation; continuation = nil; return old }
        current?.resume(throwing: error)
    }
}

public final class ARM64ConsoleTransport: ARM64ConsoleByteTransport, @unchecked Sendable {
    public let channel: UInt32

    private let pipe: ARM64ChannelOutput
    private let enqueueWrite: @Sendable ([UInt8], UInt64, TimeInterval, ResumeOnce<Void>) -> Void
    private let currentGeneration: @Sendable () -> UInt64
    private let isMachineRunning: @Sendable () -> Bool
    private let wakeWorker: @Sendable () -> Void

    private let lock = NSLock()
    private var detached = false

    /// How long one write may retry a full input ring before failing.
    var consoleWriteDeadline: TimeInterval = 30

    init(
        channel: UInt32,
        enqueueWrite: @escaping @Sendable ([UInt8], UInt64, TimeInterval, ResumeOnce<Void>) -> Void,
        currentGeneration: @escaping @Sendable () -> UInt64,
        isMachineRunning: @escaping @Sendable () -> Bool,
        wakeWorker: @escaping @Sendable () -> Void,
        onEvent: @escaping @Sendable (ARM64ChannelEvent) -> Void
    ) {
        self.channel = channel
        self.enqueueWrite = enqueueWrite
        self.currentGeneration = currentGeneration
        self.isMachineRunning = isMachineRunning
        self.wakeWorker = wakeWorker
        self.pipe = ARM64ChannelOutput(onEvent: onEvent)
        self.pipe.setCapacityHandler(wakeWorker)
    }

    /// Worker-side preferred read granularity per drain pass.
    var preferredReadChunk: Int { 16 * 1024 }

    public func write(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else { return }
        guard !lock.withLock({ detached }) else {
            throw ARM64MachineError.consoleFailed(channel: channel, detail: "console is detached")
        }
        guard isMachineRunning() else { throw ARM64MachineError.notRunning }
        let generation = currentGeneration()
        let result = ResumeOnce<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result.attach(continuation)
                enqueueWrite(bytes, generation, consoleWriteDeadline, result)
            }
        } onCancel: {
            result.cancel(throwing: CancellationError())
            self.wakeWorker()
        }
    }

    public func close() async { detach() }
    private func detach() {
        let already = lock.withLock { let value = detached; detached = true; return value }
        if !already { pipe.finishDetached(); wakeWorker() }
    }
    func inputFailed() { detach() }

    public func output() async -> AsyncStream<Data> {
        pipe.stream
    }

    // MARK: - Worker-side drain API (called only by the machine worker)

    /// True when a drain pass may read native bytes for the current
    /// generation: attached, not finished, and generation matches.
    func beginNativeDrain(generation: UInt64) -> Bool {
        lock.lock()
        let isDetached = detached
        lock.unlock()
        guard !isDetached else { return false }
        guard currentGeneration() == generation else { return false }
        return !pipe.isFinished
    }

    var hasConsumerCapacity: Bool {
        pipe.hasCapacityFor(preferredReadChunk)
    }

    func appendNativeBytes(_ data: Data, generation: UInt64) {
        guard currentGeneration() == generation else { return }
        pipe.append(data)
    }

    func endNativeDrain(totalBytes: Int) {
        // Reserved for per-channel flow-control telemetry.
    }

    /// The machine worker exited (stop or terminal state): fence the current
    /// generation's undelivered bytes. The stream stays live for restart.
    func machineStopped() {
        pipe.abortGeneration()
    }

    func setEventForwarder(_ handler: @escaping @Sendable (ARM64ChannelEvent) -> Void) {
        pipe.setEventForwarder(handler)
    }
}

// Uses the existing command-channel protocol; no parallel execution API.
extension ARM64ConsoleTransport: LinuxGuestConsoleTransport {}
