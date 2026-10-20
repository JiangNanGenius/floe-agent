import Foundation
import GRDB
import FloeCore
import FloeModels

/// Identity of the live process. A claim recorded under a different epoch
/// was minted by a process that no longer exists; such claims are settled
/// by inspecting the durable destination, never by a wall-clock lease that
/// could hand the same draft to a second owner while the first is still
/// alive.
public enum ShortcutInboxProcessEpoch {
    public static let value = UUID().uuidString
}

/// Durable FIFO inbox for Shortcuts draft actions
/// (`SendToFloeIntent` / `CreateFloeTaskIntent`).
///
/// The contract borrowed from the scheduled-occurrence ledger is the atomic
/// single-owner claim, but this is its OWN table: schedule history and draft
/// delivery must never be conflated.
///
/// * `enqueue` appends; consecutive submissions each keep a unique id and
///   are returned in FIFO (`seq`) order. Nothing here overwrites an existing
///   entry — except the deliberate `migrationKey` identity, which makes the
///   one-time legacy single-slot migration idempotent across crashes.
/// * `claimNext` flips the oldest NON-TERMINAL row (pending or claimed) to
///   `claimed` with a fresh opaque token in ONE atomic statement: concurrent
///   consumers (including multiple windows) can never both receive the same
///   draft, and an already-claimed head blocks every later pending row until
///   its own token-matched ack or release, so a younger draft can never
///   overtake an unsettled one.
/// * `ack` settles an entry ONLY when the caller presents the exact claim
///   token — i.e. only after the destination has durably verified the
///   content. Ordinary entries are removed; a `migrationKey` entry keeps a
///   `delivered` tombstone so the legacy single-slot key can never
///   redeliver it. A failed or stale ack leaves the entry recoverable.
/// * `release` returns a live claimant's own entry to `pending`; it requires
///   the same token, so a stale releaser cannot disturb a newer handoff.
public protocol ShortcutDraftInboxStore: Sendable {
    /// Appends one draft. With a `migrationKey` the enqueue is idempotent:
    /// a retry returns the existing row (same id) instead of duplicating it.
    @discardableResult
    func enqueue(
        text: String,
        source: ShortcutDraftInboxSource,
        migrationKey: String?
    ) async throws -> ShortcutDraftInboxEntry
    func pendingCount() async throws -> Int
    /// The oldest pending entries, FIFO. Read-only: peeks never claim.
    func pendingEntries(limit: Int) async throws -> [ShortcutDraftInboxEntry]
    func entry(id: UUID) async throws -> ShortcutDraftInboxEntry?
    /// Atomically claims the oldest non-terminal (pending or claimed) entry
    /// for `destinationID`. Exactly one concurrent caller receives a non-nil
    /// entry; a claimed head blocks later pending rows until it settles.
    /// `epoch` defaults to the live process identity; only isolated tests
    /// pass an explicit value.
    func claimNext(
        destinationID: String,
        at date: Date,
        epoch: String
    ) async throws -> ShortcutDraftInboxEntry?
    /// Entries claimed by `epoch` for this destination and not yet settled.
    func claims(
        destinationID: String,
        epoch: String
    ) async throws -> [ShortcutDraftInboxEntry]
    /// Claims left behind by dead processes (epoch differs from the live
    /// process). The caller settles each one against the destination.
    func abandonedClaims(currentEpoch: String) async throws -> [ShortcutDraftInboxEntry]
    /// Settles a verified delivery: removes the entry ONLY while it is still
    /// `claimed` with exactly this token. Returns false otherwise.
    @discardableResult
    func ack(id: UUID, claimToken: String) async throws -> Bool
    /// Gives up a live claim by its own token, returning the entry to
    /// `pending`. Requires the exact token; a stale releaser is rejected.
    @discardableResult
    func release(id: UUID, claimToken: String) async throws -> Bool
}

public extension ShortcutDraftInboxStore {
    func claimNext(destinationID: String, at date: Date) async throws -> ShortcutDraftInboxEntry? {
        try await claimNext(destinationID: destinationID, at: date, epoch: ShortcutInboxProcessEpoch.value)
    }
    func claims(destinationID: String) async throws -> [ShortcutDraftInboxEntry] {
        try await claims(destinationID: destinationID, epoch: ShortcutInboxProcessEpoch.value)
    }
    func abandonedClaims() async throws -> [ShortcutDraftInboxEntry] {
        try await abandonedClaims(currentEpoch: ShortcutInboxProcessEpoch.value)
    }
}

public actor SQLiteShortcutDraftInboxStore: ShortcutDraftInboxStore {
    private let database: DatabaseManager

    public init(database: DatabaseManager) { self.database = database }

    // MARK: - Enqueue

    @discardableResult
    public func enqueue(
        text: String,
        source: ShortcutDraftInboxSource,
        migrationKey: String?
    ) async throws -> ShortcutDraftInboxEntry {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw FloeError.validationFailed("Shortcut draft must not be empty")
        }
        return try await database.writer { db in
            let id: UUID
            if let migrationKey {
                id = ShortcutDraftInboxEntry.stableID(migrationKey: migrationKey)
            } else {
                id = UUID()
            }
            let now = PersistenceCodec.encode(Date())
            try db.execute(sql: """
                INSERT INTO shortcut_draft_inbox (
                    id, seq, text, source, migration_key, state, created_at, updated_at
                ) VALUES (?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM shortcut_draft_inbox), ?, ?, ?, 'pending', ?, ?)
                ON CONFLICT(migration_key) DO NOTHING
                """, arguments: [
                    id.uuidString, clean, source.rawValue, migrationKey, now, now
                ])
            if db.changesCount == 0, let migrationKey {
                // A retry of the same migration source: the row for this
                // stable identity already exists durably. Return it instead
                // of inserting a duplicate (crash-between-steps is safe).
                guard let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM shortcut_draft_inbox WHERE migration_key = ?",
                    arguments: [migrationKey]
                ) else {
                    throw FloeError.storageCorrupted("Shortcut inbox migration row vanished")
                }
                return try Self.decode(row)
            }
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM shortcut_draft_inbox WHERE id = ?",
                arguments: [id.uuidString]
            ) else {
                throw FloeError.storageCorrupted("Shortcut inbox enqueue did not persist")
            }
            return try Self.decode(row)
        }
    }

    // MARK: - Reads

    public func pendingCount() async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM shortcut_draft_inbox WHERE state = 'pending'"
            ) ?? 0
        }
    }

    public func pendingEntries(limit: Int) async throws -> [ShortcutDraftInboxEntry] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM shortcut_draft_inbox
                WHERE state = 'pending'
                ORDER BY seq
                LIMIT ?
                """, arguments: [max(1, min(limit, 200))]).map(Self.decode)
        }
    }

    public func entry(id: UUID) async throws -> ShortcutDraftInboxEntry? {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM shortcut_draft_inbox WHERE id = ?",
                arguments: [id.uuidString]
            ) else { return nil }
            return try Self.decode(row)
        }
    }

    // MARK: - Claim / settle

    public func claimNext(
        destinationID: String,
        at date: Date,
        epoch: String
    ) async throws -> ShortcutDraftInboxEntry? {
        let token = UUID().uuidString
        return try await database.writer { db in
            // One atomic UPDATE over the TRUE FIFO head: the oldest
            // non-terminal row (pending OR claimed). The outer `state =
            // 'pending'` predicate then makes the claim miss when that head is
            // already claimed: a claimed head blocks every later pending row
            // until its own token-matched ack or release settles it, so a
            // failed write plus a failed release can never let a younger draft
            // overtake. Racing claimants serialize on the write transaction;
            // the one that loses sees a claimed head and RETURNs no row.
            guard let row = try Row.fetchOne(db, sql: """
                UPDATE shortcut_draft_inbox
                SET state = 'claimed', claim_token = ?, claim_epoch = ?,
                    destination_id = ?, claimed_at = ?, updated_at = ?
                WHERE id = (
                    SELECT id FROM shortcut_draft_inbox
                    WHERE state IN ('pending', 'claimed')
                    ORDER BY seq
                    LIMIT 1
                ) AND state = 'pending'
                RETURNING *
                """, arguments: [
                    token, epoch, destinationID,
                    PersistenceCodec.encode(date), PersistenceCodec.encode(date)
                ]) else { return nil }
            return try Self.decode(row)
        }
    }

    public func claims(destinationID: String, epoch: String) async throws -> [ShortcutDraftInboxEntry] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM shortcut_draft_inbox
                WHERE state = 'claimed' AND destination_id = ? AND claim_epoch = ?
                ORDER BY seq
                """, arguments: [destinationID, epoch]).map(Self.decode)
        }
    }

    public func abandonedClaims(currentEpoch: String) async throws -> [ShortcutDraftInboxEntry] {
        try await database.reader { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM shortcut_draft_inbox
                WHERE state = 'claimed' AND claim_epoch IS NOT NULL AND claim_epoch <> ?
                ORDER BY seq
                """, arguments: [currentEpoch]).map(Self.decode)
        }
    }

    @discardableResult
    public func ack(id: UUID, claimToken: String) async throws -> Bool {
        try await database.writer { db in
            let date = PersistenceCodec.encode(Date())
            // A migrated entry leaves a durable tombstone instead of being
            // deleted: `UserDefaults` removal is not crash-synchronous with
            // the enqueue, and a late retry of the same stable migration
            // identity must never redeliver an already-consumed draft.
            try db.execute(sql: """
                UPDATE shortcut_draft_inbox
                SET state = 'delivered', updated_at = ?
                WHERE id = ? AND state = 'claimed' AND claim_token = ?
                  AND migration_key IS NOT NULL
                """, arguments: [date, id.uuidString, claimToken])
            if db.changesCount > 0 { return true }
            try db.execute(sql: """
                DELETE FROM shortcut_draft_inbox
                WHERE id = ? AND state = 'claimed' AND claim_token = ?
                  AND migration_key IS NULL
                """, arguments: [id.uuidString, claimToken])
            return db.changesCount > 0
        }
    }

    @discardableResult
    public func release(id: UUID, claimToken: String) async throws -> Bool {
        try await database.writer { db in
            let date = PersistenceCodec.encode(Date())
            try db.execute(sql: """
                UPDATE shortcut_draft_inbox
                SET state = 'pending', claim_token = NULL, claim_epoch = NULL,
                    destination_id = NULL, claimed_at = NULL, updated_at = ?
                WHERE id = ? AND state = 'claimed' AND claim_token = ?
                """, arguments: [date, id.uuidString, claimToken])
            return db.changesCount > 0
        }
    }

    // MARK: - Decoding

    private static func decode(_ row: Row) throws -> ShortcutDraftInboxEntry {
        guard let id = UUID(uuidString: row["id"]),
              let text: String = row["text"],
              let source = ShortcutDraftInboxSource(rawValue: row["source"]),
              let state = ShortcutDraftInboxState(rawValue: row["state"]),
              let createdAt = try? PersistenceCodec.decodeDate(row["created_at"]),
              let updatedAt = try? PersistenceCodec.decodeDate(row["updated_at"]) else {
            throw FloeError.storageCorrupted("Invalid shortcut inbox row")
        }
        func date(_ column: String) -> Date? {
            (row[column] as String?).flatMap { try? PersistenceCodec.decodeDate($0) }
        }
        return ShortcutDraftInboxEntry(
            id: id,
            text: text,
            source: source,
            migrationKey: row["migration_key"],
            state: state,
            claimToken: row["claim_token"],
            claimEpoch: row["claim_epoch"],
            destinationID: row["destination_id"],
            createdAt: createdAt,
            claimedAt: date("claimed_at"),
            updatedAt: updatedAt
        )
    }
}
