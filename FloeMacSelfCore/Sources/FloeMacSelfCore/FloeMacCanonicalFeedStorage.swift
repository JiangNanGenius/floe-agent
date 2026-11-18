// SPDX-License-Identifier: MPL-2.0
import FloeDesktopSync
import Foundation
import GRDB

/// Internal transaction seam only. It neither opens a database nor installs
/// anything during runtime bootstrap. The caller must own the GRDB transaction
/// and separately establish real host authority and a reviewed migration.
/// Returned positions are provisional until the outermost transaction commits;
/// they do not authorize reads, establish a snapshot or acknowledge a cursor.
/// Object-name checks do not authenticate schema or trigger definitions.
enum FloeMacCanonicalFeedStorage {
    static func install(in db: Database) throws -> CanonicalMessageFeed.Position {
        guard db.isInsideTransaction else { throw CanonicalMessageFeed.FeedError.transactionRequired }
        guard let connection = db.sqliteConnection else { throw CanonicalMessageFeed.FeedError.unavailable }
        var installed: CanonicalMessageFeed.Position?
        try db.inSavepoint {
            let generation = try CanonicalMessageFeed.install(on: connection)
            let position = try CanonicalMessageFeed.position(on: connection)
            guard position.generation == generation, position.sequence == 0 else {
                throw CanonicalMessageFeed.FeedError.unavailable
            }
            installed = position
            return .commit
        }
        guard let installed else { throw CanonicalMessageFeed.FeedError.unavailable }
        return installed
    }

    static func position(in db: Database) throws -> CanonicalMessageFeed.Position {
        guard let connection = db.sqliteConnection else { throw CanonicalMessageFeed.FeedError.unavailable }
        return try CanonicalMessageFeed.position(on: connection)
    }

    /// Establishes the replay watermark for one authorized conversation scan.
    /// Runs inside the caller's GRDB transaction on the authoritative
    /// connection; the returned watermark is provisional until that
    /// transaction commits. Establishing real host authority and selecting
    /// the conversation (excluding temporary/editor-owned data) remains the
    /// caller's duty.
    static func beginBootstrap(
        in db: Database,
        conversationID: UUID
    ) throws -> CanonicalMessageFeed.Bootstrap {
        guard let connection = db.sqliteConnection else { throw CanonicalMessageFeed.FeedError.unavailable }
        return try CanonicalMessageFeed.beginBootstrap(on: connection, conversationID: conversationID)
    }

    /// Reads one bounded keyset page of an in-flight bootstrap scan. Every
    /// page is validated against the bootstrap generation, so a history
    /// rotation mid-scan fails closed instead of mixing generations.
    static func bootstrapPage(
        in db: Database,
        bootstrap: CanonicalMessageFeed.Bootstrap,
        after: UUID?,
        limit: Int
    ) throws -> CanonicalMessageFeed.BootstrapPage {
        guard let connection = db.sqliteConnection else { throw CanonicalMessageFeed.FeedError.unavailable }
        return try CanonicalMessageFeed.bootstrapPage(on: connection, bootstrap: bootstrap, after: after, limit: limit)
    }

    /// Reads one bounded invalidation page and resolves each entry to the
    /// current canonical row (or a tombstone) in this read snapshot. A
    /// consumer must apply the page and persist `next` atomically; this
    /// wrapper only borrows the caller's transaction.
    static func changes(
        in db: Database,
        conversationID: UUID,
        after position: CanonicalMessageFeed.Position,
        limit: Int
    ) throws -> CanonicalMessageFeed.ChangePage {
        guard let connection = db.sqliteConnection else { throw CanonicalMessageFeed.FeedError.unavailable }
        return try CanonicalMessageFeed.changes(on: connection, conversationID: conversationID, after: position, limit: limit)
    }

    /// Rotates the feed history inside the caller's write transaction. Every
    /// previously issued cursor or bootstrap watermark fails with
    /// `wrongGeneration` afterwards; consumers must rebuild their authorized
    /// projection from a new bootstrap before resuming.
    static func rotateHistory(in db: Database) throws -> CanonicalMessageFeed.Position {
        guard let connection = db.sqliteConnection else { throw CanonicalMessageFeed.FeedError.unavailable }
        return try CanonicalMessageFeed.rotateHistory(on: connection)
    }
}
