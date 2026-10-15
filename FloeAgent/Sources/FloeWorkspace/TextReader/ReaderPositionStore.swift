// FloeWorkspace — Durable reading position store (preference-backed).
//
// SPDX-License-Identifier: MPL-2.0
//
// Reading positions live in the same preference domain as every other reader
// setting, keyed by an opaque document identity and tagged with the revision
// fingerprint. A position whose fingerprint no longer matches is never
// restored; the entry is reported as stale instead (the reader then starts
// from the beginning and says so). The store writes only preference data —
// never the document.

import Foundation

public protocol ReaderPositionStoring: Sendable {
    func position(for key: String) -> ReaderPosition?
    func save(_ position: ReaderPosition, for key: String)
    func removePosition(for key: String)
    func removeAll()
}

/// `UserDefaults`-backed store. Keys are opaque (`ReaderDocumentIdentity
/// .storageKey`); values are one JSON dictionary under a single defaults key,
/// pruned to the most recent `maxEntries` positions so the domain cannot grow
/// without bound. The lock makes the read-modify-write cycle atomic.
public final class ReaderUserDefaultsPositionStore: ReaderPositionStoring, @unchecked Sendable {
    public static let defaultsKey = "floe.reader.positions.v1"

    private let defaults: UserDefaults
    private let maxEntries: Int
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, maxEntries: Int = 200) {
        self.defaults = defaults
        self.maxEntries = max(1, maxEntries)
    }

    public func position(for key: String) -> ReaderPosition? {
        lock.lock()
        defer { lock.unlock() }
        return load()[key]
    }

    public func save(_ position: ReaderPosition, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        var entries = load()
        entries[key] = position
        if entries.count > maxEntries {
            let keep = entries
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        persist(entries)
    }

    public func removePosition(for key: String) {
        lock.lock()
        defer { lock.unlock() }
        var entries = load()
        entries.removeValue(forKey: key)
        persist(entries)
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func load() -> [String: ReaderPosition] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: ReaderPosition].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persist(_ entries: [String: ReaderPosition]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// In-memory store for tests and previews.
public final class ReaderMemoryPositionStore: ReaderPositionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: ReaderPosition] = [:]
    public init() {}

    public func position(for key: String) -> ReaderPosition? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]
    }

    public func save(_ position: ReaderPosition, for key: String) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = position
    }

    public func removePosition(for key: String) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: key)
    }

    public func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries = [:]
    }
}
