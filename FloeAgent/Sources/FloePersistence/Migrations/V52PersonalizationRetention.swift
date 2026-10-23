// FloePersistence — Schema v52: bounded personalization retention.
//
// Each (kind, workspace) personalization lane keeps at most TWO documents:
// the active `current` and the last confidently activated `previous` backup.
// Automatic cadence updates now apply silently under CAS (user policy: no
// second confirmation), so there is no retained "pending proposal" slot:
// legacy never-activated `automatic` drafts are obsolete review artifacts
// and are pruned. Trimming is enforced here, by the partial unique lifecycle
// indexes, and by the runtime store's rotation statements.
//
// `personalization_revision_sequences` owns the monotonic revision allocator
// so a revision number is never reused after its row is pruned.
//
// The backfill is deliberately conservative about legacy rows: only rows
// whose source kind (`manual`, `oneClick`, `rollback`) proves they were
// written as ACTIVE documents can become the activated backup. An inactive
// `automatic` row may have been activated once and later replaced, or may
// have been an unreviewed draft — history cannot tell, and silent activation
// of such a draft on upgrade is explicitly forbidden, so every inactive
// `automatic` row is pruned instead of being promoted into either slot.
//
// `backfill` is a separate static entry point because qualification tests
// re-run it against synthetic legacy data after the full migration set has
// already applied it to an empty table. It is idempotent for already
// classified lanes and never lowers the revision allocator.

import Foundation
import GRDB

enum V52PersonalizationRetention {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v52_personalization_retention") { db in
            try db.execute(sql: """
                ALTER TABLE personalization_documents
                    ADD COLUMN lifecycle TEXT
                """)
            try db.execute(sql: """
                CREATE TABLE personalization_revision_sequences (
                    kind TEXT NOT NULL CHECK (kind IN ('soul', 'userProfile')),
                    workspace_key TEXT NOT NULL DEFAULT '',
                    workspace_id TEXT REFERENCES workspaces(id) ON DELETE CASCADE,
                    last_revision INTEGER NOT NULL DEFAULT 0 CHECK (last_revision >= 0),
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (kind, workspace_key),
                    CHECK (
                        (workspace_key = '' AND workspace_id IS NULL) OR
                        (workspace_key <> '' AND workspace_id = workspace_key)
                    )
                ) STRICT;
                """)
            try Self.backfill(db, now: ISO8601DateFormatter().string(from: Date()))
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_personalization_lifecycle_global
                    ON personalization_documents(kind, lifecycle)
                    WHERE workspace_id IS NULL AND lifecycle IS NOT NULL;
                CREATE UNIQUE INDEX idx_personalization_lifecycle_workspace
                    ON personalization_documents(kind, workspace_id, lifecycle)
                    WHERE workspace_id IS NOT NULL AND lifecycle IS NOT NULL;
                """)
            try db.execute(sql: "PRAGMA user_version = 52")
        }
    }

    /// Classifies legacy rows into the bounded `current` / `previous` slots,
    /// prunes obsolete drafts and superseded backups, and seeds the monotonic
    /// revision allocator. Safe to run repeatedly.
    static func backfill(_ db: Database, now: String) throws {
        // 1. Seed (or only ever raise) the allocator from the revisions that
        //    still exist, so a pruned number is never handed out again.
        try db.execute(sql: """
            INSERT INTO personalization_revision_sequences
                (kind, workspace_key, workspace_id, last_revision, updated_at)
            SELECT kind, COALESCE(workspace_id, ''), workspace_id,
                   MAX(revision), ?
            FROM personalization_documents
            GROUP BY kind, COALESCE(workspace_id, '')
            ON CONFLICT(kind, workspace_key) DO UPDATE SET
                last_revision = MAX(personalization_revision_sequences.last_revision,
                                    excluded.last_revision),
                updated_at = excluded.updated_at
            """, arguments: [now])

        // 2. The active row is the lane's current document.
        try db.execute(sql: """
            UPDATE personalization_documents SET lifecycle = 'current'
            WHERE is_active = 1 AND lifecycle IS NULL
            """)

        // 3. The last confidently activated backup: the highest inactive row
        //    whose source proves it was once saved as an active document.
        //    Inactive `automatic` rows are excluded — they are ambiguous and
        //    must never be presented or silently treated as activated data.
        try db.execute(sql: """
            UPDATE personalization_documents SET lifecycle = 'previous'
            WHERE id IN (
                SELECT id FROM (
                    SELECT id, ROW_NUMBER() OVER (
                        PARTITION BY kind, COALESCE(workspace_id, '')
                        ORDER BY revision DESC
                    ) AS rank
                    FROM personalization_documents
                    WHERE lifecycle IS NULL AND is_active = 0
                      AND source_kind <> 'automatic'
                ) WHERE rank = 1
            )
            """)

        // 4. Everything else — obsolete unreviewed automatic drafts, extra
        //    superseded backups and duplicate rows — is pruned. The live
        //    final state keeps at most current + previous per lane.
        try db.execute(sql: """
            DELETE FROM personalization_documents WHERE lifecycle IS NULL
            """)

        // 5. Re-align the legacy activation flag with the lifecycle slot so
        //    existing snapshot readers keep seeing exactly the current row.
        try db.execute(sql: """
            UPDATE personalization_documents
            SET is_active = CASE WHEN lifecycle = 'current' THEN 1 ELSE 0 END
            """)
    }
}
