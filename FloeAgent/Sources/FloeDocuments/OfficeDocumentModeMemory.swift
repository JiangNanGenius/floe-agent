// FloeDocuments — remembers whether one Office document has been opened before.
//
// SPDX-License-Identifier: MPL-2.0
//
// Notes opens an existing/imported Office document as a read-only preview the
// first time it is entered. From the second entry onwards the document opens
// directly in the editor — even when the first visit only looked at the
// preview and never tapped Edit. (A document the user explicitly creates in
// Notes is an authoring action and is handled separately by the App: it opens
// straight in the editor on its first visit.)
//
// The type is Foundation-only, free of UIKit/UserDefaults and holds no file
// contents, so the rule can be unit-tested directly and reused by the App with
// its own persistence. Keys are derived from a workspace/scope identity and the
// document identity; no raw path is ever part of a stored key.

import Foundation

/// The mode a document is opened in.
public enum OfficeDocumentOpenMode: String, Codable, Sendable, CaseIterable {
    /// Read-only preview; the safe default for a document being entered for
    /// the first time.
    case preview
    /// The native editor with its own writable working copy; the default from
    /// a document's second entry onwards.
    case edit
}

/// Pure memory of which Office documents have completed one open. The App
/// supplies the persisted snapshot; this type never touches the filesystem or
/// defaults.
public struct OfficeDocumentModeMemory: Codable, Sendable, Equatable {
    /// Defaults key used by the App-owned store. Kept here so the app wrapper
    /// and any migration probe agree on one name.
    public static let storageKey = "office.document.openMode.v1"

    /// Persisted payload. A version field lets a future change reject unknown
    /// shapes instead of misreading them.
    public struct Snapshot: Codable, Sendable, Equatable {
        public var version: Int = 1
        /// Sorted, de-duplicated keys of documents that finished one open.
        public var seen: [String] = []

        public init(version: Int = 1, seen: [String] = []) {
            self.version = version
            self.seen = seen
        }
    }

    private var seen: Set<String>

    public init() {
        seen = []
    }

    /// Decodes a persisted snapshot. Untrusted or corrupt data degrades to an
    /// empty memory instead of throwing: a broken defaults value must never
    /// prevent a document from opening. Per-entry tolerant: one unreadable
    /// entry drops only itself, while a corrupt envelope or an unknown
    /// snapshot version drops everything.
    public init(data: Data?) {
        guard let data,
              let raw = try? JSONDecoder().decode(LenientSnapshot.self, from: data),
              raw.version == 1 else {
            seen = []
            return
        }
        seen = Set(raw.seen.compactMap { key -> String? in
            let normalized = Self.normalizedKey(key)
            return normalized == Self.emptyKey ? nil : normalized
        })
    }

    /// Tolerant decoding shape: entries stay raw strings so one bad value
    /// cannot invalidate the whole memory.
    private struct LenientSnapshot: Decodable {
        var version: Int
        var seen: [String]
    }

    public var isEmpty: Bool { seen.isEmpty }

    /// Encoded payload for persistence; nil when encoding fails.
    public var snapshotData: Data? {
        try? JSONEncoder().encode(Snapshot(seen: seen.sorted()))
    }

    /// True once the document has completed one open (preview or editor).
    public func hasOpened(forKey key: String) -> Bool {
        seen.contains(Self.normalizedKey(key))
    }

    /// The mode to open with. A document that has never been entered opens in
    /// preview; from the second entry onwards it opens in the editor.
    public func resolvedMode(forKey key: String) -> OfficeDocumentOpenMode {
        hasOpened(forKey: key) ? .edit : .preview
    }

    /// Records that the document finished opening once. A blank key is ignored
    /// rather than written as a catch-all entry.
    public mutating func markOpened(forKey key: String) {
        let normalized = Self.normalizedKey(key)
        guard normalized != Self.emptyKey else { return }
        seen.insert(normalized)
    }

    // MARK: - Keys

    static let emptyKey = "(untitled)"

    /// Bounded key for a document identity. Callers pass a scope (for example a
    /// workspace or Notes notebook identity) plus the document identity; the
    /// same pair always folds to the same key and no raw path is stored.
    public static func scopedKey(scope: String?, document: String) -> String {
        let trimmedScope = (scope ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedScope = trimmedScope.isEmpty ? "unscoped" : trimmedScope
        return "mode-" + stableDigest(resolvedScope + "\u{1F}" + normalizedKey(document))
    }

    /// Bounded, path-free document key. A document identity longer than the
    /// bound is truncated rather than rejected so an over-long name still has
    /// one stable slot.
    public static func normalizedKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return emptyKey }
        return String(trimmed.prefix(240))
    }

    /// Deterministic 64-bit FNV-1a digest, hex encoded. Used only to build a
    /// stable, bounded memory key (not a security hash).
    public static func stableDigest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
