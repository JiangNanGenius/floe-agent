import Foundation

/// Lossless playback storage. The ring handles normal streaming chunks;
/// overflow retains the caller's arrays until the render consumer catches up.
/// Unlike live capture, generated audio must never discard samples on overflow.
final class PlaybackSampleBuffer: @unchecked Sendable {
    private struct Pending {
        let samples: [Float]
        var offset: Int
    }

    private let lock = NSLock()
    private let ring: AudioSampleRingBuffer
    private var pending: [Pending] = []
    private var head = 0
    private var pendingCount = 0

    init(capacity: Int) {
        ring = AudioSampleRingBuffer(capacity: max(2, capacity))
    }

    var availableToRead: Int {
        lock.lock(); defer { lock.unlock() }
        return ring.availableToRead + pendingCount
    }

    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        // Reclaim consumed arrays on the producer, rather than the render thread.
        let retired = removeConsumed()
        let written = pendingCount == 0 ? ring.write(samples) : 0
        if written < samples.count {
            pending.append(Pending(samples: samples, offset: written))
            pendingCount += samples.count - written
        }
        lock.unlock()
        withExtendedLifetime(retired) { }
    }

    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        var read = ring.read(into: destination, count: count)
        while read < count && head < pending.count {
            let amount = min(count - read, pending[head].samples.count - pending[head].offset)
            pending[head].samples.withUnsafeBufferPointer { source in
                destination.advanced(by: read).update(
                    from: source.baseAddress!.advanced(by: pending[head].offset), count: amount)
            }
            pending[head].offset += amount
            pendingCount -= amount
            read += amount
            if pending[head].offset == pending[head].samples.count { head += 1 }
        }
        return read
    }

    func reset() {
        lock.lock()
        ring.reset()
        let retired = pending
        pending = []
        head = 0
        pendingCount = 0
        lock.unlock()
        withExtendedLifetime(retired) { }
    }

    /// Call off the render thread after playback completes.
    func reclaimConsumed() {
        lock.lock()
        let retired = removeConsumed()
        lock.unlock()
        withExtendedLifetime(retired) { }
    }

    private func removeConsumed() -> [Pending] {
        guard head > 0 else { return [] }
        let retired = Array(pending.prefix(head))
        pending.removeFirst(head)
        head = 0
        return retired
    }
}
