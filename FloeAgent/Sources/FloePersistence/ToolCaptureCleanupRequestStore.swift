// FloePersistence — durable tool-capture cleanup intents over `app_settings`.
//
// Why this exists: when a conversation deletion is confirmed but the tool
// result capture root is unavailable, the file tombstone under the capture
// root cannot be written, so counting the failure alone leaves NO durable
// retry intent across a cold launch. This store records the deletion-time
// intent in SQLite (which is independent of the capture root), reusing the
// existing v6 `app_settings` table: no new schema, no migration, no FK.
//
// Trust and privacy rules:
//  * Keys are generated exclusively from canonical `uuidString` values that
//    the caller supplies as conversation IDs. The value carries only the
//    conversation UUID, a format version and the request time — never user
//    text, titles, paths or credentials.
//  * Requests are deliberately NOT linked by a foreign key: the intent must
//    outlive the confirmed owner deletion (that deletion is precisely what
//    the request exists to finish). Conversation cascades never touch
//    `app_settings`, and only `acknowledge` removes a request.
//  * Reads are strict: a row under this prefix that is not exactly what this
//    store writes is reported as `corruptState` instead of being silently
//    skipped — a tampered row can never masquerade as a clean queue.
//  * Every SQLite failure propagates unchanged. Nothing here can report a
//    cleanup as persisted when the write did not happen.

import Foundation
import GRDB

/// One durable tool-capture cleanup intent. Non-secret by construction:
/// UUID + request time only.
public struct ToolCaptureCleanupRequest: Sendable, Equatable {
    public var conversationID: UUID
    public var requestedAt: Date

    public init(conversationID: UUID, requestedAt: Date) {
        self.conversationID = conversationID
        self.requestedAt = requestedAt
    }
}

public enum ToolCaptureCleanupRequestStoreError: Error, Sendable, Equatable {
    /// A row under this store's prefix is not in the exact canonical shape
    /// this store writes. The queue stays unreadable (and un-"cleaned")
    /// until the row is removed through `acknowledge` (exact-key delete) or
    /// explicit raw repair.
    case corruptState
}

/// Typed `app_settings` queue of "the tool capture directory for this
/// deleted conversation still must be purged" intents. Cold launch merges
/// these durable requests with the capture root's retry tombstones.
public actor ToolCaptureCleanupRequestStore {

    /// Unique, trusted `app_settings` namespace for these requests. The
    /// prefix contains no LIKE wildcards (`%`, `_`), so `prefix + "%"` is an
    /// exact namespace filter over canonically generated keys.
    public static let requestKeyPrefix = "tools.captureCleanup.request."

    /// Honest bound for one listing pass. `count()` reports the true total
    /// even beyond this cap, so a backlog is visible, never truncated away.
    public static let maximumListedRequests = 512

    static let maximumValueBytes = 4096
    static let formatVersion = "1"

    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    // MARK: - Enqueue

    /// Persists the cleanup intent for one conversation. Idempotent by
    /// identity: an existing request keeps its ORIGINAL `requestedAt` and
    /// the call returns that stored record unchanged. A real SQLite failure
    /// throws and nothing is claimed to be persisted.
    /// Callers must enqueue BEFORE the conversation's durable deletion and
    /// must abort the deletion when this throws.
    @discardableResult
    public func enqueue(conversationID: UUID, now: Date = Date()) async throws -> ToolCaptureCleanupRequest {
        try await database.writer { db in
            let key = Self.key(for: conversationID)
            if let existing = try Self.readIfPresent(key: key, db: db) {
                return existing
            }
            let record = ToolCaptureCleanupRequest(conversationID: conversationID, requestedAt: now)
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value_json, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(key) DO NOTHING
                    """,
                arguments: [key, try Self.encodedValue(record), PersistenceCodec.encode(now)]
            )
            return record
        }
    }

    // MARK: - Read

    /// Durable requests oldest-first, bounded by `limit` (clamped to
    /// `maximumListedRequests`). Never skips a row silently: a row that is
    /// not in the exact canonical shape this store writes throws
    /// `corruptState` so the caller keeps the queue unknown instead of
    /// pretending it drained.
    public func pendingRequests(limit: Int = ToolCaptureCleanupRequestStore.maximumListedRequests)
        async throws -> [ToolCaptureCleanupRequest]
    {
        let bounded = max(0, min(limit, Self.maximumListedRequests))
        return try await database.reader { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT key, value_json FROM app_settings
                WHERE key LIKE ?
                ORDER BY updated_at ASC, key ASC
                LIMIT ?
                """, arguments: [Self.requestKeyPrefix + "%", bounded])
            return try rows.map { row in
                guard let key: String = row["key"], let value: String = row["value_json"] else {
                    throw ToolCaptureCleanupRequestStoreError.corruptState
                }
                return try Self.parse(key: key, value: value)
            }
        }
    }

    /// Conversation IDs of the durable cleanup requests, oldest-first.
    public func pendingConversationIDs(limit: Int = ToolCaptureCleanupRequestStore.maximumListedRequests)
        async throws -> [UUID]
    {
        try await pendingRequests(limit: limit).map(\.conversationID)
    }

    /// True only when a canonical request row exists for this conversation;
    /// a tampered row under the exact key throws `corruptState`.
    public func hasRequest(conversationID: UUID) async throws -> Bool {
        try await database.reader { db in
            try Self.readIfPresent(key: Self.key(for: conversationID), db: db) != nil
        }
    }

    /// Honest total backlog of request rows, including rows beyond the
    /// listing cap and any non-canonical row under this prefix.
    public func count() async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM app_settings WHERE key LIKE ?",
                             arguments: [Self.requestKeyPrefix + "%"]) ?? 0
        }
    }

    // MARK: - Acknowledge

    /// Removes exactly one cleanup request by its canonical key. This is the
    /// ONLY record this call can delete; unrelated and live rows are never
    /// touched. Returns `false` when no request existed (already
    /// acknowledged — never an error). A real SQLite failure THROWS instead
    /// of reporting a removal, so the request survives the failed call.
    /// `acknowledge` is legitimate both after a confirmed purge AND to
    /// cancel a stale request whose conversation still exists; neither path
    /// may claim file cleanup without checking the durable root.
    @discardableResult
    public func acknowledge(conversationID: UUID) async throws -> Bool {
        try await database.writer { db in
            try db.execute(sql: "DELETE FROM app_settings WHERE key = ?",
                           arguments: [Self.key(for: conversationID)])
            return db.changesCount > 0
        }
    }

    // MARK: - Canonical key/value helpers

    static func key(for conversationID: UUID) -> String {
        requestKeyPrefix + conversationID.uuidString
    }

    static func encodedValue(_ record: ToolCaptureCleanupRequest) throws -> String {
        try PersistenceCodec.jsonObject([
            "v": formatVersion,
            "conversationID": record.conversationID.uuidString,
            "requestedAt": PersistenceCodec.encode(record.requestedAt),
        ])
    }

    static func readIfPresent(key: String, db: Database) throws -> ToolCaptureCleanupRequest? {
        guard let value = try String.fetchOne(db, sql: "SELECT value_json FROM app_settings WHERE key = ?",
                                              arguments: [key]) else { return nil }
        return try parse(key: key, value: value)
    }

    /// Strict decode. The key suffix must be a canonical `uuidString`
    /// (upper-case round-trip), and the value must contain exactly this
    /// store's fields with the SAME conversation ID and a parseable ISO-8601
    /// request time. Anything else is `corruptState`, never a silent skip.
    static func parse(key: String, value: String) throws -> ToolCaptureCleanupRequest {
        guard value.utf8.count <= maximumValueBytes,
              key.hasPrefix(requestKeyPrefix) else {
            throw ToolCaptureCleanupRequestStoreError.corruptState
        }
        let raw = String(key.dropFirst(requestKeyPrefix.count))
        guard let conversationID = UUID(uuidString: raw), conversationID.uuidString == raw else {
            throw ToolCaptureCleanupRequestStoreError.corruptState
        }
        do {
            let fields = try PersistenceCodec.jsonDictionary(value)
            guard fields["v"] == formatVersion,
                  fields["conversationID"] == conversationID.uuidString,
                  let requestedAtText = fields["requestedAt"],
                  Set(fields.keys) == ["v", "conversationID", "requestedAt"] else {
                throw ToolCaptureCleanupRequestStoreError.corruptState
            }
            let requestedAt = try PersistenceCodec.decodeDate(requestedAtText)
            guard PersistenceCodec.encode(requestedAt) == requestedAtText else {
                throw ToolCaptureCleanupRequestStoreError.corruptState
            }
            return ToolCaptureCleanupRequest(conversationID: conversationID, requestedAt: requestedAt)
        } catch {
            throw ToolCaptureCleanupRequestStoreError.corruptState
        }
    }
}
