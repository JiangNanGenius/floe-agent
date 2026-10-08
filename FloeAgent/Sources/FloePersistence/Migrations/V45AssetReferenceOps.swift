import GRDB

/// Schema v45: idempotent reachability-reconciliation receipts.
///
/// Canvas reference-count bookkeeping applies each delta as an op with a
/// stable id; the receipt row and the `reference_count` update land in the
/// SAME SQLite transaction, so a crash either applies both or neither, and
/// a replayed op is a recorded no-op instead of double-applying its delta
/// (which could otherwise under-count and make later pruning collect bytes
/// a persisted canvas project still reaches). The on-disk journal of pending
/// ops is only a progress hint — the receipts are the source of truth.
public enum V45AssetReferenceOps {
    public static let identifier = "v45_asset_reference_ops"

    public static let statements: [String] = [
        """
        CREATE TABLE asset_reference_receipts (
            op_id TEXT PRIMARY KEY,
            asset_id TEXT NOT NULL,
            delta INTEGER NOT NULL,
            applied_at TEXT NOT NULL
        )
        """,
        "CREATE INDEX asset_reference_receipts_asset ON asset_reference_receipts(asset_id)",
        "PRAGMA user_version = 45"
    ]

    public static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            for statement in statements {
                try db.execute(sql: statement)
            }
        }
    }
}
