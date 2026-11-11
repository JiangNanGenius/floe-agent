// SPDX-License-Identifier: MPL-2.0
import Foundation
import GRDB

/// JSON helper for nested Codable columns (source references, capabilities).
/// The database engine, WAL and transactions are GRDB's; JSON is only the
/// payload encoding for compound values, not a storage engine.
enum MeetingRecordCodec {
    static func json<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}

// MARK: - Meeting

struct MeetingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "meetings"
    var id: String
    var title: String
    var status: String
    var capabilitiesJSON: String
    var createdAt: Date
    var updatedAt: Date
}

// MARK: - Capture session

struct CaptureSessionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "capture_sessions"
    var id: String
    var meetingID: String
    var kind: String
    var state: String
    var directory: String?
    var sourceFile: String?
    var durationSeconds: Double?
    var startedAt: Date?
    var endedAt: Date?
    var stopReason: String?
    /// Analysis sessions imported from one original capture record that
    /// original's id here (trusted lineage; nil for standalone imports).
    var originSessionID: String? = nil
}

// MARK: - Speakers

struct SpeakerRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "speakers"
    var id: String
    var meetingID: String
    var label: String
    var userNamed: Bool
    var mergedInto: String?
}

/// One engine-label → stable speaker mapping, scoped to ONE real recognition
/// request. Providers restart their speaker numbering on every new request or
/// reconnect, so a "1" from an independent request must never be assumed to
/// be the same person; the scope is the identity of the actual ASR request
/// (one live-chunk attempt's request key, or one whole-file analysis session).
struct SpeakerBindingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "speaker_bindings"
    var meetingID: String
    var scope: String
    var providerLabel: String
    var speakerID: String
}

// MARK: - Transcript

struct TranscriptSegmentRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transcript_segments"
    var id: String
    var meetingID: String
    var sessionID: String
    var speakerID: String?
    var ordinal: Int
    var startSeconds: Double
    var endSeconds: Double
    var text: String
    var originalText: String?
    var correctedBy: String?
    var speakerCorrected: Bool
    // Keep superseded engine rows for existing segment references.
    var superseded: Bool = false
    /// Stable identity of one utterance within ONE live request domain
    /// (`<scope UUID>|<start ms>|<end ms>`); nil for file/canonical rows.
    var liveKey: String? = nil
    var language: String?
    var sourceJSON: String
}

// MARK: - Notes & markers

struct NoteRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "notes"
    var id: String
    var meetingID: String
    var body: String
    var author: String
    var sourceJSON: String
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
}

struct MarkerRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "markers"
    var id: String
    var meetingID: String
    var label: String?
    var sourceJSON: String
    var createdAt: Date
}

// MARK: - Todos, decisions, summaries

struct TodoRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "todos"
    var id: String
    var meetingID: String
    var text: String
    var normalizedText: String
    var status: String
    var origin: String
    var userModified: Bool
    var sourceJSON: String
    var createdAt: Date
    var updatedAt: Date
}

struct DecisionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "decisions"
    var id: String
    var meetingID: String
    var text: String
    var sourceJSON: String
    var createdAt: Date
}

struct SummaryRecordRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "summaries"
    var id: String
    var meetingID: String
    var kind: String
    var text: String
    var windowJSON: String?
    var createdAt: Date
}

/// Actor-isolated GRDB facade. WAL, serialization and transactions belong to
/// GRDB; every multi-row write runs inside one `write` transaction so a crash
/// mid-write cannot produce a half-committed meeting.
public actor MeetingDatabase {
    let pool: DatabasePool
    /// Internal deterministic test seam, always awaited before acquiring the
    /// commit permit. Production leaves it nil; revocation never waits on it.
    var beforeLiveTranscriptCommit: (@Sendable () async -> Void)?

    public init(path: String) throws {
        do {
            pool = try DatabasePool(path: path)
            try Self.migrate(pool)
        } catch {
            throw MeetingError.persistenceFailed(String(describing: error))
        }
    }

    static func migrate(_ pool: DatabasePool) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "meetings") { table in
                table.column("id", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("status", .text).notNull()
                table.column("capabilitiesJSON", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "capture_sessions") { table in
                table.column("id", .text).primaryKey()
                table.column("meetingID", .text).notNull().indexed()
                    .references("meetings", onDelete: .cascade)
                table.column("kind", .text).notNull()
                table.column("state", .text).notNull()
                table.column("directory", .text)
                table.column("sourceFile", .text)
                table.column("startedAt", .datetime)
                table.column("endedAt", .datetime)
                table.column("stopReason", .text)
            }
            try db.create(table: "speakers") { table in
                table.column("id", .text).primaryKey()
                table.column("meetingID", .text).notNull().indexed()
                    .references("meetings", onDelete: .cascade)
                table.column("label", .text).notNull()
                table.column("userNamed", .boolean).notNull().defaults(to: false)
                table.column("mergedInto", .text)
            }
            try db.create(table: "transcript_segments") { table in
                table.column("id", .text).primaryKey()
                table.column("meetingID", .text).notNull().indexed()
                    .references("meetings", onDelete: .cascade)
                table.column("sessionID", .text).notNull().indexed()
                table.column("speakerID", .text).indexed()
                table.column("ordinal", .integer).notNull()
                table.column("startSeconds", .double).notNull()
                table.column("endSeconds", .double).notNull()
                table.column("text", .text).notNull()
                table.column("originalText", .text)
                table.column("correctedBy", .text)
                table.column("language", .text)
                table.column("sourceJSON", .text).notNull()
            }
            try db.create(table: "notes") { table in
                table.column("id", .text).primaryKey()
                table.column("meetingID", .text).notNull().indexed()
                    .references("meetings", onDelete: .cascade)
                table.column("body", .text).notNull()
                table.column("author", .text).notNull()
                table.column("sourceJSON", .text).notNull()
                table.column("revision", .integer).notNull().defaults(to: 0)
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "markers") { table in
                table.column("id", .text).primaryKey()
                table.column("meetingID", .text).notNull().indexed()
                    .references("meetings", onDelete: .cascade)
                table.column("label", .text)
                table.column("sourceJSON", .text).notNull()
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "todos") { table in
                table.column("id", .text).primaryKey()
                table.column("meetingID", .text).notNull().indexed()
                    .references("meetings", onDelete: .cascade)
                table.column("text", .text).notNull()
                table.column("normalizedText", .text).notNull()
                table.column("status", .text).notNull()
                table.column("origin", .text).notNull()
                table.column("userModified", .boolean).notNull().defaults(to: false)
                table.column("sourceJSON", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(index: "todos_dedup", on: "todos", columns: ["meetingID", "normalizedText"])
            try db.create(table: "decisions") { table in
                table.column("id", .text).primaryKey()
                table.column("meetingID", .text).notNull().indexed()
                    .references("meetings", onDelete: .cascade)
                table.column("text", .text).notNull()
                table.column("sourceJSON", .text).notNull()
                table.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "summaries") { table in
                table.column("id", .text).primaryKey()
                table.column("meetingID", .text).notNull().indexed()
                    .references("meetings", onDelete: .cascade)
                table.column("kind", .text).notNull()
                table.column("text", .text).notNull()
                table.column("windowJSON", .text)
                table.column("createdAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2-import-duration") { db in
            try db.alter(table: "capture_sessions") { table in
                table.add(column: "durationSeconds", .double)
            }
        }
        migrator.registerMigration("v3-speaker-bindings") { db in
            try db.create(table: "speaker_bindings") { table in
                table.column("meetingID", .text).notNull().indexed()
                    .references("meetings", onDelete: .cascade)
                table.column("scope", .text).notNull().indexed()
                table.column("providerLabel", .text).notNull()
                table.column("speakerID", .text).notNull().indexed()
                table.primaryKey(["meetingID", "scope", "providerLabel"])
            }
        }
        migrator.registerMigration("v4-segment-speaker-correction") { db in
            // 1 = the user corrected this segment's speaker attribution; a
            // later canonical transcription pass must not overwrite it.
            try db.alter(table: "transcript_segments") { table in
                table.add(column: "speakerCorrected", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v5-canonical-transcript-history") { db in
            try db.alter(table: "transcript_segments") { table in
                table.add(column: "superseded", .boolean).notNull().defaults(to: false)
            }
        }
        // W7 continuous live recognition. Both columns are additive and
        // nullable; every pre-existing row keeps NULL and behaves exactly as
        // before. `originSessionID` records, at import time, which original
        // capture an analysis session belongs to — the trusted lineage that
        // scopes duplicate detection to ONE original recording (two originals
        // of one meeting may share time ranges without ever deduping each
        // other). `liveKey` is the stable identity of one utterance inside
        // ONE live request domain (`<scope UUID>|<start ms>|<end ms>`); a
        // re-commit of the same key adopts revised text/speaker in the same
        // write transaction unless the user corrected that field, while an
        // overlapping range from a DIFFERENT key stays a no-op.
        migrator.registerMigration("v6-continuous-live-lineage") { db in
            try db.alter(table: "capture_sessions") { table in
                table.add(column: "originSessionID", .text)
            }
            try db.create(index: "capture_sessions_origin", on: "capture_sessions", columns: ["originSessionID"])
            try db.alter(table: "transcript_segments") { table in
                table.add(column: "liveKey", .text)
            }
            try db.create(index: "transcript_segments_livekey", on: "transcript_segments", columns: ["meetingID", "liveKey"])
        }
        try migrator.migrate(pool)
    }
}
