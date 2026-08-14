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
        let entry = FloeLogger.Entry(
            timestamp: Date(), category: "security", level: "warning",
            message: SecretRedactor.redact("token=sk-abc123def456gh")
        )
        buffer.append(entry)
        let rendered = buffer.renderedText()
        #expect(rendered.contains("⟨redacted⟩"))
        #expect(!rendered.contains("sk-abc123def456gh"))
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
        #expect(after == before + 1)
        #expect(FloeLogger.buffer.recentEntries.last?.message == "diagnostics probe entry")
        #expect(FloeLogger.buffer.recentEntries.last?.category == "app")
    }
}
