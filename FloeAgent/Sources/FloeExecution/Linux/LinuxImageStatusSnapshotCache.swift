// FloeExecution — service-owned snapshot of a Linux image's composed
// installation status.
//
// Settings, the terminal empty state, the install card and first-use
// preparation all read the same image status, and each read used to hash the
// real image bytes (or at least the expanded view) again. This cache is owned
// by the shared platform service — not by any view — so repeated view
// creation reuses one snapshot instead of repeating the read:
//
//   - ONLY a fully successful read is cached. A cancelled or failed read
//     stores nothing, so an incomplete state can never be marked fresh.
//   - Every mutation (install/remove/repair/re-verify/reconnect) bumps the
//     revision, which drops every entry: the next read re-derives the truth
//     instead of serving a stale snapshot.
//   - A short max age bounds how long an externally changed on-disk state
//     (e.g. bytes replaced while the app was backgrounded) can go unnoticed;
//     the durable verification snapshot underneath still re-checks the file
//     fingerprint (sizes/mtimes/digests) on every real read.

import Foundation

/// A concurrency-safe, revisioned snapshot cache for one image status type.
public final class LinuxImageStatusSnapshotCache<Status: Sendable>: @unchecked Sendable {
    public struct Entry: Sendable {
        public var status: Status
        public var capturedAt: Date
        public init(status: Status, capturedAt: Date) {
            self.status = status
            self.capturedAt = capturedAt
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var revision: UInt64 = 0

    public init() {}

    /// Drops every cached entry. Called by every path that mutates image
    /// state (install, remove, repair, re-verify, backend reconnect), so a
    /// mutation is never followed by a stale snapshot read.
    public func bumpRevision() {
        lock.lock()
        revision &+= 1
        entries.removeAll()
        lock.unlock()
    }

    /// The current revision, for diagnostics and tests.
    public var currentRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    /// A fresh-enough entry, or nil when absent or older than `maxAge`.
    public func cached(id: String, now: Date = Date(), maxAge: TimeInterval) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id], now.timeIntervalSince(entry.capturedAt) <= maxAge else {
            return nil
        }
        return entry
    }

    /// Stores a fully completed read unconditionally. Never call this for a
    /// cancelled or failed read. Prefer `storeIfRevisionUnchanged` for reads
    /// that raced with possible mutations.
    public func store(_ status: Status, id: String, capturedAt: Date = Date()) {
        lock.lock()
        entries[id] = Entry(status: status, capturedAt: capturedAt)
        lock.unlock()
    }

    /// Publishes a completed read ONLY when no mutation bumped the revision
    /// while the read was in flight: a read that started before a mutation
    /// must never repopulate the cache with pre-mutation truth after the
    /// bump. Callers capture the ticket with `currentRevision` before the
    /// read and pass it here at publication time.
    @discardableResult
    public func storeIfRevisionUnchanged(
        _ status: Status, id: String, ticket: UInt64, capturedAt: Date = Date()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revision == ticket else { return false }
        entries[id] = Entry(status: status, capturedAt: capturedAt)
        return true
    }

    /// Reads through the cache. A fresh entry is returned without invoking
    /// `read` (after observing the caller's cancellation signal, so a
    /// superseded refresh keeps its contract of never publishing); otherwise
    /// a revision ticket is taken, `read` runs and — only when it completes
    /// successfully AND no mutation landed while it ran — its result is
    /// cached and returned. A `nil` result (nothing to cache) and a thrown
    /// error are propagated without touching the cache.
    public func status(
        id: String,
        maxAge: TimeInterval,
        isCancelled: (@Sendable () -> Bool)? = nil,
        read: () async throws -> Status?
    ) async throws -> Status? {
        if let entry = cached(id: id, maxAge: maxAge) {
            if isCancelled?() == true { throw CancellationError() }
            return entry.status
        }
        let ticket = currentRevision
        guard let fresh = try await read() else { return nil }
        storeIfRevisionUnchanged(fresh, id: id, ticket: ticket)
        return fresh
    }
}
