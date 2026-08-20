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
        pendingAction: ConfigSyncPendingAction? = nil,
        deletedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.recordType = recordType
        self.recordID = recordID
        self.fieldTimestamps = fieldTimestamps
        self.cloudChangeTag = cloudChangeTag
        self.cloudSystemFields = cloudSystemFields
        self.pendingAction = pendingAction
        self.deletedAt = deletedAt
        self.updatedAt = updatedAt
    }
}

public actor ConfigSyncMetadataStore {
    private let database: DatabaseManager
    private let encoder: JSONEncoder

    public init(database: DatabaseManager) {
        self.database = database
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    public func save(_ metadata: ConfigSyncMetadata) async throws {
        let timestamps = try encoder.encode(metadata.fieldTimestamps)
        guard let timestampsJSON = String(data: timestamps, encoding: .utf8) else {
            throw FloeError.internalError("Could not encode sync field timestamps")
        }
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO config_sync_metadata (
                        record_type, record_id, field_timestamps_json,
                        cloud_change_tag, cloud_system_fields, pending_action, deleted_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(record_type, record_id) DO UPDATE SET
                        field_timestamps_json = excluded.field_timestamps_json,
                        cloud_change_tag = excluded.cloud_change_tag,
                        cloud_system_fields = excluded.cloud_system_fields,
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
                    metadata.pendingAction?.rawValue,
                    Self.encode(metadata.deletedAt),
                    Self.encode(metadata.updatedAt)
                ]
            )
        }
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

    public func remove(recordType: String, recordID: String) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "DELETE FROM config_sync_metadata WHERE record_type = ? AND record_id = ?",
                arguments: [recordType, recordID]
            )
        }
    }

    public func saveEngineState(_ serialization: Data) async throws {
        try await database.writer { db in
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
    }

    public func engineState() async throws -> Data? {
        try await database.reader { db in
            try Data.fetchOne(db, sql: "SELECT serialization FROM sync_engine_state WHERE id = 1")
        }
    }

    private static func decode(_ row: Row) throws -> ConfigSyncMetadata {
        let timestampsJSON: String = row["field_timestamps_json"]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let timestamps = try decoder.decode([String: Date].self, from: Data(timestampsJSON.utf8))
        let pendingRaw: String? = row["pending_action"]
        return ConfigSyncMetadata(
            recordType: row["record_type"],
            recordID: row["record_id"],
            fieldTimestamps: timestamps,
            cloudChangeTag: row["cloud_change_tag"],
            cloudSystemFields: row["cloud_system_fields"],
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
