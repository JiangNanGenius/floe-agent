import Foundation
import GRDB
import FloeCore

public enum ConfigSyncPendingAction: String, Codable, Sendable, Hashable {
    case save
    case delete
}

/// Secret-free synchronization metadata keyed by CloudKit record type and ID.
public struct ConfigSyncMetadata: Codable, Sendable, Hashable, Identifiable {
    public var recordType: String
    public var recordID: String
    public var fieldTimestamps: [String: Date]
    public var cloudChangeTag: String?
    public var cloudSystemFields: Data?
    /// Merged, secret-free remote payload waiting for referenced records.
    public var deferredRemotePayload: Data?
    public var pendingAction: ConfigSyncPendingAction?
    public var deletedAt: Date?
    public var updatedAt: Date

    public var id: String { "\(recordType):\(recordID)" }

    public init(
        recordType: String,
        recordID: String,
        fieldTimestamps: [String: Date] = [:],
        cloudChangeTag: String? = nil,
        cloudSystemFields: Data? = nil,
        deferredRemotePayload: Data? = nil,
        pendingAction: ConfigSyncPendingAction? = nil,
        deletedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.recordType = recordType
        self.recordID = recordID
        self.fieldTimestamps = fieldTimestamps
        self.cloudChangeTag = cloudChangeTag
        self.cloudSystemFields = cloudSystemFields
        self.deferredRemotePayload = deferredRemotePayload
        self.pendingAction = pendingAction
        self.deletedAt = deletedAt
        self.updatedAt = updatedAt
    }
}

public actor ConfigSyncMetadataStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func save(_ metadata: ConfigSyncMetadata) async throws {
        try await database.writer { db in try Self.write(metadata, to: db) }
    }

    // Shared transaction codec: application-setting value and sync metadata
    // must commit together under one GRDB writer/CAS.
    static func write(_ metadata: ConfigSyncMetadata, to db: Database) throws {
        let encoder = JSONEncoder()
        if metadata.recordType != ApplicationSettingRecord.cloudRecordType { encoder.dateEncodingStrategy = .iso8601 }
        let timestamps = try encoder.encode(metadata.fieldTimestamps)
        guard let timestampsJSON = String(data: timestamps, encoding: .utf8) else {
            throw FloeError.internalError("Could not encode sync field timestamps")
        }
        try db.execute(
            sql: """
                INSERT INTO config_sync_metadata (
                    record_type, record_id, field_timestamps_json,
                    cloud_change_tag, cloud_system_fields, deferred_remote_payload,
                    pending_action, deleted_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(record_type, record_id) DO UPDATE SET
                    field_timestamps_json = excluded.field_timestamps_json,
                    cloud_change_tag = excluded.cloud_change_tag,
                    cloud_system_fields = excluded.cloud_system_fields,
                    deferred_remote_payload = excluded.deferred_remote_payload,
                    pending_action = excluded.pending_action,
                    deleted_at = excluded.deleted_at,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                metadata.recordType,
                metadata.recordID,
                timestampsJSON,
                metadata.cloudChangeTag,
                metadata.cloudSystemFields,
                metadata.deferredRemotePayload,
                metadata.pendingAction?.rawValue,
                Self.encode(metadata.deletedAt),
                Self.encode(metadata.updatedAt)
            ]
        )
    }

    public func metadata(recordType: String, recordID: String) async throws -> ConfigSyncMetadata? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM config_sync_metadata WHERE record_type = ? AND record_id = ?",
                arguments: [recordType, recordID]
            ) else { return nil }
            return try Self.decode(row)
        }
    }

    public func pending(limit: Int = 200) async throws -> [ConfigSyncMetadata] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM config_sync_metadata
                    WHERE pending_action IS NOT NULL
                    ORDER BY updated_at, record_type, record_id
                    LIMIT ?
                    """,
                arguments: [max(1, limit)]
            ).map(Self.decode)
        }
    }

    public func deferred(recordType: String, limit: Int = 200) async throws -> [ConfigSyncMetadata] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM config_sync_metadata
                    WHERE record_type = ? AND deferred_remote_payload IS NOT NULL
                    ORDER BY updated_at, record_id
                    LIMIT ?
                    """,
                arguments: [recordType, max(1, limit)]
            ).map(Self.decode)
        }
    }

    public func remove(recordType: String, recordID: String) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "DELETE FROM config_sync_metadata WHERE record_type = ? AND record_id = ?",
                arguments: [recordType, recordID]
            )
        }
    }

    public static let engineStateCatalogKey = "sync.engine-state.catalog.v1"
    private struct EngineStateCatalog: Codable {
        var version = 1
        var supportedRecordTypes: [String]
        var stateSHA256: String
    }

    /// New clients atomically bind the supported decoder catalog to the exact
    /// opaque serialization. An older client may still use the raw overload;
    /// its changed state then invalidates this binding instead of silently
    /// skipping records it did not know how to apply.
    public func saveEngineState(_ serialization: Data, supportedRecordTypes: [String]) async throws {
        let catalog = Array(Set(supportedRecordTypes)).sorted()
        guard !catalog.isEmpty else { throw FloeError.invalidConfiguration("Missing sync record catalog") }
        let value = EngineStateCatalog(supportedRecordTypes: catalog, stateSHA256: FloeDigest.sha256Hex(serialization))
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw FloeError.storageCorrupted("Invalid engine state catalog")
        }
        try await database.writer { db in
            try Self.writeEngineState(serialization, to: db)
            try db.execute(sql: """
                INSERT INTO app_settings(key,value_json,updated_at) VALUES(?,?,?)
                ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at
                """, arguments: [Self.engineStateCatalogKey, json, Self.encode(Date())])
        }
    }

    public func engineState(supportedRecordTypes: [String]) async throws -> Data? {
        let catalog = Array(Set(supportedRecordTypes)).sorted()
        return try await database.reader { db in
            guard !catalog.isEmpty,
                  let state = try Data.fetchOne(db, sql: "SELECT serialization FROM sync_engine_state WHERE id = 1"),
                  let json = try String.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = ?",
                    arguments: [Self.engineStateCatalogKey]),
                  let binding = try? JSONDecoder().decode(EngineStateCatalog.self, from: Data(json.utf8)),
                  binding.version == 1, binding.supportedRecordTypes == catalog,
                  binding.stateSHA256 == FloeDigest.sha256Hex(state) else { return nil }
            return state
        }
    }

    /// Compatibility/raw diagnostic path. Deliberately does not bless a state
    /// with the new catalog: old-client rollback is detectable by the digest.
    public func saveEngineState(_ serialization: Data) async throws {
        try await database.writer { db in try Self.writeEngineState(serialization, to: db) }
    }

    private static func writeEngineState(_ serialization: Data, to db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_engine_state (id, serialization, updated_at)
                VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    serialization = excluded.serialization,
                    updated_at = excluded.updated_at
                """,
            arguments: [serialization, Self.encode(Date())]
        )
    }

    public func engineState() async throws -> Data? {
        try await database.reader { db in
            try Data.fetchOne(db, sql: "SELECT serialization FROM sync_engine_state WHERE id = 1")
        }
    }

    static func decode(_ row: Row) throws -> ConfigSyncMetadata {
        let timestampsJSON: String = row["field_timestamps_json"]
        let decoder = JSONDecoder()
        let recordType: String = row["record_type"]
        if recordType != ApplicationSettingRecord.cloudRecordType { decoder.dateDecodingStrategy = .iso8601 }
        let timestamps = try decoder.decode([String: Date].self, from: Data(timestampsJSON.utf8))
        let pendingRaw: String? = row["pending_action"]
        return ConfigSyncMetadata(
            recordType: row["record_type"],
            recordID: row["record_id"],
            fieldTimestamps: timestamps,
            cloudChangeTag: row["cloud_change_tag"],
            cloudSystemFields: row["cloud_system_fields"],
            deferredRemotePayload: row["deferred_remote_payload"],
            pendingAction: pendingRaw.flatMap(ConfigSyncPendingAction.init(rawValue:)),
            deletedAt: try Self.decode(row["deleted_at"]),
            updatedAt: try Self.decodeRequired(row["updated_at"])
        )
    }

    private static func encode(_ date: Date?) -> String? {
        date.map { ISO8601DateFormatter().string(from: $0) }
    }

    private static func decode(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw FloeError.storageCorrupted("Invalid sync metadata timestamp")
        }
        return date
    }

    private static func decodeRequired(_ value: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw FloeError.storageCorrupted("Invalid sync metadata timestamp")
        }
        return date
    }
}
