// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import GRDB
import FloeCore
import FloePersistence
import FloeAgentRuntime

/// Rebuildable derived indexes live in the existing App database. Source owners stay authoritative.
nonisolated final class GlobalSourceIndexStore: Sendable {
    let database: DatabaseManager
    init(database: DatabaseManager) { self.database = database }
    func prepare() async throws {
        try await database.writer { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS global_memory_sources(id TEXT PRIMARY KEY NOT NULL, provider_id TEXT NOT NULL, owner_id TEXT NOT NULL, revision TEXT NOT NULL, descriptor BLOB NOT NULL, available INTEGER NOT NULL, excluded INTEGER NOT NULL DEFAULT 0, seen_token TEXT, indexed_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS global_memory_chunks(id TEXT PRIMARY KEY NOT NULL, source_id TEXT NOT NULL REFERENCES global_memory_sources(id) ON DELETE CASCADE, revision TEXT NOT NULL, ordinal INTEGER NOT NULL, offset INTEGER NOT NULL, text TEXT NOT NULL, digest TEXT NOT NULL, vector BLOB, model TEXT, model_revision TEXT);
                CREATE INDEX IF NOT EXISTS global_memory_chunks_source ON global_memory_chunks(source_id);
                CREATE VIRTUAL TABLE IF NOT EXISTS global_memory_fts USING fts5(chunk_id UNINDEXED, title, text, tokenize='unicode61');
                CREATE TABLE IF NOT EXISTS global_memory_jobs(source_id TEXT PRIMARY KEY NOT NULL, revision TEXT NOT NULL, phase TEXT NOT NULL, attempt INTEGER NOT NULL DEFAULT 0, next_attempt REAL NOT NULL DEFAULT 0);
                CREATE TABLE IF NOT EXISTS global_memory_links(memory_id TEXT NOT NULL, source_id TEXT NOT NULL, source_revision TEXT NOT NULL, owner_id TEXT NOT NULL, locator TEXT NOT NULL, quote_digest TEXT NOT NULL, PRIMARY KEY(memory_id,source_id));
                CREATE TABLE IF NOT EXISTS global_memory_suppression(digest TEXT PRIMARY KEY NOT NULL, created_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS global_memory_controls(id INTEGER PRIMARY KEY CHECK(id=1), paused INTEGER NOT NULL DEFAULT 0, local_text_fallback INTEGER NOT NULL DEFAULT 0);
                INSERT OR IGNORE INTO global_memory_controls(id) VALUES (1);
                """)
        }
    }
    func source(_ id: String) async throws -> GlobalSourceDescriptor? {
        try await database.reader { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT descriptor FROM global_memory_sources WHERE id=?", arguments: [id]) else { return nil }
            return try JSONDecoder().decode(GlobalSourceDescriptor.self, from: data)
        }
    }
    func isExcluded(_ id: String) async throws -> Bool {
        try await database.reader { db in (try Bool.fetchOne(db, sql: "SELECT excluded FROM global_memory_sources WHERE id=?", arguments: [id])) ?? false }
    }
    func touch(_ source: GlobalSourceDescriptor, token: String) async throws -> Bool {
        let descriptor = try JSONEncoder().encode(source)
        return try await database.writer { db in
            let current = try Row.fetchOne(db, sql: "SELECT revision,excluded FROM global_memory_sources WHERE id=?", arguments: [source.id])
            let excluded: Bool = current?["excluded"] ?? false, revision: String? = current?["revision"]
            try db.execute(sql: "INSERT INTO global_memory_sources(id,provider_id,owner_id,revision,descriptor,available,excluded,seen_token,indexed_at) VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET descriptor=excluded.descriptor,seen_token=excluded.seen_token,available=excluded.available",
                arguments: [source.id, source.providerID, source.ownerID, "", descriptor, revision == source.revision, excluded, token, Date().timeIntervalSince1970])
            return !excluded && revision != source.revision
        }
    }
    func replace(_ snapshot: GlobalSourceSnapshot, chunks: [GlobalSourceChunk], seenToken: String, queueSummary: Bool = true) async throws {
        guard chunks.count <= 1_000 else { throw GlobalSourceJobError.unavailable }
        let descriptor = try JSONEncoder().encode(snapshot.source)
        try await database.writer { db in
            guard (try Bool.fetchOne(db, sql: "SELECT excluded FROM global_memory_sources WHERE id=?", arguments: [snapshot.source.id])) != true else { throw GlobalSourceJobError.excluded }
            try db.execute(sql: "DELETE FROM global_memory_fts WHERE chunk_id IN (SELECT id FROM global_memory_chunks WHERE source_id=?)", arguments: [snapshot.source.id])
            try db.execute(sql: "DELETE FROM global_memory_chunks WHERE source_id=?", arguments: [snapshot.source.id])
            for chunk in chunks {
                let vector = try chunk.vector.map { try JSONEncoder().encode($0) }
                try db.execute(sql: "INSERT INTO global_memory_chunks(id,source_id,revision,ordinal,offset,text,digest,vector,model,model_revision) VALUES (?,?,?,?,?,?,?,?,?,?)", arguments: [chunk.id, chunk.sourceID, chunk.revision, chunk.ordinal, chunk.offset, chunk.text, chunk.digest, vector, chunk.vectorModel, chunk.vectorRevision])
                try db.execute(sql: "INSERT INTO global_memory_fts(chunk_id,title,text) VALUES (?,?,?)", arguments: [chunk.id, snapshot.source.title, chunk.text])
            }
            try db.execute(sql: "UPDATE global_memory_sources SET revision=?,descriptor=?,available=1,seen_token=?,indexed_at=? WHERE id=?", arguments: [snapshot.source.revision, descriptor, seenToken, Date().timeIntervalSince1970, snapshot.source.id])
            if queueSummary { try db.execute(sql: "INSERT INTO global_memory_jobs(source_id,revision,phase) VALUES (?,?,'queued') ON CONFLICT(source_id) DO UPDATE SET revision=excluded.revision,phase='queued',attempt=0,next_attempt=0", arguments: [snapshot.source.id, snapshot.source.revision]) }
        }
    }
    func needsVectors(sourceID: String, model: String, revision: String) async throws -> Bool {
        try await database.reader { db in
            (try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM global_memory_chunks WHERE source_id=? AND (vector IS NULL OR model<>? OR model_revision<>?))", arguments: [sourceID, model, revision])) ?? false
        }
    }
    func forgetLinkedSources(memoryID: UUID) async throws {
        try await database.writer { db in
            let ids = try String.fetchAll(db, sql: "SELECT source_id FROM global_memory_links WHERE memory_id=?", arguments: [memoryID.uuidString])
            for id in ids { try Self.removeBody(id, db: db); try db.execute(sql: "UPDATE global_memory_sources SET excluded=1 WHERE id=?", arguments: [id]) }
        }
    }
    func markMissing(provider: String, seenToken: String, unavailableOwners: Set<String> = []) async throws {
        try await database.writer { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id,owner_id FROM global_memory_sources WHERE provider_id=? AND (seen_token IS NULL OR seen_token<>?) AND available=1", arguments: [provider, seenToken])
            for row in rows {
                let id: String = row["id"], owner: String = row["owner_id"]
                try Self.removeBody(id, db: db, ownerDeleted: !unavailableOwners.contains(owner))
            }
            // Derived durable memories remain under the existing lifecycle policy.
        }
    }
    private static func removeBody(_ id: String, db: Database, ownerDeleted: Bool = true) throws {
        try db.execute(sql: "DELETE FROM global_memory_fts WHERE chunk_id IN (SELECT id FROM global_memory_chunks WHERE source_id=?)", arguments: [id])
        try db.execute(sql: "DELETE FROM global_memory_chunks WHERE source_id=?", arguments: [id])
        try db.execute(sql: "DELETE FROM global_memory_jobs WHERE source_id=?", arguments: [id])
        try db.execute(sql: "UPDATE global_memory_sources SET available=0,revision='' WHERE id=?", arguments: [id])
        if ownerDeleted { try db.execute(sql: "UPDATE memory_entries SET owner_deleted_at=COALESCE(owner_deleted_at,?) WHERE id IN (SELECT memory_id FROM global_memory_links WHERE source_id=?) AND NOT EXISTS (SELECT 1 FROM global_memory_links l JOIN global_memory_sources s ON s.id=l.source_id WHERE l.memory_id=memory_entries.id AND s.available=1)", arguments: [Date().ISO8601Format(), id]) }
    }
    func removeSource(_ id: String) async throws { try await database.writer { db in try Self.removeBody(id, db: db) } }
    func exclude(_ id: String, excluded: Bool) async throws {
        try await database.writer { db in
            if excluded { try Self.removeBody(id, db: db) }
            try db.execute(sql: "UPDATE global_memory_sources SET excluded=?,revision=CASE WHEN ?=0 THEN '' ELSE revision END WHERE id=?", arguments: [excluded, excluded, id])
        }
    }
    func lexical(_ query: String, limit: Int = 80) async throws -> [(GlobalSourceDescriptor, GlobalSourceChunk)] {
        let words = query.split { !$0.isLetter && !$0.isNumber }.map(String.init).prefix(12)
        let match = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " OR ")
        let literal = "%" + query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
        let fts = match.isEmpty ? "" : "c.id IN (SELECT chunk_id FROM global_memory_fts WHERE global_memory_fts MATCH ? LIMIT 200) OR "
        var arguments: StatementArguments = []
        if !match.isEmpty { arguments += [match] }
        arguments += [literal, literal, min(200, max(1, limit))]
        let boundArguments = arguments
        return try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.descriptor,c.* FROM global_memory_chunks c JOIN global_memory_sources s ON s.id=c.source_id
                WHERE s.available=1 AND s.excluded=0 AND c.revision=s.revision AND
                (\(fts)c.text LIKE ? ESCAPE '\\' OR CAST(s.descriptor AS TEXT) LIKE ? ESCAPE '\\') LIMIT ?
                """, arguments: boundArguments)
            return try rows.map(Self.decodeChunk)
        }
    }

    func semanticCandidates(model: String, revision: String) async throws -> [(GlobalSourceDescriptor, GlobalSourceChunk)] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: "SELECT s.descriptor,c.* FROM global_memory_chunks c JOIN global_memory_sources s ON s.id=c.source_id WHERE s.available=1 AND s.excluded=0 AND c.revision=s.revision AND c.model=? AND c.model_revision=? ORDER BY s.indexed_at DESC LIMIT 4000", arguments: [model, revision]).map(Self.decodeChunk)
        }
    }
    private static func decodeChunk(_ row: Row) throws -> (GlobalSourceDescriptor, GlobalSourceChunk) {
        let data: Data = row["descriptor"], vector: Data? = row["vector"]
        return (try JSONDecoder().decode(GlobalSourceDescriptor.self, from: data), GlobalSourceChunk(id: row["id"], sourceID: row["source_id"], revision: row["revision"], ordinal: row["ordinal"], offset: row["offset"], text: row["text"], digest: row["digest"], vector: try vector.map { try JSONDecoder().decode([Float].self, from: $0) }, vectorModel: row["model"], vectorRevision: row["model_revision"]))
    }
    func jobs(limit: Int = 8) async throws -> [(GlobalSourceDescriptor, String)] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: "SELECT s.descriptor,j.revision FROM global_memory_jobs j JOIN global_memory_sources s ON s.id=j.source_id WHERE s.available=1 AND s.excluded=0 AND j.phase<>'completed' AND j.next_attempt<=? ORDER BY j.next_attempt LIMIT ?", arguments: [Date().timeIntervalSince1970, limit]).map { row in
                let data: Data = row["descriptor"]; return (try JSONDecoder().decode(GlobalSourceDescriptor.self, from: data), row["revision"])
            }
        }
    }
    func finishJob(_ source: GlobalSourceDescriptor, success: Bool, missingModel: Bool = false) async throws {
        try await database.writer { db in
            try db.execute(sql: "UPDATE global_memory_jobs SET phase=?,attempt=attempt+1,next_attempt=? WHERE source_id=? AND revision=?", arguments: [success ? "completed" : missingModel ? "waitingModel" : "retry", Date().addingTimeInterval(missingModel ? 300 : 60).timeIntervalSince1970, source.id, source.revision])
        }
    }
    func link(memoryID: UUID, source: GlobalSourceDescriptor, quote: String) async throws {
        try await database.writer { db in
            try db.execute(sql: "INSERT INTO global_memory_links(memory_id,source_id,source_revision,owner_id,locator,quote_digest) VALUES (?,?,?,?,?,?) ON CONFLICT(memory_id,source_id) DO UPDATE SET source_revision=excluded.source_revision,locator=excluded.locator,quote_digest=excluded.quote_digest", arguments: [memoryID.uuidString, source.id, source.revision, source.ownerID, source.locator, MemoryContentDigest.make(quote)])
            try db.execute(sql: "UPDATE memory_entries SET owner_deleted_at=NULL WHERE id=?", arguments: [memoryID.uuidString])
        }
    }
    static func suppressionDigest(_ text: String) -> String { MemoryContentDigest.make(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).split(whereSeparator: \.isWhitespace).joined(separator: " ")) }
    func suppressed(_ text: String) async throws -> Bool {
        let digest = Self.suppressionDigest(text)
        return try await database.reader { db in (try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM global_memory_suppression WHERE digest=?)", arguments: [digest])) ?? false }
    }
    func forget(_ text: String) async throws {
        let digest = Self.suppressionDigest(text)
        try await database.writer { db in
            try db.execute(sql: "INSERT OR IGNORE INTO global_memory_suppression(digest,created_at) VALUES (?,?)", arguments: [digest, Date().timeIntervalSince1970])
        }
    }
    func controls() async throws -> (paused: Bool, localText: Bool) {
        try await database.reader { db in guard let row = try Row.fetchOne(db, sql: "SELECT paused,local_text_fallback FROM global_memory_controls WHERE id=1") else { return (false, false) }; return (row["paused"], row["local_text_fallback"]) }
    }
    func setControls(paused: Bool, localText: Bool) async throws { try await database.writer { db in try db.execute(sql: "UPDATE global_memory_controls SET paused=?,local_text_fallback=? WHERE id=1", arguments: [paused, localText]) } }
    func status() async throws -> GlobalSourceStatus {
        try await database.reader { db in
            var status = GlobalSourceStatus()
            status.indexedSources = try Int.fetchOne(db, sql: "SELECT count(*) FROM global_memory_sources WHERE available=1 AND excluded=0") ?? 0
            status.indexedChunks = try Int.fetchOne(db, sql: "SELECT count(*) FROM global_memory_chunks") ?? 0
            status.pendingSummaries = try Int.fetchOne(db, sql: "SELECT count(*) FROM global_memory_jobs WHERE phase<>'completed'") ?? 0
            status.unavailableSources = try Int.fetchOne(db, sql: "SELECT count(*) FROM global_memory_sources WHERE available=0") ?? 0
            if let row = try Row.fetchOne(db, sql: "SELECT paused,local_text_fallback FROM global_memory_controls WHERE id=1") { status.paused = row["paused"]; status.localTextFallback = row["local_text_fallback"] }
            return status
        }
    }
}
#endif
