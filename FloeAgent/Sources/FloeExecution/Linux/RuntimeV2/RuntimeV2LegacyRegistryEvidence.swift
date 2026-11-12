// Bounded READONLY evidence. Never calls RuntimeV2Registry.open/prepare,
// changes a row, checkpoints, migrates, or trusts lease pid/ttl/state as closure.
import Foundation
import SQLite3
import FloeCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct RuntimeV2LegacyRegistryEvidence: Sendable {
    public let leaseEnvironmentIDs: [String]
    public let fingerprint: String
}

public enum RuntimeV2LegacyRegistryReader {
    private static let worker = RuntimeV2OptimizationWorker("floe.legacy-recovery.registry-evidence")
    public static func readAsync(domain: RuntimeV2MaintenanceDomain) async throws -> RuntimeV2LegacyRegistryEvidence {
        try await worker.run { try read(domain: domain) }
    }
    private final class Deadline {
        let started = ProcessInfo.processInfo.systemUptime
        var expired: Bool { ProcessInfo.processInfo.systemUptime - started >= 3 }
    }

    public static func read(domain: RuntimeV2MaintenanceDomain) throws -> RuntimeV2LegacyRegistryEvidence {
        let url = domain.root.appendingPathComponent("registry/runtime.sqlite")
        var named = stat()
        if lstat(url.path, &named) != 0 {
            guard errno == ENOENT else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_identity_unknown"])
            }
            return .init(leaseEnvironmentIDs: [], fingerprint: FloeDigest.sha256Hex(Data("no-registry".utf8)))
        }
        let before = try RuntimeV2DiskIdentity.read(at: url)
        func walIdentity() throws -> RuntimeV2DiskIdentity? {
            let wal = URL(fileURLWithPath: url.path + "-wal")
            var info = stat()
            if lstat(wal.path, &info) != 0 {
                if errno == ENOENT { return nil }
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_wal_identity_unknown"])
            }
            let observed = try RuntimeV2DiskIdentity.read(at: wal)
            guard observed.isRegularFile, observed.linkCount == 1,
                  observed.size == 0 || (observed.size >= 32 && observed.size <= 64 * 1_024 * 1_024),
                  RuntimeV2RecoveryAdmission.key(wal) == RuntimeV2RecoveryAdmission.key(domain.root) + "/registry/runtime.sqlite-wal" else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_wal_shape_unknown"])
            }
            return observed
        }
        let walBefore = try walIdentity()
        let shm = URL(fileURLWithPath: url.path + "-shm")
        var shmInfo = stat()
        if lstat(shm.path, &shmInfo) == 0 {
            let observed = try RuntimeV2DiskIdentity.read(at: shm)
            guard observed.isRegularFile, observed.linkCount == 1,
                  observed.size >= 0, observed.size <= 8 * 1_024 * 1_024,
                  RuntimeV2RecoveryAdmission.key(shm) == RuntimeV2RecoveryAdmission.key(domain.root) + "/registry/runtime.sqlite-shm" else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_shm_shape_unknown"])
            }
        } else if errno != ENOENT {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_shm_identity_unknown"])
        }
        guard before.isRegularFile, before.linkCount == 1, before.size > 0, before.size <= 64 * 1_024 * 1_024,
              RuntimeV2RecoveryAdmission.key(url) == RuntimeV2RecoveryAdmission.key(domain.root) + "/registry/runtime.sqlite" else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_shape_unknown"])
        }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_readonly_open_failed"])
        }
        var connectionClosed = false
        defer {
            if !connectionClosed {
                sqlite3_progress_handler(database, 0, nil, nil)
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                sqlite3_close_v2(database)
            }
        }
        guard sqlite3_db_readonly(database, "main") == 1 else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_not_readonly"])
        }
        sqlite3_busy_timeout(database, 250)
        let deadline = Deadline()
        sqlite3_progress_handler(database, 1000, { context in
            guard let context else { return 1 }
            return Unmanaged<Deadline>.fromOpaque(context).takeUnretainedValue().expired ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        func execute(_ sql: String) throws {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_snapshot_failed"])
            }
        }
        // A real WAL read snapshot; immutable=1 would wrongly ignore WAL.
        try execute("PRAGMA query_only=ON")
        try execute("PRAGMA trusted_schema=OFF")
        try execute("PRAGMA temp_store=MEMORY")
        try execute("BEGIN DEFERRED")
        var bindings: [String] = []
        var environments: [String] = []
        func rows(_ sql: String, process: (OpaquePointer) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_schema_unknown"])
            }
            defer { sqlite3_finalize(statement) }
            var count = 0
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { break }
                guard result == SQLITE_ROW, count < 4096, !deadline.expired else {
                    throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_bound_or_read_failed"])
                }
                count += 1
                try process(statement)
            }
        }
        func column(_ statement: OpaquePointer, _ index: Int32, bound: Int = 256) throws -> String {
            let count = Int(sqlite3_column_bytes(statement, index))
            guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
                  count > 0, count <= bound,
                  let bytes = sqlite3_column_text(statement, index),
                  let value = String(data: Data(bytes: bytes, count: count),
                                     encoding: .utf8), !value.utf8.contains(0) else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_field_unknown"])
            }
            return value
        }
        var journalMode: String?
        try rows("PRAGMA journal_mode") { journalMode = try column($0, 0, bound: 16) }
        if let walBefore, walBefore.size > 0, journalMode?.lowercased() != "wal" {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_wal_not_in_snapshot"])
        }
        // Tables must be ordinary native tables, not a view/virtual producer.
        var ordinaryTables: Set<String> = []
        try rows("SELECT name,type,sql FROM sqlite_master WHERE name IN ('leases','queue_entries')") { statement in
            let name = try column(statement, 0)
            let kind = try column(statement, 1)
            let sql = try column(statement, 2, bound: 4096)
            guard kind == "table", sql.uppercased().hasPrefix("CREATE TABLE") else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_table_unknown"])
            }
            ordinaryTables.insert(name)
        }
        guard ordinaryTables == Set(["leases", "queue_entries"]) else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_table_missing"])
        }
        try rows("SELECT environment_id,runtime_id,incarnation,session_token,state FROM leases ORDER BY environment_id LIMIT 4097") { statement in
            let environment = try column(statement, 0, bound: 128)
            let runtime = try column(statement, 1, bound: 128)
            let incarnation = try column(statement, 2, bound: 128)
            let token = try column(statement, 3, bound: 128)
            let state = try column(statement, 4, bound: 16)
            try RuntimeV2Identifier.validate(environment, kind: .environment)
            try RuntimeV2Identifier.validate(runtime, kind: .runtime)
            guard ["held", "stale", "released"].contains(state) else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_lease_state_unknown"])
            }
            environments.append(environment)
            // Only a digest of ownership fields leaves this function.
            // pid, timestamps and TTL are deliberately not queried as proof.
            bindings.append(FloeDigest.sha256Hex(Data(
                ["lease", environment, runtime, incarnation, token, state].joined(separator: "\0").utf8)))
        }
        try rows("SELECT id,environment_id,state FROM queue_entries ORDER BY id LIMIT 4097") { statement in
            let id = try column(statement, 0, bound: 128)
            let environment = try column(statement, 1, bound: 128)
            let state = try column(statement, 2, bound: 32)
            try RuntimeV2Identifier.validate(environment, kind: .environment)
            guard ["queued", "running", "done", "cancelled", "interrupted"].contains(state) else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_queue_state_unknown"])
            }
            bindings.append(FloeDigest.sha256Hex(Data(
                ["queue", id, environment, state].joined(separator: "\0").utf8)))
        }
        let after = try RuntimeV2DiskIdentity.read(at: url)
        guard before == after, try walIdentity() == walBefore, !deadline.expired else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_identity_changed"])
        }
        try execute("ROLLBACK")
        sqlite3_progress_handler(database, 0, nil, nil)
        guard sqlite3_close(database) == SQLITE_OK else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_readonly_connection_not_closed"])
        }
        connectionClosed = true
        return .init(leaseEnvironmentIDs: environments.sorted(),
                     fingerprint: FloeDigest.sha256Hex(Data(bindings.joined(separator: "\n").utf8)))
    }
}
