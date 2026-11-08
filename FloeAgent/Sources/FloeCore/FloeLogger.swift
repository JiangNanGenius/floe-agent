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
    public enum Level: String, CaseIterable, Sendable {
        case debug, info, warning, error

        public func includes(_ level: Level) -> Bool {
            let levels = Self.allCases
            return levels.firstIndex(of: level)! >= levels.firstIndex(of: self)!
        }
    }

    public static let levelPreferenceKey = "diagnostics.minimumLogLevel"

    public static var minimumLevel: Level {
        get { Level(rawValue: UserDefaults.standard.string(forKey: levelPreferenceKey) ?? "") ?? .info }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: levelPreferenceKey) }
    }
    public enum Category: String, Sendable {
        case core, providers, runtime, tools, persistence, security, sync, ssh, vnc, app
        /// Save lifecycle of the provider editor (fixed stages only).
        case providerSave = "provider_save"
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
        public static let defaultCapacity = 2_000

        public enum FlushResult: Equatable, Sendable {
            /// The atomic snapshot write finished successfully.
            case persisted
            /// Persistence is unavailable or the write failed. RAM is retained.
            case notPersisted
            /// Termination could not wait through completion (deadline or
            /// writer-queue reentry); the queued write remains owned.
            case timedOut
        }

        private var entries: [Entry] = []
        private let capacity: Int
        private let lock = NSLock()
        private let persistenceQueue: DispatchQueue
        private let persistenceQueueKey = DispatchSpecificKey<UInt8>()
        // Protected by lock. A blocked writer must not accumulate one queued
        // closure (and one cancelled timer) for every incoming log line.
        private var persistenceRequestEnqueued = false
        private var urgentPersistenceRequested = false
        // Accessed only on persistenceQueue. Routine traffic shares one timer.
        private var delayedWriteScheduled = false
        private var delayedWriteGeneration: UInt64 = 0
        private let persistedURL: URL?

        public convenience init(capacity: Int = RingBuffer.defaultCapacity, persists: Bool = false) {
            self.init(
                capacity: capacity,
                persistedURL: persists ? Self.makePersistedURL() : nil
            )
        }

        init(
            capacity: Int,
            persistedURL: URL?,
            persistenceQueue: DispatchQueue = DispatchQueue(
                label: "org.floeagent.log-persistence", qos: .utility
            )
        ) {
            self.capacity = max(1, capacity)
            self.persistedURL = persistedURL
            self.persistenceQueue = persistenceQueue
            persistenceQueue.setSpecific(key: persistenceQueueKey, value: 1)
            if let persistedURL,
               let data = try? Data(contentsOf: persistedURL) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let restored = try? decoder.decode([Entry].self, from: data) {
                    self.entries = Array(restored.suffix(self.capacity))
                }
            }
        }

        func append(_ entry: Entry) {
            lock.lock()
            entries.append(entry)
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
            lock.unlock()
            // Urgent evidence bypasses the routine delay, but never makes a
            // UI/actor caller wait for the writer, JSON encoding, or disk.
            schedulePersistence(immediately: entry.level == "error" || entry.level == "warning")
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

        /// Enqueues an atomic snapshot including every entry appended before
        /// this request. Completion runs on the writer queue, after the actual
        /// write, not merely after scheduling it. It never recursively logs.
        /// Scene owners should hold their existing short background lease until
        /// completion; cancellation of a waiting task does not discard the write.
        public func flush(completion: @escaping @Sendable (FlushResult) -> Void) {
            guard let persistedURL else {
                completion(.notPersisted)
                return
            }
            persistenceQueue.async {
                // This barrier supersedes the pending routine snapshot. A
                // later append may arm a new timer with a different generation.
                self.delayedWriteScheduled = false
                self.delayedWriteGeneration &+= 1
                completion(Self.write(self.recentEntries, to: persistedURL))
            }
        }

        /// Suspends the caller while the owned write finishes; no thread blocks.
        public func flush() async -> FlushResult {
            await withCheckedContinuation { continuation in
                flush { continuation.resume(returning: $0) }
            }
        }

        /// Last best-effort barrier for applicationWillTerminate only. UIKit
        /// cannot await that callback, and it may never be delivered. Never use
        /// this for ordinary logging or scene transitions. A timeout leaves the
        /// queued write intact and makes no durability claim.
        public func flushBeforeTermination() -> FlushResult {
            let waiter = TerminationWaiter()
            flush { waiter.finish($0) }
            // The logger must not wait on its own serial queue, even briefly.
            guard DispatchQueue.getSpecific(key: persistenceQueueKey) == nil else {
                return .timedOut
            }
            return waiter.wait()
        }

        private func schedulePersistence(immediately: Bool) {
            guard let persistedURL else { return }
            lock.lock()
            urgentPersistenceRequested = urgentPersistenceRequested || immediately
            let shouldEnqueue = !persistenceRequestEnqueued
            persistenceRequestEnqueued = true
            lock.unlock()
            guard shouldEnqueue else { return }
            persistenceQueue.async {
                self.lock.lock()
                let urgent = self.urgentPersistenceRequested
                self.urgentPersistenceRequested = false
                self.persistenceRequestEnqueued = false
                self.lock.unlock()
                if urgent {
                    _ = Self.write(self.recentEntries, to: persistedURL)
                } else if !self.delayedWriteScheduled {
                    self.delayedWriteScheduled = true
                    self.delayedWriteGeneration &+= 1
                    let generation = self.delayedWriteGeneration
                    self.persistenceQueue.asyncAfter(deadline: .now() + 0.75) {
                        guard self.delayedWriteScheduled,
                              self.delayedWriteGeneration == generation else { return }
                        self.delayedWriteScheduled = false
                        // Always take the snapshot on the serial writer. A
                        // routine timer cannot overwrite newer urgent evidence.
                        _ = Self.write(self.recentEntries, to: persistedURL)
                    }
                }
            }
        }

        private final class TerminationWaiter: @unchecked Sendable {
            private let finished = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var result: FlushResult = .timedOut

            func finish(_ result: FlushResult) {
                lock.lock()
                self.result = result
                lock.unlock()
                finished.signal()
            }

            func wait() -> FlushResult {
                guard finished.wait(timeout: .now() + .milliseconds(100)) == .success else {
                    return .timedOut
                }
                lock.lock()
                defer { lock.unlock() }
                return result
            }
        }

        /// The actual write. Failure is intentionally swallowed — logging must
        /// never crash or recursively log a persistence failure.
        private static func write(_ snapshot: [Entry], to url: URL) -> FlushResult {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(snapshot).write(to: url, options: .atomic)
                return .persisted
            } catch {
                return .notPersisted
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
        guard Self.minimumLevel.includes(.debug) else { return }
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
        guard Self.minimumLevel.includes(.info) else { return }
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
        guard Self.minimumLevel.includes(.warning) else { return }
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
