// FloePersistence — Schema v6: generic non-secret app settings.
// See docs/ARCHITECTURE_SETTINGS.md §2.3. Append-only migration: v1–v5 are
// frozen; v6 only adds the `app_settings` key/value table. Secrets and
// identifiers of secrets never land here.

import GRDB

enum V6AppSettings {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6") { db in
            try db.execute(sql: """
                -- Generic non-secret user preferences. Keys are namespaced by
                -- category ("agent.defaultMode", "exec.timeoutSeconds", ...).
                -- Values are JSON scalars/objects. Secrets and identifiers of
                -- secrets never land here.
                CREATE TABLE app_settings (
                    key TEXT PRIMARY KEY,
                    value_json TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                ) STRICT;

                PRAGMA user_version = 6;
                """)
        }
    }
}
