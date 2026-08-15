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
    public struct Entry: Sendable, Hashable, Codable {
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

    /// Fixed-capacity ring buffer of the most recent entries. A redacted
    /// snapshot is also written to the app's caches directory so a crash does
    /// not erase the evidence needed for the next-launch diagnostics export.
    /// No transcript, API key, document body, or audio is accepted here.
    public final class RingBuffer: @unchecked Sendable {
        private var entries: [Entry] = []
        private let capacity: Int
        private let lock = NSLock()
        private let persistenceQueue = DispatchQueue(label: "org.floeagent.log-persistence", qos: .utility)
        private var pendingWrite: DispatchWorkItem?
        private let persistedURL: URL?

        public init(capacity: Int = 500, persists: Bool = false) {
            self.capacity = max(1, capacity)
            self.persistedURL = persists ? Self.makePersistedURL() : nil
            if let persistedURL,
               let data = try? Data(contentsOf: persistedURL),
               let restored = try? JSONDecoder().decode([Entry].self, from: data) {
                self.entries = Array(restored.suffix(self.capacity))
            }
        }

        func append(_ entry: Entry) {
            lock.lock()
            entries.append(entry)
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
            let snapshot = entries
            lock.unlock()
            schedulePersistence(snapshot)
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

        private func schedulePersistence(_ snapshot: [Entry]) {
            guard let persistedURL else { return }
            persistenceQueue.async { [weak self] in
                guard let self else { return }
                self.pendingWrite?.cancel()
                let item = DispatchWorkItem {
                    do {
                        try FileManager.default.createDirectory(
                            at: persistedURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        try encoder.encode(snapshot).write(to: persistedURL, options: .atomic)
                    } catch {
                        // Logging must never crash or recursively log a
                        // persistence failure. The in-memory copy remains.
                    }
                }
                self.pendingWrite = item
                self.persistenceQueue.asyncAfter(deadline: .now() + 0.75, execute: item)
            }
        }

        private static func makePersistedURL() -> URL? {
            guard let caches = try? FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ) else { return nil }
            return caches
                .appendingPathComponent("FloeAgent", isDirectory: true)
                .appendingPathComponent("diagnostics-log.json")
        }
    }

    /// Process-wide buffer shared by every logger instance.
    public static let buffer = RingBuffer(persists: true)

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
        let redacted = SecretRedactor.redact(resolved)
        Self.buffer.append(Entry(
            timestamp: Date(), category: category.rawValue, level: "debug",
            message: redacted
        ))
        #if canImport(os)
        underlying.debug("\(redacted, privacy: .public)")
        #endif
    }

    public func info(_ message: @autoclosure () -> String) {
        let resolved = message()
        let redacted = SecretRedactor.redact(resolved)
        Self.buffer.append(Entry(
            timestamp: Date(), category: category.rawValue, level: "info",
            message: redacted
        ))
        #if canImport(os)
        underlying.info("\(redacted, privacy: .public)")
        #endif
    }

    public func warning(_ message: @autoclosure () -> String) {
        let resolved = message()
        let redacted = SecretRedactor.redact(resolved)
        Self.buffer.append(Entry(
            timestamp: Date(), category: category.rawValue, level: "warning",
            message: redacted
        ))
        #if canImport(os)
        underlying.warning("\(redacted, privacy: .public)")
        #endif
    }

    public func error(_ message: @autoclosure () -> String) {
        let resolved = message()
        let redacted = SecretRedactor.redact(resolved)
        Self.buffer.append(Entry(
            timestamp: Date(), category: category.rawValue, level: "error",
            message: redacted
        ))
        #if canImport(os)
        underlying.error("\(redacted, privacy: .public)")
        #endif
    }
}
