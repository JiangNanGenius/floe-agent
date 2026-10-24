// SPDX-License-Identifier: MPL-2.0
//
// G04LanguageSettings — DURABLE per-language enabled state for the G04
// language-server center (job-bdebb54ff6ff4403). The enabled/disabled choice
// is a user preference, so it rides the ORIGINAL installed config/preferences
// authority of the SAME accepted Root: the FloePersistence DatabaseManager
// (G02InstalledComposition.cluster.database) and the ONE `app_settings`
// non-secret settings table with its original single-key UPSERT statement.
//
// Deliberately NOT used: UserDefaults/SharedPreferences, a Kotlin-side DB, or
// any second JSON preferences file. Deliberately NOT edited here: the shared
// FloeCore `AppSettingsKey` catalog (a Main-owned file). The store contract is
// an open key namespace — `SettingsStore.swift` ("values are JSON text keyed
// by \"<category>.<name>\"") — and the accepted-adapter precedent
// (RuntimeFacadeSettingsDefaults) proved an adapter can own its own key
// constant and reproduce the original write statement without touching shared
// source. One fixed row, canonical JSON, an in-transaction revision CAS and
// in-transaction read-after-write; a failed write leaves BOTH the durable row
// and the RAM projection at the last persisted value (root-safe rollback).
import Foundation
import GRDB
import FloePersistence

// MARK: - Storage identity (closed)

public enum G04LanguageSettingsRecord {
    /// The ONE app_settings row that holds the language enabled map. Key
    /// format follows the original "<category>.<name>" convention.
    public static let storageKey = "ide.languageServer.enabled"
    /// Schema tag inside the JSON body so a future format change is typed.
    public static let schemaVersion: Int = 1
}

// MARK: - Typed failures

public enum G04LanguageSettingsError: String, Error, Equatable, Sendable {
    /// The language is not in the closed server catalog (whitelist gate).
    case unknownLanguage
    /// The value was not a bool (type gate; callers never coerce).
    case invalidType
    /// The CAS token did not match the persisted row: NOTHING was written.
    case staleRevision
    /// The row exists but is not a decodable record: refused, never
    /// silently reset to defaults over a user's (corrupt) preference.
    case corruptRecord
    /// The durable store itself failed (no composition, no database, or a
    /// transaction fault): the RAM projection keeps the last persisted value.
    case persistenceUnavailable
}

// MARK: - Snapshot

public struct G04LanguageSettingsSnapshot: Sendable, Equatable {
    /// Monotonic in-store revision, the CAS token for every toggle.
    public let revision: Int64
    /// EXACTLY the eight catalog language IDs.
    public let enabled: [String: Bool]

    public init(revision: Int64, enabled: [String: Bool]) {
        self.revision = revision; self.enabled = enabled
    }

    /// All catalog languages enabled (the pre-persistence default).
    public static var defaults: G04LanguageSettingsSnapshot {
        G04LanguageSettingsSnapshot(
            revision: 0,
            enabled: Dictionary(uniqueKeysWithValues: G04LanguageServerCatalog.servers.map { ($0.languageID, true) }))
    }

    public var disabled: Set<String> {
        Set(enabled.compactMap { $0.value ? nil : $0.key })
    }
}

// MARK: - Canonical body

/// Canonical, sorted-key JSON text. Reproducible byte-for-byte from the
/// snapshot so the accepted-adapter digest discipline stays testable.
enum G04LanguageSettingsCodec {
    struct Body: Codable, Sendable {
        let schema: Int
        let revision: Int64
        let enabled: [String: Bool]
    }

    static func encode(_ snapshot: G04LanguageSettingsSnapshot) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Body(schema: G04LanguageSettingsRecord.schemaVersion,
                                           revision: snapshot.revision, enabled: snapshot.enabled))
        guard let text = String(data: data, encoding: .utf8) else {
            throw G04LanguageSettingsError.persistenceUnavailable
        }
        return text
    }

    /// Decodes a stored row STRICTLY: schema, revision, and exactly the
    /// eight catalog IDs with bool values. Anything else is `corruptRecord`
    /// (never treated as "no user choice" so a write cannot bulldoze an
    /// unknown state the app did not author).
    static func decode(_ text: String) throws -> G04LanguageSettingsSnapshot {
        guard let data = text.data(using: .utf8),
              let body = try? JSONDecoder().decode(Body.self, from: data),
              body.schema == G04LanguageSettingsRecord.schemaVersion,
              body.revision >= 0,
              body.enabled.count == G04LanguageServerCatalog.servers.count else {
            throw G04LanguageSettingsError.corruptRecord
        }
        let catalog = Set(G04LanguageServerCatalog.servers.map { $0.languageID })
        guard body.enabled.keys.allSatisfy({ catalog.contains($0) }) else {
            throw G04LanguageSettingsError.corruptRecord
        }
        return G04LanguageSettingsSnapshot(revision: body.revision, enabled: body.enabled)
    }
}

// MARK: - Durable store (ONE original DatabaseManager)

/// The single-row CAS settings backend. Same reviewed shape as the
/// accepted `FacadeSettingsDefaultsAdapter`: the ORIGINAL
/// `SQLiteSettingsStore` single-key UPSERT statement is mirrored verbatim and
/// the ONLY addition is the in-transaction revision gate + changeCount
/// defense, because the generic store exposes no CAS.
public actor G04LanguageSettingsStore {
    private let database: DatabaseManager
    /// Internal, test-only fault seam. It runs INSIDE the writer transaction
    /// so a thrown error proves the REAL rollback; it is never reachable from
    /// a production initializer and never substitutes a store.
    private let faultInjection: (@Sendable () throws -> Void)?

    public init(database: DatabaseManager) {
        self.database = database
        self.faultInjection = nil
    }

    init(database: DatabaseManager, faultInjection: (@Sendable () throws -> Void)?) {
        self.database = database
        self.faultInjection = faultInjection
    }

    // MARK: Read

    public func load() async throws -> G04LanguageSettingsSnapshot {
        let database = self.database
        do {
            return try await database.reader { db in
                guard let raw = try String.fetchOne(
                    db, sql: "SELECT value_json FROM app_settings WHERE key = ?",
                    arguments: [G04LanguageSettingsRecord.storageKey]) else {
                    return G04LanguageSettingsSnapshot.defaults
                }
                return try G04LanguageSettingsCodec.decode(raw)
            }
        } catch let error as G04LanguageSettingsError {
            throw error
        } catch {
            throw G04LanguageSettingsError.persistenceUnavailable
        }
    }

    // MARK: Toggle (CAS)

    /// Applies one whitelist language's bool with an exact-revision CAS and
    /// returns the READ-AFTER-WRITE snapshot (visible only after the real
    /// transaction commit). A stale revision or a fault writes NOTHING; the
    /// row keeps the last committed snapshot byte-for-byte.
    public func toggle(language: String, enabled: Bool,
                       expectedRevision: Int64) async throws -> G04LanguageSettingsSnapshot {
        guard G04LanguageServerCatalog.descriptor(for: language) != nil else {
            throw G04LanguageSettingsError.unknownLanguage
        }
        let database = self.database
        let fault = self.faultInjection
        do {
            return try await database.writer { db in
                let raw = try String.fetchOne(
                    db, sql: "SELECT value_json FROM app_settings WHERE key = ?",
                    arguments: [G04LanguageSettingsRecord.storageKey])
                let current: G04LanguageSettingsSnapshot
                if let raw {
                    current = try G04LanguageSettingsCodec.decode(raw)
                } else {
                    current = .defaults
                }
                // CAS gate decided BEFORE any typed mutation.
                guard current.revision == expectedRevision else {
                    throw G04LanguageSettingsError.staleRevision
                }
                var next = current.enabled
                guard let existing = next[language] else {
                    throw G04LanguageSettingsError.unknownLanguage
                }
                if existing != enabled {
                    next[language] = enabled
                }
                let snapshot = G04LanguageSettingsSnapshot(revision: current.revision &+ 1, enabled: next)
                let json = try G04LanguageSettingsCodec.encode(snapshot)
                try db.execute(sql: Self.upsertSQL,
                               arguments: [G04LanguageSettingsRecord.storageKey, json, Self.timestamp(Date())])
                if let fault { try fault() }
                guard db.changesCount == 1 else {
                    throw G04LanguageSettingsError.staleRevision
                }
                // In-transaction read-after-write: the returned snapshot is
                // what the committed row actually says.
                guard let stored = try String.fetchOne(
                    db, sql: "SELECT value_json FROM app_settings WHERE key = ?",
                    arguments: [G04LanguageSettingsRecord.storageKey]),
                      let verified = try? G04LanguageSettingsCodec.decode(stored),
                      verified == snapshot else {
                    throw G04LanguageSettingsError.persistenceUnavailable
                }
                return verified
            }
        } catch let error as G04LanguageSettingsError {
            throw error
        } catch {
            throw G04LanguageSettingsError.persistenceUnavailable
        }
    }

    // MARK: Original statement (mirrored verbatim; nothing else)

    /// Mirrors SettingsStore.swift:64-73 (INSERT ... ON CONFLICT(key) DO
    /// UPDATE value_json + updated_at), untouched by this adapter.
    private static let upsertSQL = """
        INSERT INTO app_settings (key, value_json, updated_at)
        VALUES (?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            value_json = excluded.value_json,
            updated_at = excluded.updated_at
        """

    /// Reproduces PersistenceCodec.encode exactly (ISO-8601 internet
    /// date-time WITH fractional seconds). PersistenceCodec is internal to
    /// FloePersistence, so this single formatting line is locally reproduced
    /// instead of changing shared source. Write value only; never the CAS
    /// token (the revision inside the JSON is).
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
