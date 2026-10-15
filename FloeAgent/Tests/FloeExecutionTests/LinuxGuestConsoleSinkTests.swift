// FloeExecutionTests — bounded TinyEMU console sink (cold-boot regression).
//
// A real cold boot delivers its console through TWO producers: the guest
// kernel's virtio console (multi-byte chunks) and the OpenSBI HTIF console
// (`Platform Console Device: htif` in the boot log), which prints its banner
// — and prompt/early-console output — ONE BYTE per host callback. The sink
// used to keep at most 256 callback chunks and fail the console closed on the
// first refused chunk; whenever the consumer was briefly descheduled (the
// first boot inside a launching App is exactly that window) an ordinary boot
// banner overflowed it, the stream ended, and the runner's capability
// negotiation failed with `.consoleUnavailable` before the guest could answer.
//
// The sink now buffers BYTES (each delivery is the whole pending prefix), so
// thousands of 1-byte writes coalesce into a handful of elements, and a full
// element buffer parks the producing emulator thread (bounded backpressure,
// abortable at stop) instead of skipping bytes. Only a genuinely stuck
// consumer or a backlog past the byte cap fails the console closed, keeping
// the honest no-silent-loss contract for the shared environment channel.
//
// These regressions drive the production sink directly; the real-VM App test
// (`FloeAppTests/SubagentSimulatorExecutionTests.childGuestShellAndPythonEndToEnd`)
// proves the same path against a real guest boot.

#if canImport(FloeTinyEMU)
import Foundation
import XCTest
@testable import FloeExecution

final class LinuxGuestConsoleSinkTests: XCTestCase {
    /// The bounded console refuses to silently skip bytes: a producer whose
    /// consumer does not drain is parked (backpressure) and only when the
    /// bounded wait expires does the console record the overflow and fail
    /// closed, so every client fails honestly. The accepted prefix is
    /// delivered intact and in order.
    func testConsoleSinkOverflowFailsClosedInsteadOfSilentlyDroppingBytes() {
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(2)) { continuation = $0 }
        let sink = TinyEMUConsoleSink(continuation: continuation)
        // Focused seam: production waits 30 s for a stuck consumer; the test
        // contract is the bounded wait plus the honest overflow, not the
        // duration.
        sink.backpressureDeadline = 0.2
        for index in 0..<5 {
            sink.append(Data("chunk-\(index)".utf8))
        }
        XCTAssertGreaterThan(sink.overflowedChunks, 0, "the refused delivery must be recorded")
        XCTAssertEqual(sink.pendingByteCount, 0, "a failed console retains no refused bytes")

        let collector = StringCollector()
        let expectation = expectation(description: "stream finished")
        let streamCopy = stream
        Task {
            for await chunk in streamCopy {
                collector.append(String(decoding: chunk, as: UTF8.self))
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(collector.values, ["chunk-0", "chunk-1"],
                       "the bounded console keeps the oldest queued bytes and then closes honestly")
    }

    /// A cold boot's console arrives as thousands of ONE-byte writes. The sink
    /// coalesces them into byte prefixes and, while the consumer lags, parks
    /// the producer instead of overflowing — every byte reaches the consumer
    /// exactly once, in order, and no overflow is recorded.
    func testConsoleSinkCoalescesOneByteBootFloodWithALaggingConsumer() {
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(TinyEMUConsoleSink.elementBufferLimit)) {
            continuation = $0
        }
        let sink = TinyEMUConsoleSink(continuation: continuation)
        sink.backpressureDeadline = 10
        let total = 4096
        let producerFinished = expectation(description: "producer finished")
        let producer = Thread {
            for index in 0..<total {
                sink.append(Data([UInt8(index & 0xff)]))
            }
            producerFinished.fulfill()
        }
        producer.stackSize = 256 * 1024
        producer.start()

        var expected = Data()
        for index in 0..<total { expected.append(UInt8(index & 0xff)) }

        let collector = ByteCollector()
        let consumerFinished = expectation(description: "consumer finished")
        Task {
            var delivered = 0
            for await chunk in stream {
                if delivered < 64 {
                    // The lag window that used to overflow a chunk-count bound.
                    try? await Task.sleep(for: .milliseconds(2))
                }
                collector.append(chunk)
                delivered += 1
            }
            consumerFinished.fulfill()
        }
        wait(for: [producerFinished], timeout: 30)
        let drained = waitUntil(timeout: 10) { collector.data.count >= total }
        XCTAssertTrue(drained, "the consumer drains the whole boot flood")
        sink.finish()
        wait(for: [consumerFinished], timeout: 5)
        XCTAssertEqual(collector.data, expected, "every console byte arrives exactly once, in order")
        XCTAssertEqual(sink.overflowedChunks, 0,
                       "a lagging consumer must park the producer, never overflow the console")
    }

    /// A stop unparkes a producer that is waiting on the bounded console (the
    /// emulator thread must leave the callback promptly so the run-loop exit
    /// bound holds), and a restart re-arms the same console stream for the
    /// next boot without recording an overflow.
    func testConsoleSinkAbortUnparksProducerAndRestartRearmsTheStream() {
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(TinyEMUConsoleSink.elementBufferLimit)) {
            continuation = $0
        }
        let sink = TinyEMUConsoleSink(continuation: continuation)
        sink.backpressureDeadline = 30
        let producerFinished = expectation(description: "parked producer returned after abort")
        let producer = Thread {
            for _ in 0..<(TinyEMUConsoleSink.elementBufferLimit + 64) {
                sink.append(Data([0x41]))
            }
            producerFinished.fulfill()
        }
        producer.stackSize = 256 * 1024
        producer.start()
        let parked = waitUntil(timeout: 5) { sink.pendingByteCount > 0 }
        XCTAssertTrue(parked, "the producer parks once the bounded element buffer is full")
        sink.abortWait()
        wait(for: [producerFinished], timeout: 5)
        XCTAssertEqual(sink.overflowedChunks, 0, "a stop is not an overflow")

        sink.resumeAfterStop()
        let collector = ByteCollector()
        let consumerFinished = expectation(description: "consumer finished")
        Task {
            for await chunk in stream { collector.append(chunk) }
            consumerFinished.fulfill()
        }
        sink.append(Data("next-boot".utf8))
        // The elements already enqueued before the abort stay queued for the
        // consumer (accepted bytes are never reordered or lost); the new
        // boot's bytes follow them.
        let rebooted = waitUntil(timeout: 5) {
            collector.data.count >= TinyEMUConsoleSink.elementBufferLimit + 9
        }
        XCTAssertTrue(rebooted, "the re-armed stream serves the next boot")
        sink.finish()
        wait(for: [consumerFinished], timeout: 5)
        XCTAssertEqual(
            collector.data,
            Data(repeating: 0x41, count: TinyEMUConsoleSink.elementBufferLimit)
                + Data("next-boot".utf8)
        )
    }

    // MARK: - helpers

    /// Synchronous bounded poll for the console-sink regressions.
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }
}

/// Thread-safe string collector for the fail-closed regression.
private final class StringCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ value: String) {
        lock.lock()
        items.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// Thread-safe byte collector for the flood/backpressure regressions.
private final class ByteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func append(_ chunk: Data) {
        lock.lock()
        bytes.append(chunk)
        lock.unlock()
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}
#endif
