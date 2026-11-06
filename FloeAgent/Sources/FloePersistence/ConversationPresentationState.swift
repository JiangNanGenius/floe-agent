// SPDX-License-Identifier: MPL-2.0
import Foundation
import GRDB
import FloeCore

/// Value-only presentation state, owned by a real conversation/run. Executable
/// authority is never stored here. Keep includes these bytes in its transaction.
public struct ConversationPresentationState: Sendable {
    public var key: String
    public var conversationID: UUID
    public var runID: UUID
    public var sourceID: UUID
    public var digest: String
    public var revision: UInt64
    public var document: Data
    public var state: Data
    public init(key: String, conversationID: UUID, runID: UUID, sourceID: UUID,
                digest: String, revision: UInt64, document: Data, state: Data) {
        self.key = key; self.conversationID = conversationID; self.runID = runID; self.sourceID = sourceID
        self.digest = digest; self.revision = revision; self.document = document; self.state = state
    }
    public func validate() throws {
        guard key.count == 64, digest.count == 64, revision < UInt64(Int64.max),
              document.count <= 640 * 1_024, state.count <= 80 * 1_024 else {
            throw FloeError.validationFailed("Invalid conversation presentation")
        }
    }
}

public enum ConversationPresentationSQL {
    public static func prepare(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS conversation_presentations (
                content_key TEXT PRIMARY KEY NOT NULL,
                conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                source_id TEXT NOT NULL,
                digest TEXT NOT NULL,
                revision INTEGER NOT NULL CHECK(revision >= 0),
                document BLOB NOT NULL,
                state BLOB NOT NULL
            )
            """)
    }
    public static func read(_ key: String, db: Database) throws -> ConversationPresentationState? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversation_presentations WHERE content_key=?", arguments: [key]) else { return nil }
        guard let conversation = UUID(uuidString: row["conversation_id"]),
              let run = UUID(uuidString: row["run_id"]), let source = UUID(uuidString: row["source_id"]) else {
            throw FloeError.storageCorrupted("Presentation ownership")
        }
        let revision: Int64 = row["revision"]
        guard revision >= 0 else { throw FloeError.storageCorrupted("Presentation revision") }
        let value = ConversationPresentationState(key: key, conversationID: conversation, runID: run, sourceID: source,
            digest: row["digest"], revision: UInt64(revision), document: row["document"], state: row["state"])
        try value.validate(); return value
    }
    public static func write(_ value: ConversationPresentationState, expectedRevision: UInt64?, db: Database) throws {
        try value.validate(); try prepare(db)
        guard try String.fetchOne(db, sql: "SELECT conversation_id FROM runs WHERE id=?", arguments: [value.runID.uuidString]) == value.conversationID.uuidString else {
            throw FloeError.unauthorized
        }
        if let old = try read(value.key, db: db) {
            guard old.conversationID == value.conversationID, old.runID == value.runID,
                  old.sourceID == value.sourceID, old.digest == value.digest else { throw FloeError.unauthorized }
            if let expectedRevision {
                guard old.revision == expectedRevision, value.revision == expectedRevision + 1 else { throw FloeError.validationFailed("Presentation changed") }
            } else {
                // An atomic Keep retry adopts identical bytes, never an older snapshot.
                guard old.revision == value.revision, old.state == value.state, old.document == value.document else {
                    throw FloeError.validationFailed("Presentation changed during Keep")
                }
                return
            }
            try db.execute(sql: "UPDATE conversation_presentations SET revision=?,state=? WHERE content_key=? AND revision=?",
                arguments: [Int64(value.revision), value.state, value.key, Int64(old.revision)])
            guard db.changesCount == 1 else { throw FloeError.validationFailed("Presentation changed") }
        } else {
            if let expectedRevision { guard expectedRevision == 0, value.revision == 1 else { throw FloeError.validationFailed("Presentation changed") } }
            try db.execute(sql: "INSERT INTO conversation_presentations VALUES (?,?,?,?,?,?,?,?)", arguments: [value.key,
                value.conversationID.uuidString, value.runID.uuidString, value.sourceID.uuidString,
                value.digest, Int64(value.revision), value.document, value.state])
        }
    }
}
