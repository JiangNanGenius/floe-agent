// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import GRDB
import FloePersistence
import FloeToolboxCore
import FloeToolboxFileTransports

/// Uses the App database transaction owner; queue bytes cannot grant a connection or folder lease.
nonisolated final class ToolboxTransferRepository: TransferQueueRepository, Sendable {
    private let database: DatabaseManager
    init(database: DatabaseManager) { self.database = database }
    private func prepare() async throws {
        try await database.writer { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS toolbox_transfer_queues (owner_id TEXT PRIMARY KEY NOT NULL, revision INTEGER NOT NULL, state BLOB NOT NULL)")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS toolbox_transfer_owners (target_key TEXT PRIMARY KEY NOT NULL, owner_id TEXT NOT NULL)")
        }
    }
    func owner(for target: String) async throws -> UUID {
        try await prepare()
        let proposed = UUID()
        return try await database.writer { db in
            try db.execute(sql: "INSERT INTO toolbox_transfer_owners(target_key,owner_id) VALUES (?,?) ON CONFLICT(target_key) DO NOTHING", arguments: [target, proposed.uuidString])
            guard let text = try String.fetchOne(db, sql: "SELECT owner_id FROM toolbox_transfer_owners WHERE target_key=?", arguments: [target]), let id = UUID(uuidString: text) else { throw ToolboxError.corruptStore }
            return id
        }
    }
    func load(ownerID: UUID) async throws -> TransferQueueState? {
        try await prepare()
        return try await database.reader { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT revision,state FROM toolbox_transfer_queues WHERE owner_id=?", arguments: [ownerID.uuidString]) else { return nil }
            let data: Data = row["state"], revision: Int64 = row["revision"]
            guard data.count <= 4 * 1_024 * 1_024, revision >= 0 else { throw ToolboxError.corruptStore }
            var state = try JSONDecoder().decode(TransferQueueState.self, from: data)
            guard state.ownerID == ownerID, state.revision == UInt64(revision), state.entries.count <= 128 else { throw ToolboxError.corruptStore }
            // Restoring or enqueuing another file must never silently replay an interrupted write.
            for index in state.entries.indices where [.queued, .running, .cancelling].contains(state.entries[index].phase) { state.entries[index].phase = .needsReview }
            return state
        }
    }
    func save(_ state: TransferQueueState, expectedRevision: UInt64) async throws {
        guard expectedRevision < UInt64(Int64.max) - 1, state.revision == expectedRevision + 1, state.entries.count <= 128 else { throw ToolboxError.revisionConflict }
        let data = try JSONEncoder().encode(state)
        guard data.count <= 4 * 1_024 * 1_024 else { throw ToolboxError.limit("transfer queue") }
        try await prepare()
        try await database.writer { db in
            if expectedRevision == 0 {
                try db.execute(sql: "INSERT INTO toolbox_transfer_queues(owner_id,revision,state) VALUES (?,?,?) ON CONFLICT(owner_id) DO NOTHING", arguments: [state.ownerID.uuidString, Int64(state.revision), data])
            } else {
                try db.execute(sql: "UPDATE toolbox_transfer_queues SET revision=?,state=? WHERE owner_id=? AND revision=?", arguments: [Int64(state.revision), data, state.ownerID.uuidString, Int64(expectedRevision)])
            }
            guard db.changesCount == 1 else { throw ToolboxError.revisionConflict }
        }
    }
}
#endif
