// FloeCore — Logging facade.
//
// Uses os.Logger on platforms that have it; falls back to a no-op otherwise
// so cross-platform targets build everywhere.

import Foundation

#if canImport(os)
import os
#endif

/// Category-tagged logger. Never log secrets: providers redact credentials
/// before constructing log messages.
public struct FloeLogger: Sendable {
    public enum Category: String, Sendable {
        case core, providers, runtime, tools, persistence, security, sync, ssh, vnc, app
    }

    /// One buffered log entry for the diagnostics view / export.
    public struct Entry: Sendable, Hashable {
        public var timestamp: Date
        public var category: String
        public var level: String
        public var message: String

        public init(timestamp: Date, category: String, level: String, message: String) {
            self.timestamp = timestamp
            self.category = category
            self.level = level
            self.message = message
        }
    }

    /// Fixed-capacity in-memory ring buffer of the most recent entries.
    /// Diagnostics reads and exports from here; nothing is written to disk.
    /// Messages are expected to be pre-redacted by callers and are scrubbed
    /// again by `SecretRedactor` on the way in as defense-in-depth.
    public final class RingBuffer: @unchecked Sendable {
        private var entries: [Entry] = []
        private let capacity: Int
        private let lock = NSLock()

        public init(capacity: Int = 500) {
            self.capacity = max(1, capacity)
        }

        func append(_ entry: Entry) {
            lock.lock()
            entries.append(entry)
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
            lock.unlock()
        }

        /// Most recent entries, oldest first.
        public var recentEntries: [Entry] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }

        /// Renders the buffer as redacted plain text for export.
        public func renderedText() -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return recentEntries
                .map { entry in
                    "[\(formatter.string(from: entry.timestamp))] [\(entry.category)] [\(entry.level)] \(entry.message)"
                }
                .joined(separator: "\n")
        }
    }

    /// Process-wide buffer shared by every logger instance.
    public static let buffer = RingBuffer()

    private let category: Category

    #if canImport(os)
    private let underlying: os.Logger
    #endif

    public init(category: Category) {
        self.category = category
        #if canImport(os)
        self.underlying = os.Logger(subsystem: "org.floeagent.ios", category: category.rawValue)
        #endif
    }

    public func debug(_ message: @autoclosure () -> String) {
        let resolved = message()
        Self.buffer.append(Entry(
            timestamp: Date(), category: category.rawValue, level: "debug",
            message: SecretRedactor.redact(resolved)
        ))
        #if canImport(os)
        underlying.debug("\(resolved, privacy: .public)")
        #endif
    }

    public func info(_ message: @autoclosure () -> String) {
        let resolved = message()
        Self.buffer.append(Entry(
            timestamp: Date(), category: category.rawValue, level: "info",
            message: SecretRedactor.redact(resolved)
        ))
        #if canImport(os)
        underlying.info("\(resolved, privacy: .public)")
        #endif
    }

    public func warning(_ message: @autoclosure () -> String) {
        let resolved = message()
        Self.buffer.append(Entry(
            timestamp: Date(), category: category.rawValue, level: "warning",
            message: SecretRedactor.redact(resolved)
        ))
        #if canImport(os)
        underlying.warning("\(resolved, privacy: .public)")
        #endif
    }

    public func error(_ message: @autoclosure () -> String) {
        let resolved = message()
        Self.buffer.append(Entry(
            timestamp: Date(), category: category.rawValue, level: "error",
            message: SecretRedactor.redact(resolved)
        ))
        #if canImport(os)
        underlying.error("\(resolved, privacy: .public)")
        #endif
    }
}
