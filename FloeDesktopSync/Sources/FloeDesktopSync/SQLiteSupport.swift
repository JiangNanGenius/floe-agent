import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#endif

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A single SQLite connection confined to the `SyncStore` actor. SQLite
/// statements are prepared per call; the actor is the serialization point.
final class SQLiteConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    private(set) var isClosed = false
    let path: String

    init(path: String) throws {
        self.path = path
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown open failure"
            if let database { sqlite3_close_v2(database) }
            throw SyncStoreError.openFailed(path: path, message: message)
        }
        handle = database
        sqlite3_busy_timeout(database, 5_000)
        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA foreign_keys = ON")
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func close() {
        guard !isClosed, let handle else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
        isClosed = true
    }

    func execute(_ sql: String) throws {
        guard !isClosed, let handle else { throw SyncStoreError.closed }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK else { throw failure(result) }
        defer { sqlite3_finalize(statement) }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW { continue }
            if step == SQLITE_DONE { return }
            throw failure(step)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard !isClosed, let handle else { throw SyncStoreError.closed }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw failure(result) }
        return SQLiteStatement(handle: statement, database: handle)
    }

    func userVersionValue() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version")
        guard try statement.step() else { return 0 }
        return Int32(statement.int64(0) ?? 0)
    }

    func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    var lastInsertRowID: Int64 {
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    var changedRowCount: Int {
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    private func failure(_ code: Int32) -> SyncStoreError {
        let message: String
        if let handle {
            message = String(cString: sqlite3_errmsg(handle))
        } else {
            message = "database is closed"
        }
        return SyncStoreError.sqliteFailure(code: code, message: message)
    }
}

final class SQLiteStatement {
    private var handle: OpaquePointer?
    private let database: OpaquePointer

    init(handle: OpaquePointer, database: OpaquePointer) {
        self.handle = handle
        self.database = database
    }

    deinit {
        sqlite3_finalize(handle)
    }

    func bind(_ index: Int, _ value: String) throws {
        guard let handle else { throw SyncStoreError.closed }
        let result = value.withCString {
            sqlite3_bind_text(handle, Int32(index), $0, -1, sqliteTransient)
        }
        guard result == SQLITE_OK else { throw failure(result) }
    }

    func bind(_ index: Int, _ value: Int64) throws {
        guard let handle else { throw SyncStoreError.closed }
        let result = sqlite3_bind_int64(handle, Int32(index), value)
        guard result == SQLITE_OK else { throw failure(result) }
    }

    func bind(_ index: Int, _ value: [UInt8]) throws {
        guard let handle else { throw SyncStoreError.closed }
        let result: Int32
        if value.isEmpty {
            result = sqlite3_bind_zeroblob(handle, Int32(index), 0)
        } else {
            result = value.withUnsafeBytes {
                sqlite3_bind_blob(handle, Int32(index), $0.baseAddress, Int32($0.count), sqliteTransient)
            }
        }
        guard result == SQLITE_OK else { throw failure(result) }
    }

    func bindNull(_ index: Int) throws {
        guard let handle else { throw SyncStoreError.closed }
        let result = sqlite3_bind_null(handle, Int32(index))
        guard result == SQLITE_OK else { throw failure(result) }
    }

    func step() throws -> Bool {
        guard let handle else { throw SyncStoreError.closed }
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SyncStoreError.sqliteFailure(
                code: result,
                message: String(cString: sqlite3_errmsg(database))
            )
        }
    }

    func reset() {
        guard let handle else { return }
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func isNull(_ column: Int) -> Bool {
        guard let handle else { return true }
        return sqlite3_column_type(handle, Int32(column)) == SQLITE_NULL
    }

    func text(_ column: Int) -> String? {
        guard let handle,
              let pointer = sqlite3_column_text(handle, Int32(column)) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(handle, Int32(column)))
        return String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    /// Reject invalid source bytes instead of silently substituting Unicode
    /// replacement characters when exporting canonical user content.
    func strictUTF8Text(_ column: Int) -> String? {
        guard let handle,
              let pointer = sqlite3_column_text(handle, Int32(column)) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(handle, Int32(column)))
        return String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8)
    }

    func int64(_ column: Int) -> Int64? {
        guard let handle, !isNull(column) else { return nil }
        return sqlite3_column_int64(handle, Int32(column))
    }

    func blob(_ column: Int) -> [UInt8]? {
        guard let handle,
              let pointer = sqlite3_column_blob(handle, Int32(column)) else {
            return nil
        }
        let count = Int(sqlite3_column_bytes(handle, Int32(column)))
        return [UInt8](UnsafeRawBufferPointer(start: pointer, count: count))
    }

    private func failure(_ code: Int32) -> SyncStoreError {
        SyncStoreError.sqliteFailure(
            code: code,
            message: String(cString: sqlite3_errmsg(database))
        )
    }
}
