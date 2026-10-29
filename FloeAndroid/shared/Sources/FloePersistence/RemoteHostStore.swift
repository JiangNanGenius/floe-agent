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
        vncEndpointJSON: String?,
        deviceKind: String = "unspecified",
        isRemoteExecutionEnvironment: Bool = true,
        vncEndpointsJSON: String? = nil,
        auxiliaryConnectionsJSON: String? = nil
    ) async throws {
        let now = Self.encode(Date())
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO hosts (
                        id, display_name, address, port, user, auth_json,
                        jump_chain_json, host_key_policy, allows_legacy_algorithms,
                        vnc_endpoint_json, device_kind,
                        is_remote_execution_environment, vnc_endpoints_json,
                        auxiliary_connections_json, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                        device_kind = excluded.device_kind,
                        is_remote_execution_environment = excluded.is_remote_execution_environment,
                        vnc_endpoints_json = excluded.vnc_endpoints_json,
                        auxiliary_connections_json = excluded.auxiliary_connections_json,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    id.uuidString, displayName, address, port, user, authJSON,
                    jumpChainJSON, hostKeyPolicy, allowsLegacyAlgorithms,
                    vncEndpointJSON, deviceKind, isRemoteExecutionEnvironment,
                    vncEndpointsJSON, auxiliaryConnectionsJSON, now, now
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

    // MARK: - Host profile reads (for the Hosts UI)

    /// A persisted host row, decoded into the profile field set the UI
    /// needs. Auth/jump/VNC JSON are returned raw for the caller (FloeSSH)
    /// to decode, avoiding a FloePersistence → FloeSSH dependency.
    public struct StoredHost: Sendable, Codable, Hashable, Identifiable {
        public var id: UUID
        public var displayName: String
        public var address: String
        public var port: Int
        public var user: String
        public var authJSON: String
        public var jumpChainJSON: String
        public var hostKeyPolicy: String
        public var allowsLegacyAlgorithms: Bool
        public var vncEndpointJSON: String?
        /// Optional for CloudKit compatibility with records created before v22.
        public var deviceKind: String?
        public var isRemoteExecutionEnvironment: Bool?
        public var vncEndpointsJSON: String?
        public var auxiliaryConnectionsJSON: String?

        public init(
            id: UUID, displayName: String, address: String, port: Int, user: String,
            authJSON: String, jumpChainJSON: String, hostKeyPolicy: String,
            allowsLegacyAlgorithms: Bool, vncEndpointJSON: String?,
            deviceKind: String? = nil,
            isRemoteExecutionEnvironment: Bool? = nil,
            vncEndpointsJSON: String? = nil,
            auxiliaryConnectionsJSON: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.address = address
            self.port = port
            self.user = user
            self.authJSON = authJSON
            self.jumpChainJSON = jumpChainJSON
            self.hostKeyPolicy = hostKeyPolicy
            self.allowsLegacyAlgorithms = allowsLegacyAlgorithms
            self.vncEndpointJSON = vncEndpointJSON
            self.deviceKind = deviceKind
            self.isRemoteExecutionEnvironment = isRemoteExecutionEnvironment
            self.vncEndpointsJSON = vncEndpointsJSON
            self.auxiliaryConnectionsJSON = auxiliaryConnectionsJSON
        }
    }

    /// All hosts in deterministic order (display name, then id).
    public func hosts() async throws -> [StoredHost] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM hosts ORDER BY display_name, id"
            ).map(Self.storedHost(from:))
        }
    }

    /// One host by id.
    public func host(id: UUID) async throws -> StoredHost? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM hosts WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.storedHost(from: row)
        }
    }

    public func saveHost(_ host: StoredHost) async throws {
        try await saveHost(
            id: host.id, displayName: host.displayName, address: host.address,
            port: host.port, user: host.user, authJSON: host.authJSON,
            jumpChainJSON: host.jumpChainJSON, hostKeyPolicy: host.hostKeyPolicy,
            allowsLegacyAlgorithms: host.allowsLegacyAlgorithms,
            vncEndpointJSON: host.vncEndpointJSON,
            deviceKind: host.deviceKind ?? "unspecified",
            isRemoteExecutionEnvironment: host.isRemoteExecutionEnvironment ?? true,
            vncEndpointsJSON: host.vncEndpointsJSON,
            auxiliaryConnectionsJSON: host.auxiliaryConnectionsJSON
        )
    }

    /// Deletes a host; known_hosts and sessions cascade per schema.
    public func deleteHost(id: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM hosts WHERE id = ?", arguments: [id.uuidString])
        }
    }

    private static func storedHost(from row: Row) throws -> StoredHost {
        guard let id = UUID(uuidString: row["id"]) else {
            throw FloeError.storageCorrupted("Invalid host identifier")
        }
        return StoredHost(
            id: id,
            displayName: row["display_name"],
            address: row["address"],
            port: row["port"],
            user: row["user"],
            authJSON: row["auth_json"],
            jumpChainJSON: row["jump_chain_json"],
            hostKeyPolicy: row["host_key_policy"],
            allowsLegacyAlgorithms: row["allows_legacy_algorithms"],
            vncEndpointJSON: row["vnc_endpoint_json"],
            deviceKind: row["device_kind"],
            isRemoteExecutionEnvironment: row["is_remote_execution_environment"],
            vncEndpointsJSON: row["vnc_endpoints_json"],
            auxiliaryConnectionsJSON: row["auxiliary_connections_json"]
        )
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
