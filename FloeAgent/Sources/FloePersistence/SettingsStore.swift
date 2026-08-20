// FloePersistence — Generic non-secret app-settings store.
// See docs/ARCHITECTURE_SETTINGS.md §2.1/§3.1. Values are JSON text keyed
// by "<category>.<name>"; secrets and identifiers of secrets never land
// here. Writes are cancellation-safe because GRDB serialises writers.

import Foundation
import GRDB
import FloeCore

/// Durable, non-secret app preferences backed by the `app_settings` table.
/// Values are raw JSON text; typed (Codable) helpers sit on top.
public protocol SettingsStore: Sendable {
    /// Returns the raw JSON text for `key`, or nil when unset.
    func value(forKey key: String) async throws -> String?
    /// Upserts raw JSON text for `key` and bumps `updated_at`.
    func setValue(_ json: String, forKey key: String) async throws
    /// Removes `key`; removing an absent key is a no-op.
    func removeValue(forKey key: String) async throws
    /// All key/value pairs, sorted by key for deterministic reads.
    func allValues() async throws -> [String: String]
}

public extension SettingsStore {
    /// Decodes a Codable value stored under `key`. Returns nil when unset.
    func value<T: Decodable>(forKey key: String, as type: T.Type = T.self) async throws -> T? {
        guard let json = try await value(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: Data(json.utf8))
        } catch {
            throw FloeError.storageCorrupted("Invalid JSON in app_settings['\(key)']")
        }
    }

    /// Encodes and upserts a Codable value under `key`.
    func setValue<T: Encodable & Sendable>(_ value: T, forKey key: String) async throws {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw FloeError.internalError("Could not encode app_settings['\(key)'] as UTF-8")
        }
        try await setValue(json, forKey: key)
    }
}

/// SQLite/GRDB implementation of `SettingsStore`.
public actor SQLiteSettingsStore: SettingsStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func value(forKey key: String) async throws -> String? {
        try await database.reader { db in
            try String.fetchOne(
                db,
                sql: "SELECT value_json FROM app_settings WHERE key = ?",
                arguments: [key]
            )
        }
    }

    public func setValue(_ json: String, forKey key: String) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value_json, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        value_json = excluded.value_json,
                        updated_at = excluded.updated_at
                    """,
                arguments: [key, json, PersistenceCodec.encode(Date())]
            )
        }
    }

    public func removeValue(forKey key: String) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "DELETE FROM app_settings WHERE key = ?",
                arguments: [key]
            )
        }
    }

    public func allValues() async throws -> [String: String] {
        try await database.reader { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT key, value_json FROM app_settings ORDER BY key"
            )
            var values: [String: String] = [:]
            values.reserveCapacity(rows.count)
            for row in rows {
                values[row["key"]] = row["value_json"]
            }
            return values
        }
    }
}
