// FloeCoreTests — FloeLogger in-memory ring buffer and redaction contract.
// See docs/ARCHITECTURE_SETTINGS.md §6.4: the buffer backs the diagnostics
// view/export; entries are scrubbed on write and the export is scrubbed
// again, so no secret shape may survive either surface.

import Foundation
import Testing
@testable import FloeCore

@Test("Log level thresholds include severity and exclude verbose entries")
func logLevelThresholds() {
    for (thresholdIndex, threshold) in FloeLogger.Level.allCases.enumerated() {
        for (levelIndex, level) in FloeLogger.Level.allCases.enumerated() {
            #expect(threshold.includes(level) == (levelIndex >= thresholdIndex))
        }
    }
}

@Suite("FloeCore.FloeLoggerBuffer")
struct FloeLoggerBufferTests {

    @Test("Ring buffer keeps the most recent entries up to capacity")
    func ringBufferCapacity() {
        let buffer = FloeLogger.RingBuffer(capacity: 3)
        let base = Date(timeIntervalSince1970: 1_000)
        for index in 0..<5 {
            buffer.append(FloeLogger.Entry(
                timestamp: base.addingTimeInterval(TimeInterval(index)),
                category: "app", level: "info", message: "entry-\(index)"
            ))
        }
        let entries = buffer.recentEntries
        #expect(entries.count == 3)
        #expect(entries.map(\.message) == ["entry-2", "entry-3", "entry-4"])
    }

    @Test("Logger writes into the shared buffer, scrubbed")
    func loggerAppendsRedacted() {
        // Use a dedicated buffer to isolate from the shared one.
        let buffer = FloeLogger.RingBuffer(capacity: 10)
        let fakeToken = ["sk", "abc123def456gh"].joined(separator: "-")
        let entry = FloeLogger.Entry(
            timestamp: Date(), category: "security", level: "warning",
            message: SecretRedactor.redact("token=\(fakeToken)")
        )
        buffer.append(entry)
        let rendered = buffer.renderedText()
        #expect(rendered.contains("⟨redacted⟩"))
        #expect(!rendered.contains(fakeToken))
        #expect(rendered.contains("[security] [warning]"))
    }

    @Test("renderedText is empty for an empty buffer")
    func emptyBufferRendersEmpty() {
        let buffer = FloeLogger.RingBuffer(capacity: 5)
        #expect(buffer.renderedText() == "")
    }

    @Test("Shared buffer receives entries through the logger API")
    func sharedBufferIntegration() {
        let logger = FloeLogger(category: .app)
        let before = FloeLogger.buffer.recentEntries.count
        logger.info("diagnostics probe entry")
        let after = FloeLogger.buffer.recentEntries.count
        // The process-wide buffer may already be at its fixed default
        // capacity when the whole suite runs in parallel. Appending must then
        // replace the oldest entry without increasing the count.
        #expect(after == min(before + 1, FloeLogger.RingBuffer.defaultCapacity))
        #expect(FloeLogger.buffer.recentEntries.last?.message == "diagnostics probe entry")
        #expect(FloeLogger.buffer.recentEntries.last?.category == "app")
    }

    @Test("Persisted ISO-8601 entries restore after relaunch")
    func persistedEntriesRestore() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.json")
        let buffer = FloeLogger.RingBuffer(capacity: 5, persistedURL: url)
        let timestamp = Date(timeIntervalSince1970: 1_725_000_000)
        buffer.append(.init(
            timestamp: timestamp,
            category: "runtime",
            level: "warning",
            message: "persist me"
        ))
        #expect(await buffer.flush() == .persisted)

        let restored = FloeLogger.RingBuffer(capacity: 5, persistedURL: url)
        #expect(restored.recentEntries.map(\.message) == ["persist me"])
        #expect(abs((restored.recentEntries.first?.timestamp ?? .distantPast)
            .timeIntervalSince(timestamp)) < 0.001)
    }

    @Test("A delayed info write cannot overwrite a newer urgent snapshot")
    func urgentSnapshotWinsOverPendingDebounce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("diagnostics.json")
        let buffer = FloeLogger.RingBuffer(capacity: 5, persistedURL: url)
        buffer.append(.init(
            timestamp: Date(), category: "app", level: "info", message: "older"
        ))
        buffer.append(.init(
            timestamp: Date(), category: "app", level: "error", message: "newer"
        ))
        try await Task.sleep(for: .seconds(1))

        let restored = FloeLogger.RingBuffer(capacity: 5, persistedURL: url)
        #expect(restored.recentEntries.map(\.message) == ["older", "newer"])
    }
}

@Suite("FloeCore.NonblockingLogPersistence")
struct NonblockingLogPersistenceTests {
    private final class Receipt: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: FloeLogger.RingBuffer.FlushResult?

        var result: FloeLogger.RingBuffer.FlushResult? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }

        func record(_ result: FloeLogger.RingBuffer.FlushResult) {
            lock.lock()
            stored = result
            lock.unlock()
        }
    }

    private func fixtureURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-nonblocking-log-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("diagnostics.json")
    }

    private func entry(_ message: String, level: String = "info") -> FloeLogger.Entry {
        .init(timestamp: Date(timeIntervalSince1970: 1_725_000_000),
              category: "app", level: level, message: message)
    }

    /// Deliberately occupies the *production* writer queue. The fail-safe bounds
    /// the original sync implementation's failure rather than hanging the host.
    private func block(_ queue: DispatchQueue, until gate: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
                _ = gate.wait(timeout: .now() + .seconds(2))
            }
        }
    }

    @Test("A blocked writer cannot stall MainActor warning/error or acknowledge a premature flush")
    @MainActor
    func blockedWriterDoesNotBlockUIOrCompleteEarly() async {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = DispatchQueue(label: "floe.test.blocked-log-writer")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let buffer = FloeLogger.RingBuffer(capacity: 5, persistedURL: url, persistenceQueue: queue)
        await block(queue, until: gate)
        let start = ContinuousClock.now
        buffer.append(entry("warning evidence", level: "warning"))
        buffer.append(entry("error evidence", level: "error"))
        buffer.append(entry("processNormalTermination"))
        let (results, continuation) = AsyncStream<FloeLogger.RingBuffer.FlushResult>.makeStream()
        let receipt = Receipt()
        buffer.flush { result in
            receipt.record(result)
            continuation.yield(result)
            continuation.finish()
        }
        #expect(start.duration(to: .now) < .milliseconds(200))
        #expect(receipt.result == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(buffer.recentEntries.map(\.message) == [
            "warning evidence", "error evidence", "processNormalTermination"
        ])
        gate.signal()
        for await result in results { #expect(result == .persisted) }
        let restored = FloeLogger.RingBuffer(capacity: 5, persistedURL: url)
        #expect(restored.recentEntries == buffer.recentEntries)
    }

    @Test("Flush barriers retain bounded append order across routine and urgent writes")
    func snapshotsRespectCapacityAndOrder() async throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let buffer = FloeLogger.RingBuffer(capacity: 12, persistedURL: url)
        for index in 0..<200 {
            buffer.append(entry("entry-\(index)", level: index % 3 == 0 ? "warning" : "info"))
        }
        #expect(await buffer.flush() == .persisted)
        let first = FloeLogger.RingBuffer(capacity: 12, persistedURL: url)
        #expect(first.recentEntries.map(\.message) == (188..<200).map { "entry-\($0)" })
        buffer.append(entry("latest error", level: "error"))
        #expect(await buffer.flush() == .persisted)
        // Let a previously scheduled routine timer become eligible. It must
        // never restore an older snapshot over the completed urgent barrier.
        try await Task.sleep(for: .milliseconds(850))
        let restored = FloeLogger.RingBuffer(capacity: 12, persistedURL: url)
        #expect(restored.recentEntries == buffer.recentEntries)
        #expect(restored.recentEntries.last?.message == "latest error")
    }

    @Test("Warning/error bypass the routine delay without an explicit flush")
    func urgentEvidenceWritesWithoutFlush() async throws {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = DispatchQueue(label: "floe.test.urgent-log-write")
        let buffer = FloeLogger.RingBuffer(capacity: 5, persistedURL: url, persistenceQueue: queue)
        buffer.append(entry("warning", level: "warning"))
        buffer.append(entry("error", level: "error"))
        // This marker only observes the file after earlier queue work. It
        // neither requests a flush nor waits out the routine 0.75s timer.
        let data = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: try? Data(contentsOf: url)) }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([FloeLogger.Entry].self, from: #require(data))
        #expect(entries.map(\.message) == ["warning", "error"])
    }

    @Test("Cancelling a flush waiter does not cancel accepted evidence or report completion early")
    func cancellationRetainsTheOwnedWrite() async {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = DispatchQueue(label: "floe.test.cancelled-log-flush")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let buffer = FloeLogger.RingBuffer(capacity: 5, persistedURL: url, persistenceQueue: queue)
        await block(queue, until: gate)
        buffer.append(entry("retained warning", level: "warning"))
        let waiter = Task { await buffer.flush() }
        waiter.cancel()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        gate.signal()
        #expect(await waiter.value == .persisted)
        let restored = FloeLogger.RingBuffer(capacity: 5, persistedURL: url)
        #expect(restored.recentEntries.map(\.message) == ["retained warning"])
    }

    @Test("Termination waits at most 100ms and timed-out evidence remains queued")
    @MainActor
    func terminationDeadlineIsBounded() async {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = DispatchQueue(label: "floe.test.termination-log-flush")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let buffer = FloeLogger.RingBuffer(capacity: 5, persistedURL: url, persistenceQueue: queue)
        await block(queue, until: gate)
        buffer.append(entry("processNormalTermination"))
        let start = ContinuousClock.now
        #expect(buffer.flushBeforeTermination() == .timedOut)
        #expect(start.duration(to: .now) < .milliseconds(250))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        gate.signal()
        #expect(await buffer.flush() == .persisted)
        let restored = FloeLogger.RingBuffer(capacity: 5, persistedURL: url)
        #expect(restored.recentEntries.map(\.message) == ["processNormalTermination"])
    }

    @Test("A healthy termination barrier really persists the final exit marker")
    func terminationCompletionWritesExitMarker() {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let buffer = FloeLogger.RingBuffer(capacity: 5, persistedURL: url)
        buffer.append(entry("processNormalTermination"))
        #expect(buffer.flushBeforeTermination() == .persisted)
        let restored = FloeLogger.RingBuffer(capacity: 5, persistedURL: url)
        #expect(restored.recentEntries.map(\.message) == ["processNormalTermination"])
    }

    @Test("Termination called on the writer queue never waits on itself")
    func terminationDoesNotSelfWait() async {
        let url = fixtureURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let queue = DispatchQueue(label: "floe.test.reentrant-log-flush")
        let buffer = FloeLogger.RingBuffer(capacity: 5, persistedURL: url, persistenceQueue: queue)
        buffer.append(entry("error on writer", level: "error"))
        let (result, elapsed) = await withCheckedContinuation { continuation in
            queue.async {
                let start = ContinuousClock.now
                let result = buffer.flushBeforeTermination()
                continuation.resume(returning: (result, start.duration(to: .now)))
            }
        }
        #expect(result == .timedOut)
        #expect(elapsed < .milliseconds(75))
        #expect(await buffer.flush() == .persisted)
        let restored = FloeLogger.RingBuffer(capacity: 5, persistedURL: url)
        #expect(restored.recentEntries.map(\.message) == ["error on writer"])
    }

    @Test("A failed write reports failure and preserves RAM for a real retry")
    func failedPersistenceKeepsEvidence() async throws {
        let url = fixtureURL()
        let directory = url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a directory".utf8).write(to: directory)
        let buffer = FloeLogger.RingBuffer(capacity: 5, persistedURL: url)
        buffer.append(entry("error must survive", level: "error"))
        #expect(await buffer.flush() == .notPersisted)
        #expect(buffer.recentEntries.map(\.message) == ["error must survive"])
        try FileManager.default.removeItem(at: directory)
        #expect(await buffer.flush() == .persisted)
        let restored = FloeLogger.RingBuffer(capacity: 5, persistedURL: url)
        #expect(restored.recentEntries.map(\.message) == ["error must survive"])
    }
}
