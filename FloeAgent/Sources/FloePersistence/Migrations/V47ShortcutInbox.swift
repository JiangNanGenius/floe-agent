import GRDB

/// Schema v47 — durable Shortcuts draft inbox.
///
/// `shortcut_draft_inbox` replaces the legacy single-slot
/// `UserDefaults("group.org.floeagent.ios").shortcuts.pendingDraft`, which
/// silently overwrote consecutive `SendToFloe` / `CreateFloeTask`
/// submissions. Entries are FIFO (`seq` unique, assigned inside the enqueue
/// transaction) and are only removed by a destination-verified
/// acknowledgment that presents the exact claim token, mirroring the
/// atomic claim shape of `task_schedule_occurrences` without reusing that
/// ledger. The CHECK pairs keep a row's claim columns consistent with its
/// state; nothing is ever deleted or overwritten before that ack.
enum V47ShortcutInbox {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v47_shortcut_inbox") { db in
            try db.execute(sql: """
                CREATE TABLE shortcut_draft_inbox (
                    id TEXT PRIMARY KEY,
                    seq INTEGER NOT NULL UNIQUE,
                    text TEXT NOT NULL,
                    source TEXT NOT NULL CHECK (source IN (
                        'intentSend', 'intentCreate', 'legacyMigration'
                    )),
                    migration_key TEXT UNIQUE,
                    state TEXT NOT NULL CHECK (state IN ('pending', 'claimed', 'delivered')),
                    claim_token TEXT,
                    claim_epoch TEXT,
                    destination_id TEXT,
                    created_at TEXT NOT NULL,
                    claimed_at TEXT,
                    updated_at TEXT NOT NULL,
                    CHECK (
                        (state = 'pending' AND claim_token IS NULL
                            AND claim_epoch IS NULL AND destination_id IS NULL
                            AND claimed_at IS NULL)
                        OR
                        (state = 'claimed' AND claim_token IS NOT NULL
                            AND claim_epoch IS NOT NULL
                            AND destination_id IS NOT NULL
                            AND claimed_at IS NOT NULL)
                        OR
                        (state = 'delivered')
                    )
                ) STRICT;
                CREATE INDEX idx_shortcut_inbox_state_seq
                    ON shortcut_draft_inbox(state, seq);
                """)
            try db.execute(sql: "PRAGMA user_version = 47")
        }
    }
}
