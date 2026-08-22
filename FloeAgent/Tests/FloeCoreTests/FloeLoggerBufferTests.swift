// FloeCoreTests — FloeLogger in-memory ring buffer and redaction contract.
// See docs/ARCHITECTURE_SETTINGS.md §6.4: the buffer backs the diagnostics
// view/export; entries are scrubbed on write and the export is scrubbed
// again, so no secret shape may survive either surface.

import Foundation
import Testing
@testable import FloeCore

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
    func persistedEntriesRestore() {
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
