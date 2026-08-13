import Foundation
import GRDB
import FloeCore

public struct KnownHostRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var hostID: UUID
    public var address: String
    public var port: Int
    public var keyType: String
    public var fingerprintSHA256: String
    public var firstSeenAt: Date
    public var lastSeenAt: Date

    public init(
        id: UUID = UUID(),
        hostID: UUID,
        address: String,
        port: Int,
        keyType: String,
        fingerprintSHA256: String,
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.hostID = hostID
        self.address = address
        self.port = port
        self.keyType = keyType
        self.fingerprintSHA256 = fingerprintSHA256
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }
}

/// Persistence boundary used by SSH host-key validation. Host profile JSON is
/// supplied by FloeSSH to avoid a dependency cycle.
public actor RemoteHostStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func saveHost(
        id: UUID,
        displayName: String,
        address: String,
        port: Int,
        user: String,
        authJSON: String,
        jumpChainJSON: String,
        hostKeyPolicy: String,
        allowsLegacyAlgorithms: Bool,
        vncEndpointJSON: String?
    ) async throws {
        let now = Self.encode(Date())
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO hosts (
                        id, display_name, address, port, user, auth_json,
                        jump_chain_json, host_key_policy, allows_legacy_algorithms,
                        vnc_endpoint_json, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        display_name = excluded.display_name,
                        address = excluded.address,
                        port = excluded.port,
                        user = excluded.user,
                        auth_json = excluded.auth_json,
                        jump_chain_json = excluded.jump_chain_json,
                        host_key_policy = excluded.host_key_policy,
                        allows_legacy_algorithms = excluded.allows_legacy_algorithms,
                        vnc_endpoint_json = excluded.vnc_endpoint_json,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    id.uuidString, displayName, address, port, user, authJSON,
                    jumpChainJSON, hostKeyPolicy, allowsLegacyAlgorithms,
                    vncEndpointJSON, now, now
                ]
            )
        }
    }

    public func knownHost(address: String, port: Int, keyType: String) async throws -> KnownHostRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM known_hosts
                    WHERE address = ? AND port = ? AND key_type = ?
                    """,
                arguments: [address, port, keyType]
            ) else { return nil }
            return try Self.decode(row)
        }
    }

    public func trust(_ record: KnownHostRecord) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO known_hosts (
                        id, host_id, address, port, key_type, fingerprint_sha256,
                        first_seen_at, last_seen_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(address, port, key_type) DO UPDATE SET
                        host_id = excluded.host_id,
                        fingerprint_sha256 = excluded.fingerprint_sha256,
                        last_seen_at = excluded.last_seen_at
                    """,
                arguments: [
                    record.id.uuidString, record.hostID.uuidString, record.address,
                    record.port, record.keyType, record.fingerprintSHA256,
                    Self.encode(record.firstSeenAt), Self.encode(record.lastSeenAt)
                ]
            )
        }
    }

    public func touch(id: UUID, at date: Date = Date()) async throws {
        try await database.writer { db in
            try db.execute(
                sql: "UPDATE known_hosts SET last_seen_at = ? WHERE id = ?",
                arguments: [Self.encode(date), id.uuidString]
            )
        }
    }

    private static func encode(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func decode(_ row: Row) throws -> KnownHostRecord {
        guard let id = UUID(uuidString: row["id"]),
              let hostID = UUID(uuidString: row["host_id"]),
              let firstSeen = ISO8601DateFormatter().date(from: row["first_seen_at"]),
              let lastSeen = ISO8601DateFormatter().date(from: row["last_seen_at"])
        else { throw FloeError.storageCorrupted("Invalid known-host record") }
        return KnownHostRecord(
            id: id,
            hostID: hostID,
            address: row["address"],
            port: row["port"],
            keyType: row["key_type"],
            fingerprintSHA256: row["fingerprint_sha256"],
            firstSeenAt: firstSeen,
            lastSeenAt: lastSeen
        )
    }
}
