// SPDX-License-Identifier: MPL-2.0
import FloeDesktopSync
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
}
