// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import GRDB
import FloePersistence
import FloeToolboxCore

/// The journal uses the App's existing transaction owner. Exported snapshots
/// are copies; importing one never restores a connection or an authorization.
nonisolated struct ToolboxCaptureSummary: Identifiable, Sendable {
    let id: UUID
    let ownerID: UUID
    let title: String
    let kind: String
    let updatedAt: Date
}
nonisolated final class ToolboxCaptureStore: CaptureRepository, Sendable {
    private let database: DatabaseManager
    private let exportRoot: URL
    init(database: DatabaseManager, exportRoot: URL) {
        self.database = database; self.exportRoot = exportRoot
    }
    private func prepare() async throws {
        try await database.writer { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS toolbox_captures (
                    capture_id TEXT PRIMARY KEY NOT NULL,
                    owner_id TEXT NOT NULL,
                    revision INTEGER NOT NULL CHECK(revision > 0),
                    state BLOB NOT NULL
                )
                """)
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS toolbox_capture_index (capture_id TEXT PRIMARY KEY NOT NULL, owner_id TEXT NOT NULL, title TEXT NOT NULL, kind TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL)")
        }
    }
    static func exportsRoot() throws -> URL {
        try PersonalContentLibrary.applicationRoot().deletingLastPathComponent().appendingPathComponent("Toolbox/Exports", isDirectory: true)
    }
    private static func validate(_ state: CaptureState) throws {
        guard state.version == 1, state.records.count <= 100_000,
              state.retainedBytes <= 64 * 1_024 * 1_024,
              state.revision < UInt64(Int64.max),
              state.records.allSatisfy({ $0.bytes.count <= 1_024 * 1_024 && $0.originalByteCount >= $0.bytes.count && $0.notes.count <= 16 }) else {
            throw ToolboxError.corruptStore
        }
        var previous: UInt64 = 0
        for record in state.records {
            guard record.sequence > previous else { throw ToolboxError.corruptStore }
            previous = record.sequence
        }
        guard state.nextSequence > previous else { throw ToolboxError.corruptStore }
    }
    func load(captureID: UUID, ownerID: UUID) async throws -> CaptureState? {
        try await prepare()
        return try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT owner_id,revision,state FROM toolbox_captures WHERE capture_id=?",
                arguments: [captureID.uuidString]) else { return nil }
            let storedOwner: String = row["owner_id"], revision: Int64 = row["revision"], bytes: Data = row["state"]
            guard storedOwner == ownerID.uuidString else { throw ToolboxError.denied }
            guard bytes.count <= 128 * 1_024 * 1_024 else { throw ToolboxError.corruptStore }
            let state = try JSONDecoder().decode(CaptureState.self, from: bytes)
            try Self.validate(state)
            guard state.captureID == captureID, state.ownerID == ownerID, state.revision == UInt64(revision) else {
                throw ToolboxError.corruptStore
            }
            return state
        }
    }
    func commit(_ next: CaptureState, expectedRevision: UInt64) async throws {
        try Self.validate(next)
        guard expectedRevision < UInt64(Int64.max) - 1, next.revision == expectedRevision + 1 else {
            throw ToolboxError.revisionConflict
        }
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count <= 128 * 1_024 * 1_024 else { throw ToolboxError.limit("capture size") }
        try await prepare()
        try await database.writer { db in
            if expectedRevision == 0 {
                try db.execute(sql: "INSERT INTO toolbox_captures(capture_id,owner_id,revision,state) VALUES (?,?,?,?) ON CONFLICT(capture_id) DO NOTHING",
                    arguments: [next.captureID.uuidString, next.ownerID.uuidString, Int64(next.revision), bytes])
            } else {
                try db.execute(sql: "UPDATE toolbox_captures SET revision=?,state=? WHERE capture_id=? AND owner_id=? AND revision=?",
                    arguments: [Int64(next.revision), bytes, next.captureID.uuidString, next.ownerID.uuidString, Int64(expectedRevision)])
            }
            guard db.changesCount == 1 else { throw ToolboxError.revisionConflict }
            let now = Date().timeIntervalSince1970
            try db.execute(sql: "INSERT INTO toolbox_capture_index(capture_id,owner_id,title,kind,created_at,updated_at) VALUES (?,?,?,?,?,?) ON CONFLICT(capture_id) DO UPDATE SET updated_at=excluded.updated_at WHERE owner_id=excluded.owner_id",
                arguments: [next.captureID.uuidString, next.ownerID.uuidString, "Capture", "communication", now, now])
        }
    }
    func describe(captureID: UUID, ownerID: UUID, title: String, kind: String) async throws {
        try await prepare()
        let title = String(title.prefix(160)), kind = String(kind.prefix(32))
        try await database.writer { db in
            let now = Date().timeIntervalSince1970
            try db.execute(sql: "INSERT INTO toolbox_capture_index(capture_id,owner_id,title,kind,created_at,updated_at) VALUES (?,?,?,?,?,?) ON CONFLICT(capture_id) DO UPDATE SET title=excluded.title,kind=excluded.kind WHERE owner_id=excluded.owner_id",
                arguments: [captureID.uuidString, ownerID.uuidString, title, kind, now, now])
        }
    }
    func summaries() async throws -> [ToolboxCaptureSummary] {
        try await prepare()
        return try await database.reader { db in
            try Row.fetchAll(db, sql: "SELECT c.capture_id,c.owner_id,COALESCE(i.title,'Capture') AS title,COALESCE(i.kind,'communication') AS kind,COALESCE(i.updated_at,0) AS updated_at FROM toolbox_captures c LEFT JOIN toolbox_capture_index i ON c.capture_id=i.capture_id AND c.owner_id=i.owner_id ORDER BY updated_at DESC LIMIT 200").compactMap { row in
                let idText: String = row["capture_id"], ownerText: String = row["owner_id"]
                guard let id = UUID(uuidString: idText), let owner = UUID(uuidString: ownerText) else { return nil }
                return ToolboxCaptureSummary(id: id, ownerID: owner, title: row["title"], kind: row["kind"], updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
            }
        }
    }
    func saveSnapshot(_ state: CaptureState) async throws -> URL {
        try Self.validate(state)
        let bytes = try JSONEncoder().encode(state)
        guard bytes.count <= 128 * 1_024 * 1_024 else { throw ToolboxError.limit("snapshot size") }
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let target = exportRoot.appendingPathComponent("Capture-" + UUID().uuidString + ".json")
        try bytes.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }
}
#endif
