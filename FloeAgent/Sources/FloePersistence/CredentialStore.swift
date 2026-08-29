import Foundation
import GRDB
import FloeCore

public enum CredentialKind: String, Sendable, Codable, CaseIterable, Hashable {
    case providerAPIKey
    case sshPassword
    case sshPrivateKey
    case vncPassword
    case websitePassword
    case genericToken
}

public enum CredentialOwner: Sendable, Codable, Hashable {
    case conversation(UUID)
    case workspace(UUID)
    case vault

    public var kindName: String {
        switch self {
        case .conversation: "conversation"
        case .workspace: "workspace"
        case .vault: "vault"
        }
    }
}

/// Secret-free metadata. The value addressed by `keychainAccount` is never
/// accepted by this type or stored in SQLite.
public struct CredentialRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var kind: CredentialKind
    public var owner: CredentialOwner
    public var hostID: UUID?
    public var origin: String?
    public var label: String
    public var keychainAccount: String
    public var synchronizable: Bool
    public var deviceBound: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), kind: CredentialKind, owner: CredentialOwner,
        hostID: UUID? = nil, origin: String? = nil, label: String,
        keychainAccount: String? = nil, synchronizable: Bool = false,
        deviceBound: Bool = false, createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.owner = owner
        self.hostID = hostID
        self.origin = origin
        self.label = label
        self.keychainAccount = keychainAccount ?? "credential.\(id.uuidString)"
        self.synchronizable = synchronizable
        self.deviceBound = deviceBound
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CredentialDeletionRecord: Sendable, Hashable {
    public var keychainAccount: String
    public var synchronizable: Bool
}

public actor CredentialStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    public func save(_ record: CredentialRecord) async throws {
        try await database.writer { db in
            let conversationID: String?
            let workspaceID: String?
            switch record.owner {
            case .conversation(let id): conversationID = id.uuidString; workspaceID = nil
            case .workspace(let id): conversationID = nil; workspaceID = id.uuidString
            case .vault: conversationID = nil; workspaceID = nil
            }
            try db.execute(sql: """
                INSERT INTO credential_records (
                    id, kind, owner_kind, conversation_id, workspace_id, host_id,
                    origin, label, keychain_account, synchronizable, device_bound,
                    created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    kind = excluded.kind, owner_kind = excluded.owner_kind,
                    conversation_id = excluded.conversation_id,
                    workspace_id = excluded.workspace_id, host_id = excluded.host_id,
                    origin = excluded.origin, label = excluded.label,
                    keychain_account = excluded.keychain_account,
                    synchronizable = excluded.synchronizable,
                    device_bound = excluded.device_bound, updated_at = excluded.updated_at
                """, arguments: [
                    record.id.uuidString, record.kind.rawValue, record.owner.kindName,
                    conversationID, workspaceID, record.hostID?.uuidString, record.origin,
                    record.label, record.keychainAccount, record.synchronizable,
                    record.deviceBound, Self.encode(record.createdAt), Self.encode(record.updatedAt)
                ])
        }
    }

    public func record(id: UUID) async throws -> CredentialRecord? {
        try await database.reader { db in
            try Row.fetchOne(db, sql: "SELECT * FROM credential_records WHERE id = ?", arguments: [id.uuidString])
                .map(Self.decode)
        }
    }

    public func records(owner: CredentialOwner? = nil) async throws -> [CredentialRecord] {
        try await database.reader { db in
            let rows: [Row]
            switch owner {
            case .conversation(let id):
                rows = try Row.fetchAll(db, sql: "SELECT * FROM credential_records WHERE conversation_id = ? ORDER BY updated_at DESC", arguments: [id.uuidString])
            case .workspace(let id):
                rows = try Row.fetchAll(db, sql: "SELECT * FROM credential_records WHERE workspace_id = ? ORDER BY updated_at DESC", arguments: [id.uuidString])
            case .vault:
                rows = try Row.fetchAll(db, sql: "SELECT * FROM credential_records WHERE owner_kind = 'vault' ORDER BY updated_at DESC")
            case nil:
                rows = try Row.fetchAll(db, sql: "SELECT * FROM credential_records ORDER BY updated_at DESC")
            }
            return try rows.map(Self.decode)
        }
    }

    /// A model may create a host and its credential in the same tool call.
    /// Credential normalization runs first, so only attach the optional host
    /// foreign key when that host is already durable.
    public func hostExists(id: UUID) async throws -> Bool {
        try await database.reader { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM hosts WHERE id = ?)",
                arguments: [id.uuidString]
            ) ?? false
        }
    }

    public func delete(id: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM credential_records WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func pendingDeletions() async throws -> [CredentialDeletionRecord] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: "SELECT keychain_account, synchronizable FROM credential_deletion_queue ORDER BY enqueued_at")
                .map { CredentialDeletionRecord(keychainAccount: $0["keychain_account"], synchronizable: $0["synchronizable"]) }
        }
    }

    public func completeDeletion(account: String) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM credential_deletion_queue WHERE keychain_account = ?", arguments: [account])
        }
    }

    public func recordDeletionFailure(account: String, message: String) async throws {
        try await database.writer { db in
            try db.execute(sql: "UPDATE credential_deletion_queue SET last_error = ? WHERE keychain_account = ?", arguments: [SecretRedactor.redact(message), account])
        }
    }

    private static func decode(_ row: Row) throws -> CredentialRecord {
        guard let id = UUID(uuidString: row["id"]),
              let kind = CredentialKind(rawValue: row["kind"]) else {
            throw FloeError.storageCorrupted("Invalid credential metadata")
        }
        let owner: CredentialOwner
        switch row["owner_kind"] as String {
        case "conversation":
            guard let raw: String = row["conversation_id"], let value = UUID(uuidString: raw) else { throw FloeError.storageCorrupted("Invalid credential owner") }
            owner = .conversation(value)
        case "workspace":
            guard let raw: String = row["workspace_id"], let value = UUID(uuidString: raw) else { throw FloeError.storageCorrupted("Invalid credential owner") }
            owner = .workspace(value)
        case "vault": owner = .vault
        default: throw FloeError.storageCorrupted("Invalid credential owner")
        }
        return CredentialRecord(
            id: id, kind: kind, owner: owner,
            hostID: (row["host_id"] as String?).flatMap(UUID.init(uuidString:)),
            origin: row["origin"], label: row["label"], keychainAccount: row["keychain_account"],
            synchronizable: row["synchronizable"], deviceBound: row["device_bound"],
            createdAt: try decodeDate(row["created_at"]), updatedAt: try decodeDate(row["updated_at"])
        )
    }

    private static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func decodeDate(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { throw FloeError.storageCorrupted("Invalid credential date") }
        return date
    }
}
