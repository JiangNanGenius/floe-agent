import GRDB

/// Schema v9 normalizes task approval modes without granting new authority
/// to installations whose previous "automatic" and "full control" UI were
/// intentionally backed by the human policy.
enum V9HarnessAndPermissions {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9") { db in
            try db.execute(sql: """
                UPDATE task_policies
                SET approval_mode = 'ask'
                WHERE approval_mode IS NULL
                   OR approval_mode NOT IN ('ask', 'automatic', 'fullAccess');

                -- Previous builds exposed the global Full Control value
                -- without device-owner authentication. Reset only that value;
                -- users may opt back in through the authenticated v9 UI.
                UPDATE app_settings
                SET value_json = '"human"', updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                WHERE key = 'agent.defaultMode' AND value_json = '"fullControl"';
                PRAGMA user_version = 9;
                """)
        }
    }
}
