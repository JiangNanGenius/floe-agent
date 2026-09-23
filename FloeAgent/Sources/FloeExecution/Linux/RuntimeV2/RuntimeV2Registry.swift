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
        /// Immutable software-template pin. The environment boots exactly this
        /// template version or fails closed; it is never silently re-pointed
        /// at a newer base (schema v2, nil for base-image-only environments).
        public var templateID: String?
        public var templateVersion: Int?
        public var templateDigest: String?

        public init(
            id: String, kind: String, ownerID: String?, name: String?,
            baseImageID: String?, baseRootfsDigest: String?, state: String,
            dataPath: String?, compatHostFHS: Bool, repairReason: String?,
            createdAt: Date, lastUsedAt: Date,
            templateID: String? = nil, templateVersion: Int? = nil, templateDigest: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.ownerID = ownerID
            self.name = name
            self.baseImageID = baseImageID
            self.baseRootfsDigest = baseRootfsDigest
            self.state = state
            self.dataPath = dataPath
            self.compatHostFHS = compatHostFHS
            self.repairReason = repairReason
            self.createdAt = createdAt
            self.lastUsedAt = lastUsedAt
            self.templateID = templateID
            self.templateVersion = templateVersion
            self.templateDigest = templateDigest
        }
    }

    /// One immutable software-template version (schema v2). The disk bytes
    /// live in the content-addressed blob store (`diskDigest`); the row owns
    /// the truth: content digest, architecture, parent source, package list,
    /// verification state and reference bookkeeping.
    public enum TemplateState: String, Sendable { case building, verified, failed, quarantined }

    public struct SoftwareTemplateRow: Sendable, Equatable {
        public var templateID: String
        public var version: Int
        /// Content digest over the canonical (parent, architecture, packages,
        /// recipe) tuple — never over timestamps or host paths.
        public var digest: String
        public var architecture: String
        public var parentKind: String // base-image | template-version
        public var parentID: String
        public var parentVersion: Int?
        public var parentDigest: String
        public var state: TemplateState
        public var reason: String?
        public var manifestJSON: String?
        public var packageCount: Int
        public var logicalBytes: Int64
        public var allocatedBytes: Int64
        public var downloadBytes: Int64
        public var buildMode: String? // clone | copy
        public var diskDigest: String?
        public var buildID: String?
        public var stagingPath: String?
        public var createdAt: Date
        public var verifiedAt: Date?
    }

    public struct TemplatePackageRow: Sendable, Equatable {
        public var templateID: String
        public var version: Int
        public var name: String
        public var packageVersion: String
        public var architecture: String?
        public var source: String?
        public var installState: String
        public var digest: String?
    }

    public struct TemplateReferenceRow: Sendable, Equatable {
        public var templateID: String
        public var version: Int
        public var refKind: String // environment | catalog | build | recovery | quarantine
        public var refID: String
        public var createdAt: Date
    }

    /// Result of the atomic GC transition. `.skipped` names the protection
    /// that matched INSIDE the collection transaction, never a pre-check.
    public enum TemplateCollectionOutcome: Sendable, Equatable {
        case collected(diskDigest: String, blobBytes: Int64, remainingBlobRefs: Int)
        case skipped(reason: String)
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
        // The `schema_migrations` table itself is owned by the bootstrap in
        // `applySchemaMigrations()` (created there before any script runs, so
        // an applied-version check is always possible). A migration script
        // must therefore NEVER create it again: Build 222/223 shipped v1 with
        // `CREATE TABLE schema_migrations`, which collided with the bootstrap
        // table on every fresh database and made the registry impossible to
        // open — the "Linux installed but cannot start" regression.
        (1, "initial", """
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
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
        """),
        // v2: immutable software-template versions, their package DB listing
        // (the real in-guest install evidence) and their reference counts,
        // plus the environment's immutable template pin. A template version is
        // never mutated in place: a new install is a new version, and an
        // environment boots exactly the version it recorded or fails closed.
        (2, "software-templates", """
        CREATE TABLE software_templates (
          template_id TEXT NOT NULL,
          version INTEGER NOT NULL,
          digest TEXT NOT NULL,
          architecture TEXT NOT NULL,
          parent_kind TEXT NOT NULL,
          parent_id TEXT NOT NULL,
          parent_version INTEGER,
          parent_digest TEXT NOT NULL,
          state TEXT NOT NULL,
          reason TEXT,
          manifest_json TEXT,
          package_count INTEGER NOT NULL DEFAULT 0,
          logical_bytes INTEGER NOT NULL DEFAULT 0,
          allocated_bytes INTEGER NOT NULL DEFAULT 0,
          download_bytes INTEGER NOT NULL DEFAULT 0,
          build_mode TEXT,
          disk_digest TEXT,
          build_id TEXT,
          staging_path TEXT,
          created_at TEXT NOT NULL,
          verified_at TEXT,
          PRIMARY KEY (template_id, version)
        );
        CREATE TABLE software_template_packages (
          template_id TEXT NOT NULL,
          version INTEGER NOT NULL,
          name TEXT NOT NULL,
          package_version TEXT NOT NULL,
          architecture TEXT,
          source TEXT,
          install_state TEXT NOT NULL,
          digest TEXT,
          PRIMARY KEY (template_id, version, name)
        );
        CREATE TABLE template_references (
          template_id TEXT NOT NULL,
          version INTEGER NOT NULL,
          ref_kind TEXT NOT NULL,
          ref_id TEXT NOT NULL,
          created_at TEXT NOT NULL,
          PRIMARY KEY (template_id, version, ref_kind, ref_id)
        );
        ALTER TABLE environments ADD COLUMN template_id TEXT;
        ALTER TABLE environments ADD COLUMN template_version INTEGER;
        ALTER TABLE environments ADD COLUMN template_digest TEXT;
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
            do {
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
            } catch let error as RuntimeV2Error {
                // Name the failing script: a schema collision must be
                // diagnosable from the error alone, without a debugger.
                throw RuntimeV2Error.registryCorrupt(
                    "schema migration \(migration.version) '\(migration.name)' failed: \(error.localizedDescription)"
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
                  state, data_path, compat_host_fhs, repair_reason, created_at, last_used_at,
                  template_id, template_version, template_digest)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET kind=excluded.kind, owner_id=excluded.owner_id,
                  name=excluded.name, base_image_id=excluded.base_image_id,
                  base_rootfs_digest=excluded.base_rootfs_digest, state=excluded.state,
                  data_path=excluded.data_path, compat_host_fhs=excluded.compat_host_fhs,
                  repair_reason=excluded.repair_reason, last_used_at=excluded.last_used_at,
                  template_id=excluded.template_id, template_version=excluded.template_version,
                  template_digest=excluded.template_digest
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
                    Self.bindOptionalText(row.templateID, to: statement, index: 13)
                    if let version = row.templateVersion {
                        sqlite3_bind_int64(statement, 14, Int64(version))
                    } else {
                        sqlite3_bind_null(statement, 14)
                    }
                    Self.bindOptionalText(row.templateDigest, to: statement, index: 15)
                }
            )
        }
    }

    public func environment(id: String) throws -> EnvironmentRow? {
        try query("SELECT id, kind, owner_id, name, base_image_id, base_rootfs_digest, state, data_path, compat_host_fhs, repair_reason, created_at, last_used_at, template_id, template_version, template_digest FROM environments WHERE id=?", bind: { statement in
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
                lastUsedAt: Self.date(text(statement, 11)) ?? Date.distantPast,
                templateID: text(statement, 12),
                templateVersion: sqlite3_column_type(statement, 13) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int64(statement, 13)),
                templateDigest: text(statement, 14)
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

    // MARK: software templates (immutable versions; never mutated in place)

    private static let templateColumns = """
    template_id, version, digest, architecture, parent_kind, parent_id, parent_version, \
    parent_digest, state, reason, manifest_json, package_count, logical_bytes, \
    allocated_bytes, download_bytes, build_mode, disk_digest, build_id, staging_path, \
    created_at, verified_at
    """

    private func templateRow(_ statement: OpaquePointer?) -> SoftwareTemplateRow {
        SoftwareTemplateRow(
            templateID: text(statement, 0) ?? "",
            version: Int(sqlite3_column_int64(statement, 1)),
            digest: text(statement, 2) ?? "",
            architecture: text(statement, 3) ?? "",
            parentKind: text(statement, 4) ?? "",
            parentID: text(statement, 5) ?? "",
            parentVersion: sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int64(statement, 6)),
            parentDigest: text(statement, 7) ?? "",
            state: TemplateState(rawValue: text(statement, 8) ?? "") ?? .failed,
            reason: text(statement, 9),
            manifestJSON: text(statement, 10),
            packageCount: Int(sqlite3_column_int(statement, 11)),
            logicalBytes: sqlite3_column_int64(statement, 12),
            allocatedBytes: sqlite3_column_int64(statement, 13),
            downloadBytes: sqlite3_column_int64(statement, 14),
            buildMode: text(statement, 15),
            diskDigest: text(statement, 16),
            buildID: text(statement, 17),
            stagingPath: text(statement, 18),
            createdAt: Self.date(text(statement, 19)) ?? Date.distantPast,
            verifiedAt: Self.date(text(statement, 20))
        )
    }

    /// Opens a new immutable template version in `building` state. INSERT-only:
    /// a version that already exists is never overwritten here. Returns false
    /// when the row already existed (the caller decides idempotency; a
    /// conflicting digest is always refused upstream).
    @discardableResult
    public func beginTemplateVersion(
        templateID: String, version: Int, digest: String, architecture: String,
        parentKind: String, parentID: String, parentVersion: Int?, parentDigest: String,
        manifestJSON: String?, buildID: String?, stagingPath: String?
    ) throws -> Bool {
        var inserted = false
        try transaction {
            try run(
                """
                INSERT INTO software_templates (\(Self.templateColumns))
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'building', NULL, ?, 0, 0, 0, 0, NULL, NULL, ?, ?, ?, NULL)
                ON CONFLICT(template_id, version) DO NOTHING
                """,
                bind: { statement in
                    Self.bindText(templateID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(version))
                    Self.bindText(digest, to: statement, index: 3)
                    Self.bindText(architecture, to: statement, index: 4)
                    Self.bindText(parentKind, to: statement, index: 5)
                    Self.bindText(parentID, to: statement, index: 6)
                    if let parentVersion {
                        sqlite3_bind_int64(statement, 7, Int64(parentVersion))
                    } else {
                        sqlite3_bind_null(statement, 7)
                    }
                    Self.bindText(parentDigest, to: statement, index: 8)
                    Self.bindOptionalText(manifestJSON, to: statement, index: 9)
                    Self.bindOptionalText(buildID, to: statement, index: 10)
                    Self.bindOptionalText(stagingPath, to: statement, index: 11)
                    Self.bindText(Self.iso(Date()), to: statement, index: 12)
                }
            )
            inserted = sqlite3_changes(db) > 0
        }
        return inserted
    }

    /// Reopens a FAILED version for a fresh build attempt (a fresh clone of the
    /// same recorded parent + recipe). A verified or quarantined version can
    /// never be reopened — immutability is the whole point. A leftover
    /// `disk_digest` on the failed row (an ingest that was recorded but never
    /// activated) releases exactly the one reference it took, in the same
    /// transaction.
    @discardableResult
    public func reopenTemplateVersion(
        templateID: String, version: Int, architecture: String,
        parentKind: String, parentID: String, parentVersion: Int?, parentDigest: String,
        manifestJSON: String?, buildID: String?, stagingPath: String?
    ) throws -> Bool {
        var reopened = false
        try transaction {
            let leftover: String? = try query(
                "SELECT disk_digest FROM software_templates WHERE template_id=? AND version=? AND state='failed'",
                bind: { statement in
                    Self.bindText(templateID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(version))
                }
            ) { text($0, 0) }.first ?? nil
            try run(
                """
                UPDATE software_templates SET state='building', reason=NULL, digest='',
                  architecture=?, parent_kind=?, parent_id=?, parent_version=?, parent_digest=?,
                  manifest_json=?, package_count=0, logical_bytes=0, allocated_bytes=0,
                  download_bytes=0, build_mode=NULL, disk_digest=NULL, build_id=?, staging_path=?,
                  created_at=?, verified_at=NULL
                WHERE template_id=? AND version=? AND state='failed'
                """,
                bind: { statement in
                    Self.bindText(architecture, to: statement, index: 1)
                    Self.bindText(parentKind, to: statement, index: 2)
                    Self.bindText(parentID, to: statement, index: 3)
                    if let parentVersion {
                        sqlite3_bind_int64(statement, 4, Int64(parentVersion))
                    } else {
                        sqlite3_bind_null(statement, 4)
                    }
                    Self.bindText(parentDigest, to: statement, index: 5)
                    Self.bindOptionalText(manifestJSON, to: statement, index: 6)
                    Self.bindOptionalText(buildID, to: statement, index: 7)
                    Self.bindOptionalText(stagingPath, to: statement, index: 8)
                    Self.bindText(Self.iso(Date()), to: statement, index: 9)
                    Self.bindText(templateID, to: statement, index: 10)
                    sqlite3_bind_int64(statement, 11, Int64(version))
                }
            )
            reopened = sqlite3_changes(db) > 0
            if reopened, let leftover {
                try run(
                    "UPDATE blobs SET refs = MAX(0, refs - 1) WHERE digest=?",
                    bind: { Self.bindText(leftover, to: $0, index: 1) }
                )
            }
        }
        return reopened
    }

    /// Records the exact disk digest this build attempt ingested, together with
    /// the one blob reference it took — ONE transaction, so a crash can never
    /// leave an ownerless reference (the reference exists exactly when the row
    /// names the pending owner). Only a `building` row can record an ingest.
    @discardableResult
    public func recordTemplateIngest(
        templateID: String, version: Int, diskDigest: String, bytes: Int64
    ) throws -> Bool {
        var recorded = false
        try transaction {
            try run(
                "UPDATE software_templates SET disk_digest=? WHERE template_id=? AND version=? AND state='building'",
                bind: { statement in
                    Self.bindText(diskDigest, to: statement, index: 1)
                    Self.bindText(templateID, to: statement, index: 2)
                    sqlite3_bind_int64(statement, 3, Int64(version))
                }
            )
            recorded = sqlite3_changes(db) > 0
            guard recorded else { return }
            try run(
                """
                INSERT INTO blobs (digest, bytes, refs, created_at) VALUES (?, ?, 1, ?)
                ON CONFLICT(digest) DO UPDATE SET refs = refs + 1
                """,
                bind: { statement in
                    Self.bindText(diskDigest, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, bytes)
                    Self.bindText(Self.iso(Date()), to: statement, index: 3)
                }
            )
        }
        return recorded
    }

    /// The single activation commit: packages + verified bytes + reference
    /// bookkeeping + migration phase land together or not at all. Returns false
    /// (changing nothing) when the version is no longer `building` — a late
    /// caller can never knock a verified version back or fake a verification.
    @discardableResult
    public func activateTemplateVersion(
        templateID: String, version: Int, digest: String, diskDigest: String,
        logicalBytes: Int64, allocatedBytes: Int64, downloadBytes: Int64,
        buildMode: String, packages: [TemplatePackageRow],
        removeBuildReferenceID: String?, recoveryReferenceID: String?,
        catalogReferenceID: String?, migrationID: String?
    ) throws -> Bool {
        var activated = false
        try transaction {
            try run(
                """
                UPDATE software_templates SET state='verified', digest=?, disk_digest=?,
                  logical_bytes=?, allocated_bytes=?, download_bytes=?, build_mode=?,
                  package_count=?, reason=NULL, verified_at=?
                WHERE template_id=? AND version=? AND state='building'
                """,
                bind: { statement in
                    Self.bindText(digest, to: statement, index: 1)
                    Self.bindText(diskDigest, to: statement, index: 2)
                    sqlite3_bind_int64(statement, 3, logicalBytes)
                    sqlite3_bind_int64(statement, 4, allocatedBytes)
                    sqlite3_bind_int64(statement, 5, downloadBytes)
                    Self.bindText(buildMode, to: statement, index: 6)
                    sqlite3_bind_int(statement, 7, Int32(packages.count))
                    Self.bindText(Self.iso(Date()), to: statement, index: 8)
                    Self.bindText(templateID, to: statement, index: 9)
                    sqlite3_bind_int64(statement, 10, Int64(version))
                }
            )
            activated = sqlite3_changes(db) > 0
            guard activated else { return }
            try run(
                "DELETE FROM software_template_packages WHERE template_id=? AND version=?",
                bind: { statement in
                    Self.bindText(templateID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(version))
                }
            )
            for package in packages {
                try run(
                    """
                    INSERT INTO software_template_packages
                      (template_id, version, name, package_version, architecture, source, install_state, digest)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bind: { statement in
                        Self.bindText(templateID, to: statement, index: 1)
                        sqlite3_bind_int64(statement, 2, Int64(version))
                        Self.bindText(package.name, to: statement, index: 3)
                        Self.bindText(package.packageVersion, to: statement, index: 4)
                        Self.bindOptionalText(package.architecture, to: statement, index: 5)
                        Self.bindOptionalText(package.source, to: statement, index: 6)
                        Self.bindText(package.installState, to: statement, index: 7)
                        Self.bindOptionalText(package.digest, to: statement, index: 8)
                    }
                )
            }
            if let removeBuildReferenceID {
                try run(
                    "DELETE FROM template_references WHERE template_id=? AND version=? AND ref_kind='build' AND ref_id=?",
                    bind: { statement in
                        Self.bindText(templateID, to: statement, index: 1)
                        sqlite3_bind_int64(statement, 2, Int64(version))
                        Self.bindText(removeBuildReferenceID, to: statement, index: 3)
                    }
                )
            }
            if let recoveryReferenceID {
                try run(
                    """
                    INSERT INTO template_references (template_id, version, ref_kind, ref_id, created_at)
                    VALUES (?, ?, 'recovery', ?, ?)
                    ON CONFLICT(template_id, version, ref_kind, ref_id) DO NOTHING
                    """,
                    bind: { statement in
                        Self.bindText(templateID, to: statement, index: 1)
                        sqlite3_bind_int64(statement, 2, Int64(version))
                        Self.bindText(recoveryReferenceID, to: statement, index: 3)
                        Self.bindText(Self.iso(Date()), to: statement, index: 4)
                    }
                )
            }
            if let catalogReferenceID {
                try run(
                    """
                    INSERT INTO template_references (template_id, version, ref_kind, ref_id, created_at)
                    VALUES (?, ?, 'catalog', ?, ?)
                    ON CONFLICT(template_id, version, ref_kind, ref_id) DO NOTHING
                    """,
                    bind: { statement in
                        Self.bindText(templateID, to: statement, index: 1)
                        sqlite3_bind_int64(statement, 2, Int64(version))
                        Self.bindText(catalogReferenceID, to: statement, index: 3)
                        Self.bindText(Self.iso(Date()), to: statement, index: 4)
                    }
                )
            }
            if let migrationID {
                try run(
                    "UPDATE migrations SET phase='cleanupPending', error=NULL, updated_at=? WHERE id=?",
                    bind: { statement in
                        Self.bindText(Self.iso(Date()), to: statement, index: 1)
                        Self.bindText(migrationID, to: statement, index: 2)
                    }
                )
            }
        }
        return activated
    }

    /// Fails a build attempt honestly: only a `building` row transitions, so a
    /// verified version can never be knocked back to failed by a late error.
    /// Failure is also where an ingested-but-never-activated disk reference is
    /// released: the row's recorded `disk_digest` names exactly the one
    /// reference this attempt took, and the release + the clear + the state
    /// transition commit together. Repeating the call is a no-op (the row is
    /// no longer building and no longer names a digest). Build references for
    /// the failed version are orphaned by definition and are removed.
    public func failTemplateVersion(
        templateID: String, version: Int, reason: String, stagingPath: String? = nil
    ) throws {
        try transaction {
            let recorded: String? = try query(
                "SELECT disk_digest FROM software_templates WHERE template_id=? AND version=? AND state='building'",
                bind: { statement in
                    Self.bindText(templateID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(version))
                }
            ) { text($0, 0) }.first ?? nil
            try run(
                """
                UPDATE software_templates SET state='failed', reason=?, staging_path=COALESCE(?, staging_path),
                  disk_digest=NULL
                WHERE template_id=? AND version=? AND state='building'
                """,
                bind: { statement in
                    Self.bindText(reason, to: statement, index: 1)
                    Self.bindOptionalText(stagingPath, to: statement, index: 2)
                    Self.bindText(templateID, to: statement, index: 3)
                    sqlite3_bind_int64(statement, 4, Int64(version))
                }
            )
            guard sqlite3_changes(db) > 0 else { return }
            try run(
                "DELETE FROM template_references WHERE template_id=? AND version=? AND ref_kind='build'",
                bind: { statement in
                    Self.bindText(templateID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(version))
                }
            )
            if let recorded {
                try run(
                    "UPDATE blobs SET refs = MAX(0, refs - 1) WHERE digest=?",
                    bind: { Self.bindText(recorded, to: $0, index: 1) }
                )
            }
        }
    }

    /// Quarantine keeps the row (and its evidence) but makes the version
    /// unpinnable: a collected or damaged template is never silently booted.
    public func quarantineTemplateVersion(templateID: String, version: Int, reason: String) throws {
        try transaction {
            try run(
                """
                UPDATE software_templates SET state='quarantined', reason=?
                WHERE template_id=? AND version=? AND state != 'quarantined'
                """,
                bind: { statement in
                    Self.bindText(reason, to: statement, index: 1)
                    Self.bindText(templateID, to: statement, index: 2)
                    sqlite3_bind_int64(statement, 3, Int64(version))
                }
            )
        }
    }

    public func template(templateID: String, version: Int) throws -> SoftwareTemplateRow? {
        try query(
            "SELECT \(Self.templateColumns) FROM software_templates WHERE template_id=? AND version=?",
            bind: { statement in
                Self.bindText(templateID, to: statement, index: 1)
                sqlite3_bind_int64(statement, 2, Int64(version))
            },
            map: { self.templateRow($0) }
        ).first
    }

    public func templateVersions(templateID: String) throws -> [SoftwareTemplateRow] {
        try query(
            "SELECT \(Self.templateColumns) FROM software_templates WHERE template_id=? ORDER BY version",
            bind: { Self.bindText(templateID, to: $0, index: 1) },
            map: { self.templateRow($0) }
        )
    }

    public func templates(state: TemplateState) throws -> [SoftwareTemplateRow] {
        try query(
            "SELECT \(Self.templateColumns) FROM software_templates WHERE state=? ORDER BY created_at",
            bind: { Self.bindText(state.rawValue, to: $0, index: 1) },
            map: { self.templateRow($0) }
        )
    }

    public func latestTemplate(templateID: String, state: TemplateState? = nil) throws -> SoftwareTemplateRow? {
        let rows = try templateVersions(templateID: templateID)
        return rows.last { row in
            guard let state else { return true }
            return row.state == state
        }
    }

    public func templatePackages(templateID: String, version: Int) throws -> [TemplatePackageRow] {
        try query(
            """
            SELECT template_id, version, name, package_version, architecture, source, install_state, digest
            FROM software_template_packages WHERE template_id=? AND version=? ORDER BY name
            """,
            bind: { statement in
                Self.bindText(templateID, to: statement, index: 1)
                sqlite3_bind_int64(statement, 2, Int64(version))
            }
        ) { statement in
            TemplatePackageRow(
                templateID: text(statement, 0) ?? "",
                version: Int(sqlite3_column_int64(statement, 1)),
                name: text(statement, 2) ?? "",
                packageVersion: text(statement, 3) ?? "",
                architecture: text(statement, 4),
                source: text(statement, 5),
                installState: text(statement, 6) ?? "",
                digest: text(statement, 7)
            )
        }
    }

    // MARK: template references (the GC protection boundary)

    public func addTemplateReference(
        templateID: String, version: Int, kind: String, refID: String
    ) throws {
        try transaction {
            try run(
                """
                INSERT INTO template_references (template_id, version, ref_kind, ref_id, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(template_id, version, ref_kind, ref_id) DO NOTHING
                """,
                bind: { statement in
                    Self.bindText(templateID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(version))
                    Self.bindText(kind, to: statement, index: 3)
                    Self.bindText(refID, to: statement, index: 4)
                    Self.bindText(Self.iso(Date()), to: statement, index: 5)
                }
            )
        }
    }

    public func removeTemplateReference(
        templateID: String, version: Int, kind: String, refID: String
    ) throws {
        try transaction {
            try run(
                "DELETE FROM template_references WHERE template_id=? AND version=? AND ref_kind=? AND ref_id=?",
                bind: { statement in
                    Self.bindText(templateID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(version))
                    Self.bindText(kind, to: statement, index: 3)
                    Self.bindText(refID, to: statement, index: 4)
                }
            )
        }
    }

    public func templateReferences(templateID: String, version: Int) throws -> [TemplateReferenceRow] {
        try query(
            """
            SELECT template_id, version, ref_kind, ref_id, created_at FROM template_references
            WHERE template_id=? AND version=? ORDER BY ref_kind, ref_id
            """,
            bind: { statement in
                Self.bindText(templateID, to: statement, index: 1)
                sqlite3_bind_int64(statement, 2, Int64(version))
            }
        ) { statement in
            TemplateReferenceRow(
                templateID: text(statement, 0) ?? "",
                version: Int(sqlite3_column_int64(statement, 1)),
                refKind: text(statement, 2) ?? "",
                refID: text(statement, 3) ?? "",
                createdAt: Self.date(text(statement, 4)) ?? Date.distantPast
            )
        }
    }

    /// Versions with zero references (all kinds) — GC candidates only.
    public func unreferencedTemplateVersions() throws -> [SoftwareTemplateRow] {
        try query(
            """
            SELECT \(Self.templateColumns) FROM software_templates t
            WHERE state='verified' AND NOT EXISTS (
              SELECT 1 FROM template_references r
              WHERE r.template_id=t.template_id AND r.version=t.version
            )
            ORDER BY created_at
            """,
            bind: nil,
            map: { self.templateRow($0) }
        )
    }

    /// The ONLY authority for collecting a template version. Every protection
    /// (state, grace window, template references, environment pins, held write
    /// leases) is revalidated inside ONE `BEGIN IMMEDIATE` transaction, and the
    /// state transition to `quarantined` plus the release of the version's one
    /// disk-blob reference commit together. A pin or reference inserted after
    /// any outside pre-check is therefore always seen: the row is never
    /// collected while something can still boot it.
    public func collectTemplateVersionIfUnreferenced(
        templateID: String, version: Int, grace: TimeInterval, now: Date
    ) throws -> TemplateCollectionOutcome {
        try transaction {
            let row: (state: String, diskDigest: String?, verifiedAt: Date?)? = try query(
                "SELECT state, disk_digest, verified_at FROM software_templates WHERE template_id=? AND version=?",
                bind: { statement in
                    Self.bindText(templateID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(version))
                }
            ) { statement in
                (text(statement, 0) ?? "", text(statement, 1), Self.date(text(statement, 2)))
            }.first
            guard let row else { return .skipped(reason: "no such template version") }
            guard row.state == "verified" else {
                return .skipped(reason: "state is \(row.state), not verified")
            }
            guard let diskDigest = row.diskDigest else {
                return .skipped(reason: "the verified version records no disk blob")
            }
            guard let verifiedAt = row.verifiedAt, now.timeIntervalSince(verifiedAt) >= grace else {
                return .skipped(reason: "within the GC grace window")
            }
            let referenceCount: Int = try query(
                """
                SELECT COUNT(*) FROM template_references WHERE template_id=? AND version=?
                """,
                bind: { statement in
                    Self.bindText(templateID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(version))
                }
            ) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
            guard referenceCount == 0 else {
                return .skipped(reason: "\(referenceCount) template reference(s)")
            }
            let heldLeases: Int = try query(
                """
                SELECT COUNT(*) FROM leases l JOIN environments e ON e.id=l.environment_id
                WHERE l.state='held' AND e.template_id=? AND e.template_version=?
                """,
                bind: { statement in
                    Self.bindText(templateID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(version))
                }
            ) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
            guard heldLeases == 0 else { return .skipped(reason: "held write lease") }
            let pinCount: Int = try query(
                "SELECT COUNT(*) FROM environments WHERE template_id=? AND template_version=?",
                bind: { statement in
                    Self.bindText(templateID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(version))
                }
            ) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
            guard pinCount == 0 else { return .skipped(reason: "environment pin") }

            try run(
                "UPDATE software_templates SET state='quarantined', reason=? WHERE template_id=? AND version=? AND state='verified'",
                bind: { statement in
                    Self.bindText(
                        "collected: no environment, catalog, build, recovery or quarantine reference after \(Int(grace))s",
                        to: statement, index: 1
                    )
                    Self.bindText(templateID, to: statement, index: 2)
                    sqlite3_bind_int64(statement, 3, Int64(version))
                }
            )
            guard sqlite3_changes(db) > 0 else {
                return .skipped(reason: "the version changed state concurrently")
            }
            let blob: (bytes: Int64, refs: Int)? = try query(
                "SELECT bytes, refs FROM blobs WHERE digest=?",
                bind: { Self.bindText(diskDigest, to: $0, index: 1) }
            ) { (sqlite3_column_int64($0, 0), Int(sqlite3_column_int($0, 1))) }.first
            try run(
                "UPDATE blobs SET refs = MAX(0, refs - 1) WHERE digest=?",
                bind: { Self.bindText(diskDigest, to: $0, index: 1) }
            )
            return .collected(
                diskDigest: diskDigest,
                blobBytes: blob?.bytes ?? 0,
                remainingBlobRefs: max(0, (blob?.refs ?? 0) - 1)
            )
        }
    }

    /// Records (or replaces) an environment's immutable template pin. ONE
    /// transaction: a held write lease refuses the change (an install state is
    /// never switched under a running guest), the previous environment
    /// reference row is replaced by exactly the new one (a stale reference to
    /// the abandoned version can never leak and keep it alive), and the
    /// environment row moves with it. Returns false when the environment does
    /// not exist; a pin is never invented for a missing row.
    @discardableResult
    public func pinEnvironmentTemplate(
        environmentID: String, templateID: String, version: Int, digest: String
    ) throws -> Bool {
        var updated = false
        try transaction {
            let existing = try query(
                "SELECT COUNT(*) FROM environments WHERE id=?",
                bind: { Self.bindText(environmentID, to: $0, index: 1) }
            ) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
            guard existing > 0 else { return }
            let heldLease = try query(
                "SELECT COUNT(*) FROM leases WHERE environment_id=? AND state='held'",
                bind: { Self.bindText(environmentID, to: $0, index: 1) }
            ) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
            guard heldLease == 0 else {
                throw RuntimeV2Error.templateEnvironmentRunning(environmentID: environmentID)
            }
            try run(
                "DELETE FROM template_references WHERE ref_kind='environment' AND ref_id=?",
                bind: { Self.bindText(environmentID, to: $0, index: 1) }
            )
            try run(
                """
                UPDATE environments SET template_id=?, template_version=?, template_digest=?,
                  last_used_at=? WHERE id=?
                """,
                bind: { statement in
                    Self.bindText(templateID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(version))
                    Self.bindText(digest, to: statement, index: 3)
                    Self.bindText(Self.iso(Date()), to: statement, index: 4)
                    Self.bindText(environmentID, to: statement, index: 5)
                }
            )
            try run(
                """
                INSERT INTO template_references (template_id, version, ref_kind, ref_id, created_at)
                VALUES (?, ?, 'environment', ?, ?)
                ON CONFLICT(template_id, version, ref_kind, ref_id) DO NOTHING
                """,
                bind: { statement in
                    Self.bindText(templateID, to: statement, index: 1)
                    sqlite3_bind_int64(statement, 2, Int64(version))
                    Self.bindText(environmentID, to: statement, index: 3)
                    Self.bindText(Self.iso(Date()), to: statement, index: 4)
                }
            )
            updated = true
        }
        return updated
    }

    /// Clears an environment's template pin. ONE transaction: a held write
    /// lease refuses the change and the environment reference row is removed
    /// with the pin. Returns false when no pin was set.
    @discardableResult
    public func unpinEnvironmentTemplate(environmentID: String) throws -> Bool {
        var updated = false
        try transaction {
            let pinned = try query(
                "SELECT COUNT(*) FROM environments WHERE id=? AND template_id IS NOT NULL",
                bind: { Self.bindText(environmentID, to: $0, index: 1) }
            ) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
            guard pinned > 0 else { return }
            let heldLease = try query(
                "SELECT COUNT(*) FROM leases WHERE environment_id=? AND state='held'",
                bind: { Self.bindText(environmentID, to: $0, index: 1) }
            ) { Int(sqlite3_column_int($0, 0)) }.first ?? 0
            guard heldLease == 0 else {
                throw RuntimeV2Error.templateEnvironmentRunning(environmentID: environmentID)
            }
            try run(
                "DELETE FROM template_references WHERE ref_kind='environment' AND ref_id=?",
                bind: { Self.bindText(environmentID, to: $0, index: 1) }
            )
            try run(
                """
                UPDATE environments SET template_id=NULL, template_version=NULL, template_digest=NULL,
                  last_used_at=? WHERE id=?
                """,
                bind: { statement in
                    Self.bindText(Self.iso(Date()), to: statement, index: 1)
                    Self.bindText(environmentID, to: statement, index: 2)
                }
            )
            updated = true
        }
        return updated
    }
}
