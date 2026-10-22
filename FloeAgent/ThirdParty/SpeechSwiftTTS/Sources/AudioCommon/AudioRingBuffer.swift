import Foundation
import os

/// Thread-safe ring buffer for passing audio between the audio capture thread and the MLX
/// inference thread. Writes drop oldest data when full; reads return zeros on underrun.
///
/// Uses `os_unfair_lock` for priority inheritance — safe to call `write` from a real-time
/// Core Audio I/O thread without risking priority inversion.
public final class AudioRingBuffer: @unchecked Sendable {
    private var buffer: [Float]
    private var readPos = 0
    private var writePos = 0
    private var count = 0
    private var _lock = os_unfair_lock()
    private let capacity: Int

    public init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    /// Called from audio capture thread — non-blocking; drops oldest data if full.
    public func write(_ samples: [Float]) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        for sample in samples {
            if count == capacity {
                // Drop oldest sample
                readPos = (readPos + 1) % capacity
                count -= 1
            }
            buffer[writePos] = sample
            writePos = (writePos + 1) % capacity
            count += 1
        }
    }

    /// Zero-copy write from a raw pointer — preferred on real-time audio threads
    /// to avoid heap allocation from `Array(UnsafeBufferPointer(...))`.
    public func write(from pointer: UnsafePointer<Float>, count sampleCount: Int) {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        for i in 0..<sampleCount {
            if count == capacity {
                readPos = (readPos + 1) % capacity
                count -= 1
            }
            buffer[writePos] = pointer[i]
            writePos = (writePos + 1) % capacity
            count += 1
        }
    }

    /// Called from MLX inference thread — returns zeros on underrun; never blocks.
    public func read(_ n: Int) -> [Float] {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        var result = [Float](repeating: 0, count: n)
        let available = min(n, count)
        for i in 0..<available {
            result[i] = buffer[(readPos + i) % capacity]
        }
        readPos = (readPos + available) % capacity
        count -= available
        // Remaining positions stay as zero (underrun padding)
        return result
    }

    /// Number of samples currently available to read.
    public var available: Int {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return count
    }
}
