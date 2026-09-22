// FloeExecution — Runtime v2 durable registry (registry/runtime.sqlite).
//
// One SQLite database in WAL mode owns the transactional relations between
// Conversation, Environment, Workspace, Image, Blob, Lease, Service, Port,
// Queue entry and Migration records. File sidecars (metadata.json,
// delta.header, lease.json, manifest files) exist so a damaged database can be
// repaired by re-scanning verified files — but the database NEVER points at an
// unverified file: an image row only reaches state 'verified' after its blobs
// and expanded tree passed digest verification, and every boot lookup filters
// on that state and re-checks file existence. All mutations run inside
// BEGIN IMMEDIATE transactions with rollback on error. Every applied schema
// migration is also written to registry/migrations/<version>_<name>.sql as an
// audit artifact.

import Foundation
import FloeCore
import SQLite3

public actor RuntimeV2Registry {
    // MARK: row types

    public enum ImageState: String, Sendable { case staged, verified, quarantined }

    public struct ImageRow: Sendable, Equatable {
        public var id: String
        public var manifestPath: String
        public var expandedPath: String?
        public var baseRootfsDigest: String?
        public var state: ImageState
        public var bytes: Int64
        public var quarantineReason: String?
        public var createdAt: Date
        public var verifiedAt: Date?
    }

    public struct BlobRow: Sendable, Equatable {
        public var digest: String
        public var bytes: Int64
        public var refs: Int
        public var createdAt: Date
    }

    public struct EnvironmentRow: Sendable, Equatable {
        public var id: String
        public var kind: String
        public var ownerID: String?
        public var name: String?
        public var baseImageID: String?
        public var baseRootfsDigest: String?
        public var state: String // active | stopped | deleting | repairRequired | interrupted
        public var dataPath: String?
        public var compatHostFHS: Bool
        public var repairReason: String?
        public var createdAt: Date
        public var lastUsedAt: Date
    }

    public struct WorkspaceRow: Sendable, Equatable {
        public var id: String
        public var kind: String // owned | external-ref | scratch
        public var path: String?
        public var bookmark: Data?
        public var displayPath: String?
        public var changeGeneration: Int64
        public var writeSessionOwner: String?
        public var relocationPending: Bool
        public var createdAt: Date
        public var lastUsedAt: Date
    }

    public struct LeaseRow: Sendable, Equatable {
        public var environmentID: String
        public var runtimeID: String
        public var incarnation: String
        public var sessionToken: String
        public var pid: Int64
        public var acquiredAt: Date
        public var renewedAt: Date
        public var ttlSeconds: Int64
        public var state: String // held | stale | released
    }

    public struct QueueRow: Sendable, Equatable {
        public var id: String
        public var environmentID: String
        public var requestedMB: Int
        public var state: String // queued | running | done | cancelled | interrupted
        public var enqueuedAt: Date
        public var startedAt: Date?
        public var finishedAt: Date?
    }

    public enum MigrationPhase: String, Sendable, CaseIterable {
        case discovered, copied, verified, switched, cleanupPending, done, failed
    }

    public struct MigrationRow: Sendable, Equatable {
        public var id: String
        public var kind: String
        public var phase: MigrationPhase
        public var sourcePath: String?
        public var targetPath: String?
        public var detail: String?
        public var error: String?
        public var createdAt: Date
        public var updatedAt: Date
    }

    public struct ServiceRow: Sendable, Equatable {
        public var environmentID: String
        public var name: String
        public var guestPort: Int
        public var proto: String
        public var state: String
    }

    public struct PortRow: Sendable, Equatable {
        public var environmentID: String
        public var hostPort: Int
        public var guestPort: Int
        public var proto: String
        public var runtimeID: String?
        public var state: String // reserved | active | released
    }

    // MARK: database handle

    // The actor remains the sole runtime accessor. `nonisolated(unsafe)` only
    // permits the nonisolated deinitializer to close SQLite on deployment
    // targets that predate isolated deinit support.
    nonisolated(unsafe) private var db: OpaquePointer?
    private let databaseURL: URL
    private let migrationsAuditDirectory: URL
    private var fileManager: FileManager { .default }

    public init(layout: RuntimeV2Layout) {
        self.databaseURL = layout.registryDatabaseURL
        self.migrationsAuditDirectory = layout.registryMigrationsDirectory
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: open + schema

    public func open() throws {
        guard db == nil else { return }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let handle { sqlite3_close_v2(handle) }
            throw RuntimeV2Error.registryCorrupt("cannot open runtime.sqlite: \(message)")
        }
        db = handle
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA busy_timeout=5000")
            try applySchemaMigrations()
        } catch {
            sqlite3_close_v2(handle)
            db = nil
            throw error
        }
    }

    private static let schemaMigrations: [(version: Int, name: String, sql: String)] = [
        (1, "initial", """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL);
        CREATE TABLE images (
          id TEXT PRIMARY KEY,
          manifest_path TEXT NOT NULL,
          expanded_path TEXT,
          base_rootfs_digest TEXT,
          state TEXT NOT NULL,
          bytes INTEGER NOT NULL DEFAULT 0,
          quarantine_reason TEXT,
          created_at TEXT NOT NULL,
          verified_at TEXT
        );
        CREATE TABLE blobs (
          digest TEXT PRIMARY KEY,
          bytes INTEGER NOT NULL,
          refs INTEGER NOT NULL DEFAULT 0,
          state TEXT NOT NULL DEFAULT 'verified',
          created_at TEXT NOT NULL
        );
        CREATE TABLE environments (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          owner_id TEXT,
          name TEXT,
          base_image_id TEXT,
          base_rootfs_digest TEXT,
          state TEXT NOT NULL,
          data_path TEXT,
          compat_host_fhs INTEGER NOT NULL DEFAULT 0,
          repair_reason TEXT,
          created_at TEXT NOT NULL,
          last_used_at TEXT NOT NULL
        );
        CREATE TABLE conversations (
          id TEXT PRIMARY KEY,
          environment_id TEXT REFERENCES environments(id),
          workspace_id TEXT,
          created_at TEXT NOT NULL
        );
        CREATE TABLE workspaces (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          path TEXT,
          bookmark BLOB,
          display_path TEXT,
          change_generation INTEGER NOT NULL DEFAULT 0,
          write_session_owner TEXT,
          relocation_pending INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          last_used_at TEXT NOT NULL
        );
        CREATE TABLE leases (
          environment_id TEXT PRIMARY KEY,
          runtime_id TEXT NOT NULL,
          incarnation TEXT NOT NULL,
          session_token TEXT NOT NULL,
          pid INTEGER NOT NULL,
          acquired_at TEXT NOT NULL,
          renewed_at TEXT NOT NULL,
          ttl_seconds INTEGER NOT NULL,
          state TEXT NOT NULL
        );
        CREATE TABLE services (
          environment_id TEXT NOT NULL,
          name TEXT NOT NULL,
          guest_port INTEGER NOT NULL,
          proto TEXT NOT NULL DEFAULT 'tcp',
          state TEXT NOT NULL DEFAULT 'registered',
          PRIMARY KEY (environment_id, name)
        );
        CREATE TABLE ports (
          environment_id TEXT NOT NULL,
          host_port INTEGER NOT NULL,
          guest_port INTEGER NOT NULL,
          proto TEXT NOT NULL DEFAULT 'tcp',
          runtime_id TEXT,
          state TEXT NOT NULL DEFAULT 'reserved',
          PRIMARY KEY (environment_id, host_port, proto)
        );
        CREATE TABLE queue_entries (
          id TEXT PRIMARY KEY,
          environment_id TEXT NOT NULL,
          requested_mb INTEGER NOT NULL,
          state TEXT NOT NULL,
          enqueued_at TEXT NOT NULL,
          started_at TEXT,
          finished_at TEXT
        );
        CREATE TABLE migrations (
          id TEXT PRIMARY KEY,
          kind TEXT NOT NULL,
          phase TEXT NOT NULL,
          source_path TEXT,
          target_path TEXT,
          detail TEXT,
          error TEXT,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        """)
    ]

    private func applySchemaMigrations() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL
        )
        """)
        let applied = Set(try query("SELECT version FROM schema_migrations") { statement in
            Int(sqlite3_column_int(statement, 0))
        })
        for migration in RuntimeV2Registry.schemaMigrations where !applied.contains(migration.version) {
            try transaction {
                try execute(migration.sql)
                try run(
                    "INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?)",
                    bind: { statement in
                        sqlite3_bind_int(statement, 1, Int32(migration.version))
                        Self.bindText(migration.name, to: statement, index: 2)
                        Self.bindText(Self.iso(Date()), to: statement, index: 3)
                    }
                )
            }
            // Audit artifact: the applied SQL is preserved next to the
            // database so a damaged DB can be rebuilt by replaying them.
            let audit = migrationsAuditDirectory.appendingPathComponent(
                String(format: "%04d_%@.sql", migration.version, migration.name)
            )
            if !fileManager.fileExists(atPath: audit.path) {
                try? migration.sql.write(to: audit, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: sqlite helpers

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private static func bindText(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private static func bindOptionalText(_ value: String?, to statement: OpaquePointer?, index: Int32) {
        if let value { Self.bindText(value, to: statement, index: index) } else { sqlite3_bind_null(statement, index) }
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(error)
            throw RuntimeV2Error.registryCorrupt(message)
        }
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RuntimeV2Error.registryCorrupt(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw RuntimeV2Error.registryCorrupt(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil, map: (OpaquePointer?) -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RuntimeV2Error.registryCorrupt(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        bind?(statement)
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rows.append(map(statement))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw RuntimeV2Error.registryCorrupt(String(cString: sqlite3_errmsg(db)))
            }
        }
        return rows
    }

    private func query<T>(_ sql: String, _ map: (OpaquePointer?) -> T) throws -> [T] {
        try query(sql, bind: nil, map: map)
    }

    private func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: images (the database never points at unverified files)

    /// Registers a freshly staged image. The row starts in `staged` state;
    /// `markImageVerified` is the only path to `verified`, called by the image
    /// store after every blob and the expanded tree passed digest checks.
    public func registerStagedImage(id: String, manifestPath: String, bytes: Int64) throws {
        try transaction {
            try run(
                """
                INSERT INTO images (id, manifest_path, state, bytes, created_at)
                VALUES (?, ?, 'staged', ?, ?)
                ON CONFLICT(id) DO UPDATE SET manifest_path=excluded.manifest_path,
                  state=CASE WHEN images.state='quarantined' THEN images.state ELSE 'staged' END,
                  bytes=excluded.bytes, verified_at=NULL
                """,
                bind: { statement in
                    Self.bindText(id, to: statement, index: 1)
                    Self.bindText(manifestPath, to: statement, index: 2)
                    sqlite3_bind_int64(statement, 3, bytes)
                    Self.bindText(Self.iso(Date()), to: statement, index: 4)
                }
            )
        }
    }

    public func markImageVerified(id: String, expandedPath: String, baseRootfsDigest: String) throws {
        try transaction {
            try run(
                """
                UPDATE images SET state='verified', expanded_path=?, base_rootfs_digest=?,
                  verified_at=?, quarantine_reason=NULL
                WHERE id=? AND state != 'quarantined'
                """,
                bind: { statement in
                    Self.bindText(expandedPath, to: statement, index: 1)
                    Self.bindText(baseRootfsDigest, to: statement, index: 2)
                    Self.bindText(Self.iso(Date()), to: statement, index: 3)
                    Self.bindText(id, to: statement, index: 4)
                }
            )
        }
    }

    public func quarantineImage(id: String, reason: String) throws {
        try transaction {
            try run(
                "UPDATE images SET state='quarantined', quarantine_reason=?, verified_at=NULL WHERE id=?",
                bind: { statement in
                    Self.bindText(reason, to: statement, index: 1)
                    Self.bindText(id, to: statement, index: 2)
                }
            )
        }
    }

    public func image(id: String) throws -> ImageRow? {
        try query("SELECT id, manifest_path, expanded_path, base_rootfs_digest, state, bytes, quarantine_reason, created_at, verified_at FROM images WHERE id=?", bind: { statement in
            Self.bindText(id, to: statement, index: 1)
        }) { statement in
            ImageRow(
                id: text(statement, 0) ?? "",
                manifestPath: text(statement, 1) ?? "",
                expandedPath: text(statement, 2),
                baseRootfsDigest: text(statement, 3),
                state: ImageState(rawValue: text(statement, 4) ?? "") ?? .staged,
                bytes: sqlite3_column_int64(statement, 5),
                quarantineReason: text(statement, 6),
                createdAt: Self.date(text(statement, 7)) ?? Date.distantPast,
                verifiedAt: Self.date(text(statement, 8))
            )
        }.first
    }

    /// The only lookup the boot path may use: a verified row whose manifest
    /// file still exists on disk. Anything else is not bootable, whatever the
    /// row claims.
    public func bootableImage(id: String, root: URL) throws -> ImageRow? {
        guard let row = try image(id: id), row.state == .verified else { return nil }
        let manifest = root.appendingPathComponent(row.manifestPath)
        guard fileManager.fileExists(atPath: manifest.path) else { return nil }
        return row
    }

    public func images(state: ImageState) throws -> [ImageRow] {
        try query("SELECT id FROM images WHERE state=? ORDER BY id", bind: { statement in
            Self.bindText(state.rawValue, to: statement, index: 1)
        }) { statement in
            text(statement, 0) ?? ""
        }.compactMap { try image(id: $0) }
    }

    // MARK: blobs (reference-counted; GC never collects referenced data)

    public func recordBlob(digest: String, bytes: Int64) throws {
        try transaction {
            try run(
                """
                INSERT INTO blobs (digest, bytes, refs, created_at) VALUES (?, ?, 0, ?)
                ON CONFLICT(digest) DO NOTHING
                """,
                bind: { statement in
                    Self.bindText(digest, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, bytes)
                    Self.bindText(Self.iso(Date()), to: statement, index: 3)
                }
            )
        }
    }

    public func adjustBlobRefs(digest: String, delta: Int) throws {
        try transaction {
            try run(
                "UPDATE blobs SET refs = MAX(0, refs + ?) WHERE digest=?",
                bind: { statement in
                    sqlite3_bind_int(statement, 1, Int32(delta))
                    Self.bindText(digest, to: statement, index: 2)
                }
            )
        }
    }

    public func blob(digest: String) throws -> BlobRow? {
        try query("SELECT digest, bytes, refs, created_at FROM blobs WHERE digest=?", bind: { statement in
            Self.bindText(digest, to: statement, index: 1)
        }) { statement in
            BlobRow(
                digest: text(statement, 0) ?? "",
                bytes: sqlite3_column_int64(statement, 1),
                refs: Int(sqlite3_column_int(statement, 2)),
                createdAt: Self.date(text(statement, 3)) ?? Date.distantPast
            )
        }.first
    }

    public func unreferencedBlobs(olderThan cutoff: Date) throws -> [BlobRow] {
        try query("SELECT digest, bytes, refs, created_at FROM blobs WHERE refs=0 AND created_at < ?", bind: { statement in
            Self.bindText(Self.iso(cutoff), to: statement, index: 1)
        }) { statement in
            BlobRow(
                digest: text(statement, 0) ?? "",
                bytes: sqlite3_column_int64(statement, 1),
                refs: Int(sqlite3_column_int(statement, 2)),
                createdAt: Self.date(text(statement, 3)) ?? Date.distantPast
            )
        }
    }

    public func removeBlobRecord(digest: String) throws {
        try transaction {
            try run("DELETE FROM blobs WHERE digest=? AND refs=0", bind: { statement in
                Self.bindText(digest, to: statement, index: 1)
            })
        }
    }

    public func blobStats() throws -> (count: Int, bytes: Int64, referencedBytes: Int64) {
        let rows: [(Int, Int64, Int64)] = try query(
            "SELECT COUNT(*), COALESCE(SUM(bytes),0), COALESCE(SUM(CASE WHEN refs>0 THEN bytes ELSE 0 END),0) FROM blobs"
        ) { statement in
            (Int(sqlite3_column_int(statement, 0)), sqlite3_column_int64(statement, 1), sqlite3_column_int64(statement, 2))
        }
        return rows.first ?? (0, 0, 0)
    }

    // MARK: environments

    public func upsertEnvironment(_ row: EnvironmentRow) throws {
        try transaction {
            try run(
                """
                INSERT INTO environments (id, kind, owner_id, name, base_image_id, base_rootfs_digest,
                  state, data_path, compat_host_fhs, repair_reason, created_at, last_used_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, owner_id=excluded.owner_id,
                  name=excluded.name, base_image_id=excluded.base_image_id,
                  base_rootfs_digest=excluded.base_rootfs_digest, state=excluded.state,
                  data_path=excluded.data_path, compat_host_fhs=excluded.compat_host_fhs,
                  repair_reason=excluded.repair_reason, last_used_at=excluded.last_used_at
                """,
                bind: { statement in
                    Self.bindText(row.id, to: statement, index: 1)
                    Self.bindText(row.kind, to: statement, index: 2)
                    Self.bindOptionalText(row.ownerID, to: statement, index: 3)
                    Self.bindOptionalText(row.name, to: statement, index: 4)
                    Self.bindOptionalText(row.baseImageID, to: statement, index: 5)
                    Self.bindOptionalText(row.baseRootfsDigest, to: statement, index: 6)
                    Self.bindText(row.state, to: statement, index: 7)
                    Self.bindOptionalText(row.dataPath, to: statement, index: 8)
                    sqlite3_bind_int(statement, 9, row.compatHostFHS ? 1 : 0)
                    Self.bindOptionalText(row.repairReason, to: statement, index: 10)
                    Self.bindText(Self.iso(row.createdAt), to: statement, index: 11)
                    Self.bindText(Self.iso(row.lastUsedAt), to: statement, index: 12)
                }
            )
        }
    }

    public func environment(id: String) throws -> EnvironmentRow? {
        try query("SELECT id, kind, owner_id, name, base_image_id, base_rootfs_digest, state, data_path, compat_host_fhs, repair_reason, created_at, last_used_at FROM environments WHERE id=?", bind: { statement in
            Self.bindText(id, to: statement, index: 1)
        }) { statement in
            EnvironmentRow(
                id: text(statement, 0) ?? "",
                kind: text(statement, 1) ?? "session",
                ownerID: text(statement, 2),
                name: text(statement, 3),
                baseImageID: text(statement, 4),
                baseRootfsDigest: text(statement, 5),
                state: text(statement, 6) ?? "active",
                dataPath: text(statement, 7),
                compatHostFHS: sqlite3_column_int(statement, 8) != 0,
                repairReason: text(statement, 9),
                createdAt: Self.date(text(statement, 10)) ?? Date.distantPast,
                lastUsedAt: Self.date(text(statement, 11)) ?? Date.distantPast
            )
        }.first
    }

    public func setEnvironmentState(id: String, state: String, repairReason: String? = nil) throws {
        try transaction {
            try run(
                "UPDATE environments SET state=?, repair_reason=?, last_used_at=? WHERE id=?",
                bind: { statement in
                    Self.bindText(state, to: statement, index: 1)
                    Self.bindOptionalText(repairReason, to: statement, index: 2)
                    Self.bindText(Self.iso(Date()), to: statement, index: 3)
                    Self.bindText(id, to: statement, index: 4)
                }
            )
        }
    }

    public func environments(state: String? = nil) throws -> [EnvironmentRow] {
        let ids: [String]
        if let state {
            ids = try query("SELECT id FROM environments WHERE state=? ORDER BY id", bind: { statement in
                Self.bindText(state, to: statement, index: 1)
            }) { text($0, 0) ?? "" }
        } else {
            ids = try query("SELECT id FROM environments ORDER BY id") { text($0, 0) ?? "" }
        }
        return try ids.compactMap { try environment(id: $0) }
    }

    // MARK: conversations + workspaces

    public func linkConversation(id: String, environmentID: String?, workspaceID: String?) throws {
        try transaction {
            try run(
                """
                INSERT INTO conversations (id, environment_id, workspace_id, created_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET environment_id=excluded.environment_id, workspace_id=excluded.workspace_id
                """,
                bind: { statement in
                    Self.bindText(id, to: statement, index: 1)
                    Self.bindOptionalText(environmentID, to: statement, index: 2)
                    Self.bindOptionalText(workspaceID, to: statement, index: 3)
                    Self.bindText(Self.iso(Date()), to: statement, index: 4)
                }
            )
        }
    }

    public func conversationEnvironment(id: String) throws -> String? {
        try query("SELECT environment_id FROM conversations WHERE id=?", bind: { statement in
            Self.bindText(id, to: statement, index: 1)
        }) { text($0, 0) }.first ?? nil
    }

    public func upsertWorkspace(_ row: WorkspaceRow) throws {
        try transaction {
            try run(
                """
                INSERT INTO workspaces (id, kind, path, bookmark, display_path, change_generation,
                  write_session_owner, relocation_pending, created_at, last_used_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, path=excluded.path,
                  bookmark=excluded.bookmark, display_path=excluded.display_path,
                  change_generation=excluded.change_generation,
                  write_session_owner=excluded.write_session_owner,
                  relocation_pending=excluded.relocation_pending, last_used_at=excluded.last_used_at
                """,
                bind: { statement in
                    Self.bindText(row.id, to: statement, index: 1)
                    Self.bindText(row.kind, to: statement, index: 2)
                    Self.bindOptionalText(row.path, to: statement, index: 3)
                    if let bookmark = row.bookmark {
                        _ = bookmark.withUnsafeBytes { bytes in
                            sqlite3_bind_blob(statement, 4, bytes.baseAddress, Int32(bookmark.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                        }
                    } else {
                        sqlite3_bind_null(statement, 4)
                    }
                    Self.bindOptionalText(row.displayPath, to: statement, index: 5)
                    sqlite3_bind_int64(statement, 6, row.changeGeneration)
                    Self.bindOptionalText(row.writeSessionOwner, to: statement, index: 7)
                    sqlite3_bind_int(statement, 8, row.relocationPending ? 1 : 0)
                    Self.bindText(Self.iso(row.createdAt), to: statement, index: 9)
                    Self.bindText(Self.iso(row.lastUsedAt), to: statement, index: 10)
                }
            )
        }
    }

    public func workspace(id: String) throws -> WorkspaceRow? {
        try query("SELECT id, kind, path, bookmark, display_path, change_generation, write_session_owner, relocation_pending, created_at, last_used_at FROM workspaces WHERE id=?", bind: { statement in
            Self.bindText(id, to: statement, index: 1)
        }) { statement in
            let bookmarkLength = sqlite3_column_bytes(statement, 3)
            let bookmark: Data? = bookmarkLength > 0
                ? sqlite3_column_blob(statement, 3).map { Data(bytes: $0, count: Int(bookmarkLength)) }
                : nil
            return WorkspaceRow(
                id: text(statement, 0) ?? "",
                kind: text(statement, 1) ?? "owned",
                path: text(statement, 2),
                bookmark: bookmark,
                displayPath: text(statement, 4),
                changeGeneration: sqlite3_column_int64(statement, 5),
                writeSessionOwner: text(statement, 6),
                relocationPending: sqlite3_column_int(statement, 7) != 0,
                createdAt: Self.date(text(statement, 8)) ?? Date.distantPast,
                lastUsedAt: Self.date(text(statement, 9)) ?? Date.distantPast
            )
        }.first
    }

    /// Advisory write-session coordination for a workspace shared by several
    /// environments: records the holder and bumps the change generation.
    /// Never copies workspace content.
    public func claimWorkspaceWriteSession(id: String, environmentID: String?) throws -> Int64 {
        let current = try workspace(id: id)
        let generation = (current?.changeGeneration ?? 0) + 1
        try transaction {
            try run(
                "UPDATE workspaces SET write_session_owner=?, change_generation=?, last_used_at=? WHERE id=?",
                bind: { statement in
                    Self.bindOptionalText(environmentID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, generation)
                    Self.bindText(Self.iso(Date()), to: statement, index: 3)
                    Self.bindText(id, to: statement, index: 4)
                }
            )
        }
        return generation
    }

    // MARK: leases (single writable ownership; never an activeVMID truth)

    public func recordLease(_ row: LeaseRow) throws {
        try transaction {
            try run(
                """
                INSERT INTO leases (environment_id, runtime_id, incarnation, session_token, pid,
                  acquired_at, renewed_at, ttl_seconds, state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(environment_id) DO UPDATE SET runtime_id=excluded.runtime_id,
                  incarnation=excluded.incarnation, session_token=excluded.session_token,
                  pid=excluded.pid, acquired_at=excluded.acquired_at, renewed_at=excluded.renewed_at,
                  ttl_seconds=excluded.ttl_seconds, state=excluded.state
                """,
                bind: { statement in
                    Self.bindText(row.environmentID, to: statement, index: 1)
                    Self.bindText(row.runtimeID, to: statement, index: 2)
                    Self.bindText(row.incarnation, to: statement, index: 3)
                    Self.bindText(row.sessionToken, to: statement, index: 4)
                    sqlite3_bind_int64(statement, 5, row.pid)
                    Self.bindText(Self.iso(row.acquiredAt), to: statement, index: 6)
                    Self.bindText(Self.iso(row.renewedAt), to: statement, index: 7)
                    sqlite3_bind_int64(statement, 8, row.ttlSeconds)
                    Self.bindText(row.state, to: statement, index: 9)
                }
            )
        }
    }

    public func lease(environmentID: String) throws -> LeaseRow? {
        try query("SELECT environment_id, runtime_id, incarnation, session_token, pid, acquired_at, renewed_at, ttl_seconds, state FROM leases WHERE environment_id=?", bind: { statement in
            Self.bindText(environmentID, to: statement, index: 1)
        }) { statement in
            LeaseRow(
                environmentID: text(statement, 0) ?? "",
                runtimeID: text(statement, 1) ?? "",
                incarnation: text(statement, 2) ?? "",
                sessionToken: text(statement, 3) ?? "",
                pid: sqlite3_column_int64(statement, 4),
                acquiredAt: Self.date(text(statement, 5)) ?? Date.distantPast,
                renewedAt: Self.date(text(statement, 6)) ?? Date.distantPast,
                ttlSeconds: sqlite3_column_int64(statement, 7),
                state: text(statement, 8) ?? "held"
            )
        }.first
    }

    public func heldLeases() throws -> [LeaseRow] {
        let ids: [String] = try query("SELECT environment_id FROM leases WHERE state='held'") { text($0, 0) ?? "" }
        return try ids.compactMap { try lease(environmentID: $0) }
    }

    public func releaseLease(environmentID: String, runtimeID: String) throws {
        try transaction {
            try run(
                "UPDATE leases SET state='released', renewed_at=? WHERE environment_id=? AND runtime_id=?",
                bind: { statement in
                    Self.bindText(Self.iso(Date()), to: statement, index: 1)
                    Self.bindText(environmentID, to: statement, index: 2)
                    Self.bindText(runtimeID, to: statement, index: 3)
                }
            )
        }
    }

    public func markLeaseStale(environmentID: String) throws {
        try transaction {
            try run(
                "UPDATE leases SET state='stale' WHERE environment_id=?",
                bind: { statement in
                    Self.bindText(environmentID, to: statement, index: 1)
                }
            )
        }
    }

    // MARK: queue entries

    public func recordQueueEntry(_ row: QueueRow) throws {
        try transaction {
            try run(
                """
                INSERT INTO queue_entries (id, environment_id, requested_mb, state, enqueued_at, started_at, finished_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET state=excluded.state, started_at=excluded.started_at,
                  finished_at=excluded.finished_at
                """,
                bind: { statement in
                    Self.bindText(row.id, to: statement, index: 1)
                    Self.bindText(row.environmentID, to: statement, index: 2)
                    sqlite3_bind_int(statement, 3, Int32(row.requestedMB))
                    Self.bindText(row.state, to: statement, index: 4)
                    Self.bindText(Self.iso(row.enqueuedAt), to: statement, index: 5)
                    Self.bindOptionalText(row.startedAt.map(Self.iso), to: statement, index: 6)
                    Self.bindOptionalText(row.finishedAt.map(Self.iso), to: statement, index: 7)
                }
            )
        }
    }

    public func queueEntries(state: String) throws -> [QueueRow] {
        try query("SELECT id, environment_id, requested_mb, state, enqueued_at, started_at, finished_at FROM queue_entries WHERE state=? ORDER BY enqueued_at", bind: { statement in
            Self.bindText(state, to: statement, index: 1)
        }) { statement in
            QueueRow(
                id: text(statement, 0) ?? "",
                environmentID: text(statement, 1) ?? "",
                requestedMB: Int(sqlite3_column_int(statement, 2)),
                state: text(statement, 3) ?? "queued",
                enqueuedAt: Self.date(text(statement, 4)) ?? Date.distantPast,
                startedAt: Self.date(text(statement, 5)),
                finishedAt: Self.date(text(statement, 6))
            )
        }
    }

    public func setQueueEntryState(id: String, state: String, started: Bool = false, finished: Bool = false) throws {
        try transaction {
            try run(
                """
                UPDATE queue_entries SET state=?,
                  started_at=CASE WHEN ? THEN COALESCE(started_at, ?) ELSE started_at END,
                  finished_at=CASE WHEN ? THEN ? ELSE finished_at END
                WHERE id=?
                """,
                bind: { statement in
                    Self.bindText(state, to: statement, index: 1)
                    sqlite3_bind_int(statement, 2, started ? 1 : 0)
                    Self.bindText(Self.iso(Date()), to: statement, index: 3)
                    sqlite3_bind_int(statement, 4, finished ? 1 : 0)
                    Self.bindText(Self.iso(Date()), to: statement, index: 5)
                    Self.bindText(id, to: statement, index: 6)
                }
            )
        }
    }

    /// App-restart recovery: every entry still queued/running belongs to a
    /// dead incarnation and is explicitly marked interrupted — never silently
    /// dropped and never resumed as if nothing happened.
    public func interruptOpenQueueEntries() throws -> Int {
        let open = try queueEntries(state: "queued") + queueEntries(state: "running")
        try transaction {
            for entry in open {
                try run(
                    "UPDATE queue_entries SET state='interrupted', finished_at=? WHERE id=?",
                    bind: { statement in
                        Self.bindText(Self.iso(Date()), to: statement, index: 1)
                        Self.bindText(entry.id, to: statement, index: 2)
                    }
                )
            }
        }
        return open.count
    }

    // MARK: services + ports

    public func registerService(_ row: ServiceRow) throws {
        try transaction {
            try run(
                """
                INSERT INTO services (environment_id, name, guest_port, proto, state) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(environment_id, name) DO UPDATE SET guest_port=excluded.guest_port,
                  proto=excluded.proto, state=excluded.state
                """,
                bind: { statement in
                    Self.bindText(row.environmentID, to: statement, index: 1)
                    Self.bindText(row.name, to: statement, index: 2)
                    sqlite3_bind_int(statement, 3, Int32(row.guestPort))
                    Self.bindText(row.proto, to: statement, index: 4)
                    Self.bindText(row.state, to: statement, index: 5)
                }
            )
        }
    }

    public func services(environmentID: String) throws -> [ServiceRow] {
        try query("SELECT environment_id, name, guest_port, proto, state FROM services WHERE environment_id=? ORDER BY name", bind: { statement in
            Self.bindText(environmentID, to: statement, index: 1)
        }) { statement in
            ServiceRow(
                environmentID: text(statement, 0) ?? "",
                name: text(statement, 1) ?? "",
                guestPort: Int(sqlite3_column_int(statement, 2)),
                proto: text(statement, 3) ?? "tcp",
                state: text(statement, 4) ?? "registered"
            )
        }
    }

    public func reservePort(_ row: PortRow) throws {
        try transaction {
            try run(
                """
                INSERT INTO ports (environment_id, host_port, guest_port, proto, runtime_id, state)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(environment_id, host_port, proto) DO UPDATE SET
                  guest_port=excluded.guest_port, runtime_id=excluded.runtime_id, state=excluded.state
                """,
                bind: { statement in
                    Self.bindText(row.environmentID, to: statement, index: 1)
                    sqlite3_bind_int(statement, 2, Int32(row.hostPort))
                    sqlite3_bind_int(statement, 3, Int32(row.guestPort))
                    Self.bindText(row.proto, to: statement, index: 4)
                    Self.bindOptionalText(row.runtimeID, to: statement, index: 5)
                    Self.bindText(row.state, to: statement, index: 6)
                }
            )
        }
    }

    public func ports(environmentID: String) throws -> [PortRow] {
        try query("SELECT environment_id, host_port, guest_port, proto, runtime_id, state FROM ports WHERE environment_id=? ORDER BY host_port", bind: { statement in
            Self.bindText(environmentID, to: statement, index: 1)
        }) { statement in
            PortRow(
                environmentID: text(statement, 0) ?? "",
                hostPort: Int(sqlite3_column_int(statement, 1)),
                guestPort: Int(sqlite3_column_int(statement, 2)),
                proto: text(statement, 3) ?? "tcp",
                runtimeID: text(statement, 4),
                state: text(statement, 5) ?? "reserved"
            )
        }
    }

    public func releasePorts(runtimeID: String) throws {
        try transaction {
            try run(
                "UPDATE ports SET state='released' WHERE runtime_id=?",
                bind: { statement in
                    Self.bindText(runtimeID, to: statement, index: 1)
                }
            )
        }
    }

    // MARK: migrations (discovered/copied/verified/switched/cleanupPending/done)

    public func beginMigration(id: String, kind: String, sourcePath: String?, targetPath: String?, detail: String?) throws {
        try transaction {
            try run(
                """
                INSERT INTO migrations (id, kind, phase, source_path, target_path, detail, created_at, updated_at)
                VALUES (?, ?, 'discovered', ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET phase='discovered', error=NULL,
                  source_path=excluded.source_path, target_path=excluded.target_path,
                  detail=excluded.detail, updated_at=excluded.updated_at
                """,
                bind: { statement in
                    Self.bindText(id, to: statement, index: 1)
                    Self.bindText(kind, to: statement, index: 2)
                    Self.bindOptionalText(sourcePath, to: statement, index: 3)
                    Self.bindOptionalText(targetPath, to: statement, index: 4)
                    Self.bindOptionalText(detail, to: statement, index: 5)
                    Self.bindText(Self.iso(Date()), to: statement, index: 6)
                    Self.bindText(Self.iso(Date()), to: statement, index: 7)
                }
            )
        }
    }

    public func setMigrationPhase(id: String, phase: MigrationPhase, error: String? = nil) throws {
        try transaction {
            try run(
                "UPDATE migrations SET phase=?, error=?, updated_at=? WHERE id=?",
                bind: { statement in
                    Self.bindText(phase.rawValue, to: statement, index: 1)
                    Self.bindOptionalText(error, to: statement, index: 2)
                    Self.bindText(Self.iso(Date()), to: statement, index: 3)
                    Self.bindText(id, to: statement, index: 4)
                }
            )
        }
    }

    public func migration(id: String) throws -> MigrationRow? {
        try query("SELECT id, kind, phase, source_path, target_path, detail, error, created_at, updated_at FROM migrations WHERE id=?", bind: { statement in
            Self.bindText(id, to: statement, index: 1)
        }) { statement in
            MigrationRow(
                id: text(statement, 0) ?? "",
                kind: text(statement, 1) ?? "",
                phase: MigrationPhase(rawValue: text(statement, 2) ?? "") ?? .discovered,
                sourcePath: text(statement, 3),
                targetPath: text(statement, 4),
                detail: text(statement, 5),
                error: text(statement, 6),
                createdAt: Self.date(text(statement, 7)) ?? Date.distantPast,
                updatedAt: Self.date(text(statement, 8)) ?? Date.distantPast
            )
        }.first
    }

    public func migrations(inPhases phases: Set<MigrationPhase>) throws -> [MigrationRow] {
        guard !phases.isEmpty else { return [] }
        let marks = phases.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let ids: [String] = try query("SELECT id FROM migrations WHERE phase IN (\(marks)) ORDER BY created_at") {
            text($0, 0) ?? ""
        }
        return try ids.compactMap { try migration(id: $0) }
    }
}
