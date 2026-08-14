// FloePersistence — Live remote session registry (SSH terminal / VNC).
// See docs/ALPHA_DAILY_PLAN.md: sessions must report connected/disconnected/
// suspended/unknown honestly and support reconnect after relaunch. This store
// is the durable source of truth for that state.

import Foundation
import GRDB
import FloeCore
import FloeModels

/// Tracks live and recently-live remote sessions so the app can reconnect
/// and represent honest lifecycle state across relaunch.
public protocol RemoteSessionRegistry: Sendable {
    func upsert(_ session: RemoteSessionRecord) async throws
    func session(id: UUID) async throws -> RemoteSessionRecord?
    func sessions(hostID: UUID) async throws -> [RemoteSessionRecord]
    func activeSessions() async throws -> [RemoteSessionRecord]
    func updateState(id: UUID, state: RemoteSessionRecord.State, lastHeartbeatAt: Date?) async throws
    func removeSession(id: UUID) async throws
}

/// SQLite/GRDB implementation of `RemoteSessionRegistry`.
public actor SQLiteRemoteSessionRegistry: RemoteSessionRegistry {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func upsert(_ session: RemoteSessionRecord) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO remote_sessions (
                        id, host_id, kind, state, remote_session_ref,
                        last_heartbeat_at, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        state = excluded.state,
                        remote_session_ref = excluded.remote_session_ref,
                        last_heartbeat_at = excluded.last_heartbeat_at,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    session.id.uuidString,
                    session.hostID.uuidString,
                    session.kind.rawValue,
                    session.state.rawValue,
                    session.remoteSessionRef,
                    session.lastHeartbeatAt.map(PersistenceCodec.encode),
                    PersistenceCodec.encode(session.createdAt),
                    PersistenceCodec.encode(session.updatedAt)
                ]
            )
        }
    }

    public func session(id: UUID) async throws -> RemoteSessionRecord? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM remote_sessions WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.session(from: row)
        }
    }

    public func sessions(hostID: UUID) async throws -> [RemoteSessionRecord] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM remote_sessions WHERE host_id = ? ORDER BY updated_at DESC, id",
                arguments: [hostID.uuidString]
            ).map(Self.session(from:))
        }
    }

    public func activeSessions() async throws -> [RemoteSessionRecord] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM remote_sessions
                    WHERE state IN ('connecting', 'connected', 'suspended')
                    ORDER BY updated_at DESC, id
                    """
            ).map(Self.session(from:))
        }
    }

    public func updateState(
        id: UUID,
        state: RemoteSessionRecord.State,
        lastHeartbeatAt: Date?
    ) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    UPDATE remote_sessions
                    SET state = ?, last_heartbeat_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    state.rawValue,
                    lastHeartbeatAt.map(PersistenceCodec.encode),
                    PersistenceCodec.encode(Date()),
                    id.uuidString
                ]
            )
        }
    }

    public func removeSession(id: UUID) async throws {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM remote_sessions WHERE id = ?", arguments: [id.uuidString])
        }
    }

    private static func session(from row: Row) throws -> RemoteSessionRecord {
        guard
            let id = UUID(uuidString: row["id"]),
            let hostID = UUID(uuidString: row["host_id"]),
            let kind = RemoteSessionRecord.Kind(rawValue: row["kind"]),
            let state = RemoteSessionRecord.State(rawValue: row["state"])
        else {
            throw FloeError.storageCorrupted("Invalid remote session record")
        }
        let heartbeat: Date? = try (row["last_heartbeat_at"] as String?).map(PersistenceCodec.decodeDate)
        return RemoteSessionRecord(
            id: id,
            hostID: hostID,
            kind: kind,
            state: state,
            remoteSessionRef: row["remote_session_ref"],
            lastHeartbeatAt: heartbeat,
            createdAt: try PersistenceCodec.decodeDate(row["created_at"]),
            updatedAt: try PersistenceCodec.decodeDate(row["updated_at"])
        )
    }
}
