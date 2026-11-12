// Bounded READONLY source evidence. SQLite may create sidecars only for its
// owned temporary snapshot. Never opens/prepares, checkpoints, migrates or
// changes the live registry, or trusts lease pid/ttl/state as closure.
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
        let cancellation = RuntimeV2OptimizationCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await worker.run {
                try read(domain: domain, isCancelled: { cancellation.isCancelled }, afterSnapshot: nil)
            }
        } onCancel: { cancellation.cancel() }
    }
    private final class Deadline {
        let started = ProcessInfo.processInfo.systemUptime
        let isCancelled: @Sendable () -> Bool
        init(isCancelled: @escaping @Sendable () -> Bool) { self.isCancelled = isCancelled }
        var expired: Bool { isCancelled() || ProcessInfo.processInfo.systemUptime - started >= 3 }
        func check() throws {
            if isCancelled() { throw CancellationError() }
            guard !expired else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_bound_or_read_failed"])
            }
        }
    }

    public static func read(domain: RuntimeV2MaintenanceDomain) throws -> RuntimeV2LegacyRegistryEvidence {
        try read(domain: domain, isCancelled: { false }, afterSnapshot: nil)
    }
    #if DEBUG
    static func _read(domain: RuntimeV2MaintenanceDomain, afterSnapshot: @escaping (URL) throws -> Void)
        throws -> RuntimeV2LegacyRegistryEvidence {
        try read(domain: domain, isCancelled: { false }, afterSnapshot: afterSnapshot)
    }
    #endif

    private static func read(domain: RuntimeV2MaintenanceDomain,
                             isCancelled: @escaping @Sendable () -> Bool,
                             afterSnapshot: ((URL) throws -> Void)?) throws -> RuntimeV2LegacyRegistryEvidence {
        let deadline = Deadline(isCancelled: isCancelled)
        try deadline.check()
        let url = domain.root.appendingPathComponent("registry/runtime.sqlite")
        var named = stat()
        if lstat(url.path, &named) != 0 {
            guard errno == ENOENT else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_identity_unknown"])
            }
            return .init(leaseEnvironmentIDs: [], fingerprint: FloeDigest.sha256Hex(Data("no-registry".utf8)))
        }
        let before = try RuntimeV2DiskIdentity.read(at: url)
        let rollback = URL(fileURLWithPath: url.path + "-journal")
        func refuseRollbackJournal() throws {
            var value = stat()
            guard lstat(rollback.path, &value) != 0, errno == ENOENT else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_snapshot_failed"])
            }
        }
        try refuseRollbackJournal()
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
        // Opening a WAL-mode main file without sidecars READONLY can require
        // SQLite to create its WAL index. Never grant that write to the legacy
        // domain. Copy bounded, stable source bytes first; only this private
        // temporary snapshot may create sidecars. Existing WAL is included,
        // never bypassed with immutable=1 or rewritten headers.
        let (scratch, scratchIdentity) = try makeScratch()
        let snapshot = scratch.appendingPathComponent("runtime.sqlite")
        let outcome: Result<RuntimeV2LegacyRegistryEvidence, Error>
        do {
            let header = try copySource(url, to: snapshot, expected: before, deadline: deadline)
            var copiedWAL: URL?
            if let walBefore {
                let destination = URL(fileURLWithPath: snapshot.path + "-wal")
                _ = try copySource(URL(fileURLWithPath: url.path + "-wal"), to: destination,
                                   expected: walBefore, deadline: deadline)
                if walBefore.size > 0 { copiedWAL = destination }
            }
            try afterSnapshot?(scratch)
            if let copiedWAL { try validateWAL(copiedWAL, databaseHeader: header, deadline: deadline) }
            let evidence = try querySnapshot(snapshot, hasWAL: (walBefore?.size ?? 0) > 0,
                                             deadline: deadline, fixtureDiagnostics: afterSnapshot != nil)
            guard before == (try RuntimeV2DiskIdentity.read(at: url)), try walIdentity() == walBefore else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_identity_changed"])
            }
            try refuseRollbackJournal()
            try deadline.check()
            outcome = .success(evidence)
        } catch { outcome = .failure(error) }
        // querySnapshot's handles have closed before any deletion. Cleanup
        // failure is an explicit refusal, never a successful accumulating cache.
        let current = try RuntimeV2DiskIdentity.read(at: scratch)
        guard current.device == scratchIdentity.device, current.inode == scratchIdentity.inode,
              current.mode & UInt32(S_IFMT) == UInt32(S_IFDIR) else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_snapshot_failed"])
        }
        do { try FileManager.default.removeItem(at: scratch) }
        catch { throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_snapshot_failed"]) }
        return try outcome.get()
    }

    private static func makeScratch() throws -> (URL, RuntimeV2DiskIdentity) {
        // SQLite's NOFOLLOW checks every path component. Preserve the POSIX
        // spelling: Foundation standardization can fold /private/var back to
        // its /var alias after resolving it.
        guard let parent = FileManager.default.temporaryDirectory.path.withCString({ realpath($0, nil) }) else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_snapshot_failed"])
        }
        defer { free(parent) }
        var template = Array((String(cString: parent) + "/floe-legacy-reference-XXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_snapshot_failed"])
        }
        let directory = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        do { return (directory, try RuntimeV2DiskIdentity.read(at: directory)) }
        catch {
            do { try FileManager.default.removeItem(at: directory) }
            catch { throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_snapshot_failed"]) }
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_snapshot_failed"])
        }
    }

    private static func descriptorIdentity(_ fd: Int32) throws -> RuntimeV2DiskIdentity {
        var value = stat()
        guard fstat(fd, &value) == 0 else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_identity_unknown"])
        }
        #if canImport(Darwin)
        let modified = value.st_mtimespec, changed = value.st_ctimespec
        #else
        let modified = value.st_mtim, changed = value.st_ctim
        #endif
        return .init(device: UInt64(bitPattern: Int64(value.st_dev)), inode: UInt64(value.st_ino),
            size: Int64(value.st_size), linkCount: UInt64(value.st_nlink), mode: UInt32(value.st_mode),
            modificationSeconds: Int64(modified.tv_sec), modificationNanoseconds: Int64(modified.tv_nsec),
            changeSeconds: Int64(changed.tv_sec), changeNanoseconds: Int64(changed.tv_nsec))
    }

    /// Reuses the registry's existing 64 MiB/file bound. Streaming is required
    /// here for per-chunk cancellation and descriptor + named identity checks.
    private static func copySource(_ source: URL, to destination: URL, expected: RuntimeV2DiskIdentity,
                                   deadline: Deadline) throws -> Data {
        try deadline.check()
        guard expected.isRegularFile, expected.linkCount == 1, expected.size >= 0,
              expected.size <= 64 * 1_024 * 1_024 else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_shape_unknown"])
        }
        let input = open(source.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_snapshot_failed"])
        }
        defer { close(input) }
        guard try descriptorIdentity(input) == expected else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_identity_changed"])
        }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard output >= 0 else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_snapshot_failed"])
        }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 65_536), header = Data()
        var copied: Int64 = 0
        while copied < expected.size {
            try deadline.check()
            let amount = Int(min(Int64(buffer.count), expected.size - copied))
            let count = buffer.withUnsafeMutableBytes {
                #if canImport(Darwin)
                return Darwin.read(input, $0.baseAddress!, amount)
                #else
                return Glibc.read(input, $0.baseAddress!, amount)
                #endif
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_snapshot_failed"])
            }
            if header.count < 100 { header.append(contentsOf: buffer.prefix(min(count, 100 - header.count))) }
            var written = 0
            while written < count {
                try deadline.check()
                let n = buffer.withUnsafeBytes { write(output, $0.baseAddress!.advanced(by: written), count - written) }
                if n < 0, errno == EINTR { continue }
                guard n > 0 else {
                    throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_snapshot_failed"])
                }
                written += n
            }
            copied += Int64(count)
        }
        guard try descriptorIdentity(input) == expected, try RuntimeV2DiskIdentity.read(at: source) == expected else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_identity_changed"])
        }
        return header
    }

    /// SQLite may ignore an unrecognizable WAL. Do not turn such an unknown
    /// source into a clean registry. Validate the bounded copied WAL's header,
    /// frame salts and cumulative checksums before asking SQLite to replay it.
    /// Format: https://www.sqlite.org/fileformat2.html#wal_format
    private static func validateWAL(_ url: URL, databaseHeader: Data, deadline: Deadline) throws {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        func refuse() -> RuntimeV2MaintenanceError { .ownerEvidenceIncomplete(["legacy_wal_shape_unknown"]) }
        guard bytes.count >= 32, databaseHeader.count >= 20 else { throw refuse() }
        func word(_ offset: Int, bigEndian: Bool = true) -> UInt32 {
            let a = UInt32(bytes[offset]), b = UInt32(bytes[offset + 1])
            let c = UInt32(bytes[offset + 2]), d = UInt32(bytes[offset + 3])
            return bigEndian ? a << 24 | b << 16 | c << 8 | d : d << 24 | c << 16 | b << 8 | a
        }
        let magic = word(0), pageSize = Int(word(8))
        let dbSize = Int(databaseHeader[16]) << 8 | Int(databaseHeader[17])
        guard [UInt32(0x377f0682), UInt32(0x377f0683)].contains(magic), word(4) == 3_007_000,
              pageSize >= 512, pageSize <= 65_536, pageSize & (pageSize - 1) == 0,
              pageSize == (dbSize == 1 ? 65_536 : dbSize),
              (bytes.count - 32) % (pageSize + 24) == 0 else { throw refuse() }
        var first: UInt32 = 0, second: UInt32 = 0
        func checksum(_ offset: Int, _ count: Int) {
            for i in stride(from: offset, to: offset + count, by: 8) {
                first = first &+ word(i, bigEndian: magic == 0x377f0683) &+ second
                second = second &+ word(i + 4, bigEndian: magic == 0x377f0683) &+ first
            }
        }
        checksum(0, 24)
        guard first == word(24), second == word(28) else { throw refuse() }
        for frame in stride(from: 32, to: bytes.count, by: pageSize + 24) {
            try deadline.check()
            guard word(frame) > 0, word(frame + 8) == word(16), word(frame + 12) == word(20) else { throw refuse() }
            checksum(frame, 8); checksum(frame + 24, pageSize)
            guard first == word(frame + 16), second == word(frame + 20) else { throw refuse() }
        }
    }

    private static func querySnapshot(_ url: URL, hasWAL: Bool, deadline: Deadline, fixtureDiagnostics: Bool)
        throws -> RuntimeV2LegacyRegistryEvidence {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW
        let opened = sqlite3_open_v2(url.path, &database, flags, nil)
        #if DEBUG
        // Enabled only by the internal synchronous XCTest snapshot hook. Real
        // App calls always pass false; no source DB values are logged here.
        if fixtureDiagnostics {
            let actual = url.path.withCString { realpath($0, nil) }
            defer { if let actual { free(actual) } }
            let path = actual.map { String(cString: $0) } ?? "unavailable"
            let file = try? RuntimeV2DiskIdentity.read(at: url)
            let directory = try? RuntimeV2DiskIdentity.read(at: url.deletingLastPathComponent())
            let extended = database.map { sqlite3_extended_errcode($0) } ?? opened
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unavailable"
            print("Synthetic registry snapshot open: path=\(url.path), realpath=\(path), rc=\(opened), extended=\(extended), message=\(message), file=\(String(describing: file)), directory=\(String(describing: directory))")
        }
        #endif
        guard opened == SQLITE_OK, let database else {
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
        sqlite3_busy_timeout(database, 250)
        sqlite3_progress_handler(database, 1000, { context in
            guard let context else { return 1 }
            return Unmanaged<Deadline>.fromOpaque(context).takeUnretainedValue().expired ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        func execute(_ sql: String) throws {
            try deadline.check()
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                try deadline.check()
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_snapshot_failed"])
            }
        }
        // The only writable SQLite handle names the private copy. Query-only
        // is enabled before reading schema/data; source handles are POSIX RO.
        try execute("PRAGMA query_only=ON")
        var queryOnly: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA query_only", -1, &queryOnly, nil) == SQLITE_OK,
              let queryOnly else {
            if let queryOnly { sqlite3_finalize(queryOnly) }
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_not_readonly"])
        }
        let isQueryOnly = sqlite3_step(queryOnly) == SQLITE_ROW && sqlite3_column_int(queryOnly, 0) == 1
        sqlite3_finalize(queryOnly)
        guard isQueryOnly else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_not_readonly"])
        }
        try execute("PRAGMA trusted_schema=OFF")
        try execute("PRAGMA temp_store=MEMORY")
        try execute("BEGIN DEFERRED")
        var bindings: [String] = []
        var environments: [String] = []
        func rows(_ sql: String, process: (OpaquePointer) throws -> Void) throws {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                if let statement { sqlite3_finalize(statement) }
                throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_registry_schema_unknown"])
            }
            defer { sqlite3_finalize(statement) }
            var count = 0
            while true {
                try deadline.check()
                let result = sqlite3_step(statement)
                try deadline.check()
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
        if hasWAL, journalMode?.lowercased() != "wal" {
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
        try execute("ROLLBACK")
        sqlite3_progress_handler(database, 0, nil, nil)
        guard sqlite3_close(database) == SQLITE_OK else {
            throw RuntimeV2MaintenanceError.ownerEvidenceIncomplete(["legacy_readonly_connection_not_closed"])
        }
        connectionClosed = true
        try deadline.check()
        return .init(leaseEnvironmentIDs: environments.sorted(),
                     fingerprint: FloeDigest.sha256Hex(Data(bindings.joined(separator: "\n").utf8)))
    }
}
